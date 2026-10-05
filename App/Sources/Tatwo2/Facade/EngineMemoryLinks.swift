import CryptoKit
import Darwin
import Foundation

/// W179 設定 › OS › 記憶：讓 Claude Code、Codex 共用入口的 `memory/`（一條一個 Markdown、`MEMORY.md` 索引，
/// 資料夾自己是一個 git 倉庫，入口的 git 不追蹤它）。設計見 docs/plans/W179-通用記憶設計.md「兩家引擎的記憶怎麼接到 OS」。
/// 跟 EngineLinks 同一套做法：看（scan）、接上（link：原件先整份封存到入口 archive、寫還原.md）、還原（restore）。
/// 所有路徑都從 EngineMemoryPaths 來（預設才用這台的家目錄與入口），自測在假 HOME 裡跑。
/// settings.json 只合併 `autoMemoryDirectory` 一個鍵；config.toml 只動兩行：`[memories] generate_memories = false`，
/// 以及 Codex 記憶功能的總開關 `[features] memories = true`（預設是關的，不開 Codex 根本不讀記憶）。其他位元組原樣保留，
/// 裡面若有金鑰或權杖照樣留著，不讀出來用、不寫進任何紀錄。memory/ 會被複製到其他設備，所以 Codex 的原始紀錄
/// （raw_memories.md、rollout_summaries/）不進 git，看起來含金鑰或權杖的檔也不進 git。
enum EngineMemoryEngine: String, CaseIterable, Codable, Sendable {
    case claude, codex
    var name: String { self == .claude ? "Claude Code" : "Codex CLI" }
}

struct EngineMemoryPaths: Sendable {
    let home: String
    let entryRoot: URL

    init(home: String = NSHomeDirectory(), entryRoot: URL = TatwoEntry().root) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.entryRoot = entryRoot
    }

    var memory: URL { entryRoot.appendingPathComponent("memory", isDirectory: true) }
    var archiveRoot: URL { entryRoot.appendingPathComponent("archive", isDirectory: true) }
    var claudeHome: String { home + "/.claude" }
    var claudeSettings: String { claudeHome + "/settings.json" }
    var claudeProjects: String { claudeHome + "/projects" }
    var codexHome: String { home + "/.codex" }
    var codexConfig: String { codexHome + "/config.toml" }
    var codexMemories: String { codexHome + "/memories" }
    var codexSummary: String { codexMemories + "/memory_summary.md" }

    func tilde(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
    /// 寫進 Claude 設定的值：在家目錄底下就寫成 `~/…`（跟主導手動接的一樣），否則寫絕對路徑。
    var settingsValue: String { tilde(memory.path) }
}

struct EngineMemoryRow: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case linked, notLinked, notInstalled }
    let engine: EngineMemoryEngine
    let pathText: String
    let state: State
    let statusText: String
    /// OS 自己接上時留了封存，可以一鍵還原（主導手動接的沒有封存紀錄，不給按）。
    let canRestore: Bool
    var id: String { engine.rawValue }
    var name: String { engine.name }
}

struct EngineMemoryStatus: Equatable, Sendable {
    let memoryPathText: String
    let exists: Bool
    let isGitRepository: Bool
    let itemCount: Int
    let awaitingPrimarySync: Bool
    let rows: [EngineMemoryRow]

    var installed: [EngineMemoryRow] { rows.filter { $0.state != .notInstalled } }
    var pending: [EngineMemoryRow] { rows.filter { $0.state == .notLinked } }
    var folderLine: String {
        guard exists else { return "記憶資料夾：\(memoryPathText)（還沒建立，接上時會建）" }
        var parts = ["記憶資料夾：\(memoryPathText)", "\(itemCount) 條"]
        if !isGitRepository { parts.append("還不是 git 倉庫") }
        if awaitingPrimarySync { parts.append("等主設備同步") }
        return parts.joined(separator: "・")
    }
}

/// 每次接上都在封存資料夾留一份，還原照這份做；每一步做之前先記下來，停在一半也還原得回去。
struct EngineMemoryManifest: Codable {
    struct Moved: Codable, Equatable { var original: String; var moved: String }
    struct Claude: Codable {
        var settingsPath: String
        var settingsExisted: Bool
        /// 接上前 `autoMemoryDirectory` 的原始 JSON 文字（原本沒有＝nil）。
        var originalValue: String?
        var writtenSHA: String?
        var moved: [Moved]
        var restoredAt: Date?
        /// 真的動過東西（寫過設定或搬過資料夾）才有得還原；寫之前就失敗的那次不算。
        var restorable: Bool { restoredAt == nil && (writtenSHA != nil || !moved.isEmpty) }
    }
    struct Codex: Codable {
        var configPath: String
        var configExisted: Bool
        /// replaced／inserted／appended／created；nil＝本來就是 false，沒有改。
        var edit: String?
        var originalLine: String?
        var writtenLine: String?
        var writtenSHA: String?
        var summaryPath: String
        var summaryExisted: Bool
        var memoriesExisted: Bool
        var summaryWritten: Bool
        var restoredAt: Date?
        /// `[features] memories` 那一行：跟 edit 同一套（nil＝本來就開著，沒有改）。
        var featureEdit: String? = nil
        var featureOriginalLine: String? = nil
        var featureWrittenLine: String? = nil
        var restorable: Bool {
            restoredAt == nil && (writtenSHA != nil || edit != nil || featureEdit != nil || summaryWritten)
        }
    }
    var version: Int
    var createdAt: Date
    var device: String
    var memoryPath: String
    var claude: Claude?
    var codex: Codex?
}

struct EngineMemoryLinkReport: Sendable {
    var archive: String?
    var importedFiles = 0
    var notes: [String] = []
}

enum EngineMemoryLinks {
    static let marker = "由 TATWO OS 產生，勿手改"
    static let settingsKey = "autoMemoryDirectory"
    /// Claude 開場只讀 MEMORY.md 前 200 行或 25 KB；主索引守在這之內，放不下的放 MEMORY-<來源>.md。
    static let maxIndexLines = 200
    static let maxIndexBytes = 25_000
    static let maxSummaryBytes = 8_192
    static let archivePrefix = "engine-memory-"
    static let awaitingPrimaryMarker = "tatwo-awaiting-primary"
    /// 主設備入口的 memory/，相對於那台的家目錄（入口固定在 ~/AI/TATWO OS）。
    static let remoteMemoryPath = "AI/TATWO OS/memory"
    static let indexHeader = ["# 記憶索引", "",
                              "TATWO 通用記憶。一條一個檔，開頭欄位照 Claude 的格式；說明見 README.md。放不下的在 MEMORY-<來源>.md。"]

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: 看

    static func scan(paths: EngineMemoryPaths = EngineMemoryPaths()) -> EngineMemoryStatus {
        let fm = FileManager.default
        let memory = paths.memory.path
        let exists = directoryExists(memory)
        let git = exists && fm.fileExists(atPath: memory + "/.git")
        let awaiting = git && fm.fileExists(atPath: memory + "/.git/" + awaitingPrimaryMarker)
        let records = manifests(paths).map(\.manifest)
        var rows: [EngineMemoryRow] = []

        if fm.fileExists(atPath: paths.claudeHome) {
            let settings = claudeSettings(paths)
            let value = settings?[settingsKey] as? String
            let linked = exists && value.map { pointsToMemory($0, paths: paths) } == true
            let enabled = (settings?["autoMemoryEnabled"] as? Bool) != false
            let pointed = value.map { pointsToMemory($0, paths: paths) } == true
            let status = linked ? (enabled ? "已接・共用入口的記憶" : "已接，但 Claude 的自動記憶被關掉了")
                : pointed ? "設定已指到入口，但記憶資料夾還沒建立" : value != nil ? "還沒接（現在指到別的資料夾）" : "還沒接"
            rows.append(EngineMemoryRow(engine: .claude,
                                        pathText: "\(paths.tilde(paths.claudeSettings)) › \(settingsKey) → 入口/memory",
                                        state: linked ? .linked : .notLinked, statusText: status,
                                        canRestore: records.contains { $0.claude?.restorable == true }))
        } else {
            rows.append(EngineMemoryRow(engine: .claude, pathText: "這台沒有 ~/.claude", state: .notInstalled,
                                        statusText: "沒有安裝", canRestore: false))
        }

        if fm.fileExists(atPath: paths.codexHome) {
            let config = (try? Data(contentsOf: URL(fileURLWithPath: paths.codexConfig))).map { String(decoding: $0, as: UTF8.self) }
            let generate = config.flatMap { TOMLMemories.value(of: "generate_memories", in: $0) }
            let use = config.flatMap { TOMLMemories.value(of: "use_memories", in: $0) }
            // Codex 的記憶功能預設是關的（codex features list：memories false），沒開就不會讀任何記憶。
            let feature = config.flatMap { TOMLMemories.value(of: "memories", table: "features", in: $0) } == true
            let marked = summaryHasMarker(paths.codexSummary)
            let linked = exists && generate == false && marked && feature
            let status = linked ? (use == false ? "已接，但 Codex 設成不讀記憶（use_memories = false）" : "已接・讀 OS 產生的摘要")
                : generate == false && marked ? "還沒接（Codex 的記憶功能沒開：[features] memories）"
                : generate == false ? "還沒接（摘要還不是 OS 產生的）" : "還沒接"
            rows.append(EngineMemoryRow(engine: .codex,
                                        pathText: "\(paths.tilde(paths.codexSummary)) ← 入口/memory",
                                        state: linked ? .linked : .notLinked, statusText: status,
                                        canRestore: records.contains { $0.codex?.restorable == true }))
        } else {
            rows.append(EngineMemoryRow(engine: .codex, pathText: "這台沒有 ~/.codex", state: .notInstalled,
                                        statusText: "沒有安裝", canRestore: false))
        }
        return EngineMemoryStatus(memoryPathText: paths.tilde(memory), exists: exists, isGitRepository: git,
                                  itemCount: exists ? memoryItems(in: paths.memory).count : 0,
                                  awaitingPrimarySync: awaiting, rows: rows)
    }

    /// `~/…` 與絕對路徑都算；兩邊都解開連結再比（mini 的入口本身是連結）。
    static func pointsToMemory(_ value: String, paths: EngineMemoryPaths) -> Bool {
        var expanded = value.trimmingCharacters(in: .whitespaces)
        if expanded == "~" { expanded = paths.home }
        else if expanded.hasPrefix("~/") { expanded = paths.home + "/" + expanded.dropFirst(2) }
        guard expanded.hasPrefix("/") else { return false }
        let a = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        let b = paths.memory.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b
    }

    /// 一條記憶一個檔：最上層的 .md，不算索引與說明。
    static func memoryItems(in memory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") && !isIndexFile($0) }
            .sorted()
    }

    static func isIndexFile(_ name: String) -> Bool {
        name == "MEMORY.md" || name == "README.md" || (name.hasPrefix("MEMORY-") && name.hasSuffix(".md"))
    }

    static func summaryHasMarker(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return String(decoding: handle.readData(ofLength: 600), as: UTF8.self).contains(marker)
    }

    private static func claudeSettings(_ paths: EngineMemoryPaths) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func manifests(_ paths: EngineMemoryPaths) -> [(url: URL, manifest: EngineMemoryManifest)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.archiveRoot.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [(url: URL, manifest: EngineMemoryManifest)] = []
        for name in names where name.hasPrefix(archivePrefix) {
            let url = paths.archiveRoot.appendingPathComponent(name).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(EngineMemoryManifest.self, from: data) else { continue }
            found.append((url, manifest))
        }
        return found.sorted {
            $0.manifest.createdAt != $1.manifest.createdAt ? $0.manifest.createdAt > $1.manifest.createdAt
                : $0.url.path > $1.url.path
        }
    }

    // MARK: 接上

    /// 接上（預設兩家都接；已接上的略過）。順序：a 入口 memory/ → c 原件整份封存 → b 匯入 → d Claude → e Codex → f commit。
    /// 副設備的 memory/ 不在時先試著從主設備複製；複製不到就在本機建一份、狀態寫「等主設備同步」，不失敗。
    @discardableResult
    static func link(_ engines: Set<EngineMemoryEngine> = Set(EngineMemoryEngine.allCases),
                     paths: EngineMemoryPaths = EngineMemoryPaths(), now: Date = Date(),
                     deviceName: String? = nil, role: DeviceRole? = nil,
                     pullFromPrimary: ((URL) -> Bool)? = nil) throws -> EngineMemoryLinkReport {
        TatwoMemoryLock.shared.lock(); defer { TatwoMemoryLock.shared.unlock() } // W180 E1b：寫 memory/ 時不跟自動同步撞
        let fm = FileManager.default
        var report = EngineMemoryLinkReport()
        let identity = try? DeviceIdentityStore.readLocal(entry: entry(paths))
        let role = role ?? identity?.role ?? .primary
        let device = safeName(deviceName ?? identity?.name ?? Host.current().localizedName ?? "this-mac")
        let before = scan(paths: paths)
        let targets = Set(before.rows.filter { engines.contains($0.engine) && $0.state == .notLinked }.map(\.engine))
        let stamp = dayStamp(now)

        // a. 入口 memory/
        if !before.exists {
            let pull = pullFromPrimary ?? { url in clonePrimaryMemory(into: url, paths: paths) }
            if role == .secondary, pull(paths.memory), directoryExists(paths.memory.path) {
                report.notes.append("已從主設備複製一份記憶")
            } else {
                try createMemoryFolder(paths.memory)
                if role == .secondary {
                    try? Data(stamp.utf8).write(to: paths.memory.appendingPathComponent(".git/" + awaitingPrimaryMarker))
                    report.notes.append("連不上主設備，先在這台建一份記憶，等主設備同步")
                }
            }
        } else if !fm.fileExists(atPath: paths.memory.path + "/.git") {
            try createMemoryFolder(paths.memory)
        }
        guard !targets.isEmpty else {
            report.notes += commit(paths.memory, message: "TATWO OS：記憶資料夾（\(stamp)，\(device)）")
            return report
        }

        // c. 原件整份封存（動任何東西之前）
        let archive = try makeArchive(paths, now: now)
        report.archive = archive.path
        let sources = targets.contains(.claude) ? claudeSources(paths) : []
        var manifest = EngineMemoryManifest(version: 1, createdAt: now, device: device, memoryPath: paths.memory.path)
        if targets.contains(.claude) {
            for source in sources {
                let destination = archive.appendingPathComponent("claude-projects/\(source.folder)/memory", isDirectory: true)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source.dir, to: destination)
            }
            let original = try? Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))
            if let original { try writePrivate(original, to: archive.appendingPathComponent("claude-settings.json")) }
            var originalValue: String?
            if let original {
                let bytes = [UInt8](original)
                if let member = JSONMembers.parse(bytes)?.members.first(where: { $0.key == settingsKey }) {
                    originalValue = String(decoding: bytes[member.valueRange], as: UTF8.self)
                }
            }
            manifest.claude = EngineMemoryManifest.Claude(settingsPath: paths.claudeSettings, settingsExisted: original != nil,
                                    originalValue: originalValue, writtenSHA: nil, moved: [], restoredAt: nil)
        }
        if targets.contains(.codex) {
            let memoriesExisted = directoryExists(paths.codexMemories)
            if memoriesExisted {
                try fm.copyItem(atPath: paths.codexMemories, toPath: archive.appendingPathComponent("codex-memories").path)
            }
            let config = try? Data(contentsOf: URL(fileURLWithPath: paths.codexConfig))
            if let config { try writePrivate(config, to: archive.appendingPathComponent("codex-config.toml")) }
            manifest.codex = EngineMemoryManifest.Codex(configPath: paths.codexConfig, configExisted: config != nil, edit: nil, originalLine: nil,
                                   writtenLine: nil, writtenSHA: nil, summaryPath: paths.codexSummary,
                                   summaryExisted: fm.fileExists(atPath: paths.codexSummary),
                                   memoriesExisted: memoriesExisted, summaryWritten: false, restoredAt: nil)
        }
        try save(manifest, archive)
        try writeRestoreNote(manifest, archive: archive, sources: sources, paths: paths, date: stamp)

        // b. 匯入：Claude 各專案的記憶檔＋索引；Codex 自己整理的記憶放 imports/（唯讀參考）
        var sections: [IndexSection] = []
        if targets.contains(.claude) {
            let imported = try importClaude(sources, into: paths.memory, date: stamp)
            report.importedFiles += imported.count
            sections = imported.sections
        }
        var pointers: [String] = []
        if targets.contains(.codex), let pointer = try importCodex(paths: paths, device: device, now: now) {
            pointers.append(pointer)
        }
        try mergeIndex(memory: paths.memory, sections: sections, pointers: pointers)

        // d. Claude：settings.json 只合併一個鍵；舊的記憶資料夾改名後換成連結（還開著的對話也寫進新地方）
        if targets.contains(.claude), var record = manifest.claude {
            let original = try? Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))
            let value = paths.settingsValue
            let updated = try JSONMembers.setting(settingsKey, rawValue: JSONMembers.quoted(value), in: original)
            try JSONMembers.verify(old: original, new: updated, key: settingsKey, expected: value)
            // 先記下要寫的內容再寫：寫到一半停下，還原也認得出這是我們寫的。
            record.writtenSHA = sha256(updated)
            manifest.claude = record
            try save(manifest, archive)
            try writePreserving(updated, to: paths.claudeSettings)
            for source in sources {
                let moved = uniquePath(source.dir.path + ".moved-w179-" + stamp)
                record.moved.append(.init(original: source.dir.path, moved: moved))
                manifest.claude = record
                try save(manifest, archive)
                try fm.moveItem(atPath: source.dir.path, toPath: moved)
                try fm.createSymbolicLink(atPath: source.dir.path, withDestinationPath: paths.memory.path)
            }
        }

        // e. Codex：config.toml 打開 [features] memories、把 generate_memories 改成 false（use_memories 不動）；摘要換成 OS 產生的
        if targets.contains(.codex), var record = manifest.codex {
            let original = try? Data(contentsOf: URL(fileURLWithPath: paths.codexConfig))
            let feature = try TOMLMemories.enableFeature(original)
            let generate = try TOMLMemories.disableGenerate(feature?.data ?? original)
            if let data = generate?.data ?? feature?.data {
                record.edit = generate?.kind
                record.originalLine = generate?.originalLine
                record.writtenLine = generate?.writtenLine
                record.featureEdit = feature?.kind
                record.featureOriginalLine = feature?.originalLine
                record.featureWrittenLine = feature?.writtenLine
                record.writtenSHA = sha256(data)
                manifest.codex = record
                try save(manifest, archive)
                try writePreserving(data, to: paths.codexConfig)
            }
            record.summaryWritten = true
            manifest.codex = record
            try save(manifest, archive)
            try fm.createDirectory(atPath: paths.codexMemories, withIntermediateDirectories: true)
            try Data(codexSummary(paths: paths).utf8).write(to: URL(fileURLWithPath: paths.codexSummary), options: .atomic)
        }

        // f. memory/ 自己的 git
        report.notes += commit(paths.memory, message: "TATWO OS：併入引擎記憶（\(stamp)，\(device)）")
        return report
    }

    // MARK: 還原

    /// 把設定、Codex 的記憶、Claude 的舊資料夾放回接上前的樣子；入口 memory/ 留著。
    /// 檔案沒被改過就整份放回封存（逐位元一樣）；接上後又被改過，就只撤掉我們那一個鍵／那一行。
    @discardableResult
    static func restore(_ engines: Set<EngineMemoryEngine> = Set(EngineMemoryEngine.allCases),
                        paths: EngineMemoryPaths = EngineMemoryPaths(), now: Date = Date()) throws -> [String] {
        var notes: [String] = []
        var restoredAny = false
        for (url, original) in manifests(paths) {
            var manifest = original
            let archive = url.deletingLastPathComponent()
            var done: [String] = []
            // 寫之前就失敗的那次（沒動任何東西）不算，免得按了「還原」什麼都沒做卻說好了。
            if engines.contains(.claude), var record = manifest.claude, record.restorable {
                notes += try restoreClaude(record, archive: archive, paths: paths)
                record.restoredAt = now
                manifest.claude = record
                done.append("Claude Code")
            }
            if engines.contains(.codex), var record = manifest.codex, record.restorable {
                notes += try restoreCodex(record, archive: archive)
                record.restoredAt = now
                manifest.codex = record
                done.append("Codex CLI")
            }
            guard !done.isEmpty else { continue }
            restoredAny = true
            try save(manifest, archive)
            let note = archive.appendingPathComponent("還原.md")
            if let handle = try? FileHandle(forWritingTo: note) {
                handle.seekToEndOfFile()
                handle.write(Data("\n已還原：\(done.joined(separator: "、"))（\(dayStamp(now)) \(timeStamp(now))，設定 › OS › 記憶）\n".utf8))
                try? handle.close()
            }
        }
        guard restoredAny else { throw Failure(reason: "找不到可以還原的封存（手動接上的沒有封存紀錄）") }
        return notes
    }

    private static func restoreClaude(_ record: EngineMemoryManifest.Claude, archive: URL,
                                      paths: EngineMemoryPaths) throws -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        let settings = URL(fileURLWithPath: record.settingsPath)
        if let current = try? Data(contentsOf: settings) {
            let value = ((try? JSONSerialization.jsonObject(with: current)) as? [String: Any])?[settingsKey] as? String
            if let written = record.writtenSHA, sha256(current) == written {
                if record.settingsExisted {
                    try writePreserving(Data(contentsOf: archive.appendingPathComponent("claude-settings.json")), to: record.settingsPath)
                } else {
                    try fm.moveItem(at: settings.resolvingSymlinksInPath(),
                                    to: uniqueURL(archive.appendingPathComponent("claude-settings.created-by-link.json")))
                }
            } else if let value, pointsToMemory(value, paths: paths) {
                // 接上後又被改過（或寫到一半停下）：只撤掉我們那一個鍵，其他人的改動留著。
                let updated = try record.originalValue.map { try JSONMembers.setting(settingsKey, rawValue: $0, in: current) }
                    ?? JSONMembers.removing(settingsKey, in: current)
                try JSONMembers.verify(old: current, new: updated, key: settingsKey, expected: nil)
                try writePreserving(updated, to: record.settingsPath)
                notes.append("Claude 的 settings.json 接上後又被改過，只撤掉 \(settingsKey)")
            } else if record.writtenSHA != nil {
                notes.append("Claude 的 settings.json 裡 \(settingsKey) 已經不是指到記憶資料夾，沒有動")
            }
        }
        for moved in record.moved.reversed() {
            if (try? fm.destinationOfSymbolicLink(atPath: moved.original)) != nil { try fm.removeItem(atPath: moved.original) }
            if !fm.fileExists(atPath: moved.original), fm.fileExists(atPath: moved.moved) {
                try fm.moveItem(atPath: moved.moved, toPath: moved.original)
            } else if fm.fileExists(atPath: moved.moved) {
                notes.append("\(moved.original) 已經有新的資料夾，舊的留在 \(moved.moved)")
            }
        }
        return notes
    }

    private static func restoreCodex(_ record: EngineMemoryManifest.Codex, archive: URL) throws -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        let config = URL(fileURLWithPath: record.configPath)
        if let current = try? Data(contentsOf: config) {
            if let written = record.writtenSHA, sha256(current) == written {
                if record.configExisted {
                    try writePreserving(Data(contentsOf: archive.appendingPathComponent("codex-config.toml")), to: record.configPath)
                } else {
                    try fm.moveItem(at: config.resolvingSymlinksInPath(),
                                    to: uniqueURL(archive.appendingPathComponent("codex-config.created-by-link.toml")))
                }
            } else if record.edit != nil || record.featureEdit != nil {
                // 接上後又被改過（或寫到一半停下、沒記到 sha）：只把我們改的那幾行改回來。
                if let undone = TOMLMemories.undo(current, record: record) {
                    try writePreserving(undone, to: record.configPath)
                    notes.append("Codex 的 config.toml 接上後又被改過，只把 generate_memories／[features] memories 改回來")
                } else {
                    notes.append("Codex 的 config.toml 找不到當初改的那一行，沒有動")
                }
            }
        }
        if record.summaryWritten, summaryHasMarker(record.summaryPath) {
            let summary = URL(fileURLWithPath: record.summaryPath)
            let saved = archive.appendingPathComponent("codex-memories/memory_summary.md")
            if record.summaryExisted, fm.fileExists(atPath: saved.path) {
                try fm.removeItem(at: summary)
                try fm.copyItem(at: saved, to: summary)
            } else {
                try fm.moveItem(at: summary, to: uniqueURL(archive.appendingPathComponent("codex-summary.generated.md")))
                let folder = summary.deletingLastPathComponent()
                if !record.memoriesExisted, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? fm.removeItem(at: folder)
                }
            }
        }
        return notes
    }

    // MARK: Codex 摘要

    /// 入口 memory/ 變了就重產 Codex 讀的 memory_summary.md（只在已接上時：generate_memories=false 且檔頭有 OS 標記）。
    @discardableResult
    static func refreshCodexSummary(paths: EngineMemoryPaths = EngineMemoryPaths()) -> Bool {
        guard directoryExists(paths.memory.path), summaryHasMarker(paths.codexSummary),
              let config = try? Data(contentsOf: URL(fileURLWithPath: paths.codexConfig)),
              TOMLMemories.value(of: "generate_memories", in: String(decoding: config, as: UTF8.self)) == false else { return false }
        let data = Data(codexSummary(paths: paths).utf8)
        let url = URL(fileURLWithPath: paths.codexSummary)
        guard (try? Data(contentsOf: url)) != data else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 從入口 MEMORY.md 與最近更新的記憶組出 8 KB 內的摘要；檔頭標記「由 TATWO OS 產生，勿手改」。
    static func codexSummary(paths: EngineMemoryPaths) -> String {
        let memory = paths.memory
        var out = "<!-- \(marker)。這份從 TATWO 記憶資料夾自動產生，改記憶請改那裡。 -->\n"
        out += "# TATWO 通用記憶（摘要）\n\n"
        out += "記憶正本：`\(memory.path)`。一條一個 Markdown 檔；下面的連結都相對於那個資料夾，要細節就讀那個檔，完整索引是那裡的 MEMORY.md。\n"
        out += "要記新的長期事實：在那個資料夾新增一個檔（開頭欄位照其他檔：name、description、metadata.type），再在 MEMORY.md 加一行。使用者偏好用 user_remember 提案。金鑰、密碼、權杖不寫進記憶。\n"
        let limit = maxSummaryBytes - 80
        func append(_ line: String) -> Bool {
            guard out.utf8.count + line.utf8.count + 1 <= limit else { return false }
            out += line + "\n"
            return true
        }
        var shown = Set<String>()
        let recent = memoryItems(in: memory)
            .map { ($0, modificationDate(memory.appendingPathComponent($0))) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(8)
        if !recent.isEmpty, append("\n## 最近更新") {
            for (name, _) in recent where append(entryLine(for: memory.appendingPathComponent(name), name: name)) {
                shown.insert(name)
            }
        }
        let index = (try? String(contentsOf: memory.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        let entries = index.components(separatedBy: "\n").map(stripCR).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return false }
            let targets = linkTargets(in: line)
            return targets.isEmpty || !targets.allSatisfy(shown.contains)
        }
        if !entries.isEmpty, append("\n## 索引（節錄自 MEMORY.md）") {
            for (index, line) in entries.enumerated() where !append(line) {
                out += "- （還有 \(entries.count - index) 條，見 MEMORY.md）\n"
                break
            }
        }
        return out
    }

    // MARK: 匯入與索引

    struct ClaudeSource {
        let folder: String
        let dir: URL
        let label: String
    }

    struct IndexSection {
        let label: String
        let title: String
        let lines: [String]
    }

    /// 所有 `~/.claude/projects/*/memory/`：跳過空的、跳過已經是連結的（主導手動接過或先前接過）。家目錄那個排第一。
    static func claudeSources(_ paths: EngineMemoryPaths) -> [ClaudeSource] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: paths.claudeProjects) else { return [] }
        let encodedHome = String(paths.home.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        var result: [ClaudeSource] = []
        var labels = Set<String>()
        for folder in folders.sorted() where !folder.hasPrefix(".") {
            let dir = URL(fileURLWithPath: paths.claudeProjects).appendingPathComponent(folder)
                .appendingPathComponent("memory", isDirectory: true)
            if (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil { continue }
            if ExternalWorkspacePolicy.contains(dir) { continue }   // W183 R6c 審查：解開捷徑後在入口 chatgpt/（外部 AI 的工作區）＝不併入
            guard directoryExists(dir.path) else { continue }
            let entries = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            guard !entries.isEmpty else { continue }
            let raw = folder == encodedHome ? "home"
                : folder.hasPrefix(encodedHome + "-") ? String(folder.dropFirst(encodedHome.count + 1)) : folder
            var label = safeName(raw)
            if label.isEmpty { label = "project" }
            var unique = label
            var n = 2
            while labels.contains(unique) { unique = label + "-\(n)"; n += 1 }
            labels.insert(unique)
            result.append(ClaudeSource(folder: folder, dir: dir, label: unique))
        }
        return result.sorted { ($0.label == "home" ? 0 : 1, $0.folder) < ($1.label == "home" ? 0 : 1, $1.folder) }
    }

    /// 檔案複製進入口 memory/：一樣的檔不重複放；檔名撞到內容不同就加來源後綴（名稱--來源.md）。
    static func importClaude(_ sources: [ClaudeSource], into memory: URL, date: String) throws -> (count: Int, sections: [IndexSection]) {
        let fm = FileManager.default
        var count = 0
        var sections: [IndexSection] = []
        for source in sources {
            var renamed: [String: String] = [:]
            var placed: [String] = []
            let names = try fm.contentsOfDirectory(atPath: source.dir.path)
                .filter { !$0.hasPrefix(".") && $0 != "MEMORY.md" }.sorted()
            for name in names {
                let from = source.dir.appendingPathComponent(name)
                if ExternalWorkspacePolicy.contains(from) { continue }   // W183 R6c 審查：連到入口 chatgpt/ 的檔不複製、不列進索引
                let target = placement(for: name, from: from, in: memory, label: source.label)
                if target.copy {
                    try fm.copyItem(at: from, to: memory.appendingPathComponent(target.name))
                    count += 1
                }
                renamed[name] = target.name
                placed.append(target.name)
            }
            var lines: [String] = []
            var listed = Set<String>()
            let indexFile = source.dir.appendingPathComponent("MEMORY.md")
            if !ExternalWorkspacePolicy.contains(indexFile), let text = try? String(contentsOf: indexFile, encoding: .utf8) {   // W183 R6c 審查
                for line in text.components(separatedBy: "\n").map(stripCR) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
                    var rewritten = line
                    for (old, new) in renamed where old != new {
                        rewritten = rewritten.replacingOccurrences(of: "](\(old))", with: "](\(new))")
                    }
                    listed.formUnion(linkTargets(in: rewritten))
                    lines.append(rewritten)
                }
            }
            // 索引沒列到的檔也補一行，不然 Claude 找不到它。
            for name in placed where name.hasSuffix(".md") && !listed.contains(name) && !isIndexFile(name) {
                lines.append(entryLine(for: memory.appendingPathComponent(name), name: name))
            }
            sections.append(IndexSection(label: source.label, title: "\(source.label)（\(date) 併入）", lines: lines))
        }
        return (count, sections)
    }

    static func placement(for name: String, from source: URL, in memory: URL, label: String) -> (name: String, copy: Bool) {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var candidate = name
        var n = 1
        while true {
            let path = memory.appendingPathComponent(candidate).path
            if !fm.fileExists(atPath: path), (try? fm.destinationOfSymbolicLink(atPath: path)) == nil { return (candidate, true) }
            if fm.contentsEqual(atPath: path, andPath: source.path) { return (candidate, false) }
            candidate = stem + "--" + label + (n > 1 ? "-\(n)" : "") + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
    }

    static let codexImportNames = ["memory_summary.md", "MEMORY.md", "raw_memories.md", "rollout_summaries"]

    /// Codex 自己整理的 memory_summary.md、MEMORY.md、raw_memories.md、rollout_summaries/ 放到 imports/codex-<設備>/。
    /// 匯入過沒有看內容、不看資料夾名稱（主導手動匯入的叫 codex-lead-import，設備名卻是 "Laptop One"）：
    /// 任何一個 imports/codex-*（或它底下的日期資料夾）裡這幾個檔都跟這台 ~/.codex/memories 的逐位元一樣，就只指過去；
    /// imports/codex-<設備>/ 已經有了但內容不同（還原後 Codex 又自己記了新的），放進日期子資料夾，不略過。
    static func importCodex(paths: EngineMemoryPaths, device: String, now: Date) throws -> String? {
        let fm = FileManager.default
        // W183 R6c 審查：Codex 記憶資料夾或其中的檔解開捷徑後在入口 chatgpt/（外部 AI 的工作區）＝不併入。
        guard directoryExists(paths.codexMemories), !ExternalWorkspacePolicy.contains(paths.codexMemories) else { return nil }
        let names = codexImportNames.filter { name in
            let path = paths.codexMemories + "/" + name
            return fm.fileExists(atPath: path) && !(name == "memory_summary.md" && summaryHasMarker(path))
                && !ExternalWorkspacePolicy.contains(path)
        }
        guard !names.isEmpty else { return nil }
        let files = names.filter { $0 != "rollout_summaries" }
        let compared = files.isEmpty ? names : files
        func pointer(_ folder: String, _ file: String) -> String {
            "- Codex 在 \(device) 自己整理的記憶（唯讀參考）：[\(folder)/](\(folder)/\(file))"
        }
        for folder in previousCodexImports(paths.memory) where compared.allSatisfy({ name in
            fm.contentsEqual(atPath: paths.codexMemories + "/" + name, andPath: folder.url.appendingPathComponent(name).path)
        }) {
            guard !indexMentions(folder.relative, memory: paths.memory) else { return nil }
            let existing = (try? fm.contentsOfDirectory(atPath: folder.url.path)) ?? []
            return ["README.md", "MEMORY.md", "memory_summary.md"].first(where: { existing.contains($0) }).map { pointer(folder.relative, $0) }
        }
        var folder = "imports/codex-\(device)"
        let own = paths.memory.appendingPathComponent(folder, isDirectory: true)
        if ((try? fm.contentsOfDirectory(atPath: own.path)) ?? []).contains(where: { !$0.hasPrefix(".") }) {
            folder += "/" + URL(fileURLWithPath: uniquePath(own.appendingPathComponent(dayStamp(now)).path)).lastPathComponent
        }
        let destination = paths.memory.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names {
            try fm.copyItem(atPath: paths.codexMemories + "/" + name, toPath: destination.appendingPathComponent(name).path)
        }
        let readme = "# Codex 自己整理的記憶（\(device)，\(dayStamp(now)) 匯入）\n\n"
            + "唯讀參考：接上 TATWO 記憶前，Codex 在這台自己整理的內容，原樣複製過來。原件整份封存在入口 archive/\(archivePrefix)*/codex-memories/。\n"
            + "raw_memories.md 與 rollout_summaries/ 可能夾帶對話原文，只留在這台，不進記憶的 git、不同步到其他設備。\n"
        try Data(readme.utf8).write(to: destination.appendingPathComponent("README.md"))
        return pointer(folder, "README.md")
    }

    /// imports/ 底下已經有的 Codex 匯入：imports/codex-* 本身，和它底下以日期開頭的子資料夾。
    static func previousCodexImports(_ memory: URL) -> [(url: URL, relative: String)] {
        let imports = memory.appendingPathComponent("imports", isDirectory: true)
        var found: [(url: URL, relative: String)] = []
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).sorted()
            where name.hasPrefix("codex-") && directoryExists(imports.appendingPathComponent(name).path) {
            let url = imports.appendingPathComponent(name, isDirectory: true)
            found.append((url, "imports/" + name))
            for sub in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                where sub.first?.isNumber == true && directoryExists(url.appendingPathComponent(sub).path) {
                found.append((url.appendingPathComponent(sub, isDirectory: true), "imports/\(name)/\(sub)"))
            }
        }
        return found
    }

    /// 主索引或分索引已經有連到這個資料夾（資料夾本身或它裡面的檔）的行。
    static func indexMentions(_ folder: String, memory: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? [])
            .filter { $0 == "MEMORY.md" || ($0.hasPrefix("MEMORY-") && $0.hasSuffix(".md")) }
        let prefix = folder + "/"
        return names.contains { name in
            let text = (try? String(contentsOf: memory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").flatMap(linkTargets).contains { target in
                target == folder || target == prefix || (target.hasPrefix(prefix) && !target.dropFirst(prefix.count).contains("/"))
            }
        }
    }

    /// 併進主索引：主索引守住 200 行、25 KB；放不下的寫進 MEMORY-<來源>.md，主索引留一行指過去。
    static func mergeIndex(memory: URL, sections: [IndexSection], pointers: [String]) throws {
        let fm = FileManager.default
        let mainURL = memory.appendingPathComponent("MEMORY.md")
        let existing = try? String(contentsOf: mainURL, encoding: .utf8)
        var lines = existing.map { $0.components(separatedBy: "\n").map(stripCR) } ?? indexHeader
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.isEmpty { lines = indexHeader }
        var referenced = Set(lines.flatMap(linkTargets))
        for name in (try? fm.contentsOfDirectory(atPath: memory.path)) ?? [] where name.hasPrefix("MEMORY-") && name.hasSuffix(".md") {
            let text = (try? String(contentsOf: memory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            referenced.formUnion(text.components(separatedBy: "\n").flatMap(linkTargets))
        }
        func isNew(_ line: String) -> Bool {
            let targets = linkTargets(in: line)
            return targets.isEmpty || !targets.allSatisfy(referenced.contains)
        }
        var fresh: [(section: IndexSection, lines: [String])] = []
        for section in sections {
            var kept: [String] = []
            for line in section.lines where isNew(line) {
                referenced.formUnion(linkTargets(in: line))
                kept.append(line)
            }
            if !kept.isEmpty { fresh.append((section, kept)) }
        }
        let extra = pointers.filter(isNew)
        guard !fresh.isEmpty || !extra.isEmpty || existing == nil || !fits(lines, reserve: 0) else { return }

        var overflow: [String: [String]] = [:]
        var order: [String] = []
        func spill(_ file: String, _ entries: [String]) {
            if overflow[file] == nil { order.append(file) }
            overflow[file, default: []] += entries
        }
        func pointer(_ title: String, _ file: String, _ count: Int) -> String {
            "- 「\(title)」還有 \(count) 條：[\(file)](\(file))"
        }
        // 主索引本來就超過：尾巴移到 MEMORY-tatwo.md。
        let reserveAll = fresh.count + extra.count
        if !fits(lines, reserve: reserveAll) {
            var moved: [String] = []
            while lines.count > 1, !fits(lines, reserve: reserveAll + 1) { moved.insert(lines.removeLast(), at: 0) }
            spill("MEMORY-tatwo.md", moved)
            lines.append(pointer("較早的索引", "MEMORY-tatwo.md", moved.count))
        }
        for (index, item) in fresh.enumerated() {
            let later = fresh.count - index - 1 + extra.count
            let file = "MEMORY-\(item.section.label).md"
            let header = ["", "## \(item.section.title)"]
            var kept: [String] = []
            for line in item.lines {
                guard fits(lines + header + kept + [line], reserve: later + 1) else { break }
                kept.append(line)
            }
            if !kept.isEmpty { lines += header + kept }
            let rest = Array(item.lines.dropFirst(kept.count))
            if !rest.isEmpty {
                spill(file, rest)
                lines.append(pointer(item.section.title, file, rest.count))
            }
        }
        lines += extra
        for file in order {
            let url = memory.appendingPathComponent(file)
            var text = (try? String(contentsOf: url, encoding: .utf8))
                ?? "# 記憶索引（續）\n\n主索引 MEMORY.md 放不下的部分。Claude 開場只讀主索引前 \(maxIndexLines) 行或 25 KB，這份需要時才讀。\n"
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + (overflow[file] ?? []).joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        let output = lines.joined(separator: "\n") + "\n"
        if existing != output { try Data(output.utf8).write(to: mainURL, options: .atomic) }
    }

    /// 還要留 `reserve` 行（每行最多 512 bytes）給之後的指向行。
    static func fits(_ lines: [String], reserve: Int) -> Bool {
        lines.count + reserve <= maxIndexLines
            && lines.joined(separator: "\n").utf8.count + 1 + reserve * 512 <= maxIndexBytes
    }

    static func linkTargets(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\]\\(([^)\\s]+)\\)") else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).map { range -> String in
                let target = String(line[range])
                return target.hasPrefix("./") ? String(target.dropFirst(2)) : target
            }
        }
    }

    static func entryLine(for url: URL, name: String) -> String {
        let fields = frontmatter((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        let title = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (name as NSString).deletingPathExtension
        let description = fields["description"].flatMap { $0.isEmpty ? nil : " — " + String($0.prefix(150)) } ?? ""
        return "- [\(title)](\(name))\(description)"
    }

    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n").map(stripCR)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    // MARK: 副設備：從主設備複製一份

    /// 用配對時 pin 住的主機金鑰（跟 RemoteHostLink 同一套，不做 TOFU）`git clone` 主設備入口的 memory/。
    /// 會等 SSH，主執行緒不走；任何一步不成就回 false，由呼叫端在本機建一份。
    static func clonePrimaryMemory(into memory: URL, paths: EngineMemoryPaths,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard !Thread.isMainThread else { return false }
        let fm = FileManager.default
        return withPinnedPrimaryGit(paths: paths, environment: environment) { pinned -> Bool? in
            let staging = memory.deletingLastPathComponent().appendingPathComponent(".memory-clone-" + UUID().uuidString)
            let status = run("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "clone", "-q", "--",
                                              "\(pinned.destination):\(remoteMemoryPath)", staging.path],
                             environment: pinned.environment, timeout: 90).status
            if status == 0, (try? fm.moveItem(at: staging, to: memory)) != nil { return true }
            try? fm.removeItem(at: staging)
            return nil
        } ?? false
    }

    /// W180 E1b：副設備連主設備 git 的環境（配對時 pin 住的主機金鑰、StrictHostKeyChecking=yes、不做 TOFU），
    /// clonePrimaryMemory 與記憶自動同步（TatwoMemorySync 的 fetch）共用這一套。每個連線位置各試一次，body 回非 nil 就停。
    struct PinnedPrimaryGit {
        let destination: String
        let environment: [String: String]
    }

    static func withPinnedPrimaryGit<T>(paths: EngineMemoryPaths,
                                        environment: [String: String] = ProcessInfo.processInfo.environment,
                                        _ body: (PinnedPrimaryGit) -> T?) -> T? {
        guard !Thread.isMainThread else { return nil }
        guard let identity = try? DeviceIdentityStore.readLocal(entry: entry(paths)), identity.role == .secondary,
              let primaryID = identity.primaryDeviceID?.lowercased(),
              // W180 E1b 實機：主設備由本機身分（primaryDeviceID）決定，跟 DeviceDispatch.primary() 一樣；
              // 舊配對留下的設備紀錄沒有 role 欄，不能因此拉不到記憶。紀錄明寫是別的角色才拒絕。
              let record = DeviceStatusReader.registry(environment: environment)
                .first(where: { $0.id.lowercased() == primaryID && ($0.role == nil || $0.role == .primary) }),
              let pinned = record.pinnedHostKeyFingerprint, pinned.hasPrefix("SHA256:"),
              !record.user.isEmpty, !record.user.hasPrefix("-"),
              record.user.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let knownPath = environment["TATWO2_SSH_KNOWN_HOSTS"] ?? environment["TATWO2_KNOWN_HOSTS"] ?? paths.home + "/.ssh/known_hosts"
        var match: (key: String, algorithm: String)?
        for line in (try? String(contentsOfFile: knownPath, encoding: .utf8))?.split(separator: "\n") ?? []
            where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }
            let key = "\(parts[1]) \(parts[2])"
            if (try? DeviceRegistry.fingerprint(publicKey: key)) == pinned { match = (key, String(parts[1])); break }
        }
        guard let match else { return nil }
        let fm = FileManager.default
        let pin = fm.temporaryDirectory.appendingPathComponent("w179-memory-host-" + UUID().uuidString)
        guard (try? Data(("tatwo-paired-host " + match.key + "\n").utf8).write(to: pin, options: .atomic)) != nil else { return nil }
        _ = chmod(pin.path, 0o600)
        defer { try? fm.removeItem(at: pin) }
        let algorithm = match.algorithm == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : match.algorithm
        let knownHosts = pin.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        for endpoint in record.orderedEndpoints {
            let destination = endpoint.kind == .alias ? (endpoint.alias ?? "") : "\(record.user)@\(endpoint.host)"
            guard !destination.isEmpty, !destination.hasPrefix("-") else { continue }
            var ssh = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                       "-o", "UserKnownHostsFile=\"\(knownHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null",
                       "-o", "HostKeyAlgorithms=\(algorithm)", "-o", "UpdateHostKeys=no",
                       "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
                       "-o", "HostKeyAlias=tatwo-paired-host", "-o", "CheckHostIP=no",
                       "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8"]
            if endpoint.kind != .alias { ssh += ["-p", String(endpoint.port)] }
            if let key = environment["TATWO2_SSH_KEY_PATH"] { ssh += ["-i", key, "-o", "IdentitiesOnly=yes"] }
            var env = environment.filter { !$0.key.hasPrefix("GIT_") }
            var search = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
            for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !search.contains(extra) { search.append(extra) }
            env["PATH"] = search.joined(separator: ":")
            env["GIT_SSH_COMMAND"] = ssh.map(quote).joined(separator: " ")
            env["SSH_ASKPASS_REQUIRE"] = "never"
            env["SSH_ASKPASS"] = "/usr/bin/false"
            if let result = body(PinnedPrimaryGit(destination: destination, environment: env)) { return result }
        }
        return nil
    }

    // MARK: 小工具

    static func entry(_ paths: EngineMemoryPaths) -> TatwoEntry {
        TatwoEntry(environment: ["TATWO_OS_ROOT": paths.entryRoot.path], preference: nil)
    }

    static func createMemoryFolder(_ memory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)
        let readme = memory.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            # TATWO 通用記憶

            - 這台 TATWO OS 的通用記憶。資料夾自己是一個 git 倉庫，入口的 git 不追蹤它；主設備持正本，副設備是它的副本。
            - 誰寫：接上的 Claude Code（設定 `autoMemoryDirectory` 指到這裡）直接寫；Codex 讀 OS 從這裡產生的摘要（`~/.codex/memories/memory_summary.md`）。
            - 格式：一條記憶一個 Markdown 檔，開頭欄位 `name`、`description`、`metadata.type`；`MEMORY.md` 是索引，Claude 開場只讀前 200 行或 25 KB，放不下的在 `MEMORY-<來源>.md`。
            - 不收：金鑰、密碼、權杖、帳號資料、別人的私事。
            - 原件：接上時原本的記憶與設定封存在入口 `archive/engine-memory-<日期>/`，還原方法在那裡的 `還原.md`，或在 設定 › OS › 記憶 按「還原」。

            """
            try Data(text.utf8).write(to: readme)
        }
        let ignore = memory.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) { try Data(".DS_Store\n".utf8).write(to: ignore) }
        try ensureIgnoreRules(memory)
        let index = memory.appendingPathComponent("MEMORY.md")
        if !fm.fileExists(atPath: index.path) { try Data((indexHeader.joined(separator: "\n") + "\n").utf8).write(to: index) }
        if !fm.fileExists(atPath: memory.path + "/.git") { git(["-c", "init.defaultBranch=main", "init", "-q"], in: memory) }
    }

    /// memory/ 有變動才 commit；作者固定寫 TATWO OS（不帶使用者的信箱）。回傳要告訴使用者的話（空＝成功或沒有變動）。
    /// 這個倉庫會被複製到其他設備：Codex 的原始紀錄靠 .gitignore 只留在這台；新增或改過的檔先過一遍金鑰／權杖檢查，
    /// 看起來有的不進 commit（新檔記進 .git/info/exclude，只留在這台），並告訴使用者是哪幾個檔。
    static func commit(_ memory: URL, message: String) -> [String] {
        TatwoMemoryLock.shared.lock(); defer { TatwoMemoryLock.shared.unlock() } // W180 E1b：跟記憶自動同步共用一把鎖
        guard FileManager.default.fileExists(atPath: memory.path + "/.git") else { return ["記憶資料夾不是 git 倉庫，這次沒有 commit"] }
        var notes: [String] = []
        do { try ensureIgnoreRules(memory) } catch {
            return ["記憶資料夾的 .gitignore 寫不進去，Codex 的原始紀錄可能會進 git，這次沒有 commit"]
        }
        // 上次擋下來的檔每次都重新檢查一遍（金鑰拿掉了就收進來）。
        writeHeldBack([], memory: memory)
        guard git(["add", "-A"], in: memory).status == 0 else { return ["記憶資料夾 git add 失敗"] }
        let added = staged(memory, filter: "A").filter { hasSecret(memory.appendingPathComponent($0)) }
        let changed = staged(memory, filter: "MT").filter { hasSecret(memory.appendingPathComponent($0)) }
        if !added.isEmpty { git(["--literal-pathspecs", "rm", "--cached", "-q", "--"] + added, in: memory) }
        if !changed.isEmpty { git(["--literal-pathspecs", "reset", "-q", "--"] + changed, in: memory) }
        writeHeldBack(added, memory: memory)
        let held = added + changed
        if !held.isEmpty {
            guard Set(staged(memory, filter: nil)).isDisjoint(with: held) else {
                return ["有檔看起來含金鑰或權杖，卻擋不下來，這次沒有 commit：" + held.joined(separator: "、")]
            }
            notes.append("這些檔看起來含金鑰或權杖，只留在這台、沒有進記憶的 git：" + held.joined(separator: "、") + "（金鑰拿掉後下次會自動收進來）")
        }
        let tracked = git(["ls-files", "-z", "--", ":(glob)imports/**/raw_memories.md", ":(glob)imports/**/rollout_summaries/**"],
                          in: memory).output.split(separator: "\0")
        if !tracked.isEmpty {
            notes.append("imports 裡有 \(tracked.count) 個 Codex 原始紀錄之前已經進了 git（會跟著同步到其他設備）；要不要從 git 拿掉請主設備決定，檔案本身不會刪")
        }
        guard !staged(memory, filter: nil).isEmpty else { return notes }
        if git(["commit", "-q", "-m", message], in: memory).status != 0 { notes.append("記憶資料夾 git commit 失敗") }
        return notes
    }

    /// 這次要 commit 的檔（相對於 memory/）；filter 是 git 的 --diff-filter（A 新增、M 修改、T 換類型）。
    static func staged(_ memory: URL, filter: String?) -> [String] {
        var arguments = ["diff", "--cached", "--name-only", "-z", "--no-renames"]
        if let filter { arguments.append("--diff-filter=" + filter) }
        return git(arguments, in: memory).output.split(separator: "\0").map(String.init)
    }

    /// 跟 BotLibrary.validateContent 同一組（再加幾種常見的權杖格式）：認得出來的金鑰／權杖就擋，不保證認得全部。
    static let secretPatterns = [
        #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#,
        #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}"#,
        #"\b(?:ghp_|gho_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]{20,}"#,
        #"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|secret[_-]?key|password)\s*[=:]\s*[\"']?[A-Za-z0-9_./+-]{12,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAIza[0-9A-Za-z_-]{35}"#,
    ]

    /// 只看一般檔、最多 8 MB；內容不寫進任何紀錄，只回有沒有。
    static func hasSecret(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 8 << 20, let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return secretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Codex 的原始紀錄可能夾帶對話原文：只留在這台。已經有 .gitignore（主導手動建的）也照樣補上缺的規則。
    static let localOnlyRules = ["imports/**/raw_memories.md", "imports/**/rollout_summaries/"]

    static func ensureIgnoreRules(_ memory: URL) throws {
        let url = memory.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let present = Set(text.components(separatedBy: "\n").map { stripCR($0).trimmingCharacters(in: .whitespaces) })
        let missing = localOnlyRules.filter { !present.contains($0) }
        guard !missing.isEmpty else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# TATWO OS：Codex 的原始紀錄可能夾帶對話原文，只留在這台，不進 git、不同步到其他設備\n"
            + missing.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static let heldBackBegin = "# >>> TATWO OS：看起來含金鑰或權杖，只留在這台（每次 commit 重新檢查）"
    static let heldBackEnd = "# <<< TATWO OS"

    /// 把擋下來的新檔寫進 .git/info/exclude 的一段（只在這台，不進 git）；傳空的就是清掉那一段。
    static func writeHeldBack(_ files: [String], memory: URL) {
        let url = memory.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: "\n")
        if let start = lines.firstIndex(of: heldBackBegin), let end = lines[start...].firstIndex(of: heldBackEnd) {
            lines.removeSubrange(start...end)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let patterns = files.filter { !$0.contains("\n") }.map(ignorePattern)
        if !patterns.isEmpty { lines += [heldBackBegin] + patterns + [heldBackEnd] }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard text != existing else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 一個檔的 gitignore 寫法：從 memory/ 開頭算、萬用字元跳脫、行尾空白保留。
    static func ignorePattern(_ path: String) -> String {
        var out = "/"
        for character in path {
            if "\\*?[".contains(character) { out.append("\\") }
            out.append(character)
        }
        var trailing = 0
        while out.hasSuffix(" ") { out.removeLast(); trailing += 1 }
        return out + String(repeating: "\\ ", count: trailing)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) -> (status: Int32, output: String) {
        run("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                             "-c", "user.name=TATWO OS", "-c", "user.email=tatwo-os@localhost"] + arguments,
            in: directory)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 60) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = environment ?? ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        deadline.resume()
        defer { deadline.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    static func makeArchive(_ paths: EngineMemoryPaths, now: Date) throws -> URL {
        let fm = FileManager.default
        let base = archivePrefix + dayStamp(now)
        var url = paths.archiveRoot.appendingPathComponent(base, isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: url.path) {
            url = paths.archiveRoot.appendingPathComponent(base + "-" + timeStamp(now) + (n > 1 ? "-\(n)" : ""), isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func save(_ manifest: EngineMemoryManifest, _ archive: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func writeRestoreNote(_ manifest: EngineMemoryManifest, archive: URL, sources: [ClaudeSource],
                                         paths: EngineMemoryPaths, date: String) throws {
        var did: [String] = []
        var here: [String] = []
        var steps: [String] = []
        if manifest.claude != nil {
            did.append("- Claude Code：\(sources.count) 個專案的自動記憶（`~/.claude/projects/<資料夾>/memory/`）複製進入口 `memory/`；使用者設定 `\(paths.tilde(paths.claudeSettings))` 加 `\(settingsKey)` 指到入口 `memory/`（其他設定沒動）；舊的記憶資料夾改名成 `memory.moved-w179-\(date)`，原位換成指向入口 `memory/` 的連結。")
            here.append("`claude-projects/`（各專案原本的記憶資料夾）、`claude-settings.json`")
            steps.append("Claude：把這裡的 `claude-settings.json` 複製回 `\(paths.tilde(paths.claudeSettings))`（或只拿掉 `\(settingsKey)` 那一行）；刪掉連結 `~/.claude/projects/<資料夾>/memory`，把旁邊的 `memory.moved-w179-\(date)` 改名回 `memory`。")
        }
        if manifest.codex != nil {
            did.append("- Codex：它自己整理的記憶複製到入口 `memory/imports/codex-…/`（唯讀參考；已經匯入過一樣的內容就不再複製；`raw_memories.md`、`rollout_summaries/` 只留在這台、不進記憶的 git）；`\(paths.tilde(paths.codexConfig))` 只動兩行：`[features] memories = true`（Codex 記憶功能的總開關）與 `[memories] generate_memories = false`（`use_memories` 沒動）；`\(paths.tilde(paths.codexSummary))` 換成 OS 從入口記憶產生的版本。")
            here.append("`codex-memories/`（Codex 原本整個 memories 資料夾）、`codex-config.toml`")
            steps.append("Codex：把這裡的 `codex-config.toml` 複製回 `\(paths.tilde(paths.codexConfig))`（或把 `generate_memories` 與 `[features] memories` 改回原本的值）；把 `codex-memories/memory_summary.md` 複製回 `\(paths.tilde(paths.codexMemories))/`。")
        }
        steps.append("入口的 `memory/` 可以留著（不影響任何引擎），或移到垃圾桶。")
        let text = """
        # 還原：引擎記憶併入 TATWO 通用記憶（\(date)）

        做了什麼（\(manifest.device)）：
        \(did.joined(separator: "\n"))

        這裡的原件：\(here.joined(separator: "、"))；`manifest.json` 是給 OS 還原用的紀錄。

        還原（在這台）：最簡單是到 設定 › OS › 記憶，按該引擎的「還原」。要手動的話：
        \(steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        """
        try Data(text.utf8).write(to: archive.appendingPathComponent("還原.md"), options: .atomic)
    }

    /// 寫回引擎設定：寫到連結指向的真檔（不把連結換成一般檔），保留原本的權限。
    static func writePreserving(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }

    static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        var candidate = path
        var n = 2
        while fm.fileExists(atPath: candidate) || (try? fm.destinationOfSymbolicLink(atPath: candidate)) != nil {
            candidate = path + "-\(n)"
            n += 1
        }
        return candidate
    }

    private static func uniqueURL(_ url: URL) -> URL { URL(fileURLWithPath: uniquePath(url.path)) }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func modificationDate(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        let collapsed = mapped.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(collapsed.prefix(40))
    }

    static func stripCR(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }

    static func dayStamp(_ date: Date) -> String { stamp(date, "yyyyMMdd") }
    static func timeStamp(_ date: Date) -> String { stamp(date, "HHmmss") }
    private static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// MARK: - settings.json：只動一個頂層鍵，其他位元組原樣

/// 不把整份 settings.json 解開再寫回（會改掉排版、鍵的順序與跳脫），只在原文裡找到那個頂層鍵的位置動它。
enum JSONMembers {
    struct Member {
        let key: String
        let keyRange: Range<Int>
        let valueRange: Range<Int>
    }
    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
    }

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ","), openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    static func parse(_ bytes: [UInt8]) -> Object? {
        var i = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        func skipSpace() { while i < bytes.count, whitespace.contains(bytes[i]) { i += 1 } }
        skipSpace()
        guard i < bytes.count, bytes[i] == openBrace else { return nil }
        let open = i
        i += 1
        skipSpace()
        var members: [Member] = []
        if i < bytes.count, bytes[i] == closeBrace {
            let close = i
            i += 1
            skipSpace()
            return i == bytes.count ? Object(open: open, close: close, members: []) : nil
        }
        while i < bytes.count {
            skipSpace()
            guard i < bytes.count, bytes[i] == quote, let keyEnd = skipString(bytes, i),
                  let key = (try? JSONSerialization.jsonObject(with: Data(bytes[i..<keyEnd]), options: .fragmentsAllowed)) as? String
            else { return nil }
            let keyRange = i..<keyEnd
            i = keyEnd
            skipSpace()
            guard i < bytes.count, bytes[i] == colon else { return nil }
            i += 1
            skipSpace()
            guard let valueEnd = skipValue(bytes, i) else { return nil }
            members.append(Member(key: key, keyRange: keyRange, valueRange: i..<valueEnd))
            i = valueEnd
            skipSpace()
            guard i < bytes.count else { return nil }
            if bytes[i] == comma { i += 1; continue }
            guard bytes[i] == closeBrace else { return nil }
            let close = i
            i += 1
            skipSpace()
            return i == bytes.count ? Object(open: open, close: close, members: members) : nil
        }
        return nil
    }

    private static func skipString(_ bytes: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == backslash { i += 2; continue }
            if bytes[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func skipValue(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case quote:
            return skipString(bytes, start)
        case openBrace, openBracket:
            var depth = 0
            var i = start
            while i < bytes.count {
                let c = bytes[i]
                if c == quote {
                    guard let end = skipString(bytes, i) else { return nil }
                    i = end
                    continue
                }
                if c == openBrace || c == openBracket { depth += 1 }
                if c == closeBrace || c == closeBracket {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < bytes.count, !whitespace.contains(bytes[i]),
                  ![comma, closeBrace, closeBracket].contains(bytes[i]) { i += 1 }
            return i > start ? i : nil
        }
    }

    /// 設定一個頂層鍵：有就只換它的值，沒有就照原本的縮排加在最後一個鍵後面，檔案不在就新建。
    static func setting(_ key: String, rawValue: String, in data: Data?) throws -> Data {
        let member = quoted(key)
        guard let data, !data.allSatisfy({ whitespace.contains($0) }) else {
            return Data("{\n  \(member): \(rawValue)\n}\n".utf8)
        }
        var bytes = [UInt8](data)
        guard let object = parse(bytes) else { throw EngineMemoryLinks.Failure(reason: "settings.json 的格式看不懂，先不改") }
        if let existing = object.members.first(where: { $0.key == key }) {
            bytes.replaceSubrange(existing.valueRange, with: Array(rawValue.utf8))
        } else if let first = object.members.first, let last = object.members.last {
            let lead = Array(bytes[(object.open + 1)..<first.keyRange.lowerBound])
            let separator = Array(bytes[first.keyRange.upperBound..<first.valueRange.lowerBound])
            var insertion: [UInt8] = [comma]
            if let newline = lead.lastIndex(of: 0x0A) {
                insertion += newline > 0 && lead[newline - 1] == 0x0D ? [0x0D, 0x0A] : [0x0A]
                insertion += lead[(newline + 1)...]
            } else {
                insertion += [0x20]
            }
            insertion += Array(member.utf8) + separator + Array(rawValue.utf8)
            bytes.insert(contentsOf: insertion, at: last.valueRange.upperBound)
        } else {
            bytes.replaceSubrange((object.open + 1)..<object.close, with: Array("\n  \(member): \(rawValue)\n".utf8))
        }
        return Data(bytes)
    }

    /// 拿掉一個頂層鍵（連同它前面或後面的逗號），其他位元組不動。
    static func removing(_ key: String, in data: Data) throws -> Data {
        var bytes = [UInt8](data)
        guard let object = parse(bytes) else { throw EngineMemoryLinks.Failure(reason: "settings.json 的格式看不懂，先不改") }
        guard let index = object.members.firstIndex(where: { $0.key == key }) else { return data }
        let members = object.members
        let range: Range<Int>
        if members.count == 1 { range = (object.open + 1)..<object.close }
        else if index == members.count - 1 { range = members[index - 1].valueRange.upperBound..<members[index].valueRange.upperBound }
        else { range = members[index].keyRange.lowerBound..<members[index + 1].keyRange.lowerBound }
        bytes.removeSubrange(range)
        return Data(bytes)
    }

    /// 寫入前的關卡：其他鍵必須一個都沒變，新值必須讀得回來；不合就不寫。
    static func verify(old: Data?, new: Data, key: String, expected: String?) throws {
        guard let after = (try? JSONSerialization.jsonObject(with: new)) as? [String: Any] else {
            throw EngineMemoryLinks.Failure(reason: "改完的 settings.json 讀不回來，沒有寫入")
        }
        let before = old.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let a = NSMutableDictionary(dictionary: before), b = NSMutableDictionary(dictionary: after)
        a.removeObject(forKey: key)
        b.removeObject(forKey: key)
        guard a.isEqual(b) else { throw EngineMemoryLinks.Failure(reason: "會動到 settings.json 的其他設定，沒有寫入") }
        if let expected, after[key] as? String != expected {
            throw EngineMemoryLinks.Failure(reason: "settings.json 的 \(key) 讀回來不對，沒有寫入")
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

// MARK: - config.toml：只動 generate_memories 與 [features] memories 各一行

/// 不解析整份 TOML 再寫回；只找 `[表]` 裡（或最上層 `表.鍵`）的那一行，換掉值，行尾註解與其他內容一字不動。
/// 表已經用別的寫法定義過（最上層 `memories.x = …`）就跟著用同一種寫法，不再加 `[memories]` 表頭（重複定義 Codex 會讀不了設定）；
/// 看不懂的寫法（行內表 `memories = { … }`、值不是 true／false）就不改。改完再讀一次，讀不回來就不寫。
enum TOMLMemories {
    struct Edit {
        let data: Data
        let kind: String
        let originalLine: String?
        let writtenLine: String
    }

    struct Found {
        /// 那個鍵、值是 true／false 的那一行
        var line: Int?
        /// 那一行是最上層 `表.鍵 = …` 的寫法
        var dotted = false
        /// 第一個 `[表]` 表頭
        var section: Int?
        var headers = 0
        /// 最上層 `表.<任何鍵> = …` 的行
        var dottedLines: [Int] = []
        /// 最上層 `表 = …`（行內表或值）
        var inline = false
        /// 這個鍵出現幾次（不論值）
        var keyLines = 0
        var consistent: Bool { !inline && headers <= 1 && (headers == 0 || dottedLines.isEmpty) }
    }

    private static func header(_ line: String) -> String? {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("[") else { return nil }
        if let hash = body.firstIndex(of: "#") { body = body[..<hash].trimmingCharacters(in: .whitespaces) }
        guard body.hasSuffix("]") else { return nil }
        return body.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "")
    }

    private static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

    private static func pattern(_ table: String, _ key: String, dotted: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "^(\\s*" + (dotted ? escaped(table) + "\\s*\\.\\s*" : "") + escaped(key)
                                 + "\\s*=\\s*)(true|false)(?![A-Za-z0-9_])")
    }

    /// 哪些行是設定：多行字串（三個雙引號或三個單引號）裡面的行不是，例如很長的指示文字。
    static func codeMask(_ lines: [String]) -> [Bool] {
        var mask: [Bool] = []
        var open: String?
        for line in lines {
            if let delimiter = open {
                mask.append(false)
                if line.contains(delimiter) { open = nil }
                continue
            }
            mask.append(true)
            let hash = line.firstIndex(of: "#")
            let first = ["\"\"\"", "'''"].compactMap { delimiter in line.range(of: delimiter).map { (delimiter, $0) } }
                .min { $0.1.lowerBound < $1.1.lowerBound }
            if let first, hash.map({ first.1.lowerBound < $0 }) ?? true, !line[first.1.upperBound...].contains(first.0) {
                open = first.0
            }
        }
        return mask
    }

    static func locate(_ lines: [String], table: String, key: String) -> Found {
        var found = Found()
        var current = ""
        let mask = codeMask(lines)
        let inTable = pattern(table, key, dotted: false), topLevel = pattern(table, key, dotted: true)
        let anyKey = try? NSRegularExpression(pattern: "^\\s*" + escaped(key) + "\\s*=")
        let dottedTable = try? NSRegularExpression(pattern: "^\\s*" + escaped(table) + "\\s*\\.")
        let dottedKey = try? NSRegularExpression(pattern: "^\\s*" + escaped(table) + "\\s*\\.\\s*" + escaped(key) + "\\s*=")
        let whole = try? NSRegularExpression(pattern: "^\\s*" + escaped(table) + "\\s*=")
        for (index, line) in lines.enumerated() where mask[index] {
            if let name = header(line) {
                current = name
                if name == table {
                    found.headers += 1
                    if found.section == nil { found.section = index }
                }
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            func hit(_ regex: NSRegularExpression?) -> Bool { regex?.firstMatch(in: line, range: range) != nil }
            if current == table {
                if hit(anyKey) { found.keyLines += 1 }
                if found.line == nil, hit(inTable) { found.line = index; found.dotted = false }
            } else if current.isEmpty {
                if hit(dottedTable) { found.dottedLines.append(index) }
                if hit(dottedKey) { found.keyLines += 1 }
                if found.line == nil, hit(topLevel) { found.line = index; found.dotted = true }
                if hit(whole) { found.inline = true }
            }
        }
        return found
    }

    static func value(of key: String, table: String = "memories", in text: String) -> Bool? {
        let lines = text.components(separatedBy: "\n")
        let found = locate(lines, table: table, key: key)
        guard let index = found.line, let regex = pattern(table, key, dotted: found.dotted) else { return nil }
        let line = lines[index]
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 2), in: line) else { return nil }
        return line[range] == "true"
    }

    /// Codex 別自己整理記憶：`[memories] generate_memories = false`（use_memories 不動）。
    static func disableGenerate(_ data: Data?) throws -> Edit? {
        try setting("memories", "generate_memories", to: false, in: data)
    }

    /// Codex 記憶功能的總開關（預設關）：`[features] memories = true`。
    static func enableFeature(_ data: Data?) throws -> Edit? {
        try setting("features", "memories", to: true, in: data)
    }

    /// 本來就是這個值回 nil（不動）；有那一行只換值；有表頭沒那行就加在表頭下；表是最上層 dotted 寫法就加一行 dotted；
    /// 都沒有就加在檔尾；檔案不在就新建。
    static func setting(_ table: String, _ key: String, to value: Bool, in data: Data?) throws -> Edit? {
        let written = "\(key) = \(value)"
        guard let data else {
            return Edit(data: Data("[\(table)]\n\(written)\n".utf8), kind: "created", originalLine: nil, writtenLine: written)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineMemoryLinks.Failure(reason: "config.toml 不是 UTF-8，先不改")
        }
        let unclear = EngineMemoryLinks.Failure(reason: "config.toml 的 [\(table)] 寫法看不懂，先不改")
        var lines = text.components(separatedBy: "\n")
        let found = locate(lines, table: table, key: key)
        guard found.consistent else { throw unclear }
        let edit: Edit
        if let index = found.line, let regex = pattern(table, key, dotted: found.dotted) {
            guard self.value(of: key, table: table, in: text) != value else { return nil }
            let original = lines[index]
            let replaced = regex.stringByReplacingMatches(in: original, range: NSRange(original.startIndex..., in: original),
                                                          withTemplate: "$1\(value)")
            lines[index] = replaced
            edit = Edit(data: Data(lines.joined(separator: "\n").utf8), kind: "replaced", originalLine: original, writtenLine: replaced)
        } else if found.keyLines > 0 {
            throw unclear
        } else if let section = found.section {
            let line = written + (lines[section].hasSuffix("\r") ? "\r" : "")
            lines.insert(line, at: section + 1)
            edit = Edit(data: Data(lines.joined(separator: "\n").utf8), kind: "inserted", originalLine: nil, writtenLine: line)
        } else if let last = found.dottedLines.last {
            let line = "\(table).\(written)" + (lines[last].hasSuffix("\r") ? "\r" : "")
            lines.insert(line, at: last + 1)
            edit = Edit(data: Data(lines.joined(separator: "\n").utf8), kind: "inserted", originalLine: nil, writtenLine: line)
        } else {
            var appended = text
            if !appended.isEmpty, !appended.hasSuffix("\n") { appended += "\n" }
            appended += (appended.isEmpty ? "" : "\n") + "[\(table)]\n\(written)\n"
            edit = Edit(data: Data(appended.utf8), kind: "appended", originalLine: nil, writtenLine: written)
        }
        // 寫入前的關卡：值讀得回來、這個鍵只有一個、表只有一種寫法。
        let after = String(decoding: edit.data, as: UTF8.self)
        let check = locate(after.components(separatedBy: "\n"), table: table, key: key)
        guard self.value(of: key, table: table, in: after) == value, check.keyLines == 1, check.consistent else {
            throw EngineMemoryLinks.Failure(reason: "config.toml 改完讀不回來，沒有寫入")
        }
        return edit
    }

    /// 接上後 config.toml 又被改過時的還原：只把我們改的那幾行改回原樣（或拿掉我們加的行）；值已經被別人改掉的那行不動。
    static func undo(_ data: Data, record: EngineMemoryManifest.Codex) -> Data? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        var changed = false
        let edits: [(table: String, key: String, ours: Bool, kind: String?, original: String?)] = [
            ("memories", "generate_memories", false, record.edit, record.originalLine),
            ("features", "memories", true, record.featureEdit, record.featureOriginalLine),
        ]
        for edit in edits {
            guard let kind = edit.kind else { continue }
            var lines = text.components(separatedBy: "\n")
            guard let index = locate(lines, table: edit.table, key: edit.key).line,
                  value(of: edit.key, table: edit.table, in: text) == edit.ours else { continue }
            switch kind {
            case "replaced":
                guard let original = edit.original else { continue }
                lines[index] = original
            case "inserted", "appended", "created":
                lines.remove(at: index)
            default:
                continue
            }
            text = lines.joined(separator: "\n")
            changed = true
        }
        return changed ? Data(text.utf8) : nil
    }
}

// MARK: - 檔案監看：入口 memory/ 變了就重產 Codex 摘要

/// App 起來（設定 › 開始使用第一次整理清單時）開始看入口的 memory/；資料夾有變動（新增、改名、刪除）等 2 秒再重產，
/// 另外每 5 分鐘補看一次（原地改檔不會觸發資料夾事件）。重產只在 Codex 已接上時寫，內容一樣就不寫。
final class EngineMemoryWatcher: @unchecked Sendable {
    static let shared = EngineMemoryWatcher()
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.memory-watch", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var watchedPath: String?
    private var paths: EngineMemoryPaths?

    func start(paths: EngineMemoryPaths = EngineMemoryPaths()) {
        queue.async { [self] in
            let first = self.paths == nil
            self.paths = paths
            attach()
            if first { schedule(after: 0) }
            guard timer == nil else { return }
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 300, repeating: 300)
            tick.setEventHandler { [weak self] in
                self?.attach()
                self?.schedule(after: 0)
            }
            tick.resume()
            timer = tick
        }
    }

    private func attach() {
        guard let paths else { return }
        let path = paths.memory.path
        guard source == nil || watchedPath != path else { return }
        source?.cancel()
        source = nil
        watchedPath = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                              eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                                                              queue: queue)
        watch.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            if !current.data.intersection([.delete, .rename, .revoke]).isEmpty {
                current.cancel()
                self.source = nil
                self.watchedPath = nil
            }
            self.schedule(after: 2)
        }
        watch.setCancelHandler { close(descriptor) }
        source = watch
        watchedPath = path
        watch.resume()
    }

    private func schedule(after delay: TimeInterval) {
        guard let paths else { return }
        pending?.cancel()
        // W180 E1b：讀 memory/ 時跟自動同步的合併共用一把鎖，摘要不會讀到合併到一半的檔。
        let work = DispatchWorkItem { _ = TatwoMemoryLock.run { EngineMemoryLinks.refreshCodexSummary(paths: paths) } }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
