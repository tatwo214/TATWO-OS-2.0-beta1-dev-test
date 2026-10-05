// Registry display attributes and virtual display flags informed by MonitorControl
// Support/Arm64DDC.swift and Support/DisplayManager.swift (MIT), Copyright © 2017.
// https://github.com/MonitorControl/MonitorControl — see THIRD_PARTY_NOTICES.md.
import AppKit
import IOKit
import CoreAudio
import Darwin
import CryptoKit

struct DisplayEndpoint: Sendable {
    let identity: DisplayIdentity
    let channel: DDCArm64
}

struct DisplayDiscoveryResult: Sendable {
    let displays: [ControlledDisplay]
    let channels: [CGDirectDisplayID: DDCArm64]
    let reason: String?
}

enum DisplayDiscovery {
    /// Reject ambiguous identical EDIDs, including two displays with a zero serial.
    static func match(_ identity: DisplayIdentity, displays: [ControlledDisplay], endpoints: [DisplayEndpoint]) -> DDCArm64? {
        guard identity.vendor != 0, identity.model != 0,
              displays.filter({ $0.identity == identity && !$0.isBuiltIn && !$0.isVirtual && !$0.isAppleNative }).count == 1 else { return nil }
        let candidates = endpoints.filter { $0.identity == identity }
        return candidates.count == 1 ? candidates[0].channel : nil
    }

    private static let coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)
    @MainActor static func snapshot() -> (displays: [ControlledDisplay], reason: String?) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return ([], "無法取得顯示器清單；目前執行環境可能無法存取視窗伺服器")
        }
        let screens = NSScreen.screens
        typealias Info = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
        let infoSymbol = coreDisplayHandle.flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }
        let infoFunction = infoSymbol.map { unsafeBitCast($0, to: Info.self) }
        let displays = ids.prefix(Int(count)).map { id -> ControlledDisplay in
            let info = infoFunction?(id)?.takeRetainedValue() as? [String: Any] ?? [:]
            let identity = DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let sidecar = info["kCGDisplayIsSidecar"] as? Bool ?? false
            let airplay = info["kCGDisplayIsAirPlay"] as? Bool ?? false
            let virtual = sidecar || airplay || (info["kCGDisplayIsVirtualDevice"] as? Bool ?? false) || identity.vendor == 0xF0F0 || identity.vendor == 0
            let native = !virtual && (builtIn || identity.vendor == 0x610)
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
            let persistence = SHA256.hash(data: Data((identity.storageKey + ":" + uuid).utf8)).map { String(format: "%02x", $0) }.joined()
            return ControlledDisplay(id: id, name: screen?.localizedName ?? "External display", identity: identity,
                                     persistenceKey: persistence, isBuiltIn: builtIn, isVirtual: virtual,
                                     isSidecar: sidecar, isAppleNative: native,
                                     dimmingMethod: builtIn || native || screen == nil ? .unavailable : .softwareDimmer,
                                     brightness: 100, volume: nil)
        }
        let reason = displays.isEmpty ? "沒有連線的顯示器；目前執行環境可能無法存取視窗伺服器" : nil
        return (displays, reason)
    }

    @MainActor static func discover(readOnly: Bool = false) async -> DisplayDiscoveryResult {
        let snapshot = snapshot()
        let endpoints = await Task.detached { registryEndpoints(readOnly: readOnly) }.value
        return await resolve(displays: snapshot.displays, endpoints: endpoints,
                             reason: snapshot.reason ?? (!IOAVTransport.symbolsAvailable() ? "Private IOAV symbols unavailable; software dimming fallback" : nil))
    }

    @MainActor static func resolve(displays snapshot: [ControlledDisplay], endpoints: [DisplayEndpoint], reason: String? = nil) async -> DisplayDiscoveryResult {
        var displays = snapshot
        var channels: [CGDirectDisplayID: DDCArm64] = [:]
        for index in displays.indices {
            let display = displays[index]
            guard let channel = match(display.identity, displays: snapshot, endpoints: endpoints) else { continue }
            if let brightness = await channel.read(.brightness) {
                displays[index].hardwareBrightness = brightness
                displays[index].dimmingMethod = .hardwareDDC
                displays[index].brightness = CombinedDimming.combined(hardware: brightness.percentage, shade: 0)
                channels[display.id] = channel
            }
            // Volume support is independent of brightness support. Expose only a validated reply.
            if let volume = await channel.read(.volume) {
                displays[index].hardwareVolume = volume
                displays[index].volume = volume.percentage
                channels[display.id] = channel
            }
        }
        return DisplayDiscoveryResult(displays: displays, channels: channels,
                                      reason: reason)
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, nil, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }
    private static func name(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }
    private static func identity(_ properties: [String: Any]) -> DisplayIdentity? {
        for key in ["IODisplayEDID", "EDID"] {
            if let data = properties[key] as? Data, let identity = DisplayIdentity.edid(data) { return identity }
        }
        guard let attrs = properties["DisplayAttributes"] as? [String: Any],
              let product = attrs["ProductAttributes"] as? [String: Any],
              let vendor = product["LegacyManufacturerID"] as? NSNumber,
              let model = product["ProductID"] as? NSNumber,
              let serial = product["SerialNumber"] as? NSNumber else { return nil }
        return DisplayIdentity(vendor: vendor.uint32Value, model: model.uint32Value, serial: serial.uint32Value)
    }
    private static func dcpIndex(_ entry: io_registry_entry_t) -> Int? {
        var cursor = entry
        IOObjectRetain(cursor)
        defer { IOObjectRelease(cursor) }
        for _ in 0..<32 {
            let node = name(cursor)
            if node == "dcp" { return 0 }
            if node.hasPrefix("dcpext"), let index = Int(node.dropFirst(6)) { return index + 1 }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(cursor, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(cursor)
            cursor = parent
        }
        return nil
    }
    private static func registryEndpoints(readOnly: Bool) -> [DisplayEndpoint] {
        guard IOAVTransport.symbolsAvailable() else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var frames: [Int: [DisplayIdentity]] = [:]
        var proxies: [io_registry_entry_t] = []
        defer { for proxy in proxies { IOObjectRelease(proxy) } }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            let node = name(entry)
            let attrs = properties(entry)
            if ["AppleCLCD2", "IOMobileFramebufferShim"].contains(node),
               let identity = identity(attrs), let index = attrs["DCPIndex"] as? NSNumber {
                frames[index.intValue, default: []].append(identity)
            }
            if node == "DCPAVServiceProxy", attrs["Location"] as? String == "External" {
                proxies.append(entry)
            } else { IOObjectRelease(entry) }
        }
        return proxies.compactMap { proxy in
            guard let transport = IOAVTransport(entry: proxy, readOnly: readOnly) else { return nil }
            // Direct EDID is authoritative. Registry attributes must agree if both exist.
            let direct = transport.edid()
            let local = identity(properties(proxy))
            let candidates = dcpIndex(proxy).flatMap { frames[$0] } ?? []
            let registry = local ?? (candidates.count == 1 ? candidates.first : nil)
            if let direct, let registry, direct != registry { return nil }
            guard let identity = direct ?? registry else { return nil }
            return DisplayEndpoint(identity: identity, channel: DDCArm64(transport: transport))
        }
    }
}

/// No audio device name matching or user overrides. A unique HDMI/DP route can be
/// associated with the sole physical external display. Ambiguous topologies pass through.
enum DisplayAudioRoute {
    static func target(defaultDevice: AudioDeviceID, digitalDevices: [AudioDeviceID], displays: [ControlledDisplay]) -> CGDirectDisplayID? {
        let physical = displays.filter { !$0.isBuiltIn && !$0.isVirtual }
        guard digitalDevices.count == 1, digitalDevices[0] == defaultDevice, physical.count == 1 else { return nil }
        return physical[0].id
    }
    static func currentTarget(displays: [ControlledDisplay]) -> CGDirectDisplayID? {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        var defaultAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &device) == noErr else { return nil }
        var devicesAddress = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty,
              devices.withUnsafeMutableBytes({ AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, $0.baseAddress!) }) == noErr else { return nil }
        let digital = devices.filter { id in
            var transportAddress = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr else { return false }
            return transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
        }
        return target(defaultDevice: device, digitalDevices: digital, displays: displays)
    }
}
