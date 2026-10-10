// W171 設定 › 開始使用（使用者 2026-09-22 點頭，對照稿 https://claude.ai/artifact/B4QU2bjTMWBCLfXBAGFVmd）：
// 第一次打開直接進 App，要做的事集中在這一頁總覽，各分頁頂端再各放一塊「初始設定」。
// 使用者：「以後設定頁面是否完善 就看開始使用的建設是否完善」——新增設定項時要想它在這裡怎麼出現。
import AppKit
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
    private var assistantModel: AssistantSetupModel?

    /// 還沒做的必做項（左下角提示與設定預設開哪一頁用）。
    var remaining: Int { items.filter { $0.required && $0.state == .todo }.count }
    /// 左欄要點一個小點的分頁。
    var pendingSections: Set<TatwoSettingsPage.Section> {
        Set(items.filter { $0.state == .todo || $0.state == .defaulted }.map(\.section))
    }

    func refresh(logins: [EngineLoginStatus], assistantModel: AssistantSetupModel? = nil) {
        if let assistantModel { self.assistantModel = assistantModel }
        lastLogins = logins
        var next: [Item] = []
        let loggedIn = logins.filter(\.isLoggedIn)
        next.append(Self.assistantItem(loggedIn: loggedIn.contains { $0.kind == self.assistantModel?.engineKind }, model: self.assistantModel))

        let engines = EngineLinks.scan().filter { ["claude", "codex", "openclaw"].contains($0.id) && $0.state != .notInstalled }
        let unlinked = engines.filter { $0.state == .notLinked }
        next.append(Item(id: "rules", title: "讓你的 AI 用同一套規則",
                         detail: engines.isEmpty ? "這台沒有裝 Claude Code 或 Codex；TATWO OS 內建的 AI 已經照這套規則。"
                             : unlinked.isEmpty ? "已接上：" + engines.map(\.name).joined(separator: "、")
                             : "這台有 " + unlinked.map(\.name).joined(separator: "、") + "。接上後你講一次的偏好它們都會照做；原本的規則檔會先備份。",
                         state: unlinked.isEmpty ? .done : .todo, section: .os, required: true))

        // W179：兩家引擎的記憶接到入口的 memory/（使用者 09-26：「這個記憶改動要寫到設定/開始使用裡面讓第一次進來的用戶可以快速設置」）。
        let memory = EngineMemoryLinks.scan()
        let memoryEngines = memory.installed
        let memoryPending = memory.pending
        next.append(Item(id: "memory", title: "讓你的 AI 共用一份記憶",
                         detail: memoryEngines.isEmpty ? "這台沒有裝 Claude Code 或 Codex；TATWO OS 內建的 AI 之後會直接用這份記憶。"
                             : memoryPending.isEmpty ? "已接上：" + memoryEngines.map(\.name).joined(separator: "、") + "。記憶放在入口的 memory 資料夾。"
                             : "Claude、Codex 各自記的東西合成一份，每個 AI 都讀得到；原本的會先備份。這台有 "
                                 + memoryPending.map(\.name).joined(separator: "、") + " 還沒接。",
                         state: memoryPending.isEmpty ? .done : .todo, section: .os, required: true))
        // 入口記憶變了就重產 Codex 讀的摘要（只在已接上時寫）；重複呼叫不會多開。
        EngineMemoryWatcher.shared.start()

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

    static let assistantDetail = "TATWO 助理熟悉這套 OS 和你，幫你處理設定、設備、記憶和派工。先選它用哪個模型。"

    static func assistantItem(loggedIn: Bool, model: AssistantSetupModel?) -> Item {
        let state: State = !loggedIn ? .todo : model?.isExplicit == true ? .done : .defaulted
        let name = model?.title ?? "預設模型"
        let status = !loggedIn ? "選用：\(name) · 未登入，請到設定 › 登入。" : state == .done ? "已選：\(name)" : "目前：\(name)"
        return Item(id: "model", title: "設定 TATWO 助理模型",
                    detail: assistantDetail + (status.isEmpty ? "" : "\n" + status),
                    state: state, section: .modelAccess, required: true)
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
    @ObservedObject var checklist = SetupChecklist.shared
    let open: (TatwoSettingsPage.Section) -> Void
    #if DEBUG
    var testProbe: W190SetupAcceptance.Probe?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
                TatwoSettingsPageHeader(title: "開始使用",
                                        subtitle: "不用一次做完。先選助理模型，其他的之後再來。")
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
                    ForEach(items) { item in
                        row(item)
                        if item.id == "device" { WorkPathRow(isSetup: true) }
                    }
                }
            }
            .padding(TatwoSettingsPageMetrics.inset)
        }
        .onAppear { refresh() }
        .onChange(of: model.engineLogins) { _ in refresh() }
        .onChange(of: model.assistantSetupModel) { _ in refresh() }
    }

    private func refresh() {
        checklist.refresh(logins: model.engineLogins, assistantModel: model.assistantSetupModel)
    }

    private func row(_ item: SetupChecklist.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13.5, weight: .semibold))
                    .accessibilityIdentifier("setup-title-" + item.id)
                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            SetupStateChip(state: item.state)
                .accessibilityIdentifier("setup-state-" + item.id + "-" + item.state.label)
            if item.id == "model" {
                if item.state == .todo {
                    OSChipButton(title: "登入 ›") { open(item.section) }
                        .accessibilityIdentifier("setup-assistant-login")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            testProbe?.chip = ("setup-assistant-login", frame)
                        }
                        #endif
                } else {
                    AssistantModelMenu(model: model)
                        .accessibilityIdentifier("setup-assistant-model")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            testProbe?.chip = ("setup-assistant-model", frame)
                        }
                        #endif
                }
            } else {
                OSChipButton(title: item.state == .done ? "查看 ›" : "去設定 ›") {
                    if item.id == "backup" { EnvironmentLoginTarget.backup.open() } else { open(item.section) }
                }
                    .accessibilityIdentifier("setup-open-" + item.id)
                    .accessibilityLabel((item.state == .done ? "查看：" : "去設定：") + item.title)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            testProbe?.rows[item.id] = (item, frame)
        }
        #endif
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
        .onAppear { checklist.refresh(logins: model.engineLogins, assistantModel: model.assistantSetupModel) }
        .onChange(of: model.engineLogins) { checklist.refresh(logins: $0, assistantModel: model.assistantSetupModel) }
        .onChange(of: model.assistantSetupModel) { checklist.refresh(logins: model.engineLogins, assistantModel: $0) }
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
                        .accessibilityLabel("備份到我的 GitHub")
                    OSChipButton(title: "不用") { backup.decline() }
                        .accessibilityLabel("不用備份")
                }
                if choice == .declined {
                    OSChipButton(title: "改成備份") { Task { await backup.enable() } }
                        .accessibilityLabel("改成備份到我的 GitHub")
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

#if DEBUG
/// W190：只替換登入與引擎輸入；渲染正式開始使用頁、呼叫正式模型選單動作。
enum W190SetupAcceptance {
    final class Probe {
        var rows: [String: (SetupChecklist.Item, CGRect)] = [:]
        var chip: (String, CGRect)?
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw BotLibraryError.invalid("w190setup requires isolated staging and artifacts")
        }
        let root = URL(fileURLWithPath: livePath)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w190setup requires a fresh live root")
        }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let library = BotLibrary(root: root.appendingPathComponent("library"),
                                 skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        let checklist = SetupChecklist()
        var passed = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures += 1 }
            print("W190SETUP \(condition ? "PASS" : "FAIL") \(label)")
        }
        let folder = URL(fileURLWithPath: artifacts)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened: TatwoSettingsPage.Section?
        let probe = Probe()
        func render(_ name: String, state: SetupChecklist.State, chip: String) async throws -> TatwoComposerModeAcceptance.ClickRig {
            checklist.refresh(logins: model.engineLogins, assistantModel: model.assistantSetupModel)
            check(checklist.items.first?.title == "設定 TATWO 助理模型"
                  && checklist.items.first?.state == state, "\(name) first title and state")
            check(checklist.items.filter { $0.id == "model" }.count == 1
                  && checklist.items.first?.section == .modelAccess, "\(name) single model step and login destination")
            probe.rows = [:]
            probe.chip = nil
            var page = SetupGuidePage(model: model, checklist: checklist) { opened = $0 }
            page.testProbe = probe
            let rig = TatwoComposerModeAcceptance.ClickRig(page, size: CGSize(width: 960, height: 860))
            await rig.settle()
            guard let rendered = rig.capture() else {
                rig.close()
                throw BotLibraryError.invalid("setup page render failed")
            }
            check(probe.rows["model"]?.0.title == "設定 TATWO 助理模型"
                  && probe.rows["model"]?.0.state == state
                  && probe.rows["model"]?.1.height ?? 0 > 0
                  && probe.chip?.0 == chip && probe.chip?.1.width ?? 0 > 0,
                  "\(name) rendered title, state and chip")
            guard let png = rendered.bitmap.representation(using: .png, properties: [:]) else {
                throw BotLibraryError.invalid("setup PNG encoding failed")
            }
            let url = folder.appendingPathComponent(name + ".png")
            try png.write(to: url)
            check(!png.isEmpty, "\(name) PNG written")
            print("W190SETUP PNG \(url.path)")
            return rig
        }
        model.engineLogins = [.init(kind: .codex, isLoggedIn: false, account: nil, detail: "fixture")]
        let loggedOut = try await render("no-login", state: .todo, chip: "setup-assistant-login")
        if let frame = probe.chip?.1 {
            await loggedOut.click(loggedOut.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
        }
        check(opened != nil, "login chip can be pressed")
        check(opened == .modelAccess, "login chip opens model access")
        loggedOut.close()

        model.engineLogins = [.init(kind: .codex, isLoggedIn: true, account: nil, detail: "fixture"),
                              .init(kind: .claude, isLoggedIn: true, account: nil, detail: "fixture")]
        // 引擎自動記住用過的模型，不等於使用者在模型選單選過。
        engine.setRequestedModel(model.assistantRouteChoice.id, threadID: model.assistantThreadID!)
        check(!model.assistantSetupModel.isExplicit, "automatic model bookkeeping is not an explicit selection")
        engine.setRequestedModel(nil, threadID: model.assistantThreadID!)
        let defaulted = try await render("logged-in-default", state: .defaulted, chip: "setup-assistant-model")
        check(checklist.items.first?.detail.contains("目前：" + model.assistantModelChipTitle) == true,
              "default shows the current assistant model")
        let order = checklist.items.map(\.id)
        let coderChoice = model.selectedModel
        guard let choice = model.assistantModelOptions.first(where: { !$0.isDisabled && $0.route.id != model.assistantRouteChoice.id }) else {
            throw BotLibraryError.invalid("enabled model option missing")
        }
        let menu = AssistantModelMenu.menu(for: model)
        let options = model.assistantModelOptions
        let actionable = menu.items.filter { $0.action != nil }
        check(actionable.map(\.title) == ChatRouteBrandGroup.pickerOrder.flatMap { brand in
            options.filter { $0.route.brandGroup == brand }.map(\.title)
        }, "setup uses all and only the assistant model options")
        if let item = actionable.first(where: { $0.title == choice.title }), let action = item.action {
            check(NSApp.sendAction(action, to: item.target, from: item), "selection invokes the real menu action")
        } else { check(false, "selection invokes the real menu action") }
        await defaulted.settle()
        check(model.assistantRouteChoice.id == choice.route.id
              && model.assistantModelChipTitle == AssistantModelRouting.chipName(choice.route)
              && model.assistantSetupModel.isExplicit, "selection immediately syncs the assistant model chip")
        check(checklist.items.first?.state == .done, "selection updates the open setup row immediately")
        defaulted.close()
        let selected = try await render("model-selected", state: .done, chip: "setup-assistant-model")
        check(checklist.items.first?.detail.contains("已選：" + model.assistantModelChipTitle) == true,
              "selected shows the assistant model name")
        check(order == checklist.items.map(\.id) && order.prefix(4).elementsEqual(["model", "rules", "memory", "device"]),
              "other setup steps retain their order")
        check(model.selectedModel == coderChoice, "selection preserves the Coder model")
        let pane = TatwoComposerMode.assistantSpace(model: model)
        check(pane.models.first?.title == model.assistantModelChipTitle
              && pane.segments.first?.short == model.assistantModelChipTitle, "actual assistant composer chip uses the selected name")
        selected.close()
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { reopened.shutdownAll() }
        check(reopened.threadRecord(reopened.doc.assistantThreadID)?.requestedModel == choice.route.id,
              "assistant model choice survives reopening")
        let persona = engine.composedSystemPrompt(threadID: model.assistantThreadID ?? UUID()) ?? ""
        check(persona.contains("熟悉 TATWO OS 與使用者")
              && persona.contains("設定、設備、記憶、派工協調")
              && !persona.contains("專案 bot") && !persona.contains("project bot"), "assistant preamble describes OS and user familiarity")
        print("W190SETUP SUMMARY passed=\(passed) failures=\(failures)")
        return failures == 0
    }
}
#endif
