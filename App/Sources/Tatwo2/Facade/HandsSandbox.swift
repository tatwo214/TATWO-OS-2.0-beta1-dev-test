import Darwin
import Foundation

// W183 R1／R1b：ChatGPT 手腳的沙盒（威脅模型 T5、T6、T10、T11；接口 v3 V1、V2、V5、V7、V10、V11）。
//
// 做法參考 OpenAI Codex 的 macOS Seatbelt 政策（Apache-2.0，github.com/openai/codex 的 seatbelt 設計）：
// deny-default、一律用絕對路徑 /usr/bin/sandbox-exec、路徑用 -D 參數傳（不拼進規則文字）、工作區根目錄不能被刪。
// 規則文字是本檔自己寫的，沒有照抄 Codex 的 .sbpl 片段。
//
// 四種規則（Paths.Mode）：
// - worker：ChatGPT 的指令與寫檔小幫手。寫只限工作區（保護路徑除外）與私有暫存；讀系統工具鏈、工作區（含它自己的 .git，唯讀）。
// - readOnly：讀檔、搜尋、沙盒裡的 git status／diff。工作區只讀。
// - export：開工作區的匯出小幫手（git archive → tar → git init＋基準 commit）。讀正本的 git 物件（乾淨設定的影子 gitdir），寫工作區。
// - commit：交件小幫手（git add -A＋commit、diff --binary）。只准寫工作區的 .git。
// 共同：
// - V2：工具鏈只開系統（/System、/usr、/bin、/sbin、CommandLineTools、xcode-select 的開發者資料夾）與內附 Node；不開 Homebrew
//   （/opt/homebrew 不在允許清單、/usr/local 明確拒絕）。
// - V7：保護名稱在工作區任何一層都不准寫（建立、改名、刪除、捷徑、硬連結都算寫），大小寫都算（APFS 預設不分大小寫）：
//   .git、.gitattributes、.gitmodules、.tatwo2、.claude、.codex、.agents、.cursor、.vscode、.mcp.json，
//   指示文件 AGENTS.md、CLAUDE.md、GEMINI.md、.cursorrules、.windsurfrules、.github/copilot-instructions.md；
//   .github 資料夾本身不能建、改名、刪（裡面的其他檔可以改）；工作區根不能刪或改名。
// - 明確拒絕：~/.ssh、鑰匙圈、App Support/tatwo2、TATWO OS Hands 的私有區（設定、OAuth、輸出、關口）、其他工作區、
//   入口 memory/、user.md、device.json、引擎家目錄……（就算在允許的範圍裡）。
// - 網路全拒（含 unix socket：連不到 os.sock、browser.sock）；mach/XPC 查詢全拒；不准執行 open、osascript、security……
// - 行程數、CPU 時間、檔案大小：軟硬上限一起設（沙盒裡的指令調不回去），設不成功就不跑。
// - 標記：每次執行一個專屬標記、每個工作區一個、全體手腳一個（只有這些規則讀得到的空檔案）；照標記收掉脫離群組的行程。

enum HandsSandbox {
    static let sandboxExec = "/usr/bin/sandbox-exec"
    /// V7：工作區任何一層都擋寫（Seatbelt、檔案小幫手、交件驗證各擋一次；大小寫都算）。
    static let protectedNames: [String] = [".git", ".gitattributes", ".gitmodules", ".tatwo2", ".claude", ".codex", ".agents",
                                           ".cursor", ".vscode", ".mcp.json", "AGENTS.md", "CLAUDE.md", "GEMINI.md",
                                           ".cursorrules", ".windsurfrules"]
    /// 指示文件的完整相對路徑（任何一層底下）。
    static let protectedPaths: [String] = [".github/copilot-instructions.md"]
    /// 資料夾本身不能建立、改名、刪除（擋「把 .github 整個搬走、改完再搬回來」）；裡面其他檔可以改（CI 設定在審查卡醒目標出）。
    static let guardedDirectories: [String] = [".github"]

    static let deniedExecutables: [String] = [
        "/usr/bin/open", "/usr/bin/osascript", "/usr/bin/osacompile", "/usr/bin/security", "/bin/launchctl",
        "/usr/bin/ssh", "/usr/bin/scp", "/usr/bin/sftp", "/usr/bin/ssh-add", "/usr/bin/ssh-agent", "/usr/bin/sudo",
        "/usr/bin/su", "/usr/bin/login", "/usr/sbin/screencapture", "/usr/bin/shortcuts", "/usr/bin/automator",
        "/usr/bin/pbcopy", "/usr/bin/pbpaste", "/usr/bin/tccutil", "/usr/bin/defaults", "/usr/sbin/networksetup",
    ]
    static let defaultTimeout: TimeInterval = 45
    static let maxTimeout: TimeInterval = 600
    static let streamKeep = 32 * 1024

    // MARK: - 保護名稱（大小寫都算）

    /// 固定字串 → 不分大小寫的 Seatbelt regex 片段（字母寫成 [xX]、點寫成 [.]）。只用在固定名稱上，不含任何使用者路徑。
    static func caseInsensitivePattern(_ literal: String) -> String {
        var result = ""
        for character in literal {
            if character.isLetter, character.isASCII {
                result += "[\(character.lowercased())\(character.uppercased())]"
            } else if character == "." {
                result += "[.]"
            } else if character == "/" || character == "-" || character == "_" || character.isNumber {
                result.append(character)
            } else {
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return result
    }

    /// 任何一層是保護名稱（regex 比對整條路徑；搭配 (subpath WS) 只作用在工作區裡）。
    static var protectedPattern: String { "/(" + protectedNames.map(caseInsensitivePattern).joined(separator: "|") + ")(/|$)" }
    static var protectedPathPattern: String { "/(" + protectedPaths.map(caseInsensitivePattern).joined(separator: "|") + ")$" }
    static var guardedDirectoryPattern: String { "/(" + guardedDirectories.map(caseInsensitivePattern).joined(separator: "|") + ")$" }

    /// 相對路徑的每一段：是不是保護的（檔案小幫手、交件驗證、工具參數共用）。`creating`＝這條路徑本身要被建立或刪除
    ///（.github 資料夾本身算）。
    static func isProtected(components parts: [String], creating: Bool = true) -> Bool {
        let lowered = parts.map { $0.lowercased() }
        let names = Set(protectedNames.map { $0.lowercased() })
        if lowered.contains(where: names.contains) { return true }
        let joined = lowered.joined(separator: "/")
        for path in protectedPaths.map({ $0.lowercased() }) where joined == path || joined.hasSuffix("/" + path) { return true }
        if creating, let last = lowered.last, guardedDirectories.map({ $0.lowercased() }).contains(last) { return true }
        return false
    }

    static func isProtected(path: String) -> Bool {
        isProtected(components: path.split(separator: "/").map(String.init))
    }

    /// 工作區自己的路徑不能踩到保護規則（regex 比對整條路徑；祖先有保護名稱會把整個工作區鎖死）。
    static func pathClashesWithRules(_ path: String) -> Bool {
        // W183 R10 第二輪：金鑰類的規則也是比整條路徑（祖先是 .aws、secrets…＝整個工作區讀不到）：一樣不能踩。
        [protectedPattern, protectedPathPattern, guardedDirectoryPattern, HandsSecretFiles.seatbeltPattern].contains { pattern in
            path.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - 規則

    struct Paths: Equatable {
        enum Mode: Equatable { case worker, readOnly, export, commit }
        var mode: Mode
        /// 工作區（repo，realpath）；nil＝不碰工作區的小幫手（讀專案主線）。
        var workspace: String?
        /// 工作區所在的 workspaces/<id>（其他工作區一律拒）與 workspaces/ 根。
        var workspaceDir: String?
        var workspacesRoot: String?
        /// 私有暫存（可寫）：假 HOME、TMPDIR、各種快取。
        var scratch: String
        /// 另外可讀的：內附 node、小幫手程式、影子 gitdir、正本的 git 物件。
        var readOnly: [String] = []
        /// 明確拒絕的資料夾與檔案（就算在允許的範圍裡）。
        var deniedDirectories: [String] = []
        var deniedFiles: [String] = []
        /// Xcode.app 或 CommandLineTools（唯讀）。
        var developerRoot: String?
        /// 標記資料夾（<Hands>/marks）與這次屬於哪個工作區（工作區標記）。
        var marksDirectory: String?
        var workspaceMark: String?
        /// 只有 DEBUG 自測的檔案小幫手（Homebrew 的 node）會開；ChatGPT 的指令一律不開（V2）。
        var allowHomebrew = false
        /// W183 R1b（V7）：保護項目的上層資料夾（絕對路徑）：這些資料夾本身不准改名、刪除（worker 規則）。
        var protectedAncestors: [String] = []
        /// W183 R6c：另一個放工作區的位置（入口的 chatgpt/workspaces 或 App Support 的 workspaces）：裡面別的工作區一樣讀寫都拒。
        var otherWorkspacesRoots: [String] = []
        /// W183 R6c：入口（realpath）。除了自己的工作區資料夾、私有暫存與明列的唯讀路徑，入口裡的東西一律讀寫都拒。
        var entryRoots: [String] = []
    }

    struct Profile {
        let text: String
        let parameters: [(key: String, value: String)]
        /// 這次執行的標記（nil＝準備不起來：只靠整個群組收掉＋上限）。
        var marks: RunMarks? = nil
        var argv: [String] {
            var result = ["-p", text]
            for (key, value) in parameters { result += ["-D", "\(key)=\(value)"] }
            return result
        }
    }

    /// Seatbelt 規則。路徑全部走參數；規則文字裡只有固定的系統路徑與固定名稱。
    static func profile(_ paths: Paths) -> Profile {
        var parameters: [(key: String, value: String)] = []
        func param(_ key: String, _ value: String) -> String {
            parameters.append((key, value))
            return "(param \"\(key)\")"
        }
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process-exec)",
            "(allow process-fork)",
            "(allow signal (target same-sandbox))",
            "(allow process-info* (target same-sandbox))",
            // 工具鏈要的系統資訊（node 的 os 模組要 kern.hostname；輸出裡的主機名稱會被遮蔽）。
            "(allow sysctl-read (sysctl-name-prefix \"hw.\") (sysctl-name-prefix \"machdep.cpu.\") (sysctl-name-prefix \"kern.os\")"
                + " (sysctl-name \"kern.version\") (sysctl-name \"kern.hostname\") (sysctl-name \"kern.argmax\")"
                + " (sysctl-name \"kern.maxfilesperproc\") (sysctl-name \"kern.maxproc\") (sysctl-name \"kern.boottime\")"
                + " (sysctl-name \"kern.usrstack64\") (sysctl-name \"kern.secure_kernel\") (sysctl-name \"kern.hv_support\")"
                + " (sysctl-name \"sysctl.proc_cputype\") (sysctl-name \"sysctl.proc_translated\") (sysctl-name \"vm.loadavg\"))",
            "(allow ipc-posix-sem)",
            "(allow file-read-metadata)",
            // V2：系統工具鏈（不含 /opt/homebrew；/usr/local 在下面明確拒絕）。
            "(allow file-read* (literal \"/\") (subpath \"/usr\") (subpath \"/bin\") (subpath \"/sbin\") (subpath \"/System\")"
                + " (subpath \"/Library/Apple\") (subpath \"/Library/Developer/CommandLineTools\")"
                + " (subpath \"/private/var/db/dyld\") (subpath \"/private/var/db/timezone\") (literal \"/private/var/db/xcode_select_link\")"
                + " (subpath \"/private/var/select\") (subpath \"/private/etc\") (literal \"/Library/Preferences/com.apple.dt.Xcode.plist\")"
                + " (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/random\") (literal \"/dev/urandom\")"
                + " (literal \"/dev/dtracehelper\") (subpath \"/dev/fd\"))",
        ]
        var reads: [String] = []
        if let root = paths.developerRoot { reads.append("(subpath \(param("DEV_ROOT", root)))") }
        if let ws = paths.workspace { reads.append("(subpath \(param("WS", ws)))") }
        reads.append("(subpath \(param("SCRATCH", paths.scratch)))")
        for (index, path) in paths.readOnly.enumerated() { reads.append("(subpath \(param("R\(index)", path)))") }
        lines.append("(allow file-read* " + reads.joined(separator: " ") + ")")
        // 標記：只准讀這次的、這個工作區的與全體手腳的（掃描時認人用；control 誰都不准讀）。
        var marks: RunMarks?
        if let directory = paths.marksDirectory {
            marks = RunMarks.prepare(directory: directory, workspace: paths.workspaceMark)
            if let marks {
                var allowed = ["(literal \(param("MARK_RUN", marks.run)))", "(literal \(param("MARK_HANDS", marks.hands)))"]
                if let ws = marks.workspace { allowed.append("(literal \(param("MARK_WS", ws)))") }
                lines.append("(allow file-read-data " + allowed.joined(separator: " ") + ")")
            }
        }
        lines.append("(allow file-write-data (require-all (path \"/dev/null\") (vnode-type CHARACTER-DEVICE)))")
        var writes = ["(subpath (param \"SCRATCH\"))"]
        switch paths.mode {
        case .worker, .export:
            if paths.workspace != nil { writes.append("(subpath (param \"WS\"))") }
        case .commit:
            if let ws = paths.workspace { writes.append("(subpath \(param("WS_GIT", ws + "/.git")))") }
        case .readOnly:
            break
        }
        lines.append("(allow file-write* " + writes.joined(separator: " ") + ")")
        // W183 R6c 審查：私有暫存本身（不是裡面的檔）不准改名、刪除、換成捷徑、改權限——擋「把 scratch 換成指到入口的捷徑，等 App 下次
        // 準備暫存時把入口當成暫存放行」。裡面的檔照常可以寫（09-28 本機實測：裡面建立、改名、刪除都行；根改名、刪除、chmod 被拒）。
        lines.append("(deny file-write* (literal (param \"SCRATCH\")))")
        if paths.mode == .worker, paths.workspace != nil {
            // V7：任何層級、大小寫都算；建立、改名、捷徑、硬連結、刪除都是寫。
            lines.append("(deny file-write* (require-all (subpath (param \"WS\")) (regex #\"\(protectedPattern)\")))")
            lines.append("(deny file-write* (require-all (subpath (param \"WS\")) (regex #\"\(protectedPathPattern)\")))")
            lines.append("(deny file-write* (require-all (subpath (param \"WS\")) (regex #\"\(guardedDirectoryPattern)\")))")
            lines.append("(deny file-write-unlink (literal (param \"WS\")))")
            // W183 R10 第二輪（GPT-6 4；主導裁決「沙盒規則擋，不是事後遮罩」）：工作區裡金鑰類的路徑（任何一層、大小寫都算）
            // run_command、長工作、檔案小幫手一律讀不到內容（金鑰類資料夾也列不出裡面）、寫不了（建立、改名、捷徑、刪除都算）。
            // 名字本身（lstat）不擋：git 狀態照常，列表由工具那一層拿掉。git show 讀舊 blob 另外靠「匯出與依賴都濾過、舊工作區歷史有就鎖住」。
            // Seatbelt 的字串有長度上限：清單拆成幾段、一段一條（HandsSecretFiles.seatbeltPatterns）。
            // W183 R10 第三輪（GPT-6 5）：worker 能寫的每一處都照同一份清單拒讀拒寫——包括私有暫存（TMPDIR）：把金鑰類檔的中性上層資料夾
            // 搬到暫存區再讀，一樣讀不到（規則照整條路徑比，檔名還是金鑰類）。
            for pattern in HandsSecretFiles.seatbeltPatterns {
                lines.append("(deny file-read-data file-write* (require-all (subpath (param \"WS\")) (regex #\"\(pattern)\")))")
                lines.append("(deny file-read-data file-write* (require-all (subpath (param \"SCRATCH\")) (regex #\"\(pattern)\")))")
            }
            // W183 R1b：保護項目的上層資料夾本身（改名、刪除、搬走都算）：擋「整個搬到暫存區改完再搬回來」。裡面的其他檔照常可以寫。
            if !paths.protectedAncestors.isEmpty {
                let literals = paths.protectedAncestors.enumerated().map { "(literal \(param("PA\($0.offset)", $0.element)))" }
                lines.append("(deny file-write* " + literals.joined(separator: " ") + ")")
            }
        }
        if paths.mode == .readOnly, paths.workspace != nil {
            // W183 R10 第二輪：工作區的 git 狀態與差異（唯讀）也讀不到金鑰類的檔。
            for pattern in HandsSecretFiles.seatbeltPatterns {
                lines.append("(deny file-read-data (require-all (subpath (param \"WS\")) (regex #\"\(pattern)\")))")
            }
        }
        var ownDirectory: String?
        if let root = paths.workspacesRoot, let own = paths.workspaceDir {
            // 別的工作區（別的 grant 的也在這裡）：讀寫都拒。
            lines.append("(deny file-read* file-write* (require-all (subpath \(param("WS_ROOT", root))) (require-not (subpath \(param("WS_DIR", own))))))")
            ownDirectory = "(param \"WS_DIR\")"
        } else if let root = paths.workspacesRoot {
            lines.append("(deny file-read* file-write* (subpath \(param("WS_ROOT", root))))")
        }
        // W183 R6c：工作區可能在入口的 chatgpt/ 或 App Support（舊的、入口不能用時）：另一個位置的工作區也一律拒。
        for (index, root) in paths.otherWorkspacesRoots.enumerated() {
            let key = param("WS_ROOT\(index + 1)", root)
            lines.append(ownDirectory.map { "(deny file-read* file-write* (require-all (subpath \(key)) (require-not (subpath \($0)))))" }
                         ?? "(deny file-read* file-write* (subpath \(key)))")
        }
        // W183 R6c：入口（os.md、agents.md、user.md、memory/、skillet.md……）：自己的工作區資料夾、私有暫存、明列的唯讀路徑以外一律拒
        //（不只靠 deny default；以後誰多開了一個大範圍的讀，入口照樣擋）。
        var keep = ["(require-not (subpath (param \"SCRATCH\")))"]
        if let ownDirectory { keep.append("(require-not (subpath \(ownDirectory)))") }
        keep += paths.readOnly.indices.map { "(require-not (subpath (param \"R\($0)\")))" }
        for (index, entry) in paths.entryRoots.enumerated() {
            let key = param(index == 0 ? "ENTRY" : "ENTRY\(index)", entry)
            lines.append("(deny file-read* file-write* (require-all (subpath \(key)) " + keep.joined(separator: " ") + "))")
        }
        for (index, path) in paths.deniedDirectories.enumerated() {
            let key = param("D\(index)", path)
            lines.append("(deny file-read* file-write* (literal \(key)) (subpath \(key)))")
        }
        for (index, path) in paths.deniedFiles.enumerated() {
            lines.append("(deny file-read* file-write* (literal \(param("F\(index)", path))))")
        }
        if !paths.allowHomebrew { lines.append("(deny file-read* file-write* (subpath \"/usr/local\") (subpath \"/opt/homebrew\"))") }
        // W183 R6c 審查：/System 整個可讀，但 /System/Volumes/Data 是使用者資料那顆卷（/Users、/Volumes、/private 的另一條路）。
        // 09-28 本機實測：Seatbelt 比的是解開 firmlink 後的真實路徑（從這條別名讀家目錄、暫存的檔一樣被拒），這條是多一道：
        // 別名底下沒有 firmlink 的東西也不給讀寫。
        lines.append("(deny file-read* file-write* (subpath \"/System/Volumes/Data\"))")
        lines.append("(deny network*)")
        lines.append("(deny mach-lookup (xpc-service-name-prefix \"\"))")
        lines.append("(deny process-exec " + deniedExecutables.map { "(literal \"\($0)\")" }.joined(separator: " ") + ")")
        return Profile(text: lines.joined(separator: "\n") + "\n", parameters: parameters, marks: marks)
    }

    /// 沙盒裡的環境變數：白名單＋假 HOME／TMPDIR。App 自己的環境（金鑰、TATWO2_*、SSH_AUTH_SOCK、代理）一個都不帶。
    /// V2：PATH 只有系統、開發者資料夾與內附 node（沒有 Homebrew）。
    static func environment(scratch: String, marker: String, developerDir: String?, nodeBin: String?) -> [String: String] {
        // 開發者資料夾的 usr/bin 放最前面：git 等直接用真的執行檔，不經 /usr/bin 的 xcrun 轉接（轉接要跑 xcodebuild、很慢）。
        var path = (developerDir.map { [$0 + "/usr/bin"] } ?? []) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let nodeBin, !path.contains(nodeBin) { path.append(nodeBin) }
        let home = scratch + "/home", tmp = scratch + "/tmp", cache = scratch + "/cache"
        var env: [String: String] = [
            "PATH": path.joined(separator: ":"),
            "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/",
            "XDG_CACHE_HOME": cache, "XDG_CONFIG_HOME": scratch + "/config", "XDG_DATA_HOME": scratch + "/data",
            "npm_config_cache": cache + "/npm", "npm_config_offline": "true", "npm_config_ignore_scripts": "true",
            "CLANG_MODULE_CACHE_PATH": cache + "/clang",
            "SWIFTPM_MODULECACHE_OVERRIDE": cache + "/swiftpm", "PIP_CACHE_DIR": cache + "/pip",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "CI": "1", "NO_COLOR": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat",
            "TATWO_HANDS_RUN": marker,
        ]
        // zsh 沒有 LOGNAME 會自己去拿登入名稱；給固定的帳號名，使用者名稱不進沙盒。
        let account = "tatwo-hands"
        env["USER"] = account
        env["LOGNAME"] = account
        if let developerDir { env["DEVELOPER_DIR"] = developerDir }
        return env
    }

    /// 私有暫存：資料夾 0700，底下 home、tmp、cache、config、data。
    /// W183 R6c 審查（TOCTOU）：沙盒裡的指令寫得到暫存裡面，所以這裡當作「隨時可能被動過」：上層用 realpath 固定並開著，之後逐段
    /// mkdirat／openat（O_NOFOLLOW，捷徑一律拒）、權限用 fchmod（不跟隨捷徑）；最後確認回傳的路徑就是「上層/名字」、
    /// 而且跟開著的那個資料夾是同一個（裝置、inode）。不是＝丟錯（不開工作區、不把別的地方當暫存放行）。
    static func prepareScratch(_ url: URL) throws -> String {
        let parentURL = url.deletingLastPathComponent()
        try HandsFiles.ensureDirectory(parentURL)
        guard let parent = HandsPath.realpath(parentURL.path) else { throw HandsFileError.unsafe("scratch") }
        let parentFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw HandsFileError.unsafe("scratch") }
        defer { close(parentFD) }
        let scratchFD = try ownedDirectory(in: parentFD, url.lastPathComponent)
        defer { close(scratchFD) }
        for sub in ["home", "tmp", "cache", "config", "data"] {
            let fd = try ownedDirectory(in: scratchFD, sub)
            close(fd)
        }
        return try sameDirectory(scratchFD, at: parent + "/" + url.lastPathComponent)
    }

    /// 已經在的私有暫存（不建、不改權限：跑指令時的磁碟監看、指令跑完的檢查用）。不在、不是自己的資料夾、被換掉＝丟錯。
    static func existingScratch(_ url: URL) throws -> String {
        guard let parent = HandsPath.realpath(url.deletingLastPathComponent().path) else { throw HandsFileError.unsafe("scratch") }
        let expected = parent + "/" + url.lastPathComponent
        let fd = Darwin.open(expected, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HandsFileError.unsafe("scratch_missing") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw HandsFileError.unsafe("scratch") }
        return try sameDirectory(fd, at: expected)
    }

    /// 在開著的資料夾裡建（已經有就沿用）並打開一個子資料夾：不跟隨捷徑、必須是自己的真資料夾；權限有群組／其他人的位元就改成 0700。
    private static func ownedDirectory(in directory: Int32, _ name: String) throws -> Int32 {
        if mkdirat(directory, name, 0o700) != 0, errno != EEXIST { throw HandsFileError.unsafe("scratch_create") }
        let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HandsFileError.unsafe("scratch_not_directory") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            close(fd)
            throw HandsFileError.unsafe("scratch_not_owned")
        }
        if (info.st_mode & 0o077) != 0, fchmod(fd, 0o700) != 0 {
            close(fd)
            throw HandsFileError.unsafe("scratch_mode")
        }
        return fd
    }

    /// 路徑的真實位置就是 expected，而且跟開著的 fd 是同一個資料夾。
    private static func sameDirectory(_ fd: Int32, at expected: String) throws -> String {
        var opened = stat(), named = stat()
        guard HandsPath.realpath(expected) == expected, fstat(fd, &opened) == 0, lstat(expected, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw HandsFileError.unsafe("scratch_moved")
        }
        return expected
    }

    /// Xcode／CommandLineTools：照 xcode-select 的順序找（它設定的連結 → /Applications/Xcode.app → CommandLineTools），
    /// 不跑指令。回（開發者資料夾, 允許讀的根）。
    static func developerDirectory() -> (developer: String, root: String)? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink("/private/var/db/xcode_select_link", &buffer, buffer.count - 1)
        let candidates = (length > 0 ? [String(cString: buffer)] : [])
            + ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        guard var developer = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        if let real = HandsPath.realpath(developer) { developer = real }
        if let range = developer.range(of: ".app/") { return (developer, String(developer[..<range.lowerBound]) + ".app") }
        return (developer, developer)
    }

    // MARK: - 執行

    struct Captured: Sendable {
        var head = Data()
        var tail = Data()
        var total = 0
        var truncated: Bool { total > head.count + tail.count }

        mutating func append(_ chunk: Data, keep: Int) {
            total += chunk.count
            var rest = chunk
            if head.count < keep {
                let take = min(keep - head.count, rest.count)
                head.append(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
            guard !rest.isEmpty else { return }
            tail.append(rest)
            if tail.count > keep { tail = tail.suffix(keep) }
        }

        /// 頭尾各一段；中間省略的寫明省略多少位元組。（原文，只給 App 自己解析用；回給 ChatGPT、寫進房間一律用 redactedText。）
        func text() -> String {
            let first = String(decoding: head, as: UTF8.self)
            guard !tail.isEmpty else { return first }
            let omitted = total - head.count - tail.count
            let middle = omitted > 0 ? "\n…（中間省略 \(omitted) 位元組）…\n" : ""
            return first + middle + String(decoding: tail, as: UTF8.self)
        }

        /// 先處理切點、再遮蔽（T10）：頭段結尾與尾段開頭剛好切在切點上的那個字（到空白為止）整個丟掉，
        /// 秘密跨在切點上時兩邊都不會留下沒遮到的半截；頭段、尾段各自遮蔽，尾段另擋「前面被切掉的私鑰後半段」。
        func redactedText(_ redact: (String) -> String) -> String {
            let omitted = total - head.count - tail.count
            guard omitted > 0 else { return redact(String(decoding: head + tail, as: UTF8.self)) }
            let first = Self.throughLastSpace(head), last = Self.fromFirstSpace(tail)
            let dropped = head.count - first.count + tail.count - last.count
            let middle = "\n…（中間省略 \(omitted + dropped) 位元組；切點上沒切完的字一併拿掉）…\n"
            return redact(String(decoding: first, as: UTF8.self)) + middle
                + redact(HandsRedactor.redactKeyTail(String(decoding: last, as: UTF8.self)))
        }

        static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

        /// 到最後一個空白為止（沒有空白＝整段都是沒切完的字，丟掉）。
        static func throughLastSpace(_ data: Data) -> Data {
            guard let index = data.lastIndex(where: isSpace) else { return Data() }
            return Data(data[data.startIndex...index])
        }

        /// 從第一個空白開始（沒有空白＝整段都是沒切完的字，丟掉）。
        static func fromFirstSpace(_ data: Data) -> Data {
            guard let index = data.firstIndex(where: isSpace) else { return Data() }
            return Data(data[index...])
        }
    }

    struct RunResult: Sendable {
        var exitCode: Int32?
        var signal: Int32?
        var timedOut = false
        var cancelled = false
        var stdout = Captured()
        var stderr = Captured()
        var spawnError: String?
        var sweptProcesses = 0
        var seconds: Double = 0
    }

    /// 在沙盒裡跑。新行程群組、stdin 是 /dev/null（或給定的資料）、只繼承 0/1/2、訊號設回預設；
    /// 逾時先 SIGTERM 整個群組、2 秒後 SIGKILL；結束後把群組剩下的與帶這次標記的行程都收掉。
    /// `tag`：這次屬於哪個工作區／job（撤銷、取消時照它收）；`onChunk`：輸出一邊收一邊交給呼叫端（V11 輸出區）。
    /// `admit`（W183 R1b）：啟動前最後一次授權檢查（grant 還有效、開關、等級、專案、工作區沒鎖、沒在交件），
    /// 跟「登記到還在跑的群組」在同一把鎖裡做：撤銷要嘛先發生（這裡就拒、spawnError＝refused:…），要嘛看得到這個群組並收掉它。
    static func run(profile: Profile, command: [String], environment: [String: String], cwd: String,
                    stdin: Data? = nil, timeout: TimeInterval, cpuSeconds: Int, fileSizeMB: Int = 1024,
                    keep: Int = streamKeep, tag: RunTag? = nil, admit: (() -> String?)? = nil, onStart: ((pid_t) -> Void)? = nil,
                    onChunk: ((Bool, Data) -> Void)? = nil) -> RunResult {
        let script = limitScript(cpuSeconds: cpuSeconds, fileSizeMB: fileSizeMB, processes: processLimit())
        let argv = [sandboxExec] + profile.argv + ["/bin/zsh", "-f", "-c", script, "tatwo-hands"] + command
        return spawnAndWait(argv: argv, environment: environment, cwd: cwd, stdin: stdin,
                            timeout: min(max(timeout, 1), maxTimeout + 30), marks: profile.marks, keep: keep,
                            tag: tag, admit: admit, onStart: onStart, onChunk: onChunk)
    }

    /// T11：軟硬上限一起設（先軟後硬；非 root 調低硬上限之後就調不回去，沙盒裡的 ulimit／setrlimit 拉不高）。
    /// 任何一個設不成功就不跑（結束碼 125），不吞錯誤。數值先照 App 自己現在的硬上限夾住，免得正常情況也設不成功。
    static func limitScript(cpuSeconds: Int, fileSizeMB: Int, processes: Int) -> String {
        let cpu = clamp(UInt64(max(cpuSeconds, 1)), resource: RLIMIT_CPU, unit: 1)
        let megabytes = clamp(UInt64(max(fileSizeMB, 1)), resource: RLIMIT_FSIZE, unit: 1024 * 1024)
        let limits: [(String, String)] = [("coredumpsize", "0"), ("cputime", "\(cpu)"), ("filesize", "\(megabytes)m"),
                                          ("maxproc", "\(max(processes, 1))")]
        let set = limits.map { "limit \($0.0) \($0.1) && limit -h \($0.0) \($0.1)" }.joined(separator: " && ")
        return set + " || { print -u2 'tatwo-hands: resource limits could not be set; command refused'; exit 125 }; exec \"$@\""
    }

    /// 以 unit 為單位，夾在 App 現在的硬上限以內（硬上限無限就不夾）。
    static func clamp(_ value: UInt64, resource: Int32, unit: UInt64) -> UInt64 {
        var current = rlimit()
        guard getrlimit(resource, &current) == 0, current.rlim_max < UInt64(Int64.max) else { return value }
        return max(1, min(value, current.rlim_max / unit))
    }

    /// 同一個使用者現在的行程數＋256（maxproc 是整個使用者的上限；fork storm 最多再多 256 個），不超過現在的硬上限。
    static func processLimit() -> Int {
        let wanted = UInt64(userProcesses().count + 256)
        return Int(clamping: clamp(wanted, resource: RLIMIT_NPROC, unit: 1))
    }

    struct ProcessEntry {
        let pid: pid_t
        /// 啟動時間（微秒）。
        let start: UInt64
    }

    /// 同一個使用者的行程（不含 zombie：已經死了、等人收屍的不算）。一次 sysctl 拿完，不逐個查。
    /// 列舉失敗回空清單：只給「算行程數上限」用；要判斷「有沒有殘留寫入者」一律用 userProcessesChecked（失敗＝無法判定）。
    static func userProcesses() -> [ProcessEntry] { userProcessesChecked() ?? [] }

    /// W183 R1b：列舉失敗（sysctl 錯、行程多到緩衝區裝不下三次）回 nil，呼叫端要當作「無法判定」。
    static func userProcessesChecked() -> [ProcessEntry]? {
        #if DEBUG
        if faultActive(.enumerationFails) { return nil }
        #endif
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64 * (attempt + 1))
            size = buffer.count * stride
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
                if errno == ENOMEM { continue }   // 行程在兩次呼叫之間變多了：用更大的緩衝區再來
                return nil
            }
            let zombie: CChar = 5   // SZOMB（sys/proc.h）
            return buffer.prefix(size / stride).compactMap { info in
                guard info.kp_proc.p_pid > 1, info.kp_proc.p_stat != zombie else { return nil }
                let start = info.kp_proc.p_un.__p_starttime
                return ProcessEntry(pid: info.kp_proc.p_pid, start: UInt64(max(start.tv_sec, 0)) * 1_000_000 + UInt64(max(start.tv_usec, 0)))
            }
        }
        return nil
    }

    #if DEBUG
    /// 自測的故障注入（W183 R1b）：探針不在、列舉失敗。
    enum Fault: Hashable { case probeUnavailable, enumerationFails }
    private static var faults: Set<Fault> = []
    static func setFault(_ fault: Fault, _ on: Bool) {
        liveLock.lock(); defer { liveLock.unlock() }
        if on { faults.insert(fault) } else { faults.remove(fault) }
    }
    static func faultActive(_ fault: Fault) -> Bool {
        liveLock.lock(); defer { liveLock.unlock() }
        return faults.contains(fault)
    }
    #endif

    /// 探針（W183 R1b：自測可以模擬「探針不在」）。
    static var probe: SandboxProbe? {
        #if DEBUG
        if faultActive(.probeUnavailable) { return nil }
        #endif
        return SandboxProbe.shared
    }

    /// 認「手腳的沙盒」的標記（T6 脫離群組的行程掃描）。
    ///
    /// 環境變數當標記行不通（macOS 27 不給讀別的行程的環境變數，2026-09-27 實測）；路徑、父行程、群組也都能被改掉。
    /// 唯一改不掉的是沙盒規則本身（fork、exec、setsid、改掛 launchd 都繼承同一份）。所以每次執行都在 marks/ 產生一個
    /// 空的標記檔，規則只准讀它（和固定的 marks/hands、這個工作區的 marks/ws-<id>）；marks/control 誰都不准讀。
    /// 認人＝被沙盒關著、讀得到那個標記、讀不到 control。其他工具的沙盒要嘛讀不到我們的標記，要嘛什麼都讀得到（control 也讀得到），
    /// 都不會被認錯；同時在跑的其他手腳指令也不會（它們的規則准的是別的標記）。
    struct RunMarks: Sendable {
        let run: String
        let hands: String
        let control: String
        let workspace: String?

        /// 在 <Hands>/marks 建標記（資料夾 0700、檔案 0600、不跟隨捷徑；沙盒寫不到這裡）。建不起來回 nil。
        static func prepare(directory: String, workspace: String?) -> RunMarks? {
            guard (try? HandsFiles.ensureDirectory(URL(fileURLWithPath: directory, isDirectory: true))) != nil,
                  let real = HandsPath.realpath(directory) else { return nil }
            func touch(_ path: String, exclusive: Bool) -> Bool {
                let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : 0)
                let fd = Darwin.open(path, flags, mode_t(0o600))
                guard fd >= 0 else { return false }
                defer { close(fd) }
                var info = stat()
                return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
            }
            let wsMark = workspace.map { real + "/ws-" + $0 }
            let marks = RunMarks(run: real + "/run-" + UUID().uuidString, hands: real + "/hands", control: real + "/control",
                                 workspace: wsMark)
            guard touch(marks.hands, exclusive: false), touch(marks.control, exclusive: false),
                  touch(marks.run, exclusive: true), wsMark.map({ touch($0, exclusive: false) }) ?? true else { return nil }
            liveLock.lock(); knownMarkDirectories.insert(real); liveLock.unlock()
            return marks
        }

        /// 這次執行收完之後刪掉（之後還活著的只能靠工作區標記與 marks/hands 認）。
        func discard() { _ = unlink(run) }
    }

    /// libsystem_sandbox 的 sandbox_check（沒有公開標頭）。帶路徑的查詢是可變參數函式：
    /// arm64（Apple）可變參數一律走堆疊，所以宣告成 8 個暫存器參數＋第 9 個（落在堆疊第一格）；x86_64 可變參數跟一般參數同一組暫存器。
    /// 第一次用之前先驗：對 App 自己查一個存在的檔（沒被沙盒關＝准）與一個不存在的檔（查不到＝拒），兩個都對才用，否則不認人（不殺）。
    struct SandboxProbe {
        typealias Plain = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        #if arch(arm64)
        typealias WithPath = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32, Int, Int, Int, Int, Int, UnsafePointer<CChar>?) -> Int32
        #elseif arch(x86_64)
        typealias WithPath = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32
        #endif
        let plain: Plain
        #if arch(arm64) || arch(x86_64)
        let withPath: WithPath
        #endif
        /// SANDBOX_FILTER_PATH（1）| SANDBOX_CHECK_NO_REPORT（查詢本身不寫違規紀錄）。
        let flags: Int32

        func isSandboxed(_ pid: pid_t) -> Bool { plain(pid, nil, 0) == 1 }

        /// 0＝准、1＝拒（查不到也算拒）。
        func readDenied(_ pid: pid_t, _ path: String) -> Int32 {
            #if arch(arm64)
            return path.withCString { p in "file-read-data".withCString { op in withPath(pid, op, flags, 0, 0, 0, 0, 0, p) } }
            #elseif arch(x86_64)
            return path.withCString { p in "file-read-data".withCString { op in withPath(pid, op, flags, p) } }
            #else
            return 1
            #endif
        }

        func carries(_ pid: pid_t, mark: String, control: String) -> Bool {
            isSandboxed(pid) && readDenied(pid, mark) == 0 && readDenied(pid, control) == 1
        }

        static let shared: SandboxProbe? = {
            #if arch(arm64) || arch(x86_64)
            guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "sandbox_check") else { return nil }
            var flags: Int32 = 1
            if let report = dlsym(handle, "SANDBOX_CHECK_NO_REPORT") { flags |= report.assumingMemoryBound(to: Int32.self).pointee }
            let probe = SandboxProbe(plain: unsafeBitCast(symbol, to: Plain.self), withPath: unsafeBitCast(symbol, to: WithPath.self), flags: flags)
            let me = getpid()
            let existing = Bundle.main.executablePath ?? "/bin/sh"
            guard !probe.isSandboxed(me), probe.readDenied(me, existing) == 0,
                  probe.readDenied(me, "/private/var/empty/tatwo-hands-missing-" + UUID().uuidString) == 1 else { return nil }
            return probe
            #else
            return nil
            #endif
        }()
    }

    /// 帶標記的行程掃描：先 SIGSTOP 凍住、再 SIGKILL，一輪一輪掃到沒有為止（被殺的行程剛生的子孫下一輪也認得出來：
    /// 規則會繼承），最多 16 輪。不看路徑、父行程、群組（那些都改得掉）。回傳殺掉幾個。
    /// 認不出來（系統沒有 sandbox_check、驗證沒過、標記建不起來）、列舉失敗、16 輪還收不完＝回 nil（W183 R1b：呼叫端當作「無法證明已停」）。
    /// 只靠群組收掉＋行程數與 CPU 上限的地方用 `?? 0`。
    static func sweep(mark: String, control: String, since startMicros: UInt64 = 0) -> Int? {
        guard let probe = Self.probe else { return nil }
        let me = getpid()
        var killed = Set<pid_t>()
        for _ in 0..<16 {
            guard let processes = userProcessesChecked() else { return nil }
            let targets = processes.filter { $0.pid != me && $0.start + 1_000_000 >= startMicros }
                .map(\.pid).filter { probe.carries($0, mark: mark, control: control) }
            if targets.isEmpty { return killed.count }
            for pid in targets { _ = kill(pid, SIGSTOP) }
            for pid in targets where kill(pid, SIGKILL) == 0 { killed.insert(pid) }
            usleep(30_000)
        }
        return nil
    }

    static func nowMicros() -> UInt64 {
        var now = timeval()
        gettimeofday(&now, nil)
        return UInt64(now.tv_sec) * 1_000_000 + UInt64(now.tv_usec)
    }

    // MARK: - V10：收尾（撤銷、逾時、關開關、交件前）

    /// 這次執行屬於誰：工作區、job、grant（撤銷時照它收）。
    struct RunTag: Sendable, Hashable {
        var workspace: String?
        var job: String?
        var grant: String?
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var status: Int32 = 0
        var stdout = Captured()
        var stderr = Captured()
        var stopAt: TimeInterval = .infinity
    }

    private static let liveLock = NSLock()
    /// 還在跑的群組 → 屬於誰。
    private static var liveGroups: [pid_t: RunTag] = [:]
    /// 被要求取消的群組（job_cancel、撤銷）：結果標 cancelled。
    private static var cancelledGroups: Set<pid_t> = []
    /// 用過的標記資料夾（撤銷、關開關時用 marks/hands 收掉所有手腳的行程）。
    private static var knownMarkDirectories: Set<String> = []

    /// 開關關掉、一鍵撤銷、App 結束：收掉所有還在跑的沙盒指令（整個群組），再照 marks/hands 收掉脫離群組的。
    /// 只收手腳自己的：群組是自己開的；掃描只認帶手腳標記的沙盒（別的工具的沙盒行程不會被認錯）。
    static func terminateAll() {
        liveLock.lock()
        let groups = Array(liveGroups.keys)
        cancelledGroups.formUnion(groups)
        let directories = knownMarkDirectories
        liveLock.unlock()
        for group in groups { _ = kill(-group, SIGKILL) }
        usleep(100_000)
        for directory in directories { _ = sweep(mark: directory + "/hands", control: directory + "/control") }
    }

    /// App 啟動時：上次 App 結束（或當掉）時留下的手腳行程收掉。
    static func sweepLeftovers(marksDirectory: String) -> Int {
        guard let real = HandsPath.realpath(marksDirectory) else { return 0 }
        liveLock.lock(); knownMarkDirectories.insert(real); liveLock.unlock()
        return sweep(mark: real + "/hands", control: real + "/control") ?? 0
    }

    /// 收掉某些工作區／job／grant 的：先凍住群組再 SIGKILL，再照工作區標記掃脫離群組的。回傳殺掉幾個（掃描的部分）；
    /// 掃描做不到（探針不在、列舉失敗、收不完、標記資料夾不在）回 nil（W183 R1b）。
    @discardableResult
    static func terminate(where matches: (RunTag) -> Bool, workspaces: [String], marksDirectory: String?) -> Int? {
        liveLock.lock()
        let groups = liveGroups.filter { matches($0.value) }.map(\.key)
        cancelledGroups.formUnion(groups)
        liveLock.unlock()
        // 取消／撤銷不是可執行清理腳本的寬限期。SIGTERM 會讓 shell 在
        // sleep 被打斷後繼續下一行，甚至執行 TERM trap；先凍住，不能再跑使用者指令。
        for group in groups { _ = kill(-group, SIGSTOP) }
        for group in groups { _ = kill(-group, SIGKILL) }
        guard let directory = marksDirectory.flatMap(HandsPath.realpath) else { return workspaces.isEmpty ? 0 : nil }
        var swept = 0
        for workspace in workspaces {
            let mark = directory + "/ws-" + workspace
            guard FileManager.default.fileExists(atPath: mark) else { continue }
            guard let count = sweep(mark: mark, control: directory + "/control") else { return nil }
            swept += count
        }
        return swept
    }

    static func isRunning(where matches: (RunTag) -> Bool) -> Bool {
        liveLock.lock(); defer { liveLock.unlock() }
        return liveGroups.values.contains(where: matches)
    }

    struct Writer: Sendable, Equatable {
        let pid: pid_t
        let name: String
        /// 帶手腳標記（手腳沙盒裡的行程）：可以直接收掉。
        let ours: Bool
    }

    /// V10：cwd 在這些資料夾裡、或開著這些資料夾裡的檔案「準備寫」或資料夾（之後可以 openat 寫）的行程（同一個使用者、不含 App 自己）。
    /// 用 proc_pidinfo 看 cwd（PROC_PIDVNODEPATHINFO）與每個 fd 的路徑、類型、開啟旗標（PROC_PIDFDVNODEPATHINFO）。
    /// W183 R1b：列舉失敗、查不了某個還活著的行程＝回 nil（無法判定），不當作「沒有寫入者」。
    static func writers(in roots: [String], marksDirectory: String?) -> [Writer]? {
        let me = getpid()
        let realRoots = roots.compactMap { HandsPath.realpath($0) ?? $0 }
        func inside(_ path: String) -> Bool { !path.isEmpty && realRoots.contains { HandsPath.isWithin(path, $0) } }
        let directory = marksDirectory.flatMap(HandsPath.realpath)
        guard let processes = userProcessesChecked() else { return nil }
        var result: [Writer] = []
        for entry in processes where entry.pid != me {
            var touching = false
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            errno = 0
            if proc_pidinfo(entry.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
                let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                touching = inside(cwd)
            } else if errno == ESRCH || kill(entry.pid, 0) != 0 {
                continue   // 已經結束了
            } else if errno == EPERM, isProtectedSystemBinary(processPath(entry.pid)) {
                continue   // 系統自己的常駐程式（SIP 保護的路徑）不給查：不是手腳開的，也碰不到手腳的資料夾
            } else {
                return nil
            }
            if !touching {
                guard let open = openFilesForWriting(entry.pid) else {
                    if kill(entry.pid, 0) != 0 { continue }
                    return nil
                }
                // 有些 fd 不給查（EPERM）：只有 SIP 保護路徑上的系統程式可以略過，其他一律「無法判定」。
                if open.denied, !isProtectedSystemBinary(processPath(entry.pid)) { return nil }
                touching = open.files.contains(where: inside)
                // 只拿著資料夾 fd（沒有 cwd、沒有寫入中的檔）而且是系統自己的程式（/System 底下，例如 Spotlight）：不算寫入者。
                if !touching, open.directories.contains(where: inside), !processPath(entry.pid).hasPrefix("/System/") { touching = true }
            }
            guard touching else { continue }
            var ours = false
            if let directory, let probe = Self.probe {
                ours = probe.carries(entry.pid, mark: directory + "/hands", control: directory + "/control")
            }
            result.append(Writer(pid: entry.pid, name: processName(entry.pid), ours: ours))
        }
        return result
    }

    /// 某個行程開著、帶寫入旗標（FWRITE）的檔案路徑，與開著的資料夾（不管旗標：拿著資料夾的 fd 之後可以 openat 寫）。
    /// 查不了（不是因為行程結束）回 nil。
    static func openFilesForWriting(_ pid: pid_t) -> (files: [String], directories: [String], denied: Bool)? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds: [proc_fdinfo] = []
        var got: Int32 = 0
        for attempt in 0..<3 {
            errno = 0
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else {   // 0＝沒有開任何 fd
                if errno == ESRCH || errno == 0 { return ([], [], false) }
                return errno == EPERM ? ([], [], true) : nil
            }
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32 * (attempt + 1))
            got = fds.withUnsafeMutableBytes { raw in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
            }
            guard got > 0 else {
                if errno == ESRCH || errno == 0 { return ([], [], false) }
                return errno == EPERM ? ([], [], true) : nil
            }
            if Int(got) < fds.count * stride { break }   // 緩衝區沒塞滿＝拿到全部
            if attempt == 2 { return nil }
        }
        var files: [String] = [], directories: [String] = [], denied = false
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            errno = 0
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else {
                if errno == EBADF || errno == ESRCH { continue }   // 那個 fd 剛關掉、行程剛結束
                if errno == EPERM { denied = true; continue }      // 不給查：呼叫端看是不是系統程式再決定
                return nil
            }
            let writing = (vnode.pfi.fi_openflags & 0x2) != 0   // FWRITE
            let isDirectory = (UInt32(vnode.pvip.vip_vi.vi_stat.vst_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR)
            guard writing || isDirectory else { continue }
            let path = withUnsafeBytes(of: vnode.pvip.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if isDirectory { directories.append(path) } else { files.append(path) }
        }
        return (files, directories, denied)
    }

    /// SIP 保護的系統路徑（使用者、手腳都放不了東西進去）：這些常駐程式不給查 fd（2026-09-28 mini 實測 QuickLook、routined），
    /// 可以略過；其他查不了的一律當作無法判定。手腳自己開的行程不靠這裡：交件前先照工作區標記整批收掉。
    static func isProtectedSystemBinary(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "?" }
        return (String(cString: buffer) as NSString).lastPathComponent
    }

    /// V10 交件前的結果（W183 R1b）：確定沒有寫入者／還有別的程式開著（列出來）／無法判定（探針不在、列舉失敗、收不完）。
    enum Quiesce: Equatable {
        case clear
        case remaining([Writer])
        case unknown(String)
    }

    /// V10 交件前：收掉這個工作區還在跑的（群組＋工作區標記），再用 proc_pidinfo 找 cwd／寫入中的檔案／開著的資料夾在工作區或暫存區的行程：
    /// 手腳沙盒裡的直接收掉；別的程式（證明不了它已經停）就回報，呼叫端拒絕交件。做不到完整掃描＝unknown，呼叫端也拒絕交件。
    static func quiesce(workspace id: String, roots: [String], marksDirectory: String?) -> Quiesce {
        guard Self.probe != nil else { return .unknown("sandbox_probe_unavailable") }
        guard marksDirectory.flatMap(HandsPath.realpath) != nil else { return .unknown("marks_unavailable") }
        guard terminate(where: { $0.workspace == id }, workspaces: [id], marksDirectory: marksDirectory) != nil else {
            return .unknown("sweep_incomplete")
        }
        for _ in 0..<3 {
            guard let found = writers(in: roots, marksDirectory: marksDirectory) else { return .unknown("process_scan_failed") }
            let ours = found.filter(\.ours)
            if ours.isEmpty { return found.isEmpty ? .clear : .remaining(found) }
            for writer in ours { _ = kill(writer.pid, SIGSTOP) }
            for writer in ours { _ = kill(writer.pid, SIGKILL) }
            usleep(100_000)
        }
        guard let found = writers(in: roots, marksDirectory: marksDirectory) else { return .unknown("process_scan_failed") }
        return found.isEmpty ? .clear : .remaining(found)
    }

    static func spawnAndWait(argv: [String], environment: [String: String], cwd: String, stdin: Data?,
                             timeout: TimeInterval, marks: RunMarks?, keep: Int = streamKeep, tag: RunTag? = nil,
                             admit: (() -> String?)? = nil,
                             onStart: ((pid_t) -> Void)? = nil, onChunk: ((Bool, Data) -> Void)? = nil) -> RunResult {
        defer { marks?.discard() }
        var result = RunResult()
        let started = ProcessInfo.processInfo.systemUptime
        let startMicros = nowMicros()
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { result.spawnError = "pipe_failed"; return result }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); result.spawnError = "pipe_failed"; return result }
        if stdin != nil, pipe(&inPipe) != 0 {
            [outPipe[0], outPipe[1], errPipe[0], errPipe[1]].forEach { close($0) }
            result.spawnError = "pipe_failed"; return result
        }
        for fd in [outPipe[0], errPipe[0], inPipe[1]] where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        let chdirResult = cwd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard chdirResult == 0 else {
            [outPipe[0], outPipe[1], errPipe[0], errPipe[1], inPipe[0], inPipe[1]].filter { $0 >= 0 }.forEach { close($0) }
            result.spawnError = "chdir_failed"; return result
        }
        let flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var everySignal: sigset_t = ~sigset_t(0)
        var noSignal: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
        }
        var pid: pid_t = 0
        // W183 R1b：最後一次授權檢查、啟動、登記群組在同一把鎖裡（撤銷的 terminate 也拿這把鎖看群組清單）。
        liveLock.lock()
        let refusal = admit?()
        let spawned: Int32 = refusal != nil ? -1 : argv[0].withCString { path in
            posix_spawn(&pid, path, &actions, &attributes, &cArgs, &cEnv)
        }
        if refusal == nil, spawned == 0 { liveGroups[pid] = tag ?? RunTag() }
        liveLock.unlock()
        close(outPipe[1]); close(errPipe[1])
        if inPipe[0] >= 0 { close(inPipe[0]) }
        if let refusal {
            close(outPipe[0]); close(errPipe[0]); if inPipe[1] >= 0 { close(inPipe[1]) }
            result.spawnError = "refused:" + refusal; return result
        }
        guard spawned == 0 else {
            close(outPipe[0]); close(errPipe[0]); if inPipe[1] >= 0 { close(inPipe[1]) }
            result.spawnError = "spawn_failed_\(spawned)"; return result
        }
        defer { liveLock.lock(); liveGroups[pid] = nil; cancelledGroups.remove(pid); liveLock.unlock() }
        onStart?(pid)

        if let stdin, inPipe[1] >= 0 {
            let writer = inPipe[1]
            DispatchQueue.global(qos: .utility).async {
                _ = fcntl(writer, F_SETNOSIGPIPE, 1)
                _ = HandsFiles.writeAll(writer, stdin)
                close(writer)
            }
        }

        let box = Box()
        let readerDone = DispatchSemaphore(value: 0)
        let outFD = outPipe[0], errFD = errPipe[0]
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        Thread.detachNewThread {
            var openFDs = [outFD: true, errFD: true]
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while openFDs.values.contains(true) {
                box.lock.lock(); let stopAt = box.stopAt; box.lock.unlock()
                if ProcessInfo.processInfo.systemUptime >= stopAt { break }
                var fds = openFDs.filter(\.value).map { pollfd(fd: $0.key, events: Int16(POLLIN), revents: 0) }
                let ready = poll(&fds, nfds_t(fds.count), 100)
                if ready <= 0 { continue }
                for entry in fds where entry.revents != 0 {
                    let n = Darwin.read(entry.fd, &chunk, chunk.count)
                    if n > 0 {
                        let data = Data(chunk.prefix(n))
                        box.lock.lock()
                        if entry.fd == outFD { box.stdout.append(data, keep: keep) } else { box.stderr.append(data, keep: keep) }
                        box.lock.unlock()
                        onChunk?(entry.fd == outFD, data)
                    } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                        openFDs[entry.fd] = false
                    }
                }
            }
            readerDone.signal()
        }
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            box.lock.lock(); box.status = status; box.lock.unlock()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            _ = kill(-pid, SIGTERM)
            if exited.wait(timeout: .now() + 2) == .timedOut {
                _ = kill(-pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        // 群組裡剩下的（背景 &）一律收掉；等孤兒改掛到 launchd，再掃脫離群組的。
        _ = kill(-pid, SIGKILL)
        usleep(100_000)
        if let marks { result.sweptProcesses = sweep(mark: marks.run, control: marks.control, since: startMicros) ?? 0 }
        box.lock.lock(); box.stopAt = ProcessInfo.processInfo.systemUptime + 1.5; box.lock.unlock()
        _ = readerDone.wait(timeout: .now() + 3)
        close(outFD); close(errFD)
        box.lock.lock()
        let status = box.status
        result.stdout = box.stdout
        result.stderr = box.stderr
        box.lock.unlock()
        liveLock.lock(); result.cancelled = cancelledGroups.contains(pid); liveLock.unlock()
        if (status & 0x7f) == 0 {
            result.exitCode = (status >> 8) & 0xff
        } else {
            result.signal = status & 0x7f
        }
        result.seconds = ProcessInfo.processInfo.systemUptime - started
        return result
    }

    /// 工作區與暫存區的大小（V10 磁碟上限；不跟隨捷徑；項目太多就回上限值＝當作超過）。
    static func diskUsage(_ roots: [String], limit entries: Int = 2_000_000) -> Int64 {
        var total: Int64 = 0
        var seen = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                                                                  options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                seen += 1
                if seen > entries { return Int64.max }
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - 路徑檢查（App 端第一道；沙盒是第二道）

enum HandsPathError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let reason): reason }
    }
}

enum HandsPath {
    static func realpath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func overlaps(_ a: String, _ b: String) -> Bool { isWithin(a, b) || isWithin(b, a) }

    /// realpath；還不存在就解析上層再接名字（Seatbelt 比對真實路徑：/tmp 其實是 /private/tmp）。
    static func canonical(_ path: String) -> String {
        if let real = realpath(path) { return real }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, let real = realpath(parent) else { return path }
        return real + "/" + (path as NSString).lastPathComponent
    }

    /// 相對路徑拆成段：不收絕對路徑、`..`、控制字元、太長；空字串或 "." 表示根目錄。寫入時踩到保護規則（大小寫都算）就拒絕。
    static func components(_ raw: String, forWrite: Bool) throws -> [String] {
        guard raw.utf8.count <= 1024 else { throw HandsPathError.invalid("path_too_long") }
        guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw HandsPathError.invalid("path_has_control_characters")
        }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { throw HandsPathError.invalid("path_must_be_relative") }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw HandsPathError.invalid("path_escapes_workspace") }
        if forWrite {
            guard !parts.isEmpty else { throw HandsPathError.invalid("path_required") }
            if HandsSandbox.isProtected(components: parts) {
                throw HandsPathError.invalid("protected_path:\(parts.joined(separator: "/"))")
            }
        }
        return parts
    }

    enum Expect { case file, directory, any, absentOrFile }

    /// 在 root（realpath）底下逐段 lstat：中間每一段必須是真的資料夾（不是捷徑）；最後一段照 expect 檢查。
    /// 一般檔要用 O_NOFOLLOW 開得起來、連結數 1。回傳絕對路徑。
    static func resolve(root: String, components parts: [String], expect: Expect) throws -> String {
        var current = root
        var info = stat()
        guard lstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw HandsPathError.invalid("root_missing") }
        for (index, part) in parts.enumerated() {
            current += "/" + part
            let last = index == parts.count - 1
            if lstat(current, &info) != 0 {
                guard errno == ENOENT else { throw HandsPathError.invalid("path_unreadable") }
                // 不存在：只有最後一段、而且是要新建的檔才可以；中間資料夾由小幫手建。
                if last && expect == .absentOrFile { return current }
                if !last && expect == .absentOrFile { return root + "/" + parts.joined(separator: "/") }
                throw HandsPathError.invalid("not_found")
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw HandsPathError.invalid("symlink_refused") }
            if !last {
                guard type == S_IFDIR else { throw HandsPathError.invalid("not_a_directory") }
                continue
            }
            switch expect {
            case .directory:
                guard type == S_IFDIR else { throw HandsPathError.invalid("not_a_directory") }
            case .file, .absentOrFile:
                guard type == S_IFREG else { throw HandsPathError.invalid("not_a_regular_file") }
                try checkRegularFile(current)
            case .any:
                if type == S_IFREG { try checkRegularFile(current) }
                else if type != S_IFDIR { throw HandsPathError.invalid("special_file_refused") }
            }
        }
        if parts.isEmpty, expect == .file || expect == .absentOrFile { throw HandsPathError.invalid("path_required") }
        return current
    }

    /// O_NOFOLLOW 開起來看：一般檔、連結數 1（硬連結可能指到工作區外的檔）。
    static func checkRegularFile(_ path: String) throws {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw HandsPathError.invalid(errno == ELOOP ? "symlink_refused" : "open_failed") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw HandsPathError.invalid("not_a_regular_file") }
        guard info.st_nlink <= 1 else { throw HandsPathError.invalid("hardlink_refused") }
    }

    /// 網路磁碟、雲端同步資料夾不給用（檔案可能在別台、同步到雲端）。
    static func storageProblem(_ path: String, home: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "storage_unreadable" }
        let type = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
        if ["smbfs", "afpfs", "nfs", "webdav", "macfuse", "osxfuse", "fusefs", "cifs", "ftp"].contains(where: { type.hasPrefix($0) }) {
            return "network_volume_refused"
        }
        for cloud in ["Library/CloudStorage", "Library/Mobile Documents"] where isWithin(path, home + "/" + cloud) {
            return "cloud_sync_folder_refused"
        }
        return nil
    }
}

// MARK: - 遮蔽（回給 ChatGPT、寫進房間的文字都先過這裡）

enum HandsRedactor {
    struct Context: Sendable {
        /// 路徑 → 代稱（例：工作區 → <workspace>、家目錄 → ~）。長的先換。
        var paths: [(String, String)] = []
        var hostName: String? = HandsRedactor.localHostName()
        var userName: String? = NSUserName()
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 規則都是固定字串，編不過是程式錯；這時整段遮掉（fail closed）。
        (try? NSRegularExpression(pattern: pattern)) ?? (try! NSRegularExpression(pattern: "[\\s\\S]+"))
    }

    /// 只遮高把握的秘密格式（程式碼裡一般的 token 變數名不動，免得讀檔／改檔對不上）。
    static let rules: [(NSRegularExpression, String)] = [
        (regex("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\\z)"), "[已遮蔽：私鑰]"),
        (regex("\\bsk-(?:proj-|ant-|live-|test-|svcacct-)?[A-Za-z0-9_\\-]{16,}"), "sk-[已遮蔽]"),
        (regex("\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"), "gh*_[已遮蔽]"),
        (regex("\\bgithub_pat_[A-Za-z0-9_]{20,}"), "github_pat_[已遮蔽]"),
        (regex("\\btatwoh_(?:at|rt|ac)_[A-Za-z0-9_\\-]{16,}"), "tatwoh_[已遮蔽]"),
        (regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=\\-]{8,}"), "Bearer [已遮蔽]"),
        (regex("\\bAKIA[0-9A-Z]{16}\\b"), "AKIA[已遮蔽]"),
        (regex("\\bxox[abposr]-[A-Za-z0-9\\-]{10,}"), "xox-[已遮蔽]"),
        (regex("\\bAIza[0-9A-Za-z_\\-]{30,}"), "AIza[已遮蔽]"),
        (regex("\\beyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}"), "[已遮蔽：JWT]"),
        (regex("(?i)\\b([a-z][a-z0-9+.\\-]*://)[^\\s/:@]+:[^\\s/@]+@"), "$1[已遮蔽]@"),
        (regex("(?i)\\b([a-z][a-z0-9+.\\-]*://)[A-Za-z0-9_\\-]{20,}@"), "$1[已遮蔽]@"),
        (regex("\\b([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*)=([A-Za-z0-9/+_=.\\-]{12,})"), "$1=[已遮蔽]"),
        (regex("(?<![A-Za-z0-9_./-])(file://)?/Users/[^/\\s\"'`:]+"), "$1/Users/<user>"),
    ]

    /// 主機名稱常帶使用者名字（例：某某的 MacBook）；太短的（可能是一般字）不換。
    static func localHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer)
        return name.count >= 8 ? name : nil
    }

    private static func replacingWord(_ word: String, in text: String, with label: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])" + escaped + "(?![A-Za-z0-9_-])") else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: label))
    }

    static func redact(_ text: String, context: Context = Context()) -> String {
        var result = text
        for (path, label) in context.paths.filter({ $0.0.count >= 2 }).sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: path, with: label)
        }
        if let host = context.hostName { result = replacingWord(host, in: result, with: "<host>") }
        if let user = context.userName, user.count >= 3 { result = replacingWord(user, in: result, with: "<user>") }
        for (pattern, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// 尾段的開頭可能是「前面被切掉的私鑰」的後半段（沒有 BEGIN 那行）：從開頭到第一個 END 那行整段遮掉。
    static let keyTail = regex("\\A(?:(?!-----BEGIN )[\\s\\S])*?-----END [A-Z0-9 ]*PRIVATE KEY-----")
    static func redactKeyTail(_ text: String) -> String {
        keyTail.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[已遮蔽：私鑰後半段]")
    }

    /// 先遮蔽、再截短（不能反過來：先截會把秘密切成規則比不中的半截）。
    static func redactedPrefix(_ text: String, _ limit: Int, context: Context = Context()) -> String {
        String(redact(text, context: context).prefix(limit))
    }

    /// 截短到 limit 個字元（頭尾各留一半）。只用在已經遮蔽過的文字上。
    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = max(limit / 2, 1)
        return String(text.prefix(half)) + "\n…（中間省略 \(text.count - half * 2) 字）…\n" + String(text.suffix(half))
    }
}
