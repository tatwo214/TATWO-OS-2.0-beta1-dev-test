// DDC wire framing adapted from MonitorControl/Support/Arm64DDC.swift (MIT).
// https://github.com/MonitorControl/MonitorControl — Copyright © 2017.
// Full license: THIRD_PARTY_NOTICES.md.
import Foundation
import IOKit
import Darwin

#if arch(arm64)
// ABI declarations document the private entry points. Calls resolve dynamically below,
// so the executable has no strong undefined symbol when a future OS removes an API.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ address: UInt32, _ offset: UInt32, _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> Int32
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ address: UInt32, _ offset: UInt32, _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> Int32
#endif

struct DDCValue: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16
    var percentage: Double { maximum > 0 ? Double(current) * 100 / Double(maximum) : 0 }
}

enum DDCCommand: UInt8, Sendable { case brightness = 0x10, volume = 0x62 }
enum DDCWriteResult: Sendable { case written, superseded, failed }

protocol DDCTransport: AnyObject, Sendable {
    func read(_ command: DDCCommand) async -> DDCValue?
    func write(_ command: DDCCommand, value: UInt16) -> Bool
}

/// One actor per physical service; read transactions hold the channel across timing waits.
/// Suspended waits let newer requests supersede pending writes without blocking an executor.
actor DDCArm64 {
    private let transport: any DDCTransport
    private let minimumInterval: TimeInterval
    private let pause: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> TimeInterval
    private var lastWrite = -Double.infinity
    private var cached: [DDCCommand: DDCValue] = [:]
    private var generations: [DDCCommand: UInt64] = [:]
    private var invalidated = false
    private var reading = false

    init(transport: any DDCTransport, minimumInterval: TimeInterval = 0.05,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.transport = transport
        self.minimumInterval = minimumInterval
        self.now = now
        self.pause = pause
    }

    func read(_ command: DDCCommand) async -> DDCValue? {
        while reading { await pause(0.005); await Task.yield(); if invalidated || Task.isCancelled { return nil } }
        guard !invalidated else { return nil }
        reading = true; defer { reading = false }
        for attempt in 0..<3 {
            guard !invalidated, !Task.isCancelled else { return nil }
            if let value = await transport.read(command), !invalidated, value.maximum > 0, value.current <= value.maximum {
                cached[command] = value
                return value
            }
            if attempt < 2 { await pause(0.04) }
        }
        return nil
    }

    func invalidate() async {
        invalidated = true; generations = generations.mapValues { $0 &+ 1 }
        while reading { await pause(0.005); await Task.yield() }
    }

    func set(_ percentage: Double, command: DDCCommand, smooth: Bool = true) async -> DDCWriteResult {
        guard !invalidated, percentage.isFinite else { return .failed }
        let generation = (generations[command] ?? 0) &+ 1
        generations[command] = generation
        var observed = cached[command]
        if observed == nil { observed = await read(command) }
        guard let current = observed else { return .failed }
        let target = UInt16((CombinedDimming.clamp(percentage) * Double(current.maximum) / 100).rounded())
        let start = Int(current.current)
        let steps = smooth ? max(1, min(20, Int(ceil(abs(Double(Int(target) - start)) / max(1, Double(current.maximum) * 0.08))))) : 1
        for step in 1...steps {
            guard !invalidated else { return .superseded }
            guard generations[command] == generation else { return .superseded }
            let value = UInt16(start + (Int(target) - start) * step / steps)
            if cached[command]?.current != value {
                var success = false
                for attempt in 0..<3 {
                    while reading || minimumInterval > now() - lastWrite {
                        await pause(max(0.005, minimumInterval - (now() - lastWrite)))
                        await Task.yield()
                        guard !invalidated, !Task.isCancelled, generations[command] == generation else { return .superseded }
                    }
                    guard !invalidated, !Task.isCancelled, generations[command] == generation else { return .superseded }
                    success = transport.write(command, value: value)
                    lastWrite = now()
                    if success { break }
                    if attempt < 2 { await pause(0.04) }
                }
                guard success else { return .failed }
                cached[command] = DDCValue(current: value, maximum: current.maximum)
            }
            if step < steps { try? await Task.sleep(nanoseconds: 30_000_000) }
        }
        return .written
    }
}

/// A read-only session still sends MCCS Get VCP query packets over I2C.
/// It rejects Set VCP at the transport boundary, independently of the caller.
final class IOAVTransport: DDCTransport, @unchecked Sendable {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private let service: CFTypeRef
    private let readI2C: I2C
    private let writeI2C: I2C
    private let readOnly: Bool

    static func symbolsAvailable(resolve: (String) -> UnsafeMutableRawPointer? = symbol) -> Bool {
        #if arch(arm64)
        return ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C"].allSatisfy { resolve($0) != nil }
        #else
        return false
        #endif
    }
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        // IOKit is linked by import; RTLD_DEFAULT also finds framework exports.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
    init?(entry: io_service_t, readOnly: Bool) {
        guard Self.symbolsAvailable(),
              let c = Self.symbol("IOAVServiceCreateWithService"),
              let r = Self.symbol("IOAVServiceReadI2C"), let w = Self.symbol("IOAVServiceWriteI2C"),
              let service = unsafeBitCast(c, to: Create.self)(kCFAllocatorDefault, entry)?.takeRetainedValue() else { return nil }
        self.service = service
        readI2C = unsafeBitCast(r, to: I2C.self)
        writeI2C = unsafeBitCast(w, to: I2C.self)
        self.readOnly = readOnly
    }
    func edid() -> DisplayIdentity? {
        var bytes = [UInt8](repeating: 0, count: 128)
        guard bytes.withUnsafeMutableBytes({ readI2C(service, 0x50, 0, $0.baseAddress!, 128) }) == 0 else { return nil }
        return DisplayIdentity.edid(Data(bytes))
    }
    static func packet(_ command: DDCCommand, value: UInt16? = nil) -> [UInt8] {
        let payload: [UInt8] = value.map { [command.rawValue, UInt8($0 >> 8), UInt8($0 & 255)] } ?? [command.rawValue]
        var packet = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
        packet.append(packet.reduce(value == nil ? UInt8(0x6e) : UInt8(0x6e ^ 0x51), ^))
        return packet
    }
    static func decode(_ bytes: [UInt8], command: DDCCommand) -> DDCValue? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0, bytes[4] == command.rawValue,
              bytes.reduce(UInt8(0x50), ^) == 0 else { return nil }
        let value = DDCValue(current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                             maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        return value.maximum > 0 && value.current <= value.maximum ? value : nil
    }
    func read(_ command: DDCCommand) async -> DDCValue? {
        var packet = Self.packet(command)
        guard packet.withUnsafeMutableBytes({ writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return nil }
        await Task.detached { try? await Task.sleep(nanoseconds: 50_000_000) }.value
        var reply = [UInt8](repeating: 0, count: 11)
        guard reply.withUnsafeMutableBytes({ readI2C(service, 0x37, 0, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return nil }
        return Self.decode(reply, command: command)
    }
    func write(_ command: DDCCommand, value: UInt16) -> Bool {
        guard !readOnly else { return false }
        var packet = Self.packet(command, value: value)
        return packet.withUnsafeMutableBytes { writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) } == 0
    }
}
