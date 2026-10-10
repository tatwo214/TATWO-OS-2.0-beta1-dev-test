import Foundation

/// Local to this installation. Connector identity survives grant expiry and disconnect;
/// account identity is hashed and is never part of a public device report.
final class HandsConnectorRegistry: @unchecked Sendable {
    static let shared = HandsConnectorRegistry(url: HandsPaths.default.appDir.appendingPathComponent("connect-connectors.json"))
    struct Record: Codable, Equatable, Sendable {
        var connector: HandsConnectorScan.Match
        var needsAuthorization = false
    }
    let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    static func key(device: String, identity: String, mcpURL: String) -> String {
        taggedKey(device: device, identityTag: HandsConnectAccounts.identityTag(identity), mcpURL: mcpURL)
    }
    private static func taggedKey(device: String, identityTag: String, mcpURL: String) -> String {
        HandsAuth.sha256Hex(Data(("tatwo-connector|" + device.lowercased() + "|" + identityTag + "|" + mcpURL).utf8))
    }
    private func read() -> [String: Record] {
        HandsFiles.readSecure(url, limit: 256 * 1024).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    func record(_ key: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return read()[key]
    }
    func remember(_ connector: HandsConnectorScan.Match, key: String, needsAuthorization: Bool = false) throws {
        guard let id = connector.id, !id.isEmpty, connector.serverURL != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        lock.lock(); defer { lock.unlock() }
        var records = read()
        records[key] = Record(connector: connector, needsAuthorization: needsAuthorization)
        try HandsFiles.writeAtomically(JSONEncoder().encode(records), to: url)
    }
    /// A native revoke requires pairing again even when the website still says Connected.
    /// Account tags allow this after an App restart without opening the Pod or querying lists.
    func requireAuthorization(device: String, identityTags: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        var records = read(), changed = false
        for (key, record) in records {
            guard let serverURL = record.connector.serverURL,
                  identityTags.contains(where: { Self.taggedKey(device: device, identityTag: $0, mcpURL: serverURL) == key }) else { continue }
            records[key]?.needsAuthorization = true
            changed = true
        }
        if changed { try HandsFiles.writeAtomically(JSONEncoder().encode(records), to: url) }
    }
    /// Write all reconstruction metadata before the first remote deletion. No tokens or conversation text.
    func archive(_ connectors: [HandsConnectorScan.Match]) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent("connector-archive")
            .appendingPathComponent(UUID().uuidString + ".json")
        try HandsFiles.writeAtomically(JSONEncoder().encode(connectors), to: destination)
        return destination
    }
    static func isDeviceName(_ name: String, base: String) -> Bool {
        guard name.hasPrefix(base) else { return false }
        let suffix = name.dropFirst(base.count)
        return suffix.isEmpty || (!suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber } && Int(suffix).map { $0 >= 2 } == true)
    }
}

/// Preview and execution share exact URL/name filtering. Only a UI confirmation calls execute.
@MainActor
final class HandsConnectorCleanup {
    struct Preview: Equatable {
        let key: String
        let identity: String
        let generation: Int
        let keeping: HandsConnectorScan.Match
        let removing: [HandsConnectorScan.Match]
        var devices: [Preview] = []
        var text: String {
            if !devices.isEmpty { var first = self; first.devices = []; return ([first] + devices).map(\.text).joined(separator: "\n\n") }
            return "保留：" + keeping.name + "\n\n刪除 \(removing.count) 份：\n"
                + removing.map(\.name).joined(separator: "\n") + "\n刪除前會保存本機還原紀錄。"
        }
    }
    let registry: HandsConnectorRegistry
    init(registry: HandsConnectorRegistry) { self.registry = registry }
    func preview(scan: HandsConnectorScan, key: String, identity: String, generation: Int, base: String, url: String) -> Preview? {
        guard scan.listKnown, let current = registry.record(key), !current.needsAuthorization,
              let keepID = current.connector.id, current.connector.serverURL == url,
              scan.matches.contains(where: { $0.id == keepID && $0.serverURL == url }),
              Set(scan.matches.compactMap(\.id)).count == scan.matches.count else { return nil }
        let removing = scan.matches.filter { $0.id != nil && $0.id != keepID && $0.serverURL == url && $0.connected == false
            && HandsConnectorRegistry.isDeviceName($0.name, base: base) }
        return Preview(key: key, identity: identity, generation: generation, keeping: current.connector, removing: removing)
    }
    func execute(_ preview: Preview, pod: any HandsConnectPodDriving, identity: String, generation: Int, currentGeneration: (() -> Int)? = nil) async throws -> Int {
        guard identity == preview.identity, generation == preview.generation,
              registry.record(preview.key)?.connector == preview.keeping,
              let keep = preview.keeping.id, let url = preview.keeping.serverURL,
              await pod.inspect(preview.keeping, url: url) == .connected,
              !Task.isCancelled, (currentGeneration?() ?? generation) == preview.generation else { throw CocoaError(.userCancelled) }
        let validity = Task { @MainActor in
            while !Task.isCancelled {
                let sameIdentity = await pod.identity() == identity
                guard !Task.isCancelled else { return }
                guard (currentGeneration?() ?? generation) == preview.generation, sameIdentity else { pod.releaseExclusive(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { validity.cancel() }
        return try await withTaskCancellationHandler {
            _ = try registry.archive([preview.keeping] + preview.removing)
            var deleted = 0
            for connector in preview.removing {
                guard !Task.isCancelled, await pod.identity() == identity,
                      (currentGeneration?() ?? generation) == preview.generation else { throw CocoaError(.userCancelled) }
                guard connector.connected == false, connector.serverURL == url, connector.id != keep else { break }
                let removed = await pod.deleteConnector(connector, keeping: keep, url: url)
                guard !Task.isCancelled, (currentGeneration?() ?? generation) == preview.generation,
                      await pod.identity() == identity else { throw CocoaError(.userCancelled) }
                if removed { deleted += 1 }
                else { break } // unknown delete result is never retried automatically
            }
            return deleted
        } onCancel: { validity.cancel() }
    }
}
