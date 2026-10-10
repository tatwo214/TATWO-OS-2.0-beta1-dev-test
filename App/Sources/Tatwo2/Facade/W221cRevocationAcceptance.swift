#if DEBUG
import Foundation

enum W221cRevocationAcceptance {
    static func run(_ scenario: String, make: (Int, Bool) throws -> DeviceFleetAcceptance.Fake,
                    pair: (DeviceFleetAcceptance.Fake, DeviceFleetAcceptance.Fake) throws -> Void) throws {
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W221H_FAIL_" + name) }
            print("W221H PASS " + name)
        }
        let mini = try make(60, true), studio = try make(61, false), book = try make(62, false)
        let hooks = DeviceFleetRevocation.testHooks
        DeviceFleetRevocation.testHooks = .init(sessions: { [.init(pid: 999, start: 1, fingerprint: "synthetic-unrelated", address: nil, tatwoRelated: false)] }, terminate: { _ in false })
        defer { DeviceFleetRevocation.testHooks = hooks }
        let fm = FileManager.default
        let warning = "你在這台電腦上手動加的同一把鑰匙也會一起移除（移除前會先備份）。"
        func backups() throws -> [URL] {
            let dir = mini.registry.root.appendingPathComponent("backups/authorized_keys")
            return fm.fileExists(atPath: dir.path) ? try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" } : []
        }
        if scenario == "legacy" {
            // Sol W233b #1: close／closeAll neither fire nor drop a revocation watcher; the later revoke (slice path closes first) fires it once.
            final class Count: @unchecked Sendable { var value = 0 }
            let fired = Count(), watchScope = mini.registry.root.path + "/w233c"
            let watch = DeviceFleetConnections.onRevoke(studio.id, scope: watchScope) { fired.value += 1 }
            DeviceFleetConnections.close(studio.id, scope: watchScope); DeviceFleetConnections.closeAll(scope: watchScope)
            try check("revoke-watcher-survives-close", fired.value == 0)
            DeviceFleetConnections.revoke(studio.id, scope: watchScope); DeviceFleetConnections.revoke(studio.id, scope: watchScope)
            try check("revoke-watcher-fires-once", fired.value == 1)
            DeviceFleetConnections.unregister(studio.id, scope: watchScope, token: watch)
            let key = try studio.clientKey, fp = try DeviceRegistry.fingerprint(publicKey: key)
            _ = try mini.registry.add(id: studio.id, name: "fixture", host: studio.host, user: "fixture", publicKeyFingerprint: fp)
            let manual = Data((key.trimmingCharacters(in: .newlines) + " manually-imported  \r\n").utf8)
            try DeviceDispatchSafeFile.write(manual, url: mini.registry.authorizedKeysURL)
            try mini.fleet.bootstrapPrimary(host: mini.host)
            let before = try mini.fleet.current()!.roster!
            try check("legacy-real-shape", before.devices.first { $0.id == studio.id }?.clientKeyFingerprint == nil
                && mini.registry.list().first { $0.id == studio.id }?.pinnedClientKeyFingerprint == fp)
            let proposal = try mini.fleet.propose([.revoke(id: studio.id)], actor: mini.id)
            try check("legacy-confirmation", DeviceFlowPreview.lines(before: before, proposal: proposal, registry: mini.registry).contains(warning)
                && DeviceFlowPreview.lines(before: before, proposal: proposal, registry: mini.registry).contains { $0.hasPrefix("其他沒被撤銷的電腦也會移除") })
            _ = try mini.registry.authorize(publicKey: key, deviceID: studio.id)
            let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: mini.registry.url)) as! [[String: Any]]
            try check("legacy-registry-still-only-public-pin", stored.first { $0["id"] as? String == studio.id }?["clientKeyFingerprint"] == nil)
            let bytes = try Data(contentsOf: mini.registry.authorizedKeysURL)
            try mini.fleet.revoke(studio.id)
            try check("legacy-all-key-lines-removed", !mini.registry.fleetHasAuthorizedFingerprint(fp))
            let files = try backups()
            try check("legacy-backup-exact", files.count == 1 && Data(contentsOf: files[0]) == bytes)
        } else {
            try mini.fleet.bootstrapPrimary(host: mini.host); try pair(mini, studio); try pair(mini, book)
            let fp = try DeviceRegistry.fingerprint(publicKey: studio.clientKey)
            let manual = Data((try studio.clientKey.trimmingCharacters(in: .newlines) + " manually-imported  \r\n").utf8)
            try DeviceDispatchSafeFile.write(Data(contentsOf: mini.registry.authorizedKeysURL) + manual, url: mini.registry.authorizedKeysURL)
            if scenario.hasPrefix("scope") {
                let otherManual = Data([0xef, 0xbb, 0xbf]) + Data((try mini.clientKey.trimmingCharacters(in: .newlines) + " mini-manual  \r\n\r\n" + book.clientKey.trimmingCharacters(in: .newlines) + " book-manual  \r\n").utf8)
                try DeviceDispatchSafeFile.write(otherManual + Data(contentsOf: studio.registry.authorizedKeysURL), url: studio.registry.authorizedKeysURL)
                try DeviceDispatchSafeFile.write(Data(contentsOf: book.registry.authorizedKeysURL) + manual, url: book.registry.authorizedKeysURL)
                let observerOriginal = try Data(contentsOf: book.registry.authorizedKeysURL)
                try mini.fleet.revoke(studio.id)
                try book.fleet.synchronizeEnvelope(mini.fleet.delivery(for: book.id)!)
                let observerBackupDir = book.registry.root.appendingPathComponent("backups/authorized_keys")
                let observerBackups = try fm.contentsOfDirectory(at: observerBackupDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
                try check("observer-sync-target-removed-backup-exact", Data(contentsOf: book.registry.authorizedKeysURL).range(of: manual) == nil
                    && !book.registry.fleetHasAuthorizedFingerprint(fp) && observerBackups.count == 1 && Data(contentsOf: observerBackups[0]) == observerOriginal)
                let observerAudit = try Data(contentsOf: book.fleet.logURL)
                try DeviceDispatchSafeFile.write(Data(contentsOf: book.registry.authorizedKeysURL) + manual, url: book.registry.authorizedKeysURL)
                for _ in 0..<2 { try book.fleet.synchronizeEnvelope(book.fleet.envelope()!) }
                try check("observer-repeat-no-manual-removal-or-backup", Data(contentsOf: book.registry.authorizedKeysURL).range(of: manual) != nil
                    && fm.contentsOfDirectory(at: observerBackupDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }.count == 1 && Data(contentsOf: book.fleet.logURL) == observerAudit)
                try studio.fleet.synchronizeEnvelope(scenario == "scope-roster" ? mini.fleet.envelope()! : mini.fleet.delivery(for: studio.id)!)
                try studio.fleet.reconcile(studio.fleet.current()!)
                try check("revoked-side-other-manual-exact", Data(contentsOf: studio.registry.authorizedKeysURL) == otherManual)
                try check("revoking-side-target-only", !mini.registry.fleetHasAuthorizedFingerprint(fp) && mini.registry.fleetPublicKey(deviceID: book.id) != nil)
                try check("revoked-side-no-manual-backup", !fm.fileExists(atPath: studio.registry.root.appendingPathComponent("backups/authorized_keys").path))
            } else if scenario == "repeat" {
                // One readable, unrelated synthetic session keeps session-sweep diagnostics out of this audit comparison.
                let hooks = DeviceFleetRevocation.testHooks
                DeviceFleetRevocation.testHooks = .init(sessions: { [.init(pid: 999, start: 1, fingerprint: "synthetic-unrelated", address: nil, tatwoRelated: false)] }, terminate: { _ in false })
                defer { DeviceFleetRevocation.testHooks = hooks }
                let original = try Data(contentsOf: mini.registry.authorizedKeysURL)
                try mini.fleet.revoke(studio.id)
                let files = try backups(), audit = try Data(contentsOf: mini.fleet.logURL)
                try check("initial-backup-exact", files.count == 1 && Data(contentsOf: files[0]) == original)
                let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: files[0].appendingPathExtension("json"))) as! [String: Any]
                try DeviceDispatchSafeFile.write(Data(contentsOf: files[0]), url: mini.registry.authorizedKeysURL)
                for _ in 0..<2 { try mini.fleet.reconcile(mini.fleet.current()!) }
                try check("restored-manual-exact", try mini.registry.authorizedUserLines(fingerprint: fp).count == 1
                    && Data(contentsOf: mini.registry.authorizedKeysURL).range(of: manual) != nil)
                try check("restored-marked-still-pruned", mini.registry.fleetPublicKey(deviceID: studio.id) == nil)
                try check("repeat-no-backup-no-event", backups().count == 1 && Data(contentsOf: mini.fleet.logURL) == audit)
                try check("restore-instructions", (metadata["restore"] as? String)?.contains("先在 TATWO 恢復該設備再還原") == true)
            } else if scenario == "backup-failure" {
                let directory = mini.registry.root.appendingPathComponent("backups")
                try DeviceDispatchSafeFile.write(Data("fixture blocks directory".utf8), url: directory)
                try mini.fleet.revoke(studio.id)
                try check("backup-failure-manual-exact", Data(contentsOf: mini.registry.authorizedKeysURL).range(of: manual) != nil)
                try check("backup-failure-marked-pruned", mini.registry.fleetPublicKey(deviceID: studio.id) == nil)
                try check("backup-failure-audited", String(contentsOf: mini.fleet.logURL, encoding: .utf8).contains("authorized_keys_backup_failed"))
                let warning = "第 \(try mini.registry.authorizedUserLines(fingerprint: fp).map(String.init).joined(separator: "、")) 行仍可登入；會再試一次"
                try check("backup-failure-persisted-visible", mini.fleet.read().pendingKeyRemoval?[fp]?.deviceID == studio.id && mini.fleet.read().pendingKeyRemoval?[fp]?.lines == mini.registry.authorizedUserLines(fingerprint: fp) && mini.fleet.keyRemovalWarnings().first?.contains(warning) == true)
                try fm.moveItem(at: directory, to: directory.appendingPathExtension("blocked"))
                try mini.fleet.synchronizeEnvelope(mini.fleet.envelope()!)
                try check("backup-retry-clears-pending-and-login", mini.fleet.read().pendingKeyRemoval?.isEmpty != false && mini.fleet.keyRemovalWarnings().isEmpty && !mini.registry.fleetHasAuthorizedFingerprint(fp) && backups().count == 1)
                try DeviceDispatchSafeFile.write(Data(contentsOf: mini.registry.authorizedKeysURL) + manual, url: mini.registry.authorizedKeysURL)
                let completedAudit = try Data(contentsOf: mini.fleet.logURL)
                for _ in 0..<2 { try mini.fleet.synchronizeEnvelope(mini.fleet.envelope()!) }
                try check("completed-retry-never-deletes-again", Data(contentsOf: mini.registry.authorizedKeysURL).range(of: manual) != nil && backups().count == 1 && Data(contentsOf: mini.fleet.logURL) == completedAudit)
            } else if scenario == "shared" {
                var before = try mini.fleet.current()!.roster!
                let index = before.devices.firstIndex { $0.id == book.id }!
                before.devices[index].clientKeyFingerprint = fp; before.devices[index].clientPublicKey = try studio.clientKey
                let proposal = try mini.fleet.propose([.revoke(id: studio.id)], actor: mini.id)
                var after = before; after.revoked.append(studio.id)
                let shared = DeviceFleetPendingChange(id: proposal.id, baseVersion: proposal.baseVersion, actor: proposal.actor, changes: proposal.changes, preview: after)
                try check("shared-key-no-misleading-confirmation", !DeviceFlowPreview.lines(before: before, proposal: shared, registry: mini.registry).contains { $0.contains("手動") || $0.hasPrefix("其他沒被撤銷的電腦") })
            } else { throw DeviceFleetError.malformed }
        }
        print("W221H SUMMARY failures=0")
    }
}
#endif
