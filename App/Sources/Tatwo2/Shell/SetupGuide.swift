// W171 設定 › 開始使用（使用者 2026-09-22 點頭，對照稿 https://claude.ai/artifact/B4QU2bjTMWBCLfXBAGFVmd）：
// 第一次打開直接進 App，要做的事集中在這一頁總覽，各分頁頂端再各放一塊「初始設定」。
// 使用者：「以後設定頁面是否完善 就看開始使用的建設是否完善」——新增設定項時要想它在這裡怎麼出現。
import SwiftUI

@MainActor
final class SetupChecklist: ObservableObject {
    static let shared = SetupChecklist()

    enum State: Equatable {
        case todo, defaulted, done, optional
        var label: String {
            switch self {
            case .todo: "還沒做"
            case .defaulted: "預設"
            case .done: "完成"
            case .optional: "選用"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let state: State
        let section: TatwoSettingsPage.Section
        /// 必做的才算進左下角「還有幾件」。
        let required: Bool
    }

    @Published private(set) var items: [Item] = []
    private(set) var lastLogins: [EngineLoginStatus] = []

    /// 還沒做的必做項（左下角提示與設定預設開哪一頁用）。
    var remaining: Int { items.filter { $0.required && $0.state == .todo }.count }
    /// 左欄要點一個小點的分頁。
    var pendingSections: Set<TatwoSettingsPage.Section> {
        Set(items.filter { $0.state == .todo || $0.state == .defaulted }.map(\.section))
    }

    func refresh(logins: [EngineLoginStatus]) {
        lastLogins = logins
        var next: [Item] = []
        let loggedIn = logins.filter(\.isLoggedIn)
        next.append(Item(id: "model", title: "登入一個 AI 模型",
                         detail: loggedIn.isEmpty ? "要跟 AI 對話，先登入 Claude、ChatGPT 或 Grok 其中一個。"
                             : "已登入：" + loggedIn.map { Self.brand($0.kind) }.joined(separator: "、"),
                         state: loggedIn.isEmpty ? .todo : .done, section: .modelAccess, required: true))

        let engines = EngineLinks.scan().filter { ["claude", "codex", "openclaw"].contains($0.id) && $0.state != .notInstalled }
        let unlinked = engines.filter { $0.state == .notLinked }
        next.append(Item(id: "rules", title: "讓你的 AI 用同一套規則",
                         detail: engines.isEmpty ? "這台沒有裝 Claude Code 或 Codex；TATWO OS 內建的 AI 已經照這套規則。"
                             : unlinked.isEmpty ? "已接上：" + engines.map(\.name).joined(separator: "、")
                             : "這台有 " + unlinked.map(\.name).joined(separator: "、") + "。接上後你講一次的偏好它們都會照做；原本的規則檔會先備份。",
                         state: unlinked.isEmpty ? .done : .todo, section: .os, required: true))

        let identity = try? DeviceIdentityStore.readLocal()
        let failure = FirstRunDefaults.record?.failure
        let deviceState: State = failure != nil && identity == nil ? .todo
            : FirstRunDefaults.awaitsDeviceConfirmation ? .defaulted : .done
        let role = identity?.role == .secondary ? "加入既有那台" : "第一台"
        next.append(Item(id: "device", title: "這台 Mac 的名字和身分",
                         detail: identity == nil ? "還沒建立：\(failure ?? "入口還沒準備好")"
                             : deviceState == .defaulted ? "先用了預設：「\(identity!.name)」· \(role)。已經有另一台的話，到這裡改成配對。"
                             : "「\(identity!.name)」· \(role)",
                         state: deviceState, section: .devices, required: identity == nil))

        if identity?.role != .secondary {
            let backup = EntryBackup.shared.choice
            next.append(Item(id: "backup", title: "備份到你的 GitHub",
                             detail: backup == .enabled ? "已開啟：規則和筆記會存一份到你的私人倉庫。"
                                 : backup == .declined ? "你選了不備份；想開再到這裡。"
                                 : "選用。規則、偏好和筆記存一份到你自己的私人倉庫，換電腦時拿得回來。",
                             state: backup == nil ? .optional : .done, section: .github, required: false))
        }
        let media = BrowserProtectedMedia.status()
        next.append(Item(id: "media", title: "在 OS 瀏覽器播受保護的影音",
                         detail: media == .off ? "選用。部分影音網站要 Google 的播放元件；在瀏覽器設定打開就會下載。Spotify 看下面那一項。"
                             : BrowserProtectedMedia.statusText(media),
                         state: { if case .ready = media { return .done }; return media == .off ? .optional : .todo }(),
                         section: .browserManagement, required: false))
        let spotify = SpotifyConnect.shared.status
        if spotify != .unavailable {
            next.append(Item(id: "spotify", title: "在 OS 裡聽 Spotify",
                             detail: spotify == .signedOut ? "選用。登入一次 Spotify（需要 Premium），之後在 OS 瀏覽器打開 Spotify 就由「\(SpotifyConnect.deviceName)」播放。"
                                 : SpotifyConnect.statusText(spotify),
                             state: spotify == .connected ? .done : spotify == .signedOut ? .optional : .todo,
                             section: .browserManagement, required: false))
        }
        next.append(Item(id: "computer", title: "Computer Use 權限",
                         detail: "選用。要讓 AI 幫你操作畫面時再開。",
                         state: .optional, section: .computerUse, required: false))
        if next != items { items = next }
    }

    static func brand(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .grok: "Grok"
        }
    }
}

/// 設定最上面那一頁：一次看完還有什麼沒做，點一下就到對應分頁。
struct SetupGuidePage: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var checklist = SetupChecklist.shared
    let open: (TatwoSettingsPage.Section) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
                TatwoSettingsPageHeader(title: "開始使用",
                                        subtitle: "不用一次做完。先登入一個模型就能用；其他的等你想好再來，每一件也都在對應的分頁。")
                let items = checklist.items
                let settled = items.filter { $0.state == .done || $0.state == .defaulted }.count
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(LiquidGlassTokens.brandAccent)
                            .frame(width: items.isEmpty ? 0 : proxy.size.width * CGFloat(settled) / CGFloat(items.count))
                    }
                }
                .frame(height: 5)
                VStack(spacing: 10) {
                    ForEach(items) { item in row(item) }
                }
            }
            .padding(TatwoSettingsPageMetrics.inset)
        }
        .onAppear { checklist.refresh(logins: model.engineLogins) }
    }

    private func row(_ item: SetupChecklist.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13.5, weight: .semibold))
                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            SetupStateChip(state: item.state)
            OSChipButton(title: item.state == .done ? "查看 ›" : "去設定 ›") { open(item.section) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SetupStateChip: View {
    let state: SetupChecklist.State
    var body: some View {
        let color: Color = switch state {
        case .todo: LiquidGlassTokens.brandAccent
        case .done: LiquidGlassTokens.browserSuccessFill
        case .defaulted, .optional: .secondary
        }
        Text(state.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(state == .optional ? Color.clear : color.opacity(0.12), in: Capsule())
            .overlay(state == .optional ? Capsule().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) : nil)
    }
}

/// 各分頁頂端的「初始設定」：說明＋一兩個動作；做完換成一行「完成」。
struct SetupBanner<Actions: View>: View {
    let done: Bool
    var label = "初始設定"
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(done ? "\(label) · 完成" : label)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(done ? LiquidGlassTokens.browserSuccessFill : LiquidGlassTokens.brandAccent)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if !done { HStack(spacing: 8) { actions } }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((done ? LiquidGlassTokens.browserSuccessFill : LiquidGlassTokens.brandAccent).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((done ? LiquidGlassTokens.browserSuccessFill : LiquidGlassTokens.brandAccent).opacity(0.3)))
    }
}

/// Coder 左下角的小提示：還有必做的事才出現，點了開 設定 › 開始使用。
struct SidebarSetupNudge: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var checklist = SetupChecklist.shared
    let open: () -> Void

    var body: some View {
        Group {
            if checklist.remaining > 0 {
                Button(action: open) {
                    HStack(spacing: 7) {
                        Circle().fill(LiquidGlassTokens.brandAccent).frame(width: 6, height: 6)
                        Text("開始使用").font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 4)
                        Text("還有 \(checklist.remaining) 件").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("設定 › 開始使用")
                .accessibilityIdentifier("sidebar-setup-nudge")
            }
        }
        .onAppear { checklist.refresh(logins: model.engineLogins) }
        .onChange(of: model.engineLogins) { checklist.refresh(logins: $0) }
    }
}

/// GitHub 分頁的初始設定：要不要把入口的文字正本備份到自己的私人倉庫（只在第一台問）。
struct GitHubBackupSetupBanner: View {
    @ObservedObject private var backup = EntryBackup.shared

    var body: some View {
        if OSDocuments.isPrimary {
            let choice = backup.choice
            VStack(alignment: .leading, spacing: 6) {
                SetupBanner(done: choice != nil, label: choice == nil ? "初始設定 · 選用" : "初始設定",
                            text: choice == .enabled ? "規則、偏好和筆記會備份到你的私人倉庫 \(EntryBackup.repositoryName)，之後每次改都自動推一版。"
                                : choice == .declined ? "你選了不備份。想開的話按下面的「改成備份」。"
                                : "要把規則、偏好和筆記備份到你自己的 GitHub 私人倉庫嗎？只放文字，不放程式碼、金鑰或資料庫。先在下面登入 GitHub。") {
                    OSChipButton(title: "備份到我的 GitHub", isPrimary: true) { Task { await backup.enable() } }
                    OSChipButton(title: "不用") { backup.decline() }
                }
                if choice == .declined {
                    OSChipButton(title: "改成備份") { Task { await backup.enable() } }
                }
                if !backup.statusLine.isEmpty {
                    Text(backup.statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { backup.refreshStatus() }
            .onChange(of: backup.choice) { _ in SetupChecklist.shared.refresh(logins: SetupChecklist.shared.lastLogins) }
        }
    }
}
