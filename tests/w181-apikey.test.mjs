// W181 R3：「不用 API 金鑰」只擋按量計費的 API 金鑰，訂閱登入照常能跑；所有擋送出的地方用同一個判斷。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const app = p => join(root, 'App/Sources/Tatwo2', p);
const read = p => readFileSync(app(p), 'utf8');
const between = (text, start, end) => {
  const from = text.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? text.indexOf(end, from + start.length) : text.length;
  return text.slice(from, to < 0 ? text.length : to);
};
const swiftFiles = dir => readdirSync(dir).flatMap(name => {
  const full = join(dir, name);
  if (statSync(full).isDirectory()) return name === '_archived' ? [] : swiftFiles(full);
  return name.endsWith('.swift') ? [full] : [];
});

test('一個判斷：送出、原生目標、派工退回都走 EngineDisableStore.sendBlockReason；沒勾先回 nil', () => {
  const store = read('Facade/EngineDisableStore.swift');
  const reason = between(store, 'static func sendBlockReason(', 'static func blocksSend(');
  assert.match(reason, /^static func sendBlockReason\([^{]*\{\s*guard \(optedOut \?\? disabled\(\)\)\.contains\(kind\.rawValue\) else \{ return nil \}/);   // 沒勾：什麼都不查
  assert.match(reason, /EngineAPIKeyPolicy\.claudeProjectUsesAPIKey\(cwd: cwd\)/);
  assert.match(reason, /return method == \.subscription \? nil : EngineAPIKeyPolicy\.blockMessage\(kind, method\)/);   // 判斷不出來也擋
  assert.match(store, /private static let key = "tatwo2\.disabledEngines"/);   // 存的鍵不變

  const engine = read('Facade/ChatLiveEngine.swift');
  const send = between(engine, '@discardableResult func send(threadID: UUID', 'func savePastedAttachment');
  const gate = send.indexOf('if let reason = EngineDisableStore.sendBlockReason(engine, cwd: gateCwd, otherDevice: gateDevice) {');
  assert.ok(gate > 0 && gate < send.indexOf('ensureSidecar('), 'gate before the engine starts');
  assert.match(send, /appendSystemMessage\(threadID: threadID, text: reason, status: "error\|不用 API 金鑰"\)\s*return false/);
  assert.match(send, /t\.deviceID != nil \? nil : t\.cwdOverride \?\? doc\.projects\.first \{ \$0\.id == t\.projectID \}\?\.workdir \?\? NSHomeDirectory\(\)/);   // 跟 ensureSidecar 同一個資料夾
  // 派到別台的串：不拿這台的登入判斷那台（勾了就照舊擋，說明寫那台的名字）。
  assert.match(send, /let gateDevice = EngineDisableStore\.allowsAPIKey\(engine\) \? nil : gateRecord\?\.deviceID\.map \{ id in/);
  assert.match(reason, /if let otherDevice \{ return EngineAPIKeyPolicy\.otherDeviceMessage\(kind, device: otherDevice\.isEmpty \? nil : otherDevice\) \}/);
  assert.ok(reason.indexOf('if let otherDevice') < reason.indexOf('policy.method(kind'), 'remote threads never consult this device\'s login');
  assert.match(between(engine, 'func setNativeGoal(', 'func refreshNativeGoal('), /!EngineDisableStore\.blocksSend\(\.codex\)/);
  const dispatch = between(read('Facade/DispatchEngine.swift'), 'func returnDispatchRoom(', 'func presentDispatchReturn(');
  assert.match(dispatch, /if let reason = EngineDisableStore\.sendBlockReason\(kind, cwd: context\.worktree\) \{/);

  // 除了切換鈕本身，沒有人再把「有沒有勾」當成「送不出」。
  for (const file of swiftFiles(app(''))) {
    const text = readFileSync(file, 'utf8');
    const rel = file.slice(app('').length + 1);
    if (rel.endsWith('Acceptance.swift') || rel === 'Facade/EngineDisableStore.swift') continue;
    const uses = text.match(/EngineDisableStore\.isDisabled\(/g) ?? [];
    if (rel === 'Facade/ChatPageModel.swift') assert.equal(uses.length, 1, rel);   // toggleEngineDisabled 讀設定值
    else assert.equal(uses.length, 0, rel);
    if (rel !== 'Facade/ChatPageModel.swift') assert.doesNotMatch(text, /disabledEngines\.contains\(kind/, rel);
  }
});

test('ChatPageModel：isEngineDisabled＝送不出（新判斷），isAPIKeyOptedOut＝有勾；助理、私訊框、匯入都吃新判斷', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /func isEngineDisabled\(_ kind: ClaudeSidecar\.Kind\) -> Bool \{\s*EngineDisableStore\.blocksSend\(kind, optedOut: disabledEngines, allowStale: true\)\s*\}/);
  assert.match(model, /func isAPIKeyOptedOut\(_ kind: ClaudeSidecar\.Kind\) -> Bool \{ disabledEngines\.contains\(kind\.rawValue\) \}/);
  const toggle = between(model, 'func toggleEngineDisabled(', 'func isEngineDisabled(');
  assert.ok(toggle.includes('可以用 API 金鑰了（用 API 金鑰會按量計費）'));
  // 勾下去：登入方式在背景查完才說（照真的登入方式分開說，判斷不出來不說成「只有 API 金鑰」）。
  assert.match(toggle, /Task\.detached \{ \[weak self\] in\s*let method = policy\.method\(kind\)\s*await MainActor\.run \{ self\?\.flashComposerHint\(EngineAPIKeyPolicy\.optOutHint\(kind, method\)\) \}/);
  assert.doesNotMatch(toggle, /isEngineDisabled\(/);
  const hint = between(read('Facade/EngineAPIKeyPolicy.swift'), 'static func optOutHint(', 'MARK: - 這台是哪一種登入');
  for (const text of ['不用 API 金鑰了；這台只有 API 金鑰登入，要用請登入訂閱帳號', '不用 API 金鑰了：訂閱登入照常能用，不會按量扣錢',
                      '看不出這台是訂閱登入（可能還沒登入），先不送'])
    assert.ok(hint.includes(text), text);
  assert.match(toggle, /GBrainService\.shared\.applyAPIKeyPreference\(\)/);
  // App 一開先在背景查好；背景查到（或變了）就重畫。
  assert.match(model, /apiKeyPolicyObservation = EngineAPIKeyPolicy\.shared\.changes\.sink \{ \[weak self\] in self\?\.objectWillChange\.send\(\) \}/);
  assert.match(model, /if liveMode \{ EngineAPIKeyPolicy\.shared\.refreshInBackground\(optedOut: disabledEngines\) \}/);
  // W181 主導裁決：主設備連不上時，這台有送得出去的模型（訂閱）就退回本機。
  const fallback = between(model, 'private var assistantLocalFallbackAllowed: Bool {', '\n    }\n');
  assert.match(fallback, /isDisabled: \{ self\.isEngineDisabled\(\$0\) \}\) != nil/);
  assert.match(model, /return assistantLocalFallbackAllowed \? \.local : \.unreachable\(device, gap\)/);
  assert.match(model, /return !assistantPrimarySettledIDs\.contains\(device\.id\) \|\| !assistantLocalFallbackAllowed/);
  assert.doesNotMatch(model, /assistantLocalRoute != nil \? \.local|\|\| assistantLocalRoute == nil/);
  assert.doesNotMatch(model, /禁用/);
  // 登入、登出、重新檢查後重查登入方式（背景）。
  assert.equal((model.match(/EngineAPIKeyPolicy\.shared\.refresh\(optedOut: EngineDisableStore\.disabled\(\)\)/g) ?? []).length, 3);
  // 助理與私訊框原本就經 isEngineDisabled（W179 F／W180 D2），這次不重寫那兩段。
  assert.match(model, /coder: selectedModel, isDisabled: \{ self\.isEngineDisabled\(\$0\) \}/);
  assert.match(model, /guard !isEngineDisabled\(kind\) else \{ return "assistant_engine_disabled" \}/);
  const importWiring = read('Facade/ChatPageModel+CoderImport.swift');
  assert.match(importWiring, /let blocked = Set\(ClaudeSidecar\.Kind\.allCases\.filter \{ isEngineDisabled\(\$0\) \}\.map\(\\\.rawValue\)\)/);
  assert.match(importWiring, /CoderImport\.viewOnly\(disabledEngines: blocked, isSecondary: assistantPrimaryDevice != nil\)/);
});

test('sidecar 啟動環境拿掉被勾那家的金鑰；GBrain 不帶被勾那家的金鑰', () => {
  const sidecar = read('Engine/ClaudeSidecar.swift');
  const start = between(sidecar, 'func start(cwd: String', 'private func consume(');
  const prep = start.indexOf('try Self.prepareEngineHomes(environment: &env, runtimeBin: runtimeBin)');
  assert.match(start, /let apiKeyOptedOut = EngineDisableStore\.disabled\(\)/);
  const scrub = start.indexOf('EngineAPIKeyPolicy.removeAPIKeys(from: &env, for: kind, optedOut: apiKeyOptedOut)');
  assert.match(start, /startedWithAPIKeyOptOut = apiKeyOptedOut\.contains\(kind\.rawValue\)/);
  // 設定在引擎啟動後改了：這條沒在回覆就重開（照新設定拿掉或帶金鑰），正在回覆的等這輪結束。
  const ensure = between(read('Facade/ChatLiveEngine.swift'), 'private func ensureSidecar(', 'guard let idx = doc.threads.firstIndex');
  assert.match(ensure, /let apiKeyOptOutMatches = s\.startedWithAPIKeyOptOut == !EngineDisableStore\.allowsAPIKey\(engine\)\s*\|\| runningThreads\.contains\(threadID\)/);
  assert.match(ensure, /&& apiKeyOptOutMatches && runtimeMatches \{ return s \}/);
  // CLI 分頁啟動 claude／codex／grok 也拿掉被勾那家的金鑰變數。
  const cli = between(read('Facade/ChatPageModel.swift'), 'private func launchForCLI(', 'private func cliBookEngine(');
  assert.match(cli, /if let kind = ClaudeSidecar\.Kind\(rawValue: engine\.rawValue\) \{\s*EngineAPIKeyPolicy\.removeAPIKeys\(from: &environment, for: kind, optedOut: disabledEngines\)/);
  assert.ok(cli.indexOf('removeAPIKeys') < cli.indexOf('return TatwoNativeTerminalLaunch('));
  assert.ok(prep > 0 && scrub > prep && scrub < start.indexOf('SidecarGroupedProcess.spawn('), 'scrub after homes, before spawn');
  const policy = read('Facade/EngineAPIKeyPolicy.swift');
  const keys = between(policy, 'static func apiKeyEnvironmentKeys(', 'static func removeAPIKeys(');
  for (const name of ['OPENAI_API_KEY', 'CODEX_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'XAI_API_KEY'])
    assert.ok(keys.includes(`"${name}"`), name);
  assert.match(between(policy, 'static func removeAPIKeys(', 'static func gbrainProviderEnvironment('),
    /guard optedOut\.contains\(kind\.rawValue\) else \{ return \[\] \}/);   // 沒勾一個都不動
  const gbrain = read('Facade/GBrainService.swift');
  const startOnQueue = between(gbrain, 'private func startOnQueue()', 'private func configureSecondaryIfNeeded()');
  assert.match(startOnQueue, /EngineAPIKeyPolicy\.gbrainProviderEnvironment\(\s*optedOut: EngineDisableStore\.disabled\(\), read: \{ try keychain\.read\(\$0\) \}\)/);
  assert.doesNotMatch(startOnQueue, /keychain\.read\("openai"\)|keychain\.read\("anthropic"\)/);
  assert.match(gbrain, /func applyAPIKeyPreference\(\) \{\s*queue\.async \{ \[weak self\] in\s*guard let self, process\?\.isRunning == true, isPrimary else \{ return \}/);
  // 登入方式只看「方式」欄位：權杖、金鑰的值不讀出來用、不印。
  assert.doesNotMatch(policy, /print\(|NSLog|os_log|Logger\(/);
  assert.match(policy, /process\.arguments = \["auth", "status"\]/);
  assert.match(policy, /removeAPIKeys\(from: &child, for: \.claude, optedOut: \[ClaudeSidecar\.Kind\.claude\.rawValue\]\)/);   // 查的時候也不帶金鑰
  // 主執行緒一律不起 `claude auth status`、不忙等（03:41／03:52 兩次「當機」那一類）；逾時上限跟 EngineLogin 一樣 8 秒。
  assert.doesNotMatch(policy, /Thread\.sleep|while process\.isRunning/);
  assert.match(between(policy, 'private func claudeLogin(', 'func refreshClaude()'),
    /if Thread\.isMainThread \|\| \(allowStale && cached != nil\) \{\s*refreshClaudeInBackground\(\)\s*return cached\?\.method \?\? \.checking/);
  assert.match(between(policy, 'func refreshClaude() -> EngineLoginMethod {', 'private func refreshClaudeInBackground()'),
    /if Thread\.isMainThread \{\s*refreshClaudeInBackground\(\)/);
  assert.match(policy, /assert\(!Thread\.isMainThread, "claude auth status must not run on the main thread"\)/);
  assert.match(policy, /static let claudeStatusTimeout: TimeInterval = 8/);
  assert.match(read('Facade/EngineLogin.swift'), /let deadline = Date\(\)\.addingTimeInterval\(8\)/);
});

test('文字：不用 API 金鑰／可以用 API 金鑰／訂閱照用；只能看的說明；右鍵「移到其他設備…」', () => {
  const card = read('New/EngineLoginCard.swift');
  for (const text of ['"可以用 API 金鑰"', '"不用 API 金鑰"']) assert.ok(card.includes(text), text);
  // 狀態那一小行：設定頁與總覽頁同一個來源（不起子程序；還在確認、查不到都有自己的說法）。
  const label = between(read('Facade/EngineDisableStore.swift'), 'static func optOutLabel(', 'static func allowsAPIKey(');
  for (const text of ['"不用 API 金鑰（訂閱照用）"', '"不用 API 金鑰（沒訂閱登入，送不出）"', '"不用 API 金鑰（確認登入方式中…）"', '"不用 API 金鑰（暫時查不到登入，先不送）"'])
    assert.ok(label.includes(text), text);
  assert.match(label, /policy\.method\(kind, allowStale: true\)/);
  assert.match(card, /let optOut = EngineDisableStore\.optOutLabel\(kind, optedOut: model\.disabledEngines\)/);
  for (const old of ['"禁用 API"', '"解除禁用"', '"已禁用 API"']) assert.ok(!card.includes(old), old);
  assert.match(card, /model\.isAPIKeyOptedOut\(kind\) \? Color\.green : Color\.red/);   // 沒有新增藍色
  assert.doesNotMatch(card, /Color\.blue|borderedProminent/);
  const overview = read('New/OSOverviewPage.swift');
  assert.ok(overview.includes('EngineDisableStore.optOutLabel(st.kind, optedOut: model.disabledEngines)') && !overview.includes('"已禁用 API"'));
  assert.ok(read('Facade/CoderImport.swift').includes(
    'static let viewOnlyHint = "這台現在沒有能用的模型（只有 API 金鑰、而你設定不用）：可以看；要接著做，登入訂閱帳號，或右鍵「移到其他設備…」。"'));
  // 改字前匯入的串頂舊句子：送出或移到別台時一樣拿掉。
  const importLogic = read('Facade/CoderImport.swift');
  assert.ok(importLogic.includes('static let legacyViewOnlyHints: Set<String> = ["這台的引擎已停用：可以看；要接著做，右鍵「併回設備…」送到主設備"]'));
  assert.match(between(importLogic, 'static func withoutViewOnlyHint(', 'static func transferredBanner('), /lines\.filter \{ !isViewOnlyHint\(\$0\) \}/);
  assert.match(between(importLogic, 'static func transferredBanner(', '// MARK: 對到 Coder 專案'), /filter \{ !isViewOnlyHint\(\$0\) && !\$0\.hasPrefix\(folderMissingPrefix\) \}/);
  const sidebar = read('Chat/ChatPage+Sidebar.swift');
  assert.ok(sidebar.includes('Label("移到其他設備…", systemImage: "arrow.up.forward.app")') && !sidebar.includes('Label("併回設備…"'));
  assert.match(sidebar, /_ = model\.pushThreadToDevice\(thread\.id, section\.deviceID\)/);   // 功能不變
  const blocked = read('Facade/EngineAPIKeyPolicy.swift');
  assert.ok(blocked.includes('在這台只有 API 金鑰登入'));
  assert.ok(blocked.includes('這台暫時查不到 \\(name) 是哪種登入') && blocked.includes('這台看不出那台是不是用訂閱登入'));
  assert.ok(blocked.includes('你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請在 設定 › 登入 用訂閱帳號登入，或取消這個設定。'));
});

test('自測入口與涵蓋；新檔沒有私人資料', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w181apikey"[\s\S]{0,200}EngineAPIKeyAcceptance\.run\(\)/);
  const acceptance = read('Facade/EngineAPIKeyAcceptance.swift');
  for (const label of ['opted out + subscription login → the sentence reaches the engine', 'engine started with no API key variable',
                       'opted out + API key only → not sent', 'login cannot be told → treated as an API key',
                       'not opted out → sends exactly as before', 'tatwo2.disabledEngines is unchanged',
                       'GBrain: OpenAI opted out', 'W179 F unchanged', 'Codex runs on subscription: the assistant falls back here',
                       'the main thread never waits for `claude auth status`', 'tells the screen to redraw',
                       'times out with nothing known', 'keeps the last good answer', 'restarts the engine without API key variables',
                       'running engine is reused', 'running on another device is not judged by this device', 'the old view-only line'])
    assert.ok(acceptance.includes(label), label);
  assert.doesNotMatch(acceptance, /\.set\([^)]*disableKey|EngineDisableStore\.set\(/);   // 使用者的設定只暫時覆寫
  // 私人資料由 public-privacy 的掃描把關；這裡只擋寫死的家目錄路徑。
  for (const file of ['Facade/EngineAPIKeyPolicy.swift', 'Facade/EngineAPIKeyAcceptance.swift', 'Facade/EngineDisableStore.swift'])
    assert.doesNotMatch(read(file), /\/Users\/|\/Volumes\//, file);
});

test('判斷探針（swiftc 單獨編譯真的判斷檔）：訂閱放行、API 金鑰與判斷不出來擋、沒勾照舊、環境與 GBrain 不帶金鑰', { timeout: 240000 }, () => {
  const work = mkdtempSync(join(tmpdir(), 'w181-apikey-'));
  writeFileSync(join(work, 'stubs.swift'), 'enum ClaudeSidecar { enum Kind: String, CaseIterable, Hashable { case claude, codex, grok } }\n');
  writeFileSync(join(work, 'main.swift'), String.raw`
import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let engines = dir.appendingPathComponent("engines")
let resources = dir.appendingPathComponent("resources")
let env = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "ANTHROPIC_API_KEY": "fixture-value", "W181_STATUS": dir.appendingPathComponent("status.json").path,
           "W181_LOG": dir.appendingPathComponent("probe.log").path, "TATWO2_ENGINES_ROOT": engines.path,
           "W181_DELAY": dir.appendingPathComponent("delay").path]
let paths = EnginePaths(environment: env, resourceRoot: resources)
let fm = FileManager.default
for d in [paths.codexHome, paths.claudeConfigDirectory, paths.grokAuth.deletingLastPathComponent(), paths.claudeExecutable.deletingLastPathComponent()] {
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
}
try! "#!/bin/sh\n[ -f \"$W181_DELAY\" ] && sleep \"$(cat \"$W181_DELAY\")\"\n[ -n \"$ANTHROPIC_API_KEY\" ] && echo saw >> \"$W181_LOG\"\necho \"probe $1 $2\" >> \"$W181_LOG\"\ncat \"$W181_STATUS\"\n".write(to: paths.claudeExecutable, atomically: true, encoding: .utf8)
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.claudeExecutable.path)
func put(_ text: String?, _ url: URL) { if let text { try! text.write(to: url, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: url) } }
let policy = EngineAPIKeyPolicy(paths: paths, environment: env, statusTimeout: 1)
let all: Set<String> = ["claude", "codex", "grok"]
func reason(_ kind: ClaudeSidecar.Kind, _ opted: Set<String> = all, cwd: String? = nil) -> String? {
    EngineDisableStore.sendBlockReason(kind, optedOut: opted, cwd: cwd, policy: policy)
}
let status = URL(fileURLWithPath: env["W181_STATUS"]!), log = URL(fileURLWithPath: env["W181_LOG"]!), delay = URL(fileURLWithPath: env["W181_DELAY"]!)

// 主執行緒（這裡的最上層程式就在主執行緒）：不等 claude（假的睡 1 秒），先回「還在確認」並擋下。
put(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#, status)
put("1", delay)
let t0 = Date()
let onMain = policy.method(.claude)
let onMainReason = reason(.claude)
let waited = Date().timeIntervalSince(t0)
check("main thread: no wait for claude auth status, answers checking and blocks", onMain == .checking && waited < 0.5
      && onMainReason == EngineAPIKeyPolicy.blockMessage(.claude, .checking))
put(nil, delay)

// 其餘在背景執行緒驗（Claude 的查詢只在背景起子程序）。
func background() {

put(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"access_token":"a","refresh_token":"r"}}"#, paths.codexAuth)
check("codex subscription sends", policy.method(.codex) == .subscription && reason(.codex) == nil)
put(#"{"auth_mode":"apikey","OPENAI_API_KEY":"fixture-value"}"#, paths.codexAuth)
check("codex api key blocked with the plain text", reason(.codex) == "OpenAI 在這台只有 API 金鑰登入，你設定了不用 API 金鑰（按量計費），這句沒有送出。要用請在 設定 › 登入 用訂閱帳號登入，或取消這個設定。")
check("not opted out: api key still sends (old behavior)", reason(.codex, []) == nil && reason(.codex, ["claude", "grok"]) == nil)
put(nil, paths.codexAuth)
check("codex no login file → unknown → blocked", policy.method(.codex) == .unknown && reason(.codex)?.contains("當成 API 金鑰") == true)
put(#"{"auth_mode":"chatgpt","tokens":{"access_token":"a","refresh_token":"r"}}"#, paths.codexAuth)
put("model_provider = \"gateway\"\n", paths.codexHome.appendingPathComponent("config.toml"))
check("codex other provider → unknown", policy.method(.codex) == .unknown)
put("# comment\nmodel = \"x\"\n[model_providers.gateway]\nname = \"gateway\"\n", paths.codexHome.appendingPathComponent("config.toml"))
check("codex provider table alone does not switch", policy.method(.codex) == .subscription)

put(#"{"https://auth.example::id":{"auth_mode":"oidc","refresh_token":"r"}}"#, paths.grokAuth)
check("grok oidc → subscription", policy.method(.grok) == .subscription)
put(#"{"https://auth.example::id":{"auth_mode":"api_key"}}"#, paths.grokAuth)
check("grok api key → blocked", reason(.grok) != nil)
put(#"{"x":"plain"}"#, paths.grokAuth)
check("grok unknown shape → unknown", policy.method(.grok) == .unknown)

put(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#, status)
check("claude subscription sends (background thread checks)", reason(.claude) == nil)
let probe = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
check("claude probe runs auth status without the API key variable", probe.contains("probe auth status") && !probe.contains("saw"))
put(#"{"loggedIn":true,"authMethod":"api_key","apiKeySource":"ANTHROPIC_API_KEY"}"#, status)
check("claude result cached", reason(.claude) == nil)
policy.invalidate()
check("claude api key blocked after invalidate", reason(.claude) != nil)
put(#"{"loggedIn":true,"authMethod":"api_key_helper","apiKeySource":"apiKeyHelper"}"#, status); policy.invalidate()
check("claude apiKeyHelper → api key", policy.method(.claude) == .apiKey)
put(#"{"loggedIn":false,"authMethod":"none"}"#, status); policy.invalidate()
check("claude not logged in → unknown", policy.method(.claude) == .unknown)
put(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#, status)
put(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"x"}}"#, paths.claudeConfigDirectory.appendingPathComponent("settings.json")); policy.invalidate()
check("claude user settings carrying a key → api key", policy.method(.claude) == .apiKey)
put(nil, paths.claudeConfigDirectory.appendingPathComponent("settings.json")); policy.invalidate()
put("3", delay)
check("claude check timed out, nothing known → checkFailed (not 'not logged in')", policy.refreshClaude() == .checkFailed
      && EngineAPIKeyPolicy.blockMessage(.claude, .checkFailed).contains("暫時查不到"))
put(nil, delay); policy.invalidate()
_ = policy.refreshClaude()
put("3", delay)
check("claude later timeout keeps the last good answer", policy.refreshClaude() == .subscription)
put(nil, delay)
put(nil, paths.claudeConfigDirectory.appendingPathComponent("settings.json")); policy.invalidate()
let project = dir.appendingPathComponent("project/.claude")
try! fm.createDirectory(at: project, withIntermediateDirectories: true)
put(#"{"apiKeyHelper":"/bin/echo"}"#, project.appendingPathComponent("settings.local.json"))
check("claude folder apiKeyHelper → that folder blocked", reason(.claude, cwd: project.deletingLastPathComponent().path) == EngineAPIKeyPolicy.claudeProjectMessage
      && reason(.claude, cwd: dir.path) == nil && reason(.claude, [], cwd: project.deletingLastPathComponent().path) == nil)

var e1 = ["OPENAI_API_KEY": "a", "CODEX_API_KEY": "b", "ANTHROPIC_API_KEY": "c", "PATH": "/bin"]
let before = e1
check("scrub: not opted out leaves env identical", EngineAPIKeyPolicy.removeAPIKeys(from: &e1, for: .codex, optedOut: ["claude"]).isEmpty && e1 == before)
EngineAPIKeyPolicy.removeAPIKeys(from: &e1, for: .codex, optedOut: ["codex"])
check("scrub: codex keys gone, others kept", e1 == ["ANTHROPIC_API_KEY": "c", "PATH": "/bin"])
var reads: [String] = []
let g = EngineAPIKeyPolicy.gbrainProviderEnvironment(optedOut: ["claude"]) { reads.append($0); return "v-" + $0 }
check("gbrain: opted-out provider key not read nor passed", g == ["OPENAI_API_KEY": "v-openai"] && reads == ["openai"])
check("gbrain: nothing opted out → both", EngineAPIKeyPolicy.gbrainProviderEnvironment(optedOut: []) { "v-" + $0 }.count == 2)
check("remote thread: blocked by the opt-out alone, never by this device's login", reason(.claude, cwd: nil) == nil
      && EngineDisableStore.sendBlockReason(.claude, optedOut: all, otherDevice: "", policy: policy) == EngineAPIKeyPolicy.otherDeviceMessage(.claude, device: nil)
      && EngineDisableStore.sendBlockReason(.claude, optedOut: [], otherDevice: "", policy: policy) == nil)
print("W181PROBE failures=\(failures)")
exit(failures == 0 ? 0 : 1)
}
DispatchQueue.global().async { background() }
dispatchMain()
`);
  const files = ['Facade/EngineAPIKeyPolicy.swift', 'Facade/EngineDisableStore.swift', 'Facade/EnginePaths.swift', 'Facade/EngineRuntimeSelection.swift', 'Engine/NativeStagingIsolation.swift'].map(app);
  const build = spawnSync('swiftc', ['-num-threads', '2', ...files, join(work, 'stubs.swift'), join(work, 'main.swift'), '-o', join(work, 'probe')], { encoding: 'utf8', timeout: 200000 });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(work, 'probe'), [work], { encoding: 'utf8', timeout: 30000, env: { PATH: '/usr/bin:/bin', HOME: work } });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W181PROBE failures=0/);
  assert.equal((run.stdout.match(/^PASS /gm) ?? []).length, 25, run.stdout);
});
