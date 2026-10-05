// W179 M：讓 Claude、Codex 共用 TATWO 記憶（設定 › 開始使用＋設定 › OS）。
// 使用者 2026-09-26：「兩家的記憶可以像 agents.md 一樣從 os 接過去？」「這個記憶改動要寫到設定/開始使用裡面讓第一次進來的用戶可以快速設置」。
// 原始碼契約：settings 只合併單一鍵、TOML 最小改動、主索引上限、封存與還原.md、不碰真 HOME（路徑從參數或環境來）。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const links = read('Facade/EngineMemoryLinks.swift');
const acceptance = read('Facade/EngineMemoryLinksAcceptance.swift');

test('settings.json: only the autoMemoryDirectory key is merged, never re-serialized', () => {
  assert.match(links, /static let settingsKey = "autoMemoryDirectory"/);
  assert.match(links, /JSONMembers\.setting\(settingsKey, rawValue: JSONMembers\.quoted\(value\), in: original\)/);
  assert.match(links, /try JSONMembers\.verify\(old: original, new: updated, key: settingsKey, expected: value\)\n(\s*\/\/.*\n)?\s*record\.writtenSHA = sha256\(updated\)\n\s*manifest\.claude = record\n\s*try save\(manifest, archive\)\n\s*try writePreserving\(updated, to: paths\.claudeSettings\)/,
    'verify other keys unchanged, then record what will be written, then write');
  assert.match(links, /guard a\.isEqual\(b\) else \{ throw/, 'other keys must be equal');
  assert.doesNotMatch(links, /JSONSerialization\.data\(withJSONObject/, 'never re-serialize the whole settings file');
  assert.doesNotMatch(links, /autoMemoryEnabled"\] =|"autoMemoryEnabled":/, 'does not flip autoMemoryEnabled');
  // 寫回連結指向的真檔、保留權限
  assert.match(links, /let target = URL\(fileURLWithPath: path\)\.resolvingSymlinksInPath\(\)/);
  assert.match(links, /setAttributes\(\[\.posixPermissions: permissions\]/);
});

test('config.toml: minimal edits (generate_memories=false, [features] memories=true); use_memories untouched', () => {
  assert.match(links, /withTemplate: "\$1\\\(value\)"/, 'value replaced in place, rest of line kept');
  assert.match(links, /let feature = try TOMLMemories\.enableFeature\(original\)\n\s*let generate = try TOMLMemories\.disableGenerate\(feature\?\.data \?\? original\)/);
  assert.match(links, /try setting\("features", "memories", to: true, in: data\)/, 'Codex memory feature switch (default off) turned on');
  assert.match(links, /try setting\("memories", "generate_memories", to: false, in: data\)/);
  assert.match(links, /record\.writtenSHA = sha256\(data\)\n\s*manifest\.codex = record\n\s*try save\(manifest, archive\)\n\s*try writePreserving\(data, to: paths\.codexConfig\)/,
    'manifest records the edit and its sha before config.toml is written');
  assert.match(links, /\(\?!\[A-Za-z0-9_\]\)/);
  assert.doesNotMatch(links, /"use_memories = |use_memories = true\\n|use_memories = false\\n/, 'never writes use_memories');
  // 表已經用 dotted／行內表定義過：不再加第二個表頭；改完再讀一次
  assert.match(links, /var consistent: Bool \{ !inline && headers <= 1 && \(headers == 0 \|\| dottedLines\.isEmpty\) \}/);
  assert.match(links, /let line = "\\\(table\)\.\\\(written\)"/, 'dotted table gets a dotted line');
  assert.match(links, /guard self\.value\(of: key, table: table, in: after\) == value, check\.keyLines == 1, check\.consistent else \{/,
    'edited text re-checked before writing');
  assert.match(links, /static func codeMask/, 'multi-line strings are not config');
  assert.match(links, /case "replaced":\n\s*guard let original = edit\.original else \{ continue \}\n\s*lines\[index\] = original/,
    'restore puts the original line back');
});

test('index: main MEMORY.md within 200 lines / 25 KB, overflow to MEMORY-<source>.md; Codex summary 8 KB with marker', () => {
  assert.match(links, /static let maxIndexLines = 200/);
  assert.match(links, /static let maxIndexBytes = 25_000/);
  assert.match(links, /static let maxSummaryBytes = 8_192/);
  assert.match(links, /let file = "MEMORY-\\\(item\.section\.label\)\.md"/);
  assert.match(links, /spill\("MEMORY-tatwo\.md", moved\)/, 'an oversized existing index is trimmed too');
  assert.match(links, /static let marker = "由 TATWO OS 產生，勿手改"/);
  assert.match(links, /candidate = stem \+ "--" \+ label/, 'name clash gets a source suffix');
  assert.match(links, /if fm\.contentsEqual\(atPath: path, andPath: source\.path\) \{ return \(candidate, false\) \}/, 'identical files not duplicated');
  assert.match(links, /if \(try\? fm\.destinationOfSymbolicLink\(atPath: dir\.path\)\) != nil \{ continue \}/, 'skip project folders that are already links');
  assert.match(links, /\["memory_summary\.md", "MEMORY\.md", "raw_memories\.md", "rollout_summaries"\]/);
  assert.match(links, /var folder = "imports\/codex-\\\(device\)"/);
  // 匯入過沒有看內容，不看資料夾名稱；同一台的資料夾內容不同就放日期子資料夾
  assert.match(links, /for folder in previousCodexImports\(paths\.memory\) where compared\.allSatisfy\(\{ name in\n\s*fm\.contentsEqual/);
  assert.match(links, /guard !indexMentions\(folder\.relative, memory: paths\.memory\) else \{ return nil \}/);
  assert.match(links, /folder \+= "\/" \+ URL\(fileURLWithPath: uniquePath\(own\.appendingPathComponent\(dayStamp\(now\)\)\.path\)\)\.lastPathComponent/);
});

test('memory/ git: Codex raw records local-only, secret-looking files held back', () => {
  assert.match(links, /static let localOnlyRules = \["imports\/\*\*\/raw_memories\.md", "imports\/\*\*\/rollout_summaries\/"\]/);
  assert.match(links, /do \{ try ensureIgnoreRules\(memory\) \} catch \{/, 'rules appended even to an existing .gitignore before every commit');
  const commit = links.slice(links.indexOf('static func commit('), links.indexOf('static func staged('));
  assert.ok(commit.indexOf('ensureIgnoreRules') < commit.indexOf('"add", "-A"'), 'ignore rules before git add');
  assert.ok(commit.indexOf('hasSecret') > commit.indexOf('"add", "-A"') && commit.indexOf('hasSecret') < commit.indexOf('"commit", "-q"'),
    'secret check between add and commit');
  assert.match(commit, /"rm", "--cached"/);
  assert.match(commit, /guard Set\(staged\(memory, filter: nil\)\)\.isDisjoint\(with: held\) else \{/, 'never commits when a flagged file is still staged');
  assert.match(links, /#"-----BEGIN \(\?:\[A-Z \]\+ \)\?PRIVATE KEY-----"#/, 'same patterns as BotLibrary.validateContent');
  assert.match(links, /\.git\/info\/exclude/);
  // W180 E1b：commit 跟記憶自動同步、摘要重產共用一把鎖。
  assert.match(commit, /TatwoMemoryLock\.shared\.lock\(\); defer \{ TatwoMemoryLock\.shared\.unlock\(\) \}/);
});

test('archive first, 還原.md, manifest saved before every change; restore keeps memory/', () => {
  assert.match(links, /static let archivePrefix = "engine-memory-"/);
  for (const name of ['claude-projects/', 'claude-settings.json', 'codex-memories', 'codex-config.toml', 'manifest.json', '還原.md']) {
    assert.ok(links.includes(name), name);
  }
  const archived = links.indexOf('try writeRestoreNote(manifest');
  const settingsWrite = links.indexOf('try writePreserving(updated, to: paths.claudeSettings)');
  const configWrite = links.indexOf('try writePreserving(data, to: paths.codexConfig)');
  const move = links.indexOf('try fm.moveItem(atPath: source.dir.path, toPath: moved)');
  assert.ok(archived > 0 && archived < settingsWrite && archived < configWrite && archived < move, 'originals archived before any change');
  assert.match(links, /record\.moved\.append\(\.init\(original: source\.dir\.path, moved: moved\)\)\n\s*manifest\.claude = record\n\s*try save\(manifest, archive\)\n\s*try fm\.moveItem/,
    'each move recorded before it happens (half-done link can be restored)');
  assert.match(links, /try fm\.createSymbolicLink\(atPath: source\.dir\.path, withDestinationPath: paths\.memory\.path\)/);
  assert.match(links, /if let written = record\.writtenSHA, sha256\(current\) == written \{/, 'untouched files restored byte-for-byte from the archive');
  assert.match(links, /var restorable: Bool \{ restoredAt == nil && \(writtenSHA != nil \|\| !moved\.isEmpty\) \}/,
    'a failed attempt that changed nothing gives no restore button');
  assert.match(links, /record\.restorable \{\n\s*notes \+= try restoreClaude/);
  assert.match(links, /\} else if let value, pointsToMemory\(value, paths: paths\) \{/, 'half-done Claude link: our key is still undone');
  assert.match(links, /\} else if record\.edit != nil \|\| record\.featureEdit != nil \{/, 'half-done Codex link: our lines are still undone');
  assert.match(links, /JSONMembers\.removing\(settingsKey, in: current\)/, 'edited-after-link settings: only our key is undone');
  assert.doesNotMatch(links, /removeItem\(at: paths\.memory|removeItem\(atPath: paths\.memory/, 'restore leaves memory/ in place');
  assert.match(links, /-c", "user\.name=TATWO OS", "-c", "user\.email=tatwo-os@localhost"/, 'commits never carry the user e-mail');
  assert.match(links, /"commit\.gpgsign=false"/);
});

test('paths come from parameters or the environment; no real HOME in the self-test; no secrets logged', () => {
  assert.equal(links.match(/NSHomeDirectory\(\)/g)?.length, 1, 'NSHomeDirectory only as the EngineMemoryPaths default');
  assert.doesNotMatch(links, /homeDirectoryForCurrentUser/);
  for (const signature of [/static func scan\(paths: EngineMemoryPaths = EngineMemoryPaths\(\)\)/,
                           /static func refreshCodexSummary\(paths: EngineMemoryPaths = EngineMemoryPaths\(\)\)/,
                           /paths: EngineMemoryPaths = EngineMemoryPaths\(\), now: Date = Date\(\),\n\s*deviceName: String\? = nil/]) {
    assert.match(links, signature);
  }
  assert.doesNotMatch(links, /\bprint\(|NSLog\(|fputs\(/, 'settings/config contents never logged');
  assert.match(acceptance, /print\("W179MEMLINKS FAIL isolated HOME required"\)/);
  assert.match(acceptance, /getpwuid\(getuid\(\)\)/);
  assert.doesNotMatch(acceptance, /EngineMemoryPaths\(\)|EngineMemoryLinks\.scan\(\)|EngineMemoryLinks\.link\(\)|EngineMemoryLinks\.restore\(\)/,
    'self-test always passes explicit fake paths');
  assert.doesNotMatch(acceptance, /TatwoEntry\(\)/);
});

test('secondary: pinned host key clone from the primary, else local copy waiting for sync', () => {
  assert.match(links, /let pinned = record\.pinnedHostKeyFingerprint, pinned\.hasPrefix\("SHA256:"\)/);
  assert.match(links, /"StrictHostKeyChecking=yes"/);
  assert.doesNotMatch(links, /StrictHostKeyChecking=no|accept-new/, 'no TOFU');
  assert.match(links, /guard !Thread\.isMainThread else \{ return false \}/);
  // W180 E1b：pin 住主機金鑰的 git 環境抽出來，clone 與記憶自動同步的 fetch 共用同一套（clone 的行為不變）。
  assert.match(links, /return withPinnedPrimaryGit\(paths: paths, environment: environment\) \{ pinned -> Bool\? in/);
  assert.match(links, /static func withPinnedPrimaryGit<T>\(paths: EngineMemoryPaths,/);
  assert.match(links, /static let awaitingPrimaryMarker = "tatwo-awaiting-primary"/);
  assert.match(links, /if awaitingPrimarySync \{ parts\.append\("等主設備同步"\) \}/);
});

test('scan recognizes the lead\'s manual link (~ or absolute, entry itself a symlink)', () => {
  assert.match(links, /else if expanded\.hasPrefix\("~\/"\) \{ expanded = paths\.home \+ "\/" \+ expanded\.dropFirst\(2\) \}/);
  assert.match(links, /standardizedFileURL\.resolvingSymlinksInPath\(\)\.path/);
  assert.match(links, /let linked = exists && generate == false && marked && feature/, 'Codex linked = feature on + generate off + OS summary');
  assert.match(links, /TOMLMemories\.value\(of: "memories", table: "features", in: \$0\)/);
});

test('設定 › 開始使用: memory item right after the rules item, opens 設定 › OS', () => {
  const guide = read('Shell/SetupGuide.swift');
  const rules = guide.indexOf('"讓你的 AI 用同一套規則"');
  const memory = guide.indexOf('"讓你的 AI 共用一份記憶"');
  const device = guide.indexOf('"這台 Mac 的名字和身分"');
  assert.ok(rules > 0 && memory > rules && memory < device, 'order: rules → memory → device');
  assert.ok(guide.includes('Claude、Codex 各自記的東西合成一份，每個 AI 都讀得到；原本的會先備份'));
  assert.ok(guide.includes('TATWO OS 內建的 AI 之後會直接用這份記憶'));
  assert.match(guide, /state: memoryPending\.isEmpty \? \.done : \.todo, section: \.os, required: true\)\)/);
  assert.match(guide, /EngineMemoryWatcher\.shared\.start\(\)/, 'watcher starts with the checklist (app launch)');
  assert.doesNotMatch(guide, /borderedProminent|Color\.accentColor|\.blue\b/);
});

test('設定 › OS: 記憶 block with one row per engine, glass chips, read-only text', () => {
  const page = read('New/OSSettingsPage.swift');
  assert.match(page, /memorySection\n\s*if !peers\.isEmpty \{ peersSection \}/);
  assert.match(page, /Text\("記憶"\)\.font\(\.subheadline\.weight\(\.semibold\)\)/);
  assert.match(page, /OSChipButton\(title: "接上"\) \{ memoryConfirm = MemoryConfirm\(restore: false, row: row\) \}/);
  assert.match(page, /OSChipButton\(title: "還原"\) \{ memoryConfirm = MemoryConfirm\(restore: true, row: row\) \}/);
  assert.match(page, /Text\(memory\.folderLine\)\.font\(\.caption\)\.foregroundStyle\(\.secondary\)\.textSelection\(\.enabled\)/);
  assert.match(page, /memory = EngineMemoryLinks\.scan\(\)/);
  assert.match(page, /Task\.detached \{\n\s*let outcome = Result<\[String\], Error>/, 'link/restore off the main thread');
  assert.doesNotMatch(page, /borderedProminent|請 AI 整理|TextEditor/);
});

test('self-test entry and required checks', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w179memlinks" \{\n\s*exit\(EngineMemoryLinksAcceptance\.run\(\)\)/);
  for (const label of ['settings: only one key merged, other bytes untouched', 'toml: exactly one line changed',
    'main index within 200 lines / 25 KB', 'claude originals archived whole', 'codex summary generated with marker within 8 KB',
    'memory committed', 'scan after link: all linked', 'restore: settings.json byte-identical', 'restore: config.toml byte-identical',
    'restore: codex memories byte-identical', 'restore: claude folders back in place', 'manual link with ~/ path recognized',
    'manual link with absolute path recognized', 'mini layout (entry is a symlink) recognized', 'secondary without primary: local copy waits for sync',
    'name clash gets source suffix', 'summary refreshed after memory change',
    'toml: generate line changed in place, [features] memories appended, nothing else touched',
    'codex with [features] memories off is not linked', 'toml dotted memories table: no second [memories] header',
    'toml inline memories table refused', 'codex raw memories and rollout summaries stay out of git',
    'secret-looking file held back from git with a note', 'existing .gitignore gets the local-only rules appended',
    "lead's codex import under another folder name recognized by content: no second copy, no second pointer",
    'same device folder with other content: dated subfolder, nothing skipped', 'newer codex memories imported after restore',
    'failed attempt (nothing written) gives no restore button', 'restore skips a failed attempt and leaves the manual link alone',
    'half-done link: restore undoes the edited line']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.match(acceptance, /print\("W179MEMLINKS SUMMARY failures=\\\(check\.failures\)"\)/);
});
