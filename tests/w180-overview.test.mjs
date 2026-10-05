import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W180 E2：TATWO Space「全域狀態」「專案地圖」＋分頁骨架＋overview_snapshot 的原始碼契約。
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};
const writes = /\.update\(|\.save\(|\bsend\(|archive\(|\.delete\(|removeItem|\.write\(/;

test('tab skeleton: one enum and store, host switches pages, ChatPageModel untouched', () => {
  const tabs = read('Assistant/AssistantSpaceTabs.swift');
  assert.match(tabs, /enum AssistantSpaceTab: String, CaseIterable, Identifiable, Sendable \{\s*case conversation, memory, status, projectMap, team/);
  assert.match(tabs, /final class AssistantSpaceTabStore: ObservableObject \{\s*static let shared = AssistantSpaceTabStore\(\)/);
  assert.match(tabs, /@Published private\(set\) var selected: AssistantSpaceTab = \.conversation/);
  // W180 E1：記憶頁接上了，只剩團隊點不了。
  assert.match(tabs, /case \.team: "之後"\s*case \.conversation, \.memory, \.status, \.projectMap: nil/);
  assert.match(tabs, /guard tab\.isSelectable, selected != tab else \{ return \}/);
  const host = slice(tabs, 'struct AssistantSpaceTabHost', 'struct AssistantSpaceTabChips');
  assert.match(host, /switch tabs\.selected \{\s*case \.conversation:\s*conversation\(\)\s*case \.status:\s*AssistantStatusPage\(model: model\)\s*case \.projectMap:\s*AssistantProjectMapPage\(model: model\)\s*case \.memory:\s*TatwoMemoryPage\(model: model\)[^\n]*\s*case \.team:/);
  assert.match(host, /if showsTabChips \{\s*AssistantSpaceTabChips\(tabs: tabs\)/);
  assert.match(host, /\.onAppear \{ tabs\.returnToConversation\(\) \}/);
  assert.match(host, /\.onReceive\(model\.\$mode\.dropFirst\(\)\) \{ tabs\.modeAssigned\(\$0\) \}/);
  assert.match(host, /\.onChange\(of: model\.selectedThreadID\) \{ _, threadID in\s*tabs\.selectedThreadChanged\(threadID, assistantThreadID: model\.assistantThreadID\)/);
  const chips = slice(tabs, 'struct AssistantSpaceTabChips', 'struct AssistantSpacePlaceholderPage');
  assert.match(chips, /ForEach\(AssistantSpaceTab\.allCases\)/);
  assert.match(chips, /\.chatGlassChip\(isSelected: selected\)/);
  assert.match(chips, /\.disabled\(!tab\.isSelectable\)/);
  for (const file of ['Facade/ChatPageModel.swift', 'Facade/ChatLiveEngine.swift', 'Facade/ChatLiveStore.swift']) {
    assert.doesNotMatch(read(file), /AssistantSpaceTab|AssistantOverview/, file);
  }
});

test('sidebar rows come from the tab enum (same source as the header chips); team disabled (memory opened by E1)', () => {
  const sidebar = read('Assistant/AssistantSidebarList.swift');
  assert.match(sidebar, /@ObservedObject private var tabs = AssistantSpaceTabStore\.shared/);
  // 一份資料：E1 只改 enum 的 stageNote，側欄與頁首 chip 一起開。
  assert.match(sidebar, /ForEach\(AssistantSpaceTab\.allCases\) \{ tab in\s*if tab\.isSelectable \{\s*tabRow\(tab\)\s*\} else \{\s*placeholder\(tab\.title, symbol: tab\.symbol, stage: tab\.stageNote \?\? ""\)/);
  assert.match(sidebar, /Label\(tab\.title, systemImage: tab\.symbol\)/);
  assert.doesNotMatch(sidebar, /tabRow\("|placeholder\("/, 'no hand-written rows');
  const tabs = read('Assistant/AssistantSpaceTabs.swift');
  for (const [tab, title, symbol] of [['conversation', '對話', 'bubble.left.and.bubble.right'], ['memory', '記憶', 'brain'],
    ['status', '全域狀態', 'chart.bar'], ['projectMap', '專案地圖', 'map'], ['team', '團隊', 'person.2']]) {
    assert.ok(tabs.includes(`case .${tab}: "${title}"`), title);
    assert.ok(tabs.includes(`case .${tab}: "${symbol}"`), symbol);
  }
  assert.match(sidebar, /\.disabled\(true\)/);
  assert.match(sidebar, /Button \{ tabs\.select\(tab\) \}/);
  assert.match(sidebar, /\.chatMenuRowHover\(isSelected: isSelected\)/);
  assert.doesNotMatch(sidebar, /selectedThreadID|model\./);
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.match(panels, /if model\.mode == \.tatwo \{[^\n]*\n[^\n]*W180 E2[^\n]*\n\s*AssistantSpaceTabHost\(model: model, showsTabChips: isPanel \|\| !isChatProjectRailPinned\) \{ AssistantSpacePane\(model: model\) \}/);
});

test('pure projection: no writes, files, network or message content; Island classification, not re-derived', () => {
  const overview = read('Assistant/AssistantOverview.swift');
  assert.doesNotMatch(overview, writes);
  assert.doesNotMatch(overview, /link\.call|transcript\(|\.text\b|FileManager|contentsOf|URLSession|ThreadGoalStore\.shared|DispatchQueue/);
  // 訊息只看最後一則的狀態（同 os_status 的「上一輪出錯」），不讀內容。
  assert.equal((overview.match(/\.messages/g) ?? []).length, 1);
  assert.match(overview, /thread\.messages\.last\?\.status\?\.hasPrefix\("error"\) == true && now\.timeIntervalSince\(thread\.updatedAt\) < 7 \* 86_400/);
  assert.doesNotMatch(overview, /\.cwd|workdir:|\.workdir|roomBrief|userWords|evidence|\.host\b|\.user\b|Fingerprint/);
  const status = slice(overview, 'static func deviceStatus(', 'static func coderThreads(');
  assert.match(status, /IslandWorkProvider\.project\(threads: threads, pending: input\.pending \?\? \[\], running: input\.running,\s*bots: \.init\(\), jobs: \[\], now: now, limit: nil\)/);
  assert.match(status, /status\.awaiting = input\.pending == nil \? nil : awaiting/);
  assert.match(status, /case \.awaitingApproval: awaiting\.append\(entry\)/);
  // 同 os_status：巡檢標 stalled 的算卡住；另外補 Island 不列的「已自動停止」「上一輪出錯」。
  assert.match(status, /case nil:\s*guard !entry\.isAssistant else \{ break \}[\s\S]*if thread\.subStatus == "stalled" \{ status\.stalled\.append\(row\(thread, stage: watchdogStage/);
  assert.match(status, /for thread in threads where !classified\.contains\(thread\.id\) \{\s*let stalled = thread\.subStatus == "stalled"\s*guard stalled \|\| endedWithRecentError\(thread, now: now\) else \{ continue \}/);
  // 在跑的定義同 Island／遠端引擎：引擎在跑，或房間 subStatus running。
  assert.match(overview, /running\.contains\(thread\.id\) \|\| thread\.subStatus == "running"/);
  assert.match(overview, /runningCount: threads\.filter \{ isRunning\(\$0, running: running\) \}\.count/);
  assert.match(overview, /doc\.threads\.filter \{ !\$0\.isArchived \}/);
  assert.match(overview, /projectID != doc\.assistantProjectID/);
  assert.match(overview, /static let generalProjectName = "聊天"/);
  assert.match(overview, /thread\.parentThreadID\.flatMap \{ threads\[\$0\]\?\.projectID \} \?\? thread\.projectID/);
  // 離線：只剩名稱與數量，最後活動不拿 lastSeenAt 冒充。
  const snapshot = slice(overview, 'static func snapshotProjects(', '// MARK: - 遠端摘要');
  assert.match(snapshot, /lastActivity: nil/);
  assert.doesNotMatch(snapshot, /lastSeenAt/);
  // 看不到就寫看不到＋原因。
  assert.match(overview, /static func unseen\(_ reason: String\) -> String \{ "看不到（\\\(reason\)）" \}/);
  assert.match(overview, /還沒更新，更新後就看得到/);
  assert.doesNotMatch(overview, /\bmini\b/i);
});

test('overview_snapshot wire is an explicit allowlist and the bridge serves it to paired devices only', () => {
  const overview = read('Assistant/AssistantOverview.swift');
  const allowed = slice(overview, 'static let allowedKeys: Set<String> = [', ']');
  for (const forbidden of ['"text"', '"content"', '"cwd"', '"path"', '"host"', '"user"', '"messages"', '"command"', '"lastLine"', '"workdir"', 'ingerprint'])
    assert.ok(!allowed.includes(forbidden), forbidden);
  const wire = slice(overview, 'static func snapshot(doc:', 'static func allKeys(');
  assert.doesNotMatch(wire, /messages|cwd|workdir|host|\buser\b|command|lastLine|roomBrief|userWords|evidence/);
  assert.match(overview, /job\.threadID\.flatMap \{ threadTitles\[\$0\] \}/, 'job names come from thread titles, not commands');
  const bridge = read('Facade/OSAgentBridge.swift');
  const ssh = bridge.match(/static let sshForwardMethods: Set<String> = \[([\s\S]*?)\]/)[1];
  assert.match(ssh, /W180 E2[^\n]*\n\s*"overview_snapshot",/);
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods']) {
    const body = bridge.match(new RegExp(`static let ${list}: Set<String> = \\[([\\s\\S]*?)\\]`))[1];
    assert.doesNotMatch(body, /"overview_snapshot"/, list);
  }
  assert.match(bridge, /case "overview_snapshot":   \/\/ W180 E2：見檔尾 overviewSnapshot\s*return try overviewSnapshot\(params: params\)\s*default:/);
  const handler = slice(bridge, '// MARK: - W180 E2：overview_snapshot', null);
  assert.match(handler, /guard Set\(params\.keys\)\.isSubset\(of: \["callerThreadID"\]\) else \{ throw BridgeError\.invalidParams \}/);
  assert.match(handler, /backgroundJobSnapshot\(includeLastLine: false\)/);
  assert.match(handler, /AssistantOverviewWire\.snapshot\(/);
  assert.match(handler, /model\.localLiveForBridge/);
  assert.doesNotMatch(handler, /model\??\.live\b|\.messages|\.cwd|workdir|\.text\b|deviceRecordsForBridge/);
  const onMain = slice(handler, 'onMain {', 'guard let input else');
  assert.doesNotMatch(onMain, /ThreadGoalStore/, 'goal files are read on the bridge queue, not the main thread');
  // RPC 方法，不是給 AI 的工具。
  assert.doesNotMatch(readFileSync(new URL('../Engines/os-mcp/server.mjs', import.meta.url), 'utf8'), /overview_snapshot/);
  const tools = read('Facade/OSToolsAcceptance.swift');
  assert.match(tools, /OSAgentBridge\.allows\(caller: \.ssh, method: "overview_snapshot"/);
  assert.match(tools, /!OSAgentBridge\.allows\(caller: \.other\(pid: nil\), method: "overview_snapshot"/);
  assert.match(tools, /AssistantOverviewWire\.allKeys\(overview\)\.isSubset\(of: AssistantOverviewWire\.allowedKeys\)/);
});

test('reader: goal files and SSH only off the main thread, 15 s remote, stops on disappear, no new get_document', () => {
  const reader = read('Assistant/AssistantOverviewReader.swift');
  assert.equal((reader.match(/ThreadGoalStore\.shared\.list/g) ?? []).length, 1);
  const goals = slice(reader, 'nonisolated static func readGoalSummaries(', 'nonisolated static func readLocalIdentity(');
  assert.match(goals, /dispatchPrecondition\(condition: \.notOnQueue\(\.main\)\)[\s\S]*ThreadGoalStore\.shared\.list/);
  assert.match(reader, /await Task\.detached\(priority: \.utility\) \{ Self\.readGoalSummaries\(threads: ids\) \}\.value/);
  assert.equal((reader.match(/link\.call\(/g) ?? []).length, 1);
  const fetch = slice(reader, 'nonisolated static func fetchRemoteDetail(', 'func remoteInput(');
  assert.match(fetch, /dispatchPrecondition\(condition: \.notOnQueue\(\.main\)\)[\s\S]*link\.call\(method: "overview_snapshot", params: \[:\]\)/);
  assert.match(fetch, /code == "unsupported_method" \|\| code == "caller_not_trusted"/);
  assert.match(reader, /await Task\.detached\(priority: \.utility\) \{ Self\.fetchRemoteDetail\(link: link\) \}\.value/);
  assert.match(reader, /remoteInterval: Duration = \.seconds\(15\)/);
  assert.match(reader, /guard case \.online = session\.state, let engine = session\.engine else \{\s*connections\.forget\(id\)/);
  // 重新連上（新的引擎）或頁面重開：「還沒更新」作廢、馬上重問；重問前舊結果標 N 分鐘前。
  assert.match(reader, /if connections\.observe\(id, connection: engine\) \{[^}]*remoteDetails\[id\]\?\.reconnected\(\)/);
  assert.match(reader, /if !connections\.isCurrent\(device\.id, connection: engine\) \{ state\.reconnected\(\) \}/);
  assert.match(slice(reader, 'func start(model:', 'func stop()'), /guard viewers == 1 else \{ return \}[\s\S]*remoteDetails\[id\]\?\.reconnected\(\)/);
  assert.match(reader, /private struct Mark \{ weak var connection: AnyObject\? \}/);
  // 這次開啟後沒拿到過文件：不當離線快照。
  assert.match(reader, /snapshot == TatwoNativeChatStoreDocument\(\) && !remoteSeenOnline\.contains\(device\.id\)/);
  assert.match(read('Assistant/AssistantOverview.swift'), /func shouldFetch\(now: Date, retryAfter: TimeInterval = 120\)/);
  assert.match(reader, /DeviceIdentityStore\.readLocal/);
  assert.doesNotMatch(reader, /method: "(get_document|os_status|goal_index)"/);
  assert.doesNotMatch(reader, writes);
  const stop = slice(reader, 'func stop()', 'var isPolling');
  assert.match(stop, /localLoop\?\.cancel\(\)[\s\S]*remoteLoop\?\.cancel\(\)/);
  for (const page of ['Assistant/AssistantStatusPage.swift', 'Assistant/AssistantProjectMapPage.swift']) {
    const source = read(page);
    assert.match(source, /\.onAppear \{ reader\.start\(model: model\) \}\s*\.onDisappear \{ reader\.stop\(\) \}/, page);
  }
});

test('status page: wording, identifiers, glass chips only, approvals only via Island, open in Coder', () => {
  const page = read('Assistant/AssistantStatusPage.swift');
  for (const text of ['全域狀態', '等你核准', '正在跑', '卡住與失敗', '目標', '背景工作與終端機', '設備', '到 Island 查看',
    '現在沒有在跑的工作。', '沒有卡住或失敗的工作。', '沒有未完成的目標。', '原生 /goal', '主設備', '最後上線', 'Island 請求：'])
    assert.ok(page.includes(text), text);
  for (const id of ['tatwo-status-page', 'tatwo-status-summary', 'tatwo-status-approvals', 'tatwo-status-running',
    'tatwo-status-troubles', 'tatwo-status-goals', 'tatwo-status-jobs', 'tatwo-status-devices', 'tatwo-status-open-island'])
    assert.ok(page.includes(`"${id}"`), id);
  assert.match(page, /OSChipButton\(title: "到 Island 查看", systemImage: "bell"\) \{\s*AssistantOverviewNavigation\.openApprovals\(\)/);
  assert.match(page, /\.liquidGlassSurface\(cornerRadius: LiquidGlassTokens\.radiusCard\)/);
  assert.match(page, /AssistantSpacePane\.columnWidth\(paneWidth: pane\.size\.width\)/);
  assert.match(page, /AssistantOverviewNavigation\.open\(model: model, deviceID: device\.id,\s*isThisDevice: device\.isThisDevice, threadID: threadID\)/);
  const overview = read('Assistant/AssistantOverview.swift');
  assert.match(overview, /"在跑 \\\(snapshot\.running\)\\\(work\)・等你核准 \\\(snapshot\.awaiting\)\\\(approvals\)"\s*\+ "・卡住 \\\(snapshot\.stalled\)\\\(work\)・失敗 \\\(snapshot\.failed\)\\\(work\)"/);
  assert.match(overview, /let work = snapshot\.silentDevices\.isEmpty \? "" : "＋看不到"/);
  // 有設備看不到時，卡片不說「沒有…」，而且每張卡片都列出看不到的設備與原因。
  for (const text of ['看得到的設備上沒有在跑的工作。', '看得到的設備上沒有卡住或失敗的工作。', '看得到的設備上沒有未完成的目標。',
    '看得到的設備上沒有背景工作或終端機。'])
    assert.ok(page.includes(text), text);
  assert.equal((page.match(/^\s*silentLines$/gm) ?? []).length, 4);
  assert.match(page, /OverviewText\.jobsTruncated\(jobs\)/);
  assert.match(overview, /上 \\\(count\) 件，到 \\\(device\.name\) 的 Island 核准/);
  for (const file of ['Assistant/AssistantStatusPage.swift', 'Assistant/AssistantProjectMapPage.swift', 'Assistant/AssistantSpaceTabs.swift']) {
    const source = read(file);
    assert.doesNotMatch(source, /\.blue\b|accentColor|borderedProminent|NSAlert|confirmationDialog|\.alert\(/, file);
    assert.doesNotMatch(source, writes, file);
    assert.doesNotMatch(source, /\bmini\b/i, file);
  }
  const navigation = slice(read('Assistant/AssistantProjectMapPage.swift'), 'enum AssistantOverviewNavigation', 'struct AssistantProjectMapPage');
  // 助理那條先攔下來（不切 mode，免得停掉電腦操作、收回瀏覽器請求），其他的才切到 Coder。
  assert.match(navigation, /if live\.doc\.isAssistantThread\(threadID\) \{ return returnToAssistant\(model: model\) \}\s*model\.mode = \.chat\s*model\.selectLocalThread\(threadID\)/);
  assert.match(navigation, /if remote\.doc\.isAssistantThread\(threadID\) \{ return returnToAssistant\(model: model\) \}\s*model\.mode = \.chat\s*return model\.selectRemote\(deviceID: deviceID, threadID: threadID\)/);
  assert.match(navigation, /if model\.mode != \.tatwo \{ model\.mode = \.tatwo \}\s*AssistantSpaceTabStore\.shared\.returnToConversation\(\)/);
  assert.match(navigation, /static func openApprovals\(\) \{\s*IslandExceptionsNavigation\.openWork\(\)\s*\}/);
  assert.doesNotMatch(navigation, /pendingPermission|permissionDecider|decide|approve/i);
});

test('project map page: grouped by device, offline groups disabled, rooms under parents, open in Coder', () => {
  const page = read('Assistant/AssistantProjectMapPage.swift');
  for (const text of ['專案地圖', '主串 ', '子討論串 ', '在跑 ', '最後活動 ', '未完成目標 ', '離線，連上後可以打開',
    '離線前的資料', '目標看不到', '原生 /goal', '主設備'])
    assert.ok(page.includes(text), text);
  // 沒拿到過文件寫看不到＋原因；空專案的字寫明是哪一台。
  assert.match(page, /if let empty = OverviewText\.mapEmpty\(device\)/);
  assert.doesNotMatch(page, /"離線前沒有專案。"|"這台還沒有專案。"/);
  const overview = read('Assistant/AssistantOverview.swift');
  const mapEmpty = slice(overview, 'static func mapEmpty(', 'static func goalProgress(');
  assert.match(mapEmpty, /這次開啟後還沒連上 \\\(device\.name\)/);
  assert.match(mapEmpty, /\\\(device\.name\) 離線前沒有專案。/);
  assert.match(mapEmpty, /device\.isThisDevice \? "這台還沒有專案。" : "\\\(device\.name\) 還沒有專案。"/);
  assert.match(page, /ForEach\(reader\.map\.devices\) \{ device in\s*deviceGroup\(device\)/);
  assert.match(page, /\.opacity\(device\.canOpen \? 1 : 0\.55\)\s*\.disabled\(!device\.canOpen\)/);
  assert.match(page, /guard device\.canOpen else \{ return \}/);
  assert.match(page, /if let latest = project\.latestThreadID \{ open\(device, latest\) \}/);
  assert.match(page, /"tatwo-project-map-page"/);
  assert.match(page, /\.liquidGlassSurface\(cornerRadius: LiquidGlassTokens\.radiusCard\)/);
});

test('w180overview self-test entry covers every step', () => {
  const selfTest = read('SelfTest.swift');
  assert.match(selfTest, /TATWO2_SELFTEST"\] == "w180overview"[\s\S]{0,200}AssistantOverviewAcceptance\.run\(\)/);
  const acceptance = read('Assistant/AssistantOverviewAcceptance.swift');
  assert.ok(acceptance.startsWith('#if DEBUG'));
  assert.ok(acceptance.includes('W180OVERVIEW SUMMARY passed='));
  for (const marker of ['(1)', '(2)', '(3)', '(5)', '(6)', '(7)']) assert.ok(acceptance.includes(`"${marker} `), marker);
  for (const label of ['stalled equals Island classification', 'nil approvals read 看不到', 'offline device keeps name and last seen',
    'reader goals match goal_index', 'matches os_status', 'overview_snapshot keys are allowlisted',
    'failure keeps the last result', 'stale result is marked N 分鐘前', 'old version wording uses the device display name',
    'open local thread', 'switching tabs keeps mode', 'team cannot be selected',
    'watchdog-stalled room', 'ended with an error', 'subStatus running counts on the map', 'mode is never reassigned',
    'reconnect after an old-version reply asks again at once', 'reconnect marks the last result stale',
    'never-loaded remote reads 看不到', 'summary marks unseen devices', 'jobs at the snapshot limit'])
    assert.ok(acceptance.includes(label), label);
  assert.match(acceptance, /NativeStagingIsolation\.isEnabled\(env\)/);
  assert.doesNotMatch(acceptance, /NSPanel\(|NSWindow\(|makeKeyAndOrderFront|RemoteHostLink\(/);
});
