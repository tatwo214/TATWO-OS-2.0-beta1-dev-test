import Foundation

/// Used only after strict decoding fails and the untouched document is preserved.
enum ChatDocumentRecovery {
    static func decode(_ data: Data) -> LiveDocumentRecord? {
        guard var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func valid<T: Decodable>(_ object: Any, as type: T.Type) -> Bool {
            guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed) else { return false }
            return (try? decoder.decode(type, from: bytes)) != nil
        }
        if let threads = document["threads"] as? [Any] {
            document["threads"] = threads.compactMap { raw -> [String: Any]? in
                guard var thread = raw as? [String: Any] else { return nil }
                if let issues = thread["issues"] as? [Any] {
                    thread["issues"] = issues.filter { valid($0, as: TatwoIssueListEntryV1.self) }
                }
                if let tabs = thread["cliTabs"] as? [Any] {
                    thread["cliTabs"] = tabs.filter { valid($0, as: LiveCLITabRecord.self) }
                }
                if let preset = thread["botPermissionPreset"], !(preset is NSNull),
                   !valid(preset, as: TatwoPermissionPreset.self) {
                    // Losing an unknown permission must never inherit a broader user default.
                    thread["botPermissionPreset"] = TatwoPermissionPreset.askFirst.rawValue
                }
                return valid(thread, as: LiveThreadRecord.self) ? thread : nil
            }
        }
        guard let recovered = try? JSONSerialization.data(withJSONObject: document) else { return nil }
        return try? decoder.decode(LiveDocumentRecord.self, from: recovered)
    }
}
