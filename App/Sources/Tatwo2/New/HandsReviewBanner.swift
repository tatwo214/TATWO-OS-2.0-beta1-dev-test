// W183 R3：ChatGPT 手腳房間的審查卡（接口 v3 V6、威脅模型 T9、T16）：施工卡「查看 diff」的視窗最上面一條——
// 候選 SHA（審查、測試、合併都是這一個）、主線有沒有在交件後前進、醒目標出「會被執行的檔」（Package.swift、package.json／lockfile、
// Makefile、*.sh、CI 設定、捷徑、執行位元），並寫明這是外部資料、沒有「複製合併指令」。只讀 git 物件（Hands 專用後端），不跑任何程式。
import SwiftUI

struct HandsReviewSummary: Equatable, Sendable {
    let candidate: String
    let base: String
    let mainHead: String?
    let flagged: [String]
    let files: Int
    /// 檢查候選版本時就擋下來的原因（保護路徑、gitlink…）；nil＝檢查通過。
    let refused: String?

    var mainAdvanced: Bool { mainHead.map { $0 != base } ?? false }
}

extension ChatPageModel {
    /// 手腳房間的審查摘要（不是手腳房間、還沒交件＝nil）。git 在背景跑（DispatchGit.background），只讀物件。
    func handsReviewSummary(_ id: UUID) async -> HandsReviewSummary? {
        guard isHandsRoom(id), let context = try? handsDispatchGitContext(id) else { return nil }
        return await handsReviewSummary(context)
    }

    /// 同一個 context（同一個候選 SHA）算摘要。
    func handsReviewSummary(_ context: DispatchGitContext) async -> HandsReviewSummary? {
        guard let candidate = context.handsCandidate, let base = context.handsBase else { return nil }
        let service = HandsService.attached(to: self)
        let workdir = context.workdir
        return try? await DispatchGit.background {
            let head = try? DispatchGit.preview(context).head
            do {
                let check = try service.validateCandidate(workdir: workdir, base: base, candidate: candidate)
                return HandsReviewSummary(candidate: candidate, base: base, mainHead: head, flagged: check.flagged, files: check.files.count, refused: nil)
            } catch {
                return HandsReviewSummary(candidate: candidate, base: base, mainHead: head, flagged: [], files: 0, refused: String(describing: error))
            }
        }
    }

    /// W183 R3 審查：diff 與審查卡**同一次**取同一個 context（同一個候選 SHA）算出來；算完再讀一次候選版本，
    /// ChatGPT 途中重新交件（候選變了）就丟錯、不記「看過」、不顯示混合版本。「查看 diff」與「重新載入」都走這裡。
    func loadDispatchReview(_ id: UUID) async throws -> (diff: DispatchGitDiff, review: HandsReviewSummary?) {
        let context = try dispatchGitContext(id)
        let diff = try await DispatchGit.background { try DispatchGit.diff(context) }
        var review: HandsReviewSummary?
        if context.handsCandidate != nil { review = await handsReviewSummary(context) }
        if let candidate = context.handsCandidate {
            let again = try? dispatchGitContext(id)
            guard again?.handsCandidate == candidate, review?.candidate == candidate else {
                throw DispatchGitFailure(message: "ChatGPT 剛重新交件（候選版本變了）：請再按一次「查看 diff」看新的版本")
            }
        }
        handsMarkReviewed(context, truncated: diff.truncated)   // 記住看過哪一版（合併要同一個 SHA；手腳房間以外不記）
        return (diff, review)
    }
}

struct HandsReviewBanner: View {
    let summary: HandsReviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised").foregroundStyle(.secondary)
                Text("ChatGPT 手腳交件（外部資料）").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("候選版本 \(summary.candidate.prefix(10))・基準 \(summary.base.prefix(8))・\(summary.files) 個檔")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("hands.review.candidate")
            }
            if summary.mainAdvanced, let head = summary.mainHead {
                Label("主線已前進（交件基準 \(summary.base.prefix(8))、現在 \(head.prefix(8))）：合併結果會跟你審查的版本不同，由你決定要不要合併",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hands.review.mainAdvanced")
            }
            if !summary.flagged.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("會被執行的檔（合併前請特別看）", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    ForEach(summary.flagged.prefix(30), id: \.self) { path in
                        Text(path).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if summary.flagged.count > 30 {
                        Text("另外還有 \(summary.flagged.count - 30) 個").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("hands.review.flagged")
            }
            if let refused = summary.refused {
                Text("這個候選版本沒通過檢查：\(refused)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("審查、測試、合併都用上面這個候選版本；ChatGPT 重新交件＝這次的審查作廢。這個房間沒有「複製合併指令」，合併要你在這裡按。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hands.review.banner")
    }
}
