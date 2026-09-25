import Foundation

/// W162：用 Spotlight 找這台所有 AI 規則檔、技能、MCP 與 Hook 設定，逐一做安全檢查。
/// 只讀、可隨時丟棄；不改任何檔。各家全域入口（~/.claude 等隱藏資料夾）Spotlight 不索引，另外補看。
struct EngineRuleScanItem: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var kind: EngineRuleAudit.Kind
    var linkedToEntry: Bool
    var findings: [EngineRuleAudit.Finding]
}

enum EngineRuleScanner {
    static func scan(home: String = NSHomeDirectory(), entry: TatwoEntry = TatwoEntry(), limit: Int = 3000) -> [EngineRuleScanItem] {
        var paths = Set<String>()
        let names = EngineRuleAudit.ruleNames.union(["SKILL.md", ".mcp.json"])
        let query = names.map { "kMDItemFSName == '\($0)'" }.joined(separator: " || ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home, query]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { paths.insert(String(line)) }
        }
        // Spotlight 不看隱藏資料夾：各家全域入口與技能根另外列。
        for engineHome in [".claude", ".codex", ".grok", ".openclaw/workspace"] {
            let base = home + "/" + engineHome
            for file in ["CLAUDE.md", "AGENTS.md", "settings.json", "hooks.json", ".mcp.json"] where FileManager.default.fileExists(atPath: base + "/" + file) {
                paths.insert(base + "/" + file)
            }
            if let skills = try? FileManager.default.contentsOfDirectory(atPath: base + "/skills") {
                for skill in skills where FileManager.default.fileExists(atPath: base + "/skills/" + skill + "/SKILL.md") {
                    paths.insert(base + "/skills/" + skill + "/SKILL.md")
                }
            }
        }
        if FileManager.default.fileExists(atPath: home + "/.claude.json") { paths.insert(home + "/.claude.json") }
        let entryRoot = entry.root.resolvingSymlinksInPath().path
        var items: [EngineRuleScanItem] = []
        for path in paths.sorted() where !EngineRuleAudit.isNoise(path) && !path.hasPrefix(entryRoot) {
            let name = (path as NSString).lastPathComponent
            guard let kind = name == ".claude.json" ? .mcp : EngineRuleAudit.kind(ofFileNamed: name) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let linked = resolved.hasPrefix(entryRoot + "/")
            var findings: [EngineRuleAudit.Finding] = []
            if !linked, let handle = FileHandle(forReadingAtPath: path) {
                let data = handle.readData(ofLength: 512 * 1024); try? handle.close()
                findings = EngineRuleAudit.audit(String(decoding: data, as: UTF8.self), kind: kind)
            }
            items.append(.init(path: path, kind: kind, linkedToEntry: linked, findings: findings))
            if items.count >= limit { break }
        }
        return items
    }
}
