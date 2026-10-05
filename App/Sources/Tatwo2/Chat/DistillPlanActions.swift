import SwiftUI

/// W180 E4：/蒸餾 畫布下方的操作區。
/// 上排「整理成」玻璃 chip（技能｜清單｜SOP｜GBrain，預設技能）；換類型只存畫布，不自動送出。
/// 兩步寫入：「預覽寫入」列出會寫到哪、同名舊檔會不會先封存 →「確認寫入」才寫（畫布一改，預覽就失效）。
/// 寫好之後有「還原」（卡片內玻璃確認列，不跳系統框）；同一條再 /蒸餾 時，上一份的還原留在「之前的寫入」。
/// 寫入交給別台執行而結果沒確認時，有「再查一次」（只查，不重送）。不用藍色系統鈕。
struct DistillPlanActions: View {
    let artifact: TatwoPlanArtifactV1
    let isDisabled: Bool
    let actions: DistillCanvasActions
    @State private var preview: DistillWritePlan?
    @State private var busy = false
    @State private var message = ""
    /// 正在確認要還原的那一次寫入。
    @State private var confirmingRestore: UUID?

    private var content: String { artifact.editableText() }
    private var output: DistillOutputKind { DistillCanvas.output(of: artifact) }
    private var problems: [String] { DistillCanvas.problems(content, output: output) }
    /// 預覽要還是現在這份畫布、這個類型才算數。
    private var previewCurrent: Bool {
        guard let preview else { return false }
        return preview.contentSHA == DistillCanvas.sha256(content) && preview.output == output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let submission = artifact.distillSubmission {
                result(submission)
            } else {
                draft
            }
            let earlier = artifact.distillEarlier ?? []
            if !earlier.isEmpty {
                Divider()
                Text("之前的寫入（同一條上一次 /蒸餾）").font(.caption).foregroundStyle(.secondary)
                ForEach(earlier, id: \.id) { submission in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(submission.title).font(.system(size: 12, weight: .semibold))
                        result(submission)
                    }
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .onChange(of: content) { _, _ in preview = nil }
        .onChange(of: output) { _, _ in preview = nil }
    }

    // MARK: 還沒寫入

    @ViewBuilder private var draft: some View {
        HStack(spacing: 6) {
            Text("整理成").foregroundStyle(ChatGlassChipModifier.chipForeground)
            ForEach(DistillOutputKind.allCases, id: \.self) { kind in
                Button(kind.label) { actions.setOutput(artifact.planID, kind) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .chatGlassChip(isSelected: kind == output)
                    .disabled(busy || isDisabled)
                    .accessibilityIdentifier("distill-output-\(kind.rawValue)")
            }
        }
        Text("換類型只存畫布；要 AI 照新類型重寫，在對話說「照這個類型重寫」。沒按「確認寫入」不會寫到任何地方。")
            .font(.caption).foregroundStyle(.secondary)
        if let executesOn = actions.executesOn {
            Text("寫入在\(executesOn)執行，那台會再檢查一次。").font(.caption).foregroundStyle(.secondary)
        }
        if let blocked = actions.blocked {
            Text(blocked).font(.caption).foregroundStyle(.orange)
        }
        if let queuedOn = actions.queuedOn {   // W182 R5：主設備離線時先排隊
            Text("按「確認寫入」後會在「\(queuedOn)」寫入；那台會再預覽檢查一次，有同名舊檔就不寫。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let failure = actions.queueFailure(artifact.planID) {   // W182 R5：上次排隊的那次主設備說不能做
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("上次排隊的寫入沒寫成：\(failure)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                chip("知道了", selected: false) { actions.dismissQueueFailure(artifact.planID) }
                    .accessibilityIdentifier("distill-queue-failure-dismiss")
            }
        }
        if previewCurrent, let preview {
            previewCard(preview)
        } else {
            if !problems.isEmpty {
                Text("還不能寫入：\n" + problems.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            chip(busy ? "預覽中…" : "預覽寫入", selected: false) { runPreview() }
                .disabled(busy || isDisabled || !problems.isEmpty || actions.blocked != nil)
                .accessibilityIdentifier("distill-preview")
        }
    }

    @ViewBuilder private func previewCard(_ plan: DistillWritePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.targets, id: \.path) { target in
                if target.path.hasPrefix("gbrain:") {
                    Text("會寫到 GBrain：\(plan.name)（同名舊頁若存在，會先封存）").textSelection(.enabled)
                } else {
                    Text("會寫到：\(target.path)").textSelection(.enabled)
                    if target.action == .replace {
                        Text("同名\(plan.output == .skill ? "技能" : "筆記")已存在，舊版會先封存，之後可以還原。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let executesOn = actions.executesOn {
                Text("交給\(executesOn)寫。").foregroundStyle(.secondary)
            }
            if let queuedOn = actions.queuedOn, plan.targets.isEmpty {   // W182 R5
                Text("會整理成\(plan.output.label)「\(plan.name.isEmpty ? plan.title : plan.name)」；寫入位置由「\(queuedOn)」預覽確認。")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                chip(busy ? "寫入中…" : "確認寫入", selected: true) { runWrite() }
                    .disabled(!previewCurrent || busy || isDisabled || actions.blocked != nil)
                    .accessibilityIdentifier("distill-confirm-write")
                chip("返回修改", selected: false) { self.preview = nil }
                    .disabled(busy)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: 寫入之後

    @ViewBuilder private func result(_ submission: DistillSubmission) -> some View {
        switch submission.status {
        case nil:
            Text("舊版 /蒸餾 送出紀錄：\n\(submission.message)").textSelection(.enabled)
        case "queued"?:   // W182 R5：排隊中；可以取消（畫布解鎖）；W201 不報備自動重連。
            Text("等送出").textSelection(.enabled)
            chip("取消排隊", selected: false) { actions.cancelQueued(artifact.planID, submission.id) }
                .disabled(busy)
                .accessibilityIdentifier("distill-cancel-queued")
        case "writing"?:
            Text(busy ? "寫入中…" : "上次寫入沒有確認結果；請先查 \(targets(submission))，不會自動重送。")
                .textSelection(.enabled)
            checkChip(submission)
        case "done"?:
            Text((submission.receiptLines ?? [submission.message]).joined(separator: "\n")).textSelection(.enabled)
            if submission.archivePath != nil, submission.restoredAt == nil {
                if confirmingRestore == submission.id {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("還原後，這次寫的新版會搬進封存、舊版放回原處。確定還原？")
                        HStack(spacing: 8) {
                            chip(busy ? "還原中…" : "還原", selected: true) { runRestore(submission.id) }
                                .disabled(busy || actions.blocked != nil)
                                .accessibilityIdentifier("distill-restore-confirm")
                            chip("取消", selected: false) { confirmingRestore = nil }.disabled(busy)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    chip("還原", selected: false) { confirmingRestore = submission.id }
                        .disabled(busy || actions.blocked != nil)
                        .accessibilityIdentifier("distill-restore")
                }
            }
        case "restored"?:
            Text("已還原。\n" + (submission.receiptLines ?? []).joined(separator: "\n")).textSelection(.enabled)
        default:
            Text(submission.message + "\n目的地：\(targets(submission))").textSelection(.enabled)
            checkChip(submission)
        }
    }

    /// 寫入交給別台執行、結果沒確認：到那台再查一次（只查，不重送）。
    @ViewBuilder private func checkChip(_ submission: DistillSubmission) -> some View {
        if actions.executesOn != nil {
            chip(busy ? "查詢中…" : "再查一次", selected: false) { runCheck(submission.id) }
                .disabled(busy || actions.blocked != nil)
                .accessibilityIdentifier("distill-check")
        }
    }

    private func targets(_ submission: DistillSubmission) -> String {
        let paths = (submission.targets ?? []).map(\.path)
        return paths.isEmpty ? "目的地" : paths.joined(separator: "、")
    }

    private func chip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .chatGlassChip(isSelected: selected)
    }

    // MARK: 動作

    private func runPreview() {
        guard !busy else { return }
        busy = true; message = ""
        actions.preview(artifact.planID) { outcome in
            busy = false
            switch outcome {
            case .success(let plan): preview = plan
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    /// 只有預覽還是現在這份畫布時才寫；送出的快照先存進畫布（界線）才碰目的地，由 actions.write 那一側負責。
    private func runWrite() {
        guard previewCurrent, let plan = preview, !busy, !isDisabled else { return }
        busy = true; message = ""
        actions.write(artifact.planID, plan) { result in
            busy = false
            preview = nil
            message = result.failed ? result.message : ""
        }
    }

    private func runRestore(_ submission: UUID) {
        guard !busy else { return }
        busy = true; message = ""
        actions.restore(artifact.planID, submission) { result in
            busy = false
            confirmingRestore = nil
            message = result.failed ? result.message : ""
        }
    }

    private func runCheck(_ submission: UUID) {
        guard !busy else { return }
        busy = true; message = ""
        actions.check(artifact.planID, submission) { result in
            busy = false
            message = result.failed || result.pending ? result.message : ""
        }
    }
}
