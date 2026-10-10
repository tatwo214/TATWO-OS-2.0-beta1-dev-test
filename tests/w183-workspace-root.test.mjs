import test from 'node:test';
import {runIsolated} from './helpers/w187-runtime.mjs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// W183 R6c：ChatGPT 的工作區放在入口的 chatgpt/（使用者 09-28 裁決「SSD/AI/TATWO OS/chatgpt」；「chatgtp工作區也是tap的階段就要處理好了」）。
// 原始碼契約＋幾個功能測試（真的 git、真的 sandbox-exec；只在 macOS）。沙盒規則的功能測試在這裡用自己寫的一份規則（只證明實測腳本與
// Seatbelt 的行為）；正式規則產生器與執行鏈的完整反例矩陣在 App 自測 TATWO2_SELFTEST=w183hands（lead-verify 在 mini 跑）。
const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');
const swift = name => read(`App/Sources/Tatwo2/${name}`);
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  return source.slice(from, to < 0 ? source.length : to);
};
const root = swift('Facade/HandsWorkspaceRoot.swift');
const service = swift('Facade/HandsService.swift');
const rooms = swift('Facade/HandsRooms.swift');
const sandbox = swift('Facade/HandsSandbox.swift');
const policy = between(swift('Facade/TatwoEntry.swift'), 'enum ExternalWorkspacePolicy {', undefined);
const links = swift('Facade/HandsHardLinks.swift');
const cleanGit = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
const gitIn = dir => (...args) => spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=hands-fixture@localhost', ...args], { cwd: dir, encoding: 'utf8', env: cleanGit });

test('location: <entry>/chatgpt/workspaces from the App entry resolver; App Support when isolated, missing, read-only, network or cloud', () => {
  assert.match(root, /static let folderName = "chatgpt"/);
  assert.match(service, /workspaceEntry: ChatGPTHandsService\.allowedToRun\(environment: environment\) \? entry : nil\)   \/\/ W183 R6c/,
    'entry comes from TatwoEntry (no hard-coded path); self-test, staging and source test fall back');
  const location = between(root, 'func workspaceLocation()', 'func workspacesRoots()');
  for (const reason of ['"isolated"', '"entry_missing"', '"entry_not_directory"', '"entry_not_writable"', '"entry_in_denied_area"']) {
    assert.ok(location.includes(reason), reason);
  }
  assert.match(location, /access\(entry, W_OK\) == 0/);
  assert.match(location, /HandsPath\.storageProblem\(entry, home: runtime\.home\)/, 'network volumes and cloud sync folders fall back');
  assert.match(location, /return \.entry\(entry: entry, folder: folder, base: folder \+ "\/workspaces"\)/);
  assert.doesNotMatch(root + service + policy, /(?<!\/System)\/Volumes\/[A-Z]|AI\/TATWO OS\/chatgpt/, 'no hard-coded entry path (the /System/Volumes/Data alias is a system path)');
  // App 私用狀態留在 App Support（HandsPaths 的根沒變；工作區以外都照舊）。
  const settings = swift('Facade/HandsSettings.swift');
  for (const needle of ['var appDir: URL { root.appendingPathComponent("app"', 'var outputDir: URL { root.appendingPathComponent("output"',
    'var marksDir: URL { root.appendingPathComponent("marks"', 'var scratchDir: URL { root.appendingPathComponent("scratch"']) {
    assert.ok(settings.includes(needle), needle);
  }
  assert.match(settings, /FileManager\.default\.urls\(for: \.applicationSupportDirectory, in: \.userDomainMask\)\[0\]\s*\.appendingPathComponent\(rootFolderName/);
  assert.match(swift('Facade/HandsGatewayLaunch.swift'), /var settingsFile: URL \{ appDir\.appendingPathComponent\("settings\.json"\) \}/);
});

test('records remember where each workspace lives; a workspace is created only in the location that was just verified (review: stale location)', () => {
  assert.match(rooms, /var workspacesRoot: String\? = nil/);
  const open = between(rooms, 'func openWorkspace(', 'func archiveWorkspaceFolder(');
  assert.match(open, /let wsRoot = try workspacesBaseForNewWorkspace\(\)/);
  assert.match(open, /realDir == wsRoot \+ "\/" \+ id\.uuidString/);
  assert.match(open, /record\.workspacesRoot = wsRoot/);
  for (const reason of ['export_failed', 'manifest_failed', 'not_authorized']) {
    assert.ok(open.includes(`archiveWorkspaceFolder(id, base: wsRoot, reason: "${reason}")`), reason);
  }
  const resolve = between(rooms, 'func workspace(_ raw: String, grant:', 'func target(workspaceID:');
  assert.match(resolve, /guard let realWorkspaces = workspacesBase\(of: record\)/);
  assert.match(resolve, /realDir == realWorkspaces \+ "\/" \+ id\.uuidString/);
  const base = between(root, 'func workspacesBase(of record:', 'func workspaceRepoPath(');
  assert.match(base, /guard let stored = record\.workspacesRoot else \{ return HandsPath\.realpath\(paths\.workspacesDir\.path\) \}/, 'old records = App Support');
  assert.match(base, /real == stored, workspacesRoots\(\)\.contains\(real\)/);
  assert.match(swift('Facade/HandsReview.swift'), /worktree: service\.workspaceRepoPath\(record\)/);
  assert.match(service, /guard let record = workspaceStore\.record\(id\), let base = workspacesBase\(of: record\)/);
  // 位置取一次快照 → 只驗證那一個 → 只用驗證回來的 base（不再各自重算位置、不把 fallback 當成成功）。
  const newBase = between(root, 'func workspacesBaseForNewWorkspace()', 'func probeWorkspaceSandbox(');
  assert.match(newBase, /let \(base, problem\) = verifiedWorkspacesBase\(workspaceLocation\(\), forceProbe: false\)/);
  assert.match(newBase, /guard let base else \{ throw HandsToolError\.invalid\(problem\.map \{ "workspace_root_unavailable: " \+ \$0 \} \?\? "workspace_create_failed"\) \}/);
  assert.match(newBase, /return base\n/);
  const prepare = between(root, 'func prepareWorkspaceRoot()', 'func workspacesBaseForNewWorkspace()');
  assert.match(prepare, /let location = workspaceLocation\(\)\n\s*guard case \.entry = location else \{ return nil \}\n\s*return verifiedWorkspacesBase\(location, forceProbe: true\)\.problem/);
  const verify = between(root, 'func verifiedWorkspacesBase(', 'func prepareWorkspaceRoot()');
  assert.match(verify, /HandsWorkspaceRoot\.ensureFolder\(folder: folder, base: base\)\s*\?\? HandsWorkspaceRoot\.gitProblem\(folder: folder, entry: entry\)/,
    'git is re-checked every time (index or git identity changes invalidate the cache)');
  assert.match(verify, /if !HandsWorkspaceRoot\.wasProbed\(identity\) \{/);
  assert.match(verify, /guard HandsWorkspaceRoot\.identity\(entry: entry, folder: folder, base: base\) == identity else \{/, 'folder swapped during the probe = not verified');
  assert.match(root, /struct Probed: Equatable \{\s*let entry: String\s*let folder: String\s*let base: String\s*let device: Int32\s*let inode: UInt64/);
  assert.doesNotMatch(root, /stillPrepared/);
});

test('guard 1: chatgpt/.gitignore keeps normal git add out; the entry git is asked from the entry (never from a nested repo); backups refuse chatgpt/ history', () => {
  assert.match(root, /static let gitignoreText = "\*\\n"/);
  const ensure = between(root, 'static func ensureFolder(', 'static func gitProblem(');
  assert.match(ensure, /try HandsFiles\.ensureDirectory\(url\)/, 'lstat: a symlink or a file named chatgpt is refused');
  assert.match(ensure, /HandsPath\.realpath\(folder\) == folder/);
  assert.match(ensure, /try HandsFiles\.writeAtomically\(Data\(gitignoreText\.utf8\), to: ignore\)/);
  const git = between(root, 'static func gitProblem(', 'static func backupProblem(');
  assert.match(git, /if lstat\(folder \+ "\/\.git", &info\) == 0 \{ return Message\.gitNested \}/, 'a nested repo inside chatgpt/ is refused');
  assert.match(git, /try\? HandsGit\.run\(args, cwd: entry, timeout: 15, cap: 64 \* 1024\)/, 'every query runs from the entry');
  assert.doesNotMatch(git, /cwd: folder/);
  assert.match(git, /HandsPath\.isWithin\(entry, realTop\)/, 'the repository found is the entry (or its parent)');
  assert.match(git, /!HandsPath\.isWithin\(realGitDir, folder\)/);
  assert.match(git, /\["ls-files", "-z", "--stage", "--", ":\(icase\)" \+ folderName\]/, 'tracked files and gitlinks, any case');
  assert.match(git, /\["check-ignore", "-q", "--", probe\]/);
  assert.match(git, /folderName \+ "\/\.gitignore", folderName \+ "\/README\.md"/);
  assert.match(git, /if result\.status == 1 \{ return Message\.gitNotIgnored \}/);
  assert.match(git, /lstat\(entry \+ "\/\.git", &info\) == 0 \? Message\.gitUnchecked : nil/, 'an entry with .git that cannot be checked is refused');
  // 出口：入口備份推之前查這次會送出的所有提交。
  const backupCheck = between(root, 'static func backupProblem(', 'static let probeScript');
  assert.match(backupCheck, /"log", "--full-history", "--no-follow", "--format=%H",\s*"-n", "1", "HEAD", "--", ":\(icase\)" \+ folderName\]/);
  assert.match(backupCheck, /"-c", "diff\.ignoreSubmodules=none"/);
  assert.match(backupCheck, /return lines\.contains\(where: HandsGit\.isObjectID\) \? Message\.backupHistory : Message\.backupUnchecked/);
  const backup = swift('Facade/EntryBackup.swift');
  const push = between(backup, 'private func push(createIfMissing: Bool) async {', 'nonisolated static func createPrivateRepository(');
  const guardAt = push.indexOf('if let problem = await Task.detached(operation: { HandsWorkspaceRoot.backupProblem(entry: root) }).value {');
  assert.ok(guardAt > push.indexOf('try Self.ensureRepository(') && guardAt < push.indexOf('"push", remote, "HEAD:refs/heads/main"'), 'checked right before the push');
  assert.match(push, /statusLine = "GitHub 備份沒完成：" \+ problem\n\s*return/);
  // 主機端 git 一律加固（不讀使用者全域設定、hooks 關、fsmonitor 關）。
  assert.match(rooms, /env\["GIT_CONFIG_GLOBAL"\] = "\/dev\/null"/);
  assert.match(rooms, /static let hardening = \["-c", "core\.fsmonitor=false", "-c", "core\.hooksPath=\/dev\/null"/);
  // 入口本身的 .gitignore 範本本來就是「全部忽略、只收正本」。
  assert.match(backup, /static let gitignore = """\n    # 入口只追蹤文字正本；[^\n]*\n    \*\n/);
  // 文件不把 .gitignore 講成擋得住強制加入。
  const proposal = read('docs/specs/183-chatgpt-hands/os-amendment-chatgpt-folder.md');
  for (const text of [root, proposal]) {
    assert.doesNotMatch(text, /不進 git（`chatgpt\/\.gitignore` 是 `\*`）/);
    assert.match(text, /強制加入/);
  }
});

test('guard 1 functional: "*" in chatgpt/ is enough for normal git add; a nested repo lies; only --full-history sees a forced side-branch add', () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183-r6c-git-')));
  try {
    const git = gitIn(dir);
    assert.equal(git('init', '-q', '-b', 'main').status, 0);
    fs.writeFileSync(path.join(dir, '.gitignore'), '.DS_Store\n');
    fs.mkdirSync(path.join(dir, 'chatgpt/workspaces/w/repo'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'chatgpt/workspaces/w/repo/a.txt'), 'x\n');
    assert.equal(git('check-ignore', '-q', '--', 'chatgpt/workspaces/w/repo/a.txt').status, 1, 'without our file it would be collected');
    fs.writeFileSync(path.join(dir, 'chatgpt/.gitignore'), '*\n');
    assert.equal(git('check-ignore', '-q', '--', 'chatgpt/workspaces/w/repo/a.txt').status, 0);
    assert.equal(git('check-ignore', '-q', '--', 'chatgpt/.gitignore').status, 0, 'the .gitignore itself is not collected either');
    assert.equal(git('add', '-A').status, 0);
    assert.equal(git('ls-files', '--', 'chatgpt').stdout, '');
    assert.equal(git('commit', '-q', '-m', 'base').status, 0);
    // 強制加入擋不住（所以出口要再查）；從 chatgpt/ 裡的巢狀倉庫問，會說「沒有追蹤檔」（所以一律從入口問）。
    assert.equal(git('add', '-f', 'chatgpt/workspaces/w/repo/a.txt').status, 0);
    assert.match(git('ls-files', '-z', '--stage', '--', ':(icase)chatgpt').stdout, /chatgpt\/workspaces\/w\/repo\/a\.txt/);
    spawnSync('git', ['init', '-q'], { cwd: path.join(dir, 'chatgpt'), env: cleanGit });
    assert.equal(gitIn(path.join(dir, 'chatgpt'))('ls-files', '--', '.').stdout, '', 'the nested repo hides the entry index');
    assert.equal(git('reset', '-q').status, 0);
    fs.rmSync(path.join(dir, 'chatgpt/.git'), { recursive: true, force: true });
    // 側枝：強制加入再刪掉、合併回來。現在的索引是乾淨的；預設 log 看不到，--full-history 看得到。
    assert.equal(git('checkout', '-q', '-b', 'side').status, 0);
    assert.equal(git('add', '-f', 'chatgpt/workspaces/w/repo/a.txt').status, 0);
    assert.equal(git('commit', '-q', '-m', 'forced').status, 0);
    assert.equal(git('rm', '-q', '--cached', 'chatgpt/workspaces/w/repo/a.txt').status, 0);
    assert.equal(git('commit', '-q', '-m', 'removed').status, 0);
    assert.equal(git('checkout', '-q', 'main').status, 0);
    fs.writeFileSync(path.join(dir, 'os.md'), 'v2\n');
    assert.equal(git('add', 'os.md').status, 0);
    assert.equal(git('commit', '-q', '-m', 'os').status, 0);
    assert.equal(git('merge', '-q', '--no-edit', 'side').status, 0);
    assert.equal(git('ls-files', '--', 'chatgpt').stdout, '');
    assert.equal(git('log', '--format=%H', '-n', '1', 'HEAD', '--', ':(icase)chatgpt').stdout, '', 'default history simplification misses it');
    assert.match(git('-c', 'diff.ignoreSubmodules=none', 'log', '--full-history', '--no-follow', '--format=%H', '-n', '1', 'HEAD', '--', ':(icase)chatgpt').stdout,
      /^[0-9a-f]{40}\n$/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('guard 2: one shared policy (real path, any case, file identity) at the places that actually read, import, register or launch', () => {
  assert.match(policy, /static func contains\(_ path: String, entries: \[String\]\? = nil, resolvingLinks: Bool = true\) -> Bool/);
  assert.match(policy, /let lowered = candidate\.lowercased\(\)/, 'case-insensitive (APFS default)');
  assert.match(policy, /identities\.contains\(Identity\(info\)\)/, 'device + inode of chatgpt/ on any ancestor (aliases, case variants)');
  assert.match(policy, /var list = \[TatwoEntry\(environment: environment\)\.root\.path\]/, 'the App entry resolver, not a hard-coded path');
  // 同一個資料夾名稱；判定只靠 Foundation（放在 TatwoEntry.swift：既有的單獨編譯探針不用改檔案清單）。
  assert.match(policy, /static let folderName = "chatgpt"/);
  assert.doesNotMatch(policy.split('\n').filter(line => !line.trim().startsWith('//')).join('\n'), /Hands[A-Z]/, 'no dependency on the Hands files');
  assert.ok(!fs.existsSync(path.join(repo, 'App/Sources/Tatwo2/Facade/ExternalWorkspacePolicy.swift')));
  const scanner = swift('Facade/EngineRuleScanner.swift');
  assert.match(scanner, /where !EngineRuleAudit\.isNoise\(path\) && !path\.hasPrefix\(entryRoot\)\s*&& !inChatGPTWorkspace\(path, entryRoot: entryRoot\)/);
  assert.match(scanner, /if inChatGPTWorkspace\(path, entryRoot: entryRoot, resolvingLinks: true\) \{\s*items\.append\(\.init\(path: path, kind: kind, linkedToEntry: false, findings: \[chatGPTLinkFinding\]\)\)/,
    'a rule file linked into chatgpt/ is flagged and its content is not read');
  assert.match(scanner, /ExternalWorkspacePolicy\.contains\(path, entries: \[entryRoot\], resolvingLinks: resolvingLinks\)/);
  assert.doesNotMatch(scanner, /\.write\(|removeItem|moveItem|createSymbolicLink/, 'scanner never modifies files');
  // 技能：技能清單與技能目錄同一個判定（根、資料夾、SKILL.md）。
  const plugins = swift('Facade/PluginsSource.swift');
  assert.match(plugins, /if ExternalWorkspacePolicy\.contains\(root\) \{ continue \}/);
  assert.match(plugins, /guard Self\.skillAllowed\(folder: child, manifest: manifest\) else \{ continue \}\n\s*let canonical = manifest\.resolvingSymlinksInPath\(\)\.path/);
  assert.match(plugins, /!ExternalWorkspacePolicy\.contains\(folder\.path, entries: entries\) && !ExternalWorkspacePolicy\.contains\(manifest\.path, entries: entries\)/);
  const catalog = swift('Facade/TatwoSkillsDirectoryCatalog.swift');
  assert.match(catalog, /if ExternalWorkspacePolicy\.contains\(rootURL\.path\) \{ return \.init\(value: \[\]\) \}/);
  assert.match(catalog, /PluginsSource\.skillAllowed\(folder: child, manifest: manifest\)/);
  // 記憶：Claude 記憶提案、Claude／Codex 記憶併入入口。
  const userMemory = swift('Facade/UserMemory.swift');
  assert.match(userMemory, /if ExternalWorkspacePolicy\.contains\(memory\) \{ continue \}/);
  assert.match(userMemory, /guard !ExternalWorkspacePolicy\.contains\(file\), let text = try\? String\(contentsOf: file, encoding: \.utf8\)/);
  const memoryLinks = swift('Facade/EngineMemoryLinks.swift');
  for (const needle of ['if ExternalWorkspacePolicy.contains(dir) { continue }', 'if ExternalWorkspacePolicy.contains(from) { continue }',
    'if !ExternalWorkspacePolicy.contains(indexFile), let text = try? String(contentsOf: indexFile, encoding: .utf8) {',
    'guard directoryExists(paths.codexMemories), !ExternalWorkspacePolicy.contains(paths.codexMemories) else { return nil }',
    '&& !ExternalWorkspacePolicy.contains(path)']) {
    assert.ok(memoryLinks.includes(needle), needle);
  }
  // 專案與引擎啟動：新增既有資料夾、Coder 匯入不建在裡面；對話引擎與 CLI 分頁的 AI 不在裡面啟動；手腳的專案檢查。
  const model = swift('Facade/ChatPageModel.swift');
  assert.match(between(model, 'func createProjectFromExistingFolder()', 'func newChat()'),
    /if ExternalWorkspacePolicy\.contains\(url\.path\) \{ flashComposerHint\(ExternalWorkspacePolicy\.projectRefusal\); return nil \}[^\n]*\n\s*let pid = live\.newProject/);
  assert.match(between(model, 'func openCLITab(', 'func launchForCLI('),
    /if engine != \.generic, let problem = ExternalWorkspacePolicy\.engineProblem\(cwd: cwd\) \{ flashComposerHint\(problem\); return nil \}/);
  const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:'r11-external'});
  assert.match(output, /W183-external-workspace-refused-before-engine-launch/);
  assert.match(output, /W183-external-workspace-refusal-visible/);
  // 派工：不在 chatgpt/ 裡的專案建工作副本（房間的引擎也就不會在那裡跑）。Coder 匯入照 W180 裁決不改落點（只能看的紀錄），接著用就被上面擋。
  const refusedDispatch = runIsolated('w187fleet', {TATWO2_W187_R8:'r13-external-dispatch'}).output;
  assert.match(refusedDispatch, /W183-external-workspace-dispatch-refused-before-worktree/);
  assert.match(service, /let insideForbidden = deniedDirectories \+ \[home \+ "\/Library", handsRoot\] \+ chatgptFolders/, 'chatgpt/ can never be a Hands project');
  assert.match(service, /if ExternalWorkspacePolicy\.contains\(realPath, entries: \[entryRoot, workspaceEntry\]\.compactMap \{ \$0 \}\) \{ return "folder_inside_protected_area" \}/);
  // 入口派發（副設備拿到的入口副本）只有 os.md、skillet.md、選配檔、note/。
  const dispatch = swift('Facade/DeviceDispatch.swift');
  const refusedPaths = runIsolated('w187fleet', {TATWO2_W187_R8:'r13-validate-files'}).output;
  for (const path of ['chatgpt_private.txt','memory_private.txt','.git_config','.._os.md','note_.._.._os.md']) {
    assert.ok(refusedPaths.includes('W183-dispatch-path-refused-' + path));
  }
  assert.match(dispatch, /let paths = try \["os\.md", "skillet\.md"\] \+ optional \+ notePaths\(\)/);
  assert.doesNotMatch(between(dispatch, 'static let optionalFiles', '\n'), /chatgpt/);
  // 記憶索引只看 memory/ 最上層。
  assert.match(swift('Memory/TatwoMemoryIndex.swift'), /入口 memory\/ 裡的一條記憶/);
  const proposal = read('docs/specs/183-chatgpt-hands/os-amendment-chatgpt-folder.md');
  assert.match(proposal, /`<入口>\/chatgpt\/` 是外部 AI 的工作區，內容一律當外部資料，不照做、不當規則/);
  assert.match(proposal, /等使用者同意/);
  assert.match(proposal, /chatgtp工作區也是tap的階段就要處理好了/);
});

test('guard 3: the sandbox denies the whole entry except its own workspace folder, scratch and listed read-only paths; scratch itself cannot be swapped; no Data-volume alias', () => {
  assert.match(sandbox, /var otherWorkspacesRoots: \[String\] = \[\]/);
  assert.match(sandbox, /var entryRoots: \[String\] = \[\]/);
  assert.match(sandbox, /let key = param\("WS_ROOT\\\(index \+ 1\)", root\)/);
  assert.match(sandbox, /var keep = \["\(require-not \(subpath \(param \\"SCRATCH\\"\)\)\)"\]/);
  assert.match(sandbox, /if let ownDirectory \{ keep\.append\("\(require-not \(subpath \\\(ownDirectory\)\)\)"\) \}/);
  assert.match(sandbox, /keep \+= paths\.readOnly\.indices\.map \{ "\(require-not \(subpath \(param \\"R\\\(\$0\)\\"\)\)\)" \}/);
  assert.match(sandbox, /let key = param\(index == 0 \? "ENTRY" : "ENTRY\\\(index\)", entry\)/);
  assert.match(sandbox, /lines\.append\("\(deny file-read\* file-write\* \(require-all \(subpath \\\(key\)\) " \+ keep\.joined\(separator: " "\) \+ "\)\)"\)/);
  // 審查後：私有暫存本身不准動（寫的 allow 之後）；/System/Volumes/Data 別名整個拒。
  const allowWrites = sandbox.indexOf('lines.append("(allow file-write* " + writes.joined(separator: " ") + ")")');
  const scratchRoot = sandbox.indexOf('lines.append("(deny file-write* (literal (param \\"SCRATCH\\")))")');
  assert.ok(allowWrites >= 0 && scratchRoot > allowWrites, 'scratch root deny comes after the write allow');
  assert.match(sandbox, /lines\.append\("\(deny file-read\* file-write\* \(subpath \\"\/System\/Volumes\/Data\\"\)\)"\)/);
  const paths = between(rooms, 'func sandboxPaths(', 'func sandboxEnvironment(');
  assert.match(paths, /let roots = workspacesRoots\(\)/);
  assert.match(paths, /paths\.otherWorkspacesRoots = roots\.filter \{ \$0 != ownRoot \}/);
  assert.match(paths, /paths\.entryRoots = sandboxEntryRoots\(\)/);
  const entries = between(root, 'func sandboxEntryRoots()', 'func verifiedWorkspacesBase(');
  assert.match(entries, /HandsPath\.realpath\(candidate\)/, 'realpath (Seatbelt matches real paths; the mini entry is a symlink onto an external volume)');
  // 準備時的實測：正式規則、正式執行鏈、兩處各當一次自己；參數不拼進腳本；試寫的檔用亂數名稱；讀到 canary、有 LEAK、暫存被搬走就不開。
  const probe = between(root, 'func probeWorkspaceSandbox(', 'private func runWorkspaceProbe(');
  assert.match(probe, /let first = runWorkspaceProbe\(id: own, dir: ownDir, root: base,\s*targets: targets \+ \["o:" \+ neighborFile, "o:" \+ awayFile, "l:" \+ neighborFile, "l:" \+ awayFile\]\)/);
  assert.match(probe, /let second = runWorkspaceProbe\(id: away, dir: realAway, root: realFallback, targets: targets \+ \["o:" \+ neighborFile, "l:" \+ neighborFile\]\)/);
  assert.match(probe, /let writeTarget = entry \+ "\/\.tatwo-hands-probe-" \+ UUID\(\)\.uuidString/);
  assert.match(probe, /guard lstat\(writeTarget, &info\) != 0, !first\.out\.contains\(canary\), !second\.out\.contains\(canary\) else \{/);
  const run = between(root, 'private func runWorkspaceProbe(', undefined);
  assert.match(run, /sandboxPaths\(mode: \.worker, workspace: workspace, scratch: scratch, forHelper: false\)/);
  assert.match(run, /\["\/bin\/zsh", "-f", "-c", HandsWorkspaceRoot\.probeScript, "tatwo-hands-probe"\] \+ targets \+ \["m:" \+ scratch\]/);
  assert.match(run, /let result = HandsSandbox\.run\(profile: profile, command: command,/);
  assert.match(run, /guard out\.contains\("SELF_OK"\) else \{ return \(out, HandsWorkspaceRoot\.Message\.selfFailed\) \}/);
  assert.match(run, /guard !out\.contains\("LEAK"\), !leftovers, scratchKept else \{ return \(out, HandsWorkspaceRoot\.Message\.leak\) \}/);
  assert.match(root, /#if DEBUG\n\s*if let hook = testHook\.get\(\) \{ return hook\(\) \}\n\s*#endif/, 'test hooks are DEBUG only');
  assert.match(root, /#if DEBUG\n\s*if let edit = HandsWorkspaceRoot\.probeProfileEditForTesting\.get\(\) \{/);
  const targets = between(root, 'static func probeTargets(', 'extension HandsService');
  for (const target of ['"os.md"', '"agents.md"', '"user.md"', '"skillet.md"', '"device.json"', '"memory"', '".gitignore", "README.md"',
    '"/System/Volumes/Data" + path', 'path.uppercased()', '"s:" + (isFile(constitution)', '"d:" + folder + "/workspaces"', '"a:" + folder + "/" + name']) {
    assert.ok(targets.includes(target), target);
  }
  // 遮蔽：入口路徑（可能帶外接碟名字）換成代稱。
  assert.match(service, /list\.append\(\(entry, "<entry>"\)\)/);
});

test('guard 3 functional: the probe script reports every leak kind without a sandbox and nothing but SELF_OK inside a deny profile', {
  skip: process.platform !== 'darwin' || !fs.existsSync('/usr/bin/sandbox-exec') ? 'macOS sandbox-exec required' : false,
}, () => {
  const script = between(root, 'static let probeScript = """\n', '\n        """').split('\n').map(line => line.replace(/^ {8}/, '')).join('\n')
    .replace(/^static let probeScript = """\n/, '');
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183-r6c-probe-')));
  try {
    const entry = path.join(base, 'entry'), folder = path.join(entry, 'chatgpt');
    const ws = path.join(folder, 'workspaces/own'), other = path.join(folder, 'workspaces/other');
    for (const dir of [ws + '/repo', ws + '/scratch/tmp', other + '/repo', entry + '/memory']) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(entry, 'os.md'), 'constitution\n');
    fs.writeFileSync(path.join(entry, 'memory/m.md'), 'memory\n');
    fs.writeFileSync(path.join(folder, '.gitignore'), '*\n');
    fs.writeFileSync(path.join(other, 'repo/probe.txt'), 'CANARY-OTHER\n');
    const args = () => ['n:' + path.join(entry, '.probe-write'), 'o:' + path.join(other, 'repo/probe.txt'), 'l:' + path.join(other, 'repo/probe.txt'),
      'd:' + entry, 'f:' + path.join(entry, 'os.md'), 'd:' + path.join(entry, 'memory'), 'd:' + folder, 'a:' + path.join(folder, '.gitignore'),
      'f:/System/Volumes/Data' + path.join(entry, 'os.md'), 'f:' + path.join(entry, 'os.md').toUpperCase(), 's:' + path.join(entry, 'os.md'),
      'm:' + path.join(ws, 'scratch')];
    const open = spawnSync('/bin/zsh', ['-f', '-c', script, 'probe', ...args()], { cwd: ws + '/repo', encoding: 'utf8' });
    for (const needle of ['SELF_OK', 'LEAK_WRITE', 'LEAK_LINK', 'LEAK_OTHER', 'LEAK_READ', 'LEAK_SYMLINK', 'LEAK_MOVE', 'TATWO_PROBE_DONE']) {
      assert.ok(open.stdout.includes(needle), needle + '\n' + open.stdout);
    }
    assert.ok(fs.statSync(path.join(ws, 'scratch')).isDirectory(), 'the moved scratch is put back');
    fs.rmSync(path.join(entry, '.probe-write'), { force: true });
    const profile = [
      '(version 1)', '(deny default)', '(allow process-exec)', '(allow process-fork)', '(allow sysctl-read)', '(allow file-read-metadata)',
      '(allow file-read* (literal "/") (subpath "/usr") (subpath "/bin") (subpath "/System") (subpath "/private/var/db/dyld") (subpath "/private/etc") (literal "/dev/null") (subpath "/dev/fd") (subpath (param "WS")) (subpath (param "SCRATCH")))',
      '(allow file-write-data (require-all (path "/dev/null") (vnode-type CHARACTER-DEVICE)))',
      '(allow file-write* (subpath (param "WS")) (subpath (param "SCRATCH")))',
      '(deny file-write* (literal (param "SCRATCH")))',
      '(deny file-read* file-write* (require-all (subpath (param "WS_ROOT")) (require-not (subpath (param "WS_DIR")))))',
      '(deny file-read* file-write* (require-all (subpath (param "ENTRY")) (require-not (subpath (param "SCRATCH"))) (require-not (subpath (param "WS_DIR")))))',
      '(deny file-read* file-write* (subpath "/System/Volumes/Data"))',
      '(deny network*)',
    ].join('\n');
    const boxed = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, '-D', `WS=${ws}/repo`, '-D', `SCRATCH=${ws}/scratch`, '-D', `WS_ROOT=${path.dirname(ws)}`,
      '-D', `WS_DIR=${ws}`, '-D', `ENTRY=${entry}`, '/bin/zsh', '-f', '-c', script, 'probe', ...args()], { cwd: ws + '/repo', encoding: 'utf8' });
    assert.match(boxed.stdout, /SELF_OK/, boxed.stdout + boxed.stderr);
    assert.match(boxed.stdout, /TATWO_PROBE_DONE/);
    assert.doesNotMatch(boxed.stdout, /LEAK|CANARY/, boxed.stdout);
    assert.ok(!fs.existsSync(path.join(entry, '.probe-write')), 'the entry write was blocked');
    assert.equal(fs.readFileSync(path.join(folder, '.gitignore'), 'utf8'), '*\n');
    // 預先植入的硬連結：Seatbelt 只看路徑，同一條規則讀得到（所以 App 在跑之前掃描，見 HandsHardLinks）。
    fs.linkSync(path.join(entry, 'os.md'), path.join(ws, 'repo/planted.txt'));
    const planted = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, '-D', `WS=${ws}/repo`, '-D', `SCRATCH=${ws}/scratch`, '-D', `WS_ROOT=${path.dirname(ws)}`,
      '-D', `WS_DIR=${ws}`, '-D', `ENTRY=${entry}`, '/bin/cat', 'planted.txt'], { cwd: ws + '/repo', encoding: 'utf8' });
    assert.equal(planted.stdout, 'constitution\n', 'Seatbelt alone does not stop a pre-planted hard link');
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('review: pre-planted hard links are refused before any command, git diff or submit; scratch is prepared without following links', () => {
  assert.match(links, /static func outsideLink\(under root: String, limit: Int = 1_000_000, maxDepth: Int = 256\) throws -> String\?/);
  assert.match(links, /return links\.values\.filter \{ \$0\.found < \$0\.expected \}\.map \{ \$0\.path \}\.min\(\)/, 'a link whose other names are all inside is fine');
  assert.match(links, /openat\(fd, name, O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC\)/);
  assert.match(links, /fstatat\(fd, name, &info, AT_SYMLINK_NOFOLLOW\)/);
  assert.match(links, /if let path = try HandsHardLinks\.outsideLink\(under: workspace\.dir\) \{/);
  const jobs = swift('Facade/HandsJobs.swift');
  const start = between(jobs, 'func start(command: String, workspace: HandsWorkspace', 'final class Flag');
  assert.ok(start.indexOf('try service.requireNoOutsideLinks(workspace)') >= 0
    && start.indexOf('try service.requireNoOutsideLinks(workspace)') < start.indexOf('HandsSandbox.run('), 'run_command and job_start');
  const submit = between(rooms, 'func submitWorkspace(', 'func enforceDiskQuota(');
  assert.ok(submit.indexOf('try requireNoOutsideLinks(workspace)') > 0 && submit.indexOf('try requireNoOutsideLinks(workspace)') < submit.indexOf('git -c core.fsmonitor=false -c core.hooksPath=/dev/null add -A .'));
  assert.match(between(rooms, 'func gitDiff(', 'let rev: String'), /try requireNoOutsideLinks\(workspace\)/);
  // 私有暫存：固定上層 fd、逐段 openat（O_NOFOLLOW）、fchmod、最後比對路徑與 inode；磁碟監看只認已經在的暫存。
  const scratch = between(sandbox, 'static func prepareScratch(', 'static func developerDirectory()');
  assert.match(scratch, /let parentFD = Darwin\.open\(parent, O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC\)/);
  assert.match(scratch, /if mkdirat\(directory, name, 0o700\) != 0, errno != EEXIST/);
  assert.match(scratch, /let fd = openat\(directory, name, O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC\)/);
  assert.match(scratch, /fchmod\(fd, 0o700\)/);
  assert.doesNotMatch(scratch, /HandsFiles\.ensureDirectory\(url\)|chmod\(url/);
  assert.match(scratch, /HandsPath\.realpath\(expected\) == expected, fstat\(fd, &opened\) == 0, lstat\(expected, &named\) == 0/);
  assert.match(scratch, /opened\.st_dev == named\.st_dev, opened\.st_ino == named\.st_ino/);
  assert.match(service, /scratch: try HandsSandbox\.existingScratch\(URL\(fileURLWithPath: dir \+ "\/scratch", isDirectory: true\)\)\)/, 'disk monitor never creates or chmods');
});

test('TAP step: the switch flow prepares the workspace right before starting the gateway; auto-resume checks the same', () => {
  const setup = swift('Facade/HandsSetup.swift');
  const start = between(setup, 'private func stepStart', 'private func stepURL');
  const gate = start.indexOf('if let gate = authorizationGate() { return fail(.start, gate) }');
  const prepare = start.indexOf('if let problem = HandsWorkspaceRoot.prepare() { return fail(.start, problem) }   // W183 R6c');
  assert.ok(gate >= 0 && prepare > gate, 'after the confirmation gate');
  for (const later of ['dependencies.updateSettings', 'dependencies.startService()']) {
    assert.ok(start.indexOf(later) > prepare, `before ${later}: a failure stops at this step without turning anything on`);
  }
  assert.equal((setup.match(/W183 R6c/g) ?? []).length, 1, 'one small insertion point in HandsSetup (R6a edits the rest)');
  const gateway = swift('Facade/ChatGPTHandsService.swift');
  assert.match(gateway, /var prepareWorkspace: \(\) -> String\? = \{ HandsWorkspaceRoot\.prepare\(\) \}/);
  const prep = between(gateway, 'private func prepare(_ settings: HandsGatewayLaunch.Settings) -> Prepared?', 'private func start(_ prepared: Prepared)');
  const host = prep.indexOf('guard let host = HandsGatewayLaunch.validHost(settings.publicHost)');
  const workspace = prep.indexOf('if let problem = dependencies.prepareWorkspace() { fail(problem, fingerprint: fingerprint, retryable: true); return nil }   // W183 R6c');
  assert.ok(host >= 0 && workspace > host && prep.indexOf('bundledProgramDirectory()') > workspace, 'on the host only, before the gateway starts');
  // 失敗一句白話，不帶路徑、不帶程式錯誤碼。
  const messages = between(root, 'enum Message {', '}');
  for (const line of messages.split('\n').filter(l => l.includes('static let'))) {
    assert.doesNotMatch(line, /\/|_[a-z]+_|error/i, line);
  }
  // 自測接進 w183hands；註解不把 DEBUG 執行檔、staging 的結果講成裝好的 App 驗過。
  assert.match(swift('Facade/HandsAcceptance.swift'), /try await HandsWorkspaceAcceptance\.run\(\.init\(/);
  const acceptance = swift('Facade/HandsWorkspaceAcceptance.swift');
  assert.doesNotMatch(acceptance, /這裡就實測到了|entry\.hasPrefix\("\/Volumes\/"\) \? "外接碟"/);
  assert.match(acceptance, /\*\*這不等於裝好的 TATWO OS\.app 對真正的 `<入口>\/chatgpt\/` 驗過\*\*/);
  for (const label of ['開關流程：起關口前一定先準備工作區', '自動續跑：主機重開、開關開著起關口前也準備工作區', '不進入口的 git', '沙盒擋入口其他檔',
    '規則檔掃描：跳過入口的 chatgpt/', '記憶工具照常', '交件照常', '工作區位置：入口找不到、不可寫＝退回 App Support',
    '預先植入的硬連結', '私有暫存本身', '私有暫存（App 端）', '入口備份出口', '準備失敗：chatgpt/ 裡有自己的 git', '共用判定', '技能：', '記憶匯入：',
    '引擎啟動：', '位置：開工作區只驗證、只用那一次取的位置', '沙盒實測抓得到：私有暫存本身搬得走', '實測矩陣', '另一顆卷上的假入口']) {
    assert.ok(acceptance.includes(label), label);
  }
});
