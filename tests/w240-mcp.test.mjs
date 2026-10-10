import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

import vm from 'node:vm';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

async function claudeExpansionProof() {
  const root = testScratch('w240-claude-expansion-');
  const at = name => path.join(root, name);
  for (const dir of ['home', 'claude']) fs.mkdirSync(at(dir));
  const digest = value => createHash('sha256').update(value).digest('hex');
  let headersReached = false;
  const sourceEnvironment = { W240_INPUT: 'W240_FAKE_REFERENCED_ENV', W240_INPUT_HEADER: 'W240_FAKE_REFERENCED_HEADER' };
  const headerValues = { Authorization: 'W240_FAKE_PLAIN_AUTH', 'X-Custom': 'W240_FAKE_CUSTOM_HEADER', 'X-Referenced': 'Bearer ${W240_INPUT_HEADER}' };
  const resolvedHeaders = { ...headerValues, 'X-Referenced': `Bearer ${sourceEnvironment.W240_INPUT_HEADER}` };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', data => { body += data; });
    req.on('end', () => {
      headersReached = Object.entries(resolvedHeaders).every(([key, value]) => digest(req.headers[key.toLowerCase()] ?? '') === digest(value));
      if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
      const message = JSON.parse(body);
      if (message.id === undefined) { res.writeHead(202); res.end(); return; }
      const result = message.method === 'initialize' ? { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' } } : { tools: [] };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }));
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const values = { OTHER: 'W240_FAKE_PLAIN_ENV', SOCKET_PATH: '/fake/w240.sock', EMPTY: '', RECEIPT: at('child.json'), REFERENCED: '${W240_INPUT}', DEFAULT: '${W240_ABSENT:-W240_FAKE_DEFAULT}', MISSING: '${W240_ABSENT}' };
  const resolvedValues = { ...values, REFERENCED: sourceEnvironment.W240_INPUT, DEFAULT: 'W240_FAKE_DEFAULT' };
  const childCode = `const fs=require('node:fs'),rl=require('node:readline'),{createHash}=require('node:crypto'); const expected=${JSON.stringify(Object.fromEntries(Object.entries(resolvedValues).map(([key, value]) => [key, digest(value)])))}; rl.createInterface({input:process.stdin}).on('line',line=>{ const m=JSON.parse(line); if(m.id===undefined)return; if(m.method==='initialize') fs.writeFileSync(process.env.RECEIPT,JSON.stringify({initialized:true,envReachedChild:Object.entries(expected).every(([k,v])=>createHash('sha256').update(process.env[k]??'').digest('hex')===v)})); const result=m.method==='initialize'?{protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}}:{tools:[]}; process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n'); });`;
  const config = { engine: 'claude', servers: {
    w240_local: { command: process.execPath, args: ['-e', childCode], env: values },
    w240_http: { type: 'http', url: `http://127.0.0.1:${server.address().port}/mcp`, headers: headerValues },
  } };
  let options;
  const environment = { ...sourceEnvironment, HOME: at('home'), CFFIXED_USER_HOME: at('home'), CLAUDE_CONFIG_DIR: at('claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('claude'), PATH: process.env.PATH, TATWO2_MCP_CONFIG: JSON.stringify(config) };
  const source = fs.readFileSync('Engines/claude-sidecar/sidecar.mjs', 'utf8');
  const prelude = source.slice(0, source.indexOf('const rl =')).replace(/^import .+;\n/gm, '').replaceAll('import.meta.url', JSON.stringify(new URL('../Engines/claude-sidecar/sidecar.mjs', import.meta.url).href));
  vm.runInNewContext(prelude, { path, fs, fileURLToPath, process: { argv: ['node', 'fixture'], env: environment, cwd: () => root }, query: input => { options = input.options; return {}; } });
  const forwarded = Object.fromEntries(Object.keys(config.servers).map(name => [name, options.mcpServers[name]]));
  const cliConfig = JSON.stringify({ mcpServers: forwarded });
  const privateValues = [...Object.values(values), ...Object.values(headerValues), ...Object.values(resolvedValues), ...Object.values(resolvedHeaders)].filter(Boolean);
  for (const value of privateValues) assert.ok(!cliConfig.includes(value), 'original and resolved env/header values stay out of CLI configuration');
  for (const definition of Object.values(forwarded)) for (const value of Object.values(definition.env ?? definition.headers ?? {})) assert.match(value, /^\$\{TATWO2_MCP_SECRET_\d+\}$/);
  fs.writeFileSync(at('claude/.claude.json'), cliConfig);
  const cliPath = process.env.TATWO2_W240_CLAUDE_BIN ?? (process.env.PATH ?? '').split(path.delimiter).map(dir => path.join(dir, 'claude')).find(file => fs.existsSync(file));
  assert.ok(cliPath, 'local Claude CLI is required for expansion proof');
  const cli = fs.realpathSync(cliPath);
  const isolatedEnv = { ...options.env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' };
  const profile = '(version 1)(allow default)(deny network*)(allow network-inbound (local ip "localhost:*"))(allow network-outbound (remote ip "localhost:*"))(deny mach-lookup (global-name-prefix "com.apple.securityd"))';
  const cliArgs = ['-p', profile, cli, 'mcp', 'list'];
  for (const value of privateValues) assert.ok(!JSON.stringify(cliArgs).includes(value));
  const child = spawn('/usr/bin/sandbox-exec', cliArgs, { env: isolatedEnv, cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { output += data; });
  const timer = setTimeout(() => child.kill(), 45_000);
  let status;
  try { status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); }); }
  finally { clearTimeout(timer); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  assert.equal(status, 0, output);
  assert.deepEqual(JSON.parse(fs.readFileSync(at('child.json'), 'utf8')), { initialized: true, envReachedChild: true });
  assert.equal(headersReached, true, 'actual Claude CLI expands header aliases before connecting to fake HTTP MCP');
  assert.equal(environment.TATWO2_MCP_CONFIG, undefined);
  const evidence = { claudeCLI: path.basename(cli), initialized: true, envReachedChild: true, headersReached: true, secretInArgv: false };
  fs.writeFileSync(at('evidence.json'), JSON.stringify(evidence, null, 2));
  console.log('W240MCP PASS M5 actual Claude alias expansion ' + JSON.stringify(evidence));
}

if (process.argv.includes('--claude-expansion-proof')) {
  await claudeExpansionProof();
  process.exit(0);
}

test('W240 MCP acceptance runs clean', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w240-mcp-');
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
    TATWO2_SELFTEST: 'w240mcp', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
  for (const phase of ['index', 'cards']) for (const theme of ['light', 'dark']) {
    const file = at(`artifacts/w240-${phase}-${theme}.png`);
    assert.ok(fs.statSync(file).size > 1000, `missing screenshot: ${file}`);
  }
});

test('Codex forwards bare keys, TOML fields and merged inherited/alias env to MCP child', () => {
  const source = fs.readFileSync('Engines/codex-sidecar/sidecar.mjs', 'utf8');
  const config = { engine: 'codex', enabled: ['fields'], servers: { fields: {
    command: process.execPath, args: ['-e', 'console.log(JSON.stringify({inherited:process.env.INHERITED,own:process.env.OTHER,cwd:process.cwd()}))'],
    env: { OTHER: 'W240_FAKE_OWN' }, env_vars: ['INHERITED'], cwd: process.cwd(), startup_timeout_sec: 12.5, tool_timeout_sec: 90, bearer_token_env_var: 'BEARER_FIXTURE',
  }, remote: { url: 'https://fixture.invalid/mcp', bearer_token_env_var: 'REMOTE_BEARER' } } };
  const forwarded = vm.runInNewContext(source.slice(source.indexOf('const shellQuote ='), source.indexOf('// OS 上游宣告：')) + '\n({args:githubMCPArgs,env:githubMCPEnvironment})', { mcpConfig: config });
  const definition = {};
  for (let i = 1; i < forwarded.args.length; i += 2) {
    const assignment = forwarded.args[i], prefix = 'mcp_servers.fields.';
    if (!assignment.startsWith(prefix)) continue;
    const equal = assignment.indexOf('=', prefix.length);
    definition[assignment.slice(prefix.length, equal)] = JSON.parse(assignment.slice(equal + 1));
  }
  assert.equal(definition.cwd, process.cwd());
  assert.equal(definition.startup_timeout_sec, 12.5);
  assert.equal(definition.tool_timeout_sec, 90);
  assert.equal(definition.bearer_token_env_var, 'BEARER_FIXTURE');
  assert.ok(forwarded.args.includes('mcp_servers.remote.bearer_token_env_var="REMOTE_BEARER"'));
  assert.ok(definition.env_vars.includes('INHERITED'));
  assert.equal(definition.env_vars.length, 2);
  const env = Object.fromEntries(definition.env_vars.map(key => [key, key === 'INHERITED' ? 'W240_FAKE_INHERITED' : forwarded.env[key]]));
  const child = spawnSync(definition.command, definition.args, { env, cwd: definition.cwd, encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  assert.deepEqual(JSON.parse(child.stdout), { inherited: 'W240_FAKE_INHERITED', own: 'W240_FAKE_OWN', cwd: process.cwd() });
  assert.ok(!JSON.stringify(forwarded.args).includes('W240_FAKE_OWN'));
});
