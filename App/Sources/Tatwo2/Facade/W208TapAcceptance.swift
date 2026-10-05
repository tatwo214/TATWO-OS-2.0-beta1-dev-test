#if DEBUG
import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

/// Native UI models, native queue and native connector flow; existing shared fake Pods only.
@MainActor
enum W208TapAcceptance {
    static func run() async throws -> Bool {
        var failures = 0, passed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failures += 1 }
            print("W208 \(value ? "PASS" : "FAIL") \(label)")
        }
        defer { print("W208 SUMMARY failures=\(failures) passed=\(passed)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_LIVE_ROOT"] else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: path).appendingPathComponent("w208")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifacts = URL(fileURLWithPath: env["TATWO2_SELFTEST_ARTIFACTS"] ?? root.path)
        try await cleanupGate(check, artifacts: artifacts)
        try await connectors(check, root: root, artifacts: artifacts)
        try await lowRisk(check, root: root)
        try await conversations(check, root: root, artifacts: artifacts, env: env)
        return failures == 0
    }

    private static func cleanupGate(_ check: (Bool, String) -> Void, artifacts: URL) async throws {
        let world = try HandsConnectAcceptance.World(artifacts, "cleanup-card-host")
        let offer = try await HandsConnectLocalLink(host: world.host, ownerID: HandsConnectAcceptance.hostID).offer()
        let keep = HandsConnectorScan.Match(id: "private-keep", name: "TATWO（Primary One）", auth: "oauth", serverURL: offer.mcpURL)
        var remove = keep; remove.id = "private-remove"; remove.name += "2"
        let preview = HandsConnectorCleanup.Preview(key: "fixture", identity: "fixture", generation: 0, keeping: keep, removing: [remove])
        check(preview.text.contains("保留：" + keep.name) && preview.text.contains("刪除 1 份：") && preview.text.contains(remove.name)
              && !preview.text.contains("private-keep") && !preview.text.contains("private-remove") && !preview.text.contains("https://"),
              "W210-6 confirmation separates keep/delete names and hides internal IDs and server URL")
        let before = BrowserSensitivePageGate.isActive
        for confirmation in [false, true] {
            let context = HandsConnectCardContext(phase: .connected, offer: offer, cleanupPreview: confirmation ? preview : nil)
            let pane = HandsConnectSheetView(card: .connected("已連線"), context: context, actions: HandsConnectCardActions())
            guard let rendered = GlobalDMChatAcceptance.renderSync(pane, size: CGSize(width: 480, height: 650), scheme: .light) else {
                check(false, "W210-2 actual cleanup card renders"); continue
            }
            try await Task.sleep(for: .milliseconds(30))
            check(ComputerUseController.refusesSelf(pid: ProcessInfo.processInfo.processIdentifier, lane: .externalApplication,
                    sensitivePageOpen: BrowserSensitivePageGate.isActive),
                  "W210-2 Computer Use denied for cleanup " + (confirmation ? "confirmation" : "entry"))
            if confirmation {
                var seen = Set<ObjectIdentifier>()
                func visibleText(_ object: NSObject) -> String {
                    guard seen.count < 3000, seen.insert(ObjectIdentifier(object)).inserted else { return "" }
                    if let view = object as? NSView, view.isAccessibilityHidden() { return "" }
                    var text = DMBrowserAcceptance.axText(object)
                    for child in DMBrowserAcceptance.axObject(object, "accessibilityChildren", legacy: "AXChildren") as? [NSObject] ?? [] {
                        text += visibleText(child)
                    }
                    if let view = object as? NSView { for child in view.subviews { text += visibleText(child) } }
                    return text
                }
                let text = visibleText(rendered.window) + visibleText(rendered.host)
                check(text.contains("保留") && text.contains(remove.name) && !text.contains(offer.publicHost),
                      "W210-6 actual confirmation AX hides server address even when connected card has a host offer")
            }
            GlobalDMChatAcceptance.save(rendered, "w210-cleanup-\(confirmation).png", to: artifacts)
            rendered.close()
            try await Task.sleep(for: .milliseconds(30))
        }
        check(BrowserSensitivePageGate.isActive == before, "W210-2 cleanup card dismissal releases existing sensitive gate")
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TapError.remote("W208 synthetic scenario timed out")
    }

    private static func connectors(_ check: (Bool, String) -> Void, root: URL, artifacts: URL) async throws {
        typealias A = HandsConnectAcceptance
        let registryURL = root.appendingPathComponent("connectors.json")
        let registry = HandsConnectorRegistry(url: registryURL)
        let url = "https://" + A.publicHost + "/mcp"
        let key = HandsConnectorRegistry.key(device: A.hostID, identity: A.identity, mcpURL: url)
        let connector = HandsConnectorScan.Match(id: "fixture-original", name: "TATWO（Primary One）", auth: "oauth", serverURL: url, detailPath: "/plugins/fixture-original")
        // First connect must record the website ID, not a host grant ID.
        let first = try A.World(root, "first", connectors: registry)
        try await finish(first, resolving: connector)
        check(registry.record(key)?.connector == connector && first.pod.createdNames == [connector.name], "first connection saves connector ID/name/URL locally")
        let pending = HandsConnectDigestBook(url: root.appendingPathComponent("pending-without-id.json"), maxEntries: 16, lifetime: 7 * 24 * 3600)
        let missingID = try A.World(root, "created-without-id", pendingCreateBook: pending, connectors: HandsConnectorRegistry(url: root.appendingPathComponent("unknown-id.json")))
        try await finish(missingID)
        check(pending.contains(HandsPendingCreates.digest(A.identity + "|" + url)) && missingID.flow.problem != nil,
              "a success without a website ID retains the pending marker and displays the persistence limitation")
        let afterMissingID = try A.World(root, "restart-without-id", pendingCreateBook: pending, connectors: HandsConnectorRegistry(url: root.appendingPathComponent("unknown-id.json")))
        afterMissingID.flow.offer(); try await wait { A.isConfirm(afterMissingID.flow.card) }; afterMissingID.flow.connect()
        try await wait { afterMissingID.flow.phase == .needsManual }
        check(afterMissingID.pod.createdNames.isEmpty && afterMissingID.pod.byNameCalls == [connector.name], "restart after an unknown website ID only seeks the original name, never another Create")
        afterMissingID.flow.cancel(reason: "fixture_done")
        var metrics = "round\tscenario\tlatency_ms\tresident_bytes\tconnectors\n"
        let scenarios = ["gateway_restart", "app_restart", "envelope_expiry", "authorization_expiry", "page_reload"]
        var station = first.pod.scanResult.matches
        for round in 1...20 {
            let started = Date()
            // A new registry reader and flow reproduce process restart without losing the original ID.
            let world = try A.World(root, "reconnect-\(round)", connectors: HandsConnectorRegistry(url: registryURL))
            world.pod.scanResult.matches = station
            world.pod.authorization = round % 5 == 4 ? .needsReconnect : .connected
            world.pod.resolvedConnector = connector
            if round % 5 == 4 { try await finish(world) }
            else {
                world.flow.offer()
                try await wait { A.isConfirm(world.flow.card) }
                world.flow.connect()
                try await wait { world.flow.phase == .connected }
                check(world.host.currentAttemptID == nil, "\(scenarios[(round - 1) % 5]) does not open an OAuth window while ChatGPT authorization remains")
            }
            let saved = HandsConnectorRegistry(url: registryURL).record(key)
            check(saved?.connector.id == connector.id && !world.pod.calls.contains("scan") && world.pod.createdNames.isEmpty
                  && (round % 5 != 4 || world.pod.calls.contains("reconnect:fixture-original")), "reconnect round \(round): one connector, original ID, no list read or Create")
            station = world.pod.scanResult.matches
            let row = reconnectMetric(round: round, scenario: scenarios[(round - 1) % 5], started: started, pod: world.pod)
            check(row.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").last == "1", "W210-8 measured TATWO count is one at round \(round)")
            metrics += row
            world.flow.dismiss()
        }
        try metrics.write(to: artifacts.appendingPathComponent("w208-reconnect-metrics.tsv"), atomically: true, encoding: .utf8)
        let counting = try A.World(root, "metric-extra-row")
        var extra = connector; extra.id = "metric-extra"; extra.name += "2"
        var notTatwo = connector; notTatwo.id = "other-app"; notTatwo.name = "Other app"
        counting.pod.scanResult.matches = [connector, extra, notTatwo]
        let counted = reconnectMetric(round: 0, scenario: "counterexample", started: Date(), pod: counting.pod)
        check(counted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").last == "2",
              "W210-8 TSV detects an extra actual TATWO row and excludes another app instead of hardcoding one")
        // Temporary stopped reports change only the card, not connector identity or authorization.
        first.flow.connectionChanged(ended: [A.hostID], ending: .stopped, level: nil)
        first.flow.connectionChanged(ended: [], ending: nil, level: 2, connected: [A.hostID])
        check(first.flow.card?.isConnectedResult == true && registry.record(key)?.connector.id == connector.id, "gateway stopped/recovered restores card without new connector")
        let guided = try A.World(root, "guided-existing", connectors: registry)
        guided.pod.authorization = .connected
        guided.flow.offer(); try await wait { A.isConfirm(guided.flow.card) }; guided.flow.connect(manual: true)
        try await wait { guided.flow.phase == .connected }
        check(guided.pod.createdNames.isEmpty && !guided.pod.calls.contains("scan"), "manual fallback also respects the persisted connector ID")
        let unknown = try A.World(root, "unknown-authorization", connectors: registry)
        unknown.pod.authorization = .unknown
        unknown.flow.offer(); try await wait { A.isConfirm(unknown.flow.card) }; unknown.flow.connect()
        try await wait { unknown.flow.phase == .needsManual }
        check(unknown.pod.createdNames.isEmpty && !unknown.pod.calls.contains("scan"), "unreadable authorization never replaces a remembered connector")
        unknown.flow.cancel(reason: "fixture_done")
        check(registry.record(HandsConnectorRegistry.key(device: A.hostID, identity: "other-account", mcpURL: url)) == nil,
              "connector identity is scoped to the local installation, account and server")
        let unfinished = try A.World(root, "unfinished")
        unfinished.pod.scanResult.matches = [connector]
        try await finish(unfinished)
        check(unfinished.pod.createdNames.isEmpty && unfinished.pod.calls.contains("reconnect:fixture-original"), "unfinished OAuth connector is reused")
        let mismatch = try A.World(root, "wrong-server")
        mismatch.pod.scanResult.conflictingNames = [connector.name]
        mismatch.flow.offer(); try await wait { A.isConfirm(mismatch.flow.card) }; mismatch.flow.connect()
        try await wait { mismatch.flow.phase == .needsManual }
        check(mismatch.pod.createdNames.isEmpty && mismatch.pod.deletedConnectors.isEmpty, "same name on a different server stops at manual card without mutation")
        mismatch.flow.cancel(reason: "fixture_done")

        let cleanupWorld = try A.World(root, "cleanup", connectors: registry)
        var duplicate = connector; duplicate.id = "fixture-duplicate"; duplicate.name += "12"
        var otherDevice = duplicate; otherDevice.id = "other-device"; otherDevice.name = "TATWO（Other Device）2"
        var otherURL = duplicate; otherURL.id = "other-url"; otherURL.serverURL = "https://other.example.com/mcp"
        otherDevice.connected = true; otherURL.connected = true
        // Upgrade an existing account with numbered duplicates before any ID has been saved locally.
        let migrationRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("migration.json"))
        let migration = try A.World(root, "migration", connectors: migrationRegistry)
        var active = connector; active.name += "4"; active.connected = true
        migration.pod.scanResult.matches = [active, duplicate, otherDevice, otherURL]
        migration.flow.showConnected(hosts: [A.hostID], level: 2)
        migration.flow.prepareConnectorCleanup()
        try await wait { !migration.flow.cleaningConnectors }
        check(migration.flow.cleanupPreview?.keeping == active && migrationRegistry.record(key)?.connector == active
              && migration.pod.deletedConnectors.isEmpty && migration.pod.createdNames.isEmpty,
              "upgrade discovers the uniquely connected numbered original and only previews cleanup")
        migration.flow.cancelConnectorCleanup()
        let ambiguousRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("ambiguous-migration.json"))
        let ambiguous = try A.World(root, "ambiguous-migration", connectors: ambiguousRegistry)
        var secondActive = duplicate; secondActive.connected = true
        ambiguous.pod.scanResult.matches = [active, secondActive]
        ambiguous.flow.showConnected(hosts: [A.hostID], level: 2)
        ambiguous.flow.prepareConnectorCleanup()
        try await wait { !ambiguous.flow.cleaningConnectors }
        check(ambiguous.flow.cleanupPreview == nil && ambiguousRegistry.record(key) == nil && ambiguous.pod.deletedConnectors.isEmpty,
              "upgrade with two connected originals cannot choose one or delete")
        let changedRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("changed-migration.json"))
        var generation = 0
        let changed = try A.World(root, "changed-migration", loginGeneration: { generation += 1; return generation }, connectors: changedRegistry)
        changed.pod.scanResult.matches = [active, duplicate]
        changed.flow.showConnected(hosts: [A.hostID], level: 2)
        changed.flow.prepareConnectorCleanup()
        try await wait { !changed.flow.cleaningConnectors }
        check(changed.flow.cleanupPreview == nil && changedRegistry.record(key) == nil && changed.pod.deletedConnectors.isEmpty,
              "account generation changing during migration cannot persist another account's connector")
        let foreignRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("foreign-migration.json"))
        let foreign = try A.World(root, "foreign-migration", connectors: foreignRegistry)
        foreign.pod.scanResult.matches = [active, duplicate]
        foreign.flow.showConnected(hosts: [A.secondaryID], level: 2)
        foreign.flow.prepareConnectorCleanup()
        try await wait { !foreign.flow.cleaningConnectors }
        check(foreign.flow.cleanupPreview == nil && foreignRegistry.record(key) == nil && !foreign.pod.calls.contains("scan"),
              "a resolver returning another device cannot scan or migrate its connectors")
        cleanupWorld.pod.authorization = .connected
        cleanupWorld.pod.scanResult.matches = [connector, duplicate, otherDevice, otherURL]
        let cleanup = HandsConnectorCleanup(registry: registry)
        guard let preview = cleanup.preview(scan: cleanupWorld.pod.scanResult, key: key, identity: A.identity, generation: 0,
                                             base: connector.name, url: url) else { return check(false, "cleanup preview") }
        check(preview.removing.map(\.id) == [duplicate.id] && cleanupWorld.pod.deletedConnectors.isEmpty, "cleanup preview keeps active connector and does not delete until confirmation")
        cleanupWorld.pod.beforeDelete = {
            let directory = registryURL.deletingLastPathComponent().appendingPathComponent("connector-archive")
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.contains { file in
                guard let data = HandsFiles.readSecure(file, limit: 64 * 1024), let rows = try? JSONDecoder().decode([HandsConnectorScan.Match].self, from: data) else { return false }
                return rows.contains(duplicate) && rows.contains(connector)
            } == true
        }
        cleanupWorld.flow.showConnected(hosts: [A.hostID], level: 2)
        cleanupWorld.flow.prepareConnectorCleanup()
        try await wait { !cleanupWorld.flow.cleaningConnectors && cleanupWorld.flow.cleanupPreview != nil }
        cleanupWorld.flow.cancelConnectorCleanup()
        check(cleanupWorld.flow.cleanupPreview == nil && cleanupWorld.pod.deletedConnectors.isEmpty, "canceling native cleanup confirmation does not delete")
        cleanupWorld.flow.prepareConnectorCleanup()
        try await wait { !cleanupWorld.flow.cleaningConnectors && cleanupWorld.flow.cleanupPreview != nil }
        cleanupWorld.flow.confirmConnectorCleanup()
        try await wait { !cleanupWorld.flow.cleaningConnectors && !cleanupWorld.pod.deletedConnectors.isEmpty }
        let removed = cleanupWorld.pod.deletedConnectors.count
        check(removed == 1 && cleanupWorld.pod.deletedConnectors == ["fixture-duplicate"]
              && cleanupWorld.pod.scanResult.matches.map(\.id) == [connector.id, otherDevice.id, otherURL.id], "confirmed cleanup archives reconstruction metadata before deleting only same-device/same-URL duplicates")
        do {
            _ = try await cleanup.execute(preview, pod: cleanupWorld.pod, identity: "changed", generation: 1)
            check(false, "changed-account cleanup rejected")
        } catch { check(cleanupWorld.pod.deletedConnectors.count == 1, "changed-account confirmation cannot delete") }
        for change in ["account", "generation"] {
            var epoch = 0
            let waiting = try A.World(root, "delete-wait-" + change, loginGeneration: { epoch }, connectors: registry)
            waiting.pod.authorization = .connected
            waiting.pod.scanResult.matches = [connector, duplicate]
            waiting.flow.showConnected(hosts: [A.hostID], level: 2)
            waiting.flow.prepareConnectorCleanup()
            try await wait { waiting.flow.cleanupPreview != nil && !waiting.flow.cleaningConnectors }
            var returned = false
            waiting.pod.deleteWaiting = {
                if change == "account" { waiting.pod.identityValue = "account-B" } else { epoch += 1 }
                waiting.flow.invalidate("pod_logged_out")
                try? await Task.sleep(for: .milliseconds(10))
                returned = true
            }
            waiting.flow.confirmConnectorCleanup()
            try await wait { returned && !waiting.flow.cleaningConnectors }
            check(waiting.pod.deletedConnectors.isEmpty && !waiting.pod.held,
                  "W210-1 " + change + " changes while deletion waits: deleted=false and no final Delete")
        }
        let superseded = try A.World(root, "superseded-cleanup", connectors: registry)
        superseded.pod.authorization = .connected; superseded.pod.scanResult.matches = [connector, duplicate]
        superseded.flow.showConnected(hosts: [A.hostID], level: 2)
        superseded.flow.prepareConnectorCleanup()
        try await wait { superseded.flow.cleanupPreview != nil && !superseded.flow.cleaningConnectors }
        var oldDelete: CheckedContinuation<Void, Never>?
        superseded.pod.deleteWaiting = { await withCheckedContinuation { oldDelete = $0 } }
        superseded.flow.confirmConnectorCleanup()
        try await wait { oldDelete != nil }
        superseded.flow.invalidate("pod_logged_out")
        superseded.pod.authorization = .needsReconnect
        superseded.flow.offer(); try await wait { A.isConfirm(superseded.flow.card) }
        superseded.flow.connect(manual: true)
        try await wait {
            if case .manual? = superseded.flow.card { return superseded.pod.held }
            return false
        }
        oldDelete?.resume()
        try await Task.sleep(for: .milliseconds(30))
        check(superseded.pod.held && superseded.flow.problem == nil,
              "W210-5 cancelled cleanup cannot release or overwrite a later connection run")
        superseded.flow.cancel(reason: "fixture_done")
        let lateRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("late-validity.json"))
        try lateRegistry.remember(connector, key: key)
        let late = try A.World(root, "late-validity", connectors: lateRegistry)
        late.pod.authorization = .connected; late.pod.scanResult.matches = [connector, duplicate]
        let lateCleanup = HandsConnectorCleanup(registry: lateRegistry)
        let latePreview = lateCleanup.preview(scan: late.pod.scanResult, key: key, identity: A.identity, generation: 0, base: connector.name, url: url)!
        var delayedRead: CheckedContinuation<Void, Never>?
        late.pod.identityWaiting = { read in
            if read == 2 { await withCheckedContinuation { delayedRead = $0 } }
        }
        late.pod.deleteWaiting = { try? await wait { delayedRead != nil } }
        _ = await late.pod.acquireExclusive(timeout: 1)
        let lateRemoved = try await lateCleanup.execute(latePreview, pod: late.pod, identity: A.identity, generation: 0)
        late.pod.releaseExclusive()
        _ = await late.pod.acquireExclusive(timeout: 1)
        late.pod.identityValue = "new-account-for-next-lease"
        delayedRead?.resume()
        try await Task.sleep(for: .milliseconds(20))
        check(lateRemoved == 1 && late.pod.held, "W210-1 cancelled validity read cannot release a later Pod lease")
        late.pod.releaseExclusive()
        late.pod.identityWaiting = nil; late.pod.identityValue = A.identity
        late.pod.scanResult.matches = [connector, duplicate]
        var cancelledDelete: CheckedContinuation<Void, Never>?
        late.pod.deleteWaiting = { await withCheckedContinuation { cancelledDelete = $0 } }
        _ = await late.pod.acquireExclusive(timeout: 1)
        let cancelled = Task { try await lateCleanup.execute(latePreview, pod: late.pod, identity: A.identity, generation: 0) }
        try await wait { cancelledDelete != nil }
        cancelled.cancel(); late.pod.releaseExclusive()
        _ = await late.pod.acquireExclusive(timeout: 1)
        late.pod.identityValue = "account-B-in-next-lease"
        try await Task.sleep(for: .milliseconds(80))
        check(late.pod.held, "W210-1 parent cancellation stops validity monitor before the next account lease")
        cancelledDelete?.resume(); _ = try? await cancelled.value
        late.pod.releaseExclusive()
        // If reconstruction metadata cannot be written, even a confirmed action cannot delete.
        let blockedRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("blocked/connectors.json"))
        try blockedRegistry.remember(connector, key: key)
        try Data("blocked".utf8).write(to: blockedRegistry.url.deletingLastPathComponent().appendingPathComponent("connector-archive"))
        cleanupWorld.pod.scanResult.matches = [connector, duplicate]
        let blocked = HandsConnectorCleanup(registry: blockedRegistry)
        if let blockedPreview = blocked.preview(scan: cleanupWorld.pod.scanResult, key: key, identity: A.identity, generation: 0, base: connector.name, url: url) {
            do { _ = try await blocked.execute(blockedPreview, pod: cleanupWorld.pod, identity: A.identity, generation: 0); check(false, "archive failure aborts cleanup") }
            catch { check(cleanupWorld.pod.deletedConnectors.count == 1, "archive failure aborts cleanup before any deletion") }
        } else { check(false, "blocked archive preview") }
        // A fresh App can revoke using its native account record without rereading ChatGPT lists.
        let accounts = HandsConnectAccounts(url: root.appendingPathComponent("fresh-accounts.json"))
        accounts.remember(HandsConnectAccountRecord(host: A.hostID, identityTag: HandsConnectAccounts.identityTag(A.identity), grantTag: nil, level: 2, at: Date()))
        let fresh = try A.World(root, "fresh-disconnect", disconnect: { _, hosts in Dictionary(uniqueKeysWithValues: hosts.map { ($0.lowercased(), .revoked) }) }, accounts: accounts, connectors: registry)
        fresh.flow.showConnected(hosts: [A.hostID], level: 2)
        fresh.flow.disconnect()
        try await wait { if case .disconnected? = fresh.flow.card { return true }; return false }
        check(registry.record(key)?.needsAuthorization == true && fresh.pod.calls.isEmpty, "native disconnect after App restart retains ID and records the need to pair again without opening ChatGPT")
        let repairing = try A.World(root, "native-repair", connectors: registry)
        repairing.pod.authorization = .connected; repairing.pod.resolvedConnector = connector
        try await finish(repairing)
        check(repairing.pod.calls.contains("reconnect:fixture-original") && repairing.pod.createdNames.isEmpty && registry.record(key)?.needsAuthorization == false, "native revoke reconnects the original connector even if the website still says Connected")
        for route in ["verdict-revoked", "host-missing-account"] {
            let revokedRegistry = HandsConnectorRegistry(url: root.appendingPathComponent(route + ".json"))
            try revokedRegistry.remember(connector, key: key)
            let revokedAccounts = HandsConnectAccounts(url: root.appendingPathComponent(route + "-accounts.json"))
            revokedAccounts.remember(HandsConnectAccountRecord(host: A.hostID, identityTag: HandsConnectAccounts.identityTag(A.identity), grantTag: "old-grant", level: 2, at: Date()))
            let otherKey = HandsConnectorRegistry.key(device: A.hostID, identity: "other-account", mcpURL: url)
            try revokedRegistry.remember(connector, key: otherKey)
            revokedAccounts.remember(HandsConnectAccountRecord(host: A.hostID, identityTag: HandsConnectAccounts.identityTag("other-account"), grantTag: "other-grant", level: 2, at: Date()))
            let revoked = try A.World(root, route, accounts: revokedAccounts, connectors: revokedRegistry, hostAuthorization: { _, _ in false })
            revoked.pod.authorization = .connected
            revoked.flow.offer(); try await wait { A.isConfirm(revoked.flow.card) }
            revoked.flow.showConnected(hosts: [A.hostID], level: 2)
            if route == "verdict-revoked" {
                revoked.flow.connectionChanged(ended: [A.hostID], ending: .revoked, level: nil)
                check(revokedRegistry.record(key)?.needsAuthorization == true, "W210-3 host revoke verdict persists needsAuthorization")
                check(revokedRegistry.record(otherKey)?.needsAuthorization == false,
                      "W210-3 revoking current account leaves another account authorization unchanged")
            }
            revoked.flow.offer(); try await wait { A.isConfirm(revoked.flow.card) }; revoked.flow.connect()
            try await wait { revoked.flow.phase == .connected || revoked.pod.calls.contains("reconnect:fixture-original") }
            check(revoked.pod.calls.contains("reconnect:fixture-original") && revoked.pod.createdNames.isEmpty,
                  "W210-3 " + route + " reconnects original ID instead of trusting website Connected")
            revoked.flow.cancel(reason: "fixture_done")
        }
        for allowed in [true, false] {
            let upgradedRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("upgrade-\(allowed).json"))
            let upgraded = try A.World(root, "upgrade-\(allowed)", connectors: upgradedRegistry, hostAuthorization: { _, _ in allowed })
            var authorized = connector; authorized.connected = true
            upgraded.pod.scanResult.matches = [authorized]
            upgraded.flow.offer(); try await wait { A.isConfirm(upgraded.flow.card) }; upgraded.flow.connect()
            try await wait { upgraded.host.currentAttemptID != nil || upgraded.flow.phase == .connected }
            if allowed {
                check(upgraded.host.currentAttemptID == nil && upgraded.pod.calls.allSatisfy { !$0.hasPrefix("reconnect:") }
                      && upgradedRegistry.record(key)?.connector.id == connector.id && upgraded.flow.phase == .connected,
                      "W210-4 unique OAuth Connected plus native grant adopts ID without pairing window")
            } else {
                try await wait { upgraded.pod.calls.contains("reconnect:fixture-original") }
                check(upgraded.host.currentAttemptID != nil && upgradedRegistry.record(key) == nil,
                      "W210-4 host revoke prevents adoption and keeps original pairing path")
            }
            upgraded.flow.cancel(reason: "fixture_done")
        }
        let primaryOffer = try await HandsConnectLocalLink(host: first.host, ownerID: A.hostID).offer()
        let secondaryOffer = HandsConnectOffer(hostDeviceID: A.secondaryID, hostName: "Secondary Two", publicHost: "secondary.example.com",
            scope: primaryOffer.scope, callbackHosts: primaryOffer.callbackHosts, setupEpoch: primaryOffer.setupEpoch)
        var secondaryKeep = connector; secondaryKeep.id = "secondary-original"; secondaryKeep.name = "TATWO（Secondary Two）"; secondaryKeep.serverURL = secondaryOffer.mcpURL
        var secondaryDuplicate = secondaryKeep; secondaryDuplicate.id = "secondary-duplicate"; secondaryDuplicate.name += "2"
        for missing in [false, true] {
            let multiRegistry = HandsConnectorRegistry(url: root.appendingPathComponent("multi-\(missing).json"))
            try multiRegistry.remember(connector, key: key)
            try multiRegistry.remember(secondaryKeep, key: HandsConnectorRegistry.key(device: A.secondaryID, identity: A.identity, mcpURL: secondaryOffer.mcpURL))
            let multi = try A.World(root, "multi-\(missing)", connectors: multiRegistry, linkFor: { host in
                if host == A.hostID { return (W210OfferLink(value: primaryOffer), nil) }
                return missing ? (nil, "Secondary Two 離線") : (W210OfferLink(value: secondaryOffer), nil)
            })
            multi.pod.authorization = .connected
            multi.pod.scanResult.matches = [connector, duplicate, secondaryKeep, secondaryDuplicate]
            multi.flow.showConnected(hosts: [A.hostID, A.secondaryID], level: 2)
            multi.flow.prepareConnectorCleanup()
            try await wait { !multi.flow.cleaningConnectors }
            if missing {
                check(multi.flow.cleanupPreview != nil && multi.flow.problem?.contains("Secondary Two") == true,
                      "W210-5 unavailable device explained while known device still previews")
            } else {
                check(multi.flow.cleanupPreview?.text.contains(secondaryKeep.name) == true && multi.flow.cleanupPreview?.text.contains(connector.name) == true,
                      "W210-5 two devices preview in separate sections with both originals retained")
            }
            if multi.flow.cleanupPreview != nil {
                multi.flow.confirmConnectorCleanup(); try await wait { !multi.flow.cleaningConnectors }
                check(Set(multi.pod.deletedConnectors) == Set(missing ? [duplicate.id!] : [duplicate.id!, secondaryDuplicate.id!])
                      && multi.pod.scanResult.matches.contains(connector) && multi.pod.scanResult.matches.contains(secondaryKeep),
                      "W210-5 one confirmation deletes only confirmed devices and keeps each original")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: registryURL.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "connector registry is private 0600")
    }

    private static func lowRisk(_ check: (Bool, String) -> Void, root: URL) async throws {
        typealias A = HandsConnectAcceptance
        let url = "https://" + A.publicHost + "/mcp"
        let keep = HandsConnectorScan.Match(id: "private-keep", name: "TATWO（Primary One）", auth: "oauth", serverURL: url)
        var duplicate = keep; duplicate.id = "private-delete"; duplicate.name += "2"
        for action in ["dismiss", "disconnect"] {
            let registry = HandsConnectorRegistry(url: root.appendingPathComponent("preview-" + action + ".json"))
            try registry.remember(keep, key: HandsConnectorRegistry.key(device: A.hostID, identity: A.identity, mcpURL: url))
            let world = try A.World(root, "preview-" + action, disconnect: { _, hosts in
                Dictionary(uniqueKeysWithValues: hosts.map { ($0.lowercased(), .revoked) })
            }, connectors: registry)
            world.pod.authorization = .connected; world.pod.scanResult.matches = [keep, duplicate]
            world.flow.showConnected(hosts: [A.hostID], level: 2); world.flow.prepareConnectorCleanup()
            try await wait { !world.flow.cleaningConnectors && world.flow.cleanupPreview != nil }
            if action == "dismiss" { world.flow.dismiss() }
            else { world.flow.disconnect(); try await wait { !world.flow.disconnecting } }
            check(world.flow.cleanupPreview == nil && world.pod.deletedConnectors.isEmpty,
                  "W210-L stale cleanup preview cleared on " + action + " without deleting")
        }
        let log = HandsConnectLog(url: root.appendingPathComponent("pod-results.log"))
        let transport = W208TapPod(); transport.isRunning = true
        transport.responder = { cmd, _ in
            if cmd == "connectorInspect" { return ["authorization": "connected"] }
            if cmd == "connectorDelete" { return ["deleted": true] }
            return [:]
        }
        let tap = ChatGPTTap(transport: transport)
        let driver = ChatGPTConnectorPod(tap: tap, surface: { nil }); driver.connectLog = log
        defer { driver.releaseExclusive(); tap.sleep() }
        check(await driver.acquireExclusive(timeout: 1), "W210-L synthetic Pod acquires existing exclusive lease")
        _ = await driver.inspect(keep, url: url)
        _ = await driver.deleteConnector(duplicate, keeping: keep.id!, url: url)
        var unknown = keep; unknown.id = nil
        _ = await driver.inspect(unknown, url: url)
        _ = await driver.deleteConnector(keep, keeping: keep.id!, url: url)
        let lines = log.tail()
        check(lines.count == 4 && lines.contains { $0.contains("connectorInspect result=connected count=1") }
              && lines.contains { $0.contains("connectorDelete result=true count=1") }
              && lines.contains { $0.contains("connectorInspect result=unknown count=0") }
              && lines.contains { $0.contains("connectorDelete result=false count=0") }
              && lines.allSatisfy { !$0.contains("private-keep") && !$0.contains("private-delete") && !$0.contains(A.identity) && !$0.contains(A.publicHost) },
              "W210-L each inspect/delete logs only result and count, including refusals")
        let world = try A.World(root, "entry-log")
        let loginState = CurrentValueSubject<TapConnection, Never>(.off)
        let login = HandsPodLogin(state: loginState.eraseToAnyPublisher())
        let accounts = HandsConnectAccounts(url: root.appendingPathComponent("entry-accounts.json"))
        let entry = HandsConnectEntry(flow: world.flow, accounts: accounts, probeIdentity: { nil }, login: login)
        let before = HandsConnectLog.shared.tail().count
        entry.tap(); try await Task.sleep(for: .milliseconds(50))
        let added = Array(HandsConnectLog.shared.tail().dropFirst(before))
        check(added.filter { $0.contains("entry.tap") }.count == 1 && added.filter { $0.contains("entry.act") }.count == 1
              && added.allSatisfy { $0.contains("state=off") && $0.contains("branch=") } && entry.state == .hidden && world.flow.card == nil,
              "W210-L entry tap/act log state and branch without changing hidden-entry behavior")
    }

    private static func reconnectMetric(round: Int, scenario: String, started: Date, pod: HandsConnectAcceptance.FakePod) -> String {
        let count = pod.scanResult.matches.filter { $0.name.hasPrefix("TATWO（") }.count
        return "\(round)\t\(scenario)\t\(Int(Date().timeIntervalSince(started) * 1000))\t\(residentBytes())\t\(count)\n"
    }

    private struct W210OfferLink: HandsConnectLink {
        let value: HandsConnectOffer
        var isRemote: Bool { false }
        func offer() async throws -> HandsConnectOffer { value }
        func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus { throw CocoaError(.userCancelled) }
        func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus { throw CocoaError(.userCancelled) }
        func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus { throw CocoaError(.userCancelled) }
        func confirm(attemptID: String) async throws -> HandsConnectStatus { throw CocoaError(.userCancelled) }
    }

    private static func finish(_ world: HandsConnectAcceptance.World, resolving connector: HandsConnectorScan.Match? = nil) async throws {
        typealias A = HandsConnectAcceptance
        let chatgpt = A.FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, before: {
            if !world.pod.createdNames.isEmpty, var created = connector ?? world.pod.resolvedConnector {
                if world.pod.scanResult.matches.contains(where: { $0.id == created.id }) { created.id = "unexpected-created-" + UUID().uuidString }
                world.pod.scanResult.matches.append(created)
            }
        })
        var authCode: String?
        world.pod.fillBehavior = { code, _, _ in
            authCode = try? chatgpt.submit(code)
            if authCode != nil, let connector { world.pod.resolvedConnector = connector }
            return .filled
        }
        world.flow.offer(); try await wait { A.isConfirm(world.flow.card) }; world.flow.connect()
        try await wait { authCode?.isEmpty == false }
        let access = try chatgpt.token(authCode ?? "")
        try chatgpt.tools(access)
        try await wait { world.flow.phase == .connected }
    }

    private static func conversations(_ check: (Bool, String) -> Void, root: URL, artifacts: URL, env: [String: String]) async throws {
        let pod = W208TapPod(); pod.isRunning = true
        let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(100))
        defer { tap.sleep() }
        let space = ChatGPTSpaceModel(testTap: tap)
        let dm = ChatGPTConversationSession(tap: tap)
        let cid = "fixture-200-conversation"
        var transcripts: [String: [[String: Any]]] = [:]
        var branchReply: [String: Any]?
        pod.responder = { _, command in
            switch command["cmd"] as? String {
            case "get":
                let id = command["conversationID"] as? String ?? cid
                if let branch = command["branch"] as? String, let branchReply {
                    return ["messages": [branchReply], "leaf": branch, "current": false]
                }
                return ["messages": transcripts[id] ?? [], "leaf": transcripts[id]?.last?["id"] ?? "root", "current": true]
            case "list": return ["items": [["id": cid, "title": "合成壓力測試", "update_time": Date().timeIntervalSince1970]], "total": 1]
            case "projects", "gpts", "pins", "tools", "projectConversations": return ["items": []]
            case "home": return ["suggestions": []]
            default: return nil
            }
        }
        func complete(_ command: [String: Any], in conversation: String, answer: String) {
            let id = command["id"] as! String
            let node = "reply-" + id
            if command["cmd"] as? String != "regenerate" {
                transcripts[conversation, default: []].append(["id": "user-" + id, "role": "user", "text": command["text"] as? String ?? "fixture"])
            }
            transcripts[conversation, default: []].append(["id": node, "role": "assistant", "text": answer])
            if command["temporary"] as? Bool == true { pod.emit(["type": "stream", "id": id, "kind": "temporary"]) }
            pod.emit(["type": "stream", "id": id, "kind": "conversation", "conversationID": conversation])
            pod.emit(["type": "stream", "id": id, "kind": "text", "messageID": node, "full": answer])
            pod.emit(["type": "stream", "id": id, "kind": "finished"])
        }
        var notified = false
        let oldHost = IslandNotice.shared.hostAvailable
        IslandNotice.shared.hostAvailable = true
        defer { IslandNotice.shared.hostAvailable = oldHost }
        let noticeWatch = IslandNotice.shared.$current.sink { notice in if notice?.title == "ChatGPT 回覆好了" { notified = true } }
        let oldNotice = SpaceNotice.isEnabled(ChatGPTSpaceModel.noticeSpace)
        SpaceNotice.setEnabled(ChatGPTSpaceModel.noticeSpace, true)
        defer { noticeWatch.cancel(); SpaceNotice.setEnabled(ChatGPTSpaceModel.noticeSpace, oldNotice) }
        var metrics = "round\tlatency_ms\tresident_bytes\tvisible_messages\n"
        var baseline: UInt64 = 0, final: UInt64 = 0, maxLatency = 0
        for round in 1...200 {
            let started = Date(), count = pod.sends.count
            space.draft = "合成短問 \(round)"; space.send()
            try await wait { pod.sends.count == count + 1 }
            let command = pod.sends.last!
            if round > 1 { check(command["conversationID"] as? String == cid, "round \(round) stays in the same conversation") }
            complete(command, in: cid, answer: "合成回答 \(round)")
            try await wait { !space.isSending && space.messages.last?.text == "合成回答 \(round)" }
            check(space.messages.count == round * 2 && space.failure == nil && space.messages.last?.role == .assistant, "round \(round) visible transcript and idle status")
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            final = residentBytes(); if round == 10 { baseline = final }
            maxLatency = max(maxLatency, latency)
            metrics += "\(round)\t\(latency)\t\(final)\t\(space.messages.count)\n"
        }
        let growth = Int64(final) - Int64(baseline), limit: Int64 = 128 * 1024 * 1024
        check(baseline > 0 && growth <= limit, "200 rounds RSS start=\(baseline) end=\(final) growth=\(growth) threshold=\(limit) bytes; max latency=\(maxLatency) ms")
        check(notified, "background completion produces the actual Island notification")
        try metrics.write(to: artifacts.appendingPathComponent("w208-conversation-metrics.tsv"), atomically: true, encoding: .utf8)
        if let rendered = GlobalDMChatAcceptance.renderSync(ChatGPTSpaceMainPane(model: space), size: CGSize(width: 1000, height: 820), scheme: .dark) {
            GlobalDMChatAcceptance.save(rendered, "w208-space-200.png", to: artifacts); rendered.close()
            check(true, "200-round actual Space UI rendered")
        } else { check(false, "200-round Space UI render") }

        // Three actual consumers share a single TAP queue; a second send on one consumer stays rejected.
        let previous = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace([TapModel(id: "fixture-model", title: "合成模型", detail: "")])
        defer { ChatGPTTapModelCatalog.replace(previous) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("coder")), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "合成專案", workdir: root.path), thread = engine.newThread(in: project)
        let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        engine.onChange = { coder.document = engine.document; coder.isRunning = engine.isRunning(thread); coder.objectWillChange.send() }
        coder.chatGPTTapConnectionTestDouble = { tap.connection }
        coder.selectLocalThread(thread); coder.setSingleModel(ChatGPTTapModelCatalog.routeID("fixture-model"))
        let count = pod.sends.count
        space.draft = "Space 合成"; space.send()
        coder.prompt = "Coder 合成"; coder.send()
        dm.send("私訊合成"); dm.send("第二則不應送出")
        space.draft = "第二則保留草稿"; space.send()
        try await wait { pod.sends.count == count + 1 }
        check(pod.sends.count == count + 1 && engine.isRunning(thread) && space.draft == "第二則保留草稿" && dm.messages.filter { $0.role == .user }.count == 1, "Space/Coder/DM queue concurrently and each consumer rejects a second send")
        for index in 0..<3 {
            try await wait { pod.sends.count == count + index + 1 }
            let command = pod.sends.last!, text = command["text"] as? String ?? ""
            let surface = text.contains("Coder 合成") ? "coder" : text == "私訊合成" ? "dm" : "space"
            complete(command, in: surface == "space" ? cid : "fixture-" + surface, answer: "三處合成回覆 " + surface)
        }
        try await wait { !space.isSending && !dm.isSending && !engine.isRunning(thread) }
        check(dm.messages.last?.text == "三處合成回覆 dm" && engine.transcript(for: thread).last?.text == "三處合成回覆 coder", "three surfaces receive their own visible answers")

        await tap.openDots(returnURL: ChatGPTTap.homeURL)
        check(tap.dotsState == .loaded(url: "https://chatgpt.com/dots", status: 200), "Dots borrows shared Pod")
        let beforeDots = pod.sends.count
        dm.send("Dots 期間排隊")
        try await Task.sleep(for: .milliseconds(20))
        check(pod.sends.count == beforeDots && dm.state == .queued, "DM submission remains queued while Dots owns Pod")
        tap.closeDots()
        try await wait { pod.sends.count == beforeDots + 1 }
        complete(pod.sends.last!, in: "fixture-dm", answer: "Dots 交回後回覆")
        try await wait { !dm.isSending }
        check(dm.messages.last?.text == "Dots 交回後回覆", "Dots restore releases queued send")

        let beforeStop = pod.sends.count
        space.draft = "串流停止合成"; space.send(); try await wait { pod.sends.count == beforeStop + 1 }
        let stopped = pod.sends.last!["id"] as! String
        pod.emit(["type": "stream", "id": stopped, "kind": "text", "messageID": "partial", "full": "保留的部分回覆"])
        try await wait { space.messages.last?.text == "保留的部分回覆" }
        space.stop(); try await wait { !space.isSending }
        check(space.messages.last?.text == "保留的部分回覆" && space.messages.last?.stopNotice == "已停止", "stop preserves visible partial answer and stopped notice")
        let beforeRegenerate = pod.sends.count
        space.regenerate(); try await wait { pod.sends.count == beforeRegenerate + 1 }
        check(pod.sends.last?["cmd"] as? String == "regenerate", "regenerate uses the website operation")
        complete(pod.sends.last!, in: cid, answer: "重新產生合成回覆"); try await wait { !space.isSending }
        var message = space.messages.first { $0.role == .user }!; message.parentID = "fixture-parent"
        let beforeEdit = pod.sends.count
        space.edit(message, to: "編輯舊訊息合成"); try await wait { pod.sends.count == beforeEdit + 1 }
        check(pod.sends.last?["parentID"] as? String == "fixture-parent", "edit follows the old message parent")
        complete(pod.sends.last!, in: cid, answer: "編輯後的回覆"); try await wait { !space.isSending }
        var variant = space.messages.last!; variant.variant = TapVariant(index: 1, count: 2, nodes: ["old-leaf", "new-leaf"])
        branchReply = ["id": "old-answer", "role": "assistant", "text": "舊分支合成回覆"]
        space.showVariant(variant, offset: -1)
        try await wait { space.branchLeaf == "old-leaf" }
        check(space.messages.last?.text == "舊分支合成回覆", "branch switch displays the selected branch")

        dm.newConversation(); dm.temporary = true
        let beforeTemporary = pod.sends.count
        dm.send("臨時合成"); try await wait { pod.sends.count == beforeTemporary + 1 }
        check(pod.sends.last?["temporary"] as? Bool == true, "temporary conversation carries privacy flag")
        complete(pod.sends.last!, in: "fixture-temporary", answer: "臨時合成回覆"); try await wait { !dm.isSending }
        check(dm.isTemporary && dm.messages.last?.text == "臨時合成回覆", "temporary reply stays in the temporary conversation")
        space.newChat(with: TapFolder(id: "g-p-synthetic", title: "合成專案", kind: .project))
        let beforeProject = pod.sends.count
        space.draft = "專案合成"; space.send(); try await wait { pod.sends.count == beforeProject + 1 }
        check(pod.sends.last?["gizmoID"] as? String == "g-p-synthetic", "project send stays in its project")
        complete(pod.sends.last!, in: "fixture-project", answer: "專案合成回覆"); try await wait { !space.isSending }

        let beforeFailure = pod.sends.count
        space.draft = "過長合成"; space.send(); try await wait { pod.sends.count == beforeFailure + 1 }
        pod.emit(["type": "stream", "id": pod.sends.last!["id"] as! String, "kind": "failed", "reason": "conversation_too_long", "message": "synthetic length error"])
        try await wait { !space.isSending }
        check(space.messages.last?.turnFailure?.isTooLong == true && space.messages.last?.turnFailure?.actionTitle == "開新對話接著聊", "conversation-too-long displays failure and recovery action")
        if let rendered = GlobalDMChatAcceptance.renderSync(ChatGPTSpaceMainPane(model: space), size: CGSize(width: 1000, height: 820), scheme: .dark) {
            check(GlobalDMChatAcceptance.identifiers(in: rendered).contains("chatgpt.turnFailure"), "too-long failure is present in actual UI accessibility tree")
            GlobalDMChatAcceptance.save(rendered, "w208-space-too-long.png", to: artifacts); rendered.close()
        } else { check(false, "too-long UI render") }
        space.newChat()
        let beforeInterrupt = pod.sends.count
        space.draft = "串流失聯合成"; space.send(); try await wait { pod.sends.count == beforeInterrupt + 1 }
        let interrupt = pod.sends.last!, interruptID = interrupt["id"] as! String
        pod.emit(["type": "stream", "id": interruptID, "kind": "conversation", "conversationID": "fixture-interrupt"])
        pod.emit(["type": "stream", "id": interruptID, "kind": "text", "messageID": "interrupt-answer", "full": "失聯前的部分回覆"])
        try await wait { space.messages.last?.text == "失聯前的部分回覆" }
        pod.emit(["type": "hello", "loggedIn": true])
        check(space.messages.last?.text == "失聯前的部分回覆" && space.isSending && pod.sends.count == beforeInterrupt + 1, "stream document reload keeps partial reply and never sends a second prompt")
        complete(interrupt, in: "fixture-interrupt", answer: "恢復後的完整回覆")
        try await wait { !space.isSending }
        check(space.messages.last?.text == "恢復後的完整回覆", "stream reconnect delivers the complete answer")
        // A crashed page cannot trigger another send; the saved website transcript restores the answer.
        dm.newConversation()
        let beforeReload = pod.sends.count
        dm.send("重載合成"); try await wait { pod.sends.count == beforeReload + 1 }
        let reloadCommand = pod.sends.last!
        complete(reloadCommand, in: "fixture-reload", answer: "網站保存的回覆")
        try await wait { !dm.isSending }
        pod.emit(["type": "hello", "loggedIn": true])
        dm.open(conversationID: "fixture-reload")
        try await wait { dm.loadState == .loaded }
        check(dm.messages.last?.text == "網站保存的回覆" && pod.sends.count == beforeReload + 1, "page reload restores saved answer without resubmitting")
        tap.sleep(); tap.start(); try await wait { tap.connection == .ready }
        dm.open(conversationID: cid); try await wait { dm.loadState == .loaded }
        check(dm.messages.count >= 400 && dm.messages.last?.text == "編輯後的回覆", "sleep/wake restores durable conversation")
        let started = Date().addingTimeInterval(-240)
        let thinking = ChatGPTThinking(started: started, title: "合成長思考", server: true)
        check(thinking.seconds() >= 240 && thinking.label(at: Date()).contains("4 分"), "minute-scale progress presents server-thinking duration")
    }
}
/// Dispatch Pod plus the website operations the conversation stress drives: regenerate turns and Dots display frames.
final class W208TapPod: DispatchTapPod {
    override var sends: [[String: Any]] { commands.filter { ["send", "regenerate"].contains($0["cmd"] as? String ?? "") } }
    override func displayPage(_ javascript: String) throws { displayGeneration += 1; onDisplayFrame?("https://chatgpt.com/dots", displayGeneration, false, 200) }
    override func restoreDisplayedPage(_ url: URL) { emit(["type": "hello", "loggedIn": true]) }
    override func respond(_ command: [String: Any], id: String, cmd: String) {
        if cmd == "regenerate" { return }
        if cmd != "send", cmd != "stop", let data = responder?(cmd, command) { emit(["type": "result", "id": id, "ok": true, "data": data]); return }
        super.respond(command, id: id, cmd: cmd)
    }
}

#endif
