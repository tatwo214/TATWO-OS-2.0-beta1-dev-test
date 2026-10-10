import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import http from 'node:http';
import test from 'node:test';
import { createGateway, SCOPES } from '../Engines/chatgpt-hands/gateway.mjs';

const host = 'sandbox.example.com';
const parent = join(homedir(), 'tatwo-build/tmp');
mkdirSync(parent, { recursive: true });
const osTools = [...readFileSync('Engines/os-mcp/server.mjs', 'utf8').matchAll(/^\s*\['([a-z_]+)'/gm)].map(m => m[1]);

for (const ordinary of [false, true]) test(ordinary ? 'W338 ordinary Coder dispatches sandbox with group disabled, then receives, applies and rejects same-thread proposals' : 'synthetic sandbox uses production Hands OAuth, snapshots and proposal apply; every connector and OS tool is refused', () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? resolve('.build/debug/Tatwo2');
  assert.ok(existsSync(binary), 'run verify.sh first');
  const root = mkdtempSync(join(parent, 'w264-node-'));
  try {
    for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs']) mkdirSync(join(root, dir), { recursive: true });
    const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO_STAGING_SCRATCH_HOME: join(root, 'home'), TATWO_STAGING_ROOT: root,
      TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'engines'),
      CODEX_HOME: join(root, 'engines/codex'), TATWO2_CODEX_SOURCE_HOME: join(root, 'engines/codex'),
      CLAUDE_CONFIG_DIR: join(root, 'engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: join(root, 'engines/claude'),
      TATWO2_OS_SOCKET: join(root, 'o.sock'), TATWO2_BROWSER_SOCKET: join(root, 'b.sock'),
      TATWO2_OS_ROOT: join(root, 'os'), TATWO2_DOCS_ROOT: join(root, 'docs'),
      TATWO2_OS_UPSTREAM_PATH: join(root, 'os/os-upstream.md'), TATWO2_SKILLET_PATH: join(root, 'os/skillet.md'),
      TATWO2_SELFTEST: ordinary ? 'w338sbxdispatch' : 'w264sandboxlane', TATWO2_SELFTEST_ARTIFACTS: process.env.TATWO_W264_EVIDENCE_DIR ?? root, TATWO_W264_FORBIDDEN_TOOLS: JSON.stringify(osTools) };
    delete env.SSH_AUTH_SOCK;
    const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024 });
    const output = run.stdout + run.stderr;
    if (process.env.TATWO_W264_EVIDENCE_DIR) { mkdirSync(process.env.TATWO_W264_EVIDENCE_DIR, { recursive: true }); writeFileSync(join(process.env.TATWO_W264_EVIDENCE_DIR, "w264-client.log"), output); }
    assert.equal(run.status, 0, output);
    for (const tool of osTools) assert.ok(output.includes(`PASS deny-${tool}\n`), tool);
    for (const label of ['expired-first-fetches-second', 'only-expired-is-empty-queue', 'expired-removal-persisted',
      'changed-project-skipped', 'missing-thread-is-empty-queue', 'trading-queued-job-removed',
      'stalled-running-fails-and-releases', 'stalled-failure-persists', 'running-within-three-intervals-kept',
      'clock-ahead-three-seconds-accepted', 'clock-skew-replay-denied', 'clock-ahead-six-seconds-denied',
      'sandbox-catalog-only-three', 'snapshot-no-secrets-or-host-path', 'project-unchanged-before-apply',
      'review-card-visible-with-artifact', 'user-apply-writes-project', 'trading-alias-snapshot-denied', 'replay-denied',
      'expired-request-denied', 'forged-token-denied', 'forged-lease-denied', 'cross-device-post-denied',
      'sandbox-cannot-request-full-scope', 'revocation-aborts-running-job', 'restart-preserves-abort', 'expired-token-denied', 'sandbox-register-closed-window-denied',
      'sandbox-auth-flood-preserves-main-check', 'sandbox-auth-flood-preserves-main-token-mcp',
      'heartbeat-does-not-rewrite-job-file', 'report-summary-bounded-full-report-file',
      'seventy-completed-jobs-release-slots-and-snapshots', 'revoked-review-needs-reconfirmation',
      'revoked-review-cannot-apply', 'abort-removes-job-snapshots', 'replayed-post-refused-before-git', 'expired-post-refused-before-git', 'fleet-role-change-revokes-sandbox-grant', 'legacy-sandbox-review-needs-reconfirmation']) {
      assert.ok(output.includes(`PASS ${label}`), label);
    }
    if (ordinary) for (const label of ['engine-dispatch-through-os-bridge', 'ordinary-no-group-or-chatgpt', 'ordinary-card-shows-sandbox-name', 'primary-roster-dispatch-allowed', 'enabled-group-does-not-enroll-sandbox-ledger', 'ordinary-same-thread-external-card', 'ordinary-send-keeps-native-route', 'ordinary-ledger-restores-without-tap', 'heartbeat-local-relative-time', 'heartbeat-visible-local-time-fable5', 'heartbeat-visible-local-time-aurora', 'app-dispatch-with-explicit-thread', 'ordinary-reject-keeps-project', 'non-primary-dispatch-denied', 'protected-folder-dispatch-denied', 'explicit-group-promotion-preserves-proposal']) assert.ok(output.includes(`PASS ${label}`), label);
    assert.match(output, /W264SANDBOXLANE SUMMARY failures=0 passed=\d+/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('Unix-socket MCP gateway advertises and forwards sandbox scope without granting full connector instructions', async () => {
  // HTTP over a Unix socket only: no TCP, DNS or account access.
  const root = mkdtempSync('/tmp/w264-gw-'), socket = join(root, 'g.sock'), config = join(root, 'config.json');
  const calls = [];
  writeFileSync(config, JSON.stringify({ socket_path: socket, public_host: host, allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }), { mode: 0o600 });
  const gateway = createGateway({ configFile: config, osCall: async (method, params) => {
    calls.push({ method, params });
    if (params.op === 'authorize_begin') return { transaction_id: 'tx_fixture', display_code: '2345', expires_at: new Date(Date.now() + 600000).toISOString() };
    if (params.op === 'check') return { ok: true, grant_id: 'g_' + 'a'.repeat(20), scope: params.access_token.startsWith('full') ? 'tatwo.hands' : 'sandbox', level: 0 };
    if (params.op === 'token') return { access_token: 'tatwoh_at_' + 'x'.repeat(40), refresh_token: 'tatwoh_rt_' + 'x'.repeat(40), scope: 'sandbox', expires_in: 3600 };
    if (params.op === 'register_client') return { client_id: 'client_fixture' };
    if (method === 'hands_tools') return { tools: ['sandbox_fetch_job', 'sandbox_post_result', 'sandbox_heartbeat'].map(name => ({ name, description: name, inputSchema: { type: 'object', properties: {} } })) };
    throw new Error('unexpected call');
  } });
  await new Promise(resolve => gateway.server.listen(socket, resolve));
  async function request(path, body, session, headers = {}) {
    return new Promise((resolve, reject) => {
      const req = http.request({ socketPath: socket, path, method: body ? 'POST' : 'GET', headers: {
        host, 'cf-connecting-ip': '203.0.113.10', ...(body ? { authorization: 'Bearer ' + 's'.repeat(40), 'content-type': 'application/json', accept: 'application/json' } : {}),
        ...(session ? { 'mcp-session-id': session } : {}), ...headers } }, res => {
        let text = ''; res.on('data', data => text += data); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }));
      });
      req.on('error', reject); req.end(typeof body === 'string' ? body : body ? JSON.stringify(body) : undefined);
    });
  }
  try {
    assert.deepEqual(SCOPES, ['tatwo.hands', 'sandbox']);
    const metadata = await request('/.well-known/oauth-authorization-server');
    assert.deepEqual(JSON.parse(metadata.text).scopes_supported, SCOPES);
    const query = new URLSearchParams({ response_type: 'code', client_id: 'client_fixture', redirect_uri: 'https://chat.example.com/connector/oauth/callback',
      code_challenge: 'x'.repeat(43), code_challenge_method: 'S256', state: 'state_fixture', scope: 'sandbox' });
    const authorize = await request('/authorize?' + query);
    assert.equal(authorize.status, 200, authorize.text);
    assert.equal(calls.find(c => c.params.op === 'authorize_begin')?.params.scope, 'sandbox');
    const mixed = await request('/authorize?' + new URLSearchParams({ ...Object.fromEntries(query), scope: 'sandbox tatwo.hands' }));
    assert.equal(mixed.status, 400);
    const outside = { 'cf-connecting-ip': '198.51.100.7' };
    const registered = await request('/sandbox/register', { redirect_uris: ['https://chat.example.com/connector/oauth/callback'], client_name: 'Synthetic sandbox' }, null, outside);
    assert.equal(registered.status, 201, registered.text);
    assert.equal(JSON.parse(registered.text).scope, "sandbox");
    assert.equal(calls.find(c => c.params.op === 'register_client')?.params.scope, 'sandbox');
    const exchanged = await request('/sandbox/token', new URLSearchParams({ grant_type: 'authorization_code', code: 'ac_' + 'c'.repeat(40), code_verifier: 'x'.repeat(43), client_id: 'client_fixture', redirect_uri: 'https://chat.example.com/connector/oauth/callback' }).toString(), null, { ...outside, 'content-type': 'application/x-www-form-urlencoded' });
    assert.equal(exchanged.status, 200, exchanged.text);
    assert.equal(calls.find(c => c.params.op === 'token')?.params.scope, 'sandbox');
    const deniedFull = await request('/mcp', { jsonrpc: '2.0', id: 0, method: 'initialize', params: {} }, null, { ...outside, authorization: 'Bearer full' + 's'.repeat(40) });
    assert.equal(deniedFull.status, 403, deniedFull.text);
    const init = await request('/mcp', { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }, null, outside);
    assert.equal(init.status, 200, init.text);
    assert.match(JSON.parse(init.text).result.instructions, /^Sandbox:/);
    const list = await request('/mcp', { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, init.headers['mcp-session-id']);
    assert.deepEqual(JSON.parse(list.text).result.tools.map(t => t.name), ['sandbox_fetch_job', 'sandbox_post_result', 'sandbox_heartbeat']);
  } finally { await new Promise(resolve => gateway.server.close(resolve)); rmSync(root, { recursive: true, force: true }); }
});
