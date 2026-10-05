import AppKit
import Combine
import CryptoKit

struct DisplayIdentity: Equatable, Hashable, Sendable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    static func edid(_ data: Data) -> Self? {
        let b = [UInt8](data)
        guard b.count >= 128, Array(b.prefix(8)) == [0,255,255,255,255,255,255,0],
              b.prefix(128).reduce(UInt8(0), { $0 &+ $1 }) == 0 else { return nil }
        return Self(vendor: UInt32(b[8]) << 8 | UInt32(b[9]),
                    model: UInt32(b[10]) | UInt32(b[11]) << 8,
                    serial: UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24)
    }

    var storageKey: String {
        SHA256.hash(data: Data("\(vendor):\(model):\(serial)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum DisplayDimmingMethod: String, Sendable { case hardwareDDC, softwareDimmer, unavailable }

struct ControlledDisplay: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let identity: DisplayIdentity
    let persistenceKey: String
    let isBuiltIn: Bool
    let isVirtual: Bool
    let isSidecar: Bool
    let isAppleNative: Bool
    var dimmingMethod: DisplayDimmingMethod
    var brightness: Double
    var volume: Double?
    var hardwareBrightness: DDCValue?
    var hardwareVolume: DDCValue?
}

struct DisplayFeedback: Equatable, Sendable {
    enum Kind: String, Sendable { case brightness, volume }
    let displayID: CGDirectDisplayID
    let displayName: String
    let kind: Kind
    let percentage: Double
    static let notification = Notification.Name("tatwo.display.feedback")
}

/// Hardware zero is at 20% of the combined scale; below it only the shade changes.
enum CombinedDimming {
    static let boundary = 20.0
    static let maximumShade = 0.85
    static func clampShade(_ value: Double) -> Double { value.isFinite ? min(maximumShade, max(0, value)) : 0 }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(100, max(0, value)) : 100 }
    static func split(_ value: Double, hardware: Bool) -> (hardware: Double, shade: Double) {
        let value = clamp(value)
        guard hardware else { return (100, clampShade(1 - value / 100)) }
        return (max(0, (value - boundary) * 100 / (100 - boundary)), clampShade(1 - value / boundary))
    }
    static func combined(hardware: Double, shade: Double) -> Double {
        hardware > 0 ? boundary + hardware * (100 - boundary) / 100 : boundary * (1 - clampShade(shade))
    }
}

@MainActor
final class DisplaySettings: ObservableObject {
    static let shared = DisplaySettings()
    private let defaults: UserDefaults
    private static let keyboardKey = "tatwo.display.keyboardEnabled"
    private static let shadeKey = "tatwo.display.shades"
    private var applyingDefault = false
    var keyboardDefaultPending: Bool { defaults.object(forKey: Self.keyboardKey) == nil }
    @Published var keyboardEnabled: Bool {
        didSet { if !applyingDefault { defaults.set(keyboardEnabled, forKey: Self.keyboardKey) } }
    }
    @Published private(set) var shades: [String: Double]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keyboardEnabled = defaults.bool(forKey: Self.keyboardKey)
        shades = (defaults.dictionary(forKey: Self.shadeKey) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite }.mapValues { CombinedDimming.clampShade($0) }
        defaults.set(shades, forKey: Self.shadeKey)
    }
    func shade(for key: String) -> Double { shades[key] ?? 0 }
    func applyKeyboardDefault(_ displays: [ControlledDisplay]) {
        guard keyboardDefaultPending else { return }
        applyingDefault = true
        keyboardEnabled = displays.contains { !$0.isBuiltIn && !$0.isAppleNative && $0.dimmingMethod != .unavailable }
        applyingDefault = false
    }
    func takeKeyboardPermissionNotice() -> Bool {
        let key = "tatwo.display.keyboardPermissionNoticeShown"
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key); return true
    }
    func setShade(_ value: Double, for key: String) {
        guard value.isFinite else { return }
        shades[key] = CombinedDimming.clampShade(value)
        defaults.set(shades, forKey: Self.shadeKey)
    }
}
