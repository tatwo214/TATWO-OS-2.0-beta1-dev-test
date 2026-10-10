import AppKit
import Combine
import SwiftUI

/// Adapt the existing service event to the Island's content-only notification payload.
@MainActor final class DisplayIslandFeedback {
    static let shared = DisplayIslandFeedback(notice: .shared)
    private var subscription: AnyCancellable?

    init(notice: IslandNotice) {
        subscription = NotificationCenter.default.publisher(for: DisplayFeedback.notification)
            .receive(on: DispatchQueue.main)
            .sink { [weak notice] notification in
                guard let event = notification.object as? DisplayFeedback else { return }
                MainActor.assumeIsolated { notice?.showDisplayMeter(Self.meter(event)) }
            }
    }

    static func meter(_ event: DisplayFeedback) -> IslandNotice.Meter {
        IslandNotice.Meter(displayName: event.displayName,
                           symbol: event.kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill",
                           percentage: event.percentage)
    }
    static func requestKeyboardPermission(notice: IslandNotice? = nil, openSettings: (() -> Void)? = nil) {
        Task { @MainActor in
            if await (notice ?? .shared).confirm(title: "鍵盤調光", detail: "請允許裝置控制權限，才能用鍵盤調整外接螢幕。", confirmLabel: "打開系統設定") {
                if let openSettings { openSettings() }
                else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

@MainActor
struct DisplaySettingsView: View {
    @ObservedObject var service: DisplayControlService
    @ObservedObject private var settings: DisplaySettings
    @ObservedObject private var monitorControl: MonitorControlDetector
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private let openSettings: () -> Void

    init(service: DisplayControlService? = nil, openSettings: @escaping () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }) {
        let service = service ?? .shared
        self.service = service
        settings = service.settings
        monitorControl = service.monitorControl
        self.openSettings = openSettings
    }

    var externalDisplays: [ControlledDisplay] { service.listDisplays().filter { !$0.isBuiltIn } }

    var keyboardBinding: Binding<Bool> {
        Binding(get: { settings.keyboardEnabled }, set: { settings.keyboardEnabled = $0 })
    }

    func brightnessBinding(for display: ControlledDisplay) -> Binding<Double> {
        Binding(get: { service.brightness(of: display.id) ?? display.brightness }, set: { value in
            service.preview(value, for: display.id)
            Task { @MainActor in if service.brightness(of: display.id) == value { await service.setBrightness(value, for: display.id) } }
        })
    }

    func volumeBinding(for display: ControlledDisplay) -> Binding<Double> {
        Binding(get: { service.volume(of: display.id) ?? 0 }, set: { value in
            service.preview(value, for: display.id, volume: true)
            Task { @MainActor in if service.volume(of: display.id) == value { await service.setVolume(value, for: display.id) } }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
                TatwoSettingsPageHeader(title: "顯示器", subtitle: "外接螢幕的亮度與音量。")
                if externalDisplays.isEmpty {
                    Text("目前沒有接外接螢幕")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    if service.lastError != nil {
                        Text("目前讀不到螢幕資訊，請重試。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    OSChipButton(title: "重試", action: { service.refresh() })
                        .disabled(service.isRefreshing)
                } else {
                    ForEach(externalDisplays) { display in displayCard(display) }
                }
                keyboardCard
                if CrashRelaunch.available {
                    Toggle("當機自動重開", isOn: Binding(get: { CrashRelaunch.enabled }, set: CrashRelaunch.change))
                        .toggleStyle(.switch).tint(LiquidGlassTokens.brandAccent)
                    Text("當機會自動重開；登入時也會自動開啟 App。關閉後，下次正常結束 App 後生效。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if monitorControl.isRunning {
                    Text("MonitorControl 也在執行，兩邊同時調會互搶。確認這裡好用後，可以把它關掉。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LiquidGlassTokens.brandAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(TatwoSettingsPageMetrics.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { service.settingsDidOpen() }
        .onDisappear { service.settingsDidClose() }
    }

    func dimmingLabel(for display: ControlledDisplay) -> String {
        switch display.dimmingMethod {
        case .hardwareDDC: "硬體調光"
        case .softwareDimmer: "軟體調光"
        case .unavailable: "無法調整"
        }
    }

    private func displayCard(_ display: ControlledDisplay) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                    .accessibilityLabel("已連接")
                Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(dimmingLabel(for: display))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            adjustmentRow("亮度", icon: "sun.max", value: brightnessBinding(for: display))
                .disabled(display.dimmingMethod == .unavailable || service.isRefreshing)
            if display.volume != nil {
                adjustmentRow("音量", icon: "speaker.wave.2", value: volumeBinding(for: display))
                    .disabled(service.isRefreshing)
            }
            if let reason = service.failureReason(for: display) {
                HStack(spacing: 10) {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    OSChipButton(title: "重試", action: { service.refresh() })
                        .fixedSize().disabled(service.isRefreshing)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func adjustmentRow(_ title: String, icon: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12)).frame(width: 28, alignment: .leading)
            Slider(value: value, in: 0...100)
                .tint(LiquidGlassTokens.brandAccent)
                .accentColor(LiquidGlassTokens.brandAccent)
                // Native macOS controls may ignore per-view tint. Keep their input/AX,
                // and paint only the filled track, stopping before the native thumb.
                .overlay {
                    GeometryReader { geometry in
                        Capsule().fill(LiquidGlassTokens.brandAccent)
                            .frame(width: max(0, (geometry.size.width - 20) * value.wrappedValue / 100 - 10), height: 3)
                            .padding(.leading, 10)
                            .frame(maxHeight: .infinity)
                    }
                    .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
            Text("\(Int(value.wrappedValue.rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用鍵盤亮度鍵、音量鍵調外接螢幕")
                        .font(.system(size: 13, weight: .semibold))
                    Text("調滑鼠所在的那台；按的時候 Tatwo Island 顯示百分比。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("用鍵盤亮度鍵、音量鍵調外接螢幕", isOn: keyboardBinding)
                    .toggleStyle(.switch).labelsHidden()
                    .tint(LiquidGlassTokens.brandAccent)
                    .accentColor(LiquidGlassTokens.brandAccent)
                    .overlay {
                        if settings.keyboardEnabled {
                            Capsule().fill(LiquidGlassTokens.brandAccent)
                                .frame(width: 37, height: 22)
                                .overlay {
                                    Circle().fill(.white).frame(width: 19, height: 19)
                                        .offset(x: 8)
                                }
                                .allowsHitTesting(false)
                        }
                    }
            }
            // 主導 10-03：開關關著時不顯示權限列（字越少越好）；打開才說明權限狀態。
            if settings.keyboardEnabled {
                Divider()
                if service.hasDeviceControlPermission {
                    Label("權限已開（系統設定 › 隱私權與安全性 › 裝置控制和資料取用（舊稱輔助使用））", systemImage: "checkmark")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let reason = service.keyboardError {
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            OSChipButton(title: "重試", action: { service.updateKeyboardTap() })
                                .disabled(service.isRefreshing)
                            OSChipButton(title: "打開系統設定", action: openSettings)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        Text("在系統設定 › 隱私權與安全性 › 裝置控制和資料取用（舊稱輔助使用），允許 TATWO OS。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        OSChipButton(title: "打開系統設定", action: openSettings)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground)
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

#if DEBUG
/// UI acceptance runs before normal launch, with no discovery, key tap or real shading.
private final class DisplayUIFixtureTransport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    var failWrites = false
    private var values: [DDCCommand: DDCValue] = [
        .brightness: DDCValue(current: 50, maximum: 100),
        .volume: DDCValue(current: 25, maximum: 100)
    ]
    func read(_ command: DDCCommand) -> DDCValue? {
        lock.lock(); defer { lock.unlock() }
        return values[command]
    }
    func write(_ command: DDCCommand, value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failWrites else { return false }
        values[command] = DDCValue(current: value, maximum: 100)
        return true
    }
}

@MainActor private final class DisplayUIFixtureDimmer: DisplayShading {
    var shades: [CGDirectDisplayID: Double] = [:]
    func setShade(_ shade: Double, on display: CGDirectDisplayID, animated: Bool) -> Bool {
        shades[display] = shade
        return true
    }
    func retainDisplays(_ ids: Set<CGDirectDisplayID>) { shades = shades.filter { ids.contains($0.key) } }
}

@MainActor private final class DisplayUIFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor enum DisplayUIAcceptance {
    static func run() async -> Bool {
        var failures = 0
        var artifactCount = 0
        func check(_ success: Bool, _ name: String) {
            print("W188UI \(success ? "PASS" : "FAIL") \(name)")
            if !success { failures += 1 }
        }
        let theme = TatwoThemeSelfTestScope()
        theme.use(.fable5)
        defer { theme.restore() }
        let suite = "tatwo.display.ui.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "tatwo.display.keyboardEnabled")
        let settings = DisplaySettings(defaults: defaults)
        let dimmer = DisplayUIFixtureDimmer()
        let transport = DisplayUIFixtureTransport()
        let channel = DDCArm64(transport: transport, pause: { _ in })
        var permissionGranted = false
        var permissionChecks = 0
        let detector = MonitorControlDetector(observe: false)
        let service = DisplayControlService(settings: settings, dimmer: dimmer, observe: false,
                                            monitorControl: detector, permissionCheck: {
            permissionChecks += 1
            return permissionGranted
        })
        let view = DisplaySettingsView(service: service, openSettings: {
            check(false, "fixture must never open system settings")
        })
        var hardware = DisplayAcceptance.fixture(method: .hardwareDDC)
        hardware.hardwareBrightness = DDCValue(current: 50, maximum: 100)
        hardware.hardwareVolume = DDCValue(current: 25, maximum: 100)
        hardware.volume = 25
        let software = DisplayAcceptance.fixture(2)
        let builtIn = DisplayAcceptance.fixture(3, builtIn: true, method: .unavailable)
        func install(_ displays: [ControlledDisplay]) {
            service.install(DisplayDiscoveryResult(displays: displays,
                channels: displays.contains(where: { $0.id == hardware.id }) ? [hardware.id: channel] : [:], reason: nil))
        }
        let noticeState = TatwoIslandShellState()
        let notice = IslandNotice(fallback: { _, _, _ in
            check(false, "display feedback must not open fallback windows")
            return nil
        }, holdOpen: { noticeState.holdOpen($0) }, log: { _ in })
        notice.hostAvailable = true
        let feedbackBridge = DisplayIslandFeedback(notice: notice)
        defer { withExtendedLifetime(feedbackBridge) {} }
        install([hardware, builtIn])
        check(view.externalDisplays.map(\.id) == [hardware.id], "only connected external displays")
        service.updateKeyboardTap()
        check(!settings.keyboardEnabled && permissionChecks == 0 && !service.keyTapActive,
              "keyboard defaults off and does not check permissions")

        do {
            guard let path = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"] else {
                throw NSError(domain: "W188UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "artifacts path missing"])
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func settingsCapture(_ name: String, _ page: DisplaySettingsView) async throws {
                let shell = TatwoSettingsShell(section: .constant(.display)) { page }
                    .background(LiquidGlassTokens.browserGroundFill)
                let bitmap = try await capture(shell, size: NSSize(width: 780, height: 560), to: root.appendingPathComponent(name))
                artifactCount += 1
                check(true, "PNG \(name)")
                if name == "a-hardware-volume.png" {
                    check(hasBrandPixels(bitmap, in: CGRect(x: 294, y: 110, width: 210, height: 18)), "brightness slider visibly uses brand color")
                    check(hasBrandPixels(bitmap, in: CGRect(x: 294, y: 145, width: 75, height: 18)), "volume slider visibly uses brand color")
                }
                if name == "d-keyboard-permitted.png" {
                    check(hasBrandPixels(bitmap, in: CGRect(x: 711, y: 205, width: 43, height: 28)), "enabled switch visibly uses brand color")
                }
                try await TatwoThemeSelfTestScope.withDarkAppearance {
                    let darkName = name.replacingOccurrences(of: ".png", with: "-dark.png")
                    let shell = TatwoSettingsShell(section: .constant(.display)) { page }
                        .background(LiquidGlassTokens.browserOmniboxDarkTint)
                    let dark = try await capture(shell, size: NSSize(width: 780, height: 560), to: root.appendingPathComponent(darkName), scheme: .dark)
                    artifactCount += 1
                    check(TatwoThemeSelfTestScope.hasReadableDarkPixels(dark), "darkAqua readable PNG \(darkName)")
                }
            }
            try await settingsCapture("a-hardware-volume.png", view)

            // Exercise the exact bindings supplied to the visible sliders.
            view.brightnessBinding(for: hardware).wrappedValue = 72
            try? await Task.sleep(nanoseconds: 150_000_000)
            check(service.brightness(of: hardware.id) == 72 && transport.read(.brightness)?.current == 65,
                  "brightness slider binding calls existing service and fixture transport")
            let firstID = notice.displayMeter?.id
            check(notice.displayMeter?.meter?.percentage == 72 && noticeState.isExpanded,
                  "notification subscription expands Island with service feedback")
            view.volumeBinding(for: hardware).wrappedValue = 43
            try? await Task.sleep(nanoseconds: 150_000_000)
            check(service.volume(of: hardware.id) == 43 && transport.read(.volume)?.current == 43,
                  "volume slider binding calls existing service and fixture transport")
            check(firstID != nil && notice.displayMeter?.id == firstID && notice.displayMeter?.meter?.symbol == "speaker.wave.2.fill",
                  "brightness and volume update the same Island notice")

            install([software])
            view.brightnessBinding(for: software).wrappedValue = 35
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(service.volume(of: software.id) == nil && abs((dimmer.shades[software.id] ?? 0) - 0.65) < 0.000001,
                  "software slider uses fixture shade with no volume")
            try await settingsCapture("b-software.png", view)
            install([builtIn])
            check(view.externalDisplays.isEmpty, "empty external list excludes built-in screen")
            try await settingsCapture("c-no-displays.png", view)

            install([hardware])
            permissionGranted = true
            view.keyboardBinding.wrappedValue = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            check(DisplaySettings(defaults: defaults).keyboardEnabled && service.hasDeviceControlPermission && permissionChecks > 0,
                  "keyboard toggle persists and checks injected permission")
            check(!service.keyTapActive, "fixture never installs a key tap")
            check(service.keyboardError == "鍵盤控制沒有啟動，請重試或重新確認系統權限。",
                  "M10 granted permission with failed tap has a visible reason")
            try await settingsCapture("d-keyboard-permitted.png", view)
            permissionGranted = false
            service.updateKeyboardTap()
            check(!service.hasDeviceControlPermission, "permission revocation updates UI state without prompts")
            try await settingsCapture("e-keyboard-needs-permission.png", view)
            let conflict = MonitorControlDetector(observe: false, identifiers: [MonitorControlDetector.bundleIdentifier])
            let conflictService = DisplayControlService(settings: settings, dimmer: dimmer, observe: false,
                                                       monitorControl: conflict, permissionCheck: { false })
            conflictService.install(DisplayDiscoveryResult(displays: [hardware], channels: [hardware.id: channel], reason: nil))
            check(conflictService.monitorControl.isRunning, "MonitorControl fixture feeds observed warning")
            try await settingsCapture("f-monitorcontrol.png", DisplaySettingsView(service: conflictService, openSettings: {}))

            let brightnessNotice = IslandNotice(holdOpen: { _ in }, log: { _ in })
            let volumeNotice = IslandNotice(holdOpen: { _ in }, log: { _ in })
            brightnessNotice.hostAvailable = true
            volumeNotice.hostAvailable = true
            brightnessNotice.showDisplayMeter(DisplayIslandFeedback.meter(DisplayFeedback(displayID: 1, displayName: "fixture", kind: .brightness, percentage: 72)))
            volumeNotice.showDisplayMeter(DisplayIslandFeedback.meter(DisplayFeedback(displayID: 1, displayName: "fixture", kind: .volume, percentage: 43)))
            // Same original surface and notification content used by TatwoIslandShellView.
            let meters = VStack(spacing: 28) {
                islandCaptureContent(brightnessNotice)
                islandCaptureContent(volumeNotice)
            }
            .frame(width: 700, height: 420)
            .background(LiquidGlassTokens.browserGroundFill)
            _ = try await capture(meters, size: NSSize(width: 700, height: 420), to: root.appendingPathComponent("g-island-brightness-volume.png"))
            artifactCount += 1
            check(true, "PNG g-island-brightness-volume.png")

            transport.failWrites = true
            install([hardware])
            check(await service.setBrightness(40, for: hardware.id) && service.failureReason(for: service.displays[0]) != nil,
                  "M10 failed DDC exposes reason alongside software fallback")
            try await settingsCapture("h-ddc-failure.png", view)
            let unavailable = DisplayAcceptance.fixture(4, method: .unavailable)
            install([unavailable])
            check(view.dimmingLabel(for: unavailable) == "無法調整" && service.failureReason(for: unavailable) != nil,
                  "M10 unavailable card has accurate label and reason")
            try await settingsCapture("i-unavailable.png", view)

            view.keyboardBinding.wrappedValue = false
            try? await Task.sleep(nanoseconds: 50_000_000)
            let checksWhenOff = permissionChecks
            service.updateKeyboardTap()
            check(!DisplaySettings(defaults: defaults).keyboardEnabled && permissionChecks == checksWhenOff,
                  "toggle off persists and stops permission checks")
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            check(notice.current == nil && notice.displayMeter == nil && !noticeState.isExpanded, "Island retracts one second after last event")

            let feedback = DisplayFeedback(displayID: 1, displayName: "fixture", kind: .brightness, percentage: 60)
            notice.showDisplayMeter(DisplayIslandFeedback.meter(feedback))
            let coalescedID = notice.displayMeter?.id
            try? await Task.sleep(nanoseconds: 650_000_000)
            notice.showDisplayMeter(DisplayIslandFeedback.meter(DisplayFeedback(displayID: 2, displayName: "sample", kind: .volume, percentage: 20)))
            try? await Task.sleep(nanoseconds: 500_000_000)
            check(notice.displayMeter?.id == coalescedID && notice.displayMeter?.meter?.displayName == "sample",
                  "repeat renews deadline and updates display target")
            try? await Task.sleep(nanoseconds: 650_000_000)
            check(notice.current == nil && notice.displayMeter == nil, "coalesced meter expires without queued duplicates")
            let askID = UUID()
            let pending = Task { @MainActor in
                await notice.ask(title: "fixture", detail: "fixture", allowLabel: "fixture", timeout: 5, requestID: askID)
            }
            await Task.yield()
            notice.showDisplayMeter(DisplayIslandFeedback.meter(feedback))
            check(notice.current?.id == askID, "meter does not replace pending approval")
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            notice.resolve(.cancel, id: askID)
            check(await pending.value == .cancel && notice.current == nil && notice.displayMeter == nil, "stale meter is not replayed after approval")
            notice.hostAvailable = false
            notice.showDisplayMeter(DisplayIslandFeedback.meter(feedback))
            check(notice.current == nil && notice.displayMeter == nil, "disabled Island skips feedback without fallback")
        } catch {
            check(false, "artifacts \(error.localizedDescription)")
        }
        print("W188UI SUMMARY failures=\(failures) pngs=\(artifactCount) hardwareWrites=fixture-only")
        return failures == 0
    }

    private static func islandCaptureContent(_ notice: IslandNotice) -> some View {
        TatwoIslandShellSurface(progress: 1, overlaySize: NSSize(width: 648, height: 172), onHover: { _ in })
            .overlay(alignment: .top) { IslandNoticeContent(prompt: notice, isExpanded: true) }
            .frame(width: 648, height: 172)
    }

    private static func hasBrandPixels(_ bitmap: NSBitmapImageRep, in region: CGRect) -> Bool {
        guard let brand = NSColor(LiquidGlassTokens.brandAccent).usingColorSpace(.deviceRGB) else { return false }
        let scale = Double(bitmap.pixelsWide) / 780
        var matches = 0
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(pixel.redComponent - brand.redComponent) < 0.08
                    && abs(pixel.greenComponent - brand.greenComponent) < 0.08
                    && abs(pixel.blueComponent - brand.blueComponent) < 0.08 { matches += 1 }
            }
        }
        return matches > 20
    }

    private static func capture<Content: View>(_ content: Content, size: NSSize, to url: URL, scheme: ColorScheme = .light) async throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: content.environment(\.controlActiveState, .active).environment(\.colorScheme, scheme))
        let window = DisplayUIFixtureWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        hosting.displayIfNeeded()
        // Capture only this fixture window. The compositor preserves native glass;
        // cacheDisplay's software render cannot reproduce its backdrop effect.
        typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
        defer { if let handle { dlclose(handle) } }
        let symbol = handle.flatMap { dlsym($0, "CGWindowListCreateImage") }
        let native = symbol.map { unsafeBitCast($0, to: WindowImage.self) }?(
            .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
            CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
        let bitmap: NSBitmapImageRep
        if let native {
            bitmap = NSBitmapImageRep(cgImage: native)
        } else if let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: cached)
            bitmap = cached
        } else {
            throw NSError(domain: "W188UI", code: 2, userInfo: [NSLocalizedDescriptionKey: "bitmap unavailable"])
        }
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 8_000 else {
            throw NSError(domain: "W188UI", code: 3, userInfo: [NSLocalizedDescriptionKey: "rendered PNG missing or empty"])
        }
        try png.write(to: url)
        print("W188UI ARTIFACT \(url.path)")
        window.orderOut(nil)
        return bitmap
    }
}
#endif
