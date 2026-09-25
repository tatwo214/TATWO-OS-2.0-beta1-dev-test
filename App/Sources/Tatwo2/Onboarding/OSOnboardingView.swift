import SwiftUI

/// No eager model/service creation until the read-only first-run check has finished.
/// W171：第一次打開不再進接入精靈；套上安全預設就直接進 App，其餘在 設定 › 開始使用 引導。
struct OSOnboardingGate: View {
    let finished: () -> Void
    @State private var checking = true
    @State private var error = ""

    var body: some View {
        Group {
            if checking { ProgressView("檢查本機入口…") }
            else {
                VStack(spacing: 16) {
                    Text("入口需要檢查").font(.title)
                    Text(error).textSelection(.enabled)
                    HStack {
                        Button("重試") { check() }
                        // The OS must stay usable even when the entrance needs attention.
                        Button("先使用 App") { finished() }
                    }
                }.padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 主視窗本身是透明的；這一頁自己鋪底，不透出桌布（使用者 2026-09-22 回報）。
        .background(LiquidGlassTokens.browserGroundFill)
        .task { check() }
    }

    private func check() {
        checking = true
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                Result {
                    let entry = TatwoEntry()
                    // A broken entrance link (e.g. the primary's external volume is unmounted)
                    // is not a new device: never start first-run defaults over it.
                    if entry.status == .brokenSymbolicLink {
                        throw OSUpstreamBinding.failure("入口連結斷開：\(entry.root.path)。外接卷可能未掛載；掛載後按重試，或先使用 App。")
                    }
                    if OSOnboarding.needsOnboarding(entry: entry) {
                        // 沒套上也照樣進 App；原因記在開始使用頁。
                        FirstRunDefaults.applyIfNeeded(entry: entry)
                        return
                    }
                    try OSOnboarding.repairMissingDirectories(entry: entry)
                }
            }.value
            checking = false
            switch result {
            case .success: finished()
            case .failure(let issue): error = issue.localizedDescription
            }
        }
    }
}

struct ManagedRulesRemovalView: View {
    @State private var confirming = false
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("移除 OS 管理區塊", role: .destructive) { confirming = true }.disabled(busy)
            Text("比對安裝前備份與目前檔案雜湊；有手改時停止，不覆蓋使用者內容。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .confirmationDialog("移除各家引擎的 OS 管理區塊？入口、身份與 GBrain 不會刪除。", isPresented: $confirming) {
            Button("比對備份並移除", role: .destructive) {
                busy = true
                Task {
                    let result = await Task.detached { Result { try ManagedRulesRemoval.remove(entry: TatwoEntry()) } }.value
                    busy = false
                    switch result {
                    case .success: message = "已還原；各家檔案雜湊與安裝前一致。"
                    case .failure(let error): message = "未完成：" + error.localizedDescription
                    }
                }
            }
        }
    }
}
