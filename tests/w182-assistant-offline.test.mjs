import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W182 R5（使用者 09-27：「如果主設備斷線呢？我的 macbook 就完全變空白傻傻的是嗎？」→「好 照這樣做」）：
// 主設備斷線時助理在這台接著聊（第一句帶前情）、連回補回主設備那條；要主設備才能做的事先排隊、連回依序送出；
// 頂端一行離線狀態。原始碼契約；實際行為在 App 自測 w182assistoffline（lead-verify）。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('offline handoff: the local assistant runs here and its first turn carries the primary context once', () => {
  const model = read('Facade/ChatPageModel.swift');
  const send = slice(model, 'func sendToAssistant', 'func sendAssistantDraft');
  assert.match(send, /case \.local:\s*let offlineTurn = assistantOfflineBeginTurn\(\)[^\n]*\n\s*let accepted = sendToLocalAssistant\(text: text, attachments: attachments(, onUndelivered: onUndelivered)?\)\s*assistantOfflineEndTurn\(offlineTurn, accepted: accepted\)/);
  // W179 F 的擺放照舊：主設備連得到就用主設備那條；剛才離線那段還沒補回時先補完再送（時序才對），補不成不送、草稿留著。
  assert.match(send, /case \.primary\(let remote, let primaryThreadID, let device\):\s*if assistantOfflineMergeOutstanding\(device\) \{[^\n]*W182 R5[^\n]*\n\s*return assistantOfflineDeliverAfterMerge\(device\) \{ \[weak self\] in\s*_ = self\?\.sendToAssistant\(text: text, attachments: attachments, onDelivered: onDelivered\)\s*\}\s*\}\s*return sendToPrimaryAssistant/);
  assert.match(slice(model, 'var assistantCanSend: Bool {', '\n    }\n'), /return !primaryDeliveries\.contains\(id\) && !assistantOfflineHolding/);
  assert.match(slice(model, 'var assistantIsDelivering: Bool {', '\n    }\n'), /primaryDeliveries\.contains\(id\) \|\| assistantOfflineHolding/);
  // 主設備那條一有更新就記前情、連回就補回／送出（跟原本重畫同一個地方）。
  assert.match(model, /if session\.device\.id == self\.assistantPrimaryDevice\?\.id \{ self\.primaryOfflineTick\(\) \}/);
  // 記前情只用 get_document 已經帶回來的那條紀錄：不另外拉逐字稿（每次換版都經 SSH 重拉、主執行緒解碼）。
  const tick = slice(read('Facade/PrimaryOfflineSync.swift'), 'func primaryOfflineTick() {', '\n    }\n');
  assert.match(tick, /engine\.threadRecord\(id\) \{\s*AssistantPrimaryContextMemory\.shared\.remember\(deviceID: link\.device\.id, record: record\)/);
  assert.doesNotMatch(tick, /primaryTranscript|\.transcript\(for:/);

  const handoff = read('Facade/AssistantOfflineHandoff.swift');
  const begin = slice(handoff, 'func assistantOfflineBeginTurn()', '\n    }\n');
  assert.match(begin, /guard let link = primaryLinkState\(\), link\.engine == nil, !link\.connecting/);
  assert.match(begin, /\?\.seeded != true/, 'only the first turn of a stretch is seeded');
  assert.match(begin, /AssistantOfflineContext\.source\.recentPrimaryAssistantMessages\(deviceID: link\.device\.id\)/);
  const seed = slice(handoff, 'enum AssistantOfflineSeed', '\n}\n');
  assert.match(seed, /CoderImport\.seedPrompt\(rows: seed\.rows, sourceLabel: seed\.label, userText: userText\)/);
  assert.match(seed, /armed\.removeValue\(forKey: threadID\)/, 'taken once');
  const end = slice(handoff, 'func assistantOfflineEndTurn(', '\n    }\n');
  assert.match(end, /AssistantOfflineSeed\.disarm\(turn\.threadID\)/);
  // 前情只來自介面（記憶體那份；R4 快照併入後換實作），這房不自己存一份到磁碟。
  assert.match(handoff, /protocol AssistantPrimaryContextSource: AnyObject/);
  const memory = slice(handoff, 'final class AssistantPrimaryContextMemory', '\n}\n');
  assert.doesNotMatch(memory, /FileManager|\.write\(|Data\(contentsOf/);
  assert.match(memory, /guard stamps\[key\] != stamp else \{ return \}/, 'unchanged thread: no recompute');

  // 引擎那一側：組要送的字時拿走前情（不顯示在對話裡），在匯入前情與計畫之間。
  const engine = read('Facade/ChatLiveEngine.swift');
  const sendBody = slice(engine, '@discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind = .claude', 'func savePastedAttachment');
  assert.match(sendBody, /append\(threadID, ChatMessage\(role: \.user, text: shown, turnID: turn\), source: source\)[\s\S]*if let seeded = AssistantOfflineSeed\.take\(threadID, userText: outgoing\) \{ outgoing = seeded \}[\s\S]*if let planBriefing/);
  // 主設備那一側：補回的那段引擎沒看過，下一句帶上（資料不是指令，只帶一次；沒有別的前情時才帶）。
  assert.match(sendBody, /if outgoing == engineText, let caughtUp = offlineCatchUpSeed\(threadID: threadID, currentTurn: turn, userText: engineText\) \{\s*outgoing = caughtUp[\s\S]*if let planBriefing/);
  const catchUp = slice(handoff, 'func offlineCatchUpSeed(', '\n    }\n');
  assert.match(catchUp, /guard doc\.isAssistantThread\(threadID\) else \{ return nil \}/);
  assert.match(catchUp, /guard message\.id\.hasPrefix\(AssistantOfflineWire\.rowIDPrefix\) else \{ break \}/, 'only rows after the last turn the engine saw');
  assert.match(catchUp, /CoderImport\.seedPrompt\(rows: unseen\.reversed\(\), sourceLabel: Self\.offlineCatchUpLabel, userText: userText\)/);
  assert.doesNotMatch(catchUp, /FileManager|\.write\(|send\(/);
});

test('offline stretch merges back into the primary thread: text and time only, marked, deduped, no engine', () => {
  const handoff = read('Facade/AssistantOfflineHandoff.swift');
  const wire = slice(handoff, 'enum AssistantOfflineWire', '\n}\n');
  assert.match(wire, /static let method = "assistant_append_offline"/);
  assert.match(wire, /private static let keys: Set<String> = \["requestID", "threadID", "device", "rows"\]/);
  assert.match(wire, /guard Set\(row\.keys\) == \["role", "text", "createdAt"\]/);
  assert.match(wire, /role == "user" \|\| role == "assistant"/);
  assert.match(wire, /static func marker\(_ device: String\) -> String \{ "〔在「\\\(device\)」離線時〕" \}/);
  assert.match(wire, /static let rowIDPrefix = "offline:"/);
  assert.match(wire, /let prefix = rowIDPrefix \+ "\\\(request\.requestID\.uuidString\.lowercased\(\)\):"/, 'row ids come from the request id');
  const receive = slice(handoff, 'func receiveAssistantOfflineAppend(', '\n    }\n');
  assert.match(receive, /let id = assistantThreadID, id == request\.threadID,\s*engine\.doc\.isAssistantThread\(id\)/, 'only the assistant thread');
  assert.match(receive, /guard !engine\.isRunning\(id\) else \{ throw AssistantOfflineWire\.Failure\.busy \}/);
  assert.match(receive, /engine\.appendOfflineRows\(threadID: id, rows: AssistantOfflineWire\.messages\(request\)\)/);
  assert.doesNotMatch(receive, /engine\.send\(|live\.send\(|sendToLocalAssistant|receiveAssistantTurnFromSecondary/, 'never triggers an engine');

  const engine = read('Facade/ChatLiveEngine.swift');
  const append = slice(engine, 'func appendOfflineRows(threadID: UUID, rows: [ChatMessage]) -> Int {', '\n    }\n');
  assert.match(append, /!runningThreads\.contains\(threadID\)/);
  assert.match(append, /let fresh = rows\.filter \{ !existing\.contains\(\$0\.id\) \}/, 'resend adds nothing');
  assert.match(append, /persist\(\)/);
  assert.doesNotMatch(append, /ensureSidecar|sidecar|\.send\(/);

  const merge = slice(handoff, 'func mergeAssistantOfflineStretches(', '\n    // MARK: 連回後的新一句');
  assert.match(merge, /guard !local\.isRunning\(list\[index\]\.localThreadID\) else \{ continue \}/, 'closes a stretch only after the local turn ends');
  assert.match(merge, /let chunks = AssistantOfflineWire\.chunks\(rows\)/, 'a long stretch goes in parts');
  assert.match(merge, /AssistantOfflineWire\.params\(requestID: AssistantOfflineWire\.requestID\(stretch\.id, chunk: index\),/, 'same request ids on every retry');
  assert.match(merge, /for index in min\(stretch\.mergedChunks \?\? 0, chunks\.count\)\.\.<chunks\.count/, 'parts already sent are not sent again');
  assert.match(merge, /text: "已補回「\\\(device\.displayName\)」/); // W201：原始同步資料保留，顯示投影過濾這則報備。
  assert.match(merge, /if failure\.isOldPeer \{[^\n]*\n[^\n]*\n\s*if stretch\.state != \.legacy \{ report\.legacy = true \}\s*update\.state = \.legacy/, 'older primary is tracked once; W201 does not display its automatic retries');
  assert.match(merge, /還沒更新，這段先留在這台/);
  assert.match(merge, /stop = true/, 'a failed merge stays for next time');
  const rows = slice(handoff, 'static func assistantOfflineRows(', '\n    }\n');
  assert.match(rows, /message\.role == \.user \|\| message\.role == \.assistant, message\.eventKind == \.message/);
  assert.doesNotMatch(rows, /suffix\(AssistantOfflineWire\.maxRows\)/, 'no row is dropped');
  const wireChunks = slice(handoff, 'static func chunks(', '\n    }\n');
  assert.match(wireChunks, /current\.count >= maxRows \|\| bytes \+ size > maxTotalBytes/);
  // 連回後的新一句：等補回（最多幾次），補不成不送。
  const hold = slice(handoff, 'func assistantOfflineDeliverAfterMerge(', '\n    }\n');
  assert.match(hold, /await self\.primaryOfflineSyncSettled\(\)[\s\S]*_ = await self\.primaryOfflineSyncNow\(\)[\s\S]*guard !self\.assistantOfflineMergeOutstanding\(device\) else \{ return \}\s*send\(\)/);
  assert.match(slice(handoff, 'func assistantOfflineMergeOutstanding(', '\n    }\n'), /\(stretch\.attempts \?\? 0\) < AssistantOfflineStretch\.holdAttempts/);

  const bridge = read('Facade/OSAgentBridge.swift');
  const list = (name) => bridge.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
  assert.ok(list('sshForwardMethods').includes('"assistant_append_offline"'));
  assert.ok(!list('untrustedCallerMethods').includes('"assistant_append_offline"'));
  assert.ok(!list('stagingReadOnlyMethods').includes('"assistant_append_offline"'));
  assert.match(bridge, /if method == AssistantOfflineWire\.method \{ return caller == \.ssh \}/);
  const handler = slice(bridge, 'case AssistantOfflineWire.method:', 'case "project_overview"');
  assert.match(handler, /let request = try AssistantOfflineWire\.parse\(params\)/);
  assert.match(handler, /model\.receiveAssistantOfflineAppend\(request\)/);
});

test('W201 automatic assistant fallback is quiet; blocked actions stay at the composer', () => {
  const pane = read('Assistant/AssistantSpacePane.swift');
  assert.doesNotMatch(pane, /Label\(line, systemImage: "wifi\.slash"\)/);
  assert.match(pane, /placementNote: model\.assistantPlacementNote/);
  const model = read('Facade/ChatPageModel.swift');
  const note = slice(model, 'var assistantPlacementNote: String? {', '\n    }\n');
  assert.match(note, /case \.primary: return assistantPrimaryHint == nil \? assistantOfflineLine : nil/);
  assert.doesNotMatch(note, /localFallbackNote/);
  const handoff = read('Facade/AssistantOfflineHandoff.swift');
  assert.match(handoff, /if assistantOfflineHandoffActive \{ return nil \}/);
  assert.match(handoff, /assistantDeliveryBlocked == true/);
});

test('primary outbox: three actions only, atomic file, in-order flush through the original methods', () => {
  const outbox = read('Facade/PrimaryOutbox.swift');
  assert.match(outbox, /static let fileName = "primary-outbox\.json"/);
  assert.match(outbox, /try\? data\.write\(to: url, options: \.atomic\)/);
  const kinds = slice(outbox, 'enum Kind: String, Codable, CaseIterable, Sendable {', 'var allowedKeys');
  assert.deepEqual([...kinds.matchAll(/case (\w+) = "([^"]+)"/g)].map((m) => m[2]).sort(),
    ['distill_write', 'memory_decide', 'project_proposal_decide']);
  assert.match(outbox, /guard Set\(params\.keys\) == kind\.allowedKeys else \{ return false \}/);
  assert.match(outbox, /init\(from decoder: Decoder\) throws \{ item = try\? PrimaryOutboxItem\(from: decoder\) \}/, 'unknown kinds are dropped');
  // 讀寫都在背景佇列：主執行緒不碰磁碟。
  const file = slice(outbox, 'final class PrimaryOfflineJSONFile', '\n}\n');
  assert.match(file, /queue\.async \{\s*guard let data = try\? Data\(contentsOf: url\)/);
  assert.match(file, /queue\.async \{\s*try\? FileManager\.default\.createDirectory/);

  const sync = read('Facade/PrimaryOfflineSync.swift');
  const flush = slice(sync, 'func flushPrimaryOutbox(', '\n    private func sendPrimaryOutboxItem');
  assert.match(flush, /for item in outbox\.items where item\.isWaiting && item\.handedOver != true \{/, 'in queue order');
  assert.match(outbox, /items = kept \+ \[item\]/, 'new items go to the end');
  assert.match(flush, /guard !held\.contains\(item\.kind\) else \{ continue \}/, 'keeps order within a kind: later items of that kind wait');
  assert.match(flush, /case \.retry\(let reason\):\s*outbox\.deferRetry\(item\.id, reason: reason\)\s*held\.insert\(item\.kind\)/, 'one stuck item does not block other kinds');
  assert.match(flush, /if !ignoreBackoff, let after = item\.retryAfter, after > Date\(\) \{/, 'waits out the retry delay');
  assert.match(flush, /case \.refused\(let reason, let terminal\):\s*outbox\.mark\(item\.id, state: \.failed, reason: reason, refused: true, terminal: terminal\)/);
  assert.match(slice(outbox, 'func deferRetry(', '\n    }\n'), /min\(600, 10 \* pow\(2/);
  const send = slice(sync, 'private func sendPrimaryOutboxItem(', '\n    /// 記憶提案核准');
  assert.match(send, /awaitPrimaryCall\(transport, "project_proposal_decide", params\)/);
  assert.match(send, /sendQueuedDistill\(item\)/);
  // 記憶提案：主設備回「不能做」、這台還沒配好的標失敗寫原因（不重試、不卡住後面）；只有連線類才再送。
  const memoryCase = slice(send, 'case .memoryDecide:', 'case .classifyDecide:');
  assert.match(memoryCase, /primaryOutbox\?\.noteMemoryDecided\(id: id, accept: accept\)/);
  assert.match(memoryCase, /if failure\.isLocalSetup \{\s*return \.refused\(/);
  assert.match(memoryCase, /if failure\.remote \{ return \.refused\(/);
  assert.match(memoryCase, /return \.retry\("連線不穩"\)\s*$/);
  assert.match(sync, /static let localSetupCodes: Set<String> = \["primary_not_paired", "authority_unknown"\]/);
  assert.match(sync, /var isRetryable: Bool \{ !remote && !isLocalSetup \}/);
  // W201：自動補回、排隊送出與拒收不另外跳 Island，拒收由同一份處理提示呈現。
  const memory = slice(sync, 'private func primaryMemoryDecide(', '\n    }\n');
  assert.match(memory, /UserMemoryStore\.shared\.flushOutbox\(\)[\s\S]*UserMemoryStore\.shared\.decide\(id: id, accept: accept, isPublic: isPublic\)/);
  // 記憶核准照 E1 的簽章呼叫，經 serializedRPC 排成一列。
  assert.match(read('Facade/UserMemory.swift'), /dispatch\.callPrimary\(method: "memory_decide"/);
  assert.match(slice(read('Facade/DeviceDispatch.swift'), 'func callPrimary(method: String', '\n    }\n'), /serializedRPC/);
  assert.doesNotMatch(sync, /IslandNotice\.shared\.info/);
  // RemoteHostLink 不在主執行緒跑。
  assert.match(slice(sync, 'nonisolated static func primaryLinkTransport(', '\n    // MARK: 連線有變化'), /Task\.detached\(priority: \.userInitiated\)[\s\S]*link\.call\(method: method, params: object\)/);
});

test('the three actions queue offline and can be cancelled', () => {
  const distill = read('Facade/ChatPageModel+Distill.swift');
  assert.match(distill, /case queued\(name: String\)/);
  assert.match(distill, /if distillQueueAvailable \{ return \.queued\(name: primary\.name\) \}\s*return \.blocked\("主設備連不上，連上後再寫入"\)/);
  const queuedSend = slice(distill, 'func sendQueuedDistill(', '\n    }\n}');
  assert.match(queuedSend, /method: "distill_write", planID: planID, output: output, action: \.preview, content: content/, 'the primary previews again');
  assert.match(queuedSend, /fresh\.targets\.contains\(where: \{ \$0\.action == \.replace \}\)/, 'never overwrites a same-name file the user did not see');
  assert.match(queuedSend, /self\.sendToPrimaryDistill\(transport, apply, query: query/);
  assert.match(distill, /snapshot\.status = "queued"/);
  const actions = read('Chat/DistillPlanActions.swift');
  assert.match(actions, /case "queued"\?:[\s\S]{0,200}chip\("取消排隊"/);
  assert.match(actions, /按「確認寫入」後會在/); // W201：只說動作目的，不報備設備連線。

  const classify = read('Assistant/AssistantClassificationSection.swift');
  const decide = slice(classify, 'func decideRemote(', 'guard busy.insert(id).inserted');
  assert.match(decide, /deviceID\.lowercased\(\) == model\.assistantPrimaryDevice\?\.id\.lowercased\(\)/, 'only the primary queues');
  assert.match(decide, /enqueueClassification\(deviceID: deviceID, id: id, action: action\.rawValue/);
  assert.match(decide, /message = nil/); // W201：自動排隊安靜。
  assert.match(classify, /OSChipButton\(title: item\.refused == true \? "移除" : "取消"\)/);

  const memory = read('New/OSDocumentsCard.swift');
  const view = slice(memory, 'struct MemoryProposalsView: View {', 'private func importClaude()');
  assert.match(view, /if offline, let outbox = PrimaryOutbox\.main \{\s*if outbox\.enqueueMemoryDecide\(/);
  assert.match(view, /message = "" \/\/ W201/);
  assert.match(view, /outbox\?\.cancel\(queued\.id\)/);
  assert.match(view, /if queueable, failure\.isRetryable, let outbox = PrimaryOutbox\.main,/, 'only connection problems queue from the online path');
  // 排著的核准送到了：不管畫面是不是離線時打開的，一律重讀；收下的連 user.md 一起重讀。
  assert.match(view, /publisher\(for: PrimaryOutbox\.memoryDecided\)\) \{ note in[\s\S]{0,300}refresh\(\)\s*if note\.userInfo\?\["accept"\] as\? Bool == true \{ onAccepted\(\) \}/);
  assert.doesNotMatch(view, /!offline \{ refresh\(\) \}/);
  // 頂端那行的取消：/蒸餾 寫入走畫布那條（畫布一起解鎖）。
  const banner = read('New/PrimaryOfflineBanner.swift');
  assert.match(banner, /model\.cancelPrimaryOutboxItem\(item\)/);
  assert.doesNotMatch(banner, /outbox\.cancel\(/);
  const cancel = slice(read('Facade/PrimaryOfflineSync.swift'), 'func cancelPrimaryOutboxItem(', '\n    }\n');
  assert.match(cancel, /item\.kind == \.distillWrite[\s\S]*return cancelQueuedDistill\(planID, submissionID: submissionID\)/);
});

test('W201 top line: refused actions only, shared settings list, expandable glass', () => {
  const shell = read('Shell/AppShell.swift');
  assert.match(shell, /if surface == \.window \{\s*PrimaryOfflineBannerHost\(model: chatModel, rightPanelOpen: isRightPanelOpen\)\s*\}/);
  assert.doesNotMatch(shell, /PrimaryOfflineBannerHost\([^)]*\)\s*\.padding\(\.top, WindowChromeMetrics\.bandHeight/, 'not laid over the content');
  const sync = read('Facade/PrimaryOfflineSync.swift');
  assert.ok(sync.includes('"有 \\(failed.count) 件沒送到「\\(name)」：按一下處理"'));
  assert.match(slice(sync, 'var primaryOfflineBanner: PrimaryOfflineBannerState? {', '\n    }\n'), /guard let state = primaryOfflineDetails, !state\.failed\.isEmpty else \{ return nil \}/);
  const banner = read('New/PrimaryOfflineBanner.swift');
  assert.match(banner, /最後連上：/);
  assert.match(banner, /\.liquidGlassSurface\(/);
  // 放在紅綠燈那一列：左讓紅綠燈與側欄、右讓頂右鈕（右側面板、並排瀏覽器開著再多讓）；展開的清單用 popover，不蓋內容。
  const host = slice(banner, 'struct PrimaryOfflineBannerHost: View {', '\nstruct PrimaryOfflineBanner: View {');
  assert.match(host, /static let leadingReserve = WorkspaceSidebarMetrics\.width \+ ChatPage\.sidebarPinButtonReserve/);
  assert.match(host, /static let topInset = WindowChromeMetrics\.trafficLightTopInset \+ WindowChromeMetrics\.nativeTrafficLightDiameter \/ 2 - height \/ 2/);
  assert.match(host, /Spacer\(minLength: Self\.leadingReserve\)[\s\S]*Spacer\(minLength: trailing\)/);
  assert.match(banner, /\.popover\(isPresented: \$expanded, arrowEdge: \.bottom\)/);
  assert.match(banner, /ViewThatFits\(in: \.horizontal\) \{\s*lineLabel\(state\.line\)\s*lineLabel\(state\.shortLine\)/);
  for (const file of ['New/PrimaryOfflineBanner.swift', 'Facade/PrimaryOutbox.swift', 'Facade/PrimaryOfflineSync.swift',
    'Facade/AssistantOfflineHandoff.swift']) {
    assert.doesNotMatch(read(file), /\.blue\b|accentColor|borderedProminent|NSAlert|\.alert\(/, file);
  }
});

test('engine-disable settings are never written by W182 R5 code', () => {
  for (const file of ['Facade/PrimaryOutbox.swift', 'Facade/PrimaryOfflineSync.swift', 'Facade/AssistantOfflineHandoff.swift',
    'New/PrimaryOfflineBanner.swift', 'Facade/PrimaryOfflineAcceptance.swift']) {
    assert.doesNotMatch(read(file), /EngineDisableStore\.set|disabledEngines"\)|\.set\([^)]*disableKey/, file);
  }
});

test('W182 R5 edits in shared files are small, marked insertion points', () => {
  for (const [file, min] of [['Facade/ChatPageModel.swift', 3], ['Facade/OSAgentBridge.swift', 4], ['Shell/AppShell.swift', 1],
    ['Assistant/AssistantSpacePane.swift', 2], ['Facade/ChatLiveEngine.swift', 2], ['SelfTest.swift', 1]]) {
    const count = read(file).split('W182 R5').length - 1;
    assert.ok(count >= min, `${file}: ${count} markers`);
  }
  // R4 的檔（Coder 側欄離線快照）這房不碰。
  const r4 = ['New/RemoteDevicesSidebarSections.swift', 'Facade/RemoteDeviceSession.swift', 'Facade/RemoteLiveEngine.swift'];
  for (const file of r4) assert.doesNotMatch(read(file), /W182 R5/, file);
  assert.ok(!readdirSync(new URL('../App/Sources/Tatwo2/Facade/', import.meta.url)).includes('RemoteOfflineCache.swift')
    || !read('Facade/RemoteOfflineCache.swift').includes('W182 R5'));
});
