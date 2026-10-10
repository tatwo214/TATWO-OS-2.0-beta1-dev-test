#if DEBUG
import Foundation

enum W221cAcceptance {
    typealias Fake = DeviceFleetAcceptance.Fake
    static func run(scenario: String, make: (Int, Bool) throws -> Fake,
                    pair: (Fake, Fake) throws -> Void) throws {
        var count = 0
        func check(_ label: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw DeviceDispatch.Failure(reason: "W221C_FAIL_" + label) }
            count += 1; print("W221C PASS " + label)
        }
        let mini = try make(50, true), book = try make(51, false), studio = try make(52, false)
        if scenario == "keys" {
            let unmanaged = Data([0xef, 0xbb, 0xbf]) + Data((try mini.clientKey.trimmingCharacters(in: .newlines) + " self-owned\r\n\r\n"
                + book.clientKey.trimmingCharacters(in: .newlines) + " user-login  \n"
                + studio.clientKey.trimmingCharacters(in: .newlines) + "\tother-login\r\n").utf8)
            try unmanaged.write(to: mini.registry.authorizedKeysURL)
            try mini.fleet.bootstrapPrimary(host: mini.host)
            try check("update-preserves-user-lines", Data(contentsOf: mini.registry.authorizedKeysURL).starts(with: unmanaged))
            try pair(mini, book); try pair(mini, studio)
            try check("pairing-preserves-user-lines", Data(contentsOf: mini.registry.authorizedKeysURL).starts(with: unmanaged))
            try check("managed-owner-row-added", mini.registry.fleetPublicKey(deviceID: book.id) != nil)
            let proposal = try mini.fleet.propose([.revoke(id: book.id)], actor: mini.id)
            let preview = try DeviceFlowPreview.lines(before: mini.fleet.current()!.roster!, proposal: proposal, registry: mini.registry)
            try check("confirmation-warns-only-with-user-duplicate", preview.contains("你在這台電腦上手動加的同一把鑰匙也會一起移除（移除前會先備份）。")
                && !DeviceFlowPreview.lines(before: mini.fleet.current()!.roster!, proposal: proposal).contains("你在這台電腦上手動加的同一把鑰匙也會一起移除（移除前會先備份）。"))
            let beforeRevoke = try Data(contentsOf: mini.registry.authorizedKeysURL)
            try mini.fleet.revoke(book.id)
            try check("revocation-preserves-user-lines", Data(contentsOf: mini.registry.authorizedKeysURL).starts(with: Data(String(decoding: unmanaged, as: UTF8.self).components(separatedBy: "\n").filter { !$0.contains("user-login") }.joined(separator: "\n").utf8)))
            let backups = try FileManager.default.contentsOfDirectory(at: mini.registry.root.appendingPathComponent("backups/authorized_keys"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
            try check("revocation-backup-exact-restorable", backups.count == 1 && Data(contentsOf: backups[0]) == beforeRevoke)
            let restore = mini.registry.root.appendingPathComponent("restored-authorized-keys")
            try Data(contentsOf: backups[0]).write(to: restore)
            try check("revocation-backup-restores-full-original", Data(contentsOf: restore) == beforeRevoke)
            let mode = try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? Int
            try check("revocation-backup-private", mode == 0o600)
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: backups[0].appendingPathExtension("json"))) as! [String: Any]
            try check("revocation-backup-instructions-no-keys", metadata["source"] as? String == mini.registry.authorizedKeysURL.path
                && metadata["lines"] as? [Int] == [3, 5] && metadata["time"] as? String != nil && metadata["restore"] as? String != nil
                && !String(decoding: Data(contentsOf: backups[0].appendingPathExtension("json")), as: UTF8.self).contains("ssh-ed25519"))
            let audit = try String(contentsOf: mini.fleet.logURL, encoding: .utf8).components(separatedBy: "\n").filter { $0.hasPrefix("{") || $0.split(separator: " ", maxSplits: 1).last?.hasPrefix("{") == true }
            let event = try JSONSerialization.jsonObject(with: Data(audit[0].split(separator: " ", maxSplits: 1)[1].utf8)) as! [String: Any]
            try check("revocation-audit-counts-and-backup", audit.count == 1 && event["event"] as? String == "device_revoked" && Int(audit[0].split(separator: " ")[0])! > 0 && event["deviceID"] as? String == book.id
                && event["removed"] as? Int == 2 && event["manual"] as? Int == 1 && event["backup"] as? String == backups[0].path)
            try check("revocation-removes-marked-row", mini.registry.fleetPublicKey(deviceID: book.id) == nil)
            try check("revoked-key-stays-denied-in-TATWO", mini.fleet.capabilities(for: DeviceRegistry.fingerprint(publicKey: book.clientKey)) == nil)
            // A conflict skips only this key and reports that the manual login remains.
            let remainingUser = Data(String(decoding: unmanaged, as: UTF8.self).components(separatedBy: "\n").filter { !$0.contains("user-login") }.joined(separator: "\n").utf8)
            let before = try Data(contentsOf: mini.registry.authorizedKeysURL)
            let conflicts = try mini.registry.fleetReconcileKeys([(studio.id, studio.clientKey)], preserveLegacy: [], pending: [])
            try check("unmarked-restricted-duplicate-refused", conflicts == [studio.id: "authorized_keys_user_line_conflict"])
            try check("refused-update-leaves-exact-file", Data(contentsOf: mini.registry.authorizedKeysURL) == before)
            let other = try make(53, false)
            let batch = try mini.registry.fleetReconcileKeys([(studio.id, studio.clientKey), (other.id, other.clientKey)], preserveLegacy: [], pending: [])
            try check("conflict-does-not-stop-other-device", batch == conflicts && mini.registry.fleetPublicKey(deviceID: other.id) != nil)
            try check("non-revocation-keeps-all-remaining-user-bytes", Data(contentsOf: mini.registry.authorizedKeysURL).starts(with: remainingUser))
            try mini.registry.removeAuthorizedKey(deviceID: studio.id)
            try check("remove-marked-keeps-user-lines", Data(contentsOf: mini.registry.authorizedKeysURL).starts(with: remainingUser))
            var refused = false
            // Unreadable UTF-8 must never be interpreted as an empty user file.
            let nonUTF8 = unmanaged + Data([0xff, 0x0a])
            try nonUTF8.write(to: mini.registry.authorizedKeysURL)
            refused = false
            do { try mini.registry.fleetPruneRevokedKeys() } catch { refused = DeviceFleetReason.code(error) == "authorized_keys_not_utf8" }
            try check("invalid-encoding-refuses-management", refused)
            try check("invalid-encoding-keeps-exact-file", Data(contentsOf: mini.registry.authorizedKeysURL) == nonUTF8)
        } else if scenario.hasPrefix("h-") { try W221cRevocationAcceptance.run(String(scenario.dropFirst(2)), make: make, pair: pair) }
        else if scenario == "push" { try W221cPushAcceptance.run(make: make) }
        else if scenario == "ack" { try W221cACKAcceptance.run(make: make) }
        else { throw DeviceFleetError.malformed }
        print("W221C SUMMARY checks=\(count) failures=0")
    }
}
#endif
