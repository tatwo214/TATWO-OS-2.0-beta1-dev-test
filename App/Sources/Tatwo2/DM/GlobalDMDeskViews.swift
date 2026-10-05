import AppKit
import Combine
import SwiftUI

// W179 E：內橫的右欄（W184 前是 iPhone 打開的兩欄）、框內「設定直達鍵」、桌面圓鈕、設定頁那一塊。
// W179 UI：按鈕一律 App 的玻璃 chip／玻璃圓形圖示鈕，選中才用強調色；不用藍色、系統白框或粉色實心。
// W184 AB：舊的尺寸鈕拿掉（形態在頂列左上圓鈕的右鍵選單（W184 F，原本的「⋯ 更多」）、桌面圓鈕右鍵、⌘⌥Tab）。

/// 一欄在整支手機裡的角色：單欄（外直、內直）、內橫的左欄（目前對象，永遠是對話）、內橫的右欄（另一個對象）。
enum GlobalDMBoxRole: Equatable {
    case single
    case duoLeading
    case duoTrailing

    /// 單欄時 Browser 開著＝這一欄換成 Browser；內橫的 Browser 在右欄（GlobalDMDuoBox），左欄照常是對話。
    var showsBrowser: Bool { self == .single }
    /// 打開時左欄（或單欄）拿輸入焦點。
    var takesInitialFocus: Bool { self != .duoTrailing }
}

private struct GlobalDMBoxRoleKey: EnvironmentKey {
    static let defaultValue: GlobalDMBoxRole = .single
}

extension EnvironmentValues {
    /// W179 UI：框裡的對話區與輸入列看這個決定要不要一打開就拿焦點。
    var globalDMBoxRole: GlobalDMBoxRole {
        get { self[GlobalDMBoxRoleKey.self] }
        set { self[GlobalDMBoxRoleKey.self] = newValue }
    }
}

/// 固定大小（準備中的框）；nil＝填滿面板（面板大小由控制器依形態決定）。
struct GlobalDMBoxSizing: ViewModifier {
    let size: CGSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size.width, height: size.height)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 內橫的右欄（W184 AB）

/// 內橫：一條頂列跨兩欄（在 GlobalDMPhoneBox）；這是右欄：Browser（有分頁，或按了 Browser 圓鈕；DMBrowser.reveal 開的授權頁、
/// 配對頁都開到這裡，左欄不動），否則是另一個對象的對話（第二個 store：沒有自己的頂列、不開 Browser）。Browser 只有一份，只在右欄。
struct GlobalDMDuoBox: View {
    @ObservedObject var primary: GlobalDMStore
    let secondary: GlobalDMStore?
    @ObservedObject var model: ChatPageModel
    let surface: GlobalDMSurface
    /// 框裡的 Browser 用哪一份（正式＝.shared；W184 F／G1 自測接假的）。
    let services: GlobalDMBrowserServices
    @ObservedObject private var browser: DMBrowser

    init(primary: GlobalDMStore, secondary: GlobalDMStore?, model: ChatPageModel, surface: GlobalDMSurface,
         services: GlobalDMBrowserServices = GlobalDMBrowserServices()) {
        _primary = ObservedObject(wrappedValue: primary)
        self.secondary = secondary
        _model = ObservedObject(wrappedValue: model)
        self.surface = surface
        self.services = services
        _browser = ObservedObject(wrappedValue: services.browser ?? .shared)
    }

    var body: some View {
        Group {
            // W184 G2c 第二輪（房 D；GPT-6 #1）：跟 ⌘⌥T（GlobalDMPanelController.routeNewTab）同一條判斷。
            if GlobalDMDuoLayout.rightColumnShowsBrowser(browsing: primary.isBrowsing, browsingBeside: primary.isBrowsingBeside,
                                                         hasTabs: browser.hasTabs, hasSecondary: secondary != nil) {
                DMBrowserPane(store: primary, browser: services.browser, flow: services.flow, connect: services.connect)   // 沒分頁時是 Browser 的空狀態
            } else if let secondary {
                GlobalDMBox(store: secondary, model: model, surface: surface, role: .duoTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.duo.trailing")
    }
}

// MARK: - 框內「設定直達鍵」

/// 列出可設的對象（助理、最近的 session、ChatGPT），每列按「設定」後按一個字母或數字。
/// W184 F45：最上面多一列「換形態」（預設 ⌥⌘Tab）：同一套等鍵、規則、存檔，可以改成別的 ⌥⌘＋鍵、也可以回到預設。
struct GlobalDMDirectKeyPage: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject private var hotkeys: GlobalDMHotKeys
    @StateObject private var capture = GlobalDMKeyCapture()

    /// hotkeys＝正式 .shared；自測換成假的註冊（W184 F45）。
    init(store: GlobalDMStore, hotkeys: GlobalDMHotKeys? = nil) {
        _store = ObservedObject(wrappedValue: store)
        _hotkeys = ObservedObject(wrappedValue: hotkeys ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { store.isEditingDirectKeys = false } label: {
                    GlobalDMIconLabel(systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("回到對話（Esc）")
                .accessibilityLabel("回到對話")
                .accessibilityIdentifier("tatwo.dm.keys.back")
                Text("設定直達鍵").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 4)
            Text("在任何 App 按 ⌥⌘＋一個字母或數字，直接打開私訊框並切到那個對象。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 6)
            if let message = capture.message {
                GlobalDMNoticeRow(icon: "exclamationmark.circle", text: message, actionTitle: nil,
                                  identifier: "tatwo.dm.keys.notice") {}
            }
            ScrollView {
                VStack(spacing: 1) {
                    formRow   // W184 F45
                    ForEach(targets, id: \.self) { row($0) }
                }
                .padding(8)
            }
        }
        .background(GlobalDMWindowReader(capture: capture))
        .onDisappear { capture.end() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.keys")
    }

    private var targets: [GlobalDMTarget] {
        var list: [GlobalDMTarget] = [.assistant] + store.recentSessions().map { .thread($0.id) } + [.chatGPT]
        for target in store.directKeys.keys.sorted(by: { $0.storageValue < $1.storageValue })
        where !list.contains(target) {
            list.append(target)
        }
        return list
    }

    /// W184 F45：「換形態」那一列：目前的鍵（預設 ⌥⌘Tab）、「更改」（同一套等鍵：按一個字母或數字）、改過才出現「回到預設」。
    private var formRow: some View {
        let key = hotkeys.formKey
        let capturing = capture.slot == .form
        let occupied = hotkeys.failed.contains(key)
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: DMPhone.TextSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("換形態").font(.system(size: DMPhone.TextSize.footnote)).lineLimit(1)
                Text(occupied ? "被別的 App 佔用，現在按了沒有作用" : "私訊框開著時按，依序換四種形態")
                    .font(.system(size: DMPhone.TextSize.caption))
                    .foregroundStyle(occupied ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if capturing {
                Text("按一個字母或數字…").font(.system(size: DMPhone.TextSize.caption)).foregroundStyle(LiquidGlassTokens.brandAccent)
                chip("取消", identifier: "cancel") { capture.end() }
            } else {
                GlobalDMKey(key.display)
                    .accessibilityLabel(key.display)
                    .accessibilityIdentifier("tatwo.dm.keys.form.key")
                chip("更改", identifier: "form.set") { capture.beginForm(store: store, hotkeys: hotkeys) }
                if key != GlobalDMFormKeyBook.standard {
                    Button { hotkeys.resetFormKey() } label: {
                        GlobalDMIconLabel(systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("回到預設 \(GlobalDMFormKeyBook.standard.display)")
                    .accessibilityLabel("回到預設")
                    .accessibilityIdentifier("tatwo.dm.keys.form.reset")
                } else {
                    Color.clear.frame(width: GlobalDMLayout.iconButtonSize, height: GlobalDMLayout.iconButtonSize)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .chatMenuRowHover(isSelected: capturing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.keys.form")
    }

    private func row(_ target: GlobalDMTarget) -> some View {
        let key = store.directKeys[target]
        let capturing = capture.slot == .target(target)
        let occupied = key.map { hotkeys.failed.contains($0) } ?? false
        return HStack(spacing: 8) {
            GlobalDMAvatar(target: target, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title(for: target))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if occupied {
                    Text("被別的 App 佔用，現在按了沒有作用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if capturing {
                Text("按一個字母或數字…").font(.system(size: 11)).foregroundStyle(LiquidGlassTokens.brandAccent)
                chip("取消", identifier: "cancel") { capture.end() }
            } else {
                if let key {
                    GlobalDMKey(key.display)
                } else {
                    Text("未設定").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                chip(key == nil ? "設定" : "更改", identifier: "set") {
                    capture.begin(target, store: store, hotkeys: hotkeys)
                }
                if key != nil {
                    Button { store.setDirectKey(nil, for: target) } label: {
                        GlobalDMIconLabel(systemImage: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("清掉這個直達鍵")
                    .accessibilityLabel("清掉直達鍵")
                    .accessibilityIdentifier("tatwo.dm.keys.\(target.storageValue).clear")
                } else {
                    // 沒有鍵的列補一個同大小的空位，每列的按鈕才對齊。
                    Color.clear.frame(width: GlobalDMLayout.iconButtonSize, height: GlobalDMLayout.iconButtonSize)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .chatMenuRowHover(isSelected: capturing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.keys." + target.storageValue)
    }

    private func chip(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        OSChipButton(title: title, action: action)
            .accessibilityLabel(title)
            .accessibilityIdentifier("tatwo.dm.keys.\(identifier)")
    }
}

/// 等使用者按一個鍵：這段期間全部 ⌥⌘ 熱鍵暫停（按 ⌥⌘G 也會進到這裡，不會打開 ChatGPT）；Esc 不設了。
/// 只收這一頁所在面板的按鍵（主視窗輸入框照常打字），而且只收單按一個鍵或剛好 ⌥⌘＋鍵（⌘Q、⌘V 照原本的意思走）。
/// 面板失去鍵盤焦點、App 退到背景、框收起或離開這一頁就停：熱鍵不會一直停著。
@MainActor
final class GlobalDMKeyCapture: ObservableObject {
    /// 在等哪一列的鍵：某個對象的直達鍵，或 W184 F45 的「換形態」。
    enum Slot: Equatable { case target(GlobalDMTarget), form }
    @Published private(set) var slot: Slot?
    /// 在等的直達鍵對象（「換形態」那一列是 nil）。
    var target: GlobalDMTarget? {
        guard case .target(let target) = slot else { return nil }
        return target
    }
    @Published private(set) var message: String?
    /// 這一頁所在的面板（`GlobalDMWindowReader` 回寫）；不是 @Published，換視窗不重畫。
    weak var hostWindow: NSWindow?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var watch: AnyCancellable?
    private weak var store: GlobalDMStore?
    private weak var hotkeys: GlobalDMHotKeys?

    func begin(_ target: GlobalDMTarget, store: GlobalDMStore, hotkeys: GlobalDMHotKeys) {
        begin(.target(target), store: store, hotkeys: hotkeys)
    }

    /// W184 F45：「換形態」那一列：同一套等鍵（只收這個面板、熱鍵暫停、Esc 不設了），按下去存成換形態的鍵。
    func beginForm(store: GlobalDMStore, hotkeys: GlobalDMHotKeys) {
        begin(.form, store: store, hotkeys: hotkeys)
    }

    private func begin(_ slot: Slot, store: GlobalDMStore, hotkeys: GlobalDMHotKeys) {
        end()
        // 只在私訊框面板裡收；找不到面板就不開始（絕不收整個 App 的按鍵）。
        guard let window = (hostWindow ?? NSApp.currentEvent?.window) as? GlobalDMPanel else { return }
        // 停靠框平常不搶鍵盤焦點（becomesKeyOnlyIfNeeded）；要收按鍵就先讓它成為 key。
        window.makeKey()
        self.window = window
        self.slot = slot
        self.store = store
        self.hotkeys = hotkeys
        message = nil
        hotkeys.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        })
        // 框收起（縮成圓鈕、主視窗縮到 Dock、關框）或離開這一頁時 onDisappear 不一定會跑，這裡自己停。
        // @Published 在改值之前發佈，所以用送來的新值判斷，不回頭讀 store。
        watch = Publishers.CombineLatest4(store.$isOpen, store.$isFloatingOpen, store.$isDockedVisible,
                                          store.$isEditingDirectKeys)
            .dropFirst()
            .sink { [weak self] open, floating, docked, editing in
                if !editing || !(floating || (open && docked)) { self?.end() }
            }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        watch = nil
        window = nil
        if slot != nil { slot = nil }
        hotkeys?.isSuspended = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let slot, let store, let hotkeys, let window, event.window === window else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty {
            end()
            return nil
        }
        // 只收單按一個鍵或剛好 ⌥⌘＋鍵；⌘Q、⌘V、⌃、⇧ 這些組合照原本的意思走，不會被存成直達鍵。
        guard modifiers.isEmpty || modifiers == [.command, .option] else { return event }
        GlobalHotkeyMonitor.shared.cancelPendingChord()
        let verdict: GlobalDMDirectKeyVerdict
        switch slot {
        case .target(let target): verdict = hotkeys.assign(keyCode: event.keyCode, to: target, store: store)
        case .form: verdict = hotkeys.assignFormKey(keyCode: event.keyCode, store: store)   // W184 F45：換形態的鍵
        }
        if verdict == .ok {
            message = nil
            end()
        } else {
            message = verdict.message(title: { store.title(for: $0) })
        }
        return nil
    }
}

/// 讀出這一頁所在的面板，交給 `GlobalDMKeyCapture`（只收那個面板的按鍵）。
struct GlobalDMWindowReader: NSViewRepresentable {
    let capture: GlobalDMKeyCapture

    func makeNSView(context: Context) -> GlobalDMWindowProbe {
        let probe = GlobalDMWindowProbe()
        probe.onWindow = { [weak capture] window in capture?.hostWindow = window }
        return probe
    }

    func updateNSView(_ probe: GlobalDMWindowProbe, context: Context) {
        if let window = probe.window, capture.hostWindow !== window { capture.hostWindow = window }
    }
}

/// 看不見、不接滑鼠，只回報自己被放進哪個視窗。
final class GlobalDMWindowProbe: NSView {
    var onWindow: (@MainActor (NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

// MARK: - 桌面圓鈕

/// 圓鈕的樣子跟主視窗裡的私訊鈕一樣（44pt）；點擊、拖曳、右鍵由外層的 AppKit 視圖處理。
struct GlobalDMBubbleFace: View {
    @ObservedObject var store: GlobalDMStore

    var body: some View {
        GlobalDMRoundButton(isOpen: store.isFloatingOpen) {}
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .padding(GlobalDMLayout.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 點一下展開／收回私訊框；拖曳移動、放開記住；右鍵或按住出「展開成」選單。
final class GlobalDMBubbleView: NSView {
    var onClick: () -> Void = {}
    var onDrag: () -> Void = {}
    var onDrop: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    /// W184 G1b 第二輪（GPT-6 G1b 審查 #6）自測換：滑鼠在螢幕上的位置、跳出選單（正式＝NSEvent.mouseLocation、NSMenu 的 popUp：
    /// 自測對真的圓鈕送按下、移動、放開，不讓選單卡住）。
    static var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    static var presentMenu: @MainActor (NSMenu, NSEvent?, NSView, NSPoint) -> Void = { menu, event, view, point in
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }
    private var pressLocation: NSPoint?
    private var pressOrigin: NSPoint?
    private var isDragging = false
    private var holdTask: Task<Void, Never>?

    init(store: GlobalDMStore) {
        super.init(frame: NSRect(x: 0, y: 0, width: GlobalDMLayout.dockedClosedSize.width,
                                 height: GlobalDMLayout.dockedClosedSize.height))
        let face = NSHostingView(rootView: GlobalDMBubbleFace(store: store))
        face.sizingOptions = []
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("私訊鈕")
        setAccessibilityHelp("點一下展開私訊框；按右鍵或按住選展開尺寸；可以拖到別的位置")
        setAccessibilityIdentifier("tatwo.dm.desk.bubble")
        toolTip = "私訊（⌥⌘）· 右鍵選尺寸 · ⌥⌘↑ 恢復主視窗"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    private var circle: NSRect { bounds.insetBy(dx: GlobalDMLayout.margin, dy: GlobalDMLayout.margin) }

    /// 只有圓形本體接滑鼠；四周留給陰影的透明邊點下去等於點到後面的視窗。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return NSBezierPath(ovalIn: circle).contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressLocation = Self.mouseLocation()
        pressOrigin = window?.frame.origin
        isDragging = false
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard let self, !Task.isCancelled, !self.isDragging, self.pressLocation != nil else { return }
            self.showMenu(with: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, let origin = pressOrigin, let window else { return }
        let now = Self.mouseLocation()
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !isDragging {
            guard hypot(dx, dy) >= 3 else { return }
            isDragging = true
            holdTask?.cancel()
        }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        onDrag()
    }

    override func mouseUp(with event: NSEvent) {
        holdTask?.cancel()
        defer { resetPress() }
        guard pressLocation != nil else { return }
        if isDragging { onDrop() } else { onClick() }
    }

    override func rightMouseDown(with event: NSEvent) {
        holdTask?.cancel()
        showMenu(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showMenu(with: nil)
        return true
    }

    private func showMenu(with event: NSEvent?) {
        resetPress()
        Self.presentMenu(makeMenu(), event, self, NSPoint(x: circle.minX, y: circle.minY))
    }

    private func resetPress() {
        pressLocation = nil
        pressOrigin = nil
        isDragging = false
    }
}

// MARK: - 設定 › Tatwo Island 底下的「私訊鈕」

struct GlobalDMSettingsCard: View {
    @ObservedObject private var store = GlobalDMStore.shared
    @ObservedObject private var hotkeys = GlobalDMHotKeys.shared
    @ObservedObject private var chordMonitor = GlobalHotkeyMonitor.shared
    @State private var permissionWatchID = UUID().uuidString
    @AppStorage(GlobalDMDeskSettings.chordToggleKey) private var chordToggle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("私訊鈕")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, -2)
            VStack(spacing: 0) {
                toggleRow("啟用私訊鈕", "每個 Space 右下角的圓鈕與私訊框；關掉後 ⌥⌘、直達鍵與桌面圓鈕都不作用",
                          isOn: $store.isEnabled, identifier: "tatwo.settings.dm.enabled")
                Divider().padding(.leading, 14)
                Group {
                    toggleRow("單按 ⌥⌘ 開關私訊框", "只按 ⌥⌘ 再放開；要在其他 App 裡也有效，需要裝置控制和資料取用（舊稱輔助使用）權限",
                              isOn: $chordToggle, identifier: "tatwo.settings.dm.chord")
                    chordPermissionRow
                    Divider().padding(.leading, 14)
                    collapseRow
                    Divider().padding(.leading, 14)
                    keysRow
                }
                .opacity(store.isEnabled ? 1 : 0.42)
                .disabled(!store.isEnabled)
            }
            .background(cardBackground)
        }
        .onAppear { chordMonitor.setPermissionSurfaceVisible(true, owner: permissionWatchID) }
        .onDisappear { chordMonitor.setPermissionSurfaceVisible(false, owner: permissionWatchID) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.settings.dm")
    }

    private var chordPermissionRow: some View {
        HStack(spacing: 12) {
            Text(chordMonitor.isSystemWide ? "其他 App：可用" : "其他 App：需開啟裝置控制和資料取用（舊稱輔助使用）權限")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            OSChipButton(title: "打開裝置控制和資料取用（舊稱輔助使用）設定") { chordMonitor.openAccessibilitySettings() }
                .accessibilityIdentifier("tatwo.settings.dm.accessibility")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
        .accessibilityIdentifier("tatwo.settings.dm.permission")
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>, identifier: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(LiquidGlassTokens.brandAccent)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var collapseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("縮成桌面圓鈕").font(.system(size: 13, weight: .semibold))
            Text("⌥⌘↓ 縮成桌面圓鈕，⌥⌘↑ 恢復；只在 TATWO 位於前景時有效，App 選單也有這兩項")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var keysRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("直達鍵").font(.system(size: 13, weight: .semibold))
                    Text("會在其他 App 生效：按 ⌥⌘＋鍵打開私訊框並切換對象；每顆都可關掉")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                OSChipButton(title: "到私訊框設定", systemImage: "keyboard") {
                    GlobalDMDeskController.shared.openDirectKeySettings()
                }
                .accessibilityLabel("到私訊框設定直達鍵")
                .accessibilityIdentifier("tatwo.settings.dm.editKeys")
            }
            let targets = store.directKeys.keys.sorted { $0.storageValue < $1.storageValue }
            if targets.isEmpty {
                Text("還沒有設直達鍵").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(targets, id: \.self) { target in
                if let key = store.directKeys[target] {
                    HStack(spacing: 8) {
                        Text(store.title(for: target)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if hotkeys.failed.contains(key) {
                            Text("被別的 App 佔用").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        GlobalDMKey(key.display)
                        OSChipButton(title: "關掉") { store.setDirectKey(nil, for: target) }
                            .accessibilityLabel("關掉\(store.title(for: target))的直達鍵")
                            .accessibilityIdentifier("tatwo.settings.dm.key.\(target.storageValue).clear")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
