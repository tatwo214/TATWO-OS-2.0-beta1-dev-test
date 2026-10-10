// W183 R2／R2b：ChatGPT 手腳對外關口的驗收（威脅模型 T1、T2、T3、T8、T10、T11、T13、T14、T15；接口約定 v2 §1–§3、§5、§10，v3 V8、V12、V15–V18）。
// 在暫存資料夾起真的關口（gateway.mjs，沒有 supervisor；unix socket）＋假的 os.sock（扮演 App 的 hands_auth／hands_tools／hands_call，
// 回應形狀照 Engines/chatgpt-hands/fixtures/wire.json），走完整 OAuth 與 MCP；關口與 cloudflared 的 Seatbelt 用 sandbox-exec 實跑。
// 網域一律用 example.com，秘密一律用假值（canary）。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  parseCidr, parseIp, ipAllowed, rateKey, normalizeHost, readGatewayConfig, configVerdict, createGateway, serveGateway, logEntry,
  escapeHTML, LIMITS, PAIRING_CODE, RateWindow, headerProblem, osSocketCall, socketIdentity, TAMPER_EXIT_CODE,
} from '../Engines/chatgpt-hands/gateway.mjs';

const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');
const WIRE = JSON.parse(read('Engines/chatgpt-hands/fixtures/wire.json'));
const HOST = 'hands.example.com';
const OPENAI_IP = '203.0.113.10';          // 文件用網段，當成「OpenAI 公布的」
const OTHER_IP = '198.51.100.7';
// 授權頁是「使用者自己的瀏覽器」打開的（家裡或手機的 IP），不在 OpenAI 清單裡：測試裡的瀏覽器一律用這個。
const BROWSER_IP = '198.51.100.20';
const REDIRECT = 'https://chat.example.com/connector/oauth/callback';
const CANARY = {
  code: 'K7QM2XZ9',   // v3 V17：8 碼、字元集 23456789ABCDEFGHJKLMNPQRSTUVWXYZ
  access: 'at_CANARY_' + 'A'.repeat(40),
  refresh: 'rt_CANARY_' + 'B'.repeat(40),
  authCode: 'ac_CANARY_' + 'C'.repeat(40),
};
const keys = object => Object.keys(object).sort();

function shortRoot(prefix) {
  // UNIX socket 路徑有 104 位元組上限：放 /tmp（真實路徑 /private/tmp）。
  const parent = fs.existsSync('/tmp') ? '/tmp' : fs.realpathSync(process.env.TMPDIR || '/tmp');
  return fs.realpathSync(fs.mkdtempSync(path.join(parent, prefix)));
}

/// 照 App 的版面（接口約定 v2 §10）：<root>/gateway/config.json、<root>/gateway/sock/gw.sock（socket 資料夾由 App 預建 0700）。
function handsLayout(root) {
  const gatewayDir = path.join(root, 'gateway');
  const socketDir = path.join(gatewayDir, 'sock');
  fs.mkdirSync(socketDir, { recursive: true, mode: 0o700 });
  return { root, gatewayDir, socketDir, configFile: path.join(gatewayDir, 'config.json'), socketPath: path.join(socketDir, 'gw.sock') };
}

function writeConfig(layout, overrides = {}) {
  const doc = {
    socket_path: layout.socketPath, public_host: HOST,
    allowed_ip_ranges: ['203.0.113.0/24', '2001:db8::/32'], ranges_fetched_at: new Date().toISOString(), ...overrides,
  };
  fs.writeFileSync(layout.configFile, JSON.stringify(doc), { mode: 0o600 });
}

/// 假 App：只實作 hands_* 三個方法；成功回 `{id, result}`、失敗回 `{id, error: {code, message, …}}`（fixtures/wire.json）。
/// 參數多一個欄位就拒絕（跟 R1 一樣嚴），每筆請求都記下來供檢查。
function fakeApp(socketPath) {
  const requests = [];
  const allowedKeys = {
    register_client: keys(WIRE.hands_auth.register_client.params), authorize_begin: keys(WIRE.hands_auth.authorize_begin.params),
    authorize_submit: keys(WIRE.hands_auth.authorize_submit.params), check: keys(WIRE.hands_auth.check.params),
    token_authorization_code: keys(WIRE.hands_auth.token.params_authorization_code), token_refresh_token: keys(WIRE.hands_auth.token.params_refresh_token),
  };
  const state = { window: true, clients: new Map(), pending: null, codes: new Map(), access: new Map(), refresh: new Map(), usedRefresh: new Set(), serial: 0, bindings: [] };
  const fail = (code, message, extra = {}) => ({ error: { code, message, ...extra } });
  const issue = (clientID, grantID) => {
    state.serial += 1;
    const access = state.serial === 1 ? CANARY.access : `at_${randomBytes(24).toString('hex')}`;
    const refresh = state.serial === 1 ? CANARY.refresh : `rt_${randomBytes(24).toString('hex')}`;
    state.access.set(access, { clientID, grantID });
    state.refresh.set(refresh, { clientID, grantID });
    return { access_token: access, token_type: 'Bearer', expires_in: 3600, refresh_token: refresh, scope: 'tatwo.hands' };
  };
  const revokeGrant = grantID => {
    for (const [token, info] of state.access) if (info.grantID === grantID) state.access.delete(token);
    for (const [token, info] of state.refresh) if (info.grantID === grantID) state.refresh.delete(token);
  };
  const handlers = {
    hands_auth(p) {
      const shape = p.op === 'token' ? `token_${p.grant_type}` : p.op;
      if (!allowedKeys[shape] || keys(p).join() !== allowedKeys[shape].join()) return fail('invalid_request', 'unexpected fields');
      switch (p.op) {
        case 'register_client': {
          if (!p.redirect_uris.every(u => u === REDIRECT)) return fail('invalid_redirect_uri', 'redirect_uri not allowed');
          const id = `hc_${String(state.clients.size + 1).padStart(16, '0')}`;
          state.clients.set(id, p.redirect_uris);
          return { result: { client_id: id } };
        }
        case 'authorize_begin': {
          if (!state.window) return fail('pairing_window_closed', 'open pairing in TATWO first');
          if (p.code_challenge_method !== 'S256') return fail('invalid_request', 'S256 required');
          if (!state.clients.get(p.client_id)?.includes(p.redirect_uri)) return fail('invalid_request', 'unknown client');
          if (state.pending && !state.pending.closed) return fail('pairing_busy', 'another pairing is pending');
          const display = randomBytes(2).toString('hex').toUpperCase();
          state.pending = { ...p, id: `tx_${display}`, display, attempts: 5, closed: false };
          return { result: { transaction_id: state.pending.id, display_code: display, expires_at: new Date(Date.now() + 600_000).toISOString() } };
        }
        case 'authorize_submit': {
          const pairing = state.pending;
          if (!pairing || pairing.closed || pairing.id !== p.transaction_id) return fail('pairing_expired', 'start pairing again');
          state.bindings.push(p.browser_binding_hash);
          if (p.pairing_code !== CANARY.code) {
            pairing.attempts -= 1;
            if (pairing.attempts <= 0) { pairing.closed = true; return fail('pairing_expired', 'start pairing again'); }
            return fail('invalid_pairing_code', 'wrong code', { attempts_left: pairing.attempts });
          }
          pairing.closed = true;
          state.codes.set(CANARY.authCode, { ...pairing, grantID: `g_${state.serial + 1}` });
          return { result: { authorization_code: CANARY.authCode, redirect_uri: pairing.redirect_uri, state: pairing.state } };
        }
        case 'token': {
          if (p.grant_type === 'authorization_code') {
            const pairing = state.codes.get(p.code);
            state.codes.delete(p.code);
            const challenge = createHash('sha256').update(p.code_verifier ?? '').digest('base64url');
            if (!pairing || pairing.code_challenge !== challenge || pairing.client_id !== p.client_id || pairing.redirect_uri !== p.redirect_uri) {
              return fail('invalid_grant', 'invalid grant');
            }
            return { result: issue(p.client_id, pairing.grantID) };
          }
          if (state.usedRefresh.has(p.refresh_token)) {
            const grant = [...state.refresh.values(), ...state.access.values()].find(info => info.clientID === p.client_id)?.grantID;
            if (grant) revokeGrant(grant);   // 舊的 refresh 被再用＝撤銷該 grant（v3 V15）
            return fail('invalid_grant', 'grant revoked');
          }
          const info = state.refresh.get(p.refresh_token);
          if (info?.clientID !== p.client_id) return fail('invalid_grant', 'invalid grant');
          state.refresh.delete(p.refresh_token);
          state.usedRefresh.add(p.refresh_token);
          return { result: issue(p.client_id, info.grantID) };
        }
        case 'check': {
          const info = state.access.get(p.access_token);
          return { result: info ? { ok: true, grant_id: info.grantID, client_id: info.clientID, level: 2 } : { ok: false } };
        }
        default: return fail('invalid_request', 'unknown op');
      }
    },
    hands_tools(p) {
      if (keys(p).join() !== keys(WIRE.hands_tools.params).join()) return fail('invalid_request', 'unexpected fields');
      if (!state.access.has(p.access_token)) return fail('unauthorized', 'unauthorized');
      return { result: { level: 2, tools: [
        { ...named('read_file'), description: 'Read', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } },
        { ...named('run_command'), description: 'Run', inputSchema: { type: 'object' }, annotations: { readOnlyHint: false, destructiveHint: true } },
      ] } };
    },
    hands_call(p) {
      if (keys(p).join() !== keys(WIRE.hands_call.params).join()) return fail('invalid_request', 'unexpected fields');
      if (!state.access.has(p.access_token)) return fail('unauthorized', 'unauthorized');
      if (p.name === 'boom') return fail('internal_failure', `internal failure at ${socketPath}: EACCES /Users/example/.ssh/id_ed25519 stack Error:`);
      if (p.name === 'conflict') return fail('request_id_conflict', 'request_id reused with different arguments');
      if (p.name === 'locked') return fail('tool_not_allowed', 'tool not allowed');
      if (p.name === 'busy') return { legacy: 'hands_busy' };
      if (p.name === 'revoke') { revokeGrant(state.access.get(p.access_token).grantID); return fail('unauthorized', 'unauthorized'); }
      if (p.name === 'leak') return { result: { content: [{ type: 'text', text: `path ${socketPath}` }], isError: false } };
      if (p.name === 'slow') return new Promise(resolve => setTimeout(() => resolve({ result: { content: [{ type: 'text', text: `slow ${p.access_token}` }], isError: false } }), 400));
      return { result: { content: [{ type: 'text', text: `ran ${p.name} ${JSON.stringify(p.arguments)}` }], isError: false } };
    },
  };
  // allowHalfOpen：關口送完就關寫端（SHUT_WR）；回覆可能要等（slow），不能讓 Node 自動把這一端也關掉。
  const server = net.createServer({ allowHalfOpen: true }, connection => {
    let buffer = '';
    connection.setEncoding('utf8');
    connection.on('data', chunk => { buffer += chunk; });
    connection.on('end', async () => {
      const request = JSON.parse(buffer.split('\n')[0]);
      requests.push(request);
      const outcome = await (handlers[request.method]?.(request.params) ?? { legacy: 'method_not_allowed' });
      // os.sock 自己的錯誤是舊格式 {ok:false, error:"字詞"}；App 的判斷照 fixtures {id, error:{code,message}}。
      const reply = outcome.legacy ? { id: request.id, ok: false, error: outcome.legacy }
        : outcome.error ? { id: request.id, error: outcome.error } : { id: request.id, result: outcome.result };
      connection.end(JSON.stringify(reply) + '\n');
    });
    connection.on('error', () => {});
  });
  return new Promise(resolve => server.listen(socketPath, () => resolve({ server, requests, state })));
}

function request(socketPath, { method = 'GET', url = '/', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const merged = Object.fromEntries(Object.entries({ host: HOST, 'cf-connecting-ip': OPENAI_IP, ...headers }).filter(([, v]) => v !== undefined));
    const req = http.request({ socketPath, method, path: url, headers: merged }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

async function startGateway({ limits, configOverrides, osCall, socketCheckMs } = {}) {
  const root = shortRoot('w183g-');
  const layout = handsLayout(path.join(root, 'h'));
  const osSocket = path.join(root, 'o.sock');
  const app = await fakeApp(osSocket);
  writeConfig(layout, configOverrides);
  const controller = new AbortController();
  const events = [];
  let ready;
  const readyPromise = new Promise(resolve => { ready = resolve; });
  const running = serveGateway({ configFile: layout.configFile, osSocket, signal: controller.signal, limits, osCall, healthMs: 200, socketCheckMs,
    onEvent: event => { events.push(event); if (event.ev === 'ready') ready(); } });
  running.catch(() => ready());
  await readyPromise;
  const socketPath = layout.socketPath;
  return {
    root, layout, osSocket, socketPath, app, events, running,
    get: (url, headers) => request(socketPath, { url, headers }),
    post: (url, body, headers = {}) => request(socketPath, { method: 'POST', url, body, headers: { 'content-length': Buffer.byteLength(body), ...headers } }),
    async stop() { controller.abort(); await running.catch(() => {}); app.server.close(); fs.rmSync(root, { recursive: true, force: true }); },
  };
}

const form = values => new URLSearchParams(values).toString();
const named = value => ({ name: value });
const toolCall = (id, tool, args = {}) => ({ jsonrpc: '2.0', id, method: 'tools/call', params: { ...named(tool), arguments: args } });
const formHeaders = { 'content-type': 'application/x-www-form-urlencoded' };
const jsonHeaders = { 'content-type': 'application/json' };
const origin = `https://${HOST}`;
const waitConfig = () => new Promise(resolve => setTimeout(resolve, 2200));   // 關口最多 2 秒重讀一次 config.json

function authorizeQuery(clientID, challenge, extra = {}) {
  return new URLSearchParams({ response_type: 'code', client_id: clientID, redirect_uri: REDIRECT, code_challenge: challenge,
    code_challenge_method: 'S256', state: 'st-123', resource: `https://${HOST}/mcp`, scope: 'tatwo.hands', ...extra });
}

async function pair(gw, { verifier = randomBytes(40).toString('base64url') } = {}) {
  const registered = await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT], client_name: 'ChatGPT' }), jsonHeaders);
  assert.equal(registered.status, 201, registered.text);
  const clientID = JSON.parse(registered.text).client_id;
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  gw.app.state.pending = null;   // 假 App：上一筆已處理完
  const page = await gw.get(`/authorize?${authorizeQuery(clientID, challenge)}`, { 'cf-connecting-ip': BROWSER_IP });
  assert.equal(page.status, 200, page.text);
  const transactionID = /name="transaction_id" value="([^"]+)"/.exec(page.text)[1];
  const csrf = /name="csrf" value="([^"]+)"/.exec(page.text)[1];
  const cookie = page.headers['set-cookie'][0].split(';')[0];
  const submit = (values, headers = {}) => gw.post('/authorize', form({ transaction_id: transactionID, csrf, ...values }),
    { ...formHeaders, cookie, origin, 'cf-connecting-ip': BROWSER_IP, ...headers });
  return { clientID, verifier, challenge, page, transactionID, csrf, cookie, submit };
}

/// 配對、換 token、initialize（拿 MCP session）。rpc() 預設帶 session（v3 V12：tools/call 一定要有）；extra 可以蓋掉或設成 undefined 拿掉。
async function authed(gw) {
  const flow = await pair(gw);
  const done = await flow.submit({ code: CANARY.code });
  assert.equal(done.status, 302, done.text);
  const tokens = JSON.parse((await gw.post('/token', form({ grant_type: 'authorization_code', code: CANARY.authCode, code_verifier: flow.verifier, client_id: flow.clientID, redirect_uri: REDIRECT }), formHeaders)).text);
  const base = { ...jsonHeaders, authorization: `Bearer ${tokens.access_token}` };
  const init = await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 'init', method: 'initialize', params: {} }), base);
  assert.equal(init.status, 200, init.text);
  const session = init.headers['mcp-session-id'];
  const rpc = (message, extra = {}) => gw.post('/mcp', typeof message === 'string' ? message : JSON.stringify(message), { ...base, 'mcp-session-id': session, ...extra });
  return { tokens, rpc, flow, session };
}
const SESSION_SHAPE = /^s1-[0-9a-z]{1,11}-[0-9a-f]{32}-[0-9a-f]{32}$/;
const handsCalls = gw => gw.app.requests.filter(r => r.method === 'hands_call');

// ---------- 純函式 ----------
test('T1 網段：IPv4／IPv6／mapped 比對正確，太寬或亂寫的網段不收', () => {
  const ranges = ['203.0.113.0/24', '2001:db8::/32', '192.0.2.128/25'].map(item => parseCidr(item));
  assert.ok(ranges.every(Boolean));
  assert.equal(ipAllowed('203.0.113.1', ranges), true);
  assert.equal(ipAllowed('203.0.114.1', ranges), false);
  assert.equal(ipAllowed('192.0.2.200', ranges), true);
  assert.equal(ipAllowed('192.0.2.100', ranges), false);
  assert.equal(ipAllowed('::ffff:203.0.113.9', ranges), true);
  assert.equal(ipAllowed('2001:db8:1::5', ranges), true);
  assert.equal(ipAllowed('2001:db9::5', ranges), false);
  assert.equal(ipAllowed('203.0.113.1, 198.51.100.7', ranges), false, '重複的標頭（逗號串起來）看不懂＝拒絕');
  assert.equal(ipAllowed('fe80::1%en0', ranges), false);
  assert.equal(ipAllowed('', ranges), false);
  assert.equal(ipAllowed('203.0.113.1', []), false);
  for (const bad of ['0.0.0.0/0', '11.0.0.0/8', '::/0', '2000::/16', '203.0.113.0', '203.0.113.0/33', '203.0.113.256/24', '1.2.3.4/24/1', 'x/24']) {
    assert.equal(parseCidr(bad), null, bad);
  }
  assert.deepEqual(parseIp('::ffff:1.2.3.4'), { family: 4, value: 0x01020304n });
  assert.equal(normalizeHost('Hands.Example.com:443'), HOST);
  assert.equal(normalizeHost('hands.example.com:8443'), null);
  assert.equal(normalizeHost('evil.example.com/x'), null);
});

test('v2 §2 IP 清單政策（關口讀檔）：沒有清單、空、有一筆不合法或太寬、過期 7 天、時間在未來＝全拒；捷徑不跟隨', () => {
  const root = shortRoot('w183c-');
  try {
    const file = path.join(root, 'config.json');
    const write = doc => fs.writeFileSync(file, JSON.stringify({ public_host: HOST, ranges_fetched_at: new Date().toISOString(), ...doc }));
    assert.equal(configVerdict(readGatewayConfig(file)), 'config_missing');
    write({ allowed_ip_ranges: [] });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_missing', '沒有可信清單');
    write({ allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: undefined });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_missing', '沒有抓到的時間');
    write({ allowed_ip_ranges: ['203.0.113.0/24', 'nonsense'] });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_invalid', '有一筆壞掉＝整份不用（不挑著用）');
    write({ allowed_ip_ranges: ['203.0.113.0/24', '0.0.0.0/0'] });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_invalid', '太寬的網段＝清單被竄改');
    write({ allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date(Date.now() - 8 * 86400_000).toISOString() });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_stale', '超過 7 天');
    write({ allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date(Date.now() + 2 * 3600_000).toISOString() });
    assert.equal(configVerdict(readGatewayConfig(file)), 'ranges_stale', '時間在未來');
    fs.writeFileSync(file, JSON.stringify({ allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }));
    assert.equal(configVerdict(readGatewayConfig(file)), 'host_missing');
    fs.writeFileSync(file, '{not json');
    assert.equal(configVerdict(readGatewayConfig(file)), 'config_invalid');
    write({ allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date(Date.now() - 6 * 86400_000).toISOString() });
    assert.equal(configVerdict(readGatewayConfig(file)), null, '6 天前抓的（App 更新失敗不刷新時間）還能用');
    const link = path.join(root, 'link.json');
    fs.symlinkSync(file, link);
    assert.equal(readGatewayConfig(link).ok, false, '捷徑不跟隨');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('T10 日誌：關口只印固定欄位（logEntry），送什麼奇怪的值都不會進去', () => {
  assert.deepEqual(logEntry({ m: 'POST', r: 'mcp', s: 200, ms: 12, rpc: 'tools/call', token: CANARY.access }),
    { ev: 'req', m: 'POST', r: 'mcp', s: 200, ms: 12, rpc: 'tools/call' });
  const hostile = JSON.stringify(logEntry({ m: `GET ${CANARY.access}`, r: '/x?code=' + CANARY.code, s: 'x', ms: -1, rpc: CANARY.access }));
  assert.ok(!hostile.includes(CANARY.access) && !hostile.includes(CANARY.code), hostile);
  assert.equal(escapeHTML('<script>"x" & \'y\'</script>'), '&#60;script&#62;&#34;x&#34; &#38; &#39;y&#39;&#60;&#47;script&#62;');
  for (const good of ['K7QM2XZ9', '7K3M9QX2', '23456789', 'ABCDEFGH']) assert.match(good, PAIRING_CODE);
  for (const bad of ['K7QM2XZ0', 'K7QM2XZ1', 'K7QMIXZ9', 'K7QMOXZ9', 'k7qm2xz9', 'K7QM2XZ', 'K7QM2XZ99']) assert.doesNotMatch(bad, PAIRING_CODE);
});

// ---------- 實際起關口 ----------
test('v2 §2 端點矩陣：metadata／register／token／mcp 只收 OpenAI IP；瀏覽器 IP 只到得了 /authorize；方法不對 405；其他 404；沒有管理端點', async () => {
  const gw = await startGateway();
  try {
    const browser = { 'cf-connecting-ip': BROWSER_IP };
    const ok = await gw.get('/.well-known/oauth-protected-resource');
    assert.equal(ok.status, 200);
    assert.deepEqual(JSON.parse(ok.text).scopes_supported, ['tatwo.hands', 'sandbox']);
    assert.equal(JSON.parse(ok.text).resource, `https://${HOST}/mcp`);
    assert.equal((await gw.get('/.well-known/oauth-protected-resource/mcp')).status, 200);
    const asm = JSON.parse((await gw.get('/.well-known/oauth-authorization-server')).text);
    assert.deepEqual(asm.code_challenge_methods_supported, ['S256']);
    assert.deepEqual(asm.token_endpoint_auth_methods_supported, ['none']);
    // 從瀏覽器 IP：除了 /authorize，一律 403（本文照 fixtures 的 forbidden_source）。
    const probes = [
      ['GET', '/.well-known/oauth-protected-resource'], ['GET', '/.well-known/oauth-authorization-server'], ['GET', '/.well-known/openid-configuration'],
      ['POST', '/register', JSON.stringify({ redirect_uris: [REDIRECT] }), jsonHeaders],
      ['POST', '/token', form({ grant_type: 'refresh_token', refresh_token: 'r'.repeat(30), client_id: 'hc_1' }), formHeaders],
      ['POST', '/mcp', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }), jsonHeaders],
      ['GET', '/nope'], ['GET', '/authorize/../mcp'], ['GET', '/admin'],
    ];
    for (const [method, url, body, headers] of probes) {
      const res = method === 'GET' ? await gw.get(url, browser) : await gw.post(url, body, { ...headers, ...browser });
      assert.equal(res.status, WIRE.http_mapping.forbidden_source.status, `${method} ${url}`);
      assert.equal(res.text, WIRE.http_mapping.forbidden_source.body);
    }
    const page = await gw.get(`/authorize?${authorizeQuery('hc_1', 'a'.repeat(43))}`, browser);
    assert.notEqual(page.status, 403, '授權頁不看 OpenAI 清單（使用者的瀏覽器）');
    // 沒帶來源 IP、看不懂、Host 不符：包括 /authorize 一律 403（v3 V18）。
    for (const url of ['/.well-known/oauth-protected-resource', `/authorize?${authorizeQuery('hc_1', 'a'.repeat(43))}`]) {
      assert.equal((await request(gw.socketPath, { url, headers: { 'cf-connecting-ip': undefined } })).status, 403, `${url} 沒有來源 IP`);
      assert.equal((await gw.get(url, { 'cf-connecting-ip': 'not-an-ip' })).status, 403, `${url} 來源 IP 看不懂`);
      assert.equal((await gw.get(url, { 'cf-connecting-ip': `${BROWSER_IP}, ${OPENAI_IP}` })).status, 403, `${url} 兩個來源 IP`);
      assert.equal((await gw.get(url, { ...browser, host: 'evil.example.com' })).status, 403, `${url} Host 不符`);
    }
    assert.equal((await gw.get('/.well-known/oauth-protected-resource', { 'cf-connecting-ip': '::ffff:203.0.113.10' })).status, 200);
    // 方法矩陣。
    assert.equal((await gw.post('/.well-known/oauth-protected-resource', '{}', jsonHeaders)).status, 405);
    assert.equal((await gw.get('/register')).status, 405);
    assert.equal((await gw.get('/token')).status, 405);
    const getMcp = await gw.get('/mcp');
    assert.equal(getMcp.status, 405, 'GET /mcp 回 405（v2 §2）');
    assert.equal(getMcp.headers.allow, 'POST');
    assert.equal((await request(gw.socketPath, { method: 'DELETE', url: '/mcp' })).status, 405);
    assert.equal((await request(gw.socketPath, { method: 'PUT', url: '/authorize', headers: browser })).status, 405);
    // 其他一律 404（本文照 fixtures 的 not_found），沒有任何管理端點。
    for (const probe of ['/admin', '/config', '/settings', '/debug', '/revoke', '/../gateway/config.json', '/healthz', '/metrics', '/mcp/../admin', '/register/x']) {
      const res = await gw.get(probe);
      assert.equal(res.status, WIRE.http_mapping.not_found.status, `${probe} ${res.status}`);
      assert.equal(res.text, WIRE.http_mapping.not_found.body);
    }
  } finally { await gw.stop(); }
});

test('v2 §2 IP 清單四種失效（關口實跑）：沒有可信清單、清單有一筆壞掉、過期 7 天、時間在未來 → 全部端點（含 /authorize）403；換回好清單就恢復', async () => {
  const gw = await startGateway();
  try {
    const probe = async () => [
      (await gw.get('/.well-known/oauth-authorization-server')).status,
      (await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT] }), jsonHeaders)).status,
      (await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: 'r'.repeat(30), client_id: 'hc_1' }), formHeaders)).status,
      (await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }), jsonHeaders)).status,
      (await gw.get(`/authorize?${authorizeQuery('hc_1', 'a'.repeat(43))}`, { 'cf-connecting-ip': BROWSER_IP })).status,
    ];
    const good = await probe();
    assert.ok(good.every(status => status !== 403), `好清單：${good}`);
    const cases = {
      沒有可信清單: { allowed_ip_ranges: [] },
      有一筆壞掉: { allowed_ip_ranges: ['203.0.113.0/24', '999.1.2.3/24'] },
      過期七天: { ranges_fetched_at: new Date(Date.now() - 7 * 86400_000 - 60_000).toISOString() },
      時間在未來: { ranges_fetched_at: new Date(Date.now() + 2 * 3600_000).toISOString() },
    };
    for (const [name, overrides] of Object.entries(cases)) {
      writeConfig(gw.layout, overrides);
      await waitConfig();
      assert.deepEqual(await probe(), [403, 403, 403, 403, 403], name);
    }
    fs.rmSync(gw.layout.configFile);
    await waitConfig();
    assert.deepEqual(await probe(), [403, 403, 403, 403, 403], '設定檔不見');
    writeConfig(gw.layout);
    await waitConfig();
    assert.ok((await probe()).every(status => status !== 403), '換回好清單就恢復（不用重開關口）');
    assert.ok(gw.events.some(event => event.ev === 'health' && event.config !== 'ok'), '健康檢查回報清單狀態');
  } finally { await gw.stop(); }
});

test('fixtures http_mapping：/mcp 沒 token 的 401 與 WWW-Authenticate 跟 fixture 一樣；錯 token 帶 invalid_token；OAuth 錯誤是 {error, error_description}', async () => {
  const gw = await startGateway();
  try {
    const bare = await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }), jsonHeaders);
    assert.equal(bare.status, WIRE.http_mapping.unauthorized_mcp.status);
    assert.equal(bare.headers['www-authenticate'], WIRE.http_mapping.unauthorized_mcp.www_authenticate.replace('hands.example.com', HOST));
    const wrong = await gw.post('/mcp', '{}', { ...jsonHeaders, authorization: 'Bearer ' + 'x'.repeat(40) });
    assert.equal(wrong.status, 401);
    assert.match(wrong.headers['www-authenticate'], /^Bearer error="invalid_token", resource_metadata="https:\/\/hands\.example\.com\/\.well-known\/oauth-protected-resource"$/);
    const badGrant = await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: 'r'.repeat(30), client_id: 'hc_1' }), formHeaders);
    assert.equal(badGrant.status, 400);
    assert.deepEqual(keys(JSON.parse(badGrant.text)), keys(WIRE.http_mapping.oauth_error_body));
    assert.deepEqual(JSON.parse(badGrant.text), WIRE.http_mapping.oauth_error_body);
    const badRedirect = await gw.post('/register', JSON.stringify({ redirect_uris: ['https://evil.example.com/cb'] }), jsonHeaders);
    assert.equal(badRedirect.status, 400);
    assert.deepEqual(JSON.parse(badRedirect.text), { error: 'invalid_redirect_uri', error_description: 'redirect_uri not allowed' }, 'App 說 redirect 不在 callback 清單');
    assert.equal((await gw.post('/token', form({ grant_type: 'password', client_id: 'hc_1' }), formHeaders)).text, JSON.stringify({ error: 'unsupported_grant_type', error_description: 'unsupported grant type' }));
  } finally { await gw.stop(); }
});

test('v2 §3／v3 V15 完整配對：註冊 → 授權頁顯示交易編號與回呼網域、文案「授權這筆連線」 → 錯碼 → 對碼 → 302 回 callback → token → refresh 輪替、重用即撤銷該 grant', async () => {
  const gw = await startGateway();
  try {
    const httpRedirect = await gw.post('/register', JSON.stringify({ redirect_uris: ['http://chat.example.com/cb'] }), jsonHeaders);
    assert.equal(httpRedirect.status, 400);
    const withUserinfo = 'https://u:p' + '@chat.example.com/cb';
    assert.equal((await gw.post('/register', JSON.stringify({ redirect_uris: [withUserinfo] }), jsonHeaders)).status, 400);
    assert.equal((await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT], token_endpoint_auth_method: 'client_secret_basic' }), jsonHeaders)).status, 400, '只收 public client');

    const flow = await pair(gw);
    const display = gw.app.state.pending.display;
    assert.match(flow.page.text, /<h1>授權這筆連線<\/h1>/);
    assert.ok(flow.page.text.includes(`交易編號 <strong>${display}</strong>`), '網頁顯示 App 給的同一組交易編號');
    assert.ok(flow.page.text.includes('chat.example.com'), '顯示回呼網域');
    assert.doesNotMatch(flow.page.text, /已驗證/, '不宣稱驗證了 ChatGPT 帳號');
    assert.ok(!flow.page.text.includes(CANARY.code), '配對碼不經關口');
    assert.ok(!flow.page.text.includes('<script'), '授權頁沒有腳本');
    const begin = gw.app.requests.filter(r => r.params.op === 'authorize_begin').at(-1).params;
    assert.deepEqual(begin, { op: 'authorize_begin', client_id: flow.clientID, redirect_uri: REDIRECT, code_challenge: flow.challenge,
      code_challenge_method: 'S256', state: 'st-123', resource: `https://${HOST}/mcp`, scope: 'tatwo.hands' });

    const wrong = await flow.submit({ code: '22222222' });
    assert.equal(wrong.status, 400);
    assert.match(wrong.text, /還可以再試 4 次/);
    const done = await flow.submit({ code: CANARY.code });
    assert.equal(done.status, 302, done.text);
    const location = new URL(done.headers.location);
    assert.equal(`${location.origin}${location.pathname}`, REDIRECT);
    assert.equal(location.searchParams.get('state'), 'st-123');
    assert.equal(location.searchParams.get('iss'), `https://${HOST}`);
    assert.equal(location.searchParams.get('code'), CANARY.authCode);
    assert.equal(done.headers['referrer-policy'], 'no-referrer', '轉回 ChatGPT 不帶 referrer');
    assert.match(done.headers['set-cookie'][0], /Max-Age=0/, '防偽 cookie 用完就清');
    const submit = gw.app.requests.filter(r => r.params.op === 'authorize_submit').at(-1).params;
    assert.equal(submit.transaction_id, flow.transactionID);
    assert.equal(submit.browser_binding_hash, `sha256:${createHash('sha256').update(flow.csrf).digest('hex')}`, '帶瀏覽器防偽 token 的雜湊，不帶原文');
    assert.ok(gw.app.requests.every(r => !JSON.stringify(r.params).includes(flow.csrf)), '防偽 token 原文不送給 App');
    assert.equal((await flow.submit({ code: CANARY.code })).status, 400, '一次性');

    const badVerifier = await gw.post('/token', form({ grant_type: 'authorization_code', code: CANARY.authCode, code_verifier: 'z'.repeat(43), client_id: flow.clientID, redirect_uri: REDIRECT }), formHeaders);
    assert.equal(badVerifier.status, 400);
    assert.equal(JSON.parse(badVerifier.text).error, 'invalid_grant');
    // 同一個授權碼在上面被 App 作廢了：重新配對一次再換 token。
    const again = await pair(gw);
    assert.equal((await again.submit({ code: CANARY.code.toLowerCase() })).status, 302, '配對碼不分大小寫（關口轉成大寫）');
    assert.equal(gw.app.requests.filter(r => r.params.op === 'authorize_submit').at(-1).params.pairing_code, CANARY.code);
    const exchanged = await gw.post('/token', form({ grant_type: 'authorization_code', code: CANARY.authCode, code_verifier: again.verifier, client_id: again.clientID, redirect_uri: REDIRECT, resource: `https://${HOST}/mcp` }), formHeaders);
    assert.equal(exchanged.status, 200, exchanged.text);
    const tokens = JSON.parse(exchanged.text);
    assert.deepEqual(keys(tokens), keys(WIRE.hands_auth.token.result), 'token 回應欄位照 fixture');
    assert.equal(tokens.token_type, 'Bearer');
    assert.equal(tokens.expires_in, 3600);
    assert.equal(exchanged.headers['cache-control'], 'no-store');
    const rotated = JSON.parse((await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: again.clientID }), formHeaders)).text);
    assert.notEqual(rotated.refresh_token, tokens.refresh_token);
    const reuse = await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: again.clientID }), formHeaders);
    assert.equal(reuse.status, 400);
    assert.deepEqual(JSON.parse(reuse.text), { error: 'invalid_grant', error_description: 'invalid grant' }, '不轉 App 的細節（grant revoked）');
    const afterReuse = await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }), { ...jsonHeaders, authorization: `Bearer ${rotated.access_token}` });
    assert.equal(afterReuse.status, 401, '重用舊 refresh 後該 grant 的 token 全部作廢');
    assert.ok(gw.app.requests.every(r => !('callerThreadID' in r.params)), '不帶對話 id');
    assert.ok(gw.app.requests.every(r => ['hands_auth', 'hands_tools', 'hands_call'].includes(r.method)), '只叫三個方法');
  } finally { await gw.stop(); }
});

test('v2 §3／T15 配對窗口：瀏覽器（非 OpenAI IP）打得到 /authorize，但 App 沒開窗口就請使用者先在 TATWO 按開始配對；已有一筆待配對也不開', async () => {
  const gw = await startGateway();
  try {
    const registered = JSON.parse((await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT] }), jsonHeaders)).text);
    gw.app.state.window = false;
    const closed = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'a'.repeat(43))}`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal(closed.status, 403);
    // W183 R12（.034 實機：晚一步點＝冷冰冰的 403）：白話講清楚過期了、回 TATWO 按［再連一次］（沒有「開始配對」這顆鈕了）。
    assert.match(closed.text, /這個連線請求已經過期/);
    assert.match(closed.text, /回 TATWO 按［再連一次］/);
    assert.doesNotMatch(closed.text, /<form/, '沒有窗口就沒有表單');
    assert.equal(closed.headers['set-cookie'], undefined, '沒有窗口就不發防偽 cookie');
    assert.ok(gw.app.requests.some(r => r.params.op === 'authorize_begin'), '窗口由 App 判斷（關口不自己開）');
    gw.app.state.window = true;
    const opened = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'a'.repeat(43))}`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal(opened.status, 200);
    const busy = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'b'.repeat(43))}`, { 'cf-connecting-ip': '198.51.100.21' });
    assert.equal(busy.status, 409);
    assert.match(busy.text, /已經有一筆配對在等確認/);
    // 窗口在送出前關了（App 說窗口過期）：失效、不轉址。
    const transactionID = /name="transaction_id" value="([^"]+)"/.exec(opened.text)[1];
    const csrf = /name="csrf" value="([^"]+)"/.exec(opened.text)[1];
    const cookie = opened.headers['set-cookie'][0].split(';')[0];
    gw.app.state.pending.closed = true;
    const late = await gw.post('/authorize', form({ transaction_id: transactionID, csrf, code: CANARY.code }), { ...formHeaders, cookie, origin, 'cf-connecting-ip': BROWSER_IP });
    assert.equal(late.status, 400);
    assert.ok(!late.headers.location);
    assert.match(late.text, /已失效/);
  } finally { await gw.stop(); }
});

test('v2 §2 CSRF：缺 cookie、cookie 不符、錯 Origin、沒有 Origin、Origin: null 沒標同源、Sec-Fetch-Site 跨站、表單 token 不符都拒；這些都沒送到 App', async () => {
  const gw = await startGateway();
  try {
    const flow = await pair(gw);
    const reject = async (values, headers, why) => {
      const res = await flow.submit({ code: CANARY.code, ...values }, headers);
      assert.equal(res.status, 403, why);
      assert.ok(!res.headers.location, why);
    };
    await reject({}, { cookie: '' }, '缺 cookie');
    await reject({}, { cookie: `${flow.cookie.split('=')[0]}=${'x'.repeat(43)}` }, 'cookie 不符');
    await reject({ csrf: 'forged' }, {}, '表單 token 不符');
    await reject({}, { origin: 'https://evil.example.com' }, '錯 Origin');
    await reject({}, { origin: undefined }, '沒有 Origin');
    await reject({}, { origin: 'null' }, 'Origin: null 但瀏覽器沒標同源');
    await reject({}, { origin: 'null', 'sec-fetch-site': 'cross-site' }, 'Origin: null＋跨站');
    await reject({}, { 'sec-fetch-site': 'same-site' }, '同站不同源');
    await reject({}, { origin: 'null', 'sec-fetch-site': 'same-origin', cookie: '' }, 'Origin: null 也照樣要 cookie');
    assert.ok(!gw.app.requests.some(r => r.params.op === 'authorize_submit'), '上面這些都沒送到 App（不浪費嘗試次數）');
    // 頁面是 no-referrer：瀏覽器送同源表單時 Origin 是 null，Sec-Fetch-Site 標 same-origin——這個要收。
    const ok = await flow.submit({ code: CANARY.code }, { origin: 'null', 'sec-fetch-site': 'same-origin' });
    assert.equal(ok.status, 302, ok.text);
  } finally { await gw.stop(); }
});

test('授權頁的安全標頭與跳脫：CSP default-src none／form-action self（＋callback 來源）／frame-ancestors none、no-store、no-referrer、SameSite=Strict；參數不回顯', async () => {
  const gw = await startGateway();
  try {
    const registered = JSON.parse((await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT] }), jsonHeaders)).text);
    const evil = '"><script>alert(1)</script>';
    const page = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'a'.repeat(43), { state: evil })}`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal(page.status, 200);
    const csp = page.headers['content-security-policy'];
    assert.match(csp, /(^|; )default-src 'none'(;|$)/);
    assert.match(csp, /(^|; )form-action 'self' https:\/\/chat\.example\.com(;|$)/, "form-action 'self'，再加上 302 的目的地（Chrome 會檢查轉址）");
    assert.match(csp, /(^|; )frame-ancestors 'none'(;|$)/);
    assert.doesNotMatch(csp, /script-src|unsafe-inline/);
    assert.equal(page.headers['cache-control'], 'no-store');
    assert.equal(page.headers['referrer-policy'], 'no-referrer');
    assert.equal(page.headers['x-frame-options'], 'DENY');
    assert.equal(page.headers['x-content-type-options'], 'nosniff');
    assert.match(page.headers['set-cookie'][0], /^__Host-tatwo-tx-[0-9a-f]{12}=[A-Za-z0-9_-]{43}; Path=\/; Secure; HttpOnly; SameSite=Strict; Max-Age=\d+$/);
    assert.ok(!page.text.includes('<script>') && !page.text.includes(evil) && !page.text.includes('alert(1)'), 'state 等參數不回顯');
    // 缺參數、plain PKCE、別的 scope、別的 resource：400，不開配對、不轉址。
    for (const extra of [{ code_challenge_method: 'plain' }, { state: '' }, { scope: 'admin' }, { resource: 'https://evil.example.com/mcp' }, { response_type: 'token' }]) {
      const res = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'a'.repeat(43), extra)}`, { 'cf-connecting-ip': BROWSER_IP });
      assert.equal(res.status, 400, JSON.stringify(extra));
      assert.ok(!res.headers.location);
    }
    const dup = await gw.get(`/authorize?${authorizeQuery(registered.client_id, 'a'.repeat(43))}&state=again`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal(dup.status, 400, '重複參數不收');
  } finally { await gw.stop(); }
});

test('v3 V17 配對碼：8 碼、23456789ABCDEFGHJKLMNPQRSTUVWXYZ、不分大小寫；格式不對直接擋（不送 App、不浪費次數）', async () => {
  const gw = await startGateway();
  try {
    const flow = await pair(gw);
    for (const bad of ['1234567', '123456789', '<script>', 'ABCD EFG!', 'K7QM2XZ0', 'K7QM2XZ1', 'K7QMIXZ9', 'K7QMOXZ9']) {
      const res = await flow.submit({ code: bad });
      assert.equal(res.status, 400, bad);
      assert.match(res.text, /8 位配對碼/);
    }
    assert.ok(!gw.app.requests.some(r => r.params.op === 'authorize_submit'), '格式不對的都沒送到 App');
    const done = await flow.submit({ code: ' k7qm-2xz9 ' });
    assert.equal(done.status, 302, '去掉空白與連字號、轉大寫');
    assert.equal(gw.app.requests.filter(r => r.params.op === 'authorize_submit').at(-1).params.pairing_code, CANARY.code);
  } finally { await gw.stop(); }
});

test('T2 錯碼用完就作廢（App 說 pairing_expired）', async () => {
  const gw = await startGateway();
  try {
    const flow = await pair(gw);
    let last;
    for (let i = 0; i < 5; i += 1) last = await flow.submit({ code: `2222222${'ABCDE'[i]}` });
    assert.match(last.text, /已失效/);
    const after = await flow.submit({ code: CANARY.code });
    assert.equal(after.status, 400);
    assert.ok(!after.headers.location);
  } finally { await gw.stop(); }
});

test('v3 V18 配對次數：每個來源各自有額度（IPv6 以 /64 算）、全關口另有上限', async () => {
  const gw = await startGateway({ limits: { pairingPerIpPerWindow: 2, pairingPerWindow: 6 } });
  try {
    gw.app.state.window = false;   // 只看關口的次數上限（App 端回什麼不影響）
    const query = authorizeQuery('hc_1', 'a'.repeat(43));
    const open = async ip => (await gw.get(`/authorize?${query}`, { 'cf-connecting-ip': ip })).status;
    assert.deepEqual([await open('198.51.100.30'), await open('198.51.100.30'), await open('198.51.100.30')], [403, 403, 429]);
    assert.equal(await open('198.51.100.31'), 403, '別的來源不受影響');
    assert.deepEqual([await open('2001:db8:5:6::1'), await open('2001:db8:5:6::2'), await open('2001:db8:5:6:ffff::9')], [403, 403, 429],
      '同一段 /64 算同一個來源');
    assert.equal(await open('2001:db8:5:7::1'), 403);
    assert.equal(await open('198.51.100.40'), 429, '全關口 10 分鐘上限（這裡設 6）到了：多個來源也打不滿更多');
    assert.equal(rateKey('2001:db8:5:6::1'), rateKey('2001:db8:5:6:abcd::1'));
    assert.notEqual(rateKey('2001:db8:5:6::1'), rateKey('2001:db8:5:7::1'));
    assert.equal(rateKey('::ffff:198.51.100.30'), rateKey('198.51.100.30'));
    assert.equal(rateKey('nope'), null);
  } finally { await gw.stop(); }
});

test('MCP：initialize（發 session）／tools/list／tools/call 轉給 App、ping、通知 202、批次不收、版本不對 400', async () => {
  const gw = await startGateway();
  try {
    const { tokens, rpc } = await authed(gw);
    const initRes = await rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { ...named('t'), version: '1' } } });
    const init = JSON.parse(initRes.text);
    assert.equal(init.result.protocolVersion, '2025-06-18');
    assert.deepEqual(init.result.capabilities, { tools: { listChanged: false } });
    assert.match(initRes.headers['mcp-session-id'], SESSION_SHAPE);
    assert.equal((await rpc({ jsonrpc: '2.0', method: 'notifications/initialized' })).status, 202);
    const list = JSON.parse((await rpc({ jsonrpc: '2.0', id: 2, method: 'tools/list' })).text);
    assert.deepEqual(list.result.tools.map(t => t.name), ['read_file', 'run_command']);
    assert.equal(list.result.tools[1].annotations.destructiveHint, true);
    const called = JSON.parse((await rpc(toolCall(3, 'read_file', { path: 'README.md' }))).text);
    assert.equal(called.result.isError, false);
    assert.match(called.result.content[0].text, /ran read_file \{"path":"README.md"\}/);
    const forwarded = gw.app.requests.find(r => r.method === 'hands_call');
    assert.deepEqual(keys(forwarded.params), keys(WIRE.hands_call.params));
    assert.equal(forwarded.params.access_token, tokens.access_token);
    assert.equal(forwarded.params.name, 'read_file');
    assert.match(forwarded.params.request_id, /^rq_[0-9a-f]{32}$/);
    assert.deepEqual(JSON.parse((await rpc({ jsonrpc: '2.0', id: 4, method: 'ping' })).text).result, {});
    assert.deepEqual(JSON.parse((await rpc({ jsonrpc: '2.0', id: 5, method: 'resources/list' })).text), { ...WIRE.http_mapping.jsonrpc_error, id: 5 });
    assert.equal(JSON.parse((await rpc([{ jsonrpc: '2.0', id: 6, method: 'ping' }])).text).error.code, -32600);
    assert.equal(JSON.parse((await rpc('{nope')).text).error.code, -32700);
    assert.equal((await rpc({ jsonrpc: '2.0', id: 7, method: 'ping' }, { 'mcp-protocol-version': '1999-01-01' })).status, 400);
    assert.equal((await rpc({ jsonrpc: '2.0', id: 8, method: 'ping' }, { 'content-type': 'text/plain' })).status, 415);
  } finally { await gw.stop(); }
});

test('v3 V12 request_id：同一個 session、同一個 JSON-RPC id → 同一個 request_id（HTTP 重試認得出來）；不同 id 不同；tools/call 沒有 session＝400、認不得的 session（亂填、別的 grant、過期）＝404，都不送 App', async () => {
  const gw = await startGateway();
  try {
    const { rpc, session } = await authed(gw);
    assert.match(session, SESSION_SHAPE);
    const ids = [];
    const callWith = async (id, headers = {}) => {
      const before = handsCalls(gw).length;
      const res = await rpc(toolCall(id, 'read_file', { path: 'a' }), headers);
      ids.push(handsCalls(gw).length > before ? handsCalls(gw).at(-1).params.request_id : null);
      return res;
    };
    await callWith(10);
    await callWith(10);
    await callWith(11);
    await callWith('10');
    assert.equal(ids[0], ids[1], '重試同一個請求＝同一個 request_id');
    assert.notEqual(ids[0], ids[2], '不同 JSON-RPC id');
    assert.notEqual(ids[0], ids[3], '數字 10 與字串 "10" 不同');
    // 沒有 session：不再退回隨機 request_id（那樣重試會變成新的一次執行），直接 400。
    const missing = await callWith(10, { 'mcp-session-id': undefined });
    assert.equal(missing.status, 400);
    assert.equal(JSON.parse(missing.text).error.code, -32000);
    // 認不得的 session：404（MCP 規定客戶端要重新 initialize）。
    for (const bad of ['z'.repeat(32), `s1-${Math.floor(Date.now() / 1000).toString(36)}-${'a'.repeat(32)}-${'b'.repeat(32)}`, session.slice(0, -1) + (session.endsWith('0') ? '1' : '0')]) {
      const res = await callWith(10, { 'mcp-session-id': bad });
      assert.equal(res.status, 404, bad);
      assert.deepEqual(JSON.parse(res.text), { jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Session not found' } });
    }
    // 過期（超過 24 小時）：同樣 404。檢查碼照關口的算法算對，只有時間不對。
    const grantID = gw.app.state.access.values().next().value.grantID;
    const issued = Math.floor((Date.now() - LIMITS.sessionTtlMs - 60_000) / 1000).toString(36);
    const nonce = 'c'.repeat(32);
    const tag = createHash('sha256').update(`tatwo-mcp-session\ng:${grantID}\n${issued}\n${nonce}`).digest('hex').slice(0, 32);
    assert.equal((await callWith(10, { 'mcp-session-id': `s1-${issued}-${nonce}-${tag}` })).status, 404, '過期的 session');
    assert.deepEqual(ids.slice(4), [null, null, null, null, null], '這些都沒送到 App');
    // 別的 grant 拿到這個 session id：404，不會跟原本的 grant 撞在一起。
    const other = await authed(gw);
    const before = handsCalls(gw).length;
    assert.equal((await other.rpc(toolCall(10, 'read_file', { path: 'a' }), { 'mcp-session-id': session })).status, 404);
    assert.equal(handsCalls(gw).length, before);
    // 其他方法帶了認不得的 session 也是 404；沒帶 session 的 ping／tools/list 照常。
    assert.equal((await rpc({ jsonrpc: '2.0', id: 20, method: 'tools/list' }, { 'mcp-session-id': 'z'.repeat(32) })).status, 404);
    assert.equal((await rpc({ jsonrpc: '2.0', id: 21, method: 'ping' }, { 'mcp-session-id': undefined })).status, 200);
  } finally { await gw.stop(); }
});

test('v3 V12 跨重啟去重：App 已經執行、回應沒送到、關口重開 → 客戶端拿原 session、原 id 重試，送給 App 的 request_id 一樣（App 認得出是同一件事）', async () => {
  const gw = await startGateway();
  let second;
  try {
    const { rpc, session, tokens } = await authed(gw);
    const first = await rpc(toolCall(42, 'run_command', { command: 'make test' }));
    assert.equal(first.status, 200);
    const original = handsCalls(gw).at(-1).params.request_id;
    // 關口重開＝新的行程、記憶體裡什麼都沒有（這裡用另一個獨立的關口實例、另一個 socket，接同一個 App）。
    second = createGateway({ configFile: gw.layout.configFile, osSocket: gw.osSocket });
    const socket2 = path.join(gw.root, 'gw2.sock');
    await new Promise(resolve => second.server.listen(socket2, resolve));
    const retry = await request(socket2, { method: 'POST', url: '/mcp', body: JSON.stringify(toolCall(42, 'run_command', { command: 'make test' })),
      headers: { ...jsonHeaders, authorization: `Bearer ${tokens.access_token}`, 'mcp-session-id': session } });
    assert.equal(retry.status, 200, retry.text);
    assert.equal(handsCalls(gw).at(-1).params.request_id, original, '重開後的重試推出同一個 request_id');
    // 對照：同一個 session、不同的 id 就是新的一件事。
    await request(socket2, { method: 'POST', url: '/mcp', body: JSON.stringify(toolCall(43, 'run_command', { command: 'make test' })),
      headers: { ...jsonHeaders, authorization: `Bearer ${tokens.access_token}`, 'mcp-session-id': session } });
    assert.notEqual(handsCalls(gw).at(-1).params.request_id, original);
  } finally {
    if (second) await new Promise(resolve => second.server.close(resolve));
    await gw.stop();
  }
});

test('fixtures 錯誤分三種：hands_call 的 unauthorized → 401、request_id_conflict／tool_not_allowed → 工具錯誤、os.sock 忙 → 暫時不能用；tools/list 撤銷 → 401；SSE 中途撤銷 → -32001', async () => {
  const gw = await startGateway();
  try {
    const { rpc } = await authed(gw);
    const conflict = JSON.parse((await rpc(toolCall(1, 'conflict'))).text);
    assert.deepEqual(conflict.result, { content: [{ type: 'text', text: 'request_id reused with different arguments' }], isError: true });
    const locked = JSON.parse((await rpc(toolCall(2, 'locked'))).text);
    assert.deepEqual(locked.result, { content: [{ type: 'text', text: 'tool not allowed' }], isError: true });
    const busy = JSON.parse((await rpc(toolCall(3, 'busy'))).text);
    assert.deepEqual(busy.result, { content: [{ type: 'text', text: 'TATWO OS is temporarily unavailable.' }], isError: true });
    const boom = JSON.parse((await rpc(toolCall(4, 'boom'))).text);
    assert.deepEqual(boom.result, { content: [{ type: 'text', text: 'The TATWO OS tool call failed.' }], isError: true });
    const streamedRevoke = await rpc(toolCall(5, 'revoke'), { accept: 'application/json, text/event-stream' });
    assert.equal(streamedRevoke.status, 200);
    const data = JSON.parse(streamedRevoke.text.split('\n').find(line => line.startsWith('data: ')).slice(6));
    assert.deepEqual(data, { jsonrpc: '2.0', id: 5, error: { code: -32001, message: 'Unauthorized' } });
    const listAfter = await rpc({ jsonrpc: '2.0', id: 6, method: 'tools/list' });
    assert.equal(listAfter.status, 401, 'grant 撤銷後 check 就不過');
    // App 在 hands_call 當下才發現撤銷（check 之後）：非 SSE 回 401。
    const second = await authed(gw);
    const revokeNow = await second.rpc(toolCall(7, 'revoke'));
    assert.equal(revokeNow.status, 401);
    assert.match(revokeNow.headers['www-authenticate'], /error="invalid_token"/);
  } finally { await gw.stop(); }
});

test('T11 長的 tools/call 用 SSE：先回標頭、定時保活、最後一個 event 是結果（Cloudflare 約 100 秒沒位元組就斷）', async () => {
  const gw = await startGateway({ limits: { sseKeepaliveMs: 100 } });
  try {
    const { rpc, tokens } = await authed(gw);
    const streamed = await rpc(toolCall(9, 'slow'), { accept: 'application/json, text/event-stream' });
    assert.equal(streamed.status, 200);
    assert.match(streamed.headers['content-type'], /^text\/event-stream/);
    assert.ok(streamed.text.startsWith(': ok\n\n'), '標頭與第一個位元組立刻送出');
    assert.ok((streamed.text.match(/^: keepalive$/gm) ?? []).length >= 2, streamed.text);
    const events = streamed.text.split('\n\n').filter(block => block.startsWith('event: message\n'));
    assert.equal(events.length, 1);
    const data = JSON.parse(events[0].split('\n').find(line => line.startsWith('data: ')).slice(6));
    assert.equal(data.jsonrpc, '2.0');
    assert.equal(data.id, 9);
    assert.equal(data.result.content[0].text, 'slow [redacted]');
    assert.ok(!streamed.text.includes(tokens.access_token), 'SSE 裡也遮蔽 token');
    const plain = await rpc(toolCall(10, 'read_file', {}), { accept: 'application/json' });
    assert.match(plain.headers['content-type'], /^application\/json/, '沒要 SSE 就照舊回 JSON');
    const ping = await rpc({ jsonrpc: '2.0', id: 11, method: 'ping' }, { accept: 'application/json, text/event-stream' });
    assert.match(ping.headers['content-type'], /^application\/json/, '其他方法一律 JSON');
  } finally { await gw.stop(); }
});

test('T11 大請求被拒；每個 grant、全關口 MCP、metadata、/token（全域與每 client）、註冊都有上限', async () => {
  const gw = await startGateway({ limits: { perGrantPerMinute: 6, metadataPerMinute: 3, tokenPerClientPerMinute: 2, registerPerWindow: 4 } });
  try {
    const { rpc, flow } = await authed(gw);   // 用掉 1 次 register、1 次 /token
    const huge = await rpc(JSON.stringify(toolCall(1, 'x', { blob: 'a'.repeat(LIMITS.mcpBody) })));
    assert.equal(huge.status, 413);
    const bigForm = await gw.post('/token', 'a='.concat('b'.repeat(LIMITS.formBody + 10)), formHeaders);
    assert.equal(bigForm.status, 413);
    const statuses = [];
    for (let i = 0; i < 8; i += 1) statuses.push((await rpc({ jsonrpc: '2.0', id: i, method: 'ping' })).status);
    assert.ok(statuses.includes(429), `每 grant：${statuses}`);
    const meta = [];
    for (let i = 0; i < 4; i += 1) meta.push((await gw.get('/.well-known/oauth-authorization-server')).status);
    assert.deepEqual(meta, [200, 200, 200, 429], '全關口 metadata');
    const tokenStatuses = [];
    for (let i = 0; i < 3; i += 1) tokenStatuses.push((await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: 'r'.repeat(30), client_id: flow.clientID }), formHeaders)).status);
    assert.deepEqual(tokenStatuses, [400, 429, 429], '每個 client 的 /token（authed 已經用掉 1 次）');
    const registers = [];
    for (let i = 0; i < 4; i += 1) registers.push((await gw.post('/register', JSON.stringify({ redirect_uris: [REDIRECT] }), jsonHeaders)).status);
    assert.deepEqual(registers, [201, 201, 201, 429], '全關口註冊（authed 已經用掉 1 次）');
  } finally { await gw.stop(); }
});

test('T10 錯誤不洩漏內部資訊；canary 不出現在不該出現的回應', async () => {
  const gw = await startGateway();
  const bodies = [];
  try {
    const { rpc, tokens } = await authed(gw);
    bodies.push((await rpc(toolCall(1, 'boom'))).text);
    const leak = await rpc(toolCall(2, 'leak'));
    bodies.push(leak.text);
    assert.match(JSON.parse(leak.text).result.content[0].text, /\[redacted\]/);
    for (const url of ['/nope', '/mcp', '/token']) bodies.push((await gw.get(url)).text);
    bodies.push((await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: 'r'.repeat(30), client_id: 'hc_9' }), formHeaders)).text);
    bodies.push((await gw.post('/register', '{bad json', jsonHeaders)).text);
    for (const text of bodies) {
      for (const needle of [gw.osSocket, gw.layout.root, gw.root, '/Users/example', 'EACCES', 'stack', 'Error:', CANARY.code, tokens.access_token, tokens.refresh_token]) {
        assert.ok(!text.includes(needle), `回應含 ${needle}: ${text.slice(0, 200)}`);
      }
    }
  } finally { await gw.stop(); }
});

test('T10 關口不寫檔：日誌走 stdout 事件、只有固定欄位、掃不到任何 canary；socket 0600、socket 資料夾裡只有 socket', async () => {
  const gw = await startGateway();
  let events;
  try {
    const { rpc } = await authed(gw);
    await rpc(toolCall(1, 'read_file', { secret: CANARY.access }));
    await gw.get(`/authorize?code=${CANARY.code}&state=${CANARY.refresh}`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal((fs.statSync(gw.socketPath).mode & 0o777), 0o600);
    assert.deepEqual(fs.readdirSync(gw.layout.socketDir), ['gw.sock']);
    assert.deepEqual(fs.readdirSync(gw.layout.gatewayDir).sort(), ['config.json', 'sock'], '關口沒有在設定資料夾寫任何東西');
    events = [...gw.events];
  } finally { await gw.stop(); }
  const requests = events.filter(event => event.ev === 'req');
  assert.ok(requests.length > 5);
  for (const event of requests) {
    assert.deepEqual(Object.keys(event).filter(key => !['ev', 'm', 'r', 's', 'ms', 'rpc'].includes(key)), [], JSON.stringify(event));
  }
  const text = JSON.stringify(events);
  for (const needle of Object.values(CANARY)) assert.ok(!text.includes(needle), `事件含 ${needle}`);
  assert.ok(requests.some(event => event.m === 'POST' && event.r === 'mcp' && event.s === 200 && event.rpc === 'tools/call'));
});

test('fixtures/wire.json 形狀一致：關口送出的每一種請求欄位＝fixture；App 照 fixture 回，關口照樣接得住並轉成對的 HTTP 回應', async () => {
  const sent = [];
  const reply = (method, params) => {
    sent.push({ method, params });
    const auth = WIRE.hands_auth;
    if (method === 'hands_tools') return WIRE.hands_tools.result;
    if (method === 'hands_call') return WIRE.hands_call.result;
    if (params.op === 'token') return auth.token.result;
    return auth[params.op].result;
  };
  const gw = await startGateway({ osCall: async (method, params) => reply(method, params) });
  try {
    const verifier = WIRE.hands_auth.token.params_authorization_code.code_verifier;
    const callback = WIRE.hands_auth.register_client.params.redirect_uris[0];
    const registered = JSON.parse((await gw.post('/register', JSON.stringify({ redirect_uris: [callback], client_name: 'ChatGPT' }), jsonHeaders)).text);
    assert.equal(registered.client_id, WIRE.hands_auth.register_client.result.client_id);
    const begin = WIRE.hands_auth.authorize_begin.params;
    const query = new URLSearchParams({ response_type: 'code', client_id: begin.client_id, redirect_uri: begin.redirect_uri, code_challenge: begin.code_challenge,
      code_challenge_method: 'S256', state: begin.state, resource: `https://${HOST}/mcp`, scope: begin.scope });
    const page = await gw.get(`/authorize?${query}`, { 'cf-connecting-ip': BROWSER_IP });
    assert.equal(page.status, 200, page.text);
    assert.ok(page.text.includes(`<strong>${WIRE.hands_auth.authorize_begin.result.display_code}</strong>`));
    const csrf = /name="csrf" value="([^"]+)"/.exec(page.text)[1];
    const cookie = page.headers['set-cookie'][0].split(';')[0];
    const done = await gw.post('/authorize', form({ transaction_id: WIRE.hands_auth.authorize_begin.result.transaction_id, csrf,
      code: WIRE.hands_auth.authorize_submit.params.pairing_code }), { ...formHeaders, cookie, origin, 'cf-connecting-ip': BROWSER_IP });
    assert.equal(done.status, 302, done.text);
    assert.equal(new URL(done.headers.location).searchParams.get('code'), WIRE.hands_auth.authorize_submit.result.authorization_code);
    const token = JSON.parse((await gw.post('/token', form({ grant_type: 'authorization_code', code: WIRE.hands_auth.authorize_submit.result.authorization_code,
      code_verifier: verifier, client_id: registered.client_id, redirect_uri: callback }), formHeaders)).text);
    assert.deepEqual(token, WIRE.hands_auth.token.result);
    const refreshed = JSON.parse((await gw.post('/token', form({ grant_type: 'refresh_token', refresh_token: WIRE.hands_auth.token.params_refresh_token.refresh_token,
      client_id: registered.client_id }), formHeaders)).text);
    assert.equal(refreshed.access_token, WIRE.hands_auth.token.result.access_token);
    const init = await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 0, method: 'initialize', params: {} }), { ...jsonHeaders, authorization: `Bearer ${token.access_token}` });
    const headers = { ...jsonHeaders, authorization: `Bearer ${token.access_token}`, 'mcp-session-id': init.headers['mcp-session-id'] };
    const tools = JSON.parse((await gw.post('/mcp', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }), headers)).text);
    assert.deepEqual(tools.result.tools, WIRE.hands_tools.result.tools);
    const called = JSON.parse((await gw.post('/mcp', JSON.stringify(toolCall(2, 'read_file', WIRE.hands_call.params.arguments)), headers)).text);
    assert.deepEqual(called.result, WIRE.hands_call.result);
    // 每一種請求的欄位都跟 fixture 一模一樣（R1 對多餘欄位是拒絕的）。
    const shapeOf = entry => entry.method === 'hands_auth' ? (entry.params.op === 'token' ? `token_${entry.params.grant_type}` : entry.params.op) : entry.method;
    const expected = {
      register_client: WIRE.hands_auth.register_client.params, authorize_begin: WIRE.hands_auth.authorize_begin.params,
      authorize_submit: WIRE.hands_auth.authorize_submit.params, token_authorization_code: WIRE.hands_auth.token.params_authorization_code,
      token_refresh_token: WIRE.hands_auth.token.params_refresh_token, check: WIRE.hands_auth.check.params,
      hands_tools: WIRE.hands_tools.params, hands_call: WIRE.hands_call.params,
    };
    const seen = new Set();
    for (const entry of sent) {
      const shape = shapeOf(entry);
      seen.add(shape);
      assert.deepEqual(keys(entry.params), keys(expected[shape]), shape);
    }
    assert.deepEqual([...seen].sort(), Object.keys(expected).sort(), '八種請求都走過');
    const submit = sent.find(entry => entry.params.op === 'authorize_submit').params;
    assert.match(submit.browser_binding_hash, /^sha256:[0-9a-f]{64}$/);
    assert.equal(submit.pairing_code, WIRE.hands_auth.authorize_submit.params.pairing_code);
    for (const [key, value] of Object.entries(WIRE.hands_auth.authorize_begin.params)) {
      if (key !== 'resource') assert.equal(sent.find(entry => entry.params.op === 'authorize_begin').params[key], value, key);
    }
  } finally { await gw.stop(); }
});

test('殘餘風險 V16：同一個 macOS 使用者的假 client 直接連關口 socket、偽造 OpenAI 的 CF-Connecting-IP 與 Host——打得到 metadata，但沒有配對與 token 拿不到任何工具', async () => {
  const gw = await startGateway();
  try {
    // 這個測試本身就是「同一個使用者的其他程式」：直接連 unix socket，不經 cloudflared。
    const forged = { 'cf-connecting-ip': OPENAI_IP, host: HOST };
    assert.equal((await request(gw.socketPath, { url: '/.well-known/oauth-protected-resource', headers: forged })).status, 200, '殘餘：來源 IP 偽造得了（寫進報告，不假裝解決）');
    const noToken = await request(gw.socketPath, { method: 'POST', url: '/mcp', headers: { ...forged, ...jsonHeaders }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
    assert.equal(noToken.status, 401);
    for (const guess of [CANARY.access, 'at_' + 'A'.repeat(40), 'x'.repeat(64)]) {
      const res = await request(gw.socketPath, { method: 'POST', url: '/mcp', headers: { ...forged, ...jsonHeaders, authorization: `Bearer ${guess}` },
        body: JSON.stringify(toolCall(1, 'read_file', { path: '/etc/hosts' })) });
      assert.equal(res.status, 401, guess);
    }
    const token = await request(gw.socketPath, { method: 'POST', url: '/token', headers: { ...forged, ...formHeaders },
      body: form({ grant_type: 'authorization_code', code: 'ac_' + 'f'.repeat(30), code_verifier: 'v'.repeat(43), client_id: 'hc_1', redirect_uri: REDIRECT }) });
    assert.equal(token.status, 400, '偽造的授權碼換不到 token');
    assert.ok(!gw.app.requests.some(r => r.method === 'hands_tools' || r.method === 'hands_call'), 'App 一次工具都沒被叫到');
  } finally { await gw.stop(); }
});

test('起關口：socket 路徑被一般檔案占住就不刪、不起；設定檔不在就不起；錯誤碼不含路徑', async () => {
  const root = shortRoot('w183o-');
  try {
    const layout = handsLayout(path.join(root, 'h'));
    const osSocket = path.join(root, 'o.sock');
    await assert.rejects(serveGateway({ configFile: layout.configFile, osSocket, signal: AbortSignal.timeout(2000) }), /^Error: config_missing$/);
    writeConfig(layout);
    fs.writeFileSync(layout.socketPath, 'NOT-A-SOCKET');
    await assert.rejects(serveGateway({ configFile: layout.configFile, osSocket, signal: AbortSignal.timeout(2000) }), /^Error: socket_path_occupied$/);
    assert.equal(fs.readFileSync(layout.socketPath, 'utf8'), 'NOT-A-SOCKET');
    fs.rmSync(layout.socketPath);
    writeConfig(layout, { socket_path: 'relative/gw.sock' });
    await assert.rejects(serveGateway({ configFile: layout.configFile, osSocket, signal: AbortSignal.timeout(2000) }), /^Error: socket_path_invalid$/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

// ---------- 審查 R2b：連線層、標頭、限流表、斷線收尾、socket 冒充 ----------
/// 送一段原始 HTTP（不經 http 模組，才能送重複標頭、超量標頭、送一半就停），回狀態碼或 'CLOSED'。
function rawRequest(socketPath, text, { timeoutMs = 3000 } = {}) {
  return new Promise(resolve => {
    const socket = net.createConnection({ path: socketPath });
    let data = '';
    const timer = setTimeout(() => { socket.destroy(); resolve(data ? Number(data.split(' ')[1]) : 'TIMEOUT'); }, timeoutMs);
    socket.on('connect', () => socket.write(text));
    socket.on('data', chunk => { data += chunk; });
    socket.on('error', () => {});
    socket.on('close', () => { clearTimeout(timer); resolve(data ? Number(data.split(' ')[1]) : 'CLOSED'); });
  });
}
const rawHead = (lines, extra = '') => `GET /.well-known/oauth-protected-resource HTTP/1.1\r\nHost: ${HOST}\r\n${lines.join('')}Connection: close\r\n${extra}\r\n`;
const fillers = count => Array.from({ length: count }, (_, i) => `X-Filler-${i}: ${i}\r\n`);

test('審查 R2b 標頭：超過上限（100）＝431、不是默默截斷；CF-Connecting-IP／Host／Authorization 等重複＝400；剛好上限照常', async () => {
  const gw = await startGateway();
  try {
    const ip = `CF-Connecting-IP: ${OPENAI_IP}\r\n`;
    // Host＋CF-Connecting-IP＋Connection＝3 個，再補到剛好 100。
    assert.equal(await rawRequest(gw.socketPath, rawHead([ip, ...fillers(LIMITS.maxHeaders - 3)])), 200, '剛好 100 個標頭照常');
    // 合法來源放前面、超量後面再放第二個來源標頭：解析器若默默截斷，第二個就看不到——這裡必須整筆拒絕。
    assert.equal(await rawRequest(gw.socketPath, rawHead([ip, ...fillers(LIMITS.maxHeaders)], `CF-Connecting-IP: ${OTHER_IP}\r\n`)), 431);
    assert.equal(await rawRequest(gw.socketPath, rawHead([ip, ...fillers(150)])), 431, '總長還在 16 KiB 內也一樣');
    for (const dup of [`CF-Connecting-IP: ${OPENAI_IP}\r\n`, `Host: ${HOST}\r\n`, 'Authorization: Bearer x\r\nAuthorization: Bearer y\r\n', 'Origin: https://a.example.com\r\nOrigin: https://b.example.com\r\n',
      'Mcp-Session-Id: a\r\nMcp-Session-Id: b\r\n']) {
      assert.equal(await rawRequest(gw.socketPath, rawHead([ip, dup])), 400, dup);
    }
    assert.equal(headerProblem(['Cookie', 'a=1', 'cookie', 'b=2', 'Host', HOST]), 0, 'Cookie 可以拆成好幾行（HTTP/2 轉過來本來就會）');
  } finally { await gw.stop(); }
});

test('審查 R2b 連線數：大量連上卻只送一半標頭的連線，最多 maxConnections 條，其餘直接關；標頭期限到就全部收掉；之後照常服務', { timeout: 30_000 }, async () => {
  const limits = { maxConnections: 8, headersTimeoutMs: 600, requestTimeoutMs: 1200, connectionsCheckMs: 100 };
  const gw = await startGateway({ limits });
  const sockets = [];
  try {
    const states = await Promise.all(Array.from({ length: 30 }, () => new Promise(resolve => {
      const socket = net.createConnection({ path: gw.socketPath });
      sockets.push(socket);
      socket.on('error', () => {});
      socket.resume();   // 讀掉關口回的東西，關口關線時這一端才看得到結束
      socket.on('connect', () => socket.write(`POST /mcp HTTP/1.1\r\nHost: ${HOST}\r\n`));   // 標頭沒送完
      socket.on('close', () => resolve('closed'));
      setTimeout(() => resolve(socket.destroyed ? 'closed' : 'open'), 300);
    })));
    const open = states.filter(state => state === 'open').length;
    assert.ok(open <= limits.maxConnections, `同時開著的連線 ${open} 超過上限 ${limits.maxConnections}`);
    assert.ok(open > 0, '上限內的連線照常接受');
    const reaped = await new Promise(resolve => {
      const deadline = Date.now() + 5000;
      const tick = () => { if (sockets.every(socket => socket.destroyed || socket.closed)) resolve(true); else if (Date.now() > deadline) resolve(false); else setTimeout(tick, 100); };
      tick();
    });
    assert.ok(reaped, '標頭期限到了全部收掉（不佔 fd／記憶體）');
    assert.equal((await gw.get('/.well-known/oauth-protected-resource')).status, 200, '之後照常服務');
  } finally { for (const socket of sockets) socket.destroy(); await gw.stop(); }
});

test('審查 R2b 限流表有硬容量：滿了新來源一律拒絕、不配置狀態；舊來源照常；過期後清得掉；清表最多每秒一次', () => {
  const table = new RateWindow(5, 60_000, 3);
  assert.ok(table.take('a', 0) && table.take('b', 0) && table.take('c', 0));
  assert.equal(table.take('d', 10), false, '滿了：新來源拒絕');
  assert.equal(table.buckets.size, 3, '沒有替新來源建狀態');
  assert.ok(table.take('a', 20), '已經在表裡的照常計數');
  assert.equal(table.take('e', 500), false, '一秒內不再掃表（不會每個新來源都掃一遍）');
  assert.ok(table.take('f', 60_500), '窗口過了：清掉過期的，新來源進得來');
  assert.ok(table.buckets.size <= 3);
  // peek 不建狀態。
  const global = new RateWindow(1, 60_000, 3);
  assert.ok(global.peek('all', 0));
  assert.equal(global.buckets.size, 0);
  global.take('all', 0);
  assert.equal(global.peek('all', 1), false);
  // 授權頁：先只看不記全關口配對額度，用完就擋，不替這個來源建狀態；之後才照 V18 的順序（來源、全關口）記。
  const source = read('Engines/chatgpt-hands/gateway.mjs');
  const order = ["pairingWindow.peek('all'", 'pairingPerIp.take(sourceKey', "pairingWindow.take('all'"].map(needle => source.indexOf(needle));
  assert.ok(order.every(index => index > 0) && order[0] < order[1] && order[1] < order[2], `授權頁限流順序 ${order}`);
  assert.doesNotMatch(source, /new Window\(|this\.buckets\.size > 10_000/, '舊的無上限限流表不在了');
});

test('審查 R2b 限流表（關口實跑）：很多來源打授權頁，表滿了新來源一律 429、已在表裡的照常', async () => {
  const gw = await startGateway({ limits: { rateKeys: 5 } });
  try {
    const statuses = [];
    for (let i = 1; i <= 9; i += 1) statuses.push((await gw.get('/authorize?x=1', { 'cf-connecting-ip': `198.51.100.${100 + i}` })).status);
    assert.deepEqual(statuses.slice(0, 5), [400, 400, 400, 400, 400], '前 5 個來源照常（參數不對 400）');
    assert.deepEqual(statuses.slice(5), [429, 429, 429, 429], '表滿了：新來源一律 429');
    assert.equal((await gw.get('/authorize?x=1', { 'cf-connecting-ip': '198.51.100.101' })).status, 400, '已在表裡的來源照常');
  } finally { await gw.stop(); }
});

test('審查 R2b 斷線收尾：等 App 驗 token 時客戶端斷線，不會永久佔住 grant 名額（之後同一個 grant 照常，不會一直 429）', { timeout: 30_000 }, async () => {
  let target;
  let slow = false;
  const gw = await startGateway({ osCall: async (method, params, timeoutMs) => {
    if (slow && params?.op === 'check') await new Promise(resolve => setTimeout(resolve, 300));
    return osSocketCall(target, method, params, { timeoutMs });
  } });
  target = gw.osSocket;
  try {
    const { rpc, tokens, session } = await authed(gw);
    slow = true;
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
    // 比每個 grant 的同時上限（4）多幾次：每次都在 App 還沒回 check 時就斷線。
    for (let i = 0; i < LIMITS.perGrantInFlight + 2; i += 1) {
      await new Promise(resolve => {
        const socket = net.createConnection({ path: gw.socketPath });
        socket.on('error', () => {});
        socket.on('connect', () => {
          socket.write(`POST /mcp HTTP/1.1\r\nHost: ${HOST}\r\nCF-Connecting-IP: ${OPENAI_IP}\r\nAuthorization: Bearer ${tokens.access_token}\r\nMcp-Session-Id: ${session}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
          setTimeout(() => { socket.destroy(); resolve(); }, 50);
        });
      });
    }
    await new Promise(resolve => setTimeout(resolve, 800));   // App 的 check 都回來了
    slow = false;
    const after = [];
    for (let i = 0; i < 5; i += 1) after.push((await rpc({ jsonrpc: '2.0', id: 10 + i, method: 'tools/list' })).status);
    assert.deepEqual(after, [200, 200, 200, 200, 200], `斷線沒有佔住名額：${after}`);
  } finally { await gw.stop(); }
});

test('審查 R2b／殘餘風險 V16 socket 冒充：socket 被換成別人的 listener、被刪、改名再改回來、上層資料夾被換掉，關口都會發現並以 socket_replaced／socket_missing 停下（結束碼 3）', { timeout: 30_000 }, async () => {
  const cases = {
    async replace(layout) { fs.renameSync(layout.socketPath, layout.socketPath + '.x'); return net.createServer().listen(layout.socketPath); },
    async remove(layout) { fs.unlinkSync(layout.socketPath); return null; },
    async renameBack(layout) {
      // 改名、在原路徑放自己的 listener、收完再把原本的改回來：inode 一樣，但 ctime 變了。
      fs.renameSync(layout.socketPath, layout.socketPath + '.x');
      const fake = net.createServer().listen(layout.socketPath);
      await new Promise(resolve => fake.once('listening', resolve));
      await new Promise(resolve => fake.close(resolve));
      try { fs.unlinkSync(layout.socketPath); } catch {}
      fs.renameSync(layout.socketPath + '.x', layout.socketPath);
      return null;
    },
    async swapParent(layout) {
      const socketDir = layout.socketDir;
      fs.renameSync(socketDir, socketDir + '.x');
      fs.mkdirSync(socketDir, { mode: 0o700 });
      return net.createServer().listen(layout.socketPath);
    },
  };
  for (const [name, attack] of Object.entries(cases)) {
    const gw = await startGateway({ socketCheckMs: 100 });
    let fake = null;
    try {
      assert.equal((await gw.get('/.well-known/oauth-protected-resource')).status, 200);
      const before = socketIdentity(gw.socketPath);
      fake = await attack(gw.layout);
      // 關口跟測試在同一個行程：攻擊做完、還沒讓出執行緒前量的，就是攻擊者換回來之後的樣子。
      const after = name === 'renameBack' && fs.existsSync(gw.socketPath) ? socketIdentity(gw.socketPath) : null;
      const outcome = await Promise.race([gw.running.then(() => 'resolved', error => error.message), new Promise(resolve => setTimeout(() => resolve('still running'), 3000))]);
      assert.ok(outcome === 'socket_replaced' || outcome === 'socket_missing', `${name}: ${outcome}`);
      if (after) assert.notEqual(after, before, '改名再改回來：inode 一樣，但身分（ctime）不一樣了');
    } finally { if (fake) fake.close(); await gw.stop(); }
  }
  // 直接跑 gateway.mjs（App 的開法）：被換掉時結束碼 3，App 看到就停下、不自動重開。
  const root = shortRoot('w183x-');
  try {
    const layout = handsLayout(path.join(root, 'h'));
    const osSocket = path.join(root, 'o.sock');
    const app = await fakeApp(osSocket);
    writeConfig(layout);
    const child = spawn(process.execPath, [path.join(repo, 'Engines/chatgpt-hands/gateway.mjs'), layout.configFile],
      { env: { PATH: '/usr/bin:/bin', TATWO2_OS_SOCKET: osSocket }, stdio: ['pipe', 'pipe', 'ignore'] });
    let out = '';
    child.stdout.on('data', chunk => { out += chunk; });
    for (let i = 0; i < 100 && !out.includes('"ready"'); i += 1) await new Promise(r => setTimeout(r, 100));
    fs.renameSync(layout.socketPath, layout.socketPath + '.x');
    const fake = net.createServer().listen(layout.socketPath);
    const code = await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => resolve('still running'), 5000); });
    fake.close(); app.server.close();
    if (code === 'still running') child.kill('SIGKILL');
    assert.equal(code, TAMPER_EXIT_CODE, out);
    assert.match(out, /"ev":"error","code":"socket_(replaced|missing)"/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

// ---------- 打包與 App 端原始碼契約（照 w176、w80b 的方式讀原始碼） ----------
test('打包：Engines/chatgpt-hands 進 Resources/chatgpt-hands、另起 inputs 行、沒有 supervisor、cloudflared 不打包、清理認得它', () => {
  const build = read('scripts/build-app.sh');
  assert.match(build, /\ncp -R "Engines\/chatgpt-hands" "\$CONTENTS\/Resources\/chatgpt-hands"\n/);
  assert.match(build, /\n  inputs\+=\(Engines\/chatgpt-hands\/gateway\.mjs Engines\/chatgpt-hands\/fsop\.mjs Engines\/chatgpt-hands\/gateway\.sb Engines\/chatgpt-hands\/cloudflared\.sb Engines\/chatgpt-hands\/tunnel-guard\.sh\)\n/);
  assert.doesNotMatch(build, /supervisor\.mjs/);
  assert.ok(!fs.existsSync(path.join(repo, 'Engines/chatgpt-hands/supervisor.mjs')), 'v2 §1：沒有 Node supervisor');
  // 共用能力模組與 sidecar 同組；Hands 仍在上面斷言的獨立 inputs 行。
  const group = /inputs\+=\(Engines\/model-capabilities\.mjs Engines\/claude-sidecar\/package\.json[^)]*\)/.exec(build);
  assert.ok(group, 'shared capability module and sidecar package are build inputs');
  assert.doesNotMatch(group[0], /chatgpt-hands/);
  assert.equal(spawnSync('bash', ['scripts/build-app.sh', '--check-inputs'], { cwd: repo, encoding: 'utf8' }).status, 0);
  assert.doesNotMatch(read('scripts/bundle-engines.sh'), /cloudflared/, 'cloudflared 先用使用者已裝的版本，不打包');
  const sidecar = read('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift');
  const ours = /private static func recordedCommandIsOurs[\s\S]*?\n    }\n/.exec(sidecar)[0];
  assert.match(ours, /command\.contains\("chatgpt-hands"\)/);
  assert.match(ours, /command\.contains\("cloudflared"\) && command\.contains\("TATWO OS Hands\/cf\.yml"\)/);
  const source = read('Engines/chatgpt-hands/gateway.mjs');
  const imports = [...source.matchAll(/^import .* from '([^']+)';$/gm)].map(m => m[1]);
  assert.ok(imports.every(name => name.startsWith('node:')), `gateway.mjs 只用 node: 模組：${imports}`);
  assert.doesNotMatch(source, /child_process|\bspawn\(|\bexecFile\(|\bfork\(|\bexecSync\(/, 'gateway.mjs 不開子行程');
  assert.doesNotMatch(source, /writeFileSync|appendFileSync|createWriteStream|mkdirSync|renameSync/, 'gateway.mjs 不寫檔（只建 socket）');
});

test('v3 V8／T13／T10 App 端服務：兄弟行程、啟動與退出順序、CLOEXEC_DEFAULT、cloudflared 獨立 HOME＋明確 --config＋--no-autoupdate、token 只走 0600 檔、自測／staging 不啟動', () => {
  const service = read('App/Sources/Tatwo2/Facade/ChatGPTHandsService.swift');
  const launch = read('App/Sources/Tatwo2/Facade/HandsGatewayLaunch.swift');
  const sidecar = read('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift');
  // 版面（v2 §10）。
  assert.match(launch, /static let rootFolderName = "TATWO OS Hands"/);
  for (const piece of [/appendingPathComponent\("app", isDirectory: true\)/, /gatewayDir\.appendingPathComponent\("config\.json"\)/,
    /gatewayDir\.appendingPathComponent\("sock", isDirectory: true\)/, /root\.appendingPathComponent\("cf-home", isDirectory: true\)/]) assert.match(launch, piece);
  // 啟動：sandbox-exec 直接開 gateway.mjs（沒有 supervisor），CLOEXEC_DEFAULT。
  assert.match(launch, /appendingPathComponent\("gateway\.mjs"\)\.path, paths\.gatewayConfig\.path\]/);
  assert.match(launch, /static func spawnGateway[\s\S]*?closeInheritedDescriptors: true,\n\s*onStdout: handlers\.stdout, onStderr: handlers\.stderr, onExit: handlers\.exit\)/);
  assert.match(launch, /static func spawnTunnel[\s\S]*?closeInheritedDescriptors: true, disclaimResponsibility: true,\n\s*onStdout: handlers\.stdout, onStderr: handlers\.stderr, onExit: handlers\.exit\)/);
  // 審查 R2b：回呼在開行程時就裝好（先裝回呼、再開始讀輸出與等結束）；服務不在開好之後才設。
  assert.match(sidecar, /process\.onStdout = onStdout; process\.onStderr = onStderr; process\.onExit = onExit   \/\/ W183 R2b：先裝回呼\n\s*process\.installReaders\(\)/);
  assert.match(sidecar, /exitStatus = status   \/\/ W183 R2b\n\s*stdout\.readabilityHandler = nil/, '結束碼在呼叫 onExit 之前設好');
  assert.doesNotMatch(service, /process\.on(Stdout|Stderr|Exit) = /);
  assert.match(service, /spawnGateway\(launch, paths: resolved, osSocket: osSocket, handlers: handlers\)/);
  assert.match(service, /spawnTunnel\(launch, paths: pending\.paths, handlers: handlers\)/);
  assert.match(sidecar, /if closeInheritedDescriptors \{ flags \|= Int16\(POSIX_SPAWN_CLOEXEC_DEFAULT\) \}/);
  // 順序（v3 V8）：預建資料夾 → 開關口 → 登記 → 健康（同一個 pid）→ 最後 cloudflared。
  const start = service.slice(service.indexOf('private func start(_ prepared: Prepared)'), service.indexOf('private func gatewayOutput'));
  const order = ['resolvedPaths()', 'HandsGatewayLaunch.spawnGateway(', 'dependencies.register(process.pid, startTime)'].map(needle => start.indexOf(needle));
  assert.ok(order.every(index => index >= 0) && order[0] < order[1] && order[1] < order[2], `啟動順序 ${order}`);
  assert.doesNotMatch(start, /spawnTunnel/, '關口健康之前不開 cloudflared');
  assert.match(service, /case "ready":\n\s*checkHealthThenStartTunnel/);
  assert.match(service, /guard let probe, probe\.peer == expected, peerStart == expectedStart else/, '健康探測確認聽 socket 的就是登記的 pid（連同啟動時間）');
  // 審查 R2b：定時確認行程活著、socket 聽的人沒換；被動過就停下、不自動重開。
  assert.match(service, /if gateway != nil \{\n(?:\s*\/\/[^\n]*\n)*\s*if let local = dependencies\.localDeviceID\(\), !dependencies\.hostConfirmed\(local\) \{\n\s*currentFingerprint = nil\n\s*shutdown\(then: \.stopped\)\n\s*return\n\s*\}\n\s*if settings\.fingerprint != currentFingerprint \{ shutdown\(then: \.starting\); begin\(settings\); return \}\n\s*checkAlive\(\)/);   // W183 R8c：許可沒了＝安全暫停（不撤銷）
  assert.match(service, /if let gateway, !gateway\.isRunning \{/);
  assert.match(service, /if peer != expected \|\| peerStart != expectedStart \{\n\s*lastGatewayError = "socket_replaced"/);
  assert.match(service, /gateway\?\.exitCode == HandsGatewayLaunch\.tamperExitCode/);
  assert.match(service, /if tampered \{ return fail\(Self\.tamperedText, fingerprint: nil\) \}/);
  assert.match(launch, /static let tamperExitCode: Int32 = 3/);
  assert.equal(TAMPER_EXIT_CODE, 3, 'App 與關口的結束碼一致');
  // 退出（v3 V8）：先 cloudflared（等它結束）→ 解除登記 → 再關口。
  const stop = service.slice(service.indexOf('private func terminateBoth()'), service.indexOf('private func shutdown('));
  const stopOrder = ['tunnelProcess.terminateGroup()', 'groupIsAlive(tunnelProcess.pgid)', 'dependencies.unregister(registeredPID)', 'gatewayProcess.terminateGroup()'].map(needle => stop.indexOf(needle));
  assert.ok(stopOrder.every(index => index >= 0) && stopOrder.every((value, i) => i === 0 || stopOrder[i - 1] < value), `退出順序 ${stopOrder}`);
  assert.match(service, /OSSocketCaller\.registerExternalAI\(pid: \$0, startTime: \$1, thread: HandsGatewayLaunch\.unboundThread\)/, '關口身分不綁對話');
  assert.match(service, /OSSocketCaller\.unregisterExternalAI\(pid: \$0\)/);
  assert.doesNotMatch(service, /rootThreadProvider/, 'v2 §1：不再要「ChatGPT 手腳」根對話才開關口');
  // cloudflared：參數、環境、token。
  assert.match(launch, /\["tunnel", "--no-autoupdate", "--config", config\.path, "run", "--token-file", tokenFile\.path\]/);
  assert.match(launch, /\["HOME": paths\.cloudflaredHome\.path, "PATH": "\/usr\/bin:\/bin"\]/, 'cloudflared 的環境只有 HOME、PATH');
  assert.match(launch, /\["PATH": "\/usr\/bin:\/bin", "HOME": paths\.gatewayDir\.path, "LANG": "en_US\.UTF-8", "TATWO2_OS_SOCKET": osSocket\]/, '關口的環境沒有秘密');
  assert.doesNotMatch(launch + service, /"TUNNEL_TOKEN"/, 'token 不放環境變數（非系統程式的環境同一個使用者讀得到；v3 V19 的 0600 暫存檔取代）');
  assert.doesNotMatch(launch, /"--token"/, 'token 不進 argv');
  assert.match(launch, /O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC, 0o600/, 'token 檔只建新檔、不跟隨捷徑、0600');
  assert.match(service, /dropTokenFile\(\)   \/\/ 連上了/, '連上就刪 token 檔');
  assert.match(launch, /var arguments = \["-c", guardScript, guardName, tokenFile\.path, sandboxExec, "-p", profile\]/, '看門程式用 sh -c 全文，不讀腳本檔');
  assert.match(launch, /\("HANDS_ROOT", paths\.root\.path\)/, 'cloudflared 讀不到手腳資料夾（App 設定、OAuth 狀態、關口設定）');
  assert.doesNotMatch(launch + service, /"[^"\n]*\.cloudflared[/"]/, '程式裡沒有指向 ~/.cloudflared 的路徑');
  assert.match(launch, /"\/usr\/bin\/sandbox-exec"/);
  assert.match(service, /NativeStagingIsolation\.isEnabled/);
  assert.match(service, /TATWO2_SOURCETEST/);
  assert.match(launch, /https:\/\/openai\.com\/chatgpt-connectors\.json/);
  assert.match(read('App/Sources/Tatwo2/SelfTest.swift'), /"w183gateway"[\s\S]{0,200}HandsGatewayAcceptance/);
  assert.match(service, /SidecarGroupedProcess\.isTerminating/);
  assert.match(sidecar, /fcntl\(fd, F_SETFD, fcntl\(fd, F_GETFD\) \| FD_CLOEXEC\)/, 'App 端的 pipe 不給其他子行程繼承');
  assert.match(sidecar, /lock\.lock\(\); terminating = true; let groups/, 'terminateAll 一開頭就標記');
  // IP 清單（v2 §2）：更新失敗保留舊清單且不更新時間。
  const apply = service.slice(service.indexOf('private func applyRanges('), service.indexOf('static func fetchConnectorList'));
  assert.match(apply, /case \.failure:\n\s*document\.lastError = "fetch_failed"/);
  assert.equal((apply.match(/document\.rangesFetchedAt = /g) ?? []).length, 1, '只有驗過的新清單才寫抓到的時間');
  assert.match(read('App/Sources/Tatwo2/Facade/HandsContract.swift'), /static func unregisterExternalAI\(pid: pid_t\? = nil\)/);
  // 審查 R2b：身分驗不到要記 SKIP（算進 SUMMARY），登記實作後驗不到就 FAIL。
  assert.match(read('App/Sources/Tatwo2/Facade/HandsContract.swift'), /static let registryImplemented = true/);
  const acceptance = read('App/Sources/Tatwo2/Facade/HandsGatewayAcceptance.swift');
  assert.match(acceptance, /print\("W183GATEWAY SKIP blocked-until-R1 \\\(name\)"\)/);
  assert.match(acceptance, /if HandsContract\.registryImplemented \{ check\(false/);
  assert.match(acceptance, /print\("W183GATEWAY SUMMARY failures=\\\(failures\) skipped=\\\(skipped\.count\)/);
  assert.doesNotMatch(acceptance, /W183GATEWAY NOTE/, '不再用 NOTE 默默略過');
});

// W183 R4（接口約定 v3 V21）：真實 os.sock 的整合不再固定記 SKIP；改成真的整合測試（HandsGatewayIntegration.swift，App 自測 w183gateway 實跑）。
// 這裡只釘住「走的是真的元件」與十步都在：真的橋（OSAgentBridge.shared 的自測 listener）、HandsService.shared／HandsState.shared（畫面按鈕）、
// ChatGPTHandsService 起的關口（預設的 registerExternalAI，不借 registerHelper）、HTTP 直接打關口 socket 帶 CF-Connecting-IP 與 Host。
test('W183 R4 整合測試：取代唯一的 SKIP、走真的 os.sock／HandsService／關口、十步都在、在模擬 App 結束之前跑', () => {
  const acceptance = read('App/Sources/Tatwo2/Facade/HandsGatewayAcceptance.swift');
  const integration = read('App/Sources/Tatwo2/Facade/HandsGatewayIntegration.swift');
  assert.doesNotMatch(acceptance, /pending\("真實 os\.sock 整合/, '整合已實作：不再固定記 SKIP');
  assert.match(acceptance, /MainActor\.assumeIsolated \{ HandsGatewayIntegration\.run\(check\) \}[^\n]*\n\s*endToEnd\(check, skip\)/,
    '整合在 endToEnd（最後模擬 App 結束）之前跑');
  assert.match(integration, /^#if DEBUG$/m, '只在 debug 建置');
  assert.match(integration, /NativeStagingIsolation\.isEnabled\(environment\)/, '只在完整隔離的 staging 跑');
  assert.match(integration, /handsRoot\.hasPrefix\(staging \+ "\/"\)/, 'HandsService 的資料夾不在 staging 就不跑（不碰真的 App Support）');
  assert.match(integration, /OSAgentBridge\.shared\.startSecurityTestListener\(\)/, '真的 App 端 os.sock 橋');
  assert.match(integration, /private let state = HandsState\.shared/, '開窗口、撤銷、開關都走畫面狀態');
  assert.match(integration, /private let service = HandsService\.shared/, '橋用的就是這一個 HandsService');
  for (const action of ['state.startPairing()', 'state.revokeGrant(', 'state.setEnabled(false)', 'state.pendingPairing?.pairingCode']) {
    assert.ok(integration.includes(action), action);
  }
  assert.match(integration, /let gateway = ChatGPTHandsService\(dependencies: deps\)/, '關口由 ChatGPTHandsService 起');
  assert.match(integration, /register／unregister 用預設：真的 OSSocketCaller\.registerExternalAI/);
  assert.doesNotMatch(integration, /deps\.register\s*=/, '關口的登記不換成假的');
  assert.doesNotMatch(integration, /registerHelper/, '不借 .helper（全權）');
  assert.match(integration, /CF-Connecting-IP: \\\(ip\)/);
  assert.match(integration, /Host: \\\(HandsIntegrationFixture\.host\)/);
  assert.match(integration, /static let host = "hands\.example\.com"/, '網域用 example.com');
  assert.doesNotMatch(integration, /\.cloudflared[/"]/, '不碰 ~/.cloudflared');
  assert.doesNotMatch(integration, /SecItem|kSecClass/, '不碰鑰匙圈');
  for (const step of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) assert.ok(integration.includes(`"整合 ${step}/10：`), `第 ${step} 步有自己的 PASS 行`);
  for (const method of ['"transcript"', '"dispatch_rooms"', '"hands_setup_status"']) assert.ok(integration.includes(method), `身分：${method} 要被拒`);
  assert.match(integration, /exec \? "exec " \+ nc : nc \+ "; rc=\$\?; exit \$rc"/, '子行程那一組：sh 不會直接換成 nc');
  // 印出來的只有步驟與狀態碼：report 的證據不放 token、授權碼、配對碼。
  const evidence = [...integration.matchAll(/\], "([^"\n]*)"\)/g)].map(match => match[1]).join('\n');
  assert.doesNotMatch(evidence, /access|refresh|authCode|pairingCode|code\)/, evidence);
});

const W183_FILES = ['Engines/chatgpt-hands/gateway.mjs', 'Engines/chatgpt-hands/gateway.sb',
  'Engines/chatgpt-hands/cloudflared.sb', 'Engines/chatgpt-hands/tunnel-guard.sh', 'App/Sources/Tatwo2/Facade/ChatGPTHandsService.swift',
  'App/Sources/Tatwo2/Facade/HandsGatewayLaunch.swift', 'App/Sources/Tatwo2/Facade/HandsGatewayAcceptance.swift',
  'App/Sources/Tatwo2/Facade/HandsGatewayIntegration.swift', 'tests/w183-gateway.test.mjs'];

test('T14 程式與測試不寫死網域、主機名：用公開掃描器實掃（私人清單在就一起比「類別 | 正規式」，不在就跑通用規則）', () => {
  const root = shortRoot('w183p-');
  try {
    for (const file of W183_FILES) {
      fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
      fs.copyFileSync(path.join(repo, file), path.join(root, file));
      assert.doesNotMatch(read(file), /\.trycloudflare\.com/i, file);
    }
    const scan = () => spawnSync(process.execPath, [path.join(repo, 'scripts/public-safety-scan.mjs'), root], { encoding: 'utf8' });
    const clean = scan();
    assert.equal(clean.status, 0, clean.stderr);
    // 證明掃描器真的掃了這棵樹：放一個私人網段位址就要失敗。
    fs.appendFileSync(path.join(root, W183_FILES[0]), `\n// ${[192, 168, 7, 9].join('.')}\n`);
    assert.equal(scan().status, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

// ---------- Seatbelt 實跑（T8、T13；v3 V8 的關口規則） ----------
function nodeRoot(real) {
  for (const prefix of ['/opt/homebrew', '/usr/local']) if (real.startsWith(prefix + '/')) return prefix; // Homebrew 的 Node 會載入 opt/ 底下的程式庫
  return path.dirname(real);
}
function ancestors(paths) {
  const out = new Set();
  for (const item of paths) {
    let current = path.dirname(item);
    while (current !== '/' && current !== '.') { out.add(current); current = path.dirname(current); }
  }
  return [...out];
}
function gatewaySandboxArgs({ programDir, layout, osSocket }) {
  const nodeBin = fs.realpathSync(process.execPath);
  const params = {
    NODE_BIN: nodeBin, NODE_ROOT: nodeRoot(nodeBin), PROGRAM_DIR: programDir, CONFIG: layout.configFile, SOCKET: layout.socketPath, OS_SOCKET: osSocket,
  };
  const anc = ancestors([nodeBin, params.NODE_ROOT + '/x', programDir + '/x', params.CONFIG, params.SOCKET, osSocket]);
  assert.ok(anc.length <= 24, `上層資料夾太多：${anc.length}`);
  const args = ['-p', read('Engines/chatgpt-hands/gateway.sb')];
  for (const [key, value] of Object.entries(params)) args.push('-D', `${key}=${value}`);
  for (let i = 0; i < 24; i += 1) args.push('-D', `ANC_${i}=${anc[i] ?? '/'}`);
  return { args, nodeBin };
}

const PROBE = `
import net from 'node:net'; import fs from 'node:fs'; import cp from 'node:child_process'; import dns from 'node:dns';
const [targets, other, allowed] = [JSON.parse(process.argv[2]), process.argv[3], process.argv[4]];
const out = {};
for (const [key, file] of Object.entries(targets.read)) { try { fs.readFileSync(file); out[key] = 'READ'; } catch (e) { out[key] = e.code; } }
for (const [key, file] of Object.entries(targets.write)) { try { fs.writeFileSync(file, 'x'); out[key] = 'WROTE'; } catch (e) { out[key] = e.code; } }
try { fs.readdirSync(targets.home); out.home = 'LISTED'; } catch (e) { out.home = e.code; }
try { out.spawn = cp.spawnSync('/bin/echo', ['x']).error ? 'EPERM' : 'RAN'; } catch (e) { out.spawn = e.code; }
const connect = opts => new Promise(r => { const s = net.createConnection(opts); s.on('connect', () => { s.destroy(); r('CONNECTED'); }); s.on('error', e => r(e.code)); setTimeout(() => r('TIMEOUT'), 3000); });
out.other = await connect({ path: other });
out.allowed = await connect({ path: allowed });
out.tcp = await connect({ host: '127.0.0.1', port: Number(process.env.PROBE_PORT) });
out.dns = await new Promise(r => dns.lookup('example.com', e => r(e ? 'FAILED' : 'RESOLVED')));
console.log(JSON.stringify(out));
`;

function sandboxAvailable() {
  const probe = spawnSync('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)', '/usr/bin/true'], { encoding: 'utf8' });
  return probe.status === 0;
}

test('T8／v3 V8 關口 Seatbelt 實跑：關口照常服務、叫得到 os.sock；讀不到 App 設定與 OAuth 狀態、通道 token、cf.yml、~/.ssh 替身；除了自己的 socket 哪裡都寫不了；連不到其他 socket、不能對外連線、不能開程式', { timeout: 60_000 }, async () => {
  assert.ok(sandboxAvailable(), 'sandbox-exec 不能用（在別的沙盒裡跑測試？）——不跳過，請在一般環境跑');
  const root = shortRoot('w183s-');
  const tcp = net.createServer(c => c.end()).listen(0, '127.0.0.1');
  const servers = [tcp];
  try {
    const hands = path.join(root, 'h');
    const layout = handsLayout(hands);
    fs.mkdirSync(path.join(hands, 'app'), { mode: 0o700 });
    fs.mkdirSync(path.join(hands, 'cf-home'), { mode: 0o700 });
    const secrets = {
      settings: path.join(hands, 'app', 'settings.json'), oauth: path.join(hands, 'app', 'auth.json'),
      tunnelToken: path.join(hands, 'cf-home', '.tunnel-token-canary'), cfConfig: path.join(hands, 'cf.yml'),
    };
    for (const [key, file] of Object.entries(secrets)) fs.writeFileSync(file, `${key}-CANARY`, { mode: 0o600 });
    const fakeHome = path.join(root, 'home');
    fs.mkdirSync(path.join(fakeHome, '.ssh'), { recursive: true });
    fs.writeFileSync(path.join(fakeHome, '.ssh', 'id_ed25519'), 'SSH-CANARY');
    const osSocket = path.join(root, 'o.sock');
    const app = await fakeApp(osSocket);
    servers.push(app.server);
    const other = net.createServer(c => c.end()).listen(path.join(root, 'x.sock'));
    servers.push(other);
    writeConfig(layout);
    await new Promise(resolve => tcp.once('listening', resolve).listening && resolve());
    const programDir = fs.realpathSync(path.join(repo, 'Engines/chatgpt-hands'));
    const { args, nodeBin } = gatewaySandboxArgs({ programDir, layout, osSocket });

    // 1) 真的關口在 Seatbelt 裡（跟 App 一樣：sandbox-exec 直接開 gateway.mjs，沒有 supervisor）：起得來、服務得到、叫得到假 os.sock。
    const child = spawn('/usr/bin/sandbox-exec', [...args, nodeBin, path.join(programDir, 'gateway.mjs'), layout.configFile],
      { cwd: layout.socketDir, env: { PATH: '/usr/bin:/bin', HOME: layout.gatewayDir, TATWO2_OS_SOCKET: osSocket }, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const deadline = Date.now() + 15_000;
    while (!stdout.includes('"ready"') && Date.now() < deadline && child.exitCode === null) await new Promise(r => setTimeout(r, 100));
    assert.match(stdout, /"ev":"ready"/, `關口在沙盒裡起不來：${stdout} ${stderr.slice(0, 400)}`);
    assert.equal((await request(layout.socketPath, { url: '/.well-known/oauth-authorization-server' })).status, 200);
    assert.equal((await request(layout.socketPath, { url: '/.well-known/oauth-authorization-server', headers: { 'cf-connecting-ip': OTHER_IP } })).status, 403);
    const register = await request(layout.socketPath, { method: 'POST', url: '/register', body: JSON.stringify({ redirect_uris: [REDIRECT] }), headers: jsonHeaders });
    assert.equal(register.status, 201, '沙盒裡連得到 os.sock');
    for (let i = 0; i < 20 && !stdout.includes('"r":"register"'); i += 1) await new Promise(r => setTimeout(r, 100));   // 回應送出後才記
    assert.match(stdout, /"ev":"req","m":"POST","r":"register","s":201/, '日誌走 stdout');
    child.stdin.end(); // App 關掉 stdin＝收
    const code = await new Promise(resolve => child.once('exit', resolve));
    assert.equal(code, 0, stderr);
    assert.ok(!fs.existsSync(layout.socketPath), '收掉時清掉自己的 socket');
    assert.deepEqual(fs.readdirSync(layout.socketDir), [], '沒有留下任何檔案');

    // 2) 同一份規則下的探針：證明拿不到秘密、除了自己的 socket 哪裡都寫不了、碰不到其他 socket、沒有網路、開不了程式。
    const probeDir = path.join(root, 'probe');
    fs.mkdirSync(probeDir);
    fs.writeFileSync(path.join(probeDir, 'probe.mjs'), PROBE);
    const probeArgs = gatewaySandboxArgs({ programDir: probeDir, layout, osSocket }).args;
    const targets = {
      read: { ...secrets, ssh: path.join(fakeHome, '.ssh', 'id_ed25519'), config: layout.configFile },
      write: { socketDir: path.join(layout.socketDir, 'other'), gatewayDir: path.join(layout.gatewayDir, 'x'), configWrite: layout.configFile, tmp: '/private/tmp/w183-probe-x' },
      home: fakeHome,
    };
    const probe = spawnSync('/usr/bin/sandbox-exec', [...probeArgs, nodeBin, path.join(probeDir, 'probe.mjs'), JSON.stringify(targets), path.join(root, 'x.sock'), osSocket],
      { cwd: layout.socketDir, encoding: 'utf8', env: { PATH: '/usr/bin:/bin', PROBE_PORT: String(tcp.address().port) }, timeout: 30_000 });
    const result = JSON.parse(probe.stdout.trim().split('\n').at(-1));
    assert.deepEqual(result, {
      settings: 'EPERM', oauth: 'EPERM', tunnelToken: 'EPERM', cfConfig: 'EPERM', ssh: 'EPERM', config: 'READ',
      socketDir: 'EPERM', gatewayDir: 'EPERM', configWrite: 'EPERM', tmp: 'EPERM', home: 'EPERM', spawn: 'EPERM', other: 'EPERM', allowed: 'CONNECTED', tcp: 'EPERM', dns: 'FAILED',
    }, probe.stderr);
    assert.equal(result.config, 'READ');
    assert.ok(!probe.stdout.includes('CANARY'));
  } finally {
    for (const server of servers) server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('T8／T13 cloudflared Seatbelt 實跑：讀不到家目錄（含 .cloudflared）與手腳資料夾、除了 cf-home 哪裡都寫不了（工具鏈、/tmp）、只連得到關口的 socket、本機 TCP 服務一律連不到、內網與本機網卡的 443 連不到、只開 Cloudflare 用的埠、開不了其他程式', { timeout: 60_000 }, async () => {
  assert.ok(sandboxAvailable(), 'sandbox-exec 不能用');
  const root = shortRoot('w183f-');
  const servers = [];
  try {
    // 本機 TCP 服務（扮演 n8n、Ollama、資料庫、除錯埠）：綁 0.0.0.0，127.0.0.1／0.0.0.0 都連得到。
    const local = net.createServer(c => c.end()).listen(0, '0.0.0.0');
    servers.push(local);
    await new Promise(resolve => local.once('listening', resolve).listening && resolve());
    const home = path.join(root, 'home');
    const hands = path.join(home, 'Library', 'Application Support', 'TATWO OS Hands');
    const layout = handsLayout(hands);
    const cfHome = path.join(hands, 'cf-home');
    fs.mkdirSync(cfHome, { recursive: true });
    fs.mkdirSync(path.join(hands, 'app'));
    fs.mkdirSync(path.join(home, '.cloudflared'));
    fs.writeFileSync(path.join(home, '.cloudflared', 'cert.pem'), 'CF-CANARY');
    const config = path.join(hands, 'cf.yml');
    fs.writeFileSync(config, 'ingress:\n  - service: http_status:404\n');
    fs.writeFileSync(path.join(hands, 'app', 'settings.json'), '{"secret":"SETTINGS-CANARY"}');
    writeConfig(layout);
    // 家目錄外、使用者自己擁有的執行檔資料夾（扮演 Homebrew 的 bin／Cellar）：被打穿的 cloudflared 不能改寫。
    const toolchain = path.join(root, 'toolchain', 'bin');
    fs.mkdirSync(toolchain, { recursive: true });
    fs.writeFileSync(path.join(toolchain, 'git'), '#!/bin/sh\necho real\n', { mode: 0o755 });
    // 內網（NAS、路由器管理頁）與本機網卡位址的 443：Seatbelt 分不出網段，所以整個 443 不開。位址用 join 組，免得隱私掃描器誤判。
    const lan = { lan10: [10, 0, 0, 1].join('.'), lan172: [172, 16, 0, 1].join('.'), lan192: [192, 168, 1, 1].join('.'), ula: 'fd00::1' };
    const localIP = Object.values(os.networkInterfaces()).flat().find(item => item && item.family === 'IPv4' && !item.internal)?.address;
    if (localIP) lan.localIface = localIP;
    const gwSocket = layout.socketPath;
    servers.push(net.createServer(c => c.end()).listen(gwSocket));
    servers.push(net.createServer(c => c.end()).listen(path.join(root, 'o.sock')));
    await new Promise(r => setTimeout(r, 100));
    const nodeBin = fs.realpathSync(process.execPath);
    const probeDir = path.join(root, 'probe');
    fs.mkdirSync(probeDir);
    fs.writeFileSync(path.join(probeDir, 'probe.mjs'), `
import net from 'node:net'; import fs from 'node:fs'; import cp from 'node:child_process'; import dgram from 'node:dgram';
const out = {};
for (const [k, f] of Object.entries({ cert: process.argv[2], settings: process.argv[3], config: process.argv[4], gatewayConfig: process.argv[9] })) { try { fs.readFileSync(f); out[k] = 'READ'; } catch (e) { out[k] = e.code; } }
try { fs.writeFileSync(process.argv[5] + '/state', 'x'); out.cfhome = 'WROTE'; } catch (e) { out.cfhome = e.code; }
try { out.spawn = cp.spawnSync('/bin/echo', ['x']).error ? 'EPERM' : 'RAN'; } catch (e) { out.spawn = e.code; }
const connect = p => new Promise(r => { const s = net.createConnection({ path: p }); s.on('connect', () => { s.destroy(); r('CONNECTED'); }); s.on('error', e => r(e.code)); });
const tcp = (host, port) => new Promise(r => { const s = net.createConnection({ host, port }); const t = setTimeout(() => { s.destroy(); r('TIMEOUT'); }, 1500); s.on('connect', () => { clearTimeout(t); s.destroy(); r('CONNECTED'); }); s.on('error', e => { clearTimeout(t); r(e.code); }); });
const udp = (host, port) => new Promise(r => { const s = dgram.createSocket(host.includes(':') ? 'udp6' : 'udp4'); s.on('error', e => { s.close(); r(e.code); }); s.send(Buffer.from('x'), port, host, e => { s.close(); r(e ? e.code : 'SENT'); }); });
out.gateway = await connect(process.argv[6]); out.os = await connect(process.argv[7]);
const port = Number(process.argv[8]);
out.lo4 = await tcp('127.0.0.1', port); out.lo6 = await tcp('::1', port); out.any = await tcp('0.0.0.0', port);
out.lo443 = await tcp('127.0.0.1', 443); out.lanService = await tcp('192.0.2.1', 5678); out.loUdp = await udp('127.0.0.1', 9999);
const edge = await tcp('192.0.2.1', 7844); out.edgeTcp = edge === 'EPERM' ? 'EPERM' : 'ALLOWED';
const edgeUdp = await udp('192.0.2.1', 7844); out.edgeUdp = edgeUdp === 'EPERM' ? 'EPERM' : 'ALLOWED';
const https = await tcp('192.0.2.1', 443); out.https = https === 'EPERM' ? 'EPERM' : 'ALLOWED';
for (const [k, host] of Object.entries(JSON.parse(process.argv[11]))) { const r = await tcp(host, 443); out['443_' + k] = r === 'EPERM' ? 'EPERM' : 'ALLOWED'; }
for (const [k, f] of Object.entries({ toolchain: process.argv[10] + '/git', toolchainNew: process.argv[10] + '/cloudflared', tmp: '/private/tmp/w183-cf-' + process.pid })) {
  try { fs.writeFileSync(f, 'x'); out['write_' + k] = 'WROTE'; } catch (e) { out['write_' + k] = e.code; }
}
console.log(JSON.stringify(out));`);
    // 用 Node 扮演 cloudflared（CF_BIN）：同一份規則，證明規則本身擋得住。Node 本身放在家目錄替身外面。
    const args = ['-p', read('Engines/chatgpt-hands/cloudflared.sb'), '-D', `CF_BIN=${nodeBin}`, '-D', `CF_HOME=${cfHome}`,
      '-D', `CF_CONFIG=${config}`, '-D', `GW_SOCKET=${gwSocket}`, '-D', `USER_HOME=${home}`, '-D', `HANDS_ROOT=${hands}`];
    const probe = spawnSync('/usr/bin/sandbox-exec', [...args, nodeBin, path.join(probeDir, 'probe.mjs'),
      path.join(home, '.cloudflared', 'cert.pem'), path.join(hands, 'app', 'settings.json'), config, cfHome, gwSocket, path.join(root, 'o.sock'),
      String(local.address().port), layout.configFile, toolchain, JSON.stringify(lan)],
    { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', HOME: cfHome }, timeout: 30_000 });
    const result = JSON.parse(probe.stdout.trim().split('\n').at(-1));
    assert.deepEqual(result, {
      cert: 'EPERM', settings: 'EPERM', config: 'READ', gatewayConfig: 'EPERM', cfhome: 'WROTE', spawn: 'EPERM', gateway: 'CONNECTED', os: 'EPERM',
      lo4: 'EPERM', lo6: 'EPERM', any: 'EPERM', lo443: 'EPERM', lanService: 'EPERM', loUdp: 'EPERM',
      edgeTcp: 'ALLOWED', edgeUdp: 'ALLOWED', https: 'EPERM',
      ...Object.fromEntries(Object.keys(lan).map(key => ['443_' + key, 'EPERM'])),
      write_toolchain: 'EPERM', write_toolchainNew: 'EPERM', write_tmp: 'EPERM',
    }, probe.stderr);
    assert.equal(fs.readFileSync(path.join(toolchain, 'git'), 'utf8'), '#!/bin/sh\necho real\n', '工具鏈的執行檔沒被改');
    assert.ok(!fs.existsSync(path.join(toolchain, 'cloudflared')));
    // 同一個本機服務，沙盒外連得到（證明上面的 EPERM 是規則擋的，不是服務不在）。
    assert.equal(await new Promise(r => { const c = net.createConnection({ host: '127.0.0.1', port: local.address().port }); c.on('connect', () => { c.destroy(); r('CONNECTED'); }); c.on('error', e => r(e.code)); }), 'CONNECTED');
    // 規則裡擋掉的系統服務（剪貼簿、畫面、TCC、Apple Event）寫在規則文字裡（Node 探不到 mach 服務，這裡只檢查規則本身）。
    const profile = read('Engines/chatgpt-hands/cloudflared.sb');
    for (const needle of ['(deny appleevent-send)', '(global-name-prefix "com.apple.pasteboard")', '(global-name-prefix "com.apple.windowserver")',
      '(global-name-prefix "com.apple.tccd")', '(deny network-outbound (remote ip "localhost:*"))', '(subpath (param "HANDS_ROOT"))', '(deny file-write*)']) assert.ok(profile.includes(needle), needle);
    assert.doesNotMatch(profile.replace(/;;.*$/gm, ''), /\*:443/, '規則裡沒有開 443');
  } finally {
    for (const server of servers) server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

const SYSCTL_PROBE = String.raw`
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/sysctl.h>
static const char *name_read(const char *name) { char buf[256]; size_t size = sizeof(buf); return sysctlbyname(name, buf, &size, NULL, 0) == 0 ? "OK" : (errno == EPERM ? "EPERM" : "FAILED"); }
int main(int argc, char **argv) {
  int pid = atoi(argv[1]); const char *needle = argv[2];
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t size = 0; const char *procargs = "FAILED";
  if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) procargs = errno == EPERM ? "EPERM" : "FAILED";
  else { char *buf = malloc(size); if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) procargs = errno == EPERM ? "EPERM" : "FAILED";
    else { procargs = "NOTFOUND"; for (size_t i = 0; i + strlen(needle) <= size; i++) if (!memcmp(buf + i, needle, strlen(needle))) { procargs = "READ"; break; } } }
  int all[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}; size = 0;
  const char *procall = sysctl(all, 4, NULL, &size, NULL, 0) == 0 ? "OK" : (errno == EPERM ? "EPERM" : "FAILED");
  printf("{\"procargs\":\"%s\",\"procall\":\"%s\",\"hostname\":\"%s\",\"bootargs\":\"%s\",\"osrelease\":\"%s\",\"memsize\":\"%s\"}\n",
    procargs, procall, name_read("kern.hostname"), name_read("kern.bootargs"), name_read("kern.osrelease"), name_read("hw.memsize"));
  return 0;
}
`;

test('審查 R2b 關口 Seatbelt 的 sysctl（原生探針實跑）：只開 Node 需要的；行程表、開機參數讀不到（主機名稱 uname 要用，只好開）；KERN_PROCARGS2（別的行程的環境變數）Seatbelt 擋不住＝殘餘，照實記錄', { timeout: 60_000 }, async t => {
  assert.ok(sandboxAvailable(), 'sandbox-exec 不能用');
  const cc = spawnSync('/usr/bin/xcrun', ['--find', 'cc'], { encoding: 'utf8' });
  assert.equal(cc.status, 0, '找不到 C 編譯器（xcrun cc）——不跳過，請在裝了 Xcode 工具的環境跑');
  const root = shortRoot('w183n-');
  let canary;
  try {
    const layout = handsLayout(path.join(root, 'h'));
    const osSocket = path.join(root, 'o.sock');
    writeConfig(layout);
    const probeDir = path.join(root, 'probe');
    fs.mkdirSync(probeDir);
    fs.writeFileSync(path.join(probeDir, 'probe.c'), SYSCTL_PROBE);
    // 經 xcrun 編（它會帶上 SDK 的標頭路徑）。
    const built = spawnSync('/usr/bin/xcrun', ['cc', '-O0', '-o', path.join(probeDir, 'probe'), path.join(probeDir, 'probe.c')], { encoding: 'utf8' });
    assert.equal(built.status, 0, built.stderr);
    // 扮演「同一個使用者的其他程式，環境裡有秘密」：非系統程式（Node）＋canary 環境變數。
    canary = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1 << 30)'], { env: { PATH: '/usr/bin:/bin', W183_ENV_CANARY: 'env-CANARY-secret' }, stdio: 'ignore' });
    await new Promise(resolve => setTimeout(resolve, 300));
    const probeBin = fs.realpathSync(path.join(probeDir, 'probe'));
    // 同一份 gateway.sb，只是 NODE_BIN 換成探針（規則只准 exec NODE_BIN）。
    const params = { NODE_BIN: probeBin, NODE_ROOT: path.dirname(probeBin), PROGRAM_DIR: probeDir, CONFIG: layout.configFile, SOCKET: layout.socketPath, OS_SOCKET: osSocket };
    const anc = ancestors([probeBin, probeDir + '/x', params.CONFIG, params.SOCKET, osSocket]);
    const args = ['-p', read('Engines/chatgpt-hands/gateway.sb')];
    for (const [key, value] of Object.entries(params)) args.push('-D', `${key}=${value}`);
    for (let i = 0; i < 24; i += 1) args.push('-D', `ANC_${i}=${anc[i] ?? '/'}`);
    const outside = JSON.parse(spawnSync(probeBin, [String(canary.pid), 'env-CANARY-secret'], { encoding: 'utf8' }).stdout);
    const inside = JSON.parse(spawnSync('/usr/bin/sandbox-exec', [...args, probeBin, String(canary.pid), 'env-CANARY-secret'], { encoding: 'utf8', cwd: layout.socketDir }).stdout);
    assert.equal(outside.procall, 'OK', '沙盒外讀得到行程表（證明探針本身有效）');
    assert.equal(outside.hostname, 'OK');
    assert.deepEqual({ procall: inside.procall, bootargs: inside.bootargs, osrelease: inside.osrelease, memsize: inside.memsize, hostname: inside.hostname },
      { procall: 'EPERM', bootargs: 'EPERM', osrelease: 'OK', memsize: 'OK', hostname: 'OK' });
    // 殘餘（不宣稱已隔離）：沙盒外讀得到 canary 的環境，就記下沙盒裡是不是也讀得到。實測 macOS 27 讀得到——秘密不放環境變數。
    t.diagnostic(`KERN_PROCARGS2（別的同 UID 非系統行程的環境）：沙盒外 ${outside.procargs}、關口沙盒裡 ${inside.procargs}`);
    assert.ok(['READ', 'NOTFOUND', 'EPERM', 'FAILED'].includes(inside.procargs));
  } finally {
    canary?.kill('SIGKILL');
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('T10／T11 兄弟行程收尾：App 被強制結束（SIGKILL）→ 關口（stdin EOF）與 cloudflared（看門程式）兩組都自己收、token 檔刪掉；cloudflared 停了看門程式也收', { timeout: 60_000 }, async () => {
  const root = shortRoot('w183w-');
  const servers = [];
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; } };
  const until = async (ms, fn) => { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await new Promise(r => setTimeout(r, 100)); } return fn(); };
  try {
    const layout = handsLayout(path.join(root, 'h'));
    const cfHome = path.join(layout.root, 'cf-home');
    fs.mkdirSync(cfHome, { recursive: true, mode: 0o700 });
    writeConfig(layout);
    const osSocket = path.join(root, 'o.sock');
    servers.push((await fakeApp(osSocket)).server);
    const guard = path.join(repo, 'Engines/chatgpt-hands/tunnel-guard.sh');
    const fake = `require('fs').writeFileSync(process.env.PIDFILE, String(process.pid)); setInterval(() => {}, 1 << 30)`;
    // 假 App：照 App 的方式開兩個兄弟（各自一個行程群組、stdin 接 pipe），然後被 SIGKILL。
    const appScript = path.join(root, 'app.mjs');
    fs.writeFileSync(appScript, `
import { spawn } from 'node:child_process'; import fs from 'node:fs';
const [gateway, configFile, osSocket, guard, tokenFile, pidfile, out, fake] = process.argv.slice(2);
const gw = spawn(process.execPath, [gateway, configFile], { env: { PATH: '/usr/bin:/bin', TATWO2_OS_SOCKET: osSocket }, stdio: ['pipe', 'ignore', 'ignore'], detached: true });
const tg = spawn('/bin/sh', ['-c', fs.readFileSync(guard, 'utf8'), 'chatgpt-hands/tunnel-guard', tokenFile, process.execPath, '-e', fake], { env: { PATH: '/usr/bin:/bin', PIDFILE: pidfile }, stdio: ['pipe', 'ignore', 'ignore'], detached: true });
fs.writeFileSync(out, JSON.stringify({ gateway: gw.pid, guard: tg.pid }));
setInterval(() => {}, 1 << 30);`);
    const run = async ({ killApp }) => {
      const tokenFile = path.join(cfHome, `.tunnel-token-${randomBytes(4).toString('hex')}`);
      fs.writeFileSync(tokenFile, 'tunnel-CANARY', { mode: 0o600 });
      const pidfile = path.join(root, `cf-${randomBytes(4).toString('hex')}.pid`);
      const out = path.join(root, `pids-${randomBytes(4).toString('hex')}.json`);
      const app = spawn(process.execPath, [appScript, path.join(repo, 'Engines/chatgpt-hands/gateway.mjs'), layout.configFile, osSocket, guard, tokenFile, pidfile, out, fake], { stdio: 'ignore' });
      assert.ok(await until(10_000, () => fs.existsSync(out) && fs.existsSync(pidfile) && fs.existsSync(layout.socketPath)), '兩組都起來');
      const pids = { ...JSON.parse(fs.readFileSync(out, 'utf8')), cloudflared: Number(fs.readFileSync(pidfile, 'utf8')) };
      assert.ok(Object.values(pids).every(alive));
      if (killApp) app.kill('SIGKILL'); else process.kill(pids.cloudflared, 'SIGKILL');
      const guardDone = await until(8_000, () => !alive(pids.guard) && !alive(pids.cloudflared));
      assert.ok(guardDone, `看門程式與 cloudflared 都結束 ${JSON.stringify(pids)}`);
      assert.ok(!fs.existsSync(tokenFile), 'token 檔被看門程式刪掉');
      if (killApp) {
        assert.ok(await until(8_000, () => !alive(pids.gateway)), '關口 stdin 收到 EOF 就收');
        assert.ok(await until(3_000, () => !fs.existsSync(layout.socketPath)), '關口清掉自己的 socket');
      } else {
        assert.ok(alive(pids.gateway), '只停 cloudflared 時關口由 App 收（這裡 App 還活著，所以關口還在）');
        app.kill('SIGKILL');
        assert.ok(await until(8_000, () => !alive(pids.gateway)));
      }
    };
    await run({ killApp: true });
    await run({ killApp: false });
  } finally {
    for (const server of servers) server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
test('W185 permission restoration precedes failure latch, transient failures back off without clearing safety', () => {
  const source = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/ChatGPTHandsService.swift', import.meta.url), 'utf8');
  const evaluate = source.slice(source.indexOf('private func evaluate()'), source.indexOf('private func publish('));
  assert.ok(evaluate.indexOf('lastHostConfirmed == false, confirmed') < evaluate.indexOf('if let latched = latchedFailure'));
  assert.match(evaluate, /resetFailures\(\)/);
  assert.match(evaluate, /dependencies\.now\(\) < retryAt/);
  assert.match(source, /min\(300\.0, 30\.0 \* pow/);
  assert.match(source, /讀不到通道憑證.*retryable: true/);
  assert.match(source, /dependencies\.prepareWorkspace\(\).*retryable: true/);
  const reset = source.slice(source.indexOf('private func resetFailures()'), source.indexOf('private func lifecycle('));
  assert.doesNotMatch(reset, /safetyLatched =|clearSafetyStop\(/);
  assert.match(source, /restart reason=\\\(restartReason\) result=\\\(result\)/);
});
