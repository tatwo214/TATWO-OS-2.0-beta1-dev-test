import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

// W178 安全修正的驗收：配對（PAIRTEST）與 os.sock 呼叫者檢查（SECURITYTEST）。
// 這個 node 行程是 App 的父行程，不是 App 開出來的程式，正好扮演「同一台 Mac 上的其他程式」。
const binary = process.env.TATWO2_TEST_BINARY;

function fixture() {
  // UNIX socket 路徑有 104 位元組上限：放在短的暫存目錄。
  // 用解析過的真實路徑（/tmp 其實是 /private/tmp），staging 隔離檢查才對得上。
  const root = fs.realpathSync(fs.mkdtempSync(path.join(fs.existsSync('/tmp') ? '/tmp' : tmpdir(), 'w178-')));
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e', 'entry', 'docs']) fs.mkdirSync(at(name));
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'),
    TATWO2_LIVE_ROOT: at('l'), TATWO2_ENGINES_ROOT: at('e'),
    CODEX_HOME: at('e/codex'), TATWO2_CODEX_SOURCE_HOME: at('e/codex'),
    CLAUDE_CONFIG_DIR: at('e/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('e/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO_OS_ROOT: at('entry'), TATWO2_OS_ROOT: at('entry'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('docs/os-upstream.md'), TATWO2_SKILLET_PATH: at('entry/skillet.md'),
  };
  return { root, at, env };
}

function requireBinary() {
  assert.ok(binary && fs.existsSync(binary), 'Set TATWO2_TEST_BINARY to the current build; never skip.');
}

function rpc(socketPath, request, { closeWrite = true, timeout = 8000 } = {}) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const socket = net.createConnection(socketPath);
    let data = '';
    const timer = setTimeout(() => { socket.destroy(); reject(new Error(`rpc timeout ${request.method}`)); }, timeout);
    socket.setEncoding('utf8');
    socket.on('connect', () => {
      const line = JSON.stringify(request) + '\n';
      if (closeWrite) socket.end(line); else socket.write(line);
    });
    socket.on('data', chunk => {
      data += chunk;
      if (data.includes('\n')) socket.destroy();
    });
    socket.on('error', error => { clearTimeout(timer); reject(error); });
    socket.on('close', () => {
      clearTimeout(timer);
      try { resolve({ reply: JSON.parse(data.split('\n')[0]), ms: Date.now() - started }); }
      catch (error) { reject(new Error(`bad reply for ${request.method}: ${JSON.stringify(data)}`)); }
    });
  });
}

test('W178 pairing: code never crosses the network, MITM key swaps and injected ssh options are refused', { timeout: 120_000 }, () => {
  requireBinary();
  const { at, env } = fixture();
  const result = spawnSync(binary, [], {
    env: { ...env, TATWO2_PAIRTEST: '1' }, encoding: 'utf8', timeout: 100_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  fs.writeFileSync(at('pairtest.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /PAIRTEST ALL PASS/);
  assert.doesNotMatch(output, /PAIRTEST FAIL/);
  for (const label of ['不知道配對碼就換不進金鑰', '簽過之後換掉公鑰會被拒', '舊版明文配對碼被拒', '明文碼外洩後配對窗立刻關閉',
    '攻擊請求沒有新增任何授權', '主機回覆沒有配對碼驗證就不採信', '對方登入名夾帶 ssh 選項被擋', '掃到的主機金鑰跟對方證明的不同就停']) {
    assert.ok(output.includes('PAIRTEST PASS ' + label), label);
  }
});

test('W178 os.sock: other local programs only reach status and proposal methods; a silent peer cannot block the bridge', { timeout: 150_000 }, async () => {
  requireBinary();
  const { at, env } = fixture();
  const done = at('node-done');
  const child = spawn(binary, [], {
    env: { ...env, TATWO2_SECURITYTEST: '1', TATWO2_SECURITYTEST_DONE: done }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  const exited = once(child, 'exit');
  try {
    const readyBy = Date.now() + 60_000;
    while (!output.includes('SECURITYTEST SOCKET READY')) {
      if (child.exitCode !== null) assert.fail(`SECURITYTEST exited early:\n${output}`);
      if (Date.now() > readyBy) assert.fail(`socket never ready:\n${output}`);
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    const socketPath = env.TATWO2_OS_SOCKET;
    // 這個實例是 staging 隔離（沒有使用者資料），get_document 等唯讀空狀態方法依設計對外可讀；其餘照樣擋。
    for (const method of ['list_rooms', 'send_message', 'transcript', 'run_background', 'computer_observe',
      'cli_open', 'cli_send', 'whoami', 'select_thread', 'github_import_from_gh', 'app_terminate_for_update']) {
      const { reply } = await rpc(socketPath, { id: method, method, params: { callerThreadID: '00000000-0000-0000-0000-000000000001' } });
      assert.equal(reply.ok, false, method);
      assert.equal(reply.error, 'caller_not_trusted', `${method}: ${JSON.stringify(reply)}`);
    }
    const unsignedJob = await rpc(socketPath, { id: 'job', method: 'job_submit', params: {} });
    assert.equal(unsignedJob.reply.error, 'caller_not_trusted');
    const status = await rpc(socketPath, { id: 'status', method: 'device_status', params: {} });
    assert.notEqual(status.reply.error, 'caller_not_trusted', JSON.stringify(status.reply));
    const stagingDocument = await rpc(socketPath, { id: 'doc', method: 'get_document', params: {} });
    assert.notEqual(stagingDocument.reply.error, 'caller_not_trusted', JSON.stringify(stagingDocument.reply));
    // 回應會帶回 id：超大 id 直接拒絕。
    const hugeID = await rpc(socketPath, { id: 'x'.repeat(4096), method: 'device_status', params: {} });
    assert.equal(hugeID.reply.error, 'bad_request_id');

    // 一個連上就不送也不關的連線，不能卡住後面的呼叫（舊版 readToEnd 會一直等）。
    const idle = net.createConnection(socketPath);
    await once(idle, 'connect');
    const afterIdle = await rpc(socketPath, { id: 'after-idle', method: 'device_status', params: {} });
    assert.ok(afterIdle.ms < 3000, `blocked ${afterIdle.ms} ms`);
    idle.destroy();
    // 送完一行但不關寫端的客戶端也拿得到回覆。
    const open = await rpc(socketPath, { id: 'open', method: 'device_status', params: {} }, { closeWrite: false });
    assert.equal(open.reply.id, 'open');
  } finally {
    fs.writeFileSync(done, 'done\n');
    const timer = setTimeout(() => child.kill('SIGKILL'), 30_000);
    await exited;
    clearTimeout(timer);
    fs.writeFileSync(at('securitytest.log'), output);
  }
  assert.equal(child.exitCode, 0, output);
  assert.match(output, /SECURITYTEST ALL PASS/);
  assert.doesNotMatch(output, /SECURITYTEST FAIL/);
  // 第六、七輪：核准畫面看得到完整內容；終端機送出不交錯（有 tmux 3.6b 就一定要真的跑，三輪測試的 PATH 裡有）。
  assert.ok(output.includes('SECURITYTEST PASS 查看視窗：允許鍵不接 Return'), 'full-text sheet');
  const tmuxSkipped = output.includes('SECURITYTEST NOTE 終端機送出測試未跑');
  for (const label of ['終端機：同一分頁兩次送出不交錯', '終端機：貼上後確認失敗就清掉、不執行']) {
    assert.ok(tmuxSkipped || output.includes('SECURITYTEST PASS ' + label), label);
  }
});
