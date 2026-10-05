import Foundation

/// Bounded, process-local display lookup. Catalog generations include remembered names.
/// Send admission still reads the current provider capabilities and connection.
final class ChatRouteLookupCache: @unchecked Sendable {
    private struct Version: Equatable {
        let engine: UInt64
        let tap: UInt64
    }
    private final class Entry {
        let version: Version
        let choices: [ChatRouteChoice]
        let aliases: [String: ChatRouteChoice]
        var resolutions: [String: Resolution] = [:]
        init(version: Version, choices: [ChatRouteChoice]) {
            self.version = version
            self.choices = choices
            var aliases: [String: ChatRouteChoice] = [:]
            for choice in choices {
                for value in [choice.id, choice.canonicalModelSlug, choice.modelArgument, choice.title, choice.family].compactMap({ $0 }) {
                    let key = ChatProviderModelIdentity.lookupKey(value)
                    if aliases[key] == nil { aliases[key] = choice }
                }
            }
            self.aliases = aliases
        }
    }
    private struct Resolution { let value: ChatRouteChoice? }
    static let shared = ChatRouteLookupCache()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private func entry(deviceID: String) -> Entry {
        let version = Version(engine: EngineModelCatalog.revision(deviceID: deviceID), tap: ChatGPTTapModelCatalog.revision)
        lock.lock()
        if let entry = entries[deviceID], entry.version == version {
            lock.unlock()
            return entry
        }
        lock.unlock()
        let choices = EngineModelCatalog.profiles(deviceID: deviceID).map { ChatRouteChoice(profile: $0) }
            + ChatGPTTapModelCatalog.choices
        let entry = Entry(version: version, choices: choices)
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= 32 { entries.removeAll(keepingCapacity: true) }
        entries[deviceID] = entry
        return entry
    }

    func choices(deviceID: String) -> [ChatRouteChoice] { entry(deviceID: deviceID).choices }

    func resolve(_ id: String, deviceID: String,
                 fallback: ([ChatRouteChoice]) -> ChatRouteChoice?) -> ChatRouteChoice? {
        let entry = entry(deviceID: deviceID)
        lock.lock()
        if let result = entry.resolutions[id] {
            lock.unlock()
            return result.value
        }
        lock.unlock()
        let needle = ChatProviderModelIdentity.lookupKey(id)
        let result = needle.isEmpty ? nil : entry.aliases[needle] ?? fallback(entry.choices)
        // Oversized external identifiers are resolved normally without retaining them.
        if id.utf8.count <= 1024 {
            lock.lock()
            if entry.resolutions.count >= 512 { entry.resolutions.removeAll(keepingCapacity: true) }
            entry.resolutions[id] = Resolution(value: result)
            lock.unlock()
        }
        return result
    }
}
