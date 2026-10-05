import Combine
import Foundation

// W182 R4（使用者 09-27「如果主設備斷線呢？我的macbook就完全變空白傻傻的是嗎？」→「好 照這樣做」）：
// 那台連不上時，Coder 側欄與私訊框照樣列出最後同步的專案與對話（灰、可以讀），
// 「在這台接著聊」把那條複製成本機的一條新討論串、用這台的模型接著聊；不自動合併（兩條是分支，搬對話要使用者按）。

/// Coder 選著的遠端串那台連不上時的唯讀狀態（輸入框換成說明＋「在這台接著聊」）。
struct RemoteOfflineReadOnlyState: Equatable {
    let deviceID: String
    let deviceName: String
    let threadID: UUID
    let syncedAt: Date?
}

/// 私訊框說明列右邊那顆玻璃 chip。
struct GlobalDMNoteAction {
    let title: String
    let run: @MainActor () -> Void
}

/// 「在這台接著聊」的規則與文字（純函式；自測與原始碼契約都讀這裡）。
enum RemoteOfflineContinue {
    static let bannerStatus = "info|離線接續"
    static let bannerIDPrefix = "w182-offline|"
    static let chipTitle = "在這台接著聊"
    static let notReadNote = "這則離線前沒讀過，連上後才看得到"
    private static let bannerHead = "這條從"
    private static let bannerMark = "複製過來（它離線時）"

    /// 串頂第一則系統說明。專案是這台新建的就說原資料夾在哪；離線前沒讀過內容就說只有標題。
    static func bannerText(deviceName: String, title: String, createdProject: String?, hasContent: Bool) -> String {
        var lines = ["這條從\(deviceName)的『\(title)』複製過來（它離線時）；那邊的原串沒動。"]
        if let createdProject {
            lines.append("原資料夾在\(deviceName)；這裡先放在「\(createdProject)」專案（資料夾用這台的家目錄）。")
        }
        if !hasContent { lines.append("這條離線前沒讀過內容，這裡只有標題。") }
        return lines.joined(separator: "\n")
    }

    /// 串頂那則的 id 記來源（那台的 id＋那條的 id），連回來時認得出是哪一台。
    static func bannerID(deviceID: String, remoteThreadID: UUID) -> String {
        bannerIDPrefix + remoteThreadID.uuidString + "|" + deviceID
    }

    static func origin(_ message: ChatMessage) -> (deviceID: String, remoteThreadID: UUID)? {
        guard message.role == .system, message.id.hasPrefix(bannerIDPrefix) else { return nil }
        let rest = message.id.dropFirst(bannerIDPrefix.count)
        guard let bar = rest.firstIndex(of: "|"), let remoteID = UUID(uuidString: String(rest[..<bar])) else { return nil }
        let deviceID = String(rest[rest.index(after: bar)...])
        return deviceID.isEmpty ? nil : (deviceID, remoteID)
    }

    /// 前情寫「先前在〈設備名〉的對話紀錄」：串頂第一行是離線接續的說明才有（移到別台後狀態不跟著走，只認文字）。
    static func sourceLabel(_ message: ChatMessage) -> String? {
        guard message.role == .system, message.status == bannerStatus || message.status == nil,
              let firstLine = message.text.split(separator: "\n").first.map(String.init),
              firstLine.hasPrefix(bannerHead), firstLine.contains(bannerMark),
              let mark = firstLine.range(of: "的『") else { return nil }
        let name = firstLine[firstLine.index(firstLine.startIndex, offsetBy: bannerHead.count)..<mark.lowerBound]
        return name.isEmpty ? "另一台設備" : String(name)
    }

    /// Coder 唯讀畫面輸入框位置那一行。
    static func readOnlyLine(deviceName: String, synced: String?) -> String {
        "\(deviceName)離線：這是最後同步" + (synced.map { "（\($0)）" } ?? "") + "的內容，只能看。"
    }

    static func dmNote(place: String) -> String {
        "\(place)現在連不上：這是最後同步的內容，只能看；要接著做，按「\(chipTitle)」。"
    }

    /// 複製哪些：你說的、AI 回的文字訊息；工具呼叫與輸出、系統說明、錯誤不複製。新的 id，不帶回合 id 與狀態。
    static func copyRows(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { row in
            guard row.eventKind == .message, row.role == .user || row.role == .assistant,
                  !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ChatMessage(role: row.role, text: row.text, modelID: row.modelID, createdAt: row.createdAt)
        }
    }

    enum ProjectPlan: Equatable {
        case chat
        case existing(UUID)
        case create(String)
    }

    /// 放哪：原本在一般／聊天的放聊天；其他本機有同名專案就放進去，沒有就建同名專案（資料夾用這台家目錄）。絕不放進聊天。
    static func projectPlan(remote doc: LiveDocumentRecord, thread: LiveThreadRecord, local: LiveDocumentRecord) -> ProjectPlan {
        guard let projectID = thread.projectID, let project = doc.projects.first(where: { $0.id == projectID }) else { return .chat }
        if projectID == doc.generalProjectID || (doc.generalProjectID == nil && project.name == "一般") { return .chat }
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "另一台的專案" : trimmed
        let excluded = Set([local.generalProjectID, local.assistantProjectID].compactMap { $0 })
        if let match = local.projects.first(where: {
            !excluded.contains($0.id) && !(local.generalProjectID == nil && $0.name == "一般")
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) { return .existing(match.id) }
        return .create(name)
    }
}

/// 「在這台接著聊」之後請 Coder 輸入框拿游標（輸入框的焦點在 ChatPage，靠這個訊號）。
@MainActor
final class RemoteOfflineContinueSignals: ObservableObject {
    static let shared = RemoteOfflineContinueSignals()
    @Published private(set) var composerFocusRequest = 0
    func requestComposerFocus() { composerFocusRequest += 1 }
    /// 正在複製的（設備 id|那條 id）：連點兩下只建一條。
    var continuing: Set<String> = []
}

extension ChatPageModel {
    /// Coder 選著的遠端串、那台連不上、離線副本裡有這條。
    private var remoteOfflineSession: RemoteDeviceSession? {
        guard isLive, let selected = selectedRemote,
              let session = remoteSessions.first(where: { $0.device.id == selected.deviceID }),
              session.engine == nil, session.offlineMirror.hasThread(selected.threadID) else { return nil }
        return session
    }

    /// 輸入框換成「只能看＋在這台接著聊」的時候；連回來就是 nil（唯讀畫面自動變回能送出）。
    var remoteOfflineReadOnly: RemoteOfflineReadOnlyState? {
        guard let session = remoteOfflineSession, let threadID = selectedRemote?.threadID else { return nil }
        return RemoteOfflineReadOnlyState(deviceID: session.device.id, deviceName: session.device.name,
                                          threadID: threadID, syncedAt: session.offlineMirror.syncedAt)
    }

    /// 唯讀畫面的內容：記憶體裡的，或從磁碟背景讀（讀好會重畫）。
    var remoteOfflineTranscript: [ChatMessage] {
        guard let session = remoteOfflineSession, let threadID = selectedThreadID else { return [] }
        return session.offlineMirror.transcript(for: threadID) ?? []
    }

    /// 遠端串那台連不上時對話區算不算「載入中」：沒有離線副本照舊（連線中…）；有存內容、還在從磁碟讀才算。
    static func remoteOfflineLoading(_ session: RemoteDeviceSession, _ threadID: UUID?) -> Bool {
        guard let threadID, session.offlineMirror.hasThread(threadID) else { return true }
        return session.offlineMirror.hasTranscript(threadID) && session.offlineMirror.transcript(for: threadID) == nil
    }

    /// 那台連不上、這條離線前沒讀過：對話區寫一行說明（不是空白、不是連線中）。
    var remoteOfflineEmptyNote: String? {
        guard let session = remoteOfflineSession, let threadID = selectedThreadID,
              !session.offlineMirror.hasTranscript(threadID) else { return nil }
        return RemoteOfflineContinue.notReadNote
    }

    /// 側欄右鍵：那台連不上、離線副本裡有這條，就給「在這台接著聊」。
    func remoteOfflineCanContinue(deviceID: String, threadID: UUID) -> Bool {
        guard isLive, let session = remoteSessions.first(where: { $0.device.id == deviceID }) else { return false }
        return session.engine == nil && session.offlineMirror.hasThread(threadID)
    }

    /// 在這台接著聊（Coder 與私訊框共用）：把那條（離線副本裡的訊息、標題、所屬專案名）複製成本機的一條新討論串，
    /// 串頂第一則說明來源；openInCoder＝選到新串、游標在 Coder 輸入框（私訊框自己換對象）。那台的原串與離線副本都不動。
    /// 第一句的前情由 ChatLiveEngine.send → offlineCopySeed 帶（只第一次）。
    func continueOfflineThreadHere(deviceID: String, threadID: UUID, openInCoder: Bool = true,
                                   completion: (@MainActor (UUID?) -> Void)? = nil) {
        guard isLive, let engine = localLiveForBridge,
              let session = remoteSessions.first(where: { $0.device.id == deviceID }),
              let snapshot = session.offlineMirror.snapshot, let thread = session.offlineMirror.thread(threadID),
              !snapshot.document.isAssistantThread(threadID) else {
            flashComposerHint("找不到這條的離線副本，沒有複製")
            completion?(nil)
            return
        }
        let deviceName = session.device.name
        // 同一條已經在這台接著聊過（還沒封存）：打開那條，不再建一條一樣的。
        if let existing = Self.offlineCopy(in: engine, deviceID: deviceID, remoteThreadID: threadID) {
            openOfflineCopy(existing, inCoder: openInCoder)
            flashComposerHint("這條已經在這台接著聊過，打開那條")
            completion?(existing)
            return
        }
        // 正在複製同一條（連點兩下）：這次不做。
        let key = deviceID + "|" + threadID.uuidString
        guard RemoteOfflineContinueSignals.shared.continuing.insert(key).inserted else {
            completion?(nil)
            return
        }
        let mirror = session.offlineMirror
        Task { @MainActor [weak self] in
            defer { RemoteOfflineContinueSignals.shared.continuing.remove(key) }
            let messages = await mirror.loadTranscript(threadID) ?? []
            guard let self else { completion?(nil); return }
            let localID = self.makeOfflineCopy(engine: engine, remote: snapshot.document, thread: thread,
                                               deviceID: deviceID, deviceName: deviceName, messages: messages)
            self.openOfflineCopy(localID, inCoder: openInCoder)
            let note = "已在這台接著聊「\(thread.title)」；\(deviceName)上的原串沒動"
            self.flashComposerHint(self.localEngineUsable ? note : note + "。這台現在沒有能用的模型：登入訂閱帳號就能接著聊")
            completion?(localID)
        }
    }

    /// 這台上從那台那條複製過來、還沒封存的串（串頂那則的 id 記著來源）。
    static func offlineCopy(in engine: ChatLiveEngine, deviceID: String, remoteThreadID: UUID) -> UUID? {
        engine.doc.threads.first { thread in
            guard !thread.isArchived, let first = engine.transcript(for: thread.id).first,
                  let origin = RemoteOfflineContinue.origin(first) else { return false }
            return origin.deviceID == deviceID && origin.remoteThreadID == remoteThreadID
        }?.id
    }

    private func openOfflineCopy(_ localID: UUID, inCoder: Bool) {
        guard inCoder else { return }   // 私訊框自己換對象，Coder 的選取不動
        mode = .chat
        selectLocalThread(localID)
        RemoteOfflineContinueSignals.shared.requestComposerFocus()
    }

    /// 這台有沒有送得出去的模型（三家至少一家沒被擋）。
    private var localEngineUsable: Bool {
        ClaudeSidecar.Kind.allCases.contains { !isEngineDisabled($0) }
    }

    private func makeOfflineCopy(engine: ChatLiveEngine, remote doc: LiveDocumentRecord, thread: LiveThreadRecord,
                                 deviceID: String, deviceName: String, messages: [ChatMessage]) -> UUID {
        let rows = RemoteOfflineContinue.copyRows(messages)
        var createdProject: String?
        let projectID: UUID?
        switch RemoteOfflineContinue.projectPlan(remote: doc, thread: thread, local: engine.doc) {
        case .chat:
            projectID = nil
        case .existing(let id):
            projectID = id
        case .create(let name):
            projectID = engine.newProject(name: name, workdir: NSHomeDirectory())
            createdProject = name
        }
        if let projectID { CoderProjectSpaces.shared.adoptLocalProject(projectID) }   // 選了專案空間時看得到
        let banner = ChatMessage(
            id: RemoteOfflineContinue.bannerID(deviceID: deviceID, remoteThreadID: thread.id),
            role: .system,
            text: RemoteOfflineContinue.bannerText(deviceName: deviceName, title: thread.title,
                                                   createdProject: createdProject, hasContent: !rows.isEmpty),
            status: RemoteOfflineContinue.bannerStatus,
            createdAt: rows.first?.createdAt ?? Date())
        return engine.insertOfflineCopy(projectID: projectID, title: thread.title, rows: [banner] + rows)
    }

    /// W201：設備連回不主動提醒；搬移仍由使用者在右鍵選單自行發起。

    // MARK: 私訊框

    /// 這條 session 在一台連不上、但有離線副本的設備上（本機的不算）。
    func dmOfflineSession(_ threadID: UUID) -> RemoteDeviceSession? {
        guard localLiveForBridge?.threadRecord(threadID) == nil else { return nil }
        return remoteSessions.first { $0.engine == nil && $0.offlineMirror.hasThread(threadID) }
    }

    /// 私訊框：那台連不上、這條離線前沒讀過。
    func dmOfflineEmptyText(_ threadID: UUID) -> String? {
        guard dmRemote(for: threadID) == nil, let session = dmOfflineSession(threadID),
              !session.offlineMirror.hasTranscript(threadID) else { return nil }
        return RemoteOfflineContinue.notReadNote
    }

    /// 私訊框說明列的「在這台接著聊」：建好本機那條就把私訊框換到它（Coder 的選取不動）。
    func dmOfflineContinueAction(_ threadID: UUID, store: GlobalDMStore) -> GlobalDMNoteAction? {
        guard dmRemote(for: threadID) == nil, let session = dmOfflineSession(threadID) else { return nil }
        let deviceID = session.device.id
        return GlobalDMNoteAction(title: RemoteOfflineContinue.chipTitle) { [weak self, weak store] in
            self?.continueOfflineThreadHere(deviceID: deviceID, threadID: threadID, openInCoder: false) { localID in
                if let localID { store?.select(.thread(localID)) }
            }
        }
    }

    // MARK: 設定 › 設備

    /// 那台存了什麼（設定頁一行）；沒有這台的連線物件是 nil。
    func remoteOfflineUsageLine(deviceID: String) -> String? {
        remoteSessions.first { $0.device.id == deviceID }?.offlineMirror.usageLine
    }

    /// 清除這台的離線副本（移到垃圾桶，可以放回）；正在看它的唯讀畫面就先回本機。
    func clearRemoteOfflineCache(deviceID: String, completion: @escaping @MainActor (String) -> Void) {
        guard let session = remoteSessions.first(where: { $0.device.id == deviceID }) else {
            completion("這台現在沒有離線副本")
            return
        }
        if selectedRemote?.deviceID == deviceID, session.engine == nil { exitRemoteMode() }
        session.offlineMirror.clear { [weak self, weak session] result in
            switch result {
            case .success(true):
                completion("已清除：這台存的副本移到垃圾桶（可以放回）。"
                           + (session?.engine != nil ? "現在連著線，下次同步會再存一份新的。" : ""))
            case .success(false):
                completion("這台現在沒有離線副本")
            case .failure(let error):
                completion("沒清掉：\(error.localizedDescription)")
            }
            self?.rebuildRemoteSidebarSections()
        }
    }

    /// 設定 › 設備「移除」那台（在換掉連線物件之前叫）：它存在這台的離線副本一起移到垃圾桶（可以放回），
    /// 不留在磁碟、畫面上也不會沒有地方清；之後重新配對同一個 id 不會冒出舊快照。那台的連線物件先停記。
    func retireRemoteOfflineCache(deviceID: String, environment: [String: String],
                                  completion: (@MainActor (Result<Bool, Error>) -> Void)? = nil) {
        let report: @MainActor (Result<Bool, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(true):
                self?.flashComposerHint("已移除設備；那台存在這台的離線副本也移到垃圾桶了（可以放回）。")
            case .success(false):
                break
            case .failure(let error):
                self?.flashComposerHint("已移除設備，但那台存在這台的離線副本沒移到垃圾桶：\(error.localizedDescription)")
            }
            completion?(result)
        }
        if let session = remoteSessions.first(where: { $0.device.id == deviceID }) {
            session.offlineMirror.retire(completion: report)
        } else {
            let cache = RemoteOfflineCache(root: RemoteOfflineCache.defaultRoot(environment: environment))
            cache.run({ cache in Result { try cache.clear(deviceID: deviceID) } }, then: report)
        }
    }

    #if DEBUG
    /// 自測：裝上假的遠端設備（不開 SSH）；那台有更新就馬上重算側欄。
    func w182AdoptRemoteSessionsForTest(_ sessions: [RemoteDeviceSession]) {
        remoteSessions = sessions
        for session in sessions {
            session.onUpdate = { [weak self] in
                self?.rebuildRemoteSidebarSections()
                self?.objectWillChange.send()
            }
        }
        rebuildRemoteSidebarSections()
    }
    #endif
}

// MARK: - W182 R4：前情（ChatLiveEngine.send 在 E3 匯入之後叫）

extension ChatLiveEngine {
    /// 離線時從別台複製過來的串第一次用某家引擎送：開新的引擎對話、第一句帶最近內容（照 E3 seedPrompt：包成資料不是指令）。
    /// 只認串頂那則說明；那家引擎已經有這條的 session（不是第一次）就不帶。
    func offlineCopySeed(threadID: UUID, engine: ClaudeSidecar.Kind, userText: String, currentTurn: String) -> String? {
        guard let thread = threadRecord(threadID), thread.parentThreadID == nil,
              thread.sessionIDs[engine.rawValue] == nil, !(engine == .claude && thread.sessionID != nil) else { return nil }
        let rows = transcript(for: threadID)
        guard let first = rows.first, let label = RemoteOfflineContinue.sourceLabel(first) else { return nil }
        let seedRows = rows.dropFirst().compactMap { row -> CoderImport.SeedRow? in
            guard row.turnID != currentTurn || row.role != .user else { return nil }
            guard row.role != .system, row.eventKind == .message else { return nil }
            return .init(kind: row.role == .user ? .user : .assistant, text: row.text)
        }
        guard !seedRows.isEmpty else { return nil }
        return CoderImport.seedPrompt(rows: seedRows, sourceLabel: label, userText: userText)
    }
}
