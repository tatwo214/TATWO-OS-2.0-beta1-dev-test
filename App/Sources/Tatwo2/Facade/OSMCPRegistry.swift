import Foundation
import CryptoKit
import Darwin

struct OSMCPRegistry: Sendable {
    enum Group: String, CaseIterable, Codable, Sendable { case codex, claude, general = "通用" }
    struct Consent: Codable, Equatable, Sendable {
        var fingerprint: String?
        var fields: [String: String]?
        init(_ object: [String: Any]) {
            var execution = object
            for field in ["env", "headers", "http_headers"] {
                if let values = object[field] as? [String: Any] {
                    var hashed = values.mapValues { _ in "" }
                    for (key, value) in values where key.range(of: "TOKEN|KEY|SECRET|PASSWORD|PASSWD|AUTH", options: [.regularExpression, .caseInsensitive]) == nil {
                        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                        hashed[key] = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                    }
                    execution[field] = hashed
                }
            }
            var parts = execution
            for field in ["env", "headers", "http_headers"] { if let values = parts.removeValue(forKey: field) as? [String: Any] { for (key, value) in values { parts[field + "." + key] = value } } }
            fields = parts.mapValues { value in (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "" }
            fingerprint = (try? JSONSerialization.data(withJSONObject: ["version": 2, "execution": execution], options: [.sortedKeys])).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
    }

    struct Item: Codable, Identifiable, Sendable {
        var source, sourceName, name: String
        var command = ""
        var args: [String] = []
        var remoteURL: String? = nil
        var envKeys: [String] = []
        var headersHelper: String? = nil
        var consent: Consent? = nil
        var packageOverride: [String]? = nil
        enum CodingKeys: String, CodingKey { case source, sourceName, name, group, scope, consent, packageOverride }
        var group: Group
        var scope: String? = nil
        var id: String { source + "\n" + (scope ?? "") + "\n" + sourceName }
        var displayName: String { sourceName + (scope.map { "・…/" + URL(fileURLWithPath: $0).pathComponents.suffix(2).joined(separator: "/") } ?? "") }
        var commandLine: String {
            let main = command.isEmpty ? (remoteURL.map { Self.hasSecret($0, urlOnly: true) ? "••••" : $0 } ?? "遠端 MCP") : ([command] + redactedArgs).joined(separator: " ")
            guard let helper = headersHelper else { return main }
            // 只有像金鑰的值才遮（遮的同時整項擋下）；指令裡只是出現 auth／token 字樣要照原文給使用者看。
            return main + "\n會執行：" + (helperSecret ? "••••" : helper)
        }
        var dangerous: Bool { ["computer-use", "computer_use"].contains { (sourceName + " " + commandLine).localizedCaseInsensitiveContains($0) } }
        var secretArguments: Set<Int> { Self.secrets(in: args) }
        var helperSecret: Bool { headersHelper.map { !Self.secrets(in: Self.words($0)).isEmpty } ?? false }
        /// Shell-style words: quotes group and are removed, so `"--token" "x"` is checked like `--token x`;
        /// a backslash escapes the next character as in a shell (inside double quotes only `"` `\` `$` `` ` ``), so `\"` does not end a quote;
        /// backslash-newline is a line continuation and disappears. Expansions ($VAR, $(…), $'…') are not evaluated.
        /// Walks Unicode scalars like a shell walks bytes: a combining mark after a quote must not merge with it.
        static func words(_ command: String) -> [String] {
            var words: [String] = [], current = String.UnicodeScalarView(), quote: Unicode.Scalar?, started = false, escaped = false
            for ch in command.unicodeScalars {
                if escaped {
                    escaped = false
                    if ch == "\n" { continue }
                    if quote == "\"" && !"\"\\$`".unicodeScalars.contains(ch) { current.append("\\") }
                    current.append(ch); started = true; continue
                }
                if ch == "\\" && quote != "'" { escaped = true; continue }
                if let open = quote { if ch == open { quote = nil } else { current.append(ch) }; continue }
                if ch == "\"" || ch == "'" { quote = ch; started = true; continue }
                if " \t\n".unicodeScalars.contains(ch) { if started { words.append(String(current)); current = .init(); started = false }; continue }
                current.append(ch); started = true
            }
            if started { words.append(String(current)) }
            return words
        }
        static func secrets(in args: [String]) -> Set<Int> {
            var result = Set<Int>()
            let strong = "key|token|secret|password|passwd|auth|bearer"
            // --header 後面只有標頭名稱像憑證（Authorization、Cookie…）才算金鑰；Accept: application/json 不算。
            func credentialHeader(_ value: String) -> Bool {
                guard let colon = value.unicodeScalars.firstIndex(of: ":") else { return true }   // 看不出標頭名稱就當金鑰
                return String(value.unicodeScalars[..<colon]).range(of: strong + "|authorization|cookie", options: [.regularExpression, .caseInsensitive]) != nil || hasSecret(value)
            }
            for (i, arg) in args.enumerated() {
                let scalars = arg.unicodeScalars
                let pair = scalars.firstIndex(of: "=").map { [String(scalars[..<$0]), String(scalars[scalars.index(after: $0)...])] } ?? [arg]
                let named = pair[0].range(of: strong, options: [.regularExpression, .caseInsensitive]) != nil
                let header = !named && pair[0].range(of: "header", options: .caseInsensitive) != nil
                if pair.count == 2 && (named || header && credentialHeader(String(pair[1]))) { result.insert(i) }
                if arg.hasPrefix("-") && pair.count == 1 && args.indices.contains(i + 1) && (named || header && credentialHeader(args[i + 1])) { result.insert(i + 1) }
                let value = pair.count == 2 ? String(pair[1]) : arg
                if hasSecret(value) { result.insert(i) }
            }
            return result
        }
        static func hasSecret(_ text: String, urlOnly: Bool = false) -> Bool {
            let direct = #"(?:^|[\s=:"',])(?:sk-|ghp_|github_pat_|xox|AKIA)|(?:[?;&]|\s)(?:password|passwd|pwd)\s*=\s*[^;&\s]+"#
            guard let value = text.removingPercentEncoding else { return urlOnly || text.contains("://") || text.range(of: direct, options: [.regularExpression, .caseInsensitive]) != nil }
            if value.range(of: direct, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            let regex = try! NSRegularExpression(pattern: #"[a-z][a-z0-9+.-]*://[^\s\"'<>]*"#, options: .caseInsensitive)
            // 解碼的斜線可能把登入資料移到路徑，原本的登入資料檢查仍須保留。
            if regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains(where: { match in
                guard let range = Range(match.range, in: text), let url = URLComponents(string: String(text[range])) else { return false }
                return url.user != nil || url.password != nil
            }) { return true }
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            if urlOnly && (matches.count != 1 || matches[0].range != NSRange(value.startIndex..., in: value)) { return true }
            return matches.contains { match in
                guard let range = Range(match.range, in: value), let scheme = value[range].range(of: "://") else { return true }
                let rest = String(value[scheme.upperBound..<range.upperBound]), end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
                let authority = String(rest[..<end])
                guard authority.range(of: #"^(?:[^/@?#\s]+@)?(?:\[[0-9a-f:.]+\]|[^:/?#\s\[\]]+)(?::[0-9]{1,5})?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      URLComponents(string: String(value[range]))?.url?.host?.isEmpty == false else { return true }
                if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                    var address = in6_addr()
                    guard String(authority[authority.index(after: authority.startIndex)..<close]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return true }
                }
                if let port = authority.split(separator: "]").last?.split(separator: ":").last, let number = Int(port), number > 65535 { return true }
                return authority.contains("@") || rest[end...].components(separatedBy: CharacterSet(charactersIn: "/?&#;=")).contains { $0.range(of: "key|token|secret|password|passwd|pwd|auth|sig|^(?:sk-|ghp_|github_pat_|xox|AKIA)", options: [.regularExpression, .caseInsensitive]) != nil }
            }
        }
        func execution(_ definition: [String: Any]) -> [String: Any] {
            var object = definition
            if let spec = packageOverride, spec.count == 2, var args = object["args"] as? [String], let index = args.firstIndex(of: spec[0]) { args[index] = spec[1]; object["args"] = args }
            return object
        }
        var redactedArgs: [String] { let hidden = secretArguments; return args.enumerated().map { hidden.contains($0.offset) ? "••••" : $0.element } }
        var invisibleText: Bool { ([displayName] + envKeys).contains { OSAgentBridge.hasInvisibleCharacters($0) } || OSAgentBridge.hasInvisibleCharacters(commandLine, allowLineBreaks: true) }
        var blocked: Bool { invisibleText || !secretArguments.isEmpty || helperSecret || (remoteURL.map { Self.hasSecret($0, urlOnly: true) } ?? false) }
        var warning: String? { invisibleText ? "名稱或指令含看不見的字元，請改用一般文字" : helperSecret ? "會執行的指令裡像有金鑰，請改放 env 再帶入" : (remoteURL.map { Self.hasSecret($0, urlOnly: true) } ?? false) ? "網址裡像有金鑰，請改用 headers 或 env 再帶入" : blocked ? "參數裡像有金鑰，請改放 env 再帶入" : dangerous ? "可能大量開程式，曾拖垮 8 GB 的 Mac" : nil }
    }
    struct Scan: Sendable { var items: [Item] = []; var problems: [Group: [String]] = [:] }
    let environment: [String: String]
    var paths: EnginePaths { EnginePaths(environment: environment) }
    var root: URL { environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) } ?? paths.appSupportRoot.appendingPathComponent("live") }
    var url: URL { root.appendingPathComponent("os-mcp.json") }
    private func allowed(_ file: URL) -> Bool {
        NativeStagingIsolation.validationError(environment) == nil && (!NativeStagingIsolation.isEnabled(environment) ||
            [paths.userHome, paths.enginesRoot, root].contains { NativeStagingIsolation.allowsRead(file, within: $0) })
    }
    private func json(_ file: URL) throws -> [String: Any] {
        guard allowed(file) else { throw CocoaError(.fileReadNoPermission) }
        #if DEBUG
        if environment["TATWO2_SELFTEST"] == "w245mcp", NativeStagingIsolation.isEnabled(environment), file.lastPathComponent == ".claude.json", let delay = environment["TATWO2_MCP_TEST_READ_DELAY"].flatMap(Double.init) { Thread.sleep(forTimeInterval: delay) }
        #endif
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return object
    }
    private func definitions(_ file: URL) throws -> [(String?, [String: [String: Any]])] {
        guard allowed(file) else { throw CocoaError(.fileReadNoPermission) }
        if file.pathExtension == "toml" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let parsed = PluginServerConfiguration.parseTOML(text)
            guard !text.contains("\"\"\""), !text.contains("'''") else { throw CocoaError(.fileReadCorruptFile) }
            var objects: [String: [String: Any]] = parsed.mapValues { value in var object: [String: Any] = ["args": value.args, "enabled": value.enabled]; if let command = value.command { object["command"] = command }; return object }
            var current: String?, section = "", pendingArray: (key: String, text: String)?
            let pair = try NSRegularExpression(pattern: #"(?:^|[,{])\s*(?:"([^"]+)"|'([^']+)'|([\w-]+))\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')"#)
            for line in text.components(separatedBy: .newlines) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    let table = PluginServerConfiguration.tableName(line); current = table?.name
                    section = table?.nested == true ? (["env", "headers", "http_headers", "env_http_headers"].first { line.contains("." + $0 + "]") }.map { $0 == "http_headers" ? "headers" : $0 } ?? "ignored") : ""
                } else if let current {
                    if let pending = pendingArray { pendingArray = (pending.key, pending.text + line) }
                    if section.isEmpty, let equal = line.firstIndex(of: "=") {
                        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                        let raw = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                        if ["env_vars", "enabled_tools", "disabled_tools"].contains(key) { pendingArray = (key, raw) }
                        if ["startup_timeout_sec", "tool_timeout_sec"].contains(key), let value = Double(raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)), value.isFinite { objects[current]?[key] = value }
                    }
                    if let pending = pendingArray, pending.text.contains("]") {
                        objects[current]?[pending.key] = PluginServerConfiguration.parseTOML("[mcp_servers.fields]\nargs = " + pending.text)["fields"]?.args ?? []
                        pendingArray = nil
                    }
                    for match in pair.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        let fields = (1...4).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
                        let key = fields.prefix(3).first { !$0.isEmpty } ?? ""
                        let raw = fields[3], value = raw.hasPrefix("'") ? String(raw.dropFirst().dropLast()) : (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
                        let target = section.isEmpty ? (line.range(of: #"^\s*(?:env|[\"']env[\"'])\s*="#, options: .regularExpression) != nil ? "env" : line.range(of: #"^\s*env_http_headers\s*="#, options: .regularExpression) != nil ? "env_http_headers" : line.range(of: #"^\s*(?:http_headers|headers)\s*="#, options: .regularExpression) != nil ? "headers" : "") : section
                        if !target.isEmpty && target != "ignored", let value { var values = objects[current]?[target] as? [String: String] ?? [:]; values[key] = value; objects[current]?[target] = values }
                        if section.isEmpty && ["url", "cwd", "bearer_token_env_var"].contains(key), let value { objects[current]?[key] = value }
                    }
                }
            }
            guard !parsed.isEmpty || !text.contains("mcp_servers") else { throw CocoaError(.fileReadCorruptFile) }
            return [(nil, objects)]
        }
        let object = try json(file)
        func servers(_ object: [String: Any]) throws -> [String: [String: Any]] {
            guard let value = object["mcpServers"] ?? object["servers"] else { return [:] }
            guard let value = value as? [String: [String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        var result = [(file.lastPathComponent == ".mcp.json" ? file.deletingLastPathComponent().path : nil, try servers(object))]
        if let projects = object["projects"] as? [String: [String: Any]] {
            for key in projects.keys.sorted() { result.append((key, try servers(projects[key]!))) }
        }
        return result
    }
    func scan() -> Scan {
        var result = Scan(), sources: [(Group, URL)] = []
        let home = paths.userHome
        let codex = environment["TATWO2_CODEX_SOURCE_HOME"] ?? environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        if codex != home.appendingPathComponent(".codex").path { sources.append((.codex, home.appendingPathComponent(".codex/config.toml"))) }
        sources.append((.codex, URL(fileURLWithPath: codex).appendingPathComponent("config.toml")))
        for path in [".claude.json", ".claude/settings.json", "Library/Application Support/Claude/claude_desktop_config.json"] { sources.append((.claude, home.appendingPathComponent(path))) }
        if NativeStagingIsolation.isEnabled(environment) { sources.append((.claude, paths.claudeAccountFile)); sources.append((.claude, paths.claudeConfigDirectory.appendingPathComponent("settings.json"))) }
        for path in [".cursor/mcp.json", "Library/Application Support/Code/User/mcp.json", ".codeium/windsurf/mcp_config.json"] { sources.append((.general, home.appendingPathComponent(path))) }
        let projects = (try? json(root.appendingPathComponent("document.json")))?["projects"] as? [[String: Any]] ?? []
        for project in projects { if let path = project["workdir"] as? String { sources.append((.general, URL(fileURLWithPath: path).appendingPathComponent(".mcp.json"))) } }
        var seen = Set<String>()
        for (group, file) in sources where allowed(file) && FileManager.default.fileExists(atPath: file.path) {
            do {
                for (scope, servers) in try definitions(file) {
                    for name in servers.keys.sorted() {
                        let object = servers[name]!, command = object["command"] as? String ?? ""
                        guard !command.isEmpty || object["url"] is String else { throw CocoaError(.fileReadCorruptFile) }
                        let item = Item(source: file.path, sourceName: name, name: name, command: command,
                            args: object["args"] as? [String] ?? [], remoteURL: object["url"] as? String, envKeys: Array((object["env"] as? [String: Any] ?? [:]).keys).sorted(), headersHelper: object["headersHelper"] as? String, consent: Consent(object), group: group, scope: scope)
                        if seen.insert(item.id).inserted { result.items.append(item) }
                    }
                }
            } catch { result.problems[group, default: []].append("讀不懂：" + file.path) }
        }
        return result
    }
    func load() throws -> [Item] {
        guard allowed(url) else { throw CocoaError(.fileReadNoPermission) }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let items = try JSONDecoder().decode([Item].self, from: data).map { stored in
            var item = stored
            if item.scope == nil, URL(fileURLWithPath: item.source).lastPathComponent == ".mcp.json" { item.scope = URL(fileURLWithPath: item.source).deletingLastPathComponent().path }
            if item.consent?.fingerprint == nil { item.consent = nil }
            let object = sourceDefinition(item); if let object { item.command = object["command"] as? String ?? ""; item.headersHelper = object["headersHelper"] as? String; item.envKeys = Array((object["env"] as? [String: Any] ?? [:]).keys).sorted() }; item.args = resolve(item)?["args"] as? [String] ?? object?["args"] as? [String] ?? []; item.remoteURL = object?["url"] as? String
            return item
        }
        if raw.contains(where: { !Set($0.keys).isSubset(of: ["source", "sourceName", "name", "group", "scope", "consent", "packageOverride"]) || ($0["consent"] as? [String: Any]).map { !Set($0.keys).isSubset(of: ["fingerprint", "fields"]) } == true }) {
            let stamp = String(Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.prefix(8)
            let backup = root.appendingPathComponent("os-mcp.json.bak-" + stamp)
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try save(items)
        }
        return items
    }
    var backupPath: String? {
        guard allowed(root), let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.lastPathComponent.hasPrefix("os-mcp.json.bak-") }.sorted { $0.path < $1.path }.last.map { "…/" + $0.pathComponents.suffix(2).joined(separator: "/") }
    }
    private func save(_ items: [Item]) throws {
        guard allowed(url) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        Self.composerCache.invalidate(url)
    }
    func available() -> Scan {
        var result = scan()
        let ids = Set(((try? load()) ?? []).map(\.id))
        result.items.removeAll { ids.contains($0.id) }
        return result
    }
    func bringIn(_ selected: [Item]) throws {
        var items = try load()
        for var item in selected {
            guard let object = sourceDefinition(item) else { throw CocoaError(.fileReadNoSuchFile) }
            item.args = object["args"] as? [String] ?? []; item.remoteURL = object["url"] as? String
            guard !item.blocked, item.consent?.fingerprint != nil, item.consent == Consent(object) else { throw CocoaError(.fileReadNoPermission) }
            item.consent = Consent(object)
            if let existing = items.firstIndex(where: { $0.id == item.id }) {
                item.packageOverride = items[existing].packageOverride
                item.consent = Consent(item.execution(object))
                if items[existing].name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil { item.name = items[existing].name; items[existing] = item; continue }
                items.remove(at: existing)
            }
            item.name = item.sourceName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            if item.name.isEmpty { item.name = "mcp" }
            let reserved = item.name == "gbrain_allai" || ["github_", "github-", "tatwo", "os-mcp", "browser-mcp"].contains { item.name.lowercased().hasPrefix($0) }
            let base = item.name + "-" + (item.group == .general ? "general" : item.group.rawValue)
            if reserved || items.contains(where: { $0.name == item.name }) { item.name = base }
            var n = 2
            while items.contains(where: { $0.name == item.name }) { item.name = base + "-\(n)"; n += 1 }
            items.append(item)
        }
        try save(items)
    }
    func remove(_ id: String) throws { try save(load().filter { $0.id != id }) }
    private func sourceDefinition(_ item: Item) -> [String: Any]? {
        (try? definitions(URL(fileURLWithPath: item.source)))?.first(where: { $0.0 == item.scope })?.1[item.sourceName]
    }
    func failureReason(_ item: Item, definition: [String: Any]? = nil) -> String? {
        guard let object = definition ?? sourceDefinition(item) else { return "來源不見了" }
        var current = item; current.args = object["args"] as? [String] ?? []; current.remoteURL = object["url"] as? String
        if current.blocked { return current.warning }
        return item.consent?.fields != nil && item.consent == Consent(item.execution(object)) ? nil : "來源設定變了，請重新帶入"
    }
    func changeNotice(_ item: Item) -> String? {
        guard let object = sourceDefinition(item) else { return nil }
        guard let fields = item.consent?.fields else { return "這版改了同意方式" }
        let current = Consent(item.execution(object))
        let changed = Set(fields.keys).union(current.fields?.keys.map { $0 } ?? []).filter { fields[$0] != current.fields?[$0] }.sorted()
        return changed.isEmpty ? nil : "來源設定變了：" + changed.joined(separator: "、")
    }
    func resolve(_ item: Item) -> [String: Any]? {
        guard let object = sourceDefinition(item), failureReason(item, definition: object) == nil else { return nil }
        return item.execution(object)
    }

    func servers() -> [String: Any] {
        var result: [String: Any] = [:]
        for item in (try? load()) ?? [] { if let object = resolve(item) { result[item.name] = object } }
        return result
    }

    private static let composerCache = ComposerCache()
    private final class ComposerCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (registry: OSMCPRegistry, files: [URL], dates: [Date?], names: [String])] = [:]
        private var generations: [String: Int] = [:]
        private let queue = DispatchQueue(label: "tatwo.mcp.composer-cache", qos: .utility)
        private var refreshing = Set<String>()
        private func key(_ registry: OSMCPRegistry) -> String { registry.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\n") }
        private func dates(_ files: [URL], _ registry: OSMCPRegistry) -> [Date?] {
            files.map { file in
                if NativeStagingIsolation.isEnabled(registry.environment), !NativeStagingIsolation.allowsRead(file, within: URL(fileURLWithPath: registry.environment["TATWO_STAGING_ROOT"] ?? "/nonexistent")) { return nil }
                return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            }
        }
        func invalidate(_ file: URL) {
            lock.lock(); defer { lock.unlock() }
            for entry in Array(entries.keys) where entries[entry]?.registry.url == file { entries.removeValue(forKey: entry); generations[entry, default: 0] += 1; refreshing.remove(entry) }
        }
        func names(_ registry: OSMCPRegistry) -> [String] {
            let id = key(registry)
            lock.lock(); let entry = entries[id], generation = generations[id, default: 0]; lock.unlock()
            guard let entry else { return rebuild(registry, id: id, generation: generation) }
            if dates(entry.files, registry) != entry.dates {
                lock.lock(); let start = generations[id, default: 0] == generation && refreshing.insert(id).inserted; lock.unlock()
                if start { queue.async { _ = self.rebuild(registry, id: id, generation: generation) } }
            }
            return entry.names
        }
        private func rebuild(_ registry: OSMCPRegistry, id: String, generation: Int) -> [String] {
            let files = [registry.url, registry.environment["TATWO2_GITHUB_ACCOUNTS_FILE"].map { URL(fileURLWithPath: $0) } ?? registry.root.deletingLastPathComponent().appendingPathComponent("github/accounts.json"), TatwoEntry(environment: registry.environment).deviceJSON] + ((try? registry.load()) ?? []).map { URL(fileURLWithPath: $0.source) }
            let stamps = dates(files, registry), names = registry.uncachedComposerNames
            lock.lock(); defer { lock.unlock() }
            guard generations[id, default: 0] == generation else { return entries[id]?.names ?? names }
            entries[id] = (registry, files, stamps, names); generations[id, default: 0] += 1; refreshing.remove(id)
            return names
        }
        func generation(_ registry: OSMCPRegistry) -> Int { lock.lock(); defer { lock.unlock() }; return generations[key(registry), default: 0] }
    }
    var composerNames: [String] { Self.composerCache.names(self) }
    #if DEBUG
    var composerCacheGeneration: Int { Self.composerCache.generation(self) }
    #endif
    private var uncachedComposerNames: [String] {
        let brain = GBrainService.definition(environment: environment) == nil ? [] : ["gbrain"]
        let github = ((try? GitHubAccountsStore(environment: environment).loadAccounts()) ?? []).map { "github-" + $0.username }
        return ["TATWO OS"] + Array(Set(brain + github + ((try? load()) ?? []).filter { resolve($0) != nil }.map(\.name))).sorted()
    }

    typealias Fetcher = @Sendable (URL) async throws -> Data
    struct Update: Sendable {
        enum State: Sendable { case newer, latest, unpinned, local, missing }
        var state: State
        var oldVersion = "", newVersion = ""
        var oldArgs: [String] = [], newArgs: [String] = []
        var label: String {
            switch state {
            case .newer: "有更新 \(oldVersion) → \(newVersion)"
            case .latest: "已是最新"
            case .unpinned: "沒指定版本（每次啟動都抓最新）"
            case .local: "無法檢查（本機程式）"
            case .missing: "查不到（網路或套件名）"
            }
        }
    }
    func checkUpdates(fetcher: Fetcher? = nil) async -> [String: Update] {
        var results: [String: Update] = [:]
        for item in (try? load()) ?? [] {
            var index: Int?, npm = false
            switch URL(fileURLWithPath: item.command).lastPathComponent {
            case "npx": npm = true; index = item.args.firstIndex { !["-y", "--yes"].contains($0) }
            case "uvx": index = item.args.isEmpty ? nil : 0
            case "pipx": if item.args.first == "run" { index = item.args.firstIndex(of: "--spec").map { $0 + 1 } ?? (item.args.count > 1 ? 1 : nil) }
            default: break
            }
            guard let index, item.args.indices.contains(index), !item.args[index].hasPrefix("-") else { results[item.id] = Update(state: .local); continue }
            let spec = item.args[index], split = npm ? spec.lastIndex(of: "@").flatMap { $0 == spec.startIndex ? nil : $0 } : spec.range(of: "==")?.lowerBound
            let pkg = split.map { String(spec[..<$0]) } ?? spec
            let version = split.map { String(spec[spec.index($0, offsetBy: npm ? 1 : 2)...]) } ?? ""
            guard !version.isEmpty else { results[item.id] = Update(state: .unpinned); continue }
            let endpoint = npm ? "https://registry.npmjs.org/\(pkg)/latest" : "https://pypi.org/pypi/\(pkg)/json"
            do {
                guard let endpoint = URL(string: endpoint), pkg.range(of: #"^(?:@[\w.-]+/)?[\w.-]+$"#, options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
                let data: Data
                if let fetcher { data = try await fetcher(endpoint) }
                else {
                    guard !NativeStagingIsolation.isEnabled(environment) else { throw URLError(.notConnectedToInternet) }
                    var request = URLRequest(url: endpoint); request.timeoutInterval = 8
                    let reply = try await URLSession.shared.data(for: request)
                    guard (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    data = reply.0
                }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let latest = (npm ? object?["version"] : (object?["info"] as? [String: Any])?["version"]) as? String, !latest.isEmpty else { throw URLError(.cannotParseResponse) }
                var args = item.args; args[index] = pkg + (npm ? "@" : "==") + latest
                results[item.id] = Update(state: version.compare(latest, options: .numeric) == .orderedAscending ? .newer : .latest,
                    oldVersion: version, newVersion: latest, oldArgs: item.args, newArgs: args)
            } catch { results[item.id] = Update(state: .missing) }
        }
        return results
    }
    func update(_ id: String, to update: Update, confirmed: Bool) throws {
        guard confirmed, update.state == .newer else { return }
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].args == update.oldArgs else { throw CocoaError(.fileWriteUnknown) }
        guard failureReason(items[index]) == nil, update.oldArgs.count == update.newArgs.count,
              update.oldArgs.indices.filter({ update.oldArgs[$0] != update.newArgs[$0] }).count == 1,
              let changed = update.oldArgs.indices.first(where: { update.oldArgs[$0] != update.newArgs[$0] }) else { throw CocoaError(.fileWriteUnknown) }
        var preview = items[index]; preview.args = update.newArgs
        guard !preview.blocked else { throw CocoaError(.fileWriteNoPermission) }
        let sourceSpec = items[index].packageOverride?.first ?? update.oldArgs[changed]
        items[index].packageOverride = [sourceSpec, update.newArgs[changed]]
        guard let object = sourceDefinition(items[index]) else { throw CocoaError(.fileReadNoSuchFile) }
        items[index].consent = Consent(items[index].execution(object))
        try save(items)
    }

}
