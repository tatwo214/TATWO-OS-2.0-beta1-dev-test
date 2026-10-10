#if DEBUG
import Foundation

extension HandsConnectAcceptance {
    @MainActor static func w304bInstalled(_ check: Checker, _ base: URL) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/w304b-native-pod.mjs")
        for mode in ["existing", "missing", "empty", "w325"] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", fixture.path, mode]
            process.standardOutput = pipe
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            guard status == 0 else { throw CocoaError(.fileReadUnknown) }
            let data = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
            let matches = try JSONDecoder().decode([HandsConnectorScan.Match].self,
                from: JSONSerialization.data(withJSONObject: data["matches"] ?? []))
            let world = try World(base, "w304b-" + mode)
            world.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: data["listKnown"] as? Bool ?? false,
                devMode: nil, matches: matches, failure: data["failure"] as? String)
            world.flow.offer()
            let offered = await waitUntil(5) { isConfirm(world.flow.card) }
            world.flow.connect()
            let reached = await waitUntil(5) {
                mode == "missing" ? world.flow.phase == .needsManual
                    : world.pod.calls.contains(mode == "existing" || mode == "w325" ? "reconnect:" + (matches.first?.id ?? "") : "create")
            }
            check(offered && reached && (mode == "empty" || world.pod.createdNames.isEmpty),
                "W304b Installed DOM → real HandsConnectFlow: \(mode)", "\(world.pod.calls)")
            world.flow.cancel(reason: "test_done")
        }
    }
}
#endif
