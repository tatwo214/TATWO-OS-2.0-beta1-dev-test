#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum DeviceFleetFourteenthRoundAcceptance {
    static func run(scenario: String, a: DeviceFleetAcceptance.Fake, b: DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R14_FAIL_" + name) }
            print("W187R14 PASS " + name)
        }
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        if scenario == "r14-begin" {
            var local = try a.dispatch.identity()
            var record = PrimaryTransfer.Record(from: b.id, to: a.id, oldEpoch: 0, epoch: 1, participants: [a.id], sourceDeviceID: b.id, sourceRoot: b.dispatch.entry.root.path, hashes: try b.dispatch.snapshot().mapValues(DeviceDispatch.hash), signingName: "fixture release")
            record.committed = true
            local.transfer = record
            try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
            let done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
            Task { @MainActor in
                defer { done.signal() }
                let session = DeviceFlowSession(environment: a.env, pasteboard: NSPasteboard(name: .init(UUID().uuidString)), rpc: { _, _, _ in throw DeviceFleetGate.CallError.appUnavailable })
                defer { session.close() }
                do {
                    try session.open(.transfer); await session.refresh()
                    let pending = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowCard(session: session), artifact: "r14-begin-pending")
                    try check("SEQ-01-pending-hides-start-with-reason", !pending.contains("與現任主設備相同") && pending.contains("先完成①所有設備的讀回"))
                    var ready = try a.dispatch.identity(); ready.transfer!.epochACKs = [a.id]
                    try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(ready)
                    await session.refresh()
                    let text = try await DeviceFleetEleventhRoundAcceptance.render(DeviceFlowCard(session: session), artifact: "r14-begin-ready")
                    try check("SEQ-01-readback-done-shows-start-before-brain-release", text.contains("與現任主設備相同") && ready.transfer?.complete == false)
                } catch { errors.fail(error) }
            }
            guard done.wait(timeout: .now() + 40) == .success else { throw DeviceFleetError.malformed }
            if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
        }
        if scenario.hasPrefix("r14-dispatch-") {
            let fm = FileManager.default
            let peer = b.registry.list().first { $0.id == a.id }!
            let first = try a.dispatch.offer(to: b.id)
            _ = try b.dispatch.apply(first, authenticatedPrimary: peer)
            for path in first.files.keys where scenario == "r14-dispatch-readonly" {
                let mode = try fm.attributesOfItem(atPath: b.dispatch.entry.root.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber
                try check("ROSTER-01-readonly-" + path, mode?.intValue == 0o444)
            }
            let notes = b.dispatch.entry.root.appendingPathComponent("note")
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            try Data("synthetic removed note".utf8).write(to: notes.appendingPathComponent("removed.md"))
            let archive = b.dispatch.entry.root.appendingPathComponent("archive")
            try fm.createSymbolicLink(at: archive, withDestinationURL: a.dispatch.root)
            let bundle = try a.dispatch.offer(to: b.id)
            do { _ = try b.dispatch.apply(bundle, authenticatedPrimary: peer); throw DeviceFleetError.signature }
            catch { try check("SEQ-03-archive-failure-keeps-applied", (error as? DeviceDispatch.Failure)?.reason == "unsafe_archive" && b.dispatch.receipts()[a.id]?.phase == "applied") }
            try fm.removeItem(at: archive)
            try check("SEQ-03-written-files-survive-archive-failure", Data(contentsOf: b.dispatch.entry.constitution) == bundle.files["os.md"])
            let retry = try a.dispatch.offer(to: b.id)
            try check("SEQ-03-fresh-sequence-retry-converges", b.dispatch.apply(retry, authenticatedPrimary: peer).phase == "converged")
        }
        if scenario == "r14-wake" {
            // A restricted synthetic owner edge forces notifications through the same
            // stdio transport as fetch/ACK. No real SSH path can be selected here.
            var graph = try a.fleet.current()!.roster!
            graph.edges = [.init(from: .device(a.id), to: .device(b.id), direction: .mutual, capabilities: ["dispatch"])]
            try a.fleet.publish(&graph)
            try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
            let primary = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env, retireBackup: { _ in })
            let secondary = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, retireBackup: { _ in })
            try check("ROSTER-03-fixture-notifications-use-owned-gate",
                      RemoteHostLink(environment: a.env).requiresFleetGate(a.registry.list().first { $0.id == b.id }!)
                      && RemoteHostLink(environment: b.env).requiresFleetGate(b.registry.list().first { $0.id == a.id }!))
            let bridge = OSAgentBridge.fleetFixtureBridge(), calls = HandsLocked<[[String]]>([])
            let previousExchange = DeviceFleetGate.fixtureExchange
            DeviceFleetGate.fixtureExchange = { root, peer, frame in
                guard [a.registry.root.path, b.registry.root.path].contains(root),
                      [a.id, b.id].contains(peer.id), let method = frame["method"] as? String,
                      let params = frame["params"] as? [String: Any] else { throw DeviceFleetError.malformed }
                let response: [String: Any]
                if method == "dispatch_wake" {
                    // This peer is a transport fixture, not another wake generator.
                    response = ["ok": true, "result": ["scheduled": true]]
                } else {
                    let target = peer.id == a.id ? a.dispatch : b.dispatch
                    response = try OSAgentBridge.fleetFixtureBridge().fixtureHandle(dispatch: target, method: method, params: params)
                }
                let bytes = try JSONSerialization.data(withJSONObject: response) + Data([10])
                calls.update { $0.append([root, peer.id, method]) }
                return (0, "Authenticated to synthetic peer\n", bytes)
            }
            defer { DeviceFleetGate.fixtureExchange = previousExchange }
            func waitFor(_ condition: () -> Bool) throws {
                let deadline = Date().addingTimeInterval(5)
                while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                guard condition() else { throw DeviceDispatch.Failure(reason: "W187R14_FAIL_ROSTER-03-real-align-timeout") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            primary.align()
            try waitFor { !calls.get().isEmpty }
            try check("ROSTER-03-transport-observes-real-primary-align-notification",
                      calls.get() == [[a.registry.root.path, b.id, "dispatch_wake"]])
            calls.set([])
            let response = try bridge.fixtureHandle(dispatch: primary, method: "dispatch_wake", params: [:], caller: .app)
            Thread.sleep(forTimeInterval: 0.3)
            try check("ROSTER-03-ordinary-primary-wake-does-not-align-or-notify", response["ok"] as? Bool == true && calls.get().isEmpty)
            let secondaryResponse = try bridge.fixtureHandle(dispatch: secondary, method: "dispatch_wake", params: [:], caller: .app)
            try waitFor { secondary.receipts()[a.id]?.phase == "converged" && calls.get().contains([b.registry.root.path, a.id, "dispatch_ack"]) }
            try check("ROSTER-03-secondary-wake-fetches-and-ACKs-through-real-align",
                      secondaryResponse["ok"] as? Bool == true && calls.get() == [
                        [b.registry.root.path, a.id, "dispatch_fetch"], [b.registry.root.path, a.id, "dispatch_ack"]])
            calls.set([])
            var local = try primary.identity()
            var record = PrimaryTransfer.Record(from: b.id, to: a.id, oldEpoch: 0, epoch: 1, participants: [a.id], sourceDeviceID: b.id, sourceRoot: b.dispatch.entry.root.path, hashes: try b.dispatch.snapshot().mapValues(DeviceDispatch.hash), signingName: "fixture release")
            record.committed = true; local.transfer = record
            try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
            let pendingResponse = try bridge.fixtureHandle(dispatch: primary, method: "dispatch_wake", params: [:], caller: .app)
            try waitFor { !calls.get().isEmpty }
            try check("ROSTER-03-pending-new-primary-wake-fetches-former-primary-only",
                      pendingResponse["ok"] as? Bool == true && calls.get() == [[a.registry.root.path, b.id, "dispatch_fetch"]])
            calls.set([])
            local.transfer!.constitution = true; local.transfer!.sourceDeviceID = a.id; local.transfer!.sourceRoot = a.dispatch.entry.root.path
            try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
            let switchedResponse = try bridge.fixtureHandle(dispatch: primary, method: "dispatch_wake", params: [:], caller: .app)
            Thread.sleep(forTimeInterval: 0.3)
            try check("ROSTER-03-switched-primary-wake-does-not-align", switchedResponse["ok"] as? Bool == true && calls.get().isEmpty)
        }
        if scenario.hasPrefix("r14-second") {
            var local = try a.dispatch.identity()
            var record = PrimaryTransfer.Record(from: a.id, to: b.id, oldEpoch: 0, epoch: 1, participants: [b.id], sourceDeviceID: b.id, sourceRoot: b.dispatch.entry.root.path, hashes: try a.dispatch.snapshot().mapValues(DeviceDispatch.hash), signingName: "fixture release")
            record.committed = true; record.epochACKs = [b.id]; record.constitution = true; record.constitutionRevision = 1
            local.transfer = record
            try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(local)
            if scenario == "r14-second-update" {
                let calls = HandsLocked(0)
                let dispatch = DeviceDispatch(entry: a.dispatch.entry, registry: a.registry, environment: a.env, retireBackup: { _ in }, rpc: { _, _, _ in
                    calls.set(calls.get() + 1); throw DeviceDispatch.Failure(reason: "fixture_unexpected_rpc")
                })
                let before = try dispatch.identity(), start = Date()
                try PrimaryTransfer.update(dispatch, constitution: true)
                try dispatch.updateTransfer(constitution: true)
                try check("SEQ-02-completed-second-returns-immediately-without-RPC", Date().timeIntervalSince(start) < 1 && calls.get() == 0 && dispatch.identity() == before)
                var promoted = before
                promoted.transfer!.from = b.id; promoted.transfer!.to = a.id; promoted.transfer!.participants = [a.id]; promoted.transfer!.epochACKs = [a.id]
                promoted.transfer!.sourceDeviceID = a.id; promoted.transfer!.sourceRoot = a.dispatch.entry.root.path
                try DeviceIdentityStore.forLocalDevice(entry: a.dispatch.entry, pairedDeviceID: a.id).write(promoted)
                let promotedStart = Date()
                try dispatch.updateTransfer(constitution: true)
                try check("SEQ-02-completed-new-primary-returns-without-recovery", Date().timeIntervalSince(promotedStart) < 1 && calls.get() == 0 && dispatch.identity() == promoted)
                let text = DeviceFleetReason.plain(DeviceDispatch.Failure(reason: "transfer_work_readback_pending"))
                try check("SEQ-02-work-readback-pending-has-actionable-Chinese", text.contains("工作檔") && text.contains("App") && text.contains("②") && !text.contains("transfer_work_readback_pending"))
            } else {
                let preview = local, done = DispatchSemaphore(value: 0), errors = DeviceFleetFourthRoundAcceptance.Results()
                Task { @MainActor in
                    defer { done.signal() }
                    do {
                        let host = NSHostingView(rootView: DeviceFlowTransferPanel(preview: preview).frame(width: 1000, height: 1100))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.contentView = host
                        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                        func buttons(_ view: NSView) -> [DeviceFlowPhysicalButton.Native] { (view as? DeviceFlowPhysicalButton.Native).map { [$0] } ?? view.subviews.flatMap(buttons) }
                        try check("SEQ-02-completed-second-button-disabled", buttons(host).contains { $0.title == "② 比對凍結的正本並切換正本派發來源" && !$0.isEnabled })
                    } catch { errors.fail(error) }
                }
                guard done.wait(timeout: .now() + 30) == .success else { throw DeviceFleetError.malformed }
                if let error = errors.failures.first { throw DeviceDispatch.Failure(reason: error) }
            }
        }
        print("W187R14 SUMMARY failures=0")
    }
}
#endif
