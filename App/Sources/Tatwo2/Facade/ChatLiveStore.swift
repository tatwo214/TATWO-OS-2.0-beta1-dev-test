// 2.0 真水電：對話資料的存檔格式（JSON，一份文件）。取代 1.0 的 journal／sqlite。
// 畫面吃的仍是 1.0 的 ChatMessage / TatwoNativeChatStoreDocument（在 Facade 的同名薄版），這裡只負責存與讀。
import Foundation
import os

struct LiveMessageRecord: Codable, Equatable {
    var id: String
    var role: String          // user / assistant / system
    var text: String
    var status: String?
    var eventKind: String     // TatwoNativeChatEventKind.rawValue
    var turnID: String?
    var createdAt: Date
    /// 引擎自己回報的模型。要存檔：沒存的話 App 重開後整條討論串的頭像都會變成「現在選的那個模型」。舊檔沒有這欄。
    var modelID: String? = nil
    var modelDisplayName: String? = nil
    var runtimeAdapterID: String? = nil   // 舊檔可無此欄；來源隨訊息保存。
    var engineErrorDetails: String? = nil

    init(_ m: ChatMessage) {
        id = m.id; role = m.role.storageValue; text = m.text; status = m.status
        eventKind = m.eventKind.rawValue; turnID = m.turnID; createdAt = m.createdAt
        modelID = m.modelID
        modelDisplayName = m.modelDisplayName
        runtimeAdapterID = m.runtimeAdapterID
        engineErrorDetails = m.engineErrorDetails
    }

    var chatMessage: ChatMessage {
        let r: ChatMessageRole = role == "user" ? .user : role == "system" ? .system : .assistant
        var message = ChatMessage(id: id, role: r, text: text, status: status,
                           modelID: modelID, modelDisplayName: modelDisplayName,
                           eventKind: TatwoNativeChatEventKind(rawValue: eventKind) ?? .message,
                           turnID: turnID, createdAt: createdAt)
        message.runtimeAdapterID = runtimeAdapterID
            ?? (modelID?.hasPrefix(TatwoChatRuntimeAdapter.chatgptTap.rawValue + ":") == true
                ? TatwoChatRuntimeAdapter.chatgptTap.rawValue : nil)
        message.engineErrorDetails = engineErrorDetails
        return message
    }
}

struct LiveCLITabRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var engine: String
    var cwd: String
    var title: String
}

/// W184 H4 修正（GPT-6 H4 審查 #3）：一條 thread 的 ultrawork 設定——檔位（0＝關、1…5＝S～XXL）、主導、每一個副手——存在那條的紀錄裡
/// （跟模型、速度、記憶同一個地方）。這裡只有資料（跟對話紀錄一起編、一起存）；怎麼用（說明那一段、送出、主設備怎麼收）在
/// Chat/TatwoComposerModeUltrawork.swift 的 extension。
struct UltraworkTurnSettings: Codable, Equatable, Sendable {
    var level: Int
    var primaryModelID: String?
    var auxiliaryModelIDs: [String]
}

struct LiveThreadRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var projectID: UUID?
    var title: String = "新聊天"
    var isPinned: Bool = false
    var isArchived: Bool = false
    var sessionID: String?      // 舊欄位（Claude），保留相容
    var sessionIDs: [String: String] = [:]   // 引擎 → session id（claude/codex/grok 各自續接）
    var sessionIsolated: [String: Bool] = [:]
    func sessionID(for engine: String, isolated: Bool) -> String? {
        guard (sessionIsolated[engine] ?? (controllerCreatorFingerprint == nil ? false : nil)) == isolated else { return nil }
        return sessionIDs[engine] ?? (engine == "claude" ? sessionID : nil)
    }
    var engine: String?         // 最近用的引擎
    var requestedModel: String?
    var requestedEffort: String?
    var requestedSpeedTier: String?
    var nativeGoal: ChatNativeGoal?
    var model: String?
    var enabledMCP: [String] = []   // 空＝使用該引擎預設全部
    var messages: [LiveMessageRecord] = []
    var issues: [TatwoIssueListEntryV1] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var cliTabs: [LiveCLITabRecord] = []
    var cliTabsUpdatedAt: Date?
    // 2.0 B1/B3：子討論串（sub）欄位；舊 JSON 沒有這些鍵會解成 nil
    var parentThreadID: UUID?
    var roomBrief: String?
    var roomReadOnly: Bool?   // nil/false: existing construction room; true: enforced reviewer runner.
    var lastOutputAt: Date?
    var subStatus: String?   // running / done
    var cwdOverride: String?   // 房間專屬 worktree（E1 派工引擎）；nil 就用專案 workdir
    var botPermissionPreset: TatwoPermissionPreset? // Bot uses the existing native approval enum, not a new permission system.
    var deviceID: String?   // R3：nil＝本機；有值＝從 devices.json 找遠端設備
    var importedFrom: CoderImportSource?   // W180 E3：從 Codex／Claude Code 匯入的出處；舊檔沒有這欄
    var controllerCreatorFingerprint: String? // Durable local creator scope for restricted remote work conversations.
    var memoryStrength: String?   // W180 E1：記憶強度 off/light/medium/deep；nil＝照預設（TatwoMemoryStrength.resolve）
    var ultrawork: UltraworkTurnSettings?   // W184 H4 修正（審查 #3）：這條的 ultrawork（檔位＋主導＋每一個副手）；nil＝沒開過
    var ultraworkSent: UltraworkTurnSettings?   // W184 H4 修正（審查 #2）：上一輪真的帶出去的（開著的才記）；關掉那一輪說一聲用

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String = "新聊天",
        isPinned: Bool = false,
        isArchived: Bool = false,
        sessionID: String? = nil,
        sessionIDs: [String: String] = [:],
        engine: String? = nil,
        model: String? = nil,
        enabledMCP: [String] = [],
        messages: [LiveMessageRecord] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cliTabs: [LiveCLITabRecord] = [],
        cliTabsUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sessionID = sessionID
        self.sessionIDs = sessionIDs
        self.engine = engine
        self.model = model
        self.enabledMCP = enabledMCP
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliTabs = cliTabs
        self.cliTabsUpdatedAt = cliTabsUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, isPinned, isArchived, sessionID, sessionIDs, sessionIsolated, engine, model, enabledMCP
        case messages, createdAt, updatedAt, cliTabs, cliTabsUpdatedAt
        case parentThreadID, roomBrief, roomReadOnly, lastOutputAt, subStatus
        case issues, cwdOverride, deviceID, botPermissionPreset, requestedModel, requestedEffort, requestedSpeedTier, nativeGoal
        case importedFrom   // W180 E3
        case controllerCreatorFingerprint
        case memoryStrength   // W180 E1
        case ultrawork, ultraworkSent   // W184 H4 修正
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新聊天"
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        sessionIDs = try c.decodeIfPresent([String: String].self, forKey: .sessionIDs) ?? [:]
        sessionIsolated = try c.decodeIfPresent([String: Bool].self, forKey: .sessionIsolated) ?? [:]
        requestedModel = try c.decodeIfPresent(String.self, forKey: .requestedModel)
        requestedEffort = try c.decodeIfPresent(String.self, forKey: .requestedEffort)
        requestedSpeedTier = try c.decodeIfPresent(String.self, forKey: .requestedSpeedTier)
        nativeGoal = try c.decodeIfPresent(ChatNativeGoal.self, forKey: .nativeGoal)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        enabledMCP = try c.decodeIfPresent([String].self, forKey: .enabledMCP) ?? []
        messages = try c.decodeIfPresent([LiveMessageRecord].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        cliTabs = try c.decodeIfPresent([LiveCLITabRecord].self, forKey: .cliTabs) ?? []
        cliTabsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .cliTabsUpdatedAt)
        // 舊 JSON 沒有這些鍵會解成 nil（B1/B3 子討論串欄位；E2 監工要靠它們讀寫活性）
        parentThreadID = try c.decodeIfPresent(UUID.self, forKey: .parentThreadID)
        roomBrief = try c.decodeIfPresent(String.self, forKey: .roomBrief)
        roomReadOnly = try c.decodeIfPresent(Bool.self, forKey: .roomReadOnly)
        controllerCreatorFingerprint = try c.decodeIfPresent(String.self, forKey: .controllerCreatorFingerprint)
        lastOutputAt = try c.decodeIfPresent(Date.self, forKey: .lastOutputAt)
        subStatus = try c.decodeIfPresent(String.self, forKey: .subStatus)
        issues = try c.decodeIfPresent([TatwoIssueListEntryV1].self, forKey: .issues) ?? []
        cwdOverride = try c.decodeIfPresent(String.self, forKey: .cwdOverride)
        botPermissionPreset = try c.decodeIfPresent(TatwoPermissionPreset.self, forKey: .botPermissionPreset)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        // W180 E3：出處壞掉只丟這一欄，不讓整份文件解不開。
        importedFrom = (try? c.decodeIfPresent(CoderImportSource.self, forKey: .importedFrom)) ?? nil
        memoryStrength = try c.decodeIfPresent(String.self, forKey: .memoryStrength)   // W180 E1：舊檔沒有這欄
        // W184 H4 修正：舊檔、舊版主設備的文件沒有這兩欄；壞掉只丟這一欄，不讓整份文件解不開。
        ultrawork = (try? c.decodeIfPresent(UltraworkTurnSettings.self, forKey: .ultrawork)) ?? nil
        ultraworkSent = (try? c.decodeIfPresent(UltraworkTurnSettings.self, forKey: .ultraworkSent)) ?? nil
    }
}

struct LiveProjectRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var workdir: String
    var isExpanded: Bool = true
    var githubRepos: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        workdir: String,
        isExpanded: Bool = true,
        githubRepos: [String] = []
    ) {
        self.id = id
        self.name = name
        self.workdir = workdir
        self.isExpanded = isExpanded
        self.githubRepos = githubRepos
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workdir, isExpanded, githubRepos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "一般"
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? NSHomeDirectory()
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        githubRepos = try c.decodeIfPresent([String].self, forKey: .githubRepos) ?? []
    }
}

struct LiveDocumentRecord: Codable, Equatable {
    var projects: [LiveProjectRecord] = []
    var threads: [LiveThreadRecord] = []
    var selectedThreadID: UUID?
    // Explicit identity: an existing user project called "一般" is still a
    // project. Older documents decode this optional field as nil.
    var generalProjectID: UUID?
    var assistantProjectID: UUID?

    mutating func ensureAssistantProject() -> UUID {
        if let id = assistantProjectID, projects.contains(where: { $0.id == id }) { return id }
        let entry = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI/TATWO OS")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
        let project = LiveProjectRecord(name: "TATWO 助理",
            workdir: exists && isDirectory.boolValue ? entry.path : NSHomeDirectory())
        projects.append(project)
        assistantProjectID = project.id
        return project.id
    }

    var assistantThreadID: UUID? {
        guard let projectID = assistantProjectID else { return nil }
        return threads.first { $0.projectID == projectID && $0.parentThreadID == nil }?.id
    }

    @discardableResult
    mutating func ensureAssistantThread() -> UUID {
        let projectID = ensureAssistantProject()
        if let id = assistantThreadID {
            if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].isArchived = false }
            return id
        }
        let thread = LiveThreadRecord(projectID: projectID, title: "TATWO 助理")
        threads.append(thread)
        return thread.id
    }

    mutating func ensureGeneralProject() -> UUID {
        if let id = generalProjectID, projects.contains(where: { $0.id == id }) { return id }
        let project = LiveProjectRecord(name: "一般", workdir: NSHomeDirectory())
        projects.append(project)
        generalProjectID = project.id
        return project.id
    }

    mutating func prepareChatHierarchy() {
        if projects.isEmpty { _ = ensureGeneralProject() }
        let ids = Set(projects.map(\.id))
        let orphaned = threads.indices.filter { index in
            guard let id = threads[index].projectID else { return true }
            return !ids.contains(id)
        }
        // Previously these records disappeared from the UI. Their engine
        // workdir already fell back to HOME; retain messages and overrides.
        if !orphaned.isEmpty {
            let id = ensureGeneralProject()
            for index in orphaned { threads[index].projectID = id }
        }
    }
}

/// 一份 JSON 放 Application Support/tatwo2/live/document.json；原檔未確認保留就禁止寫回。
final class ChatLiveStore {
    let url: URL
    private let persistenceLock = NSRecursiveLock()
    private var savedDocument: LiveDocumentRecord?
    private var savedStamp: PolicyFileStamp?
    #if DEBUG
    static var fixtureLoad: (() -> Void)?
    #endif
    private let writeProtectionKeys: [String]
    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/live", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let documentURL = base.appendingPathComponent("document.json")
        url = documentURL
        writeProtectionKeys = [documentURL.standardizedFileURL.path,
            base.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("document.json").path,
            documentURL.resolvingSymlinksInPath().standardizedFileURL.path]
    }

    enum LoadState: Equatable { case missing, loaded, readFailed, decodeFailed }
    private let loadMetadata = OSAllocatedUnfairLock<(state: LoadState, notice: String?)>(initialState: (.missing, nil))
    private(set) var loadState: LoadState {
        get { loadMetadata.withLock { $0.state } }
        set { loadMetadata.withLock { $0.state = newValue } }
    }
    private static let readOnlyReasons = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private var notice: String? {
        get { loadMetadata.withLock { $0.notice } }
        set { loadMetadata.withLock { $0.notice = newValue } }
    }
    private func readOnlyReason(in reasons: [String: String]) -> String? {
        for key in writeProtectionKeys { if let reason = reasons[key] { return reason } }
        return nil
    }
    var isReadOnly: Bool { Self.readOnlyReasons.withLock { readOnlyReason(in: $0) != nil } }
    var loadNotice: String? { Self.readOnlyReasons.withLock { readOnlyReason(in: $0) } ?? notice }

    private func protectOriginal(_ reason: String) {
        Self.readOnlyReasons.withLock { reasons in
            for key in writeProtectionKeys where reasons[key] == nil { reasons[key] = reason }
        }
    }

    func load() -> LiveDocumentRecord {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        #if DEBUG
        Self.fixtureLoad?()
        #endif
        let stamp = PolicyFileStamp(url)
        let document = loadFromDisk()
        savedDocument = document; savedStamp = stamp
        return document
    }

    private func loadFromDisk() -> LiveDocumentRecord {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil {
                loadState = .missing
            } else {
                loadState = .readFailed
                protectOriginal("對話紀錄讀不到，無法確認原檔已另存；本次以唯讀模式開啟，不會覆寫。原檔位置：\(url.path)。原因：\(error.localizedDescription)")
            }
            return LiveDocumentRecord()
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let doc = try? dec.decode(LiveDocumentRecord.self, from: data) {
            loadState = .loaded
            return doc
        }
        loadState = .decodeFailed
        if let backup = Self.preserveUnreadable(data, beside: url) {
            notice = "對話紀錄有資料這一版解不開，原檔已比對一致並另存於 \(backup.path)。這裡先讀回可辨識的紀錄；能完整讀懂副本的版本會提供還原按鈕。"
        } else {
            protectOriginal("對話紀錄解不開，而且原檔另存或比對失敗；本次以唯讀模式開啟，不會覆寫。原檔位置：\(url.path)。請先確認儲存空間與檔案權限。")
        }
        return ChatDocumentRecovery.decode(data) ?? LiveDocumentRecord()
    }

    /// 保留舊驗收入口；產品提示依每個 store 的 loadNotice，不共用全域狀態。
    nonisolated(unsafe) static var lastUnreadableBackup: URL?

    private static func backupData(_ file: URL) -> Data? {
        guard let kind = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              kind.isRegularFile == true, kind.isSymbolicLink != true else { return nil }
        return try? Data(contentsOf: file)
    }

    @discardableResult
    static func preserveUnreadable(_ data: Data, beside url: URL) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent("unreadable", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                where Self.backupData(file) == data {
                lastUnreadableBackup = file; return file
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let target = dir.appendingPathComponent("document-\(stamp)-\(UUID().uuidString).json")
            try data.write(to: target, options: .withoutOverwriting)
            guard try Data(contentsOf: target) == data else { return nil }
            lastUnreadableBackup = target
            return target
        } catch { return nil }
    }

    /// 只提供本版能完整解碼的副本；啟動不自動覆蓋目前文件。
    func restorableBackup() -> URL? {
        let dir = url.deletingLastPathComponent().appendingPathComponent("unreadable", isDirectory: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let current = try? Data(contentsOf: url)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("document-") && $0.pathExtension == "json" }
            .sorted { Self.backupDate($0) > Self.backupDate($1) }
            .first { file in
                guard let data = Self.backupData(file), data != current,
                      (try? decoder.decode(LiveDocumentRecord.self, from: data)) != nil else { return false }
                return shouldOfferBackup(file)
            }
    }

    /// 副本清單與已開啟的還原按鈕共用此規則；目前文件再保存後也要重算。
    func shouldOfferBackup(_ candidate: URL) -> Bool {
        if loadState == .readFailed || loadState == .decodeFailed { return true }
        guard let currentDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return Self.backupDate(candidate) > currentDate
    }

    static func backupDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
    }

    func restoreBackup(_ candidate: URL) throws -> LiveDocumentRecord {
        guard !isReadOnly else { throw BotLibraryError.invalid("本次為唯讀模式，不能覆寫原檔：" + url.path) }
        let dir = url.deletingLastPathComponent().appendingPathComponent("unreadable", isDirectory: true)
        guard candidate.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else {
            throw BotLibraryError.invalid("還原副本位置不符")
        }
        let data = try Data(contentsOf: candidate)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(LiveDocumentRecord.self, from: data)
        let current: Data
        do { current = try Data(contentsOf: url) }
        catch {
            protectOriginal("目前對話紀錄讀不到；本次為唯讀模式，不會覆寫。原檔位置：\(url.path)。原因：\(error.localizedDescription)")
            throw error
        }
        guard Self.preserveUnreadable(current, beside: url) != nil else {
            let reason = "目前對話紀錄另存或比對失敗，尚未還原；本次為唯讀模式。原檔位置：" + url.path
            protectOriginal(reason)
            throw BotLibraryError.invalid(reason)
        }
        try Self.readOnlyReasons.withLock { reasons in
            if let reason = readOnlyReason(in: reasons) { throw BotLibraryError.invalid(reason) }
            try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else { throw BotLibraryError.invalid("還原後內容比對失敗") }
        }
        notice = nil; loadState = .loaded
        return restored
    }

    #if DEBUG
    /// W189 send-04 自測：壞掉的 document.json 讀完後原檔要原封不動另存一份、同內容只存一次。
    static func selfTestUnreadablePreserved() -> Bool {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("w189-doc-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let store = ChatLiveStore(root: dir)
        let broken = Data("{\"threads\":[{\"id\":42}]}".utf8)
        guard (try? broken.write(to: store.url)) != nil else { print("W189DOCSAFETY FAIL setup"); return false }
        lastUnreadableBackup = nil
        let doc = store.load()
        let saved = dir.appendingPathComponent("unreadable", isDirectory: true)
        let copies = (try? fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil)) ?? []
        let preserved = copies.contains { (try? Data(contentsOf: $0)) == broken }
        _ = store.load()
        let again = ((try? fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil)) ?? []).count
        let original = (try? Data(contentsOf: store.url)) == broken
        var checks: [(String, Bool)] = [
            ("unreadable document yields empty record", doc.threads.isEmpty),
            ("original preserved byte-identical in unreadable/", preserved),
            ("same content stored once across repeated loads", again == 1),
            ("load itself never rewrites document.json", original),
            ("backup recorded for the visible notice", lastUnreadableBackup != nil),
        ]
        for (name, ok) in checks { print("W189DOCSAFETY \(ok ? "PASS" : "FAIL") \(name)") }
        let blocked = ChatLiveStore(root: dir.appendingPathComponent("blocked-fixture"))
        try? broken.write(to: blocked.url)
        try? Data("fixture".utf8).write(to: blocked.url.deletingLastPathComponent().appendingPathComponent("unreadable"))
        _ = blocked.load()
        blocked.save(LiveDocumentRecord())
        checks.append(("M1 preservation failure never overwrites original", (try? Data(contentsOf: blocked.url)) == broken))
        try? fm.removeItem(at: blocked.url.deletingLastPathComponent().appendingPathComponent("unreadable"))
        blocked.save(LiveDocumentRecord())
        checks.append(("M1 read-only lasts for this store execution", (try? Data(contentsOf: blocked.url)) == broken))
        let anotherStore = ChatLiveStore(root: blocked.url.deletingLastPathComponent())
        anotherStore.save(LiveDocumentRecord())
        checks.append(("M1 read-only applies to every store in this process", (try? Data(contentsOf: blocked.url)) == broken))
        let alias = dir.appendingPathComponent("alias-fixture")
        try? fm.createSymbolicLink(at: alias, withDestinationURL: blocked.url.deletingLastPathComponent())
        ChatLiveStore(root: alias).save(LiveDocumentRecord())
        checks.append(("M1 an alias cannot bypass this execution's read-only mode", (try? Data(contentsOf: blocked.url)) == broken))
        let denied = ChatLiveStore(root: dir.appendingPathComponent("read-fixture"))
        try? fm.createDirectory(at: denied.url, withIntermediateDirectories: true)
        denied.save(LiveDocumentRecord())
        var isDirectory: ObjCBool = false
        checks.append(("M1 unreadable document is not missing", fm.fileExists(atPath: denied.url.path, isDirectory: &isDirectory) && isDirectory.boolValue))
        for (name, passed) in checks.dropFirst(5) { print("W189DOCSAFETY \(passed ? "PASS" : "FAIL") \(name)") }
        let missing = ChatLiveStore(root: dir.appendingPathComponent("missing-fixture"))
        _ = missing.load()
        checks.append(("M1 missing document remains writable", missing.loadState == .missing && !missing.isReadOnly))
        checks.append(("M1 read failure has visible reason and original location", denied.loadState == .readFailed && denied.isReadOnly && denied.loadNotice?.contains(denied.url.path) == true))
        checks.append(("M1 decode failure remains distinct", blocked.loadState == .decodeFailed && blocked.isReadOnly))
        let restore = ChatLiveStore(root: dir.appendingPathComponent("restore-fixture"))
        var prior = LiveDocumentRecord(); prior.threads = [LiveThreadRecord(title: "sample")]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let priorData = (try? encoder.encode(prior)) ?? Data()
        let priorBackup = Self.preserveUnreadable(priorData, beside: restore.url)
        let current = LiveDocumentRecord(threads: [LiveThreadRecord(title: "fixture")])
        restore.save(current)
        let currentData = try? Data(contentsOf: restore.url)
        if let priorBackup {
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: priorBackup.path)
            checks.append(("M1 healthy document hides older backup", restore.restorableBackup() == nil))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-240)], ofItemAtPath: restore.url.path)
        }
        checks.append(("M1 readable backup offered without automatic overwrite", restore.restorableBackup().flatMap { try? Data(contentsOf: $0) } == priorData && (try? Data(contentsOf: restore.url)) == currentData))
        if let candidate = restore.restorableBackup() {
            let result = try? restore.restoreBackup(candidate)
            let copies = (try? fm.contentsOfDirectory(at: candidate.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            checks.append(("M1 explicit restore preserves current bytes first", result?.threads.first?.title == "sample" && copies.contains { (try? Data(contentsOf: $0)) == currentData }))
            checks.append(("M1 restored document survives reopen", ChatLiveStore(root: restore.url.deletingLastPathComponent()).load().threads.first?.title == "sample"))
        } else { checks.append(("M1 restore fixture setup", false)) }
        let failureRoot = dir.appendingPathComponent("restore-failure-fixture")
        let failedRestore = ChatLiveStore(root: failureRoot)
        failedRestore.save(current)
        let beforeFailure = try? Data(contentsOf: failedRestore.url)
        if let candidate = Self.preserveUnreadable(priorData, beside: failedRestore.url) {
            try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: candidate.deletingLastPathComponent().path)
            let restored = try? failedRestore.restoreBackup(candidate)
            checks.append(("M1 restore refuses if current backup cannot be preserved", restored == nil && (try? Data(contentsOf: failedRestore.url)) == beforeFailure))
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.deletingLastPathComponent().path)
        } else { checks.append(("M1 failed restore fixture setup", false)) }
        let retarget = ChatLiveStore(root: dir.appendingPathComponent("retarget-fixture"))
        try? broken.write(to: retarget.url)
        try? Data("fixture".utf8).write(to: retarget.url.deletingLastPathComponent().appendingPathComponent("unreadable"))
        _ = retarget.load()
        try? fm.moveItem(at: retarget.url, to: retarget.url.deletingLastPathComponent().appendingPathComponent("original-fixture.json"))
        let replacement = ChatLiveStore(root: dir.appendingPathComponent("target-fixture"))
        replacement.save(current)
        try? fm.createSymbolicLink(at: retarget.url, withDestinationURL: replacement.url)
        let linkBefore = try? fm.destinationOfSymbolicLink(atPath: retarget.url.path)
        retarget.save(LiveDocumentRecord())
        checks.append(("M1 read-only cannot reset when the document target changes", retarget.isReadOnly && linkBefore != nil && (try? fm.destinationOfSymbolicLink(atPath: retarget.url.path)) == linkBefore))
        for (name, passed) in checks.dropFirst(10) { print("W189DOCSAFETY \(passed ? "PASS" : "FAIL") \(name)") }
        lastUnreadableBackup = nil
        let ok = checks.allSatisfy(\.1)
        print("W189DOCSAFETY SUMMARY failures=\(checks.filter { !$0.1 }.count)")
        return ok
    }
    #endif

    /// Pasted images belong to the same persistent store as their transcript,
    /// not the system temporary directory. Never overwrite an existing file.
    func saveAttachment(data: Data, suggestedName: String) throws -> URL {
        let name = (suggestedName as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "圖片.png" : name
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: target, options: .atomic)
        return target
    }

    func save(_ doc: LiveDocumentRecord) {
        try? saveChecked(doc, verify: false)
    }

    /// Called by the bridge after leaving MainActor; also respects edits made by another store/CLI.
    func saveIfChanged(_ doc: LiveDocumentRecord, expectedStamp: PolicyFileStamp? = nil) {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        // A main-actor save after the bridge captured its snapshot supersedes that snapshot.
        if let expectedStamp, expectedStamp != PolicyFileStamp(url) { return }
        let previous = savedStamp == PolicyFileStamp(url) ? savedDocument : nil
        if !OSAgentBridge.documentsEqual(doc, previous ?? load()) { save(doc) }
    }

    func saveChecked(_ doc: LiveDocumentRecord, verify: Bool = true) throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        guard !isReadOnly else { throw BotLibraryError.invalid("對話紀錄為唯讀：" + url.path) }
        var merged = doc
        let existing = load()
        guard !isReadOnly else { throw BotLibraryError.invalid("原檔未確認保留，禁止寫回：" + url.path) }
        for index in merged.threads.indices {
            guard
                let old = existing.threads.first(where: { $0.id == merged.threads[index].id }),
                let oldDate = old.cliTabsUpdatedAt,
                oldDate > (merged.threads[index].cliTabsUpdatedAt ?? .distantPast)
            else { continue }
            merged.threads[index].cliTabs = old.cliTabs
            merged.threads[index].cliTabsUpdatedAt = oldDate
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(merged)
        try Self.readOnlyReasons.withLock { reasons in
            if let reason = readOnlyReason(in: reasons) { throw BotLibraryError.invalid(reason) }
            try data.write(to: url, options: .atomic)
            savedDocument = merged; savedStamp = PolicyFileStamp(url)
            if verify {
                guard try Data(contentsOf: url) == data else {
                    throw BotLibraryError.invalid("chat_store_write_verification_failed")
                }
            }
        }
    }

    func cliTabs(threadID: UUID) -> [LiveCLITabRecord] {
        load().threads.first(where: { $0.id == threadID })?.cliTabs ?? []
    }

    func updateCLITabs(threadID: UUID, tabs: [LiveCLITabRecord]) {
        var doc = load()
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[index].cliTabs = tabs
        doc.threads[index].cliTabsUpdatedAt = Date()
        save(doc)
    }
}
