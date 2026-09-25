import Foundation

/// W160 設定 › OS：這台上每個 AI 引擎讀哪個規則檔、有沒有連到入口。
/// 只做兩件事：看（scan）與把一個引擎接上（link：原件封存到入口 archive，原位換成連結）。
/// 不讀內容、不改引擎的其他設定。
struct EngineLinkRow: Identifiable, Equatable {
    enum State: Equatable { case linked, notLinked, notInstalled, notApplicable }

    let id: String
    let name: String
    /// 顯示用的路徑說明，例如「~/.claude/CLAUDE.md → 入口/agents.md」
    let pathText: String
    let state: State
    let statusText: String
    /// 可接上的檔案（引擎端路徑 → 入口檔名）；nil＝這列不能在這裡接
    let links: [(source: String, target: String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state && lhs.pathText == rhs.pathText && lhs.statusText == rhs.statusText
    }
}

enum EngineLinks {
    static func scan(entry: TatwoEntry = TatwoEntry(), home: String = NSHomeDirectory(),
                     runtimeUpstreamPath: String = OSUpstream.runtimePath(environment: ProcessInfo.processInfo.environment)) -> [EngineLinkRow] {
        let root = entry.root.path
        var rows: [EngineLinkRow] = []
        func tilde(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }

        func single(id: String, name: String, homeDir: String, file: String, target: String) {
            let source = homeDir + "/" + file
            let state: EngineLinkRow.State
            if !FileManager.default.fileExists(atPath: homeDir) { state = .notInstalled }
            else { state = isLink(source, to: root + "/" + target) ? .linked : .notLinked }
            rows.append(EngineLinkRow(id: id, name: name, pathText: "\(tilde(source)) → 入口/\(target)", state: state,
                                      statusText: text(state), links: state == .notInstalled ? [] : [(source, target)]))
        }
        single(id: "claude", name: "Claude Code", homeDir: home + "/.claude", file: "CLAUDE.md", target: "agents.md")
        single(id: "codex", name: "Codex CLI", homeDir: home + "/.codex", file: "AGENTS.md", target: "agents.md")

        let builtIn = FileManager.default.fileExists(atPath: runtimeUpstreamPath)
        rows.append(EngineLinkRow(id: "builtin", name: "OS 內建 Claude／Codex／Grok",
                                  pathText: "每條對話開頭帶入 agents.md 與 user.md",
                                  state: builtIn ? .linked : .notLinked,
                                  statusText: builtIn ? "已接" : "下次開新對話時產生", links: []))

        if FileManager.default.fileExists(atPath: home + "/.openclaw") {
            single(id: "openclaw", name: "OpenClaw", homeDir: home + "/.openclaw/workspace", file: "AGENTS.md", target: "agents.md")
        }
        rows.append(EngineLinkRow(id: "grok-cli", name: "Grok CLI", pathText: "沒有全域規則檔；OS 啟動時用 --rules 帶入",
                                  state: .notApplicable, statusText: "不適用", links: []))

        // $skillet：三家各一份 SKILL.md，全部連到入口 skillet.md 才算接好。
        let skillHomes = [".claude", ".codex", ".grok"].map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        let skillLinks = skillHomes.map { ($0 + "/skills/skillet/SKILL.md", "skillet.md") }
        let skillState: EngineLinkRow.State = skillLinks.isEmpty ? .notInstalled
            : skillLinks.allSatisfy({ isLink($0.0, to: root + "/skillet.md") }) ? .linked : .notLinked
        rows.append(EngineLinkRow(id: "skillet", name: "技能 $skillet",
                                  pathText: "各家 skills/skillet/SKILL.md → 入口/skillet.md",
                                  state: skillState, statusText: text(skillState), links: skillLinks))
        return rows
    }

    static func text(_ state: EngineLinkRow.State) -> String {
        switch state {
        case .linked: "已接・一致"
        case .notLinked: "還沒接"
        case .notInstalled: "沒有安裝"
        case .notApplicable: "不適用"
        }
    }

    /// 連結是否（逐層解開後）指到入口的那個檔。入口本身可能也是連結（mini），兩邊都解開再比。
    static func isLink(_ path: String, to target: String) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { return false }
        let a = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
        return a == b && FileManager.default.fileExists(atPath: b)
    }

    /// 接上：原件（若有）搬到入口 archive/engine-rules/<日期>/<id>/ 並記 MANIFEST，原位換成連結。
    /// 已是正確連結的略過；入口缺目標檔就不接（不製造斷掉的連結）。
    static func link(_ row: EngineLinkRow, entry: TatwoEntry = TatwoEntry(), now: Date = Date()) throws {
        let fm = FileManager.default
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let archive = entry.root.appendingPathComponent("archive/engine-rules/\(formatter.string(from: now))/\(row.id)")
        var manifest: [String] = []
        for (source, target) in row.links {
            let targetPath = entry.root.appendingPathComponent(target).path
            guard fm.fileExists(atPath: targetPath) else { throw OSUpstreamBinding.failure("入口缺少 \(target)，先不接") }
            if isLink(source, to: targetPath) { continue }
            let sourceURL = URL(fileURLWithPath: source)
            try fm.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: source)) != nil || fm.fileExists(atPath: source) {
                try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                var saved = archive.appendingPathComponent(sourceURL.lastPathComponent)
                var n = 1
                while fm.fileExists(atPath: saved.path) || (try? fm.destinationOfSymbolicLink(atPath: saved.path)) != nil {
                    saved = archive.appendingPathComponent("\(sourceURL.lastPathComponent).\(n)"); n += 1
                }
                try fm.moveItem(atPath: source, toPath: saved.path)
                manifest.append("- \(saved.lastPathComponent) ← \(source)（還原：刪掉連結，把這個檔搬回去）")
            }
            try fm.createSymbolicLink(atPath: source, withDestinationPath: targetPath)
        }
        if !manifest.isEmpty {
            let file = archive.appendingPathComponent("MANIFEST.md")
            let header = fm.fileExists(atPath: file.path) ? "" : "# \(row.name) 接上統一入口前的原件\n\n"
            let handle = try? FileHandle(forWritingTo: file)
            if let handle {
                handle.seekToEndOfFile(); handle.write(Data((manifest.joined(separator: "\n") + "\n").utf8)); try? handle.close()
            } else {
                try Data((header + manifest.joined(separator: "\n") + "\n").utf8).write(to: file)
            }
        }
    }
}
