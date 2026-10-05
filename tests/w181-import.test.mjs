// W181 R1：Coder 匯入改成照 Codex／Claude Code 左邊欄的專案挑；匯入視窗 ✕／完成／Esc／⌘W 都只關這個 sheet。
// 各家的紀錄（含 Codex 的 sqlite）只讀：這裡用合成的資料夾驗清單、順序、標題來源，並比對原檔雜湊前後不變。
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, utimesSync, statSync, existsSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const app = p => join(root, 'App/Sources/Tatwo2', p);
const read = p => readFileSync(app(p), 'utf8');

test('治理：清單只讀——不寫檔、不連網、資料庫只用唯讀開、SQL 只有 SELECT；OS 內 AI 沒有讀歷史的 RPC', () => {
  for (const file of ['Facade/CodexAppProjects.swift', 'Facade/ClaudeCodeProjects.swift', 'Facade/CoderImportCatalog.swift']) {
    const source = read(file);
    for (const banned of [/\.write\(/, /removeItem/, /moveItem/, /copyItem/, /createFile/, /URLSession/, /forWritingTo/, /forUpdating/, /trashItem/])
      assert.doesNotMatch(source, banned, `${file} ${banned}`);
  }
  const codex = read('Facade/CodexAppProjects.swift');
  assert.doesNotMatch(codex, /SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|sqlite3_exec|INSERT|UPDATE |DELETE|CREATE |DROP |PRAGMA/);
  const sql = [...codex.matchAll(/(?:rows\(db, |sqlite3_prepare_v2\(db, )"([^"]+)"/g)].map(m => m[1]);
  assert.ok(sql.length >= 5, sql.join(' | '));
  for (const statement of sql) assert.match(statement, /^SELECT /, statement);
  assert.match(codex, /SQLITE_OPEN_READONLY \| SQLITE_OPEN_NOMUTEX/);
  assert.match(codex, /\?mode=ro&immutable=1/);   // Codex 沒開時不建 -wal／-shm、不上鎖
  assert.match(codex, /sqlite3_busy_timeout\(db, 200\)/);   // 忙的時候不跟 Codex 搶
  assert.match(codex, /name\.hasPrefix\("state_"\), name\.hasSuffix\("\.sqlite"\)/);   // 版本號會變：取最大號
  for (const name of ['CodexAppProjects', 'ClaudeCodeProjects', 'CoderImportCatalog', 'CLITranscript'])
    assert.doesNotMatch(read('Facade/OSAgentBridge.swift'), new RegExp(name));
  assert.doesNotMatch(read('Facade/ChatPageModel.swift'), /CoderImportBrowser|CodexAppProjects|ClaudeCodeProjects|CoderImportTarget/);   // 熱檔不動
});

test('畫面：兩顆來源 chip、左欄專案（則數＋最後活動）、中欄正式標題、右欄預覽；不再有「含非互動」「匯入 ≤」「Zero KB」', () => {
  const browser = read('New/CoderImportBrowser.swift');
  for (const text of ['sourceChip(.codex, "Codex")', 'sourceChip(.claude, "Claude Code")', '"Codex 的專案"', '"Claude Code 的專案"',
                      '則 · 最後 ', 'CoderImportCatalog.projectlessName', 'showsProjectless.toggle()', '匯入這個專案（\\(pending) 則）',
                      '"已匯入・打開" : "匯入"', 'OSChipButton(title: "完成", isPrimary: true, action: onClose)', '選一則對話來看',
                      '子代理、背景執行（exec、SDK、-p）與封存的不列。', '會跟著 Coder 同步到配對設備'])
    assert.ok(browser.includes(text), text);
  assert.doesNotMatch(browser, /含非互動|匯入 ≤|usageText|isBatch|CLITranscriptHistoryView/);
  assert.match(browser, /else if let notice = CoderImportCatalog\.nearCapNotice\(used: model\.coderImportUsedBytes\)/);   // 用量只在接近上限時出一行
  assert.match(browser, /VStack\(spacing: 0\) \{\s*if model\.coderImportViewOnly \{ note\(CoderImport\.viewOnlyHint, symbol: "info\.circle"\) \}/);   // 只能看的提示照舊在最上面
  assert.match(browser, /@State private var showsProjectless = false/);   // 「沒有專案的對話」預設收起
  // 讀清單、讀預覽、讀完整紀錄、篩選都在背景、切走就停。
  assert.equal((browser.match(/Task\.detached\(priority: \.userInitiated/g) || []).length, 5);   // 清單、看原檔、完整紀錄、預覽、篩選
  assert.equal((browser.match(/onCancel: \{ work\.cancel\(\) \}/g) || []).length, 4);
  assert.match(browser, /CoderImportCatalog\.previewItems\(session\)/);   // 預覽先讀原檔最後一段
  // W181 審查：「看原檔」要看得到完整紀錄（W110 的讀檔：整份、背景、有進度、切走就取消；搜尋、顯示工具）。
  assert.match(browser, /CLITranscriptArchive\.read\(session\) \{ value in Task \{ @MainActor in percent = value \} \}/);
  assert.match(browser, /OSChipButton\(title: full \? "只看最近" : "讀完整紀錄"/);
  assert.match(browser, /ChatChipTextField\(title: "在這段對話裡找", text: \$query\)/);
  assert.match(browser, /CoderImportCatalog\.filter\(record, query: needle, showsTools: tools\)/);
  assert.match(browser, /startsFull: focus\.map \{ \$0\.matches\(conversation\.session\) \} \?\? false/);   // 看原檔直接開完整紀錄
  // W181 審查：「已匯入」用家別＋session id（跟 E3 去重一樣），「看原檔」用出處的家別找，不從路徑猜。
  assert.match(browser, /private func isImported\(_ item: CoderImportConversation\) -> Bool \{ model\.coderImportIsImported\(item\) \}/);
  assert.doesNotMatch(browser, /coderImportedPaths|contains\("\/\.codex\/"\)/);
  assert.match(browser, /CoderImportCatalog\.locate\(focus, in: catalogs\[value\] \?\? \[\]\)/);
  assert.match(browser, /let owner = focus\.engine \?\? guessEngine\(path\)/);
  assert.doesNotMatch(browser, /borderedProminent|\.tint\(|Color\.blue|\.accentColor|NSAlert|\.alert\(|confirmationDialog|NSPasteboard|URLSession/);
  const catalog = read('Facade/CoderImportCatalog.swift');
  assert.match(catalog, /static let previewTailBytes = 2 \* 1024 \* 1024/);
  assert.match(catalog, /var importKey: String \{ CoderImport\.dedupeKey\(engine: session\.engine\.rawValue, sessionID: session\.sessionID, path: session\.url\.path\) \}/);
  assert.match(read('Facade/CodexAppProjects.swift'), /CoderImportCatalog\.resolvedPath\(row\["rollout_path"\] \?\? ""\)/);   // ~/.codex 是捷徑
  assert.match(read('Facade/ClaudeCodeProjects.swift'), /let projectsRoot = projectsRoot\.resolvingSymlinksInPath\(\)/);   // ~/.claude 是捷徑
  // W181 審查：同名不同資料夾不沿用——先照（解開捷徑的）資料夾找，名字被別的資料夾用掉就加區別。
  const placement = catalog.slice(catalog.indexOf('static func placement('), catalog.indexOf('static func distinctName('));
  assert.ok(placement.indexOf('projects.first(where: { resolvedPath($0.workdir) == target })') > 0);
  assert.ok(placement.indexOf('distinctName(name, root: folder') > placement.indexOf('resolvedPath($0.workdir) == target'));
  assert.doesNotMatch(placement.slice(placement.indexOf('let target = resolvedPath(trimmed)')), /caseInsensitiveCompare/);   // 有根目錄時不靠名字合併
  assert.match(catalog, /static let nearCapRatio = 0\.8/);
  // 匯入沿用 E3，不重寫：專案層只決定放進哪個 Coder 專案。
  const wiring = read('Facade/ChatPageModel+CoderImport.swift');
  assert.match(wiring, /func importCoderProject\(_ project: CoderImportProject[\s\S]*importCLISessions\(\(pending\.isEmpty \? available : pending\)\.map\(\\\.session\), target: CoderImportTarget\(project\)/);
  assert.match(wiring, /if let placement, !items\.isEmpty \{ self\.ensureCoderImportProject\(placement, engine: engine\) \}/);
  assert.match(wiring, /let placement = target\.map \{ coderImportPlacement\(for: \$0, engine: engine\) \}/);
  assert.match(wiring, /CoderImportTarget\.placing\(original, in: \$0\.workdir\)/);
  assert.match(wiring, /CoderImportCatalog\.placement\(name: target\.name, root: target\.root,/);
  assert.match(wiring, /Set\(localLiveForBridge\?\.doc\.threads\.compactMap \{ \$0\.importedFrom\?\.dedupeKey \} \?\? \[\]\)/);
  assert.doesNotMatch(wiring, /coderImportedPaths|coderImportWorkdir/);
  assert.match(wiring, /這個專案還有 \\\(skipped\) 則沒匯入/);
  assert.match(wiring, /let ids = engine\.importCLISessions\(items, viewOnlyHint: viewOnlyHint\)/);
  assert.match(wiring, /self\.init\(name: CodexAppProjects\.projectlessCoderName, root: project\.root\)/);
  // W181 R3 把這句改成白話（不再有「引擎已停用」「併回」）；這裡只確認還有這一行、而且不是舊字。
  { const hint = read('Facade/CoderImport.swift'); assert.match(hint, /static let viewOnlyHint = "/); assert.doesNotMatch(hint, /static let viewOnlyHint = "這台的引擎已停用/); };
  // W110 閱讀器回到原樣、CLI 分頁不給匯入。
  assert.doesNotMatch(read('New/CLITranscriptHistoryView.swift'), /onImport|importedIDs|importUsage|focusPath|CoderImport/);
  assert.doesNotMatch(read('Chat/ChatPage+Panels.swift'), /onImport|CoderImport/);
});

test('關得掉：sheet 自己接 Esc／⌘W／取消，只關 sheet；第一下點擊就算數；掛在 TATWO 主視窗；自測走真的事件佇列', () => {
  const switcher = read('New/CoderProjectSpaceSwitcher.swift');
  const sheet = switcher.slice(switcher.indexOf('final class CoderSheetWindow'));
  assert.match(sheet, /override func cancelOperation\(_ sender: Any\?\) \{ dismissSheet\(\) \}/);
  assert.match(sheet, /override func performClose\(_ sender: Any\?\) \{ dismissSheet\(\) \}/);
  assert.match(sheet, /if Self\.isPlainEscape\(event\), !isComposingText \{\s*dismissSheet\(\)\s*return\s*\}/);   // 中文輸入法選字時的 Esc 照常給輸入法
  assert.match(sheet, /hasMarkedText\(\)/);
  assert.match(sheet, /override func acceptsFirstMouse\(for event: NSEvent\?\) -> Bool \{ true \}/);
  assert.doesNotMatch(sheet, /sheetParent\?\.cancelOperation|parent\.cancelOperation|nextResponder/);   // 不往主視窗傳
  assert.match(switcher, /CoderImportBrowser\(model: model, roots: roots \?\? model\.coderImportRoots, focus: focus, onClose: \{ close\(\) \}\)/);
  assert.match(switcher, /Button\("看這條的原檔"\) \{ CoderSheetPresenter\.presentImport\(model: model, focus: source\) \}/);
  assert.match(switcher, /source \?\? focusPath\.flatMap \{ model\.coderImportSource\(path: \$0\) \}/);   // 串的右鍵只給路徑：先找回出處
  // W181 審查：Esc 按住（自動重複）或連按兩下，後面的 Esc 也不能落到主視窗。
  assert.match(sheet, /if let event = NSApp\.currentEvent, Self\.isPlainEscape\(event\) \{ CoderSheetEscapeGuard\.arm\(after: event\) \}/);
  const guard = switcher.slice(switcher.indexOf('enum CoderSheetEscapeGuard'));
  assert.match(guard, /static let window: TimeInterval = 0\.4/);
  assert.match(guard, /if protectNextEscape \|\| event\.timestamp <= until \|\| \(held && event\.isARepeat\) \{\s*protectNextEscape = false\s*held = true\s*return true\s*\}\s*disarm\(\)\s*return false/);
  assert.match(guard, /static func arm\(after event: NSEvent\) \{\s*protectNextEscape = false\s*mainWindowOnly = false\s*until = event\.timestamp \+ window\s*held = event\.type == \.keyDown/);
  assert.match(guard, /if event\.type == \.keyUp \{\s*held = false[\s\S]{0,120}return false/);
  assert.match(guard, /return swallows\(event\) \? nil : event/);
  // 沒有根因能證明的補丁標成防護性。
  assert.ok((switcher.match(/防護性/g) || []).length >= 3);
  assert.match(switcher, /if let parent = sheet\.sheetParent \{ parent\.endSheet\(sheet\) \} else \{ sheet\.orderOut\(nil\) \}/);
  assert.match(switcher, /if let main = NSApp\.mainWindow as\? TatwoWorkOSWindow \{ return main \}/);   // 不掛到私訊框之類的小面板上
  assert.match(switcher, /host\.sizingOptions = \[\.minSize\]/);
  const browser = read('New/CoderImportBrowser.swift');
  assert.match(browser, /\.accessibilityLabel\("關閉"\)\.accessibilityIdentifier\("coder\.import\.close"\)/);
  assert.match(browser, /\.frame\(width: 28, height: 28\)\.chatGlassChip\(\)\.contentShape\(Rectangle\(\)\)/);   // ✕ 整塊都點得到
  const selftest = read('SelfTest.swift');
  assert.match(selftest, /environment\["TATWO2_SELFTEST"\] == "w181import"[\s\S]{0,260}CoderImportBrowserAcceptance\.run\(\)/);
  const acceptance = read('Facade/CoderImportBrowserAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NSApp\.postEvent\(event, atStart: false\)/);
  assert.doesNotMatch(acceptance, /NSApp\.sendEvent\(/);   // 不繞過本機事件監聽
  for (const text of ['Esc closes only the sheet', '⌘W (performClose) closes only the sheet', 'even when the sheet is not key',
                      'is the topmost window at its spot', 'does not cover the sheet', 'real HID mouse click',
                      'holding Esc (key repeat after the sheet closed) never reaches the main window', 'Esc pressed twice within 0.1 s',
                      'a fresh Esc later goes to the main window as before', 'real Island + real main window', 'TatwoIslandShellPanel(',
                      'the TATWO window stays open', 'the check above is not vacuous',
                      'two Claude Code folders with the same last name', 'another folder is not reused',
                      'shows as 已匯入 in the new browser', 'not by guessing from the path', 'instead of importing a blank duplicate',
                      'full record: whole file read'])
    assert.ok(acceptance.includes(text), text);
});

const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const walk = dir => readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isSymbolicLink() ? [] : e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);

test('邏輯探針：Codex 專案順序與歸屬、Claude Code 標題順序、子代理與背景不列；Codex 沒開也讀得到；原檔（含 sqlite）不變', () => {
  const work = mkdtempSync(join(tmpdir(), 'w181-import-'));
  const line = o => JSON.stringify(o);
  const old = new Date(Date.now() - 3600_000);
  const codexHome = join(work, 'codex'); mkdirSync(codexHome, { recursive: true });
  symlinkSync(codexHome, join(work, 'codex-link'));   // 這台的 ~/.codex、~/.claude 都是捷徑
  const folder = name => { const p = join(work, 'work', name); mkdirSync(p, { recursive: true }); return p; };
  const one = folder('one'), two = folder('two'), three = folder('three'), four = folder('four'), chats = folder('chats');
  mkdirSync(join(two, 'sub'), { recursive: true });
  const q = v => v === null ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`;
  // 舊版資料庫：號碼小，不該被讀。
  let r = spawnSync('sqlite3', [join(codexHome, 'state_2.sqlite'), "CREATE TABLE projects (id TEXT, name TEXT, metadata TEXT, position INTEGER); INSERT INTO projects VALUES ('old','舊版的專案','{}',0);"], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const now = Date.now();
  const sql = [
    'PRAGMA journal_mode=WAL;',
    "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT '{}', position INTEGER NOT NULL, created_at_ms INTEGER NOT NULL DEFAULT 0, updated_at_ms INTEGER NOT NULL DEFAULT 0);",
    'CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL);',
    "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, first_user_message TEXT NOT NULL DEFAULT '', agent_nickname TEXT, agent_role TEXT, updated_at_ms INTEGER, thread_source TEXT, preview TEXT NOT NULL DEFAULT '', recency_at_ms INTEGER NOT NULL DEFAULT 0, name TEXT, project_id TEXT, originator TEXT);",
    'CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);',
  ];
  for (const [id, name, rootPath, position] of [['P1', '第一個專案', one, 0], ['P2', '第二個專案', two, 1], ['P3', '釘選的專案', three, 2], ['P4', '空的專案', four, 3]])
    sql.push(`INSERT INTO projects (id, name, position) VALUES (${q(id)}, ${q(name)}, ${position}); INSERT INTO project_roots VALUES (${q(id)}, 0, ${q(rootPath)});`);
  const sessions = join(codexHome, 'sessions/2026/09/20'); mkdirSync(sessions, { recursive: true });
  const rollout = id => join(sessions, `rollout-2026-09-20T01-00-00-${id}.jsonl`);
  const thread = (id, { cwd = one, title = '', name = null, first = '', preview = '', source = 'vscode', threadSource = 'user', archived = 0,
                        nickname = null, role = null, project = null, originator = null, age = 1000, file = true, viaLink = false } = {}) => {
    if (file) {
      writeFileSync(rollout(id), [line({ type: 'session_meta', payload: { id, cwd } }),
        line({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: `問 ${id}` }] } }),
        line({ type: 'response_item', payload: { type: 'function_call_output', output: 'TOOL-OUTPUT-MARKER' } }),
        line({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: `答 ${id}` }] } })].join('\n') + '\n');
      utimesSync(rollout(id), old, old);
    }
    const at = now - age;
    // 這台的 Codex 資料庫記的是 ~/.codex/…（捷徑），不是解開後的路徑。
    const stored = viaLink ? join(work, 'codex-link', 'sessions/2026/09/20', `rollout-2026-09-20T01-00-00-${id}.jsonl`) : rollout(id);
    sql.push(`INSERT INTO threads (id, rollout_path, source, cwd, title, archived, first_user_message, agent_nickname, agent_role, updated_at_ms, thread_source, preview, recency_at_ms, name, project_id, originator) VALUES (${[id, stored, source, cwd, title, archived, first, nickname, role, at, threadSource, preview, at, name, project, originator].map(v => typeof v === 'number' ? v : q(v)).join(', ')});`);
  };
  thread('t1', { title: '第一句 t1', first: '第一句 t1', name: '改過的名字', age: 100 });
  thread('t2', { title: 'Codex 取的標題', project: 'P1', age: 200, viaLink: true });
  thread('t3', { first: '只有第一句', age: 300, file: false });
  thread('t4', { preview: '只有預覽', age: 400 });
  thread('t5', { title: 'exec 房間', source: 'exec', age: 10 });
  thread('t6', { title: '子代理', threadSource: 'subagent', age: 10 });
  thread('t7', { title: '封存的', archived: 1, age: 10 });
  thread('t8', { title: '被生出來的', age: 10 });
  thread('t9', { title: 'codex exec', originator: 'codex_exec', age: 10 });
  thread('t10', { age: 10 });   // 開了沒說話
  thread('t11', { title: '有代理暱稱', nickname: 'Helper', role: 'explorer', age: 10 });
  thread('t12', { title: '沒有專案的對話 t12', cwd: join(chats, '2026-09-20/new-chat'), age: 500 });
  thread('t13', { title: '資料夾在第二個專案底下', cwd: join(two, 'sub'), age: 600 });
  thread('t14', { title: '釘選專案的對話', cwd: three, age: 700 });
  sql.push("INSERT INTO thread_spawn_edges VALUES ('t1', 't8', 'closed');");
  const db = join(codexHome, 'state_5.sqlite');
  r = spawnSync('sqlite3', [db], { input: sql.join('\n'), encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const assignments = {};
  for (const id of ['t1', 't3', 't4', 't5', 't6', 't7', 't8', 't9', 't10', 't11']) assignments[id] = { projectKind: 'local', projectId: 'L1' };
  assignments.t14 = { projectKind: 'local', projectId: 'L3' };
  writeFileSync(join(codexHome, '.codex-global-state.json'), JSON.stringify({
    'local-projects': { L1: { id: 'L1', name: '第一個專案', rootPaths: [one] }, L3: { id: 'L3', name: '釘選的專案', rootPaths: [three] } },
    'app-server-project-id-by-legacy-project-id-by-host': { [`local:${codexHome}`]: { L1: 'P1', L2: 'P2', L3: 'P3', L4: 'P4' } },
    'project-order': ['L1', 'R9', 'L2', 'L4'],
    'pinned-project-ids': ['L3'],
    'remote-projects': [{ id: 'R9', hostId: 'remote-ssh-discovered:primary-one', remotePath: '/remote/x', label: '遠端的專案' }],
    'thread-project-assignments': assignments,
    'projectless-thread-ids': ['t12'],
    'thread-workspace-root-hints': { t12: chats, t13: join(two, 'sub') },
  }));

  // Claude Code：一個資料夾一個專案；子代理在 <session>/subagents/；-p 跑的是 sdk-cli；桌面 App 的標題另外存。
  const home = folder('home');
  const claudeOne = folder('claude-one');
  const projects = join(work, 'claude/projects');
  symlinkSync(join(work, 'claude'), join(work, 'claude-link'));
  const ids = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [i + 1, `${String(i + 1).padStart(8, '0')}-2222-4333-8444-555555555555`]));
  const session = (n, dir, { cwd = claudeOne, entry = 'cli', sidechain = false, body = [], tail = [], padding = 0, age = 600 } = {}) => {
    mkdirSync(join(projects, dir), { recursive: true });
    const rows = [line({ type: 'user', cwd, entrypoint: entry, sessionId: ids[n], isSidechain: sidechain, message: { role: 'user', content: '<command-name>/clear</command-name>\n<command-message>clear</command-message>' } })];
    rows.push(...body.map(line));
    for (let i = 0; i < padding; i++) rows.push(line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: `填充 ${i} ` + 'x'.repeat(2000) }] } }));
    rows.push(...tail.map(line));
    const path = join(projects, dir, `${ids[n]}.jsonl`);
    writeFileSync(path, rows.join('\n') + '\n');
    const when = new Date(Date.now() - age * 1000); utimesSync(path, when, when);
  };
  const user = (text, meta = false) => ({ type: 'user', isMeta: meta, message: { role: 'user', content: text } });
  const answer = { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: '好' }, { type: 'tool_use', name: 'sample', input: { command: 'ls' } }] } };
  session(1, '-fx-one', { body: [user('c1 第一句'), answer, { type: 'ai-title', aiTitle: 'AI 標題 c1' }, { type: 'summary', summary: '摘要 c1' },
                                  { type: 'custom-title', customTitle: '自訂標題 c1' }, { type: 'agent-name', agentName: '代理名稱 c1' }], age: 600 });
  session(2, '-fx-one', { body: [user('c2 第一句'), answer, { type: 'ai-title', aiTitle: 'AI 標題 c2' }, { type: 'summary', summary: '摘要 c2' },
                                  { type: 'custom-title', customTitle: '自訂標題 c2' }], age: 700 });
  session(3, '-fx-one', { body: [user('c3 第一句'), { type: 'summary', summary: '摘要 c3' }, { type: 'ai-title', aiTitle: 'AI 標題 c3' }], age: 800 });
  session(4, '-fx-one', { body: [user('c4 第一句'), { type: 'summary', summary: '摘要 c4' }], age: 900 });
  session(5, '-fx-one', { body: [user('不該當標題的 meta', true), user('<local-command-stdout>指令輸出</local-command-stdout>'), user('c5 真的第一句'), answer,
                                  { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', content: 'TOOL-OUTPUT-MARKER' }] } }], age: 1000 });
  session(6, '-fx-one', { sidechain: true, body: [user('子代理')], age: 1100 });
  session(7, '-fx-one', { entry: 'sdk-cli', body: [user('claude -p 跑的')], age: 1200 });
  session(8, '-fx-one', { entry: 'sdk-ts', body: [user('桌面 App 裡開的')], age: 1300 });
  session(9, '-fx-one', { body: [user('封存的桌面對話')], age: 1400 });
  session(10, '-fx-one', { body: [user('大檔的第一句'), { type: 'ai-title', aiTitle: '大檔開頭的 AI 標題' }], padding: 400,
                           tail: [{ type: 'custom-title', customTitle: '大檔尾巴的自訂標題' }], age: 1500 });
  mkdirSync(join(projects, '-fx-one', ids[1], 'subagents'), { recursive: true });
  writeFileSync(join(projects, '-fx-one', ids[1], 'subagents', 'agent-a.jsonl'), line({ type: 'user', cwd: claudeOne, isSidechain: true, message: { role: 'user', content: 'sub' } }) + '\n');
  session(11, '-fx-home', { cwd: home, body: [user('家目錄裡問的'), { type: 'ai-title', aiTitle: '家目錄的對話' }], age: 100 });
  session(12, '-fx-rooms', { cwd: '/tmp/room', entry: 'sdk-cli', body: [user('施工')], age: 50 });
  const desktop = join(work, 'desktop/account/org'); mkdirSync(desktop, { recursive: true });
  writeFileSync(join(desktop, `local_${ids[8]}.json`), JSON.stringify({ sessionId: `local_${ids[8]}`, title: '桌面標題 c8', isArchived: false, cwd: claudeOne }));
  writeFileSync(join(desktop, `local_${ids[9]}.json`), JSON.stringify({ sessionId: ids[9], title: '封存的桌面標題', isArchived: true, cwd: claudeOne }));

  writeFileSync(join(work, 'main.swift'), `
import Foundation
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + " " + detail); if !ok { exit(1) } }
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let roots = CoderImportCatalog.Roots(codexHome: base.appendingPathComponent("codex"), claudeProjects: base.appendingPathComponent("claude/projects"),
                                     claudeDesktopSessions: base.appendingPathComponent("desktop"), home: base.appendingPathComponent("work/home").path)
check("newest state db", CodexAppProjects.stateDatabase(in: roots.codexHome)?.lastPathComponent == "state_5.sqlite")
let codex = CoderImportCatalog.load(.codex, roots: roots)
check("codex order: pinned, project-order, remote skipped, projectless last", codex.map(\\.name) == ["釘選的專案", "第一個專案", "第二個專案", "空的專案", CoderImportCatalog.projectlessName], "\\(codex.map(\\.name))")
let first = codex[1]
check("codex titles: name, title, first message, preview; newest first", first.conversations.map(\\.title) == ["改過的名字", "Codex 取的標題", "只有第一句", "只有預覽"], "\\(first.conversations.map(\\.title))")
check("codex root and missing file", first.root.hasSuffix("/work/one") && first.conversations[2].fileExists == false && first.conversations[0].fileExists)
let all = Set(codex.flatMap(\\.conversations).map(\\.session.sessionID))
check("subagents, background, archived, spawned, nicknamed and empty threads are not listed", all == ["t1", "t2", "t3", "t4", "t12", "t13", "t14"], "\\(all.sorted())")
check("folder under a project root counts for it", codex[2].conversations.map(\\.session.sessionID) == ["t13"])
check("pinned project", codex[0].isPinned && codex[0].conversations.map(\\.session.sessionID) == ["t14"] && codex[3].conversations.isEmpty)
check("projectless group: explicit ids, Codex's own folder", codex[4].isProjectless && codex[4].conversations.map(\\.session.sessionID) == ["t12"] && codex[4].root.hasSuffix("/work/chats"), codex[4].root)
check("sessions are native, interactive, importable", codex.flatMap(\\.conversations).allSatisfy { CoderImport.eligible($0.session) && $0.session.engine == .codex })
check("per-project count and last activity", first.conversations.count == 4 && first.lastActivity == first.conversations.first?.activity)
check("projectless root falls back to the common folder", CodexAppProjects.projectlessRoot(hints: [], folders: ["/a/b/c", "/a/b/d/e"]) == "/a/b"
      && CodexAppProjects.projectlessRoot(hints: ["/x/y", "/x/y/", "/z"], folders: ["/a"]) == "/x/y" && CodexAppProjects.projectlessRoot(hints: [], folders: ["/a", "/b"]) == "")
check("immutable uri escapes the path", CodexAppProjects.immutableURI(URL(fileURLWithPath: "/tmp/a b/c#d?.sqlite")) == "file:/tmp/a%20b/c%23d%3F.sqlite?mode=ro&immutable=1", CodexAppProjects.immutableURI(URL(fileURLWithPath: "/tmp/a b/c#d?.sqlite")))
let claude = CoderImportCatalog.load(.claude, roots: roots)
check("claude projects: folder names, newest first, 家目錄, background-only folder hidden", claude.map(\\.name) == [CoderImport.homeProjectName, "claude-one"], "\\(claude.map(\\.name))")
let titles = Dictionary(uniqueKeysWithValues: claude.flatMap(\\.conversations).map { ($0.session.sessionID, $0.title) })
func id(_ n: Int) -> String { String(format: "%08d", n) + "-2222-4333-8444-555555555555" }
check("claude title order like its own session list: agent name, custom title, AI title, summary, first real message",
      titles[id(1)] == "代理名稱 c1" && titles[id(2)] == "自訂標題 c2" && titles[id(3)] == "AI 標題 c3" && titles[id(4)] == "摘要 c4" && titles[id(5)] == "c5 真的第一句", "\\(titles)")
check("a title line only in the tail of a big file", titles[id(10)] == "大檔尾巴的自訂標題", titles[id(10)] ?? "nil")
check("desktop app title wins for the same session", titles[id(8)] == "桌面標題 c8")
check("sidechain, -p, archived desktop session and subagent files are not listed", titles[id(6)] == nil && titles[id(7)] == nil && titles[id(9)] == nil && titles.count == 8, "\\(titles.count)")
check("claude project root is the session folder", claude[1].root.hasSuffix("/work/claude-one"))
if let c5 = claude[1].conversations.first(where: { $0.session.sessionID == id(5) }) {
    let preview = CoderImportCatalog.previewItems(c5.session)
    check("preview: talk only, no tool or command output", preview.items.map(\\.kind) == [.user, .assistant] && !preview.items.contains { $0.text.contains("TOOL-OUTPUT-MARKER") || $0.text.contains("指令輸出") || $0.text.contains("meta") }, "\\(preview.items.map(\\.text))")
} else { check("c5 listed", false) }
if let big = claude[1].conversations.first(where: { $0.session.sessionID == id(10) }) {
    let preview = CoderImportCatalog.previewItems(big.session, maxBytes: 64 * 1024)
    check("preview of a big file reads only its tail", preview.partial && !preview.items.isEmpty && preview.items.count <= CoderImportCatalog.previewRows)
} else { check("big listed", false) }
let cap = CoderImport.maxImportedBytesTotal
check("usage: silent until near the cap", CoderImportCatalog.nearCapNotice(used: 0) == nil && CoderImportCatalog.nearCapNotice(used: cap / 2) == nil
      && CoderImportCatalog.nearCapNotice(used: cap * 9 / 10)?.contains("快滿了") == true && CoderImportCatalog.nearCapNotice(used: cap)?.contains("已經滿了") == true)
// W181 審查：~/.codex、~/.claude 是捷徑；「已匯入」與「看原檔」用家別＋session id；同名不同資料夾不併。
let linkRoots = CoderImportCatalog.Roots(codexHome: base.appendingPathComponent("codex-link"), claudeProjects: base.appendingPathComponent("claude-link/projects"),
                                         claudeDesktopSessions: base.appendingPathComponent("desktop"), home: roots.home)
let linked = CoderImportCatalog.load(.codex, roots: linkRoots)
let linkedPaths = (codex + linked).flatMap(\\.conversations).filter(\\.fileExists).map(\\.session.url.path)
check("codex behind a symlink: same list; rollout paths (even ones Codex stored through the link) resolved",
      linked.map(\\.name) == codex.map(\\.name) && linkedPaths.count == 12 && linkedPaths.allSatisfy { !$0.contains("/codex-link/") }, "\\(linkedPaths)")
let linkedClaude = CoderImportCatalog.load(.claude, roots: linkRoots)
check("claude behind a symlink: same list, paths resolved", linkedClaude.map(\\.name) == claude.map(\\.name)
      && linkedClaude.flatMap(\\.conversations).allSatisfy { !$0.session.url.path.contains("/claude-link/") })
if let t2 = linked.flatMap(\\.conversations).first(where: { $0.session.sessionID == "t2" }) {
    let source = CoderImportSource(engine: "codex", sessionID: "t2", path: t2.session.url.path, title: "", cwd: "", sourceModifiedAt: Date(),
                                   importedAt: Date(), totalMessages: 0, keptMessages: 0)
    check("看原檔 finds the Codex one by engine + session id; the other engine never matches",
          CoderImportCatalog.locate(CoderImportFocus(source), in: codex)?.conversation.session.sessionID == "t2"
          && CoderImportCatalog.locate(CoderImportFocus(engine: .claude, sessionID: "t2", path: source.path), in: codex) == nil
          && CoderImportCatalog.locate(CoderImportFocus(engine: nil, sessionID: "", path: base.appendingPathComponent("codex-link/sessions/2026/09/20/rollout-2026-09-20T01-00-00-t2.jsonl").path), in: codex)?.conversation.session.sessionID == "t2")
    check("已匯入 uses the same key as E3's dedupe (engine + session id)", t2.importKey == source.dedupeKey)
} else { check("t2 listed through the link", false) }
let existing: [CoderImport.ProjectInfo] = [.init(id: UUID(), name: "工具", workdir: "/b/工具"), .init(id: UUID(), name: "TATWO OS", workdir: "/y/tatwo")]
let home = NSHomeDirectory()
check("placement: same folder reuses; same name elsewhere gets a distinct project; home → 家目錄; no root → by name",
      CoderImportCatalog.placement(name: "工具", root: "/a/工具", projects: existing, home: home) == CoderImportPlacement(name: "工具（a）", workdir: "/a/工具")
      && CoderImportCatalog.placement(name: "tatwo os", root: "/x/w181", projects: existing, home: home) == CoderImportPlacement(name: "tatwo os（w181）", workdir: "/x/w181")
      && CoderImportCatalog.placement(name: "別的名字", root: "/b/工具/", projects: existing, home: home) == CoderImportPlacement(name: "工具", workdir: "/b/工具")
      && CoderImportCatalog.placement(name: "隨便", root: home, projects: existing, home: home).name == CoderImport.homeProjectName
      && CoderImportCatalog.placement(name: "Tatwo Os", root: "", projects: existing, home: home) == CoderImportPlacement(name: "TATWO OS", workdir: "/y/tatwo")
      && CoderImportCatalog.placement(name: "新專案", root: "/c/new", projects: existing, home: home) == CoderImportPlacement(name: "新專案", workdir: "/c/new"))
`);
  const sources = ['Facade/CLITranscriptArchive.swift', 'Facade/CoderImport.swift', 'Facade/CoderImportCatalog.swift', 'Facade/CodexAppProjects.swift', 'Facade/ClaudeCodeProjects.swift'].map(app);
  const build = spawnSync('swiftc', ['-O', ...sources, join(work, 'main.swift'), '-o', join(work, 'probe')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const fixture = () => walk(work).filter(p => !/\/(main\.swift|probe)$/.test(p) && !/state_5\.sqlite-(shm)$/.test(p)).sort();
  const fingerprint = () => fixture().map(p => [p, sha(p), statSync(p).mtimeMs]);
  // Codex 開著（旁邊有 -wal／-shm）：照 SQLite 的規矩當讀者。
  const before = fingerprint();
  let run = spawnSync(join(work, 'probe'), [work], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal((run.stdout.match(/^PASS /gm) || []).length, 26, run.stdout);
  assert.deepEqual(fingerprint(), before);   // 原檔（含 state_5.sqlite 與 -wal）雜湊與修改時間都沒變
  // Codex 沒開（只剩主檔）：改用 immutable，照樣讀得到，也不建 -wal／-shm。
  for (const suffix of ['-wal', '-shm']) rmSync(db + suffix, { force: true });
  const closed = fingerprint();
  run = spawnSync(join(work, 'probe'), [work], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.ok(!existsSync(db + '-wal') && !existsSync(db + '-shm'), 'no sidecar files created');
  assert.deepEqual(fingerprint(), closed);
});
