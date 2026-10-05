// 2.0 新畫面（不是照搬）：設定頁「模型登入」— 三家引擎各自登入／登出、額度條、不用 API 金鑰（W181 R3 前叫「禁用 API」）。
// 使用者 2026-09-05：標題改「模型登入」、GPT 改 OpenAI、少註解、額度條、列向左拖拽出「禁用 API」、登出鈕重設計並上下置中。
import SwiftUI

struct EngineLoginCard: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject var chatGPT: ChatGPTTap = .shared
    var environmentTarget: EnvironmentLoginTarget? = nil
    #if DEBUG
    final class Probe {
        var details: [ClaudeSidecar.Kind: CGRect] = [:]
        var expanded: Set<ClaudeSidecar.Kind> = []
        var environmentToggle: CGRect?
    }
    var testProbe: Probe? = nil
    #endif
    @State private var environmentExpanded = false
    @State private var expandedDetails: Set<ClaudeSidecar.Kind> = []
    @State private var loginInput = ""
    @State private var confirmResetCredit = false

    private let kinds: [ClaudeSidecar.Kind] = [.codex, .claude, .grok]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
        VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
            TatwoSettingsPageHeader(title: "登入") {
                OSChipButton(title: "重新檢查") { model.refreshEngineLogins(); model.refreshEngineQuotas() }
            }
            // W171 初始設定：登入任何一家就能開始對話。
            if !model.engineLogins.contains(where: \.isLoggedIn) {
                SetupBanner(done: false, text: "登入下面其中一個就能開始對話。") { EmptyView() }
            }

            VStack(spacing: 0) {
                ChatGPTTapLoginRow(tap: chatGPT).padding(.vertical, 8).padding(.horizontal, 6)
                Divider().opacity(0.5)
                ForEach(kinds, id: \.rawValue) { kind in
                    SwipeRevealRow(revealWidth: 132, isRevealedInitially: false) {
                        row(kind)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                    } reveal: {
                        VStack(spacing: 4) {
                            Button {
                                model.toggleEngineDisabled(kind)
                            } label: {
                                // W181 R3：勾了只是不用 API 金鑰（按量計費），訂閱登入照常能跑。
                                HStack(spacing: 5) {
                                    Image(systemName: model.isAPIKeyOptedOut(kind) ? "checkmark.circle" : "nosign")
                                    Text(model.isAPIKeyOptedOut(kind) ? "可以用 API 金鑰" : "不用 API 金鑰")
                                        .lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                                .foregroundStyle(.white)
                                .background(model.isAPIKeyOptedOut(kind) ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)   // 以後的開關往下塞
                        }
                        .padding(6)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.secondary.opacity(0.06))
                    }
                    Divider().opacity(0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.engineLoginInProgress != nil {
                loginProgress
            }
            Button { environmentExpanded.toggle() } label: {
                HStack { Text("環境登入"); Spacer(); Image(systemName: environmentExpanded ? "chevron.up" : "chevron.down") }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("login.environment.toggle")
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.environmentToggle = $0 }
            #endif
            if environmentExpanded {
                EnvironmentLoginTabPicker()
                GitHubBackupSetupBanner().id(EnvironmentLoginTarget.backup.rawValue)
                    .accessibilityIdentifier("login.environment.backup")
                UpdateAvailableCard().id(EnvironmentLoginTarget.update.rawValue)
                    .accessibilityIdentifier("login.environment.update")
                EnvironmentLoginContent(model: model).id(environmentTarget?.rawValue == "cloudflare" ? "cloudflare" : "github")
                    .accessibilityIdentifier("login.environment.accounts")
                TapSettingsView(chatGPT: chatGPT)
            }
        }
        .padding(TatwoSettingsPageMetrics.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refreshEngineLogins(); model.refreshEngineQuotas() }
        .task(id: environmentTarget) {
            guard let target = environmentTarget else { return }
            if let tab = EnvironmentLoginTab(rawValue: target == .backup ? "github" : target.rawValue) {
                UserDefaults.standard.set(tab.rawValue, forKey: EnvironmentLoginTab.storageKey)
            }
            environmentExpanded = true
            await Task.yield()
            proxy.scrollTo(target.rawValue, anchor: .top)
        }
        }
    }

    static func runtimeSummary(_ choice: EngineRuntimeSelection.Choice) -> String {
        choice.source == "本機" ? "用的是本機較新的版本" : "用的是 App 內附的版本"
    }

    // MARK: 一列

    @ViewBuilder
    private func row(_ kind: ClaudeSidecar.Kind) -> some View {
        let status = model.engineLogins.first(where: { $0.kind == kind })
        let loggedIn = status?.isLoggedIn ?? false
        // W181 R3：勾了不用 API 金鑰才有這一小行；blocked＝勾了、而且這台只有 API 金鑰（送不出）。不起子程序。
        let optOut = EngineDisableStore.optOutLabel(kind, optedOut: model.disabledEngines)
        let disabled = optOut?.blocked ?? false
        let detail = model.engineQuotaDetails[kind.rawValue]
        let account = detail?.accountLabel ?? status?.account
        HStack(alignment: .top, spacing: 12) {
            // 各家 logo 取代小圓點（使用者 2026-09-05）；未登入變淡、送不出（W181 R3）加紅圈
            ZStack {
                if kind == .codex { ChatGPTLogo() }
                else if let logo = ProviderSVGIconLoader.image(for: Self.logoID(kind)) {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)      // SVG 是單色，淺色主題要跟著文字色，不然看不見
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                } else {
                    Text(String(Self.title(kind).prefix(1)))
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.top, 3)
            .opacity(loggedIn ? 1 : 0.35)
            .overlay(
                Circle().stroke(Color.red.opacity(disabled ? 0.8 : 0), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            )

            VStack(alignment: .leading, spacing: 6) {
                // 第一行：名字・等級（純文字）・到期
                HStack(spacing: 10) {
                    Text(Self.title(kind))
                        .font(.subheadline.weight(.semibold))
                    Text(detail?.tierLabel ?? Self.plan(kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let expires = detail?.expiresAt {
                        Text("到期 \(Self.day(expires))").font(.caption).foregroundStyle(.secondary)
                    } else if let since = detail?.subscribedAt {
                        Text("訂閱起 \(Self.day(since))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let optOut {
                        Text(optOut.text)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(optOut.blocked ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                }
                // 第二行：帳號，靠左
                Text(loggedIn ? (account ?? "已登入") : "未登入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail, !detail.windows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.windows) { w in windowBar(w) }
                    }
                    .padding(.top, 2)
                    if let credits = detail.creditsBalance {
                        Text("點數 \(credits)").font(.caption).foregroundStyle(.secondary)
                    }
                    // W120（使用者 2026-09-21）：「查看原始回傳不用」；重置券改成「券符號 ×N」——有券可點（仍要二次確認），0 張或查不到就變暗不能點。
                    if kind == .codex {
                        let tickets = detail.resetCreditCount ?? 0
                        Button { confirmResetCredit = true } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "ticket")
                                Text("×\(tickets)").monospacedDigit()
                            }
                            .font(.caption).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tickets > 0 ? Color.accentColor : Color.secondary)
                        .opacity(tickets > 0 ? 1 : 0.35)
                        .disabled(tickets <= 0)
                        .help(tickets > 0 ? "重置券 \(tickets) 張；點一下使用一張（會再確認一次）" : "沒有重置券")
                        .accessibilityLabel("重置券 \(tickets) 張").accessibilityIdentifier("engine.codex.resetTicket")
                    }
                } else if loggedIn {
                    Text(detail?.note.isEmpty == false ? (detail?.note == ClaudeCredentialStore.accessDeniedReason ? "需要允許讀取額度" : "暫時讀不到額度，可稍後重新檢查。") : "額度讀取中…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    // W106：鑰匙圈授權只能由使用者自己觸發；按了才會出現 macOS 的授權視窗，選「永遠允許」即可。
                    if kind == .claude, detail?.note == ClaudeCredentialStore.accessDeniedReason {
                        Button("允許讀取額度…") { model.authorizeClaudeQuotaRead() }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                if let choice = status?.executableChoice {
                    Text(Self.runtimeSummary(choice)).font(.caption2).foregroundStyle(.secondary)
                }
                if status?.executableChoice != nil || detail?.note.isEmpty == false {
                    DisclosureGroup("詳細", isExpanded: Binding(
                        get: { expandedDetails.contains(kind) },
                        set: { expanded in
                            if expanded { expandedDetails.insert(kind) } else { expandedDetails.remove(kind) }
                            #if DEBUG
                            testProbe?.expanded = expandedDetails
                            #endif
                        })) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let choice = status?.executableChoice {
                                Text(choice.summary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let note = detail?.note, !note.isEmpty {
                                Text(note).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        testProbe?.details[kind] = frame
                    }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if model.engineLoginInProgress == kind {
                    ProgressView().controlSize(.small)
                } else if loggedIn {
                    Button {
                        model.logoutEngine(kind)
                    } label: {
                        Text("登出")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    OSChipButton(title: "登入", isPrimary: true) { model.loginEngine(kind) }
                        .disabled(model.engineLoginInProgress != nil)
                }
            }
            .frame(alignment: .top)
        }
        .opacity(disabled ? 0.6 : 1)
        .alert("確定要用掉一張重置券？", isPresented: $confirmResetCredit) {
            Button("取消", role: .cancel) {}
            Button("用掉", role: .destructive) { model.consumeOpenAIResetCredit() }
        } message: {
            Text("這是 OpenAI 給的「額度重置券」，用掉就沒了。你說過要留給 GPT-6，確定現在用？")
        }
    }

    private func windowBar(_ w: EngineQuotaDetail.Window) -> some View {
        let remaining = max(0, min(100, 100 - w.usedPercent))
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                // 內建 ProgressView 的軌道在紙感底色上幾乎看不見；自己畫，軌道有實際對比。
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(remaining < 15 ? Color.red : (remaining < 40 ? Color.orange : Color.accentColor))
                        .frame(width: max(3, 120 * remaining / 100))
                }
                .frame(width: 120, height: 6)
                Text("剩 \(Int(remaining.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, alignment: .leading)
            }
            Text(w.resetsAt.map { "重置 \(Self.countdown($0))" } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(w.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .trailing)
        }
    }

    // MARK: 登入進度

    private var loginProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("登入中… 瀏覽器會自己打開；沒開的話把下面的網址貼到瀏覽器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.engineLoginLog.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField("輸入驗證碼", text: $loginInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                OSChipButton(title: "送出", isPrimary: true) { submit() }
                    .disabled(loginInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func submit() {
        model.submitEngineLoginInput(loginInput)
        loginInput = ""
    }

    private static func title(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .grok: "Grok"
        }
    }

    private static func plan(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "ChatGPT 訂閱"
        case .claude: "Claude 訂閱"
        case .grok: "SuperGrok 訂閱"
        }
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private static func countdown(_ date: Date) -> String {
        let now = ChatPageModel.exportChatScene != nil || ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            ? Date(timeIntervalSinceReferenceDate: 800_000_000) : Date()
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "現在" }
        if s < 3_600 { return "\(s / 60) 分後" }
        if s < 86_400 { return "\(s / 3_600) 小時 \((s % 3_600) / 60) 分後" }
        return "\(s / 86_400) 天 \((s % 86_400) / 3_600) 小時後"
    }

    private static func logoID(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "codex-gpt"
        case .claude: "claude"
        case .grok: "grok"
        }
    }

    private static func quotaID(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "codex-gpt"
        case .claude: "claude"
        case .grok: "grok"
        }
    }
}

/// 一列往左拖，底下露出動作鈕（macOS 的 List.swipeActions 在這種卡片裡畫不出來，所以自己做）。
struct SwipeRevealRow<Content: View, Reveal: View>: View {
    let revealWidth: CGFloat
    let isRevealedInitially: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let reveal: () -> Reveal

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat = 0

    init(revealWidth: CGFloat, isRevealedInitially: Bool,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder reveal: @escaping () -> Reveal) {
        self.revealWidth = revealWidth
        self.isRevealedInitially = isRevealedInitially
        self.content = content
        self.reveal = reveal
        _offset = State(initialValue: isRevealedInitially ? -revealWidth : 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            reveal()
                .frame(width: revealWidth)
                .opacity(offset < -8 ? 1 : 0)
            content()
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let proposed = dragStart + value.translation.width
                            offset = max(-revealWidth, min(0, proposed))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                offset = offset < -revealWidth * 0.45 ? -revealWidth : 0
                            }
                            dragStart = offset
                        }
                )
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { offset = 0 }
                        dragStart = 0
                    }
                }
        }
        .clipped()
    }
}

/// ChatGPT TAP 登入；與 Codex 的訂閱登入各自獨立。
struct ChatGPTTapLoginRow: View {
    @ObservedObject var tap: ChatGPTTap
    @State private var showsLogin = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChatGPTLogo()
            VStack(alignment: .leading, spacing: 6) {
                Text("ChatGPT").font(.subheadline.weight(.semibold))
                Text(tap.isLoggedIn ? "已登入" : "未登入").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("login.chatgpt.status")
            }
            Spacer()
            ChatGPTTapLoginButton(tap: tap) { showsLogin = true }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("login.chatgpt.tap")
        .sheet(isPresented: $showsLogin) {
            if let pod = tap.webPod { TapPodSheet(title: "ChatGPT 登入", pod: pod) { showsLogin = false } }
        }
        .onChange(of: tap.isLoggedIn) { _, loggedIn in if loggedIn { showsLogin = false } }
    }
}

struct ChatGPTTapLoginButton: View {
    @ObservedObject var tap: ChatGPTTap
    var onLogin: () -> Void
    var body: some View {
        OSChipButton(title: tap.isLoggedIn ? "登出" : "登入") {
            if tap.isLoggedIn { tap.logout() }
            else { tap.setEnabled(true); onLogin() }
        }.accessibilityIdentifier("login.chatgpt.action")
    }
}
