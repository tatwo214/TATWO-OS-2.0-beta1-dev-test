import Darwin
import Foundation

// W183 R6c：ChatGPT 的沙盒工作區放在入口的 chatgpt/。
// 使用者 09-28：「這樣是不是在ssd/ai/tatwo os/建一個chatgpt資料夾讓他去做工作最好 這樣權限或者沙盒是可以的嗎？但記憶跟一些工作工具是不是就會受限？」
// 主導建議放在入口外（外部內容不跟憲法、記憶混在一起），使用者裁決放 `<入口>/chatgpt`；主導承諾三道防護（下面）。
// 使用者 09-28：「chatgtp工作區也是tap的階段就要處理好了」——TAP 開關那一步就準備好，不另外多一步給使用者看。
//
// - 位置：`<入口>/chatgpt/workspaces/<id>/{repo,scratch}`。入口找不到、不可寫、在網路磁碟或雲端同步資料夾、或在自測／staging：
//   退回 `<App Support>/TATWO OS Hands/workspaces`（照舊）。App 私用的狀態（app/、gateway/、cf-home/、cf-setup/、logs/、output/、marks/、
//   scratch/）一律留在 App Support，不進入口；金鑰、token 更不會。
// - 防護一（不進入口的 git）：建 chatgpt/ 時放 `chatgpt/.gitignore`（內容 `*`）：一般的 `git add` 不會收。每次準備都用入口自己的 git
//  （從入口查，不從 chatgpt/ 裡查；chatgpt/ 自己有 .git＝不開）確認真的忽略、索引裡 chatgpt 底下沒有已追蹤的檔或子模組（大小寫都算）。
//   .gitignore 擋不住強制加入（git add -f）和「以前收過又移掉」的歷史：入口備份推到 GitHub 之前（EntryBackup）再用 backupProblem
//   查這次會送出的所有提交，碰過 chatgpt 就不推。
// - 防護二（別的 AI 不讀它）：共用判定 ExternalWorkspacePolicy 套在規則檔掃描、技能、記憶匯入、專案建立、引擎啟動；
//   入口派發只帶 os.md、skillet.md、note/（DeviceDispatch）；憲法修改提案在 docs/specs/183-chatgpt-hands/os-amendment-chatgpt-folder.md。
// - 防護三（沙盒照樣鎖住）：規則裡整個入口讀寫都拒（自己的工作區資料夾、私有暫存、明列的唯讀路徑除外），兩處的其他工作區也拒；
//   路徑一律 realpath、用 -D 傳（HandsSandbox.profile）。準備時用正式的規則與執行鏈實測兩次（入口這處、App Support 那處各當一次「自己」）：
//   自己的檔寫得進、讀得回（外接碟權限）；入口的 os.md 等（含 /System/Volumes/Data 別名、大小寫變體、工作區裡指過去的捷徑）、
//   chatgpt/.gitignore 與說明檔、兩處的其他工作區都讀寫不到、硬連結不了；私有暫存本身搬不走——全部要擋住，不然就不開。
//   做不到不放寬沙盒、不改 TCC。主機上的程式預先放進工作區的硬連結沙盒擋不住（Seatbelt 只看路徑），由 HandsHardLinks 在跑之前擋。
// - 什麼時候準備：TAP 開關的流程（HandsSetup 起關口之前）、主機 App 重開開關開著自動續跑（ChatGPTHandsService 起關口之前）、
//   開工作區前（位置先取一次快照，只驗證、只用那一個；git 每次重查，沙盒實測在同一個資料夾（裝置、inode）上做過就沿用）。

enum HandsWorkspaceRoot {
    static let folderName = "chatgpt"
    static let gitignoreText = "*\n"
    static let readmeText = """
        # ChatGPT 手腳的工作區

        TATWO OS 自動建立（W183 R6c）。這裡是外部 AI（ChatGPT）在沙盒裡改檔、跑測試的地方。
        - 一般的 `git add` 不會收（`.gitignore` 是 `*`）；強制加入的，入口備份推到 GitHub 之前會被擋下、不推。不派發到其他設備。
        - 裡面的內容一律當外部資料：別的 AI 不照做、不當規則。
        - 成果只經 TATWO 的候選分支與審查合併；不要直接從這裡複製回專案。

        """

    /// 失敗時給使用者看的一句話（TAP 那一列顯示「出錯：〈這句〉」；入口備份顯示在備份那一列）。
    enum Message {
        static let folder = "入口裡的 chatgpt 資料夾建不起來（權限？或那裡已經有一個不是資料夾的 chatgpt）"
        static let gitUnchecked = "入口的 git 檢查不了（git 不能用？），確認不了 chatgpt 資料夾不會進備份"
        static let gitNotIgnored = "入口的 git 沒有忽略 chatgpt 資料夾，為了不讓 ChatGPT 的檔案進備份先不開"
        static let gitTracked = "入口的 git 已經收了 chatgpt 資料夾裡的檔案，先從入口的 git 移掉再按重試"
        static let gitNested = "入口的 chatgpt 資料夾裡有自己的 git，入口的檢查會查錯地方，先把它移走再按重試"
        static let probeFailed = "沙盒實測跑不起來，先不開"
        static let selfFailed = "沙盒在入口的 chatgpt 資料夾讀寫不到（外接碟權限？），先不開"
        static let leak = "沙盒擋不住入口的其他檔案，為了安全先不開"
        static let backupUnchecked = "入口的 git 歷史檢查不了，確認不了 chatgpt 資料夾不會被推上去，先不備份"
        static let backupHistory = "入口的 git 歷史裡有 chatgpt 資料夾（ChatGPT 的工作區）的檔案，為了不推到 GitHub 先不備份；把那些提交從入口的歷史拿掉再試"
    }

    /// 開關流程與自動續跑叫這裡。成功回 nil；失敗回一句白話。會跑 git 與沙盒實測：不要在主執行緒叫。
    static func prepare() -> String? {
        #if DEBUG
        if let hook = testHook.get() { return hook() }
        #endif
        return HandsService.shared.prepareWorkspaceRoot()
    }

    #if DEBUG
    /// 自測：換掉 prepare（看開關流程與自動續跑有沒有叫、失敗是不是停在那一步）。
    static let testHook = Box<(@Sendable () -> String?)?>(nil)
    /// 自測：把實測用的規則故意改鬆或改緊（證明實測真的抓得到「擋不住」與「讀寫不到」，不是永遠說好）。
    static let probeProfileEditForTesting = Box<(@Sendable (String) -> String)?>(nil)
    /// 自測：沙盒實測跑了幾次（證明換了資料夾會重測、沒換會沿用）。
    static let probeRunsForTesting = Box(0)
    #endif

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// 沙盒實測做過的那個 chatgpt 資料夾：入口、位置、資料夾的裝置與 inode 全部一樣才沿用（換了資料夾、入口搬了＝重測）。
    struct Probed: Equatable {
        let entry: String
        let folder: String
        let base: String
        let device: Int32
        let inode: UInt64
    }

    private static let probed = Box<[Probed]>([])

    /// 現在這個資料夾的身分（真的資料夾、是自己的、路徑都是真實路徑）；不是＝nil。
    static func identity(entry: String, folder: String, base: String) -> Probed? {
        var info = stat(), baseInfo = stat()
        guard HandsPath.realpath(entry) == entry, HandsPath.realpath(folder) == folder, HandsPath.realpath(base) == base,
              lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              lstat(base, &baseInfo) == 0, (baseInfo.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Probed(entry: entry, folder: folder, base: base, device: info.st_dev, inode: info.st_ino)
    }

    static func wasProbed(_ identity: Probed) -> Bool { probed.get().contains(identity) }

    static func markProbed(_ identity: Probed) {
        probed.set(probed.get().filter { $0.folder != identity.folder } + [identity])
    }

    static func forgetProbe(folder: String) {
        probed.set(probed.get().filter { $0.folder != folder })
    }

    /// 建 `<入口>/chatgpt/`（0700、不是捷徑、是自己的）、`.gitignore`（`*`）、說明檔、`workspaces/`。失敗回一句話。
    static func ensureFolder(folder: String, base: String) -> String? {
        do {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try HandsFiles.ensureDirectory(url)   // lstat：已經有東西但不是資料夾（含捷徑）、不是自己的＝丟錯
            guard HandsPath.realpath(folder) == folder else { throw HandsFileError.unsafe("chatgpt_folder_moved") }
            let ignore = url.appendingPathComponent(".gitignore")
            if HandsFiles.readSecure(ignore, limit: 4096).map({ String(decoding: $0, as: UTF8.self) }) != gitignoreText {
                try HandsFiles.writeAtomically(Data(gitignoreText.utf8), to: ignore)   // 是捷徑或特殊檔＝丟錯，不跟著寫
            }
            var info = stat()
            let readme = url.appendingPathComponent("README.md")
            if lstat(readme.path, &info) != 0 { try? HandsFiles.writeAtomically(Data(readmeText.utf8), to: readme) }
            try HandsFiles.ensureDirectory(URL(fileURLWithPath: base, isDirectory: true))
            guard HandsPath.realpath(base) == base else { throw HandsFileError.unsafe("workspaces_folder_moved") }
            return nil
        } catch {
            return Message.folder
        }
    }

    /// 入口的 git 真的忽略 chatgpt/（用入口自己的 .gitignore 與設定；不讀使用者全域設定，免得別處的規則把問題蓋掉）。
    /// W183 R6c 審查：一律從入口查（cwd＝入口、路徑用入口相對的 chatgpt/…），查到的倉庫必須是入口自己的（或入口的上層），
    /// git 資料夾不能在 chatgpt/ 裡；chatgpt/ 自己有 .git（巢狀倉庫會讓查詢變成查它自己）＝不開。索引裡 chatgpt 底下
    /// （大小寫都算）有一般檔或子模組（mode 160000）＝不開。入口不是 git 倉（也沒有上層的倉）＝沒有東西會被收，算過。不在主執行緒叫。
    static func gitProblem(folder: String, entry: String) -> String? {
        var info = stat()
        if lstat(folder + "/.git", &info) == 0 { return Message.gitNested }
        func git(_ args: [String]) -> (status: Int32, out: String, truncated: Bool)? {
            try? HandsGit.run(args, cwd: entry, timeout: 15, cap: 64 * 1024)
        }
        guard let top = git(["rev-parse", "--show-toplevel"]) else { return Message.gitUnchecked }
        if top.status != 0 { return lstat(entry + "/.git", &info) == 0 ? Message.gitUnchecked : nil }
        guard let realTop = HandsPath.realpath(top.out.trimmingCharacters(in: .whitespacesAndNewlines)), HandsPath.isWithin(entry, realTop),
              let gitDir = git(["rev-parse", "--absolute-git-dir"]), gitDir.status == 0,
              let realGitDir = HandsPath.realpath(gitDir.out.trimmingCharacters(in: .whitespacesAndNewlines)),
              !HandsPath.isWithin(realGitDir, folder) else { return Message.gitUnchecked }
        // 先看索引（子模組在 check-ignore 會直接報錯，先認出來給對的那句話）。
        guard let tracked = git(["ls-files", "-z", "--stage", "--", ":(icase)" + folderName]), tracked.status == 0 else {
            return Message.gitUnchecked
        }
        guard tracked.out.isEmpty, !tracked.truncated else { return Message.gitTracked }
        for probe in [folderName + "/.gitignore", folderName + "/README.md", folderName + "/workspaces/" + UUID().uuidString + "/repo/probe.txt"] {
            guard let result = git(["check-ignore", "-q", "--", probe]) else { return Message.gitUnchecked }
            if result.status == 1 { return Message.gitNotIgnored }
            if result.status != 0 { return Message.gitUnchecked }
        }
        return nil
    }

    /// W183 R6c 審查：入口備份推到 GitHub 之前（EntryBackup）。這次會送出的是 HEAD 走得到的所有提交（含合併進來的側枝）：
    /// 任何一個碰過 chatgpt（大小寫都算、含子模組）＝不推。--full-history：預設的歷史簡化會跳過「加了又刪掉」的側枝。
    /// 不讀使用者全域設定（HandsGit）；子模組變更照算。成功回 nil；失敗回一句白話。不在主執行緒叫。
    static func backupProblem(entry: String) -> String? {
        guard let result = try? HandsGit.run(["-c", "diff.ignoreSubmodules=none", "log", "--full-history", "--no-follow", "--format=%H",
                                              "-n", "1", "HEAD", "--", ":(icase)" + folderName], cwd: entry, timeout: 60, cap: 64 * 1024),
              result.status == 0, !result.truncated else { return Message.backupUnchecked }
        let lines = result.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return nil }
        return lines.contains(where: HandsGit.isObjectID) ? Message.backupHistory : Message.backupUnchecked
    }

    /// 沙盒實測的腳本（參數都用 $1…，不拼進腳本；cwd＝自己的 repo）。每個參數是「種類:路徑」：
    /// d＝列資料夾、f＝讀檔（丟掉內容）、o＝讀另一個工作區的檔（印出來：看有沒有 canary）、n＝新建檔、a＝以附加方式打開已有的檔（不寫內容）、
    /// l＝硬連結進來、s＝在工作區建一個指過去的捷徑再讀、m＝把私有暫存本身搬走。成功的一律印 LEAK_…（除了自己的讀寫：SELF_OK）。
    static let probeScript = """
        if print -r -- ok >| .tatwo-hands-probe 2>/dev/null && [[ "$(<.tatwo-hands-probe)" == ok ]]; then print SELF_OK; fi
        /bin/rm -f -- .tatwo-hands-probe
        for t in "$@"; do
          p=${t#?:}
          case $t in
            d:*) /bin/ls -a -- "$p" >/dev/null 2>&1 && print -r -- "LEAK_READ $p" ;;
            f:*) /bin/cat -- "$p" >/dev/null 2>&1 && print -r -- "LEAK_READ $p" ;;
            o:*) /bin/cat -- "$p" 2>/dev/null && print -r -- "LEAK_OTHER $p" ;;
            n:*) if print -r -- x >| "$p" 2>/dev/null; then print -r -- "LEAK_WRITE $p"; fi ;;
            a:*) if : >> "$p" 2>/dev/null; then print -r -- "LEAK_WRITE $p"; fi ;;
            l:*) if /bin/ln -- "$p" .tatwo-hands-probe-link 2>/dev/null; then print -r -- "LEAK_LINK $p"; /bin/rm -f -- .tatwo-hands-probe-link; fi ;;
            s:*) if /bin/ln -s -- "$p" .tatwo-hands-probe-sym 2>/dev/null; then
                   /bin/cat -- .tatwo-hands-probe-sym >/dev/null 2>&1 && print -r -- "LEAK_SYMLINK $p"
                   /bin/rm -f -- .tatwo-hands-probe-sym
                 fi ;;
            m:*) if /bin/mv -- "$p" .tatwo-hands-probe-moved 2>/dev/null; then
                   print -r -- "LEAK_MOVE $p"; /bin/mv -- .tatwo-hands-probe-moved "$p" 2>/dev/null
                 fi ;;
          esac
        done
        print TATWO_PROBE_DONE
        """

    /// 入口裡要確認讀寫不到的東西（有的才試）：入口本身、chatgpt/ 與 workspaces/、正本檔、memory/ 等、chatgpt/.gitignore 與說明檔；
    /// 另外用 /System/Volumes/Data 別名與全大寫的寫法各讀一次入口與 os.md（Seatbelt 比的是真實路徑：這裡實測），
    /// 在工作區裡建捷徑指到 os.md（或 .gitignore）再讀。
    static func probeTargets(entry: String, folder: String) -> [String] {
        var targets = ["d:" + entry, "d:" + folder, "d:" + folder + "/workspaces"]
        let fm = FileManager.default
        func isFile(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
        for name in ["os.md", "agents.md", "user.md", "skillet.md", "device.json", "todo.md", "issue.md"] where isFile(entry + "/" + name) {
            targets.append("f:" + entry + "/" + name)
        }
        for name in ["memory", "note", "gbrain"] {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: entry + "/" + name, isDirectory: &isDirectory), isDirectory.boolValue { targets.append("d:" + entry + "/" + name) }
        }
        for name in [".gitignore", "README.md"] where isFile(folder + "/" + name) {
            targets += ["f:" + folder + "/" + name, "a:" + folder + "/" + name]
        }
        let constitution = entry + "/os.md"
        var variants = ["d:" + entry]
        if isFile(constitution) { variants.append("f:" + constitution) }
        for variant in variants {
            let kind = String(variant.prefix(2)), path = String(variant.dropFirst(2))
            if !path.hasPrefix("/System/Volumes/Data/") { targets.append(kind + "/System/Volumes/Data" + path) }
            if path.uppercased() != path { targets.append(kind + path.uppercased()) }
        }
        targets.append("s:" + (isFile(constitution) ? constitution : folder + "/.gitignore"))
        return targets
    }
}

extension HandsService {
    /// 新工作區放哪（每次重算：外接碟可能晚掛上、被拔掉）。
    enum WorkspaceLocation: Equatable {
        /// 入口可以用：entry＝入口（realpath）、folder＝`<入口>/chatgpt`、base＝`<入口>/chatgpt/workspaces`。
        case entry(entry: String, folder: String, base: String)
        /// App Support（照舊）：自測／staging、入口找不到、不可寫、在網路磁碟或雲端同步資料夾。
        case fallback(base: String, reason: String)
    }

    func workspaceLocation() -> WorkspaceLocation {
        let fallback = HandsPath.canonical(paths.workspacesDir.path)
        guard let candidate = runtime.workspaceEntry else { return .fallback(base: fallback, reason: "isolated") }
        guard let entry = HandsPath.realpath(candidate) else { return .fallback(base: fallback, reason: "entry_missing") }
        var info = stat()
        guard stat(entry, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return .fallback(base: fallback, reason: "entry_not_directory") }
        guard access(entry, W_OK) == 0 else { return .fallback(base: fallback, reason: "entry_not_writable") }
        if let problem = HandsPath.storageProblem(entry, home: runtime.home) { return .fallback(base: fallback, reason: problem) }
        let folder = entry + "/" + HandsWorkspaceRoot.folderName
        // 不會踩到沙盒一律拒絕的地方（例如入口被設在秘密資料夾裡）。
        if runtime.deniedDirectories.contains(where: { HandsPath.overlaps($0, folder) }) { return .fallback(base: fallback, reason: "entry_in_denied_area") }
        return .entry(entry: entry, folder: folder, base: folder + "/workspaces")
    }

    /// 合法的 workspaces 位置：App Support 的（第一個，一定有）＋入口的（入口找得到就算，不管現在可不可寫：沙盒一樣要拒）。
    func workspacesRoots() -> [String] {
        var roots = [HandsPath.canonical(paths.workspacesDir.path)]
        if let entry = runtime.workspaceEntry.flatMap(HandsPath.realpath) {
            let base = entry + "/" + HandsWorkspaceRoot.folderName + "/workspaces"
            if !roots.contains(base) { roots.append(base) }
        }
        return roots
    }

    /// 紀錄記的 workspaces 位置（舊紀錄沒記＝App Support）。不是現在合法的位置、或被換成捷徑＝nil（當作搬走了）。
    func workspacesBase(of record: HandsWorkspaceRecord) -> String? {
        guard let stored = record.workspacesRoot else { return HandsPath.realpath(paths.workspacesDir.path) }
        guard let real = HandsPath.realpath(stored), real == stored, workspacesRoots().contains(real) else { return nil }
        return real
    }

    /// 施工卡要的工作區位置（照紀錄；找不到就用紀錄記的原樣）。
    func workspaceRepoPath(_ record: HandsWorkspaceRecord) -> String {
        (workspacesBase(of: record) ?? record.workspacesRoot ?? paths.workspacesDir.path) + "/" + record.id.uuidString + "/repo"
    }

    /// 沙盒規則裡整個拒絕的入口（realpath；外接碟晚掛上也算得到）。入口包住手腳資料夾或家目錄（設定錯了）就不加這條，免得連標記都讀不到。
    func sandboxEntryRoots() -> [String] {
        let hands = HandsPath.canonical(paths.root.path)
        var roots: [String] = []
        for candidate in [runtime.workspaceEntry, runtime.entryRoot].compactMap({ $0 }) {
            guard let real = HandsPath.realpath(candidate), !roots.contains(real),
                  !HandsPath.isWithin(hands, real), !HandsPath.isWithin(runtime.home, real) else { continue }
            roots.append(real)
        }
        return roots
    }

    /// W183 R6c 審查：驗證「這一個」位置（呼叫端先取好位置的快照；建立工作區只能用這裡回的 base）。
    /// App Support＝建好資料夾就好。入口＝建 chatgpt/、.gitignore、workspaces/；入口的 git 每次重查；沙盒實測在同一個資料夾
    ///（入口、位置、裝置、inode 都一樣）上做過就沿用，forceProbe（TAP 開關、自動續跑）一律重測；實測前後資料夾換了＝不算。
    /// 回（驗證過的 workspaces 位置, nil）或（nil, 一句話）；兩個都是 nil＝App Support 建不起來。
    func verifiedWorkspacesBase(_ location: WorkspaceLocation, forceProbe: Bool) -> (base: String?, problem: String?) {
        switch location {
        case .fallback(let base, _):
            guard (try? HandsFiles.ensureDirectory(URL(fileURLWithPath: base, isDirectory: true))) != nil,
                  let real = HandsPath.realpath(base) else { return (nil, nil) }
            return (real, nil)
        case .entry(let entry, let folder, let base):
            if forceProbe { HandsWorkspaceRoot.forgetProbe(folder: folder) }
            if let problem = HandsWorkspaceRoot.ensureFolder(folder: folder, base: base)
                ?? HandsWorkspaceRoot.gitProblem(folder: folder, entry: entry) {
                HandsWorkspaceRoot.forgetProbe(folder: folder)
                return (nil, problem)
            }
            guard let identity = HandsWorkspaceRoot.identity(entry: entry, folder: folder, base: base) else {
                HandsWorkspaceRoot.forgetProbe(folder: folder)
                return (nil, HandsWorkspaceRoot.Message.folder)
            }
            if !HandsWorkspaceRoot.wasProbed(identity) {
                if let problem = probeWorkspaceSandbox(entry: entry, base: base) {
                    HandsWorkspaceRoot.forgetProbe(folder: folder)
                    return (nil, problem)
                }
                guard HandsWorkspaceRoot.identity(entry: entry, folder: folder, base: base) == identity else {
                    HandsWorkspaceRoot.forgetProbe(folder: folder)
                    return (nil, HandsWorkspaceRoot.Message.folder)
                }
                HandsWorkspaceRoot.markProbed(identity)
            }
            return (base, nil)
        }
    }

    /// 準備入口的 chatgpt/（HandsWorkspaceRoot.prepare）：TAP 開關、自動續跑。放 App Support 的情況＝照舊，不用準備。
    func prepareWorkspaceRoot() -> String? {
        let location = workspaceLocation()
        guard case .entry = location else { return nil }
        return verifiedWorkspacesBase(location, forceProbe: true).problem
    }

    /// 開工作區：位置取一次快照、只驗證那一個、回驗證過的 workspaces 位置（realpath）。準備不過就不開。
    func workspacesBaseForNewWorkspace() throws -> String {
        let (base, problem) = verifiedWorkspacesBase(workspaceLocation(), forceProbe: false)
        guard let base else { throw HandsToolError.invalid(problem.map { "workspace_root_unavailable: " + $0 } ?? "workspace_create_failed") }
        return base
    }

    /// 用 ChatGPT 指令的同一條規則（worker）與同一條執行鏈（HandsSandbox.run）實測兩次：
    /// 1) 入口這處當自己：自己的檔寫得進、讀得回（外接碟權限）；入口的東西（別名、大小寫變體、捷徑都試）、chatgpt/.gitignore 與說明檔
    ///    讀寫不到；入口這處另一個工作區、App Support 那處的工作區讀不到、硬連結不了；私有暫存本身搬不走。
    /// 2) App Support 那處當自己：一樣讀不到入口的東西與入口這處的工作區。
    func probeWorkspaceSandbox(entry: String, base: String) -> String? {
        #if DEBUG
        HandsWorkspaceRoot.probeRunsForTesting.set(HandsWorkspaceRoot.probeRunsForTesting.get() + 1)
        #endif
        let fm = FileManager.default
        let folder = (base as NSString).deletingLastPathComponent
        let fallbackRoot = HandsPath.canonical(paths.workspacesDir.path)
        let own = UUID(), neighbor = UUID(), away = UUID()
        let ownDir = base + "/" + own.uuidString, neighborDir = base + "/" + neighbor.uuidString
        let awayDir = fallbackRoot + "/" + away.uuidString
        let marks = HandsPath.realpath(paths.marksDir.path)
        let writeTarget = entry + "/.tatwo-hands-probe-" + UUID().uuidString
        defer {
            for dir in [ownDir, neighborDir, awayDir] { try? fm.removeItem(atPath: dir) }
            unlink(writeTarget)   // 自己這次試寫的檔（名字是亂數）；寫進去了也當成沒擋住（下面先看過）
            if let marks { for id in [own, away] { unlink(marks + "/ws-" + id.uuidString) } }
        }
        let canary = "tatwo-hands-probe-" + UUID().uuidString
        let neighborFile = neighborDir + "/repo/probe.txt"
        guard fallbackRoot != base,
              (try? HandsFiles.ensureDirectory(URL(fileURLWithPath: ownDir + "/repo", isDirectory: true))) != nil,
              (try? HandsFiles.writeAtomically(Data(canary.utf8), to: URL(fileURLWithPath: neighborFile))) != nil,
              (try? HandsFiles.writeAtomically(Data(canary.utf8), to: URL(fileURLWithPath: awayDir + "/repo/probe.txt"))) != nil,
              let realAway = HandsPath.realpath(awayDir), let realFallback = HandsPath.realpath(fallbackRoot),
              realAway == realFallback + "/" + away.uuidString else { return HandsWorkspaceRoot.Message.probeFailed }
        let awayFile = realAway + "/repo/probe.txt"
        let targets = HandsWorkspaceRoot.probeTargets(entry: entry, folder: folder) + ["n:" + writeTarget]
        let first = runWorkspaceProbe(id: own, dir: ownDir, root: base,
                                      targets: targets + ["o:" + neighborFile, "o:" + awayFile, "l:" + neighborFile, "l:" + awayFile])
        if let problem = first.problem { return problem }
        let second = runWorkspaceProbe(id: away, dir: realAway, root: realFallback, targets: targets + ["o:" + neighborFile, "l:" + neighborFile])
        if let problem = second.problem { return problem }
        var info = stat()
        guard lstat(writeTarget, &info) != 0, !first.out.contains(canary), !second.out.contains(canary) else {
            return HandsWorkspaceRoot.Message.leak
        }
        return nil
    }

    /// 一次實測（dir＝這次當「自己」的暫時工作區 workspaces/<id>，底下 repo/ 已建；root＝它所在的 workspaces）。
    private func runWorkspaceProbe(id: UUID, dir: String, root: String, targets: [String]) -> (out: String, problem: String?) {
        guard let scratch = try? HandsSandbox.prepareScratch(URL(fileURLWithPath: dir + "/scratch", isDirectory: true)),
              HandsPath.realpath(dir) == dir, let repo = HandsPath.realpath(dir + "/repo") else {
            return ("", HandsWorkspaceRoot.Message.probeFailed)
        }
        let now = Date()
        let record = HandsWorkspaceRecord(id: id, grantID: "probe", projectID: id, projectName: "probe", title: "probe", baseSHA: "",
                                          workspaceBase: "", workspaceHead: nil, candidateSHA: nil, submittedBaseSHA: nil, status: "open",
                                          lockReason: nil, dependencies: [], baselineBytes: 0, createdAt: now, updatedAt: now, workspacesRoot: root)
        let workspace = HandsWorkspace(record: record, dir: dir, repo: repo, scratch: scratch)
        let (sandbox, developer) = sandboxPaths(mode: .worker, workspace: workspace, scratch: scratch, forHelper: false)
        let command = ["/bin/zsh", "-f", "-c", HandsWorkspaceRoot.probeScript, "tatwo-hands-probe"] + targets + ["m:" + scratch]
        var profile = HandsSandbox.profile(sandbox)
        #if DEBUG
        if let edit = HandsWorkspaceRoot.probeProfileEditForTesting.get() {
            profile = HandsSandbox.Profile(text: edit(profile.text), parameters: profile.parameters, marks: profile.marks)
        }
        #endif
        let result = HandsSandbox.run(profile: profile, command: command,
                                      environment: sandboxEnvironment(scratch: scratch, developer: developer), cwd: repo,
                                      timeout: 30, cpuSeconds: 15, fileSizeMB: 16, keep: 16 * 1024)
        let out = result.stdout.text()
        guard result.spawnError == nil, result.exitCode == 0, out.contains("TATWO_PROBE_DONE"), !result.stdout.truncated else {
            return (out, HandsWorkspaceRoot.Message.probeFailed)
        }
        guard out.contains("SELF_OK") else { return (out, HandsWorkspaceRoot.Message.selfFailed) }
        var info = stat()
        let leftovers = [".tatwo-hands-probe-link", ".tatwo-hands-probe-sym", ".tatwo-hands-probe-moved"].contains { lstat(repo + "/" + $0, &info) == 0 }
        let scratchKept = (try? HandsSandbox.existingScratch(URL(fileURLWithPath: dir + "/scratch", isDirectory: true))) == scratch
        guard !out.contains("LEAK"), !leftovers, scratchKept else { return (out, HandsWorkspaceRoot.Message.leak) }
        return (out, nil)
    }
}
