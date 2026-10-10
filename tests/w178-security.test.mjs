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
  const parent = process.env.TATWO2_SECURITY_TEST_ROOT || (fs.existsSync('/tmp') ? '/tmp' : tmpdir());
  fs.mkdirSync(parent, { recursive: true });
  const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, 'w178-')));
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e', 'entry', 'docs']) fs.mkdirSync(at(name));
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'),
    TATWO2_AUTHORIZED_KEYS: at('authorized_keys'), TATWO2_SSH_KNOWN_HOSTS: at('known_hosts'),
    TATWO2_SSH_KEY_PATH: at('fixture-key'), TATWO2_SSH_HOST_KEY_PUB: at('fixture-host.pub'), SSH_AUTH_SOCK: at('absent-agent'),
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
      'cli_open', 'cli_send', 'whoami', 'select_thread', 'github_import_from_gh', 'app_terminate_for_update',
      'os_status', 'goal_index', 'project_overview', 'project_suggest', 'project_proposal_decide']) {
      const { reply } = await rpc(socketPath, { id: method, method, params: { callerThreadID: '00000000-0000-0000-0000-000000000001' } });
      assert.equal(reply.ok, false, method);
      assert.equal(reply.error, 'caller_not_trusted', `${method}: ${JSON.stringify(reply)}`);
    }
    // W183 R1：ChatGPT 手腳的三個方法只給 App 登記的關口本人（.externalAI）；同一台 Mac 上的其他程式一律不行。
    for (const method of ['hands_tools', 'hands_call', 'hands_auth']) {
      const { reply } = await rpc(socketPath, { id: method, method, params: { callerThreadID: '00000000-0000-0000-0000-000000000001' } });
      assert.equal(reply.ok, false, method);
      assert.equal(reply.error, 'caller_not_trusted', `${method}: ${JSON.stringify(reply)}`);
    }
    // W182 R5：補回助理那條（assistant_append_offline）只給已配對設備，同一台 Mac 上的其他程式一律不行。
    const append = await rpc(socketPath, { id: 'append', method: 'assistant_append_offline', params: {} });
    assert.equal(append.reply.error, 'caller_not_trusted', JSON.stringify(append.reply));
    const unsignedJob = await rpc(socketPath, { id: 'job', method: 'job_submit', params: {} });
    assert.equal(unsignedJob.reply.error, 'caller_not_trusted');
    const status = await rpc(socketPath, { id: 'status', method: 'device_status', params: {} });
    assert.notEqual(status.reply.error, 'caller_not_trusted', JSON.stringify(status.reply));
    const stagingDocument = await rpc(socketPath, { id: 'doc', method: 'get_document', params: {} });
    // W179 rooms keep fixtures on the staging volume. Only physical /private/tmp or /private/var/folders
    // roots qualify for W178's extra read-only allowance; an external-volume fixture must still fail closed.
    if (env.TATWO_STAGING_ROOT.startsWith('/private/tmp/') || env.TATWO_STAGING_ROOT.startsWith('/private/var/folders/')) {
      assert.notEqual(stagingDocument.reply.error, 'caller_not_trusted', JSON.stringify(stagingDocument.reply));
    } else {
      assert.equal(stagingDocument.reply.error, 'caller_not_trusted', JSON.stringify(stagingDocument.reply));
    }
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

// W180 E1b：記憶自動同步的兩個設備 RPC 跟 memory_propose 同一組——外部程式只能帶設備簽章來（DeviceDispatch.authenticate 驗章），
// 不在 SSH 遙控清單、也不在 staging 唯讀清單。原始碼契約，不需要建好的 App。
test('W180 E1b memory sync RPCs: signed-device group only', () => {
  const bridge = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/OSAgentBridge.swift', import.meta.url), 'utf8');
  const list = name => bridge.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
  for (const method of ['memory_sync_target', 'memory_sync_receive', 'memory_sync_export', 'memory_sync_import']) {
    assert.ok(list('untrustedCallerMethods').includes(`"${method}"`), `${method} reachable only with a device signature`);
    assert.ok(!list('sshForwardMethods').includes(`"${method}"`), `${method} not an SSH remote-control method`);
    assert.ok(!list('stagingReadOnlyMethods').includes(`"${method}"`), `${method} not a staging read-only method`);
  }
  assert.match(bridge, /private var requestDispatch: DeviceDispatch \{[\s\S]*?#endif\s*return DeviceDispatch\.shared/);
  assert.match(bridge, /"memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import":\n\s*let \(sender, payload\) = try requestDispatch\.authenticate\(method: method, proof: params\)/);
});

// W182 R5：副設備離線時那段助理問答補回主設備（assistant_append_offline）——只給已配對設備（SSH 轉進來），
// 不在「外部程式也能用」與 staging 唯讀清單；這台自己的 AI 引擎、背景工作也不能呼叫（只能 caller == .ssh）。
test('W182 R5 assistant_append_offline: paired devices only', () => {
  const bridge = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/OSAgentBridge.swift', import.meta.url), 'utf8');
  const list = name => bridge.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
  const method = 'assistant_append_offline';
  assert.ok(list('sshForwardMethods').includes(`"${method}"`), 'SSH (paired device) list');
  assert.ok(!list('untrustedCallerMethods').includes(`"${method}"`), 'not for other programs');
  assert.ok(!list('stagingReadOnlyMethods').includes(`"${method}"`), 'not a staging read-only method');
  assert.match(bridge, /if method == AssistantOfflineWire\.method \{ return caller == \.ssh \}/);
  assert.match(bridge, /private static let remoteMethods: Set<String> = \[[\s\S]*?"assistant_append_offline"/);
});

// W183 R1：ChatGPT 手腳的關口（.externalAI）只准三個方法，這三個方法也不在任何既有清單（不給其他程式、SSH、staging）。原始碼契約。
test('W183 R1 external AI: exact three-method allowlist, never in the existing lists', () => {
  const read = name => fs.readFileSync(new URL(`../App/Sources/Tatwo2/Facade/${name}`, import.meta.url), 'utf8');
  const bridge = read('OSAgentBridge.swift');
  const contract = read('HandsContract.swift');
  const list = (source, name) => source.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
  const hands = list(contract, 'externalAIMethods').match(/"([^"]+)"/g)?.map(value => value.slice(1, -1)).sort();
  assert.deepEqual(hands, ['hands_auth', 'hands_call', 'hands_tools']);
  for (const name of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    assert.doesNotMatch(list(bridge, name), /"hands_/, name);
  }
  const allows = bridge.slice(bridge.indexOf('static func allows(caller:'), bridge.indexOf('/// 只有隔離根在暫存目錄'));
  assert.match(allows, /if case \.externalAI = caller \{ return HandsContract\.externalAIMethods\.contains\(method\) \}\n\s*if HandsContract\.externalAIMethods\.contains\(method\) \{ return false \}/);
  assert.match(allows, /case \.externalAI:\n\s*return false/);
});

// W183 R3：ChatGPT 手腳的標準設定流程（hands_setup_*）只給 App 與這台的引擎；副設備看主機狀態（remote_hands_*）要設備簽章。原始碼契約。
test('W183 R3 hands setup tools and secondary RPC: trust lists', () => {
  const read = name => fs.readFileSync(new URL(`../App/Sources/Tatwo2/Facade/${name}`, import.meta.url), 'utf8');
  const bridge = read('OSAgentBridge.swift');
  const setup = read('HandsSetup.swift');
  const list = name => bridge.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
  for (const name of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    assert.doesNotMatch(list(name), /"hands_setup_/, `${name}: setup tools only for the App and local engines`);
  }
  for (const method of ['remote_hands_status', 'remote_hands_action']) {
    assert.ok(list('untrustedCallerMethods').includes(`"${method}"`), `${method} reachable only with a device signature`);
    assert.ok(!list('sshForwardMethods').includes(`"${method}"`) && !list('stagingReadOnlyMethods').includes(`"${method}"`), method);
  }
  const allows = bridge.slice(bridge.indexOf('static func allows(caller:'), bridge.indexOf('/// 只有隔離根在暫存目錄'));
  assert.match(allows, /if HandsSetupTool\.methods\.contains\(method\) \{ return HandsSetupTool\.allows\(caller\) \}/);
  assert.ok(allows.indexOf('HandsSetupTool.methods') > allows.indexOf('if case .externalAI = caller { return HandsContract.externalAIMethods.contains(method) }'),
    'the external AI rule runs first');
  assert.match(setup, /case \.job, \.ssh, \.externalAI, \.other: return false/);
  assert.match(bridge, /case "remote_hands_status", "remote_hands_action":\n\s*let \(sender, payload\) = try DeviceDispatch\.shared\.authenticate\(method: method, proof: params\)/);
});
