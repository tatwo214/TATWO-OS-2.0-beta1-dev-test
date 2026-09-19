// W87b-1／2／3 更新體驗：計量網路可見＋開關、暫停續傳、每 6 小時檢查。
// 只用隔離的生產切片與本機 fixture 伺服器；不安裝、不碰 /Applications、不改安裝器。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const updater = read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
const checker = read('App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift');
const card = read('App/Sources/Tatwo2/New/UpdateAvailableCard.swift');

test('W87b-1 metered blocking is visible, switchable and overridable for one candidate', () => {
  // 設定 › App 更新那頁的內容就是 UpdateAvailableCard（掛載點 Shell/ChatPageSettings.swift 的 .github）。
  assert.match(card, /@AppStorage\(UpdateNetworkPolicy\.allowMeteredKey\) private var allowsMeteredDownload = false/);
  assert.match(card, /Toggle\(UpdateNetworkPolicy\.allowMeteredLabel, isOn: \$allowsMeteredDownload\)/);
  assert.match(card, /updater\.setAllowsMeteredAutomaticDownload\(value\)/);
  assert.match(card, /if let notice = updater\.networkNotice \{[\s\S]*Text\(notice\)/);
  assert.match(card, /Button\(UpdateNetworkPolicy\.downloadNowLabel\) \{[\s\S]*updater\.downloadNowIgnoringMetering\(to: release\.tag_name, repository: checker\.repository\)/);
  // 狀態文字沿用卡片既有的次要文字樣式，不新做元件。
  assert.match(card, /Text\(notice\)\.font\(\.footnote\)\.foregroundStyle\(\.secondary\)/);
  assert.match(updater, /static let allowMeteredKey = "update-allow-metered"/);
  assert.match(updater, /static let meteredText = "目前網路被視為計量，未自動下載"/);
  assert.match(updater, /static let downloadNowLabel = "現在就下載"/);
  const manual = updater.slice(updater.indexOf('    func downloadNowIgnoringMetering'),
    updater.indexOf('    func setAllowsMeteredAutomaticDownload'));
  assert.match(manual, /manualDownload = true/);
  assert.match(manual, /UpdateTransferGate\.shared\.setOpen\(true\)/);
  assert.match(manual, /prefetch\(to: tag, repository: repository, force: true\)/);
  // 一次性：候選換掉時 prefetch 會把 manualDownload 設回 force 值。
  assert.match(updater, /manualDownload = force; preparationReason = ""/);
});

test('W87b-2 a path change pauses instead of cancelling; cancellation stays user or superseded only', () => {
  const handler = updater.slice(updater.indexOf('        network.pathUpdateHandler'),
    updater.indexOf('    /// W87b-1：使用者按「現在就下載」'));
  assert.doesNotMatch(handler, /download\?\.cancel\(\)/);
  assert.match(handler, /UpdateTransferGate\.shared\.setOpen\(allowed \|\| manualDownload\)/);
  // 只剩三個取消點：使用者主動（cancelUpdate）、候選被取代（prefetch／invalidateCandidate）。
  assert.equal((updater.match(/download\?\.cancel\(\)/g) ?? []).length, 3);
  for (const owner of ['    func invalidateCandidate()', '    func prefetch(to tag', '    func cancelUpdate()']) {
    const start = updater.indexOf(owner);
    assert.ok(start > 0, owner);
    assert.ok(updater.indexOf('download?.cancel()', start) - start < 900, owner);
  }
  // 暫停不刪 parts、不消耗重試次數，恢復後同一段續傳。
  assert.match(updater, /while true \{\s*await gate\.wait\(\)\s*for attempt in 0\.\.<3/);
  assert.match(updater, /guard !gate\.isPaused else \{ break \}/);
  assert.match(updater, /await gate\.wait\(\) \/\/ W87b-2：暫停時連 HEAD 都不發/);
  assert.match(updater, /await UpdateTransferGate\.shared\.wait\(\) \/\/ W87b-2/);
});

test('W87b-3 six-hour monotonic schedule keeps the launch check and adds no background wake', () => {
  const start = checker.slice(checker.indexOf('    func start() {'), checker.indexOf('    func stop()'));
  assert.match(start, /UpdateCheckSchedule\.launchDelayNanoseconds/);
  assert.match(start, /UpdateCheckSchedule\.isDue\(now: ProcessInfo\.processInfo\.systemUptime, last: lastCheck\)/);
  assert.match(start, /lastCheck = ProcessInfo\.processInfo\.systemUptime/);
  assert.match(start, /guard schedule == nil else \{ return \}/);
  // 只在 App 執行中排程：不裝 launchd job、不要求系統喚醒。
  assert.doesNotMatch(start, /launchctl|NSBackgroundActivityScheduler|IOPMAssertion|beginActivity/);
  assert.match(checker, /static let intervalNanoseconds: UInt64 = 6 \* 60 \* 60 \* 1_000_000_000/);
  assert.match(card, /Text\("上次檢查：\\\(Self\.checkTime\.string\(from: checkedAt\)\)"\)/);
});

test('W87b production policy and schedule decisions compile and hold', () => {
  const root = testScratch('w87b-policy-');
  const policy = updater.slice(updater.indexOf('enum UpdateNetworkPolicy'), updater.indexOf('enum UpdateMarkState'));
  const schedule = checker.slice(checker.indexOf('enum UpdateCheckSchedule'),
    checker.indexOf('@MainActor\nfinal class GitHubReleaseUpdateChecker'));
  writeFileSync(join(root, 'main.swift'), `import Foundation
${policy}
${schedule}
// 計量＋開關關＝擋下並看得見；開關開＝照非計量；「現在就下載」＝一次性放行。
precondition(UpdateNetworkPolicy.state(satisfied: true, metered: true, allowMetered: false,
  manual: false, downloading: false) == "metered_blocked")
precondition(UpdateNetworkPolicy.notice("metered_blocked") == "目前網路被視為計量，未自動下載")
precondition(UpdateNetworkPolicy.state(satisfied: true, metered: true, allowMetered: true,
  manual: false, downloading: false) == "ready")
precondition(UpdateNetworkPolicy.state(satisfied: true, metered: true, allowMetered: false,
  manual: true, downloading: false) == "ready")
precondition(UpdateNetworkPolicy.state(satisfied: true, metered: false, allowMetered: false,
  manual: false, downloading: false) == "ready")
// 下載中被擋＝暫停（不是取消，也不是重新排隊）。
precondition(UpdateNetworkPolicy.state(satisfied: true, metered: true, allowMetered: false,
  manual: false, downloading: true) == "paused")
precondition(UpdateNetworkPolicy.state(satisfied: false, metered: false, allowMetered: true,
  manual: true, downloading: true) == "paused")
precondition(UpdateNetworkPolicy.state(satisfied: false, metered: false, allowMetered: true,
  manual: true, downloading: false) == "offline")
precondition(UpdateNetworkPolicy.notice("ready") == nil && UpdateNetworkPolicy.notice("offline") == nil)
precondition(!UpdateNetworkPolicy.allowsAutomaticDownload(satisfied: false, metered: false, allowMetered: true))
// 單調時鐘：啟動那次到期一次，之後滿 6 小時才再來；uptime 倒退也算到期。
precondition(UpdateCheckSchedule.isDue(now: 1, last: nil))
precondition(!UpdateCheckSchedule.isDue(now: 30, last: 30))
precondition(!UpdateCheckSchedule.isDue(now: 21_599, last: 0))
precondition(UpdateCheckSchedule.isDue(now: 21_600, last: 0))
precondition(UpdateCheckSchedule.isDue(now: 5, last: 100))
precondition(UpdateCheckSchedule.interval == 21_600)
print("W87b policy PASS")
`);
  const compiled = spawnSync('swiftc', ['-num-threads', '2', join(root, 'main.swift'), '-o', join(root, 'probe')],
    { encoding: 'utf8', timeout: 120000 });
  assert.equal(compiled.status, 0, compiled.stderr);
  const result = spawnSync(join(root, 'probe'), [], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /W87b policy PASS/);
});

const python = String.raw`
import http.server, sys, threading, json
root = sys.argv[1]
payload = open(root + '/payload', 'rb').read()
lock = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_HEAD(self): self.respond(True)
    def do_GET(self): self.respond(False)
    def respond(self, head):
        r = self.headers.get('Range')
        with lock:
            with open(root + '/requests', 'a') as f:
                f.write(json.dumps({'path': self.path, 'method': self.command, 'range': r}) + '\n')
        if self.path == '/mark':
            self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers(); return
        size = len(payload)
        start, end = 0, size - 1
        if r: start, end = map(int, r.split('=')[1].split('-'))
        self.send_response(206 if r else 200)
        self.send_header('ETag', '"w87b-v1"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if r: self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.end_headers()
        if head: return
        try: self.wfile.write(payload[start:end+1])
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
`;

test('W87b-2 paused transfers issue nothing, keep their parts and only refetch the missing ranges',
  { skip: process.platform !== 'darwin', timeout: 180000 }, async t => {
    const root = testScratch('w87b-pause-');
    const count = 6, payload = Buffer.alloc(3_000_006);
    for (let i = 0; i < payload.length; i++) payload[i] = (i * 7) % 251;
    const digest = createHash('sha256').update(payload).digest('hex');
    writeFileSync(join(root, 'payload'), payload);
    writeFileSync(join(root, 'server.py'), python);
    const machinery = (updater.slice(updater.indexOf('private final class UpdateDownloadProgress'),
      updater.indexOf('private struct UpdateRuntimeLayer'))
      + updater.split('// PARALLEL-DOWNLOAD-BEGIN\n')[1].split('// PARALLEL-DOWNLOAD-END')[0])
      // fixture 只放寬 ranges 的可見度，行為與生產碼逐字相同。
      .replace('private static func ranges', 'static func ranges');
    const redirect = checker.slice(checker.indexOf('final class UpdateRedirectDelegate:'),
      checker.indexOf('\n}', checker.indexOf('final class UpdateRedirectDelegate:')) + 2);
    writeFileSync(join(root, 'main.swift'), `import Foundation
import CryptoKit
${machinery}
${redirect}
final class Passed: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func bump() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}
@main struct Main {
  static func main() async throws {
    let a = CommandLine.arguments
    let gate = UpdateTransferGate()
    if a[1] == "gate" {
      let passed = Passed()
      gate.setOpen(false)
      let waiting = (0..<3).map { _ in Task { await gate.wait(); passed.bump() } }
      try await Task.sleep(for: .milliseconds(200))
      precondition(gate.isPaused && passed.value == 0) // 暫停就是停住，不是放行
      let cancelled = Task { await gate.wait(); passed.bump() }
      try await Task.sleep(for: .milliseconds(50))
      cancelled.cancel()
      await cancelled.value // 取消必須放行，否則永遠停在閘門
      precondition(passed.value == 1)
      gate.setOpen(true)
      for task in waiting { await task.value }
      precondition(passed.value == 4 && !gate.isPaused)
      await gate.wait() // 開著就直接通過
      print("gate PASS")
      return
    }
    let url = URL(string: a[2])!, destination = URL(fileURLWithPath: a[3]), size = Int64(a[4])!
    if a[1] == "paused" {
      gate.setOpen(false)
      let transfer = Task {
        try await UpdateParallelDownload.ranges(request: URLRequest(url: url), destination: destination,
                                                size: size, count: ${count}, gate: gate) { _, _ in }
      }
      try await Task.sleep(for: .milliseconds(900))
      _ = try await URLSession.shared.data(from: URL(string: a[5])!) // 在請求記錄裡插旗標
      gate.setOpen(true)
      try await transfer.value
      print("paused PASS")
      return
    }
    try await UpdateParallelDownload.ranges(request: URLRequest(url: url), destination: destination,
                                            size: size, count: ${count}, gate: gate) { _, _ in }
    print("resume PASS")
  }
}`);
    const compiled = spawnSync('swiftc', ['-parse-as-library', '-num-threads', '2',
      join(root, 'main.swift'), '-o', join(root, 'probe')], { encoding: 'utf8', timeout: 180000 });
    assert.equal(compiled.status, 0, compiled.stderr);
    const server = spawn('python3', ['-u', join(root, 'server.py'), root]);
    try {
      const [portBytes] = await once(server.stdout, 'data');
      const base = `http://127.0.0.1:${String(portBytes).trim()}`;
      const requests = () => readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse);
      const bounds = index => {
        const start = Math.floor(Number(payload.length) * index / count);
        return [start, Math.floor(Number(payload.length) * (index + 1) / count) - 1];
      };

      await t.test('the gate releases every waiter on resume and on cancellation', () => {
        const run = spawnSync(join(root, 'probe'), ['gate'], { encoding: 'utf8', timeout: 60000 });
        assert.equal(run.status, 0, run.stderr);
        assert.match(run.stdout, /gate PASS/);
      });

      await t.test('a paused transfer sends nothing, then finishes the same run', async () => {
        const destination = join(root, 'paused.zip');
        const run = spawnSync(join(root, 'probe'),
          ['paused', `${base}/paused.zip`, destination, String(payload.length), `${base}/mark`],
          { encoding: 'utf8', timeout: 120000, env: { ...process.env, TATWO_OS_DOWNLOAD_PARTS: String(count) } });
        assert.equal(run.status, 0, run.stderr);
        assert.match(run.stdout, /paused PASS/);
        const log = requests();
        const mark = log.findIndex(r => r.path === '/mark');
        assert.ok(mark >= 0, 'fixture marker missing');
        // 暫停期間一個請求都不發（連 HEAD 都不發），恢復後同一個 task 自己跑完。
        assert.deepEqual(log.slice(0, mark), []);
        assert.equal(log.filter(r => r.path === '/paused.zip' && r.method === 'GET').length, count);
        assert.equal(createHash('sha256').update(readFileSync(destination)).digest('hex'), digest);
      });

      await t.test('已下載的 parts 留著，恢復後只補缺的段', () => {
        const destination = join(root, 'resume.zip');
        const url = `${base}/resume.zip`;
        const identity = createHash('sha256').update(url).digest('hex').slice(0, 16);
        const parts = `${destination}.parts-${identity}-${payload.length}-${count}`;
        mkdirSync(parts);
        for (const index of [0, 1, 2]) {
          const [start, end] = bounds(index);
          writeFileSync(join(parts, String(index)), payload.subarray(start, end + 1));
        }
        const before = requests().length;
        const run = spawnSync(join(root, 'probe'), ['resume', url, destination, String(payload.length)],
          { encoding: 'utf8', timeout: 120000, env: { ...process.env, TATWO_OS_DOWNLOAD_PARTS: String(count) } });
        assert.equal(run.status, 0, run.stderr);
        assert.match(run.stdout, /resume PASS/);
        const ranges = requests().slice(before).filter(r => r.path === '/resume.zip' && r.method === 'GET')
          .map(r => r.range).sort();
        assert.deepEqual(ranges, [3, 4, 5].map(index => `bytes=${bounds(index)[0]}-${bounds(index)[1]}`).sort());
        assert.equal(createHash('sha256').update(readFileSync(destination)).digest('hex'), digest);
        assert.ok(!existsSync(parts), 'joined ranges clean up their own parts folder');
      });
    } finally {
      server.kill(); await once(server, 'close');
      console.log('W87b pause/resume evidence: ' + root);
    }
  });

test('W87b changes no installer, packaging or signing gate', () => {
  const repo = fileURLToPath(new URL('..', import.meta.url));
  const paths = ['install.sh', 'public/install.sh', 'scripts/package-release.sh'];
  const rev = ['beta1/integration', 'mini/beta1/integration', 'origin/beta1/integration']
    .find(ref => spawnSync('git', ['-C', repo, 'rev-parse', '--verify', '--quiet', ref + '^{commit}'],
      { encoding: 'utf8' }).status === 0);
  assert.ok(rev, '列車基準分支不在這個 clone 裡，無法驗證安裝閘門零改動');
  const base = spawnSync('git', ['-C', repo, 'merge-base', 'HEAD', rev], { encoding: 'utf8' });
  assert.equal(base.status, 0, base.stderr);
  const diff = spawnSync('git', ['-C', repo, 'diff', '--stat', base.stdout.trim(), '--', ...paths],
    { encoding: 'utf8' });
  assert.equal(diff.status, 0, diff.stderr);
  assert.equal(diff.stdout.trim(), '');
  assert.equal(read('install.sh'), read('public/install.sh'));
});
