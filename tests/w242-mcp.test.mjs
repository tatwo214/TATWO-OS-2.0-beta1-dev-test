import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import vm from 'node:vm';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

if (process.argv.includes('--engine-proof')) { await engineProof(); process.exit(0); }

test('W242 MCP third-round acceptance runs clean', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w242-mcp-');
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
    TATWO2_SELFTEST: 'w242mcp', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
  for (const phase of ['index', 'cards']) for (const theme of ['light', 'dark']) assert.ok(fs.statSync(at(`artifacts/w242-${phase}-${theme}.png`)).size > 1000);
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

test('K1 both engines exclude credential URLs before argv reaches fake MCP subprocess', () => {
  const root = testScratch('w242-url-');
  const childCode = "process.stdout.write(JSON.stringify({argv:process.argv.slice(1),started:true}))";
  const fixtureHost = 'fixture.invalid', userInfo = 'u:p', user = 'u', fakeKey = ['sk', 'W242_FAKE'].join('-');
  const urls = [`https://${userInfo}@${fixtureHost}/mcp`, `https://${user}@${fixtureHost}/mcp`, `https://${userInfo}%3Fa@${fixtureHost}/mcp`, 'https://fixture.invalid/mcp?token=W242_FAKE', 'https://fixture.invalid/api_key/W242_FAKE', `https://fixture.invalid/mcp?x=${fakeKey}`, 'https://fixture.invalid/mcp?%74oken=W242_FAKE'];
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
});

async function engineProof() {
  const root = testScratch('w242-engine-'), at = name => path.join(root, name);
  for (const dir of ['home', 'codex']) fs.mkdirSync(at(dir));
  const receipt = at('calls.jsonl'), startup = at('startup.json');
  const childFile = at('fake-mcp.cjs');
  fs.writeFileSync(childFile, `const fs=require('node:fs'),rl=require('node:readline');
fs.writeFileSync(process.env.STARTUP,JSON.stringify({argv:process.argv.slice(2),envReached:process.env.FAKE_ENV==='W242_ENV'}));
rl.createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;
let result={};if(m.method==='initialize')result={protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}};
if(m.method==='tools/list')result={tools:['read','write','extra'].map(name=>({name,description:name,inputSchema:{type:'object',properties:{}}}))};
if(m.method==='tools/call'){fs.appendFileSync(process.env.RECEIPT,JSON.stringify(m.params)+'\\n');result={content:[{type:'text',text:'fixture result'}]};}
process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');});`);
  let headersReached = false;
  const httpMCP = http.createServer((req, res) => {
    let body = ''; req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      headersReached ||= req.headers['x-inherited'] === 'W242_HEADER' && req.headers['x-inline'] === 'W242_INLINE';
      if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
      const m = JSON.parse(body);
      if (m.id === undefined) { res.writeHead(202); res.end(); return; }
      const result = m.method === 'initialize' ? { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' } } : { tools: [] };
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ jsonrpc: '2.0', id: m.id, result }));
    });
  });
  await new Promise(resolve => httpMCP.listen(0, '127.0.0.1', resolve));
  const secretURL = 'https://fixture.invalid/mcp?token=W242_URL_FAKE';
  const config = { engine: 'codex', enabled: ['fields', 'remote', 'blocked'], configured: [], servers: {
    fields: { command: process.execPath, args: [childFile], env: { RECEIPT: receipt, STARTUP: startup, FAKE_ENV: 'W242_ENV' }, enabled_tools: ['read', 'write'], disabled_tools: ['write'] },
    remote: { url: `http://127.0.0.1:${httpMCP.address().port}/mcp`, env_http_headers: { 'X-Inherited': 'HEADER_ENV' }, headers: { 'X-Inline': 'W242_INLINE' } },
    blocked: { command: process.execPath, args: [childFile, '--url=' + secretURL] },
  } };
  const source = fs.readFileSync('Engines/codex-sidecar/sidecar.mjs', 'utf8');
  const forwarded = vm.runInNewContext(source.slice(source.indexOf('const disabledMCPNames ='), source.indexOf('// OS 上游宣告：')) + '\n({args:[...githubMCPArgs,...disabledMCPArgs,...approveMCPArgs],env:githubMCPEnvironment})', {
    mcpConfig: config, permissionMode: 'acceptEdits', isolatedHasServer: () => false, configuredMCPNamesFromToml: () => [],
  });
  assert.ok(!JSON.stringify(forwarded.args).includes(secretURL));
  assert.ok(!forwarded.args.some(a => a === 'mcp_servers.blocked.default_tools_approval_mode="approve"'));
  assert.ok(forwarded.args.includes('mcp_servers.fields.default_tools_approval_mode="approve"'));
  const cliPath = (process.env.PATH ?? '').split(path.delimiter).map(dir => path.join(dir, 'codex')).find(file => fs.existsSync(file));
  assert.ok(cliPath, 'local Codex CLI is required for actual tool filtering proof');
  const cli = fs.realpathSync(cliPath);
  const profile = '(version 1)(allow default)(deny network*)(allow network-inbound (local ip "localhost:*"))(allow network-outbound (remote ip "localhost:*"))(deny mach-lookup (global-name-prefix "com.apple.securityd"))';
  const env = { HOME: at('home'), CFFIXED_USER_HOME: at('home'), CODEX_HOME: at('codex'), PATH: process.env.PATH, HEADER_ENV: 'W242_HEADER', ...forwarded.env };
  const child = spawn('/usr/bin/sandbox-exec', ['-p', profile, cli, ...forwarded.args, ...['tatwo2_browser', 'tatwo2_os'].flatMap(name => ['-c', `mcp_servers.${name}.command="/usr/bin/false"`, '-c', `mcp_servers.${name}.enabled=false`]), '-c', 'features.plugins=false', '-c', 'features.plugin_sharing=false', '-c', 'model_provider="fixture"', '-c', 'model_providers.fixture.name="fixture"', '-c', 'model_providers.fixture.base_url="http://127.0.0.1:1/v1"', 'app-server'], { cwd: root, env, stdio: ['pipe', 'pipe', 'pipe'] });
  let nextID = 1, buffer = '', stderr = ''; const pending = new Map();
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdout.on('data', chunk => {
    buffer += chunk;
    for (;;) {
      const end = buffer.indexOf('\n'); if (end < 0) break;
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      let m; try { m = JSON.parse(line); } catch { continue; }
      if (pending.has(m.id)) { const { resolve, reject } = pending.get(m.id); pending.delete(m.id); m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result); }
      else if (m.id !== undefined && m.method) child.stdin.write(JSON.stringify({ id: m.id, result: { action: 'decline' } }) + '\n');
    }
  });
  function rpc(method, params) {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timeout: ${stderr}`)); }, 20_000);
      pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }
  child.on('exit', status => { for (const request of pending.values()) request.reject(new Error(`app-server exit=${status}: ${stderr}`)); pending.clear(); });
  try {
    await rpc('initialize', { clientInfo: { name: 'fixture', version: '1' }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ method: 'initialized', params: {} }) + '\n');
    const thread = await rpc('thread/start', { cwd: root, approvalPolicy: 'on-request', sandbox: 'danger-full-access', model: 'fixture', modelProvider: 'fixture', ephemeral: true });
    const threadId = thread.thread.id;
    const inventory = await rpc('mcpServerStatus/list', { threadId });
    const fields = inventory.data.find(server => server.name === 'fields');
    assert.ok(fields, JSON.stringify(inventory));
    assert.deepEqual(Object.keys(fields.tools).map(key => fields.tools[key].name).sort(), ['read']);
    const blocked = inventory.data.find(server => server.name === 'blocked');
    assert.equal(blocked.runtimeStatus, 'disabled');
    assert.deepEqual(blocked.tools, {});
    const allowed = await rpc('mcpServer/tool/call', { threadId, server: 'fields', tool: 'read', arguments: {} });
    assert.ok(!allowed.isError, JSON.stringify(allowed));
    for (const tool of ['write', 'extra']) await assert.rejects(rpc('mcpServer/tool/call', { threadId, server: 'fields', tool, arguments: {} }), /disabled|not found|not allowed|not enabled|Unknown|unknown/i);
    assert.deepEqual(fs.readFileSync(receipt, 'utf8').trim().split('\n').map(line => JSON.parse(line).name), ['read']);
    assert.deepEqual(JSON.parse(fs.readFileSync(startup, 'utf8')), { argv: [], envReached: true });
    assert.equal(headersReached, true, 'actual Codex HTTP MCP receives inherited header mapping and aliased raw header');
    const evidence = { secretURLInArgv: false, enabledTools: ['read'], deniedTools: ['write', 'extra'], autoApprovalDidNotBypass: true, headersReached: true };
    fs.writeFileSync(at('evidence.json'), JSON.stringify(evidence, null, 2));
    console.log('W242 ENGINE PASS ' + JSON.stringify(evidence));
  } finally {
    child.stdin.end(); child.kill('SIGTERM');
    httpMCP.closeAllConnections(); await new Promise(resolve => httpMCP.close(resolve));
  }
}
