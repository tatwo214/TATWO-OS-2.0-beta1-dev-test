import Foundation

// W182 R5：副設備眼中主設備的連線狀態、連回來之後的同步（補回助理那段、依序送出排隊的事）。
// W201：自動同步安靜進行；只有拒收的佇列項目在頂端請使用者處理，完整清單放設定 › 設備。
// 主設備、單機（沒有主設備）一律沒事：primaryLinkState() 是 nil，這裡什麼都不做。

/// 對主設備的一次已配對設備呼叫（SSH 轉進去、跟 Coder 看遠端設備同一條連線）。回覆＝result 那一段的 JSON。
typealias PrimaryCallTransport = @MainActor (_ method: String, _ params: [String: Any],
                                            _ completion: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void) -> Void

/// 這一刻主設備的連線（副設備才有）。
struct PrimaryLinkState {
    let device: AssistantPrimaryDevice
    /// 連得到時的遠端引擎；連不上是 nil。
    let engine: (any AssistantRemoteEngine)?
    /// App 開著以來第一次連還沒結果（這時不說「離線」）。
    let connecting: Bool
    /// 最後一次連上的時間（自測替身沒有）。
    let lastSeenAt: Date?

    var isOffline: Bool { engine == nil && !connecting }
}

/// 呼叫主設備沒成功的原因：主設備有回話（拒收）或連線類。
struct PrimaryCallFailure: Error, Equatable, Sendable {
    let code: String
    /// 主設備有回話（remoteError）＝true；連線斷掉、簽章失敗、找不到主設備＝false。
    let remote: Bool

    /// 雖然是主設備回的，其實是「現在忙／連線」這類，等一下再送就好。
    static let transientCodes: Set<String> = ["no_active_endpoints", "os_bridge_busy", "distill_busy", "assistant_busy",
                                              "request_incomplete_or_too_large"]

    init(code: String, remote: Bool) {
        self.code = code
        self.remote = remote
    }

    init(_ error: Error) {
        if case RemoteHostLinkError.remoteError(let detail) = error {
            code = detail
            remote = !Self.transientCodes.contains(detail)
        } else if let failure = error as? DeviceDispatch.Failure {
            code = failure.reason
            remote = false
        } else if let known = error as? PrimaryCallFailure {
            self = known
        } else {
            code = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            remote = false
        }
    }

    /// 主設備是舊版、不認得這個方法。
    var isOldPeer: Bool { remote && (code == "caller_not_trusted" || code == "unsupported_method") }

    /// 這台自己的設定問題（還沒跟主設備配好）：重送也不會好。
    static let localSetupCodes: Set<String> = ["primary_not_paired", "authority_unknown"]
    var isLocalSetup: Bool { !remote && Self.localSetupCodes.contains(code) }

    /// 連線類（等一下再送就好）：可以放進佇列。主設備說不能做、這台還沒配好的不排隊。
    var isRetryable: Bool { !remote && !isLocalSetup }
}

/// 送出一筆排隊的事的結果。
enum PrimaryOutboxOutcome: Equatable, Sendable {
    /// 送到了（白話一行）。
    case sent(String)
    /// 這次沒送到（連線、主設備忙）：留著下次再送。
    case retry(String)
    /// 主設備回「不能做」：標失敗、不重試；terminal＝再送也一樣，不給重送。
    case refused(String, terminal: Bool = false)
}

struct PrimaryOutboxFlushReport: Equatable {
    var sent: [String] = []
    var refused: [String] = []
    var waiting = 0
}

struct PrimaryOfflineSyncReport: Equatable {
    var merge = AssistantOfflineMergeReport()
    var outbox = PrimaryOutboxFlushReport()
}

/// 設定 › 設備的同步清單；有拒收項目時也供頂端處理提示使用。
struct PrimaryOfflineBannerState: Equatable {
    let name: String
    let lastSeenAt: Date?
    let waiting: [PrimaryOutboxItem]
    let failed: [PrimaryOutboxItem]
    /// 助理：這台離線時接著聊、等連回後補回的段落數。
    let assistantStretches: Int

    var line: String {
        "有 \(failed.count) 件沒送到「\(name)」：按一下處理"
    }

    /// 紅綠燈那一列放不下整句時的短版（整句在展開的清單頂端）。
    var shortLine: String {
        "有 \(failed.count) 件沒送到：按一下處理"
    }
}

/// 一台（一個 live 資料夾）的同步狀態：只在記憶體。
@MainActor
final class PrimaryOfflineSync {
    private static var byRoot: [String: PrimaryOfflineSync] = [:]

    static func forRoot(_ root: URL) -> PrimaryOfflineSync {
        let key = root.standardizedFileURL.path
        let sync = byRoot[key] ?? PrimaryOfflineSync()
        byRoot[key] = sync
        return sync
    }

    /// 第一次連主設備已經有結果（連上或連不上）的設備 id；之後的重試不算「連線中」。
    var settledDeviceIDs: Set<String> = []
    /// 正在跑的那一輪同步（補回＋送出）；沒有在跑是 nil。
    fileprivate(set) var current: Task<PrimaryOfflineSyncReport, Never>?
    var running: Bool { current != nil }
    /// W201：使用者剛送的新一句因補回失敗而被留在草稿；純背景同步不顯示這則說明。
    var assistantDeliveryBlocked = false
    /// 連回後的新一句在等剛才離線那段補回（補完才送，時序才對）；沒有在等是 nil。
    var assistantHold: Task<Void, Never>?
    fileprivate var loop: Task<Void, Never>?
    fileprivate var wasOnline: [String: Bool] = [:]
    #if DEBUG
    /// 自測：對主設備的已配對設備呼叫（不連 SSH，直接交給主設備那一側的 OSAgentBridge）。
    var testPrimaryCall: PrimaryCallTransport?
    /// 自測：記憶提案核准（正式版是 UserMemoryStore.decide → DeviceDispatch.callPrimary 驗章）；回 nil＝成功。
    var testMemoryDecide: (@MainActor (_ id: String, _ accept: Bool, _ isPublic: Bool) async -> PrimaryCallFailure?)?
    /// 自測：這台的名字。
    var testDeviceName: String?
    #endif
}

@MainActor
func awaitPrimaryCall(_ transport: @escaping PrimaryCallTransport, _ method: String,
                      _ params: [String: Any]) async -> Result<Data, Error> {
    await withCheckedContinuation { continuation in
        transport(method, params) { continuation.resume(returning: $0) }
    }
}

extension ChatPageModel {
    private var primaryOfflineRoot: URL? { localLiveForBridge?.store.url.deletingLastPathComponent() }

    /// 這台的「要主設備才能做」佇列（live/primary-outbox.json）；沒有本機引擎是 nil。
    var primaryOutbox: PrimaryOutbox? { primaryOfflineRoot.map { PrimaryOutbox.forRoot($0, main: isLive) } }

    var primaryOfflineSync: PrimaryOfflineSync? { primaryOfflineRoot.map { PrimaryOfflineSync.forRoot($0) } }

    /// 這台是副設備、主設備在配對清單裡時，主設備現在的連線；主設備、單機是 nil。
    var managedAssistantIsLocal: Bool {
        let fleet = primaryLocalCache?.fleet ?? DeviceFleetStore(
            registry: DeviceRegistry(environment: fleetRoutingEnvironment), environment: fleetRoutingEnvironment)
        let stamps = [fleet.url, fleet.registry.url].map(PolicyFileStamp.init)
        if let cached = primaryLocalCache, cached.stamps == stamps { return cached.value }
        let value: Bool
        do { value = try fleet.trust().map { $0.kind != .owner } ?? false }
        catch { value = true }
        primaryLocalCache = (fleet, stamps, value)
        return value
    }
    /// Clear stale colleague destinations after upgrading to display-only SUB roles. Local transcripts stay intact.
    func clearNonOwnerPrimaryWork() async {
        let fleet = DeviceFleetStore(registry: DeviceRegistry(environment: fleetRoutingEnvironment), environment: fleetRoutingEnvironment)
        guard let payload = try? fleet.current() else { return }
        let isManaged = managedAssistantIsLocal
        if let store = assistantOfflineStore {
            await store.ready()
            store.update { rows in rows.removeAll { isManaged || payload.roster?.kind(of: $0.primaryDeviceID) != .owner } }
        }
        if let outbox = primaryOutbox {
            await outbox.ready()
            for item in outbox.items {
                if isManaged || item.params["deviceID"].map({ payload.roster?.kind(of: $0) != .owner }) == true { outbox.remove(item.id) }
            }
        }
    }
    func primaryLinkState() -> PrimaryLinkState? {
        guard !managedAssistantIsLocal else { return nil }
        #if DEBUG
        if let double = assistantPrimaryTestDouble {
            return PrimaryLinkState(device: double.device, engine: double.engine(), connecting: double.connecting(), lastSeenAt: nil)
        }
        #endif
        guard let device = assistantPrimaryDevice,
              let session = remoteSessions.first(where: { $0.device.id == device.id }) else { return nil }
        let settled = primaryOfflineSync?.settledDeviceIDs.contains(device.id) ?? false
        let engine: (any AssistantRemoteEngine)? = session.engine
        return PrimaryLinkState(device: device, engine: engine,
                                connecting: engine == nil && session.state == .connecting && !settled,
                                lastSeenAt: session.lastSeenAt)
    }

    /// 這台的名字（補回時每則標「在〈這台〉離線時」）。
    func primaryOfflineThisDeviceName() -> String {
        #if DEBUG
        if let name = primaryOfflineSync?.testDeviceName { return name }
        #endif
        return (try? DeviceIdentityStore.readLocal())?.name ?? "副設備"
    }

    /// 對主設備的已配對設備呼叫（SSH 轉進去；RemoteHostLink 在背景跑，主執行緒不等）。連不上是 nil。
    func primaryCallTransport() -> PrimaryCallTransport? {
        #if DEBUG
        if let test = primaryOfflineSync?.testPrimaryCall { return primaryLinkState()?.engine != nil ? test : nil }
        #endif
        guard let device = assistantPrimaryDevice,
              let session = remoteSessions.first(where: { $0.device.id == device.id }), session.engine != nil else { return nil }
        return Self.primaryLinkTransport(session.link)
    }

    nonisolated static func primaryLinkTransport(_ link: RemoteHostLink) -> PrimaryCallTransport {
        { method, params, completion in
            guard JSONSerialization.isValidJSONObject(params), let body = try? JSONSerialization.data(withJSONObject: params) else {
                return completion(.failure(RemoteHostLinkError.invalidResponse))
            }
            Task.detached(priority: .userInitiated) {
                let outcome = Result<Data, Error> {
                    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                    return try JSONSerialization.data(withJSONObject: try link.call(method: method, params: object))
                }
                await MainActor.run { completion(outcome) }
            }
        }
    }

    // MARK: 連線有變化

    /// W182 R5：主設備那條連線有變化（onUpdate）、或每 10 秒一次：連得到時記下主設備那條最近的對話（斷線時當前情），
    /// 有東西等補回或等送出就同步一次。主設備、單機什麼都不做。
    func primaryOfflineTick() {
        if managedAssistantIsLocal { Task { @MainActor [weak self] in await self?.clearNonOwnerPrimaryWork() }; return }
        guard let sync = primaryOfflineSync, let link = primaryLinkState() else { return }
        if let session = remoteSessions.first(where: { $0.device.id == link.device.id }), session.state != .connecting {
            sync.settledDeviceIDs.insert(link.device.id)
        }
        if let outbox = primaryOutbox, outbox.primaryName != link.device.displayName { outbox.primaryName = link.device.displayName }
        let online = link.engine != nil
        // 只用 get_document 已經帶回來的那份（不另外拉逐字稿）；那條沒變就不重算。
        if let engine = link.engine, let id = engine.doc.assistantThreadID, let record = engine.threadRecord(id) {
            AssistantPrimaryContextMemory.shared.remember(deviceID: link.device.id, record: record)
        }
        let cameBack = online && sync.wasOnline[link.device.id] == false
        sync.wasOnline[link.device.id] = online
        startPrimaryOfflineLoop(sync)
        guard online, !sync.running, cameBack || primaryOfflineHasWork(link) else { return }
        Task { @MainActor [weak self] in _ = await self?.primaryOfflineSyncNow(reconnected: cameBack) }
    }

    private func startPrimaryOfflineLoop(_ sync: PrimaryOfflineSync) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] != nil { return }   // 自測自己呼叫，不另外跑
        #endif
        guard sync.loop == nil, isLive else { return }
        sync.loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.primaryOfflineTick()
            }
        }
    }

    private func primaryOfflineHasWork(_ link: PrimaryLinkState) -> Bool {
        if primaryOutbox?.items.contains(where: { $0.isDue() }) == true { return true }
        return assistantOfflineStore?.stretches.contains { stretch in
            stretch.primaryDeviceID == link.device.id
                && (stretch.state == .open || stretch.state == .pending
                    || (stretch.state == .legacy && (stretch.lastAttemptAt ?? .distantPast) < Date().addingTimeInterval(-600)))
        } ?? false
    }

    /// 連得到主設備時同步一次：先補回助理那段，再依序送出排隊的事；不主動報備。
    /// reconnected＝剛連回來：舊主設備那段也再試一次、排隊的不等重試間隔。已經有一輪在跑就不另外跑（回空的結果）。
    @discardableResult
    func primaryOfflineSyncNow(reconnected: Bool = false) async -> PrimaryOfflineSyncReport {
        guard let sync = primaryOfflineSync, !sync.running, primaryLinkState()?.engine != nil else { return PrimaryOfflineSyncReport() }
        let round = Task { @MainActor [weak self] () -> PrimaryOfflineSyncReport in
            defer { sync.current = nil }   // 這一輪做完就清掉（等它的人醒來時已經可以再開下一輪）
            return await self?.primaryOfflineSyncRound(sync, reconnected: reconnected) ?? PrimaryOfflineSyncReport()
        }
        sync.current = round
        return await round.value
    }

    /// 等正在跑的那一輪同步做完（沒有在跑就馬上回）。
    func primaryOfflineSyncSettled() async {
        _ = await primaryOfflineSync?.current?.value
    }

    private func primaryOfflineSyncRound(_ sync: PrimaryOfflineSync, reconnected: Bool) async -> PrimaryOfflineSyncReport {
        var report = PrimaryOfflineSyncReport()
        guard let link = primaryLinkState(), let engine = link.engine else { return report }
        await assistantOfflineStore?.ready()
        await primaryOutbox?.ready()
        if let primaryThread = engine.doc.assistantThreadID, let transport = primaryCallTransport() {
            report.merge = await mergeAssistantOfflineStretches(device: link.device, primaryThread: primaryThread,
                                                                transport: transport, retryLegacy: reconnected)
        }
        report.outbox = await flushPrimaryOutbox(link, ignoreBackoff: reconnected)
        // W201：連回、補送、舊版重試與拒收都不另外跳 Island；拒收由可點的處理提示呈現。
        objectWillChange.send()
        return report
    }

    // MARK: 依序送出排隊的事

    /// 照排隊順序一筆一筆送：送到的拿掉；連線類沒送到的留著、寫原因、隔一段再送，同一種的後面幾筆也等下一輪（照順序），
    /// 別種的照送（一筆送不出去不會卡住別的事）；主設備說不能做的標失敗、不重試。
    func flushPrimaryOutbox(_ link: PrimaryLinkState, ignoreBackoff: Bool = false) async -> PrimaryOutboxFlushReport {
        var report = PrimaryOutboxFlushReport()
        guard !managedAssistantIsLocal else { await clearNonOwnerPrimaryWork(); return report }
        guard let outbox = primaryOutbox else { return report }
        await outbox.ready()
        var held: Set<PrimaryOutboxItem.Kind> = []
        // 照排隊順序（佇列只會接在最後，存檔也照這個順序）。
        for item in outbox.items where item.isWaiting && item.handedOver != true {
            guard outbox.items.contains(where: { $0.id == item.id }) else { continue }   // 途中被取消
            guard !held.contains(item.kind) else { continue }   // 同一種前面那筆還沒送到：照順序等
            if !ignoreBackoff, let after = item.retryAfter, after > Date() {
                held.insert(item.kind)
                continue
            }
            outbox.mark(item.id, state: .sending)
            let outcome = await sendPrimaryOutboxItem(item, link: link)
            switch outcome {
            case .sent(let line):
                outbox.remove(item.id)
                report.sent.append(line)
            case .retry(let reason):
                outbox.deferRetry(item.id, reason: reason)
                held.insert(item.kind)
            case .refused(let reason, let terminal):
                outbox.mark(item.id, state: .failed, reason: reason, refused: true, terminal: terminal)
                report.refused.append(reason)
            }
        }
        report.waiting = outbox.waiting.count
        return report
    }

    private func sendPrimaryOutboxItem(_ item: PrimaryOutboxItem, link: PrimaryLinkState) async -> PrimaryOutboxOutcome {
        let name = link.device.displayName
        switch item.kind {
        case .memoryDecide:
            let id = item.params["id"] ?? "", accept = item.params["accept"] == "true", isPublic = item.params["isPublic"] == "true"
            guard let failure = await primaryMemoryDecide(id: id, accept: accept, isPublic: isPublic) else {
                primaryOutbox?.noteMemoryDecided(id: id, accept: accept)   // 記憶提案畫面重讀
                return .sent(accept ? "記憶提案收下了" : "記憶提案略過了")
            }
            if failure.code.contains("memory_not_pending") { return .refused("這條記憶提案在「\(name)」上已經處理過或不在了", terminal: true) }
            if failure.isOldPeer { return .refused("「\(name)」還沒更新，不能在這台核准記憶提案") }
            if failure.isLocalSetup {
                return .refused("這台還沒跟「\(name)」配好（\(failure.code)），記憶提案的決定送不過去；到設定 › 設備重新配對後再按一次")
            }
            // 主設備有回話、但不是「忙」這類：再送也一樣，標失敗、寫原因，不卡住後面的事。
            if failure.remote { return .refused("「\(name)」沒收下這個決定（\(failure.code)）") }
            return .retry("連線不穩")
        case .classifyDecide:
            guard item.params["deviceID"]?.lowercased() == link.device.id.lowercased() else {
                return .refused("這則建議不在「\(name)」上，沒有送", terminal: true)
            }
            guard let transport = primaryCallTransport() else { return .retry("「\(name)」還連不上") }
            let params: [String: Any] = ["id": item.params["id"] ?? "", "action": item.params["action"] ?? ""]
            let outcome = await awaitPrimaryCall(transport, "project_proposal_decide", params)
            switch outcome {
            case .success:
                // W201：自動補送成功只刷新資料，不在分類頁另報備一次。
                Task { await AssistantOverviewReader.shared.refreshRemoteNow() }
                return .sent("分類建議的決定送到了")
            case .failure(let error):
                let failure = PrimaryCallFailure(error)
                guard failure.remote else { return .retry("連線不穩") }
                guard case .failed(let code, let reasons) = ProjectClassificationBoard.parseRemoteError(failure.code) else {
                    return .retry(failure.code)
                }
                let settled = PrimaryOutboxItem.classificationTerminalReasonCodes.contains(code)
                return .refused(ProjectClassification.userMessage(code: code, reasons: reasons, remoteName: name), terminal: settled)
            }
        case .distillWrite:
            return await withCheckedContinuation { continuation in
                sendQueuedDistill(item) { continuation.resume(returning: $0) }
            }
        }
    }

    /// 記憶提案核准（照 E1：DeviceDispatch.callPrimary 簽章，經 serializedRPC 排成一列）；回 nil＝成功。
    /// 先把這台還沒送出的提案送過去（提案 id 才對得上）。
    private func primaryMemoryDecide(id: String, accept: Bool, isPublic: Bool) async -> PrimaryCallFailure? {
        #if DEBUG
        if let test = primaryOfflineSync?.testMemoryDecide { return await test(id, accept, isPublic) }
        #endif
        return await Task.detached(priority: .userInitiated) { () -> PrimaryCallFailure? in
            UserMemoryStore.shared.flushOutbox()
            do {
                try UserMemoryStore.shared.decide(id: id, accept: accept, isPublic: isPublic)
                return nil
            } catch {
                return PrimaryCallFailure(error)
            }
        }.value
    }

    /// 頂端那行清單上的「取消／移除」：排著的 /蒸餾 寫入走畫布那條（佇列拿掉、畫布一起解鎖），其他直接從佇列拿掉。
    func cancelPrimaryOutboxItem(_ item: PrimaryOutboxItem) {
        if item.kind == .distillWrite, item.refused != true,
           let planID = item.params["planID"].flatMap(UUID.init(uuidString:)),
           let submissionID = item.params["submissionID"].flatMap(UUID.init(uuidString:)) {
            return cancelQueuedDistill(planID, submissionID: submissionID)
        }
        primaryOutbox?.cancel(item.id)
    }

    /// W201：人按重送才再排入原佇列；蒸餾先由原畫布方法驗內容、恢復送出快照。
    /// 已交付的寫入仍不得重播；畫布改過或關掉時留在清單，請使用者重新預覽。
    @discardableResult
    func retryPrimaryOutboxItem(_ item: PrimaryOutboxItem) -> String? {
        guard item.canRetry else { return "這件已處理或已交付；請移除清單項目。" }
        guard let outbox = primaryOutbox, PrimaryOutboxItem.validate(item.kind, item.params),
              outbox.items.contains(where: { $0.id == item.id && $0.kind == item.kind && $0.params == item.params && !$0.isWaiting && $0.handedOver != true }) else { return "這件已處理或已交付；請先查原來的結果。" }
        if item.kind == .distillWrite {
            guard let planID = item.params["planID"].flatMap(UUID.init(uuidString:)),
                  let threadID = item.params["threadID"].flatMap(UUID.init(uuidString:)),
                  let submissionID = item.params["submissionID"].flatMap(UUID.init(uuidString:)),
                  let output = item.params["output"].flatMap(DistillOutputKind.init(rawValue:)),
                  let content = item.params["content"],
                  let plan = try? localLiveForBridge?.loadPlanArtifact(threadID),
                  plan.planID == planID, plan.distillSubmission == nil, DistillCanvas.output(of: plan) == output,
                  let expected = try? Self.queuedDistillPreview(content: content, output: output, planID: planID) else {
                return "畫布已改變或關閉；請到原對話重新預覽，再確認寫入。"
            }
            var snapshot = DistillSubmission(id: submissionID, threadID: threadID, content: content, title: expected.title,
                                             slug: expected.name, gbrain: output == .gbrain, skillet: false, message: "等送出")
            snapshot.output = output; snapshot.targets = []; snapshot.status = "queued"; snapshot.planID = planID
            guard saveDistillSubmission(planID, snapshot) else {
                return "畫布已改變或存不下；請到原對話重新預覽，再確認寫入。"
            }
        }
        guard outbox.enqueue(item.kind, params: item.params, title: item.title, replacing: { $0.id == item.id }) != nil else {
            return "這件的內容無法排入；請回原來的地方重新確認。"
        }
        primaryOfflineTick()
        return nil
    }

    // MARK: 設定清單與頂端處理提示

    /// 主設備的完整佇列，讓使用者在設定 › 設備自行展開；離線與在線都可查看。
    var primaryOfflineDetails: PrimaryOfflineBannerState? {
        guard let link = primaryLinkState() else { return nil }
        let items = primaryOutbox?.items ?? []
        let stretches = assistantOfflineStore?.stretches.filter {
            $0.primaryDeviceID == link.device.id && ($0.state == .open || $0.state == .pending || $0.state == .legacy)
        } ?? []
        return PrimaryOfflineBannerState(name: link.device.displayName, lastSeenAt: link.lastSeenAt,
                                         waiting: items.filter(\.isWaiting), failed: items.filter { !$0.isWaiting },
                                         assistantStretches: stretches.count)
    }
    /// 只排隊與自動接著聊不建立橫條；拒收需要使用者決定，處理完就消失。
    var primaryOfflineBanner: PrimaryOfflineBannerState? {
        guard let state = primaryOfflineDetails, !state.failed.isEmpty else { return nil }
        return state
    }

}
