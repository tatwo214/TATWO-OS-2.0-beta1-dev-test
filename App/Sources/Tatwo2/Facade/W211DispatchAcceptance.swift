#if DEBUG
import Foundation

@MainActor enum W211DispatchAcceptance {
    static func run() -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("W211SYNC \(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w211-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": root.appendingPathComponent("entry").path], preference: nil)
            try FileManager.default.createDirectory(at: entry.root, withIntermediateDirectories: true)
            let deviceID = UUID().uuidString, primaryID = UUID().uuidString
            let registry = DeviceRegistry(root: root.appendingPathComponent("registry"),
                authorizedKeysURL: root.appendingPathComponent("authorized_keys"))
            let missingKey = root.appendingPathComponent("absent-paired-key")
            var rpcCalls = 0
            let dispatch = DeviceDispatch(entry: entry, registry: registry,
                environment: ["TATWO2_SSH_KEY_PATH": missingKey.path], rpc: { _, _, _ in
                    rpcCalls += 1
                    throw DeviceDispatch.Failure(reason: "fixture_must_never_send")
                })
            var identity = DeviceIdentity(deviceID: deviceID, name: "fixture", hardwareModel: "fixture",
                role: .secondary, epoch: nil, primaryDeviceID: nil, updatedAt: Date())
            try identity.encoded().write(to: entry.deviceJSON)
            dispatch.synchronize()
            let unknown = dispatch.receipts()["local"]
            let identityMessage = "這台還沒記下主設備，入口文件不會同步；請在私訊框請 TATWO 助理處理。"
            let keyMessage = "這台沒有連回主設備的金鑰，入口文件不會同步；請在私訊框請 TATWO 助理處理配對。"
            check(unknown != nil, "incomplete identity persists a synchronization failure")
            check(DeviceConsistencyPanel.dispatchMessage(unknown) == identityMessage,
                  "missing primary shows Chinese consistency status")
            dispatch.synchronize()
            check(unknown != nil && dispatch.receipts()["local"]?.updated == unknown?.updated,
                  "repeated incomplete identity keeps first failure time")
            _ = try registry.add(DeviceRecord(id: primaryID, name: "fixture", host: "127.0.0.1",
                user: "fixture", sshPort: 1, publicKeyFingerprint: "SHA256:fixture", addedAt: Date(),
                lastSeenAt: Date(), workdirMap: [:], role: .primary, epoch: 1))
            identity.primaryDeviceID = primaryID; identity.epoch = 1
            try identity.encoded().write(to: entry.deviceJSON)
            dispatch.synchronize()
            let missing = dispatch.receipts()[primaryID]
            check(DeviceConsistencyPanel.dispatchMessage(missing) == keyMessage,
                  "missing paired key shows Chinese consistency status")
            check(dispatch.receipts()["local"] == nil, "identified failure replaces anonymous failure status")
            check(rpcCalls == 0 && !FileManager.default.fileExists(atPath: missingKey.path)
                  && !FileManager.default.fileExists(atPath: missingKey.path + ".pub"),
                  "failure tests never send RPC or generate paired keys")
            if let missing {
                check(dispatch.receipts(now: missing.updated.addingTimeInterval(61))[primaryID]?.phase == "timeout",
                      "synchronization timeout behavior is preserved")
            } else { check(false, "missing key persists receipt for timeout") }
            var malformed = try JSONSerialization.jsonObject(with: identity.encoded()) as! [String: Any]
            malformed["epoch"] = NSNull()
            try JSONSerialization.data(withJSONObject: malformed).write(to: entry.deviceJSON)
            dispatch.synchronize()
            check(DeviceConsistencyPanel.dispatchMessage(dispatch.receipts()["local"]) == identityMessage,
                  "missing epoch shows Chinese consistency status")
            let english = DeviceDispatch.Receipt(seq: 0, phase: "delivered", hashes: [:], updated: Date(),
                detail: "The operation could not be completed")
            check(DeviceConsistencyPanel.dispatchMessage(english) == "入口文件尚未同步；請在私訊框請 TATWO 助理處理。",
                  "unknown English system error is not displayed verbatim")
        } catch { check(false, "isolated synchronization fixture: \(error.localizedDescription)") }
        print("W211SYNC SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
