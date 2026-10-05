import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createGateway } from '../Engines/chatgpt-hands/gateway.mjs';

// Only fixture files and an isolated UNIX socket; never contacts the live App.
async function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync('/tmp/w183clock-'));
  const file = path.join(root, 'config.json');
  const socket = path.join(root, 'gw.sock');
  const epoch = Date.now();
  let wall = epoch, elapsed = 0, revision = 0;
  const write = (overrides = {}) => {
    fs.writeFileSync(file, JSON.stringify({
      public_host: 'hands.example.com', allowed_ip_ranges: ['203.0.113.0/24'],
      ranges_fetched_at: new Date(epoch).toISOString(), ...overrides,
    }));
    const stamp = new Date(epoch + ++revision * 1000);
    fs.utimesSync(file, stamp, stamp);
  };
  write();
  const { server } = createGateway({
    configFile: file, osSocket: path.join(root, 'unused.sock'),
    now: () => wall, monotonicNow: () => elapsed,
    osCall: () => { throw new Error('fixture must not call the App'); },
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socket, resolve);
  });
  t.after(async () => {
    await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
    fs.rmSync(root, { recursive: true, force: true });
  });
  const request = (url = '/.well-known/oauth-authorization-server', method = 'GET') =>
    new Promise((resolve, reject) => {
      const req = http.request({
        socketPath: socket, path: url, method,
        headers: { host: 'hands.example.com', 'cf-connecting-ip': '203.0.113.10' },
      }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
      req.on('error', reject); req.end();
    });
  return { write, request, file, advance: ms => { elapsed += ms; },
    wall: ms => { wall = epoch + ms; } };
}

for (const wallOffset of [0, -250, -30_000]) {
  test(`gateway reload deadline survives wall-clock offset ${wallOffset}ms`, async t => {
    const f = await fixture(t);
    assert.equal(await f.request(), 200);
    f.write({ allowed_ip_ranges: [] });
    f.wall(wallOffset);
    f.advance(2001);
    for (const [url, method] of [
      ['/.well-known/oauth-authorization-server', 'GET'], ['/register', 'POST'],
      ['/token', 'POST'], ['/mcp', 'POST'], ['/authorize', 'GET'],
    ]) assert.equal(await f.request(url, method), 403, `${method} ${url}`);
    f.write();
    f.advance(2001);
    assert.equal(await f.request(), 200, 'valid replacement recovers without restart');
  });
}

test('gateway cache uses elapsed time but IP-list expiry still uses wall time', async t => {
  const f = await fixture(t);
  assert.equal(await f.request(), 200);
  f.wall(8 * 86400_000);
  assert.equal(await f.request(), 403, 'expired list is rejected even inside cache window');
  f.wall(0);
  assert.equal(await f.request(), 200);
  fs.unlinkSync(f.file);
  f.advance(2001);
  assert.equal(await f.request(), 403, 'missing config fails closed at reload deadline');
  f.write();
  f.advance(2001);
  assert.equal(await f.request(), 200);
});
