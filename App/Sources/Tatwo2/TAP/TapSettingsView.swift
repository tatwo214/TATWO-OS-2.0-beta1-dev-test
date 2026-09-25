import SwiftUI

/// 設定 › Plugin › TAP（W177；使用者 2026-09-24「設定/plugins/skillet、mcp、tap、pocket」）。
/// 列出每一座 Tap 的狀態、用哪種 Pod、記憶體；可登入、打開網頁版、休眠、啟用／停用。按鈕一律玻璃 chip。
struct TapSettingsView: View {
    /// ChatGPT Space 按「前往登入」時設的旗標：打開這頁就直接跳出登入（Space 裡不放網頁，使用者 09-25）。
    static let loginRequestKey = "tatwo.tap.chatgpt.openLogin"
    @ObservedObject private var chatGPT = ChatGPTTap.shared
    @State private var showsWebPage = false
    /// 這次打開網頁版是為了登入：登入完成就自動關掉（使用者 2026-09-24「登入完應該要優化成自動關閉登入分頁」）。
    @State private var openedForLogin = false
    @State private var footprint: UInt64?
    /// Pod 回報的診斷（只有欄位名稱與短代號，沒有內容）。
    @State private var podDiagnostics: [(String, String)] = []
    @State private var notifyReplies = SpaceNotice.isEnabled(ChatGPTSpaceModel.noticeSpace)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("TAP", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title3.bold())
                Spacer()
                Text("TATWO App Protocol")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()
            // 設定頁外層已經會捲動（PluginsPage 的 scrollsContent），這裡不再包一層 ScrollView。
            VStack(alignment: .leading, spacing: 14) {
                Text("把外部 App 接進 OS：每個 App 一座 Tap，App 的真用戶端跑在 Pod 裡，登入各自隔離。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                chatGPTCard
                Text("權杖只留在 Pod 的網頁裡；OS 不寫檔、不記錄對話內容。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                footprint = chatGPT.pod.footprintBytes
                if chatGPT.connection == .ready { podDiagnostics = await chatGPT.diagnostics() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(isPresented: $showsWebPage, onDismiss: { openedForLogin = false }) {
            TapPodSheet(title: openedForLogin ? "登入 ChatGPT（Pod）" : "ChatGPT 網頁版（Pod）", pod: chatGPT.pod) {
                showsWebPage = false
            }
        }
        .onChange(of: chatGPT.connection) { _, connection in
            if showsWebPage, openedForLogin, connection == .ready { showsWebPage = false }
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: Self.loginRequestKey) else { return }
            UserDefaults.standard.removeObject(forKey: Self.loginRequestKey)
            if chatGPT.connection != .ready { openWebPage(forLogin: true) }
        }
        .accessibilityIdentifier("tap-settings")
    }

    private var chatGPTCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(chatGPT.displayName).font(.headline)
                statusPill(chatGPT.connection)
                Spacer()
                Toggle("啟用", isOn: Binding(get: { ChatGPTTap.isEnabled }, set: { chatGPT.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(LiquidGlassTokens.brandAccent)   // 跟其他設定頁一樣用品牌色，不用系統藍
                    .accessibilityIdentifier("tap.chatgpt.enabled")
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Pod", "\(chatGPT.podKindTitle)（OS 瀏覽器核心，獨立登入空間）")
                row("記憶體", memoryText)
                row("用途", "Space › ChatGPT：用你的 ChatGPT 訂閱聊天，不耗 Codex 額度")
                // 各 Space 的通知（09-25）：回覆好了用 Island 提示，只放對話名稱。
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("通知").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Toggle("回覆好了，而且你不在那則對話上時，用 Island 通知（只顯示對話名稱）", isOn: Binding(
                        get: { notifyReplies }, set: { notifyReplies = $0; SpaceNotice.setEnabled(ChatGPTSpaceModel.noticeSpace, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.callout)
                        .tint(LiquidGlassTokens.brandAccent)
                        .accessibilityIdentifier("tap.chatgpt.notify")
                }
                if let shape = chatGPT.lastStreamShape {
                    // 診斷用：只有事件名稱與欄位名稱，沒有對話內容。
                    row("串流", chatGPT.lastStreamParsed ? "逐段解析正常" : "解析不到，改用網頁畫面顯示")
                    Text(shape)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.leading, 58)
                        .accessibilityIdentifier("tap.chatgpt.streamShape")
                }
                if !podDiagnostics.isEmpty {
                    row("診斷", "欄位名稱與代號，沒有對話內容")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(podDiagnostics.indices, id: \.self) { index in
                            Text("\(podDiagnostics[index].0)：\(podDiagnostics[index].1)")
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.leading, 58)
                    .accessibilityIdentifier("tap.chatgpt.diagnostics")
                }
            }
            HStack(spacing: 8) {
                if chatGPT.connection == .needsLogin {
                    chip("登入", systemImage: "person.crop.circle") { openWebPage(forLogin: true) }
                } else if chatGPT.connection != .off {
                    chip("打開網頁版", systemImage: "globe") { openWebPage(forLogin: false) }
                }
                if chatGPT.pod.isRunning {
                    chip("休眠", systemImage: "moon") { chatGPT.sleep() }
                }
                if chatGPT.connection == .ready {
                    // 診斷：打開網頁自己的選單看有哪些選項（只看不按）。
                    chip("探查網頁選單", systemImage: "magnifyingglass") {
                        Task { await chatGPT.probe(conversationID: ChatGPTSpaceModel.shared.selectedIDForProbe, library: true) }
                    }
                }
                if case .failed = chatGPT.connection {
                    chip("重新連上", systemImage: "arrow.clockwise") { chatGPT.restart() }
                }
            }
        }
        .padding(16)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
        .accessibilityIdentifier("tap.chatgpt.card")
    }

    private var memoryText: String {
        guard chatGPT.pod.isRunning else { return "休眠中，不佔記憶體" }
        guard let footprint else { return "讀取中" }
        return String(format: "約 %.0f MB", Double(footprint) / 1_048_576)
    }

    private func openWebPage(forLogin: Bool) {
        chatGPT.start()
        openedForLogin = forLogin
        showsWebPage = true
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value).font(.callout)
        }
    }

    private func chip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatGlassChip()
    }

    private func statusPill(_ connection: TapConnection) -> some View {
        let (text, color): (String, Color) = switch connection {
        case .off: ("已停用", .secondary)
        case .starting: ("連線中", .orange)
        case .needsLogin: ("需要登入", .orange)
        case .ready: ("已連上", .green)
        case .sleeping: ("休眠中", .secondary)
        case .failed(let message): ("出錯：\(message)", .red)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .chatGlassChip()
        .accessibilityIdentifier("tap.chatgpt.status")
    }
}

/// 在設定頁直接看 Pod 的網頁（登入、確認帳號）；關掉就交回 Space 或停泊視窗。
struct TapPodSheet: View {
    let title: String
    let pod: TapWebPod
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Text("完成")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chatGlassChip()
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            TapPodHostView(pod: pod)
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 640, idealHeight: 720)
    }
}
