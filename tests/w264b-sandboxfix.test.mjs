import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import http from 'node:http';
import { createGateway, GatewayError } from '../Engines/chatgpt-hands/gateway.mjs';

test('sandbox floods cannot spend main MCP, registration, token, client or grant budgets', async () => {
  const root = mkdtempSync('/tmp/w264b-'), socket = join(root, 'g.sock'), configFile = join(root, 'config.json');
  const host = 'hands.example.com', access = 'tatwoh_at_' + 'x'.repeat(40), calls = [];
  let pairingOpen = false, clock = Date.now();
  writeFileSync(configFile, JSON.stringify({ socket_path: socket, public_host: host, allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }), { mode: 0o600 });
  const gateway = createGateway({ configFile, now: () => clock, limits: { rateKeys: 5, perIpPerMinute: 50, authPerIpPerMinute: 4,
    registerPerWindow: 3, tokenPerMinute: 3, tokenPerClientPerMinute: 3, mcpPerMinute: 3, perGrantPerMinute: 3 },
    osCall: async (method, params) => {
      calls.push({ method, params });
      if (params.op === 'register_client') {
        if (params.scope === 'sandbox' && !pairingOpen) throw new GatewayError('os_refused', 'pairing_window_closed');
        return { client_id: 'client_fixture' };
      }
      if (params.op === 'check') return params.access_token.startsWith('forged') ? { ok: false } :
        { ok: true, grant_id: 'g_' + 'a'.repeat(20), scope: params.access_token.startsWith('full') ? 'tatwo.hands' : 'sandbox' };
      if (params.op === 'token') return { access_token: access, refresh_token: 'tatwoh_rt_' + 'x'.repeat(40), scope: params.scope ?? 'tatwo.hands' };
      if (method === 'hands_call') throw new GatewayError('os_refused', params.access_token.startsWith('full') ? 'tool_not_allowed' : 'sandbox_tool_not_allowed');
      throw new Error('unexpected call');
    } });
  await new Promise(resolve => gateway.server.listen(socket, resolve));
  const register = { redirect_uris: ['https://chat.example.com/connector/oauth/callback'] };
  const token = new URLSearchParams({ grant_type: 'refresh_token', refresh_token: 'rt_' + 'x'.repeat(40), client_id: 'client_fixture' }).toString();
  async function request(path, body, ip = '198.51.100.7', bearer = 'sandbox' + 'x'.repeat(40), session) {
    return new Promise((resolve, reject) => {
      const req = http.request({ socketPath: socket, path, method: 'POST', headers: { host, 'cf-connecting-ip': ip,
        authorization: 'Bearer ' + bearer, 'content-type': typeof body === 'string' ? 'application/x-www-form-urlencoded' : 'application/json',
        ...(session ? { 'mcp-session-id': session } : {}) } }, res => {
        let text = ''; res.on('data', part => text += part); res.on('end', () => resolve({ status: res.statusCode, text, headers: res.headers }));
      });
      req.on('error', reject); req.end(typeof body === 'string' ? body : JSON.stringify(body));
    });
  }
  const initialize = { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} };
  try {
    assert.equal((await request('/sandbox/register', register)).status, 400, 'closed pairing refuses registration');
    pairingOpen = true;
    assert.equal((await request('/sandbox/register', register)).status, 201);
    for (let index = 0; index < 80; index++) {
      const ip = `198.51.100.${index % 30 + 1}`;
      await request('/sandbox/register', register, ip);
      await request('/sandbox/token', token, ip);
      await request('/mcp', initialize, ip, index % 2 ? 'forged' + 'x'.repeat(40) : undefined);
    }
    // The same client ID and grant ID were used by the flood. Table capacity also filled.
    assert.equal((await request('/register', register, '203.0.113.10')).status, 201);
    assert.equal((await request('/token', token, '203.0.113.10')).status, 200);
    const main = await request('/mcp', initialize, '203.0.113.10', 'full' + 'x'.repeat(40));
    assert.equal(main.status, 200, main.text);
    const result = await request('/mcp', { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'fixture', arguments: {} } }, '203.0.113.10', 'full' + 'x'.repeat(40), main.headers['mcp-session-id']);
    assert.equal(JSON.parse(result.text).result.content[0].text, 'tool not allowed');
    assert.ok(calls.some(c => c.params.op === 'register_client' && c.params.scope === 'sandbox'));
    assert.ok(calls.some(c => c.params.op === 'check' && c.params.access_token.startsWith('full')));
    clock += 60_001;
    const sandbox = await request('/mcp', initialize);
    assert.equal(sandbox.status, 200, sandbox.text);
    const sandboxLocked = await request('/mcp', { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'fixture', arguments: {} } }, undefined, undefined, sandbox.headers['mcp-session-id']);
    assert.equal(JSON.parse(sandboxLocked.text).result.content[0].text, '沙盒只能領工、交件、回報心跳。');
  } finally { await new Promise(resolve => gateway.server.close(resolve)); rmSync(root, { recursive: true, force: true }); }
});

