import Foundation

/// Local device resource only. Preserve every byte outside the edited JSON values.
enum WorkPath {
    private static let lock = NSLock()
    static func defaultURL(_ entry: TatwoEntry) -> URL { entry.root.appendingPathComponent("staging", isDirectory: true) }
    static func current(_ entry: TatwoEntry) throws -> URL {
        let object = try JSONSerialization.jsonObject(with: read(entry)) as? [String: Any]
        let path = (object?["resources"] as? [String: Any])?["staging"] as? String
        return path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? defaultURL(entry)
    }
    static func read(_ entry: TatwoEntry) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: entry.deviceJSON.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw failure("設備身份檔不可讀") }
        return try Data(contentsOf: entry.deviceJSON)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "WorkPath", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func warning(bytes: Int64?) -> String? { bytes.map { $0 < 50_000_000_000 ? "空間偏少（可用空間少於 50 GB）" : nil } ?? nil }
    static func validate(_ url: URL) throws -> String? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else { throw failure("這個資料夾不可寫，請選另一個資料夾。") }
        let probe = url.appendingPathComponent(".tatwo-write-" + UUID().uuidString)
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch { throw failure("這個資料夾不可寫：" + error.localizedDescription) }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return warning(bytes: values?.volumeAvailableCapacityForImportantUsage)
    }
    static func set(_ chosen: URL?, entry: TatwoEntry) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let original = try read(entry)
        let url = chosen ?? defaultURL(entry)
        if chosen == nil, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let note = try validate(url)
        var bytes = Array(original)
        let root = try members(bytes, in: 0..<bytes.count)
        func encoded(_ value: Any) throws -> [UInt8] { Array(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) }
        if let resource = root.first(where: { $0.key == "resources" }) {
            var replacement = Array(bytes[resource.value])
            let fields = try members(replacement, in: 0..<replacement.count)
            if let staging = fields.first(where: { $0.key == "staging" }) {
                replacement.replaceSubrange(staging.value, with: try encoded(url.path))
            } else { try insert("staging", value: url.path, into: &replacement) }
            bytes.replaceSubrange(resource.value, with: replacement)
        } else {
            try insert("resources", value: ["entry": entry.root.path,
                "physicalEntry": entry.root.resolvingSymlinksInPath().path, "staging": url.path], into: &bytes)
        }
        guard try read(entry) == original else { throw failure("設備身份檔已變更，請再試一次。") }
        try Data(bytes).write(to: entry.deviceJSON, options: .atomic)
        return note
    }
    private struct Field { let key: String; let value: Range<Int> }
    /// JSONSerialization validates syntax; this scanner locates members without reserializing them.
    private static func members(_ bytes: [UInt8], in range: Range<Int>) throws -> [Field] {
        _ = try JSONSerialization.jsonObject(with: Data(bytes[range])) as? [String: Any] ?? { throw failure("設備資源格式不正確") }()
        var i = range.lowerBound, fields: [Field] = []
        func whitespace() { while i < range.upperBound && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func token() -> Range<Int> {
            let start = i
            var depth = 0, string = false
            while i < range.upperBound {
                let c = bytes[i]
                if string { if c == 92 { i += 2; continue }; if c == 34 { string = false } }
                else if c == 34 { string = true }
                else if c == 123 || c == 91 { depth += 1 }
                else if c == 125 || c == 93 { if depth == 0 { break }; depth -= 1 }
                else if depth == 0 && [44, 58, 9, 10, 13, 32].contains(c) { break }
                i += 1
                if depth == 0 && !string { break }
            }
            // Numbers/literals can span several bytes.
            if bytes[start] != 34 && bytes[start] != 123 && bytes[start] != 91 {
                while i < range.upperBound && ![44, 125, 93, 9, 10, 13, 32].contains(bytes[i]) { i += 1 }
            }
            return start..<i
        }
        whitespace(); i += 1; whitespace()
        while bytes[i] != 125 {
            let key = try JSONSerialization.jsonObject(with: Data(bytes[token()]), options: .fragmentsAllowed) as! String
            whitespace(); i += 1; whitespace()
            fields.append(Field(key: key, value: token()))
            whitespace(); if bytes[i] == 44 { i += 1; whitespace() } else { break }
        }
        guard Set(fields.map(\.key)).count == fields.count else { throw failure("設備資源有重複欄位") }
        return fields
    }
    private static func insert(_ key: String, value: Any, into bytes: inout [UInt8]) throws {
        let fields = try members(bytes, in: 0..<bytes.count)
        let end = bytes.lastIndex(of: 125)!
        let pair = try JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.insert(contentsOf: (fields.isEmpty ? [] : [44]) + Array(pair.dropFirst().dropLast()), at: end)
    }
}
