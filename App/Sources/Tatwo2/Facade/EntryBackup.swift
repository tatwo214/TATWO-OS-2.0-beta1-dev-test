import Foundation

/// W160（使用者 2026-09-22）：入口的文字正本用 git 記版本，並可備份到使用者自己的私人 GitHub 倉庫。
/// - 本機 git 一律建立（沒登入也有版本歷史）；只有使用者同意時才推到 GitHub。
/// - 只在主設備推：主設備持正本，副設備的入口是派發來的副本。
/// - token 只放在這次 git 指令的環境變數，不進命令列、不寫進 git 設定（沿用 PullRequestService 的做法）。
@MainActor
final class EntryBackup: ObservableObject {
    static let shared = EntryBackup()
    static let repositoryName = "tatwo-os-entry"
    private static let choiceKey = "tatwo2.entryBackup.choice"
    /// 白名單：只收文字正本；原始碼、產物、GBrain、封存、草稿裡的私人來源一律不進 git。
    static let gitignore = """
    # 入口只追蹤文字正本；其餘（原始碼、產物、封存、GBrain、草稿來源）不進 git
    *
    !.gitignore
    !README.md
    !os.md
    !skillet.md
    !user.md
    !agents.md
    !todo.md
    !issue.md
    !note/
    !note/note.md
    !drafts/
    !drafts/**
    drafts/**/sources/
    .DS_Store

    """

    enum Choice: String { case enabled, declined }

    @Published private(set) var statusLine = ""
    @Published private(set) var busy = false

    var choice: Choice? {
        get { UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(Choice.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.choiceKey); refreshStatus() }
    }

    func refreshStatus() {
        let entry = TatwoEntry()
        let isRepo = Self.isRepository(entry)
        let remote = isRepo ? Self.gitOutput(["remote", "get-url", "origin"], in: entry.root) : nil
        switch (choice, isRepo, remote) {
        case (_, false, _): statusLine = "入口還沒有版本紀錄"
        case (.declined, true, _): statusLine = "入口有本機版本紀錄・沒有備份到 GitHub"
        case (_, true, .some(let url)): statusLine = "GitHub 備份：" + Self.displayName(url)
        case (_, true, .none): statusLine = OSDocuments.isPrimary ? "入口有本機版本紀錄・還沒接 GitHub" : "副設備：正本與備份在主設備"
        }
    }

    // MARK: 本機 git

    nonisolated static func isRepository(_ entry: TatwoEntry) -> Bool {
        guard let top = gitOutput(["rev-parse", "--show-toplevel"], in: entry.root) else { return false }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath() == entry.root.resolvingSymlinksInPath()
    }

    /// 入口還不是 git 就建立，第一個 commit 收目前的正本。已是 git 什麼都不動。
    @discardableResult
    nonisolated static func ensureRepository(entry: TatwoEntry = TatwoEntry(), deviceName: String) throws -> Bool {
        guard entry.exists else { throw OSUpstreamBinding.failure("找不到入口 \(entry.root.path)") }
        if isRepository(entry) { return false }
        let ignore = entry.root.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data(gitignore.utf8).write(to: ignore, options: .atomic)
        }
        for args in [["init", "-q", "-b", "main"],
                     ["config", "user.name", "TATWO OS（\(deviceName)）"],
                     ["config", "user.email", "tatwo-os@users.noreply.github.com"],
                     ["add", "-A"],
                     ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "入口開始記版本（\(deviceName)）"]] {
            guard gitOutput(args, in: entry.root, allowEmpty: true) != nil else {
                throw OSUpstreamBinding.failure("建立入口版本紀錄失敗：git \(args.first ?? "")")
            }
        }
        return true
    }

    // MARK: GitHub

    /// 同意備份：建立（或沿用）私人倉庫、設定 origin（網址不含 token）、推一次。
    func enable() async {
        choice = .enabled
        await push(createIfMissing: true)
    }

    func decline() { choice = .declined }

    /// 設定頁存檔提交後呼叫；沒同意、不是主設備、沒登入都安靜略過。
    func pushIfEnabled() {
        guard choice == .enabled, OSDocuments.isPrimary, !busy else { return }
        Task { await push(createIfMissing: false) }
    }

    private func push(createIfMissing: Bool) async {
        guard OSDocuments.isPrimary else { refreshStatus(); return }
        let store = GitHubAccountsStore()
        guard let account = (try? store.loadAccounts())?.first(where: \.isDefault) ?? (try? store.loadAccounts())?.first,
              let token = try? store.mcpToken(username: account.username), !token.isEmpty else {
            statusLine = "要備份到 GitHub，請先到 設定 › GitHub 登入"
            return
        }
        busy = true; defer { busy = false }
        let entry = TatwoEntry()
        let slug = account.username + "/" + Self.repositoryName
        do {
            try Self.ensureRepository(entry: entry, deviceName: Host.current().localizedName ?? "本機")
            if createIfMissing { try await Self.createPrivateRepository(slug: slug, token: token) }
            if Self.gitOutput(["remote", "get-url", "origin"], in: entry.root) == nil {
                _ = Self.gitOutput(["remote", "add", "origin", "https://github.com/\(slug).git"], in: entry.root, allowEmpty: true)
            }
            let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let remote = "tatwo-backup-" + UUID().uuidString.lowercased()
            let url = "https://x-access-token:\(encoded)@github.com/\(slug).git"
            let environment = ["GIT_CONFIG_COUNT": "4",
                               "GIT_CONFIG_KEY_0": "remote.\(remote).url", "GIT_CONFIG_VALUE_0": url,
                               "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
                               "GIT_CONFIG_KEY_2": "http.followRedirects", "GIT_CONFIG_VALUE_2": "false",
                               "GIT_CONFIG_KEY_3": "remote.\(remote).pushurl", "GIT_CONFIG_VALUE_3": url]
            _ = try await PullRequestService.git(["-c", "core.hooksPath=/dev/null", "push", remote, "HEAD:refs/heads/main"],
                                                 at: entry.root, environment: environment)
            statusLine = "GitHub 備份：\(slug)（私人）・剛剛推送"
        } catch {
            statusLine = "GitHub 備份沒完成：\(error.localizedDescription)"
        }
    }

    /// 已存在就沿用（必須是私人倉庫，公開的一律拒絕）；不存在就建一個私人的。
    nonisolated static func createPrivateRepository(slug: String, token: String) async throws {
        func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
            request.httpMethod = method; request.timeoutInterval = 30
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let (status, existing) = try await request("/repos/" + slug, method: "GET")
        if status == 200 {
            guard existing["private"] as? Bool == true else {
                throw OSUpstreamBinding.failure("GitHub 上的 \(slug) 是公開倉庫，不拿來放備份")
            }
            return
        }
        guard status == 404 else { throw OSUpstreamBinding.failure("查不到 GitHub 倉庫狀態（HTTP \(status)）") }
        let name = slug.split(separator: "/").last.map(String.init) ?? repositoryName
        let (created, _) = try await request("/user/repos", method: "POST", body: [
            "name": name, "private": true, "auto_init": false,
            "description": "TATWO OS 入口：憲法、agents.md、使用者偏好、技能、施工單（私人備份）",
        ])
        guard created == 201 else { throw OSUpstreamBinding.failure("建立私人倉庫失敗（HTTP \(created)）") }
    }

    // MARK: git helper（短指令、無 token；輸出只取第一行）

    nonisolated static func gitOutput(_ arguments: [String], in directory: URL, allowEmpty: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            .merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (allowEmpty ? "" : nil) : text
    }

    nonisolated static func displayName(_ remote: String) -> String {
        var text = remote
        for prefix in ["https://github.com/", "git@github.com:"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        return text
    }
}
