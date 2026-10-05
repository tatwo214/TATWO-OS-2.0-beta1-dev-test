// W183 R12 第一批（.032 實機驗收後；主導 1、3、5）：連線用雙頁排法（通用的任務版面機制）、ChatGPT 改了說明文字的卡、重連不多建連接器。
// 靜態守：行為在 w183connect、w184forms、w184browser 自測與 tests/w183-connect.test.mjs（真的 Pod 腳本）驗。
import { test } from 'node:test';
import { nativeW214 } from './w214-native-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const swift = (path) => read('App/Sources/Tatwo2/' + path);
const code = (source) => source.split('\n').filter((line) => !line.trim().startsWith('//') && !line.trim().startsWith('///')).join('\n');
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : -1;
  return source.slice(from, to > from ? to : undefined);
};

const layout = swift('DM/GlobalDMTaskLayout.swift');
const phoneBox = swift('DM/GlobalDMPhoneBox.swift');
const dmView = swift('New/HandsConnectDMView.swift');
const browserView = swift('DM/DMBrowserView.swift');
const connect = swift('Facade/HandsConnect.swift');
const memory = swift('Facade/HandsConnectMemory.swift');
const pod = swift('TAP/ChatGPTConnectorPod.swift');

test('R12 1: a generic task layout — begin mounts the task card on the left page, want switches to the task form (typing waits), end restores unless the user moved; the chat column is covered, never rebuilt', () => {
  assert.match(layout, /struct GlobalDMTask: Hashable, Sendable \{\s*let id: String[\s\S]*?let form: GlobalDMForm/);
  assert.match(layout, /static let connect = GlobalDMTask\(id: "connect", form: \.innerLandscape\)/);
  for (const name of ['func register(_ task: GlobalDMTask, page:', 'func begin(_ task: GlobalDMTask, on store: GlobalDMStore)', 'func want(_ task: GlobalDMTask)', 'func end(_ task: GlobalDMTask)']) {
    assert.ok(layout.includes(name), name);
  }
  // 左頁只在兩頁的形態、只蓋掛著任務的那個框。
  assert.match(layout, /guard let task, form\.isDuo, owner === store else \{ return nil \}/);
  // 使用者自己換的形態＝結束時不改回；打字、組字中延後。
  assert.match(between(layout, 'private func formChanged(', '}\n}'), /if task != nil, original != nil \{ userMoved = true \}/);
  assert.match(between(layout, 'func end(_ task: GlobalDMTask) {', 'private func switchTo('), /guard let back, !moved, dependencies\.form\(\) == task\.form else \{ return \}/);
  assert.match(between(layout, 'private func switchTo(', 'private func retry('), /if dependencies\.busyTyping\(\) \{/);
  assert.match(layout, /GlobalDMPanelController\.isComposing\(in: \$0\)/);
  // 私訊那一欄不拆（蓋著、點不到、不唸），左欄永遠是同一個 GlobalDMBox。
  assert.match(layout, /\.opacity\(page == nil \? 1 : 0\)\s*\.allowsHitTesting\(page == nil\)\s*\.accessibilityHidden\(page != nil\)/);
  assert.match(phoneBox, /GlobalDMTaskCover\(store: store\) \{\s*GlobalDMBox\(store: store, model: model, surface: surface, role: form\.isDuo \? \.duoLeading : \.single\)\s*\}/);
});

test('R12 1: the connect task — in process + needs the web → inner landscape; card on the left page (no sheet, nothing on the web); connected or hidden → task ends; one column → the page stops above the card', () => {
  assert.match(dmView, /taskLayout\.begin\(\.connect, on: store\)/);
  assert.match(dmView, /if inProcess \{ taskLayout\.want\(\.connect\) \}/);
  assert.match(between(dmView, 'func hide() {', 'private func requestBox()'), /taskLayout\.end\(\.connect\)/);
  assert.match(between(dmView, 'func markDone() {', '/// 正式：Pod 的原生回報'), /taskLayout\.end\(\.connect\)/);
  assert.match(dmView, /var showsSheet: Bool \{ isShown && currentCard\(\) != nil && !floatsInBrowser && !onLeftPage \}/);
  assert.match(dmView, /var cardWithBrowser: Bool \{ floatsInBrowser && !onLeftPage \}/);
  assert.match(browserView, /guard connect\.cardWithBrowser, !showingTabList, let tab = browser\.activeTab else \{ return false \}/);
  assert.match(browserView, /pageFrame\(toolbar: toolbar, yield: card == nil \? nil : cardTop\.map \{ max\(0, size\.height - \$0 \+ DMBrowserPhone\.pageSide\) \}\)/);
  // 自測自己建的框不動到這台的形態設定。
  assert.match(dmView, /self\.taskLayout = taskLayout \?\? \(store === GlobalDMStore\.shared \? \.shared : \.inert\(\)\)/);
  // 收起私訊框：等的時間不倒數（只算網頁在畫面上的時間）、流程不取消。
  assert.match(dmView, /var webOnScreen: Bool \{ store\.isShowingBox && browser\.shownSurface != nil \}/);
  assert.match(between(connect, 'private func awaitAuthorize(', 'private func pairing('), /if presenter\.webOnScreen \{ shown \+= max\(0, now\.timeIntervalSince\(last\)\) \}/);
  // 左頁：整頁高度、自己捲；進度寫第幾步／共幾步；「上面的頁面」在兩頁說「右邊的頁面」。
  assert.match(dmView, /"第 \\\(min\(max\(step, 0\), total - 1\) \+ 1\) 步／共 \\\(total\) 步"/);
  assert.match(dmView, /\.replacingOccurrences\(of: "上面的頁面", with: "右邊的頁面"\)/);
});

test('R12 3: the changed-text card shows the full plain text (verbatim) with a glass-chip 同意並繼續; agreeing stores only a SHA-256 and resumes with the exact print; the same version later resumes by itself (once)', () => {
  assert.match(connect, /case consent\(HandsConsentOffer\)/);
  assert.match(connect, /var digest: String \{ HandsAuth\.sha256Hex\(Data\(\("tatwo-connect-consent\|" \+ print\)\.utf8\)\) \}/);
  const wait = between(connect, 'private func waitForUserWarning(', 'private func waitUserTimer(');
  assert.match(wait, /if ack\.approved != offer\.print, dependencies\.consentApprovals\?\.contains\(offer\.digest\) == true \{/);
  assert.match(wait, /card = \.consent\(offer\)/);
  const approve = between(connect, 'func approveConsent() {', 'private func resumeWithConsent(');
  assert.match(approve, /dependencies\.consentApprovals\?\.insert\(offer\.digest\)\s*continueAfterUser\(ack: ack\.approving\(offer\.print\)\)/);
  assert.match(dmView, /Text\(verbatim: offer\.text\)/);
  assert.match(dmView, /GlobalDMChipButton\(title: HandsConnectCardFace\.consentAction\) \{ actions\.approveConsent\(\) \}/);
  assert.doesNotMatch(code(between(dmView, 'private func consent(_ offer: HandsConsentOffer)', 'private func consentText(')), /\.borderedProminent|\.tint\(\.blue\)|Color\.blue/);
  assert.match(pod, /if let approved = acknowledged\?\.approved \{ arguments\["approved"\] = approved \}/);
  assert.match(pod, /nonisolated static func carrying\(_ action: HandsConnectorAction, approved: String\?\) -> HandsConnectorAction \{/);
  assert.match(memory, /static let shared = HandsConnectDigestBook\(url: HandsPaths\.default\.appDir\.appendingPathComponent\("connect-consent-approvals\.json"\), maxEntries: 16\)/);
});

test('R12 5: pressing Create stays remembered; missing entry only offers an explicit, scoped, one-run rebuild', () => {
  assert.match(memory, /HandsAuth\.sha256Hex\(Data\(\("tatwo-connect-pending\|" \+ createKey\)\.utf8\)\)/);
  const run = between(connect, 'if let match = scan.matches.first {', '// 開窗口之前再看一次帳號');
  assert.match(run, /forgetPendingCreate\(createKey\)/);
  // W183 R12（.036）：接著同一張表單做（帶著確認）不算再建一次（撞名改名之後、同意說明之後要能接著走）。
  assert.match(run, /\} else if ack == nil, allowCreateAfterMissing == nil, hasPendingCreate\(createKey\) \|\| nameInUse != nil \{[\s\S]*?reconnectByName = true/);
  const missing = between(connect, 'if case .notFound(let step) = action,', '\n        } else {');
  assert.match(missing, /step == "open" \|\| step == "by_name"/);
  assert.match(missing, /recovery: MissingCreateRecovery\(key: createKey, generation: attemptGeneration\)/);
  assert.doesNotMatch(missing, /forgetPendingCreate|\.remove\(/);
  assert.match(connect, /let rebuild = !manual && retryWillRebuild \? missingCreateRecovery : nil/);
  assert.match(connect, /var retryWillRebuild: Bool/);
  assert.match(connect, /recovery\.key == identity \+ "\|" \+ url && recovery\.generation == dependencies\.loginGeneration\(\)/);
  assert.match(connect, /if action == \.pressed \|\| action == \.unknown \{\s*allowCreateAfterMissing = nil\s*namedReconnectResume = nil\s*\}/);
  const continuation = between(connect, 'private func continueAfterUser(ack:', 'func invalidate(');
  assert.match(continuation, /let rebuild = allowCreateAfterMissing/);
  assert.match(continuation, /keepPod: true,\s*rebuild: rebuild, named: named/);
  assert.match(continuation, /let named = namedReconnectResume/);
  assert.match(connect, /guard !manual, keepPod, rebuild == nil, named\.accepts\(ack\)/);
  assert.match(connect, /reconnectByName = namedReconnectResume != nil/);
  assert.match(between(connect, 'private func endRun()', 'private func stop('), /missingCreateRecovery = nil\s*allowCreateAfterMissing = nil/);
  assert.match(connect, /找不到不等於不存在/);
  // 這裡只是補充的原始碼守門；狀態轉換的反例在 App 的 r12MissingNameRecovery。
  const behavior = swift('Facade/HandsConnectR12Acceptance.swift');
  assert.match(behavior, /try await r12MissingNameRecovery\(check, base\)/);
  assert.match(connect, /if existing == nil, action == \.pressed \|\| action == \.unknown \{ notePendingCreate\(createKey\) \}/);
  // W183 R12（.033 實機）：後面多接一個 connectLog: .shared（正式版的連線紀錄）。
  assert.match(connect, /pendingCreateBook: HandsPendingCreates\.shared[,)]/);
});

// ---------- W183 R12 第二批（主導 2：亮框指路；主導 4：拿掉 L0／L1／L2） ----------

const config = swift('Facade/HandsBuildConfig.swift');
const build = swift('New/ChatGPTBuildSection.swift');
const buildModel = swift('Facade/HandsBuildModel.swift');
const controller = swift('Facade/HandsBuildController.swift');
const tap = swift('TAP/ChatGPTTap.swift');

test('R12 4: no level choice — the ChatGPT Dev panel shows one plain line, the confirm card writes abilities (no level capsule), the status writes abilities; the central config unifies every device at L2 once and raises only through the R11 check', () => {
  // 面板：L0／L1／L2 那一排拿掉，一行白話（跟確認卡同一句）；W214 拿掉下面的狀態說明列。
  assert.match(build, /Text\(HandsBuildCopy\.capabilities\)/);
  assert.doesNotMatch(code(build), /levelChip|HandsBuildUIIntent\.level\(|ForEach\(0\.\.\.HandsSettings\.maxLevel|HandsState\.levelLabel/);
  assert.match(nativeW214(4), /W214 PASS N4.no-project-chips-or-detail-rows.true/);
  assert.match(buildModel, /static var capabilities: String \{ HandsConnectAbility\.line\(level: HandsBuildConfig\.defaultLevel\) \}/);
  assert.match(connect, /case 2: "連上後：看全部專案・可用 Codex・記憶只讀＋收件匣"/);
  assert.match(buildModel, /static func connected\(_ level: Int\) -> String \{ "已連線・" \+ HandsConnectAbility\.words\(level: level\) \}/);
  assert.match(controller, /if connected\.count == selected\.count \{ return HandsBuildCopy\.connected\(actualLevel\) \}/);
  assert.match(controller, /guard let info = report\(device\.id\), !info\.levelGuard else \{ return false \}/);
  // 確認卡：不畫能力／等級膠囊，一行能力；無障礙也不唸等級；交易類那一句不寫（L0）。
  const confirm = between(dmView, 'struct HandsConnectConfirmContent: View {', 'struct HandsConnectRoute: View {');
  assert.doesNotMatch(code(confirm), /HandsConnectAbilityChips|HandsState\.levelLabel|（L0）/);
  assert.match(confirm, /static func line\(_ offer: HandsConnectOffer\) -> String \{ HandsConnectAbility\.line\(level: offer\.scope\.level\) \}/);
  assert.doesNotMatch(dmView, /struct HandsConnectAbilityChips/);
  // 中央設定：照一次（低於 L2 的都記成待升，L0 也算）、不直接升；升不升照 R11 同一道 raiseCheck（舊版主機一律不升）。
  const unify = between(config, 'static func unifiedLevels(_ config: HandsBuildConfig) -> HandsBuildConfig? {', 'static func raisingPending(');
  assert.match(unify, /guard config\.levelUnified != true else \{ return nil \}/);
  assert.match(unify, /for entry in config\.devices where entry\.level < defaultLevel/);
  assert.doesNotMatch(unify, /\.level = defaultLevel/, 'unifying never raises by itself (existing grants are not enlarged)');
  const raising = between(config, 'static func raisingPending(', 'static func raiseCheck(');
  assert.match(raising, /if next\.devices\[index\]\.level < defaultLevel \{/);
  assert.match(raising, /guard raiseCheck\(report, config: config, now: now\) == \.allowed else \{ return nil \}/);
  assert.match(config, /guard report\.levelGuard else \{ return \.needsUpdate \}/, 'old hosts are never raised');
  assert.match(config, /if let unified = HandsBuildConfig\.unifiedLevels\(valid\), \(try\? save\(unified\)\) != nil \{ valid = unified \}/);
  assert.match(config, /migratedFromLegacy: nil, levelDefault: defaultLevel,\s*levelUnified: true\)/);
  assert.match(config, /case levelUnified = "level_unified"/);
});

test('R12 2: the human-click step is pointed at, never clicked — the Pod script finds and measures the one button, CEF verifies the same spot (one enabled button), then the script draws a ring + arrow; the card says 「點一下亮起來的「連接」」 (「右邊」 in two pages); no pointer = the old line', () => {
  // Pod 驅動：找、核（CEF 畫面快照：同一個位置剛好一顆沒停用的按鈕）、才畫；沒有任何點的方法。
  const point = between(pod, 'func pointAtGesture(url: String, name: String) async -> HandsGesturePoint {', 'func clearGesture() {');
  // W183 R12（.034 實機：亮框沒出現）：find 多帶外掛名稱（區塊找法放寬）；CEF 快照變成加分（認得到記進紀錄，認不到不當成找不到）；找不到＝結構快照。
  assert.match(point, /request\("connectorGesture", \["phase": "find", "url": url, "name": name\]/);
  assert.match(point, /confirmed = Self\.gestureControl\(snapshot, target: target, generation: generation, viewport: view\.bounds\.size\) != nil/);
  assert.match(point, /await snapshotPage\("connectorGesture", "not_found", lease: lease\)/);
  assert.match(point, /Self\.gestureControl\(snapshot, target: target, generation: generation, viewport: view\.bounds\.size\) != nil/);
  assert.ok(point.indexOf('Self.gestureControl(') > 0 && point.indexOf('Self.gestureControl(') < point.indexOf('"phase": "show"'), 'the CEF check comes before drawing');
  // W183 R12（.037 實機）：只有「Continue to <這次的名字>」那一步 TATWO 自己真的點擊（使用者按［連線］＝同意連線；ChatGPT 要的是真人手勢），
  // 腳本確認落在那一顆上；其他（Connect／連接／授權）照舊只畫亮框、不按。
  assert.doesNotMatch(code(point), /clickElement|connectorPress|evaluateJavaScript/);
  assert.ok(point.indexOf('found["kind"] as? String == "continue"') > 0 && point.indexOf('found["kind"] as? String == "continue"') < point.indexOf('view.sendClick('));
  assert.match(point, /request\("connectorGesture", \["phase": "landed"\]/);
  assert.match(pod, /controls\.contains\(where: \{ \$0\["elementID"\] as\? String == control\.elementID && \$0\["kind"\] as\? String == "button" \}\)/);
  // 網頁腳本：只標、不按；亮框點得穿過去；指令走安全回報。
  const cmd = between(tap, 'connectorGesture: async (c) => {', 'connectorOutline: async () => {');
  assert.doesNotMatch(code(cmd), /kpress|\.click\(|dispatchClick/);
  assert.match(tap, /const GESTURE = \/\^\(connect\|connect to \.\{1,80\}\|reconnect\|authorize\|連線\|/);
  assert.match(tap, /const GESTURE_SELECTOR = 'button, \[role="button"\], a\[href\], \[role="link"\]';/);
  assert.match(tap, /const RING_STYLE = 'position:fixed;pointer-events:none;z-index:2147483647;/);
  assert.match(tap, /'pluginNewMenuWatch', 'pluginNewMenuAbort', 'connectorGesture', 'connectorOutline', 'connectorTick', 'connectorInspect', 'connectorDelete'\];/);
  // 流程：網頁在畫面上等了一下才找；配對頁出來、時限到＝拿掉；手動模式不指；找不到＝照舊那一句。
  const wait = between(connect, 'private func awaitAuthorize(', 'private func pairing(');
  assert.match(wait, /let pointsGesture = !manualAttempt/);
  // W183 R12（.035 實機）：結果多一種 waiting（ChatGPT 的對話框停在等它的授權視窗）。
  // W183 R12（.036 實機；主導裁決：撞名就自動換名字重建）：名字改用 connectorNameInUse（沒改過＝「TATWO（<設備名稱>）」；撞名改過＝後面加 2…9，重連沿用本機記下的）。
  assert.match(wait, /let found = await pod\.pointAtGesture\(url: intent\.mcpURL, name: connectorNameInUse\(offer\)\)/);
  assert.match(wait, /if pointed \{ pod\.clearGesture\(\) \}\s*return await pairing\(/);
  assert.match(wait, /card = \.working\(Self\.gestureWaitText\)/);
  // W183 R12（.034 實機：真的 ChatGPT 是英文介面，那一顆寫 Connect）。
  assert.match(connect, /static let gesturePointText = "點一下亮起來的「Connect」"/);
  assert.match(dmView, /\.replacingOccurrences\(of: "點一下亮起來的", with: "點一下右邊亮起來的"\)/);
});

// ---------- W183 R12（.033 實機 09-30：連線又失敗、正式版查不到任何紀錄）：正式版的連線紀錄＋對不上時的結構快照 ----------

test('R12 connect log: release builds write one line per step (attempt code, step, result) to connect-log.txt (0600, rotated); mismatches add a page-structure snapshot (DOM text, not a screenshot); secrets are scrubbed; hands_setup_status carries the last 200 lines', () => {
  const log = swift('Facade/HandsConnectLog.swift');
  assert.match(log, /appendingPathComponent\("connect-log\.txt"\)/);
  assert.match(log, /posixPermissions: 0o600/);
  for (const rule of ['(?i)bearer', '"<email>"', '"<token>"', '"<code>"', '"$1?<…>"']) assert.ok(log.includes(rule), rule);
  // 流程：log() 不再只在 DEBUG；卡片、進度、階段每一次換都一行；配對碼、帳號不寫。
  const logFn = between(connect, 'private func log(_ text: String) {', 'nonisolated static func cardLogLine(');
  assert.match(logFn, /#endif\s*\/\/[^\n]*\n\s*dependencies\.connectLog\?\.write\("flow", text\)/);
  const cardLine = between(connect, 'nonisolated static func cardLogLine(', 'static let cancelUnknownText');
  assert.match(cardLine, /case \.pairing\(let view\): "pairing code_shown=\\\(view\.pairingCode != nil\)/);
  assert.match(cardLine, /case \.confirm\(let offer, _\):/);
  assert.doesNotMatch(cardLine, /account|\\\(view\.pairingCode\)/);
  assert.match(connect, /didSet \{\s*if card != oldValue \{\s*pairingClipboard\.clear\(\)\s*log\("card " \+ \(card\.map\(Self\.cardLogLine\) \?\? "none"\)\)\s*\}\s*\}/);
  assert.match(connect, /dependencies\.connectLog\?\.begin\(attempt: created\.attemptID\)/);
  assert.match(connect, /connectLog: \.shared[,)]/);
  // Pod：每個指令的結果一行；對不上（交回、拒絕含 press_stale、找不到、不只一個）＝結構快照；代勾找不到節點＝那一帶的控制項＋快照。
  assert.match(pod, /trace\(command, data, generation: generation\)/);
  assert.match(pod, /if Self\.needsSnapshot\(decoded\) \{ await snapshotPage\(command, HandsConnectFlow\.actionLabel\(decoded\), lease: lease\) \}/);
  assert.match(pod, /if Self\.needsSnapshot\(result\) \{ await snapshotPage\("connectorPress"/);
  assert.match(pod, /await noteNodeMiss\(target, view: view, lease: lease\)/);
  assert.match(pod, /request\("connectorOutline", \[:\], hold: lease, timeout: \.seconds\(8\)\)/);
  // 網頁腳本：快照不讀任何欄位的值；arm.check() 失敗那一刻留一份（arm 的時候那一顆 vs. 現在的按鈕）；截圖保護不動（快照是 DOM 文字）。
  assert.match(tap, /a\.desc = describeEl\(button\);/);
  assert.match(tap, /noteStale\('check:' \+ \(staleWhy \|\| '\?'\), owned\.rec, a\);/);
  assert.doesNotMatch(code(between(tap, 'const describeEl = (el) => {', 'const outlineRootOf = ')), /dValue|\.value\b|placeholder/);
  assert.match(tap, /const OUTLINE_MAX = 16384;/);
  // 給 App 與這台的引擎：hands_setup_status 帶最後 200 行（總長有上限）。
  assert.match(swift('Facade/HandsSetup.swift'), /payload\["connect_log"\] = HandsConnectLog\.shared\.tail\(200, maxTotal: 256 \* 1024\)/);
});

// ---------- W183 R12（.034 實機紀錄：代勾卡在 CEF 的節點驗證、Create 重畫、第 3 步 60 秒就放棄、過期頁、亮框沒出現） ----------

test('R12 .034: auto-tick verifies by DOM when CEF cannot see the box (native click at the re-measured centre, then DOM confirms ticked + Create enabled); Create re-found in the same form; the wait for Connect lasts the pairing window with a countdown; the expired page speaks plainly', () => {
  assert.match(pod, /target\.node = await captureTickNode\(target, lease: lease\)/);
  assert.match(pod, /clicked = await domTick\(target, view: view, lease: lease, generation: generation\)/);
  assert.match(pod, /return await tickLanded\(target\.form, view: view, lease: lease, generation: generation\) \? \.clicked : \.notClicked/);
  assert.match(pod, /after\?\["status"\] as\? String == "ok" && after\?\["checked"\] as\? Bool == true && after\?\["create"\] as\? Bool == true/);
  const aimCmd = between(tap, 'connectorTick: async (c) => {', 'connectorHome: async () => {');
  assert.doesNotMatch(code(aimCmd), /kpress|\.click\(|dispatchClick|ksetValue/, 'aiming and checking never press anything');
  assert.ok(aimCmd.indexOf("consentPrint(root) !== rec.consent") < aimCmd.indexOf('tickPoint(rec.zones[0])'), 'consent before measuring');
  assert.match(tap, /if \(now !== button && safeTag\(now\) !== safeTag\(button\)\) return stale\('create_button_replaced'\);/);
  assert.match(tap, /if \(submit\.length !== 1\) return stale\('create_buttons_' \+ Str\(submit\.length\)\);/);
  assert.match(connect, /var authorizeAppears: TimeInterval = HandsAuth\.windowLifetime/);
  assert.match(connect, /static let gestureHintShort = "點一下上面的頁面上的「Connect」"/);
  assert.match(connect, /let next = base \+ "・剩 " \+ Self\.remainingText\(intent\.expiresAt\.timeIntervalSince\(now\)\)/);
  const gateway = read('Engines/chatgpt-hands/gateway.mjs');
  assert.match(gateway, /const WINDOW_CLOSED = '這個連線請求已經過期（或還沒在 TATWO 按［連線］）。請回 TATWO 按［再連一次］/);
});

test('R12 .035: Create is pressed by a real CEF click (aim → sendClick → confirm) with the scripted press only as the logged fallback; every refused tick says why and which path ran; popups and main pages are logged by host+path; a waiting plugin dialog is not "not found"', () => {
  const press = between(pod, 'private func nativePress(', 'nonisolated static func logURL(');
  assert.ok(press.indexOf('"phase": "aim"') < press.indexOf('view.sendClick(') && press.indexOf('view.sendClick(') < press.indexOf('"phase": "confirm"'));
  // W183 R12（.036 實機）：量不到、點不中＝不退回程式按：亮起來等使用者自己按。
  assert.doesNotMatch(press, /request\("connectorPress", \["form": token\], hold/);
  assert.match(press, /return await waitForUserPress\(token, lease: lease, generation: generation\)/);
  assert.match(pod, /create aim_failed why=/);
  assert.match(tap, /if \(!\(lastTrustedClick && lastTrustedAt >= aimed\.at && pressHit\(aimed\.arm, lastTrustedClick\)\)\) return \{ status: 'not_landed' \};/);
  assert.match(connect, /static let createByUserText = "點一下亮起來的「Create」/);
  assert.match(press, /create path=native click at=/);
  assert.match(pod, /if let native = await nativePress\(token, lease: lease, generation: armedGeneration\) \{ return native \}/);
  assert.match(pod, /tick path=\\\(target\.node == nil \? "dom" : "cef"\)/);
  assert.match(pod, /tick refused why=page gen=/);
  assert.match(pod, /abs\(a\.width - b\.width\) < 1 && abs\(a\.height - b\.height\) < 1/);
  assert.match(pod, /popup opened opener_main=/);
  assert.match(pod, /return host \+ String\(url\.path\.prefix\(120\)\)/);
  const cmd = between(tap, 'connectorPress: async (cmd) => {', 'connectorConsent: async (cmd) => {');
  assert.match(cmd, /return \{ status: 'pressed', native: true, byUser: true \};/);
  assert.ok(cmd.indexOf("if (!arm.check())") < cmd.indexOf("if (phase === 'aim')"), 'aim only after every check passed');
  assert.match(tap, /if \(stuck && aSome\(boxesIn\(dialogs\[i\]\), isChecked\)\) return \{ status: 'waiting' \};/);
  assert.match(connect, /static let popupWaitText = "ChatGPT 在等它的授權視窗…/);
  assert.match(connect, /var popupWaitNotice: TimeInterval = 20/);
});

test('R12 .037: Continue to <name> is pressed by TATWO with a real click (name-bound); Create is scrolled/aimed at the visible strip; consent is compared over the risk block only; the built-but-unauthorised one is found by the remembered name', () => {
  assert.match(tap, /const CONTINUE = \/\^\(continue to \|繼續前往\|繼續到\|繼續使用\|前往\)\(\.\{1,80\}\)\$\/i;/);
  assert.match(tap, /return !!m && safeSquash\(m\[2\]\) === name;/);
  assert.match(tap, /if \(!\(right - left >= 8 && bottom - top >= 4\)\) \{ out\.why = 'off_screen'; return out; \}/);
  assert.match(tap, /const m = await measureSettled\(arm\.button\);/);
  assert.match(tap, /const seen = consentScan\(riskArea\(root\)\);   \/\/ W183 R12（\.037）：只顯示風險說明那一段/);
  assert.match(tap, /\{ id: 'en-2026-09-30-risk', area: true,/);
  assert.match(tap, /aSome\(leaves\(a\), \(el\) => safeSquash\(safeText\(el\)\) === byName\)/);
  assert.match(pod, /func reconnectByName\(url: String, name: String, acknowledged: HandsConnectorAck\?\) async -> HandsConnectorAction \{/);
  assert.match(connect, /static func continueClickedText\(_ label: String\) -> String \{/);
});
