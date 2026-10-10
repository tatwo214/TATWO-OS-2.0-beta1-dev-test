import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

test('both sidecars forward an imported MCP and its current env without secret argv', () => {
  const root = testScratch('w235-forwarding-');
  const values = { TOKEN: 'W235_FAKE_ONLY_TOKEN', OTHER: 'W235_FAKE_ONLY_OTHER' };
  const hashes = Object.fromEntries(Object.entries(values).map(([key, value]) => [key, createHash('sha256').update(value).digest('hex')]));
  const script = `const {createHash}=require('node:crypto'); const expected=${JSON.stringify(hashes)}; process.stdout.write(JSON.stringify({envOK:Object.entries(expected).every(([k,v])=>createHash('sha256').update(process.env[k]??'').digest('hex')===v),argsOK:process.argv[1]==='a b'&&process.argv[2]==="a'b"}));`;
  const servers = {
    'w235-imported': { command: process.execPath, args: ['-e', script, 'a b', "a'b"], env: values },
    'github-Fixture': { command: '/fixture/github-mcp', args: ['stdio'] },
  };
  const config = { engine: 'codex', servers, configured: Object.keys(servers), enabled: Object.keys(servers) };
  const codex = fs.readFileSync('Engines/codex-sidecar/sidecar.mjs', 'utf8');
  const forwarded = vm.runInNewContext(codex.slice(codex.indexOf('const shellQuote ='), codex.indexOf('// OS 上游宣告：')) + '\n({args:githubMCPArgs,env:githubMCPEnvironment})', { mcpConfig: structuredClone(config) });
  const definition = {};
  for (let i = 1; i < forwarded.args.length; i += 2) {
    const assignment = forwarded.args[i];
    const prefix = 'mcp_servers.w235-imported.';
    if (!assignment.startsWith(prefix)) continue;
    const separator = assignment.indexOf('=', prefix.length);
    definition[assignment.slice(prefix.length, separator)] = JSON.parse(assignment.slice(separator + 1));
  }
  const assertChild = (command, args, env) => {
    const child = spawnSync(command, args, { env: { ...process.env, ...env }, encoding: 'utf8', timeout: 10_000 });
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout), { envOK: true, argsOK: true });
  };
  assertChild(definition.command, definition.args, Object.fromEntries(definition.env_vars.map(key => [key, forwarded.env[key]])));
  for (const value of Object.values(values)) assert.ok(!JSON.stringify(forwarded.args).includes(value));
  const codexEvidence = { importedForwarded: !!definition.command, githubControlForwarded: forwarded.args.some(arg => arg.includes('github-Fixture')), envForwarded: Object.keys(forwarded.env).length, envReachedChild: true, secretInArgv: false };
  assert.deepEqual(codexEvidence, { importedForwarded: true, githubControlForwarded: true, envForwarded: 2, envReachedChild: true, secretInArgv: false });
  const extra = vm.runInNewContext(codex.slice(codex.indexOf('const shellQuote ='), codex.indexOf('// OS 上游宣告：')) + '\n({args:githubMCPArgs,env:githubMCPEnvironment})', { mcpConfig: {
    engine: 'codex', enabled: ['remote.with.dot'], servers: {
      'remote.with.dot': { url: 'https://fixture.invalid/mcp', headers: { Authorization: values.TOKEN } },
      disabled: servers['w235-imported'],
    },
  } });
  assert.equal(Object.keys(extra.env).length, 1, 'disabled MCP secrets are omitted');
  assert.ok(extra.args.some(arg => arg.includes('env_http_headers') && arg.includes('Authorization')));
  assert.ok(extra.args.some(arg => arg === 'mcp_servers.disabled.enabled=false'));
  assert.ok(extra.args.some(arg => arg.startsWith('mcp_servers.disabled.command=')), 'disabled definition retains its transport');
  for (const value of Object.values(values)) assert.ok(!JSON.stringify(extra.args).includes(value));

  const claude = fs.readFileSync('Engines/claude-sidecar/sidecar.mjs', 'utf8');
  let options;
  const environment = { TATWO2_MCP_CONFIG: JSON.stringify({ ...config, engine: 'claude' }) };
  const prelude = claude.slice(0, claude.indexOf('const rl =')).replace(/^import .+;\n/gm, '').replaceAll('import.meta.url', JSON.stringify(new URL('../Engines/claude-sidecar/sidecar.mjs', import.meta.url).href));
  vm.runInNewContext(prelude, { path, fs, fileURLToPath, process: { argv: ['node', 'fixture'], env: environment, cwd: () => root }, query: input => { options = input.options; return {}; } });
  const imported = options.mcpServers['w235-imported'];
  const env = Object.fromEntries(Object.entries(imported.env).map(([key, value]) => [key, value.replace(/\$\{([^}]+)\}/g, (_, alias) => options.env[alias])]));
  assertChild(imported.command, imported.args, env);
  for (const value of Object.values(values)) assert.ok(!JSON.stringify(options.mcpServers).includes(value));
  assert.equal(environment.TATWO2_MCP_CONFIG, undefined);
  const claudeEvidence = { importedForwarded: !!imported.command, githubControlForwarded: !!options.mcpServers['github-Fixture'], envForwarded: Object.keys(env).length, secretAliases: Object.keys(environment).length, envReachedChild: true, secretInArgv: false };
  assert.deepEqual(claudeEvidence, { importedForwarded: true, githubControlForwarded: true, envForwarded: 2, secretAliases: 2, envReachedChild: true, secretInArgv: false });
  fs.writeFileSync(path.join(root, 'codex-forwarding-evidence.json'), JSON.stringify(codexEvidence, null, 2));
  fs.writeFileSync(path.join(root, 'claude-forwarding-evidence.json'), JSON.stringify(claudeEvidence, null, 2));
});

test('W235 MCP discovery, secret-free imports and confirmed updates run clean', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w235-mcp-');
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  const at = name => path.join(root, name);
  const env = {
    ...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'),
    TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
    CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
    CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_SELFTEST: 'w235mcp', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
  for (const phase of ['index', 'updates']) for (const theme of ['light', 'dark']) {
    const file = at(`artifacts/w235-${phase}-${theme}.png`);
    assert.ok(fs.statSync(file).size > 1000, `missing screenshot: ${file}`);
  }
});
