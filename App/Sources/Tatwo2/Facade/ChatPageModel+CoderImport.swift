import Foundation

/// W180 E3：匯入的進度（ChatPageModel 的 extension 放不了存的欄位，所以另外一個小物件）。
/// 讀檔在背景、可以取消、有進度；主執行緒只做最後的寫入。
@MainActor
final class CoderImportJob: ObservableObject {
    static let shared = CoderImportJob()
    @Published fileprivate(set) var isRunning = false
    @Published fileprivate(set) var status = ""
    fileprivate var work: Task<Void, Never>?
    /// 匯入完成、串已選好時叫（匯入視窗用來自己關掉）。
    var onFinished: (() -> Void)?

    func cancel() { work?.cancel() }
    func clearStatusIfIdle() { if !isRunning { status = "" } }
}

extension ChatPageModel {
    /// 只列使用者自己在終端機用的 CLI；OS 內建引擎那份就是 Coder 自己的討論串。假資料模式回空（沿用 W110）。
    var coderImportSources: [CLITranscriptArchive.Source] {
        cliTranscriptSources.filter { $0.origin == .native }
    }

    /// 已經匯入過的（清單上的按鈕變「已匯入・打開」）。W181 R1 審查修正：跟 E3 一樣用家別＋session id 去重，
    /// 不比路徑字串（~/.codex、~/.claude 是捷徑時，E3 存的是解開後的路徑）。
    var coderImportedKeys: Set<String> {
        Set(localLiveForBridge?.doc.threads.compactMap { $0.importedFrom?.dedupeKey } ?? [])
    }

    /// 本機這條是匯入的：右鍵「看原檔」用。
    func coderImportSource(_ threadID: UUID?) -> CoderImportSource? {
        localLiveForBridge?.threadRecord(threadID)?.importedFrom
    }

    /// 只有原檔路徑時（串的右鍵「看原檔」）找回它的出處（家別、session id）。
    func coderImportSource(path: String) -> CoderImportSource? {
        let resolved = CoderImportCatalog.resolvedPath(path)
        return localLiveForBridge?.doc.threads.lazy.compactMap(\.importedFrom)
            .first { $0.path == path || CoderImportCatalog.resolvedPath($0.path) == resolved }
    }

    /// 副設備（身分檔寫 secondary、主設備在配對清單裡）而且這台三家都送不出（施工單 Q2 甲）：可以匯入、只能看；
    /// 要接著做就登入訂閱帳號，或移到其他設備。主設備或單機不算。
    /// W181 R3：看這台真的送不出的那幾家（勾了不用 API 金鑰、又只有 API 金鑰登入），不是只看有沒有勾；有一家能跑就不標。
    var coderImportViewOnly: Bool {
        let blocked = Set(ClaudeSidecar.Kind.allCases.filter { isEngineDisabled($0) }.map(\.rawValue))
        return CoderImport.viewOnly(disabledEngines: blocked, isSecondary: assistantPrimaryDevice != nil)
    }

    /// 這台所有匯入的串估算佔 document.json 多少（總量上限用；封存的也還在文件裡，一起算）。
    var coderImportUsedBytes: Int {
        localLiveForBridge?.doc.threads.reduce(0) { total, thread in
            total + (thread.importedFrom.map { $0.keptBytes ?? CoderImport.maxBytesPerSession } ?? 0)
        } ?? 0
    }

    /// 匯入一段或一批（每批最多 30 段、總量有上限）。已匯入過的直接打開舊的那條，不重讀。
    /// W181 R1：target＝整批放進 Coder 裡的哪個專案（Codex／Claude Code 的專案 → 同名專案；nil＝照各則自己的資料夾，E3 原規則）。
    /// job 預設 nil＝共用的那個（預設參數不能直接寫 .shared：它屬於主執行緒，Swift 6 會擋）。
    func importCLISessions(_ sessions: [CLITranscriptSession], target: CoderImportTarget? = nil, job: CoderImportJob? = nil,
                           totalCap: Int = CoderImport.maxImportedBytesTotal) {
        let job = job ?? .shared
        guard isLive, let engine = localLiveForBridge else { flashComposerHint("這台沒有本機的 Coder 資料，沒辦法匯入"); return }
        guard !job.isRunning else { job.status = "上一批還在匯入；等它完成，或先取消。"; return }
        let placement = target.map { coderImportPlacement(for: $0, engine: engine) }
        var reopened: UUID?, fresh: [CLITranscriptSession] = []
        for original in sessions where CoderImport.eligible(original) {
            let session = placement.map { CoderImportTarget.placing(original, in: $0.workdir) } ?? original
            if let id = engine.importedThreadID(engine: session.engine.rawValue, sessionID: session.sessionID, path: session.url.path) {
                reopened = reopened ?? id
            } else if !fresh.contains(where: { $0.id == session.id }) {
                fresh.append(session)
            }
        }
        let skipped = max(0, fresh.count - CoderImport.maxSessionsPerBatch)
        fresh = Array(fresh.prefix(CoderImport.maxSessionsPerBatch))
        guard !fresh.isEmpty else {
            if let reopened {
                engine.reopenImportedThread(reopened)
                openImportedThread(reopened, note: "這段已經匯入過，打開原本那條", job: job)
            } else {
                job.status = "沒有可以匯入的對話（房間、腳本與 OS 內建引擎的對話不匯入）"
            }
            return
        }
        guard coderImportUsedBytes < totalCap else {
            job.status = "沒有匯入：\(CoderImport.usageText(used: coderImportUsedBytes, cap: totalCap))，已經滿了。" + Self.coderImportCapReason
            return
        }
        let viewOnlyHint = coderImportViewOnly ? CoderImport.viewOnlyHint : nil
        job.isRunning = true
        job.status = "準備讀取 \(fresh.count) 段…"
        let batch = fresh
        job.work = Task { [weak self] in
            let total = batch.count
            let work = Task.detached(priority: .userInitiated) { () -> [(CLITranscriptSession, CoderImport.Digest, Bool)] in
                var out: [(CLITranscriptSession, CoderImport.Digest, Bool)] = []
                for (index, session) in batch.enumerated() {
                    if Task.isCancelled { break }
                    let items = CLITranscriptArchive.read(session) { percent in
                        Task { @MainActor in job.status = "讀取第 \(index + 1)／\(total) 段 \(percent)%" }
                    }
                    if Task.isCancelled { break }
                    var isDirectory: ObjCBool = false
                    let missing = !session.cwd.isEmpty
                        && !(FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory) && isDirectory.boolValue)
                    out.append((session, CoderImport.digest(items), missing))
                }
                return out
            }
            let results = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            job.isRunning = false
            job.work = nil
            guard !Task.isCancelled, results.count == total, let self, let engine = self.localLiveForBridge else {
                job.status = "已取消，沒有匯入任何對話"
                return
            }
            let now = Date()
            // 總量上限：照順序放，放不下的後面都不收（大小是存進 document.json 的估算）。
            let admitted = CoderImport.admitted(used: self.coderImportUsedBytes, sizes: results.map { $0.1.estimatedStoredBytes }, cap: totalCap)
            var items: [(digest: CoderImport.Digest, source: CoderImportSource)] = []
            for (session, digest, missing) in results.prefix(admitted) {
                items.append((digest: digest, source: CoderImportSource(
                    engine: session.engine.rawValue, sessionID: session.sessionID, path: session.url.path,
                    title: session.title, cwd: session.cwd, sourceModifiedAt: session.modifiedAt, importedAt: now,
                    totalMessages: digest.total, keptMessages: digest.kept,
                    folderMissing: missing ? true : nil,
                    liveAtImport: now.timeIntervalSince(session.modifiedAt) <= CLITranscriptArchive.liveWindow ? true : nil,
                    keptBytes: digest.estimatedStoredBytes)))
            }
            // W181 R1：整個專案匯入時先建好專案（資料夾＝那個專案的根目錄；同名不同資料夾就加區別），E3 照資料夾對到它。
            if let placement, !items.isEmpty { self.ensureCoderImportProject(placement, engine: engine) }
            // 主執行緒只做最後的寫入：整批加進文件後存一次檔，專案空間也只寫一次。
            let ids = engine.importCLISessions(items, viewOnlyHint: viewOnlyHint)
            CoderProjectSpaces.shared.adoptLocalProjects(ids.compactMap { engine.threadRecord($0)?.projectID })
            let overCap = results.count - admitted
            guard let firstID = ids.first else {
                job.status = "沒有匯入：\(CoderImport.usageText(used: self.coderImportUsedBytes, cap: totalCap))，這批放不下。"
                    + Self.coderImportCapReason
                return
            }
            var note = placement == nil ? "匯入了 \(ids.count) 段；每段放最近的內容，完整紀錄仍在原檔"
                : "匯入了 \(ids.count) 則到「\(placement?.name ?? "")」；每則放最近的內容，完整紀錄仍在原檔"
            if skipped > 0, target != nil {
                note += "；一次最多 \(CoderImport.maxSessionsPerBatch) 則，先匯入最近的，這個專案還有 \(skipped) 則沒匯入（再按一次「匯入這個專案」接著匯入）"
            } else if skipped > 0 { note += "；一次最多 \(CoderImport.maxSessionsPerBatch) 段，還有 \(skipped) 段沒匯入" }
            if overCap > 0 { note += "；到了總量上限，還有 \(overCap) 段沒匯入" }
            if let viewOnlyHint { note += "。" + viewOnlyHint }
            self.openImportedThread(firstID, note: note, job: job)
        }
    }

    static let coderImportCapReason = "上限是為了不讓兩台同步時卡住（Coder 的對話每 5 秒整份同步）；完整紀錄還是可以在這裡讀原檔。"

    /// 選到那條（Coder、本機），用輸入框上方那一行說結果。寫入走 localLiveForBridge：選著遠端串時也只寫本機。
    private func openImportedThread(_ threadID: UUID, note: String, job: CoderImportJob) {
        mode = .chat
        selectLocalThread(threadID)
        flashComposerHint(note)
        job.status = note
        job.onFinished?()
    }
}

// MARK: - W181 R1：照 Codex／Claude Code 自己的專案匯入

/// 整批放進 Coder 的哪個專案：名稱用來源那家的專案名，資料夾是那個專案的根目錄。
struct CoderImportTarget: Equatable, Sendable {
    let name: String
    let root: String

    init(name: String, root: String) { self.name = name; self.root = root }
    /// Codex 的「沒有專案的對話」整組放進一個 Coder 專案（不照每則的暫存資料夾各建一個，免得側欄冒出一大堆看不懂的專案）；
    /// 連 Codex 都沒記資料夾的才照各則自己的資料夾放（E3 規則）。
    init?(_ project: CoderImportProject) {
        if project.isProjectless {
            guard !project.root.isEmpty else { return nil }
            self.init(name: CodexAppProjects.projectlessCoderName, root: project.root)
        } else {
            self.init(name: project.name, root: project.root)
        }
    }

    /// 這一則放到指定資料夾（E3 照資料夾對到 Coder 專案；資料夾不在就照 E3 標「資料夾已不在」）。標題、出處不變。
    static func placing(_ session: CLITranscriptSession, in workdir: String) -> CLITranscriptSession {
        CLITranscriptSession(url: session.url, engine: session.engine, origin: session.origin, sessionID: session.sessionID,
                             title: session.title, cwd: workdir, modifiedAt: session.modifiedAt, bytes: session.bytes,
                             isBatch: session.isBatch)
    }
}

extension ChatPageModel {
    /// 使用者自己的 Codex App／Claude Code；假資料模式不讀真的紀錄（沿用 W110）。
    var coderImportRoots: CoderImportCatalog.Roots? { isLive ? .standard() : nil }

    /// 這一則匯入過了沒（家別＋session id，跟 E3 去重一樣）。
    func coderImportIsImported(_ conversation: CoderImportConversation, keys: Set<String>? = nil) -> Bool {
        (keys ?? coderImportedKeys).contains(conversation.importKey)
    }

    /// 匯入整個專案：還沒匯入、原檔還在的，最近的先；都匯入過了就打開最近那條。
    func importCoderProject(_ project: CoderImportProject, job: CoderImportJob? = nil) {
        let imported = coderImportedKeys
        let available = project.conversations.filter(\.fileExists)
        let pending = available.filter { !coderImportIsImported($0, keys: imported) }
        importCLISessions((pending.isEmpty ? available : pending).map(\.session), target: CoderImportTarget(project), job: job)
    }

    /// 匯入一則（已匯入的就打開那條）；放進它所屬專案對應的 Coder 專案。
    func importCoderConversation(_ conversation: CoderImportConversation, in project: CoderImportProject, job: CoderImportJob? = nil) {
        importCLISessions([conversation.session], target: CoderImportTarget(project), job: job)
    }

    /// 這個來源專案會放進 Coder 的哪個專案（畫面上的說明用）。
    func coderImportDestination(_ project: CoderImportProject) -> CoderImportPlacement? {
        guard let target = CoderImportTarget(project), let engine = localLiveForBridge else { return nil }
        return coderImportPlacement(for: target, engine: engine)
    }

    /// W181 R1 審查修正：先照（解開捷徑的）資料夾找 Coder 專案；同名但資料夾不同就不沿用，改建一個加區別的
    /// （規則在 CoderImportCatalog.placement）。一般、助理專案不算。
    func coderImportPlacement(for target: CoderImportTarget, engine: ChatLiveEngine) -> CoderImportPlacement {
        CoderImportCatalog.placement(name: target.name, root: target.root,
                                     projects: coderImportCandidates(engine).map { .init(id: $0.id, name: $0.name, workdir: $0.workdir) },
                                     home: NSHomeDirectory())
    }

    /// 那個資料夾還沒有 Coder 專案就照 placement 的名字建一個（家目錄交給 E3 的「家目錄」專案）。
    func ensureCoderImportProject(_ placement: CoderImportPlacement, engine: ChatLiveEngine) {
        let path = CoderImport.normalized(placement.workdir)
        guard path != CoderImport.normalized(NSHomeDirectory()),
              !coderImportCandidates(engine).contains(where: { CoderImport.normalized($0.workdir) == path }) else { return }
        _ = engine.newProject(name: placement.name, workdir: path)
    }

    private func coderImportCandidates(_ engine: ChatLiveEngine) -> [LiveProjectRecord] {
        let excluded = Set([engine.doc.generalProjectID, engine.doc.assistantProjectID].compactMap { $0 })
        return engine.doc.projects.filter { !excluded.contains($0.id) && $0.name != "一般" }
    }
}
