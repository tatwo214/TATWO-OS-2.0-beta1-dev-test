import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

if (process.argv.includes('--consent-proof')) {
  const config = JSON.parse(process.env.W245_PAYLOAD);
  const options = claudeForward(config, process.env.HOME);
  const imported = Object.keys(config.servers).find(name => !name.startsWith('tatwo'));
  if (imported) {
    const server = options.mcpServers[imported];
    const env = { ...process.env, ...options.env, ...Object.fromEntries(Object.entries(server.env ?? {}).map(([key, value]) => [key, value.replace(/\$\{([^}]+)\}/g, (_, alias) => options.env[alias])])) };
    const child = spawnSync(server.command, server.args, { env, encoding: 'utf8' });
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout), { pathOK: true, tokenOK: true });
    console.log('W245 CONSENT PASS child started');
  } else {
    assert.equal(Object.keys(config.servers).length, 0);
    console.log('W245 CONSENT PASS child withheld');
  }
  process.exit(0);
}

if (process.argv.includes('--engine-proof')) { engineProof(); process.exit(0); }

test('W245 MCP fourth-round acceptance runs clean', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w245-mcp-');
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
    TATWO2_SELFTEST: 'w245mcp', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
  for (const phase of ['index', 'cards']) for (const theme of ['light', 'dark']) assert.ok(fs.statSync(at(`artifacts/w245-${phase}-${theme}.png`)).size > 1000);
});

function codexForward(config) {
  const source = fs.readFileSync('Engines/codex-sidecar/sidecar.mjs', 'utf8');
  return vm.runInNewContext(source.slice(source.indexOf('const shellQuote ='), source.indexOf('// OS 上游宣告：')) + '\n({args:githubMCPArgs,env:githubMCPEnvironment})', { mcpConfig: structuredClone(config) });
}
function claudeForward(config, root) {
  const source = fs.readFileSync('Engines/claude-sidecar/sidecar.mjs', 'utf8');
  const prelude = source.slice(0, source.indexOf('const rl =')).replace(/^import .+;\n/gm, '').replaceAll('import.meta.url', JSON.stringify(new URL('../Engines/claude-sidecar/sidecar.mjs', import.meta.url).href));
  let options;
  vm.runInNewContext(prelude, { path, fs, fileURLToPath, process: { argv: ['node', 'fixture'], env: { TATWO2_MCP_CONFIG: JSON.stringify(config) }, cwd: () => root }, query: input => { options = input.options; return {}; } });
  return options;
}

function engineProof() {
  const root = testScratch('w245-url-');
  const childCode = "process.stdout.write(JSON.stringify({argv:process.argv.slice(1),started:true}))";
  const fakePAT = ['ghp', 'W245_FAKE'].join('_');
  const urls = ['https://fixture.invalid/mcp#access_token=W245_FAKE', 'https://fixture.invalid/mcp#%61pi_key=W245_FAKE', `https://fixture.invalid/mcp#x=${fakePAT}`, 'https://fixture.invalid/mcp#password=W245_FAKE'];
  for (const url of urls) {
    const config = { engine: 'codex', enabled: ['remote', 'stdio', 'control'], servers: {
      remote: { url }, stdio: { command: process.execPath, args: ['-e', childCode, '--url=' + url] }, control: { command: process.execPath, args: ['-e', childCode, 'safe'] },
    } };
    const codex = codexForward(config), claude = claudeForward({ ...config, engine: 'claude' }, root);
    assert.ok(!JSON.stringify(codex.args).includes(url));
    assert.ok(codex.args.includes('mcp_servers.remote.enabled=false'));
    assert.ok(codex.args.includes('mcp_servers.stdio.enabled=false'));
    assert.equal(claude.mcpServers.remote, undefined); assert.equal(claude.mcpServers.stdio, undefined);
    assert.ok(!JSON.stringify(claude.mcpServers).includes(url));
    for (const definition of [claude.mcpServers.control, { command: JSON.parse(codex.args.find(a => a.startsWith('mcp_servers.control.command=')).split('=')[1]), args: JSON.parse(codex.args.find(a => a.startsWith('mcp_servers.control.args=')).slice('mcp_servers.control.args='.length)) }]) {
      const child = spawnSync(definition.command, definition.args, { env: {}, cwd: root, encoding: 'utf8' });
      assert.equal(child.status, 0, child.stderr);
      assert.deepEqual(JSON.parse(child.stdout), { argv: ['safe'], started: true });
    }
  }
  console.log('W245 ENGINE PASS fragment exclusion');
}

test('B1 fake MCP child proves fragment exclusion in both engine configurations', engineProof);
