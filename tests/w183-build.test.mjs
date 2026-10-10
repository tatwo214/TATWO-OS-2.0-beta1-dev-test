// W183 R8c：ChatGPT build 多設備後端的原始碼契約（GPT-6 設計審查 W183-R8「開工前必改」六條；contract.md §11、threat-model.md T12／T17）。
// 動態的兩台／三台情境（主設備真的簽信封、副設備真的驗、信箱、登入、連線、交換碼卡與 token、安全鎖、離線那台的通道）在 App 自測
// TATWO2_SELFTEST=w183build（lead-verify 在 mini 跑）；這裡釘住程式碼的界線，免得之後被改鬆。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = 'App/Sources/Tatwo2/';
const swift = (p) => read(app + p);
const code = (source) => source.replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^\n"]*$/gm, '').replace(/^\s*\/\/\/.*$/gm, '');
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(!end || to > from, `missing ${end}`);
  return source.slice(from, to < 0 ? source.length : to);
};

const config = swift('Facade/HandsBuildConfig.swift');
const envelope = swift('Facade/HandsBuildEnvelope.swift');
const mailbox = swift('Facade/HandsBuildMailbox.swift');
const sync = swift('Facade/HandsBuildSync.swift');
const controller = swift('Facade/HandsBuildController.swift');
const acceptance = swift('Facade/HandsBuildAcceptance.swift') + '\n' + swift('Facade/HandsBuildReviewAcceptance.swift')
  + '\n' + swift('Facade/HandsBuildIntegrationReviewAcceptance.swift');
const buildInterface = swift('Facade/HandsBuild.swift');
const setup = swift('Facade/HandsSetup.swift');
const remote = swift('Facade/HandsRemote.swift');
const auth = swift('Facade/HandsAuth.swift');
const service = swift('Facade/HandsService.swift');
const gateway = swift('Facade/ChatGPTHandsService.swift');
const accounts = swift('Facade/CloudflareAccounts.swift');
const host = swift('Facade/HandsConnectHost.swift');
const connect = swift('Facade/HandsConnect.swift');
const links = swift('Facade/HandsConnectLinks.swift');
const scope = swift('Facade/HandsConnectScope.swift');
const bridge = swift('Facade/OSAgentBridge.swift');
const contractSource = swift('Facade/HandsContract.swift');
const tools = swift('Facade/HandsTools.swift');
const tap = swift('TAP/ChatGPTTap.swift');
const pod = swift('TAP/ChatGPTConnectorPod.swift');
const shell = swift('Shell/AppShell.swift');
const selftest = swift('SelfTest.swift');
const jobs = swift('Facade/HandsJobs.swift');
const handsState = swift('Facade/HandsState.swift');
const mcpServer = read('Engines/os-mcp/server.mjs');
const contract = read('docs/specs/183-chatgpt-hands/contract.md');
const threat = read('docs/specs/183-chatgpt-hands/threat-model.md');
const allSwift = readdirSync(new URL('../' + app + 'Facade/', import.meta.url)).filter((f) => f.endsWith('.swift'))
  .map((f) => swift('Facade/' + f)).join('\n');

// ---------- 必改 1：每台設定與世代模型 ----------

test('must-fix 1: per-device config with separate epochs; CAS on every change; one hostname per device; no single host claim or lease', () => {
  for (const field of ['var primaryID: String', 'var authorityEpoch: Int', 'var configRevision: Int', 'var enabled: Bool', 'var devices: [HandsBuildDeviceEntry]']) {
    assert.ok(config.includes(field), field);
  }
  for (const field of ['var deviceRevision: Int', 'var revocationGeneration: Int', 'var subdomain: String', 'var level: Int', 'var projectIDs: [String]']) {
    assert.ok(between(config, 'struct HandsBuildDeviceEntry', 'enum CodingKeys').includes(field), field);
  }
  // W183 R8c 審查（GPT-6 中）：預期版本一定要帶（沒有「nil＝跳過比對」）；RPC 沒帶、布林、小數、負的一律不收；畫面沒拿到設定不能改。
  // W183 R11 第二輪（GPT-6 R11b 審查 1）：update 多一個 raise（調高等級照那台的回報核）；預期版本那幾條照舊守。
  // W183 R11 最後一輪（GPT-6 R11c 審查 1）：raise 多拿改之前的這一份（那台要已經套用到這一版）；下面守的照舊。
  const update = between(config, 'func update(expectedRevision: Int, ops: [HandsBuildConfigOp], raise: (String, HandsBuildConfig) -> HandsBuildRaise) throws -> HandsBuildConfig {', 'static func apply(');
  assert.match(update, /guard expectedRevision == current\.configRevision else \{ throw HandsBuildConfigError\.revisionConflict\(current\.configRevision\) \}/);
  assert.doesNotMatch(allSwift, /expectedRevision: Int\?|updateConfig\(expected: Int\?/);
  assert.match(mailbox, /guard let number = payload\["expected_revision"\] as\? NSNumber, CFGetTypeID\(number\) != CFBooleanGetTypeID\(\),\n\s*Double\(number\.intValue\) == number\.doubleValue, number\.intValue >= 0 else \{ throw HandsBuildMailboxError\.invalid\("expected_revision"\) \}/);
  assert.match(between(controller, 'private func change(_ ops: [HandsBuildConfigOp]) {', 'func setEnabled('), /guard let expected = config\?\.configRevision else \{/);
  assert.match(update, /if current\.slice\(for: id\)\.contentKey != config\.slice\(for: id\)\.contentKey \{\n\s*config\.devices\[index\]\.deviceRevision = \(old\?\.deviceRevision \?\? 0\) \+ 1/);
  assert.match(update, /if current\.isActive\(id\), !config\.isActive\(id\) \{\n\s*config\.devices\[index\]\.revocationGeneration = \(old\?\.revocationGeneration \?\? 0\) \+ 1/);
  assert.match(update, /if let owner = table\.owner\(of: host\), !HandsHostAuthority\.same\(owner, entry\.deviceID\) \{ throw HandsBuildConfigError\.hostnameOwned\(host\) \}/);
  assert.match(config, /guard labels\.insert\(label\)\.inserted else \{ throw HandsBuildConfigError\.hostnameTaken\(label\) \}/);
  // 「沒有副設備的人一律主設備」：打開時一台都沒勾＝勾主設備。
  assert.match(between(config, 'config.enabled = on', 'case .select('), /if on, config\.devices\.allSatisfy\(\{ !\$0\.selected \}\) \{/);
  // 預設子網域：主設備 os-for-chatgpt、其他 os-for-chatgpt-<簡稱>。
  assert.match(config, /candidate = base \+ "-" \+ tail/);
  // 單主機的交接與租約拿掉。
  assert.doesNotMatch(allSwift, /final class HandsHostLease|HandsHostLease\.(shared|permits)/);
  assert.match(remote, /case "claim_host", "release_host":\n[^\n]*\n\s*throw Failure\.invalid\(hostClaimRetired\)/);
  assert.match(gateway, /var hostConfirmed: \(_ local: String\) -> Bool = \{ HandsBuildPermit\.permits\(\$0\) \}/);
  // 設定正本沒有秘密欄位。
  assert.doesNotMatch(code(between(config, 'struct HandsBuildConfig: Codable', 'enum HandsBuildConfigError')), /token|secret|cert|password|apiToken/i);
});

test('must-fix 8: legacy single host migrates to "that one device selected" and never copies OAuth state', () => {
  const migrate = between(config, 'static func migrated(local: String', '\n}\n');
  assert.match(migrate, /let host = \(settings\.hostDeviceID \?\? \(settings\.enabled \? local : nil\)\)\?\.lowercased\(\)/);
  // W183 R11（使用者 09-30「接上要明確讓chatgpt能獲得codex能力 以及os記憶讀取」）：舊的預設 L1 遷過來＝L2（Codex、記憶）；使用者刻意收窄的 L0 照舊。
  // W183 R11 第二輪（GPT-6 R11 審查 1）：舊預設 L1 不在遷移時直接升 L2——記成待升（那台回報說會先封頂或沒有連線才升）。等級照舊的設定帶過來。
  assert.match(migrate, /selected: true,\n\s*subdomain: settings\.effectiveSubdomainLabel, level: settings\.level,\n\s*projectIDs: hostIsLocal \? settings\.allowedProjectIDs : \[\]/);
  // W183 R12（使用者 09-30 裁決：拿掉等級選擇；所有設備一律 L2）：L0 也記成待升（還是等那台的回報、同一道 raiseCheck 才升）。
  assert.match(migrate, /if settings\.level < HandsBuildConfig\.defaultLevel \{ config\.levelDefaultPending = \[host\] \}/);
  assert.match(migrate, /evidence: "legacy_host"/);
  assert.doesNotMatch(code(migrate), /HandsAuth|auth\.json|\bgrants?\b|token/i);
  assert.match(between(config, 'func load() -> HandsBuildConfig? {', 'func ownership()'), /檔案壞了（不是沒有）＝不自己重建：當成全部關著（fail closed）/);
});

// ---------- 必改 2：可信設定套用 ----------

test('must-fix 2: signed envelope with the existing device identity key; only the pinned primary key; rollback and same-revision-different-content refused', () => {
  assert.match(envelope, /static let namespace = "tatwo2-hands-build"/);
  assert.doesNotMatch(envelope, /"tatwo2-rpc"/, 'a separate namespace from the RPC proofs');
  for (const field of ['var primaryID: String', 'var authorityEpoch: Int', 'var targetDeviceID: String', 'var configRevision: Int', 'var deviceRevision: Int',
    'var revocationGeneration: Int', 'var contentHash: String', 'var issuedAt: Int', 'var expiresAt: Int']) {
    assert.ok(between(envelope, 'struct HandsBuildEnvelopeBody', 'enum CodingKeys').includes(field), field);
  }
  const verify = between(envelope, 'static func verify(_ envelope: HandsBuildEnvelope', 'static func verifySignature(');
  const order = ['guard let pinned = trust.pinnedPrimaryKey', 'fingerprint == pinned', 'verifySignature(body:', 'body.primaryID, trust.primaryID',
    'body.authorityEpoch == trust.epoch', 'body.targetDeviceID, trust.localID', 'body.content.contentHash == body.contentHash', 'guard expires > current']
    .map((needle) => verify.indexOf(needle));
  assert.ok(order.every((i) => i >= 0) && order.every((v, i) => i === 0 || order[i - 1] < v), `verify order ${order}`);
  assert.match(envelope, /record\?\.pinnedClientKeyFingerprint/);
  const accept = between(envelope, 'func accept(_ envelope: HandsBuildEnvelope, trust: HandsBuildTrust, now: Date) throws -> Outcome {', 'private func store(');
  assert.match(accept, /if body\.configRevision < current\.configRevision \{ throw HandsBuildEnvelopeError\.rollback \}/);
  assert.match(accept, /guard body\.contentHash == current\.contentHash else \{ throw HandsBuildEnvelopeError\.conflict \}/);
  // W183 R8c 審查（GPT-6 中）：每台的 deviceRevision 與撤銷世代各自單調；同一個 deviceRevision＝同一份內容。
  assert.match(accept, /guard body\.deviceRevision >= current\.deviceRevision, body\.revocationGeneration >= current\.revocationGeneration else \{\n\s*throw HandsBuildEnvelopeError\.rollback/);
  assert.match(accept, /guard body\.content\.contentKey == current\.content\.contentKey, body\.revocationGeneration == current\.revocationGeneration else \{\n\s*throw HandsBuildEnvelopeError\.conflict/);
  // W183 R8c 審查（Claude 高）：逐位元一樣的信封不重驗章（每輪同步不開 ssh-keygen）；只核期限。
  assert.match(accept, /if let verified, verified\.trust == trust, verified\.raw == envelope \{/);
  assert.match(envelope, /讀回來重驗章/);
  // 許可：副設備看已接受、沒過期、給這台的；過期＝安全暫停。
  const permit = between(envelope, 'func state(_ local: String) -> State {', 'func permits(');
  assert.match(permit, /guard dependencies\.now\(\) < body\.expiresDate else \{ return \.paused\("expired"\) \}/);
  // 關口跑著時許可沒了＝停下，不撤銷；工具與配對入口也看許可。
  assert.match(gateway, /if let local = dependencies\.localDeviceID\(\), !dependencies\.hostConfirmed\(local\) \{\n\s*currentFingerprint = nil\n\s*shutdown\(then: \.stopped\)/);
  assert.doesNotMatch(between(gateway, 'if let local = dependencies.localDeviceID(), !dependencies.hostConfirmed(local) {', 'checkAlive()'), /revoke/);
  assert.match(service, /guard current\.enabled, deviceAllowed\(current\), permitCheck\?\(\) \?\? true else \{ throw HandsWireError\.unauthorized \}/);
  assert.match(service, /if permitCheck\?\(\) == false \{ return "build_paused" \}/);
});

test('must-fix 2: background reconcile narrows, never retries; explicit disable revokes; polling never clears the safety lock', () => {
  const reconcile = between(sync, 'struct HandsBuildReconciler', 'final class HandsBuildExecutor');
  // W183 R8c 審查（GPT-6 高）：關掉這台＝**先**作廢進行中的設定工作（換世代、收掉 cloudflared），再撤銷、關開關；存不進去＝不算套用。
  const revoke = between(reconcile, 'if slice.revocationGeneration > record.revocationGeneration {', '// 2.');
  assert.ok(revoke.indexOf('cancelSetup()') >= 0 && revoke.indexOf('cancelSetup()') < revoke.indexOf('updateSettings'), 'cancel the setup job before turning off');
  assert.match(revoke, /if durable \{ record\.revocationGeneration = slice\.revocationGeneration \} else \{ failed = true \}/);
  assert.match(sync, /cancelSetup: \{ HandsSetup\.shared\.cancel\(\) \},\n\s*suspend: \{ service\.suspendForPermit\(\) \}\)/);
  // W183 R10（取代「等級與專案只收窄」；使用者 09-29「這邊要勾選也太怪…沒有那麼多權限需要隔離」）：本機等級＝中央設定（收窄、放大都在
  // 這台收到就生效，不用到主機再核准）；專案不再照中央清單收窄（全部可見：本機 allowed_project_ids 不是閘門，這裡不寫）。
  assert.match(reconcile, /settings\.level = slice\.level\n/);
  assert.doesNotMatch(code(reconcile), /settings\.allowedProjectIDs =|min\(settings\.level, slice\.level\)/);
  // 收窄存不成＝本機記的等級比中央高就先收掉跑著的工作（有效設定本來就直接看中央：收窄一定生效）。
  assert.match(reconcile, /if local\.level > slice\.level \{ suspend\(\) \}/);
  // W183 R8c 審查（Claude 中）：只在這台的版本變大時收窄（同一版不動）；只有「從沒勾變成勾了」才打開。
  assert.doesNotMatch(code(reconcile), /\} else if slice\.active \{/, 'no narrowing on the same revision');
  assert.match(reconcile, /if becameActive, HandsGatewayLaunch\.validHost\(settings\.publicHost\) != nil \{ settings\.enabled = true \}/);
  // W183 R8c 審查（GPT-6 高）：許可沒了＝收掉跑著的工作、關配對窗口（grant 留著）；長工作跑的時候也看許可。
  assert.match(reconcile, /if wasActive == true, !state\.isActive \{\n\s*suspend\(\)/);
  assert.match(service, /func suspendForPermit\(\) \{[\s\S]*?jobs\.cancel\(where: \{ _ in true \}[\s\S]*?HandsSandbox\.terminateAll\(\)\n\s*auth\.closeWindow\(\)/);
  assert.doesNotMatch(between(service, 'func suspendForPermit() {', '/// 開始配對'), /revoke/);
  assert.match(jobs, /if service\.permitCheck\?\(\) == false \{\n\s*HandsSandbox\.terminate\(where:/);
  assert.doesNotMatch(code(reconcile), /retry\(|retryKeepingSafetyLock|unlockSafety|clearSafetyStop/);
  assert.doesNotMatch(code(sync), /\.retry\(\)/, 'the sync file never calls retry(); the executor only calls the incident-bound unlock');
  assert.match(sync, /unlockSafety: \{ incident in ChatGPTHandsService\.shared\.unlockSafety\(incident: incident\) \}/);
  // W183 R8c 審查（GPT-6 高）：解除安全鎖綁事故編號、setupEpoch（一定要帶）、撤銷世代；撤銷全部綁按的時候看到的那一組。
  assert.match(sync, /static let epochActions: Set<String> = \["login", "apply_urls", "unlock_safety", "revoke_all"\]/);
  assert.match(sync, /guard let epoch = intent\.setupEpoch else \{ return "epoch_missing" \}/);
  assert.match(sync, /guard dependencies\.unlockSafety\(incident\) else \{ record\(intent, "incident_changed"\); return refuse\(intent, "incident_changed"\) \}/);
  assert.match(sync, /guard HandsAuth\.constantTimeEqual\(HandsBuildDeviceReport\.digest\(grants: service\.auth\.activeGrantIDs\), seen\) else \{/);
  assert.match(gateway, /queue\.sync \{\n\s*let current = safetyLatched \? \(latchedIncident \?\? Self\.safetyIncident\(paths\)\) : Self\.safetyIncident\(paths\)\n\s*guard let current, HandsAuth\.constantTimeEqual\(current, incident\) else \{ return false \}/);
  // 設定流程叫關口一律保留安全鎖；「解除」只有使用者明確按的。
  assert.match(setup, /startService: \{ ChatGPTHandsService\.shared\.retryKeepingSafetyLock\(\) \}/);
  assert.match(remote, /guard let incident = payload\["safety_incident"\] as\? String, \(1\.\.\.64\)\.contains\(incident\.utf8\.count\), host\.unlockSafety\(incident\) else \{/);
  assert.match(remote, /case "start_setup", [^\n]*"unlock_safety":\n\s*guard payload\["grant_id"\] == nil else \{ throw Failure\.invalid\("unexpected field"\) \}\n\s*var result = try setupAction\(/,
    'the signed unlock_safety action is routed to setupAction (not refused as an unknown op)');
  // 這台畫面上安全停機那一列的「重試」＝使用者對這台明確解除（只在安全停機時叫 unlockSafety；其他時候照樣保留安全鎖）。
  const oneSwitch = swift('Facade/HandsOneSwitch.swift');
  assert.match(between(oneSwitch, 'static func retry(setup: HandsSetup) {', 'static func reauthorize('),
    /if case \.failed\(ChatGPTHandsService\.tamperedText\) = setup\.dependencies\.servicePhase\(\) \{ setup\.dependencies\.unlockSafety\(\) \}/);
  assert.match(setup, /var unlockSafety: \(\) -> Void = \{\}/);
  assert.match(setup, /deps\.unlockSafety = \{ ChatGPTHandsService\.shared\.retry\(\) \}/);
  assert.doesNotMatch(code(between(setup, 'func resumeIfEnabled()', 'func reauthorize(')), /unlockSafety/);
  // 背景同步不靠設定頁；自測／staging 不跑。
  assert.match(shell, /HandsBuildSync\.shared\.start\(\)/);
  assert.match(between(sync, 'func start() {', 'func heatUp()'), /guard ChatGPTHandsService\.allowedToRun\(environment: ProcessInfo\.processInfo\.environment\) else \{ return \}/);
});

// ---------- 必改 3：信箱協定 ----------

test('must-fix 3: mailbox binds owner/target/operation/attempt/revision/epoch/expiry/payload hash; owner-only results; in memory only; B decides', () => {
  const submission = between(mailbox, 'static func submission(_ raw: [String: Any], owner: String, now: Date) throws -> HandsBuildIntent {', 'var deliveryWire');
  assert.match(submission, /guard let claimed = raw\["payload_hash"\] as\? String, HandsAuth\.constantTimeEqual\(claimed, hash\) else/);
  assert.match(submission, /owner: owner\.lowercased\(\)/, 'owner = the verified sender, never the payload');
  assert.doesNotMatch(submission, /raw\["owner"\]/);
  assert.match(mailbox, /static let actions: Set<String> = \["login", "login_cancel", "apply_urls", "connect", "revoke_all", "unlock_safety"\]/);
  assert.match(between(mailbox, 'func take(target: String, now: Date)', 'func pending('), /operation\.delivered = true/);
  assert.match(between(mailbox, 'func post(_ result: HandsBuildResult, from sender: String', 'func takeResults('), /guard HandsHostAuthority\.same\(operation\.intent\.target, sender\) else \{ throw HandsBuildMailboxError\.notTarget \}/);
  const take = between(mailbox, 'func takeResults(owner: String, now: Date, acks: [String: Int] = [:]) -> [HandsBuildResult] {', 'func debugState(');
  assert.match(take, /HandsHostAuthority\.same\(operation\.intent\.owner, owner\)/);
  // W183 R8c 審查（GPT-6 中）：擁有者 ack 了才拿掉（最後一則也 ack＝整件清掉）；沒 ack 的下一次再給；還在等、P 不認得＝gone。
  assert.match(take, /operations\[id\] = operation\.finalPosted && operation\.results\.isEmpty && operation\.nextSeq <= seq \+ 1 \? nil : operation/);
  assert.match(take, /func gone\(owner: String, waiting: \[String\], now: Date\) -> \[String\] \{/);
  assert.match(mailbox, /guard !operation\.finalPosted, !operation\.senderSeqs\.contains\(result\.seq\) else \{ return operation\.intent\.owner \}/);
  assert.match(sync, /private func expireWaiters\(now: Date, gone: \(String\) -> Bool\) \{/);
  assert.match(sync, /object: \["state": "unknown", "reason": expired \? "expired" : "result_unknown"\]/);
  assert.doesNotMatch(code(between(sync, 'private func postResult(', 'private func flushOutbox(')), /try\? self\.dependencies\.callPrimary\(\["op": "result"[^)]*\)\n/, 'a failed post goes to the outbox');
  assert.match(sync, /self\.outbox\.append\(result\)/);
  assert.doesNotMatch(code(mailbox), /writeAtomically|\.write\(to:|FileManager|UserDefaults/, 'the relay keeps nothing on disk');
  // 設備簽章 RPC：只收 SSH 轉進來（這台的 AI 引擎、背景工作、外部 AI 一律拒）；驗章得到的 sender。
  assert.match(bridge, /if method == HandsBuildRemote\.method \{ return caller == \.ssh \}/);
  assert.match(bridge, /case "hands_build":\n\s*let \(sender, payload\) = try requestDispatch\.authenticate\(method: method, proof: params\)\n\s*return try HandsBuildRemote\.handle\(payload: payload, sender: sender\)/);
  assert.match(bridge, /private var requestDispatch: DeviceDispatch \{\s*#if DEBUG\s*if let fleetTestDispatch \{ return fleetTestDispatch \}\s*#endif\s*return DeviceDispatch\.shared/);
  // B：先落地冪等紀錄才做；取消先到＝墓碑；setupEpoch；套用要同一版設定。
  const run = between(sync, 'private func run(_ intent: HandsBuildIntent,', 'private func record(');
  const ledgerFirst = run.indexOf('guard saveLedger(ledger) else'), dispatch = run.indexOf('switch intent.action');
  assert.ok(ledgerFirst > 0 && dispatch > ledgerFirst, 'ledger on disk before acting');
  assert.match(run, /if let tomb = ledger\.tombstones\[intent\.operationID\], HandsHostAuthority\.same\(tomb\.owner, intent\.owner\) \{/);
  assert.match(sync, /return epoch == dependencies\.setup\(\)\.setupEpoch \? nil : "epoch_stale"/);
  // W183 R8c 審查（GPT-6 中）：登入的位子原子地佔用（忙碌的第二件不蓋掉）；取消認擁有者、找得到那一件才回成功；墓碑綁擁有者、存不進去回失敗。
  assert.match(sync, /if runningLogin != nil \{ lock\.unlock\(\); record\(intent, "busy"\); return refuse\(intent, "busy"\) \}/);
  assert.match(sync, /guard HandsHostAuthority\.same\(running\.owner, intent\.owner\) else \{ record\(intent, "not_owner"\); return refuse\(intent, "not_owner"\) \}/);
  assert.match(sync, /let cancelled = dependencies\.setup\(\)\.cancelRemoteLogin\(target\)/);
  assert.match(sync, /guard saved else \{ record\(intent, "ledger_not_saved"\); return refuse\(intent, "ledger_not_saved"\) \}/);
  assert.match(setup, /guard jobActive, remoteLogin != nil, remoteLoginOperation == operationID, let run = currentRun, run\.id == remoteLoginRun else \{/);
  assert.match(sync, /guard current\.configRevision == intent\.configRevision else \{ return reject\("config_changed"\) \}/);
  assert.match(sync, /func reject\(_ reason: String\) \{ record\(intent, reason\); refuse\(intent, reason, completion: completion\) \}/);
  // 連線的每一步跟設備簽章 RPC 同一套主機規則（擁有者＝P 驗章得到的 A）。
  assert.match(sync, /try HandsConnectRemote\.handle\(op, payload: payload, sender: intent\.owner, host: dependencies\.remoteHost\(\),/);
  assert.match(links, /struct HandsConnectMailboxLink: HandsConnectLink/);
  assert.match(links, /static func live\(target: String\) -> \(link: \(any HandsConnectLink\)\?, problem: String\?\)/);
});

test('must-fix 3: the public status carries no login URL, confirm token or pairing code', () => {
  const status = code(between(remote, 'static func status(_ host: Host', 'static func same('));
  assert.doesNotMatch(status, /login_url|confirm_token|pairing_code|"card"|absoluteString/);
  const report = code(between(mailbox, 'struct HandsBuildDeviceReport', 'final class HandsBuildAuthority'));
  assert.doesNotMatch(report, /login_url|loginURL|pairing|confirm_token|token"|secret/i);
  // 登入網址只經信箱交給擁有者（不進狀態檔、給 AI 的狀態）。
  assert.match(setup, /if trigger != \.remote \{ self\.openIfCurrent\(url, round: round\) \} else \{ self\.deliverRemoteLoginURL\(url\) \}/);
  assert.doesNotMatch(between(setup, 'func statusPayload()', 'enum HandsSetupTool'), /login_url|loginURL\b|absoluteString/);
});

// ---------- 必改 4：登入、套用網址、安全鎖分開 ----------

test('must-fix 4: login is only login (no auto domain, no adopt, no continue); apply builds URLs; resume and the assistant never create DNS', () => {
  const upsert = between(accounts, 'func upsert(accountID: String', 'func setDomainName(');
  assert.doesNotMatch(code(upsert), /selectedDomain = domain\.zoneID|selectedDomain: domain\.zoneID/);
  assert.match(upsert, /selectedDomain: nil/);
  assert.match(accounts, /var selected: CloudflareDomain\? \{\n\s*domains\.first \{ \$0\.zoneID == selectedDomain \}\n\s*\}/);
  assert.doesNotMatch(code(setup), /private func adopt\(|resumeIntent|continueAfterConfirm|func chosenAccountDomain/);
  const authorize = between(setup, 'private func stepAuthorize', 'private struct CommandResult');
  assert.match(authorize, /mutate \{ \$0\.loginZoneID = cert\.zoneID \}/);
  assert.match(authorize, /return waitUser\(\.authorize, Self\.chooseDomainMessage\)/);
  assert.match(between(setup, 'func confirmAuthorization(token: String', 'private func domainName'), /let started = enqueue\(\[\], trigger: trigger/);
  assert.match(setup, /func applyURLs\(accountID: String, zoneID: String, trigger: HandsSetupTrigger, requester: String\? = nil, finished: \(\(\) -> Void\)\? = nil\) -> Bool \{\n\s*do \{ try chooseDomain\(accountID: accountID, zoneID: zoneID\) \} catch \{ return false \}/);
  assert.match(between(setup, 'private func stepTunnel', 'let state = snapshot'), /if trigger == \.resume \|\| trigger == \.assistant, snapshot\.tunnelID == nil \|\| snapshot\.publicHost == nil \{\n\s*return waitUser\(\.tunnel, Self\.applyFirstMessage\)/);
  assert.match(setup, /func loginForRemote\(requester: String, operationID: String\? = nil, onURL: @escaping \(URL\) -> Void,\n\s*onEnd: @escaping \(HandsLoginOutcome\) -> Void\) -> Bool/);
  // W183 R8c 審查（GPT-6／Claude 高）：自動續跑與助理只恢復已經套用的網址（任何網址都不遷移、不 route dns）。
  assert.match(setup, /private func keepsCurrentHost\(_ state: HandsSetupState, trigger: HandsSetupTrigger\) -> Bool \{\n\s*guard state\.publicHost != nil, state\.tunnelID != nil else \{ return false \}\n\s*return trigger == \.resume \|\| trigger == \.assistant/);
  assert.doesNotMatch(setup, /keepsLegacyHost/);
  // W183 R8c 審查（GPT-6 中）：「套用」＝不變的快照；選網域與佔用工作槽同一把鎖；建通道、改 DNS、寫「打開」之前都再核；本機也走執行者。
  const applyPlan = between(setup, 'func applyURLs(plan: HandsApplyPlan, trigger: HandsSetupTrigger', 'private func adoptPlan(');
  assert.match(applyPlan, /lock\.lock\(\); defer \{ lock\.unlock\(\) \}[\s\S]*?try chooseDomain\(accountID: plan\.accountID, zoneID: plan\.zoneID\)[\s\S]*?activePlan = plan\n\s*let started = enqueue\(/);
  const tunnelStep = between(setup, 'private func stepTunnel', '// 3. 通道 token');
  assert.match(tunnelStep, /if let plan, let problem = planProblem\(plan\) \{ return fail\(\.tunnel, problem\) \}/);
  assert.ok(tunnelStep.indexOf('guard unchanged() else { return fail(.tunnel, plan != nil ? Self.planChangedMessage : changed) }   // W183 R8c 審查：改 DNS 之前再核')
    < tunnelStep.indexOf('base + ["route", "dns", tunnelID, requested]'), 're-check the plan right before route dns');
  assert.match(between(setup, 'private func stepStart', 'private func stepURL'), /if !self\.dependencies\.buildPermit\(hostDevice\)\.isActive \{ refusal\.set\("permit"\); return \}\n\s*if let plan = self\.currentPlan, self\.planProblem\(plan\) != nil \{ refusal\.set\("permit"\); return \}/);
  assert.match(sync, /let started = setup\.applyURLs\(plan: plan, trigger: \.remote, requester: intent\.owner, finished:/);
  assert.doesNotMatch(controller, /HandsSetup\.shared\.applyURLs/, 'the controller never bypasses the executor');
  const local = between(controller, 'func applyHere(expected:', 'static func localApplyText');
  assert.match(local, /try sync\.applyHere\(expected: expected, setupEpoch: setupEpoch, onResult: receive\)/);
  assert.match(sync, /dependencies\.executor\.applyHere\(intent, current:/);
  assert.doesNotMatch(code(local), /syncSoon\(|updateConfig\(|\.submit\(/, 'local apply neither updates config nor sends remote work');
});

// ---------- 必改 5：每台 OAuth／工作區邊界 ----------

test('must-fix 5: grants carry host, issuer/resource and revocation generation; exact resource on the App side; evidence v2 binds target/attempt/epoch', () => {
  const grant = between(auth, 'struct Grant: Codable, Equatable {', 'var isActive: Bool');
  for (const field of ['var hostDeviceID: String? = nil', 'var issuer: String? = nil', 'var resource: String? = nil', 'var generation: Int? = nil']) {
    assert.ok(grant.includes(field), field);
  }
  // W183 R8c 審查（GPT-6 中）：主機、issuer、resource、撤銷世代全部要有、而且精確相符（缺欄位的舊資料只經明確遷移）。
  const bound = between(auth, 'static func bound(_ grant: HandsAuthState.Grant, to binding: HandsGrantBinding?) -> Bool {', 'func upgradeLegacyBindings(');
  assert.match(bound, /guard let host = grant\.hostDeviceID, host\.caseInsensitiveCompare\(binding\.hostDeviceID\) == \.orderedSame,\n\s*let issuer = grant\.issuer, let expectedIssuer = binding\.issuer, issuer\.lowercased\(\) == expectedIssuer\.lowercased\(\),\n\s*let resource = grant\.resource, let expectedResource = binding\.resource, resource\.lowercased\(\) == expectedResource\.lowercased\(\),\n\s*let generation = grant\.generation, generation == binding\.generation else \{ return false \}/);
  assert.doesNotMatch(code(bound), /if let resource/, 'no optional-resource bypass');
  assert.match(auth, /_ = revokeLocked\(revoke, reason: "binding_upgrade"\)/);
  assert.match(sync, /if state\.isActive, !failed, let binding = service\.auth\.binding\?\(\) \{ service\.auth\.upgradeLegacyBindings\(binding\) \}/);
  assert.match(auth, /state\.clients\.contains\(where: \{ \$0\.id == grant\.clientID \}\), Self\.bound\(grant, to: currentBinding\) else \{ return nil \}/);
  assert.match(auth, /grant\.isActive, grant\.clientID == clientID, Self\.bound\(grant, to: bindingForIssue\) else \{ throw HandsWireError\.invalidGrant \}/, 'refresh also checks the binding');
  assert.match(auth, /if let expected = context\.resource \{\n\s*if let resource, resource != expected \{ throw HandsWireError\.invalidRequest\("resource"\) \}/);
  assert.match(service, /let resource = HandsGatewayLaunch\.validHost\(current\.publicHost\)\.map \{ "https:\/\/\\\(\$0\)\/mcp" \}/);
  assert.match(auth, /"sha256:" \+ sha256Hex\(Data\(\["tatwo-evidence-v2", target\.lowercased\(\), issuer\.lowercased\(\), resource\.lowercased\(\), attempt\.lowercased\(\),\n\s*setupEpoch, evidence\]/);
  assert.match(host, /\} else if HandsAuth\.constantTimeEqual\(expectedEvidence\(tx, attempt\), evidence\) \{/);
  assert.match(connect, /let evidence = HandsAuth\.boundEvidence\(first\.evidence, target: intent\.hostDeviceID, issuer: issuer, resource: intent\.mcpURL,/);
  // 同一個 Pod 一次只建一個連接器；「連全部」逐台排；名稱「TATWO（<設備名稱>）」。
  assert.match(controller, /private func startNextConnect\(\) \{\n\s*guard connecting == nil, !connectQueue\.isEmpty else \{ return \}/);
  assert.match(config, /return cleaned\.isEmpty \? "TATWO" : "TATWO（\\\(cleaned\)）"/);
  // W183 R9c（C1）：名稱只收這個樣子（抓好的 RegExp exec），填的是指令參數自己的 name。
  // W183 R12（.036 實機；主導裁決：撞名就換名字重建）：後面可以多一個 2–9（「TATWO（Mac mini）2」）；其他照舊退回 TATWO。
  assert.match(tap, /return reTest\(\/\^TATWO（\[\^\\u0000-\\u001f（）\]\{1,40\}）\(\?:\[2-9\]\|\[1-9\]\[0-9\]\+\)\?\$\/, n\) \? n : CONNECTOR_NAME;/);
  assert.match(tap, /const wantName = connectorName\(own\(c, 'name'\)\);/);
  assert.match(tap, /ksetValue\(names\[0\], wantName\);/);
  assert.match(pod, /var arguments: \[String: Any\] = \["url": url, "name": name\]/);
  // W183 R10（取代「卡上選的範圍不超過 build 給那台的上限」）：卡上不再選範圍——主機一律拒收帶範圍的 begin（範圍＝中央等級＋這台全部專案）；
  // 等級超過中央設定的呼叫、工作一律拒（capProblem；交易實盤類專案另外最多 L0）。
  assert.match(host, /guard request\.choice == nil else \{ throw HandsConnectRefusal\.scopeInvalid \}/);
  assert.doesNotMatch(code(scope), /func validatedChoice/);
  assert.match(service, /func capProblem\(level: Int, projectID: UUID\?\) -> String\? \{\s*if let cap = scopeCap\?\(\), level > cap\.level \{ return "level_lowered" \}\s*if level > HandsTradingFloor\.maxLevel, let projectID, isTradingCached\(projectID\) \{ return "project_read_only" \}/);
  // 卡上、面板上的清單＝這台全部能當專案的（不再照上限收窄；新專案自動加入）。
  assert.match(scope, /func connectProjectChoices\(allowed: Set<String>\) -> \[HandsProjectChoice\] \{\s*allConnectProjectChoices\(allowed: allowed\)\s*\}/);
});

// ---------- 必改 6：Cloudflare 資源所有權 ----------

test('must-fix 6: ownership kept on the primary; each device lists only tunnels it has evidence for; unknown ownership or DNS = list nothing', () => {
  assert.match(config, /mutating func replace\(device: String, with reported: \[Record\], released: \[String\] = \[\], now: Date\) -> \[String\] \{/);
  assert.match(config, /if let owner = owner\(of: host\), !HandsHostAuthority\.same\(owner, id\) \{ conflicts\.append\(host\); continue \}/);
  // W183 R8c 審查（GPT-6 中）：沒回報不等於釋放（只憑釋放證據拿掉）；表滿了不擠掉舊的；讀不到＝unknown（不是空表）。
  const replace = between(config, 'mutating func replace(device: String', 'var wire: [[String: Any]]');
  assert.match(replace, /records\.removeAll \{ HandsHostAuthority\.same\(\$0\.deviceID, id\) && releasedHosts\.contains\(\$0\.hostname\.lowercased\(\)\) \}/);
  assert.doesNotMatch(code(replace), /removeFirst|evidence != "legacy_host"/);
  assert.match(replace, /if existing\.sameResource\(as: record\) \{ continue \}/, 'identical records are not rewritten (Claude: rewrite every 2 s)');
  assert.match(config, /if lstat\(ownershipURL\.path, &info\) != 0 \{ return errno == ENOENT \? HandsBuildOwnership\(\) : HandsBuildOwnership\(unknown: true\) \}/);
  assert.match(config, /guard !table\.unknown else \{ ownershipProblem = HandsBuildConfigError\.ownershipUnknown\.plain; return \[\] \}/);
  assert.match(setup, /state\.releasedHosts = Array\(list\.suffix\(8\)\)/);
  const list = between(setup, 'private func listUnused(base: [String], home: URL)', 'private func dnsTunnelTargets()');
  assert.match(list, /guard let foreign = dependencies\.foreignTunnels\(\) else \{ recordCategory\("tunnel\.list", "ownership_unknown"\); return \(nil, false\) \}/);
  assert.match(list, /guard let targets else \{ recordCategory\("tunnel\.list", "dns_unknown"\); return \(nil, false\) \}/);
  assert.match(list, /evidence\.contains\(\$0\.id\.lowercased\(\)\) && !foreign\.contains\(\$0\.id\.lowercased\(\)\) && !targets\.contains\(\$0\.id\)/);
  assert.match(setup, /\$0\.createdTunnels = Array\(Set\(\(\$0\.createdTunnels \?\? \[\]\) \+ \[id\.lowercased\(\)\]\)\)\.sorted\(\)   \/\/ W183 R8c：建立證據/);
  assert.match(sync, /guard let copy = ownershipCopy, !copy\.unknown else \{ return nil \}/);
});

// ---------- 7：T12 改寫、AI 工具改不了設定 ----------

test('T12 rewrite: many devices reachable, none can manage others; AI tools cannot change the build config (counter-examples)', () => {
  const t12 = threat.split('\n').find((line) => line.startsWith('| T12 '));
  assert.ok(t12 && t12.includes('不代表任何一台的 ChatGPT 工具能管理、派工或轉送到其他設備'), t12);
  assert.ok(threat.split('\n').some((line) => line.startsWith('| T17 ')), 'T17 settings and mailbox');
  for (const words of ['主設備明文中繼', '主設備被攻陷', '同一個 macOS 使用者身分的惡意程式']) assert.ok(contract.includes(words), words);
  assert.match(contract, /# 11\. ChatGPT build 多設備（W183 R8c/);
  // 外部 AI 仍然只有三個方法；工具清單沒有管理別台的。
  const methods = contractSource.match(/static let externalAIMethods: Set<String> = \[([\s\S]*?)\]/)?.[1].match(/"([^"]+)"/g)?.map((v) => v.slice(1, -1)).sort();
  assert.deepEqual(methods, ['hands_auth', 'hands_call', 'hands_tools']);
  assert.doesNotMatch(code(tools), /hands_build|HandsBuild|DeviceDispatch|dispatch_/);
  assert.doesNotMatch(mcpServer, /hands_build/, 'no OS MCP tool reaches the build config or mailbox');
  assert.match(between(setup, 'enum HandsSetupTool', undefined), /guard keys\.isSubset\(of: \["step", "action", "hostDeviceID"\]\) else \{ throw Failure\.invalid\("unexpected field"\) \}/);
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    assert.doesNotMatch(bridge.match(new RegExp(`static let ${list}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '', /"hands_build"/, list);
  }
});

// ---------- 接口（R8a 的畫面接這裡）與自測 ----------

test('interface: HandsBuild.swift only adds (deviceID on projects, per-device login and unlock with defaults); the controller implements it', () => {
  for (const name of ['var enabled: Bool { get }', 'func setEnabled(_ on: Bool)', 'func setDevice(_ id: String, selected: Bool)', 'func loginCloudflare()',
    'func chooseZone(_ id: String)', 'func setSubdomain(_ label: String, for deviceID: String)', 'func applyURLs()', 'func setLevel(_ level: Int)',
    'func setProject(_ id: String, selected: Bool)', 'func connect(deviceID: String?)']) {
    assert.ok(buildInterface.includes(name), name);
  }
  assert.match(buildInterface, /var deviceID: String\? = nil/);
  assert.match(buildInterface, /extension HandsBuildModeling \{\n\s*func loginCloudflare\(for deviceID: String\) \{ loginCloudflare\(\) \}/);
  assert.match(controller, /final class HandsBuildController: ObservableObject, HandsBuildModeling \{/);
  // 別台的登入網址只開 Cloudflare 授權頁（固定版本 cloudflared 的那一種）。
  assert.match(controller, /if !result\.final, state == "login_url", let raw = object\["url"\] as\? String, let url = HandsCloudflared\.loginURL\(in: raw\) \{/);
  // 最後一則（含「結果未知」）一定收起授權頁。W183 R8 整合（R8b）：授權完成＝分頁標「完成」（頁面關掉、不再算敏感、分頁留著）；
  // 其他（取消、失敗、結果未知）＝分頁收掉——兩條都不留可以操作的登入頁。
  assert.match(controller, /guard result\.final else \{ return \}\n(\s*\/\/[^\n]*\n)*\s*if let opened = logins\.removeValue\(forKey: result\.operationID\)\?\.url \{\n\s*if state == "authorized" \{ dependencies\.markLoginDone\(opened\) \} else \{ dependencies\.closeLogin\(opened\) \}/);
  assert.match(controller, /var markLoginDone: @MainActor \(URL\) -> Void = \{ url in HandsSetup\.postLoginPagesDone\(only: url\) \}/);
  // 未收到回執＝不寫已套用／已關。
  assert.match(controller, /return report\.appliedConfigRevision >= config\.configRevision|return info\.appliedConfigRevision >= config\.configRevision/);
});

test('self-test w183build is registered, isolated, and covers every required scenario', () => {
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w183build"[\s\S]{0,300}HandsBuildAcceptance\.run\(\)/);
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /guard NativeStagingIsolation\.isEnabled\(environment\), NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.doesNotMatch(code(acceptance), /CloudflareKeychain\(\)|CloudflareAccountsStore\.shared|HandsSetup\.shared|URLSession|HandsBuildSync\.shared|HandsBuildAuthority\.shared|\.ssh\/id_/);
  for (const label of ['兩台同時服務', '關 B 不動 A', '舊的啟用晚到', '偽造（別的金鑰簽的）', '回滾（舊版本晚到）', '同一版不同內容', '安全暫停',
    'A 替 B 登入', 'C 拿不到', 'A 替 B 連線', '交換碼卡', '交換 token', '交換 attempt', '環境登入加一個新帳號', '安全停機鎖都還在', '離線 B 的不列',
    'hands_build 只給 SSH 轉進來', '遷移', '同一個主機名不能分給兩台', 'DNS 查不到：整份不列', '取消比登入先到', 'P 重開',
    // W183 R8c 審查：行為驗收（不是原始碼形狀）。
    '零 cloudflared 指令（沒有 route dns）', '先作廢那個設定工作', '拍下的那一份跟 build 給這台的不一樣', '主設備是目標', '人在主設備替 B 登入',
    '回應在路上掉了', 'outbox 下一輪再送', '收成「結果未知」', '快速輪詢只算', '第二件登入（忙碌）不蓋掉第一件', '授權頁只開在 A 的私訊框',
    '沒收到 B 的回執', '連不到，關閉還沒套用', '畫面還沒從主設備拿到設定', '只有「從沒勾變成勾了」才打開這台', '在這台關掉開關＝中央設定也取消勾這台',
    '同一版不收窄', '晚到的舊解除', '這一次的事故編號', '逐欄核對', '升級前的舊 grant', '每台各自單調', '不重驗章', '改設定一定要帶預期版本',
    '沒回報的舊網址照樣是那台的', '所有權表讀不到＝不知道', '不重寫檔案', '安全暫停的收尾', '多久問一次']) {
    assert.ok(acceptance.includes(label), label);
  }
  // 恆真的條件不算驗收（W183 R8c 審查：GPT-6、Claude）。
  assert.doesNotMatch(code(acceptance), /\|\| true\b|&& true\)/);
  // 安全鎖那一段用真的關口（allowUnderTest）、走到 stepStart 叫真的「保留安全鎖」重試。
  assert.match(acceptance, /deps\.allowUnderTest = true/);
  assert.match(acceptance, /setupDeps\.startService = \{ gateway\.retryKeepingSafetyLock\(\) \}/);
});

test('W183 R8c review (Claude): polling only when needed, backoff when offline, no re-verify, no republish, no disk reads in view getters', () => {
  assert.match(sync, /var hot: TimeInterval = 1\.5/);
  assert.match(sync, /var active: TimeInterval = 15/);
  assert.match(sync, /var inactive: TimeInterval = 60/);
  assert.match(sync, /var maxBackoff: TimeInterval = 300/);
  assert.match(sync, /var authorityIdle: TimeInterval = 30/);
  assert.match(sync, /if failures > 0 \{ return min\(intervals\.backoff \* pow\(2, Double\(min\(failures - 1, 10\)\)\), intervals\.maxBackoff\) \}/);
  assert.match(sync, /waiters\.values\.contains \{ now\.timeIntervalSince\(\$0\.submittedAt\) < dependencies\.intervals\.hotWindow \}/);
  // W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的牆上時鐘跳過＝也馬上重發（換成跳之後的一對時間）；其他照舊（沒變不重發、最久 republish 秒一次）。
  assert.match(sync, /if publishedView\.map\(\{ !\$0\.sameContent\(as: view\) \}\) \?\? true \|\| now\.timeIntervalSince\(lastPublishedAt\) >= dependencies\.intervals\.republish\s*\|\| localJumped \{/);
  assert.doesNotMatch(between(controller, 'var localID: String? {', 'var enabled: Bool'), /dependencies\.localID\(\)/, 'localID is cached, not read from disk per render');
  assert.doesNotMatch(between(controller, 'var devices: [HandsBuildDevice] {', 'var selectedDevices'), /pairedDevices\(\)/);
  // 等級與專案：舊畫面改的寫穿到中央（上限跟著這台的選擇走）；關開關也寫穿。
  assert.match(handsState, /nonisolated\(unsafe\) static var onLocalScopeChanged: \(\(Int, \[String\]\) -> Void\)\?/);
  assert.match(setup, /if let local = dependencies\.localDeviceID\(\) \{ dependencies\.buildSwitchedOff\(local\) \}/);
  assert.match(setup, /deps\.buildSwitchedOff = \{ local in HandsBuildSync\.shared\.localSwitchedOff\(local: local\) \}/);
});

// ---------- W183 R8 整合審查（GPT-6 跨引擎＋Claude）：合併之後的界線（行為驗收在 w183build 的 HandsBuildIntegrationReviewAcceptance.swift） ----------

test('W183 R8 integration review: apply pins the seen snapshot; legacy remote setup is not an apply; owner-only login URL; local unlock is incident-bound', () => {
  // 套用：按的時候看到的那一份（主權＋版本）一路帶到送出；送出那一刻不自己讀版本；沒回執不送。
  const submit = between(sync, '    func submit(action: String, target: String', '    /// 送一件、等最後一則結果');
  assert.match(submit, /expected: HandsBuildExpected\? = nil/);
  assert.match(submit, /guard let current, current\.configRevision == expected\.revision, HandsBuildExpected\.authority\(of: current\) == expected\.authority else \{/);
  assert.match(submit, /revision = expected\.revision/);
  assert.doesNotMatch(code(submit), /store\.load\(\)\?\.configRevision \?\? known/, 'no re-read of the revision at send time');
  assert.doesNotMatch(code(between(controller, 'private func checkPendingApply()', 'private func sendApply(')), /applyURLs\(\)/, 'no send-anyway on timeout');
  // 舊的遠端設定 RPC（start_setup／continue_setup＝trigger .remote、不是 applyURLs）：跟自動續跑一樣只照用已經建好的。
  assert.match(setup, /private func legacyRemote\(_ trigger: HandsSetupTrigger\) -> Bool \{\n\s*guard trigger == \.remote else \{ return false \}\n\s*lock\.lock\(\); defer \{ lock\.unlock\(\) \}\n\s*return !applyRun/);
  assert.match(setup, /return trigger == \.resume \|\| trigger == \.assistant \|\| legacyRemote\(trigger\)/);
  assert.match(between(setup, 'private func stepTunnel', 'let state = snapshot'), /if legacyRemote\(trigger\), snapshot\.tunnelID == nil \|\| snapshot\.publicHost == nil \{\n\s*return waitUser\(\.tunnel, Self\.applyFirstMessage\)/);
  assert.equal((setup.match(/apply: true/g) ?? []).length, 2, 'only the two applyURLs entry points mark a job as an apply');
  // 替別台登入：網址只交給擁有者，不發布到那台畫面看的 loginURL；畫面開頁前核這一輪是不是這台自己的。
  assert.match(between(setup, 'private func publishRoundURL(', 'func isLocalLoginPage('), /loginOwnerOnly = remoteLogin != nil\n\s*if !loginOwnerOnly \{ DispatchQueue\.main\.async \{ \[weak self\] in self\?\.loginURL = url \} \}/);
  assert.match(setup, /return loginRound != nil && !loginOwnerOnly && loginURLValue == url/);
  const model = swift('Facade/HandsBuildModel.swift');
  assert.match(model, /case \.openLogin\(let url\):\n\s*\/\/[^\n]*\n\s*guard setup\.isLocalLoginPage\(url\) else \{ notice = HandsBuildCopy\.changed; return false \}/);
  assert.match(model, /if case \.openLogin\(let url\) = action, !setup\.isLocalLoginPage\(url\) \{/);
  // 解除安全鎖（這台）：跟信箱那條同一套核對，不叫不帶事故編號的 retry()。
  assert.doesNotMatch(code(controller), /\.retry\(\)/);
  assert.match(sync, /func unlockHere\(incident: String, setupEpoch: String\?, revocationGeneration: Int\) -> String\? \{/);
  assert.match(between(sync, 'func unlockHere(incident:', '    private func connect(_ intent'), /return dependencies\.unlockSafety\(incident\) \? nil : "incident_changed"/);
});

test('W183 R8 integration review: central cap enforced on every call; narrowing that cannot be saved suspends; no report is not "off"; connect round ends on dismiss', () => {
  // 工具清單、呼叫、授權、啟動、發布都照有效設定（再 ∩ grant）；跑著的工作也看中央等級。
  // W183 R10（取代「本機 ∩ 中央上限」）：有效設定＝中央設定的等級＋這台全部專案（不再 ∩ 本機核准；主機收到就生效）。
  // W183 R11 第二輪（GPT-6 R11 審查 1）：有效設定照舊＝中央設定（不跟本機取小、不 ∩ 本機核准）；中央等級一變先把現有的 grant 封頂才生效
  //（levelGuard）。原本的一行寫法拆開了，守的一樣。
  const effectiveBody = between(service, 'func effectiveSettings() -> HandsSettings {', '/// 這台上一次生效的中央等級');
  assert.match(effectiveBody, /let effective = local\.centralized\(by: cap\)/);
  assert.match(effectiveBody, /if cap != nil \{ levelGuard\(central: effective\.level, local: local\.level\) \}\s*return effective/);
  assert.doesNotMatch(code(effectiveBody), /min\(|allowedProjectIDs/);
  assert.match(between(service, 'func handle(method: String', 'private func authorized('), /let current = effectiveSettings\(\)/);
  assert.match(between(service, 'func admissionProblem(', '/// 給 HandsSandbox.run 的 admit'), /let current = effectiveSettings\(\)/);
  assert.match(jobs, /if service\.capProblem\(level: 2, projectID: workspace\.record\.projectID\) != nil \{/);
  const cap = between(swift('Facade/HandsSettings.swift'), 'func centralized(by cap:', '/// 真正比對用的清單');
  assert.match(cap, /if let cap \{ copy\.level = min\(max\(cap\.level, 0\), Self\.maxLevel\) \}\s*copy\.allProjects = true/);
  assert.doesNotMatch(cap, /allowedProjectIDs|min\(level,/, 'no local approval in the effective scope');
  // 收窄沒存成＝跑著的工作收掉、不 resume。
  const reconcile = between(sync, 'struct HandsBuildReconciler', 'final class HandsBuildExecutor');
  assert.match(reconcile, /\} catch \{\n\s*failed = true[\s\S]*?\{ suspend\(\) \}\n\s*\}\n\s*serviceChanged\(\)\n\s*if slice\.active, !failed \{ resume\(\) \}/);
  // 回報實際生效的範圍；關掉的回執（撤銷世代）。
  // W183 R11 第二輪（GPT-6 R11 審查 1）：回報先拿有效設定（中央等級變了＝先封頂），中間讀 grant 的等級，再寫 report.level（照舊是有效設定的等級）。
  const reportBody = between(sync, 'let effective = service.effectiveSettings()', 'report.projectChoices = service.buildProjectChoices()');
  assert.match(reportBody, /report\.level = effective\.level/);
  assert.match(sync, /report\.appliedGeneration = appliedRecord\?\.revocationGeneration \?\? 0/);
  // 沒有回報＝不知道（只有從沒跑過才算關）；有回報也要是套用過這次關掉的回執。
  const off = between(controller, 'private func offState(_ id: String)', 'var devices: [HandsBuildDevice]');
  assert.match(off, /guard let info = self\.report\(id\) else \{\n\s*let neverRan = /);
  assert.match(off, /return neverRan \? \.off : \.waiting/);
  assert.match(off, /let receipt = info\.appliedGeneration\.map \{ \$0 >= generation \}/);
  // ［連線］：卡片取消＝這一輪結束；沒真的開始＝不佔著。
  assert.match(connect, /closedByUser \+= 1/);
  assert.match(connect, /func offer\(target: String\?, preset: HandsScopeChoice\? = nil\) -> Bool \{/);
  // W183 R10：［連線］不帶面板上的範圍（preset: nil）；卡片取消照舊結束這一輪。
  assert.match(controller, /guard dependencies\.flow\.offer\(target: target, preset: nil\) else \{\n\s*connecting = nil\n\s*connectQueue = \[\]/);
  assert.match(controller, /dependencies\.flow\.\$closedByUser\.dropFirst\(\)\.sink/);
  assert.match(between(connect, '    func offer() {', 'private func clearChoice()'), /targetDeviceID = nil\n\s*presetChoice = nil/);
  assert.match(selftest + swift('Facade/HandsBuildAcceptance.swift'), /try await integrationReviewChecks\(check, base, keys\)/);
});

test('privacy: no private terms (docs/private-privacy-terms.txt) and no hardcoded device names in the new sources', () => {
  const terms = read('docs/private-privacy-terms.txt').split('\n').filter((line) => line.includes(' | ') && !/^\s*(#|except)/.test(line))
    .map((line) => new RegExp(line.split(' | ')[1].trim(), 'i'));
  assert.ok(terms.length >= 5, 'terms file read');
  for (const source of [config, envelope, mailbox, sync, controller, acceptance]) {
    for (const term of terms) assert.doesNotMatch(source, term, String(term));
    assert.doesNotMatch(source, /MacBook|\bmini\b/, 'no hardcoded device names');
  }
});
