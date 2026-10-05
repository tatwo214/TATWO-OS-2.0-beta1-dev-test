// W184 CU（09-30 mini .032 兩個實測失敗）：Computer Use 以 TATWO 自己為目標——
// 1. GPT-6 對私訊框左上的頁面圓鈕做 AXShowMenu：選單的追蹤迴圈跑在 GCD 主佇列區塊裡，bridge 的 onMain、transcript 全部逾時（整個 App 卡死）。
// 2. 開著主視窗＋停靠的私訊框＋Island 時 computer_observe 三次都回 computer_window_not_uniquely_identified。
// W184 CU 第二輪（GPT-6 審查 1–6）：可以用＝每一條選取分支的前置條件、排進 run loop 的動作執行前重驗（權限降級當場撤銷）、
// 直接動作要元件身分、兩套座標、私有 API 失效時拒絕、反例測試。
// W184 CU 第三輪（GPT-6 複核）：擋擷取三態（讀不到＝受保護）＋WindowCaptureShield 強制否決、成功與錯誤回應同一條輸出過濾、
// 沒有視窗編號＝讀樹前一律拒絕（截圖與不截圖一樣）、選單／浮出視窗的事件送到它自己的視窗、按鍵 believer 照編號、C3 不再依結果 SKIP。
// 這裡守原始碼的契約：每一條都釘「整段路徑」（guard 的順序、呼叫的先後），不是字串有沒有出現；真的開選單、量主佇列、
// 讀選單項目、同位置的真視窗、真的 ChatPageModel setter 在 `TATWO2_SELFTEST=w184cu`。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const app = 'App/Sources/Tatwo2/';
const cu = read(app + 'New/ComputerUseController.swift');
const pick = read(app + 'New/ComputerUseWindowPick.swift');
const events = read(app + 'New/ComputerUseBackgroundEvents.swift');
const pointer = read(app + 'New/ComputerUsePointer.swift');
const model = read(app + 'Facade/ChatPageModel.swift');
const selfTest = read(app + 'SelfTest.swift');
const acceptance = read(app + 'New/ComputerUseSelfTargetAcceptance.swift');
const between = (text, start, end) => {
  const from = text.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? text.indexOf(end, from + start.length) : text.length;
  assert.ok(to > from, `missing ${end} after ${start}`);
  return text.slice(from, to);
};
const code = text => text.split('\n').map(line => line.replace(/\/\/.*$/, '')).join('\n');
/** 每一個 needle 都要在前一個之後出現（順序就是路徑）。 */
const ordered = (text, needles, label) => needles.reduce((last, needle) => {
  const at = text.indexOf(needle, last + 1);
  assert.ok(at > last, `${label}: expected "${needle}" after position ${last}`);
  return at;
}, -1);

test('1. self-target AX actions run from a main run-loop block with a cancellable identity, never inside a GCD main-queue block or the session lock', () => {
  const perform = code(between(cu, 'static func performAction(_ node: AXUIElement', 'static func performOnMainRunLoop('));
  // 其他 App：跨行程，照舊同步。
  assert.match(perform, /guard authority\.grant\.pid == ProcessInfo\.processInfo\.processIdentifier else \{\s*return AXUIElementPerformAction\(node, name as CFString\)\s*\}/);
  // 自己：排進 SelfSchedule（有 token、執行前重驗），區塊裡只有 SelfAction 記號＋AX 呼叫，沒有 session lock、沒有 GCD 主佇列。
  assert.match(perform, /SelfSchedule\.schedule\(authority\) \{\s*SelfAction\.begin\(\)\s*defer \{ SelfAction\.end\(\) \}\s*_ = AXUIElementPerformAction\(node, name as CFString\)\s*\}\s*return \.success/);
  assert.doesNotMatch(perform, /DispatchQueue\.main|gate\.dispatch|locked\(/);
  const runLoop = code(between(cu, 'static func performOnMainRunLoop(', 'enum SelfSchedule'));
  assert.match(runLoop, /let loop = CFRunLoopGetMain\(\)\s*CFRunLoopPerformBlock\(loop, CFRunLoopMode\.commonModes\.rawValue, work\)\s*CFRunLoopWakeUp\(loop\)/);
  // 每一個 AX 動作都帶 authority（沒有漏掉舊的 grant/gate 版本）。
  assert.equal((cu.match(/performAction\([^)]*grant: grant/g) ?? []).length, 0);
  assert.equal((cu.match(/performAction\([^)]*authority: authority\)/g) ?? []).length, 5);
  // /goal 101 照舊：自我目標的 AX 一定回主執行緒；唯一的 Task.detached 在 run(pid:) 給其他 App。
  assert.match(cu, /static func run<T>\(pid: Int32,[^\n]*\) async throws -> T \{\s*if pid == ProcessInfo\.processInfo\.processIdentifier \{\s*return try await MainActor\.run/);
  assert.equal((cu.match(/Task\.detached/g) ?? []).length, 1);
});

test('2. the queued self action re-verifies grant, connection, context, full access and sensitive page at run time; revocation voids the queue; the permission setter revokes synchronously', () => {
  // 排程：token 進集合 → run loop 區塊 → token 還在才繼續（撤銷＝作廢）→ 重驗 → 才做事。
  const schedule = code(between(cu, 'enum SelfSchedule {', 'enum SelfAction {'));
  ordered(schedule, ['static func schedule(_ authority: ComputerUseSelfAuthority', 'let token = UUID()',
    'pending.withLock { _ = $0.insert(token) }', 'performOnMainRunLoop {', 'guard pending.withLock({ $0.remove(token) != nil }) else { return }',
    'MainActor.assumeIsolated {', 'guard authority.stillAuthorized() else { return }', 'work()', 'return token'], 'SelfSchedule.schedule');
  assert.match(schedule, /static func cancelAll\(\) \{ pending\.withLock \{ \$0\.removeAll\(\) \} \}/);
  // 重驗的內容：grant 有效、還連著、情境還在（控制器那份 contextIsCurrent，含基準的 selfOperated 例外）、還是全權、沒有敏感頁。
  const authority = code(between(cu, 'struct ComputerUseSelfAuthority', 'enum ComputerUseNative {'));
  assert.match(authority, /@MainActor func stillAuthorized\(\) -> Bool \{\s*guard \(try\? gate\.validate\(grant\)\) != nil, requestIsConnected\(\), contextIsCurrent\(\) else \{ return false \}\s*if grant\.pid == ProcessInfo\.processInfo\.processIdentifier \{\s*guard selfTargetPermitted\(\),\s*!ComputerUseController\.refusesSelf\(pid: grant\.pid, lane: grant\.lane, sensitivePageOpen: sensitivePageOpen\(\)\) else \{ return false \}\s*\}\s*return true\s*\}/);
  // 控制器把它們接進來：ChatPageModel 的 contextIsCurrent、requestIsConnected、selfTargetPermitted（現在的權限）、敏感頁閘門。
  assert.match(cu, /ComputerUseSelfAuthority\(grant: grant, gate: session, requestIsConnected: requestIsConnected,\s*contextIsCurrent: contextIsCurrent, selfTargetPermitted: selfTargetPermitted,\s*sensitivePageOpen: \{ BrowserSensitivePageGate\.isActive \}\)/);
  assert.match(model, /selfTargetPermitted: \{ \[weak self\] in self\?\.permissionPreset == \.fullAccess \},/);
  // 撤銷（停止、換目標）＝佇列作廢：session.stop 之後馬上 cancelAll。
  const stop = code(between(cu, '    func stop(owner: UUID? = nil) {', '    /// W184 CU 第二輪（GPT-6 審查 #2）：權限預設'));
  ordered(stop, ['session.stop()', 'ComputerUseNative.SelfSchedule.cancelAll()', 'granted = nil', 'preferredWindow = nil'], 'stop()');
  const prepare = code(between(cu, 'private func prepareStart(', 'private func reserveConsent('));
  ordered(prepare, ['session.stop()', 'ComputerUseNative.SelfSchedule.cancelAll()', 'granted = nil'], 'prepareStart');
  // 權限 setter：從全權降下來＝同步撤銷（不是等下一次呼叫）。
  const setter = code(between(model, '@Published var permissionPreset: TatwoPermissionPreset =', '@Published var selectedSpeedTier'));
  assert.match(setter, /didSet \{[\s\S]*?ComputerUseController\.shared\.permissionPresetChanged\(from: oldValue, to: permissionPreset\)\s*\}/);
  assert.match(cu, /func permissionPresetChanged\(from old: TatwoPermissionPreset, to new: TatwoPermissionPreset\) \{\s*guard old != new, old == \.fullAccess else \{ return \}\s*stop\(\)\s*\}/);
  // 直接動作的排程也走同一個 SelfSchedule（同一份重驗）。
  assert.match(cu, /func schedule\(authority: ComputerUseSelfAuthority\) -> UUID \{[\s\S]*?return ComputerUseNative\.SelfSchedule\.schedule\(authority\) \{/);
});

test('3. the direct (NSAccessibility) route needs element identity inside the node\'s own window, exactly one match, re-resolved at run time', () => {
  const direct = code(between(cu, 'static func selfDirectAction(', '@MainActor static func selfAccessibilityElement('));
  // 身分從 AX 節點讀（角色、子角色、標題／說明、識別碼、位置大小）；節點所屬視窗 → 編號；沒有編號＝不找；視窗要可以用；找得到唯一一個才回。
  ordered(direct, ['guard pid == ProcessInfo.processInfo.processIdentifier, Thread.isMainThread,', 'let fingerprint = ElementFingerprint.read(node, deadline: deadline)',
    'kAXWindowAttribute', 'kAXTopLevelUIElementAttribute', 'guard let owner, let windowID = windowID(of: owner) else { return nil }',
    'guard ComputerUseWindowPick.stillUsable(windowID: windowID, pid: pid),', 'let target = selfAccessibilityElement(fingerprint, windowNumber: Int(windowID)) else { return nil }'], 'selfDirectAction');
  assert.doesNotMatch(direct, /NSApp\.windows|frontToBack/);
  const fingerprint = code(between(cu, 'struct ElementFingerprint', 'struct SelfDirectAction'));
  for (const field of ['kAXRoleAttribute', 'kAXSubroleAttribute', 'kAXTitleAttribute', 'kAXDescriptionAttribute', 'kAXIdentifierAttribute']) assert.ok(fingerprint.includes(field), field);
  assert.match(fingerprint, /guard string\("accessibilityRole"\) == role, \(string\("accessibilitySubrole"\) \?\? ""\) == subrole,\s*\(string\("accessibilityIdentifier"\) \?\? ""\) == identifier,/);
  assert.match(fingerprint, /guard ComputerUseNative\.sameFrame\(topLeft, frame\) else \{ return false \}/);
  assert.match(fingerprint, /return objectTexts == texts/);
  // 只走那一個視窗的樹；對到兩個就停；剛好一個才回。
  const find = code(between(cu, '@MainActor static func selfAccessibilityElement(', '/// W184 CU 第二輪（GPT-6 審查 #4）'));
  assert.match(find, /guard let window = NSApp\.window\(withWindowNumber: windowNumber\) else \{ return nil \}/);
  assert.match(find, /guard depth < 40, visited < 4000, matches\.count < 2 else \{ return \}/);
  assert.match(find, /walk\(window, depth: 0\)\s*return matches\.count == 1 \? matches\[0\] : nil/);
  assert.doesNotMatch(find, /NSApp\.windows/);
  // 執行前再找一次：視窗還可以用、同一個物件，不然不做。
  const schedule = code(between(cu, 'struct SelfDirectAction', 'static func selfDirectAction('));
  assert.match(schedule, /guard ComputerUseWindowPick\.stillUsable\(windowID: CGWindowID\(truncatingIfNeeded: windowNumber\), pid: getpid\(\)\),\s*let found = ComputerUseNative\.selfAccessibilityElement\(fingerprint, windowNumber: windowNumber\),\s*found === target else \{ return \}/);
  // backgroundInput／input：先直接（找得到唯一才算）、找不到才 AX；都經過閘門（dispatch）。
  const background = code(between(cu, 'static func backgroundInput(', 'static func menuItem('));
  assert.match(background, /func direct\(_ name: String\) throws -> Bool \{\s*guard let action = selfDirectAction\(node, name, pid: grant\.pid, deadline: deadline\) else \{ return false \}\s*try gate\.dispatch\(observationID: observation\.id, for: grant\) \{ action\.schedule\(authority: authority\) \}\s*return true\s*\}/);
  assert.match(background, /case \.click:\s*if try direct\(kAXPressAction\) \{ return \.done\(center\(node\)\) \}\s*if try perform\(kAXPressAction\)/);
  assert.match(background, /case \.rightClick:\s*if try direct\(kAXShowMenuAction\) \{ return \.done\(center\(node\)\) \}\s*return try perform\(kAXShowMenuAction\)/);
  const axAction = code(between(cu, 'case .axAction(let index, let name):', 'case .focusWindow(let index):'));
  assert.match(axAction, /if let direct = selfDirectAction\(node, name, pid: grant\.pid, deadline: deadline\) \{\s*try gate\.dispatch\(observationID: observation\.id, for: grant\) \{ direct\.schedule\(authority: authority\) \}\s*return\s*\}\s*let result = performAction\(node, name, authority: authority\)/);
  assert.doesNotMatch(cu, /selfEventRoute|selfAccessibilityAction\(/);
});

test('1. while a self AX action is still inside a menu or dialog, nothing calls AX in-process: observe says busy, only keys go through; open menus are read', () => {
  assert.match(cu, /enum SelfAction \{\s*private static let running = OSAllocatedUnfairLock\(initialState: 0\)/);
  const readState = code(between(cu, 'static func readState(', 'let app = AXUIElementCreateApplication(pid)'));
  assert.match(readState, /if pid == ProcessInfo\.processInfo\.processIdentifier, SelfAction\.inFlight \{ return \.busyState\(running\) \}/);
  const background = code(between(cu, 'static func backgroundInput(', 'let app = AXUIElementCreateApplication(grant.pid)'));
  assert.match(background, /if grant\.pid == ProcessInfo\.processInfo\.processIdentifier, SelfAction\.inFlight \{ return \.notApplicable \}/);
  const input = code(between(cu, '    static func input(_ request: Request', 'switch request {\n        case .pointer(let pointer):'));
  assert.match(input, /try check\(\)\s*if grant\.pid == ProcessInfo\.processInfo\.processIdentifier, SelfAction\.inFlight \{\s*guard case \.pressKey\(let key\) = request else \{ throw ComputerUseFailure\(selfBusyCode\) \}\s*try postKeyToSelf\(key, observation: observation, grant: grant, gate: gate\)\s*return\s*\}/);
  const post = code(between(cu, 'static func postKeyToSelf(', undefined));
  assert.doesNotMatch(post, /AXUIElement|attribute\(/);
  assert.match(post, /try gate\.dispatch\(observationID: observation\.id, for: grant\) \{\s*down\.postToPid\(grant\.pid\); up\.postToPid\(grant\.pid\)/);
  const busy = code(between(cu, 'private func busyObservation(', '/// A sheet abort'));
  assert.match(busy, /try checkContext\(grant, contextIsCurrent\)\s*try refuseSelfWhileSensitive\(grant\)/);
  assert.match(busy, /"windowState": "busy"[\s\S]*"screenshotAvailable": false/);
  const menus = code(between(cu, 'static func openMenus(', 'struct Key: Sendable'));
  assert.match(code(between(pick, 'static func popUpMenuWindows(', 'static func menuWindow(')), /let level = Int\(CGWindowLevelForKey\(\.popUpMenuWindow\)\)/);
  assert.match(menus, /AXUIElementGetPid\(node, &owner\) == \.success, owner == pid/);
  const tree = code(between(cu, 'static func readState(', 'static func openMenus('));
  assert.match(tree, /let menuBranch = inMenu \|\| role == kAXMenuRole/);
  assert.match(tree, /for menu in openMenus\(pid: pid, app: app, deadline: deadline, offsets: offsets\) \{[\s\S]*?try walk\(menu, depth: 0, inMenu: true\)/);
});

test('2./5. window picking: three-valued protection + shield veto, usable on every branch, no window number = refused before read (image or not), one output filter for success and error', () => {
  // 三態：kCGWindowSharingState 缺、不是整數、不認得＝unknown；unknown 與 protected 一樣擋。Facts 沒給 server＝unknown。
  const protection = code(between(pick, 'static func protection(sharingState value: Any?)', 'struct Facts: Equatable'));
  ordered(protection, ['guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),', 'else { return .unknown }',
    'case 0: return .protected', 'case 1, 2: return .shareable', 'default: return .unknown'], 'protection');
  assert.match(pick, /init\(onScreen: Bool, alpha: Double, layer: Int, server: Protection = \.unknown, shield: Protection\? = nil,/);
  assert.match(pick, /var captureProtected: Bool \{ server != \.shareable \|\| \(shield != nil && shield != \.shareable\) \}/);
  assert.match(pick, /var usable: Bool \{ visible && ignoresMouse != true && !captureProtected \}/);
  assert.match(pick, /var disclosable: Bool \{ !captureProtected \}/);
  assert.doesNotMatch(pick, /serverProtected|appKitProtected \?\?|captureProtected: Bool\? = nil/);
  // facts：每個 App 都讀視窗伺服器的三態；自家視窗在主執行緒問 WindowCaptureShield（持有＋linger），不在主執行緒＝unknown。
  const facts = code(between(pick, 'static func facts(pid: pid_t)', 'static func candidates('));
  ordered(facts, ['var sharing = info[kCGWindowSharingState as String]', 'server: protection(sharingState: sharing))',
    'guard pid == getpid() else { return result }', 'guard Thread.isMainThread else {', 'result[id]?.shield = .unknown',
    'MainActor.assumeIsolated {', "result[id]?.shield = .shareable; continue", 'result[id]?.shield = WindowCaptureShield.shared.isShielding(window) ? .protected : .shareable'], 'facts');
  // choose：沒有 AX 編號＝一律拒絕（指定的、沒指定的）；指定的 → 在清單裡 → 可以用 → 就是 AX 讀的那個；知道編號 → 在清單裡 → 可以用。
  // 位置大小、標題、前後順序的猜法沒有了。
  const choose = code(between(pick, 'static func choose(', 'static func sameSize('));
  ordered(choose, ['guard let focusedID else {', 'observed_window_unverifiable_without_ax_window_id', 'requested_window_unverifiable_without_ax_window_id',
    'if let requested {', 'guard let chosen = all.first(where: { $0.windowID == requested }) else {', 'requested_window_not_capturable',
    'guard chosen.facts.usable else {', 'requested_window_not_usable', 'guard focusedID == requested else {', 'requested_window_is_not_the_observed_window',
    'guard let same = all.first(where: { $0.windowID == focusedID }) else {', 'observed_window_not_capturable',
    'guard same.facts.usable else {', 'observed_window_not_usable'], 'choose');
  assert.doesNotMatch(choose, /frontToBack|focusedTitle|only_usable|same_frame_and_title|sameFrame\.filter\(\\\.facts\.usable\)/);
  assert.doesNotMatch(pick, /static func frontToBack/);
  // AX 那邊：第一個可以用的；途中碰到沒有編號的＝拒絕（不跳過、不當成可以用）。
  const axWindow = code(between(pick, 'static func axWindow<T>(', 'static func choose('));
  ordered(axWindow, ['for node in [focused, main].compactMap({ $0 }) + all {', 'case .usable: return .window(node)',
    'case .unverifiable: return .unverifiable', 'case .unusable: continue', 'return .none'], 'axWindow');
  const readState = code(between(cu, 'static func readState(', 'static func openMenus('));
  ordered(readState, ['let facts = ComputerUseWindowPick.facts(pid: pid)', 'func status(_ node: AXUIElement) -> ComputerUseWindowPick.AXStatus {',
    'guard let windowID = id(node) else { return .unverifiable }', 'return facts[windowID]?.usable == true ? .usable : .unusable',
    'if let preferredWindowID {', 'guard let wanted = windowElements.first(where: { id($0) == preferredWindowID }) else {',
    'requested_window_unverifiable_without_ax_window_id', 'requested_window_not_in_accessibility_tree',
    'guard facts[preferredWindowID]?.usable == true else {', 'requested_window_not_usable', 'window = wanted',
    'switch ComputerUseWindowPick.axWindow(focused: focused, main: main, all: windowElements, status: status) {',
    'case .unverifiable:', 'observed_window_unverifiable_without_ax_window_id',
    // 讀樹之前就決定（拒絕在 walk 之前）。
    'let bounds = try window.map', 'if windowID.flatMap({ facts[$0] })?.disclosable == true {', 'if includeTree, let window { try walk(window, depth: 0) }'], 'readState');
  assert.doesNotMatch(readState, /\?\.usable \?\? true/);
  assert.match(readState, /serverFrame: chosenID\.flatMap \{ ComputerUseWindowPick\.serverFrame\(windowID: \$0, owner: pid\) \}\)/);
  // observe：正式的 read（w183-ui 也釘）→ choose → 擷取 → 同一個視窗編號 → 敏感頁 → 回傳當下的 facts：有視窗就要有編號、要可以用 →
  // publish → windows 經過輸出過濾。image:false 走同一條（讀樹在擷取之前、回傳前的驗證不看有沒有截圖）。
  const observe = code(between(cu, 'private func observe(_ grant', '/// A sheet abort'));
  ordered(observe, ['try refuseSelfWhileSensitive(grant)', 'try ComputerUseNative.read(pid: pid, expectedTarget: target,',
    'try read(grant.pid, target, deadline, false, preferred)', 'catch let failure as ComputerUseFailure',
    'requestedWindowID == nil && preferred != nil && failure.code.hasPrefix(ComputerUseWindowPick.failurePrefix)', 'preferredWindow = nil',
    'if before.window != nil, includeImage {', 'server: .unknown))',
    'switch ComputerUseWindowPick.choose(candidates, focusedID: before.windowID, focusedFrame: before.frame,', 'case .unresolved(let reason, let list):',
    'focusedFacts: candidates.first { $0.windowID == before.windowID }?.facts))', 'SCScreenshotManager.captureImage',
    'try read(grant.pid, target, deadline, true, preferred)', 'before.windowID == after.windowID,', 'windowID == nil || after.windowID == windowID else {',
    'try refuseSelfWhileSensitive(grant)', 'let disclosure = ComputerUseWindowPick.facts(pid: grant.pid)', 'if after.window != nil {',
    'guard let observedID = after.windowID else {', 'observed_window_unverifiable_without_ax_window_id',
    'guard disclosure[observedID]?.usable == true else {', 'observed_window_not_usable', 'try session.publish(',
    '"windows": after.windowPayload(disclosing: disclosure)'], 'observe');
  assert.doesNotMatch(observe, /after\.windowPayload,|if let observedID = after\.windowID, !/);
  // 自測入口只在 DEBUG，只給自己這個行程，走同一個 observe、讀樹換成同一個 readState。
  const hook = between(cu, '#if DEBUG\n    /// 自測（DEBUG 才有）：走正式的 observe 整段', '#endif');
  assert.match(hook, /guard grant\.pid == getpid\(\) else \{ throw ComputerUseFailure\("computer_target_denied"\) \}/);
  assert.match(hook, /return try await observe\(grant, target: ComputerUseTarget\(bundleIdentifier: "w184cu self-test"\)/);
  assert.match(hook, /try ComputerUseNative\.readState\(\.current, deadline: deadline, includeTree: includeTree,/);
  // 統一的輸出過濾：成功回應的 windows、錯誤的候選、錯誤裡 AX 讀的那個視窗都走 disclosed。
  const disclosed = code(between(pick, 'static func disclosed(', 'struct Candidate: Equatable'));
  assert.match(disclosed, /guard let facts, facts\.disclosable else \{\s*var row: \[String: Any\] = \["protected": true\]\s*if let windowID \{ row\["windowID"\] = Int\(windowID\) \}\s*return row\s*\}\s*return full\(\)/);
  const failure = code(between(pick, 'static func failureCode(', 'nonisolated static let failurePrefix'));
  assert.match(failure, /let focused = disclosed\(windowID: focusedID, facts: focusedID == nil \? nil : focusedFacts\) \{/);
  assert.match(failure, /let rows: \[\[String: Any\]\] = candidates\.map \{ candidate in\s*disclosed\(windowID: candidate\.windowID, facts: candidate\.facts\) \{/);
  const payload = code(between(cu, 'func windowPayload(disclosing facts:', 'static func busyState('));
  assert.match(payload, /var row = ComputerUseWindowPick\.disclosed\(windowID: item\.windowID, facts: item\.windowID\.flatMap \{ facts\[\$0\] \}\) \{/);
  assert.match(payload, /row\["index"\] = index/);
  assert.match(code(between(pick, 'static func failure(reason:', 'static func reason(of')), /focusedFacts: focusedID\.flatMap \{ id in all\.first \{ \$0\.windowID == id \}\?\.facts \}/);
  // windowID：MCP 結構、App 的參數驗證、控制器（看得到才記住；停止、換目標、focus_window 放掉）。
  const server = read('Engines/os-mcp/server.mjs');
  assert.match(server, /windowID: \{ type: 'integer', minimum: 1, maximum: 4294967295,/);
  assert.match(server, /擋擷取的只有 windowID 與 protected，指定它會被拒絕/);
  assert.match(server, /含讀不到擋擷取狀態/);
  assert.match(model, /_ = try ComputerUseNative\.windowIDParameter\(params\["windowID"\]\)\s*allowed = \["callerThreadID", "sessionID", "windowID"\]/);
  assert.match(cu, /if let requested, granted == grant \{ preferredWindow = \(grant\.id, requested\) \}/);
  assert.equal((cu.match(/preferredWindow = nil/g) ?? []).length, 5);
  assert.match(cu, /if case \.focusWindow = request \{ preferredWindow = nil \}/);
  // DEBUG 的模擬開關只在 DEBUG 裡。
  assert.match(pick, /#if DEBUG\n\/\/\/ 自測用（DEBUG 才有；正式版沒有這段）[\s\S]*enum ComputerUseSelfTestHooks \{[\s\S]*#endif\s*$/);
  assert.match(cu, /#if DEBUG\s*if ComputerUseSelfTestHooks\.windowIDUnavailable \{ return nil \}[^\n]*\n\s*#endif\s*guard let windowIDSymbol else \{ return nil \}/);
  assert.match(pick, /#if DEBUG\s*if ComputerUseSelfTestHooks\.sharingUnknown\(CGWindowID\(number\)\) \{ sharing = nil \}[^\n]*\n\s*#endif/);
});

test('4. event targets: every synthesized event goes to a window resolved by number (observed window, a menu\'s own window, a popover\'s own window); unresolved = refused; no point search anywhere', () => {
  const geometry = code(between(cu, 'struct EventGeometry: Sendable {', '/// W184 CU：computer_observe 的選填 windowID'));
  assert.match(geometry, /let serverFrame: CGRect\s*let windowID: CGWindowID/);
  assert.match(geometry, /func serverPoint\(_ ax: CGPoint\) -> CGPoint \{\s*CGPoint\(x: ax\.x - axFrame\.minX \+ serverFrame\.minX, y: ax\.y - axFrame\.minY \+ serverFrame\.minY\)\s*\}/);
  assert.match(geometry, /func target\(\) throws -> ComputerUseBackgroundEvents\.Target \{\s*try ComputerUseBackgroundEvents\.target\(pid: pid, windowID: windowID, bounds: serverFrame\)\s*\}/);
  assert.match(cu, /func eventGeometry\(\) throws -> EventGeometry \{\s*guard let windowID, let serverFrame else \{ throw ComputerUseFailure\(ComputerUseNative\.eventTargetUnresolved\) \}/);
  // 元素的事件視窗：選單 → 選單自己的視窗（選單層級、位置大小＝AXMenu 平移座標差、剛好一個、可以用）；觀察的視窗；別的視窗 → 自己的編號、這個行程、可以用、大小一樣。
  const element = code(between(cu, 'static func eventGeometry(for node: AXUIElement', 'static func eventTarget(forWindow'));
  ordered(element, ['let observed = try state.eventGeometry()', 'if role == kAXMenuRole {', 'ComputerUseWindowPick.menuWindow(',
    'windows: ComputerUseWindowPick.popUpMenuWindows(pid: state.pid)),', 'ComputerUseWindowPick.stillUsable(windowID: menuWindow.0, pid: state.pid) else {',
    'throw ComputerUseFailure(eventTargetUnresolved)', 'if role == kAXWindowRole { break }', 'kAXWindowAttribute', 'kAXTopLevelUIElementAttribute',
    'if let window = state.window, CFEqual(owner, window) { return observed }', 'guard let id = windowID(of: owner) else { throw ComputerUseFailure(eventTargetUnresolved) }',
    'guard ComputerUseWindowPick.stillUsable(windowID: id, pid: state.pid),', 'let server = ComputerUseWindowPick.serverFrame(windowID: id, owner: state.pid),',
    'ComputerUseWindowPick.sameSize(ax, server) else {'], 'eventGeometry(for:)');
  const menuWindow = code(between(pick, 'static func menuWindow(', 'enum AXStatus'));
  assert.match(menuWindow, /let expected = axMenuFrame\.offsetBy\(dx: offset\.dx, dy: offset\.dy\)\s*let matches = windows\.filter \{ ComputerUseNative\.sameFrame\(\$0\.1, expected\) \}\s*return matches\.count == 1 \? matches\[0\] : nil/);
  // 選單：hit test 用 AX 座標（視窗伺服器座標減座標差），碰到的 AXMenu 要跟那個選單視窗一模一樣；沒有座標差＝不讀。
  const menus = code(between(cu, 'static func openMenus(', 'struct Key: Sendable'));
  ordered(menus, ['for (id, bounds) in ComputerUseWindowPick.popUpMenuWindows(pid: pid) {', 'search: for offset in offsets {',
    'for point in menuProbePoints(serverBounds: bounds, offset: offset) {', 'AXUIElementCopyElementAtPosition(scope, Float(point.x), Float(point.y), &hit)',
    'ComputerUseWindowPick.menuWindow(axMenuFrame: menuFrame, offset: offset, windows: [(id, bounds)]) != nil'], 'openMenus');
  assert.match(menus, /let ax = bounds\.offsetBy\(dx: -offset\.dx, dy: -offset\.dy\)/);
  const tree = code(between(cu, 'static func readState(', 'static func openMenus('));
  ordered(tree, ['var offsets: [CGVector] = []', 'let server = ComputerUseWindowPick.serverFrame(windowID: windowID, owner: pid),',
    'ComputerUseWindowPick.sameSize(server, item.frame) else { continue }', 'let offset = CGVector(dx: server.minX - item.frame.minX, dy: server.minY - item.frame.minY)'], 'offsets');
  // 用點找視窗的舊做法整個拿掉。
  assert.doesNotMatch(events, /static func target\(pid: pid_t, at point: CGPoint\)|windowContaining|ignoresMouse\(windowNumber/);
  assert.doesNotMatch(cu, /ComputerUseBackgroundEvents\.target\(pid: [^,]*, at:|target\(axPoint:/);
  assert.match(events, /static func target\(pid: pid_t, windowID: CGWindowID, bounds: CGRect\) throws -> Target \{[\s\S]*?return Target\(psn: psn, windowID: UInt32\(windowID\), windowBounds: bounds\)\s*\}/);
  // 指標路徑：每個點都帶它自己的事件視窗（圖片座標＝觀察的視窗；元素＝elementGeometry）；事件送 target.target()、座標都經 target.serverPoint；
  // 拖曳兩端要同一個視窗。
  const input = code(between(pointer, 'static func input(_ request: Request', undefined));
  ordered(input, ['func resolve(_ location: Location) throws -> (point: CGPoint, geometry: ComputerUseNative.EventGeometry) {',
    'case .point(let x, let y):', 'imageHeight: observation.imageHeight, frame: bounds), geometry)', 'case .element(let index):',
    'let node = try element(index)', 'return (CGPoint(x: rect.midX, y: rect.midY), try elementGeometry(node))', 'let (from, target) = try resolve(request.from)'], 'pointer resolve');
  assert.equal((input.match(/let receiver = try target\.target\(\)/g) ?? []).length, 3);
  assert.match(input, /let point = target\.serverPoint\(axPoint\)\s*guard let event = CGEvent\(mouseEventSource: source, mouseType: type,\s*mouseCursorPosition: point, mouseButton: button\)/);
  assert.match(input, /let at = target\.serverPoint\(from\)[\s\S]*?ComputerUseBackgroundEvents\.mouse\(receiver, right \? \.rightDown : \.leftDown, at: at,/);
  assert.match(input, /ComputerUseBackgroundEvents\.scroll\(receiver, at: at, dx: request\.dx, dy: request\.dy\)/);
  assert.match(input, /event\.location = target\.serverPoint\(from\)/);
  ordered(input, ['let (to, end) = try resolve(destination)', 'guard end.windowID == target.windowID else { throw ComputerUseFailure(ComputerUseNative.eventTargetUnresolved) }',
    'let receiver = try target.target()'], 'drag same window');
  assert.match(input, /at: target\.serverPoint\(point\), eventNumber: number\)/);
  assert.match(input, /up\.location = target\.serverPoint\(point\)/);
  assert.doesNotMatch(input, /geometry\.serverPoint|geometry\.target/);
  assert.match(code(between(cu, 'case .pointer(let pointer):', 'case .setValue(let index, let text):')),
    /geometry: try state\.eventGeometry\(\),\s*check: check, element: checkedElement,\s*elementGeometry: \{ try eventGeometry\(for: \$0, state: state, deadline: deadline\) \},/);
  // 按鍵的 believer：自己的視窗照觀察的編號；其他（面板服務、別的視窗）照它自己的編號；確認不了＝沒有 believer。
  assert.match(cu, /if keyPID == grant\.pid, sameWindow\(keyWindow, state\.window\) \{\s*believer = try\? state\.eventGeometry\(\)\.target\(\)\s*\} else \{\s*believer = try\? eventTarget\(forWindow: keyWindow, pid: keyPID, deadline: deadline\)\s*\}/);
  const believer = code(between(cu, 'static func eventTarget(forWindow', '/// W184 CU：computer_observe 的選填 windowID'));
  assert.match(believer, /guard let id = windowID\(of: window\), let server = ComputerUseWindowPick\.serverFrame\(windowID: id, owner: pid\),\s*let ax = try\? frame\(window, deadline: deadline\), ComputerUseWindowPick\.sameSize\(ax, server\) else \{\s*throw ComputerUseFailure\(eventTargetUnresolved\)/);
  assert.ok(cu.includes('"computer_user_active_wait_then_retry", "computer_sensitive_page_open", "computer_event_target_unresolved"'));
  // 自測的事件紀錄只在 DEBUG。
  assert.match(events, /#if DEBUG\s*ComputerUseSelfTestHooks\.record\(/);
});

test('security gates unchanged: sensitive page, full access for self, selected local chat (baseline selfOperated exception kept)', () => {
  assert.match(cu, /sensitivePageOpen && lane == \.externalApplication && pid == ownPID/);
  assert.match(cu, /guard Self\.refusesSelf\(pid: grant\.pid, lane: grant\.lane, sensitivePageOpen: BrowserSensitivePageGate\.isActive\) else \{ return \}/);
  assert.match(cu, /if Self\.isSelf\(requestedTarget\), BrowserSensitivePageGate\.isActive \{ throw ComputerUseFailure\(Self\.sensitivePageCode\) \}/);
  assert.match(read(app + 'New/ComputerUseTarget.swift'), /guard !deniedIdentifiers\.contains\(normalized\), !isSelf \|\| allowSelf else \{/);
  assert.match(model, /allowSelfTarget: permissionPreset == \.fullAccess,/);
  assert.match(model, /guard isLive, mode == \.chat \|\| selfOperated, selectedRemote == nil, selectedThreadID == caller \|\| selfOperated,/);
  assert.match(cu, /guard contextIsCurrent\(\) else \{ throw ComputerUseFailure\("computer_local_chat_required"\) \}/);
  assert.match(cu, /selfTargetPermitted: @escaping @MainActor \(\) -> Bool = \{ false \},/);
});

test('6. executable self-test w184cu: registered, DEBUG only, real menus through production paths, the counterexamples for findings 1–5, watchdog; C4 stays a SKIP that is not completion', () => {
  assert.match(selfTest, /TATWO2_SELFTEST"\] == "w184cu"[\s\S]{0,200}ComputerUseSelfTargetAcceptance\.run\(\)/);
  assert.ok(acceptance.startsWith('#if DEBUG'));
  assert.ok(acceptance.trimEnd().endsWith('#endif'));
  // A：反例（GCD 主佇列）與正式的排程都開真的選單、量 bridge 式的 main.sync。
  assert.match(acceptance, /DispatchQueue\.main\.async \{ _ = fixture\.circle\.accessibilityPerformShowMenu\(\) \}/);
  assert.match(acceptance, /ComputerUseNative\.performOnMainRunLoop \{ _ = fixture\.circle\.accessibilityPerformShowMenu\(\) \}/);
  assert.match(acceptance, /DispatchQueue\.global\(qos: \.userInitiated\)\.async \{ DispatchQueue\.main\.sync \{\}; synced\.signal\(\) \}/);
  // B：正式的 readState／backgroundInput／input／performAction 都帶 authority；反例是舊做法的 AX 呼叫。
  for (const needle of ['ComputerUseNative.readState(running', 'ComputerUseNative.backgroundInput(request, observation: observation, authority: auth',
    'ComputerUseNative.input(request, observation: observation, authority: auth', 'ComputerUseNative.performAction(third.elements[index], "AXShowMenu", authority: auth)',
    'act(.axAction(circle, "AXShowMenu")', 'act(.pressKey(escape)', '.init(kind: .rightClick', '.accessibilityAction(.showMenu) { anchor.showMenu(menu) }',
    'DispatchQueue.main.async { _ = AXUIElementPerformAction(node, "AXShowMenu" as CFString) }']) {
    assert.ok(acceptance.includes(needle), needle);
  }
  // 反例（GPT-6 1–5）：每一條都要在，而且是「期待拒絕／作廢」，不是期待選中。
  const counterexamples = [
    'B10 counterexample: permission downgraded', 'B10 counterexample: the request disconnected', 'B10 counterexample: the context changed',
    'B10 counterexample: a sensitive page appeared', 'B10 counterexample: the grant was stopped', 'B10 Stop while the modal is open',
    'B11 a synthesized right-click by image coordinates goes to the observed window itself',
    'B12 counterexample: when 甲 and 乙 are indistinguishable', 'B12 counterexample: the element left the window',
    'B13 counterexample (GPT-6 re-check #4, the key path)', 'B13 counterexample (GPT-6 re-check #4): a menu item\'s event window is the menu\'s own pop-up window',
    'B13 counterexample: a drag from the menu item into the observed window spans two windows', 'B13 the production pointer path sends the click on menu item 乙', 'B13 the receiver is the menu: that synthesized click',
    'C0 counterexample (GPT-6 re-check #1): the window server\'s sharing state is three-valued', 'C0 counterexample: unknown protection is refused and masked',
    'C1 counterexample (GPT-6 #1)', 'C1 counterexample (GPT-6 #5, re-check #3)',
    'C3 counterexample: a window this test made capture-protected', 'C3 counterexample (GPT-6 re-check #1): WindowCaptureShield still holds',
    'C3 counterexample (GPT-6 #1) on real windows', 'C3 counterexample: readState refuses a requested windowID', 'C3 counterexample (GPT-6 #1, the linger)',
    'C5 counterexample: searching the window list with the AX point', 'C5 counterexample (GPT-6 re-check #4): an observation without its window number',
    'C6 counterexample (GPT-6 re-check #4, 1020 apart)',
    'C7 counterexample (GPT-6 re-check #2)', 'C7 counterexample (GPT-6 re-check #1)', 'C7 counterexample (GPT-6 re-check #3)',
    'E counterexample (GPT-6 #2): setting the real ChatPageModel.permissionPreset'];
  for (const label of counterexamples) assert.ok(acceptance.includes(label), label);
  assert.match(acceptance, /flags\.permitted = false \}/);
  assert.match(acceptance, /model\.permissionPreset = \.approveForMe\s*let voidedAtOnce = !S\.isPending\(token\) && S\.pendingCount == 0/);
  assert.match(acceptance, /WindowCaptureShield\.shared\.hold\(lingerHolder, window: normal\)[\s\S]*?WindowCaptureShield\.shared\.release\(lingerHolder\)[\s\S]*?held == "requested_window_not_usable" && lingering == "requested_window_not_usable"/);
  // C3 的保護驗證不依待測結果跳過（GPT-6 複核 #5）：沒有 protectedObservable、受保護 fixture 的判定無條件 check。
  assert.doesNotMatch(acceptance, /protectedObservable|視窗伺服器讀不到 sharingType/);
  assert.match(acceptance, /check\(f\[4\]\?\.server == \.protected && f\[4\]\?\.captureProtected == true && f\[4\]\?\.usable == false,/);
  // C7 走控制器的 observe（DEBUG 入口），模擬開關用完一定還原。
  assert.match(acceptance, /controller\.observeForSelfTest\(grant, includeImage: image, requestedWindowID: requested\)/);
  assert.match(acceptance, /defer \{\s*H\.setSharingUnknown\(\[\]\)\s*H\.windowIDUnavailable = false\s*controller\.stop\(\)\s*\}/);
  // 要權限的段落沒有權限＝SKIP 寫原因（不是 PASS）；C4 的 SKIP 寫明沒完成、主導實機驗。
  assert.match(acceptance, /if AXIsProcessTrusted\(\) \{[\s\S]*?\} else \{\s*check\.skip\(/);
  assert.match(acceptance, /if CGPreflightScreenCaptureAccess\(\) \{[\s\S]*?\} else \{\s*check\.skip\("C4 [^"]*這一條沒完成，主導實機驗"\)/);
  // 看門狗：卡住就 FAIL 退出，不讓驗證一直等。
  assert.match(acceptance, /print\("W184CU FAIL watchdog:/);
  assert.match(acceptance, /print\("W184CU SUMMARY failures=\\\(check\.failed\) passed=\\\(check\.passed\) skipped=\\\(check\.skipped\)"\)/);
});

test('os-mcp transport: computer_observe windowID reaches the App as given, malformed ones never do', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'w184cu-transport-'));
  try {
    const run = spawnSync(process.execPath, [path.join(root, 'Engines/os-mcp/computer-use-test.mjs')],
      { encoding: 'utf8', timeout: 60000, env: { ...process.env, TATWO2_CALLER_TRANSPORT_ROOT: dir } });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.match(run.stdout, /COMPUTER-MCP TRANSPORT PASS: \d+ cases, 0 failed/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
