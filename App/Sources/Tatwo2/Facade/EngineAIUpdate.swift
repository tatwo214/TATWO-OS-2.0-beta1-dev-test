import Foundation
import Combine

@MainActor final class EngineAIUpdate: ObservableObject {
    static let shared = EngineAIUpdate()
    typealias Source = (ClaudeSidecar.Kind) async -> (String?, String?, EngineModelCatalog.Catalog?)
    @Published var selecting = false
    @Published var selected = Set<String>()
    private var openingRows: [String: String] = [:]
    private var versions: [String: (String?, String?, EngineModelCatalog.Catalog?)] = [:]
    func toggle(_ id: String) {
        guard selecting, !running, let value = versions[id], let current = value.0, let newest = value.1, EngineRuntimeSelection.isNewer(newest, than: current) else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
        rows[id] = Self.versionLine(current, newest) + (selected.contains(id) ? "" : "（你沒勾）")
    }
    func cancel() { guard selecting, !running else { return }; selecting = false; selected = []; rows = openingRows; openingRows = [:]; versions = [:]; message = "" }
    func installSelected(changed: () -> Void = {}) async {
        guard selecting, !running, !selected.isEmpty else { return }; selecting = false
        await check(source: { self.versions[$0.rawValue] ?? (nil, nil, nil) }, changed: changed, selection: selected)
    }
    @Published var running = false
    @Published var message = ""
    @Published var rows: [String: String] = [:]
    @Published var proposals: [Proposal] = []
    let defaults: UserDefaults
    var localSource: LocalModelSource.Source?
    var localInstalled: Bool { localSource != nil || LocalModelSource.installed() }
    var source: Source?
    var install: ((ClaudeSidecar.Kind, String) async throws -> String)?
    var rollbackAction: ((ClaudeSidecar.Kind) async throws -> String)?
    @Published var hasNewVersion = false
    @Published var rollbackVersions: [String: String] = [:]
    private var checkingVersions = false
    private var dailyTask: Task<Void, Never>?
    func refreshLocalVersions(paths: EnginePaths = EnginePaths(), forceVerification: Bool = false) async {
        guard !running, !selecting, !checkingVersions else { return }
        checkingVersions = true; defer { checkingVersions = false }
        var refreshed: [String: String] = [:], found = false, known = false, unknown = false
        for kind in [ClaudeSidecar.Kind.codex, .claude, .grok] {
            let current = try? await paths.selectionAsync(for: kind, forceVerification: forceVerification).version
            let newest = defaults.string(forKey: "ai.newest." + kind.rawValue)
            refreshed[kind.rawValue] = newest == nil ? (current ?? "目前版本查不到") : Self.versionLine(current, newest)
            if let newest { known = true; if let current { found = found || EngineRuntimeSelection.isNewer(newest, than: current) } else { unknown = true } }
        }
        guard !running, !selecting, !Task.isCancelled else { return }
        rows.merge(refreshed) { _, new in new }
        if known { hasNewVersion = found || (unknown && hasNewVersion); defaults.set(hasNewVersion, forKey: "ai.available") }
    }
    func startDailyChecks() {
        guard dailyTask == nil, !NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else { return }
        dailyTask = Task { await refreshLocalVersions(); while !Task.isCancelled { await backgroundCheck(); try? await Task.sleep(for: .seconds(3600)) } }
    }
    func backgroundCheck(source: Source? = nil, now: Date = Date()) async {
        guard !running, !selecting, !checkingVersions, now.timeIntervalSince1970 - defaults.double(forKey: "ai.lastCheck") >= 86400 else { return }
        checkingVersions = true; defer { checkingVersions = false }
        var found = false, unknown = false
        for kind in [ClaudeSidecar.Kind.codex, .claude, .grok] {
            let (current, latest, _) = await (source ?? { await Self.read($0, versionsOnly: true) })(kind)
            if let latest { defaults.set(latest, forKey: "ai.newest." + kind.rawValue) }
            if let current, let latest { found = found || EngineRuntimeSelection.isNewer(latest, than: current) } else { unknown = true }
        }
        hasNewVersion = found || (unknown && hasNewVersion)
        defaults.set(hasNewVersion, forKey: "ai.available"); defaults.set(now.timeIntervalSince1970, forKey: "ai.lastCheck")
    }
    func rollback(_ kind: ClaudeSidecar.Kind) async {
        guard !running, !selecting else { return }; running = true; defer { running = false }
        do { rows[kind.rawValue] = try await (rollbackAction ?? { try await EngineInstall(paths: EnginePaths()).rollback($0) })(kind); rollbackVersions[kind.rawValue] = nil }
        catch { rows[kind.rawValue] = error.localizedDescription }
    }
    nonisolated static func modelName(_ id: String) -> String {
        let profile = TatwoChatRouteProfile.resolve(id)
        return profile.runtimeAdapter == .unavailable ? (EngineModelCatalog.rememberedName(id, deviceID: "local") ?? id) : profile.displayName
    }
    struct Proposal: Identifiable, Sendable {
        let id: Int, old: String, suggested: String?
        var title: String { ["主導", "loops", "細修", "機械工", "審查"][min(id, 4)] }
        var text: String { "\(title)原本用的 \(EngineAIUpdate.modelName(old)) 下架了，" + (suggested.map { "改用 \(EngineAIUpdate.modelName($0))？" } ?? "需要你選") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; hasNewVersion = defaults.bool(forKey: "ai.available")
        let installer = EngineInstall(paths: EnginePaths())
        for kind in ClaudeSidecar.Kind.allCases { rollbackVersions[kind.rawValue] = installer.previous(kind)?.deletingLastPathComponent().lastPathComponent }
    }
    nonisolated static func provider(_ id: String) -> String {
        if id.hasPrefix("claude-") { return "claude" }; if id.hasPrefix("grok-") { return "grok" }
        return EngineModelCatalog.catalogs().first { $0.models.contains { $0.model == id } }?.engine ?? EngineModelCatalog.engineID(TatwoChatRouteProfile.resolve(id))
    }
    nonisolated static func suggested(_ old: String, catalog: EngineModelCatalog.Catalog) -> String? {
        func suffix(_ id: String) -> String? { id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "." }).last { $0.contains(where: \.isLetter) }.map(String.init) }
        let family = old.lowercased().split(separator: "-").first.map(String.init)
        let same = catalog.models.map(\.model).filter {
            $0.lowercased().split(separator: "-").first.map(String.init) == family &&
            suffix($0) == suffix(old)
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return same.first ?? catalog.defaultModel.flatMap { id in catalog.models.contains { $0.model == id } ? id : nil }
    }
    func check(source: Source? = nil, changed: () -> Void = {}, selection: Set<String>? = nil) async {
        guard !running, !selecting else { return }
        if selection == nil { versions = [:]; selected = [] }
        var updated: [String] = [], skipped: [String] = []
        running = true; while checkingVersions { try? await Task.sleep(for: .milliseconds(100)) }; var added = 0, removed = 0, latest = 0, unknown = 0, pending = false
        if selection == nil { openingRows = rows }
        defer { running = false; changed() }
        for (index, kind) in [ClaudeSidecar.Kind.codex, .claude, .grok].enumerated() {
            if let selection, !selection.contains(kind.rawValue) {
                if let value = versions[kind.rawValue], let current = value.0, let newest = value.1, EngineRuntimeSelection.isNewer(newest, than: current) { skipped.append(Self.name(kind)); pending = true }
                pending = pending || rows[kind.rawValue]?.contains(EngineInstall.manualGrok) == true
                continue
            }
            message = "正在\(selection == nil ? "檢查" : "更新") \(kind.rawValue)（第 \(index + 1) 家，共 3 家）。正在用的對話不會被打斷。"
            rows[kind.rawValue] = "進行中…"
            let (current, newest, readCatalog) = await (source ?? self.source ?? { await Self.read($0, versionsOnly: selection == nil, forceVerification: selection == nil) })(kind)
            if let newest { defaults.set(newest, forKey: "ai.newest." + kind.rawValue) }
            var version = Self.versionLine(current, newest), catalog = readCatalog
            if selection == nil { versions[kind.rawValue] = (current, newest, readCatalog) }
            if let current, let newest, EngineRuntimeSelection.isNewer(newest, than: current) {
                if selection == nil { selected.insert(kind.rawValue) }
            }
            if let current, let newest, EngineRuntimeSelection.isNewer(newest, than: current), selection != nil, install != nil || self.source == nil {
                do {
                    if let install { version = try await install(kind, newest) }
                    else {
                        let paths = EnginePaths(), choice = try await paths.selectionAsync(for: kind, forceVerification: true)
                        version = try await EngineInstall(paths: paths).install(kind, current: choice, newest: newest)
                        catalog = (await Self.read(kind)).2
                    }
                    if version.contains("已更新") { updated.append(Self.name(kind)) }
                    rollbackVersions[kind.rawValue] = EngineInstall(paths: EnginePaths()).previous(kind)?.deletingLastPathComponent().lastPathComponent
                } catch { pending = true; rows[kind.rawValue] = "更新失敗：" + error.localizedDescription; continue }
            }
            pending = pending || version.contains("可更新") || version.contains("請手動更新")
            if let current, let newest { if !EngineRuntimeSelection.isNewer(newest, than: current) { latest += 1 } } else { unknown += 1 }
            if kind == .grok, newest == nil, source == nil, self.source == nil { version = EngineInstall.manualGrok }
            guard var catalog, !catalog.models.isEmpty else { rows[kind.rawValue] = version + (selection?.contains(kind.rawValue) == true ? "。模型清單查不到" : ""); continue }
            if catalog.defaultModel == nil { let id = TatwoChatRouteProfile.resolve(kind == .codex ? "gpt-6.1-sol" : kind == .claude ? "fable-5.1" : "grok-build").modelArgument; catalog.defaultModel = catalog.models.first { $0.model == id }?.model }
            let counts = replaceCatalog(catalog, version: version, changed: changed)
            added += counts.0; removed += counts.1
        }
        if localInstalled {
            message = "正在列出本機模型。只換新模型清單，照本機。"
            let (version, catalog) = await (localSource ?? { await LocalModelSource.read() })()
            if let catalog {
                let counts = replaceCatalog(catalog, version: version, changed: changed)
                added += counts.0; removed += counts.1
            } else { rows["ollama"] = version }
        }
        hasNewVersion = pending; defaults.set(pending, forKey: "ai.available"); defaults.set(Date().timeIntervalSince1970, forKey: "ai.lastCheck")
        message = "更新完成：\(latest) 家都是最新" + (unknown > 0 ? "，\(unknown) 家查不到最新版本" : "") +
            (added + removed == 0 ? "，模型沒有變。" : "。模型清單已換新：新增 \(added) 個、下架 \(removed) 個。")
        if selection == nil { selecting = true }
        else { message = "已更新：" + (updated.isEmpty ? "無" : updated.joined(separator: "、")) + (skipped.isEmpty ? "" : "；" + skipped.joined(separator: "、") + " 照你的選擇不更新") + "。" }
    }
    private func replaceCatalog(_ value: EngineModelCatalog.Catalog, version: String, changed: () -> Void) -> (Int, Int) {
        var catalog = value, seen = Set<String>()
        catalog.models = catalog.models.filter { seen.insert(ChatProviderModelIdentity.lookupKey($0.model)).inserted }
        let key = catalog.engine
        let previous = EngineModelCatalog.profiles().filter { EngineModelCatalog.engineID($0) == key }
        let before = Set(previous.map { $0.modelArgument ?? $0.id }), after = Set(catalog.models.map(\.model))
        let a = after.subtracting(before), b = before.subtracting(after)
        let config = UltraworkRoleConfigurationStore(defaults: defaults).load()
        for (slot, old) in ([config.primaryModelID] + config.auxiliaryModelIDs).enumerated() where Self.provider(old) == key {
            let argument = TatwoChatRouteProfile.resolve(old).modelArgument ?? old
            if !catalog.models.contains(where: { EngineModelCatalog.modelKey($0.model, engine: key, catalog: catalog) == EngineModelCatalog.modelKey(argument, engine: key, catalog: catalog) }), !proposals.contains(where: { $0.id == slot && $0.old == old }) {
                proposals.append(.init(id: slot, old: old, suggested: Self.suggested(argument, catalog: catalog)))
            }
        }
        EngineModelCatalog.replace(EngineModelCatalog.catalogs().filter { $0.engine != key } + [catalog])
        rows[key] = version + (a.isEmpty && b.isEmpty ? "" : "。新增 \(a.sorted().joined(separator: "、"))；下架 \(b.sorted().joined(separator: "、"))")
        changed()
        return (a.count, b.count)
    }
    static func name(_ kind: ClaudeSidecar.Kind) -> String {
        kind == .codex ? "Codex" : kind == .claude ? "Claude Code" : "Grok Build"
    }
    static func versionLine(_ current: String?, _ latest: String?) -> String {
        guard let latest else { return "\(current ?? "目前版本查不到")。查不到最新版本" }
        guard let current else { return "目前版本查不到；最新 \(latest)" }
        return EngineRuntimeSelection.isNewer(latest, than: current) ? "\(current) → \(latest) 可更新" : "\(current)。已是最新"
    }
    func decide(_ proposal: Proposal, accept: Bool) async throws {
        guard accept, let new = proposal.suggested else { return }
        var config = UltraworkRoleConfigurationStore(defaults: defaults).load()
        guard ([config.primaryModelID] + config.auxiliaryModelIDs).indices.contains(proposal.id),
              ([config.primaryModelID] + config.auxiliaryModelIDs)[proposal.id] == proposal.old else { return }
        guard OSDocuments.isPrimary || OSDocuments.secondaryWriter != nil else { throw OSDocuments.DocumentError.readOnly("請交主設備核准角色") }
        _ = try await Self.background { try OSDocuments.write(id: "os", text: Self.table(OSDocuments.read(id: "os"), section: "4", role: proposal.title, model: new)).message }
        guard OSDocuments.isPrimary else { message = "已交主設備核准角色"; return }
        if proposal.id == 0 { config.primaryModelID = new } else { config.setAuxiliary(new, at: proposal.id - 1) }
        UltraworkRoleConfigurationStore(defaults: defaults).save(config)
        proposals.removeAll { $0.id == proposal.id }
    }
    nonisolated static func table(_ text: String, section: String, role: String, model: String) -> String {
        var inside = false
        return text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("## ") { inside = line.hasPrefix("## \(section).") || line.hasPrefix("## \(section) ") }
            var cells = line.components(separatedBy: "|")
            if inside, cells.count > 3, cells[1].trimmingCharacters(in: .whitespaces).components(separatedBy: "（").first == role,
               cells[2].trimmingCharacters(in: .whitespaces).range(of: #"^[A-Za-z][A-Za-z0-9 ._-]*[0-9][A-Za-z0-9 ._-]*(?:（[^）]*）)?$"#, options: .regularExpression) != nil { cells[2] = " \(model) "; return cells.joined(separator: "|") }
            return line
        }.joined(separator: "\n")
    }
    nonisolated static func retired(_ id: String, deviceID: String = "local") -> EngineModelCatalog.Catalog? {
        let profile = TatwoChatRouteProfile.resolve(id)
        return EngineModelCatalog.catalogs(deviceID: deviceID).first { catalog in catalog.engine == provider(id) &&
            !catalog.models.contains { EngineModelCatalog.modelKey($0.model, engine: catalog.engine, catalog: catalog) == EngineModelCatalog.modelKey(profile.modelArgument ?? id, engine: catalog.engine, catalog: catalog) } }
    }
    static func read(_ kind: ClaudeSidecar.Kind, versionsOnly: Bool = false, forceVerification: Bool = false) async -> (String?, String?, EngineModelCatalog.Catalog?) {
        guard !NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else { return (nil, nil, nil) }
        let paths = EnginePaths(), choice = try? await paths.selectionAsync(for: kind, forceVerification: forceVerification)
        let newest: String?
        switch kind {
        case .codex: newest = await codexLatest()
        case .claude: newest = await claudeLatest()
        case .grok: newest = nil
        }
        if kind != .grok { return (choice?.version, newest, versionsOnly ? nil : await EngineModelCatalogProbe.shared.read(kind)) }
        guard let choice else { return (nil, nil, nil) }
        let latest = await grokLatest(choice.executable, home: paths.grokHome)
        if versionsOnly { return (choice.version, latest, nil) }
        let text = await command(choice.executable, ["--no-auto-update", "models"], home: paths.grokHome)
        // Unauthenticated or unrecognized output is never a retirement list.
        guard let text, !text.contains("not authenticated"), let list = text.components(separatedBy: "Available models:\n").last, list != text else { return (choice.version, latest, nil) }
        let ids = list.components(separatedBy: "\n").compactMap { line -> String? in
            let id = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return id.range(of: "^grok-[a-z0-9.-]+$", options: .regularExpression) != nil ? id : nil
        }
        let models = ids.map { EngineModelCatalog.Model(model: $0, displayName: $0, efforts: [], defaultEffort: "", speeds: [], defaultSpeed: "", images: false) }
        let preferred = text.components(separatedBy: "\n").first { $0.hasPrefix("Default model: ") }.map { String($0.dropFirst(15)) }
        return (choice.version, latest, models.isEmpty ? nil : .init(engine: "grok", identity: choice.identity, source: "grok models", models: models, defaultModel: preferred))
    }
    static func codexLatest() async -> String? { await npmLatest("@openai/codex") }
    static func claudeLatest() async -> String? { await npmLatest("@anthropic-ai/claude-code") }
    static func grokLatest(_ executable: URL, home: URL) async -> String? {
        await command(executable, ["--no-auto-update", "update", "--check"], home: home)?.components(separatedBy: " -> ").last.flatMap(version)
    }
    static func npmLatest(_ package: String) async -> String? {
        guard let data = try? await EngineInstall.download(URL(string: "https://registry.npmjs.org/\(package)/latest")!, limit: 1_000_000, seconds: 10),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["version"] as? String else { return nil }
        return version(text)
    }
    nonisolated static func version(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\A(?:(?:codex(?:-cli)?|claude(?: code)?|grok)\s+)?([0-9]+\.[0-9]+\.[0-9]+)(?: \(Claude Code\))?\z"#
        guard let match = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached { try Task.checkCancellation(); let value = try work(); try Task.checkCancellation(); return value }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    nonisolated static func wait(_ process: Process, output: URL, limit: Int, seconds: TimeInterval) throws {
        defer { if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() } }
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < end, (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0 <= limit else { throw CocoaError(.fileReadTooLarge) }
            if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.03)
        } while true
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func command(_ executable: URL, _ args: [String], home: URL) async -> String? {
        try? await background {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
            let process = Process(); process.executableURL = executable; process.arguments = args
            var env = ProcessInfo.processInfo.environment; env["HOME"] = home.path; env["DISABLE_AUTOUPDATER"] = "1"; env["GROK_HOME"] = home.appendingPathComponent(".grok").path
            if args == ["update"] {
                let config = executable.deletingLastPathComponent().appendingPathComponent("update-config")
                try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                env["CLAUDE_CONFIG_DIR"] = config.path; env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = config.path
                env["XDG_CACHE_HOME"] = config.appendingPathComponent("cache").path; env["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share").path
            }
            process.environment = env; process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice; try process.run()
            try wait(process, output: file, limit: 1_000_000, seconds: args == ["update"] ? 180 : 12)
            let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
            let data = try reader.read(upToCount: 1_000_001) ?? Data()
            guard data.count <= 1_000_000 else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
