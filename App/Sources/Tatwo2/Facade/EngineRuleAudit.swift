import Foundation

/// W162 全機收斂的安全檢查（純文字，不碰檔案，tests/w162-scan.test.mjs 單獨編譯）。
/// 只回報「在哪一行、是哪一類」，從不回傳內容本身——疑似金鑰那一行更不能被印出來。
enum EngineRuleAudit {
    enum Kind: String, CaseIterable { case rules = "規則檔", skill = "技能", mcp = "MCP 設定", hooks = "Hook 設定" }

    struct Finding: Equatable {
        var line: Int
        var category: String   // 外來指示／疑似金鑰／會執行指令
        var note: String       // 不含原文
    }

    static let ruleNames: Set<String> = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "GROK.md", ".cursorrules", "copilot-instructions.md"]

    static func kind(ofFileNamed name: String) -> Kind? {
        if ruleNames.contains(name) { return .rules }
        if name == "SKILL.md" { return .skill }
        if name == ".mcp.json" || name == "mcp.json" { return .mcp }
        if name == "settings.json" || name == "hooks.json" { return .hooks }
        return nil
    }

    private static let injection: [String] = [
        #"ignore (all |any )?(the )?(previous|prior|above) instructions"#, #"disregard (all |any )?(previous|prior|your) instructions"#,
        #"do not (tell|inform|show) the user"#, #"不要(告訴|讓)使用者"#, #"忽略(之前|以上|先前)的(指示|規則)"#,
        #"you are now (in )?(developer|dan|jailbreak)"#,
    ]
    private static let secrets: [(String, String)] = [
        (#"\bsk-(proj-|ant-)?[A-Za-z0-9_\-]{20,}"#, "像 API 金鑰"), (#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, "像 GitHub token"),
        (#"\bgithub_pat_[A-Za-z0-9_]{30,}"#, "像 GitHub token"), (#"\bAKIA[0-9A-Z]{16}\b"#, "像 AWS 金鑰"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "私鑰"), (#"\bxox[abpr]-[A-Za-z0-9-]{10,}"#, "像 Slack token"),
    ]

    static func audit(_ text: String, kind: Kind) -> [Finding] {
        var findings: [Finding] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.lowercased()
            if injection.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) {
                findings.append(.init(line: index + 1, category: "外來指示", note: "要 AI 忽略規則或瞞著使用者的句子"))
            }
            for (pattern, what) in secrets where raw.range(of: pattern, options: .regularExpression) != nil {
                findings.append(.init(line: index + 1, category: "疑似金鑰", note: what + "（內容不顯示）"))
                break
            }
            if kind == .mcp || kind == .hooks, raw.range(of: #""command"\s*:\s*""#, options: .regularExpression) != nil {
                let parts = raw.components(separatedBy: "\"")
                let name = parts.firstIndex(of: "command").flatMap { $0 + 2 < parts.count ? parts[$0 + 2] : nil }
                    .map { ($0 as NSString).lastPathComponent } ?? "?"
                findings.append(.init(line: index + 1, category: "會執行指令", note: "啟動 " + String(name.prefix(40))))
            }
        }
        return findings
    }

    /// 不該掃的地方：套件、建置產物、快取、封存、垃圾桶。
    static func isNoise(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        let noisy: Set<Substring> = ["node_modules", ".build", "build", "dist", "DerivedData", "Caches", ".Trash", "archive",
                                     "archives", ".git", "vendor", "Pods", "site-packages", ".venv", "plugins", "cache"]
        return parts.contains(where: { noisy.contains($0) }) || path.contains("/Library/Application Support/")
    }
}
