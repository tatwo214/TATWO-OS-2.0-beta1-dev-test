#if DEBUG
import Foundation

/// Eight disposable devices. No daemon, real SSH directory, hostnames or network access.
enum DeviceFleetGraphAcceptance {
    struct Fixture {
        let member: DeviceFleetMember
        let registry: DeviceRegistry
        let environment: [String: String]
        let fleet: DeviceFleetStore
    }
    static func run(root: URL) throws {
        let fm = FileManager.default
        DeviceFleetRevocation.testHooks = .init(sessions: { [] }, terminate: { _ in false })
        defer { DeviceFleetRevocation.testHooks = nil }
        var checks = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "W187GRAPH_FAIL_" + label, code: 1) }
            checks += 1; print("W187GRAPH PASS \(label)")
        }
        func rejects(_ label: String, expected: DeviceFleetError, _ action: () throws -> Void) throws {
            do { try action() } catch {
                guard (error as? DeviceFleetError) == expected else { throw error }
                checks += 1; print("W187GRAPH PASS \(label)"); return
            }
            throw NSError(domain: "W187GRAPH_UNEXPECTED_ACCEPT_" + label, code: 1)
        }
        let ids = (1...10).map { String(format: "%08x-2222-4222-8222-222222222222", $0) }
        func make(_ index: Int, group: String, role: DeviceFleetRole, kind: DeviceFactionKind) throws -> Fixture {
            let base = root.appendingPathComponent("graph-fixture-\(index)")
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": base.appendingPathComponent("entry").path], preference: nil)
            try fm.createDirectory(at: entry.root, withIntermediateDirectories: true)
            let key = base.appendingPathComponent("client").path, host = base.appendingPathComponent("host").path
            for path in [key, host] {
                guard try DeviceDispatch.run("/usr/bin/ssh-keygen",
                    ["-q", "-t", "ed25519", "-N", "", "-C", index == 0 ? "example-private-main-comment" : "fixture", "-f", path]).0 == 0 else {
                    throw DeviceFleetError.missingKey
                }
            }
            let environment = ["TATWO_OS_ROOT": entry.root.path,
                "TATWO2_LIVE_ROOT": base.appendingPathComponent("live").path,
                "TATWO2_AUTHORIZED_KEYS": base.appendingPathComponent("authorized_keys").path,
                "TATWO2_SSH_KNOWN_HOSTS": base.appendingPathComponent("known_hosts").path,
                "TATWO2_SSH_KEY_PATH": key, "TATWO2_SSH_HOST_KEY_PUB": host + ".pub"]
            let client = try String(contentsOfFile: key + ".pub", encoding: .utf8)
            let hostKey = try String(contentsOfFile: host + ".pub", encoding: .utf8)
            let member = DeviceFleetMember(id: ids[index], name: "fixture-\(index)", factionID: group, role: role,
                clientKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: client),
                hostKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: hostKey),
                clientPublicKey: client, hostPublicKey: hostKey,
                endpoints: [.init(kind: .lan, host: "192.0.2.\(index + 1)")], user: "fixture")
            let identity = DeviceIdentity(deviceID: ids[index], name: member.name, hardwareModel: "fixture",
                role: index == 0 ? .primary : .secondary, epoch: 1, primaryDeviceID: ids[0], updatedAt: Date())
            try identity.encoded().write(to: entry.deviceJSON)
            let registry = DeviceRegistry(environment: environment)
            let fleet = DeviceFleetStore(registry: registry, environment: environment)
            return .init(member: member, registry: registry, environment: environment, fleet: fleet)
        }
        let a = try make(0, group: "main", role: .primary, kind: .owner)
        let b = try make(1, group: "main", role: .secondary, kind: .owner)
        let c = try make(2, group: "main", role: .secondary, kind: .owner)
        let p = try make(3, group: "company", role: .primary, kind: .managed)
        let q = try make(4, group: "company", role: .secondary, kind: .managed)
        let r = try make(5, group: "company", role: .secondary, kind: .managed)
        let s = try make(6, group: "main", role: .sandbox, kind: .sandbox)
        let t = try make(7, group: "main", role: .sandbox, kind: .sandbox)
        let fixtures = [a,b,c,p,q,r,s,t]
        for fixture in fixtures {
            let kind: DeviceFactionKind = fixture.member.role == .sandbox ? .sandbox
                : (fixture.member.groupID == "main" ? .owner : .managed)
            let trust = DeviceFleetTrust(localID: fixture.member.id, primaryID: a.member.id, epoch: 1,
                                         pinnedPrimaryKey: a.member.clientKeyFingerprint!, kind: kind)
            let data = try JSONSerialization.data(withJSONObject: [
                "trust": DeviceDispatch.object(trust), "pending": [], "confirmations": [], "leaving": false,
                "managedRemoved": [], "leaveRequests": [], "controllerHistory": []])
            try DeviceDispatchSafeFile.write(data, url: fixture.fleet.url)
            // A denied managed row is pruned; the same unmarked key below survives ordinary synchronization.
            try Data("\(fixture.member.clientPublicKey!.trimmingCharacters(in: .whitespacesAndNewlines)) tatwo2-device:fixture-denied-key\n".utf8)
                .write(to: fixture.registry.authorizedKeysURL)
        }
        let groups = [
            DeviceFleetGroup(id: "main", name: "example MAIN", type: .main, primaryDeviceID: a.member.id,
                             managerDisplayName: "example manager"),
            DeviceFleetGroup(id: "company", name: "公司", type: .sub, primaryDeviceID: p.member.id,
                             parentGroupID: "main", managerDisplayName: "example company")]
        let members = fixtures.map(\.member)
        var roster = DeviceFleetRoster(version: 1, primaryID: a.member.id, epoch: 1, groups: groups,
                                       devices: members, edges: DeviceFleetRoster.defaults(groups: groups, devices: members))
        // W187g fifth ruling: tests precede implementation; these defaults used to fail.
        try check("g-first-managed-not-primary", !DeviceFleetDefaults.firstManagedDeviceIsPrimary)
        try check("g-staff-peer-capabilities-empty", DeviceFleetDefaults.staffPeerCapabilities.isEmpty)
        var unassigned = roster
        unassigned.groups[1].primaryDeviceID = ""
        unassigned.devices[3].role = .secondary
        try unassigned.validate()
        try check("g-sub-without-primary-valid", unassigned.groups[1].primaryDeviceID.isEmpty)
        var phantomPrimary = unassigned; phantomPrimary.devices[3].role = .primary
        try rejects("g-unassigned-sub-cannot-hide-primary-role", expected: .role) { try phantomPrimary.validate() }
        var missingMainPrimary = roster; missingMainPrimary.groups[0].primaryDeviceID = ""
        try rejects("g-main-still-requires-primary", expected: .malformed) { try missingMainPrimary.validate() }
        try roster.validate()
        func rawIssue(_ payload: DeviceFleetPayload, environment: [String: String]) throws -> DeviceFleetEnvelope {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(payload)
            let signature = try DeviceSignature.sign(body, namespace: DeviceFleetEnvelope.namespace, environment: environment)
            return .init(body: body, signature: signature.0, publicKey: signature.1)
        }
        func deliver(_ graph: DeviceFleetRoster) throws {
            for fixture in fixtures {
                let payload: DeviceFleetPayload = graph.kind(of: fixture.member.id) == .owner
                    ? .init(roster: graph) : .init(slice: try graph.slice(for: fixture.member.id))
                try fixture.fleet.accept(DeviceFleetEnvelope.issue(payload, environment: a.environment))
            }
        }
        try deliver(roster)
        for fixture in fixtures {
            if let slice = try fixture.fleet.pendingConsent() {
                try check("initial-controls-withheld-until-local-consent", try fixture.fleet.effectiveControllers(slice.controllers).isEmpty)
                try fixture.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers)
            }
        }
        let all = DeviceFleetCapabilities.all.sorted(), managed = DeviceFleetCapabilities.managed.sorted()
        let sandbox = DeviceFleetCapabilities.sandbox.sorted()
        let expected: [[Int: [String]]] = [
            [1:all,2:all], [0:all,2:all], [0:all,1:all],
            [0:managed,1:managed,2:managed],
            // Fifth ruling removes both SUB-primary and colleague grants.
            [0:managed,1:managed,2:managed],
            [0:managed,1:managed,2:managed],
            [0:sandbox,1:sandbox,2:sandbox], [0:sandbox,1:sandbox,2:sandbox]]
        for (index, fixture) in fixtures.enumerated() {
            var actual: [Int: [String]] = [:]
            for (source, caller) in fixtures.enumerated() {
                let fingerprint = caller.member.clientKeyFingerprint!
                let authorized = fixture.registry.fleetHasAuthorizedFingerprint(fingerprint)
                let capabilities = try fixture.fleet.capabilities(for: fingerprint)
                try check("key-capability-consistency-\(index)-\(source)", authorized == (capabilities != nil))
                if authorized { actual[source] = capabilities!.sorted() }
            }
            try check("default-device-\(index)-exact-grants", actual == expected[index])
            let text = try String(contentsOf: fixture.registry.authorizedKeysURL, encoding: .utf8)
            try check("default-device-\(index)-marked-keys-only", text.split(whereSeparator: \.isNewline).count == expected[index].count
                      && text.split(whereSeparator: \.isNewline).allSatisfy { $0.contains("tatwo2-device:") })
            print("W187GRAPH GRANTS fixture-\(index) " + actual.keys.sorted().map {
                "fixture-\($0):" + actual[$0]!.joined(separator: ",")
            }.joined(separator: " | "))
        }
        func method(_ fixture: Fixture, caller: Fixture, _ method: String) -> Bool {
            OSSocketCaller.sshMethodAllowed(fingerprint: caller.member.clientKeyFingerprint, method: method, registry: fixture.registry)
        }
        try check("memory-off-refused-production-ssh-gate", !method(q, caller: a, "memory_list"))
        try check("files-on-allowed-production-ssh-gate", method(q, caller: a, "document_inspect"))
        try check("memory-family-all-refused", ["memory_search", "memory_get", "memory_save", "memory_propose",
                                              "memory_list", "memory_decide", "memory_sync_target", "memory_sync_receive"]
            .allSatisfy { !method(q, caller: a, $0) })
        try check("memory-list-and-files-remain-in-w178-allowlist",
                  OSAgentBridge.allows(caller: .ssh, method: "memory_list", params: [:], staging: false)
                  && OSAgentBridge.allows(caller: .ssh, method: "document_inspect", params: [:], staging: false))
        func rpc(_ sender: Fixture, _ target: Fixture, _ method: String) throws -> (String, [String: Any]) {
            let origin = DeviceDispatch(entry: sender.fleet.entry, registry: sender.registry, environment: sender.environment)
            let destination = DeviceDispatch(entry: target.fleet.entry, registry: target.registry, environment: target.environment)
            return try destination.authenticate(method: method, proof: origin.signed(method: method, payload: [:], recipient: target.member.id))
        }
        do {
            _ = try rpc(a, q, "memory_list")
            throw NSError(domain: "W187GRAPH_MEMORY_RPC_UNEXPECTED", code: 1)
        } catch let error as DeviceDispatch.Failure {
            try check("memory-off-refused-signed-rpc", error.reason == "untrusted_rpc_controller")
        }
        _ = try rpc(a, q, "inbox_target")
        try check("files-on-allowed-signed-rpc", true)
        var mainToSub = roster.edges.first { $0.from == .group("main") && $0.to == .group("company") }!
        mainToSub.capabilities.append("memory")
        let pending = try a.fleet.propose([.setEdge(mainToSub)], actor: a.member.id)
        try check("proposal-not-signed-or-applied", a.fleet.current()!.revision == 1 && !method(q, caller: a, "memory_list"))
        try rejects("confirmation-required", expected: .confirmationRequired) {
            _ = try a.fleet.confirm(pending.id, userConfirmed: false)
        }
        _ = try a.fleet.confirm(pending.id, userConfirmed: true)
        roster = try a.fleet.current()!.roster!
        for fixture in fixtures.dropFirst() {
            try fixture.fleet.accept(a.fleet.delivery(for: fixture.member.id)!)
        }
        try check("memory-gain-remains-closed-after-primary-signature", !method(q, caller: a, "memory_list") && !method(p, caller: c, "memory_sync_target"))
        for fixture in fixtures {
            if let slice = try fixture.fleet.pendingConsent() { try fixture.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers) }
        }
        try check("memory-on-after-local-confirmed-signature", method(q, caller: a, "memory_list") && method(p, caller: c, "memory_sync_target"))
        _ = try rpc(a, q, "memory_list")
        try check("memory-on-allowed-signed-rpc", true)
        // Fifth ruling: a designated SUB primary has no control over colleagues.
        do {
            _ = try rpc(p, q, "inbox_target")
            throw NSError(domain: "W187GRAPH_SUB_PEER_RPC_UNEXPECTED", code: 1)
        } catch let error as DeviceDispatch.Failure {
            try check("sub-primary-signed-files-to-own-secondary-refused", error.reason == "untrusted_rpc_controller")
        }
        try check("write-always-v2", String(decoding: try a.fleet.envelope()!.body, as: UTF8.self).contains("tatwo.device-fleet.v2"))
        try check("ssh-gate-never-widens-w178", !OSAgentBridge.allows(caller: .ssh, method: "computer_action", params: [:], staging: false)
                  && !OSAgentBridge.allows(caller: .ssh, method: "run_background", params: [:], staging: false))
        try check("sandbox-screen-update-memory-off", ["computer_action", "ipad_touch", "hands_build", "memory_list"]
            .allSatisfy { !method(s, caller: a, $0) })
        try check("sandbox-native-dispatch-and-files-without-memory", method(s, caller: a, "send_message") && method(s, caller: a, "document_inspect") && !method(s, caller: a, "memory_sync_receive"))
        try check("dispatch-only-cannot-run-file-execution", !DeviceFleetCapabilities.allows(method: "send_message", capabilities: ["dispatch"]))
        try check("unknown-method-deny-even-full-capabilities", !method(b, caller: a, "future_unclassified"))
        try check("unidentifiable-key-cannot-inherit-owner",
                  !OSSocketCaller.sshMethodAllowed(fingerprint: nil, method: "memory_list", registry: q.registry))
        try check("fingerprint-not-from-rpc-params", !method(a, caller: p, "document_inspect"))
        for (name, capability) in DeviceFleetCapabilities.methodTable {
            try check("method-table-\(name)", DeviceFleetCapabilities.allows(method: name, capabilities: DeviceFleetCapabilities.nativeExecutionMethods.contains(name) ? ["dispatch", "files", "memory"] : [capability])
                      && !DeviceFleetCapabilities.allows(method: name, capabilities: []))
        }
        for (method, capability) in [("memory_future", "memory"), ("computer_future", "screen"),
                                    ("ipad_future", "screen"), ("cli_future", "dispatch"), ("command_future", "dispatch")] {
            try check("method-family-\(method)", DeviceFleetCapabilities.required(for: method) == capability)
        }
        var mainPeer = roster.edges.first { $0.from == .device(a.member.id) && $0.to == .device(b.member.id) }!
        let fullPeer = mainPeer
        mainPeer.capabilities = ["files"]
        let reduced = try a.fleet.propose([.setEdge(mainPeer)], actor: a.member.id)
        _ = try a.fleet.confirm(reduced.id, userConfirmed: true)
        do {
            _ = try rpc(b, a, "memory_list")
            throw NSError(domain: "W187GRAPH_OWNER_CAPABILITY_BYPASS", code: 1)
        } catch let error as DeviceDispatch.Failure {
            try check("main-peer-signed-rpc-cannot-bypass-capability", error.reason == "fleet_capabilityDenied")
        }
        try check("main-peer-files-key-preserved", a.registry.fleetHasAuthorizedFingerprint(b.member.clientKeyFingerprint!)
                  && method(a, caller: b, "inbox_target"))
        let restored = try a.fleet.propose([.setEdge(fullPeer)], actor: a.member.id)
        _ = try a.fleet.confirm(restored.id, userConfirmed: true)
        roster = try a.fleet.current()!.roster!
        let before = try a.fleet.envelope()!
        var reverse = roster; reverse.version += 1
        reverse.edges.append(.init(from: .device(p.member.id), to: .device(a.member.id),
                                   direction: .oneway, capabilities: ["files"]))
        try rejects("sub-to-main-entire-roster-refused", expected: .reverseEdge) {
            try a.fleet.accept(rawIssue(.init(roster: reverse), environment: a.environment))
        }
        try check("invalid-roster-no-partial-application", a.fleet.envelope() == before
                  && !a.registry.fleetHasAuthorizedFingerprint(p.member.clientKeyFingerprint!))
        var foreignSigned = roster; foreignSigned.version += 1
        try rejects("sub-primary-signed-roster-refused", expected: .signer) {
            try a.fleet.accept(rawIssue(.init(roster: foreignSigned), environment: p.environment))
        }
        try rejects("sub-primary-cannot-issue-main-roster", expected: .signer) {
            _ = try DeviceFleetEnvelope.issue(.init(roster: roster), environment: p.environment)
        }
        try rejects("sub-transfer-proposal-refused", expected: .managedLocked) {
            _ = try p.fleet.propose([.transfer(to: a.member.id)], actor: p.member.id)
        }
        try rejects("sub-cannot-enroll-main", expected: .reverseEnrollment) {
            try roster.requireMAINEnrollment(actor: p.member.id, device: q.member.id)
        }
        try rejects("sandbox-cannot-be-enrolled-in-main", expected: .reverseEnrollment) {
            _ = try a.fleet.propose([.moveDevice(id: s.member.id, groupID: "main")], actor: a.member.id)
        }
        try rejects("sandbox-cannot-enroll-main", expected: .reverseEnrollment) {
            try roster.requireMAINEnrollment(actor: s.member.id, device: q.member.id)
        }
        var promotedSandbox = roster; promotedSandbox.version += 1
        for index in promotedSandbox.devices.indices where promotedSandbox.devices[index].id == s.member.id {
            promotedSandbox.devices[index].role = .secondary
        }
        promotedSandbox.edges = DeviceFleetRoster.defaults(groups: promotedSandbox.groups, devices: promotedSandbox.devices)
        try rejects("known-sandbox-cannot-be-relabeled-main-even-primary-signed", expected: .reverseEnrollment) {
            try a.fleet.accept(rawIssue(.init(roster: promotedSandbox), environment: a.environment))
        }
        let locked = roster.edges.first { $0.from == .group("company") && $0.locked }!
        var unlocked = locked; unlocked.locked = false
        try rejects("locked-arrow-cannot-edit", expected: .lockedEdge) {
            _ = try a.fleet.propose([.setEdge(unlocked)], actor: a.member.id)
        }
        var mutual = mainToSub; mutual.direction = .mutual
        try rejects("mutual-main-sub-cannot-bypass-reverse-lock", expected: .reverseEdge) {
            _ = try a.fleet.propose([.setEdge(mutual)], actor: a.member.id)
        }
        var subToSandbox = roster; subToSandbox.version += 1
        subToSandbox.edges.append(.init(from: .device(p.member.id), to: .device(s.member.id),
                                        direction: .oneway, capabilities: ["dispatch"]))
        try rejects("sub-primary-authority-only-own-group", expected: .reverseEdge) { try subToSandbox.validate() }
        let transfer = try a.fleet.propose([.transfer(to: b.member.id)], actor: a.member.id)
        try rejects("transfer-confirm-remains-not-ready", expected: .confirmationRequired) {
            _ = try a.fleet.confirm(transfer.id, userConfirmed: true)
        }
        try check("blocked-transfer-keeps-primary-and-epoch", a.fleet.current()!.roster!.primaryID == a.member.id
                  && a.fleet.current()!.epoch == 1)
        let hidden = try q.fleet.envelope()!.body
        let hiddenText = String(decoding: hidden, as: UTF8.self)
        let hiddenEnvelope = String(decoding: try JSONEncoder().encode(q.fleet.envelope()!), as: UTF8.self)
        try check("hidden-main-no-public-key-comment-in-body-or-envelope",
                  !hiddenText.contains("example-private-main-comment") && !hiddenEnvelope.contains("example-private-main-comment"))
        try check("hidden-main-no-name-address-id-role-version", !hiddenText.contains(a.member.name)
                  && !hiddenText.contains("192.0.2.1") && !hiddenText.contains(a.member.id)
                  && !hiddenText.contains("\"primaryID\"") && !hiddenText.contains("\"version\"")
                  && q.fleet.current()!.slice!.primary == nil)
        let companySlice = try q.fleet.current()!.slice!
        try check("sub-own-primary-and-no-peer-graph-visible", q.fleet.current()!.slice!.group?.primaryDeviceID == p.member.id
                  && q.fleet.current()!.slice!.devices.count == 3
                  && (q.fleet.current()!.slice!.edges ?? []).allSatisfy { edge in
                      !(companySlice.devices.contains { $0.id == edge.from.id }
                        && companySlice.devices.contains { $0.id == edge.to.id })
                  })
        let visible = try a.fleet.propose([.setVisibility(groupID: "company", showMainPrimary: true)], actor: a.member.id)
        _ = try a.fleet.confirm(visible.id, userConfirmed: true)
        try q.fleet.accept(a.fleet.delivery(for: q.member.id)!)
        try check("show-main-opt-in-projection", q.fleet.current()!.slice!.primary?.name == a.member.name
                  && Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(q.fleet.current()!.slice!.primary!)) as! [String: Any]).keys) == ["name", "role"])
        let stale = try a.fleet.propose([.renameGroup(id: "company", name: "example stale")], actor: a.member.id)
        let fresh = try a.fleet.propose([.renameDevice(id: b.member.id, name: "example renamed")], actor: a.member.id)
        _ = try a.fleet.confirm(fresh.id, userConfirmed: true)
        try rejects("stale-proposal-cannot-overwrite-new-roster", expected: .staleProposal) {
            _ = try a.fleet.confirm(stale.id, userConfirmed: true)
        }
        let service = DeviceFleetStore(registry: a.registry, environment: a.environment)
        try rejects("foreign-service-cannot-confirm-token", expected: .primaryRequired) { _ = try service.confirm(stale.id, userConfirmed: true) }
        let graph = try a.fleet.readGraph()!.roster!
        try rejects("DM-02-MAIN-to-SUB-preview-refused", expected: .reverseEnrollment) {
            _ = try DeviceFleetGraphService.propose(roster: graph, actor: a.member.id,
                changes: [.moveDevice(id: c.member.id, groupID: "company")])
        }
        // Model a valid older signed downgrade: the current proposal UI can no longer create one.
        var oldSignedMove = graph
        oldSignedMove.devices[oldSignedMove.devices.firstIndex { $0.id == c.member.id }!].groupID = "company"
        oldSignedMove.groups[oldSignedMove.groups.firstIndex { $0.id == "company" }!].showMainPrimary = false
        oldSignedMove.edges.removeAll { !$0.locked && ($0.from == .device(c.member.id) || $0.to == .device(c.member.id)) }
        oldSignedMove.edges += DeviceFleetRoster.defaults(groups: oldSignedMove.groups, devices: oldSignedMove.devices).filter {
            !$0.locked && ($0.from == .device(c.member.id) || $0.to == .device(c.member.id))
        }
        try a.fleet.publish(&oldSignedMove)
        try c.fleet.accept(a.fleet.delivery(for: c.member.id)!)
        try check("main-to-sub-awaits-local-controller-consent", !method(c, caller: p, "document_inspect"))
        if let slice = try c.fleet.pendingConsent() { try c.fleet.approveConsent(revision: slice.revision, controllers: slice.controllers) }
        try check("signed-move-main-to-sub-changes-trust-and-keys", c.fleet.trust()?.kind == .managed
                  && c.fleet.current()?.slice?.primary == nil
                  && !c.registry.fleetHasAuthorizedFingerprint(p.member.clientKeyFingerprint!)
                  && c.registry.fleetHasAuthorizedFingerprint(a.member.clientKeyFingerprint!))
        try rejects("signed-move-sub-to-main-refused-even-main-authority", expected: .reverseEnrollment) {
            _ = try a.fleet.propose([.moveDevice(id: c.member.id, groupID: "main")], actor: a.member.id)
        }
        try check("blocked-sub-promotion-preserves-managed-identity", c.fleet.trust()?.kind == .managed && c.fleet.current()?.slice != nil)
        let extra = try make(8, group: "extra", role: .primary, kind: .managed)
        var pendingSub = extra.member; pendingSub.role = .secondary
        // A pending SUB member must not gain temporary MAIN access even before roster enrollment.
        _ = try a.registry.authorize(publicKey: pendingSub.clientPublicKey!, deviceID: pendingSub.id)
        try a.fleet.queue(pendingSub)
        let cleanup = try a.fleet.propose([.renameGroup(id: "main", name: "example MAIN"),
            .setManagerDisplayName(groupID: "main", name: "example MAIN manager")], actor: a.member.id)
        _ = try a.fleet.confirm(cleanup.id, userConfirmed: true)
        try check("pending-sub-key-not-preserved-in-main", !a.registry.fleetHasAuthorizedFingerprint(pendingSub.clientKeyFingerprint!))
        try check("manager-display-name-confirmed-service", a.fleet.current()!.roster!.groups.first { $0.id == "main" }?.managerDisplayName == "example MAIN manager")
        let extraGroup = DeviceFleetGroup(id: "extra", name: "example extra", type: .sub, primaryDeviceID: extra.member.id,
                                         parentGroupID: "company", managerDisplayName: "example manager")
        let add = try a.fleet.propose([.addGroup(extraGroup, primary: extra.member)], actor: a.member.id)
        try check("add-group-preview-primary-parent-and-default-arrow",
                  add.preview.groups.contains(extraGroup)
                  && add.preview.edges.contains { $0.from == .group("main") && $0.to == .group("extra")
                      && $0.capabilities == DeviceFleetCapabilities.managed })
        var crossSub = add.preview
        crossSub.edges.append(.init(from: .device(p.member.id), to: .device(extra.member.id), direction: .oneway, capabilities: ["files"]))
        try rejects("sub-primary-cannot-control-other-sub-group", expected: .subAuthority) { try crossSub.validate() }
        _ = try a.fleet.confirm(add.id, userConfirmed: true)
        let extraSandbox = try make(9, group: "extra", role: .sandbox, kind: .sandbox)
        let sandboxProposal = try a.fleet.propose([.addSandbox(extraSandbox.member)], actor: a.member.id)
        try check("add-sandbox-default-limited-incoming-and-reverse-lock",
                  sandboxProposal.preview.incoming(to: extraSandbox.member.id).count == 2
                  && !sandboxProposal.preview.incoming(to: extraSandbox.member.id).contains { $0.clientKeyFingerprint == c.member.clientKeyFingerprint }
                  && sandboxProposal.preview.incoming(to: extraSandbox.member.id).allSatisfy {
                      $0.capabilities.sorted() == DeviceFleetCapabilities.sandbox.sorted()
                  } && sandboxProposal.preview.edges.contains {
                      $0.from == .device(extraSandbox.member.id) && $0.direction == .none && $0.locked
                  })
        _ = try a.fleet.confirm(sandboxProposal.id, userConfirmed: true)
        var twoMain = try a.fleet.current()!.roster!
        var anotherMain = groups[0]; anotherMain.id = "invalid-main"
        twoMain.groups.append(anotherMain)
        try rejects("multiple-main-groups-refused", expected: .malformed) { try twoMain.validate() }
        // Legacy v1 signed bytes, not v2 masquerading as v1; trust and SSH pins are unchanged.
        var legacyDevices: [[String: Any]] = []
        for fixture in [a,b,c,p,q,r,s,t] {
            var row = try DeviceDispatch.object(fixture.member)
            row["factionID"] = fixture.member.role == .sandbox ? "legacy-sandbox" : fixture.member.groupID
            row["groupID"] = nil
            row["role"] = fixture.member.role == .sandbox ? "sandbox"
                : (fixture.member.groupID == "company" ? "managed" : fixture.member.role.rawValue)
            legacyDevices.append(row)
        }
        let legacyRoster: [String: Any] = ["version": 100, "primaryID": a.member.id, "epoch": 1,
            "factions": [["id":"main","name":"example MAIN","kind":"owner","managerDisplayName":"example manager"],
                         ["id":"company","name":"example SUB","kind":"managed","managerDisplayName":"example company"],
                         ["id":"legacy-sandbox","name":"example sandbox","kind":"sandbox","managerDisplayName":"example manager"]],
            "devices": legacyDevices, "revoked": []]
        let bytes = try JSONSerialization.data(withJSONObject: ["schema":"tatwo.device-fleet.v1","roster":legacyRoster], options: [.sortedKeys])
        let legacySignature = try DeviceSignature.sign(bytes, namespace: DeviceFleetEnvelope.namespace, environment: a.environment)
        let legacy = DeviceFleetEnvelope(body: bytes, signature: legacySignature.0, publicKey: legacySignature.1)
        try b.fleet.accept(legacy)
        let migrated = try b.fleet.current()!.roster!
        try check("v1-read-migrates-groups-edges-no-repair", migrated.groups.count == 2 && !migrated.edges.isEmpty
                  && b.fleet.trust()?.pinnedPrimaryKey == a.member.clientKeyFingerprint
                  && b.registry.fleetHasAuthorizedFingerprint(a.member.clientKeyFingerprint!))
        try check("v1-migration-never-widens-sub-peers", migrated.incoming(to: q.member.id).count == 3
                  && !migrated.incoming(to: q.member.id).contains { $0.clientKeyFingerprint == p.member.clientKeyFingerprint })
        try check("v1-new-memory-and-sandbox-capabilities-default-off",
                  migrated.incoming(to: q.member.id).allSatisfy { $0.capabilities.sorted() == managed }
                  && migrated.incoming(to: s.member.id).allSatisfy { $0.capabilities.sorted() == sandbox })
        let rewritten = try DeviceFleetEnvelope.issue(.init(roster: migrated), environment: a.environment)
        let rewrittenText = String(decoding: rewritten.body, as: UTF8.self)
        try check("v1-write-is-v2-no-faction-format", rewrittenText.contains("tatwo.device-fleet.v2")
                  && rewrittenText.contains("\"groups\"") && rewrittenText.contains("\"groupID\"")
                  && !rewrittenText.contains("\"factions\"") && !rewrittenText.contains("\"managed\""))
        try rejects("v1-replay-still-refused", expected: .replay) { try b.fleet.accept(legacy) }
        let audit = try String(contentsOf: a.fleet.logURL, encoding: .utf8)
        try check("rejection-reasons-audited", audit.contains("fleet_reverseEdge") && audit.contains("fleet_signer")
                  && audit.contains("fleet_confirmationRequired"))
        // Fifth ruling: MAIN alone designates a role, without changing any effective capability.
        let baseline = try a.fleet.current()!.roster!
        let baselineIdentity = try DeviceIdentityStore.readLocal(entry: a.fleet.entry)
        let designation = try a.fleet.propose([.setSubPrimary(groupID: "company", deviceID: q.member.id)], actor: a.member.id)
        try check("g-designation-preview-only-before-confirmation", a.fleet.current()!.roster! == baseline
                  && designation.preview.groups.first { $0.id == "company" }?.primaryDeviceID == q.member.id
                  && designation.preview.devices.first { $0.id == p.member.id }?.role == .secondary
                  && designation.preview.edges == baseline.edges)
        try rejects("g-designation-requires-confirmation", expected: .confirmationRequired) {
            _ = try a.fleet.confirm(designation.id, userConfirmed: false)
        }
        for (name, actor, error) in [("g-secondary-cannot-designate", b.member.id, DeviceFleetError.primaryRequired),
                                    ("g-sub-cannot-designate", p.member.id, .managedLocked),
                                    ("g-sandbox-cannot-designate", s.member.id, .managedLocked)] {
            try rejects(name, expected: error) {
                _ = try DeviceFleetGraphService.propose(roster: baseline, actor: actor,
                    changes: [.setSubPrimary(groupID: "company", deviceID: p.member.id)])
            }
        }
        try rejects("g-sub-cannot-spoof-main-proposal-actor", expected: .managedLocked) {
            _ = try p.fleet.propose([.setSubPrimary(groupID: "company", deviceID: q.member.id)], actor: a.member.id)
        }
        for (group, device) in [("main", q.member.id), ("company", a.member.id),
                                ("company", s.member.id), ("company", extra.member.id), ("missing", q.member.id)] {
            try rejects("g-invalid-designation-\(group)-\(device)", expected: .role) {
                _ = try a.fleet.propose([.setSubPrimary(groupID: group, deviceID: device)], actor: a.member.id)
            }
        }
        var revokedCandidate = baseline; revokedCandidate.revoked.append(q.member.id)
        try rejects("g-revoked-cannot-be-designated", expected: .role) {
            _ = try DeviceFleetGraphService.propose(roster: revokedCandidate, actor: a.member.id,
                changes: [.setSubPrimary(groupID: "company", deviceID: q.member.id)])
        }
        _ = try a.fleet.confirm(designation.id, userConfirmed: true)
        for device in [p.member.id, r.member.id] {
            let change = try a.fleet.propose([.setSubPrimary(groupID: "company", deviceID: device)], actor: a.member.id)
            _ = try a.fleet.confirm(change.id, userConfirmed: true)
        }
        let cancel = try a.fleet.propose([.setSubPrimary(groupID: "company", deviceID: nil)], actor: a.member.id)
        _ = try a.fleet.confirm(cancel.id, userConfirmed: true)
        let unmarked = try a.fleet.current()!.roster!
        try check("g-designate-replace-cancel-primary", unmarked.groups.first { $0.id == "company" }!.primaryDeviceID.isEmpty
                  && unmarked.devices.filter { $0.groupID == "company" }.allSatisfy { $0.role == .secondary }
                  && unmarked.edges == baseline.edges && unmarked.primaryID == baseline.primaryID && unmarked.epoch == baseline.epoch
                  && DeviceIdentityStore.readLocal(entry: a.fleet.entry) == baselineIdentity)
        let staffEndpoints: [(DeviceFleetEndpoint, DeviceFleetEndpoint)] = [
            (.device(p.member.id), .device(q.member.id)), (.device(q.member.id), .device(r.member.id)),
            (.group("company"), .device(q.member.id)), (.device(p.member.id), .group("company"))]
        for direction in [DeviceFleetEdge.Direction.oneway, .mutual, .none] {
            for (from, to) in staffEndpoints {
                try rejects("g-peer-refused-\(from.id)-\(to.id)-\(direction)", expected: .staffPeersUnavailable) {
                    _ = try a.fleet.propose([.setEdge(.init(from: from, to: to, direction: direction,
                        capabilities: direction == .none ? [] : ["files"]))], actor: a.member.id)
                }
            }
        }
        try check("g-peer-proposals-all-refused", DeviceFleetError.staffPeersUnavailable.localizedDescription == "職員電腦之間的互聯暫不開放")
        // Authentic historical v2 bytes contain primary→secondary, mutual peers, and group→device.
        var historical = unmarked; historical.version += 1
        historical.groups[historical.groups.firstIndex { $0.id == "company" }!].primaryDeviceID = p.member.id
        historical.devices[historical.devices.firstIndex { $0.id == p.member.id }!].role = .primary
        historical.edges += [
            .init(from: .device(p.member.id), to: .device(q.member.id), direction: .oneway, capabilities: managed),
            .init(from: .device(q.member.id), to: .device(r.member.id), direction: .mutual, capabilities: all),
            .init(from: .group("company"), to: .device(q.member.id), direction: .oneway, capabilities: managed)]
        try historical.validate()
        var historicalState = try a.fleet.read()
        historicalState.envelope = try rawIssue(.init(roster: historical), environment: a.environment)
        try a.fleet.save(historicalState)
        var legacySlice = try historical.slice(for: q.member.id)
        legacySlice.devices = historical.devices.filter { $0.groupID == "company" }
        for peer in [p.member, r.member] {
            legacySlice.controllers.append(.init(clientKeyFingerprint: peer.clientKeyFingerprint!, clientPublicKey: peer.clientPublicKey!, capabilities: all))
            _ = try q.registry.authorize(publicKey: peer.clientPublicKey!, deviceID: peer.id)
        }
        try q.fleet.accept(rawIssue(.init(slice: legacySlice), environment: a.environment))
        try check("g-legacy-peer-keys-pruned-on-load-without-main-signing", !q.registry.fleetHasAuthorizedFingerprint(p.member.clientKeyFingerprint!)
                  && !q.registry.fleetHasAuthorizedFingerprint(r.member.clientKeyFingerprint!))
        let readOnlyState = try Data(contentsOf: a.fleet.url)
        _ = try a.fleet.current()
        try check("R4-DM-03-reading-never-signs-migration", Data(contentsOf: a.fleet.url) == readOnlyState)
        _ = try a.fleet.migrateStaffInterconnections(a.fleet.current()!, trust: a.fleet.trust()!)
        let migratedPeers = try a.fleet.current()!.roster!
        try check("g-next-signature-removes-legacy-peer-arrows", migratedPeers.version == historical.version + 1
                  && !migratedPeers.edges.contains { migratedPeers.isStaffInterconnection($0) }
                  && migratedPeers.edges == historical.edges.filter { !historical.isStaffInterconnection($0) }
                  && migratedPeers.groups.first { $0.id == "company" }?.primaryDeviceID == p.member.id)
        try check("R3-DM-05-explicit-sync-signs-security-migration", migratedPeers.version == historical.version + 1)
        try q.fleet.accept(a.fleet.delivery(for: q.member.id)!)
        try check("g-migration-removes-peer-keys-and-live-gate", !q.registry.fleetHasAuthorizedFingerprint(p.member.clientKeyFingerprint!)
                  && !q.registry.fleetHasAuthorizedFingerprint(r.member.clientKeyFingerprint!)
                  && !method(q, caller: p, "document_inspect") && !method(q, caller: r, "memory_list")
                  && method(q, caller: a, "document_inspect"))
        let issued = try DeviceFleetEnvelope.issue(.init(roster: historical), environment: a.environment).verified(trust: a.fleet.trust()!)
        try check("g-direct-issuance-also-migrates", issued.roster!.edges == migratedPeers.edges)
        let issuedSlice = try DeviceFleetEnvelope.issue(.init(slice: historical.slice(for: q.member.id)), environment: a.environment)
            .verified(trust: q.fleet.trust()!).slice!
        try check("g-delivery-issuance-also-removes-colleagues", !issuedSlice.controllers.contains { controller in
            historical.devices.contains { $0.groupID == "company" && $0.clientKeyFingerprint == controller.clientKeyFingerprint }
        })
        let manual = Data((b.member.clientPublicKey!.trimmingCharacters(in: .newlines) + " manual-owner\r\n").utf8)
        let old = try Data(contentsOf: a.registry.authorizedKeysURL)
        try DeviceDispatchSafeFile.write(manual + old, url: a.registry.authorizedKeysURL)
        try a.fleet.reconcile(a.fleet.current()!)
        try check("g-non-revocation-keeps-user-bytes", Data(contentsOf: a.registry.authorizedKeysURL).starts(with: manual))
        let original = try Data(contentsOf: a.registry.authorizedKeysURL)
        try a.fleet.revoke(b.member.id)
        try check("g-revoke-removes-unmarked-same-key", !a.registry.fleetHasAuthorizedFingerprint(b.member.clientKeyFingerprint!))
        let backup = try fm.contentsOfDirectory(at: a.registry.root.appendingPathComponent("backups/authorized_keys"), includingPropertiesForKeys: nil).first { $0.pathExtension == "bak" }!
        try check("g-revoke-backup-exact", Data(contentsOf: backup) == original)
        try DeviceDispatchSafeFile.write(Data(contentsOf: backup), url: a.registry.authorizedKeysURL)
        try check("g-revoke-backup-restorable", Data(contentsOf: a.registry.authorizedKeysURL) == original)
        print("W187GRAPH SUMMARY checks=\(checks) failures=0")
    }
}
#endif
