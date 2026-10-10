#if DEBUG
import AppKit
import SwiftUI
import Vision

/// Disposable identities and real signatures. No live SSH, engine or remote devices.
enum DeviceFlowAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let rootPath = environment["TATWO_STAGING_ROOT"], let artifactsPath = environment["TATWO2_SELFTEST_ARTIFACTS"],
              [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !EngineLogin(environment: environment).status(for: $0).isLoggedIn }) else {
            throw DeviceFleetError.malformed
        }
        let root = URL(fileURLWithPath: rootPath).appendingPathComponent("fleet-fixture")
        let artifacts = URL(fileURLWithPath: artifactsPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let initialRevocationHooks = DeviceFleetRevocation.testHooks
        DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
        defer { DeviceFleetRevocation.testHooks = initialRevocationHooks }
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1; if !condition { failures += 1 }
            print("W187DM \(condition ? "PASS" : "FAIL") \(label)")
        }
        func refused(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) } catch { check(true, label) }
        }
        let ids = (1...4).map { String(format: "%08x-3333-4333-8333-333333333333", $0) }
        func member(_ index: Int, group: String, role: DeviceFleetRole) throws -> DeviceFleetMember {
            let key = root.appendingPathComponent("fixture-\(index)-client").path
            let host = root.appendingPathComponent("fixture-\(index)-host").path
            for path in [key, host] {
                guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", path]).0 == 0 else {
                    throw DeviceFleetError.missingKey
                }
            }
            let client = try String(contentsOfFile: key + ".pub", encoding: .utf8)
            let hostKey = try String(contentsOfFile: host + ".pub", encoding: .utf8)
            return .init(id: ids[index], name: "fixture \(index)", factionID: group, role: role,
                         clientKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: client),
                         hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostKey),
                         clientPublicKey: client, hostPublicKey: hostKey,
                         endpoints: [.init(kind: .lan, host: "192.0.2.\(index + 1)")], user: "fixture")
        }
        let members = try [member(0, group: "main", role: .primary), member(1, group: "main", role: .secondary),
                           member(2, group: "sub", role: .primary), member(3, group: "main", role: .sandbox)]
        var env = environment
        env["TATWO_OS_ROOT"] = root.appendingPathComponent("entry").path
        env["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("live").path
        env["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("authorized_keys").path
        env["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("known_hosts").path
        env["TATWO2_SSH_KEY_PATH"] = root.appendingPathComponent("fixture-0-client").path
        env["TATWO2_SSH_HOST_KEY_PUB"] = root.appendingPathComponent("fixture-0-host.pub").path
        let entry = TatwoEntry(environment: env)
        try FileManager.default.createDirectory(at: entry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: ids[0], name: "fixture", hardwareModel: "fixture", role: .primary,
                           epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: entry.deviceJSON)
        let clipboard = NSPasteboard.withUniqueName()
        let session = DeviceFlowSession(environment: env, pasteboard: clipboard, rpc: { _, _, _ in throw DeviceFleetError.unknownMember })
        defer { session.close() }
        let groups = [DeviceFleetGroup(id: "main", name: "開發 fixture", type: .main, primaryDeviceID: ids[0], managerDisplayName: "fixture"),
                      DeviceFleetGroup(id: "sub", name: "職員 fixture", type: .sub, primaryDeviceID: ids[2], parentGroupID: "main", managerDisplayName: "fixture")]
        let roster = DeviceFleetRoster(version: 1, primaryID: ids[0], epoch: 1, groups: groups, devices: members,
                                       edges: DeviceFleetRoster.defaults(groups: groups, devices: members))
        let trust = DeviceFleetTrust(localID: ids[0], primaryID: ids[0], epoch: 1, pinnedPrimaryKey: members[0].clientKeyFingerprint!, kind: .owner)
        var state = try session.store.read(); state.trust = trust; try session.store.save(state)
        try session.store.accept(DeviceFleetEnvelope.issue(.init(roster: roster), environment: env))
        await session.refresh()
        check(session.canInviteSandbox, "R3-PAIR-06-primary-can-invite-sandbox")
        if environment["TATWO2_W187_R7_DM"] == "1" {
            var isolated = env
            isolated["TATWO_OS_ROOT"] = root.appendingPathComponent("r7-dm-entry").path
            isolated["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("r7-dm-live").path
            isolated["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("r7-dm-authorized").path
            isolated["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("r7-dm-known").path
            let isolatedEntry = TatwoEntry(environment: isolated)
            try FileManager.default.createDirectory(at: isolatedEntry.root, withIntermediateDirectories: true)
            try Data(contentsOf: entry.deviceJSON).write(to: isolatedEntry.deviceJSON)
            let primary = DeviceFlowSession(environment: isolated, pasteboard: clipboard, rpc: { _, _, _ in throw DeviceFleetError.unknownMember })
            defer { primary.close() }
            var journal = try primary.store.read(); journal.trust = trust; try primary.store.save(journal)
            try primary.store.accept(DeviceFleetEnvelope.issue(.init(roster: roster), environment: isolated))
            var next = roster; next.revoked.append(ids[3]); try primary.store.publish(&next)
            _ = try primary.store.claimRevocationDelivery(ids[3])
            await primary.refresh()
            check(primary.pendingDeliveryLines.isEmpty, "R7-CARDS-05-revocation-retries-do-not-flash-in-DM")
            check(try primary.store.read().deliveryProblems?[ids[3]] == nil, "R7-CARDS-05-no-warning-before-send")
            try primary.store.recordDeliveryProblem(ids[3], error: DeviceFleetGate.CallError.unreachable)
            let snapshot = DeviceFleetUISnapshot(payload: try primary.store.current(), localID: ids[0], deliveryProblems: try primary.store.read().deliveryProblems ?? [:])
            check(snapshot.pendingDeliveryLines.contains { $0.contains("還沒收到撤銷") && $0.contains("私訊框") }, "R7-CARDS-05-settings-warning-offers-action")
            journal = try primary.store.read(); journal.leaveRequests = [ids[2]]; try primary.store.save(journal)
            await primary.refresh(); check(primary.leaveRequests == [ids[2]], "R7-CARDS-06-primary-sees-leave-request")
            journal.trust!.localID = ids[1]; try primary.store.save(journal)
            let secondary = DeviceFlowSession(environment: isolated, pasteboard: clipboard, rpc: { _, _, _ in throw DeviceFleetError.unknownMember })
            await secondary.refresh()
            check(secondary.leaveRequests.isEmpty, "R7-CARDS-06-secondary-hides-unapprovable-request")
            secondary.close()
        }
        // Full MAIN owners exercise an interactive method through the same real socket/caller checkpoint as dispatch.
        let ownerEngine = ChatLiveEngine(store: ChatLiveStore(root: URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!)), environment: env)
        defer { ownerEngine.shutdownAll() }
        let ownerBots = BotLibrary(root: URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!), skillsRoot: root.appendingPathComponent("owner-skills"))
        await ownerBots.ready()
        let ownerModel = ChatPageModel(environment: env, botCoreFixture: (ownerEngine, BotStore(library: ownerBots)))
        let ownerThread = ownerEngine.newThread(in: nil, title: "Synthetic owner conversation")
        let ownerBridge = OSAgentBridge.fleetFixtureBridge(); ownerBridge.fixtureModel(ownerModel)
        var ownerSenderEnv = env
        ownerSenderEnv["TATWO_OS_ROOT"] = root.appendingPathComponent("owner-sender-entry").path
        ownerSenderEnv["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("owner-sender-live").path
        ownerSenderEnv["TATWO2_SSH_KEY_PATH"] = root.appendingPathComponent("fixture-1-client").path
        let ownerSenderEntry = TatwoEntry(environment: ownerSenderEnv)
        try FileManager.default.createDirectory(at: ownerSenderEntry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: ids[1], name: "Synthetic owner", hardwareModel: "fixture", role: .secondary,
                           epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: ownerSenderEntry.deviceJSON)
        let ownerSender = DeviceDispatch(entry: ownerSenderEntry, registry: DeviceRegistry(environment: ownerSenderEnv), environment: ownerSenderEnv)
        let ownerReceiver = DeviceDispatch(entry: entry, registry: session.store.registry, environment: env)
        let ownerParams: [String: Any] = ["threadID": ownerThread.uuidString]
        let ownerHandshake = try ownerSender.signed(method: "transcript", payload: ownerParams, recipient: ids[0])
        let ownerReply = try await Task.detached { try ownerBridge.fixtureHandle(dispatch: ownerReceiver, method: "transcript", params: ownerParams, handshake: ownerHandshake) }.value
        check(ownerReply["ok"] as? Bool == true && (ownerReply["result"] as? [String: Any])?["messages"] as? [Any] != nil,
              "R3-GATE-01-owner-transcript-nil-fingerprint-through-handle")
        let unsignedOwner = try await Task.detached { try ownerBridge.fixtureHandle(dispatch: ownerReceiver, method: "transcript", params: ownerParams) }.value
        check(unsignedOwner["ok"] as? Bool == false, "R3-GATE-01-owner-transcript-without-handshake-refused")
        let callerID = UUID()
        func call(_ method: String, _ params: [String: Any] = [:], caller: OSSocketCaller? = nil) throws -> [String: Any] {
            try AssistantFleetTools.perform(method, params: params, caller: caller ?? .engine(callerID),
                                            assistantThread: callerID, session: session)
        }
        for method in AssistantFleetTools.methods.sorted() {
            for caller in [OSSocketCaller.externalAI, .ssh, .other(pid: nil), .app, .helper, .job(callerID)] {
                for staging in [false, true] {
                    check(!OSAgentBridge.allows(caller: caller, method: method,
                                               params: ["callerThreadID": callerID.uuidString], staging: staging),
                          "bridge-refuses-\(caller.label)-\(method)-staging-\(staging)")
                }
                refused("handler-refuses-\(caller.label)-\(method)") { _ = try call(method, caller: caller) }
            }
            check(OSAgentBridge.allows(caller: .engine(callerID), method: method, params: [:], staging: false),
                  "bridge-routes-engine-\(method)-to-assistant-validation")
            refused("other-thread-refuses-\(method)") { _ = try call(method, caller: .engine(UUID())) }
            refused("missing-assistant-refuses-\(method)") {
                _ = try AssistantFleetTools.perform(method, params: [:], caller: .engine(callerID), assistantThread: nil, session: session)
            }
        }
        check(session.transferCandidates.map(\.id) == [ids[1]], "transfer-main-only-no-sub-managed-sandbox")
        check(DeviceFlowUserAction.current() == nil, "no-programmatic-user-confirmation-authority")
        refused("remote-self-confirmation-refused") { _ = try call("fleet_confirm", ["userConfirmed": true], caller: .ssh) }
        refused("external-ai-refused") { _ = try call("fleet_overview", caller: .externalAI) }
        refused("other-thread-refused") { _ = try call("fleet_open_card", ["card": "invite"], caller: .engine(UUID())) }
        refused("job-refused") { _ = try call("fleet_overview", caller: .job(callerID)) }
        refused("caller-thread-parameter-cannot-spoof") { _ = try call("fleet_overview", ["callerThreadID": UUID().uuidString]) }
        refused("open-card-cannot-supply-confirmation") { _ = try call("fleet_open_card", ["card": "transfer", "userConfirmed": true]) }
        _ = try call("fleet_open_card", ["card": "menu"])
        check(session.active == .menu && session.window == nil, "cards-open-without-model-or-minting-code")
        session.setCell(0, text: "ab-1 c中2d!")
        check(session.code == "AB1C2D" && session.codeCells.count == 6, "six-cells-uppercase-ascii-only")
        session.setCell(2, text: "!"); check(session.codeCells[2].isEmpty, "illegal-input-removed")
        session.codeCells = Array(repeating: "", count: 6)
        let at = Date()
        let code = try TatwoDevicePairingCodeEngineV1.mint(createdBy: ids[0], authorityPrimary: ids[0], authorityEpoch: 1, now: at, seed: "A1B2C3")
        refused("expired-code-refused-by-production-engine") {
            try TatwoDevicePairingCodeEngineV1.validate(seed: code.seed, against: code, now: at.addingTimeInterval(300))
        }
        let consumed = try TatwoDevicePairingCodeEngineV1.consume(seed: code.seed, record: code, expectedPrimary: ids[0], expectedEpoch: 1, now: at)
        refused("one-use-code-replay-refused") { try TatwoDevicePairingCodeEngineV1.validate(seed: code.seed, against: consumed, now: at) }
        session.fixtureCard(.invite, window: .init(code: code.seed, expiresAt: at.addingTimeInterval(2), address: "192.0.2.10:18815"))
        session.copyCode()
        check(session.clipboard.copied == .code && clipboard.string(forType: .string) == "A1B2C3", "copy-code-does-not-copy-address")
        session.tick(at: at.addingTimeInterval(3))
        check(session.window == nil && session.clipboard.copied == nil && clipboard.string(forType: .string) == nil && !session.discovery.advertised, "countdown-clears-code-qr-discovery-and-clipboard")
        refused("managed-pair-requires-peer-local-consent") {
            _ = try DevicePairingClient(environment: env).pair(host: "192.0.2.10", port: 18815, code: "A1B2C3", name: "fixture", kind: .managed)
        }
        let advertisement = DevicePairingDiscovery.sessionTag(code.seed)
        check(advertisement != code.seed && advertisement.count == 64
              && advertisement != DevicePairingDiscovery.sessionTag(code.seed), "bonjour-advertises-independent-random-not-code")
        check(DevicePairingDiscovery.resolvedHost("fixture.example.") == "fixture.example"
              && DevicePairingDiscovery.resolvedHost("fixture..example.") == nil, "bonjour-terminal-dot-normalized-without-widening-host-validation")
        var secretRoster = roster
        secretRoster.groups[0].name = "A1B2C3 192.0.2.10"
        secretRoster.devices[0].name = members[0].clientPublicKey!
        let safe = try AssistantFleetTools.overview(.init(roster: secretRoster))
        let encoded = String(data: try JSONSerialization.data(withJSONObject: safe), encoding: .utf8)!
        check(!encoded.contains("A1B2C3") && !encoded.contains("192.0.2.") && !encoded.contains("SHA256:")
              && !encoded.contains("ssh-ed25519") && !encoded.contains("fixture"), "tool-overview-redacts-code-qr-keys-fingerprints-addresses-and-names")
        let filtered = try AssistantFleetTools.overview(.init(slice: roster.slice(for: ids[2])))
        check(filtered["baseVersion"] == nil && filtered["writable"] as? Bool == false, "managed-overview-no-main-version")
        session.close()
        let before = try session.store.envelope()
        let revokeReply = try call("fleet_propose", ["baseVersion": 1, "changes": [["op": "revoke_device", "target": "d2"]]])
        check(try session.store.envelope() == before && session.pending?.preview.revoked.contains(ids[1]) == true
              && revokeReply["confirmed"] as? Bool == false, "DM-03-revoke-tool-never-signs-before-click")
        let revokeWire = try JSONSerialization.data(withJSONObject: revokeReply)
        check(!String(decoding: revokeWire, as: UTF8.self).contains("192.0.2.")
              && !String(decoding: revokeWire, as: UTF8.self).contains("SHA256:"), "DM-03-revoke-proposal-hides-endpoints-and-fingerprints")
        session.cancelProposal()
        let reply = try call("fleet_propose", ["baseVersion": 1, "changes": [["op": "set_edge", "from": "g1", "to": "g2", "direction": "oneway", "capabilities": ["files"]]]])
        check(try session.store.envelope() == before && reply["confirmed"] as? Bool == false && session.pending != nil,
              "fleet-propose-does-not-confirm-or-sign")
        let proposalReply = String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
        check(!proposalReply.contains("A1B2C3") && !proposalReply.contains("192.0.2.") && !proposalReply.contains("SHA256:")
              && !proposalReply.contains("ssh-ed25519"), "tool-proposal-output-is-secret-free")
        check(session.previewLines.contains { $0.contains("操作畫面") && $0.contains("原本：允許 → 改成：不允許") }, "preview-describes-capability-before-after")
        check(session.previewLines.count == 3 && session.previewLines.allSatisfy { !$0.contains("看檔案") && !$0.contains("讀它的記憶") && !$0.contains("單向 →") },
              "preview-only-changed-capabilities-no-unchanged-direction")
        func preview(_ changes: [DeviceFleetChange], in graph: DeviceFleetRoster = roster) throws -> [String] {
            DeviceFlowPreview.lines(before: graph, proposal: try DeviceFleetGraphService.propose(roster: graph, actor: ids[0], changes: changes))
        }
        let sameEdge = roster.edges.first { $0.from == .group("main") && $0.to == .group("sub") }!
        check(try preview([.setEdge(sameEdge), .renameGroup(id: "main", name: groups[0].name),
                           .renameDevice(id: ids[1], name: members[1].name), .setVisibility(groupID: "sub", showMainPrimary: false),
                           .setManagerDisplayName(groupID: "sub", name: groups[1].managerDisplayName)]).isEmpty,
              "preview-noop-edge-names-visibility-manager-empty")
        check(try preview([.renameGroup(id: "main", name: "sample"), .renameGroup(id: "main", name: groups[0].name)]).isEmpty,
              "preview-reverted-edits-empty")
        var directionEdge = roster.edges.first { $0.from == .device(ids[0]) && $0.to == .device(ids[1]) }!
        directionEdge.direction = .oneway
        let directionRows = try preview([.setEdge(directionEdge)])
        check(directionRows.count == 1 && directionRows[0].contains("原本：互通 → 改成：單向：fixture 0〔開發 fixture · MAIN · 我的主設備")
              && directionRows[0].contains("控制 fixture 1〔開發 fixture · MAIN · 我的副設備"),
              "preview-direction-plain-controller-to-peer")
        var disconnected = roster
        let edgeIndex = disconnected.edges.firstIndex(of: sameEdge)!
        disconnected.edges[edgeIndex].direction = .none
        disconnected.edges[edgeIndex].capabilities = []
        check(try preview([.setEdge(sameEdge)], in: disconnected).count == 7,
              "preview-disconnected-to-connected-shows-direction-and-enabled-capabilities")
        refused("tool-cannot-pass-user-confirmation-flag") {
            _ = try call("fleet_propose", ["baseVersion": 1, "changes": [], "userConfirmed": true])
        }
        refused("tool-cannot-transfer-through-proposal") {
            _ = try call("fleet_propose", ["baseVersion": 1, "changes": [["op": "transfer", "target": "d2"]]])
        }
        // Real stdio MCP → socket peer classification → bridge → native handler, with disposable roots.
        let liveRoot = root.appendingPathComponent("mcp-live")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: environment)
        defer { engine.shutdownAll() }
        guard let assistantID = engine.doc.assistantThreadID else { throw DeviceFleetError.malformed }
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(root: liveRoot)))
        OSAgentBridge.shared.configureCallerTest(model: model, manager: BackgroundJobManager(root: liveRoot))
        OSAgentBridge.shared.startSecurityTestListener()
        for _ in 0..<50 where !OSAgentBridge.shared.isListening { try await Task.sleep(nanoseconds: 100_000_000) }
        check(OSAgentBridge.shared.isListening, "mcp-real-socket-listener-ready")
        let node = String(decoding: try DeviceDispatch.run("/usr/bin/which", ["node"]).1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { checkout.deleteLastPathComponent() }
        let server = checkout.appendingPathComponent("Engines/os-mcp/server.mjs")
        let sharedSession = DeviceFlowSession.shared
        let sharedEntry = TatwoEntry(environment: environment)
        try DeviceIdentity(deviceID: ids[0], name: "fixture", hardwareModel: "fixture", role: .primary,
                           epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: sharedEntry.deviceJSON)
        var sharedState = try sharedSession.store.read()
        sharedState.trust = trust
        sharedState.envelope = try DeviceFleetEnvelope.issue(.init(roster: roster), environment: env)
        try sharedSession.store.save(sharedState) // Still verified by readGraph; does not install SSH keys.
        let originalRoots = OSSocketCaller.rootsProvider
        defer { OSSocketCaller.rootsProvider = originalRoots; DeviceFlowSession.shared.close() }
        let mcpCallers: [(String, OSSocketCaller.Root?)] = [
            ("assistant", .engine(assistantID)), ("other-thread", .engine(UUID())),
            ("external-ai", .externalAI), ("tap-or-external-mcp", nil), ("background", .job(assistantID)),
        ]
        for (label, caller) in mcpCallers {
            let process = Process(), input = Pipe()
            let outputURL = root.appendingPathComponent("mcp-\(label).jsonl")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            process.executableURL = URL(fileURLWithPath: node); process.arguments = [server.path]
            var processEnv = environment
            processEnv["TATWO2_THREAD_ID"] = assistantID.uuidString // forged by every refused caller
            process.environment = processEnv; process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let pid = process.processIdentifier
            guard let start = OSSocketCaller.processStartTime(pid) else { throw DeviceFleetError.malformed }
            OSSocketCaller.rootsProvider = {
                var roots = originalRoots?() ?? [:]
                if let caller { roots[pid] = .init(root: caller, startTime: start) }
                return roots
            }
            func toolRequest(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
                ["id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
            }
            let requests: [[String: Any]] = [
                ["id": 1, "method": "tools/list"],
                toolRequest(2, "fleet_overview"),
                toolRequest(3, "fleet_open_card", ["card": "menu"]),
                toolRequest(4, "fleet_propose", ["baseVersion": 1, "changes": []]),
                toolRequest(5, "fleet_propose", ["baseVersion": 1, "changes": [["op": "rename_group", "target": "g2", "name": "MCP sample"]]]),
            ]
            for request in requests {
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
                input.fileHandleForWriting.write(Data([10]))
            }
            try input.fileHandleForWriting.close()
            await Task.detached { process.waitUntilExit() }.value
            try output.close()
            OSSocketCaller.rootsProvider = originalRoots
            let replies = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            check(process.terminationStatus == 0 && replies.count == 5, "mcp-\(label)-five-replies")
            guard replies.count == 5 else { continue }
            let list = (replies[0]["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            let names = Set(list.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("fleet_") })
            if label == "assistant" {
                check(names == AssistantFleetTools.methods, "mcp-assistant-lists-exactly-three-no-confirmation-tool")
                for reply in replies[1...2] {
                    check((reply["result"] as? [String: Any])?["isError"] as? Bool != true, "mcp-assistant-dispatch-\(reply["id"]!)")
                }
                let proposalError = String(describing: replies[3])
                check(proposalError.contains("fleet_invalid_input"), "mcp-assistant-proposal-reaches-native-validation")
                let contents = (replies[4]["result"] as? [String: Any])?["content"] as? [[String: Any]]
                let text = contents?.first?["text"] as? String ?? ""
                let proposal = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                check(proposal?["confirmed"] as? Bool == false && proposal?["status"] as? String == "awaiting_user_confirmation",
                      "mcp-assistant-valid-proposal-awaits-user")
                check(sharedSession.active == .permissions && sharedSession.pending != nil
                      && sharedSession.previewLines.contains { $0.contains("MCP sample") }, "mcp-proposal-reaches-shared-dm-preview")
                check(try sharedSession.store.readGraph()?.roster == roster, "mcp-proposal-never-signs-or-mutates-roster")
                check(!text.contains("MCP sample") && !text.contains("fixture"), "mcp-proposal-response-hides-custom-names")
            } else {
                check(names.isEmpty, "mcp-\(label)-no-fleet-tools-in-list")
                for reply in replies[1...] {
                    check(String(describing: reply).contains("unknown_tool:fleet_"), "mcp-\(label)-cannot-call-\(reply["id"]!)")
                }
            }
        }
        let themeScope = TatwoThemeSelfTestScope()
        themeScope.use(.fable5)
        defer { themeScope.restore() }
        func png(_ name: String, _ view: some View, height: CGFloat = 1100) throws {
            guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: .init(width: 400, height: height)),
                  let data = rendered.bitmap.representation(using: .png, properties: [:]) else {
                check(false, "png-\(name)"); return
            }
            defer { rendered.close() }
            if name == "restoration-confirmation", let image = rendered.bitmap.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                let unwrappedText = text.filter { !$0.isNewline }
                check(unwrappedText.contains("不寫檔"), "R3-PAIR-05-restoration-original-file-rights-visible-without-truncation")
                let roleLabels = text.split(separator: "\n").filter { $0.hasPrefix("將恢復") && $0.contains("角色") }
                check(roleLabels.count == 1,
                      "R3-PAIR-05-restoration-role-confirmation-shown-once")
                try text.write(to: artifacts.appendingPathComponent("restoration-confirmation.txt"), atomically: true, encoding: .utf8)
            }
            if name == "invite" {
                check(DMSecretCodeView.liveViews.contains { $0.qrImage != nil && $0.window === rendered.window }, "qr-renders-in-native-secret-view")
                check(WindowCaptureShield.shared.isShielding(rendered.window), "sensitive-card-window-blocks-computer-use-capture")
                let token = DMSecretCodeView.holdForCapture()
                check(DMSecretCodeView.liveViews.filter { $0.window === rendered.window }.allSatisfy { $0.isHidden }, "code-and-qr-suppressed-during-dm-capture")
                DMSecretCodeView.releaseCapture(token)
            }

            try data.write(to: artifacts.appendingPathComponent(name + ".png"))
            check(data.count > 1000, "png-\(name)")
            print("W187DM ARTIFACT \(artifacts.appendingPathComponent(name + ".png").path)")
        }
        func cardPNG(_ name: String, height: CGFloat = 1100) throws {
            try png(name, VStack(alignment: .leading, spacing: 14) {
                Text("TATWO 助理").font(.headline)
                DeviceFlowCard(session: session)
                Spacer(minLength: 0)
            }.padding(16).background(TatwoActivePalette.current.canvasBase), height: height)
        }
        try cardPNG("permissions-preview")
        await session.confirmFromCard(.fixture())
        check(try session.store.readGraph()?.roster?.version == 1 && session.pending != nil, "DM-02-wrong-authority-cannot-confirm")
        let changedCardAuthority = DeviceFlowUserAction.fixture(binding: session.cardBinding)
        session.disconnectAllOnRevoke.toggle()
        await session.confirmFromCard(changedCardAuthority)
        check(try session.store.readGraph()?.roster?.version == 1 && session.pending != nil, "DM-02-changed-card-invalidates-authority")
        session.disconnectAllOnRevoke = false
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        check(try session.store.readGraph()?.roster?.version == 2 && session.pending == nil, "card-confirmation-signs-only-after-user-button")
        let after = try session.store.envelope()
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        check(try session.store.envelope() == after, "confirmation-cannot-replay")
        _ = try session.propose([.setEdge(directionEdge)])
        try cardPNG("permissions-direction-preview")
        session.cancelProposal()
        _ = try call("fleet_propose", ["baseVersion": 2, "changes": [["op": "rename_group", "target": "g2", "name": "sample"]]])
        let cancelledToken = session.pending!.id
        session.cancelProposal()
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        check(try session.store.envelope() == after, "cancel-never-signs")
        refused("cancelled-backend-token-destroyed") { _ = try session.store.confirm(cancelledToken, userConfirmed: true) }
        refused("locked-reverse-arrow-refused") {
            _ = try call("fleet_propose", ["baseVersion": 2, "changes": [["op": "set_edge", "from": "g2", "to": "g1", "direction": "oneway", "capabilities": ["files"]]]])
        }
        for kind in DeviceFlowKind.allCases {
            session.close(); session.fixtureCard(kind)
            if [.invite, .managed, .sandbox].contains(kind) {
                session.fixtureCard(kind, window: .init(code: "A1B2C3", expiresAt: Date().addingTimeInterval(290), address: "192.0.2.10:18815"))
            }
            if kind == .managed { session.selectedGroup = "new"; session.newGroupName = "sample 職員"; session.managerName = "sample 公司" }
            if kind == .progress { session.fixtureProgress(exchanged: true, version: nil, connected: false) }
            try cardPNG(kind.rawValue)

        }
        session.fixtureCard(.progress); session.fixtureProgress(exchanged: true, version: 2, connected: true)
        try cardPNG("progress-complete", height: 600)
        session.close(); session.fixtureCard(.menu)
        let defaultsName = "ai.tatwo.fixture.w187dm.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let dm = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false })
        dm.select(.assistant)
        try png("logged-out-chip", GlobalDMComposer(store: dm, placeholder: "問助理任何事…", isRunning: false, canSend: false, initiallyFocused: false), height: 170)
        check(!dm.hasContentToSend && session.active == .menu, "equipment-chip-and-card-independent-of-model-login")
        // d2 behavior tests run against fake keys/roots only; no real SSH transport is started.
        check(DeviceFleetName.clean("Boss\u{202E}\u{200B}\n\t\u{7} Mac") == "Boss Mac", "ROSTER-08-control-bidi-zero-width-removed")
        check(DeviceFleetName.clean(String(repeating: "設", count: 200)).utf8.count <= 160, "ROSTER-08-visible-name-bounded")
        check(DeviceFleetName.unique("fixture 1", used: ["fixture 1", "fixture 1 (2)"]) == "fixture 1 (3)", "ROSTER-08-duplicates-get-suffix")
        var duplicate = roster; duplicate.devices[1].name = duplicate.devices[0].name
        refused("ROSTER-08-signed-duplicate-name-refused") { try duplicate.validate() }
        var bidi = roster; bidi.devices[1].name = "boss\u{202E}"
        refused("ROSTER-08-signed-bidi-name-refused") { try bidi.validate() }
        var staffBefore = roster
        staffBefore.devices[1].groupID = "sub"
        staffBefore.edges = DeviceFleetRoster.defaults(groups: groups, devices: staffBefore.devices)
        refused("DM-06-local-sub-to-main-refused") {
            _ = try DeviceFleetGraphService.propose(roster: staffBefore, actor: ids[0], changes: [.moveDevice(id: ids[1], groupID: "main")])
        }
        refused("DM-06-local-sandbox-to-main-refused") {
            _ = try DeviceFleetGraphService.propose(roster: roster, actor: ids[0], changes: [.moveDevice(id: ids[3], groupID: "main")])
        }
        let promotion = DeviceFleetPendingChange(id: UUID(), baseVersion: 1, actor: ids[0], changes: [.moveDevice(id: ids[1], groupID: "main")], preview: roster)
        let gains = DeviceFlowPreview.lines(before: staffBefore, proposal: promotion)
        check(gains.contains { $0.contains("新增控制權") && $0.contains(members[1].name) && $0.contains(members[3].name) && $0.contains("派工") }, "DM-06-group-inheritance-reports-every-new-controller")
        check(gains.contains { $0.contains("身分變更") && $0.contains("重新配對") }, "DM-06-owner-promotion-warning")
        let demotion = DeviceFleetPendingChange(id: UUID(), baseVersion: 1, actor: ids[0], changes: [.moveDevice(id: ids[1], groupID: "sub")], preview: staffBefore)
        check(DeviceFlowPreview.lines(before: roster, proposal: demotion).contains { $0.contains("身分變更") && $0.contains("不再能讀") }, "DM-06-owner-demotion-warning")
        session.close()
        // Restoration is a separate physical confirmation, and displays the retained per-device arrows.
        var restoreEnv = env
        restoreEnv["TATWO_OS_ROOT"] = root.appendingPathComponent("restore-entry").path
        restoreEnv["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("restore-live").path
        restoreEnv["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("restore-authorized").path
        restoreEnv["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("restore-known").path
        restoreEnv["TATWO2_PAIRING_HOST"] = "127.0.0.1"
        let restoreEntry = TatwoEntry(environment: restoreEnv)
        try FileManager.default.createDirectory(at: restoreEntry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: ids[0], name: "fixture", hardwareModel: "fixture", role: .primary, epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: restoreEntry.deviceJSON)
        let restoreSession = DeviceFlowSession(environment: restoreEnv, pasteboard: NSPasteboard.withUniqueName(), rpc: { _, _, _ in throw DeviceFleetError.unknownMember })
        defer { restoreSession.close() }
        var restoreRoster = roster
        restoreRoster.revoked = [ids[2]]
        for i in restoreRoster.edges.indices where restoreRoster.edges[i].from == .group("main") && restoreRoster.edges[i].to == .group("sub") { restoreRoster.edges[i].capabilities = ["files"] }
        restoreRoster.edges.append(.init(from: .device(ids[0]), to: .device(ids[2]), direction: .oneway, capabilities: ["dispatch"]))
        let originalRestoreRoster = restoreRoster
        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_DM"] == "1" {
            var rejoined = restoreRoster.devices.first { $0.id == ids[1] }!
            restoreRoster.revoked.append(rejoined.id)
            rejoined.id = "eeeeeeee-3333-4333-8333-333333333333"; rejoined.name = "active re-paired label"
            restoreRoster.devices.append(rejoined)
            // Same public key in a retained revoked row and the active ordinary re-pair.
        }
        var restoreState = try restoreSession.store.read(); restoreState.trust = trust; try restoreSession.store.save(restoreState)
        try restoreSession.store.accept(DeviceFleetEnvelope.issue(.init(roster: restoreRoster), environment: env))
        await restoreSession.refresh(); restoreSession.fixtureCard(.managed)
        if ProcessInfo.processInfo.environment["TATWO2_W187_R4_DM"] == "1" {
            restoreSession.fixtureCard(.invite)
            check(!restoreSession.revokedCandidates.contains { $0.id == ids[1] }, "R5-CARDS-05-active-repaired-key-excludes-old-restoration-candidate")
            let reusedKeyHost = DevicePairingHost(registry: restoreSession.store.registry, environment: restoreEnv)
            refused("R5-CARDS-05-active-repaired-key-refused-before-code") {
                _ = try reusedKeyHost.startPairingWindow(restoringDeviceID: ids[1])
            }
            reusedKeyHost.cancelPairingWindow()
            restoreSession.restoringDeviceID = ids[1]
            check(restoreSession.selectedGroup == "sub", "R4-PAIR-N3-owner-restore-does-not-pollute-managed-group")
            restoreSession.restoringDeviceID = ""; restoreSession.fixtureCard(.managed)
            let invitation = restoreSession.invitationConsentLines.joined(separator: "\n")
            check(invitation.contains("active re-paired label"), "R4-PAIR-N1-invite-survives-duplicate-fingerprint-uses-active-label")
            restoreSession.restoringDeviceID = ids[2]
            check(restoreSession.invitationConsentLines.joined(separator: "\n").contains("active re-paired label"),
                  "R4-PAIR-N1-restoration-survives-duplicate-fingerprint-uses-active-label")
            restoreRoster = originalRestoreRoster; restoreRoster.version += 1
            try restoreSession.store.accept(DeviceFleetEnvelope.issue(.init(roster: restoreRoster), environment: env))
            await restoreSession.refresh()
        }
        restoreSession.restoringDeviceID = ids[2]
        let restorationLines = restoreSession.invitationConsentLines.joined(separator: "\n")
        check(restoreSession.selectedGroup == "sub" && restorationLines.contains("fixture 2") && restorationLines.contains("將恢復的角色") && restorationLines.contains("自己建立的對話") && !restorationLines.contains("安裝更新"), "R3-PAIR-05-restore-card-original-group-role-and-arrows")
        check(restoreSession.window == nil, "R3-PAIR-02-selecting-identity-does-not-mint-code")
        await restoreSession.generateFromCard(.fixture())
        check(restoreSession.window == nil, "R3-PAIR-02-restoration-invalid-physical-confirmation-refused")
        try png("restoration-confirmation", DeviceFlowCard(session: restoreSession).padding(16).background(TatwoActivePalette.current.canvasBase), height: 1050)
        restoreSession.close()
        check(restoreSession.restoringDeviceID.isEmpty, "R3-PAIR-02-close-clears-restoration")
        restoreSession.fixtureCard(.managed); restoreSession.restoringDeviceID = ids[2]
        try restoreSession.open(.invite)
        check(restoreSession.restoringDeviceID.isEmpty, "R3-PAIR-02-changing-card-clears-restoration")
        restoreSession.fixtureCard(.managed); restoreSession.restoringDeviceID = ids[2]
        await restoreSession.generateFromCard(.fixture(binding: restoreSession.cardBinding))
        check(restoreSession.window != nil, "R3-PAIR-02-physical-confirmation-mints-dedicated-code")
        restoreSession.close(); restoreSession.fixtureCard(.managed); restoreSession.restoringDeviceID = ids[2]
        restoreRoster = try restoreSession.store.current()!.roster!
        restoreRoster.revoked = []; restoreRoster.version += 1
        try restoreSession.store.accept(DeviceFleetEnvelope.issue(.init(roster: restoreRoster), environment: env))
        await restoreSession.refresh()
        check(restoreSession.restoringDeviceID.isEmpty && restoreSession.message.contains("這台已恢復"), "R3-PAIR-02-stale-restoration-selection-cleared-and-explained")
        var staffEnvironment = env
        staffEnvironment["TATWO_OS_ROOT"] = root.appendingPathComponent("staff-consent-entry").path
        staffEnvironment["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("staff-consent-live").path
        staffEnvironment["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("staff-consent-authorized").path
        staffEnvironment["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("staff-consent-known").path
        let staffEntry = TatwoEntry(environment: staffEnvironment)
        try FileManager.default.createDirectory(at: staffEntry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: ids[2], name: "fixture staff", hardwareModel: "fixture", role: .secondary,
                           epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: staffEntry.deviceJSON)
        let staffSession = DeviceFlowSession(environment: staffEnvironment, pasteboard: NSPasteboard.withUniqueName())
        defer { staffSession.close() }
        var staffState = try staffSession.store.read()
        staffState.trust = .init(localID: ids[2], primaryID: ids[0], epoch: 1, pinnedPrimaryKey: members[0].clientKeyFingerprint!, kind: .managed)
        staffState.envelope = nil; staffState.consentCeiling = nil
        try staffSession.store.save(staffState)
        check(!staffSession.canInviteSandbox, "R3-PAIR-06-managed-secondary-has-no-sandbox-invitation")
        let slice = try roster.slice(for: ids[2])
        check(DeviceFleetStore.consentLines(slice).count == slice.controllers.count && DeviceFleetStore.consentLines(slice).allSatisfy { $0.contains("安裝更新") }, "DM-04-consent-enumerates-actual-controllers-and-capabilities")
        let none = try staffSession.store.effectiveControllers(slice.controllers)
        check(none.isEmpty, "DM-04-new-managed-device-has-no-unconsented-controls")
        staffState.envelope = try DeviceFleetEnvelope.issue(.init(slice: slice), environment: env)
        try staffSession.store.save(staffState)
        try staffSession.store.reconcile(.init(slice: slice))
        check(try staffSession.store.pendingConsent() != nil && slice.controllers.allSatisfy {
            staffSession.store.registry.fleetHasAuthorizedFingerprint($0.clientKeyFingerprint)
                && (try? staffSession.store.methodAllowed(fingerprint: $0.clientKeyFingerprint, method: "document_inspect")) == false
                && (try? staffSession.store.methodAllowed(fingerprint: $0.clientKeyFingerprint, method: "dispatch_ack")) == true
        }, "DM-04-initial-consent-only-allows-system-transport")
        let digestSession = DeviceFlowSession(environment: staffEnvironment, pasteboard: NSPasteboard.withUniqueName())
        defer { digestSession.close() }
        check(try !digestSession.approveJoinedConsent(expected: String(repeating: "0", count: 64))
              && digestSession.awaitingInitialConsent && digestSession.message.contains("權限已改變")
              && staffSession.store.effectiveControllers(slice.controllers).isEmpty,
              "R3-PAIR-05-join-digest-mismatch-never-auto-approves")
        refused("DM-04-stale-consent-refused") { try staffSession.store.approveConsent(revision: slice.revision + 1, controllers: slice.controllers) }
        var forgedControllers = slice.controllers; forgedControllers[0].capabilities.append("memory")
        refused("DM-04-forged-consent-refused") { try staffSession.store.approveConsent(revision: slice.revision, controllers: forgedControllers) }
        try staffSession.store.approveConsent(revision: slice.revision, controllers: slice.controllers)
        check(try staffSession.store.pendingConsent() == nil && staffSession.store.effectiveControllers(slice.controllers) == slice.controllers, "DM-04-local-consent-opens-exact-ceiling")
        var expandedSlice = slice; expandedSlice.revision += 1
        for index in expandedSlice.controllers.indices { expandedSlice.controllers[index].capabilities.append("memory") }
        let expandedPayload = DeviceFleetPayload(slice: expandedSlice)
        var nextStaffState = try staffSession.store.read()
        nextStaffState.envelope = try DeviceFleetEnvelope.issue(expandedPayload, environment: env)
        try staffSession.store.save(nextStaffState); try staffSession.store.reconcile(expandedPayload)
        check(try staffSession.store.pendingConsent() != nil && staffSession.store.effectiveControllers(expandedSlice.controllers).allSatisfy { !$0.capabilities.contains("memory") }, "DM-04-later-memory-gain-awaits-local-consent")
        check(try !staffSession.store.methodAllowed(fingerprint: expandedSlice.controllers[0].clientKeyFingerprint, method: "memory_list"), "DM-04-live-rpc-gate-intersects-ceiling")
        let restarted = DeviceFleetStore(registry: staffSession.store.registry, environment: env)
        check(try restarted.effectiveControllers(expandedSlice.controllers) == slice.controllers, "DM-04-ceiling-persists-across-restart")
        staffSession.fixtureCard(.permissions); await staffSession.refresh()
        try png("consent-expanded", DeviceFlowCard(session: staffSession).padding(16).background(TatwoActivePalette.current.canvasBase), height: 800)
        await staffSession.approveConsentFromCard(.fixture(), revision: expandedSlice.revision)
        check(try staffSession.store.pendingConsent() != nil, "DM-02-invalid-authority-cannot-raise-ceiling")
        await staffSession.approveConsentFromCard(.fixture(binding: staffSession.cardBinding), revision: expandedSlice.revision)
        check(try staffSession.store.pendingConsent() == nil && staffSession.store.methodAllowed(fingerprint: expandedSlice.controllers[0].clientKeyFingerprint, method: "memory_list"), "DM-04-physical-card-approves-new-memory")
        // Fifth ruling: A is SUB primary only as a display role; colleague B keeps all assistant work local.
        var colleagueEnv = staffEnvironment
        colleagueEnv["TATWO_OS_ROOT"] = root.appendingPathComponent("colleague-entry").path
        colleagueEnv["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("colleague-live").path
        colleagueEnv["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("colleague-authorized").path
        colleagueEnv["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("colleague-known").path
        colleagueEnv["TATWO2_SSH_KEY_PATH"] = root.appendingPathComponent("fixture-1-client").path
        colleagueEnv["TATWO2_SSH_HOST_KEY_PUB"] = root.appendingPathComponent("fixture-1-host.pub").path
        if ProcessInfo.processInfo.environment["TATWO2_W187_R6_DM"] == "1" {
            colleagueEnv["TATWO2_ENGINES_ROOT"] = root.appendingPathComponent("r6-shared-engines").path
        }
        let colleagueEntry = TatwoEntry(environment: colleagueEnv)
        try FileManager.default.createDirectory(at: colleagueEntry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: ids[1], name: "fixture B", hardwareModel: "fixture", role: .secondary, epoch: 1, primaryDeviceID: ids[0], updatedAt: Date()).encoded().write(to: colleagueEntry.deviceJSON)
        let colleagueRegistry = DeviceRegistry(environment: colleagueEnv)
        let colleagueStore = DeviceFleetStore(registry: colleagueRegistry, environment: colleagueEnv)
        var colleagueRoster = roster; colleagueRoster.devices[1].groupID = "sub"; colleagueRoster.devices[1].role = .secondary
        colleagueRoster.edges = DeviceFleetRoster.defaults(groups: colleagueRoster.groups, devices: colleagueRoster.devices)
        let colleagueSlice = try colleagueRoster.slice(for: ids[1])
        var colleagueState = try colleagueStore.read()
        colleagueState.trust = .init(localID: ids[1], primaryID: ids[0], epoch: 1, pinnedPrimaryKey: members[0].clientKeyFingerprint!, kind: .managed)
        colleagueState.envelope = try DeviceFleetEnvelope.issue(.init(slice: colleagueSlice), environment: env)
        colleagueState.consentCeiling = Dictionary(uniqueKeysWithValues: colleagueSlice.controllers.map { ($0.clientKeyFingerprint, $0.capabilities) })
        try colleagueStore.save(colleagueState); try colleagueStore.reconcile(.init(slice: colleagueSlice))
        // Insert an obsolete colleague route so this is not a vacuous empty-registry test.
        _ = try colleagueRegistry.add(id: ids[2], name: "fixture A", host: "192.0.2.3", user: "fixture", publicKeyFingerprint: members[2].hostKeyFingerprint!, hostKeyFingerprint: members[2].hostKeyFingerprint, clientKeyFingerprint: members[2].clientKeyFingerprint)
        let colleagueEngine = ChatLiveEngine(store: ChatLiveStore(root: URL(fileURLWithPath: colleagueEnv["TATWO2_LIVE_ROOT"]!)), environment: colleagueEnv)
        defer { colleagueEngine.shutdownAll() }
        let colleagueBots = BotLibrary(root: URL(fileURLWithPath: colleagueEnv["TATWO2_LIVE_ROOT"]!), skillsRoot: root.appendingPathComponent("colleague-skills"))
        await colleagueBots.ready()
        let colleagueModel = ChatPageModel(environment: colleagueEnv, botCoreFixture: (colleagueEngine, BotStore(library: colleagueBots)))
        colleagueModel.fixtureConfigureRemoteSessions()
        if case .local = colleagueModel.assistantPlacement { check(true, "R3-DM-01-designated-A-B-assistant-placement-local") }
        else { check(false, "R3-DM-01-designated-A-B-assistant-placement-local") }
        check(colleagueModel.remoteSessions.isEmpty, "R3-DM-02-stale-colleague-no-remote-session-or-SSH")
        final class AttemptLog: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func add() { lock.withLock { count += 1 } }
            var total: Int { lock.withLock { count } }
        }
        let attempts = AttemptLog(); PeerUpdateSource.fixtureCommandSink = { _ in attempts.add() }
        let colleagueRecord = colleagueRegistry.list().first { $0.id == ids[2] }!
        let peerOffers = await PeerUpdateSource.discover([colleagueRecord], environment: colleagueEnv)
        var cachedEntry = PeerUpdateEntry(); cachedEntry.files["TATWO-OS-app.zip"] = "synthetic"
        let cachedOffer = PeerUpdateSource.Offer(device: colleagueRecord, host: "192.0.2.3", entries: ["v2.0.21": cachedEntry])
        let publicArchiveName = "TATWO-OS-app.zip"
        let cachedPull = try await PeerUpdateSource.pull(cachedOffer, tag: "v2.0.21", name: publicArchiveName, folder: root, environment: colleagueEnv)
        PeerUpdateSource.fixtureCommandSink = nil
        check(peerOffers.isEmpty && cachedPull == nil && attempts.total == 0, "R3-DM-02-discovery-and-cached-pull-have-zero-SSH-attempts")
        let status = await Task.detached { RemoteHostLink(environment: colleagueEnv).queryDeviceStatus(device: colleagueRecord) }.value
        check(status.reason == "fleet_staff_local", "R3-DM-02-direct-status-probe-skipped-before-SSH")
        if case .local = colleagueModel.distillRoute() { check(true, "R3-DM-01-B-distill-route-local") }
        else { check(false, "R3-DM-01-B-distill-route-local") }
        let outbox = colleagueModel.primaryOutbox!
        await outbox.ready()
        check(outbox.enqueueClassification(deviceID: ids[2], id: UUID(), action: "approve", summary: "synthetic") != nil, "R3-DM-01-stale-A-work-queued")
        await colleagueModel.clearNonOwnerPrimaryWork()
        check(outbox.items.isEmpty, "R3-DM-01-stale-A-work-removed")
        // Actual SSH bridge path: dispatch-only controller may only mutate its own created threads.
        let colleagueDispatch = DeviceDispatch(entry: colleagueEntry, registry: colleagueRegistry, environment: colleagueEnv)
        let controllerDispatch = DeviceDispatch(entry: entry, registry: session.store.registry, environment: env)
        let restrictedBridge = OSAgentBridge.fleetFixtureBridge(); restrictedBridge.fixtureModel(colleagueModel)
        restrictedBridge.configureCallerTest(model: colleagueModel, manager: BackgroundJobManager(root: root.appendingPathComponent("controller-background")))
        let existing = colleagueEngine.newThread(in: nil, title: "staff-owned")
        let colleagueAssistantID = colleagueEngine.doc.assistantThreadID!
        func controllerCall(_ method: String, _ params: [String: Any], caller: OSSocketCaller = .ssh) async throws -> [String: Any] {
            let handshake = caller == .ssh ? try controllerDispatch.signed(method: method, payload: params, recipient: ids[1]) : nil
            return try await Task.detached { try restrictedBridge.fixtureHandle(dispatch: colleagueDispatch, method: method, params: params, handshake: handshake, fingerprint: caller == .ssh ? members[0].clientKeyFingerprint : nil, caller: caller) }.value
        }
        check(try await controllerCall("send_message", ["threadID": existing.uuidString, "text": "forbidden"])["ok"] as? Bool == false, "R3-DM-03-existing-staff-thread-send-refused-through-handle")
        check(try await controllerCall("stop_thread", ["threadID": colleagueAssistantID.uuidString])["ok"] as? Bool == false, "R3-DM-03-assistant-stop-refused-through-handle")
        check(try await controllerCall("stop_thread", ["threadID": existing.uuidString])["ok"] as? Bool == false, "R3-DM-03-existing-staff-thread-stop-refused-through-handle")
        let created = try await controllerCall("new_thread", ["title": "controller-owned"])
        let newID = UUID(uuidString: (created["result"] as? [String: Any])?["threadID"] as? String ?? "")
        check(created["ok"] as? Bool == true && newID != nil, "R3-DM-03-controller-new-thread-through-handle")
        if let newID {
            var sent: [UUID] = []
            restrictedBridge.fixtureSend = { id, _ in sent.append(id) }
            for method in ["send_message", "send_message_with_options"] {
                let before = colleagueEngine.transcript(for: newID).count
                var params: [String: Any] = ["threadID": newID.uuidString, "text": "synthetic", "model": "chatgpt-tap:fixture-model"]
                if method == "send_message_with_options" { params["reasoningEffort"] = "tap-heavy" }
                let response = try await controllerCall(method, params)
                check(response["ok"] as? Bool == false && String(describing: response).contains("managed_chatgpt_tap_forbidden"),
                      "W221b-bridge-\(method)-managed-TAP-refused")
                check(sent.isEmpty && !colleagueEngine.tapSelfTestHasRunner(newID), "W221b-bridge-\(method)-no-launch-or-runner")
                check(colleagueEngine.transcript(for: newID).count == before + 1
                      && colleagueEngine.transcript(for: newID).last?.text == "受管對話不能使用 ChatGPT TAP，因為它會使用這台的私人 ChatGPT 帳號與記憶。",
                      "W221b-bridge-\(method)-one-inline-reason")
            }
            check(try await controllerCall("send_message", ["threadID": newID.uuidString, "text": "Synthetic owned turn", "memoryStrength": "deep"])["ok"] as? Bool == true,
                  "R5-CARDS-01-default-controller-own-send-allowed-without-memory")
            check(sent == [newID] && colleagueEngine.threadRecord(newID)?.memoryStrength == "off",
                  "R5-CARDS-01-send-cannot-enable-ungranted-memory")
            check(try await controllerCall("send_message", ["threadID": existing.uuidString, "text": "forbidden"])["ok"] as? Bool == false && sent == [newID],
                  "R5-CARDS-01-other-creator-send-still-denied")
            if ProcessInfo.processInfo.environment["TATWO2_W187_R6_DM"] == "1" {
                let marker = "synthetic-private-preference-R6"
                try Data(marker.utf8).write(to: colleagueEntry.root.appendingPathComponent("user.md"))
                let runtime = OSUpstream.overridePath
                try Data(("## Synthetic safe rules\n\n## 使用者偏好（入口 user.md）\n" + marker).utf8).write(to: URL(fileURLWithPath: runtime))
                let privateMemory = colleagueEntry.root.appendingPathComponent("memory")
                try FileManager.default.createDirectory(at: privateMemory, withIntermediateDirectories: true)
                try Data(marker.utf8).write(to: privateMemory.appendingPathComponent("private.md"))
                let policy = ManagedEnginePolicy(thread: newID, environment: colleagueEnv)
                let work = URL(fileURLWithPath: try policy.workDirectory(for: LiveThreadRecord(), project: nil))
                let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Engines/codex-sidecar/sidecar.mjs")
                let key = "tatwo2.sidecarPath.codex", previous = UserDefaults.standard.object(forKey: key)
                UserDefaults.standard.set(script.path, forKey: key)
                defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
                let login = Data("{\"synthetic\":true}".utf8)
                try DeviceDispatchSafeFile.write(login, url: root.appendingPathComponent("r6-shared-engines/codex/auth.json"))
                var launch: ([String], [String: String], String)?
                ClaudeSidecar.fixtureLaunch = { _, arguments, environment, cwd in launch = (arguments, environment, cwd) }
                defer { ClaudeSidecar.fixtureLaunch = nil }
                check(colleagueEngine.fixtureStartSidecar(newID, engine: .codex), "R6-CARDS-N1-real-launch-through-admitted-thread")
                try await DeviceFleetEighthRoundAcceptance.waitForLaunch { launch != nil }
                check(launch != nil && !launch!.0.joined(separator: " ").contains(marker), "R6-CARDS-N1-controlled-launch-excludes-user-preferences")
                if let launch, let profile = launch.0.firstIndex(of: "-p") {
                    for child in [false, true] {
                        let process = Process(), output = Pipe()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                        let file = privateMemory.appendingPathComponent("private.md").path
                        process.arguments = Array(launch.0.prefix(profile + 2)) + (child ? ["/bin/sh", "-c", "/bin/cat '" + file + "'"] : ["/bin/cat", file])
                        process.environment = launch.1; process.currentDirectoryURL = URL(fileURLWithPath: launch.2)
                        process.standardOutput = output; process.standardError = FileHandle.nullDevice
                        try process.run(); process.waitUntilExit()
                        let bytes = output.fileHandleForReading.readDataToEndOfFile()
                        check(process.terminationStatus != 0 && !String(decoding: bytes, as: UTF8.self).contains(marker), "R6-CARDS-N1-parent-and-native-child-cannot-read-memory-" + String(child))
                    }
                } else { check(false, "R6-CARDS-N1-production-launch-has-sandbox") }
                check(launch?.2 != NSHomeDirectory() && launch != nil, "R6-CARDS-N1-isolated-work-directory")
                colleagueEngine.shutdownAll()
                let previousApprover = restrictedBridge.backgroundCommandApprover
                restrictedBridge.backgroundCommandApprover = { _, _, _ in true }
                let backgroundCapture = work.appendingPathComponent("r6-background-read.txt")
                let command = "/bin/cat '" + privateMemory.appendingPathComponent("private.md").path + "' > '" + backgroundCapture.path + "'"
                let background = try await controllerCall("run_background", ["callerThreadID": newID.uuidString, "cmd": command, "cwd": work.path], caller: .engine(newID))
                restrictedBridge.backgroundCommandApprover = previousApprover
                check(background["ok"] as? Bool == true, "R6-CARDS-N1-approved-background-still-allowed")
                for _ in 0..<50 where !FileManager.default.fileExists(atPath: backgroundCapture.path) { try await Task.sleep(for: .milliseconds(100)) }
                try await Task.sleep(for: .milliseconds(200))
                check((try? String(contentsOf: backgroundCapture, encoding: .utf8))?.contains(marker) == false, "R6-CARDS-N1-approved-background-cannot-bypass-memory")
                check((try? Data(contentsOf: policy.root.appendingPathComponent("engines/codex/auth.json"))) == login, "R6-CARDS-N1-isolated-login-remains-available")
                for name in ["engines", "home"] {
                    let directory = policy.root.appendingPathComponent(name)
                    let saved = policy.root.appendingPathComponent(name + "-saved")
                    try FileManager.default.moveItem(at: directory, to: saved)
                    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: privateMemory)
                    let started = colleagueEngine.fixtureStartSidecar(newID, engine: .codex)
                    colleagueEngine.shutdownAll()
                    try FileManager.default.removeItem(at: directory)
                    try FileManager.default.moveItem(at: saved, to: directory)
                    check(!started, "R6-CARDS-N1-App-refuses-aliased-" + name + "-before-launch")
                    check(!FileManager.default.fileExists(atPath: privateMemory.appendingPathComponent("codex").path), "R6-CARDS-N1-App-does-not-create-engine-files-in-memory")
                }
            }
            restrictedBridge.fixtureSend = nil
            if ProcessInfo.processInfo.environment["TATWO2_W187_R4_DM"] != nil {
                colleagueModel.permissionPreset = .fullAccess
                let deniedCommand = try await controllerCall("run_background", ["callerThreadID": newID.uuidString, "cmd": "printf synthetic", "cwd": root.path], caller: .engine(newID))
                check(deniedCommand["ok"] as? Bool == false, "R4-DM-03-dispatch-only-native-shell-refused-even-with-staff-full-access")
            }
            check(colleagueEngine.threadRecord(newID)?.controllerCreatorFingerprint == members[0].clientKeyFingerprint, "R3-DM-03-creator-recorded")
            check(try await controllerCall("stop_thread", ["threadID": newID.uuidString])["ok"] as? Bool == true, "R3-DM-03-controller-own-stop-allowed")
            check(try await controllerCall("user_remember", ["text": "Synthetic fixture memory"], caller: .engine(newID))["error"] as? String == DeviceFleetError.capabilityDenied.reason, "R3-DM-03-bound-engine-memory-bypass-refused")
            check(colleagueEngine.threadRecord(newID)?.memoryStrength == "off", "R3-DM-03-controller-passive-memory-off")
            let child = colleagueEngine.newThread(in: nil, title: "controller-child")
            colleagueEngine.configureRoom(threadID: child, parentThreadID: newID, roomBrief: "synthetic", engine: "codex", cwdOverride: root.path)
            check(try await controllerCall("user_remember", ["text": "Synthetic fixture memory"], caller: .engine(child))["error"] as? String == DeviceFleetError.capabilityDenied.reason, "R3-DM-03-dispatch-child-memory-bypass-refused")
        }
        staffSession.close()
        session.close(); await session.refresh()
        let records = members.map { m in DeviceRecord(id: m.id, name: m.name, host: m.endpoints[0].host, user: m.user, sshPort: 22,
            publicKeyFingerprint: m.hostKeyFingerprint!, addedAt: Date(), lastSeenAt: Date(), workdirMap: ["/secret": "/remote-secret"],
            hostKeyFingerprint: m.hostKeyFingerprint, clientKeyFingerprint: m.clientKeyFingerprint) }
        let projected = DeviceFleetStore.engineDeviceProjection(records, payload: .init(roster: roster))
        check(projected.count == 4 && projected.allSatisfy { Set($0.keys) == ["id", "name", "role", "group", "online"] }, "DM-07-engine-projection-exact-allowlist")
        let projectionJSON = String(decoding: try JSONSerialization.data(withJSONObject: projected), as: UTF8.self)
        check(!projectionJSON.contains("192.0.2.") && !projectionJSON.contains("SHA256:") && !projectionJSON.contains("secret"), "DM-07-engine-projection-no-address-fingerprint-workdir")
        var visibleRoster = roster; visibleRoster.groups[1].showMainPrimary = true
        let visibleSlice = try visibleRoster.slice(for: ids[2])
        let primaryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(visibleSlice.primary!)) as! [String: Any]
        check(Set(primaryJSON.keys) == ["name", "role"], "DM-08-opt-in-primary-wire-only-name-role")
        let native = DeviceFlowPhysicalButton.Native(frame: NSRect(x: 10, y: 10, width: 160, height: 34))
        let nativeWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false; nativeWindow.contentView!.addSubview(native)
        defer { nativeWindow.close() }
        var presses = 0; native.invoke = { _ in presses += 1 }; native.binding = "fixture"; native.changedAt = ProcessInfo.processInfo.systemUptime - 2
        check(!native.accessibilityPerformPress(), "DM-02-AXPress-explicitly-refused")
        native.performClick(nil)
        check(presses == 0, "DM-02-programmatic-press-cannot-mint-authority")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { native.mouseDown(with: event) } else { native.mouseUp(with: event) }
        }
        check(presses == 0, "DM-02-synthetic-mouse-events-refused")
        let oneShot = DeviceFlowUserAction.fixture(binding: session.cardBinding)
        check(oneShot.consume(for: session) && !oneShot.consume(for: session), "DM-02-authority-is-one-shot")
        let stale = DeviceFlowUserAction.fixture(binding: session.cardBinding)
        try await Task.sleep(for: .milliseconds(550))
        check(!stale.consume(for: session), "DM-02-authority-expires-within-half-second")
        session.fixtureCard(.menu)
        let beforeAcknowledgement = try session.store.current()
        var warningState = try session.store.read()
        warningState.possiblyConnected = [ids[1]]; warningState.possiblyConnectedDevices = [ids[1]: 1]
        try session.store.save(warningState); await session.refresh()
        try png("connection-closure-confirmation", DeviceFlowCard(session: session).padding(16).background(TatwoActivePalette.current.canvasBase), height: 700)
        await session.confirmConnectionsClosed(.fixture())
        check(session.possiblyConnected == [ids[1]], "R3-REV-01-invalid-physical-authority-keeps-warning")
        let earlierWarning = DeviceFlowUserAction.fixture(binding: session.cardBinding)
        warningState.possiblyConnectedDevices = [ids[1]: 2]; try session.store.save(warningState)
        await session.confirmConnectionsClosed(earlierWarning)
        check(session.possiblyConnected == [ids[1]], "R3-REV-01-new-warning-generation-needs-new-confirmation")
        await session.confirmConnectionsClosed(.fixture(binding: session.cardBinding))
        check(try session.possiblyConnected.isEmpty && session.store.read().possiblyConnectedDevices?.isEmpty == true,
              "R3-REV-01-physical-acknowledgement-clears-diagnostics")
        check(try session.store.current() == beforeAcknowledgement, "R3-REV-01-acknowledgement-never-changes-permissions")
        session.fixtureCard(.permissions)
        check(UIProbe.run(["action": "snapshot"])["error"] as? String == "sensitive_window_open", "DM-09-open-card-snapshot-refused")
        session.close()
        let holder = NSObject(); nativeWindow.orderFrontRegardless(); WindowCaptureShield.shared.hold(holder, window: nativeWindow)
        check(UIProbe.run(["action": "snapshot"])["error"] as? String == "sensitive_window_open", "DM-09-any-protected-window-refuses-snapshot")
        WindowCaptureShield.shared.release(holder); nativeWindow.orderOut(nil)
        try Data("fixture.host \(members[2].hostPublicKey!)\n".utf8).write(to: session.store.registry.fleetKnownHostsURL)
        try Data().write(to: session.store.registry.knownHostsURL)
        let link = RemoteHostLink(environment: env)
        try link.fixturePrepareHostPin(records[2])
        // All one-shot SSH callers use this environment before the immutable pin factory.
        let combined = try DeviceFleetSSHPins.withEnvironment(for: records[2], registry: session.store.registry) {
            try SSHHostPin.make(records[2], environment: $0)
        }
        check(combined.fingerprint == records[2].pinnedHostKeyFingerprint,
              "REG-05-shared-caller-pin-finds-fleet-only-key")
        try Data("unrelated.fixture \(members[1].hostPublicKey!)\n".utf8).write(to: session.store.registry.knownHostsURL)
        check(try DeviceFleetSSHPins.lines(for: records[2], registry: session.store.registry).count == 2,
              "REG-05-shared-caller-reads-both-sources")
        try Data("@revoked unrelated.fixture \(members[2].hostPublicKey!)\n".utf8).write(to: session.store.registry.knownHostsURL)
        refused("REG-05-shared-caller-global-revocation-refused") {
            _ = try DeviceFleetSSHPins.withEnvironment(for: records[2], registry: session.store.registry) {
                try SSHHostPin.make(records[2], environment: $0)
            }
        }
        try Data().write(to: session.store.registry.knownHostsURL)
        check(try link.requiresFleetGate(records[2]), "REG-05-managed-peer-selects-gate")
        check(try !link.requiresFleetGate(records[1]), "REG-05-owner-peer-retains-general-channel")
        var gateCalls = 0
        link.fixtureGate = { peer, method, _ in gateCalls += 1; return ["fixture": peer.id, "method": method] }
        let gateReply = try await Task.detached { try link.callPinned(device: records[2], method: "document_inspect") }.value
        check(gateReply["method"] as? String == "document_inspect" && gateCalls == 1, "REG-05-restricted-call-uses-exec-gate-no-forwarding")
        do { _ = try await Task.detached { try link.callPinned(device: records[2], method: "unclassified_fixture") }.value; check(false, "REG-05-unlisted-method-refused-before-transport") }
        catch { check(gateCalls == 1, "REG-05-unlisted-method-refused-before-transport") }
        try Data("\(records[2].host) \(members[1].hostPublicKey!)\n".utf8).write(to: session.store.registry.knownHostsURL)
        refused("REG-05-two-pin-files-conflict-refuses-general-channel") { try link.fixturePrepareHostPin(records[2]) }
        check(try session.store.read().pinConflicts?.contains(records[2].id) == true, "REG-05-conflicting-host-marked-for-readonly-page")
        try Data().write(to: session.store.registry.knownHostsURL)
        let oldHooks = DeviceFleetRevocation.testHooks
        defer { DeviceFleetRevocation.testHooks = oldHooks }
        var terminated: [Int32] = []
        DeviceFleetRevocation.testHooks = .init(sessions: {
            [.init(pid: 99901, start: 1, fingerprint: "unrelated-fixture-key", address: "198.51.100.11", tatwoRelated: false)]
        }, terminate: { session in terminated.append(session.pid); return true })
        _ = try session.propose([.revoke(id: ids[1])])
        session.disconnectAllOnRevoke = false
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        check(terminated.isEmpty, "TR-02-unchecked-revoke-does-not-disconnect-unrelated-sessions")
        _ = try session.propose([.revoke(id: ids[3])])
        session.disconnectAllOnRevoke = true
        try cardPNG("revoke-uncertain-connections", height: 700)
        await session.confirmFromCard(.fixture())
        check(terminated.isEmpty, "DM-02-invalid-authority-cannot-broad-disconnect")
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        check(terminated == [99901], "TR-02-explicit-physical-choice-calls-broad-disconnect")
        var handbackIdentity = DeviceIdentity(deviceID: ids[0], name: "fixture", hardwareModel: "fixture", role: .primary,
            epoch: 2, primaryDeviceID: ids[0], updatedAt: Date())
        handbackIdentity.transfer = PrimaryTransfer.Record(from: ids[0], to: ids[1], oldEpoch: 2, epoch: 3,
            participants: [ids[1]], previousTransferID: UUID().uuidString, sourceDeviceID: ids[0], sourceRoot: "/fixture",
            hashes: ["os.md": "fixture"], sourcePages: 42, signingName: "fixture")
        guard let handback = GlobalDMChatAcceptance.renderSync(DeviceFlowTransferPanel(preview: handbackIdentity)
            .padding(16).background(TatwoActivePalette.current.canvasBase), size: .init(width: 400, height: 1100)) else { throw DeviceFleetError.malformed }
        defer { handback.close() }
        var cancelVisible = false
        func findCancel(_ view: NSView) {
            if let button = view as? DeviceFlowPhysicalButton.Native, button.title.contains("取消尚未遞增的移交") { cancelVisible = true }
            view.subviews.forEach(findCancel)
        }
        if let view = handback.window.contentView { findCancel(view) }
        check(cancelVisible, "TR-04-handback-precommit-cancel-visible-native-button")
        let handbackPNG = handback.bitmap.representation(using: .png, properties: [:])!
        try handbackPNG.write(to: artifacts.appendingPathComponent("transfer-handback-cancellable.png"))
        check(handbackPNG.count > 1000, "png-transfer-handback-cancellable")
        print("W187DM ARTIFACT \(artifacts.appendingPathComponent("transfer-handback-cancellable.png").path)")
        var lockedIdentity = handbackIdentity; lockedIdentity.transfer!.committed = true
        lockedIdentity.transfer!.hashes = ["os.md": String(repeating: "a", count: 64), "skillet.md": String(repeating: "b", count: 64)]
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let dispatch = DeviceDispatch.shared
        guard HandsPath.canonical(dispatch.entry.root.path).hasPrefix(HandsPath.canonical(rootPath) + "/") else { throw DeviceFleetError.malformed }
        let savedIdentity = try? Data(contentsOf: dispatch.entry.deviceJSON)
        try FileManager.default.createDirectory(at: dispatch.entry.root, withIntermediateDirectories: true)
        try lockedIdentity.encoded().write(to: dispatch.entry.deviceJSON)
        defer {
            if let savedIdentity { try? savedIdentity.write(to: dispatch.entry.deviceJSON) }
            else { try? FileManager.default.removeItem(at: dispatch.entry.deviceJSON) }
        }
        DispatchQueue.global().async {
            dispatch.withStateLock { ready.signal(); _ = release.wait(timeout: .now() + 4) }
        }
        guard ready.wait(timeout: .now() + 2) == .success else { throw DeviceFleetError.malformed }
        let began = ProcessInfo.processInfo.systemUptime
        let responsive = GlobalDMChatAcceptance.renderSync(DeviceFlowTransferPanel(preview: lockedIdentity), size: .init(width: 400, height: 1100))
        release.signal()
        defer { responsive?.close() }
        check(responsive != nil && ProcessInfo.processInfo.systemUptime - began < 1.5, "R8-CKPT-01-transfer-panel-renders-with-dispatch-lock-held")
        var retiredIdentity = handbackIdentity
        retiredIdentity.role = .secondary; retiredIdentity.primaryDeviceID = ids[1]
        retiredIdentity.epoch = 3; retiredIdentity.transfer!.committed = true
        try png("transfer-retired", DeviceFlowTransferPanel(preview: retiredIdentity, previewCoordinatorRetired: true)
            .padding(16).background(TatwoActivePalette.current.canvasBase), height: 550)
        // Fifth ruling: the real assistant handler proposes, the physical card alone signs.
        session.close()
        let beforeDesignation = try session.store.readGraph()!.roster!
        _ = try call("fleet_propose", ["baseVersion": NSNumber(value: beforeDesignation.version),
            "changes": [["op": "set_sub_primary", "target": "g2", "device": NSNull()]]])
        check(try session.store.readGraph()!.roster! == beforeDesignation
              && session.pending?.preview.groups[1].primaryDeviceID == ""
              && session.previewLines.contains { $0.contains("未指定") }
              && session.previewLines.contains(DeviceFleetDefaults.staffRoleExplanation), "g-assistant-cancellation-is-role-only-preview")
        try cardPNG("sub-primary-cancel-preview", height: 850)
        await session.confirmFromCard(.fixture())
        check(try session.store.readGraph()!.roster! == beforeDesignation && session.pending != nil,
              "g-assistant-cancellation-rejects-programmatic-confirmation")
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        let noSubPrimary = try session.store.readGraph()!.roster!
        check(noSubPrimary.groups[1].primaryDeviceID.isEmpty && noSubPrimary.devices[2].role == .secondary
              && noSubPrimary.edges == beforeDesignation.edges, "g-physical-card-cancels-marker-without-permission-change")
        _ = try call("fleet_propose", ["baseVersion": NSNumber(value: noSubPrimary.version),
            "changes": [["op": "set_sub_primary", "target": "g2", "device": "d3"]]])
        check(session.previewLines.contains { $0.contains("SUB 主設備") } && session.previewLines.contains(DeviceFleetDefaults.staffRoleExplanation),
              "g-designation-preview-explains-marker")
        check(!session.previewLines.contains { $0.hasPrefix("設備名稱") }, "g-designation-never-claims-device-rename")
        try cardPNG("sub-primary-designate-preview", height: 850)
        await session.confirmFromCard(.fixture(binding: session.cardBinding))
        let designated = try session.store.readGraph()!.roster!
        check(designated.groups[1].primaryDeviceID == ids[2] && designated.devices[2].role == .primary
              && designated.edges == beforeDesignation.edges && designated.primaryID == beforeDesignation.primaryID
              && designated.epoch == beforeDesignation.epoch, "g-physical-card-designates-role-without-main-authority-change")
        for direction in ["oneway", "mutual", "none"] {
            do {
                _ = try call("fleet_propose", ["baseVersion": NSNumber(value: designated.version),
                    "changes": [["op": "set_edge", "from": "g2", "to": "d3", "direction": direction,
                                 "capabilities": direction == "none" ? [] : ["files"]]]])
                check(false, "g-assistant-staff-edge-refused-" + direction)
            } catch let error as AssistantFleetTools.Failure {
                check(error.reason == "職員電腦之間的互聯暫不開放", "g-assistant-staff-edge-refused-" + direction)
            }
        }
        check(try session.store.readGraph()!.roster! == designated && session.pending == nil,
              "g-refused-staff-arrows-never-create-card-or-signature")
        // A secondary's ordinary pairing stays pending; its progress must not imply admission.
        var pendingEnv = ownerSenderEnv
        pendingEnv["TATWO2_SSH_HOST_KEY_PUB"] = root.appendingPathComponent("fixture-1-host.pub").path
        pendingEnv["TATWO2_AUTHORIZED_KEYS"] = root.appendingPathComponent("pending-authorized").path
        pendingEnv["TATWO2_SSH_KNOWN_HOSTS"] = root.appendingPathComponent("pending-known-hosts").path
        let pendingSession = DeviceFlowSession(environment: pendingEnv, pasteboard: NSPasteboard.withUniqueName(), rpc: { _, _, _ in throw DeviceFleetError.unknownMember })
        defer { pendingSession.close() }
        var pendingRoster = roster; pendingRoster.revoked = [ids[2]]
        var pendingState = try pendingSession.store.read()
        pendingState.trust = .init(localID: ids[1], primaryID: ids[0], epoch: 1, pinnedPrimaryKey: members[0].clientKeyFingerprint!, kind: .owner)
        try pendingSession.store.save(pendingState)
        try pendingSession.store.accept(DeviceFleetEnvelope.issue(.init(roster: pendingRoster), environment: env))
        await pendingSession.refresh(); pendingSession.fixtureAwaitingMember()
        var pendingMember = members[2]
        pendingMember.id = "ffffffff-3333-4333-8333-333333333333"
        pendingMember.name = "synthetic pending re-pair"
        pendingMember.groupID = "main"; pendingMember.role = .secondary
        pendingState = try pendingSession.store.read(); pendingState.pending = [pendingMember]
        try pendingSession.store.save(pendingState)
        await pendingSession.refresh()
        check(pendingSession.joinedDeviceLabel.contains(pendingMember.name), "REV-05-secondary-pending-progress-names-device")
        check(pendingSession.pairingHistoryNotice.contains("曾被撤銷") && pendingSession.pairingHistoryNotice.contains("主設備本機"), "REV-05-secondary-pending-repair-explains-history-and-local-route")
        check(try pendingSession.store.current()!.roster! == pendingRoster && pendingSession.signedVersion == nil, "REV-05-secondary-pending-progress-never-admits-member")
        print("W187DM SUMMARY checks=\(checks) failures=\(failures)")
        return failures == 0
    }
}
#endif
