import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W180 E3b：助理提議專案分類（藍圖 O7）的原始碼契約。
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const repo = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};
const setBody = (source, name) => source.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1];
const folderWrites = /createDirectory|removeItem|moveItem|trashItem|copyItem|createFile|\.write\(to: URL\(fileURLWithPath|workdir\)\.write/;

test('engine: moveThread only changes project membership, sub-threads follow, one checked save', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  const block = slice(engine, '// MARK: - W180 E3b', null);
  assert.match(block, /func moveThread\(_ threadID: UUID, toProject projectID: UUID\) throws -> \[ProjectMoveEntry\]/);
  assert.match(block, /ProjectClassification\.subtree\(of: threadID, in: candidate\.threads\)/);
  assert.match(block, /candidate\.threads\[index\]\.projectID = projectID/);
  assert.match(block, /guard projectID != candidate\.assistantProjectID[\s\S]*!candidate\.isAssistantThread\(threadID\)/);
  assert.match(block, /func restoreThreadProjects\(_ entries: \[ProjectMoveEntry\], archivingEmpty projectIDs: \[UUID\]\)/);
  assert.match(block, /candidate\.threads\[index\]\.projectID == entry\.to/);
  assert.match(block, /!candidate\.threads\.contains\(where: \{ \$0\.projectID == id \}\)/, 'only an empty project is archived');
  // 核准後才開的子討論串、房間：跟著最近一條在紀錄裡、已搬回的祖先回原專案，並回報給呼叫端補進紀錄。
  assert.match(block, /guard let ancestor = cursor, restoredIDs\.contains\(ancestor\), let entry = recorded\[ancestor\]/);
  assert.match(block, /later\.append\(ProjectMoveEntry\(threadID: candidate\.threads\[index\]\.id, from: from, to: entry\.to\)\)/);
  assert.match(block, /try store\.saveChecked\(candidate\)\s*doc = candidate/);
  // 只改歸屬：不動資料夾、不改更新時間、不停引擎。
  assert.doesNotMatch(block, folderWrites);
  assert.doesNotMatch(block, /updatedAt|\.stop\(|FileManager|cwdOverride|workdir =/);
  // 熱檔插點在檔尾、標 W180 E3b，不引用 E2 的型別。
  assert.doesNotMatch(engine, /AssistantSpaceTab|AssistantOverview/);
});

test('store and logic: queue + move log in live/, never touch project folders, archive not delete', () => {
  const source = read('Facade/ProjectClassification.swift');
  assert.match(source, /static let proposalsFile = "project-proposals\.json"/);
  assert.match(source, /static let movesFile = "project-moves\.json"/);
  assert.match(source, /catch \{ throw ProjectClassificationError\.unreadable \}/, 'an unreadable file is never overwritten');
  assert.doesNotMatch(source, folderWrites);
  assert.doesNotMatch(source, /removeItem|FileManager\.default\.(createDirectory|moveItem|trashItem)/);
  for (const field of ['var threadIDs: [UUID]', 'var targetProjectID: UUID?', 'var newProjectName: String?', 'var reason: String',
    'var sourceThreadID: UUID?', 'enum Status: String, Codable, Sendable { case pending, approved, rejected }',
    'var proposalID: UUID?', 'var movedAt: Date', 'var entries: [ProjectMoveEntry]', 'var archivedProjects: [LiveProjectRecord]'])
    assert.ok(source.includes(field), field);
  const plan = slice(source, 'static func plan(', '// MARK: 助理工具：project_overview');
  // 只能搬到同一個資料夾的專案，或新專案（沿用原本的資料夾）；子討論串跟著主串。
  assert.match(plan, /if folder != targetFolder \{\s*problem\("other_folder"/);
  assert.match(plan, /LiveProjectRecord\(name: String\(targetName\.prefix\(nameLimit\)\), workdir: current\.workdir\)/);
  assert.match(plan, /problem\("sub_thread"/);
  assert.match(plan, /problem\("running"/);
  assert.match(plan, /problem\("bot"/);
  assert.match(plan, /problem\("assistant"/);
  assert.match(source, /static let maxThreads = 30/);
  assert.match(source, /static let ruleLine = "只改對話屬於哪個專案，不動任何資料夾；只能搬到同一個資料夾的專案或新專案，原本的對話才接得回。"/);
  const undo = slice(source, 'static func undo(', 'static func decide(');
  assert.match(undo, /restoreThreadProjects\(record\.entries, archivingEmpty: record\.createdProjects\.map\(\\\.id\)\)/);
  assert.match(undo, /record\.archivedProjects = restored\.archived/);
  assert.match(undo, /record\.laterEntries = restored\.later/);
  // 後進先出：較晚、還沒復原的搬移動到同一家對話或這次新建的專案，就先擋，什麼都不動。
  assert.match(undo, /let blockers = undoBlockers\(record, moves: moves[\s\S]*guard blockers\.isEmpty else \{ throw ProjectClassificationError\.undoBlocked\(blockers\) \}\s*let restored = try engine\.restoreThreadProjects/);
  const blockers = slice(source, 'static func undoBlockers(', '// MARK: - 動作');
  assert.match(blockers, /for later in moves\[moves\.index\(after: position\)\.\.\.\] where later\.undoneAt == nil/);
  assert.match(blockers, /family\.contains\(\$0\.threadID\)/);
  assert.match(blockers, /created\.contains\(move\.to\)/);
  assert.match(blockers, /isRunning\(\$0, running: running\)/);
  assert.match(source, /canUndo: record\.undoneAt == nil && undoBlocked\.isEmpty/);
  assert.match(source, /case "undo_blocked": return "現在不能復原："/);
  const approve = slice(source, 'static func approve(', 'static func reject(');
  assert.match(approve, /guard proposal\.status == \.pending/);
  assert.match(approve, /throw ProjectClassificationError\.blocked/);
  assert.match(approve, /catch \{\s*let restored = try\? engine\.restoreThreadProjects/, 'a move without its record is rolled back');
});

test('assistant tools: project_overview is metadata only; project_suggest only queues and only from the assistant', () => {
  const source = read('Facade/ProjectClassification.swift');
  const overview = slice(source, 'static func overview(', '// MARK: 助理工具：project_suggest');
  assert.doesNotMatch(overview, /\.text\b|roomBrief|cwdOverride|"workdir"|"path"|"cwd"|\.workdir\b(?!\))/);
  assert.match(overview, /"messageCount": thread\.messages\.lazy\.filter \{ \$0\.eventKind == "message" \}\.count/);
  assert.match(overview, /\$0\.projectID != doc\.assistantProjectID/);
  assert.match(overview, /"folderGroup": group/);
  const suggest = slice(source, 'static func suggest(', '// MARK: 卡片');
  assert.match(suggest, /\$0\.id == caller && \$0\.projectID == assistantProjectID/);
  assert.match(suggest, /throw ProjectClassificationError\.assistantOnly/);
  assert.match(suggest, /store\.updateProposals/);
  assert.doesNotMatch(suggest, /moveThread|restoreThreadProjects|approve\(/);
  const parse = slice(source, 'static func parseItems(', 'static func suggest(');
  assert.match(parse, /Set\(row\.keys\)\.isSubset\(of: \["threadIDs", "targetProjectID", "newProjectName", "reason"\]\)/);
  assert.match(parse, /guard !reason\.isEmpty, reason\.count <= reasonLimit/);
  assert.match(parse, /guard total <= maxThreads/);
  const decide = slice(source, 'static func decide(', 'static func userMessage(');
  assert.match(decide, /guard boundThread == nil else \{ throw ProjectClassificationError\.enginesCannotDecide \}/);
  assert.match(decide, /Set\(params\.keys\)\.isSubset\(of: \["id", "action", "callerThreadID"\]\)/);
  assert.match(decide, /case "approve":[\s\S]*case "reject":[\s\S]*case "undo":/);

  const server = repo('Engines/os-mcp/server.mjs');
  for (const name of ['project_overview', 'project_suggest'])
    assert.equal([...server.matchAll(new RegExp(`^  \\['${name}',.*\\],$`, 'gm'))].length, 1, `${name}: one tuple per line`);
  assert.doesNotMatch(server, /project_proposal_decide/, 'the decision is an RPC, not an AI tool');
  assert.match(server, /\['project_suggest', [^\n]*nothing moves until the user approves/);
  const manual = read('Resources/tatwo-assistant.md');
  assert.ok(manual.includes('`project_overview`') && manual.includes('`project_suggest`'));
  assert.ok(manual.includes('分類你只提議、不能搬'));
  assert.ok(manual.includes('幫我整理專案'));
});

test('bridge: tools on no trust list; paired devices decide by id only; engines cannot decide', () => {
  const bridge = read('Facade/OSAgentBridge.swift');
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    const body = setBody(bridge, list);
    assert.ok(body !== undefined, list);
    assert.doesNotMatch(body, /"project_overview"|"project_suggest"/, list);
  }
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods'])
    assert.doesNotMatch(setBody(bridge, list), /"project_proposal_decide"/, list);
  assert.match(setBody(bridge, 'sshForwardMethods'), /W180 E3b[^\n]*\n\s*"project_proposal_decide",/);
  assert.match(bridge, /case "project_overview", "project_suggest", "project_proposal_decide":   \/\/ W180 E3b[^\n]*\n\s*return try projectClassification\(method: method, params: params, boundThread: context\.boundThread\)\s*case "overview_snapshot":/);
  const glue = slice(bridge, '// MARK: - W180 E3b', '// MARK: - W180 E2：overview_snapshot');
  assert.match(glue, /guard boundThread == nil else \{ throw ProjectClassificationError\.enginesCannotDecide \}/);
  assert.match(glue, /model\?\.localLiveForBridge/);
  assert.doesNotMatch(glue, /model\??\.live\b|deviceRecordsForBridge|link\.call/);
  // overview_snapshot 多回白名單欄位；提案檔在 bridge 佇列上讀。
  const handler = slice(bridge, '// MARK: - W180 E2：overview_snapshot', null);
  assert.match(handler, /snapshot\[ProjectClassificationWire\.key\] = ProjectClassificationWire\.rows\(ProjectClassification\.cards\(/);
  const tests = repo('tests/w178-security.test.mjs');
  assert.match(tests, /'project_overview', 'project_suggest', 'project_proposal_decide'\]\) \{/);
});

test('wire: allowlisted proposal fields only, merged into the overview allowlist', () => {
  const source = read('Facade/ProjectClassification.swift');
  const allowed = slice(source, 'static let allowedKeys: Set<String> = [', ']');
  for (const forbidden of ['"text"', '"content"', '"cwd"', '"path"', '"workdir"', '"messages"', '"command"', '"host"', '"user"', 'ingerprint'])
    assert.ok(!allowed.includes(forbidden), forbidden);
  const keys = [...allowed.matchAll(/"([A-Za-z]+)"/g)].map(m => m[1]);
  const overview = slice(read('Assistant/AssistantOverview.swift'), 'static let allowedKeys: Set<String> = [', ']');
  for (const key of keys) assert.ok(overview.includes(`"${key}"`), `overview allowlist has ${key}`);
  assert.match(overview, /W180 E3b/);
  const rows = slice(source, 'static func rows(', 'static func cards(_ snapshot');
  assert.doesNotMatch(rows, /workdir|cwd|messages|\.text\b|roomBrief|sourceThreadID/);
  for (const key of ['"id"', '"status"', '"reason"', '"targetName"', '"threads"', '"threadID"', '"title"', '"canUndo"'])
    assert.ok(rows.includes(key), key);
  const reader = read('Assistant/AssistantOverviewReader.swift');
  assert.equal((reader.match(/link\.call\(/g) ?? []).length, 1, 'proposals ride on the same overview_snapshot call');
  assert.match(reader, /ProjectClassificationWire\.cards\(snapshot\)/);
  assert.match(reader, /case \.needsUpdate: if remoteProposals\[id\] != nil \{ remoteProposals\[id\] = nil \}/);
});

test('page: glass chip at the top, proposals and recent moves, in-card confirm row, no system dialogs', () => {
  const page = read('Assistant/AssistantProjectMapPage.swift');
  assert.match(page, /AssistantClassificationChip\(model: model\)   \/\/ W180 E3b/);
  assert.match(page, /AssistantClassificationSection\(model: model\)   \/\/ W180 E3b/);
  assert.ok(page.indexOf('AssistantClassificationSection(model: model)') < page.indexOf('ForEach(reader.map.devices)'));
  const section = read('Assistant/AssistantClassificationSection.swift');
  for (const text of ['請助理整理分類', '分類建議', '最近搬移', '核准搬移', '不要', '復原', '新專案：', '取消', '搬移',
    '還沒有建議。', 'ProjectClassification.ruleLine'])
    assert.ok(section.includes(text), text);
  for (const id of ['tatwo-classify-ask', 'tatwo-classify-card', 'tatwo-classify-approve', 'tatwo-classify-reject',
    'tatwo-classify-undo', 'tatwo-classify-confirm-row', 'tatwo-classify-moves'])
    assert.ok(section.includes(`"${id}"`), id);
  assert.match(section, /OSChipButton\(title: "核准搬移", systemImage: "checkmark", isPrimary: true\) \{\s*confirming = Confirm\(key: key, action: \.approve\)/);
  assert.match(section, /\.disabled\(!card\.blocked\.isEmpty\)/);
  assert.match(section, /\.chatLiquidSection\(cornerRadius: 12\)/);
  for (const file of [section, page]) {
    assert.doesNotMatch(file, /\.blue\b|accentColor|borderedProminent|NSAlert|confirmationDialog|\.alert\(/);
    assert.doesNotMatch(file, /\bmini\b/i);
  }
  // 按 chip：先回對話分頁，再送固定的一句給助理（本機或主設備那條，照助理自己的路由）。
  const ask = slice(section, 'static func askAssistant(', 'struct AssistantClassificationChip');
  assert.match(ask, /AssistantSpaceTabStore\.shared\.returnToConversation\(\)[\s\S]*model\.sendToAssistant\(text: text\)/);
  assert.match(ask, /if !sent, model\.assistantPrompt\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty/);
  // 副設備：只送提案 id＋決定，在背景佇列（SSH 不上主執行緒）。
  const remote = slice(section, 'nonisolated static func sendDecision(', 'nonisolated static func parseRemoteError(');
  assert.match(remote, /dispatchPrecondition\(condition: \.notOnQueue\(\.main\)\)[\s\S]*link\.call\(method: "project_proposal_decide", params: \["id": id\.uuidString, "action": action\.rawValue\]\)/);
  assert.match(section, /await Task\.detached\(priority: \.userInitiated\) \{ Self\.sendDecision\(link: link, id: id, action: action\) \}\.value/);
  assert.doesNotMatch(section, /moveThread|restoreThreadProjects|\.saveChecked|FileManager/);
});

test('w180classify self-test entry covers every acceptance item', () => {
  const selfTest = read('SelfTest.swift');
  assert.match(selfTest, /TATWO2_SELFTEST"\] == "w180classify"[\s\S]{0,200}ProjectClassificationAcceptance\.run\(\)/);
  const acceptance = read('Facade/ProjectClassificationAcceptance.swift');
  assert.ok(acceptance.startsWith('#if DEBUG'));
  assert.ok(acceptance.includes('W180CLASSIFY SUMMARY passed='));
  for (const label of ['a pending proposal changes nothing', 'approve moves the thread with its sub-threads',
    'no folder is created or changed', 'undo restores every thread field by field', 'the emptied new project is archived',
    'a new project that is not empty after undo is kept', 'the decision RPC accepts only an id', 'an engine cannot approve',
    'the assistant tools are not on any trust list', 'project_overview returns no message content',
    'only the assistant conversation may propose', 'a running thread blocks approval', 'overview_snapshot carries proposals',
    'the chip returns to the conversation', 'an unreadable proposal file is never overwritten',
    'undo brings sub-threads opened after approval back with their main thread',
    'undoing the earlier move first is refused', 'undoing in reverse order returns the thread to its original project',
    'a later move into the new project also has to be undone first', 'undo waits while a sub-thread is running'])
    assert.ok(acceptance.includes(label), label);
  assert.match(acceptance, /NativeStagingIsolation\.isEnabled\(env\)/);
  assert.doesNotMatch(acceptance, /NSPanel\(|NSWindow\(|makeKeyAndOrderFront|RemoteHostLink\(/);
  assert.match(repo('docs/specs/180-w179-followups/tasks.md'), /## E3b[\s\S]*resume/);
});
