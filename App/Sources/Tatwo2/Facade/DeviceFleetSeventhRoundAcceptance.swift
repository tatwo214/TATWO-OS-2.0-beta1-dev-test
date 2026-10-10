#if DEBUG
import Darwin
import Foundation

/// Synthetic roots, pinned fixture peers and real production policy/transport only.
enum DeviceFleetSeventhRoundAcceptance {
    static func run(scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake, DeviceFactionKind, String?, Bool) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W187R7_FAIL_" + name) }
            print("W187R7 PASS " + name)
        }
        if scenario == "memory-endpoints" {
            try DeviceFleetFifthRoundAcceptance.run(scenario: "memory-endpoints", make: make, pair: pair)
            print("W187R7 SUMMARY failures=0"); return
        }
        let a = try make(90, true), b = try make(91, false)
        if ["native-paths", "sandbox-plan"].contains(scenario) {
            var env = a.env
            let base = a.registry.root.deletingLastPathComponent()
            env["HOME"] = base.appendingPathComponent("synthetic-home").path
            env["TATWO2_ENGINES_ROOT"] = base.appendingPathComponent("shared-engines").path
            env["TATWO2_OS_UPSTREAM_PATH"] = base.appendingPathComponent("os/os-upstream.md").path
            env["TATWO2_OS_SOCKET"] = ProcessInfo.processInfo.environment["TATWO2_OS_SOCKET"]
            env["TATWO2_BROWSER_SOCKET"] = ProcessInfo.processInfo.environment["TATWO2_BROWSER_SOCKET"]
            let policy = ManagedEnginePolicy(thread: UUID(), environment: env)
            let paths = ["live/bots/sample/memory/profile.md", "live/bots/sample/instructions.md",
                         "live/document.json", "live/cli-scrollback/sample.txt", "live/cli-sessions.json",
                         "live/cli-workbench.json", "live/memory-usage.json", "os/os-upstream.md",
                         "os/os-upstream.md.bak-synthetic", "os/os-upstream.kept-generated.md",
                         "skills/sample/SKILL.md", "future-private-store/private.txt"]
                .map { base.appendingPathComponent($0) }
                + [a.dispatch.entry.root.appendingPathComponent("memory/private.md"),
                   a.dispatch.entry.root.appendingPathComponent("user.md"),
                   a.dispatch.entry.root.appendingPathComponent("future-memory/private.md"),
                   base.appendingPathComponent("managed-engines/other-thread/engines/codex/auth.json")]
            for path in paths {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic private marker\n".utf8).write(to: path)
            }
            let cwd = try policy.workDirectory(for: LiveThreadRecord(), project: nil)
            if scenario == "sandbox-plan" {
                let launch: [String: Any] = ["arguments": policy.sandboxArguments(executable: "/usr/bin/env", arguments: [], writableDirectory: cwd),
                    "environment": try policy.prepareEnvironment(["PATH": "/usr/bin:/bin", "TMUX": "synthetic-unrestricted-server"]),
                    "cwd": cwd, "privatePaths": paths.map(\.path)]
                let artifacts = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"]!
                try JSONSerialization.data(withJSONObject: launch).write(to: URL(fileURLWithPath: artifacts).appendingPathComponent("sandbox-plan.json"))
            } else {
                var leaked: [String] = []
                for path in paths {
                    let read = try DeviceDispatch.run("/usr/bin/sandbox-exec", policy.sandboxArguments(executable: "/bin/cat", arguments: [path.path]))
                    let write = try DeviceDispatch.run("/usr/bin/sandbox-exec", policy.sandboxArguments(executable: "/usr/bin/tee", arguments: [path.path]), input: Data("synthetic overwrite\n".utf8))
                    if read.0 == 0 || write.0 == 0 { leaked.append(path.lastPathComponent) }
                    else { print("W187R7 PASS CARDS-01-read-and-write-denied-" + path.path.replacingOccurrences(of: base.path + "/", with: "")) }
                }
                try check("CARDS-01-every-private-store-denied-" + leaked.joined(separator: ","), leaked.isEmpty)
                let command = "printf synthetic > ordinary.txt && /bin/cat ordinary.txt"
                let ordinary = try DeviceDispatch.run("/usr/bin/sandbox-exec", policy.sandboxArguments(executable: "/bin/sh", arguments: ["-c", command]), directory: URL(fileURLWithPath: cwd))
                try check("CARDS-04-no-memory-cannot-use-App-terminal-relay", !DeviceFleetCapabilities.allows(method: "cli_send", capabilities: ["dispatch", "files"]))
                try check("CARDS-03-ordinary-read-write-needs-no-approval", ordinary.0 == 0 && String(decoding: ordinary.1, as: UTF8.self) == "synthetic")
            }
            print("W187R7 SUMMARY failures=0"); return
        }
        try a.fleet.bootstrapPrimary(host: a.host)
        try pair(a, b, .owner, nil, false)
        b.dispatch.synchronize()
        switch scenario {
        case "projection-errors":
            let peer = a.registry.list().first { $0.id == b.id }!
            defer { DeviceFleetGate.fixtureExchange = nil }
            for reason in ["unsupported_method", "unknown_method", "method_not_found", "projection_unsupported", "malformed"] {
                DeviceFleetGate.fixtureExchange = { _, _, _ in
                    (0, "Authenticated to synthetic peer\n", try JSONSerialization.data(withJSONObject: ["ok": false, "error": reason]))
                }
                do { _ = try DeviceFleetGate.call(peer: peer, method: "dispatch_ack", params: [:], registry: a.registry); throw DeviceFleetError.signature }
                catch { try a.fleet.recordDeliveryProblem(b.id, error: error) }
                let lines = try DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted()
                try check("CARDS-02-real-gate-refusal-visible-" + reason, lines.contains { $0.contains("更新") && $0.contains("新版權限") && $0.contains("fixture 91") })
                let snapshot = try DeviceFleetUISnapshot(payload: a.fleet.current(), localID: a.id, deliveryProblems: a.fleet.read().deliveryProblems ?? [:])
                try check("CARDS-02-warning-belongs-to-refusing-row-" + reason, snapshot.deliveryWarnings[b.id]?.contains("這台的 App 需要更新才能收新版權限") == true && snapshot.deliveryWarnings[a.id] == nil)
                try a.fleet.recordDeliveryProblem(b.id, error: RemoteHostLinkError.remoteError(reason))
                try check("CARDS-02-full-channel-refusal-also-visible-" + reason, a.fleet.read().deliveryProblems?[b.id] == "projection_refused")
            }
            for error in [DeviceFleetGate.CallError.unreachable, .appUnavailable, .rejected("fixture_temporary_error"), .rejected("fleet_malformed"), .rejected("local_storage_failed"), .rejected("invalid_ssh_proof")] {
                try a.fleet.recordDeliveryProblem(b.id, error: error)
                try check("CARDS-02-temporary-or-security-error-is-not-version-warning", DeviceFleetStore.deliveryWarnings(roster: a.fleet.current()?.roster, problems: a.fleet.read().deliveryProblems ?? [:]).values.sorted().isEmpty)
            }
            try a.fleet.recordDeliveryProblem(b.id, error: nil)
            try check("CARDS-02-success-clears-warning", a.fleet.read().deliveryProblems?[b.id] == nil)
        case "memory-errors":
            for reason in ["memory_bundle_unavailable", "invalid_memory_bundle", "invalid_memory_bundle_tree"] {
                try check("MEM-02-export-direction-" + reason, TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.rejected(reason)).contains("從主設備拉來的記憶驗不過"))
            }
            try check("MEM-02-transferred-is-actionable", TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.primaryTransferred).contains("會自動找新主"))
            try check("MEM-02-grant-denial-is-plain", TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.rejected("fleet_gate_denied")).contains("記憶權限"))
            try check("MEM-02-unknown-is-direction-neutral", TatwoMemorySyncEngine.short(DeviceFleetGate.CallError.rejected("fixture_unknown")) == "原因不明")
        case "memory-fetch":
            let p = EngineMemoryPaths(home: a.dispatch.root.appendingPathComponent("home").path, entryRoot: a.dispatch.entry.root)
            let q = EngineMemoryPaths(home: b.dispatch.root.appendingPathComponent("home").path, entryRoot: b.dispatch.entry.root)
            for paths in [p, q] { try EngineMemoryLinks.createMemoryFolder(paths.memory) }
            try TatwoMemorySyncAcceptance.note(p.memory, "primary.md", title: "Synthetic", body: "Synthetic memory.")
            try TatwoMemorySyncAcceptance.note(q.memory, "secondary.md", title: "Synthetic", body: "Synthetic memory.")
            let primary = TatwoMemorySyncEngine(paths: { p }, dispatch: a.dispatch)
            let bridge = OSAgentBridge.fleetFixtureBridge(); bridge.fixtureMemory(primary)
            var calls = 0
            let channel = DeviceDispatch(entry: b.dispatch.entry, registry: b.registry, environment: b.env, rpc: { _, method, params in
                calls += 1
                let reply = try bridge.fixtureHandle(dispatch: a.dispatch, method: method, params: params)
                guard reply["ok"] as? Bool == true else { throw DeviceFleetError.malformed }
                return reply["result"] as! [String: Any]
            })
            var fetches = 0
            let secondary = TatwoMemorySyncEngine(paths: { q }, dispatch: channel, fetch: { _, _ in fetches += 1; throw DeviceFleetGate.CallError.appUnavailable })
            try check("MEM-02-sleep-after-target-is-offline", secondary.runOnce(.manual).state == .offline && fetches == 1)
            var roster = try a.fleet.current()!.roster!
            for index in roster.edges.indices { roster.edges[index].capabilities.removeAll { $0 == "memory" } }
            try a.fleet.publish(&roster); try b.fleet.synchronizeEnvelope(a.fleet.envelope()!)
            let before = calls
            let denied = secondary.runOnce(.manual)
            try check("MEM-02-no-grant-does-not-sync-or-warn", calls == before && denied.error == nil && denied.line.isEmpty)
        case "secondary-leave":
            let staff = try make(92, false)
            let main = try a.fleet.current()!.roster!.groups.first { $0.type == .main }!.id
            try pair(a, staff, .sandbox, main, true)
            try staff.fleet.requestLeave()
            b.dispatch.synchronize()
            let before = try staff.fleet.current()!.revision
            var roster = try a.fleet.current()!.roster!
            for index in roster.edges.indices where roster.edges[index].to == .device(staff.id) { roster.edges[index].capabilities = ["files"] }
            try a.fleet.publish(&roster)
            b.dispatch.synchronize()
            try check("CARDS-06-secondary-forwards-projection", staff.fleet.current()!.revision > before)
            try check("CARDS-06-secondary-has-no-unapprovable-leave-request", b.fleet.read().leaveRequests.isEmpty)
            a.dispatch.synchronize()
            try check("CARDS-06-primary-can-still-receive-leave-request", a.fleet.read().leaveRequests.contains(staff.id))
        default: throw DeviceFleetError.malformed
        }
        print("W187R7 SUMMARY failures=0")
    }
}
#endif
