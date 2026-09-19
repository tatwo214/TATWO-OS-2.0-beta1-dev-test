// W100：遠端模式主執行緒不跑 SSH。
// 靜態部分鎖住「getter 只讀快取、link 呼叫只出現在標明 refresh／背景的地方」；
// 動態部分用真的 RemoteHostLink.swift 編一支小程式，證明主佇列進 call 會被擋下來。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');

/// 從 `signature` 開始抓一個大括號平衡的函式／計算屬性主體。
function body(text, signature) {
  const start = text.indexOf(signature);
  assert.notEqual(start, -1, `找不到 ${signature}`);
  const i = text.indexOf('{', start + signature.length);
  assert.notEqual(i, -1, `${signature} 沒有主體`);
  let depth = 0;
  for (let j = i; j < text.length; j += 1) {
    if (text[j] === '{') depth += 1;
    else if (text[j] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(i, j + 1);
    }
  }
  assert.fail(`${signature} 的大括號沒有收斂`);
}

test('W100 a: RemoteLiveEngine 的 View getter 只讀快取，link 呼叫只在背景 refresh', () => {
  const engine = source('Facade/RemoteLiveEngine.swift');

  // 被 View／ChatPageModel 的 getter 直接叫到的方法，函式體內不得有任何 link 呼叫。
  const readers = [
    'func transcript(for threadID: UUID?) -> [ChatMessage]',
    'func isTranscriptLoading(_ threadID: UUID?) -> Bool',
    'func isRunning(_ threadID: UUID?) -> Bool',
    'func threadRecord(_ threadID: UUID?) -> LiveThreadRecord?',
    'func projectRecord(_ projectID: UUID?) -> LiveProjectRecord?',
    'func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1]',
    'var document: TatwoNativeChatStoreDocument',
    'var archivedThreadCount: Int',
  ];
  for (const signature of readers) {
    const text = body(engine, signature);
    assert.doesNotMatch(text, /\.call\(/, `${signature} 不得在呼叫執行緒上打 link`);
    assert.doesNotMatch(text, /link\./, `${signature} 不得直接碰 link`);
  }

  // transcript 只回快取；沒有快取才排一次背景刷新。
  const transcript = body(engine, 'func transcript(for threadID: UUID?) -> [ChatMessage]');
  assert.match(transcript, /if let cached = transcriptCache\[threadID\] \{ return cached \}/);
  assert.match(transcript, /refreshTranscript\(threadID\)/);

  // 所有 link 呼叫只准出現在 perform{...}（背景佇列）或建構子那條輪詢的 Task.detached 裡。
  const outside = engine
    .split('\n')
    .filter(line => /\.call\(method:/.test(line) && !/perform\(\{/.test(line));
  assert.deepEqual(outside.length, 1, `link 呼叫外流：\n${outside.join('\n')}`);
  // W100d：輪詢的 link 呼叫與 JSON 解碼都在同一個 Task.detached 的 Result 閉包裡；revision 沒變不解碼。
  assert.match(outside[0], /let result = try link\.call\(method: "get_document"/);
  assert.match(engine, /Task\.detached\(priority: \.utility\) \{ \(\) -> Result<Fetched\?, Error> in\s*\n\s*Result \{\s*\n\s*let result = try link\.call/);
  assert.match(engine, /if fetchedRevision == known, known >= 0 \{/);
  assert.match(engine, /nonisolated private static func decode<T: Decodable>/);
  assert.match(engine, /nonisolated static let pollInterval: Double = 5/);

  // perform 一定把工作丟到自己的序列佇列，完成才回主執行緒。
  const perform = body(engine, 'private func perform<T>');
  assert.match(perform, /callQueue\.async \{/);
  assert.match(perform, /Task \{ @MainActor in completion\(outcome\) \}/);
  assert.match(engine, /private let callQueue = DispatchQueue\(/);

  // 同一條逐字稿進行中的刷新不重複發，失敗有冷卻。
  const refresh = body(engine, 'private func refreshTranscript(_ threadID: UUID)');
  assert.match(refresh, /guard !transcriptLoading\.contains\(threadID\) else \{ return \}/);
  assert.match(refresh, /transcriptRetryAfter\[threadID\] = Date\(\)\.addingTimeInterval\(3\)/);
  assert.match(refresh, /self\.onChange\?\(\)/);

  // 失敗提示 30 秒內不重複（提示風暴）。
  const hint = body(engine, 'private func hintOnce(_ key: String, _ message: String)');
  assert.match(hint, /timeIntervalSince\(last\) < 30/);
  assert.doesNotMatch(refresh, /onHint\?\(/, 'refresh 失敗要走 hintOnce，不可直接 onHint');
});

test('W100 b: RemoteHostLink 的 SSH 入口都禁止主佇列', () => {
  const link = source('Facade/RemoteHostLink.swift');
  for (const signature of [
    'func call(method: String, params: [String: Any] = [:]) throws -> [String: Any]',
    'private func establishLocked(_ device: DeviceRecord, sshReady: () -> Void = {}) throws',
    'private func sshHome(_ device: DeviceRecord) throws -> String',
  ]) {
    assert.match(
      body(link, signature),
      /dispatchPrecondition\(condition: \.notOnQueue\(\.main\)\)/,
      `${signature} 少了主佇列斷言`);
  }
  // 這是設計約束，不是除錯開關：不准被編譯條件包起來。
  assert.doesNotMatch(link, /#if DEBUG[\s\S]{0,400}notOnQueue\(\.main\)/);
});

test('W100 c: ChatPageModel 的畫面 getter 只讀 getter；寫入與連線都在背景', () => {
  const model = source('Facade/ChatPageModel.swift');

  const messages = body(model, 'var transcriptMessages: [ChatMessage]');
  assert.match(messages, /activeConversationEngine\?\.transcript\(for: selectedThreadID\)/);
  assert.doesNotMatch(messages, /\.call\(|link\.|Task/);

  const loading = body(model, 'var isRemoteTranscriptLoading: Bool');
  assert.match(loading, /isTranscriptLoading\(selectedThreadID\)/);
  assert.doesNotMatch(loading, /\.call\(/);

  // 進遠端模式不再同步等 SSH。
  const enter = body(model, 'func enterRemoteMode(_ device: DeviceRecord) -> Bool');
  assert.doesNotMatch(enter, /connectNow\(\)/, '進遠端模式不得同步連線');
  assert.match(enter, /session\.start\(\)/);
  assert.match(enter, /pendingRemoteEntryDeviceID = device\.id/);

  // ChatPageModel 內唯一的 link 呼叫（push 的 baseline 前置）必須在 Task.detached 裡。
  const push = body(model, 'func pushThreadToDevice(');
  assert.match(push, /Task\.detached\(priority: \.userInitiated\)[\s\S]*?link\.call\(method: "push_thread"/);
  assert.equal((model.match(/\.call\(method:/g) || []).length, 1);
  const pull = body(model, 'func pullThreadFromDevice(');
  assert.match(pull, /remote\.pullThread\(threadID: remoteThreadID\) \{/);
});

test('W100 d: 沒有快取時對話區顯示「連線中…」', () => {
  const view = readFileSync(resolve('App/Sources/Tatwo2/Chat/ChatPage+Transcript.swift'), 'utf8');
  const area = body(view, 'func messageArea(contentMaxWidth: CGFloat?) -> some View');
  assert.match(area, /model\.isRemoteTranscriptLoading/);
  assert.match(area, /ProgressView\("連線中…"\)/);
  // 沿用既有空狀態的樣子，不另外做一套。
  assert.match(area, /ProgressView\("載入對話"\)/);
});

test('W100b f: SelfTest harness 等完成回呼，診斷入口不在主執行緒打 SSH', () => {
  const selfTest = source('SelfTest.swift');

  // 併回／拉到：拿回呼的結果，等到回呼才判斷；逾時 30 秒算 FAIL，不是把斷言拿掉。
  const parallel = body(selfTest, 'static func runParallelTest(prefix: String, includeTransfers: Bool)');
  assert.match(parallel, /model\.pushThreadToDevice\(clientThreadID, device\.id\) \{ result in/);
  assert.match(parallel, /model\.pullThreadFromDevice\(device\.id, pushedID\) \{ result in/);
  const settle = body(parallel, 'func settle(_ label: String, _ done: () -> Bool) -> Bool');
  assert.match(settle, /Date\(\)\.addingTimeInterval\(30\)/);
  // 在主執行緒上用 semaphore 硬等會把 @MainActor 回呼一起卡死，所以是邊等邊讓 run loop 跑。
  assert.match(settle, /RunLoop\.current\.run\(mode: \.default, before:/);
  assert.doesNotMatch(settle, /DispatchSemaphore/);
  assert.match(parallel, /pushReturned\s*\n\s*&& pushedThread\?\.title/);
  assert.match(parallel, /pullReturned\s*\n\s*&& pulledThread != nil/);

  // 共用 helper：SelfTest 要打 link 一律經 offMain（自己的佇列＋semaphore 等結果）。
  const offMain = body(selfTest, 'static func offMain<T>(_ work: @escaping () throws -> T) throws -> T');
  assert.match(offMain, /linkProbeQueue\.async \{ outcome = Result\(catching: work\); done\.signal\(\) \}/);
  assert.match(selfTest, /private static let linkProbeQueue = DispatchQueue\(/);

  // 整個 SelfTest 不得有裸的主執行緒 link 呼叫（TATWO2_REMOTEPROBE、W78 自測都算）。
  const lines = selfTest.split('\n');
  const bare = lines.filter((line, index) => {
    if (!/\.callPinned\(device:|\blink\.(call|connect)\(/.test(line)) return false;
    if (/^\s*\/\//.test(line)) return false;
    // 呼叫本身或往前三行之內要看得到 offMain {（多行鏈式呼叫也算包好了）。
    return !lines.slice(Math.max(0, index - 3), index + 1).some(near => /offMain \{/.test(near));
  });
  assert.deepEqual(bare, [], `SelfTest 仍在主執行緒直接打 link：\n${bare.join('\n')}`);

  // ChatPageModel 的搬移 API 真的把結果交回來（harness 不是自己去猜）。
  const model = source('Facade/ChatPageModel.swift');
  for (const signature of [
    'func pushThreadToDevice(',
    'func pullThreadFromDevice(',
  ]) {
    assert.match(model.slice(model.indexOf(signature), model.indexOf(signature) + 240),
      /completion: \(@MainActor \(UUID\?\) -> Void\)\? = nil/, `${signature} 少了完成回呼`);
  }
});

test('W100 e: 主佇列進 RemoteHostLink.call 會被擋，背景佇列照常回錯誤', { timeout: 180_000 }, () => {
  const root = testScratch('w100-nohang-');
  writeFileSync(join(root, 'Remote.swift'), source('Facade/RemoteHostLink.swift'));
  writeFileSync(join(root, 'Stubs.swift', ), String.raw`
import Foundation

enum DeviceRole: String, Codable, Sendable { case primary, secondary }
enum DeviceStatusReader {
    static func registry(environment: [String: String]) -> [DeviceRecord] { [] }
}
struct DeviceStatusSnapshot: Sendable {
    static func decode(_ value: [String: Any]) throws -> Self { Self() }
}
struct DeviceStatusProbe {
    enum Connection { case reachable, appUnavailable, sshUnavailable }
    var connection: Connection
    var snapshot: DeviceStatusSnapshot?
    var acquiredAt: Date
    var reason: String?
}
@main struct Probe {
    static func main() {
        let link = RemoteHostLink(environment: [:])
        if CommandLine.arguments[1] == "main" {
            // 主佇列：設計上不准走到這裡，應該當場被 dispatchPrecondition 擋下。
            _ = try? link.call(method: "get_document")
            print("REACHED-SSH-ON-MAIN")
            exit(0)
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { _ = try link.call(method: "get_document"); print("UNEXPECTED-OK") }
            catch { print("PASS background-call-returns \(error)") }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
`);
  const binary = join(root, 'probe');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    join(app, 'Facade/DeviceRegistry.swift'), join(root, 'Remote.swift'), join(root, 'Stubs.swift'),
    '-o', binary], { encoding: 'utf8', timeout: 150_000 });

  let trapped = null;
  try {
    const output = execFileSync(binary, ['main'], { encoding: 'utf8', timeout: 30_000, stdio: 'pipe' });
    assert.fail(`主佇列呼叫沒有被擋下來：${output}`);
  } catch (error) {
    trapped = error;
  }
  assert.ok(trapped.signal || (trapped.status ?? 0) !== 0,
    `主佇列呼叫應該中止行程，實際 status=${trapped.status} signal=${trapped.signal}`);
  assert.doesNotMatch(String(trapped.stdout ?? ''), /REACHED-SSH-ON-MAIN/);

  const background = execFileSync(binary, ['background'], { encoding: 'utf8', timeout: 30_000 });
  assert.match(background, /PASS background-call-returns/);
  console.log(background.trim());
});
