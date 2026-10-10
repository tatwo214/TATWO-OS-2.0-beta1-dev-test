// W183 R6b：一個開關——連線安全與 Pod（App 自動建 ChatGPT 連接器、配對頁在私訊框）。
// 靜態：原始碼契約（連線意圖、主機一次一個 attempt、取消作廢未兌換的授權碼、配對碼只給擁有者、狀態輪詢沒有碼、start_pairing 對副設備停用、
//        popup 手勢保護不放寬、runPodCommand 只在 chatgpt.com、自測註冊、不寫死網域）。
// 動態：在 node:vm 裡跑真正的 Pod 腳本（ChatGPTTap.podScript）的連接器指令，用本機假頁面模擬 ChatGPT 外掛頁：
//        有／沒有開發者模式、已有同網址連接器、表單多個或找不到、網址被改、要打勾、警語、OAuth 下拉。
// 流程與配對（真的 HandsAuth／HandsConnectHost、假 Pod、真的設備簽章）在 App 自測 TATWO2_SELFTEST=w183connect（lead-verify 在 mini 跑）。
import test from 'node:test';
import { nativeW214 } from './w214-native-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import vm from 'node:vm';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = 'App/Sources/Tatwo2/';
const swift = (p) => read(app + p);
const code = (source) => source.replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^\n"]*$/gm, '');
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  return source.slice(from, to < 0 ? source.length : to);
};

const connect = swift('Facade/HandsConnect.swift');
const host = swift('Facade/HandsConnectHost.swift');
const links = swift('Facade/HandsConnectLinks.swift');
const auth = swift('Facade/HandsAuth.swift');
const service = swift('Facade/HandsService.swift');
const state = swift('Facade/HandsState.swift');
const remote = swift('Facade/HandsRemote.swift');
const tap = swift('TAP/ChatGPTTap.swift');
const podDriver = swift('TAP/ChatGPTConnectorPod.swift');
const webPod = swift('TAP/TapWebPod.swift');
const dmView = swift('New/HandsConnectDMView.swift');
const webSheet = swift('DM/GlobalDMWebSheet.swift');
const sensitive = swift('Browser/BrowserSensitivePage.swift');
const acceptance = swift('Facade/HandsConnectAcceptance.swift');
const selftest = swift('SelfTest.swift');
const bridge = swift('Facade/OSAgentBridge.swift');
const mcpServer = read('Engines/os-mcp/server.mjs');
const contract = read('docs/specs/183-chatgpt-hands/contract.md');
const threat = read('docs/specs/183-chatgpt-hands/threat-model.md');

// ---------- 靜態：接口與安全界線 ----------

test('interface: HandsConnectFlow keeps the R6a names and meanings (offer, cancel(reason:), phase, problem)', () => {
  for (const phase of ['idle', 'waitingTap = "waiting_tap"', 'waitingUser = "waiting_user"', 'creatingConnector = "creating_connector"',
    'waitingPairing = "waiting_pairing"', 'verifying', 'connected', 'needsManual = "needs_manual"', 'refused', 'failed']) {
    assert.ok(connect.includes(`case ${phase}`), phase);
  }
  assert.match(connect, /struct HandsConnectIntent: Sendable, Equatable \{\s*let attemptID: UUID[\s\S]*let setupEpoch: String[\s\S]*let ownerDeviceID: String[\s\S]*let hostDeviceID: String[\s\S]*let mcpURL: String[\s\S]*let scope: HandsGrantScope[\s\S]*let podAccount: String\?[\s\S]*let expiresAt: Date/);
  assert.match(connect, /static let shared = HandsConnectFlow\(\)/);
  assert.match(connect, /@Published private\(set\) var phase: HandsConnectionPhase = \.idle/);
  assert.match(connect, /@Published private\(set\) var problem: String\?/);
  assert.match(connect, /\n    func offer\(\) \{/);
  assert.match(connect, /\n    func cancel\(reason: String\) \{/);
  // 意圖只在記憶體（沒有存檔、沒有 UserDefaults）。
  assert.doesNotMatch(code(connect) + code(host), /UserDefaults|writeAtomically|FileManager|\.write\(to:/);
});

test('host: one attempt at a time (same ID idempotent, other ID busy); window, transaction, scope, codes, grant bound to the attempt', () => {
  const begin = between(host, 'func begin(_ request: HandsConnectRequest', 'func cancel(attemptID');
  assert.match(begin, /HandsHostAuthority\.same\(request\.ownerDeviceID, sender\)/, 'owner is the verified sender');
  assert.match(begin, /guard attempt\.request\.attemptID == request\.attemptID else \{ throw HandsConnectRefusal\.busy \}/);
  assert.match(begin, /return \(statusLocked\(attempt, requester: sender, evidence: nil\), request\.attemptID, \.distantPast\)   \/\/ 同 ID：冪等/);
  // begin 之前就到的取消（墓碑）：晚到的 begin 回終態、不開窗口。
  assert.match(begin, /if let done = finished\.first\(where: \{ \$0\.id == request\.attemptID \}\)/);
  assert.match(begin, /guard request\.setupEpoch == offer\.setupEpoch else \{ throw HandsConnectRefusal\.staleEpoch \}/);
  assert.match(begin, /guard request\.scopeDigest == offer\.digest, request\.mcpURL == offer\.mcpURL else \{ throw HandsConnectRefusal\.scopeChanged \}/);
  assert.match(begin, /service\.auth\.openAttemptWindow\(attemptID: request\.attemptID, scope: offer\.scope\)/);
  // authorize_begin 用窗口拍下的範圍，不讀按下之後才改的設定。
  assert.match(auth, /scope: window\.scope \?\? context\.scope, expiresAt: window\.expiresAt,\s*attemptsLeft: Self\.pairingAttempts, attemptID: window\.attemptID, resource: resource\)/);
  assert.match(auth, /expiresAt: current\.addingTimeInterval\(Self\.codeLifetime\), attemptID: pending\.attemptID,\s*resource: pending\.resource\)/);
  // HandsService 在 authorize_begin 前核對範圍與世代；/mcp 成功才回報（驗過 token 之後）。
  // 審查：開交易、送碼、換 token 之前都核一次；/mcp 前核一次（admit）；設定一改也核一次。
  assert.match(service, /if \["authorize_begin", "authorize_submit", "token"\]\.contains\(op\) \{ HandsConnectHost\.attached\(to: self\)\?\.validateBeforeAuthorize\(\) \}/);
  const tools = between(service, 'case "hands_tools":', 'case "hands_call":');
  assert.ok(tools.indexOf('let grant = try authorized(params, current)') < tools.indexOf('admit(grantID: grant.grantID)'));
  assert.ok(tools.indexOf('admit(grantID: grant.grantID)') < tools.indexOf('noteMCP(grantID: grant.grantID)'));
  const call = between(service, 'case "hands_call":', 'default:');
  assert.ok(call.indexOf('if grant.provisional {') > call.indexOf('let grant = try authorized(params, current)'));
  assert.ok(call.indexOf('if grant.provisional') < call.indexOf('try call(name: name'), 'a provisional grant cannot call tools');
  // W333：暫時 grant 的呼叫也算這個 attempt 的 /mcp（先 admit 核世代範圍期限），但照樣請稍後、不給工具；轉正的 grant 呼叫不回報。
  assert.match(call, /if grant\.provisional \{\s*(?:\/\/[^\n]*\n\s*)*guard HandsConnectHost\.attached\(to: self\)\?\.admit\(grantID: grant\.grantID\) \?\? true else \{ throw HandsWireError\.unauthorized \}\s*HandsConnectHost\.attached\(to: self\)\?\.noteMCP\(grantID: grant\.grantID\)\s*throw HandsWireError\.rateLimited\s*\}/);
  assert.equal(call.match(/noteMCP/g).length, 1, 'only the provisional branch reports');
  assert.match(between(service, 'func updateSettings(', 'func setEnabled'), /DispatchQueue\.global\(qos: \.userInitiated\)\.async \{ host\.validateBeforeAuthorize\(\) \}/);
});

test('cancel voids window, pending transaction and unredeemed codes; revokes the attempt grant; closeWindow also drops unredeemed codes', () => {
  const cancel = between(auth, 'func cancelAttempt(_ attemptID: String', 'func attemptWindowExpiry');
  assert.match(cancel, /cancelledAttempts\.append\(attemptID\)/);
  assert.match(cancel, /if hadWindow \{ window = nil \}/);
  assert.match(cancel, /if hadTransaction \{ transaction = nil \}/);
  assert.match(cancel, /codes = codes\.filter \{ \$0\.value\.attemptID != attemptID \|\| \$0\.value\.used \}/);
  assert.match(cancel, /revokeLocked\(active, reason:/);
  const close = between(auth, 'func closeWindow() {', 'func cancelTransaction');
  assert.match(close, /codes = codes\.filter \{ \$0\.value\.used \}/);
  // 取消過的 attempt 的授權碼換不到 grant；換到 grant 才記「這個 attempt 的 grant」。
  assert.match(auth, /if let attempt = entry\.attemptID, cancelledAttempts\.contains\(attempt\) \{ codes\[key\] = nil; throw HandsWireError\.invalidGrant \}/);
  assert.match(auth, /attemptGrants\[attempt, default: \[\]\]\.append\(grant\.id\)/);
  // 關口能叫的 op 沒有變（開窗口、取消、綁瀏覽器都只在 App 內）。
  const ops = between(auth, 'func handle(op: String, params: [String: Any], context: Context)', 'private func requireKeys');
  assert.deepEqual([...ops.matchAll(/case "([a-z_]+)"/g)].map((m) => m[1]), ['register_client', 'authorize_begin', 'authorize_submit', 'token', 'check']);
});

test('success = this attempt\'s grant plus that grant\'s first /mcp; cancel and success have one terminal state', () => {
  const grant = between(host, 'func noteGrant(attempt attemptID', 'func noteMCP');
  assert.match(grant, /if attempt\.boundEvidence == nil \{\s*attempt\.terminal = \.refused; attempt\.reason = "grant_without_evidence"/);
  assert.match(grant, /else if let problem = validityProblem\(attempt, offer: offer\)/, 'epoch, scope and deadline re-checked when the grant appears');
  assert.match(grant, /voidLocked\(attemptID, reason: attempt\.reason \?\? "cancelled", &after\)/);
  // 第一次 /mcp 只到 tools_ready；已連線只由擁有者的確認產生（grant 轉正）。
  const mcp = between(host, 'func noteMCP(grantID: String)', 'func noteRegistered');
  assert.match(mcp, /guard var attempt = current, attempt\.terminal == nil, attempt\.grantID == grantID,\s*service\.auth\.grantRecord\(grantID\)\?\.isActive == true else \{ return \}/);
  assert.match(mcp, /attempt\.mcpSeen = true/);
  assert.doesNotMatch(mcp, /\.connected/);
  const confirm = between(host, 'func confirm(attemptID: String, sender: String)', 'func validateBeforeAuthorize');
  assert.match(confirm, /guard let grant = attempt\.grantID, attempt\.mcpSeen else \{ throw HandsConnectRefusal\.notConfirmable \}/);
  assert.match(confirm, /if service\.auth\.completeAttemptGrant\(grant\) \{\s*attempt\.terminal = \.connected/);
  assert.match(confirm, /HandsHostAuthority\.same\(attempt\.request\.ownerDeviceID, sender\) else \{ throw HandsConnectRefusal\.notOwner \}/);
  // 取消與撤銷在同一把鎖裡：先撤銷（cancelAttemptDeferred）才公布終態；通知放鎖之後送。
  const cancel = between(host, 'func cancel(attemptID: String, sender: String', 'func status(attemptID');
  assert.match(cancel, /if attempt\.terminal != \.connected \{ voidLocked\(attemptID, reason: attempt\.reason \?\? "cancelled", &after\) \}\s*return finishLocked\(attempt\)/);
  assert.match(host, /private func voidLocked\(_ attemptID: String, reason: String, _ after: inout \[\(\) -> Void\]\) \{\s*let result = service\.auth\.cancelAttemptDeferred/);
  assert.match(host, /lock\.unlock\(\)\s*after\.forEach \{ \$0\(\) \}\s*return result/);
  // 期限不因為有 grant 就不收；begin 排了到期計時。
  assert.match(host, /private func expireLocked\(_ after: inout \[\(\) -> Void\]\) \{\s*guard var attempt = current, attempt\.terminal == nil, now\(\) >= deadline\(attempt\) else \{ return \}/);
  assert.match(host, /asyncAfter\(deadline: \.now\(\) \+ delay\) \{ \[weak self\] in self\?\.expireIfStale\(id\) \}/);
  // App 重開：還沒確認的 grant 撤銷。
  assert.match(auth, /let unfinished = state\.grants\.filter \{ \$0\.isActive && \$0\.pendingAttempt != nil \}\.map\(\\\.id\)/);
  assert.match(auth, /projectIDs: entry\.projectIDs, createdAt: now\(\), lastUsedAt: nil,\s*pendingAttempt: entry\.attemptID, hostDeviceID: bindingForIssue\?\.hostDeviceID\.lowercased\(\),/);
  // 授權完成（granted）與工具連上（connected）是不同狀態。
  assert.match(host, /case granted\n[\s\S]*case connected/);
  assert.match(connect, /case \.granted:[\s\S]*phase = \.verifying[\s\S]*授權完成，等 ChatGPT 接上 TATWO 的工具/);
});

test('pairing code: only to the owner, only after the Pod-observed authorize params match the transaction; mismatch terminates', () => {
  const status = between(host, 'func status(attemptID: String, sender: String, evidence: String?)', 'func validateBeforeAuthorize');
  assert.match(status, /guard HandsHostAuthority\.same\(attempt\.request\.ownerDeviceID, sender\) else \{ throw HandsConnectRefusal\.notOwner \}/);
  assert.match(status, /attempt\.terminal = \.refused; attempt\.reason = "transaction_mismatch"/);
  const locked = between(host, 'private func statusLocked', 'static func cleanReason');
  assert.match(locked, /let showCode = isOwner && bound && evidence\.map \{ HandsAuth\.constantTimeEqual\(\$0, attempt\.boundEvidence \?\? ""\) \} == true/);
  assert.match(auth, /static func evidenceHash\(clientID: String, redirectURI: String, state: String, challenge: String\) -> String/);
  // 擁有者這端：只收這一輪按了建立之後的第一個配對頁；網域、路徑、參數都要對；對話裡的連結不算。
  const frame = between(connect, 'func frameChanged(_ frame: HandsPodFrame)', 'private func podLost');
  // W183 R10 第二輪（GPT-6 1）：等配對頁的起點是 App 送出「按」的那一刻（錨點）；之前（整個準備期間）出現的配對頁一律終止、作廢。
  assert.match(frame, /let live = intent != nil && !granted && \(pressAnchor != nil \|\| awaitingSince != nil \|\| observed != nil\)/);
  assert.match(frame, /if intent != nil, !granted, observed == nil, pressAnchor == nil, awaitingSince == nil,\s*Self\.authorizeEvidence\(url, publicHost: publicHost\) != nil \{\s*log\("authorize before create"\)\s*return refuse\(Self\.beforeCreateText, my: runID\)/);
  assert.match(frame, /\} else if live \{[\s\S]*?if let why = pressAnchor\.flatMap\(\{ Self\.anchorProblem\(frame, anchor: \$0, leftChatGPT: mainLeftChatGPT\) \}\)\s*\?\? Self\.provenanceProblem\(frame, since: pressAnchor\?\.at \?\? awaitingSince \?\? \.distantFuture\) \{[\s\S]*?refuse\([\s\S]*?\} else \{\s*observed = \(evidence, frame\)/);
  const anchor = between(connect, 'nonisolated static func anchorProblem(', 'private func pressDispatched(');
  assert.match(anchor, /guard let key = frame\.popupKey, !anchor\.popups\.contains\(key\) else \{ return "popup_before_press" \}/);
  assert.match(anchor, /guard let opened = frame\.openedAt, opened >= anchor\.at else \{ return "popup_before_press" \}/);
  assert.match(anchor, /guard frame\.generation > anchor\.mainGeneration else \{ return "not_after_press" \}/);
  assert.match(anchor, /return leftChatGPT \? "left_chatgpt_after_press" : nil/);
  assert.match(frame, /log\("authorize ignored \(not awaiting\)"\)/);
  // 審查：綁住的畫面開始載入、關掉＝碼當下收；外站授權頁、被帶到別的網站＝當下終止；舊世代不算。
  assert.match(frame, /if frame\.closed \{[\s\S]*?hideCode\(\)/);
  assert.match(frame, /if frame\.loading \{[\s\S]*?hideCode\(\)/);
  assert.match(frame, /if let seen = surfaceGenerations\[surface\], frame\.generation < seen \{ return \}/);
  assert.match(frame, /if live, Self\.isForeignAuthorize\(url, publicHost: publicHost\) \{[\s\S]*?return refuse\(/);
  assert.match(frame, /if live, !Self\.expectedAfterPairing\(url, publicHost: publicHost\) \{[\s\S]*?refuse\(/);
  const provenance = between(connect, 'static func provenanceProblem', 'static func expectedAfterPairing');
  assert.match(provenance, /guard let opened = frame\.openedAt, opened >= since else \{ return "popup_before_press" \}/);
  assert.match(provenance, /if isConversationPath\(source\.path\) \{ return "conversation" \}/);
  const evidence = between(connect, 'static func authorizeEvidence', 'static func isAuthorizeResult');
  assert.match(evidence, /components\.scheme == "https"/);
  assert.match(evidence, /components\.host\?\.lowercased\(\) == publicHost\.lowercased\(\), components\.port == nil, components\.user == nil/);
  assert.match(evidence, /components\.percentEncodedPath == "\/authorize"/);
  assert.match(evidence, /guard values\[item\.name\] == nil/, 'duplicate parameters are refused');
  // 綁 attempt 的確認卡不上設定頁與 Island。
  assert.match(state, /if card\?\.attemptID != nil \{ return \}/);
  assert.match(state, /guard card\?\.attemptID == nil else \{ return \}/);
});

test('remote: begin_connect/cancel_connect/connect_status signed with expires_at, epoch, attempt and owner; no code in the polled status; bare start_pairing retired', () => {
  assert.match(remote, /if let op = payload\["op"\] as\? String, HandsConnectRemote\.ops\.contains\(op\) \{[^\n]*\n\s*return try HandsConnectRemote\.handle\(op, payload: payload, sender: sender, host: host\)/);
  assert.match(remote, /case "start_pairing":[\s\S]{0,200}throw Failure\.invalid\(HandsConnectRemote\.startPairingRetired\)/);
  assert.doesNotMatch(code(remote), /result\["card"\]|auth\.pendingCard/);
  const handler = between(host, 'enum HandsConnectRemote', undefined);
  // W183 R7a：begin_connect 多帶卡上選的範圍（level、project_ids），一樣在簽章涵蓋的 payload 裡。
  assert.match(handler, /"begin_connect": \["op", "expires_at", "attempt_id", "setup_epoch", "owner_device_id", "scope_digest", "mcp_url",\s*"level", "project_ids"\]/);
  assert.match(handler, /"connect_status": \["op", "expires_at", "attempt_id", "evidence"\]/);
  assert.match(handler, /"cancel_connect": \["op", "expires_at", "attempt_id", "reason"\]/);
  assert.match(handler, /"connect_confirm": \["op", "expires_at", "attempt_id"\]/);
  assert.match(handler, /try connect\.confirm\(attemptID: attempt, sender: sender\)/);
  // 舊的 stop_pairing 只關手動窗口（綁 attempt 的要擁有者 cancel_connect）。
  assert.match(remote, /case "stop_pairing":[\s\S]{0,200}guard host\.service\.auth\.closeManualWindow\(\) else \{ throw Failure\.invalid\(HandsConnectRemote\.stopPairingAttempt\) \}/);
  const manual = between(auth, 'func closeManualWindow() -> Bool {', 'func attemptWindowExpiry');
  assert.match(manual, /if window\?\.attemptID != nil \|\| transaction\?\.attemptID != nil \{ lock\.unlock\(\); return false \}/);
  assert.match(handler, /expires > now\.timeIntervalSince1970, expires <= now\.timeIntervalSince1970 \+ HandsRemote\.maxAhead/);
  assert.match(handler, /guard HandsHostAuthority\.same\(owner, sender\) else \{ throw HandsConnectRefusal\.notOwner \}/);
  assert.match(handler, /ownerDeviceID: sender/);
  // 不是 AI 工具：os-mcp、OS 工具、外部 AI 都碰不到連線意圖。
  assert.doesNotMatch(mcpServer, /begin_connect|connect_status|cancel_connect|HandsConnect/);
  assert.doesNotMatch(bridge, /HandsConnectFlow|HandsConnectHost/);
  // 送出結果未知：先查，不直接重送。
  assert.match(links, /return \.unknown\(HandsRemoteClient\.plain\(error\)\)/);
  assert.match(connect, /case \.unknown:\n\s*\/\/ 送出結果未知：先查，不重送。\n\s*guard let status = try\? await link\.status\(attemptID: request\.attemptID, evidence: nil\)/);
  // 審查：begin 送出前就記成「主機可能收了」（取消一定會送）；取消採用主機的回覆。
  const run = between(connect, 'private func run(_ intent: HandsConnectIntent', 'private func awaitAuthorize');
  assert.ok(run.indexOf('begun = true') >= 0 && run.indexOf('begun = true') < run.indexOf('try await link.begin(request)'));
  const outcome = between(connect, 'private static func cancelOnHost', 'private func releasePod');
  assert.match(outcome, /return status\.state == \.connected \? \.connected : \.cancelled/);
  assert.match(connect, /case \.connected: self\.showLateSuccess\(\)/);
  assert.match(connect, /case \.unknown:\s*self\.phase = \.failed\s*self\.problem = HandsConnectFlow\.cancelUnknownText/);
});

test('flow: window only after the user pressed; Pod checks (login, developer mode, existing connector) run with the window closed; no auto-resume', () => {
  const run = between(connect, 'private func run(_ intent: HandsConnectIntent', 'private func awaitAuthorize');
  const order = ['pod.prepare()', 'pod.acquireExclusive', 'pod.scan(url: intent.mcpURL)', 'link.begin(request)', 'pod.create(url: intent.mcpURL'];
  let at = -1;
  for (const step of order) {
    const next = run.indexOf(step, at + 1);
    assert.ok(next > at, `${step} after the previous step`);
    at = next;
  }
  // 開發者模式、警語、登入：先取消主機上的 attempt（窗口關著），不代按。
  for (const name of ['waitForLogin', 'waitForDeveloperMode', 'waitForUserWarning']) {
    const body = between(connect, `private func ${name}(`, 'private func');
    assert.match(body, /cancelAttemptOnHost\(reason:/, name);
  }
  // ［連線］只有卡片上的按鈕叫得到；offer() 只顯示卡片。
  assert.match(connect, /guard case \.confirm\? = card else \{ return \}/);
  const offer = between(connect, '    func offer() {', '    func cancel(reason: String)');
  assert.doesNotMatch(offer, /startAttempt|link\.begin|pod\.create/);
  // 作廢：鎖螢幕、登出、Pod 關掉 → 取消這個 attempt、回到等你按。
  assert.match(connect, /NSWorkspace\.screensDidSleepNotification/);
  assert.match(connect, /com\.apple\.screenIsLocked/);
  assert.match(podDriver, /case \.off, \.sleeping, \.failed: self\?\.onLost\?\("pod_closed"\)/);
});

test('Pod: exclusive lease (no page switch mid-chat), commands only on chatgpt.com, popup gesture protection untouched', () => {
  // W183 R9 審查（GPT-6 #9）：原生「新增 ▾」的操作租約（menuHold）跟連接器獨占雙向互斥；排隊的送出也等它。
  // W184 G3：即時語音拿著 Pod（voiceClaim，送出「開始」前就佔住）時也拿不到獨占、排隊的送出也等它；原本守的條件都還在。
  // W197（.056）：Dots 借用 Pod 時連接器也拿不到獨占（守衛最前面多 dotsLease，其餘不變）。
  // W183 R10 第二輪：connectorPress（Create／重新連線的第二步：App 記下錨點之後才送）也只走這條、一樣要帶獨占。
  // W183 R12（主導 2）：多一個 connectorGesture（要真人點的那一顆指給他看；只標、不按），一樣只走這條、一樣要帶獨占。
  // W183 R12（.033 實機）：再多一個 connectorOutline（對不上時的結構快照；只讀、DOM 文字），一樣只走這條、一樣要帶獨占。
  assert.match(tap, /static let connectorCommands: Set<String> = \["connectorScan", "connectorDevMode", "connectorCreate", "connectorReconnect",\s*"connectorPress", "connectorConsent", "connectorHighlight", "connectorHome", "connectorSettings",\s*"connectorAbort", "connectorAccount", "connectorNavigated",\s*"connectorGesture",[^\n]*\n\s*"connectorOutline",[^\n]*\n\s*"connectorTick",[^\n]*\n\s*"connectorInspect", "connectorDelete", "connectorProbe"\]/);   // W183 R12（.034）：代勾的 DOM 驗證
  assert.match(tap, /static let connectorReads: Set<String> = \["connectorDevMode", "connectorAccount"\]/);
  // 審查：會換頁的指令在獨占時一律不做；連接器的寫入指令要帶著目前的獨占。
  // W183 R9：原生外掛頁的「新增 ▾」（pluginNewMenu）也會換頁：一樣在獨占時不做。
  assert.match(tap, /static let pageCommands: Set<String> = \["voice", "branch", "share", "probe", "navigate", "pluginNewMenu"\]/);
  assert.match(tap, /if paging, connectorHold != nil \{ throw TapError\.remote\(/);
  assert.match(tap, /guard let hold, hold == connectorHold else \{ throw TapError\.remote\(/);
  // 放掉獨占＝先中止、帶回首頁（外站＝原生載回、等 hello），回到了才放行聊天。
  const release = between(podDriver, 'func releaseExclusive() {', 'func scan(url: String)');
  assert.ok(release.indexOf('await self.restore(id)') < release.indexOf('tap.endConnectorHold(id)'));
  assert.match(release, /await request\("connectorAbort"/);
  assert.match(release, /surface\.loadMain\(\(surface as\? TapWebPod\)\?\.homeURL \?\? ChatGPTTap\.homeURL\)/);
  assert.match(release, /if tap\.helloCount != hellos, mainURL\?\.host\?\.lowercased\(\) == "chatgpt\.com" \{ return \}/);
  assert.match(release, /tap\.restart\(\)/);
  // 等待會在流程取消時停（不空轉）。
  assert.match(podDriver, /if Task\.isCancelled \{ return false \}/);
  assert.match(podDriver, /do \{ try await Task\.sleep\(nanoseconds: 500_000_000\) \} catch \{ return false \}/);
  assert.doesNotMatch(podDriver, /try\? await Task\.sleep\(nanoseconds: (300|500)_000_000\)/);
  // 拿著獨占時開的 popup＝配對頁：敏感頁、不給擷取、流程結束一律關。
  // W183 R8b 審查（GPT-6）：私訊框 Browser 受保護呈現 Pod 時開的視窗（登入）也一樣。
  assert.match(podDriver, /let pairing = hold != nil\s*let sensitive = pairing \|\| surface\(\)\?\.isGuardedPresentation == true\s*if sensitive \{\s*popup\.sensitivePage = true\s*popup\.window\?\.sharingType = \.none/);
  assert.match(podDriver, /entry\.view\?\.closeBrowser\(\)/);
  assert.match(tap, /return "location\.host==='chatgpt\.com'&&window\.__tatwoPod&&window\.__tatwoPod\.command\("/);
  // TapWebPod：原本的 popup 設定先跑（BrowserHumanInteraction），只多一個通知；不設敏感頁、不改 onPopupRequested。
  assert.match(webPod, /let configuredPopup = view\.onPopupCreated\n\s*view\.onPopupCreated = \{ \[weak self\] popup in\n\s*configuredPopup\?\(popup\)\n\s*self\?\.onPopup\?\(popup\)/);
  assert.doesNotMatch(webPod, /sensitivePage|onPopupRequested|chatgpt\.com/);
  const bridgeSource = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.doesNotMatch(bridgeSource, /W183 R6b/, 'no bridge change: popup gesture protection stays as is');
  // W183 R8b 審查（GPT-6）：只多一個「只准 https」的旗標（受保護呈現中的 Pod）；popup 的收法、手勢保護不動。
  assert.equal((bridgeSource.match(/httpsOnly/g) ?? []).length, 1);
  // 自動填碼是下一版：Pod 驅動沒有填碼、App 不在配對頁執行任何腳本。
  assert.doesNotMatch(code(podDriver) + code(connect), /pairing_code|fillOneTimeCode|evaluateJavaScript/);
});

test('DM: native card over the DM (not a chat message); composer removed; code marks the sensitive gate and blocks screen capture', () => {
  assert.match(webSheet, /\.overlay \{\n\s*if isShown \{ HandsConnectDMLayer\(store: store\) \}   \/\/ W183 R6b/);
  assert.match(webSheet, /outerActive \|\| \(isShown && connect\.covers\(store\)\)/);
  assert.match(sensitive, /\|\| HandsConnectPresenter\.anySensitive/);
  // 審查：卡片在畫面上的整段時間（不是只有碼在畫面上）＋配對頁視窗還開著。
  // W183 R8a 審查（GPT-6）：ChatGPT build 的安全設定卡在畫面上也算（HandsBuildScreenGate）。
  // W183 R11（主導 D：連上之後要在閘門外看得到狀態）：只剩結果的卡片（已連線、已斷線：沒有碼、沒有同意、沒有授權頁）不算連線過程；
  // 過程的每一種（確認、登入、警語、配對、確認中、出錯可以再連、讀取中）照舊算，三個來源照舊都在。
  assert.match(dmView, /static var anySensitive: Bool \{\n\s*shown\.contains \{ \$0\.value\?\.inProcess == true \} \|\| ChatGPTConnectorPod\.sensitivePopupCount > 0 \|\| HandsBuildScreenGate\.isShown\n\s*\}/);
  // W183 R11 第二輪（GPT-6 R11b 審查 4）：「連線狀態未確認」也只是結果（沒有碼、沒有同意）；過程的每一種照舊算。
  assert.match(dmView, /nonisolated static func inProcess\(_ card: HandsConnectCard\?\) -> Bool \{\s*switch card \{\s*case \.connected\?, \.disconnected\?, \.unconfirmed\?: return false[^\n]*\n\s*default: return true/);
  // W184 D（截圖只擋授權頁與配對碼；契約 §3b 已同步）：卡片一出來照舊撤銷以 TATWO 為目標的 Computer Use（閘門整段、不放寬）；
  // 截圖改看配對碼在不在畫面上（refreshCodeShield），卡片出來本身不擋。
  assert.match(between(dmView, '    func show() {', '    func hide() {'), /BrowserSensitivePageGate\.pageAppeared\(\)[\s\S]*refreshCodeShield\(\)/);
  // W183 R8b：收卡片＝還原擷取；還沒完成的連線分頁收掉、完成的留著（分頁不會自己消失）。
  const hide = between(dmView, '    func hide() {', '    func setPodVisible');
  assert.match(hide, /unprotectWindow\(\)[\s\S]*browser\.close\(purpose: \.chatgptPairing, keepingDone: true\)\s*browser\.close\(purpose: \.chatgptDeveloper, keepingDone: true\)/);
  const presenter = between(dmView, 'final class HandsConnectPresenter', 'struct HandsConnectDMLayer');
  assert.match(presenter, /BrowserSensitivePageGate\.pageAppeared\(\)/);
  // W183 R8b 審查：不給擷取以視窗計數（跟 Browser 的敏感分頁共用 WindowCaptureShield，最後一個放手才還原）。
  // W184 D：卡片只在配對碼正在畫面上時持有（碼綁住的那一頁在 Browser 的畫面上、卡片把碼畫出來）。
  assert.match(presenter, /WindowCaptureShield\.shared\.hold\(self, window: codeOnScreen \? cardWindow : nil\)/);
  // W183 R8b：Pod 的畫面＝Browser 的「ChatGPT Dev」分頁；配對頁 popup 收進分頁（不再擺原生視窗）；完成＝標「完成」。
  assert.match(presenter, /browser\.openPod\(purpose: \.chatgptDeveloper, currentURL: podURL\(\), onCancel: cancelFlow\)/);
  // W183 R12（主導 1）：配對頁要出來了＝先叫任務版面換成兩頁（taskLayout.want），再叫到前面；守的一樣。
  assert.match(presenter, /func placePopup\(key: Int\) \{\s*if isShown && !inSettings \{ taskLayout\.want\(\.connect\) \}[^\n]*\n\s*browser\.focusPopup\(key: key\)/);
  assert.match(presenter, /func markDone\(\) \{\s*browser\.markDone\(purpose: \.chatgptDeveloper\)\s*browser\.markDone\(purpose: \.chatgptPairing\)/);
  assert.match(presenter, /connector\.onSensitivePopup = \{ \[weak browser\] popup, key, pairing in\s*browser\?\.adoptPopup\(DMBrowserPopupPage\(popup: popup\), key: key/);
  assert.doesNotMatch(code(dmView), /positionPopup|setFrame\(rect|orderFrontRegardless|NSWindow\.Level/);
  assert.match(connect, /presenter\.markDone\(\)   \/\/ W183 R8b/);
  assert.match(connect, /extension HandsConnectPresenting \{\s*func markDone\(\) \{\}/);
  // 確認卡蓋在框上；按了［連線］之後的卡片浮在 Browser 的連線分頁下方。
  assert.match(presenter, /case \.loading, \.confirm: return false\s*default: return browser\.hasConnectTab/);
  // W183 R12（主導 1）：sheet 出不出來改看 showsSheet（還是「不浮在 Browser」＋多一個「不在左頁」：兩頁攤開時卡片在左頁）；守的一樣。
  assert.match(dmView, /var showsSheet: Bool \{ !inSettings && isShown && currentCard\(\) != nil && !floatsInBrowser && !onLeftPage \}/);
  assert.match(dmView, /if presenter\.showsSheet, presenter\.store === store, let card = flow\.card \{/);
  assert.match(dmView, /struct HandsConnectFloatingCard: View/);
  // 卡片最少要顯示的（one-switch.md；T15：Pod 目前帳號、主機、服務網址、等級白話、專案、callback 網域、交易編號）。
  // W184 D 手機樣子：sheet 標題「連上 ChatGPT」、帳號那一列唸「Pod 目前帳號」、網址那一列唸「服務網址」、配對碼卡「配對碼・只在這台」。
  for (const words of ['連上 ChatGPT', 'Pod 目前帳號', '主機', '服務網址', '專案', '沒有', '授權後回到', '取消', '連線',
    '可讀這台的專案、可讀正式記憶；只寫 ChatGPT 收件匣與提案，不直接改專案檔', '交易', '配對碼・只在這台']) {
    assert.ok(dmView.includes(words), words);
  }
  assert.doesNotMatch(dmView, /已驗證/);
  assert.doesNotMatch(code(dmView), /IslandNotice|SpaceNotice|NSLog|print\(/);
  // W183 R8b：Pod 的 popup 收進分頁——原生視窗先透明、點不到；收視窗只收它自己的（頁面在私訊框時不能收到私訊框）。
  assert.match(podDriver, /if sensitive, onSensitivePopup != nil, let window = popup\.window \{\s*window\.alphaValue = 0\s*window\.ignoresMouseEvents = true/);
  assert.match(podDriver, /entry\.home\?\.orderOut\(nil\)/);
  assert.doesNotMatch(podDriver, /entry\.view\?\.window\?\.orderOut/);
});

test('self-test w183connect is registered, DEBUG-only, isolated, and never reports a fake CEF pass', () => {
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w183connect"[\s\S]{0,300}HandsConnectAcceptance\.run\(\)/);
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.isEnabled\(environment\)/);
  assert.doesNotMatch(acceptance, /CloudflareKeychain\(\)|URLSession|HandsSetup\.shared|ChatGPTTap\.shared/);
  assert.match(acceptance, /check\.skip\("真 CEF/);
  for (const words of ['攻擊者先占交易', '回答裡的授權連結', '一次只接受一個 attempt', '非擁有者', '舊世代晚到', '取消與 \/token 同時',
    '取消後舊授權碼換不到 grant', 'remote_hands_status 裡沒有配對碼', '別的 grant 的 \/mcp 不算這次成功']) {
    assert.match(acceptance, new RegExp(words), words);
  }
});

test('docs: contract pairing section and T15 describe the attempt flow', () => {
  for (const words of ['attempt', 'begin_connect', 'cancel_connect', '範圍快照', '還沒兌換的授權碼', '第一次 `/mcp`']) assert.ok(contract.includes(words), words);
  const t15 = threat.split('\n').find((line) => line.startsWith('| T15 '));
  assert.ok(t15 && t15.includes('［連線］') && t15.includes('attempt'), 'T15 names the [連線] press and the attempt');
});

test('no hard-coded domains or host names in the new files', () => {
  const files = ['Facade/HandsConnect.swift', 'Facade/HandsConnectHost.swift', 'Facade/HandsConnectLinks.swift', 'Facade/HandsConnectAcceptance.swift',
    'TAP/ChatGPTConnectorPod.swift', 'New/HandsConnectDMView.swift'];
  for (const file of files) {
    const source = swift(file);
    const hosts = [...source.matchAll(/\b([a-z0-9-]+\.)+(com|net|org|io|dev|app)\b/g)].map((m) => m[0])
      .filter((h) => !/(^|\.)(example\.com|example\.net|chatgpt\.com|openai\.com)$/.test(h) && !/^com\.apple\./.test(h));
    assert.deepEqual(hosts, [], file);
  }
});

// ---------- W183 R7a：［連線］卡上選等級與專案 ----------

const scope = swift('Facade/HandsConnectScope.swift');
const scopeAcceptance = swift('Facade/HandsScopeAcceptance.swift');
const tools = swift('Facade/HandsTools.swift');
const setupSource = swift('Facade/HandsSetup.swift');

test('W183 R10 host: no scope on the card — begin with level/project_ids is refused before anything is written; the snapshot is the central level + all projects (digest "*")', () => {
  // 守（取代 R7a「驗過就寫進主機設定」）：主機的範圍只照 ChatGPT build 的中央設定；卡片、設備簽章的 begin_connect 都改不到。
  // 帶了範圍的 begin 在任何副作用（排隊、拍快照、開窗口）之前就拒絕。
  const begin = between(host, 'func begin(_ request: HandsConnectRequest', 'func cancel(attemptID');
  const order = ['guard request.choice == nil else { throw HandsConnectRefusal.scopeInvalid }', 'commitLock.lock(); defer { commitLock.unlock() }',
    'let offer = try self.offer()', 'service.auth.openAttemptWindow(attemptID: request.attemptID, scope: offer.scope)'].map((n) => begin.indexOf(n));
  assert.ok(order.every((i) => i >= 0) && order.every((v, i) => i === 0 || order[i - 1] < v), `refuse a card scope first, then queue, snapshot, open ${order}`);
  // 守：主機這一端沒有任何寫等級、專案的路（applyChoice、validatedChoice、updateSettings 都不在）。
  assert.doesNotMatch(code(host), /applyChoice|validatedChoice|updateSettings|allowedProjectIDs =|\.level = /);
  assert.doesNotMatch(code(scope), /func validatedChoice|connectProjectsOutsideCap|uncheckedInBuild/);
  // 守：offer 照有效設定（中央等級＋全部專案），不給卡上選。
  assert.match(host, /func offer\(includeChoices: Bool = false\) throws -> HandsConnectOffer \{\s*try offer\(settings: service\.effectiveSettings\(\), includeChoices: includeChoices\)/);
  assert.doesNotMatch(between(host, 'func offer(settings: HandsSettings', '// MARK: - begin'), /projectChoices =|supportsChoice = true|uncheckedInBuild/);
  // 守：digest——全部可見＝專案那一段是「*」（新專案、外接碟暫時不見不讓進行中的連線作廢）；等級、網址、記憶、callback 照舊綁。
  assert.match(between(host, 'var digest: String {', 'var wire: [String: Any] {'), /let projects = scope\.allProjects \? "\*" : scope\.projects\.map\(\\\.id\)\.sorted\(\)\.joined\(separator: ","\)/);
  assert.match(between(host, 'var digest: String {', 'var wire: [String: Any] {'), /String\(scope\.level\), projects, scope\.memory/);
  // 守：wire 帶 all_projects（只收布林）與只能看的清單。
  assert.match(host, /out\["all_projects"\] = true\s*out\["read_only_projects"\] = scope\.readOnlyProjectIDs/);
  assert.match(host, /let all = \(object\["all_projects"\] as\? NSNumber\)\.map \{ CFGetTypeID\(\$0\) == CFBooleanGetTypeID\(\) && \$0\.boolValue \} \?\? false/);
  // 守：cancel 照舊跟 begin 排隊（commitLock 在 locked 之前）。
  const cancelBody = between(host, 'func cancel(attemptID: String, sender: String', 'func status(attemptID');
  assert.ok(cancelBody.indexOf('commitLock.lock(); defer { commitLock.unlock() }') >= 0
    && cancelBody.indexOf('commitLock.lock(); defer { commitLock.unlock() }') < cancelBody.indexOf('return try locked { after in'));
  // 守：副設備的 begin_connect 照舊嚴格解析 level／project_ids（解析得出來＝交給 begin 拒絕，不是悄悄忽略）。
  assert.match(host, /let choice = try HandsScopeChoice\.fromWire\(payload\)/);
  assert.match(scope, /guard let number = payload\["level"\] as\? NSNumber, CFGetTypeID\(number\) != CFBooleanGetTypeID\(\)/);
  assert.match(host, /case scopeInvalid = "connect_scope_invalid"/);
  // 守：專案清單的解析規則照舊（遠端狀態還在用）：超過上限、看不懂的列、多的欄位、重複 id＝整份不收；不截斷。
  assert.match(scope, /guard let rows = raw as\? \[Any\], rows\.count <= listLimit else \{ return nil \}/);
  assert.match(scope, /guard decoded\.count == rows\.count, Set\(decoded\.map\(\\\.id\)\)\.count == decoded\.count else \{ return nil \}/);
  assert.match(scope, /guard Set\(raw\.keys\)\.isSubset\(of: \["id", "name", "folder", "problem"\]\)/);
  assert.doesNotMatch(code(scope), /\.prefix\(64\)/);
  // 守：「全部可見」＝能當專案的＋暫時用不了的（之後回來照樣可見、工作區不被鎖）；政策上不能當專案的（入口、chatgpt/、家目錄…）不算。
  const visible = between(scope, 'func visibleProjectRecords()', 'func buildProjectRecords()');
  assert.match(visible, /guard let real = HandsPath\.realpath\(workdir\) else \{ return true \}/);
  assert.match(visible, /guard let problem = runtime\.folderProblem\(real\) else \{ return true \}\s*return HandsProjectChoice\.temporaryProblems\.contains\(problem\)/);
  assert.match(swift('Facade/HandsRooms.swift'), /let host = Set\(visibleProjectRecords\(\)\.map \{ \$0\.0\.uuidString \}\)/);
});

test('W183 R10 remote status reports the effective scope (central level, all projects) and the host project list; W214 hides project chips', () => {
  // 守：副設備看到的是有效範圍（中央等級＋這台全部專案），不是本機那一份舊欄位。
  assert.match(remote, /let effective = host\.service\.effectiveSettings\(\)/);
  assert.match(remote, /"level": effective\.level,/);
  assert.match(remote, /"allowed_projects": allowedNames,/);
  assert.match(remote, /let choices = host\.service\.connectProjectChoices\(allowed: Set\(settings\.allowedProjectIDs\)\)\s*if choices\.count <= HandsProjectChoice\.listLimit \{ result\["project_choices"\] = choices\.map\(\\\.wire\) \}/);
  assert.match(remote, /projectChoices = HandsProjectChoice\.list\(object\["project_choices"\]\) \?\? \[\]/);
  // W214 removes the display-only project chips; the host scope and Connect intent stay covered.
  const build = swift('New/ChatGPTBuildSection.swift');
  const controller = swift('Facade/HandsBuildController.swift');
  assert.match(nativeW214(4), /W214 PASS N4.no-project-chips-or-detail-rows.true/);
  // W183 R12（使用者 09-30 裁決：拿掉等級選擇）：面板的 L0／L1／L2 那一排拿掉，換成一行白話（連上後能做的）；沒有選等級的按鈕。
  assert.match(build, /Text\(HandsBuildCopy\.capabilities\)/);
  assert.doesNotMatch(code(build), /levelChip|HandsBuildUIIntent\.level\(/);
  assert.match(controller, /guard dependencies\.flow\.offer\(target: target, preset: nil\) else \{/);
  assert.doesNotMatch(controller, /let preset = entry\.map/);
});

test('W183 R10 card: no scope chooser (no level segments, no project layer, no "go tick first" hint); read-only summary + the consent line next to ［連線］; glass chips, native card', () => {
  // 守（使用者 09-29「這邊要勾選也太怪」）：拿掉專案那一層與「先到 ChatGPT build 勾」的提示；卡片只顯示中央設定的等級＋這台全部專案。
  assert.doesNotMatch(dmView, /struct HandsConnectScopeChooser|struct HandsConnectLevelSegments|HandsConnectSheetPage|emptyProjectsText|uncheckedNote|先到那裡勾|toggleProject|chooseLevel/);
  const confirm = between(dmView, 'struct HandsConnectConfirmContent: View', '// MARK: - 按了［連線］之後');
  // W183 R12（主導：確認卡不顯示等級膠囊，直接寫能力）：等級的字（HandsState.levelLabel）換成那一行能力；交易類那一句不寫（L0）。
  for (const words of ['HandsConnectFlow.consentLine', 'tatwo.dm.handsConnect.consent', 'HandsConnectAbility.line(level: offer.scope.level)', 'Self.projectsText(offer)',
    'HandsConnectCardBody.memorySummary(level: offer.scope.level)', 'HandsConnectCardBody.levelText(offer.scope.level)', 'Self.tradingNote(offer)',
    '這台全部（\\(offer.scope.projects.count) 個）', '交易類專案只能看；金鑰、憑證類檔案一律讀不到', 'tatwo.dm.handsConnect.scopeSummary', 'tatwo.dm.handsConnect.readOnly']) {
    assert.ok(confirm.includes(words), words);
  }
  // 守：［連線］旁一行小字（使用者 09-29 裁決：按［連線］那一下就算同意）；那一顆的 help 也寫同一句。
  assert.match(connect, /static let consentLine = "按連線＝同意 ChatGPT 開發者模式的風險說明，TATWO 會替你勾選"/);
  assert.match(dmView, /DMPhoneCapsuleButton\(title: "連線", prominent: true\) \{ actions\.connect\(\) \}\s*\.help\(HandsConnectFlow\.consentLine\)/);
  // 守：卡片的按鈕只經 live actions 接到流程；沒有等級、專案的按鈕。W183 R11：多了［斷線］與已斷線卡的［連線］（一樣只經 live actions）。
  // W183 R12（主導 3）：多一顆［同意並繼續］（也只接卡片上的按鈕）；其他照舊。
  assert.match(dmView, /HandsConnectCardActions\(dismiss: \{ flow\.dismiss\(\) \}, connect: \{ flow\.connect\(\) \}, continueAfterUser: \{ flow\.continueAfterUser\(\) \},\s*retry: \{ flow\.retry\(manual: \$0\) \}, disconnect: \{ flow\.disconnect\(\) \}, reconnect: \{ flow\.reconnect\(\) \},\s*approveConsent: \{ flow\.approveConsent\(\) \},[\s\S]*?copyPairingCode: \{ flow\.copyPairingCode\(\$0\) \}\)/);
  assert.doesNotMatch(confirm, /\.toggleStyle\(\.checkbox\)|pickerStyle\(\.segmented\)|\.bordered|\.borderedProminent|\.tint\(\.blue\)|Color\.blue/);
  // 守：流程沒有卡上選的動作；按［連線］照主機給的卡片送（新主機不給卡上選＝不帶範圍；舊主機給了＝照它給的那一份）。
  assert.doesNotMatch(connect, /func chooseLevel\(|func toggleProject\(/);
  assert.match(connect, /let request = HandsConnectRequest\(intent: intent, scopeDigest: offer\.digest, choice: offer\.scopeChoice\)/);
  assert.match(scope, /var scopeChoice: HandsScopeChoice\? \{\s*supportsChoice \? HandsScopeChoice\(level: scope\.level, projectIDs: Set\(scope\.projects\.map\(\\\.id\)\)\) : nil/);
  assert.doesNotMatch(code(dmView), /L3/);
});

test('W183 R7a/R10 AI tools cannot change the level or projects (the only writers: the signed central config mirrored by the reconciler, the settings screen, normalisation)', () => {
  // 守：改等級與專案的地方只有：畫面（HandsState）、reconcile 把主設備簽的中央等級寫進本機（照信封、不放大其他來源）、設定本身的正規化。
  // W183 R10：主機收［連線］卡範圍的那條路（HandsConnectHost.applyChoice）整個拿掉。
  const files = readdirSync(new URL('../' + app + 'Facade/', import.meta.url)).filter((f) => f.endsWith('.swift') && !/Acceptance|Integration/.test(f))
    .map((f) => 'Facade/' + f).concat(readdirSync(new URL('../' + app + 'New/', import.meta.url)).filter((f) => f.endsWith('.swift')).map((f) => 'New/' + f));
  const writers = files.filter((f) => /(\$0|candidate|copy|settings)\.(level|allowedProjectIDs) = /.test(code(swift(f)))).sort();
  assert.deepEqual(writers, ['Facade/HandsBuildSync.swift', 'Facade/HandsSettings.swift', 'Facade/HandsState.swift']);
  const reconciled = code(swift('Facade/HandsBuildSync.swift')).match(/(\$0|settings)\.(level|allowedProjectIDs) = [^\n;]*/g) ?? [];
  // reconcile 只寫主設備簽的那一份（slice）：等級照中央設定；專案不再寫（全部可見）。
  assert.deepEqual(reconciled, ['settings.level = slice.level'], reconciled.join(' | '));
  const normalised = code(swift('Facade/HandsSettings.swift')).match(/copy\.(level|allowedProjectIDs) = [^\n;]*/g) ?? [];
  assert.ok(normalised.length > 0 && normalised.every((line) => /min\(|compactMap|filter|cap\.level/.test(line)), normalised.join(' | '));
  const setters = files.filter((f) => /\b(setLevel|setAllowedProjects)\(/.test(code(swift(f)).replace(/func (setLevel|setAllowedProjects)\(/g, ''))).sort();
  // 設定畫面的等級改到 ChatGPT build 的 adapter（HandsBuildModel；畫面只經它）——守的一樣是「只有原生設定畫面叫」。
  assert.deepEqual(setters, ['Facade/HandsBuildModel.swift'], 'only the settings screen (its adapter) calls the setters');
  // 外部 AI 的工具、助理的 hands_setup_step、os-mcp 都沒有改範圍的路。
  assert.doesNotMatch(code(tools), /updateSettings|setLevel|setAllowedProjects|allowedProjectIDs =/);
  assert.match(between(setupSource, 'enum HandsSetupTool', undefined), /guard keys\.isSubset\(of: \["step", "action", "hostDeviceID"\]\) else \{ throw Failure\.invalid\("unexpected field"\) \}/);
  assert.doesNotMatch(mcpServer, /project_ids|allowed_project|scope_choice|begin_connect/);
  assert.doesNotMatch(bridge, /HandsConnectFlow|HandsConnectHost|validatedChoice|connectProjectChoices/);
  // W183 R7a 審查：自測走真的 os.sock 處理路徑用的接縫只在 DEBUG；正式照舊用 DeviceDispatch.shared 驗章。
  assert.match(bridge, /#if DEBUG\n[^\n]*\n\s*case "remote_hands_status" where handsRemoteSeam != nil, "remote_hands_action" where handsRemoteSeam != nil:\s*guard let seam = handsRemoteSeam else \{ throw BridgeError\.unsupportedMethod \}\s*let \(sender, payload\) = try seam\.dispatch\.authenticate\(method: method, proof: params\)[\s\S]{0,200}#endif/);
  assert.match(bridge, /case "remote_hands_status", "remote_hands_action":\n\s*let \(sender, payload\) = try DeviceDispatch\.shared\.authenticate\(method: method, proof: params\)/);
  assert.match(bridge, /#if DEBUG\s*\/\/\/ W183 R7a 審查（Claude）：自測用[^\n]*\n\s*private var handsRemoteSeam/);
  // 殘餘寫清楚（不宣稱「AI 一律改不了」）：同使用者身分能跑任意指令的程式、配對金鑰（threat-model T17）。
  assert.match(scope, /殘餘（W183 R7a 審查，GPT-6；不宣稱「AI 一律改不了」）/);
  assert.match(read('docs/specs/183-chatgpt-hands/threat-model.md'), /\| T17 \|/);
});

test('W183 R10 self-test covers the scope rules (all visible, central level, card refused, trading view-only, counterexamples)', () => {
  assert.match(acceptance, /try await scopeCard\(check, base\)/);
  assert.match(acceptance, /try await r10Checks\(check, base\)/);
  assert.match(scopeAcceptance, /^#if DEBUG/);
  assert.doesNotMatch(scopeAcceptance, /CloudflareKeychain\(\)|URLSession|HandsSetup\.shared|ChatGPTTap\.shared|HandsConnectFlow\.shared/);
  for (const label of ['W183 R10 卡片：範圍＝這台全部專案', 'W183 R10 按［連線］：範圍快照＝全部專案', 'W183 R10 這次連上的 grant：核准的是「這台全部專案」',
    'W183 R10 新專案自動包含', 'W183 R10 底線 B：交易實盤類專案（名字或資料夾名）開工作區一律被拒', 'W183 R10 反例：外部 AI（ChatGPT）沒有、也叫不動改等級或專案的工具',
    'W183 R10 主機一律不收卡上選的範圍', 'W183 R10 不帶範圍的 begin（新版擁有者）', 'W183 R10 反例：外部 AI 在授權請求裡塞等級、專案',
    'W183 R10 remote_hands_status：主機的專案清單＝這台全部能當專案的', 'W183 R10 副設備：卡片經簽章 RPC 拿到「全部專案」的卡片',
    'W183 R10 接口：全部可見的卡片來回一樣', 'W183 R10 中央設定即生效', 'W183 R10 中央收窄照舊立刻生效', 'W183 R10 底線 B：交易實盤類（名字含實盤、資料夾名含 hermes）',
    'W183 R7a 審查 取消比 begin 先到（墓碑）', 'W183 R7a 審查 同一個 attempt id、不同的內容', 'W183 R10 資料夾暫時不見的專案',
    'W183 R10 主機有 70 個專案', 'W183 R7a 反例：沒有設備簽章的 begin_connect', 'W183 R7a 反例：外部 AI 的身分叫不到 remote_hands_action',
    'W183 R10 有效簽章的 begin_connect 帶了等級、專案＝connect_scope_invalid', 'W183 R10 對照組：同一條 os.sock 路徑、有效的設備簽章、不帶範圍才開得了窗口']) {
    assert.ok(scopeAcceptance.includes(label), label);
  }
  // 真的走 os.sock 的處理路徑（引擎身分），不是直接叫 authenticate；外部 AI 的每一個真實工具都叫一次。
  assert.match(scopeAcceptance, /OSAgentBridge\.handsRemoteTestBridge\(dispatch: primary, host: remoteHost\)/);
  assert.match(scopeAcceptance, /bridge\.respondForSelfTest\(caller: caller, request: data\)/);
  assert.match(scopeAcceptance, /let engine = OSSocketCaller\.engine\(UUID\(\)\)/);
  assert.match(scopeAcceptance, /for tool in catalog where !call\(tool\.name,/);
  assert.doesNotMatch(scopeAcceptance, /forbiddenTool|"set_level"|OSAgentBridge\.allows\(caller: \.externalAI/);
});

// ---------- 動態：真的 Pod 腳本，本機假頁面 ----------

import { script as podScriptRaw, podScript as keyedPodScript, POD_KEY, POD_FILE, MCP, makePage, h, queryAll, FakeList, FakeRect, FakeStyle, FakeRecord, FakeNode, FakeText, El, FakeDocument } from './w185-pod-fixture.mjs';
const podScript = keyedPodScript(POD_KEY);

/// 外掛頁：一顆「＋」，按了打開建立表單（名稱、描述、MCP 網址、驗證方式、建立）。
function pluginsPage(body, { plusCount = 1, form = 'select', warning = '', checkbox = false, tamper = false, formCount = 1, devMode = true, slowForm = false } = {}) {
  body.appendChild(h('section', {}, h('h2', {}, 'Created by you'), h('p', {}, 'No apps created yet')));
  const created = { clicks: 0, dialog: null };
  const makeDialog = () => {
    const url = h('input', { id: 'mcp-url', placeholder: 'https://example.com/mcp' });
    if (tamper) url.addEventListener('input', function () { this.value = 'https://evil.example.net/mcp'; });
    // W183 R9 審查（GPT-6 #1）：both＝下拉之外還有一個寫 API key 的驗證選單鈕（兩個控制項）；lying＝寫 OAuth 那一項的 value 其實是 api_key。
    // W183 R9 審查（GPT-6 N5）：basic／opaque＝寫 OAuth 那一項的 value 是認不得的值（basic、2）；ariaConflict＝下拉的 aria-valuetext 寫 API key；
    // radio*＝驗證方式是一組原生單選（radioConflict：OAuth 那一個 data-state 說沒選；radioDouble：No Auth 那一個 aria-checked 說選了；
    // radioValue：OAuth 那一個的 value 是 basic）。
    const oauthValue = { lying: 'api_key', basic: 'basic', opaque: '2' }[form] || 'oauth';
    const authGroup = ['au', 'th'].join('');   // 單選組的 name（公開倉的個資掃描會把 name 後面直接寫字當成使用者名稱）
    const radio = (value, label, extra = {}) => h('label', {}, h('input', { type: 'radio', name: authGroup, value, ...extra }), label);
    const auth = ['select', 'both', 'lying', 'basic', 'opaque', 'ariaConflict'].includes(form)
      ? h('select', { id: 'auth', ...(form === 'ariaConflict' ? { 'aria-valuetext': 'API key' } : {}) },
        h('option', { value: 'none' }, 'No Auth'), h('option', { value: oauthValue }, 'OAuth'), h('option', { value: 'mixed' }, 'Mixed'))
      : form.startsWith('radio')
        // R9c（GPT-6 C5、C6）：radioAriaConflict＝看得到的字是 Basic、aria-label 卻寫 OAuth；radioMixed＝OAuth 那一個的 data-state 是 mixed。
        ? h('div', { role: 'radiogroup', 'aria-label': 'Authentication' },
          radio('none', 'No Auth', { checked: true, ...(form === 'radioDouble' ? { 'aria-checked': 'true' } : {}) }),
          radio(form === 'radioValue' ? 'basic' : 'oauth', form === 'radioAriaConflict' ? 'Basic' : 'OAuth',
            { ...(form === 'radioConflict' ? { 'data-state': 'unchecked' } : {}), ...(form === 'radioMixed' ? { 'data-state': 'mixed' } : {}),
              ...(form === 'radioAriaConflict' ? { 'aria-label': 'OAuth' } : {}) }))
        // R9c（GPT-6 C5）：inputCombo＝<input role=combobox>，aria-valuetext 與 value 屬性寫 OAuth、即時的值卻是 basic。
        : form === 'inputCombo'
          ? Object.assign(h('input', { role: 'combobox', 'aria-label': 'Authentication', 'aria-valuetext': 'OAuth', value: 'OAuth' }), { value: 'basic' })
          : h('button', { 'aria-haspopup': 'listbox', 'aria-label': 'Authentication', role: 'combobox' }, 'No Auth');
    const secondAuth = form === 'both' ? h('button', { 'aria-haspopup': 'listbox', 'aria-label': 'Authentication method', role: 'combobox' }, 'API key') : null;
    if (form === 'combobox') {
      auth.onclick = function () {
        const pick = (label) => h('div', { role: 'option', onclick() { auth.text = label; options.forEach((o) => o.remove()); } }, label);
        const options = [pick('No Auth'), pick('OAuth')];
        options.forEach((o) => body.appendChild(o));
      };
    }
    const create = h('button', { onclick() { created.clicks += 1; } }, 'Create');
    const dialog = h('div', { role: 'dialog' },
      h('h2', {}, 'New App'),
      warning ? h('p', {}, warning) : null,
      h('label', { for: 'app-name' }, 'Name'), h('input', { id: 'app-name' }),
      h('label', { for: 'app-desc' }, 'Description'), h('textarea', { id: 'app-desc' }),
      h('label', { for: 'mcp-url' }, 'MCP Server URL'), url,
      h('label', { for: 'auth' }, 'Authentication'), auth, secondAuth,
      // checkbox：'for'＝勾選框與它的 <label for> 分開（N2 反例用）；其他＝<label> 包著勾選框。
      checkbox === 'for' ? h('div', {}, h('input', { type: 'checkbox', id: 'trust' }), h('label', { for: 'trust' }, 'I trust this application'))
        : checkbox ? h('label', {}, h('input', { type: 'checkbox', id: 'trust' }), 'I trust this application') : null,
      create);
    return dialog;
  };
  for (let i = 0; i < plusCount; i += 1) {
    body.appendChild(h('button', { 'aria-label': 'Create app', onclick() {
      const open = () => { for (let k = 0; k < formCount; k += 1) { const d = makeDialog(); created.dialog = created.dialog || d; body.appendChild(d); } };
      if (slowForm) setTimeout(open, 400); else open();
    } }, '+'));
  }
  body.appendChild(h('div', {}, h('span', {}, 'Developer mode'), h('button', { role: 'switch', 'aria-checked': devMode ? 'true' : 'false', 'aria-label': 'Developer mode' })));
  // 目錄裡別的外掛的「新增」鈕不能被當成建立。
  body.appendChild(h('button', {}, 'Add'));
  return created;
}

test('pod connector: scan identifies an existing connector by exact MCP URL + OAuth (not by name) and reads developer mode', async () => {
  const pod = makePage({
    installed: { status: 200, json: { items: [
      { plugin: { id: 'plg_other', release: { display_name: 'TATWO', mcp: { url: 'https://os-for-chatgpt.example.com/mcp/extra' }, auth: { type: 'oauth' } } } },
      { plugin: { id: 'plg_ours', release: { display_name: 'Something else', mcp: { url: MCP }, auth: { type: 'oauth' } } } },
    ] } },
    build: (body) => pluginsPage(body),
  });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorScan', url: MCP });
  assert.equal(result.ok, true);
  assert.equal(result.data.listKnown, true);
  assert.equal(result.data.devMode, true);
  assert.deepEqual(result.data.matches, [{ id: 'plg_ours', name: 'Something else', auth: 'oauth', serverURL: MCP, detailPath: '/plugins/plg_ours' }]);
  assert.equal(pod.pageState.pathname, '/'); // Already rendered self-created section is preserved.
  assert.doesNotMatch(JSON.stringify(pod.reports), /SECRET-TOKEN|Bearer/);
});

test('pod connector: unreadable list is reported as unknown (App will not press create); dev mode off is visible', async () => {
  const pod = makePage({ installed: { status: 500, json: {} }, build: (body) => pluginsPage(body, { devMode: false }) });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorScan', url: MCP });
  assert.equal(result.data.listKnown, false);
  assert.equal(result.data.devMode, false);
  const dev = await pod.command({ cmd: 'connectorDevMode' });
  assert.equal(dev.data.devMode, false);
});

test('pod connector: create fills name, exact URL and OAuth, reads back, then presses Create once', async () => {
  let created;
  const pod = makePage({ build: (body) => (created = pluginsPage(body)) });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorCreate', url: MCP, resume: false });
  assert.deepEqual(result.data, { status: 'pressed' });
  assert.equal(created.clicks, 1);
  const inputs = queryAll(created.dialog, 'input');
  assert.equal(inputs.find((x) => x.getAttribute('id') === 'app-name').value, 'TATWO');
  assert.equal(inputs.find((x) => x.getAttribute('id') === 'mcp-url').value, MCP);
  assert.equal(queryAll(created.dialog, 'select')[0].value, 'oauth');
});

// W183 R8c：多台時每台一個連接器「TATWO（<設備名稱>）」（ChatGPT 裡分得出來）；只收這個樣子，其他一律 TATWO。辨識既有的照舊用帳號＋完整網址＋OAuth。
test('W183 R8c pod connector: named TATWO（<device name>）; anything else falls back to TATWO', async () => {
  // 歷史重複的編號也要能辨識；新建名稱由原生提供，不做撞名遞增。
  for (const [name, expected] of [['TATWO（Studio B）', 'TATWO（Studio B）'], ['Evil\nName', 'TATWO'], ['TATWO（' + 'x'.repeat(41) + '）', 'TATWO'],
    ['TATWO（a）（b）', 'TATWO'], [undefined, 'TATWO'], ['TATWO（Studio B）2', 'TATWO（Studio B）2'], ['TATWO（Studio B）10', 'TATWO（Studio B）10'], ['TATWO（Studio B）x', 'TATWO']]) {
    let created;
    const pod = makePage({ build: (body) => (created = pluginsPage(body)) });
    await pod.signIn();
    const result = await pod.command({ cmd: 'connectorCreate', url: MCP, name, resume: false });
    assert.deepEqual(result.data, { status: 'pressed' }, String(name));
    assert.equal(queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'app-name').value, expected, String(name));
  }
  assert.match(podDriver, /func create\(url: String, name: String, acknowledged: HandsConnectorAck\?\) async -> HandsConnectorAction \{\n\s*resolvedConnector = nil\n\s*var arguments: \[String: Any\] = \["url": url, "name": name\]/);
  // W183 R12（.036 實機；主導裁決：撞名就自動換名字重建）：名字改用 connectorNameInUse（沒改過＝「TATWO（<設備名稱>）」；撞名改過＝後面加 2…9，重連沿用本機記下的）。
  assert.match(connect, /action = await pod\.create\(url: intent\.mcpURL, name: connectorNameInUse\(offer\), acknowledged: ack\)/);
  assert.match(connect, /func connectorNameInUse\(_ offer: HandsConnectOffer\) -> String \{ nameInUse \?\? HandsBuildConfig\.connectorName\(offer\.hostName\) \}/);
});

test('pod connector: OAuth from a listbox combobox (options rendered outside the dialog)', async () => {
  let created;
  const pod = makePage({ build: (body) => (created = pluginsPage(body, { form: 'combobox' })) });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorCreate', url: MCP, resume: false });
  assert.deepEqual(result.data, { status: 'pressed' });
  assert.equal(created.clicks, 1);
});

test('pod connector: more than one "+" or more than one form or no form → stop, never guess', async () => {
  let created;
  const many = makePage({ build: (body) => (created = pluginsPage(body, { plusCount: 2 })) });
  await many.signIn();
  assert.deepEqual((await many.command({ cmd: 'connectorCreate', url: MCP, resume: false })).data, { status: 'ambiguous', step: 'plus' });
  assert.equal(created.clicks, 0);
  const twoForms = makePage({ build: (body) => (created = pluginsPage(body, { formCount: 2 })) });
  await twoForms.signIn();
  assert.deepEqual((await twoForms.command({ cmd: 'connectorCreate', url: MCP, resume: false })).data, { status: 'ambiguous', step: 'form' });
  assert.equal(created.clicks, 0);
  const none = makePage({ build: (body) => { body.appendChild(h('button', {}, 'Add')); return {}; } });
  await none.signIn();
  // W183 R9：舊的「＋」與改版後的「新增 ▾」都找不到（目錄裡別的外掛的「Add」不是選單鈕，不算）。
  assert.deepEqual((await none.command({ cmd: 'connectorCreate', url: MCP, resume: false }, 20000)).data, { status: 'not_found', step: 'new_button' });
});

test('pod connector: URL rewritten by the page → refused, Create not pressed', async () => {
  let created;
  const pod = makePage({ build: (body) => (created = pluginsPage(body, { tamper: true })) });
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, resume: false })).data, { status: 'refused', reason: 'url_mismatch' });
  assert.equal(created.clicks, 0);
});

test('pod connector: an unchecked trust box or a warning goes to the user (never ticked, never pressed); resume with the seen form + warning presses once', async () => {
  let created;
  const boxed = makePage({ build: (body) => (created = pluginsPage(body, { checkbox: true })) });
  await boxed.signIn();
  const first = (await boxed.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.status, 'needs_user');
  assert.equal(first.reason, 'checkbox');
  assert.match(first.form, /^f[a-z0-9]{6,20}$/);
  assert.equal(created.clicks, 0);
  assert.equal(queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'trust').checked, false, 'the App never ticks it');
  // 使用者按了「繼續」但還沒勾：照樣不按。
  const again = (await boxed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
  assert.equal(again.status, 'needs_user');
  assert.equal(again.reason, 'checkbox');
  assert.notEqual(again.form, first.form, 'W183 R9 審查：每交回一次換一個記號（上一次的確認作廢）');
  assert.equal(created.clicks, 0);
  // W183 R9 審查（GPT-6 #2）：網頁自己改成勾選（不是使用者按的）＝不算，交回給使用者、不按。
  const trust = queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'trust');
  trust.checked = true;
  const pageTicked = (await boxed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: again.form, warning: again.warning } })).data;
  assert.equal(pageTicked.status, 'needs_user');
  assert.equal(pageTicked.reason, 'untrusted_tick');
  assert.equal(created.clicks, 0);
  // 上一次的確認（已經又交回過一次）再帶來＝拒絕，不按。
  assert.deepEqual((await boxed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: again.form, warning: again.warning } })).data,
    { status: 'refused', reason: 'ack_replayed' });
  // 使用者自己取消、再勾（真的按）之後按「繼續」：同一張表單、同一段警語＝按一次。
  boxed.userClick(trust);
  boxed.userClick(trust);
  assert.equal(trust.checked, true);
  assert.deepEqual((await boxed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: pageTicked.form, warning: pageTicked.warning } })).data, { status: 'pressed' });
  assert.equal(created.clicks, 1);
  // 按過的確認再帶一次（重放）＝拒絕，不再按。
  assert.deepEqual((await boxed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: pageTicked.form, warning: pageTicked.warning } })).data,
    { status: 'refused', reason: 'ack_replayed' });
  assert.equal(created.clicks, 1);

  const warned = makePage({ build: (body) => (created = pluginsPage(body, { warning: 'Custom apps are not verified by OpenAI. High risk.' })) });
  await warned.signIn();
  const seen = (await warned.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(seen.status, 'needs_user');
  assert.equal(seen.reason, 'warning');
  assert.equal(created.clicks, 0);
  // 看過的不是這一段警語（指紋不同）：再交給使用者，不按。
  const wrong = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: 'deadbeef-1' } })).data;
  assert.equal(wrong.status, 'needs_user');
  assert.equal(created.clicks, 0);
  // 警語文字變了（同一張表單）：指紋不同＝再交給使用者。
  const note = queryAll(created.dialog, 'p')[0];
  note.text = 'Custom apps are not verified. High risk. Data may be shared.';
  const changed = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: wrong.form, warning: seen.warning } })).data;
  assert.equal(changed.status, 'needs_user');
  assert.notEqual(changed.warning, seen.warning);
  assert.equal(created.clicks, 0);
  assert.deepEqual((await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: changed.form, warning: changed.warning } })).data, { status: 'pressed' });
  assert.equal(created.clicks, 1);
});

test('pod connector: resume without the seen form (e.g. developer mode auto-resume) never treats a new form\'s warning as read', async () => {
  let created;
  const warned = makePage({ build: (body) => (created = pluginsPage(body, { warning: 'Custom apps are not verified by OpenAI. High risk.' })) });
  await warned.signIn();
  const seen = (await warned.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(seen.status, 'needs_user');
  // 表單不見了（換頁、關掉），再帶舊的 ack：新開的表單警語沒看過＝交給使用者。
  created.dialog.remove();
  created.dialog = null;
  const fresh = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data;
  assert.equal(fresh.status, 'needs_user');
  assert.notEqual(fresh.form, seen.form);
  assert.equal(created.clicks, 0);
});

test('pod connector: a newer command or connectorAbort stops an older one before its next action (no late press)', async () => {
  let created;
  const pod = makePage({ build: (body) => (created = pluginsPage(body, { slowForm: true })) });
  await pod.signIn();
  const pending = pod.command({ cmd: 'connectorCreate', url: MCP });
  await new Promise((r) => setTimeout(r, 150));
  await pod.command({ cmd: 'connectorAbort' });
  const result = await pending;
  assert.deepEqual(result.data, { status: 'aborted' });
  assert.equal(created.clicks, 0, 'the old script did not press Create after the abort');
});

test('pod connector: only well-formed https MCP URLs, never chatgpt.com/openai.com; commands do nothing outside chatgpt.com', async () => {
  const pod = makePage({ build: (body) => pluginsPage(body) });
  await pod.signIn();
  for (const bad of ['http://os-for-chatgpt.example.com/mcp', 'https://chatgpt.com/mcp', 'https://x.openai.com/mcp', 'https://os-for-chatgpt.example.com/mcp?x=1',
    'https://' + 'u' + '@os-for-chatgpt.example.com/mcp', 'https://os-for-chatgpt.example.com:8443/mcp']) {
    const result = await pod.command({ cmd: 'connectorCreate', url: bad, resume: false });
    assert.equal(result.ok, false, bad);
  }
  const other = vm.createContext({ location: { host: 'os-for-chatgpt.example.com' }, window: {} });
  assert.equal(vm.runInContext(podScript, other)(() => {}), false, 'the TATWO pairing page never gets the Pod script');
  assert.match(tap, /location\.host==='chatgpt\.com'&&window\.__tatwoPod/);
});

test('pod connector: guided mode only highlights (no clicks), home clears the highlight', async () => {
  let created;
  const pod = makePage({ build: (body) => (created = pluginsPage(body)) });
  await pod.signIn();
  const lit = await pod.command({ cmd: 'connectorHighlight', url: MCP });
  assert.equal(lit.data.highlighted, true);
  assert.equal(queryAll(pod.body, '[data-tatwo-highlight]').length, 1);
  assert.equal(created.clicks, 0);
  assert.equal(created.dialog, null, 'the + button was not pressed');
  await pod.command({ cmd: 'connectorHome' });
  assert.equal(queryAll(pod.body, '[data-tatwo-highlight]').length, 0);
  assert.equal(pod.pageState.pathname, '/');
});

/// 外掛清單頁：我們那個外掛的連結（id）、打開是詳情對話框（完整網址、驗證方式、連線鈕）；目錄裡還有別的 App 與它的「Connect」。
function installedPage(body, { withLink = true, otherConnect = true, twoConnects = false, auth = 'OAuth', textURL = true } = {}) {
  const pressed = { ours: 0, other: 0 };
  const openDetail = () => body.appendChild(h('div', { role: 'dialog' },
    h('h2', {}, 'TATWO'),
    h('p', {}, MCP),
    h('p', {}, 'Authentication ' + auth),
    h('button', { onclick() { pressed.ours += 1; } }, 'Connect'),
    twoConnects ? h('button', { onclick() { pressed.ours += 1; } }, 'Connect') : null));
  body.appendChild(h('main', {},
    withLink ? h('a', { href: '/plugins/plg_ours', onclick: openDetail }, 'TATWO') : null,
    textURL ? h('span', {}, 'Server: ' + MCP) : null,
    otherConnect ? h('section', {}, h('h3', {}, 'Another App'), h('button', { onclick() { pressed.other += 1; } }, 'Connect')) : null));
  return pressed;
}

test('pod reconnect: opens only the connector the list identified (id link), reads back URL/auth inside its detail box, presses its one Connect', async () => {
  let pressed;
  const pod = makePage({ build: (body) => (pressed = installedPage(body)) });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' });
  assert.deepEqual(result.data, { status: 'pressed' });
  assert.equal(pressed.ours, 1);
  assert.equal(pressed.other, 0, 'another app\'s Connect is never pressed');
});

test('pod reconnect: no id link on the page → not_found, even when the page text shows the full URL and another app has a unique Connect', async () => {
  let pressed;
  const pod = makePage({ build: (body) => (pressed = installedPage(body, { withLink: false })) });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' });
  assert.equal(result.data.status, 'not_found');
  assert.equal(pressed.other, 0);
  assert.equal(pressed.ours, 0);
  // 沒有 id 就不猜。
  const noID = await pod.command({ cmd: 'connectorReconnect', url: MCP });
  assert.deepEqual(noID.data, { status: 'not_found', step: 'id' });
  assert.equal(pressed.other, 0);
});

test('pod reconnect: two Connect buttons in the detail box → ambiguous; a detail box saying No Auth → refused', async () => {
  let pressed;
  const two = makePage({ build: (body) => (pressed = installedPage(body, { twoConnects: true })) });
  two.pageState.pathname = '/plugins';
  await two.signIn();
  assert.deepEqual((await two.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' })).data, { status: 'ambiguous', step: 'connect' });
  assert.equal(pressed.ours + pressed.other, 0);
  const noAuth = makePage({ build: (body) => (pressed = installedPage(body, { auth: 'No Auth' })) });
  noAuth.pageState.pathname = '/plugins';
  await noAuth.signIn();
  assert.deepEqual((await noAuth.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' })).data, { status: 'refused', reason: 'auth_not_oauth' });
  assert.equal(pressed.ours + pressed.other, 0);
});

test('pod reconnect: a longer URL that merely starts with ours (…/mcp/extra) is not our connector', async () => {
  const pod = makePage({ build: (body) => {
    const pressed = { ours: 0 };
    body.appendChild(h('main', {},
      h('a', { href: '/plugins/plg_ours', onclick() {
        body.appendChild(h('div', { role: 'dialog' }, h('p', {}, MCP + '/extra'), h('button', { onclick() { pressed.ours += 1; } }, 'Connect')));
      } }, 'TATWO')));
    return pressed;
  } });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' }, 20000);
  assert.equal(result.data.status, 'not_found');
  assert.equal(pod.page.ours, 0);
});

// W183 R12（主導 2：要真人點的那一步指給他看）：ChatGPT 開授權視窗要真的手勢——TATWO 不按，只指路。
/// 連接器的詳情對話框（完整網址＋一顆 Connect，有版面位置）；外面還有別的 App 的 Connect。
function gesturePage(body, { twoInDialog = false, noURL = false } = {}) {
  const pressed = { ours: 0, other: 0 };
  const connect = h('button', { onclick() { pressed.ours += 1; } }, 'Connect');
  connect._rect = new FakeRect(40, 300, 120, 36);
  const extra = twoInDialog ? Object.assign(h('button', { onclick() { pressed.ours += 1; } }, '連接'), { _rect: new FakeRect(40, 360, 120, 36) }) : null;
  body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'TATWO（Primary One）'), noURL ? null : h('p', {}, MCP), connect, extra));
  const other = h('button', { onclick() { pressed.other += 1; } }, 'Connect');
  other._rect = new FakeRect(40, 520, 120, 36);
  body.appendChild(h('main', {}, h('section', {}, h('h3', {}, 'Another App'), other)));
  return { pressed, connect, other };
}

test('W183 R12 pod gesture pointer: the one Connect in the box showing our URL is scrolled into view and measured; a ring + arrow are drawn only after the App verified it (show), never clicked; alive / clear / abort', async () => {
  let page;
  const pod = makePage({ viewport: { width: 400, height: 700 }, build: (body) => (page = gesturePage(body)) });
  await pod.signIn();
  const lit = () => queryAll(pod.body, '[data-tatwo-highlight]');
  const found = (await pod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data;
  assert.equal(found.status, 'found');
  assert.match(found.mark, /^f[a-z0-9]{6,20}$/);
  assert.deepEqual(found.rect, { x: 40, y: 300, w: 120, h: 36, vw: 400, vh: 700 });
  assert.equal(page.connect._scrolls.length, 1, 'scrolled into view (instant, centred)');
  assert.equal(page.connect._scrolls[0].block, 'center');
  assert.equal(lit().length, 0, 'nothing is drawn before the App verified the node (CEF snapshot)');
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'alive' })).data, { shown: false });
  // App 用 CEF 節點驗證核過同一個位置才叫 show：畫亮框＋箭頭（最上層、點得穿過去）。
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'show', mark: found.mark })).data, { shown: true });
  const marks = lit();
  assert.equal(marks.length, 2, 'a ring and an arrow');
  const ring = marks.find((m) => m.getAttribute('data-tatwo-highlight') === 'gesture');
  const arrow = marks.find((m) => m.getAttribute('data-tatwo-highlight') === 'gesture-arrow');
  assert.ok(ring && arrow);
  for (const m of marks) {
    assert.match(m.getAttribute('style'), /position:fixed;pointer-events:none;z-index:2147483647/);
    assert.equal(m.getAttribute('aria-hidden'), 'true');
  }
  assert.match(ring.getAttribute('style'), /left:34px;top:294px;width:132px;height:48px/, 'the ring hugs the button (6px outside)');
  assert.match(arrow.getAttribute('style'), /left:87px;top:270px;/, 'the arrow sits above the button, pointing down at it');
  // 記號只用一次；還指著＝alive（不重畫）。
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'show', mark: found.mark })).data, { shown: false });
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'alive' })).data, { shown: true });
  // 跟著它：捲動（位置變了）＝下一輪重畫在新的位置。
  page.connect._rect = new FakeRect(40, 200, 120, 36);
  await new Promise((r) => setTimeout(r, 400));
  assert.match(ring.getAttribute('style'), /left:34px;top:194px;/, 'the ring follows the button');
  assert.equal(page.pressed.ours + page.pressed.other, 0, 'TATWO never presses it (ChatGPT needs a real gesture)');
  await pod.command({ cmd: 'connectorGesture', phase: 'clear' });
  assert.equal(lit().length, 0);
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'alive' })).data, { shown: false });
  // 取消（connectorAbort）也拿掉。
  const again = (await pod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data;
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'show', mark: again.mark })).data, { shown: true });
  await pod.command({ cmd: 'connectorAbort' });
  assert.equal(lit().length, 0, 'cancelling removes the pointer');
  assert.equal(page.pressed.ours + page.pressed.other, 0);
});

test('W183 R12 pod gesture pointer: two buttons in that box, a box without our URL (and more than one dialog), a moved button or a stale mark → nothing is drawn', async () => {
  let two;
  const twoPod = makePage({ viewport: { width: 400, height: 700 }, build: (body) => (two = gesturePage(body, { twoInDialog: true })) });
  await twoPod.signIn();
  assert.deepEqual((await twoPod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data, { status: 'not_found' });
  assert.equal(queryAll(twoPod.body, '[data-tatwo-highlight]').length, 0);
  assert.equal(two.pressed.ours + two.pressed.other, 0);
  // 沒有放著我們網址的那一區：只有一個對話框＝看那一個（這裡只有一顆＝指它）；兩個對話框＝不猜。
  const lone = makePage({ viewport: { width: 400, height: 700 }, build: (body) => gesturePage(body, { noURL: true }) });
  await lone.signIn();
  assert.equal((await lone.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data.status, 'found');
  const many = makePage({ viewport: { width: 400, height: 700 }, build: (body) => {
    gesturePage(body, { noURL: true });
    body.appendChild(h('div', { role: 'dialog' }, h('p', {}, 'Something else')));
  } });
  await many.signIn();
  assert.deepEqual((await many.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data, { status: 'not_found' });
  // 量完之後它動了（App 核的是舊位置）＝不畫；記號不對＝不畫。
  let moved;
  const movedPod = makePage({ viewport: { width: 400, height: 700 }, build: (body) => (moved = gesturePage(body)) });
  await movedPod.signIn();
  const found = (await movedPod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data;
  assert.deepEqual((await movedPod.command({ cmd: 'connectorGesture', phase: 'show', mark: 'f000000wrong' })).data, { shown: false });
  const again = (await movedPod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data;
  moved.connect._rect = new FakeRect(40, 310, 120, 36);
  assert.deepEqual((await movedPod.command({ cmd: 'connectorGesture', phase: 'show', mark: again.mark })).data, { shown: false });
  assert.notEqual(found.mark, again.mark);
  assert.equal(queryAll(movedPod.body, '[data-tatwo-highlight]').length, 0);
  // 沒有畫面大小（量不出位置）＝不指。
  const blind = makePage({ build: (body) => gesturePage(body) });
  await blind.signIn();
  // W183 R12（.037）：量不到位置也帶那一顆的字與種類（卡片、紀錄用）。
  const blindFound = (await blind.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data;
  assert.equal(blindFound.status, 'not_found');
  assert.equal(blindFound.step, 'position');
});

// W183 R12（.033 實機 09-30：連線失敗、正式版查不到 ChatGPT 的頁面長什麼樣）：對不上時的結構快照（DOM 文字，不是截圖；不讀任何欄位的值）。
test('W183 R12 pod outline: the main dialog as an element tree (tag, role, input type/name/checked, button and label text, 80 chars per text), never field values; iframes by origin only; 16 KB cap', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const asked = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;   // 表單填好（網址、名稱）、交回使用者勾
  assert.equal(asked.status, 'needs_user');
  page.dialog.appendChild(h('iframe', { src: 'https://auth.example.org/embed?token=SECRET' }));
  page.dialog.appendChild(h('p', {}, 'x'.repeat(200)));
  const outline = (await pod.command({ cmd: 'connectorOutline' })).data.outline;
  assert.equal(typeof outline, 'string');
  assert.match(outline, /^div role=dialog/, 'the one dialog is the root');
  assert.match(outline, /\n +button disabled "Create"\n/);
  assert.match(outline, /\n +(input|div|button)[^\n]*checked=0/, 'the checkbox state');
  assert.match(outline, /\n +iframe( hidden)? #iframe src=https:\/\/auth\.example\.org\n/, 'iframes by origin only (no path, no query)');
  assert.ok(!outline.includes(MCP), 'no field values (the URL field holds the MCP URL)');
  assert.ok(!outline.includes('SECRET') && !outline.includes('/embed'));
  assert.equal(page.fields.url.value, MCP, 'the URL field really has a value (and the outline never reads it)');
  assert.ok(!outline.split('\n').some((line) => line.includes('input') && line.includes(MCP)), 'the URL field line has no value');
  assert.match(outline, /"x{80}…"/, 'texts cut at 80 characters');
  assert.equal(page.created + page.fields.create.clicks, 0, 'reading the outline presses nothing');
  // 很大的頁面：截在 16 KB。
  const big = makePage({ build: (body) => {
    const main = h('main', {}, h('h1', {}, 'Plugins'));
    body.appendChild(main);
    for (let i = 0; i < 900; i += 1) main.appendChild(h('div', {}, h('span', {}, 'row ' + i + ' ' + 'y'.repeat(40))));
  } });
  big.pageState.pathname = '/plugins';
  await big.signIn();
  const huge = (await big.command({ cmd: 'connectorOutline' })).data.outline;
  assert.ok(huge.length <= 16384 + 40, 'capped at 16 KB');
  assert.match(huge, /…（截斷在 16 KB）$/);
});

test('connector diagnostics exclude hidden/sidebar conversations and refuse to dump a chat page or ambiguous surface', async () => {
  const pod = makePage({ build(body) {
    body.appendChild(h('aside', { hidden: true }, h('a', {}, 'PRIVATE SIDEBAR TITLE')));
    body.appendChild(h('aside', {}, 'PRIVATE VISIBLE SIDEBAR'));
    body.appendChild(h('main', {},
      h('section', { hidden: true }, 'PRIVATE HIDDEN CONTENT'),
      h('h1', {}, 'Plugins'), h('button', {}, 'New')));
  } });
  await pod.signIn();
  const chat = (await pod.command({ cmd: 'connectorOutline' })).data.outline;
  assert.equal(chat, '(no unambiguous visible connector surface)');
  pod.pageState.pathname = '/plugins';
  const list = (await pod.command({ cmd: 'connectorOutline' })).data.outline;
  assert.match(list, /^main/);
  assert.match(list, /Plugins/);
  assert.doesNotMatch(list, /PRIVATE/);
  queryAll(pod.body, 'h1')[0].text = 'PRIVATE CHAT';
  assert.equal((await pod.command({ cmd: 'connectorOutline' })).data.outline, '(no unambiguous visible connector surface)', 'changing the URL alone cannot make an old chat page a diagnostic surface');
  pod.body.appendChild(h('div', { role: 'dialog' }, 'PRIVATE MODAL ONE'));
  pod.body.appendChild(h('div', { role: 'dialog' }, 'PRIVATE MODAL TWO'));
  assert.equal((await pod.command({ cmd: 'connectorOutline' })).data.outline, '(no unambiguous visible connector surface)');
});

// 真正執行 Pod 腳本；不用「原始碼含關鍵字」代替重連行為。
function namedConnectorDetail(body, name, { url = MCP, auth = 'OAuth' } = {}) {
  const button = h('button', {}, 'Connect');
  const dialog = h('div', { role: 'dialog' },
    h('h2', {}, name), h('p', {}, url), h('p', {}, 'Authentication ' + auth), button);
  body.appendChild(dialog);
  return { button, dialog };
}
const RECOVER_NAME = 'TATWO（Primary One）2';

test('reconnect recovery: an already-open named detail works without a list link; URL and OAuth are still checked', async () => {
  let detail;
  const pod = makePage({ build(body) { detail = namedConnectorDetail(body, RECOVER_NAME); } });
  pod.pageState.pathname = '/plugins/plg_ours';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME })).data, { status: 'pressed' });
  assert.equal(detail.button.clicks, 1);
});

test('reconnect recovery: an already-open ID detail works only when the current route identifies that ID', async () => {
  let detail;
  const pod = makePage({ build(body) { detail = namedConnectorDetail(body, 'TATWO'); } });
  pod.pageState.pathname = '/plugins/plg_ours';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' })).data, { status: 'pressed' });
  assert.equal(detail.button.clicks, 1);
});

test('reconnect recovery: same-origin absolute name links work and unrelated detail routes return to the list', async () => {
  let detail;
  const pod = makePage({ build(body) {
    body.appendChild(h('main', {}, h('a', {
      href: 'https://chatgpt.com/plugins/plg_ours',
      onclick() { detail = namedConnectorDetail(body, RECOVER_NAME); },
    }, RECOVER_NAME)));
  } });
  pod.pageState.pathname = '/plugins/plg_other';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME })).data, { status: 'pressed' });
  assert.equal(pod.pageState.pathname, '/plugins');
  assert.equal(detail.button.clicks, 1);
});

test('reconnect recovery: delayed ID links are awaited instead of treating URL navigation as a loaded list', async () => {
  let detail;
  const pod = makePage({});
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  const timer = setTimeout(() => pod.body.appendChild(h('main', {}, h('a', {
    href: '/plugins/plg_delayed', onclick() { detail = namedConnectorDetail(pod.body, 'TATWO'); },
  }, 'TATWO'))), 120);
  try {
    assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_delayed' })).data, { status: 'pressed' });
    assert.equal(detail.button.clicks, 1);
  } finally { clearTimeout(timer); }
});

test('reconnect recovery: a missing name or off-origin namesake never presses anything', async () => {
  let foreign;
  const pod = makePage({ build(body) {
    foreign = h('a', { href: '//evil.example/plugins/plg_ours' }, RECOVER_NAME);
    body.appendChild(h('main', {}, foreign));
  } });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME })).data, { status: 'not_found', step: 'open' });
  assert.equal(foreign.clicks, 0);
});

test('reconnect recovery: duplicate named links are ambiguous and never pressed', async () => {
  const links = [];
  const pod = makePage({ build(body) {
    for (const id of ['one', 'two']) {
      const link = h('a', { href: '/plugins/' + id }, RECOVER_NAME);
      links.push(link); body.appendChild(link);
    }
  } });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME })).data, { status: 'ambiguous', step: 'open' });
  assert.equal(links.reduce((n, l) => n + l.clicks, 0), 0);
});

test('reconnect recovery: missing OAuth evidence is refused, including a change after arming', async () => {
  for (const auth of ['', 'No Auth']) {
    let detail;
    const pod = makePage({ build(body) { detail = namedConnectorDetail(body, RECOVER_NAME, { auth }); } });
    pod.pageState.pathname = '/plugins/plg_ours';
    await pod.signIn();
    assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME })).data, { status: 'refused', reason: 'auth_not_oauth' });
    assert.equal(detail.button.clicks, 0);
  }
  let detail;
  const pod = makePage({ build(body) { detail = namedConnectorDetail(body, RECOVER_NAME); } });
  pod.pageState.pathname = '/plugins/plg_ours';
  await pod.signIn();
  const armed = (await pod.command({ cmd: 'connectorReconnect', url: MCP, name: RECOVER_NAME }, 12000, { press: false })).data;
  assert.equal(armed.status, 'armed');
  detail.dialog._kids.find((x) => x.text === 'Authentication OAuth').text = 'Authentication unknown';
  assert.equal((await pod.send({ cmd: 'connectorPress', form: armed.form })).data.status, 'refused');
  assert.equal(detail.button.clicks, 0);
});

test('W183 R12 pod Create re-rendered (.034 real page: React redraws after the tick): the press re-finds the one "Create" in the same form and presses it once; a changed field is still press_stale with a snapshot of why', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const asked = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const ready = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } }, 12000, { press: false })).data;
  assert.equal(ready.status, 'armed');
  // React 整段重畫：Create 換成一個新的節點（同樣的字、同一種元素、同一張表單）。
  const old = page.fields.create;
  let freshClicks = 0;
  const fresh = h('button', { onclick() { freshClicks += 1; page.created += 1; } }, 'Create');
  old.parentNode.appendChild(fresh);
  old.remove();
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: ready.form })).data, { status: 'pressed', refound: true });
  assert.equal(freshClicks, 1, 'the current Create was pressed once');
  assert.equal(old.clicks || 0, 0, 'the detached one was not');
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: ready.form })).data, { status: 'refused', reason: 'ack_replayed' });
  assert.equal(freshClicks, 1);
  // 兩顆 Create（不是「就是它」）＝不按。
  let two;
  const twoPod = makePage({ build: (body) => (two = newPluginsPage(body)) });
  await twoPod.signIn();
  const q2 = (await twoPod.command({ cmd: 'connectorCreate', url: MCP })).data;
  two.userTicks();
  const r2 = (await twoPod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: q2.form, warning: q2.warning } }, 12000, { press: false })).data;
  two.fields.create.parentNode.appendChild(h('button', {}, 'Create'));
  assert.deepEqual((await twoPod.send({ cmd: 'connectorPress', form: r2.form })).data, { status: 'refused', reason: 'press_stale' });
  assert.ok(['check:create_buttons_2', 'check:warning_changed'].includes((await twoPod.command({ cmd: 'connectorOutline' })).data.stale.why));
  assert.equal(two.created + two.fields.create.clicks, 0);
  // 網址欄被改＝press_stale，快照寫是哪一條、arm 的時候那一顆、現在的按鈕清單。
  let changed;
  const changedPod = makePage({ build: (body) => (changed = newPluginsPage(body)) });
  await changedPod.signIn();
  const q3 = (await changedPod.command({ cmd: 'connectorCreate', url: MCP })).data;
  changed.userTicks();
  const r3 = (await changedPod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: q3.form, warning: q3.warning } }, 12000, { press: false })).data;
  changed.fields.url.value = 'https://evil.example.net/mcp';
  assert.deepEqual((await changedPod.send({ cmd: 'connectorPress', form: r3.form })).data, { status: 'refused', reason: 'press_stale' });
  const got = (await changedPod.command({ cmd: 'connectorOutline' })).data;
  assert.equal(got.stale.why, 'check:field_values_changed');
  assert.match(got.stale.armed, /^button[^\n]*"Create"/);
  assert.match(got.stale.armedNow, /^button[^\n]*"Create"/);
  assert.match(got.stale.buttons, /button[^\n]*"Create"/);
  assert.match(got.stale.structure, /^div role=dialog/);
  assert.ok(!got.stale.structure.includes('evil.example.net'), 'no field values in the snapshot');
  assert.equal((await changedPod.command({ cmd: 'connectorOutline' })).data.stale, undefined, 'taken once');
  assert.deepEqual((await changedPod.send({ cmd: 'connectorPress', form: 'f99x12345678' })).data, { status: 'refused', reason: 'press_stale' });
  assert.equal((await changedPod.command({ cmd: 'connectorOutline' })).data.stale.why, 'no_record');
  assert.equal(changed.created + changed.fields.create.clicks, 0);
});

// W183 R12（.035 實機：程式按 Create 沒有真人手勢，ChatGPT 的授權視窗被擋、對話框整張停在等待）：Create 改成 aim → CEF 真的點擊 → confirm。
test('W183 R12 pod native Create: aim checks everything and measures Create without pressing; a real click on it + confirm = pressed (native); no click = the script presses (native:false); a real click elsewhere = press_missed, never a second press', async () => {
  const armedPage = async () => {
    let page;
    const pod = makePage({ viewport: { width: 466, height: 678 }, build: (body) => (page = newPluginsPage(body)) });
    await pod.signIn();
    const asked = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    page.userTicks();
    const ready = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } }, 12000, { press: false })).data;
    assert.equal(ready.status, 'armed');
    page.fields.create._rect = new FakeRect(300, 600, 80, 30);
    return { pod, page, form: ready.form };
  };
  // 1. 真的點在 Create 上＝按了（只有那一下，腳本不補按）。
  const one = await armedPage();
  const aimed = (await one.pod.send({ cmd: 'connectorPress', form: one.form, phase: 'aim' })).data;
  assert.deepEqual(aimed, { status: 'aimed', rect: { x: 300, y: 600, w: 80, h: 30, vw: 466, vh: 678 } });
  assert.equal(one.page.created, 0, 'aiming never presses');
  one.page.userClick(one.page.fields.create);
  assert.deepEqual((await one.pod.send({ cmd: 'connectorPress', form: one.form, phase: 'confirm' })).data, { status: 'pressed', native: true });
  assert.equal(one.page.created, 1);
  assert.deepEqual((await one.pod.send({ cmd: 'connectorPress', form: one.form })).data, { status: 'refused', reason: 'ack_replayed' });
  assert.equal(one.page.created, 1);
  // 2. 沒有真的點擊（W183 R12 .036：不准退回程式按——程式按沒有真人手勢）＝not_landed，什麼都沒按；
  //    App 改成 wait_user：Create 亮起來，使用者自己按了（poll 看到）＝pressed（byUser）。
  const two = await armedPage();
  await two.pod.send({ cmd: 'connectorPress', form: two.form, phase: 'aim' });
  assert.deepEqual((await two.pod.send({ cmd: 'connectorPress', form: two.form, phase: 'confirm' })).data, { status: 'not_landed' });
  assert.equal(two.page.created, 0);
  assert.deepEqual((await two.pod.send({ cmd: 'connectorPress', form: two.form, phase: 'wait_user' })).data, { status: 'waiting_user' });
  assert.ok(queryAll(two.pod.body, '[data-tatwo-highlight]').length >= 1, 'Create is highlighted');
  assert.deepEqual((await two.pod.send({ cmd: 'connectorPress', form: two.form, phase: 'poll' })).data, { status: 'waiting_user' });
  assert.equal(two.page.created, 0, 'waiting never presses');
  two.page.userClick(two.page.fields.create);
  assert.deepEqual((await two.pod.send({ cmd: 'connectorPress', form: two.form, phase: 'poll' })).data, { status: 'pressed', native: true, byUser: true });
  assert.equal(two.page.created, 1);
  assert.equal(queryAll(two.pod.body, '[data-tatwo-highlight]').length, 0, 'the highlight goes away');
  // 3. 真的點擊落在別處＝也不補按（not_landed）。
  const three = await armedPage();
  await three.pod.send({ cmd: 'connectorPress', form: three.form, phase: 'aim' });
  three.page.userClick(three.page.fields.name);
  assert.deepEqual((await three.pod.send({ cmd: 'connectorPress', form: three.form, phase: 'confirm' })).data, { status: 'not_landed' });
  assert.equal(three.page.created + three.page.fields.create.clicks, 0);
  await three.pod.command({ cmd: 'connectorAbort' });
  // 3b. Create 在畫面外（對話框底部被切掉）＝aim_failed＋原因（off_screen）與位置。
  const off = await armedPage();
  off.page.fields.create._rect = new FakeRect(300, 700, 80, 30);
  const missed = (await off.pod.send({ cmd: 'connectorPress', form: off.form, phase: 'aim' })).data;
  assert.equal(missed.status, 'aim_failed');
  assert.equal(missed.why, 'off_screen');
  assert.equal(missed.rect, '300,700 80x30 in 466x678');
  // 只有一部分在畫面裡＝點看得到的那一部分的中間。
  off.page.fields.create._rect = new FakeRect(300, 660, 80, 30);
  assert.deepEqual((await off.pod.send({ cmd: 'connectorPress', form: off.form, phase: 'aim' })).data, { status: 'aimed', rect: { x: 300, y: 660, w: 80, h: 18, vw: 466, vh: 678 } });
  // 4. aim 也照舊全部核：網址欄被改＝press_stale（不量、不按）。
  const four = await armedPage();
  four.page.fields.url.value = 'https://evil.example.net/mcp';
  assert.deepEqual((await four.pod.send({ cmd: 'connectorPress', form: four.form, phase: 'aim' })).data, { status: 'refused', reason: 'press_stale' });
  assert.equal(four.page.created, 0);
});

// W183 R12（.036 實機；主導裁決：撞名就自動換名字重建）
test('W208 collision never changes the connector name or presses Create again', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = pluginsPage(body)) });
  await pod.signIn();
  await pod.command({ cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）' });
  const name = queryAll(page.dialog, '#app-name')[0];
  const before = page.clicks;
  const result = await pod.command({ cmd: 'connectorRename', url: MCP, name: 'TATWO（Studio B）2' });
  assert.equal(result.ok, false);
  assert.equal(page.clicks, before);
  assert.equal(name.value, 'TATWO（Studio B）');
});

test('W183 R12 pod Continue: the "Connect <name>" dialog with the one "Continue to <name>" is found as kind continue (name must match); a real click on it = landed; another name or two buttons = not this step', async () => {
  const dialog = (name, extra) => (body) => {
    const cont = h('button', {}, h('span', {}, 'Continue to ' + name));
    cont._rect = new FakeRect(40, 540, 300, 40);
    body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'Connect ' + name), h('div', {}, 'Connectors may introduce risk'), h('div', {}, cont, extra ? h('button', {}, 'Continue to ' + name) : null)));
    body.appendChild(h('button', {}, 'Close dialog'));
    return { cont };
  };
  let page;
  const pod = makePage({ viewport: { width: 524, height: 617 }, build: (body) => (page = dialog('TATWO（Studio B）2')(body)) });
  await pod.signIn();
  const found = (await pod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP, name: 'TATWO（Studio B）2' })).data;
  assert.equal(found.status, 'found');
  assert.equal(found.kind, 'continue');
  assert.equal(found.label, 'Continue to TATWO（Studio B）2');
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'landed' })).data, { landed: false }, 'no click yet');
  pod.userClick(page.cont);
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'landed' })).data, { landed: true });
  const other = makePage({ viewport: { width: 524, height: 617 }, build: dialog('TATWO（Somebody）') });
  await other.signIn();
  assert.notEqual((await other.command({ cmd: 'connectorGesture', phase: 'find', url: MCP, name: 'TATWO（Studio B）2' })).data.kind, 'continue');
  const two = makePage({ viewport: { width: 524, height: 617 }, build: dialog('TATWO（Studio B）2', true) });
  await two.signIn();
  assert.notEqual((await two.command({ cmd: 'connectorGesture', phase: 'find', url: MCP, name: 'TATWO（Studio B）2' })).data.kind, 'continue');
});

test('W183 R12 pod reconnect by name: the list cannot see the built-but-unauthorised one — the one link whose text is exactly the remembered name is opened, the full URL and OAuth are checked in its detail, then its Connect is armed/pressed; the base name never matches the "…2" one', async () => {
  const build = (linkName) => (body) => {
    const pressed = { ours: 0 };
    const openDetail = () => body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, linkName), h('p', {}, MCP), h('p', {}, 'Authentication OAuth'),
      h('button', { onclick() { pressed.ours += 1; } }, 'Connect')));
    body.appendChild(h('main', {}, h('a', { href: '/plugins/app_xyz', onclick: openDetail }, h('span', {}, linkName))));
    return pressed;
  };
  let pressed;
  const pod = makePage({ build: (body) => (pressed = build('TATWO（Studio B）2')(body)) });
  pod.pageState.pathname = '/plugins';
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorReconnect', url: MCP, name: 'TATWO（Studio B）2' })).data, { status: 'pressed' });
  assert.equal(pressed.ours, 1);
  let other;
  const miss = makePage({ build: (body) => (other = build('TATWO（Studio B）2')(body)) });
  miss.pageState.pathname = '/plugins';
  await miss.signIn();
  assert.equal((await miss.command({ cmd: 'connectorReconnect', url: MCP, name: 'TATWO（Studio B）' })).data.status, 'not_found');
  assert.equal(other.ours, 0);
});

test('W183 R12 pod consent over the risk section only: when the risk text and the box sit in their own block, that block alone is checked (the risk-only version matches; an alert or another Name elsewhere does not matter); a changed clause shows only that block on the card', async () => {
  let page;
  const pod = makePage({ viewport: { width: 466, height: 678, visual: true }, build: (body) => (page = newPluginsPage(body, { boxRect: [20, 400, 18, 18], riskContainer: 'checkbox' })) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.reason, 'risk_ack');
  assert.equal(first.consent, undefined, 'the risk block matches the risk-only version');
  assert.ok(first.tick);
  page.dialog.appendChild(h('span', { role: 'alert' }, 'An app with this name already exists. Choose another name'));
  const again = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;   // 跟改名之後一樣：同一張表單、不帶確認
  assert.equal(again.consent, undefined, 'still recognised with an alert elsewhere on the form');
  // 那一段的字改了＝不認得；卡片只顯示那一段（不含欄位、標籤、錯誤提示）。
  let changed;
  const other = makePage({ viewport: { width: 466, height: 678, visual: true }, build: (body) => (changed = newPluginsPage(body, { boxRect: [20, 400, 18, 18], riskContainer: 'checkbox', riskClause: 'A new clause about data.' })) });
  await other.signIn();
  const offered = (await other.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(offered.consent, 'unknown');
  assert.match(offered.offer.text, /A new clause about data\./);
  assert.ok(!/Description|Authentication|already exists|Read the guide/.test(offered.offer.text), 'only the risk block: ' + offered.offer.text);
});

test('W183 R12 pod Create only 6px on screen (.037: 405,610.7 78x36 in 524x617): aimed at the visible strip', async () => {
  let page;
  const pod = makePage({ viewport: { width: 524, height: 617 }, build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const asked = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const ready = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } }, 12000, { press: false })).data;
  page.fields.create._rect = new FakeRect(405, 611, 78, 36);
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: ready.form, phase: 'aim' })).data, { status: 'aimed', rect: { x: 405, y: 611, w: 78, h: 6, vw: 524, vh: 617 } });
  assert.equal(page.created, 0);
});

test('W183 R12 pod gesture: after Create the whole plugin dialog waits (Create disabled, box ticked) → waiting, not "not found"', async () => {
  const pod = makePage({ viewport: { width: 466, height: 678 }, build: (body) => body.appendChild(h('div', { role: 'dialog' },
    h('h2', {}, 'New Plugin'),
    h('button', { role: 'checkbox', 'aria-checked': 'true', 'aria-disabled': 'true' }),
    h('button', { disabled: true }, 'Cancel'),
    h('button', { disabled: true }, 'Create'))) });
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data, { status: 'waiting' });
  // .035 實機快照的樣子（Radix：label 裡 button role=checkbox＋藏起來的 input；整張停用）。
  const real = makePage({ build: (body) => body.appendChild(h('div', { role: 'dialog' }, h('form', {},
    h('h2', {}, 'New Plugin'),
    h('label', {}, h('button', { role: 'checkbox', 'aria-checked': 'true', disabled: true }), h('input', { type: 'checkbox', hidden: true }),
      h('span', {}, 'I understand and want to continue')),
    h('div', {}, h('a', { href: 'https://developers.openai.com/x' }, 'Read the guide'), h('button', { disabled: true }, 'Cancel'), h('button', { disabled: true }, 'Create'))),
    h('button', {}, 'Close dialog'))) });
  await real.signIn();
  assert.deepEqual((await real.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data, { status: 'waiting' });
  // .036 實機：ChatGPT 在對話框裡說沒建成（同名）＝rejected＋那一句。
  const taken = makePage({ build: (body) => body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'New Plugin'),
    h('span', { role: 'alert' }, 'An app with this name already exists. Choose another name'), h('button', {}, 'Create'))) });
  await taken.signIn();
  assert.deepEqual((await taken.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data,
    { status: 'rejected', alert: 'An app with this name already exists. Choose another name' });
  const idle = makePage({ build: (body) => body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'Something'), h('button', {}, 'OK'))) });
  await idle.signIn();
  assert.deepEqual((await idle.command({ cmd: 'connectorGesture', phase: 'find', url: MCP })).data, { status: 'not_found' });
});

// W183 R12（.034 實機：CEF 的畫面快照認不到 ChatGPT 對話框裡的勾選框＝永遠不代勾）：代勾改走 DOM 驗證。
test('W183 R12 pod DOM tick: aim re-verifies the one box in TATWO\'s own form (consent unchanged, label matches, visible, enabled, unticked) and measures it; after the native click it reports ticked + Create enabled; the script never ticks', async () => {
  const ACK_AT = [20, 400, 18, 18];
  let page;
  const pod = makePage({ viewport: { width: 466, height: 678, visual: true }, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT })) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.reason, 'risk_ack');
  assert.deepEqual(first.tick, { x: 20, y: 400, w: 18, h: 18, vw: 466, vh: 678 });
  const aim = (await pod.command({ cmd: 'connectorTick', phase: 'aim', form: first.form })).data;
  assert.deepEqual(aim, { status: 'ok', tick: { x: 20, y: 400, w: 18, h: 18, vw: 466, vh: 678 } });
  assert.deepEqual((await pod.command({ cmd: 'connectorTick', phase: 'after', form: first.form })).data, { status: 'ok', checked: false, create: false });
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'false', 'aiming never ticks');
  page.userTicks();   // App 的 CEF 真滑鼠點（isTrusted）
  assert.deepEqual((await pod.command({ cmd: 'connectorTick', phase: 'after', form: first.form })).data, { status: 'ok', checked: true, create: true });
  // 勾好了＝不再瞄（還沒勾才點；點過一次就不點第二次）。
  assert.deepEqual((await pod.command({ cmd: 'connectorTick', phase: 'aim', form: first.form })).data, { status: 'changed', why: 'box' });
  // 記號不認得＝gone。
  assert.deepEqual((await pod.command({ cmd: 'connectorTick', phase: 'aim', form: 'f99x12345678' })).data, { status: 'gone' });
  assert.equal(page.created, 0);
});

test('W183 R12 pod DOM tick counter-examples: a second checkbox, a disabled box, a changed label or changed consent text between measuring and aiming → not aimed (the App does not click)', async () => {
  const ACK_AT = [20, 400, 18, 18];
  const start = async (options) => {
    let page;
    const pod = makePage({ viewport: { width: 466, height: 678, visual: true }, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT, ...options })) });
    await pod.signIn();
    const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    assert.ok(first.tick, 'measured first');
    return { pod, page, first };
  };
  const aim = async (x) => (await x.pod.command({ cmd: 'connectorTick', phase: 'aim', form: x.first.form })).data;
  const extra = await start();
  extra.page.dialog.appendChild(h('button', { role: 'checkbox', 'aria-checked': 'false' }));
  assert.deepEqual(await aim(extra), { status: 'changed', why: 'checkbox' });
  const disabled = await start();
  disabled.page.fields.box.setAttribute('aria-disabled', 'true');
  const d = await aim(disabled);
  assert.equal(d.status, 'changed');
  assert.ok(['box', 'consent'].includes(d.why), d.why);
  const relabel = await start();
  const zone = relabel.page.fields.box.parentNode;
  zone.appendChild(h('div', {}, 'Share my data with third parties'));
  const r = await aim(relabel);
  assert.equal(r.status, 'changed');
  assert.ok(['box', 'consent'].includes(r.why), r.why);
  const reworded = await start();
  reworded.page.dialog.appendChild(h('p', {}, 'New clause: we may change this later.'));
  assert.deepEqual(await aim(reworded), { status: 'changed', why: 'consent' });
  for (const x of [extra, disabled, relabel, reworded]) assert.equal(x.page.fields.box.getAttribute('aria-checked'), 'false');
});

test('pod scan: only a complete, recognised list counts as known (paged or unknown shapes stay unknown → the App never presses Create)', async () => {
  for (const [json, known] of [
    [{ items: [] }, true],
    [[], true],
    [{ items: [], has_more: true }, false],
    [{ items: [], cursor: 'abc' }, false],
    [{ items: [{}], total: 5 }, false],
    [{ results: 'nope' }, false],
    [{ items: [], plugins: [] }, false],
    [{ items: ['x'] }, false],
  ]) {
    const pod = makePage({ installed: { status: 200, json }, build: (body) => pluginsPage(body) });
    await pod.signIn();
    const result = await pod.command({ cmd: 'connectorScan', url: MCP });
    assert.equal(result.data.listKnown, known, JSON.stringify(json));
  }
  // 頁面文字只有「前綴相同的更長網址」：不當成有。
  const prefix = makePage({ installed: { status: 200, json: { items: [] } }, build: (body) => { pluginsPage(body); body.appendChild(h('p', {}, MCP + '/extra')); } });
  await prefix.signIn();
  assert.deepEqual((await prefix.command({ cmd: 'connectorScan', url: MCP })).data.matches, []);
});

test('pod account identity: login id, workspace and email only (for comparison); commands never run off chatgpt.com', async () => {
  const who = 'user-abc', mail = 'Fixture-Mail';
  const pod = makePage({ build: (body) => pluginsPage(body), routes: {
    '/backend-api/me': { id: who, email: mail },
    '/backend-api/accounts/check/v4-2023-04-27': { account_ordering: ['ws-1'], accounts: {} },
  } });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorAccount' });
  assert.deepEqual(result.data, { user: who, workspace: 'ws-1', email: mail });
  assert.doesNotMatch(JSON.stringify(pod.reports), /SECRET-TOKEN|Bearer/);
  // Swift 那端比對用的身分：讀不到（沒有登入編號也沒有信箱）＝nil，不能當成通過。
  assert.match(podDriver, /guard !user\.isEmpty \|\| !email\.isEmpty else \{ return nil \}/);
  assert.match(connect, /guard let identityNow else \{\s*return refuse\("讀不到 Pod 的 ChatGPT 帳號，無法確認是同一個帳號/);
  assert.match(connect, /guard identityNow == intent\.podIdentity else \{\s*return refuse\("Pod 的 ChatGPT 帳號在連線中途換了/);
});

test('new Swift files exist (source list sanity)', () => {
  const names = readdirSync(new URL('../' + app + 'Facade/', import.meta.url));
  for (const name of ['HandsConnect.swift', 'HandsConnectHost.swift', 'HandsConnectLinks.swift', 'HandsConnectAcceptance.swift']) assert.ok(names.includes(name), name);
});

// ---------- W183 R9：ChatGPT 改版（外掛頁「新增 ▾」→「建立 MCP 應用程式」→ New Plugin 表單） ----------
// 09-29 實機（v2.0.21.027）：自動建連接器停在「ChatGPT 的外掛頁跟預期的不一樣（plus）」——外掛頁右上角改成「新增 ▾」，
// 選單三項「建立外掛程式」「上傳外掛程式封存檔」「建立 MCP 應用程式」；表單是 New Plugin（Connection 分段 Server URL｜Tunnel、
// Authentication 下拉預設 OAuth、風險警語、「I understand and want to continue」勾選框，沒勾 Create 是灰的）。
// W183 R9 審查（Claude #11）：實機截圖只有「選單＝中文介面」與「表單＝英文介面」。下面 en 的選單字（New、Create plugin、Upload plugin archive、
// Create MCP app）與 zh 的表單字（新增外掛程式、名稱、說明、連線、伺服器 URL、通道、驗證、進階 OAuth 設定、自訂 MCP 伺服器有風險、
// 我了解並想要繼續、建立…）是猜的、還沒對過實機——列在主導實機驗的清單；拿到截圖再換成真的字。

const R9_TEXT = {
  en: { new: 'New', items: { plugin: 'Create plugin', archive: 'Upload plugin archive', mcp: 'Create MCP app' }, title: 'New Plugin',
    icon: 'Icon (optional)', nameLabel: 'Name', namePh: 'Custom Tool', desc: 'Description (optional)', descPh: 'Explain what it does in a few words',
    conn: 'Connection', server: 'Server URL', tunnel: 'Tunnel', auth: 'Authentication', adv: 'Advanced OAuth settings',
    advSub: 'Review discovered OAuth settings, or enter them manually, then choose a client setup method and configure default scopes',
    risk: 'Custom MCP servers introduce risk.', learn: 'Learn more', ack: 'I understand and want to continue',
    // W183 R10 第二輪：照 09-29 實機截圖（H/briefs/w183-r9-web-new-plugin-form.png）的完整字——白名單就是這一份。
    ackSub: 'Only connect to MCP servers you trust. An untrusted server may access or steal information shared through app use, or trick ChatGPT '
      + 'into using tools in unintended ways, including changing or deleting data.',
    png: 'PNG only. Best results at 256 x 256 px or larger. Max file size: 10 KB', guide: 'Read the guide',
    learnHref: 'https://help.openai.com/en/articles/mcp-risk', guideHref: 'https://developers.openai.com/apps-sdk',
    cancel: 'Cancel', create: 'Create', pluginTitle: 'Create plugin' },
  zh: { new: '新增', items: { plugin: '建立外掛程式', archive: '上傳外掛程式封存檔', mcp: '建立 MCP 應用程式' }, title: '新增外掛程式',
    icon: '圖示（選填）', nameLabel: '名稱', namePh: '自訂工具', desc: '說明（選填）', descPh: '用幾個字說明它的功能',
    conn: '連線', server: '伺服器 URL', tunnel: '通道', auth: '驗證', adv: '進階 OAuth 設定', advSub: '檢查找到的 OAuth 設定，或自己輸入',
    risk: '自訂 MCP 伺服器有風險。', learn: '了解更多', ack: '我了解並想要繼續', ackSub: '只連接你信任的 MCP 伺服器；不可信的伺服器可能存取或竊取資料。',
    png: '僅限 PNG。檔案大小上限：10 KB', guide: '閱讀指南', learnHref: 'https://help.openai.com/zh-hant/articles/mcp-risk',
    guideHref: 'https://developers.openai.com/apps-sdk',
    cancel: '取消', create: '建立', pluginTitle: '建立外掛程式' },
};

/// 改版後的外掛頁：右上角「新增 ▾」（選單鈕）＋選單三項；「建立 MCP 應用程式」打開 New Plugin 表單。目錄裡別的外掛的安裝鈕、「Add」都不是它。
/// W183 R9 審查（Claude #1–#3、#10、#12；GPT-6 #11）：跟真的頁面一樣——風險勾選框按了會翻轉、Create 跟著能按；灰的 Create 按了只記 clicks；
/// Icon 那一格只有「＋」（沒有 aria-label）。另有各種反例的開關（舊選單已開、外部同字項、延遲掛載、矛盾狀態、多一個勾選框、Advanced 帶 aria-haspopup…）。
function newPluginsPage(body, { lang = 'en', items = ['plugin', 'archive', 'mcp'], tunnelDefault = false, segState = 'aria', stuckTunnel = false,
  newCount = 1, plainNew = false, menuOpens = true, authDefault = 'OAuth', labelled = true, extraBox = false, advPopup = null,
  menuDelay = 0, ariaControls = false, decoyMenu = false, staleMenu = null, externalItem = false, authValueText = null,
  descInput = false, urlUnlabelled = false, tamperName = false, advText = null, splitRisk = false, segInput = null, riskClause = null, divBox = false,
  boxForm = null, riskContainer = null, boxRect = null, nativeBox = false, labelRect = null, cover = null, extraChecked = false, labelLink = null,
  learnHref = null, extraText = null, ackFirst = false, guideHref = null } = {}) {
  const t = R9_TEXT[lang];
  const s = { pressed: [], created: 0, authClicks: 0, advClicks: 0, iconClicks: 0, serverClicks: 0, tunnelClicks: 0, dialog: null, pluginDialog: null,
    fields: null, menus: 0, staleClicks: 0, externalClicks: 0, menu: null, stale: null };
  const setSeg = (el, on) => {
    if (segState === 'aria' || segState === 'unknownText') { el.setAttribute('aria-checked', on ? 'true' : 'false'); el.setAttribute('data-state', on ? 'on' : 'off'); }
    // 矛盾：aria 說沒選、data-state 說選了。
    if (segState === 'conflict') { el.setAttribute('aria-checked', 'false'); el.setAttribute('data-state', on ? 'on' : 'off'); }
  };
  const segLabel = (key) => (segState === 'unknownText' ? { server: 'Remote', tunnel: 'Local' }[key] : t[key]);
  const makeForm = () => {
    const name = h('input', { placeholder: t.namePh });
    if (tamperName) name.addEventListener('input', function () { this.value = 'Something Else'; });
    // descInput：說明欄是一般 input，placeholder 還寫著「MCP server URL」（像網址欄，但它是說明）。
    const desc = descInput ? h('input', { placeholder: 'Describe the MCP server URL this connects to' }) : h('textarea', { placeholder: t.descPh });
    const url = h('input', urlUnlabelled ? { hidden: tunnelDefault } : { placeholder: 'https://example.com/mcp', hidden: tunnelDefault });
    const connGroup = ['co', 'nn'].join('');
    // W183 R9 審查（GPT-6 N6）：segInput＝Connection 是兩個真的 <input type=radio>（<label for>）；'conflict'＝Server 的 checked 是 true、
    // data-state 卻說 unchecked，Tunnel 的 checked 是 false、data-state 卻說 checked。
    // R9c（GPT-6 C6）：'mixed'＝Server 的 data-state 是 mixed；'currentFalse'＝Server 勾著、aria-current 卻寫 false。
    const server = segInput
      ? h('input', { type: 'radio', name: connGroup, id: 'conn-server', checked: !tunnelDefault,
        'data-state': segInput === 'conflict' ? 'unchecked' : segInput === 'mixed' ? 'mixed' : (tunnelDefault ? 'unchecked' : 'checked'),
        ...(segInput === 'currentFalse' ? { 'aria-current': 'false' } : {}),
        onclick() { s.serverClicks += 1; url.hidden = false; } })
      : h('button', { role: 'radio', onclick() {
        s.serverClicks += 1;
        if (stuckTunnel) return;
        setSeg(server, true); setSeg(tunnel, false); url.hidden = false;
      } }, segLabel('server'));
    const tunnel = segInput
      ? h('input', { type: 'radio', name: connGroup, id: 'conn-tunnel', checked: tunnelDefault, 'data-state': segInput === 'conflict' ? 'checked' : (tunnelDefault ? 'checked' : 'unchecked'),
        onclick() { s.tunnelClicks += 1; url.hidden = true; } })
      : h('button', { role: 'radio', onclick() { s.tunnelClicks += 1; setSeg(tunnel, true); setSeg(server, false); url.hidden = true; } }, segLabel('tunnel'));
    if (!segInput) { setSeg(server, !tunnelDefault); setSeg(tunnel, tunnelDefault); }
    const segGroup = segInput
      ? h('div', { role: 'radiogroup' }, server, h('label', { for: 'conn-server' }, segLabel('server')), tunnel, h('label', { for: 'conn-tunnel' }, segLabel('tunnel')))
      : h('div', { role: 'radiogroup' }, server, tunnel);
    const auth = h('button', { type: 'button', ...(authValueText ? { 'aria-valuetext': authValueText } : {}), onclick() {
      s.authClicks += 1;
      const pick = (label) => h('div', { role: 'option', onclick() { auth.text = label; options.forEach((o) => o.remove()); } }, label);
      const options = [pick('OAuth'), pick('No Auth')];
      options.forEach((o) => body.appendChild(o));
    } }, authDefault);
    const create = h('button', { disabled: true, onclick() { s.created += 1; } }, t.create);
    // 真的頁面（Radix）的勾選框：按了翻轉、Create 跟著能不能按。
    // W183 R9 審查（GPT-6 N2）：divBox＝不是按鈕的 role=checkbox（div），網頁自己在 keydown 處理空白鍵與 Enter（都會翻轉）。
    const flip = (el) => {
      const on = el.getAttribute('aria-checked') !== 'true';
      el.setAttribute('aria-checked', on ? 'true' : 'false');
      el.setAttribute('data-state', on ? 'checked' : 'unchecked');
      create.disabled = !on;
    };
    // W183 R10：nativeBox＝原生 <input type=checkbox>（自訂樣式：本身很小、藏起來），字在 <label for> 裡（代勾改點那一個 label）。
    const box = nativeBox
      ? h('input', { type: 'checkbox', id: 'ack', ...(boxForm ? { form: boxForm } : {}), onclick() { create.disabled = !this.checked; } })
      : h(divBox ? 'div' : 'button', { role: 'checkbox', 'aria-checked': 'false', 'data-state': 'unchecked', ...(divBox ? { tabindex: '0' } : {}),
        ...(boxForm ? { form: boxForm } : {}), onclick() { flip(this); } });
    if (divBox) box.addEventListener('keydown', function (e) { if (e.key === ' ' || e.key === 'Enter') flip(this); });
    // W183 R10：boxRect／labelRect＝那一格、那一個 label 在畫面上的位置（[left, top, width, height]；代勾量這個）。
    if (boxRect) box._rect = new FakeRect(...boxRect);
    // labelLink：label 裡夾著一個連結（例如條款），在畫面上的位置［left, top, width, height］。
    const termsLink = labelLink ? Object.assign(h('a', { href: '#terms' }, 'terms'), { _rect: new FakeRect(...labelLink) }) : null;
    const ackLabel = nativeBox ? h('label', { for: 'ack' }, h('div', {}, t.ack), h('div', {}, t.ackSub), termsLink) : null;
    if (ackLabel && labelRect) ackLabel._rect = new FakeRect(...labelRect);
    const ackRow = () => (nativeBox ? h('div', {}, box, ackLabel) : h('div', {}, box, h('div', {}, h('div', {}, t.ack), h('div', {}, t.ackSub))));
    // extraChecked：多的那一格一開始就勾著（沒勾的只剩風險那一格，但表單上不只一格＝不代勾）。
    const extra = extraBox ? h('button', { role: 'checkbox', 'aria-checked': extraChecked ? 'true' : 'false', onclick() {
      this.setAttribute('aria-checked', this.getAttribute('aria-checked') === 'true' ? 'false' : 'true');
    } }) : null;
    // advText：Advanced 那一格的字短（只剩 advText），靠的就不是「字太長」那一道排除。
    const adv = advText
      ? h('button', { ...(advPopup ? { 'aria-haspopup': advPopup } : {}), onclick() { s.advClicks += 1; } }, advText)
      : h('button', { ...(advPopup ? { 'aria-haspopup': advPopup } : {}), onclick() { s.advClicks += 1; } }, h('div', {}, t.adv), h('div', {}, t.advSub));
    // splitRisk：主要警語拆成好幾段（只有一段有警語字）＋ Learn more 連結。
    const riskHead = h('span', {}, 'Custom MCP servers');
    const riskSpan = splitRisk ? h('div', {}, riskHead, h('span', {}, 'introduce risk.'), h('a', { href: learnHref ?? t.learnHref }, t.learn))
      : h('span', {}, t.risk, h('a', { href: learnHref ?? t.learnHref }, t.learn));
    // W183 R9 審查（GPT-6 N9）：riskClause＝同一個警語容器裡、跟著一段沒有警語字的條款（長短由測試給）。
    const clause = riskClause ? h('p', {}, riskClause) : null;
    // W183 R9c（GPT-6 C8）：riskContainer＝警語容器裡還有 Learn more 按鈕（button）、展開鈕（disclosure）、或勾選那一列本身（checkbox）。
    const riskBlock = () => (riskContainer === 'button' ? h('div', {}, riskSpan, clause, h('button', {}, 'Learn more'))
      : riskContainer === 'disclosure' ? h('div', {}, riskSpan, h('button', { 'aria-expanded': 'true' }, 'Show less'), clause)
        : riskContainer === 'checkbox' ? h('div', {}, riskSpan, clause, ackRow())
          : h('div', {}, riskSpan, clause));
    const dialog = h('div', { role: 'dialog', 'aria-modal': 'true' },
      h('h2', {}, t.title),
      h('div', {}, h('button', { onclick() { s.iconClicks += 1; } }, '+'), h('div', {}, h('div', {}, t.icon), h('div', {}, t.png))),
      h('div', {}, labelled ? h('label', {}, t.nameLabel) : h('div', {}, t.nameLabel), name),
      // descInput：說明欄的名稱寫著「MCP server URL」（像網址欄，其實是說明）：網址絕不能填進去。
      h('div', {}, h('div', {}, descInput ? 'Description (MCP server URL)' : t.desc), desc),
      h('div', {}, h('div', {}, h('span', {}, t.conn), segGroup), url),
      h('div', {}, h('div', {}, t.auth), auth),
      adv,
      // W183 R10 第二輪：ackFirst＝勾選那一列排在警語前面（字的順序換了）；extraText＝多一段新條款（放在底部按鈕前面）。
      ackFirst ? [riskContainer === 'checkbox' ? null : ackRow(), riskBlock()] : [riskBlock(),
        extra ? h('div', {}, extra, h('div', {}, 'Show this app in every chat')) : null,
        riskContainer === 'checkbox' ? null : ackRow()],
      extraText ? h('p', {}, extraText) : null,
      // W183 R10 第二輪：實機底部左邊還有「Read the guide」連結（白名單照順序核對連結的字與網域）。
      h('div', {}, h('a', { href: guideHref ?? t.guideHref }, t.guide), h('button', {}, t.cancel), create),
      // W183 R10：cover＝蓋在上面的東西（在版面上、文件順序在後面＝蓋住它底下的東西；沒有字，只驗「被蓋住」這一件）。
      cover ? Object.assign(h('div', { role: 'status' }), { _rect: new FakeRect(...cover) }) : null);
    s.fields = { name, desc, url, server, tunnel, auth, create, box, extra, adv, riskSpan, riskHead, clause, ackLabel };
    return dialog;
  };
  // 使用者自己勾「I understand and want to continue」（真的按：isTrusted）；網頁自己的程式勾（不是 isTrusted）。
  // W183 R10：TATWO 的代勾是 App 的原生點擊（CEF：網頁看到的也是 isTrusted）＝測試裡同樣用 userClick 打在 Pod 量出來的那一格上。
  s.userTicks = () => s.userClick(s.fields.box);
  s.pageTicks = () => s.pageClick(s.fields.box);
  s.userPicksTunnel = () => s.userClick(s.fields.tunnel);
  const open = (key) => {
    s.pressed.push(key);
    if (key === 'mcp') { s.dialog = makeForm(); body.appendChild(s.dialog); }
    if (key === 'plugin') {
      s.pluginName = h('input', { placeholder: t.namePh });
      s.pluginCreate = h('button', { onclick() { s.created += 1; } }, t.create);
      s.pluginDialog = h('div', { role: 'dialog' }, h('h2', {}, t.pluginTitle), h('div', {}, h('label', {}, t.nameLabel), s.pluginName),
        h('div', {}, h('button', {}, t.cancel), s.pluginCreate));
      body.appendChild(s.pluginDialog);
    }
    // archive：網頁開的是選檔視窗（不是對話框）。
  };
  if (staleMenu) {
    // 上一次留下、還開著的選單（裡面也有「Create plugin」「建立 MCP 應用程式」）：closable＝按 Escape 會關；stuck＝關不掉。
    s.stale = h('div', { role: 'menu' }, h('button', { role: 'menuitem', onclick() { s.staleClicks += 1; } }, t.pluginTitle),
      h('div', { role: 'menuitem', onclick() { s.staleClicks += 1; } }, t.items.mcp));
    body.appendChild(s.stale);
    if (staleMenu === 'closable') body.document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && s.stale) { s.stale.remove(); s.stale = null; } });
  }
  for (let i = 0; i < newCount; i += 1) {
    const attrs = plainNew ? {} : { 'aria-haspopup': 'menu', 'aria-expanded': 'false' };
    const button = h('button', { ...attrs, onclick() {
      if (!menuOpens) return;
      s.menus += 1;
      const show = () => {
        const menu = h('div', { role: 'menu', id: 'new-menu-' + s.menus },
          ...items.map((key) => h('div', { role: 'menuitem', onclick() { menu.remove(); open(key); } }, h('svg', {}), t.items[key])));
        s.menu = menu;
        if (ariaControls) button.setAttribute('aria-controls', ariaControls === 'wrong' ? 'not-this-menu' : 'new-menu-' + s.menus);
        body.appendChild(menu);
        // 同時冒出來的另一個選單（例如別的元件的）：裡面也有同字的項目。
        if (decoyMenu) body.appendChild(h('div', { role: 'menu' }, h('div', { role: 'menuitem', onclick() { s.pressed.push('decoy'); } }, t.items.mcp)));
      };
      if (menuDelay) setTimeout(show, menuDelay); else show();
    } }, t.new, h('svg', {}));
    body.appendChild(h('header', {}, button));
  }
  // 目錄：別的外掛的安裝鈕（圖示、aria-label）、一顆不是選單鈕的「Add」、（可選）一個不在選單裡、同字的 menuitem。
  body.appendChild(h('main', {}, h('section', {}, h('h3', {}, 'Gmail'), h('button', { 'aria-label': 'Install Gmail', onclick() { s.pressed.push('install'); } }, h('svg', {}))),
    h('button', { onclick() { s.pressed.push('add'); } }, 'Add'),
    externalItem ? h('div', { role: 'menuitem', onclick() { s.externalClicks += 1; } }, t.items.mcp) : null));
  body.appendChild(h('div', {}, h('span', {}, 'Developer mode'), h('button', { role: 'switch', 'aria-checked': 'true', 'aria-label': 'Developer mode' })));
  return s;
}

/// 表單上沒被使用者碰過的東西（TATWO 自己按了什麼都算）。
const untouched = (page) => {
  const f = page.fields;
  return f.box.clicks === 0 && f.create.clicks === 0 && page.iconClicks + page.advClicks === 0 && (!f.extra || f.extra.clicks === 0);
};

test('W183 R9 pod connector (new UI): 新增 ▾ → only 建立 MCP 應用程式; fills Name + exact URL, keeps Server URL and the default OAuth untouched, never ticks the risk box', async () => {
  for (const lang of ['en', 'zh']) {
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body, { lang })) });
    await pod.signIn();
    const first = (await pod.command({ cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）' })).data;
    assert.equal(first.status, 'needs_user', lang);
    assert.equal(first.reason, 'risk_ack', lang + ': the unchecked box is the "I understand and want to continue" one');
    assert.match(first.form, /^f[a-z0-9]{6,20}$/);
    assert.deepEqual(page.pressed, ['mcp'], lang + ': only 建立 MCP 應用程式 was chosen (never 建立外掛程式 or 上傳外掛程式封存檔, never a catalog button)');
    assert.equal(page.fields.name.value, 'TATWO（Studio B）');
    assert.equal(page.fields.url.value, MCP);
    assert.equal(page.fields.desc.value, '', 'Description untouched');
    assert.equal(page.authClicks + page.advClicks + page.iconClicks + page.serverClicks + page.tunnelClicks, 0, 'Authentication (already OAuth), Advanced, Icon, Connection untouched');
    assert.equal(page.fields.box.getAttribute('aria-checked'), 'false', 'the App never ticks it');
    assert.ok(untouched(page), lang + ': the risk box and the grey Create were never clicked (not even a click that the page ignored)');
    assert.equal(page.created, 0);
    // 按了「繼續」但還沒勾：照樣不按。
    const again = (await pod.command({ cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）', ack: { form: first.form, warning: first.warning } })).data;
    assert.equal(again.status, 'needs_user');
    assert.equal(again.reason, 'risk_ack');
    assert.ok(untouched(page));
    // 使用者自己勾了之後按「繼續」（帶最近一次交回的確認）：同一張表單、網址一樣、OAuth、Server URL＝按一次 Create（不再開一張新的）。
    page.userTicks();
    assert.equal(page.fields.box.clicks, 1, 'only the user clicked the box');
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）', ack: { form: again.form, warning: again.warning } })).data, { status: 'pressed' });
    assert.equal(page.created, 1);
    assert.equal(page.fields.create.clicks, 1);
    assert.equal(page.fields.box.clicks, 1, 'TATWO never clicked the box');
    assert.equal(page.menus, 1, 'the menu was opened once');
    assert.deepEqual(page.pressed, ['mcp']);
  }
});

test('W183 R9 pod connector (new UI): Connection must be Server URL — Tunnel selected → press Server URL and read back; stuck, unreadable, contradictory or unrecognised → refused, never Tunnel', async () => {
  let page;
  const tunnel = makePage({ build: (body) => (page = newPluginsPage(body, { tunnelDefault: true })) });
  await tunnel.signIn();
  const moved = (await tunnel.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(moved.status, 'needs_user');
  assert.equal(page.serverClicks, 1);
  assert.equal(page.fields.server.getAttribute('aria-checked'), 'true');
  assert.equal(page.fields.url.value, MCP);
  // W183 R9 審查（GPT-6 #4）：矛盾（aria 說沒選、data-state 說選了）、分段的字認不出來（新表單卻當舊表單放行）也一律拒絕。
  for (const opts of [{ tunnelDefault: true, stuckTunnel: true }, { segState: 'none' }, { segState: 'conflict' }, { segState: 'unknownText' }]) {
    const stuck = makePage({ build: (body) => (page = newPluginsPage(body, opts)) });
    await stuck.signIn();
    assert.deepEqual((await stuck.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'connection_not_server_url' }, JSON.stringify(opts));
    assert.equal(page.created + page.tunnelClicks + page.fields.create.clicks, 0);
    assert.equal(page.fields.url.value, '', 'nothing filled when the connection cannot be confirmed');
  }
  // 舊的「＋」開的表單沒有分段＝舊表單照舊；但表單上寫著 Tunnel（新表單的分段認不出來）＝不當舊表單放行。
  let created;
  const legacyTunnel = makePage({ build: (body) => (created = pluginsPage(body, { warning: 'Connect with a Tunnel or a URL' })) });
  await legacyTunnel.signIn();
  assert.deepEqual((await legacyTunnel.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'connection_not_server_url' });
  assert.equal(created.clicks, 0);
  // 使用者看警語時換成 Tunnel、再按「繼續」：讀回＝拒絕（不按 Create、不開新的一張）。
  const switched = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await switched.signIn();
  const seen = (await switched.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  page.userPicksTunnel();
  assert.deepEqual((await switched.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data,
    { status: 'refused', reason: 'connection_not_server_url' });
  assert.equal(page.created, 0);
  assert.equal(page.fields.create.clicks, 0);
  assert.equal(page.menus, 1);
});

test('W183 R9 pod connector (new UI): the menu item must be exactly one 建立 MCP 應用程式 inside the menu this 新增 opened; the other two, stale menus, outside or decoy items are never chosen', async () => {
  let page;
  const missing = makePage({ build: (body) => (page = newPluginsPage(body, { items: ['plugin', 'archive'] })) });
  await missing.signIn();
  assert.deepEqual((await missing.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'not_found', step: 'mcp_item' });
  assert.deepEqual(page.pressed, [], '建立外掛程式／上傳外掛程式封存檔 are never pressed');
  const twice = makePage({ build: (body) => (page = newPluginsPage(body, { items: ['plugin', 'mcp', 'mcp'] })) });
  await twice.signIn();
  assert.deepEqual((await twice.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'ambiguous', step: 'mcp_item' });
  assert.deepEqual(page.pressed, []);
  const closed = makePage({ build: (body) => (page = newPluginsPage(body, { menuOpens: false })) });
  await closed.signIn();
  assert.deepEqual((await closed.command({ cmd: 'connectorCreate', url: MCP }, 20000)).data, { status: 'not_found', step: 'new_menu' });
  const two = makePage({ build: (body) => (page = newPluginsPage(body, { newCount: 2 })) });
  await two.signIn();
  assert.deepEqual((await two.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'ambiguous', step: 'new_button' });
  assert.equal(page.menus, 0);
  const plain = makePage({ build: (body) => (page = newPluginsPage(body, { plainNew: true })) });
  await plain.signIn();
  assert.deepEqual((await plain.command({ cmd: 'connectorCreate', url: MCP }, 20000)).data, { status: 'not_found', step: 'new_button' });
  assert.deepEqual(page.pressed, [], 'the catalog install button and the plain "Add" are never pressed');
  // W183 R9 審查（GPT-6 #5）：上一次留下的選單還開著（關不掉）＝不猜；關得掉＝先關再開這一次的。
  const stuck = makePage({ build: (body) => (page = newPluginsPage(body, { staleMenu: 'stuck' })) });
  await stuck.signIn();
  assert.deepEqual((await stuck.command({ cmd: 'connectorCreate', url: MCP }, 20000)).data, { status: 'ambiguous', step: 'new_menu' });
  assert.equal(page.staleClicks + page.menus, 0, 'nothing in the stale menu was pressed, 新增 was not pressed');
  const closable = makePage({ build: (body) => (page = newPluginsPage(body, { staleMenu: 'closable' })) });
  await closable.signIn();
  assert.equal((await closable.command({ cmd: 'connectorCreate', url: MCP })).data.status, 'needs_user');
  assert.equal(page.staleClicks, 0);
  assert.deepEqual(page.pressed, ['mcp']);
  // 頁上另有同字、不在選單裡的 menuitem；選單延遲掛載；同時冒出兩個選單（有 aria-controls＝只認它指的那一個，沒有＝不猜）。
  for (const opts of [{ externalItem: true }, { menuDelay: 600 }, { ariaControls: true, decoyMenu: true }]) {
    const pod = makePage({ build: (body) => (page = newPluginsPage(body, opts)) });
    await pod.signIn();
    assert.equal((await pod.command({ cmd: 'connectorCreate', url: MCP })).data.status, 'needs_user', JSON.stringify(opts));
    assert.deepEqual(page.pressed, ['mcp'], JSON.stringify(opts));
    assert.equal(page.externalClicks, 0);
  }
  // 「新增」鈕的 aria-controls 指的不是打開的那一個選單＝不猜（不拿別的新選單頂替）。
  const wrongControls = makePage({ build: (body) => (page = newPluginsPage(body, { ariaControls: 'wrong' })) });
  await wrongControls.signIn();
  assert.deepEqual((await wrongControls.command({ cmd: 'connectorCreate', url: MCP }, 20000)).data, { status: 'not_found', step: 'new_menu' });
  assert.deepEqual(page.pressed, []);
  const decoy = makePage({ build: (body) => (page = newPluginsPage(body, { decoyMenu: true })) });
  await decoy.signIn();
  assert.deepEqual((await decoy.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'ambiguous', step: 'new_menu' });
  assert.deepEqual(page.pressed, []);
  // 舊的「＋」那一條不會認到選單裡的「Create plugin」（上一次留下的選單還開著、頁上沒有別的鈕）。
  const menuOnly = makePage({ build: (body) => {
    const s = { clicks: 0 };
    body.appendChild(h('div', { role: 'menu' }, h('button', { role: 'menuitem', onclick() { s.clicks += 1; } }, 'Create plugin')));
    return s;
  } });
  await menuOnly.signIn();
  assert.deepEqual((await menuOnly.command({ cmd: 'connectorCreate', url: MCP }, 20000)).data, { status: 'not_found', step: 'new_button' });
  assert.equal(menuOnly.page.clicks, 0);
});

test('W183 R9 pod connector (new UI): OAuth — a non-OAuth default is switched and read back; conflicting value sources, "OAuth API key", two auth controls → never Create', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body, { authDefault: 'No Auth', labelled: false })) });
  await pod.signIn();
  const result = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(result.status, 'needs_user');
  assert.equal(page.authClicks, 1);
  assert.equal(page.fields.auth.textContent, 'OAuth');
  assert.equal(page.fields.name.value, 'TATWO');
  // W183 R9 審查（GPT-6 #1）：按鈕寫 OAuth、aria-valuetext 卻是 API key＝不是 OAuth。
  const conflict = makePage({ build: (body) => (page = newPluginsPage(body, { authValueText: 'API key' })) });
  await conflict.signIn();
  assert.deepEqual((await conflict.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'auth_not_oauth' });
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 「OAuth API key」不是一種驗證方式：認不出來＝停（不按 Create）。
  const mixed = makePage({ build: (body) => (page = newPluginsPage(body, { authDefault: 'OAuth API key' })) });
  await mixed.signIn();
  assert.notEqual((await mixed.command({ cmd: 'connectorCreate', url: MCP })).data.status, 'pressed');
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 兩個驗證方式控制項（舊表單：下拉＋另一個選單鈕寫 API key）＝不挑一個相信。
  let created;
  const both = makePage({ build: (body) => (created = pluginsPage(body, { form: 'both' })) });
  await both.signIn();
  assert.deepEqual((await both.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'ambiguous', step: 'auth' });
  assert.equal(created.clicks, 0);
  // 選了的那一項字寫 OAuth、value 卻是 api_key＝不是 OAuth。
  const lying = makePage({ build: (body) => (created = pluginsPage(body, { form: 'lying' })) });
  await lying.signIn();
  assert.deepEqual((await lying.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'auth_not_oauth' });
  assert.equal(created.clicks, 0);
});

test('W183 R9 審查 (Claude #12): the Advanced OAuth settings button is never taken for the Authentication control, even with aria-haspopup', async () => {
  // 每一道排除各自有反例：aria-haspopup=dialog（字短、沒有 Advanced 字樣也不算）、aria-haspopup=menu 字短（靠 Advanced 字樣排除）、字很長。
  for (const opts of [{ advPopup: 'dialog' }, { advPopup: 'menu' }, { advPopup: 'dialog', advText: 'OAuth settings' }, { advPopup: 'menu', advText: 'Advanced OAuth' }]) {
    const advPopup = JSON.stringify(opts);
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body, opts)) });
    await pod.signIn();
    const result = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    assert.equal(result.status, 'needs_user', advPopup);
    assert.equal(result.reason, 'risk_ack', advPopup);
    assert.equal(page.advClicks + page.authClicks, 0, advPopup);
    assert.equal(page.fields.adv.clicks + page.fields.auth.clicks, 0, advPopup);
  }
});

test('W183 R9 審查 (Claude #3, #10): a second run while the dialog is still open never presses the Icon 「＋」 or Create; an unrelated extra checkbox → "checkbox", nothing ticked', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.status, 'needs_user');
  // 使用者按［再連一次］（新的一輪、不帶確認）：對話框還開著——接著用 TATWO 填好的那一張，不再按「新增」、不按 Icon 的「＋」。
  const rerun = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(rerun.status, 'needs_user');
  assert.equal(rerun.reason, 'risk_ack');
  assert.equal(page.iconClicks, 0);
  assert.equal(page.menus, 1);
  assert.ok(untouched(page));
  // 頁面上開著一張不是 TATWO 填的表單（例如上一輪沒填完、或使用者自己開的）：不在它下面按任何東西。
  const foreign = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await foreign.signIn();
  foreign.body.children.find((c) => c.tagName === 'HEADER').children[0].click();   // 使用者自己按「新增」
  page.menu.children.find((x) => x.textContent.includes(R9_TEXT.en.items.mcp)).click();
  assert.deepEqual((await foreign.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'ambiguous', step: 'form_open' });
  assert.equal(page.fields.name.value, '');
  assert.ok(untouched(page));
  // 頁上開著一個別的對話框（例如「建立外掛程式」的，Icon 那一格只有「＋」）：舊的「＋」那一條不會按到對話框裡的「＋」。
  const other = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await other.signIn();
  let bareClicks = 0;
  other.body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'Create plugin'), h('button', { onclick() { bareClicks += 1; } }, '+')));
  assert.equal((await other.command({ cmd: 'connectorCreate', url: MCP })).data.status, 'needs_user');
  assert.equal(bareClicks, 0, 'the bare 「＋」 inside another dialog is never pressed');
  assert.deepEqual(page.pressed, ['mcp']);
  // 多一個跟風險無關的勾選框：交給使用者（checkbox，不是 risk_ack），兩格都沒被按。
  const extra = makePage({ build: (body) => (page = newPluginsPage(body, { extraBox: true })) });
  await extra.signIn();
  const both = (await extra.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(both.status, 'needs_user');
  assert.equal(both.reason, 'checkbox');
  assert.equal(page.fields.extra.getAttribute('aria-checked'), 'false');
  assert.ok(untouched(page));
});

test('W183 R9 審查 (GPT-6 #2): only a real user click (isTrusted) on the handed-over box counts; the page ticking it, Tab passing over it, a replaced form or a replayed confirmation never lead to Create', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  // 網頁自己的程式勾（不是 isTrusted）＝不算。
  page.pageTicks();
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  const byPage = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
  assert.equal(byPage.status, 'needs_user');
  assert.equal(byPage.reason, 'untrusted_tick');
  assert.equal(page.created + page.fields.create.clicks, 0);
  // Tab 經過那一格不算；使用者用空白鍵取消、再勾（真的按）＝算。
  pod.userKey(page.fields.box, 'Tab');
  const tabbed = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: byPage.form, warning: byPage.warning } })).data;
  assert.equal(tabbed.reason, 'untrusted_tick');
  pod.userKey(page.fields.box, ' ');
  pod.userKey(page.fields.box, ' ');
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: tabbed.form, warning: tabbed.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);
  // 同一個確認再帶一次（重放）＝拒絕，不再按。
  assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: tabbed.form, warning: tabbed.warning } })).data,
    { status: 'refused', reason: 'ack_replayed' });
  assert.equal(page.created, 1);

  // 對話框留著、裡面的 Name 欄換成一個新的（值一樣）＝表單被換掉：拒絕。
  const swapped = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await swapped.signIn();
  const seen = (await swapped.command({ cmd: 'connectorCreate', url: MCP })).data;
  const holder = page.fields.name.parentElement;
  const twin = h('input', { placeholder: R9_TEXT.en.namePh, value: page.fields.name.value });
  page.fields.name.remove();
  holder.appendChild(twin);
  page.userTicks();
  assert.deepEqual((await swapped.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data,
    { status: 'refused', reason: 'form_replaced' });
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 交給使用者的那一格被換成一個已經勾好的新格子＝表單被換掉：拒絕。
  const boxSwap = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await boxSwap.signIn();
  const handed = (await boxSwap.command({ cmd: 'connectorCreate', url: MCP })).data;
  const row = page.fields.box.parentElement;
  page.fields.box.remove();
  row.children.unshift(Object.assign(h('button', { role: 'checkbox', 'aria-checked': 'true', 'data-state': 'checked' }), { parentElement: row }));
  page.fields.create.disabled = false;
  assert.deepEqual((await boxSwap.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data,
    { status: 'refused', reason: 'form_replaced' });
  assert.equal(page.created, 0);
  // Name 被網頁改掉（填完就變）＝拒絕。
  const renamed = makePage({ build: (body) => (page = newPluginsPage(body, { tamperName: true })) });
  await renamed.signIn();
  assert.deepEqual((await renamed.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'name_mismatch' });
  assert.equal(page.created, 0);
});

test('W183 R9 審查 (GPT-6 #6, #7): the URL goes only into a clearly-marked URL field (never Description); a changed warning block (incl. its link text) is handed back', async () => {
  let page;
  const vague = makePage({ build: (body) => (page = newPluginsPage(body, { descInput: true, urlUnlabelled: true })) });
  await vague.signIn();
  assert.deepEqual((await vague.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'not_found', step: 'url' });
  assert.equal(page.fields.desc.value, '', 'the Description (placeholder mentions MCP connection) never gets the URL');
  assert.equal(page.fields.name.value, '');
  // 使用者看完、勾了；主要警語（含 Learn more 連結的那一段）被改了＝指紋不同，再交給使用者。
  const warned = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await warned.signIn();
  const seen = (await warned.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  page.fields.riskSpan.text = 'Custom MCP servers introduce risk. They can read everything you share.';
  const changed = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data;
  assert.equal(changed.status, 'needs_user');
  assert.equal(changed.reason, 'warning');
  assert.notEqual(changed.warning, seen.warning);
  assert.equal(page.created, 0);
  // 連結字變了也算。
  page.fields.riskSpan.children[0].text = 'Read the new terms';
  const relinked = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: changed.form, warning: changed.warning } })).data;
  assert.equal(relinked.reason, 'warning');
  assert.notEqual(relinked.warning, changed.warning);
  // W183 R9 審查（GPT-6 N3）：交回新的確認＝新的一輪；上一輪（看舊警語時）的勾選不算——沒有在這一輪再勾一次就按「繼續」＝不按。
  const stale = (await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: relinked.form, warning: relinked.warning } })).data;
  assert.equal(stale.status, 'needs_user');
  assert.equal(stale.reason, 'untrusted_tick');
  assert.equal(stale.warning, relinked.warning, 'same warning; only the tick is stale');
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 使用者在這一輪自己取消、再勾一次＝按一次 Create。
  page.userTicks();
  page.userTicks();
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  assert.deepEqual((await warned.command({ cmd: 'connectorCreate', url: MCP, ack: { form: stale.form, warning: stale.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);
  // 主要警語拆成好幾段（只有一段有警語字）：沒有警語字的那一段改了也算（整段警語一起比）。
  const split = makePage({ build: (body) => (page = newPluginsPage(body, { splitRisk: true })) });
  await split.signIn();
  const splitSeen = (await split.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  page.fields.riskHead.text = 'Verified MCP servers';
  const splitChanged = (await split.command({ cmd: 'connectorCreate', url: MCP, ack: { form: splitSeen.form, warning: splitSeen.warning } })).data;
  assert.equal(splitChanged.reason, 'warning');
  assert.notEqual(splitChanged.warning, splitSeen.warning);
  assert.equal(page.created, 0);
});

// W183 R9 審查（GPT-6 N1）：同源的網頁程式在主世界改寫內建函式——Array.prototype.push 把紀錄裡的 target／box／node 換成風險那一格、
// Map／WeakMap 的 set 把東西外流、WeakMap／Map 的 get 對沒記過的東西回「1」（假裝是這一輪的證據）、Array 的 includes／indexOf 一律說有、
// Event.prototype.target 永遠說是風險那一格、HTMLInputElement 的 checked 取值器說謊。Pod 在文件建立時抓好的版本都不受影響：偽造不被收，
// 使用者自己真的勾照樣算（抓好的版本沒有把正常流程弄壞）。殘餘：CEF 沒有隔離世界，這是加高門檻；真正的界線是配對碼＋grant。
test('W183 R9 審查 (GPT-6 N1): rewriting Array.prototype.push, Map/WeakMap methods, the Event.prototype.target getter or the checked getter cannot forge "the user ticked it"', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.reason, 'risk_ack');
  pod.sandbox.__riskBox = page.fields.box;
  pod.run(`
    const box = window.__riskBox;
    const leaked = window.__leaked = [];
    const push = Array.prototype.push;
    Array.prototype.push = function (...items) {
      for (const it of items) if (it && typeof it === 'object') for (const k of ['target', 'box', 'node']) if (k in it) { try { it[k] = box; } catch (e) {} }
      return push.apply(this, items);
    };
    const includes = Array.prototype.includes, indexOf = Array.prototype.indexOf;
    Array.prototype.includes = function (x, ...rest) { return x === box ? true : includes.call(this, x, ...rest); };
    Array.prototype.indexOf = function (x, ...rest) { return x === box && indexOf.call(this, x, ...rest) < 0 ? 0 : indexOf.call(this, x, ...rest); };
    const mset = Map.prototype.set, mget = Map.prototype.get;
    Map.prototype.set = function (k, v) { push.call(leaked, v); return mset.call(this, k, v); };
    Map.prototype.get = function (k) { const v = mget.call(this, k); return v === undefined ? 1 : v; };
    const wset = WeakMap.prototype.set, wget = WeakMap.prototype.get;
    WeakMap.prototype.set = function (k, v) { push.call(leaked, k); return wset.call(this, k, v); };
    WeakMap.prototype.get = function (k) { const v = wget.call(this, k); return v === undefined ? 1 : v; };
    WeakMap.prototype.has = function () { return true; };
    Object.defineProperty(Event.prototype, 'target', { get() { return box; }, configurable: true });
  `);
  // 使用者真的點了頁面上別的地方（說明欄）；網頁的程式自己勾那一格。
  pod.userClick(page.fields.desc);
  page.pageTicks();
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  const forged = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
  assert.equal(forged.status, 'needs_user');
  assert.equal(forged.reason, 'untrusted_tick', 'the page cannot turn a click elsewhere, or its own tick, into the user\'s tick');
  assert.equal(page.created + page.fields.create.clicks, 0);
  assert.equal(pod.run('window.__leaked.some((x) => x && typeof x === "object" && ("zones" in x || "proof" in x || "asked" in x || "expectedName" in x))'), false,
    'no form record leaks through Map / WeakMap');
  // 同樣改寫還在：使用者自己取消、再勾（真的按）＝算，按一次 Create。
  page.userTicks();
  page.userTicks();
  assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: forged.form, warning: forged.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);

  // 原生勾選框：網頁把 checked 取值器改成永遠說「勾了」（舊表單的 trust 那一格）＝Pod 照樣看到沒勾，交給使用者、不按。
  let created;
  const legacy = makePage({ build: (body) => (created = pluginsPage(body, { checkbox: true })) });
  await legacy.signIn();
  const asked = (await legacy.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(asked.reason, 'checkbox');
  const real = Object.getOwnPropertyDescriptor(El.prototype, 'checked');
  try {
    Object.defineProperty(El.prototype, 'checked', { get() { return true; }, set(v) { this._checked = !!v; }, configurable: true });
    const lied = (await legacy.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } })).data;
    assert.equal(lied.status, 'needs_user');
    assert.equal(lied.reason, 'checkbox', 'the captured checked getter still reads "not ticked"');
    assert.equal(created.clicks, 0);
  } finally {
    Object.defineProperty(El.prototype, 'checked', real);
  }
});

// W183 R9 審查（GPT-6 N2、N3）：事件發生的當下就綁「這一輪交給使用者的那一格」與它的 label，只收點擊與焦點在框上的空白鍵，
// 而且要同一次操作讓它從沒勾變成勾；每次交回開新的一輪。
test('W183 R9 審查 (GPT-6 N2, N3): a re-pointed or foreign <label>, label.click() by the page, Enter, a click before the hand-back or in an earlier round never count', async () => {
  // (1) 別的欄位的 label 被網頁改成指著風險框（使用者點「Name」的 label，瀏覽器把點擊轉給風險框）＝不算。
  let created;
  const moved = makePage({ build: (body) => (created = pluginsPage(body, { checkbox: 'for' })) });
  await moved.signIn();
  const one = (await moved.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(one.reason, 'checkbox');
  const trust = queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'trust');
  const nameLabel = queryAll(created.dialog, 'label').find((x) => x.getAttribute('for') === 'app-name');
  nameLabel.setAttribute('for', 'trust');
  moved.userClick(nameLabel);
  assert.equal(trust.checked, true, 'the browser forwarded the click to the box');
  nameLabel.setAttribute('for', 'app-name');   // 網頁再改回去（這一輪已經作廢）
  const viaForeign = (await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: one.form, warning: one.warning } })).data;
  assert.equal(viaForeign.reason, 'untrusted_tick');
  assert.equal(created.clicks, 0);
  // (1b) 網頁臨時蓋一個 <label for> 在別處（不是這一輪記下的 label）：使用者點它、瀏覽器轉給風險框＝不算；按「繼續」之前拿掉也一樣。
  moved.userClick(trust);   // 先取消（這一輪：勾→沒勾）
  const overlay = h('label', { for: 'trust' }, 'Continue');
  created.dialog.appendChild(overlay);
  moved.userClick(overlay);
  assert.equal(trust.checked, true, 'the browser forwarded the overlay click to the box');
  overlay.remove();
  const viaOverlay = (await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: viaForeign.form, warning: viaForeign.warning } })).data;
  assert.equal(viaOverlay.reason, 'untrusted_tick', 'a click forwarded from a label that is not this round\'s label does not count');
  assert.equal(created.clicks, 0);
  // (2) 網頁的程式叫 label.click()（Chromium 會把轉給欄位的那一下當成真人）＝不算。
  const trustLabel = queryAll(created.dialog, 'label').find((x) => x.getAttribute('for') === 'trust' && x !== nameLabel);
  moved.userClick(trust);   // 使用者先取消（這一輪：勾→沒勾）
  assert.equal(trust.checked, false);
  trustLabel.click();       // 網頁的程式按 label：瀏覽器轉給風險框、翻成勾
  assert.equal(trust.checked, true);
  const viaScript = (await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: viaOverlay.form, warning: viaOverlay.warning } })).data;
  assert.equal(viaScript.reason, 'untrusted_tick');
  assert.equal(created.clicks, 0);
  // (3) 這一輪記下的 label 被改指別處、再改回來＝這一輪作廢（就算之後真的點）。
  moved.userClick(trust);
  trustLabel.setAttribute('for', 'app-desc');
  trustLabel.setAttribute('for', 'trust');
  moved.userClick(trustLabel);
  assert.equal(trust.checked, true);
  const repointed = (await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: viaScript.form, warning: viaScript.warning } })).data;
  assert.equal(repointed.reason, 'untrusted_tick', 'the round is void once its label relation changed');
  assert.equal(created.clicks, 0);
  // 新的一輪：使用者點這一格的 label（取消、再勾）＝算。
  moved.userClick(trustLabel);
  moved.userClick(trustLabel);
  assert.deepEqual((await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: repointed.form, warning: repointed.warning } })).data, { status: 'pressed' });
  assert.equal(created.clicks, 1);

  // (3b) MutationObserver 一筆紀錄都沒送也擋得住（點的那一刻就看 label 關聯）：這一輪記下的 label 在點的那一刻 for 指著別處
  // （瀏覽器把點擊轉給別的欄位）、網頁自己把框勾上、再把 for 改回來＝不算。
  const noMO = makePage({ build: (body) => (created = pluginsPage(body, { checkbox: 'for' })), mutationObserver: 'deaf' });
  await noMO.signIn();
  const asked3b = (await noMO.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(asked3b.reason, 'checkbox');
  const box3b = queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'trust');
  const label3b = queryAll(created.dialog, 'label').find((x) => x.getAttribute('for') === 'trust');
  label3b.setAttribute('for', 'app-desc');
  label3b.onclick = () => { box3b.checked = true; };   // 網頁自己勾
  noMO.userClick(label3b);
  label3b.onclick = null;
  label3b.setAttribute('for', 'trust');
  assert.equal(box3b.checked, true);
  const viaStale = (await noMO.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked3b.form, warning: asked3b.warning } })).data;
  assert.equal(viaStale.reason, 'untrusted_tick', 'a click on a label that did not point at the box at that moment does not count');
  assert.equal(created.clicks, 0);

  // (4) 焦點被放到那一格上、使用者按 Enter（按鈕式的勾選框被點了一下）＝不算；空白鍵＝算。
  let page;
  const keys = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await keys.signIn();
  const handed = (await keys.command({ cmd: 'connectorCreate', url: MCP })).data;
  keys.userKey(page.fields.box, 'Enter');
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  const entered = (await keys.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data;
  assert.equal(entered.reason, 'untrusted_tick');
  keys.userKey(page.fields.box, ' ');
  keys.userKey(page.fields.box, ' ');
  assert.deepEqual((await keys.command({ cmd: 'connectorCreate', url: MCP, ack: { form: entered.form, warning: entered.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);

  // (4b) 不是按鈕的 role=checkbox（網頁自己在 keydown 翻轉）：Enter＝不算；焦點在框上的空白鍵＝算。
  const divKeys = makePage({ build: (body) => (page = newPluginsPage(body, { divBox: true })) });
  await divKeys.signIn();
  const divHanded = (await divKeys.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(divHanded.reason, 'risk_ack');
  divKeys.userKey(page.fields.box, 'Enter');
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  const divEntered = (await divKeys.command({ cmd: 'connectorCreate', url: MCP, ack: { form: divHanded.form, warning: divHanded.warning } })).data;
  assert.equal(divEntered.reason, 'untrusted_tick');
  divKeys.userKey(page.fields.box, ' ');
  divKeys.userKey(page.fields.box, ' ');
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'true');
  assert.deepEqual((await divKeys.command({ cmd: 'connectorCreate', url: MCP, ack: { form: divEntered.form, warning: divEntered.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);

  // (5) 登記表單之後、第一次交回之前（TATWO 還在填）的點擊不算；上一輪的勾選也不算。
  const early = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await early.signIn();
  const pending = early.command({ cmd: 'connectorCreate', url: MCP });
  while (!(page.fields && page.fields.url.value === MCP)) await new Promise((r) => setTimeout(r, 5));
  page.userTicks();
  const beforeHandBack = (await pending).data;
  assert.equal(beforeHandBack.status, 'needs_user');
  const tooEarly = (await early.command({ cmd: 'connectorCreate', url: MCP, ack: { form: beforeHandBack.form, warning: beforeHandBack.warning } })).data;
  assert.equal(tooEarly.reason, 'untrusted_tick', 'a tick before the first hand-back is not this round\'s tick');
  assert.equal(page.created + page.fields.create.clicks, 0);
});

// W183 R9 審查（GPT-6 N4）：表單紀錄綁實際的 form 關係與操作世代；取消（connectorAbort）、離開頁面、節點拆下來過（拆了再掛回去也算）、
// 換了內層 form、Name／網址欄的 form 屬性改了＝永久作廢（使用者再勾、再按「繼續」也不按）。
test('W183 R9 審查 (GPT-6 N4): detached-and-reattached, moved into a new inner form, form attribute changed, cancelled (connectorAbort) or left the page → the record is void for good', async () => {
  const scenarios = [
    ['reattach', (pod, page) => { const d = page.dialog; const parent = d.parentElement; d.remove(); parent.appendChild(d); }, { status: 'refused', reason: 'form_replaced' }],
    ['inner form', (pod, page) => { const holder = page.fields.name.parentElement; const form = h('form', {}); holder.appendChild(form); form.appendChild(page.fields.name); }, { status: 'refused', reason: 'form_replaced' }],
    // MutationObserver 一筆紀錄都沒送也擋得住：Name 欄實際所屬的 form 換了＝表單被換掉（讀回那一道自己驗）。
    ['inner form, observer silent', (pod, page) => { const holder = page.fields.name.parentElement; const form = h('form', {}); holder.appendChild(form); form.appendChild(page.fields.name); },
      { status: 'refused', reason: 'form_replaced' }, { mutationObserver: 'deaf' }],
    ['form attribute', (pod, page) => { page.fields.url.setAttribute('form', 'another-form'); }, { status: 'refused', reason: 'form_replaced' }],
    // R9c（GPT-6 C4）：確認框改指到外面另一張 <form>（MutationObserver 一筆都沒送：讀回時比實際的歸屬）。
    ['risk box moved to another form, observer silent', (pod, page) => { pod.body.appendChild(h('form', { id: 'elsewhere' })); page.fields.box.setAttribute('form', 'elsewhere'); },
      { status: 'refused', reason: 'form_replaced' }, { mutationObserver: 'deaf' }],
    // 歸屬變了又變回來（MutationObserver 看到過）＝照樣永久作廢。
    ['outer form id swapped and back', async (pod) => {
      const first = pod.body.children.find((x) => x.getAttribute('id') === 'owner-form');
      first.setAttribute('id', 'old-owner');
      await new Promise((r) => setTimeout(r, 5));
      first.setAttribute('id', 'owner-form');
    }, { status: 'refused', reason: 'form_replaced' }, { ownerForm: true }],
    // 外面那張 form 換了 id、另一張拿走原來的 id（確認框本身一點都沒動）＝歸屬變了。
    ['outer form id swapped', (pod, page) => {
      pod.body.appendChild(h('form', { id: 'second' }));
      const first = pod.body.children.find((x) => x.getAttribute('id') === 'owner-form');
      first.setAttribute('id', 'old-owner');
      pod.body.children.find((x) => x.getAttribute('id') === 'second').setAttribute('id', 'owner-form');
    }, { status: 'refused', reason: 'form_replaced' }, { ownerForm: true }],
    ['abort', async (pod) => { assert.deepEqual((await pod.command({ cmd: 'connectorAbort' })).data, { ok: true }); }, { status: 'refused', reason: 'ack_replayed' }],
    ['left the page', async (pod) => { pod.pageState.pathname = '/gpts/mine'; pod.body.appendChild(h('div', {}, 'another page')); await new Promise((r) => setTimeout(r, 5)); pod.pageState.pathname = '/plugins'; },
      { status: 'refused', reason: 'ack_replayed' }],
  ];
  for (const [label, act, expected, options] of scenarios) {
    let page;
    const { ownerForm, ...pageOptions } = options || {};
    const pod = makePage({ build: (body) => {
      // ownerForm：確認框一開始就用 form 屬性歸到外面那張 <form id="owner-form">。
      if (ownerForm) body.appendChild(h('form', { id: 'owner-form' }));
      return (page = newPluginsPage(body, ownerForm ? { boxForm: 'owner-form' } : {}));
    }, ...pageOptions });
    await pod.signIn();
    const handed = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    assert.equal(handed.reason, 'risk_ack', label);
    await act(pod, page);
    page.userTicks();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data, expected, label);
    assert.equal(page.created + page.fields.create.clicks, 0, label);
    // 再帶一次同一個確認也一樣（永久作廢，不是這一次剛好沒讀到）。
    const again = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data;
    assert.notEqual(again.status, 'pressed', label);
    assert.equal(page.created + page.fields.create.clicks, 0, label);
  }
});

// W183 R9 審查（GPT-6 N5）：OAuth 每一種控制項都正面驗證（選中那一項的字與 value 都要是已知的 OAuth 值、其他來源不衝突；單選收全部狀態來源）。
test('W183 R9 審查 (GPT-6 N5): OAuth is positively verified for select and radio — unknown value, ARIA conflict, contradictory or double-selected radios → never Create', async () => {
  for (const form of ['basic', 'opaque', 'ariaConflict', 'radioConflict', 'radioDouble', 'radioValue']) {
    let created;
    const pod = makePage({ build: (body) => (created = pluginsPage(body, { form })) });
    await pod.signIn();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'auth_not_oauth' }, form);
    assert.equal(created.clicks, 0, form);
  }
  // 正面的對照：value 是 oauth 的下拉、一組乾淨的單選（按 OAuth、讀回其他都是沒選）＝按一次 Create。
  for (const form of ['select', 'radio']) {
    let created;
    const pod = makePage({ build: (body) => (created = pluginsPage(body, { form })) });
    await pod.signIn();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'pressed' }, form);
    assert.equal(created.clicks, 1, form);
  }
});

// W183 R9 審查（GPT-6 N6）：Connection 是真的 <input type=radio> 時也收全部狀態來源；checked 跟 data-state 打架＝讀不出來，拒絕（不用 Tunnel）。
test('W183 R9 審查 (GPT-6 N6): Connection with real input radios — consistent state works; checked vs data-state contradiction → refused, never Tunnel', async () => {
  let page;
  const ok = makePage({ build: (body) => (page = newPluginsPage(body, { segInput: 'ok' })) });
  await ok.signIn();
  const handed = (await ok.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(handed.reason, 'risk_ack');
  assert.equal(page.fields.url.value, MCP);
  const conflict = makePage({ build: (body) => (page = newPluginsPage(body, { segInput: 'conflict' })) });
  await conflict.signIn();
  assert.deepEqual((await conflict.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'connection_not_server_url' });
  assert.equal(page.tunnelClicks + page.created + page.fields.create.clicks, 0);
  assert.equal(page.fields.url.value, '');
});

// W183 R9 審查（GPT-6 N9）：警語容器超過上限（或看不出邊界）＝不自動按（warning_unbounded，App 請使用者改用手動），不靜默只比一段；
// 上限以內：同一個容器裡沒有警語字的條款改了也算（整個容器一起比）。
test('W183 R9 審查 (GPT-6 N9; R9c C8): the whole form is the warning snapshot — an over-long form → warning_unbounded; a changed keyword-free clause is caught even when the warning container holds a button, the tick box or a disclosure', async () => {
  const long = 'Terms apply to everything you send to this app. '.repeat(100);
  const clause = 'Terms apply to everything you send to this app. '.repeat(13);
  for (const riskContainer of [null, 'button', 'checkbox', 'disclosure']) {
    let page;
    // 整張表單的字超過上限：不自動按（使用者勾了、按了「繼續」也一樣）。
    const tooLong = makePage({ build: (body) => (page = newPluginsPage(body, { riskClause: long, riskContainer })) });
    await tooLong.signIn();
    const first = (await tooLong.command({ cmd: 'connectorCreate', url: MCP })).data;
    assert.equal(first.status, 'needs_user', String(riskContainer));
    assert.equal(first.reason, 'warning_unbounded', String(riskContainer));
    assert.equal(first.warning, '');
    page.userTicks();
    const again = (await tooLong.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
    assert.equal(again.reason, 'warning_unbounded', String(riskContainer));
    assert.equal(page.created + page.fields.create.clicks, 0, String(riskContainer));
    // 上限以內：同一個警語容器裡沒有警語字的條款改了＝指紋不同，再交給使用者（容器裡有按鈕、勾選框、展開鈕都一樣）。
    const medium = makePage({ build: (body) => (page = newPluginsPage(body, { riskClause: clause, riskContainer })) });
    await medium.signIn();
    const seen = (await medium.command({ cmd: 'connectorCreate', url: MCP })).data;
    assert.equal(seen.reason, 'risk_ack', String(riskContainer));
    page.userTicks();
    page.fields.clause.text = clause.replace('everything', 'nothing');
    const changed = (await medium.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data;
    assert.equal(changed.reason, 'warning', String(riskContainer) + ': a change in the keyword-free part of the warning is caught');
    assert.notEqual(changed.warning, seen.warning);
    assert.equal(page.created, 0);
    // 使用者在這一輪再看、再勾一次＝按一次（證明不是一律擋掉）。
    page.userTicks();
    page.userTicks();
    assert.deepEqual((await medium.command({ cmd: 'connectorCreate', url: MCP, ack: { form: changed.form, warning: changed.warning } })).data, { status: 'pressed' }, String(riskContainer));
  }
});

// ---------- W183 R9c（GPT-6 第三次核對 C1–C8） ----------

// SAFE-CHAIN 的範圍（Pod 腳本裡 BEGIN／END 標記之間的行號，vm 的檔名是 tatwo-pod.js）。
const SAFE_RANGES = (() => {
  const lines = podScript.split('\n');
  const out = [];
  let from = 0;
  lines.forEach((l, i) => {
    if (l.includes('SAFE-CHAIN BEGIN')) from = i + 1;
    else if (l.includes('SAFE-CHAIN END') && from) { out.push([from, i + 1]); from = 0; }
  });
  return out;
})();
// 叫換掉的版本的那一行是不是 SAFE-CHAIN 裡的（堆疊：[0] Error、[1] 這個函式、[2] 換掉的版本自己、[3] 叫它的那一行）。
const safeChainCaller = () => {
  const frames = String(new Error().stack || '').split('\n');
  const m = /tatwo-pod\.js:(\d+):\d+/.exec(frames[3] || '');
  if (!m) return 0;
  const line = Number(m[1]);
  return SAFE_RANGES.some(([a, b]) => line >= a && line <= b) ? line : 0;
};
// 把一個物件上的方法或取值器換成「記下 SAFE-CHAIN 有沒有叫到、然後照原本的做」的版本；回一個還原的函式。
const poison = (target, key, hits, label) => {
  const desc = Object.getOwnPropertyDescriptor(target, key);
  if (!desc) return () => {};
  const name = label + '.' + String(key);
  let next;
  if (typeof desc.get === 'function') {
    const get = desc.get;
    const set = desc.set;
    next = { get() { const line = safeChainCaller(); if (line) hits.push(name + '@' + line); return Reflect.apply(get, this, []); },
      set: set ? function (v) { Reflect.apply(set, this, [v]); } : undefined, configurable: true, enumerable: desc.enumerable };
  } else if (typeof desc.value === 'function') {
    const fn = desc.value;
    next = { value: function (...args) { const line = safeChainCaller(); if (line) hits.push(name + '@' + line); return Reflect.apply(fn, this, args); },
      writable: true, configurable: true, enumerable: desc.enumerable };
  } else return () => {};
  Object.defineProperty(target, key, next);
  return () => Object.defineProperty(target, key, desc);
};
const PAGE_BUILTINS = [
  ['String.prototype', ['toLowerCase', 'toUpperCase', 'trim', 'trimStart', 'trimEnd', 'replace', 'replaceAll', 'split', 'indexOf', 'lastIndexOf', 'includes', 'slice',
    'substring', 'substr', 'normalize', 'charCodeAt', 'charAt', 'codePointAt', 'startsWith', 'endsWith', 'match', 'matchAll', 'search', 'padStart', 'padEnd',
    'concat', 'at', 'localeCompare', Symbol.iterator]],
  ['Array.prototype', ['every', 'some', 'filter', 'map', 'forEach', 'indexOf', 'lastIndexOf', 'includes', 'push', 'pop', 'shift', 'unshift', 'join', 'concat',
    'find', 'findIndex', 'findLast', 'slice', 'splice', 'reverse', 'sort', 'reduce', 'flat', 'flatMap', 'fill', 'keys', 'values', 'entries', 'at', Symbol.iterator]],
  ['RegExp.prototype', ['test', 'exec', 'flags', 'global', 'ignoreCase', 'source', Symbol.replace, Symbol.match, Symbol.matchAll, Symbol.split, Symbol.search]],
  ['Object', ['keys', 'values', 'entries', 'assign', 'freeze', 'getOwnPropertyDescriptor', 'defineProperty', 'create', 'getPrototypeOf', 'fromEntries']],
  ['Object.prototype', ['hasOwnProperty', 'toString', 'valueOf', 'isPrototypeOf', 'propertyIsEnumerable']],
  ['Array', ['isArray', 'from', 'of']],
  ['JSON', ['parse', 'stringify']],
  ['Reflect', ['apply', 'get', 'set', 'has', 'ownKeys']],
  ['Function.prototype', ['call', 'apply', 'bind']],
  ['Promise.prototype', ['then', 'catch', 'finally']],
  ['Promise', ['resolve', 'reject', 'all', 'race']],
  ['Date', ['now']],
  ['Math', ['random', 'imul', 'min', 'max', 'floor']],
  ['WeakMap.prototype', ['get', 'set', 'has', 'delete']],
  ['Map.prototype', ['get', 'set', 'has', 'delete']],
  ['Set.prototype', ['add', 'has', 'delete']],
  ['Number.prototype', ['toString', 'toFixed']],
  ['Event.prototype', ['type', 'target', 'preventDefault']],
  ['KeyboardEvent.prototype', ['key', 'code']],
  ['globalThis', ['decodeURIComponent', 'encodeURIComponent', 'String', 'setTimeout', 'queueMicrotask', 'getComputedStyle']],
];
// 假 DOM 的類別（外面這一層的；全部的頁面共用：換完一定要還原）。
const DOM_CLASSES = [
  ['FakeNode', FakeNode], ['El', El], ['FakeDocument', FakeDocument], ['FakeList', FakeList], ['FakeRect', FakeRect], ['FakeStyle', FakeStyle],
  ['FakeRecord', FakeRecord], ['Response', Response], ['URL', URL],
];
const poisonAll = (pod, hits) => {
  const undo = [];
  for (const [expr, keys] of PAGE_BUILTINS) {
    const target = pod.run(expr);
    for (const key of keys) undo.push(poison(target, key, hits, expr));
  }
  for (const [label, C] of DOM_CLASSES) {
    // 底線開頭的是假 DOM 自己內部用的（不是瀏覽器的 API）。
    for (const key of Reflect.ownKeys(C.prototype)) if (key !== 'constructor' && !(typeof key === 'string' && key.startsWith('_'))) undo.push(poison(C.prototype, key, hits, label));
  }
  const mo = pod.sandbox.MutationObserver.prototype;
  for (const key of ['observe', 'disconnect']) undo.push(poison(mo, key, hits, 'MutationObserver'));
  return () => { for (const fn of undo.reverse()) fn(); };
};

test('W183 R9c (GPT-6 C1): with every page-rewritable built-in and DOM accessor replaced, the SAFE-CHAIN never calls a replaced one and every decision stays the same', async () => {
  const hits = [];
  const outcomes = [];
  const run = async (label, make, flow) => {
    const pod = make();
    await pod.signIn();
    const restore = poisonAll(pod, hits);
    try { outcomes.push([label, await flow(pod)]); } finally { restore(); }
  };
  // 1. 新表單：交回（risk_ack）→ 使用者自己勾 →「繼續」＝按一次 Create。
  let page;
  await run('create', () => makePage({ build: (body) => (page = newPluginsPage(body)) }), async (pod) => {
    const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    page.userTicks();
    const done = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
    return [first.reason, done.status, page.created];
  });
  // 2. OAuth 那一項的 value 是 basic＝拒絕。
  let created;
  await run('basic', () => makePage({ build: (body) => (created = pluginsPage(body, { form: 'basic' })) }), async (pod) => {
    const r = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    return [r.status, r.reason, created.clicks];
  });
  // 3. Connection 預設 Tunnel：按 Server URL、讀回。
  await run('tunnel', () => makePage({ build: (body) => (page = newPluginsPage(body, { tunnelDefault: true })) }), async (pod) => {
    const r = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    return [r.status, page.serverClicks, page.tunnelClicks];
  });
  // 4. 驗證方式預設 No Auth：換成 OAuth、讀回。
  await run('auth switch', () => makePage({ build: (body) => (page = newPluginsPage(body, { authDefault: 'No Auth', labelled: false })) }), async (pod) => {
    const r = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    return [r.status, page.fields.auth.textContent];
  });
  // 5. 重新連線：只按清單認出來的那一個的連線鈕。
  let pressed;
  await run('reconnect', () => { const pod = makePage({ build: (body) => (pressed = installedPage(body)) }); pod.pageState.pathname = '/plugins'; return pod; }, async (pod) => {
    const r = (await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'plg_ours' })).data;
    return [r.status, pressed.ours, pressed.other];
  });
  // 6. 掃描清單（fetch、JSON）。
  await run('scan', () => makePage({
    installed: { status: 200, json: { items: [{ plugin: { id: 'plg_ours', release: { display_name: 'Our app', mcp: { url: MCP }, auth: { type: 'oauth' } } } }] } },
    build: (body) => pluginsPage(body),
  }), async (pod) => {
    const r = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
    return [r.listKnown, JSON.stringify(r.matches)];
  });
  // 7. 原生「新增 ▾」：只開那一個對話框；還開著嗎；撤銷。
  await run('menu', () => makePage({ build: (body) => (page = newPluginsPage(body)) }), async (pod) => {
    const r = (await pod.command({ cmd: 'pluginNewMenu', item: 'mcp', op: 'op-poison-0001' })).data;
    const w = (await pod.command({ cmd: 'pluginNewMenuWatch', op: 'op-poison-0001' })).data;
    const a = (await pod.command({ cmd: 'pluginNewMenuAbort', op: 'op-poison-0001' })).data;
    return [r.status, w.open, a.ok, JSON.stringify(page.pressed)];
  });
  // 8. W183 R10 代勾：量位置（捲到中間、畫面大小、那一點最上面是誰）也只用抓好的版本；App 的原生點擊之後照舊按一次 Create。
  await run('tick', () => makePage({ viewport: { width: 466, height: 678, visual: true }, build: (body) => (page = newPluginsPage(body, { boxRect: [20, 400, 18, 18] })) }),
    async (pod) => {
      const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
      pod.userClick(page.fields.box);
      const done = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } })).data;
      return [first.reason, JSON.stringify(first.tick), done.status, page.created];
    });
  assert.deepEqual(hits, [], 'the SAFE-CHAIN called a page-rewritable method: ' + hits.slice(0, 12).join(', '));
  assert.deepEqual(outcomes, [
    ['create', ['risk_ack', 'pressed', 1]],
    ['basic', ['refused', 'auth_not_oauth', 0]],
    ['tunnel', ['needs_user', 1, 0]],
    ['auth switch', ['needs_user', 'OAuth']],
    ['reconnect', ['pressed', 1, 0]],
    ['scan', [true, JSON.stringify([{ id: 'plg_ours', name: 'Our app', auth: 'oauth', serverURL: MCP, detailPath: '/plugins/plg_ours' }])]],
    ['menu', ['opened', true, true, JSON.stringify(['mcp'])]],
    ['tick', ['risk_ack', JSON.stringify({ x: 20, y: 400, w: 18, h: 18, vw: 466, vh: 678 }), 'pressed', 1]],
  ]);
});

test('W183 R9c (GPT-6 C1): a page lying through String.prototype.toLowerCase (basic → oauth) or JSON / toJSON cannot flip a decision or the reported result; a missing capability → unsafe_env', async () => {
  // GPT-6 的例子：toLowerCase 只把 basic 回成 oauth。
  let created;
  const lying = makePage({ build: (body) => (created = pluginsPage(body, { form: 'basic' })) });
  await lying.signIn();
  lying.run(`
    const lower = String.prototype.toLowerCase;
    String.prototype.toLowerCase = function () { const s = String(this); return s === 'basic' ? 'oauth' : lower.call(this); };
    Object.prototype.toJSON = function () { return this && this.status === 'refused' ? { status: 'pressed' } : this; };
  `);
  const r = await lying.command({ cmd: 'connectorCreate', url: MCP });
  assert.deepEqual(r.data, { status: 'refused', reason: 'auth_not_oauth' }, 'the decision and the reported result are both unchanged');
  assert.equal(created.clicks, 0);
  lying.run('delete Object.prototype.toJSON;');
  // 少了必要的瀏覽器能力（例如 MutationRecord）＝連接器與「新增」一律拒絕，不退回網頁的方法。
  let page;
  const missing = makePage({ drop: ['MutationRecord'], build: (body) => (page = newPluginsPage(body)) });
  await missing.signIn();
  assert.deepEqual((await missing.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'unsafe_env' });
  assert.deepEqual((await missing.command({ cmd: 'pluginNewMenu', item: 'mcp', op: 'op-missing-0001' })).data, { status: 'refused', reason: 'unsafe_env' });
  assert.equal((await missing.command({ cmd: 'connectorScan', url: MCP })).data.listKnown, false);
  assert.deepEqual(page.pressed, [], 'nothing was pressed');
});

test('W183 R9c (GPT-6 C1): inside the SAFE-CHAIN regions the Pod script calls no page-rewritable method directly (static)', () => {
  const lines = podScript.split('\n');
  assert.equal(SAFE_RANGES.length, 3, 'kit, connector helpers, connector commands');
  const CAPTURE = /^\s*const (R_apply|O_gopd|O_define|O_create|O_keys|O_hasOwn|A_isArray|J_parse|WM|WM_get|WM_set|WM_has|Str|S_charCodeAt|SP_toLowerCase|SP_indexOf|SP_slice|RE_exec|M_imul|M_random|D_now|P|P_then|F_decode|S_setTimeout|Q_micro|W_gcs|HIST|NAV|C_URL|C_Event|C_Mouse|C_Pointer|C_Keyboard|C_PopState) = /;
  const FORBIDDEN = /(\bwaitFor\(|\bpress\(|\bsetValue\(|\brouteTo\(|\bsleep\(|\bString\(|\bObject\.|\bArray\.|\bJSON\.|\bDate\.|\bMath\.|\.(filter|map|some|every|forEach|find|findIndex|includes|indexOf|join|concat|push|slice|splice|split|replace|replaceAll|toLowerCase|toUpperCase|trim|test|exec|startsWith|endsWith|match|normalize|charCodeAt|getAttribute|setAttribute|querySelector|querySelectorAll|click|focus|dispatchEvent|getClientRects|getBoundingClientRect|remove|appendChild|contains|addEventListener|then)\(|\.(tagName|textContent|parentElement|children|childNodes|options|selected|checked|value|disabled|readOnly|hidden|style|nodeType|nodeValue)\b|\bc\.(url|name|ack|op|item|connectorID|path|cmd)\b|\[\.\.\.|\bfor \(const [A-Za-z_]+ of\b)/;
  const hits = [];
  for (const [a, b] of SAFE_RANGES) {
    for (let i = a; i <= b; i += 1) {
      const code = lines[i - 1].replace(/\/\/.*$/, '');
      if (CAPTURE.test(code)) continue;
      // 允許：methodOf 讀屬性描述子的 value（腳本一開始、網頁還沒跑時）。
      if (/const methodOf = /.test(code)) continue;
      const m = FORBIDDEN.exec(code);
      if (m) hits.push(i + ': ' + m[0] + ' | ' + code.trim().slice(0, 100));
    }
  }
  assert.deepEqual(hits, []);
  // 腳本一開始就包好 History、聽 Navigation API；回報連接器結果用自己寫的 JSON、用抓好的 then。
  assert.match(podScript, /O_define\(HP, 'pushState', \{ value: wrap\(H_push, 'history_push'\), writable: true, configurable: true, enumerable: true \}\);\s*O_define\(HP, 'replaceState', \{ value: wrap\(H_replace, 'history_replace'\), writable: true, configurable: true, enumerable: true \}\);/);
  assert.match(podScript, /R_apply\(M_addEvt, NAV, \['currententrychange', \(event\) => \{\s*let type = 'unknown';\s*try \{\s*const value = pget\(G_navChangeType, event\);\s*if \(value === 'push' \|\| value === 'replace' \|\| value === 'traverse' \|\| value === 'reload'\) type = value;\s*\} catch \(e\) \{\}\s*pathNow\('currententrychange', type\);\s*\}\]\)/);
  assert.match(podScript, /const reply = listHas\(SAFE_COMMANDS, cmd\) \? postSafe : post;/);
  assert.match(podScript, /R_apply\(P_then, pending, \[/);
});

// R9c（GPT-6 C2）：每一次有效的啟動先同步拿掉那一格的舊證據；使用者取消之後網頁自己再勾回去（處理程式裡、或微任務裡）＝沒有證據。
test('W183 R9c (GPT-6 C2): after the user unticks, the page ticking it back (in its click handler or a microtask) leaves no valid proof', async () => {
  for (const when of ['microtask', 'handler']) {
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
    await pod.signIn();
    const handed = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    page.userTicks();   // 使用者真的勾（這一輪有證據）
    await new Promise((r) => setTimeout(r, 5));
    const box = page.fields.box;
    const recheck = () => { box.setAttribute('aria-checked', 'true'); box.setAttribute('data-state', 'checked'); page.fields.create.disabled = false; };
    box.addEventListener('click', function () {
      if (this.getAttribute('aria-checked') !== 'false') return;
      if (when === 'microtask') queueMicrotask(recheck); else recheck();
    });
    page.userTicks();   // 使用者真的取消；網頁再勾回去
    await new Promise((r) => setTimeout(r, 5));
    assert.equal(box.getAttribute('aria-checked'), 'true', when);
    const after = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data;
    assert.equal(after.status, 'needs_user', when);
    assert.equal(after.reason, 'untrusted_tick', when + ': the earlier proof was revoked by the user\'s untick');
    assert.equal(page.created + page.fields.create.clicks, 0, when);
  }
  // 原生勾選框：使用者點掉之後網頁在處理程式裡再設成勾（瀏覽器先翻轉、網頁再翻回來）＝一樣沒有證據。
  let created;
  const legacy = makePage({ build: (body) => (created = pluginsPage(body, { checkbox: true })) });
  await legacy.signIn();
  const asked = (await legacy.command({ cmd: 'connectorCreate', url: MCP })).data;
  const trust = queryAll(created.dialog, 'input').find((x) => x.getAttribute('id') === 'trust');
  legacy.userClick(trust);
  await new Promise((r) => setTimeout(r, 5));
  trust.addEventListener('click', function () { if (!this.checked) this.checked = true; });
  legacy.userClick(trust);
  assert.equal(trust.checked, true);
  const legacyAfter = (await legacy.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } })).data;
  assert.equal(legacyAfter.reason, 'untrusted_tick');
  assert.equal(created.clicks, 0);
});

// R9c（GPT-6 C3）：同一份文件裡離開又回來（沒有 DOM 變化、沒有 popstate）、繞過 History.prototype 的換網址、原生回報的導頁＝紀錄永久作廢。
test('W183 R9c (GPT-6 C3): a same-document round trip with no DOM change, a navigation that bypasses History.prototype, or a navigation the native side reports → the confirmation is void for good', async () => {
  const cases = [
    ['pushState round trip', (pod) => { pod.run("history.pushState({}, '', '/gpts/mine'); history.pushState({}, '', '/plugins');"); }],
    // 沒有 Navigation API 的頁面：只靠包好的 History 也擋得住。
    ['pushState round trip, no Navigation API', (pod) => { pod.run("history.pushState({}, '', '/gpts/mine'); history.pushState({}, '', '/plugins');"); }, { drop: ['navigation'] }],
    ['replaceState round trip', (pod) => { pod.run("history.replaceState({}, '', '/gpts/mine'); history.replaceState({}, '', '/plugins');"); }],
    ['navigation API only', (pod) => { pod.navigateNatively('/gpts/mine'); pod.navigateNatively('/plugins'); }],
    ['native report after returning', async (pod) => { assert.deepEqual((await pod.command({ cmd: 'connectorNavigated', path: '/gpts/mine' })).data, { ok: true }); }],
  ];
  for (const [label, act, options] of cases) {
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body)), ...(options || {}) });
    await pod.signIn();
    const handed = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
    await act(pod);
    assert.equal(pod.pageState.pathname, '/plugins', label);
    page.userTicks();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data,
      { status: 'refused', reason: 'ack_replayed' }, label);
    assert.equal(page.created + page.fields.create.clicks, 0, label);
  }
  // 對照：換網址但路徑沒變（replaceState 同一個路徑）不算離開，照樣按得下去。
  let page;
  const same = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await same.signIn();
  const handed = (await same.command({ cmd: 'connectorCreate', url: MCP })).data;
  same.run("history.replaceState({}, '', '/plugins');");
  await same.command({ cmd: 'connectorNavigated', path: '/plugins' });
  page.userTicks();
  assert.deepEqual((await same.command({ cmd: 'connectorCreate', url: MCP, ack: { form: handed.form, warning: handed.warning } })).data, { status: 'pressed' });
});

// R9c（GPT-6 C5、C6）：值來源照控制項種類讀（輸入框式讀即時的值；單選分別核對看得到的名字與 aria）；狀態來源讀不出來或矛盾＝null。
test('W183 R9c (GPT-6 C5, C6): input combobox live value, radio visible label vs aria-label, data-state mixed and aria-current=false are never taken as OAuth / Server URL', async () => {
  for (const [form, expected] of [['inputCombo', { status: 'not_found', step: 'auth' }], ['radioAriaConflict', { status: 'refused', reason: 'auth_not_oauth' }],
    ['radioMixed', { status: 'refused', reason: 'auth_not_oauth' }]]) {
    let created;
    const pod = makePage({ build: (body) => (created = pluginsPage(body, { form })) });
    await pod.signIn();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP })).data, expected, form);
    assert.equal(created.clicks, 0, form);
  }
  for (const segInput of ['mixed', 'currentFalse']) {
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body, { segInput })) });
    await pod.signIn();
    assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP })).data, { status: 'refused', reason: 'connection_not_server_url' }, segInput);
    assert.equal(page.tunnelClicks + page.created + page.fields.create.clicks, 0, segInput);
  }
});

test('W183 R9 guided mode (new UI) highlights 「新增 ▾」 without pressing it', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  const lit = await pod.command({ cmd: 'connectorHighlight', url: MCP });
  assert.equal(lit.data.highlighted, true);
  assert.equal(queryAll(pod.body, '[data-tatwo-highlight]').length, 1);
  assert.equal(page.menus, 0);
  assert.deepEqual(page.pressed, []);
});

test('W183 R9 pluginNewMenu (native 外掛頁「新增 ▾」): opens only that dialog — nothing filled, ticked or created; archive only highlights; one-time op; the App can ask whether it is still open', async () => {
  let n = 0;
  const op = () => 'op-fixture-' + String(n += 1).padStart(4, '0');
  for (const lang of ['en', 'zh']) {
    let page;
    const pod = makePage({ build: (body) => (page = newPluginsPage(body, { lang })) });
    await pod.signIn();
    const id = op();
    assert.deepEqual((await pod.command({ cmd: 'pluginNewMenu', item: 'mcp', op: id })).data, { status: 'opened' }, lang);
    assert.deepEqual(page.pressed, ['mcp']);
    assert.equal(pod.pageState.pathname, '/plugins');
    for (const key of ['name', 'desc', 'url']) assert.equal(page.fields[key].value, '', `${lang} ${key} not filled`);
    assert.equal(page.fields.box.getAttribute('aria-checked'), 'false', 'the risk box is not ticked');
    assert.ok(untouched(page), 'the risk box and Create were never clicked');
    assert.equal(page.created + page.authClicks + page.serverClicks + page.tunnelClicks + page.advClicks + page.iconClicks, 0, 'nothing else pressed');
    // App 問「還開著嗎」：開著；對話框關了＝沒開著；別的序號＝不認得。
    assert.deepEqual((await pod.command({ cmd: 'pluginNewMenuWatch', op: id })).data, { known: true, open: true });
    assert.deepEqual((await pod.command({ cmd: 'pluginNewMenuWatch', op: 'op-someone-else' })).data, { known: false, open: false });
    page.dialog.remove();
    assert.deepEqual((await pod.command({ cmd: 'pluginNewMenuWatch', op: id })).data, { known: true, open: false });
    // 一次性：同一個序號再用＝拒絕（不再按）；沒有序號＝不收。
    assert.deepEqual((await pod.command({ cmd: 'pluginNewMenu', item: 'mcp', op: id })).data, { status: 'refused', reason: 'op_used' });
    assert.equal((await pod.command({ cmd: 'pluginNewMenu', item: 'mcp' })).ok, false);
    assert.equal(page.menus, 1);
  }
  let page;
  const plugin = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await plugin.signIn();
  assert.deepEqual((await plugin.command({ cmd: 'pluginNewMenu', item: 'plugin', op: op() })).data, { status: 'opened' });
  assert.deepEqual(page.pressed, ['plugin']);
  assert.equal(page.pluginName.value, '', 'the plugin form is not filled');
  assert.equal(page.pluginCreate.clicks, 0, 'its Create is never pressed');
  assert.equal(page.created, 0);
  // W183 R9 審查（GPT-6 #10）：上傳封存檔＝只打開「新增」選單、標出那一項（使用者自己點它選檔）；不按那一項、不回假的 pressed。
  const archive = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await archive.signIn();
  const archiveOp = op();
  assert.deepEqual((await archive.command({ cmd: 'pluginNewMenu', item: 'archive', op: archiveOp })).data, { status: 'menu_open' });
  assert.deepEqual(page.pressed, [], 'the archive item is only highlighted, never pressed by TATWO');
  assert.equal(queryAll(archive.body, '[data-tatwo-highlight]').length, 1);
  assert.deepEqual((await archive.command({ cmd: 'pluginNewMenuWatch', op: archiveOp })).data, { known: true, open: true });
  archive.userClick(page.menu.children.find((x) => x.textContent.includes(R9_TEXT.en.items.archive)));
  assert.deepEqual(page.pressed, ['archive'], 'the user clicked it');
  assert.deepEqual((await archive.command({ cmd: 'pluginNewMenuWatch', op: archiveOp })).data, { known: true, open: false });
  // 撤銷（分頁關掉、私訊框收起來）：還在等選單的那一次在下一個動作前停手，選單晚出來也不按。
  const slow = makePage({ build: (body) => (page = newPluginsPage(body, { menuDelay: 700 })) });
  await slow.signIn();
  const slowOp = op();
  const pending = slow.command({ cmd: 'pluginNewMenu', item: 'mcp', op: slowOp });
  await new Promise((r) => setTimeout(r, 200));
  await slow.command({ cmd: 'pluginNewMenuAbort', op: slowOp });
  assert.deepEqual((await pending).data, { status: 'aborted' });
  await new Promise((r) => setTimeout(r, 900));
  assert.deepEqual(page.pressed, [], 'nothing pressed after the abort');
  // 已經開著對話框＝不在它下面按。
  const busy = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await busy.signIn();
  busy.body.appendChild(h('div', { role: 'dialog' }, h('p', {}, 'Something else')));
  assert.deepEqual((await busy.command({ cmd: 'pluginNewMenu', item: 'mcp', op: op() })).data, { status: 'busy', step: 'dialog_open' });
  assert.equal(page.menus, 0);
  const unknown = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await unknown.signIn();
  assert.equal((await unknown.command({ cmd: 'pluginNewMenu', item: 'upload', op: op() })).ok, false);
  assert.equal(page.menus, 0);
  const missing = makePage({ build: (body) => (page = newPluginsPage(body, { items: ['plugin', 'archive'] })) });
  await missing.signIn();
  assert.deepEqual((await missing.command({ cmd: 'pluginNewMenu', item: 'mcp', op: op() })).data, { status: 'not_found', step: 'menu_item' });
  assert.deepEqual(page.pressed, []);
  const old = makePage({ build: (body) => pluginsPage(body) });
  await old.signIn();
  assert.deepEqual((await old.command({ cmd: 'pluginNewMenu', item: 'mcp', op: op() }, 20000)).data, { status: 'not_found', step: 'new_button' });
});

test('W183 R9 審查 (GPT-6 #3): every Pod command must carry the App key — the page\'s own script (no key, wrong key, un-keyed script) is dropped silently', async () => {
  let page;
  const pod = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await pod.signIn();
  assert.ok(await pod.silent({ cmd: 'pluginNewMenu', item: 'mcp', op: 'op-from-the-page-1' }), 'no key → no result at all');
  assert.ok(await pod.silent({ cmd: 'pluginNewMenu', item: 'mcp', op: 'op-from-the-page-2', key: POD_KEY.replace(/^a/, 'b') }), 'wrong key → no result');
  assert.ok(await pod.silent({ cmd: 'connectorCreate', url: MCP, key: '' }));
  assert.ok(await pod.silent({ cmd: 'list', offset: 0, limit: 5 }), 'every command, not only the connector ones');
  assert.equal(page.menus + page.pressed.length, 0, 'nothing happened on the page');
  // 佔位字沒換掉（App 沒給鑰匙）＝一律不收，就算帶著佔位字本身。
  const unkeyed = makePage({ script: podScriptRaw, build: (body) => (page = newPluginsPage(body)) });
  await unkeyed.signIn();
  assert.ok(await unkeyed.silent({ cmd: 'pluginNewMenu', item: 'mcp', op: 'op-unkeyed-0001', key: '__TATWO_POD_KEY__' }));
  assert.equal(page.menus, 0);
  // App 這一端：每次建立 Pod 換一把、換不掉佔位字＝不開；每個指令都走 keyedCommandScript。
  assert.match(tap, /let key = Self\.makePodKey\(\)\s*podKey = key\s*try pod\.start\(script: Self\.keyedPodScript\(key\)\)/);
  assert.match(tap, /guard parts\.count == 2 else \{ throw TapPodError\.scriptRejected \}/);
  assert.match(tap, /var generator = SystemRandomNumberGenerator\(\)/);
  const swiftPart = tap.slice(0, tap.indexOf('static let podScript'));
  assert.equal((swiftPart.match(/Self\.commandScript\(/g) || []).length, 1, 'only keyedCommandScript builds a command');
  assert.match(swiftPart, /private func keyedCommandScript\(_ payload: \[String: Any\]\) throws -> String \{\s*var keyed = payload\s*keyed\["key"\] = podKey\s*return try Self\.commandScript\(keyed\)/);
  assert.match(podScript, /if \(!\(POD_KEY\.length === 64 && typeof command\.key === 'string' && command\.key === POD_KEY\)\) return;/);
  assert.match(webPod, /func start\(script: String\) throws \{\s*guard browser == nil else \{ return \}\s*self\.script = script/);
  assert.doesNotMatch(code(swiftPart), /print\(.*podKey|NSLog|podKey.*write/);
});

test('W183 R9 App side: step codes become sentences (no more 「（plus）」), risk_ack / untrusted card text, refusals, manual steps for the new UI in both languages', () => {
  // 找不到＝一句話；不再把代號放進括號。
  assert.doesNotMatch(connect, /跟預期的不一樣（\\\(step\)）/);
  assert.match(connect, /case \.notFound, \.ambiguous:\s*return needsManual\(Self\.pageMismatchText\(action\), my: my\)/);
  assert.match(connect, /static let newMenuMissingText = "ChatGPT 外掛頁的新增選單裡找不到加 MCP 伺服器的那一項（ChatGPT 改版，或這個帳號沒開開發者模式）；可以再連一次，或改用手動"/);
  assert.match(connect, /if entry\.contains\(step\) \{ return newMenuMissingText \}/);
  assert.match(connect, /if step == "form_open" \{ return formOpenText \+ tail \}/);
  // 「I understand and want to continue」：W183 R10 起 TATWO 代勾（App 的原生點擊）；交給使用者勾的卡只剩退路，卡片講清楚是 TATWO 這次沒勾成。
  // 勾著卻不是使用者（或 TATWO 的原生點擊）按的＝講清楚要取消再自己勾。
  assert.match(connect, /static let riskAckCardText = "TATWO 這次沒辦法替你勾（那一格不在畫面上）：在 Browser 分頁讀完風險說明、自己勾「I understand and want to continue」/);
  assert.match(connect, /reason == Self\.riskAckReason \? Self\.riskAckCardText\s*: reason == Self\.untrustedTickReason \? Self\.untrustedTickCardText/);
  assert.match(podDriver, /case "risk_ack": HandsConnectFlow\.riskAckReason/);
  assert.match(podDriver, /case "untrusted_tick": HandsConnectFlow\.untrustedTickReason/);
  // W183 R9 審查（GPT-6 N9）：警語太長或看不出範圍＝不自動按，改手動（不是「繼續」再試）。
  assert.match(podDriver, /case "warning_unbounded": HandsConnectFlow\.warningUnboundedReason/);
  assert.match(connect, /case \.needsUser\(let reason, _\) where reason == Self\.warningUnboundedReason:\s*\/\/[^\n]*\n\s*return needsManual\(Self\.warningUnboundedText, my: my\)/);
  assert.match(connect, /: Self\.warningCardText\(reason\),/);
  assert.match(connect, /case "connection_not_server_url": "ChatGPT 表單的 Connection 不是「Server URL」/);
  for (const reason of ['form_replaced', 'name_mismatch', 'ack_replayed']) assert.match(connect, new RegExp(`case "${reason}": "`), reason);
  // W321：手動步驟採用十月介面的實際按鈕名稱。
  const manual = between(connect, 'static func manualSteps(', 'static let riskAckCardText');
  for (const words of ['Plugins', 'Installed', 'Manage', 'Plugin settings', 'Reconnect', 'Add custom MCP server',
    'Name（名稱）填 \\(name)', 'Server URL（伺服器 URL）', 'Authentication（驗證）選 OAuth',
    '勾 I understand and want to continue', '按 Create as a plugin', '打 8 碼']) assert.ok(manual.includes(words), words);
  assert.doesNotMatch(manual, /新增 ▾|Create MCP app|設定 › Apps › 自己建立的/);
  assert.doesNotMatch(manual, /按「＋」/);
  // W183 R12（.036 實機；主導裁決：撞名就自動換名字重建）：名字改用 connectorNameInUse（沒改過＝「TATWO（<設備名稱>）」；撞名改過＝後面加 2…9，重連沿用本機記下的）。
  assert.match(connect, /steps: Self\.manualSteps\(intent\.mcpURL, name: connectorNameInUse\(offer\), existing:/);
  // 網頁腳本：舊的「＋」先、改版的「新增 ▾」後；腳本自己從不勾（W183 R10 的代勾是 App 的原生點擊，腳本只量位置）；Connection 讀回。
  assert.match(podScript, /const plus = plusButtons\(\);\s*const menu = plus\.length \? \[\] : newButtons\(\);/);
  assert.match(podScript, /await pickNewItem\(pick, menu\[0\], 'mcp', 'mcp_item', live\);/);
  assert.match(podScript, /if \(unchecked\.length\) return \{ reason: aEvery\(unchecked, \(b\) => reTest\(RISK_ACK, boxText\(b\)\)\) \? 'risk_ack' : 'checkbox', digest \};/);
  assert.doesNotMatch(podScript, /\.checked = true|setAttribute\('aria-checked', 'true'\)/, 'the Pod script never ticks a box');
  assert.doesNotMatch(podScript, /TUNNEL_SEG\.test\([^)]*\)\)\s*press|press\(segments\(root\)\.tunnel/, 'the Pod script never picks Tunnel');
  // 使用者真的按過的紀錄：只在 window 的捕獲階段收點擊與空白鍵（Enter 不算），isTrusted 才算；網頁的程式送的點擊派送中＝一律不算。
  assert.match(podScript, /if \(e\.isTrusted !== true\) \{\s*if \(type === 'click'\) \{ taint \+= 1; micro\(\(\) => \{ taint -= 1; \}\); \}\s*return;\s*\}\s*if \(taint > 0\) return;/);
  assert.match(podScript, /const space = \(type === 'keydown' \|\| type === 'keyup'\) && spaceKey\(e\);\s*if \(!click && !space\) return;/);
  assert.match(podScript, /R_apply\(M_addEvt, window, \['click', noteTrusted, true\]\);\s*R_apply\(M_addEvt, window, \['keydown', noteTrusted, true\]\);\s*R_apply\(M_addEvt, window, \['keyup', noteTrusted, true\]\);/);
});

test('W183 R9 native 外掛頁「新增 ▾」: glass chip top-right, a popover list with three items + MCP hint (accessibility ids), a Pod operation lease; self-tests registered', () => {
  const pages = swift('TAP/ChatGPTPages.swift');
  const view = swift('New/ChatGPTPluginNewMenuView.swift');
  const menu = swift('Facade/ChatGPTPluginNewMenu.swift');
  assert.match(pages, /ChatGPTPageScaffold\(model: model, title: Self\.title, subtitle: Self\.subtitle, trailing: Self\.newMenuTrailing\(\.shared\)\)/);
  assert.match(pages, /static let title = "外掛"\s*static let subtitle = "在你常用的工具裡使用 ChatGPT"/);
  assert.match(pages, /ChatGPTPageHeader\(title: title, subtitle: subtitle, trailing: trailing\)/);
  assert.match(pages, /ChatGPTPluginNewMenuMessage\(menu: \.shared\)/);
  assert.match(view, /Text\("新增"\)[\s\S]{0,120}Image\(systemName: "chevron\.down"\)[\s\S]{0,260}\.chatGlassChip\(\)/);
  assert.match(view, /\.popover\(isPresented: \$open, arrowEdge: \.bottom\) \{\s*ChatGPTPluginNewMenuList\(menu: menu\)/);
  assert.match(view, /ForEach\(ChatGPTPluginNewItem\.allCases\)/);
  assert.match(view, /\.accessibilityIdentifier\("chatgpt\.plugins\.new\.\\\(item\.rawValue\)"\)/);
  assert.match(view, /if item == \.mcp \{[\s\S]{0,160}Text\(ChatGPTPluginNewItem\.mcpHint\)[\s\S]{0,420}\.accessibilityIdentifier\("chatgpt\.plugins\.new\.hint"\)/);
  assert.doesNotMatch(view, /borderedProminent|\.bordered\b|\.tint\(\.blue\)|Color\.blue|\.alert\(/);
  for (const words of ['case .plugin: "建立外掛程式"', 'case .archive: "上傳外掛程式封存檔"', 'case .mcp: "建立 MCP 應用程式"', 'ChatGPT build 的［連線］（會自動填好）'])
    assert.ok(menu.includes(words), words);
  assert.match(menu, /return browser\.openPod\(purpose: \.chatgptDeveloper, currentURL: ChatGPTConnectorPod\.shared\.mainURL, onCancel: onCancel\)/);
  assert.match(menu, /send: \{ item, op, hold in try await ChatGPTTap\.shared\.pluginNewMenu\(item, op: op, hold: hold\) \}/);
  assert.doesNotMatch(code(menu), /connectorCreate|setValue|"url"|"name"|ack:/, 'the native menu never fills, ticks or creates');
  // 撤銷先送、再放掉租約；逾時 10 分鐘。
  assert.match(menu, /if abort \{ dependencies\.abort\(op\) \}\s*dependencies\.endHold\(current\.hold\)/);
  assert.match(menu, /var holdLimit: TimeInterval = 600/);
  // Tap：只收三個字；要帶操作租約與一次性序號；拿不到的原因一句話；租約期間排隊、別人的會換頁指令一律不做。
  assert.match(tap, /static let pluginNewMenuItems: Set<String> = \["plugin", "archive", "mcp"\]/);
  assert.match(tap, /func pluginNewMenu\(_ item: String, op: String, hold: UUID\) async throws -> \[String: Any\] \{/);
  assert.match(tap, /guard menuHold == hold else \{ throw TapError\.remote\(/);
  assert.match(tap, /if connectorHold != nil \{ return "ChatGPT 正在連接 TATWO（私訊框）；等它完成再按" \}/);
  // W184 G3：即時語音拿著 Pod（voiceClaim）時「新增」也不開；原本擋的（回答中、停止中、語音開著、換頁中）都還在。
  assert.match(tap, /if activeRequestID != nil \|\| stoppingRequestID != nil \|\| voiceOpen \|\| voiceClaim != nil \|\| pageRequests > 0 \{\s*return "ChatGPT 正在回答（或在語音模式）；等它結束再按"\s*\}/);
  assert.match(tap, /if paging, let menuHold, owner != menuHold \{/);
  // Pod 的檔案選擇器：只給人用。W183 R9 審查（GPT-6 N8）：CEF 的 onWebFeaturesInvalidated 接到選擇器（取消 sheet、結清回覆、通知「新增」）；stop 拆掉。
  assert.match(webPod, /Self\.wireWebFeatures\(view, picker: filePicker\)/);
  assert.match(webPod, /Self\.unwireWebFeatures\(browser, picker: filePicker\)/);
  assert.match(webPod, /host\.onFileDialog = \{ \[weak picker\] mode, title, defaultPath, filters, multiple, completion in/);
  assert.match(webPod, /host\.onWebFeaturesInvalidated = \{ \[weak picker\] in picker\?\.browserInvalidated\(\) \}/);
  assert.match(webPod, /extension TatwoCEFBrowserView: TapPodWebFeatureHost \{\}/);
  assert.match(swift('TAP/TapPodFilePicker.swift'), /func browserInvalidated\(\) \{\s*invalidate\(\)\s*onBrowserInvalidated\?\(\)\s*\}/);
  // W183 R9 審查（GPT-6 N7）：從拿到租約起就看（送出之前就開始）；網頁世代在「選檔中」之前看。
  assert.ok(menu.indexOf('watch(op)\n        let data: [String: Any]') > 0, 'the watch starts before the reply');
  assert.match(menu, /if self\.dependencies\.pageGeneration\(\) != now\.generation \{ return self\.finish\(op, abort: true, note: Self\.pageChangedText\) \}\s*guard now\.handedAt != nil else \{ continue \}[^\n]*\n\s*if self\.dependencies\.pickerOpen\(\) \{ continue \}/);
  assert.match(menu, /armPicker: \{ hook in ChatGPTTap\.shared\.pod\.filePicker\.onBrowserInvalidated = hook \}/);
  // W183 R9c（GPT-6 C7）：私訊框、Browser 一變就用 boxClosed 判斷（事件訂閱；boxClosed 的內容不動，留給房 D）。
  assert.match(menu, /return browser\.store\.objectWillChange\.merge\(with: browser\.objectWillChange\)\s*\.receive\(on: DispatchQueue\.main\)/);
  assert.match(menu, /visibilityWatch = dependencies\.visibilityChanges \{ \[weak self\] in self\?\.visibilityChanged\(op\) \}/);
  assert.match(menu, /private func visibilityChanged\(_ op: String\) \{\s*guard let current = operation, current\.op == op else \{ return \}\s*if dependencies\.boxClosed\(\) \{ finish\(op, abort: true, note: Self\.boxClosedText\) \}/);
  // W183 R9c（GPT-6 C3）：原生看到的導頁（連接器拿著 Pod、沒有指令在跑）送 connectorNavigated。
  const connectorPod = swift('TAP/ChatGPTConnectorPod.swift');
  assert.match(connectorPod, /guard let hold, commandsInFlight == 0, tap\.connection == \.ready else \{ return \}/);
  assert.match(connectorPod, /tap\.connectorRequest\("connectorNavigated", \["path": path\], hold: hold, timeout: \.seconds\(3\)\)/);
  // W183 R12（主導 2）：清單後面多一個 connectorGesture（只標、不按）；connectorNavigated 照舊在清單裡。
  assert.match(tap, /"connectorAccount", "connectorNavigated",\s*"connectorGesture",[^\n]*\n\s*"connectorOutline",[^\n]*\n\s*"connectorTick",[^\n]*\n\s*"connectorInspect", "connectorDelete", "connectorProbe"\]/);
  const picker = swift('TAP/TapPodFilePicker.swift');
  assert.match(picker, /\(mode == 0 \|\| mode == 1\) && context\.guarded && context\.visible && context\.human && context\.window != nil/);
  assert.doesNotMatch(picker, /\.urls = |directoryURL = URL\(fileURLWithPath: defaultPath\)\n|selectFile|panel\.url = /);
  // 自測：w183connect（卡片的字、手動步驟、專案一致）、w183browser（原生選單三項各自送對的指令、租約、撤銷、互斥、鑰匙、選檔、畫面）。
  assert.match(acceptance, /try await r9Checks\(check, base\)/);
  assert.match(swift('DM/DMBrowserAcceptance.swift'), /await pluginNewMenuChecks\(check\)/);
  const r9 = swift('Facade/HandsConnectR9Acceptance.swift');
  const r9browser = swift('DM/DMBrowserR9Acceptance.swift');
  for (const source of [r9, r9browser]) {
    assert.match(source, /^#if DEBUG/);
    assert.doesNotMatch(source, /ChatGPTTap\.shared|ChatGPTConnectorPod\.shared|DMBrowser\.shared|HandsConnectFlow\.shared|URLSession|check\(true,/);
  }
  for (const name of ['keyChecks', 'itemChecks', 'textChecks', 'busyChecks', 'exclusiveChecks', 'menuCancelChecks', 'lateReplyChecks', 'sendPhaseChecks', 'visibilityChecks',
    'filePickerChecks', 'webFeatureChecks', 'pluginNewMenuRenderChecks'])
    assert.match(r9browser, new RegExp(`await ${name}\\(check\\)|${name}\\(check\\)`), name);
  assert.match(r9browser, /ImageRenderer\(content: view\)/);
  assert.match(r9browser, /TATWO2_SELFTEST_ARTIFACTS/);
  assert.match(r9browser, /axPress\(element\)/);
});

test('W183 R10 projects: every host project stays visible to MCP; W214 removes the Dev panel list', () => {
  // 守（取代 R9 的「卡片只列勾了的、沒勾就指回面板」）：兩邊都是這台全部能當專案的（新專案自動加入）；面板只顯示、不能勾。
  assert.match(swift('Facade/HandsService.swift'), /func grantScope\(_ current: HandsSettings\) -> HandsGrantScope \{\s*let records = current\.allProjects \? buildProjectRecords\(\) : projectRecords\(Set\(current\.allowedProjectIDs\)\)/);
  assert.match(scope, /func buildProjectChoices\(\) -> \[HandsProjectChoice\] \{\s*buildProjectRecords\(\)\.compactMap/);
  const build = swift('New/ChatGPTBuildSection.swift');
  const model = swift('Facade/HandsBuildModel.swift');
  const controller = swift('Facade/HandsBuildController.swift');
  assert.doesNotMatch(build + model, /projectsNoneLines|projectsNoneHint|projectsNoneFor|notActive|未生效/);
  assert.doesNotMatch(model, /static let (?:projectsAll|readOnly) =/);
  assert.match(build, /Text\(HandsBuildCopy\.capabilities\)/);
  assert.match(dmView, /let count = offer\.scope\.readOnlyProjectIDs\.count[\s\S]{0,150}個交易類專案只能看/);
  assert.match(model, /case \.setProject:\s*\/\/[^\n]*\n\s*return \[\]/);
  assert.match(controller, /HandsBuildProject\(id: entry\.deviceID \+ "\/" \+ choice\.id, name: choice\.name, selected: true,[\s\S]{0,200}readOnly: choice\.readOnlyFloor\)/);
  assert.match(nativeW214(4), /W214 PASS N4.title-capability-and-connect.true/);
  assert.match(nativeW214(4), /W214 PASS N4.no-project-chips-or-detail-rows.true/);
  // 守：卡片與面板的「只能看」用同一個判斷（HandsTradingFloor；擋在主機）。
  assert.match(swift('Facade/HandsFloors.swift'), /var readOnlyFloor: Bool \{ HandsTradingFloor\.isTrading\(name: name, folder: folder\) \}/);
  // W183 R10 第二輪（GPT-6 6）：卡片的「只能看」清單含別名（同一個資料夾的任一個名字命中；讀清單時更新過的分類）。
  assert.match(swift('Facade/HandsService.swift'), /let readOnly = records\.filter \{ isTradingCached\(\$0\.0\) \}\.map \{ \$0\.0\.uuidString \}\.sorted\(\)/);
});

// ---------- W183 R10：代勾「I understand and want to continue」 ----------
// 使用者 09-29：「這邊要勾選也太怪 就要給他用了還要多一個勾選」；裁決：按［連線］＝同意，「I understand」由 TATWO 代勾，只限 TATWO 自己開的那一頁。
// 取代 R9 的「TATWO 不代勾」：腳本只**量**那一格的位置（needs_user＋tick），App 用 CEF 的節點驗證點擊點下去（網頁看到 isTrusted）；
// 那一下算不算照舊由 R9 的證據鏈判（這一輪交回的那一格、從沒勾變成勾、一次性記號、表單換了就重來）。
// W183 R10 第二輪（GPT-6 2、3；主導裁決）：只量那一格本身（不再改點 label）；同意內容＝版本化的完整文字白名單（整張表單看得到的字照順序、
// 連結的字與網域照順序；英文照 09-29 截圖，中文沒有核實過＝一律交給使用者），不再用關鍵字或詞集合相似度。
const PHONE = { width: 466, height: 678 };
const ACK_AT = [20, 400, 18, 18];
const TICK_AT = { x: 20, y: 400, w: 18, h: 18, vw: 466, vh: 678 };

test('W183 R10 pod tick: only the one known box on the verified 09-29 English form → needs_user + tick; the script itself never ticks; the App\'s native click on it → armed → Create once', async () => {
  let page;
  const pod = makePage({ viewport: PHONE, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT })) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(first.status, 'needs_user');
  assert.equal(first.reason, 'risk_ack');
  assert.equal(first.consent, undefined, 'the whole form matches the verified en-2026-09-29 version');
  // 守：交給 App 的是那一格在畫面上的位置（CSS px）＋當時的畫面大小（App 核對畫面大小一樣、再用快照找到同一個節點才點）。
  assert.deepEqual(first.tick, TICK_AT);
  // 守：腳本自己從不勾——那一格沒被點、還沒勾、Create 還是灰的；只把它立刻捲到畫面中間（不照網頁的 scroll-behavior 慢慢捲）。
  assert.equal(page.fields.box.clicks, 0);
  assert.equal(page.fields.box.getAttribute('aria-checked'), 'false');
  assert.equal(page.fields.create.disabled, true);
  assert.deepEqual(page.fields.box._scrolls.map((o) => ({ ...o })), [{ block: 'center', inline: 'nearest', behavior: 'instant' }]);
  // 守：App 的原生點擊（isTrusted）打在那一格上 → 同一張表單的記號＋警語指紋再送一次 → armed（不按）→ connectorPress → 按 Create 一次。
  pod.userClick(page.fields.box);
  const armed = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } }, 12000, { press: false })).data;
  assert.equal(armed.status, 'armed');
  assert.equal(page.created + page.fields.create.clicks, 0, 'armed never presses');
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: armed.form })).data, { status: 'pressed' });
  assert.equal(page.created, 1);
  // 守：記號用過就沒了（按第二次＝拒絕）。
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: armed.form })).data, { status: 'refused', reason: 'ack_replayed' });
  assert.equal(page.created, 1);
  // 守：給了位置不代表網頁自己的程式勾也算——網頁的 click()（不是 isTrusted）照舊 untrusted_tick，不按 Create。
  let other;
  const byPage = makePage({ viewport: PHONE, build: (body) => (other = newPluginsPage(body, { boxRect: ACK_AT })) });
  await byPage.signIn();
  const seen = (await byPage.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.deepEqual(seen.tick, TICK_AT);
  other.pageTicks();
  const refused = (await byPage.command({ cmd: 'connectorCreate', url: MCP, ack: { form: seen.form, warning: seen.warning } })).data;
  assert.equal(refused.reason, 'untrusted_tick');
  assert.equal(other.created + other.fields.create.clicks, 0);
});

test('W183 R10 第二輪 pod consent whitelist: anything but the verified full text is "unknown" (reason stays risk_ack, no tick): Chinese UI, a keyword-free new clause, a reworded or reordered form, a link to another site', async () => {
  const run = async (opts) => {
    let page;
    const pod = makePage({ viewport: PHONE, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT, ...opts })) });
    await pod.signIn();
    return { page, r: (await pod.command({ cmd: 'connectorCreate', url: MCP })).data };
  };
  const cases = [
    // 中文介面：沒有核實過的中文版本＝不代勾（寧可交給使用者勾）。
    ['zh (never verified)', { lang: 'zh' }],
    // GPT-6 3 的例子：沒有任何風險字的新條款（以前的關鍵字比對會漏）。
    ['keyword-free new clause', { extraText: 'By continuing, you agree that orders may be placed automatically and all funds moved out.' }],
    ['new clause in the warning box', { riskClause: 'Apps you connect can read your files.' }],
    ['neutral extra sentence', { riskClause: 'See the documentation for details.' }],
    ['reordered (checkbox row first)', { ackFirst: true }],
    ['Learn more points elsewhere', { learnHref: 'https://evil.example.net/learn' }],
    ['Read the guide points elsewhere', { guideHref: 'http://help.openai.com/guide' }],
    ['a sentence reworded', { advText: 'OAuth settings' }],
  ];
  for (const [label, opts] of cases) {
    const { page, r } = await run(opts);
    // 守：那一格還是那一格（risk_ack），但同意內容不認得＝consent unknown、不給位置、表單沒被碰；App 的卡片說明原因、交給使用者勾。
    assert.equal(r.status, 'needs_user', label);
    assert.equal(r.reason, 'risk_ack', label);
    assert.equal(r.consent, 'unknown', label);
    assert.equal(r.tick, undefined, label);
    assert.ok(untouched(page), label);
  }
  // 對照組：認得的那一句拆成好幾段（每一段都在、順序一樣）照樣認得——比的是整段字，不是節點怎麼切。
  const { r: split } = await run({ splitRisk: true });
  assert.equal(split.consent, undefined);
  assert.deepEqual(split.tick, TICK_AT);
});

// ---------- W183 R12（主導 3：ChatGPT 改了說明文字——卡片顯示全文＋［同意並繼續］，同意過的那一份才代勾） ----------
test('W183 R12 pod consent: an unknown text comes back as plain text + links (text, domain) + one print; only that exact print brought back by the App makes it known (tick → Create once); a link to another site or a different print stays unknown; abort forgets it', async () => {
  const clause = 'Apps you connect can read your files.';
  let page;
  const pod = makePage({ viewport: PHONE, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT, riskClause: clause })) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  // 守：不認得＝照舊不給位置、不碰表單；另外帶回那一份（純文字：只有文字節點，沒有 HTML；連結只有字與網域）。
  assert.equal(first.status, 'needs_user');
  assert.equal(first.reason, 'risk_ack');
  assert.equal(first.consent, 'unknown');
  assert.equal(first.tick, undefined);
  assert.ok(untouched(page));
  assert.ok(first.offer && first.offer.text.includes(clause), 'the new clause is in the text shown on the card');
  assert.doesNotMatch(first.offer.text, /[<>]/, 'plain text only');
  assert.ok(first.offer.print.startsWith('user\n') && first.offer.print.includes(first.offer.text));
  assert.ok(first.offer.links.length >= 1 && first.offer.links.every((l) => /^https:\/\/[a-z.]*openai\.com$/.test(l.origin) && typeof l.text === 'string'));
  // 守：App 帶回別的一份（被改過一個字）＝還是不認得。
  const wrong = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning },
    approved: first.offer.print.replace('files', 'fi1es') })).data;
  assert.equal(wrong.consent, 'unknown');
  assert.equal(wrong.tick, undefined);
  // 守：帶回一字不差的那一份（使用者在 TATWO 卡片上按了同意並繼續）＝認得：量出那一格的位置（App 代勾）；腳本自己照舊不勾。
  const known = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: wrong.form, warning: wrong.warning },
    approved: first.offer.print })).data;
  assert.equal(known.reason, 'risk_ack');
  assert.equal(known.consent, undefined);
  assert.deepEqual(known.tick, TICK_AT);
  assert.equal(page.fields.box.clicks, 0);
  // App 的原生點擊（isTrusted）→ 同一張表單再送一次 → armed → connectorPress → Create 一次。
  pod.userClick(page.fields.box);
  const armed = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: known.form, warning: known.warning },
    approved: first.offer.print }, 12000, { press: false })).data;
  assert.equal(armed.status, 'armed');
  assert.deepEqual((await pod.send({ cmd: 'connectorPress', form: armed.form })).data, { status: 'pressed' });
  assert.equal(page.created, 1);
  // 守：取消（connectorAbort）之後同意過的那一份不留：新的表單照舊不認得。
  await pod.send({ cmd: 'connectorAbort' });
  let other;
  const again = makePage({ viewport: PHONE, build: (body) => (other = newPluginsPage(body, { boxRect: ACK_AT, riskClause: clause })) });
  await again.signIn();
  const fresh = (await again.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(fresh.consent, 'unknown');
  assert.ok(untouched(other));
  // 守：連結指到別的網站＝不給一鍵同意（沒有 offer：照舊請使用者自己勾）。
  let third;
  const elsewhere = makePage({ viewport: PHONE, build: (body) => (third = newPluginsPage(body, { boxRect: ACK_AT, learnHref: 'https://evil.example.net/learn' })) });
  await elsewhere.signIn();
  const foreign = (await elsewhere.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.equal(foreign.consent, 'unknown');
  assert.equal(foreign.offer, undefined);
  assert.ok(untouched(third));
});

test('W183 R10 pod tick: an unknown checkbox (ticked or not) → "checkbox"; no tick unless it is exactly that one box', async () => {
  const run = async (opts) => {
    let page;
    const pod = makePage({ viewport: PHONE, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT, ...opts })) });
    await pod.signIn();
    return { page, r: (await pod.command({ cmd: 'connectorCreate', url: MCP })).data };
  };
  // 守：表單上多一格沒見過的勾選框（沒勾）＝R9 照舊交給使用者（checkbox），不給位置、兩格都沒碰。
  let { page, r } = await run({ extraBox: true });
  assert.equal(r.reason, 'checkbox');
  assert.equal(r.tick, undefined);
  assert.ok(untouched(page));
  // 守：多的那一格一開始就勾著（沒勾的只剩風險那一格）＝表單上不只一格：一樣交給使用者（checkbox），不代勾。
  ({ page, r } = await run({ extraBox: true, extraChecked: true }));
  assert.equal(r.status, 'needs_user');
  assert.equal(r.reason, 'checkbox', 'another checkbox on the form → the user ticks, not TATWO');
  assert.equal(r.tick, undefined);
  assert.ok(untouched(page));
});

test('W183 R10 pod tick: no reliable place → no tick (hand to the user): pinch-zoomed or shifted visual viewport, box off-screen or too small, something on top of it, no viewport getters, a styled tiny box behind its label', async () => {
  const run = async (opts, viewport = PHONE) => {
    let page;
    const pod = makePage({ viewport, build: (body) => (page = newPluginsPage(body, opts)) });
    await pod.signIn();
    return { page, pod, r: (await pod.command({ cmd: 'connectorCreate', url: MCP })).data };
  };
  const cases = [
    ['pinch zoom', { boxRect: ACK_AT }, { ...PHONE, visual: true, scale: 1.25 }],
    ['visual viewport shifted', { boxRect: ACK_AT }, { ...PHONE, visual: true, offsetTop: 40 }],
    ['below the viewport', { boxRect: [20, 700, 18, 18] }, PHONE],
    ['partly off the right edge', { boxRect: [460, 400, 18, 18] }, PHONE],
    ['too small', { boxRect: [20, 400, 6, 6] }, PHONE],
    ['covered by an overlay', { boxRect: ACK_AT, cover: [0, 390, 466, 40] }, PHONE],
    ['not laid out (nothing at that point)', {}, PHONE],
    ['no innerWidth / innerHeight', { boxRect: ACK_AT }, null],
  ];
  for (const [label, opts, viewport] of cases) {
    const { page, r } = await run(opts, viewport);
    // 守：照舊交給使用者（risk_ack，卡片說 TATWO 這次沒辦法替你勾），不給位置、表單沒被碰。
    assert.equal(r.status, 'needs_user', label);
    assert.equal(r.reason, 'risk_ack', label);
    assert.equal(r.tick, undefined, label);
    assert.ok(untouched(page), label);
  }
  // W183 R10 第二輪（GPT-6 2）：自訂樣式的原生勾選框（本身很小、字在 <label for> 裡）＝不再改點 label（CEF 的節點驗證點擊要的是那一個節點）：
  // 不給位置、交給使用者；使用者自己點那個 label 照 R9 的證據鏈照樣算。
  const { page, pod, r } = await run({ nativeBox: true, boxRect: [20, 400, 1, 1], labelRect: [44, 396, 300, 40] });
  assert.equal(r.reason, 'risk_ack');
  assert.equal(r.tick, undefined, 'no label fallback any more');
  pod.userClick(page.fields.ackLabel);
  assert.equal(page.fields.box.checked, true);
  assert.deepEqual((await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: r.form, warning: r.warning } })).data, { status: 'pressed' });
  assert.equal(page.created, 1);
  // 對照組：沒縮放、沒位移的 visualViewport ＝照樣代勾。
  const { r: plain } = await run({ boxRect: ACK_AT }, { ...PHONE, visual: true });
  assert.deepEqual(plain.tick, TICK_AT);
});

test('W183 R10 第二輪 two-step press (GPT-6 1): Create / reconnect only after the App set its anchor — armed never presses; the press re-checks everything and is one-time; anything that changed in between → press_stale, nothing pressed', async () => {
  // 1. 沒有勾選框的舊表單（legacy）：核對完＝armed、不按；用 armed 的記號按＝按一次。
  let created;
  const legacy = makePage({ build: (body) => (created = pluginsPage(body)) });
  await legacy.signIn();
  const armed = (await legacy.command({ cmd: 'connectorCreate', url: MCP }, 12000, { press: false })).data;
  assert.equal(armed.status, 'armed');
  assert.match(armed.form, /^f\d+x\d{8}$/);
  assert.equal(created.clicks, 0, 'armed never presses');
  // 守：隨便一個記號、上一步交回的舊確認都按不了。
  assert.deepEqual((await legacy.send({ cmd: 'connectorPress', form: 'f99x12345678' })).data, { status: 'refused', reason: 'press_stale' });
  assert.equal(created.clicks, 0);
  assert.deepEqual((await legacy.send({ cmd: 'connectorPress', form: armed.form })).data, { status: 'pressed' });
  assert.equal(created.clicks, 1);
  assert.deepEqual((await legacy.send({ cmd: 'connectorPress', form: armed.form })).data, { status: 'refused', reason: 'ack_replayed' });
  assert.equal(created.clicks, 1);
  // 2. armed 之後、按之前網址欄被改了＝press_stale（不按，記號作廢）。
  let page;
  const changed = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await changed.signIn();
  const asked = (await changed.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const ready = (await changed.command({ cmd: 'connectorCreate', url: MCP, ack: { form: asked.form, warning: asked.warning } }, 12000, { press: false })).data;
  assert.equal(ready.status, 'armed');
  page.fields.url.value = 'https://evil.example.net/mcp';
  assert.deepEqual((await changed.send({ cmd: 'connectorPress', form: ready.form })).data, { status: 'refused', reason: 'press_stale' });
  assert.equal(page.created + page.fields.create.clicks, 0);
  assert.deepEqual((await changed.send({ cmd: 'connectorPress', form: ready.form })).data, { status: 'refused', reason: 'press_stale' });
  // 3. armed 之後使用者（或網頁）把勾取消＝按之前再核，不按。
  const unticked = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await unticked.signIn();
  const q = (await unticked.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const r2 = (await unticked.command({ cmd: 'connectorCreate', url: MCP, ack: { form: q.form, warning: q.warning } }, 12000, { press: false })).data;
  page.userTicks();   // 取消
  assert.deepEqual((await unticked.send({ cmd: 'connectorPress', form: r2.form })).data, { status: 'refused', reason: 'press_stale' });
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 4. armed 之後真的取消（App 放掉獨占前送 connectorAbort）或換頁＝不按。
  const aborted = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await aborted.signIn();
  const q3 = (await aborted.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const r3 = (await aborted.command({ cmd: 'connectorCreate', url: MCP, ack: { form: q3.form, warning: q3.warning } }, 12000, { press: false })).data;
  await aborted.send({ cmd: 'connectorAbort' });
  assert.equal((await aborted.send({ cmd: 'connectorPress', form: r3.form })).data.status, 'refused');
  assert.equal(page.created + page.fields.create.clicks, 0);
  const moved = makePage({ build: (body) => (page = newPluginsPage(body)) });
  await moved.signIn();
  const q4 = (await moved.command({ cmd: 'connectorCreate', url: MCP })).data;
  page.userTicks();
  const r4 = (await moved.command({ cmd: 'connectorCreate', url: MCP, ack: { form: q4.form, warning: q4.warning } }, 12000, { press: false })).data;
  moved.navigateNatively('/c/some-chat');
  assert.equal((await moved.send({ cmd: 'connectorPress', form: r4.form })).data.status, 'refused');
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 5. armed 的確認同時用掉：再拿同一個確認去 connectorCreate＝ack_replayed。
  assert.deepEqual((await moved.send({ cmd: 'connectorCreate', url: MCP, ack: { form: q4.form, warning: q4.warning } })).data,
    { status: 'refused', reason: 'ack_replayed' });
});

test('W183 R10 第三輪 consent binding (GPT-6 3): what the auto-tick agreed to (version, ordered text, link texts and resolved sites) is re-checked right before the click (connectorConsent) and before Create is pressed; a link that now points elsewhere → hand back to the user, nothing pressed', async () => {
  // 1. 量完之後、派送之前：什麼都沒變＝ok；「Learn more」改指別的網站（字、節點都沒變；MutationObserver 不看 href）＝changed。
  let page;
  const pod = makePage({ viewport: PHONE, build: (body) => (page = newPluginsPage(body, { boxRect: ACK_AT })) });
  await pod.signIn();
  const first = (await pod.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.deepEqual(first.tick, TICK_AT);
  assert.deepEqual((await pod.send({ cmd: 'connectorConsent', form: first.form })).data, { status: 'ok' });
  const learn = page.fields.riskSpan.children.find((c) => c.tagName === 'A');
  assert.ok(learn, 'fixture: the Learn more link');
  learn.setAttribute('href', 'https://evil.example.net/learn');
  assert.deepEqual((await pod.send({ cmd: 'connectorConsent', form: first.form })).data, { status: 'changed' });
  // 2. 就算那一下點了（例如舊版 App），帶回確認的時候再核：交回使用者（consent unknown、新的一輪），不 armed、不按。
  pod.userClick(page.fields.box);
  const back = (await pod.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first.form, warning: first.warning } }, 12000, { press: false })).data;
  assert.equal(back.status, 'needs_user');
  assert.equal(back.reason, 'risk_ack');
  assert.equal(back.consent, 'unknown');
  assert.equal(page.created + page.fields.create.clicks, 0);
  // 舊的記號、隨便的記號：changed（不是 ok）。
  assert.deepEqual((await pod.send({ cmd: 'connectorConsent', form: first.form })).data, { status: 'changed' });
  assert.deepEqual((await pod.send({ cmd: 'connectorConsent', form: 'fnope1234567' })).data, { status: 'changed' });

  // 3. armed 之後、按之前換了連結的網址：connectorPress 交回使用者（consent unknown），不按；那個 armed 記號用掉了。
  let page2;
  const pod2 = makePage({ viewport: PHONE, build: (body) => (page2 = newPluginsPage(body, { boxRect: ACK_AT })) });
  await pod2.signIn();
  const first2 = (await pod2.command({ cmd: 'connectorCreate', url: MCP })).data;
  pod2.userClick(page2.fields.box);
  const armed = (await pod2.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first2.form, warning: first2.warning } }, 12000, { press: false })).data;
  assert.equal(armed.status, 'armed');
  page2.fields.riskSpan.children.find((c) => c.tagName === 'A').setAttribute('href', 'https://platform.openai.com/elsewhere');
  const pressed = (await pod2.send({ cmd: 'connectorPress', form: armed.form })).data;
  assert.equal(pressed.status, 'needs_user');
  assert.equal(pressed.consent, 'unknown');
  assert.equal(page2.created + page2.fields.create.clicks, 0);
  assert.equal((await pod2.send({ cmd: 'connectorPress', form: armed.form })).data.status, 'refused');
  assert.equal(page2.created, 0);

  // 4. 對照組：沒有變＝照常 armed → 按一次。
  let page3;
  const pod3 = makePage({ viewport: PHONE, build: (body) => (page3 = newPluginsPage(body, { boxRect: ACK_AT })) });
  await pod3.signIn();
  const first3 = (await pod3.command({ cmd: 'connectorCreate', url: MCP })).data;
  assert.deepEqual((await pod3.send({ cmd: 'connectorConsent', form: first3.form })).data, { status: 'ok' });
  pod3.userClick(page3.fields.box);
  const armed3 = (await pod3.command({ cmd: 'connectorCreate', url: MCP, ack: { form: first3.form, warning: first3.warning } }, 12000, { press: false })).data;
  assert.equal(armed3.status, 'armed');
  assert.deepEqual((await pod3.send({ cmd: 'connectorPress', form: armed3.form })).data, { status: 'pressed' });
  assert.equal(page3.created, 1);
});

test('W183 R10 tick & press contract (static, next to the dynamic tests above): the Pod only measures and never presses on its own; the App ticks the one node it recorded (CEF backendNodeId, node-verified click, consent re-checked just before), binds every step of Create to one lease and one operation, and sets the provenance anchor before it sends the press', () => {
  const tickFor = between(podScript, 'const tickFor = (rec, root) => {', 'const createStillReady');
  const tickPoint = between(podScript, 'const tickPoint = (zone) => {', 'const tickFor = (rec, root) => {');
  // 守：量位置的兩段不改 checked、不派送事件、不叫 click（代勾只經 App 的原生點擊）；只量那一格本身（沒有 label 的退路）。
  assert.doesNotMatch(tickFor + tickPoint, /G_checked|kpress|dDispatch|M_dispatch|\.click\(|setAttr|O_define|zone\.labels/);
  // 守：只認這一格——這一輪交回的唯一那一格、它那一列是 RISK_ACK、還沒勾、同意內容對得上核實過的版本（白名單，不是相似度）。
  assert.match(tickFor, /if \(boxes\.length !== 1 \|\| rec\.zones\.length !== 1 \|\| rec\.zones\[0\]\.box !== boxes\[0\]\) \{ out\.reason = 'checkbox'; return out; \}/);
  assert.match(tickFor, /if \(isChecked\(box\) \|\| !reTest\(RISK_ACK, boxText\(box\)\)\) \{ out\.reason = 'checkbox'; return out; \}/);
  // W183 R12（主導 3）：不認得的那一份另外帶回去給 App 顯示（out.offer）；守的一樣：不認得＝不給位置、不代勾。
  assert.match(tickFor, /if \(!consentVersion\(root\)\) \{ out\.reason = 'warning_changed'; out\.offer = consentOffer\(root\); return out; \}/);
  // 守（第三輪）：代勾那一刻綁住同意內容（版本、順序文字、連結字與解析後網域）；每一輪交回都清掉（只屬於那一輪）。
  assert.match(tickFor, /rec\.consent = out\.tick \? consentPrint\(root\) : '';/);
  assert.match(between(podScript, 'const roundOpen = (rec) => {', 'const roundIntact'), /rec\.consent = '';/);
  const print = between(podScript, 'const consentPrint = (root) => {', '// 那一格在畫面上的位置');
  assert.match(print, /out \+= '\\n' \+ seen\.links\[i\]\.text \+ ' -> ' \+ origin;/);
  assert.doesNotMatch(podScript, /KNOWN_RISK|RISK_WORDS|coveredBy|riskTokens/, 'no keyword / word-set similarity any more');
  assert.match(podScript, /const CONSENT_VERSIONS = \[\s*\{ id: 'en-2026-09-29',/);
  // W183 R12（主導 3）：consent 'unknown' 的時候多帶那一份（offer）；其他照舊。
  assert.match(podScript, /if \(warning\.reason === 'risk_ack'\) \{\s*const t = tickFor\(rec, root\);\s*if \(t\.reason === 'checkbox'\) back\.reason = 'checkbox';\s*else if \(t\.reason === 'warning_changed'\) \{ back\.consent = 'unknown'; if \(t\.offer\) back\.offer = t\.offer; \}[^\n]*\n\s*else if \(t\.tick\) back\.tick = t\.tick;\s*\}/);
  // 守：兩步按——connectorCreate／connectorReconnect 核對完只回 armed（不按）；connectorPress 先核同意內容、再核一次、用掉記號才按。
  const create = between(podScript, 'connectorCreate: async (c) => {', 'connectorReconnect: async (c) => {');
  assert.doesNotMatch(create, /kpress\(submit/);
  assert.match(create, /if \(rec\.consent && consentPrint\(root\) !== rec\.consent\) \{[\s\S]{0,200}back\.consent = 'unknown';\s*return back;\s*\}/);
  assert.match(create, /return armPress\(owned, button, 'create', \(\) => createStillReady\(rec, url, button, seen\)\);/);
  const press = between(podScript, 'connectorPress: async (cmd) => {', 'connectorConsent: async (cmd) => {');
  assert.ok(press.indexOf('consentPrint(rec.root) !== rec.consent') < press.indexOf('if (!arm.check())'), 'consent first, then the rest');
  assert.match(press, /if \(!arm\.check\(\)\) \{ rec\.armed = null; voidRecord\(t, 'stale'\); return \{ status: 'refused', reason: 'press_stale' \}; \}/);
  assert.match(press, /consume\(\{ mark: t, rec \}\);\s*kpress\(arm\.button\);/);
  const consentCmd = between(podScript, 'connectorConsent: async (cmd) => {', 'connectorHighlight: async (c) => {');
  assert.doesNotMatch(consentCmd, /kpress|ksetValue|consume\(|rekey\(/, 'the consent check only reads');
  assert.match(consentCmd, /return \{ status: consentPrint\(rec\.root\) === rec\.consent \? 'ok' : 'changed' \};/);
  // 守：App 端代勾——拿著 Pod、有量完當下記下的節點（CEF 的 backendNodeId）與表單記號；同一份文件、畫面大小一樣、沒縮放；先請網頁腳本核同意內容
  //（變了＝consentChanged），再用 CEF 的節點驗證點擊點「那一個節點」（不依座標重新認領、不走裸座標 sendClick）。
  const pod = swift('TAP/ChatGPTConnectorPod.swift');
  const tick = between(pod, 'func tick(_ target: HandsTickTarget) async -> HandsTickOutcome {', 'nonisolated static func tickControl(');
  // W183 R12（.034 實機：CEF 的畫面快照整頁只有 1 個控制項＝節點驗證永遠過不了、永遠不代勾；主導定的修法）：CEF 認得到＝照舊點那一個節點（加分）；
  // 認不到＝走 DOM 驗證：按之前網頁腳本在同一份文件再驗一次（表單、同意內容一字不差、剛好一格、字對得上、看得見、沒停用、還沒勾）並量位置，
  // 還拿著同一次獨占、同一份文件、畫面大小一樣、沒縮放才用 CEF 真的滑鼠事件點中心（domTick）；點完用 DOM 確認勾上了、Create 能按（tickLanded），沒有＝交回使用者。
  assert.match(tick, /guard let lease = hold, tap\.connection == \.ready, let view = surface\(\)\?\.nativeView, !target\.form\.isEmpty else \{/);
  assert.match(tick, /guard target\.generation != 0, generation == target\.generation, Self\.sameViewport\(view\.bounds\.size, viewport\), view\.zoomLevel == 0 else \{/);
  assert.ok(tick.indexOf('request("connectorConsent", ["form": target.form], hold: lease') > 0);
  assert.ok(tick.indexOf('request("connectorConsent"') < tick.indexOf('view.clickElement('), 'consent is checked before the click');
  // W183 R12（.035 實機）：不點的地方多寫一行原因進紀錄；判斷照舊（changed＝同意內容變了、其他＝不點）。
  assert.match(tick, /guard consent\["status"\] as\? String == "ok" else \{[^}]*\n\s*return consent\["status"\] as\? String == "changed" \? \.consentChanged : \.notClicked\s*\}/);
  assert.match(tick, /view\.clickElement\(node\.id, at: point, expectedRect: rect, viewportSize: view\.bounds\.size,\s*navigationGeneration: generation, dispatchGate:/);
  assert.match(tick, /guard let self, self\.hold == lease, view\.navigationGeneration == generation else \{ return false \}/);
  assert.doesNotMatch(tick, /sendClick\(|Self\.snapshot\(|tickControl\(/, 'no re-claiming by CEF coordinates at click time (the DOM path is domTick)');
  // 守：節點是量完當下認的（同一次獨占、同一份文件；快照裡同一個位置剛好一個）；認不到＝不代勾（交給使用者）。
  const capture = between(pod, 'private func captureTickNode(', '/// armed 的一次性記號');
  assert.match(capture, /let control = Self\.tickControl\(snapshot, target: target, generation: target\.generation, viewport: view\.bounds\.size\)/);
  assert.match(capture, /hold == lease, view\.navigationGeneration == target\.generation,/);
  const control = between(pod, 'nonisolated static func tickControl(', '/// 代填：');
  assert.match(control, /guard matches\.count == 1 else \{ return nil \}/);
  // 守：兩步按綁住同一次獨占、同一份文件、流程的操作編號——每次 await 回來、記錨點前、送「按」之前都核；armed 那一步逾時＝沒有按。
  const action = between(pod, 'private func action(_ command: String, _ arguments: [String: Any]) async -> HandsConnectorAction {', 'private func captureTickNode(');
  assert.match(action, /guard let lease = hold else \{ return \.notFound\("no_lease"\) \}\s*let operation = pressOperation \?\? ""/);
  assert.match(action, /data = try await request\(command, arguments, hold: lease, timeout: \.seconds\(45\)\)/);
  assert.match(action, /\} catch TapError\.timeout \{\s*\/\/[^\n]*\n\s*return \.notFound\("arm_timeout"\)/);
  assert.match(action, /guard hold == lease, !Task\.isCancelled else \{ return \.notFound\("stale_operation"\) \}/);
  assert.match(action, /target\.node = await captureTickNode\(target, lease: lease\)\s*guard hold == lease else \{ return \.notFound\("stale_operation"\) \}/);
  assert.match(action, /operation: operation\)\s*onPressDispatch\?\(anchor\)\s*guard hold == lease,/);
  assert.match(action, /let pressed = try await request\("connectorPress", \["form": token\], hold: lease, timeout: \.seconds\(20\)\)\s*guard hold == lease else \{ return \.unknown \}/);
  const anchorAt = action.indexOf('onPressDispatch?(anchor)');
  const pressAt = action.indexOf('request("connectorPress"');
  assert.ok(anchorAt > 0 && pressAt > anchorAt, 'the anchor is set before the press is sent');
  // 守：流程——代勾只點一次；沒勾到＝交給使用者；派送前核到同意內容變了＝交給使用者（卡片說不認得）；錨點只收這一次的操作。
  const flow = between(connect, 'private func tickAndCreate(', 'private func awaitAuthorize(');
  assert.equal((flow.match(/pod\.tick\(/g) || []).length, 1, 'one native click per hand-back');
  assert.match(flow, /case \.consentChanged:\s*\/\/[^\n]*\n\s*return \.needsUser\(Self\.warningChangedReason, seen\)/);
  assert.match(flow, /case \.notClicked:\s*return \.needsUser\(Self\.tickMissedReason, seen\)/);
  assert.match(flow, /case \.tickable\(let again, _\):\s*return \.needsUser\(Self\.tickMissedReason, again\)/);
  assert.match(flow, /where reason == Self\.riskAckReason \|\| reason == Self\.untrustedTickReason:\s*return \.needsUser\(Self\.tickMissedReason, again\)/);
  assert.match(flow, /beginPressOperation\(\)\s*let next: HandsConnectorAction/);
  const dispatched = between(connect, 'private func pressDispatched(_ anchor: HandsPressAnchor) {', 'private func beginPressOperation() {');
  assert.match(dispatched, /guard let expected = pressOperation, anchor\.operation == expected else \{\s*log\("stale press anchor"\)\s*return\s*\}/);
  assert.doesNotMatch(connect, /\bticking\b/);
  assert.match(connect, /pressUnproven = true/);
  assert.match(connect, /let provenFill = pressAnchor != nil && !pressUnproven && !crowdedSinceAnchor && !manualAttempt\s*if let code, provenFill, autoFill == \.notTried \{/);
});
