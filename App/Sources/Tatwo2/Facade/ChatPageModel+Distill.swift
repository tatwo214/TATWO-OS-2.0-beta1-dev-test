import Foundation

/// W180 E4：ChatPageModel 裡 /蒸餾 要記的小狀態（熱檔只留一行 `var distillState`）。
struct DistillModelState {
    /// 遠端畫布開好後重新走一次 send()：這條不再開畫布，直接照一般路徑送出那句。
    var openedRemotely: UUID?
    /// 最近一次遠端讀畫布的序號；舊的回覆不蓋新的。
    var remoteFetch = 0
    var archivedCanvases: [TatwoPlanArtifactV1] = []
    /// 這台是不是副設備、主設備是誰（身分檔讀一次就記著；畫面每次重畫不再讀檔）。
    var isSecondary: Bool?
    var primaryID: String?
    #if DEBUG
    /// 自測：這台寫入的技能根與入口（每個 model 各一份：同一個行程裡的主設備、副設備各用各的）。
    var testRoots: DistillWriterRoots?
    /// 自測：這台當副設備時的主設備（id、名稱；transport 回 nil＝連不上）。
    var testPrimary: (id: String, name: String, transport: @MainActor () -> DistillTransport?)?
    /// 自測：遠端 session 所在的那台（回 nil＝連不上）。
    var testRemote: (@MainActor (_ deviceID: String) -> DistillTransport?)?
    /// 自測：遠端畫布開好後，把那句 /蒸餾 交給遠端引擎（正式版是 send() → RemoteLiveEngine.send → 那台的 send_message）。
    var testRemoteSend: (@MainActor (_ threadID: UUID, _ text: String) -> Void)?
    #endif
}

/// 對另一台（遠端 session 所在的設備，或副設備眼中的主設備）的一次呼叫：RemoteLiveEngine 走已配對設備的 SSH 通道；
/// 自測換成直接交給那一側的 OSAgentBridge（同一套認人、處理、錯誤轉字串）。
typealias DistillTransport = @MainActor (_ method: String, _ params: [String: Any],
                                         _ completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void) -> Void

@MainActor
enum DistillRemoteClient {
    nonisolated static func message(_ error: Error) -> String {
        if case RemoteHostLinkError.remoteError(let detail) = error {
            if ["caller_not_trusted", "unsupported_method"].contains(detail) { return "那台的 TATWO OS 還不支援遠端 /蒸餾（要更新）" }
            if detail.hasPrefix("remote_access_disabled") { return "那台還沒開放已配對設備操作（要先配對）" }
            if detail == "invalid_params" { return "那台不收這個請求（兩台版本可能不同，要更新）" }
            if detail == "distill_busy" || detail == "os_bridge_busy" { return "那台正忙，等一下再試" }
            return detail
        }
        if error is RemoteHostLinkError { return "連線不穩，等一下再試" }
        return error.localizedDescription
    }
}

/// 畫布下方操作區用的動作。本機、遠端 session、副設備交主設備都是這一組；寫入一律在主設備（或單機）執行。
struct DistillCanvasActions {
    /// 寫入在哪一台執行；nil＝這台。
    var executesOn: String?
    /// 現在不能預覽／寫入的原因（例：主設備連不上，連上後再寫入）。
    var blocked: String?
    var setOutput: @MainActor (UUID, DistillOutputKind) -> Void
    var preview: @MainActor (UUID, @escaping @MainActor (Result<DistillWritePlan, Error>) -> Void) -> Void
    var write: @MainActor (UUID, DistillWritePlan, @escaping @MainActor (DistillWriteResult) -> Void) -> Void
    /// 還原（第二個參數：哪一次寫入；nil＝這張畫布的）。
    var restore: @MainActor (UUID, UUID?, @escaping @MainActor (DistillWriteResult) -> Void) -> Void
    /// 寫入沒有確認結果時，到執行寫入的那台再查一次。
    var check: @MainActor (UUID, UUID, @escaping @MainActor (DistillWriteResult) -> Void) -> Void
    /// W182 R5：主設備離線，按「確認寫入」會先排隊（主設備的名字）；連得到、單機、遠端是 nil。
    var queuedOn: String? = nil
    /// W182 R5：取消排著的那次寫入（畫布編號、那次寫入的編號）。
    var cancelQueued: @MainActor (UUID, UUID) -> Void = { _, _ in }
    /// W182 R5：這張畫布上次排隊的寫入，主設備說不能做的原因（沒有是 nil）；「知道了」拿掉這一行。
    var queueFailure: @MainActor (UUID) -> String? = { _ in nil }
    var dismissQueueFailure: @MainActor (UUID) -> Void = { _ in }

    static var unavailable: DistillCanvasActions {
        let refused = DistillWriteResult(status: "failed", lines: ["這裡不能寫入"], archivePath: nil)
        return DistillCanvasActions(executesOn: nil, blocked: "這裡不能寫入", setOutput: { _, _ in },
                                    preview: { _, done in done(.failure(DistillCanvas.Failure(reason: "這裡不能寫入"))) },
                                    write: { _, _, done in done(refused) },
                                    restore: { _, _, done in done(refused) },
                                    check: { _, _, done in done(refused) })
    }
}

extension ChatPageModel {
    /// 這張 /蒸餾 畫布的寫入走哪裡。
    enum DistillRoute {
        /// 這台就是主設備（或單機）：畫布與寫入都在這台。
        case local
        /// 看的是主設備上的 session：畫布在那台，寫入也在那台。
        case remote(DistillTransport, name: String)
        /// 這台是副設備、session 在這台：畫布在這台，寫入交給主設備（主設備再檢查一次）。
        case primary(DistillTransport, name: String)
        /// 現在寫不了（連不上，或 session 在別的副設備上）。
        case blocked(String)
        /// W182 R5：這台是副設備、session 在這台、主設備離線：按確認寫入先排隊，連回後自動送（主設備再預覽檢查一次）。
        case queued(name: String)
    }

    func distillRoute() -> DistillRoute {
        guard !managedAssistantIsLocal else { return .local }
        let primary = distillPrimary()
        if let remote = selectedRemote {
            let name = distillRemoteName(remote.deviceID)
            // 寫入一律在主設備：看的是主設備上的 session 才交那台寫。別台（副設備）上的 session 請到那台按確認寫入，那台會交主設備寫。
            let record = remoteSessions.first { $0.device.id == remote.deviceID }?.device
            let isPrimary = primary.map { $0.id?.lowercased() == remote.deviceID.lowercased() } ?? (record?.role == .primary)
            guard isPrimary else { return .blocked("這條對話在「\(name)」上；寫入要在主設備做，請到「\(name)」按確認寫入（會交給主設備寫）") }
            guard let transport = distillTransport(deviceID: remote.deviceID) else { return .blocked("「\(name)」連不上，連上後再寫入") }
            return .remote(transport, name: name)
        }
        if let primary {
            guard let transport = primary.transport else {
                // W182 R5：主設備在配對清單裡、只是現在離線：先排隊（還沒配對過主設備的照舊停用）。
                if distillQueueAvailable { return .queued(name: primary.name) }
                return .blocked("主設備連不上，連上後再寫入")
            }
            return .primary(transport, name: primary.name)
        }
        return .local
    }

    private func distillRemoteName(_ deviceID: String) -> String {
        remoteSessions.first { $0.device.id == deviceID }?.device.name ?? "遠端設備"
    }

    /// 遠端 session 的畫布在那台：開、讀、改都直接找那台（寫入走哪裡另外看 distillRoute）。
    private func distillCanvasTransport() -> (transport: DistillTransport, name: String)? {
        guard !managedAssistantIsLocal else { return nil }
        guard let remote = selectedRemote, let transport = distillTransport(deviceID: remote.deviceID) else { return nil }
        return (transport, distillRemoteName(remote.deviceID))
    }

    private func distillTransport(deviceID: String) -> DistillTransport? {
        #if DEBUG
        if let test = distillState.testRemote { return test(deviceID) }
        #endif
        guard let remote = remoteSessions.first(where: { $0.device.id == deviceID })?.engine else { return nil }
        return { method, params, completion in remote.distillCall(method, params: params, completion: completion) }
    }

    /// 這台是副設備時的主設備（id、名稱＋連得到時的通道）；主設備、單機是 nil。
    private func distillPrimary() -> (id: String?, name: String, transport: DistillTransport?)? {
        guard !managedAssistantIsLocal else { return nil }
        #if DEBUG
        if let test = distillState.testPrimary { return (test.id, test.name, test.transport()) }
        #endif
        if let device = assistantPrimaryDevice {
            guard let remote = remoteSessions.first(where: { $0.device.id == device.id })?.engine else { return (device.id, device.displayName, nil) }
            return (device.id, device.displayName, { method, params, completion in remote.distillCall(method, params: params, completion: completion) })
        }
        if distillState.isSecondary == nil {
            distillState.primaryID = AssistantPrimaryResolver.primaryDeviceID(environment: ProcessInfo.processInfo.environment)
            distillState.isSecondary = distillState.primaryID != nil
        }
        // 副設備但主設備還沒配對：不寫這台，等連上主設備。
        return distillState.isSecondary == true ? (distillState.primaryID, "主設備", nil) : nil
    }

    /// 這台執行寫入時用的根目錄、設備名與 GBrain。
    var distillHostContext: DistillHostContext {
        var roots = DistillWriterRoots.current()
        #if DEBUG
        if let test = distillState.testRoots { roots = test }
        #endif
        let name = (try? DeviceIdentityStore.readLocal())?.name ?? "這台"
        return DistillHostContext(roots: roots, device: name, gbrainDefinition: {
            guard GBrainService.shared.healthy,
                  let definition = GBrainService.definition(environment: ProcessInfo.processInfo.environment) else { return nil }
            return try? JSONSerialization.data(withJSONObject: definition)
        })
    }

    // MARK: 已配對設備轉進來的請求（OSAgentBridge 在主執行緒呼叫這兩個；寫入本身在 bridge 的背景執行緒跑）

    func distillRemoteBegin(_ request: DistillRemoteRequest) throws -> DistillRemoteReply {
        guard let engine = localLiveForBridge else { throw DistillCanvas.Failure(reason: "這台的 TATWO OS 還沒準備好") }
        // 寫入一律在主設備：這台是副設備就不在這台預覽、寫入或還原（別台看這台的 session 時，請在這台按確認寫入，會交主設備寫）。
        if request.method == "distill_write", request.action != .status, distillPrimary() != nil {
            throw DistillCanvas.Failure(reason: "這台是副設備，不在這台寫入；請在這台的畫布按「確認寫入」，會交給主設備寫")
        }
        let reply = try DistillHost.begin(request, engine: engine, context: distillHostContext)
        if request.canvasAction != nil, selectedRemote == nil, selectedThreadID == request.threadID {
            activePlanArtifact = reply.canvas
            refreshArchivedCanvasList()
        }
        return reply
    }

    func distillRemoteFinish(_ job: DistillWriteJob, _ outcome: DistillWriteOutcome) throws -> DistillRemoteReply {
        guard let engine = localLiveForBridge else { throw DistillCanvas.Failure(reason: "這台的 TATWO OS 還沒準備好") }
        refreshSkillsAfterDistill(job, outcome)
        return try DistillHost.finish(job, outcome, engine: engine)
    }

    private func refreshSkillsAfterDistill(_ job: DistillWriteJob, _ outcome: DistillWriteOutcome) {
        // 技能寫好或還原後重掃技能根，Coder 輸入框打 $ 馬上看得到（或消失）。
        guard job.plan.output == .skill || job.mode == .restore, case .done = outcome else { return }
        // 正在掃的那一輪可能在寫入之前就讀過技能根：等它跑完再掃一次。
        let inFlight = pluginRefreshTask
        Task { @MainActor [weak self] in
            await inFlight?.value
            _ = self?.reloadPluginRegistry()
        }
    }

    // MARK: 送出 /蒸餾

    /// 本機 /蒸餾：開新畫布。上一份還在寫入就不開；上一份已寫入、還能還原的留在新畫布的「之前的寫入」。
    func openLocalDistillCanvas(_ threadID: UUID, argument: String) -> Bool {
        guard let engine = localLiveForBridge else { return false }
        do {
            let plan = try DistillHost.open(engine: engine, threadID: threadID, argument: argument, remote: false)
            if selectedThreadID == threadID { activePlanArtifact = plan }
            return true
        } catch {
            flashComposerHint(error.localizedDescription)
            return false
        }
    }

    func exitRemoteDistillMode() {
        guard let planID = activePlanArtifact?.planID else { return }
        changeRemoteCanvasMode("archive", planID: planID)
    }

    func restoreRemoteDistillCanvas(_ planID: UUID) { changeRemoteCanvasMode("restore", planID: planID) }

    private func changeRemoteCanvasMode(_ action: String, planID: UUID) {
        guard let remote = selectedRemote, let target = distillCanvasTransport() else {
            flashComposerHint("遠端設備連不上；畫布保留，連上後再離開或還原"); return
        }
        var request = DistillRemoteRequest(method: "distill_edit", threadID: remote.threadID, planID: planID)
        request.canvasAction = action
        let draft = prompt
        let tokens = draft.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        let isExitCommand = tokens.count == 2 && ["/plan", "/pr", "/feedback", "/蒸餾"].contains(String(tokens[0]))
            && ["off", "exit", "stop", "關閉", "結束"].contains(tokens[1].lowercased())
        distillCall(target.transport, request) { [weak self] outcome in
            guard let self, self.selectedRemote?.deviceID == remote.deviceID, self.selectedThreadID == remote.threadID else { return }
            switch outcome {
            case .success(let reply):
                self.distillState.remoteFetch += 1
                self.activePlanArtifact = reply.canvas
                if let archives = reply.archives { self.distillState.archivedCanvases = archives }
                if action == "archive", isExitCommand, self.prompt == draft { self.prompt = "" }
                if action == "restore" { self.planInspectorRequest = UUID() }
            case .failure(let error): self.flashComposerHint(DistillRemoteClient.message(error))
            }
        }
    }

    /// send() 的遠端分支：回 true＝畫布已經在那台開好，照一般路徑送出這句；false＝先去開畫布（或開不了），這次到此為止。
    func continueRemoteDistillSend() -> Bool {
        guard let remote = selectedRemote, let id = selectedThreadID else { return false }
        if distillState.openedRemotely == id {
            distillState.openedRemotely = nil
            return true
        }
        guard let target = distillCanvasTransport() else {
            flashComposerHint("遠端設備連不上，連上後再 /蒸餾；草稿留著")
            return false
        }
        let draft = prompt
        let request = DistillRemoteRequest(method: "distill_open", threadID: id, argument: DistillCanvas.argument(in: draft) ?? "")
        distillCall(target.transport, request) { [weak self] outcome in
            guard let self, self.selectedRemote?.deviceID == remote.deviceID, self.selectedThreadID == id else { return }
            switch outcome {
            case .success(let reply):
                self.distillState.remoteFetch += 1   // 比這次早送出的讀取回覆不再蓋掉新畫布
                self.activePlanArtifact = reply.canvas
                if let archives = reply.archives { self.distillState.archivedCanvases = archives }
                self.planInspectorRequest = UUID()
                guard self.prompt == draft else {
                    self.flashComposerHint("畫布已開在「\(target.name)」；草稿改過了，這句先沒送")
                    return
                }
                #if DEBUG
                if let send = self.distillState.testRemoteSend {
                    send(id, draft)
                    self.prompt = ""
                    return
                }
                #endif
                self.distillState.openedRemotely = id
                self.send()
                self.distillState.openedRemotely = nil
            case .failure(let error):
                self.flashComposerHint("/蒸餾 畫布沒開成：\(DistillRemoteClient.message(error))；草稿留著")
            }
        }
        return false
    }

    /// 遠端 session 有更新（RemoteDeviceSession.onUpdate：那台的文件變了，例如 AI 回覆了）：畫布是 /蒸餾 就重讀一次。
    func distillRemoteSessionUpdated(deviceID: String) {
        guard selectedRemote?.deviceID == deviceID, activePlanArtifact?.kind == "distill" else { return }
        refreshRemoteDistillCanvas()
    }

    /// 遠端 session 的畫布：只讀 /蒸餾 那一種（別種畫布在遠端照樣不顯示、不能改）。
    func refreshRemoteDistillCanvas() {
        guard let remote = selectedRemote, let target = distillCanvasTransport() else { return }
        distillState.remoteFetch += 1
        let token = distillState.remoteFetch
        distillCall(target.transport, DistillRemoteRequest(method: "distill_get", threadID: remote.threadID)) { [weak self] outcome in
            guard let self, token == self.distillState.remoteFetch,
                  self.selectedRemote?.deviceID == remote.deviceID, self.selectedRemote?.threadID == remote.threadID,
                  case .success(let reply) = outcome else { return }
            if reply.canvas != self.activePlanArtifact { self.activePlanArtifact = reply.canvas }
            if let archives = reply.archives, archives != self.distillState.archivedCanvases {
                self.objectWillChange.send()
                self.distillState.archivedCanvases = archives
            }
        }
    }

    /// 遠端 session 的 /蒸餾 畫布人手修改：先顯示改好的，那台存不下就換回原本的並說明。
    func saveRemoteDistillText(_ text: String) -> Bool {
        guard let remote = selectedRemote, var plan = activePlanArtifact, plan.kind == "distill", plan.distillSubmission == nil else {
            flashComposerHint("遠端討論串只有 /蒸餾 畫布能改")
            return false
        }
        guard let target = distillCanvasTransport() else {
            flashComposerHint("遠端設備連不上，畫布先不改")
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashComposerHint("畫布不可空白")
            return false
        }
        let previous = plan
        plan.applyEditedText(text)
        activePlanArtifact = plan
        let request = DistillRemoteRequest(method: "distill_edit", threadID: remote.threadID, planID: plan.planID, text: text)
        distillCall(target.transport, request) { [weak self] outcome in
            guard let self, self.selectedRemote?.threadID == remote.threadID else { return }
            switch outcome {
            case .success(let reply):
                self.distillState.remoteFetch += 1
                self.activePlanArtifact = reply.canvas
                if let archives = reply.archives { self.distillState.archivedCanvases = archives }
            case .failure(let error):
                if self.activePlanArtifact?.planID == previous.planID { self.activePlanArtifact = previous }
                self.flashComposerHint("畫布沒存到「\(target.name)」：\(DistillRemoteClient.message(error))")
            }
        }
        return true
    }

    // MARK: 畫布按鈕

    var distillCanvasActions: DistillCanvasActions {
        let route = distillRoute()
        var executesOn: String?
        var blocked: String?
        switch route {
        case .local: break
        case .remote(_, let name): executesOn = "「\(name)」"
        case .primary(_, let name): executesOn = "主設備「\(name)」"
        case .blocked(let reason): blocked = reason
        case .queued: break
        }
        var queuedOn: String?
        if case .queued(let name) = route { queuedOn = name }
        return DistillCanvasActions(
            executesOn: executesOn, blocked: blocked,
            setOutput: { [weak self] id, output in self?.setDistillOutput(id, output) },
            preview: { [weak self] id, done in
                guard let self else { return done(.failure(DistillCanvas.Failure(reason: "畫布已關閉"))) }
                self.previewDistill(id, done)
            },
            write: { [weak self] id, plan, done in
                guard let self else { return done(Self.distillFailed("畫布已關閉")) }
                self.writeDistill(id, plan, done)
            },
            restore: { [weak self] id, submission, done in
                guard let self else { return done(Self.distillFailed("畫布已關閉")) }
                self.restoreDistill(id, submission: submission, done)
            },
            check: { [weak self] id, submission, done in
                guard let self else { return done(Self.distillFailed("畫布已關閉")) }
                self.checkDistill(id, submission: submission, done)
            },
            queuedOn: queuedOn,   // W182 R5
            cancelQueued: { [weak self] id, submission in self?.cancelQueuedDistill(id, submissionID: submission) },
            queueFailure: { [weak self] id in self?.queuedDistillFailure(id)?.reason },
            dismissQueueFailure: { [weak self] id in
                if let failed = self?.queuedDistillFailure(id) { self?.primaryOutbox?.cancel(failed.id) }
            })
    }

    nonisolated static func distillFailed(_ reason: String) -> DistillWriteResult {
        DistillWriteResult(status: "failed", lines: [reason], archivePath: nil)
    }

    nonisolated static func distillUnconfirmed(_ reason: String) -> DistillWriteResult {
        DistillWriteResult(status: "unconfirmed", lines: [reason], archivePath: nil)
    }

    /// 那台回了拒絕（寫之前的檢查沒過）＝沒寫；連線斷掉、沒回應＝不知道寫了沒有，不自動重送。
    nonisolated static func distillFailure(_ error: Error, who: String) -> DistillWriteResult {
        if case RemoteHostLinkError.remoteError = error { return distillFailed(DistillRemoteClient.message(error)) }
        return distillUnconfirmed("\(who)沒有回應；請先查\(who)，不會自動重送")
    }

    /// 寫入或還原送出後，這次回覆還沒有定論（那台先回「寫入中」，或連線斷掉不知道收到沒有）：要再用 status 查。
    nonisolated static func needsFollowUp(_ outcome: Result<DistillRemoteReply, Error>) -> Bool {
        switch outcome {
        case .success(let reply): return reply.result?.pending ?? true
        case .failure(let error):
            if case RemoteHostLinkError.remoteError = error { return false }
            return true
        }
    }

    nonisolated static func writeResult(_ outcome: Result<DistillRemoteReply, Error>, who: String) -> DistillWriteResult {
        switch outcome {
        case .success(let reply): return reply.result ?? distillUnconfirmed("\(who)沒有回結果；請先查\(who)，不會自動重送")
        case .failure(let error): return distillFailure(error, who: who)
        }
    }

    /// 畫布目前的內容（要是這張）。
    private func currentDistill(_ planID: UUID) -> TatwoPlanArtifactV1? {
        guard let plan = activePlanArtifact, plan.planID == planID, plan.kind == "distill" else { return nil }
        return plan
    }

    private static func submissions(_ plan: TatwoPlanArtifactV1) -> [DistillSubmission] {
        [plan.distillSubmission].compactMap { $0 } + (plan.distillEarlier ?? [])
    }

    /// 換「整理成」的類型：只存畫布，不自動送出。
    func setDistillOutput(_ planID: UUID, _ output: DistillOutputKind) {
        guard let plan = currentDistill(planID), plan.distillSubmission == nil else { return }
        let hint = "已改成整理成「\(output.label)」；在對話說「照這個類型重寫」，AI 就會照新格式重寫草稿"
        if selectedRemote != nil {
            guard let target = distillCanvasTransport() else { return flashComposerHint("遠端設備連不上，類型先不改") }
            var changed = plan
            changed.distillOutput = output
            activePlanArtifact = changed
            let request = DistillRemoteRequest(method: "distill_edit", threadID: plan.threadID, planID: planID, output: output)
            distillCall(target.transport, request) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let reply):
                    self.distillState.remoteFetch += 1
                    if self.activePlanArtifact?.planID == planID { self.activePlanArtifact = reply.canvas }
                    if let archives = reply.archives { self.distillState.archivedCanvases = archives }
                    self.flashComposerHint(hint)
                case .failure(let error):
                    if self.activePlanArtifact?.planID == planID { self.activePlanArtifact = plan }
                    self.flashComposerHint("類型沒存到「\(target.name)」：\(DistillRemoteClient.message(error))")
                }
            }
            return
        }
        guard let engine = localLiveForBridge else { return }
        do {
            activePlanArtifact = try DistillHost.edit(engine: engine, threadID: plan.threadID, planID: planID, text: nil, output: output)
            flashComposerHint(hint)
        } catch { flashComposerHint(error.localizedDescription) }
    }

    func previewDistill(_ planID: UUID, _ done: @escaping @MainActor (Result<DistillWritePlan, Error>) -> Void) {
        guard let plan = currentDistill(planID), plan.distillSubmission == nil else {
            return done(.failure(DistillCanvas.Failure(reason: "這張畫布已經寫入過或換了一張")))
        }
        let content = plan.editableText()
        let output = DistillCanvas.output(of: plan)
        switch distillRoute() {
        case .blocked(let reason):
            done(.failure(DistillCanvas.Failure(reason: reason)))
        case .queued:
            done(Result { try Self.queuedDistillPreview(content: content, output: output, planID: planID) })   // W182 R5
        case .local:
            done(Result { try DistillHost.preview(content: content, output: output, planID: planID, context: distillHostContext) })
        case .remote(let transport, _):
            let request = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .preview, content: content)
            distillCall(transport, request) { outcome in done(Self.previewPlan(outcome, who: "那台")) }
        case .primary(let transport, _):
            let request = DistillRemoteRequest(method: "distill_write", planID: planID, output: output, action: .preview, content: content)
            distillCall(transport, request) { outcome in done(Self.previewPlan(outcome, who: "主設備")) }
        }
    }

    nonisolated static func previewPlan(_ outcome: Result<DistillRemoteReply, Error>, who: String) -> Result<DistillWritePlan, Error> {
        switch outcome {
        case .success(let reply):
            if let plan = reply.plan { return .success(plan) }
            return .failure(DistillCanvas.Failure(reason: "\(who)沒有回預覽"))
        case .failure(let error):
            return .failure(DistillCanvas.Failure(reason: DistillRemoteClient.message(error)))
        }
    }

    /// 人按了「確認寫入」：預覽要還是現在這份畫布；先存下送出的快照（界線），才在主設備寫。不自動重送。
    func writeDistill(_ planID: UUID, _ expected: DistillWritePlan, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        guard let plan = currentDistill(planID), plan.distillSubmission == nil else {
            return done(Self.distillFailed("這張畫布已經寫入過或換了一張"))
        }
        let content = plan.editableText()
        guard DistillCanvas.sha256(content) == expected.contentSHA, DistillCanvas.output(of: plan) == expected.output else {
            return done(Self.distillFailed("畫布改過了；請重新預覽"))
        }
        let submissionID = UUID()
        switch distillRoute() {
        case .blocked(let reason):
            done(Self.distillFailed(reason))
        case .queued(let name):
            queueDistillWrite(plan, expected: expected, content: content, submissionID: submissionID, name: name, done)   // W182 R5
        case .local:
            guard let engine = localLiveForBridge else { return done(Self.distillFailed("這台的 TATWO OS 還沒準備好")) }
            let request = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .apply,
                                               content: content, submissionID: submissionID, expected: expected)
            let reply: DistillRemoteReply
            do { reply = try DistillHost.begin(request, engine: engine, context: distillHostContext) }
            catch { return done(Self.distillFailed(error.localizedDescription)) }
            if let canvas = reply.canvas { activePlanArtifact = canvas }
            guard let job = reply.job else { return done(Self.distillFailed("沒有要寫的東西")) }
            runDistillJob(job, engine: engine, done)
        case .remote(let transport, let name):
            let request = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .apply,
                                               content: content, submissionID: submissionID, expected: expected)
            let query = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .status,
                                             submissionID: submissionID)
            sendRemoteDistill(transport, request, query: query, planID: planID, who: "「\(name)」", done)
        case .primary(let transport, let name):
            // 界線存在這台的畫布；主設備寫，結果再存回來。主設備沒回應就留著「未確認」，不自動重送（畫布上可以再查）。
            var snapshot = DistillSubmission(id: submissionID, threadID: plan.threadID, content: content, title: expected.title,
                                             slug: expected.name, gbrain: expected.output == .gbrain, skillet: false,
                                             message: "交給主設備「\(name)」寫入中；若中斷，請先查主設備，不會自動重送。")
            snapshot.output = expected.output
            snapshot.targets = expected.targets
            snapshot.status = "writing"
            snapshot.planID = planID
            guard saveDistillSubmission(planID, snapshot) else { return done(Self.distillFailed("畫布已改變或存不下；沒有寫入")) }
            let request = DistillRemoteRequest(method: "distill_write", planID: planID, output: expected.output, action: .apply,
                                               content: content, submissionID: submissionID, expected: expected,
                                               source: (try? DeviceIdentityStore.readLocal())?.name ?? "副設備")
            let query = DistillRemoteRequest(method: "distill_write", planID: planID, action: .status, submissionID: submissionID)
            sendToPrimaryDistill(transport, request, query: query, threadID: plan.threadID, submissionID: submissionID,
                                 restore: false, done)
        }
    }

    func restoreDistill(_ planID: UUID, submission wanted: UUID?, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        guard let plan = currentDistill(planID),
              let submission = Self.submissions(plan).first(where: { $0.id == (wanted ?? plan.distillSubmission?.id) }),
              submission.status == "done", submission.restoredAt == nil else {
            return done(Self.distillFailed("這張畫布沒有可以還原的寫入"))
        }
        switch distillRoute() {
        case .blocked(let reason):
            done(Self.distillFailed(reason))
        case .queued(let name):
            done(Self.distillFailed("主設備「\(name)」離線；連回後再還原"))   // W182 R5
        case .local:
            guard let engine = localLiveForBridge else { return done(Self.distillFailed("這台的 TATWO OS 還沒準備好")) }
            let request = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .restore,
                                               submissionID: submission.id)
            let reply: DistillRemoteReply
            do { reply = try DistillHost.begin(request, engine: engine, context: distillHostContext) }
            catch { return done(Self.distillFailed(error.localizedDescription)) }
            guard let job = reply.job else { return done(Self.distillFailed("沒有要還原的東西")) }
            runDistillJob(job, engine: engine, done)
        case .remote(let transport, let name):
            let request = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: planID, action: .restore,
                                               submissionID: submission.id)
            let query = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: submission.planID ?? planID,
                                             action: .status, submissionID: submission.id)
            sendRemoteDistill(transport, request, query: query, planID: planID, who: "「\(name)」", done)
        case .primary(let transport, _):
            guard let archive = submission.archivePath else { return done(Self.distillFailed("找不到這次寫入的封存")) }
            let writtenPlan = submission.planID ?? planID
            let request = DistillRemoteRequest(method: "distill_write", planID: writtenPlan, output: submission.output, action: .restore,
                                               submissionID: submission.id, archivePath: archive)
            let query = DistillRemoteRequest(method: "distill_write", planID: writtenPlan, action: .status, submissionID: submission.id)
            sendToPrimaryDistill(transport, request, query: query, threadID: plan.threadID, submissionID: submission.id,
                                 restore: true, done)
        }
    }

    /// 「再查一次」：寫入沒有確認結果時，到執行寫入的那台查這次寫入現在怎樣了（不重送）。
    func checkDistill(_ planID: UUID, submission id: UUID, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        guard let plan = currentDistill(planID), let submission = Self.submissions(plan).first(where: { $0.id == id }) else {
            return done(Self.distillFailed("畫布上找不到這次寫入"))
        }
        guard !DistillHost.inFlight.contains(id) else { return done(DistillWriteResult(status: "writing", lines: ["還在處理中"], archivePath: nil)) }
        switch distillRoute() {
        case .blocked(let reason):
            done(Self.distillFailed(reason))
        case .queued(let name):
            done(Self.distillFailed("主設備「\(name)」離線；連回後再查"))   // W182 R5
        case .local:
            guard let engine = localLiveForBridge else { return done(Self.distillFailed("這台的 TATWO OS 還沒準備好")) }
            let reply = DistillHost.status(submissionID: id, planID: submission.planID ?? planID, threadID: plan.threadID,
                                           engine: engine, roots: distillHostContext.roots)
            done(reply.result ?? Self.distillUnconfirmed("查不到結果"))
        case .remote(let transport, let name):
            let query = DistillRemoteRequest(method: "distill_write", threadID: plan.threadID, planID: submission.planID ?? planID,
                                             action: .status, submissionID: id)
            awaitDistillResult(transport, query, who: "「\(name)」", delay: false) { [weak self] reply, result in
                self?.finishRemoteDistill(planID, reply, result, done)
            }
        case .primary(let transport, _):
            let query = DistillRemoteRequest(method: "distill_write", planID: submission.planID ?? planID, action: .status, submissionID: id)
            awaitDistillResult(transport, query, who: "主設備", delay: false) { [weak self] _, result in
                self?.storeLocalDistillResult(plan.threadID, id, result, restore: result.mode == "restore")
                done(result)
            }
        }
    }

    /// 這台的寫入或還原：檔案與 GBrain 的事在背景做，結果存回畫布。
    private func runDistillJob(_ job: DistillWriteJob, engine: ChatLiveEngine, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { DistillWriter.perform(job) }.value
            do {
                let reply = try DistillHost.finish(job, outcome, engine: engine)
                if let canvas = reply.canvas, self?.activePlanArtifact?.threadID == canvas.threadID { self?.activePlanArtifact = canvas }
                self?.refreshSkillsAfterDistill(job, outcome)
                done(reply.result ?? DistillHost.result(job.mode, outcome))
            } catch {
                done(Self.distillUnconfirmed("結果沒存回畫布：\(error.localizedDescription)；請先查目的地，不會自動重送"))
            }
        }
    }

    /// 看主設備上的 session：寫入、還原交給那台；那台先回「寫入中」或連線斷掉時，照 status 查到有定論為止。
    private func sendRemoteDistill(_ transport: @escaping DistillTransport, _ request: DistillRemoteRequest, query: DistillRemoteRequest,
                                   planID: UUID, who: String, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        distillCall(transport, request) { [weak self] outcome in
            guard let self else { return }
            if case .success(let reply) = outcome, let canvas = reply.canvas, self.activePlanArtifact?.planID == planID {
                self.activePlanArtifact = canvas   // 先顯示「寫入中」
            }
            guard Self.needsFollowUp(outcome) else {
                let reply = try? outcome.get()
                return self.finishRemoteDistill(planID, reply, Self.writeResult(outcome, who: who), done)
            }
            self.awaitDistillResult(transport, query, who: who) { [weak self] reply, result in
                self?.finishRemoteDistill(planID, reply, result, done)
            }
        }
    }

    /// 副設備自己那條：寫入、還原交給主設備（沒有討論串）；結果存回這台的畫布。等待時這次寫入標成進行中（不能被新的 /蒸餾 蓋掉）。
    private func sendToPrimaryDistill(_ transport: @escaping DistillTransport, _ request: DistillRemoteRequest, query: DistillRemoteRequest,
                                      threadID: UUID, submissionID: UUID, restore: Bool,
                                      _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        DistillHost.markInFlight(submissionID)
        let settle: @MainActor (DistillWriteResult) -> Void = { [weak self] result in
            DistillHost.clearInFlight(submissionID)
            self?.storeLocalDistillResult(threadID, submissionID, result, restore: restore)
            done(result)
        }
        distillCall(transport, request) { [weak self] outcome in
            guard let self, Self.needsFollowUp(outcome) else { return settle(Self.writeResult(outcome, who: "主設備")) }
            self.awaitDistillResult(transport, query, who: "主設備") { _, result in settle(result) }
        }
    }

    /// 用 status 查一次寫入或還原的結果，直到有定論或逾時；逾時就留「未確認」（畫布上可以再查一次）。
    /// 那台查不到這次寫入（可能還沒收到）最多等 15 秒。
    private func awaitDistillResult(_ transport: @escaping DistillTransport, _ query: DistillRemoteRequest, who: String, delay: Bool = true,
                                    deadline: Date? = nil, unknownSince: Date? = nil,
                                    _ done: @escaping @MainActor (DistillRemoteReply?, DistillWriteResult) -> Void) {
        let deadline = deadline ?? Date().addingTimeInterval(DistillWire.pollDeadline)
        Task { @MainActor [weak self] in
            if delay { try? await Task.sleep(for: .seconds(DistillWire.pollInterval)) }
            guard let self else { return }
            self.distillCall(transport, query) { [weak self] outcome in
                guard let self else { return }
                var unknown = unknownSince
                switch outcome {
                case .success(let reply):
                    let result = reply.result ?? DistillWriteResult(status: "unknown", lines: ["沒有回結果"], archivePath: nil)
                    guard result.pending else { return done(reply, result) }
                    unknown = result.status == "unknown" ? (unknownSince ?? Date()) : nil
                case .failure(let error):
                    if case RemoteHostLinkError.remoteError = error {
                        return done(nil, Self.distillUnconfirmed("\(who)查不到結果（\(DistillRemoteClient.message(error))）；請先查\(who)，不會自動重送"))
                    }
                }
                let now = Date()
                if now < deadline, unknown.map({ now.timeIntervalSince($0) < 15 }) ?? true {
                    self.awaitDistillResult(transport, query, who: who, deadline: deadline, unknownSince: unknown, done)
                } else {
                    done(nil, Self.distillUnconfirmed("\(who)還沒有回結果；請先查\(who)，不會自動重送（畫布上可以按「再查一次」）"))
                }
            }
        }
    }

    private func finishRemoteDistill(_ planID: UUID, _ reply: DistillRemoteReply?, _ result: DistillWriteResult,
                                     _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        distillState.remoteFetch += 1
        if let canvas = reply?.canvas, activePlanArtifact?.planID == planID || activePlanArtifact?.planID == canvas.planID {
            activePlanArtifact = canvas
        } else {
            refreshRemoteDistillCanvas()
        }
        done(result)
    }

    /// 副設備自己那條的畫布：把主設備回的結果存回來（這張的，或「之前的寫入」那一份）。寫入前就失敗的會把畫布解鎖。
    private func storeLocalDistillResult(_ threadID: UUID, _ submissionID: UUID, _ result: DistillWriteResult, restore: Bool) {
        guard let engine = localLiveForBridge,
              var plan = try? engine.loadPlanArtifact(threadID), plan.kind == "distill" else { return }
        func updated(_ submission: DistillSubmission) -> DistillSubmission? {
            var submission = submission
            switch result.status {
            case "done":
                submission.status = "done"; submission.receiptLines = result.lines
                submission.archivePath = result.archivePath ?? submission.archivePath
                submission.message = result.message
            case "restored":
                submission.status = "restored"
                submission.restoredAt = TatwoPlanArtifactV1.storagePrecision(Date())
                submission.receiptLines = (submission.receiptLines ?? []) + result.lines
                submission.message = result.message
            case "failed":
                if !restore { return nil }   // 寫入前就被擋下：什麼都沒寫，畫布解鎖
            default:
                submission.status = "unconfirmed"; submission.message = result.message
            }
            return submission
        }
        if let current = plan.distillSubmission, current.id == submissionID {
            plan.distillSubmission = updated(current)
            if plan.distillSubmission == nil { plan.state = .discussing }
        } else if let index = plan.distillEarlier?.firstIndex(where: { $0.id == submissionID }) {
            if let next = updated(plan.distillEarlier![index]) { plan.distillEarlier![index] = next }
        } else {
            return
        }
        do {
            try engine.savePlanArtifact(plan)
            if activePlanArtifact?.planID == plan.planID { activePlanArtifact = plan }
        } catch { flashComposerHint("結果沒存回畫布；請先查主設備，不會自動重送") }
    }

    private func distillCall(_ transport: DistillTransport, _ request: DistillRemoteRequest,
                             completion: @escaping @MainActor (Result<DistillRemoteReply, Error>) -> Void) {
        let params: [String: Any]
        do { params = try request.params() } catch { return completion(.failure(error)) }
        transport(request.method, params) { outcome in
            completion(outcome.flatMap { object in Result { try DistillRemoteReply.decode(object) } })
        }
    }

    // MARK: W182 R5：主設備離線時先排隊，連回後自動送

    /// 主設備在配對清單裡、只是現在離線（還沒配對過主設備的不排隊，照舊停用）。
    private var distillQueueAvailable: Bool {
        guard primaryOutbox != nil else { return false }
        #if DEBUG
        if distillState.testPrimary != nil { return true }
        #endif
        return assistantPrimaryDevice != nil
    }

    /// 離線時的預覽：只在這台檢查內容、算出名字（寫到那台哪裡，連回後那台再預覽確認）。
    nonisolated static func queuedDistillPreview(content: String, output: DistillOutputKind, planID: UUID) throws -> DistillWritePlan {
        let problems = DistillCanvas.problems(content, output: output)
        guard problems.isEmpty else { throw DistillCanvas.Failure(reason: problems.joined(separator: "\n")) }
        let title = DistillCanvas.title(for: content)
        let name: String
        switch output {
        case .skill: name = DistillCanvas.skillFrontmatter(content)?.name ?? ""
        case .checklist, .sop: name = DistillCanvas.noteName(for: title, id: planID)
        case .gbrain: name = DistillCanvas.slug(for: title, id: planID)
        }
        return DistillWritePlan(output: output, name: name, title: title, targets: [], contentSHA: DistillCanvas.sha256(content))
    }

    /// 按了「確認寫入」但主設備離線：先把這次寫入存進畫布（標「排隊中」、畫布鎖住），再放進佇列。
    private func queueDistillWrite(_ plan: TatwoPlanArtifactV1, expected: DistillWritePlan, content: String, submissionID: UUID,
                                   name: String, _ done: @escaping @MainActor (DistillWriteResult) -> Void) {
        guard let outbox = primaryOutbox else { return done(Self.distillFailed("主設備連不上，連上後再寫入")) }
        var snapshot = DistillSubmission(id: submissionID, threadID: plan.threadID, content: content, title: expected.title,
                                         slug: expected.name, gbrain: expected.output == .gbrain, skillet: false,
                                         message: "排隊中：連回主設備「\(name)」後會自動送；那台會再預覽檢查一次，有同名舊檔就不寫。")
        snapshot.output = expected.output
        snapshot.targets = []
        snapshot.status = "queued"
        snapshot.planID = plan.planID
        guard saveDistillSubmission(plan.planID, snapshot) else { return done(Self.distillFailed("畫布已改變或存不下；沒有排隊")) }
        guard outbox.enqueueDistillWrite(planID: plan.planID, threadID: plan.threadID, output: expected.output, content: content,
                                         submissionID: submissionID, source: primaryOfflineThisDeviceName(),
                                         title: expected.title) != nil else {
            releaseQueuedDistill(threadID: plan.threadID, submissionID: submissionID, statuses: ["queued"])
            return done(Self.distillFailed("排不進佇列（內容太大或格式不對）；沒有寫入"))
        }
        done(DistillWriteResult(status: "queued", lines: ["連回主設備「\(name)」後會自動送"], archivePath: nil))
    }

    /// 取消排著的那次寫入：從佇列拿掉、畫布解鎖（送出中的取消不了）。
    func cancelQueuedDistill(_ planID: UUID, submissionID: UUID) {
        let item = primaryOutbox?.item(.distillWrite, key: "submissionID", value: submissionID.uuidString)
        if let item {
            guard item.state != .sending else { return flashComposerHint("正在送出，取消不了") }
            primaryOutbox?.cancel(item.id)
        }
        let threadID = activePlanArtifact?.planID == planID ? activePlanArtifact?.threadID
            : item?.params["threadID"].flatMap(UUID.init(uuidString:))
        guard let threadID else { return }
        releaseQueuedDistill(threadID: threadID, submissionID: submissionID, statuses: ["queued"])
    }

    /// 這張畫布上次排隊的寫入被主設備擋下（不能做）的那筆。
    func queuedDistillFailure(_ planID: UUID) -> PrimaryOutboxItem? {
        guard let item = primaryOutbox?.item(.distillWrite, key: "planID", value: planID.uuidString), item.refused == true else { return nil }
        return item
    }

    /// 排著的那次寫入從畫布拿掉（取消、或主設備說不能做）：畫布解鎖，可以改完重來。
    private func releaseQueuedDistill(threadID: UUID, submissionID: UUID, statuses: Set<String>) {
        guard let engine = localLiveForBridge, var plan = try? engine.loadPlanArtifact(threadID), plan.kind == "distill" else { return }
        if let current = plan.distillSubmission, current.id == submissionID, statuses.contains(current.status ?? "") {
            plan.distillSubmission = nil
            plan.state = .discussing
        } else if let index = plan.distillEarlier?.firstIndex(where: { $0.id == submissionID && statuses.contains($0.status ?? "") }) {
            plan.distillEarlier?.remove(at: index)
            if plan.distillEarlier?.isEmpty == true { plan.distillEarlier = nil }
        } else {
            return
        }
        do {
            try engine.savePlanArtifact(plan)
            if activePlanArtifact?.planID == plan.planID { activePlanArtifact = plan }
        } catch { flashComposerHint("畫布存不下；排著的寫入已拿掉") }
    }

    /// 排著的那次寫入交給主設備了：畫布上改成「寫入中」（跟線上按確認寫入同一個樣子）。
    private func markQueuedDistillWriting(threadID: UUID, submissionID: UUID, targets: [DistillTarget], name: String) {
        guard let engine = localLiveForBridge, var plan = try? engine.loadPlanArtifact(threadID), plan.kind == "distill" else { return }
        func mark(_ submission: inout DistillSubmission) {
            submission.status = "writing"
            submission.targets = targets
            submission.message = "交給主設備「\(name)」寫入中；若中斷，請先查主設備，不會自動重送。"
        }
        if plan.distillSubmission?.id == submissionID, var current = plan.distillSubmission {
            mark(&current)
            plan.distillSubmission = current
        } else if let index = plan.distillEarlier?.firstIndex(where: { $0.id == submissionID }), var earlier = plan.distillEarlier?[index] {
            mark(&earlier)
            plan.distillEarlier?[index] = earlier
        } else {
            return
        }
        try? engine.savePlanArtifact(plan)
        if activePlanArtifact?.planID == plan.planID { activePlanArtifact = plan }
    }

    /// 連回主設備後送出排著的 /蒸餾 寫入。先請主設備預覽（跟按「預覽寫入」同一個請求）：檢查沒過、或那邊已經有同名舊檔，
    /// 就不寫（排隊時沒看到那邊的狀況，不替使用者蓋掉舊的），畫布解鎖並說明；過了才照那份預覽寫入，結果存回這台的畫布。
    /// 寫入送出後不自動重送（照 E4：沒回應就留「未確認」，畫布上可以再查一次）。
    func sendQueuedDistill(_ item: PrimaryOutboxItem, completion: @escaping @MainActor (PrimaryOutboxOutcome) -> Void) {
        guard item.kind == .distillWrite, PrimaryOutboxItem.validate(item.kind, item.params),
              let planID = item.params["planID"].flatMap(UUID.init(uuidString:)),
              let threadID = item.params["threadID"].flatMap(UUID.init(uuidString:)),
              let submissionID = item.params["submissionID"].flatMap(UUID.init(uuidString:)),
              let output = item.params["output"].flatMap(DistillOutputKind.init(rawValue:)),
              let content = item.params["content"] else { return completion(.refused("排隊的內容讀不懂，沒有寫入", terminal: true)) }
        guard let primary = distillPrimary(), let transport = primary.transport else { return completion(.retry("主設備還連不上")) }
        let name = primary.name
        let refuse: @MainActor (String) -> Void = { [weak self] reason in
            self?.releaseQueuedDistill(threadID: threadID, submissionID: submissionID, statuses: ["queued", "writing"])
            completion(.refused(reason))
        }
        let preview = DistillRemoteRequest(method: "distill_write", planID: planID, output: output, action: .preview, content: content)
        distillCall(transport, preview) { [weak self] outcome in
            guard let self else { return completion(.retry("畫布已關閉")) }
            let fresh: DistillWritePlan
            switch outcome {
            case .failure(let error):
                guard PrimaryCallFailure(error).remote else { return completion(.retry(DistillRemoteClient.message(error))) }
                return refuse("「\(name)」沒收下這份：\(DistillRemoteClient.message(error))")
            case .success(let reply):
                guard let plan = reply.plan else { return completion(.retry("「\(name)」沒有回預覽")) }
                fresh = plan
            }
            guard fresh.contentSHA == DistillCanvas.sha256(content), fresh.output == output else {
                return refuse("「\(name)」預覽出來的內容對不上；沒有寫入，請重新預覽")
            }
            guard !fresh.targets.contains(where: { $0.action == .replace }) else {
                return refuse("「\(name)」上已經有同名的\(output == .skill ? "技能" : "筆記")；排隊時看不到那邊，這份先沒寫（不蓋掉舊的）。"
                              + "請在畫布重新預覽後再按確認寫入。")
            }
            self.primaryOutbox?.markHandedOver(item.id)
            self.markQueuedDistillWriting(threadID: threadID, submissionID: submissionID, targets: fresh.targets, name: name)
            let apply = DistillRemoteRequest(method: "distill_write", planID: planID, output: output, action: .apply, content: content,
                                             submissionID: submissionID, expected: fresh, source: item.params["source"])
            let query = DistillRemoteRequest(method: "distill_write", planID: planID, action: .status, submissionID: submissionID)
            self.sendToPrimaryDistill(transport, apply, query: query, threadID: threadID, submissionID: submissionID,
                                      restore: false) { result in
                switch result.status {
                case "done": completion(.sent("/蒸餾 寫到「\(name)」了：\(fresh.title)"))
                case "failed": refuse("「\(name)」沒寫入：\(result.message)")
                default: completion(.sent("/蒸餾 交給「\(name)」寫了，還沒確認結果；畫布上可以按「再查一次」"))
                }
            }
        }
    }
}
