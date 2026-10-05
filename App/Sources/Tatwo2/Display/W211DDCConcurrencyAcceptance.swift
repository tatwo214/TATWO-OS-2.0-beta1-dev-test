#if DEBUG
import Foundation

@MainActor enum W211DDCConcurrencyAcceptance {
    static func run() async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("W211DDC \(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let transport = W211SlowReadTransport()
        let channel = DDCArm64(transport: transport)
        _ = await channel.read(.brightness)
        let reading = Task { await channel.read(.volume) }
        while transport.activeReads == 0 { await Task.yield() }
        let writing = Task { await channel.set(75, command: .brightness, smooth: false) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(transport.writeCount == 0, "suspended read transaction excludes hardware writes")
        _ = await reading.value
        check(await writing.value == .written && !transport.overlap,
              "one physical channel permits only one in-flight transaction")
        let draining = Task { await channel.read(.brightness) }
        while transport.activeReads == 0 { await Task.yield() }
        await channel.invalidate()
        check(transport.activeReads == 0, "invalidation drains suspended read before replacing channel")
        check(await draining.value == nil, "invalidated suspended read never updates cache")
        let count = transport.writeCount
        check(await channel.set(90, command: .brightness) == .failed && transport.writeCount == count,
              "invalidation prevents late hardware writes")
        print("W211DDC SUMMARY failures=\(failures)")
        return failures == 0
    }
}

private final class W211SlowReadTransport: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reading = 0
    private var writes = 0
    private var overlapping = false
    private var current: UInt16 = 50
    var activeReads: Int { lock.withLock { reading } }
    var writeCount: Int { lock.withLock { writes } }
    var overlap: Bool { lock.withLock { overlapping } }
    func read(_ command: DDCCommand) async -> DDCValue? {
        lock.withLock { reading += 1; overlapping = overlapping || reading > 1 }
        try? await Task.sleep(nanoseconds: 60_000_000)
        return lock.withLock { reading -= 1; return DDCValue(current: current, maximum: 100) }
    }
    func write(_ command: DDCCommand, value: UInt16) -> Bool {
        lock.withLock {
            overlapping = overlapping || reading > 0
            writes += 1; current = value
            return true
        }
    }
}
#endif
