// W180 E1b：通用記憶 memory/ 的主副自動同步。
// 設計 docs/plans/W179-通用記憶設計.md「主設備與副設備」（09-26 定：自動、持續）；施工單 w180-e1b-sync、實作地圖 E1 第 7 步。
// 1) 合併規則（純邏輯）用 swiftc 單獨編譯實跑；2) 其餘是原始碼契約：協定順序、收件驗樹、一把鎖、不在主執行緒跑 git、信任表、狀態列。
// 真的兩個 git 倉＋注入傳輸的端到端在 App 自測 TATWO2_SELFTEST=w180memsync。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';
import { runIsolated } from './helpers/w187-runtime.mjs';
let memoryRuntime;
const realMemory = () => memoryRuntime ??= runIsolated('w180memsync').output;

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const sync = read('Memory/TatwoMemorySync.swift');
const merge = read('Memory/TatwoMemorySyncMerge.swift');
const row = read('Memory/TatwoMemorySyncStatusRow.swift');
const acceptance = read('Memory/TatwoMemorySyncAcceptance.swift');
const links = read('Facade/EngineMemoryLinks.swift');
const bridge = read('Facade/OSAgentBridge.swift');
const dispatchSource = read('Facade/DeviceDispatch.swift');
const between = (text, start, end) => {
  const from = text.indexOf(start);
  const to = text.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `${start} … ${end}`);
  return text.slice(from, to);
};
const inOrder = (text, needles, label) => {
  let at = -1;
  for (const needle of needles) {
    const next = text.indexOf(needle, at + 1);
    assert.ok(next > at, `${label}: ${needle} out of order or missing`);
    at = next;
  }
};

test('W180 E1b merge rules (production Swift compiled standalone)', {
  timeout: 180000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w180-memsync-');
  const checks = `
@main struct Checks {
    nonisolated(unsafe) static var failures = 0
    static func require(_ ok: Bool, _ label: String) {
        if ok { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
    }
    static func main() {
        typealias M = TatwoMemorySyncMerge
        let a = M.Entry(mode: "100644", id: "a"), b = M.Entry(mode: "100644", id: "b"), c = M.Entry(mode: "100644", id: "c")
        require(M.resolve(base: a, primary: a, secondary: b, path: "x.md") == .take(b), "only the secondary changed: take it")
        require(M.resolve(base: a, primary: b, secondary: a, path: "x.md") == .take(b), "only the primary changed: take it")
        require(M.resolve(base: a, primary: b, secondary: c, path: "x.md") == .both, "both changed: keep both versions")
        require(M.resolve(base: a, primary: nil, secondary: b, path: "x.md") == .take(b), "primary deleted, secondary edited: keep the edit")
        require(M.resolve(base: a, primary: b, secondary: nil, path: "x.md") == .take(b), "secondary deleted, primary edited: keep the edit")
        require(M.resolve(base: a, primary: a, secondary: nil, path: "x.md") == .take(nil), "a plain deletion on one side is kept")
        require(M.resolve(base: nil, primary: nil, secondary: c, path: "x.md") == .take(c), "unrelated histories: secondary-only file kept")
        require(M.resolve(base: nil, primary: b, secondary: nil, path: "x.md") == .take(b), "unrelated histories: primary-only file kept")
        require(M.resolve(base: nil, primary: b, secondary: c, path: "x.md") == .both, "unrelated histories: same name, both kept")
        require(M.resolve(base: nil, primary: b, secondary: c, path: "MEMORY.md") == .union, "index merged by lines")
        require(M.resolve(base: a, primary: b, secondary: c, path: "imports/x/.gitignore") == .union, ".gitignore merged by lines")
        require(M.resolve(base: a, primary: b, secondary: c, path: "notes/MEMORY.md") == .both, "only the top-level index is a line list")
        require(M.resolve(base: nil, primary: M.Entry(mode: "100755", id: "b"), secondary: b, path: "x.md") == .take(M.Entry(mode: "100755", id: "b")),
                "same content, different mode: primary wins, no copy")

        let header = "# 記憶索引\\n\\n說明\\n"
        require(M.unionLines(base: nil, primary: header + "- 主\\n", secondary: header + "- 副\\n") == header + "- 副\\n- 主\\n",
                "first sync: header once, both entries kept")
        require(M.unionLines(base: "# i\\n- a\\n- b\\n", primary: "# i\\n- a\\n- b\\n- p\\n", secondary: "# i\\n- b\\n- s\\n") == "# i\\n- b\\n- s\\n- p\\n",
                "secondary deletion applied, both additions kept")
        require(M.unionLines(base: "# i\\n- a\\n", primary: "# i\\n", secondary: "# i\\n- a\\n- s\\n") == "# i\\n- s\\n",
                "primary deletion stays deleted")
        require(M.unionLines(base: nil, primary: "x\\ny\\n", secondary: "x\\ny\\n") == "x\\ny\\n", "identical sides unchanged")
        let one = M.unionLines(base: "# i\\n", primary: "# i\\n- p\\n", secondary: "# i\\n- s\\n")
        require(one == M.unionLines(base: "# i\\n", primary: "# i\\n- p\\n", secondary: "# i\\n- s\\n") && one == "# i\\n- s\\n- p\\n",
                "union is deterministic (same on both devices)")

        require(M.copyPath(for: "shared.md", label: "Primary-One", day: "20260927", taken: []) == "shared--Primary-One-20260927.md",
                "copy name <name>--<device>-<date>.md")
        require(M.copyPath(for: "notes/a.md", label: "L", day: "20260927", taken: ["notes/a--L-20260927.md"]) == "notes/a--L-20260927-2.md",
                "copy name clash gets -2, stays in the same folder")
        require(M.copyPath(for: "a.md", label: "L", day: "20260927", taken: ["A--L-20260927.MD"]) == "a--L-20260927-2.md",
                "copy name clash is case-insensitive (macOS)")
        require(M.copyPath(for: ".tatwo/feedback.json", label: "", day: "20260927", taken: []) == ".tatwo/feedback--device-20260927.json",
                "non-Markdown keeps its extension; empty label falls back")
        require(M.isConflictCopy("shared--Primary-One-20260927.md") && M.isConflictCopy("notes/a--L-20260927-2.md")
                && !M.isConflictCopy("primary-first.md") && !M.isConflictCopy("note--claude-mini.md"),
                "conflict copies recognized by name")

        let note = "---\\nname: 晚餐\\nmetadata:\\n  type: user\\n---\\n\\n不吃香菜\\n"
        let marked = String(decoding: M.markConflict(Data(note.utf8), path: "dinner.md"), as: UTF8.self)
        require(marked == "---\\nconflict: \\"dinner.md\\"\\nname: 晚餐\\nmetadata:\\n  type: user\\n---\\n\\n不吃香菜\\n", "conflict marked in the front matter")
        require(M.markConflict(Data(marked.utf8), path: "dinner.md") == Data(marked.utf8), "already marked: unchanged")
        require(String(decoding: M.markConflict(Data("hello\\n".utf8), path: "x.md"), as: UTF8.self) == "---\\nconflict: \\"x.md\\"\\n---\\n\\nhello\\n",
                "no front matter: one is added")
        require(M.markConflict(Data("{}".utf8), path: "a.json") == Data("{}".utf8), "non-Markdown copies are byte-identical")
        require(M.markConflict(Data(note.utf8), path: "dinner.md") == M.markConflict(Data(note.utf8), path: "dinner.md"),
                "marker has no date or device: the same version is recognized later")

        func t(_ mode: String, _ type: String, _ path: String, id: String = "id1", size: Int? = 10) -> M.TreeEntry {
            M.TreeEntry(mode: mode, type: type, id: id, size: size, path: path)
        }
        require(M.problem(in: [t("100644", "blob", "a.md"), t("100755", "blob", "imports/x/run.md"), t("100644", "blob", ".gitignore")],
                          reference: [:]) == nil, "regular files accepted")
        require(M.problem(in: [t("120000", "blob", "a.md")], reference: [:])?.contains("連結檔") == true, "symlink rejected")
        require(M.problem(in: [t("160000", "commit", "sub", size: nil)], reference: [:])?.contains("子模組") == true, "submodule rejected")
        for bad in ["../x.md", ".git/config", ".GIT/config", "a/.g\\u{200C}it/hooks/x", "a//b.md", "./a.md", "/abs.md", "a\\nb.md"] {
            require(M.problem(in: [t("100644", "blob", bad)], reference: [:])?.contains("以外的路徑") == true, "outside path rejected: " + bad.debugDescription)
        }
        require(M.problem(in: [t("100644", "blob", ".gitattributes")], reference: [:])?.contains("git 設定檔") == true,
                "new .gitattributes rejected")
        require(M.problem(in: [t("100644", "blob", ".gitattributes")], reference: [".gitattributes": M.Entry(mode: "100644", id: "id1")]) == nil,
                "unchanged .gitattributes accepted")
        require(M.problem(in: [t("100644", "blob", "big.md", size: 9_000_000)], reference: [:])?.contains("太大") == true, "huge file rejected")

        let raw = "100644 blob aaaa      12\\tMEMORY.md\\u{0}120000 blob bbbb       9\\tlink.md\\u{0}160000 commit cccc       -\\tsub\\u{0}100644 blob dddd 5\\t記憶.md\\u{0}"
        let parsed = M.parseTree(Data(raw.utf8)) ?? []
        require(parsed.count == 4 && parsed[0].size == 12 && parsed[1].mode == "120000" && parsed[2].size == nil
                && parsed[3].path == "記憶.md", "ls-tree -r -z -l parsed (sizes, modes, UTF-8 names)")
        require(M.parseTree(Data("garbage\\u{0}".utf8)) == nil, "unreadable listing is unsafe")

        // W180 E1b 審查：一次拿掉太多先不套用。
        require(!M.massRemoval(removed: 2, total: 3) && !M.massRemoval(removed: 10, total: 500), "a few removals go through")
        require(M.massRemoval(removed: 11, total: 500) && M.massRemoval(removed: 3, total: 12) && !M.massRemoval(removed: 3, total: 15),
                "more than 10, or 3+ and over a fifth: held for confirmation")
        require(M.removed(from: ["a.md", "Foo.md", "keep.md"], to: ["keep.md", "foo.md"]) == ["a.md"],
                "removed paths ignore case-only renames (macOS)")
        // 大小寫、檔和資料夾同名。
        require(M.caseGroups(["Foo.md", "foo.md", "bar.md", "x/A.md", "x/a.md"]) == [["Foo.md", "foo.md"], ["x/A.md", "x/a.md"]],
                "case-only duplicates grouped")
        require(M.caseGroups(["cafe\\u{301}.md", "caf\\u{E9}.md"]).count == 1, "NFC and NFD spellings are the same file on macOS")
        require(M.layoutProblem(["a", "a/b.md"])?.contains("同名的檔和資料夾") == true, "file vs folder with the same name")
        require(M.layoutProblem(["A", "a/b.md"])?.contains("同名的檔和資料夾") == true, "file vs folder differing only in case")
        require(M.layoutProblem(["Notes/x.md", "notes/y.md"])?.contains("只差大小寫的資料夾") == true, "folders differing only in case")
        require(M.layoutProblem(["notes/x.md", "notes/y.md", "a.md"]) == nil, "normal layout accepted")
        require(M.problem(in: [t("100644", "blob", "Foo.md"), t("100644", "blob", "foo.md")], reference: [:])?.contains("只差大小寫") == true,
                "a tree with case-only duplicates is not accepted")
        require(M.problem(in: [t("100644", "blob", "a"), t("100644", "blob", "a/b.md")], reference: [:])?.contains("同名的檔和資料夾") == true,
                "a tree with a file and a folder of the same name is not accepted")
        // 擋住合併的檔（改過沒 commit、新檔、被忽略的）。
        require(M.blocking(changed: ["a.md", "b.md", "imports/x/raw.md", "c"], dirty: ["A.md", "imports/", "c/d.md", "zzz.md"])
                == ["a.md", "imports/x/raw.md", "c"], "blocking files: same file (any case), inside an ignored folder, or a folder in the way")
        require(M.names(["a.md", "b.md", "c.md"]) == "a.md、b.md 等 3 個" && M.names(["a.md"]) == "a.md", "short list of names")
        require(M.numbered("x/a.md", 2) == "x/a-2.md" && M.numbered("README", 3) == "README-3", "archive name clash numbering")
        // git cat-file --batch 的輸出。
        let batch = M.parseBatch(Data("aa blob 3\\nabc\\nbb commit 0\\n\\n".utf8), withContent: true)
        require(batch?.count == 2 && batch?[0].data == Data("abc".utf8) && batch?[1].type == "commit", "cat-file --batch parsed")
        require(M.parseBatch(Data("aa blob 9\\nabc\\n".utf8), withContent: true) == nil, "truncated batch is unsafe")
        require(M.parseBatch(Data("aa missing\\n".utf8), withContent: true) == nil, "missing object is unsafe")
        require(M.parseBatch(Data("aa blob 3\\nbb tree 20\\n".utf8), withContent: false)?.map(\\.size) == [3, 20], "batch-check parsed")
        print("W180MEMSYNC-MERGE SUMMARY failures=\\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, merge + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')], { encoding: 'utf8', timeout: 170000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [], { encoding: 'utf8', timeout: 30000 });
  assert.doesNotMatch(output, /^FAIL /m, output);
  assert.match(output, /W180MEMSYNC-MERGE SUMMARY failures=0/);
});

test("secondary protocol: commit \u2192 target \u2192 pinned fetch \u2192 check tree \u2192 merge \u2192 pushPinned inbox \u2192 signed receive", {timeout:240_000}, () => {
  const output = realMemory();
  assert.ok(output.includes("primary clears the inbox branch after merging"), "primary clears the inbox branch after merging");
  assert.ok(output.includes("back online: queued change sent"), "back online: queued change sent");
  assert.ok(output.includes("history without the secret: sync resumes"), "history without the secret: sync resumes");
});

test("signed calls to the primary are serialized: sequence numbers arrive in order", {timeout:240_000}, () => {
  const output = realMemory();
  assert.ok(output.includes("concurrent signed calls to the primary are serialized: none rejected as replayed"), "concurrent signed calls to the primary are serialized: none rejected as replayed");
});

test('primary receive: commit local first, exact inbox ref, only regular files, same merge rule, inbox cleared', () => {
  const receive = between(sync, 'case "memory_sync_receive":', '// MARK: 合併');
  assert.match(receive, /ref == Self\.inboxRef\(sender\), DeviceStatusReader\.validCommit\(commit\)/, 'sender comes from the verified signature');
  assert.match(receive, /guard keys == \["ref", "commit"\] \|\| keys == \["ref", "commit", "allowRemoving"\],/);
  assert.match(receive, /return try TatwoMemoryLock\.run \{/);
  inOrder(receive, ['EngineMemoryLinks.commit(memory', 'revParse(memory, ref) == commit', 'treeProblem(memory, commit: commit, reference: head)',
    'prepare(memory: memory, other: commit, otherIsPrimary: false', 'apply(prepared, memory: memory, local: "主設備", allowRemoving: allowed)',
    '"update-ref", "-d", ref, commit'], 'primary receive');
  // 主設備那邊的錯誤用主設備的角度說（副設備原樣顯示）。
  assert.match(receive, /throw Failure\(reason: "主設備：" \+ failure\)/);
  assert.match(receive, /catch let failure as Failure \{\n\s*throw Self\.onPrimary\(failure\)/);
  assert.match(sync, /guard available else \{ throw Failure\(reason: "主設備的記憶資料夾沒接上"\) \}/);
  // 一律關 hooks、作者固定 TATWO OS；合併用 ff-only 放進工作樹，會蓋到正在改的檔就停。
  assert.match(sync, /\["-c", "core\.hooksPath=\/dev\/null", "-c", "commit\.gpgsign=false", "-c", "user\.name=TATWO OS",\n\s*"-c", "user\.email=tatwo-os@localhost"/);
  assert.match(sync, /\["merge", "--ff-only", "--no-overwrite-ignore", "-q", commit\]/);
  assert.match(sync, /"commit-tree", treeID, "-p", head, "-p", other/, 'merge commit keeps both histories');
  assert.match(merge, /case "120000": return "有連結檔：/);
  assert.match(merge, /case "160000": return "有子模組：/);
  assert.match(merge, /if folded\(name\) == "\.git" \{ return false \}/);
});

test("never destructive: no reset --hard, no clean, no deleting user files", {timeout:240_000}, () => {
  assert.doesNotMatch(sync + merge, /"reset"|"clean"|"rm"|"checkout"|"restore"|"stash"|trashItem|"--force"|"-f"/);
  const removals = (sync + merge).split('\n').filter(line => line.includes('.removeItem('));
  assert.ok(removals.length >= 1);
  for (const line of removals) {
    assert.match(line, /awaitingPrimaryMarker|index\)|inputFile|at: folder\)/, `only the App's own marker and temp files: ${line.trim()}`);
  }
  const output = realMemory();
  assert.ok(output.includes("the primary refuses an unconfirmed mass deletion by itself"), "the primary refuses an unconfirmed mass deletion by itself");
  assert.ok(output.includes("after confirming: the primary archives them with a restore note, then removes them"));
  assert.ok(output.includes("after confirming here: archived first, then removed"));
  assert.ok(output.includes("rejected trees leave the primary working tree untouched"));
  assert.ok(output.includes("once the primary's file is gone, sync resumes"), "once the primary's file is gone, sync resumes");
});

test('macOS names: case-only duplicates keep both versions; file/folder clashes stop the round', () => {
  const prepare = between(sync, 'func prepare(memory: URL', 'func apply(_ prepared: Prepared');
  inOrder(prepare, ['for path in keepBoth', 'TatwoMemorySyncMerge.caseGroups(Array(result.keys))', 'try keepCopy(of: entry, path: path)',
    'TatwoMemorySyncMerge.layoutProblem(Array(result.keys))', 'writeTree(memory, result)'], 'prepare');
  assert.match(prepare, /let keep = group\.first \{ primaryTree\[\$0\] != nil && primaryTree\[\$0\] == result\[\$0\] \} \?\? group\[0\]/);
  assert.match(merge, /let paths = tree\.map\(\\\.path\)\n\s*if let group = caseGroups\(paths\)\.first/, 'incoming trees checked too');
});

test('secrets checked at the sync boundary (both sending and receiving), including history', () => {
  const problem = between(sync, 'func treeProblem(', 'static func looksSecret(');
  assert.match(problem, /return secretProblem\(memory, commit: commit, reference: reference\)/);
  assert.match(problem, /var arguments = \["rev-list", "--objects", commit\]\n\s*if let reference \{ arguments \+= \["--not", reference\] \}/);
  assert.match(problem, /\$0\.size <= TatwoMemorySyncMerge\.maxFileBytes/);
  assert.match(sync, /EngineMemoryLinks\.secretPatterns\.contains \{ text\.range\(of: \$0, options: \.regularExpression\) != nil \}/);
  assert.match(sync, /return finish\(\.failed, "這台的記憶" \+ problem \+ "，這輪不送"\)/);
});

test('errors in plain Chinese: real unknown error and fetch/push directions', {timeout:240_000}, () => {
  for (const scenario of ['memory-errors','memory-restricted-fetch','memory-push']) {
    const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:scenario});
    assert.match(output,/W187R8 SUMMARY failures=0/);
  }
});

test("one lock for commit / merge / write; watcher reads under it", {timeout:240_000}, () => {
  const output = realMemory();
  assert.ok(output.includes("commit waits for the shared memory lock"), "commit waits for the shared memory lock");
  assert.ok(output.includes("memory/ change reaches the primary within 10 seconds via the file watcher"), "memory/ change reaches the primary within 10 seconds via the file watcher");
});

test('timing: every 60 s, a change triggers within 10 s, background queue, never git on the main thread', () => {
  assert.match(sync, /static let interval: TimeInterval = 60/);
  const delay = Number(sync.match(/static let changeDelay: TimeInterval = (\d+(?:\.\d+)?)/)?.[1]);
  const latency = Number(sync.match(/FSEventStreamEventId\(kFSEventStreamEventIdSinceNow\), (\d+(?:\.\d+)?), flags/)?.[1]);
  assert.ok(delay + latency < 10, `change → sync within 10 s (${delay} + ${latency})`);
  assert.match(sync, /kFSEventStreamCreateFlagFileEvents/, 'in-place edits and subfolders are seen');
  assert.match(sync, /FSEventStreamSetDispatchQueue\(created, queue\)/);
  assert.match(sync, /!\$0\.contains\("\/\.git\/"\)/, 'our own .git writes do not retrigger');
  assert.match(sync, /let queue = DispatchQueue\(label: "ai\.tatwo\.tatwo2\.memory-sync", qos: \.utility\)/);
  const runGit = between(sync, 'static func runGit(', 'func revParse(');
  assert.match(runGit, /guard !Thread\.isMainThread else \{\n\s*count\(onMain: false\)\n\s*return GitResult\(status: -2/);
  assert.match(sync, /func runOnce\([^)]*\) -> TatwoMemorySyncStatus \{\n\s*guard !Thread\.isMainThread else \{/);
  assert.doesNotMatch(sync, /DispatchQueue\.main\.sync|onMain \{/);
  assert.match(sync, /if reason == \.change, before == committed, pendingCount\(memory\) == 0/, 'own merge writes do not hit the network again');
});

test('pinned git environment shared with clonePrimaryMemory (behaviour unchanged)', () => {
  const clone = between(links, 'static func clonePrimaryMemory(', 'struct PinnedPrimaryGit');
  assert.match(clone, /guard !Thread\.isMainThread else \{ return false \}/);
  assert.match(clone, /return withPinnedPrimaryGit\(paths: paths, environment: environment\) \{ pinned -> Bool\? in/);
  assert.match(clone, /"clone", "-q", "--",\n\s*"\\\(pinned\.destination\):\\\(remoteMemoryPath\)", staging\.path\]/);
  assert.match(clone, /\} \?\? false/);
  const pinned = between(links, 'static func withPinnedPrimaryGit<T>(', '// MARK: 小工具');
  for (const needle of ['let pinned = record.pinnedHostKeyFingerprint, pinned.hasPrefix("SHA256:")', '"StrictHostKeyChecking=yes"',
    '"HostKeyAlias=tatwo-paired-host"', 'env["GIT_SSH_COMMAND"]', 'defer { try? fm.removeItem(at: pin) }',
    'guard !Thread.isMainThread else { return nil }']) {
    assert.ok(pinned.includes(needle), needle);
  }
  assert.doesNotMatch(pinned, /StrictHostKeyChecking=no|accept-new/);
});

test("RPC trust: memory_sync_* need a device signature, never SSH remote control or staging read-only", {timeout:240_000}, () => {
  const output = realMemory();
  assert.ok(output.includes("receive only accepts the sender's own inbox ref"), "receive only accepts the sender's own inbox ref");
  assert.ok(output.includes("tampered device signature rejected"), "tampered device signature rejected");
  assert.ok(output.includes("trust tables: signed-device group only, not SSH remote control or staging read-only"));
});

test('status: @Published last sync / pending / conflicts / one-line error; glass row in 設定 › OS › 記憶; started at launch', () => {
  for (const field of [/var lastSync: Date\? = nil/, /var pending = 0/, /var conflicts = 0/, /var error: String\? = nil/,
    /@Published private\(set\) var status: TatwoMemorySyncStatus/, /static let shared = TatwoMemorySync\(\)/]) {
    assert.match(sync, field);
  }
  for (const words of ['"記憶資料夾沒接上"', '"主設備的記憶資料夾沒接上"', '"連不上主設備"', '"同步沒成功："', '"主設備・已記下"', '"已同步"']) {
    assert.ok(sync.includes(words), words);
  }
  assert.match(row, /@ObservedObject private var sync = TatwoMemorySync\.shared/);
  assert.match(row, /\.chatGlassChip\(\)/);
  assert.match(row, /\.lineLimit\(1\)/);
  assert.doesNotMatch(row, /borderedProminent|\.blue\b|Color\.accentColor|(?<!OSChip)Button\(|\.alert\(|confirmationDialog/);
  // 一次刪很多先不套用：玻璃 chip → 卡片內確認列（先不要／刪掉），不跳系統框。
  assert.match(row, /if status\.state == \.held, !confirming \{\n\s*OSChipButton\(title: status\.heldOutgoing \? "照樣送出" : "照樣套用"\)/);
  assert.match(row, /OSChipButton\(title: "先不要"\)/);
  assert.match(row, /OSChipButton\(title: "刪掉"\) \{\n\s*sync\.approveHeld\(\)/);
  assert.match(row, /\.chatLiquidSection\(cornerRadius: 12\)/);
  assert.match(sync, /"這台刪了 \\\(held\) 條記憶，先不送到主設備" : "另一台刪了 \\\(held\) 條記憶，先不套用到這台"/);
  assert.match(read('New/OSSettingsPage.swift'), /Text\(memory\.folderLine\)[^\n]*\n\s*TatwoMemorySyncStatusRow\(\) \/\/ W180 E1b/);
  assert.match(read('Shell/AppShell.swift'), /EngineMemoryWatcher\.shared\.start\(\)[^\n]*\n\s*TatwoMemorySync\.shared\.start\(\) \/\/ W180 E1b/);
});

test('self-test entry, isolation and required checks', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w180memsync" \{\n\s*exit\(TatwoMemorySyncAcceptance\.run\(\)\)/);
  assert.match(acceptance, /print\("W180MEMSYNC FAIL isolated HOME required"\)/);
  assert.match(acceptance, /getpwuid\(getuid\(\)\)/);
  assert.doesNotMatch(acceptance, /EngineMemoryPaths\(\)|TatwoEntry\(\)|TatwoMemorySyncEngine\.shared|DeviceDispatch\.shared/,
    'self-test never touches the real entry, memory or device state');
  for (const label of ['main thread: runOnce refused, no git on main', 'unrelated histories: both sides keep their files',
    'unrelated histories: MEMORY.md keeps both sides\' lines, header once', 'secondary add reaches the primary',
    'primary add reaches the secondary', 'primary receive commits what was written locally first; nothing lost',
    "both edited: primary version keeps the name, this device's version saved as <name>--<device>-<date>.md with conflict",
    'primary-side merge: same rule, primary version keeps the name, one copy',
    'repeated rounds: no duplicate copies, both sides identical', 'same pair of versions never copied twice (even on another day)',
    'offline: queued in the local git', 'back online: queued change sent', 'primary volume not mounted: quiet status, no error',
    'secondary: primary folder missing, change kept locally', 'symlink in the tree rejected', 'path outside memory/ (..) rejected',
    '.git folder (any case) rejected', 'submodule rejected', 'rejected trees leave the primary working tree untouched',
    "receive only accepts the sender's own inbox ref", 'tampered device signature rejected',
    'trust tables: signed-device group only, not SSH remote control or staging read-only',
    "this device's symlink is not sent, status says why", 'commit waits for the shared memory lock',
    'no user file lost on either side', 'memory/ change reaches the primary within 10 seconds via the file watcher',
    'no git on the main thread during any sync',
    'concurrent signed calls to the primary are serialized: none rejected as replayed',
    'primary app not updated yet: says so, not offline',
    "primary-side failure shown on the secondary in plain Chinese, from the primary's side, naming the file",
    "a held-back file blocks this device's merge: status names it, uploads still reach the primary",
    "names differing only in case (macOS): both versions kept, primary's keeps the name",
    'a file and a folder with the same name: stops and says so, nothing dropped',
    'a secret-looking file committed by hand is not sent to the primary',
    'removed in the latest version but still in history: still not sent',
    'this device deleted many notes: not sent until confirmed, the primary keeps them',
    'the primary refuses an unconfirmed mass deletion by itself',
    'after confirming: the primary archives them with a restore note, then removes them',
    'the other device deleted many notes: not applied here until confirmed',
    'after confirming here: archived first, then removed']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.match(acceptance, /print\("W180MEMSYNC SUMMARY failures=\\\(check\.failures\)"\)/);
});

// W180 E1b 實機（.014）：MacBook 的配對紀錄是舊格式、沒有 role 欄 → 以前一律「拉不到主設備的記憶」。
// 主設備由本機身分的 primaryDeviceID 決定（同 DeviceDispatch.primary()）；紀錄明寫別的角色才拒絕。
test('pinned memory git accepts a paired record without a role field (legacy pairing), rejects an explicit non-primary role', () => {
  const links = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/EngineMemoryLinks.swift', import.meta.url), 'utf8');
  const pinned = links.split('static func withPinnedPrimaryGit<T>(')[1].split('// MARK: 小工具')[0];
  assert.match(pinned, /\$0\.id\.lowercased\(\) == primaryID && \(\$0\.role == nil \|\| \$0\.role == \.primary\)/);
  assert.match(pinned, /identity\.role == \.secondary/);
});
