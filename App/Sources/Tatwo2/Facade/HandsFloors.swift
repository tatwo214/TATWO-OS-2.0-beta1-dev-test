import Foundation

// W183 R10（使用者 09-29：「這邊要勾選也太怪 就要給他用了還要多一個勾選 chatgpt是日常最親的ai 沒有那麼多權限需要隔離」）：
// 範圍改成「全部可見」（等級照 ChatGPT build 面板的中央設定、專案＝那台所有能當專案的），換來兩條看不見、不增加操作的底線：
// - A 金鑰：金鑰類檔案在所有等級、所有工具（讀、列、搜尋、開工作區的匯出快照、git 差異）都讀不到。
// - B 實盤：交易實盤類專案 ChatGPT 最多 L0（只能看）——L1／L2 的寫入與執行工具一律拒絕；主機自己判斷（看 Coder 的專案名與資料夾名），
//   不信 ChatGPT 傳來的任何參數。依據：憲法「AI 不碰下單、倉位、資金」。
// 兩張清單都放在這裡的常數（改清單只改這裡；檔案小幫手 fsop.mjs 的 SECRET_* 是同一份的複本，node 測試比對兩邊一樣）。
// W183 R10 第二輪（GPT-6 4、5、6、7；主導裁決）：
// - A 的清單補上交易專案最常見的洩漏（wallet.dat、*.wallet、secret*／secrets*／.secrets、apikey／api_key／api-key、service-account*、
//   mnemonic*、seed*、*.tfvars；寧可多擋）；覆蓋面補齊——進工作區的每一個來源（匯出、依賴複製）都濾、依賴裡的 .git 拿掉、
//   不帶 .build/repositories（沒清過的 Git 物件庫）；run_command／長工作的沙盒規則對同一份清單拒讀拒寫（不是事後遮罩）；
//   專案根目錄本身（或它上面某一層）是金鑰類資料夾＝整個專案不納入範圍；舊工作區第一次用到時掃一次：工作樹裡的搬去隔離、歷史裡有＝鎖住。
// - B 用資料夾的實際身分彙整（真實路徑、裝置＋inode、共用的 Git 儲存庫）：同一個資料夾任一個名字命中＝指向它的專案全部最多 L0；
//   分類有版本，變了就取消受影響的執行中工作，交件前核對版本。

/// 底線 A：金鑰類檔案。路徑的任何一段對上＝整條路徑都算（資料夾對上＝裡面全部都算）。一律不分大小寫。
enum HandsSecretFiles {
    /// 整個名字。
    static let names: [String] = [".netrc", ".git-credentials", ".pypirc", ".npmrc", ".dockercfg", ".pgpass", ".htpasswd", "wallet.dat"]
    /// 開頭：`.env*`（.env、.env.production、.envrc…）、`credentials*`、`id_*`（SSH 金鑰 id_rsa、id_ed25519.pub…）；
    /// W183 R10 第二輪：`secret*`、`secrets*`、`.secrets*`（資料夾）、`apikey*`、`api_key*`、`api-key*`、`service-account*`、`mnemonic*`、`seed*`。
    static let prefixes: [String] = [".env", "credentials", "id_", "secret", "secrets", ".secrets", "apikey", "api_key", "api-key",
                                     "service-account", "mnemonic", "seed"]
    /// 結尾：金鑰、憑證、鑰匙圈匯出；W183 R10 第二輪：錢包（`*.wallet`）、Terraform 變數（`*.tfvars`）。
    static let suffixes: [String] = [".pem", ".key", ".p12", ".pfx", ".p8", ".ppk", ".jks", ".keystore", ".keychain", ".keychain-db",
                                     ".crt", ".cer", ".der", ".kdbx", ".asc", ".gpg", ".wallet", ".tfvars"]
    /// 整個資料夾（裡面全部都算）。
    static let directories: [String] = [".ssh", ".gnupg", ".aws", ".docker", ".kube", ".azure", ".password-store"]

    /// 一段名字是不是金鑰類。
    static func isSecret(name raw: String) -> Bool {
        let name = raw.lowercased()
        guard !name.isEmpty else { return false }
        if names.contains(name) || directories.contains(name) { return true }
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return suffixes.contains(where: { name.hasSuffix($0) })
    }

    /// 相對路徑的任何一段是金鑰類。
    static func isSecret(components: [String]) -> Bool { components.contains(where: isSecret(name:)) }

    static func isSecret(path: String) -> Bool {
        isSecret(components: path.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    /// W183 R10 第二輪：路徑（專案的設定路徑或真實路徑）有一段是金鑰類：家目錄底下只看家目錄以下那一段（使用者名稱不算），
    /// 不在家目錄底下＝整條路徑。專案根目錄本身（.aws、credentials-backup…）或它上面某一層是＝整個專案不納入範圍。
    static func isSecretRoot(_ path: String, home: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        let base = (home as NSString).standardizingPath
        let tail = standard.lowercased().hasPrefix(base.lowercased() + "/") ? String(standard.dropFirst(base.count + 1)) : standard
        return isSecret(path: tail)
    }

    /// W183 R10 第二輪：沙盒規則（Seatbelt regex，比整條路徑；搭配 (subpath WS) 只作用在工作區裡）：任何一層是金鑰類。不分大小寫。
    /// 整條（NSRegularExpression 用：工作區自己的路徑不能踩到）。
    static var seatbeltPattern: String { seatbeltWrap(seatbeltAlternatives) }

    /// 沙盒規則用的分段：Seatbelt 的一個字串最多約 1000 字（09-29 本機實測：1032 字＝「Error reading string」，整份規則讀不進去、
    /// 沙盒起不來），所以拆成幾段、每段不超過 seatbeltChunkLimit，一段一條規則（合起來跟 seatbeltPattern 比對的一樣）。
    static var seatbeltPatterns: [String] {
        var groups: [[String]] = []
        for alternative in seatbeltAlternatives {
            if let last = groups.last, seatbeltWrap(last + [alternative]).utf8.count <= seatbeltChunkLimit {
                groups[groups.count - 1].append(alternative)
            } else {
                groups.append([alternative])
            }
        }
        return groups.map(seatbeltWrap)
    }

    static let seatbeltChunkLimit = 900

    static var seatbeltAlternatives: [String] {
        let ci = HandsSandbox.caseInsensitivePattern
        return (names + directories).map(ci) + prefixes.map { ci($0) + "[^/]*" } + suffixes.map { "[^/]*" + ci($0) }
    }

    static func seatbeltWrap(_ alternatives: [String]) -> String { "/(" + alternatives.joined(separator: "|") + ")(/|$)" }

    /// W183 R10 第二輪：舊工作區的掃描版本（清單改了就加一：之前掃過的工作區在下一次用到時照新清單再掃一次）。
    /// W183 R10 第三輪：3＝整理也換了（依賴的 .git、舊的 .build/repositories 整包隔離；工作區自己的 .git 封存後重建乾淨的副本）。
    static let scanVersion = 3

    /// 拒絕時回給 ChatGPT 的字（不說是哪一種、不回內容）。
    static let refusal = "secret_file_refused: key, certificate, credential and wallet files (.env*, *.pem, *.key, id_*, credentials*, secret*, api keys, service accounts, wallets, seed/mnemonic, *.tfvars, keychain exports…) are never readable by ChatGPT"

    /// git 的排除 pathspec（git grep／git diff 用；不分大小寫、任何一層）。後面照樣再濾一次路徑（這只是讓 git 先不去碰）。
    static var gitExcludePathspecs: [String] {
        var out: [String] = []
        for name in names + directories { out.append(":(exclude,glob,icase)**/\(name)"); out.append(":(exclude,glob,icase)**/\(name)/**") }
        for prefix in prefixes { out.append(":(exclude,glob,icase)**/\(prefix)*"); out.append(":(exclude,glob,icase)**/\(prefix)*/**") }
        for suffix in suffixes { out.append(":(exclude,glob,icase)**/*\(suffix)"); out.append(":(exclude,glob,icase)**/*\(suffix)/**") }
        return out
    }

    /// 開工作區的匯出（git archive 解開之後、建基準 commit 之前）刪掉金鑰類檔案的 find 條件（固定字串，沒有任何使用者路徑）。
    static var findExpression: String {
        var tests: [String] = []
        for name in names + directories { tests.append("-iname '\(name)'") }
        for prefix in prefixes { tests.append("-iname '\(prefix)*'") }
        for suffix in suffixes { tests.append("-iname '*\(suffix)'") }
        return "\\( " + tests.joined(separator: " -o ") + " \\)"
    }
}

/// 底線 B：交易實盤類專案（專案名或資料夾名含這些字，不分大小寫）＝ChatGPT 最多 L0（只能看）。
/// W183 R10 第二輪（GPT-6 6）：同一個資料夾（真實路徑、裝置＋inode、共用的 Git 儲存庫）的任一個名字命中＝指向它的專案全部都是（classify）。
enum HandsTradingFloor {
    /// 改清單只改這裡。
    static let keywords: [String] = ["實盤", "交易", "trading", "hermes", "btc"]
    /// 這類專案 ChatGPT 最多到這一級。
    static let maxLevel = 0
    /// 拒絕時回給 ChatGPT 的字。
    static let refusal = "project_read_only: this is a live-trading project; ChatGPT may only read it (L0). Writing, running commands and workspaces are refused by TATWO"

    /// 專案名、設定資料夾末段及真實路徑家目錄以下各段含關鍵字（非整段相等；tradingcard-notes 也算）。
    static func isTrading(name: String, folder: String) -> Bool {
        let real = (HandsPath.realpath(folder) ?? (folder as NSString).standardizingPath).lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path.lowercased()
        let tail = real == home ? "" : real.hasPrefix(home + "/") ? String(real.dropFirst(home.count + 1)) : real
        let texts = [name.lowercased(), (folder as NSString).lastPathComponent.lowercased()] + tail.split(separator: "/").map(String.init)
        return keywords.contains { keyword in texts.contains { $0.contains(keyword.lowercased()) } }
    }

    /// 一個專案紀錄自己（名字、設定的資料夾、真實路徑的資料夾）命中。
    static func matches(_ record: (UUID, String, String)) -> Bool {
        isTrading(name: record.1, folder: record.2) || isTrading(name: record.1, folder: HandsPath.realpath(record.2) ?? record.2)
    }

    /// 全部專案的分類（照實際身分彙整別名）：回交易實盤類的專案 id（大寫）。
    static func classify(_ records: [(UUID, String, String)]) -> Set<String> {
        var keysByID: [UUID: Set<String>] = [:]
        var tradingKeys = Set<String>()
        var out = Set<String>()
        for record in records {
            let keys = identityKeys(record.2)
            keysByID[record.0] = keys
            if matches(record) {
                out.insert(record.0.uuidString)
                tradingKeys.formUnion(keys)
            }
        }
        for (id, keys) in keysByID where !keys.isDisjoint(with: tradingKeys) { out.insert(id.uuidString) }
        return out
    }

    /// 資料夾的實際身分：真實路徑（不分大小寫；捷徑解開）、裝置＋inode、共用的 Git 儲存庫（.git 資料夾，或 worktree 的 .git 檔指到的
    /// commondir 的真實路徑）。讀不到＝只有設定的路徑。
    static func identityKeys(_ workdir: String) -> Set<String> {
        guard let real = HandsPath.realpath(workdir) else { return ["path:" + workdir.lowercased()] }
        var keys: Set<String> = ["path:" + real.lowercased()]
        var info = stat()
        if stat(real, &info) == 0 { keys.insert("ino:\(info.st_dev):\(info.st_ino)") }
        if let common = gitCommonDir(real) { keys.insert("git:" + common.lowercased()) }
        return keys
    }

    /// 這個資料夾的 Git 儲存庫本體（只讀檔案，不跑 git）。
    static func gitCommonDir(_ real: String) -> String? {
        let dotgit = real + "/.git"
        var info = stat()
        guard lstat(dotgit, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFDIR { return HandsPath.realpath(dotgit) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size < 4096,
              let text = try? String(contentsOfFile: dotgit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitdir = raw.hasPrefix("/") ? raw : (real as NSString).appendingPathComponent(raw)
        guard let resolved = HandsPath.realpath(gitdir) else { return nil }
        if let common = try? String(contentsOfFile: resolved + "/commondir", encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = trimmed.hasPrefix("/") ? trimmed : (resolved as NSString).appendingPathComponent(trimmed)
            return HandsPath.realpath(path) ?? resolved
        }
        return resolved
    }
}

extension HandsProjectChoice {
    /// 底線 B：面板上標「只能看」（跟主機判斷用同一個函式；畫面只是顯示，擋在主機）。
    var readOnlyFloor: Bool { HandsTradingFloor.isTrading(name: name, folder: folder) }
}
