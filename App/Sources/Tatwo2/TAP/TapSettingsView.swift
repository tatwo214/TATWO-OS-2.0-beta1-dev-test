import SwiftUI

/// 設定 › Plugin › TAP（W177；使用者 2026-09-24「設定/plugins/skillet、mcp、tap、pocket」）。
/// 列出每一座 Tap 的狀態、用哪種 Pod、記憶體；可登入、休眠、啟用／停用。按鈕一律玻璃 chip。
/// W183 R5（使用者 09-28）：「打開網頁版用不到」拿掉；診斷「一大堆文字」收成一列，要看再展開。
/// W183 R8a（使用者 09-28「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」）：ChatGPT 卡與 ChatGPT build 合成一張；診斷、探查、休眠收進卡頭的「…」。
struct TapSettingsView: View {
    /// ChatGPT Space 按「前往登入」時設的旗標：打開這頁就直接跳出登入（Space 裡不放網頁，使用者 09-25）。
    static let loginRequestKey = "tatwo.tap.chatgpt.openLogin"
    @ObservedObject var chatGPT: ChatGPTTap = .shared
    @State private var showsFlow = false
    #if DEBUG
    var testBuildFrame: HandsBuildModel.Frame? = nil
    #endif
    @State private var showsWebPage = false
    /// 這次打開網頁版是為了登入：登入完成就自動關掉（使用者 2026-09-24「登入完應該要優化成自動關閉登入分頁」）。
    @State private var openedForLogin = false
    @State private var footprint: UInt64?
    /// Pod 回報的診斷（只有欄位名稱與短代號，沒有內容）。
    @State private var podDiagnostics: [(String, String)] = []
    @State private var notifyReplies = SpaceNotice.isEnabled(ChatGPTSpaceModel.noticeSpace)
    /// 診斷（串流形狀、Pod 欄位代號）預設收起。
    @State private var showsDiagnostics = false

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
                chatGPTCard   // W183 R8a：ChatGPT 與 ChatGPT build 合成一張卡
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
                footprint = chatGPT.webPod?.footprintBytes
                if chatGPT.connection == .ready { podDiagnostics = await chatGPT.diagnostics() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(isPresented: $showsWebPage, onDismiss: { openedForLogin = false }) {
            if let pod = chatGPT.webPod {
                TapPodSheet(title: "ChatGPT 登入", pod: pod) { showsWebPage = false }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap-settings")
    }

    /// W183 R8a（使用者 09-28「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」；對照稿 w183-r8-mock-Main）：一張卡。
    /// 卡頭（ChatGPT 圖示、狀態、「啟用」）→ 分隔線 →「ChatGPT build」一列＋節點流程＋節點面板（New/ChatGPTBuildSection.swift）。
    /// 以前攤開的 Pod、記憶體、用途、通知、診斷、探查、休眠收進卡頭的「…」；要你按的（登入、重新連上）留在卡頭。
    private var chatGPTCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(nsColor: .textBackgroundColor))
                    Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    ChatGPTLogo()
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                Button { showsFlow.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(chatGPT.displayName).font(.system(size: 17, weight: .semibold))
                        statusPill(chatGPT.connection)
                        Image(systemName: showsFlow ? "chevron.up" : "chevron.down").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel("ChatGPT \(chatGPT.isLoggedIn ? "已登入" : "未登入") 運作圖")
                .accessibilityValue(showsFlow ? "展開" : "收合")
                .accessibilityIdentifier("tap.chatgpt.flow.toggle")
                Spacer(minLength: 8)
                ChatGPTTapLoginButton(tap: chatGPT) { openWebPage(forLogin: true) }
                if case .failed = chatGPT.connection {
                    chip("重新連上", systemImage: "arrow.clockwise") { chatGPT.restart() }
                }
                moreMenu
                Text("啟用").font(.system(size: 13)).foregroundStyle(.secondary)
                Toggle("啟用", isOn: Binding(get: { ChatGPTTap.isEnabled }, set: { chatGPT.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(LiquidGlassTokens.brandAccent)   // 跟其他設定頁一樣用品牌色，不用系統藍
                    .accessibilityIdentifier("tap.chatgpt.enabled")
            }
            Divider()
            // W183 R8a：ChatGPT build（原「ChatGPT 手腳」）：開關、ⓘ、節點流程與面板（邏輯在 Facade/HandsBuildModel.swift）。
            buildSection
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.card")
    }

    private var buildSection: some View {
        var section = ChatGPTBuildSection(showsFlow: showsFlow, onEnableChatGPT: { chatGPT.setEnabled(true) })
        #if DEBUG
        section.testFrame = testBuildFrame
        #endif
        return section
    }

    /// 卡頭的「…」：Pod 與記憶體、通知、診斷、探查網頁選單、休眠（不佔版面，按了才打開）。
    private var moreMenu: some View {
        Menu {
            Text("\(chatGPT.podKindTitle)・記憶體 \(memoryText)")
            Text("用途：Space › ChatGPT，不耗 Codex 額度")
            Divider()
            // 各 Space 的通知（09-25）：回覆好了用 Island 提示，只放對話名稱。
            Toggle("回覆好了用 Island 通知（只顯示對話名稱）", isOn: Binding(
                get: { notifyReplies }, set: { notifyReplies = $0; SpaceNotice.setEnabled(ChatGPTSpaceModel.noticeSpace, $0) }))
                .accessibilityIdentifier("tap.chatgpt.notify")
            if chatGPT.lastStreamShape != nil || !podDiagnostics.isEmpty {
                // 診斷用：只有事件名稱與欄位名稱，沒有對話內容。按了才打開（小卡片）。
                Button("診斷") { showsDiagnostics = true }
            }
            if chatGPT.connection == .ready {
                // 診斷：打開網頁自己的選單看有哪些選項（只看不按）。
                Button("探查網頁選單") {
                    Task { await chatGPT.probe(conversationID: ChatGPTSpaceModel.shared.selectedIDForProbe, library: true) }
                }
            }
            if chatGPT.webPod?.isRunning == true {
                Button("休眠") { chatGPT.sleep() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
        .accessibilityLabel("ChatGPT 更多")
        .accessibilityIdentifier("tap.chatgpt.more")
        .popover(isPresented: $showsDiagnostics, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("診斷").font(.system(size: 13, weight: .semibold))
                Text(chatGPT.lastStreamShape == nil || chatGPT.lastStreamParsed ? "正常" : "串流解析不到，改用網頁畫面顯示")
                    .font(.callout)
                if showsDiagnostics {
                    VStack(alignment: .leading, spacing: 2) {
                        if let shape = chatGPT.lastStreamShape {
                            Text("串流：\(shape)").accessibilityIdentifier("tap.chatgpt.streamShape")
                        }
                        ForEach(podDiagnostics.indices, id: \.self) { index in
                            Text("\(podDiagnostics[index].0)：\(podDiagnostics[index].1)")
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .accessibilityIdentifier("tap.chatgpt.diagnostics")
        }
    }

    private var memoryText: String {
        guard chatGPT.webPod?.isRunning == true else { return "休眠中，不佔記憶體" }
        guard let footprint else { return "讀取中" }
        return String(format: "約 %.0f MB", Double(footprint) / 1_048_576)
    }

    private func openWebPage(forLogin: Bool) {
        chatGPT.start()
        openedForLogin = forLogin
        showsWebPage = true
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
        case .off: (chatGPT.isLoggedIn ? "已登入・停用" : "未登入・停用", .secondary)
        case .starting: ("連線中", .orange)
        case .needsLogin: ("未登入", .orange)
        case .ready: ("已登入", .green)
        case .sleeping: (chatGPT.isLoggedIn ? "已登入・休眠中" : "未登入・休眠中", .secondary)
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
