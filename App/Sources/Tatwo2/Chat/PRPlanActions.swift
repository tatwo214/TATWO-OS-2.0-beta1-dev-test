import SwiftUI
import AppKit

struct PRPlanActions: View {
    let artifact: TatwoPlanArtifactV1
    let isDisabled: Bool
    let onConfirm: () -> Void
    let onSubmit: () -> Void
    let onReturnToDiscussion: () -> Void
    var onRetrySubmission: () -> Void = {}
    #if DEBUG
    var testLoggedIn: Bool? = nil
    #endif
    @State private var showsRetryConfirmation = false
    @StateObject private var accounts = GitHubAccountsStore()
    @State private var loggedIn = false
    @State private var loggingIn = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("貢獻到 TATWO OS 公開倉；目前專案須為該倉或其 fork。")
                .font(.caption).foregroundStyle(.secondary)
            if let review = artifact.prReview {
                Text("\(review.account) → \(review.repository)").font(.caption).textSelection(.enabled)
                ForEach(PRPlanReview.files(review.snapshot.diff)) { file in
                    DisclosureGroup {
                        ScrollView(.horizontal) {
                            Text(file.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    } label: {
                        Text("\(file.path)  +\(file.added) / -\(file.removed)")
                            .font(.caption).lineLimit(2).help(file.path)
                    }
                }
            }
            if let message = artifact.prMessage { Text(message).textSelection(.enabled) }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            if !loggedIn {
                Button(loggingIn ? "登入中…" : "登入 GitHub") {
                    loggingIn = true; loginError = nil
                    Task {
                        defer { loggingIn = false }
                        do { _ = try await accounts.loginViaGH(); loggedIn = (try? PullRequestCoordinator.shared.identity()) != nil }
                        catch { loginError = error.localizedDescription }
                    }
                }.disabled(loggingIn)
                if let code = accounts.deviceCode {
                    Text(code).textSelection(.enabled)
                    Button("開啟 GitHub 驗證") {
                        accounts.submitLoginInput("")
                        if let url = accounts.verificationURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if let url = artifact.prReview?.submittedURL {
                Link("已送 PR · \(url.absoluteString)", destination: url)
            } else if artifact.state == .ready {
                if let review = artifact.prReview, review.attempted {
                    if PullRequestService.validRepository(review.repository),
                       let url = URL(string: "https://github.com/\(review.repository)/pulls") {
                        Link("到 GitHub 查", destination: url)
                    }
                    Button("確認後重試") { showsRetryConfirmation = true }
                        .disabled(isDisabled || !loggedIn)
                        .accessibilityIdentifier("pr-plan-retry-submission")
                        .alert("先確認 GitHub 與本機分支", isPresented: $showsRetryConfirmation) {
                            Button("取消", role: .cancel) {}
                            Button("確認未送出，允許重試", action: onRetrySubmission)
                        } message: {
                            Text("請確認沒有已建立的 PR，並檢查本機分支與改動。確認後會重新檢查目前改動，仍需再按「送 PR」才提交。")
                        }
                }
                Button("送 PR", action: onSubmit)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 7).chatGlassChip()
                    .disabled(isDisabled || !loggedIn || artifact.prReview?.attempted != false)
                    .accessibilityIdentifier("pr-plan-submit")
            } else {
                Button(artifact.prImplementationInterrupted == true ? "重試實作" : (artifact.state == .confirmed ? "計畫已確認" : "確認計畫"), action: onConfirm)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 7).chatGlassChip()
                    .disabled(isDisabled || !loggedIn || artifact.state != .discussing || artifact.sections.isEmpty)
                    .accessibilityIdentifier("pr-plan-confirm")
                if artifact.prImplementationInterrupted == true {
                    Button("回到討論", action: onReturnToDiscussion)
                        .disabled(isDisabled)
                        .accessibilityIdentifier("pr-plan-discuss")
                }
            }
        }
        .coderScrollIndicators()
        .onAppear {
            #if DEBUG
            if let testLoggedIn { loggedIn = testLoggedIn; return }
            #endif
            loggedIn = (try? PullRequestCoordinator.shared.identity()) != nil
        }
    }
}
