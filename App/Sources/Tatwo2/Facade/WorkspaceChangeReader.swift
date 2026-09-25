import Foundation

/// W104：「變更收據」原本接的是空殼（面板與取差異的函式都是 1.0 留下的替身，永遠回傳空的），所以按了從來沒反應。
/// 這裡真的去讀這條聊天工作資料夾的 git 狀態。只讀、不寫、不拿 git 的鎖；一律在背景執行緒呼叫。
struct WorkspaceChanges: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notGit             // 工作資料夾不是 git 專案
        case clean              // 是 git 專案，但沒有未提交的變更
        case changed
        case failed(String)     // git 跑不起來或逾時
    }
    var state: State
    var root: String
    var branch: String?
    var diff: TatwoParsedDiff
    /// 還沒被 git 追蹤的新檔（git diff 不會列出內容）。
    var untracked: [String]
    /// 差異太大被截斷：統計與清單仍完整，逐行內容只到上限為止。
    var truncated: Bool

    var fileCount: Int { diff.files.count + untracked.count }
    var added: Int { diff.files.reduce(0) { $0 + $1.addedCount } }
    var removed: Int { diff.files.reduce(0) { $0 + $1.removedCount } }

    static func empty(_ state: State, root: String) -> WorkspaceChanges {
        WorkspaceChanges(state: state, root: root, branch: nil, diff: TatwoParsedDiff(files: []), untracked: [], truncated: false)
    }
}

struct WorkspaceChangeSummary: Equatable, Sendable {
    let files: Int
    let added: Int
    let removed: Int
}

enum WorkspaceChangeReader {
    static let diffByteLimit = 2_000_000
    static let timeout: TimeInterval = 8

    static func read(workdir: String) -> WorkspaceChanges {
        guard let inside = git(["rev-parse", "--is-inside-work-tree"], in: workdir), inside.status == 0,
              inside.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .empty(.notGit, root: workdir)
        }
        let root = git(["rev-parse", "--show-toplevel"], in: workdir)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? workdir
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: workdir).flatMap { $0.status == 0 ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        guard let status = git(["status", "--porcelain", "--untracked-files=normal"], in: workdir), status.status == 0 else {
            return .empty(.failed("git status 沒有回應"), root: root)
        }
        let untracked = status.text.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("?? ") ? String(line.dropFirst(3)) : nil
        }
        // 有 HEAD 就比對 HEAD（含已 stage 的）；全新倉庫還沒有 commit 時改看已 stage 的內容。
        let hasHead = git(["rev-parse", "--verify", "--quiet", "HEAD"], in: workdir)?.status == 0
        let arguments = ["diff"] + (hasHead ? ["HEAD"] : ["--cached"]) + ["--no-color", "--no-ext-diff", "-U3"]
        guard let raw = git(arguments, in: workdir, limit: diffByteLimit), raw.status == 0 || raw.truncated else {
            return .empty(.failed("git diff 沒有回應"), root: root)
        }
        let parsed = TatwoDiffHunkParser.parse(unifiedDiff: raw.text)
        let state: WorkspaceChanges.State = parsed.files.isEmpty && untracked.isEmpty ? .clean : .changed
        return WorkspaceChanges(state: state, root: root, branch: branch, diff: parsed, untracked: untracked, truncated: raw.truncated)
    }

    static func summary(workdir: String) -> WorkspaceChangeSummary? {
        let changes = read(workdir: workdir)
        guard changes.state == .changed else { return nil }
        return WorkspaceChangeSummary(files: changes.fileCount, added: changes.added, removed: changes.removed)
    }

    private struct Output { let status: Int32; let text: String; let truncated: Bool }

    private static func git(_ arguments: [String], in directory: String, limit: Int = 400_000) -> Output? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"      // 只讀：不要跟使用者或引擎正在跑的 git 搶 index.lock
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        var data = Data()
        var truncated = false
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            if data.count >= limit { truncated = true; process.terminate(); break }
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self), truncated: truncated)
    }
}
