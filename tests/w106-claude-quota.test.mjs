// W106：模型登入頁的 Claude 額度一直讀不到，還叫人重新登入，但聊天明明能用。
// 根因：登入子程序沒有明寫 CLAUDE_SECURESTORAGE_CONFIG_DIR，Claude Code 就自己從
// CLAUDE_CONFIG_DIR 推出一個獨立 Keychain namespace（"Claude Code-credentials-<sha8>"）；
// 聊天 sidecar 明寫空字串，讀的是共用的 "Claude Code-credentials"。額度讀的是前者，
// 那份自登入那一刻起就沒人更新，於是永遠是過期 token → 401 →「重新登入一次」。
// 這個測試釘住兩件事：(1) 登入與聊天寫／讀同一個 namespace；
// (2) 額度讀憑證時挑「還沒過期」的那一份，並且沒登入／讀不到／過期分開講。
import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

const facade = 'App/Sources/Tatwo2/Facade/';
const engine = 'App/Sources/Tatwo2/Engine/';
const storeSource = facade + 'ClaudeCredentialStore.swift';
const pathsSource = facade + 'EnginePaths.swift';
const isolationSource = engine + 'NativeStagingIsolation.swift';

const store = read(storeSource);
const isolation = read(isolationSource);
const quota = read(facade + 'EngineQuotaDetail.swift');
const usage = read(facade + 'UsageSource.swift');
const login = read(facade + 'EngineLogin.swift');
const sidecar = read('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift');

function slice(text, from, to, label) {
  const start = text.indexOf(from);
  const end = text.indexOf(to, start + 1);
  assert.ok(start >= 0 && end > start, `slice ${label} not found`);
  return text.slice(start, end);
}

test('W106 登入與聊天共用同一個 Claude Keychain namespace', () => {
  const isolate = slice(isolation, 'static func isolateClaude(', '/// Do not follow skill/config links',
    'isolateClaude');
  // 一定要明寫，而且值必須來自 sidecarClaudeNamespace——跟聊天 sidecar 同一個決定。
  assert.match(isolate, /result\["CLAUDE_SECURESTORAGE_CONFIG_DIR"\] = sidecarClaudeNamespace\(/);
  // 不可以再只有 staging 才寫；正式版留空不寫就是這次的病灶。
  assert.ok(!/if isEnabled\(environment\)\s*\{\s*result\["CLAUDE_SECURESTORAGE_CONFIG_DIR"\]/.test(isolate),
    'isolateClaude must not leave the production namespace unset');
  // 登入／登出／auth status 走的是 isolateClaude，聊天走的是 prepareEngineHomes：兩邊同一個來源。
  assert.match(login, /NativeStagingIsolation\.isolateClaude\(/);
  assert.match(sidecar,
    /environment\["CLAUDE_SECURESTORAGE_CONFIG_DIR"\] = NativeStagingIsolation\.sidecarClaudeNamespace\(/);
});

test('W106 額度只從 ClaudeCredentialStore 拿憑證，不自己拼服務名', () => {
  // 額度不可以再自己 sha256 設定夾路徑、也不可以用 ?? 硬退回另一個 namespace：
  // 那個 ?? 只在「項目不存在」時才換，過期的項目會一直搶先。
  assert.ok(!quota.includes('SHA256'), 'EngineQuotaDetail must not derive the keychain service itself');
  assert.ok(!quota.includes('keychainJSON'), 'EngineQuotaDetail must not read the keychain directly');
  assert.match(quota, /ClaudeCredentialStore\.load\(paths: paths, environment: environment\)/);
  // 額度也不可以自己起 /usr/bin/security 子程序（打包後會踩 Keychain ACL）。
  assert.ok(!usage.includes('/usr/bin/security'), 'UsageSource must not spawn the security CLI');
  assert.match(usage, /ClaudeCredentialStore\.load\(paths: EnginePaths\(\)\)/);
});

test('W106 讀不到額度時不再誤導成「要重新登入」', () => {
  // 舊文案：401 一律「Anthropic 的登入過期了，重新登入一次」、沒 token 一律「要登入後才讀得到」。
  assert.ok(!quota.includes('Anthropic 的登入過期了，重新登入一次'));
  assert.ok(!quota.includes('Anthropic 額度要登入後才讀得到'));
  assert.match(quota, /Anthropic 回 401/);
  // 三種原因各自有話講，而且只有「真的沒憑證」才叫人登入。
  assert.match(store, /case noCredential/);
  assert.match(store, /case accessDenied/);
  assert.match(store, /case expired\(Date\?\)/);
  const reason = slice(store, 'var reason: String {', '/// Claude Code 的規則', 'reason');
  assert.match(reason, /Keychain 裡沒有 Anthropic 登入憑證/);
  assert.match(reason, /ClaudeCredentialStore\.accessDeniedReason/);
  assert.match(store, /static let accessDeniedReason = "[^"]*不是沒登入/);
  assert.match(reason, /Claude 還能聊天/);
  assert.ok(!/過期[^」]{0,20}重新登入一次/.test(reason));
  // 憑證過期不可以再被算成 401 的「需重新登入」。
  assert.match(usage, /tokenExpired\(Date\?\)/);
  const display = slice(usage, 'catch let error as ClaudeOAuthUsageError {', 'catch {', 'display');
  assert.match(display, /case \.unauthorized: status = "需重新登入"/);
  assert.match(display, /case \.tokenMissing: status = "需登入"/);
  assert.match(display, /default: status = "額度讀不到"/);
});

test('W106 憑證挑選：過期的那份不可以蓋過還能用的那份', {
  skip: process.platform !== 'darwin', timeout: 180000,
}, () => {
  const dir = testScratch('w106-claude-quota-');
  const main = path.join(dir, 'Checks.swift');
  const binary = path.join(dir, 'checks');
  fs.writeFileSync(main, `import Foundation
import Security

@main
struct Checks {
  static func credential(_ token: String, expiresAt: Double) -> Data {
    let object: [String: Any] = ["claudeAiOauth": [
      "accessToken": token, "expiresAt": expiresAt,
      "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x",
    ]]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  static func check(_ item: String, _ passed: Bool, _ evidence: String) {
    print("W106 \\(passed ? "PASS" : "FAIL") \\(item) — \\(evidence)")
  }

  static func main() {
    let root = CommandLine.arguments[1]
    var environment: [String: String] = ["HOME": root, "TATWO2_ENGINES_ROOT": root + "/engines"]
    let paths = EnginePaths(environment: environment)
    let configDir = paths.claudeConfigDirectory.path

    // 正式版：聊天 namespace 為空 → 共用服務名排第一，登入留下的獨立 namespace 只是備援。
    let services = ClaudeCredentialStore.candidateServices(paths: paths, environment: environment)
    let isolated = ClaudeCredentialStore.service(namespace: configDir)
    check("候選順序", services == [ClaudeCredentialStore.baseService, isolated],
      services.joined(separator: " | "))
    check("獨立 namespace 有 sha8 後綴",
      isolated.hasPrefix(ClaudeCredentialStore.baseService + "-")
        && isolated.count == ClaudeCredentialStore.baseService.count + 9, isolated)

    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let live = now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000
    let dead = now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000

    // W106 的真實情況：登入寫的那份（獨立 namespace）過期了，聊天用的那份還活著。
    let mixed: ClaudeCredentialStore.Reader = { service in
      service == isolated
        ? (status: errSecSuccess, data: credential("stale-fixture", expiresAt: dead))
        : (status: errSecSuccess, data: credential("live-fixture", expiresAt: live))
    }
    switch ClaudeCredentialStore.load(paths: paths, environment: environment, now: now, reader: mixed) {
    case .success(let value):
      check("挑到還沒過期的那份",
        value.accessToken == "live-fixture" && value.service == ClaudeCredentialStore.baseService,
        value.service)
      check("帶出訂閱等級", value.rateLimitTier == "default_claude_max_20x",
        value.rateLimitTier ?? "nil")
    case .failure(let failure):
      check("挑到還沒過期的那份", false, "\\(failure)")
    }

    // 反過來：只有獨立 namespace 有活的憑證時也要挑得到（備援還在）。
    let fallbackOnly: ClaudeCredentialStore.Reader = { service in
      service == isolated
        ? (status: errSecSuccess, data: credential("fallback-fixture", expiresAt: live))
        : (status: errSecItemNotFound, data: nil)
    }
    if case .success(let value) = ClaudeCredentialStore.load(
      paths: paths, environment: environment, now: now, reader: fallbackOnly) {
      check("備援 namespace 仍可用", value.accessToken == "fallback-fixture", value.service)
    } else {
      check("備援 namespace 仍可用", false, "load failed")
    }

    // 三種失敗互不冒充。
    let missing: ClaudeCredentialStore.Reader = { _ in (status: errSecItemNotFound, data: nil) }
    let denied: ClaudeCredentialStore.Reader = { _ in (status: errSecInteractionNotAllowed, data: nil) }
    let expired: ClaudeCredentialStore.Reader = { _ in (status: errSecSuccess, data: credential("x", expiresAt: dead)) }
    func failure(_ reader: @escaping ClaudeCredentialStore.Reader) -> ClaudeCredentialStore.Failure? {
      if case .failure(let value) = ClaudeCredentialStore.load(
        paths: paths, environment: environment, now: now, reader: reader) { return value }
      return nil
    }
    check("沒有項目＝沒登入", failure(missing) == .noCredential, "\\(failure(missing) as Any)")
    check("讀不到內容＝權限被拒", failure(denied) == .accessDenied, "\\(failure(denied) as Any)")
    let expiredFailure = failure(expired)
    check("有項目但過期＝過期", expiredFailure == .expired(Date(timeIntervalSince1970: dead / 1000)),
      "\\(expiredFailure as Any)")
    check("過期的說明不叫人重新登入",
      !(expiredFailure?.reason.contains("重新登入") ?? true), expiredFailure?.reason ?? "nil")

    // 登入子程序的環境：正式版＝空（共用），staging＝設定夾（隔離）。
    let production = NativeStagingIsolation.isolateClaude(environment, configDirectory: configDir)
    check("正式版登入用共用 namespace", production["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "",
      production["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? "unset")
    check("正式版登入寫的服務名＝聊天讀的服務名",
      ClaudeCredentialStore.service(namespace: production["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? "")
        == services[0], services[0])
    environment["TATWO_STAGING_SCRATCH_HOME"] = root + "/staging"
    let staging = NativeStagingIsolation.isolateClaude(environment, configDirectory: configDir)
    check("staging 仍然隔離", staging["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == configDir,
      staging["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? "unset")
  }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '5', '-num-threads', '2',
    path.join(root, storeSource), path.join(root, pathsSource), path.join(root, isolationSource),
    main, '-o', binary], { cwd: root, encoding: 'utf8', timeout: 180000 });
  assert.equal(compile.status, 0, `${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
  const probe = spawnSync(binary, [dir], { cwd: root, encoding: 'utf8', timeout: 60000 });
  assert.equal(probe.status, 0, `${probe.error ?? ''}\n${probe.stdout}\n${probe.stderr}`);
  process.stdout.write(probe.stdout);
  const lines = probe.stdout.split('\n').filter((line) => line.startsWith('W106 '));
  assert.equal(lines.length, 12, probe.stdout);
  assert.deepEqual(lines.filter((line) => line.startsWith('W106 FAIL')), [], probe.stdout);
});

test('W106 回歸：背景讀鑰匙圈不准跳系統視窗；授權只能由使用者按鈕觸發', () => {
  // .021 實機：SecItemCopyMatching 讀 Claude Code CLI 建的共用憑證會跳授權視窗，主執行緒的 GitHub token 讀取排在後面，整個 App 卡死。
  const store = read('App/Sources/Tatwo2/Facade/ClaudeCredentialStore.swift');
  assert.match(store, /static let keychainReader: Reader = \{ service in read\(service: service, interactive: false\) \}/);
  assert.match(store, /if !interactive \{\s*SecKeychainGetUserInteractionAllowed\(&previous\)\s*SecKeychainSetUserInteractionAllowed\(false\)/);
  assert.match(store, /defer \{ if !interactive \{ SecKeychainSetUserInteractionAllowed\(previous\.boolValue\) \} \}/);
  assert.match(store, /static func authorizeInteractively\(/);
  const card = read('App/Sources/Tatwo2/New/EngineLoginCard.swift');
  assert.match(card, /detail\?\.note == ClaudeCredentialStore\.accessDeniedReason \{\s*Button\("允許讀取額度…"\) \{ model\.authorizeClaudeQuotaRead\(\) \}/);
  // 互動式讀取只能有一個呼叫點。
  const model = read('App/Sources/Tatwo2/Facade/ChatPageModel.swift');
  assert.equal((model.match(/authorizeInteractively\(/g) ?? []).length, 1);
});

