// Launched by isolated Swift acceptance; both HTTP and OS transport use Unix sockets.
import assert from 'node:assert/strict';
import { createConnection } from 'node:net';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createGateway } from '../../Engines/chatgpt-hands/gateway.mjs';

const root = process.argv[2], host = 'hands.example.com', socket = join(root, 'g.sock');
const config = join(root, 'config.json');
writeFileSync(config, JSON.stringify({ socket_path: socket, public_host: host, allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }), { mode: 0o600 });
const gateway = createGateway({ configFile: config, osSocket: join(root, 'o.sock') });
await new Promise(resolve => gateway.server.listen(socket, resolve));
const agent = resolve('Engines/sandbox-agent/sandbox-agent.py');
const home = join(root, 'client-home'); mkdirSync(home, { recursive: true });
const env = { PATH: process.env.PATH, HOME: home, LANG: 'en_US.UTF-8' };
async function run(action, extra = [], pairing = false) {
  const child = spawn('python3', [agent, action, '--socket', socket, ...extra], { env });
  let output = '';
  child.stdout.on('data', x => output += x); child.stderr.on('data', x => output += x);
  const poll = pairing ? setInterval(() => {
    const code = join(root, 'pairing-code');
    if (existsSync(code)) { child.stdin.end(readFileSync(code, 'utf8') + '\n'); clearInterval(poll); }
  }, 20) : null;
  const timer = setTimeout(() => child.kill('SIGKILL'), 40000);
  const status = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); });
  clearTimeout(timer); clearInterval(poll);
  writeFileSync(join(root, `python-${action}-${extra.includes('--once') ? 'once' : 'pair'}.log`), output);
  return { status, output };
}
try {
  const paired = await run('pair', ['--gateway', 'https://' + host, '--name', 'Dots fixture'], true);
  assert.equal(paired.status, 0, paired.output);
  writeFileSync(join(root, 'paired'), 'yes');
  // W339：權杖一小時就過期；先讓它過期，跑的時候要自己用 refresh token 換新（真關口＋真 HandsAuth）。
  const tokenFile = join(home, '.tatwo-sandbox/token.json');
  const expire = () => { const token = JSON.parse(readFileSync(tokenFile, 'utf8')); token.expires_at = 0; writeFileSync(tokenFile, JSON.stringify(token)); return token; };
  const before = expire();
  // A complete JSON line must be answered even while the peer keeps its write side open.
  await new Promise((resolve, reject) => {
    const peer = createConnection({ path: join(root, 'o.sock') });
    peer.setTimeout(2000, () => { peer.destroy(); reject(new Error('host waited for EOF')); });
    peer.on('error', reject);
    peer.on('connect', () => peer.write(JSON.stringify({ method: 'hands_auth', params: { op: 'check', access_token: before.access_token } }) + '\n'));
    let reply = '';
    peer.on('data', chunk => {
      reply += chunk;
      if (!reply.includes('\n')) return;
      try { assert.equal(JSON.parse(reply).result.ok, true); peer.destroy(); resolve(); }
      catch (error) { peer.destroy(); reject(error); }
    });
  });
  assert.ok(before.refresh_token && before.client_id, 'pairing keeps refresh token and client id');
  while (!existsSync(join(root, 'queued'))) await new Promise(resolve => setTimeout(resolve, 20));
  const result = await run('run', ['--runner', 'sh', '--once', '--interval', '1']);
  assert.equal(result.status, 0, result.output);
  const after = JSON.parse(readFileSync(tokenFile, 'utf8'));
  assert.ok(after.refresh_token !== before.refresh_token && after.access_token !== before.access_token && after.expires_at > Date.now() / 1000, 'refreshed and rotated');
  assert.match(result.output, /交件已送主設備審查/);
  writeFileSync(join(root, 'submitted'), 'yes');
  while (!existsSync(join(root, 'revoked'))) await new Promise(resolve => setTimeout(resolve, 20));
  expire();   // 撤銷後連 refresh token 也換不到新的
  const revoked = await run('run', ['--runner', 'sh', '--once']);
  assert.equal(revoked.status, 3, revoked.output);
  assert.match(revoked.output, /refused/);
  console.log('W335CLIENT PASS pair-heartbeat-fetch-run-post-real-proposal; revoked-stops');
} finally { await new Promise(resolve => gateway.server.close(resolve)); }
