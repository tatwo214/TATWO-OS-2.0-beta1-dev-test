import AppKit
import Combine
import ApplicationServices
import CoreAudio

@MainActor final class DisplayControlService: ObservableObject {
    static let shared = DisplayControlService()
    @Published private(set) var displays: [ControlledDisplay] = [] { didSet { publishKeySnapshot() } }
    @Published private(set) var isRefreshing = false { didSet { publishKeySnapshot() } }
    @Published private(set) var hasDeviceControlPermission = false { didSet { publishKeySnapshot() } }
    @Published private(set) var keyTapActive = false
    @Published private(set) var lastError: String?
    @Published private(set) var displayErrors: [CGDirectDisplayID: String] = [:]
    @Published private(set) var keyboardError: String?
    let settings: DisplaySettings
    let monitorControl: MonitorControlDetector
    let feedback = PassthroughSubject<DisplayFeedback, Never>()
    private let dimmer: any DisplayShading
    private var channels: [CGDirectDisplayID: DDCArm64] = [:]
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshGeneration: UInt64 = 0
    private var adjustmentGenerations: [CGDirectDisplayID: UInt64] = [:]
    private var volumeGenerations: [CGDirectDisplayID: UInt64] = [:]
    private var sleeping = false
    private var refreshTask: Task<Void, Never>?
    private var settingsVisible = false
    private let observesSystem: Bool
    private let discover: @MainActor () async -> DisplayDiscoveryResult
    private var keyTap: DisplayKeyTap?
    private let permissionCheck: () -> Bool
    private var audioAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var audioListener: AudioObjectPropertyListenerBlock?

    init(settings: DisplaySettings? = nil, dimmer: (any DisplayShading)? = nil, observe: Bool = true,
         monitorControl: MonitorControlDetector? = nil,
         permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         discover: @escaping @MainActor () async -> DisplayDiscoveryResult = { await DisplayDiscovery.discover() }) {
        self.settings = settings ?? .shared
        self.dimmer = dimmer ?? SoftwareDimmer()
        self.monitorControl = monitorControl ?? MonitorControlDetector(observe: observe)
        self.permissionCheck = permissionCheck
        self.observesSystem = observe
        self.discover = discover
        self.settings.$keyboardEnabled.dropFirst().sink { [weak self] enabled in
            self?.publishKeySnapshot(enabled: enabled)
            // Published sends before didSet; apply on the next main-actor turn.
            Task { @MainActor in self?.keyboardSettingChanged() }
        }.store(in: &subscriptions)
        guard observe else { return }
        keyTap = DisplayKeyTap(service: self)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.publishKeySnapshot() }
        }
        audioListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioAddress, .main, listener)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sleeping = false; self?.handleDisplayChange() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDisplayChange() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateKeyboardTap() }
        })
        if discoveryNeeded { refresh() }
    }

    private var discoveryNeeded: Bool {
        settingsVisible || settings.keyboardDefaultPending || settings.keyboardEnabled || settings.shades.values.contains { $0 > 0 }
    }
    func settingsDidOpen() {
        settingsVisible = true
        if observesSystem { refresh() } else { updateKeyboardTap() }
    }
    func settingsDidClose() { settingsVisible = false }
    func handleDisplayChange() {
        if discoveryNeeded { refresh() }
    }
    private func keyboardSettingChanged() {
        if observesSystem && settings.keyboardEnabled && !settings.keyboardDefaultPending { refresh() } else { updateKeyboardTap() }
    }

    func failureReason(for display: ControlledDisplay) -> String? {
        if let reason = displayErrors[display.id] { return reason }
        guard display.dimmingMethod == .unavailable else { return nil }
        if display.isAppleNative { return "這台螢幕由 macOS 控制，請使用系統的亮度控制。" }
        return "目前無法在這台螢幕加上遮光，請重試。"
    }
    private func recordError(_ reason: String, for id: CGDirectDisplayID) {
        displayErrors[id] = reason
        lastError = reason
    }

    func listDisplays() -> [ControlledDisplay] { displays }
    func brightness(of id: CGDirectDisplayID) -> Double? {
        displays.first { $0.id == id && $0.dimmingMethod != .unavailable }?.brightness
    }
    func volume(of id: CGDirectDisplayID) -> Double? { displays.first { $0.id == id }?.volume }

    func preview(_ value: Double, for id: CGDirectDisplayID, volume: Bool = false) {
        guard value.isFinite, !isRefreshing, !sleeping, let index = displays.firstIndex(where: { $0.id == id }),
              volume ? displays[index].volume != nil : displays[index].dimmingMethod != .unavailable else { return }
        if volume { volumeGenerations[id, default: 0] &+= 1 } else { adjustmentGenerations[id, default: 0] &+= 1 }
        if volume { displays[index].volume = CombinedDimming.clamp(value) }
        else { displays[index].brightness = CombinedDimming.clamp(value) }
    }

    func refresh() {
        guard !sleeping else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        isRefreshing = true
        let old = Array(channels.values)
        channels = [:]
        refreshTask = Task { @MainActor [weak self] in
            for channel in old { await channel.invalidate() }
            guard let self, self.refreshGeneration == generation else { return }
            let result = await self.discover()
            guard !Task.isCancelled, self.refreshGeneration == generation, !self.sleeping else {
                for channel in result.channels.values { await channel.invalidate() }
                return
            }
            self.install(result)
            self.isRefreshing = false
            self.updateKeyboardTap()
        }
    }
    private func suspend() {
        sleeping = true
        refreshGeneration &+= 1
        refreshTask?.cancel()
        keyTap?.stop()
        keyTapActive = false
        isRefreshing = true
        let old = Array(channels.values)
        channels = [:]
        Task { for channel in old { await channel.invalidate() } }
    }
    /// Also used by the fixture acceptance harness; it does not discover real hardware.
    func install(_ result: DisplayDiscoveryResult) {
        displays = result.displays
        channels = result.channels
        lastError = result.reason
        displayErrors.removeAll()
        adjustmentGenerations.removeAll()
        volumeGenerations.removeAll()
        dimmer.retainDisplays(Set(displays.filter { $0.dimmingMethod != .unavailable }.map(\.id)))
        for index in displays.indices where displays[index].dimmingMethod != .unavailable {
            let shade = settings.shade(for: displays[index].persistenceKey)
            if displays[index].dimmingMethod == .hardwareDDC {
                let hardware = displays[index].hardwareBrightness?.percentage ?? 100
                // Only restore a combined shade when the physical panel still reports zero.
                // A reconnect never restores hardware brightness by writing to the panel.
                displays[index].brightness = CombinedDimming.combined(hardware: hardware, shade: hardware == 0 ? shade : 0)
                if !dimmer.setShade(hardware == 0 ? shade : 0, on: displays[index].id, animated: false) {
                    displays[index].brightness = CombinedDimming.combined(hardware: hardware, shade: 0)
                    recordError("目前無法在這台螢幕加上遮光，請重試。", for: displays[index].id)
                }
            } else {
                displays[index].brightness = (1 - shade) * 100
                if !dimmer.setShade(shade, on: displays[index].id, animated: false) {
                    displays[index].dimmingMethod = .unavailable
                    recordError("目前無法在這台螢幕加上遮光，請重試。", for: displays[index].id)
                }
            }
        }
        settings.applyKeyboardDefault(displays)
    }

    @discardableResult func setBrightness(_ value: Double, for id: CGDirectDisplayID, smooth: Bool = false) async -> Bool {
        guard value.isFinite, !isRefreshing, !sleeping,
              let index = displays.firstIndex(where: { $0.id == id && $0.dimmingMethod != .unavailable }) else { return false }
        let percentage = CombinedDimming.clamp(value)
        let configuration = refreshGeneration
        let generation = (adjustmentGenerations[id] ?? 0) &+ 1
        adjustmentGenerations[id] = generation
        displays[index].brightness = percentage
        emit(id: id, kind: .brightness, percentage: percentage)
        let split = CombinedDimming.split(percentage, hardware: displays[index].dimmingMethod == .hardwareDDC)
        if displays[index].dimmingMethod == .hardwareDDC, let channel = channels[id] {
            let result = await channel.set(split.hardware, command: .brightness, smooth: smooth)
            guard configuration == refreshGeneration, adjustmentGenerations[id] == generation,
                  let currentIndex = displays.firstIndex(where: { $0.id == id }) else { return false }
            switch result {
            case .superseded: return false
            case .failed:
                displays[currentIndex].dimmingMethod = .softwareDimmer
                displays[currentIndex].hardwareBrightness = nil
                displays[currentIndex].volume = nil
                displays[currentIndex].hardwareVolume = nil
                channels[id] = nil
                recordError("這台螢幕沒有回應亮度調整，已改用軟體調光。", for: id)
                await channel.invalidate()
                guard configuration == refreshGeneration, adjustmentGenerations[id] == generation else { return false }
                let fallback = CombinedDimming.split(percentage, hardware: false)
                guard dimmer.setShade(fallback.shade, on: id, animated: true) else {
                    displays[currentIndex].dimmingMethod = .unavailable
                    recordError("這台螢幕沒有回應亮度調整，也無法加上遮光，請重試。", for: id)
                    return false
                }
                settings.setShade(fallback.shade, for: displays[currentIndex].persistenceKey)
            case .written:
                if let maximum = displays[currentIndex].hardwareBrightness?.maximum {
                    displays[currentIndex].hardwareBrightness = DDCValue(current: UInt16((split.hardware * Double(maximum) / 100).rounded()), maximum: maximum)
                }
                guard dimmer.setShade(split.shade, on: id, animated: true) else {
                    displays[currentIndex].brightness = CombinedDimming.combined(hardware: split.hardware, shade: 0)
                    recordError("目前無法在這台螢幕加上遮光，請重試。", for: id)
                    emit(id: id, kind: .brightness, percentage: displays[currentIndex].brightness)
                    return false
                }
                settings.setShade(split.shade, for: displays[currentIndex].persistenceKey)
            }
        } else {
            guard dimmer.setShade(split.shade, on: id, animated: true) else {
                displays[index].dimmingMethod = .unavailable
                recordError("目前無法在這台螢幕加上遮光，請重試。", for: id)
                return false
            }
            settings.setShade(split.shade, for: displays[index].persistenceKey)
        }
        return true
    }

    @discardableResult func setVolume(_ value: Double, for id: CGDirectDisplayID, smooth: Bool = false) async -> Bool {
        guard value.isFinite, !isRefreshing, !sleeping,
              let index = displays.firstIndex(where: { $0.id == id && $0.volume != nil }), let channel = channels[id] else { return false }
        let percentage = CombinedDimming.clamp(value)
        let configuration = refreshGeneration
        let generation = (volumeGenerations[id] ?? 0) &+ 1
        volumeGenerations[id] = generation
        displays[index].volume = percentage
        emit(id: id, kind: .volume, percentage: percentage)
        let result = await channel.set(percentage, command: .volume, smooth: smooth)
        guard configuration == refreshGeneration, volumeGenerations[id] == generation,
              let currentIndex = displays.firstIndex(where: { $0.id == id }) else { return false }
        switch result {
        case .superseded: return false
        case .failed:
            displays[currentIndex].volume = nil
            displays[currentIndex].hardwareVolume = nil
            recordError("這台螢幕沒有回應音量調整，暫時無法調音量。", for: id)
            return false
        case .written:
            if let maximum = displays[currentIndex].hardwareVolume?.maximum {
                displays[currentIndex].hardwareVolume = DDCValue(current: UInt16((percentage * Double(maximum) / 100).rounded()), maximum: maximum)
            }
            return true
        }
    }
    private func emit(id: CGDirectDisplayID, kind: DisplayFeedback.Kind, percentage: Double) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let event = DisplayFeedback(displayID: id, displayName: display.name, kind: kind, percentage: percentage)
        feedback.send(event)
        NotificationCenter.default.post(name: DisplayFeedback.notification, object: event)
    }
    private func publishKeySnapshot(enabled: Bool? = nil) {
        guard let keyTap else { return }
        keyTap.update(.init(displays: displays, enabled: enabled ?? settings.keyboardEnabled,
                            trusted: hasDeviceControlPermission, refreshing: isRefreshing,
                            audioDisplay: DisplayAudioRoute.currentTarget(displays: displays)))
    }
    func updateKeyboardTap() {
        publishKeySnapshot()
        guard settings.keyboardEnabled else {
            keyTap?.stop()
            keyTapActive = false
            hasDeviceControlPermission = false
            keyboardError = nil
            return
        }
        hasDeviceControlPermission = permissionCheck()
        if !hasDeviceControlPermission && settings.keyboardDefaultPending && IslandNotice.shared.hostAvailable && settings.takeKeyboardPermissionNotice() {
            DisplayIslandFeedback.requestKeyboardPermission()
        }
        if settings.keyboardEnabled && hasDeviceControlPermission && !sleeping {
            keyTapActive = keyTap?.start() ?? false
            keyboardError = keyTapActive ? nil : "鍵盤控制沒有啟動，請重試或重新確認系統權限。"
        } else { keyTap?.stop(); keyTapActive = false; keyboardError = nil }
    }
    deinit {
        keyTap?.stop()
        if let audioListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioAddress, .main, audioListener) }
        refreshTask?.cancel()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
