import AppKit
import Carbon
import Combine

/// 全系統熱鍵的底層：正式版是 Carbon `RegisterEventHotKey`（不需要輔助使用權限）；自測換成假的。
@MainActor
protocol GlobalDMHotKeyBackend: AnyObject {
    func activate(onPress: @escaping @MainActor (UInt32) -> Void)
    func deactivate()
    /// 註冊 ⌥⌘＋`keyCode`；被別的 App 佔用時回 false。
    func register(id: UInt32, keyCode: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// W179 E：⌥⌘↓ 縮成私訊鈕、⌥⌘↑ 恢復主視窗、⌥⌘＋直達鍵。
/// 直達鍵跟著私訊鈕總開關重新註冊；App 結束時 `uninstall` 全部移除（成對）。
/// ⌥⌘↓／⌥⌘↑ 只在 TATWO 位於前景時以本機事件處理，不註冊或探測全系統箭頭熱鍵。
/// W184 AB：⌘⌥Tab（換形態）只在私訊框看得到時註冊、收起就放掉，不搶別的 App 的鍵。
/// W184 F45：換形態的鍵使用者可以改（直達鍵頁「換形態」那一列；預設 Tab）：`formKey`，存在 `formDefaults`（GlobalDMFormKeyBook）。
@MainActor
final class GlobalDMHotKeys: ObservableObject {
    static let shared = GlobalDMHotKeys(backend: GlobalDMCarbonHotKeys())
    nonisolated static let signature: OSType = 0x5457_444D // "TWDM"
    static let probeID: UInt32 = 999

    enum Action: Equatable {
        case collapse
        case restore
        case direct(GlobalDMTarget)
        /// W184 AB：⌘⌥Tab 換到下一個形態。
        case cycleForm
    }

    /// 註冊失敗（被別的 App 佔用）的鍵；設定頁、框內那一頁與頁面圓鈕的右鍵選單照這個說明。
    @Published private(set) var failed: Set<GlobalDMDirectKey> = []
    /// 框內設直達鍵時暫停全部熱鍵：按下的鍵才會進到設定頁，不會觸發原本的直達鍵。
    var isSuspended = false { didSet { if isSuspended != oldValue { refresh() } } }
    /// 主視窗縮成桌面圓鈕了（控制器回寫）：App 內的箭頭處理照這個狀態判斷。
    var isCollapsed = false { didSet { if isCollapsed != oldValue { refresh() } } }
    /// W184 AB：私訊框現在看得到（控制器回寫）：這段時間才註冊 ⌘⌥Tab。
    var isBoxShowing = false { didSet { if isBoxShowing != oldValue { refresh() } } }
    var onAction: ((Action) -> Void)?
    private(set) var isInstalled = false
    private var registered: [UInt32: (key: GlobalDMDirectKey, action: Action)] = [:]
    private var enabled = false
    private var keys: [GlobalDMTarget: GlobalDMDirectKey] = [:]
    private let backend: GlobalDMHotKeyBackend
    private var appKeyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// W184 F45：換形態的鍵（⌥⌘＋它；預設 Tab）。直達鍵頁「換形態」那一列改（assignFormKey／resetFormKey）；右鍵選單、直達鍵頁照它顯示。
    @Published private(set) var formKey: GlobalDMDirectKey
    /// 換形態的鍵存在哪（正式＝.standard；自測換成暫時的 suite）。
    private let formDefaults: UserDefaults

    init(backend: GlobalDMHotKeyBackend, formDefaults: UserDefaults = .standard) {
        self.backend = backend
        self.formDefaults = formDefaults
        self.formKey = GlobalDMFormKeyBook.load(from: formDefaults)
    }

    /// 目前真的註冊著的鍵（自測與設定頁用）。
    var registeredKeys: Set<GlobalDMDirectKey> { Set(registered.values.map(\.key)) }

    func install(store: GlobalDMStore) {
        guard !isInstalled else { return }
        isInstalled = true
        backend.activate { [weak self] id in self?.pressed(id) }
        appKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleAppKey(event, appActive: NSApp.isActive)
        }
        enabled = store.isEnabled
        keys = store.directKeys
        // @Published 在改值之前發佈，所以用送來的新值，不回頭讀 store。
        store.$isEnabled.dropFirst()
            .sink { [weak self] value in
                self?.enabled = value
                self?.refresh()
            }
            .store(in: &cancellables)
        store.$directKeys.dropFirst()
            .sink { [weak self] value in
                self?.keys = value
                self?.refresh()
            }
            .store(in: &cancellables)
        refresh()
    }

    func uninstall() {
        guard isInstalled else { return }
        if let appKeyMonitor { NSEvent.removeMonitor(appKeyMonitor) }
        appKeyMonitor = nil
        isInstalled = false
        cancellables = []
        refresh()
        backend.deactivate()
    }

    private func refresh() {
        for id in registered.keys { backend.unregister(id: id) }
        registered = [:]
        guard isInstalled, enabled, !isSuspended else {
            if !isSuspended, !failed.isEmpty { failed = [] }
            return
        }
        var entries: [(key: GlobalDMDirectKey, action: Action)] = []
        if isBoxShowing { entries.append((key: formKey, action: .cycleForm)) }   // W184 AB：框收起就不註冊；W184 F45：鍵是使用者設的（預設 Tab）
        for (target, key) in keys.sorted(by: { $0.key.storageValue < $1.key.storageValue }) {
            entries.append((key: key, action: Action.direct(target)))
        }
        var failures: Set<GlobalDMDirectKey> = []
        var nextID: UInt32 = 1
        for entry in entries {
            let id = nextID
            nextID += 1
            if backend.register(id: id, keyCode: UInt32(entry.key.keyCode)) {
                registered[id] = entry
            } else {
                failures.insert(entry.key)
            }
        }
        if failures != failed { failed = failures }
    }

    /// 非啟用私訊面板可能收到 local event；仍須確認 App 在前景。
    func handleAppKey(_ event: NSEvent, appActive: Bool) -> NSEvent? {
        guard isInstalled, enabled, !isSuspended, appActive, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option]
        else { return event }
        let action: Action
        switch event.keyCode {
        case GlobalDMDirectKey.down.keyCode where !isCollapsed: action = .collapse
        case GlobalDMDirectKey.up.keyCode where isCollapsed: action = .restore
        default: return event
        }
        GlobalHotkeyMonitor.shared.cancelPendingChord()
        onAction?(action)
        return nil
    }

    func pressed(_ id: UInt32) {
        guard let entry = registered[id] else { return }
        // Carbon 熱鍵吃掉那顆鍵的 keyDown；把這次 ⌥⌘ 手勢作廢，放開時才不會又開關私訊框。
        GlobalHotkeyMonitor.shared.cancelPendingChord()
        onAction?(entry.action)
    }

    /// 這個鍵現在能不能用：已經是自己的就可以；否則試著註冊一下馬上拿掉（別的 App 佔用時不行）。
    func probe(_ key: GlobalDMDirectKey) -> Bool {
        if registeredKeys.contains(key) { return true }
        let ok = backend.register(id: Self.probeID, keyCode: UInt32(key.keyCode))
        if ok { backend.unregister(id: Self.probeID) }
        return ok
    }

    /// 框內設直達鍵：擋鍵清單與衝突 → 試註冊 → 存進 store。
    func assign(keyCode: UInt16, to target: GlobalDMTarget, store: GlobalDMStore) -> GlobalDMDirectKeyVerdict {
        guard let key = GlobalDMDirectKey(keyCode: keyCode) else { return .unsupported }
        let verdict = GlobalDMDirectKeyRules.verdict(key, for: target, in: store.directKeys, formKey: formKey)   // W184 F45：換形態的鍵也擋
        guard verdict == .ok else { return verdict }
        guard store.directKeys[target] != key else { return .ok }
        guard probe(key) else { return .occupied(key) }
        return store.setDirectKey(key, for: target)
    }

    /// W184 F45：直達鍵頁「換形態」那一列按下一個鍵：同一套規則（系統保留鍵、只收英文字母或數字、不能跟任何直達鍵同一顆）→
    /// 試註冊（被別的 App 佔用就說）→ 存、馬上照新鍵重新註冊。按 Tab＝回到預設。
    func assignFormKey(keyCode: UInt16, store: GlobalDMStore) -> GlobalDMDirectKeyVerdict {
        guard let key = GlobalDMDirectKey(keyCode: keyCode) else { return .unsupported }
        let verdict = GlobalDMFormKeyBook.verdict(key, directKeys: store.directKeys)
        guard verdict == .ok else { return verdict }
        guard key != formKey else { return .ok }
        // 預設的 Tab 一定收（跟沒改過一樣；被佔用照舊在頁面與選單上說）；其他的鍵先試註冊。
        if key != GlobalDMFormKeyBook.standard, !probe(key) { return .occupied(key) }
        setFormKey(key)
        return .ok
    }

    /// W184 F45：「換形態」那一列的「回到預設」（⌥⌘Tab）。
    func resetFormKey() {
        guard formKey != GlobalDMFormKeyBook.standard else { return }
        setFormKey(GlobalDMFormKeyBook.standard)
    }

    private func setFormKey(_ key: GlobalDMDirectKey) {
        formKey = key
        GlobalDMFormKeyBook.save(key, to: formDefaults)
        refresh()
    }
}

/// Carbon 版：`RegisterEventHotKey` 用 exclusive，別的 App 已經佔住同一組鍵時會失敗，我們就照實說。
@MainActor
final class GlobalDMCarbonHotKeys: GlobalDMHotKeyBackend {
    fileprivate static var onPress: (@MainActor (UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    func activate(onPress: @escaping @MainActor (UInt32) -> Void) {
        Self.onPress = onPress
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        // 處理器掛在事件分派目標（所有事件先經過這裡），熱鍵註冊在 App 目標；同 MASShortcut 的做法。
        if InstallEventHandler(GetEventDispatcherTarget(), globalDMCarbonHotKeyHandler, 1, &spec, nil, &installed)
            == OSStatus(noErr) {
            handler = installed
        }
    }

    func deactivate() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        Self.onPress = nil
    }

    func register(id: UInt32, keyCode: UInt32) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, UInt32(optionKey | cmdKey),
                                         EventHotKeyID(signature: GlobalDMHotKeys.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == OSStatus(noErr), let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}

/// Carbon 在主執行緒的事件迴圈呼叫這個（Application event target）。
private func globalDMCarbonHotKeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                         _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == OSStatus(noErr), hotKey.signature == GlobalDMHotKeys.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let id = hotKey.id
    if Thread.isMainThread {
        MainActor.assumeIsolated { GlobalDMCarbonHotKeys.onPress?(id) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { GlobalDMCarbonHotKeys.onPress?(id) } }
    }
    return OSStatus(noErr)
}
