import Foundation

// W183 R1b：ChatGPT 手腳房間的審查與合併（接口 v3 V6、威脅模型 T16）。
//
// - Hands 專用後端：工作區不在正本的 .tatwo2/wt，不用 worktree 路徑假設；施工卡的 diff 與合併都照工作區紀錄裡**固定的候選 SHA**。
// - diff：`<交件基準>..<候選 SHA>`（--no-ext-diff --no-textconv，DispatchGit.diff）；主線在交件後前進了就在卡上寫「主線已前進」。
// - 合併：照舊用 DispatchGit.merge（固定 SHA、失敗回滾）；另外要求使用者先看過**這一版**的 diff（重新交件＝舊審查作廢）。
// - 關掉「複製合併指令」（DispatchGitContext.mergeCommand 對手腳房間一律拒絕；施工卡不顯示那顆）。

@MainActor
enum HandsReviewLedger {
    /// 房間 → 使用者看過 diff 的候選 SHA（與當時 diff 有沒有被截斷）。
    static var reviewed: [UUID: (candidate: String, truncated: Bool)] = [:]
}

extension ChatPageModel {
    /// W183 R1b：手腳房間的施工卡內容（nil＝不是手腳房間，走一般派工）。還沒交件就沒有候選版本（丟錯＝卡上不給 diff／合併）。
    func handsDispatchGitContext(_ id: UUID) throws -> DispatchGitContext? {
        guard isHandsRoom(id) else { return nil }
        let service = HandsService.attached(to: self)
        guard let record = service.workspaceStore.record(id) else { throw DispatchGitFailure(message: "找不到 ChatGPT 工作區紀錄") }
        guard let candidate = record.candidateSHA, let base = record.submittedBaseSHA else {
            throw DispatchGitFailure(message: "ChatGPT 還沒交件，沒有候選版本")
        }
        guard let live, let project = live.projectRecord(record.projectID) else { throw DispatchGitFailure(message: "找不到專案") }
        return DispatchGitContext(id: id, title: record.title, workdir: project.workdir, worktree: service.workspaceRepoPath(record),
                                  branch: record.branch, deviceID: nil, handsCandidate: candidate, handsBase: base)
    }

    /// 看過這一版 diff（施工卡「查看 diff」載入成功時記）。
    func handsMarkReviewed(_ context: DispatchGitContext, truncated: Bool) {
        guard let candidate = context.handsCandidate else { return }
        HandsReviewLedger.reviewed[context.id] = (candidate, truncated)
    }

    /// 合併前：手腳房間要先看過**現在這個**候選版本的 diff。回（確認框要加的提醒）。
    func handsMergeCheck(_ context: DispatchGitContext, preview: DispatchMergePreview) throws -> String {
        guard let candidate = context.handsCandidate else { return "" }
        guard let seen = HandsReviewLedger.reviewed[context.id], seen.candidate == candidate, preview.branchHead == candidate else {
            throw DispatchGitFailure(message: "ChatGPT 的候選版本（\(candidate.prefix(8))）你還沒看過 diff，或看過之後又重新交件了：先按「查看 diff」")
        }
        var note = "\n候選版本：\(candidate.prefix(8))（ChatGPT 手腳；外部資料）"
        if let base = context.handsBase, preview.head != base {
            note += "\n⚠︎ 主線已前進（交件基準 \(base.prefix(8))、現在 \(preview.shortHead)）：合併結果會跟你審查的版本不同"
        }
        if seen.truncated { note += "\n⚠︎ 你看的 diff 太大被截斷了：審查不完整" }
        return note
    }
}

/// W183 R1b（T16、V6）：ChatGPT 手腳的合併是在主機上跑 git（沙盒外、正本的工作樹），所以用專用的保護：
/// - 任何一層設定有外部合併程式（`merge.<名>.driver`）＝不在 App 裡合併（git 會直接執行它，沒辦法隔離）。
/// - 設定是從專案工作樹裡的檔讀進來的（例如 include.path 指到專案裡的檔）＝不合併（ChatGPT 改得到那個檔）。
/// - 所有 filter（clean／smudge／process）一律關掉（`-c filter.<名>.smudge=` …、required=false）：合併、status 都不會執行它們。
///   合併會寫到的檔只要有 filter 屬性（關掉會寫壞檔），或任何 filter 指令提到要改的檔（下次 git 就會跑 ChatGPT 改過的程式）＝不合併。
/// - hooks、fsmonitor 由 DispatchGit.run 關；另外 gc／maintenance 不自動、不跟子模組、不 renormalize、不驗簽（不跑 gpg）。
/// - 先用 merge-tree 預演（只寫物件、不碰工作樹）；合併用 --no-commit，index 等於預演結果才提交（DispatchGit.handsMerge）。
enum HandsMergeGuard {
    struct Plan: Equatable {
        /// 每個 git 都加（放在子指令前面）。
        let flags: [String]
        /// 設定裡有定義的 filter 名稱（大小寫照原樣）。
        let filters: Set<String>
        /// filter 的指令文字（比對「指令提到要改的檔」）。
        let commands: [String]
    }

    static let baseFlags = ["-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "submodule.recurse=false",
                            "-c", "merge.renormalize=false", "-c", "merge.verifySignatures=false",
                            "-c", "status.submoduleSummary=false", "-c", "core.untrackedCache=false"]

    static func refuse(_ reason: String) -> DispatchGitFailure {
        DispatchGitFailure(message: "ChatGPT 手腳的候選版本不在 App 裡合併：\(reason)。請先看過 diff，再自己決定怎麼合併。")
    }

    /// 讀這個專案實際生效的全部設定（含系統、使用者、include），決定要加哪些旗標；不安全就丟錯。每次合併前重讀。
    static func plan(_ context: DispatchGitContext) throws -> Plan {
        let listing = try DispatchGit.run(["config", "-z", "--show-origin", "--list"], cwd: context.workdir, cap: 1024 * 1024, quiet: true)
        guard listing.status == 0, !listing.truncated else { throw refuse("讀不到完整的 git 設定") }
        let gitDir = try DispatchGit.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: context.workdir, quiet: true)
        guard gitDir.status == 0, let common = HandsPath.realpath(gitDir.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let root = HandsPath.realpath(context.workdir) else { throw refuse("找不到專案的 git 資料夾") }
        var tokens = listing.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        if tokens.last == "" { tokens.removeLast() }
        guard tokens.count % 2 == 0 else { throw refuse("git 設定的格式看不懂") }
        var filters = Set<String>(), commands: [String] = []
        while let origin = tokens.popFirst(), let entry = tokens.popFirst() {
            if origin.hasPrefix("file:") {
                let raw = String(origin.dropFirst(5))
                let absolute = raw.hasPrefix("/") ? raw : root + "/" + raw
                let real = HandsPath.realpath(absolute) ?? URL(fileURLWithPath: absolute).standardizedFileURL.path
                if HandsPath.isWithin(real, root) && !HandsPath.isWithin(real, common) && !HandsPath.isWithin(real, root + "/.git") {
                    throw refuse("git 設定會讀專案工作樹裡的檔（\(raw)），合併後 ChatGPT 改過的內容就會變成設定")
                }
            }
            let newline = entry.firstIndex(of: "\n")
            let key = newline.map { String(entry[..<$0]) } ?? entry
            let value = newline.map { String(entry[entry.index(after: $0)...]) } ?? ""
            let lower = key.lowercased()
            if lower.hasPrefix("merge."), lower.hasSuffix(".driver"), lower.split(separator: ".").count >= 3 {
                throw refuse("這個專案的 git 設定有外部合併程式（\(key)），合併時 git 會直接執行它")
            }
            guard lower.hasPrefix("filter."), let dot = key.lastIndex(of: "."), key.distance(from: key.startIndex, to: dot) > 7 else { continue }
            let variable = key[key.index(after: dot)...].lowercased()
            guard ["clean", "smudge", "process", "required"].contains(variable) else { continue }
            let name = String(key[key.index(key.startIndex, offsetBy: 7)..<dot])
            guard !name.isEmpty, !name.contains("="), !name.contains("\n"), !name.contains("\0") else {
                throw refuse("git filter 的名稱沒辦法安全地關掉（\(name)）")
            }
            filters.insert(name)
            if variable != "required", !value.trimmingCharacters(in: .whitespaces).isEmpty { commands.append(value) }
        }
        var flags = baseFlags
        for name in filters.sorted() {
            flags += ["-c", "filter.\(name).clean=", "-c", "filter.\(name).smudge=", "-c", "filter.\(name).process=",
                      "-c", "filter.\(name).required=false"]
        }
        return Plan(flags: flags, filters: filters, commands: commands)
    }

    /// 預演：merge-tree 算出合併結果（不碰工作樹），列出合併會寫到的檔，檢查 filter 屬性與 filter 指令。回預演的 tree。
    static func rehearse(_ context: DispatchGitContext, plan: Plan, head: String, candidate: String) throws -> String {
        let merged = try DispatchGit.run(["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages", head, candidate],
                                         cwd: context.workdir, extra: plan.flags, quiet: true)
        guard merged.status == 0 else {
            throw merged.status == 1 ? refuse("主線跟候選版本有衝突") : refuse("合併預演失敗")
        }
        let tree = merged.text.split(separator: "\0", omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !merged.truncated, HandsGit.isObjectID(tree) else { throw refuse("合併預演的結果讀不完整") }
        let changed = try DispatchGit.run(["diff-tree", "-r", "-z", "--no-renames", "--name-only", head, tree],
                                          cwd: context.workdir, cap: 8 * 1024 * 1024, extra: plan.flags, quiet: true)
        guard changed.status == 0, !changed.truncated else { throw refuse("列不出合併會寫到哪些檔") }
        let paths = changed.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        for path in paths {
            if let command = plan.commands.first(where: { $0.contains(path) }) {
                throw refuse("合併會改到 git filter 會執行的檔（\(path)；filter 指令：\(command.prefix(80))）")
            }
        }
        guard !plan.filters.isEmpty, !paths.isEmpty else { return tree }
        var input = Data(paths.joined(separator: "\0").utf8); input.append(0)
        let attributes = try DispatchGit.run(["check-attr", "-z", "--stdin", "filter"], cwd: context.workdir, cap: 16 * 1024 * 1024,
                                             extra: plan.flags, stdin: input, quiet: true)
        guard attributes.status == 0, !attributes.truncated else { throw refuse("讀不到檔案的 git 屬性") }
        var fields = attributes.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        if fields.last == "" { fields.removeLast() }
        guard fields.count == paths.count * 3 else { throw refuse("git 屬性的輸出不完整") }
        while let path = fields.popFirst(), let _ = fields.popFirst(), let value = fields.popFirst() {
            if plan.filters.contains(value) {
                throw refuse("合併會寫到有 git filter（\(value)）的檔（\(path)）；App 不執行 filter，寫出來的內容會跟平常不同")
            }
        }
        return tree
    }
}
