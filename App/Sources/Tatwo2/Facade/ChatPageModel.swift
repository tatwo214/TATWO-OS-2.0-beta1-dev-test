// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift；只保留 chat 畫面 Binding 欄位與本地假資料入口
import SwiftUI
import AppKit
import Combine


@MainActor
final class ChatPageModel: ObservableObject {
    struct SlashCommandItem: Identifiable, Hashable {
        let id: String
        let cmd: String
        let title: String
        let subtitle: String
        let icon: String
    }
    let authorityBootstrapModel = TatwoAppAuthorityBootstrapModel()
    let remoteBorrowAuthorizationStore = TatwoRemoteBorrowAuthorizationStore.default()
    let assistantTranscriptCache = TatwoAssistantTranscriptCache()
    private let fixture: ChatFixture
    /// 金樣專用：某些場景要在固定劇本後面多幾則（打字中、錯誤卡），不動 ChatFixture 本體。
    private var fixtureExtraMessages: [ChatMessage] = []
    private let runtimeEnvironment: [String: String]
    private let engineLogin: EngineLogin
    private var engineLoginCheckedAt: [ClaudeSidecar.Kind: Date] = [:]
    private var engineLoginRefreshInFlight = false
    private let deviceRegistry: DeviceRegistry
    private let devicePairingHost: DevicePairingHost
    private let githubAccountsStore: GitHubAccountsStore
    /// 真水電：沒有匯出／假資料環境變數時走 live（Claude sidecar）；有就走 1.0 金樣假資料。
    let isLive: Bool
    private(set) var live: (any LiveEngineAPI)?
    private var localLive: ChatLiveEngine?
    /// W179 F：接在主設備時這次在選單選的模型（只在記憶體；下一句帶過去，主設備收到後記在那條）。
    private(set) var assistantPrimaryModelChoice: String?
    /// W179 F：身分檔讀一次就記著（nil＝還沒讀）；配對清單變動時重讀。
    private var resolvedAssistantPrimaryID: String??
    private var assistantPrimaryID: String? {
        if let resolvedAssistantPrimaryID { return resolvedAssistantPrimaryID }
        let id = AssistantPrimaryResolver.primaryDeviceID(environment: runtimeEnvironment)
        resolvedAssistantPrimaryID = .some(id)
        return id
    }
    /// W179 F：送到主設備、還在等主設備回覆收到的討論串（這段時間不再送、草稿留著）。
    @Published private(set) var primaryDeliveries: Set<UUID> = []
    /// W179 F：接主設備時的一行提示（送到主設備沒成功、主設備連線的提示）；threadID nil＝不分哪條。
    @Published private var primaryHint: AssistantPrimaryHint?
    /// W179 F：這次 App 開著以來，第一次連主設備已經有結果（連上或連不上）的設備 id；之後的重試不算「連線中」。
    private var assistantPrimarySettledIDs: Set<String> = []
    #if DEBUG
    /// 自測用：假的主設備（不連 SSH）；engine 回 nil＝現在連不上，connecting 回 true＝正在連。
    var assistantPrimaryTestDouble: (device: AssistantPrimaryDevice, engine: () -> (any AssistantRemoteEngine)?,
                                     connecting: () -> Bool)?
    /// W180 自測用：其他配對設備的假遠端（不連 SSH），規則同上。
    var dmRemoteDeviceTestDoubles: [(device: AssistantPrimaryDevice, engine: () -> (any AssistantRemoteEngine)?,
                                     connecting: () -> Bool)] = []
    /// W180 自測用：私訊框對本機助理／本機 session 送出時，在選引擎與登入檢查之前換成記錄替身（不啟動引擎、不燒額度）；
    /// 驗附件路徑真的交到送出這一步。回傳是否收下。
    var dmLocalSendTestDouble: ((_ threadID: UUID, _ text: String, _ attachments: [String]) -> Bool)?
    /// W184 H4 修正（審查 #10）：自測當作這幾家已登入，好讓 Coder 的 send() 與私訊框的 sendFromDM 真的走到引擎——引擎程式由自測換成
    /// 只記下收到什麼的替身腳本（sidecarPath 覆寫），不啟動真的引擎、不燒額度；抓「實際送出的參數」用。
    var assistantEngineSendTestDouble: ((String, String) -> Bool)?
    var catalogRefreshTestDouble: (() -> Void)?
    var loginRefreshTestDouble: (() -> [EngineLoginStatus])?
    private(set) var loginRefreshStartsForSelfTest = 0
    private(set) var catalogRefreshStartsForSelfTest = 0
    var engineLoginTestDouble: Set<ClaudeSidecar.Kind>?
    var chatGPTTapConnectionTestDouble: (() -> TapConnection)?
    var chatGPTTapWakeTestDouble: (() -> Void)?
    private(set) var sendLoginChecks: [ClaudeSidecar.Kind] = []
    func sendLoginStatusForSelfTest(_ kind: ClaudeSidecar.Kind) -> EngineLoginStatus { sendLoginStatus(kind) }
    func completeEngineLoginForSelfTest(_ status: EngineLoginStatus) { completeEngineLogin(status) }
    func seedSendLoginStatusForSelfTest(_ status: EngineLoginStatus, checkedAt: Date) {
        replaceEngineLoginStatus(status)
        engineLoginCheckedAt[status.kind] = checkedAt
    }
    #endif
    /// Coder 送出與私訊框送出的登入檢查（W184 H4 修正：自測替身在這裡接上，其他照舊）。
    private func sendLoginStatus(_ kind: ClaudeSidecar.Kind) -> EngineLoginStatus {
        #if DEBUG
        sendLoginChecks.append(kind)
        if engineLoginTestDouble?.contains(kind) == true {
            return EngineLoginStatus(kind: kind, isLoggedIn: true, account: nil, detail: "self-test double")
        }
        #endif
        if let checked = engineLoginCheckedAt[kind], Date().timeIntervalSince(checked) >= 0,
           Date().timeIntervalSince(checked) < 60, let cached = engineLogins.first(where: { $0.kind == kind }) {
            return cached
        }
        refreshEngineLogins()
        if let checked = engineLoginCheckedAt[kind], Date().timeIntervalSince(checked) >= 0,
           Date().timeIntervalSince(checked) < 60, let cached = engineLogins.first(where: { $0.kind == kind }) {
            return cached
        }
        // Unknown or expired login must not block the send: the check runs in the background, so refusing here
        // bounced the first message after a minute idle. The engine's own rejection settles delivery, restores the
        // draft and now carries the 登入 exit (EngineFailurePresentation).
        return EngineLoginStatus(kind: kind, isLoggedIn: true, account: nil, detail: "登入狀態待引擎確認")
    }
    /// W180 D2：私訊框看過的別台 session 在哪一台（只在記憶體）；那台連不上時說明與保留對象用。
    private var dmKnownDeviceIDs: [UUID: String] = [:]
    /// W180 A4：私訊框對別台上的對話這次在選單選的模型（只在記憶體；下一句帶過去，那台收到後記在那條）。
    private(set) var dmRemoteModelChoices: [UUID: String] = [:]
    // Shared identity for TATWO Space and the later DM surface; never a selection.
    var assistantThreadID: UUID? { localLive?.doc.assistantThreadID }
    /// W180 D3：助理頁現在顯示的那串訊息屬於哪條（本機那條，或接主設備時主設備那條）。
    var assistantTranscriptThreadID: UUID? {
        switch assistantPlacement {
        case .primary(_, let id, _): return id
        case .unreachable: return nil
        case .local: return assistantThreadID
        }
    }
    @Published var assistantPrompt = ""
    var assistantMessages: [ChatMessage] {
        switch assistantPlacement {
        case .primary(let remote, let id, _): return Self.primaryTranscript(remote, id)
        case .unreachable: return []
        case .local: return localLive?.transcript(for: assistantThreadID) ?? []
        }
    }
    /// 主設備那條的逐字稿還在第一次拉（手上什麼都沒有）：畫面顯示「連線中…」，不顯示空白的歡迎畫面。
    var assistantTranscriptLoading: Bool {
        guard case .primary(let remote, let id, _) = assistantPlacement else { return false }
        return remote.isTranscriptLoading(id) && Self.primaryTranscript(remote, id).isEmpty
    }
    /// 送到主設備那句還在等主設備回覆收到。
    var assistantIsDelivering: Bool {
        if case .primary(_, let id, _) = assistantPlacement { return primaryDeliveries.contains(id) || assistantOfflineHolding }   // W182 R5
        return false
    }
    var assistantIsRunning: Bool {
        switch assistantPlacement {
        case .primary(let remote, let id, _): return remote.isRunning(id)
        case .unreachable: return false
        case .local: return localLive?.isRunning(assistantThreadID) ?? false
        }
    }
    /// W179 F：接到主設備時＝這次在選單選的 → 那條記住的；本機＝跳過被停用引擎挑出來的
    /// （三家都停用時退回原本的選擇，送出由引擎擋下並說明，主設備與單機行為不變）。
    var assistantRouteChoice: ChatRouteChoice {
        if case .primary(let remote, let id, let device) = assistantPlacement,
           let route = (assistantPrimaryModelChoice ?? remote.threadRecord(id)?.requestedModel ?? remote.threadRecord(id)?.model).map({ ChatRouteChoice.resolve($0, deviceID: device.id) }) {
            return route
        }
        if let route = assistantLocalRoute { return route }
        let stored = localLive?.threadRecord(assistantThreadID)?.requestedModel
        return ChatRouteChoice.resolve(stored ?? UltraworkRoleConfigurationStore().load().primaryModelID)
    }

    func setAssistantModel(_ modelID: String) {
        let route = ChatRouteChoice.resolve(modelID)
        if case .primary(let remote, let id, _) = assistantPlacement {
            // 主設備那條：下一句把這個模型帶過去，主設備收到後記在那條；不套本機的停用判斷。
            guard !remote.isRunning(id), AssistantModelRouting.engineKind(for: route) != nil else { return }
            assistantPrimaryModelChoice = route.id
            recordAssistantModelSelection(threadID: id)
            objectWillChange.send()
            return
        }
        guard let id = assistantThreadID, let engine = localLive, !engine.isRunning(id),
              let kind = AssistantModelRouting.engineKind(for: route), !isEngineDisabled(kind) else { return }
        engine.setModelPreferences(threadID: id, model: route.id,
            effort: reasoningAfterModelSwitch(route, stored: engine.threadRecord(id)?.requestedEffort),
            speedTier: (route.defaultSpeedTier ?? .fast).rawValue)
        recordAssistantModelSelection(threadID: id)
        objectWillChange.send()
    }

    /// Explicit target, local engine, and thread-owned preferences: no Coder/remote selection is read or changed.
    /// W179 F：回 true＝送出了（本機）或正送往主設備；`onDelivered` 在真的送到時跑一次（本機馬上跑，主設備等它回覆收到），
    /// 呼叫端在那時才清草稿。
    /// W180 D2：attachments＝本機檔案路徑（私訊框的附件）；只有本機那條收得下，接在主設備時不送（「＋」已停用並說明）。
    @discardableResult
    func sendToAssistant(text: String, attachments: [String] = [],
                         onDelivered: @escaping @MainActor () -> Void = {},
                         onUndelivered: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        guard Self.dmCoderOnlyCommand(in: text) == nil else { return false }
        if !attachments.isEmpty, !assistantAcceptsAttachments { return false }
        // W179 F：副設備連得到主設備就交給主設備那條；接不到（連線中、連不上且本機全停用）時不送（畫面有一行說明、草稿留著）。
        switch assistantPlacement {
        case .primary(let remote, let primaryThreadID, let device):
            if assistantOfflineMergeOutstanding(device) {   // W182 R5：剛才離線那段先補回主設備那條，補完再送這句（時序才對）
                return assistantOfflineDeliverAfterMerge(device) { [weak self] in
                    _ = self?.sendToAssistant(text: text, attachments: attachments, onDelivered: onDelivered)
                }
            }
            return sendToPrimaryAssistant(remote, threadID: primaryThreadID, device: device, text: text,
                                          onDelivered: onDelivered)
        case .unreachable:
            return false
        case .local:
            let offlineTurn = assistantOfflineBeginTurn()   // W182 R5：主設備離線時在這台接著聊（這段第一句帶前情）
            let accepted = sendToLocalAssistant(text: text, attachments: attachments, onUndelivered: onUndelivered)
            assistantOfflineEndTurn(offlineTurn, accepted: accepted)   // W182 R5
            if accepted { onDelivered() }
            return accepted
        }
    }

    /// 本機那條助理：這台自己挑模型（跳過這台停用的引擎）、登入檢查、人設。主設備收到副設備交來的一句也走這裡。
    private func sendToLocalAssistant(text: String, attachments: [String] = [],
                                      onUndelivered: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        guard let id = assistantThreadID, let engine = localLive, !engine.store.isReadOnly,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              !engine.isRunning(id) else { return false }
        #if DEBUG
        if let dmLocalSendTestDouble { return dmLocalSendTestDouble(id, text, attachments) }
        #endif
        let route = assistantRouteChoice
        let kind: ClaudeSidecar.Kind
        switch route.brandGroup {
        case .anthropic: kind = .claude
        case .openAI: kind = .codex
        case .xAI: kind = .grok
        default:
            engine.appendSystemMessage(threadID: id, text: "這個模型還沒有接上引擎，請選其他模型。", status: "error|引擎")
            return false
        }
        let status = sendLoginStatus(kind)
        guard status.isLoggedIn else {
            engine.appendSystemMessage(threadID: id,
                text: "這句沒有送出：\(engineLoginDisplayName(kind)) 還沒登入，到設定 › 登入。",
                status: "error|登入")
            objectWillChange.send()
            return false
        }
        #if DEBUG
        if let assistantEngineSendTestDouble { return assistantEngineSendTestDouble(text, route.id) }
        #endif
        let modelArgument: String?
        switch kind {
        case .claude: modelArgument = route.modelArgument
        case .codex: modelArgument = route.modelArgument ?? route.canonicalModelSlug
        case .grok: modelArgument = route.modelArgument
        }
        engine.autoApprove = permissionPreset == .approveForMe
        engine.userPermissionPreset = permissionPreset
        let record = engine.threadRecord(id)
        // W184 H4 修正第三輪：私訊框按下就清草稿（照舊）；引擎後來說沒送到／不確定，交回呼叫端照同一套放回（onUndelivered）。
        let accepted = engine.send(threadID: id, text: text, model: modelArgument, engine: kind, systemPrompt: nil,
            attachments: attachments,
            reasoningEffort: kind == .codex ? record?.requestedEffort ?? route.defaultEffort.codexRawValue : nil,
            serviceTier: kind == .codex
                ? (record?.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))
                    ?? route.defaultSpeedTier)?.appServerValue : nil,
            ultrawork: nil) { outcome in
                if let message = Self.undeliveredMessage(outcome) { onUndelivered(message) }
            }
        objectWillChange.send()
        return accepted
    }

    /// W184 H4 修正第三輪：沒送到／不確定時說的那一句（Coder 抽屜、私訊框提示同一套字）；送到了＝nil。
    static func undeliveredMessage(_ outcome: LiveSendDelivery) -> String? {
        switch outcome {
        case .delivered: return nil
        case .notDelivered(let reason): return "這句沒送到：\(reason)；草稿留在輸入框，可以再送一次"
        case .unknown(let reason): return "不確定這句有沒有送到（\(reason)）；草稿留著，先看對話再決定要不要重送"
        }
    }

    func sendAssistantDraft() {
        let text = assistantPrompt
        // 送到了才清；送到主設備的要等它回覆收到，這段時間草稿被改過就不動。
        sendToAssistant(text: text) { [weak self] in
            if self?.assistantPrompt == text { self?.assistantPrompt = "" }
        }
    }

    func stopAssistant() {
        switch assistantPlacement {
        case .primary(let remote, let id, _):
            remote.stop(threadID: id)
        case .unreachable:
            return
        case .local:
            guard let id = assistantThreadID else { return }
            localLive?.stop(threadID: id)
        }
        objectWillChange.send()
    }

    // MARK: - W179 F 助理住在主設備

    /// 這台是副設備、主設備在配對清單裡時的主設備；主設備、單機或沒配對過是 nil（行為不變）。
    var assistantPrimaryDevice: AssistantPrimaryDevice? {
        #if DEBUG
        if let assistantPrimaryTestDouble { return assistantPrimaryTestDouble.device }
        #endif
        guard isLive, let primaryID = assistantPrimaryID,
              let record = AssistantPrimaryResolver.device(primaryID: primaryID, in: remoteSessions.map(\.device))
        else { return nil }
        return AssistantPrimaryDevice(id: record.id, displayName: record.name)
    }

    /// 主設備現在連得到時的遠端引擎（跟 Coder 看遠端設備用的是同一條連線）；連不上是 nil。
    private var assistantPrimaryEngine: (any AssistantRemoteEngine)? {
        #if DEBUG
        if let assistantPrimaryTestDouble { return assistantPrimaryTestDouble.engine() }
        #endif
        guard let device = assistantPrimaryDevice else { return nil }
        return remoteSessions.first { $0.device.id == device.id }?.engine
    }

    /// 正在連主設備：App 開著以來第一次連還沒結果；本機也全停用時，之後每次重試也算（說明寫「正在連」比「連不上」準）。
    /// 已經連上（有遠端引擎）就不是。
    private var assistantPrimaryConnecting: Bool {
        #if DEBUG
        if let assistantPrimaryTestDouble { return assistantPrimaryTestDouble.connecting() }
        #endif
        guard let device = assistantPrimaryDevice,
              let session = remoteSessions.first(where: { $0.device.id == device.id }),
              session.engine == nil, session.state == .connecting else { return false }
        return !assistantPrimarySettledIDs.contains(device.id) || !assistantLocalFallbackAllowed   // W181 R3
    }

    /// 副設備這一刻接不到主設備那條助理的原因；接得到（或不是副設備）是 nil。
    private var assistantPrimaryGap: AssistantPrimaryGap? {
        guard assistantPrimaryDevice != nil else { return nil }
        if let remote = assistantPrimaryEngine { return remote.doc.assistantThreadID == nil ? .noAssistant : nil }
        return assistantPrimaryConnecting ? .connecting : .offline
    }

    /// 這一刻助理接在哪：主設備那條、本機那條，或接不到（連線中；或連不上而本機也全停用）。
    var assistantPlacement: AssistantPlacement {
        guard let device = assistantPrimaryDevice else { return .local }
        // 先前退回本機時送的那輪還在跑：跑完才切，停止鈕才不會不見。
        if localLive?.isRunning(assistantThreadID) == true { return .local }
        if let remote = assistantPrimaryEngine, let id = remote.doc.assistantThreadID {
            return .primary(engine: remote, threadID: id, device: device)
        }
        let gap = assistantPrimaryGap ?? .offline
        // 正在連線不退回本機那條（連上後同一段對話才不會分成兩條）。
        if gap == .connecting { return .unreachable(device, gap) }
        return assistantLocalFallbackAllowed ? .local : .unreachable(device, gap)   // W181 R3
    }

    /// W181（使用者 09-27：「這台為何不跑模型 這樣我mini關掉或當機怎麼辦」＋裁決「只是不想被 API 按量扣錢」）：
    /// 副設備的助理平常住主設備（W179 F 不變）；主設備連不上時，這台只要有送得出去的模型（訂閱登入）就退回本機接著回。
    private var assistantLocalFallbackAllowed: Bool {
        AssistantModelRouting.pick(stored: localLive?.threadRecord(assistantThreadID)?.requestedModel,
                                   lead: UltraworkRoleConfigurationStore().load().primaryModelID,
                                   coder: selectedModel, isDisabled: { self.isEngineDisabled($0) }) != nil
    }

    /// 本機跑助理時挑的路由（跳過被停用的引擎）；三家都停用是 nil。
    private var assistantLocalRoute: ChatRouteChoice? {
        AssistantModelRouting.pick(stored: localLive?.threadRecord(assistantThreadID)?.requestedModel,
                                   lead: UltraworkRoleConfigurationStore().load().primaryModelID,
                                   coder: selectedModel, isDisabled: { self.isEngineDisabled($0) })
    }

    var assistantCanSend: Bool {
        switch assistantPlacement {
        case .primary(_, let id, _): return !primaryDeliveries.contains(id) && !assistantOfflineHolding   // W182 R5
        case .unreachable: return false
        case .local: return assistantThreadID != nil && localConversationReadOnlyNotice == nil
        }
    }

    /// W201：助理真的不能送出時，在輸入框位置說明；本機能接著聊與自動重連不報備。
    var assistantPlacementNote: String? {
        switch assistantPlacement {
        case .unreachable(let device, let gap): return AssistantPlacement.unreachableNote(device, gap)
        case .local:
            if let notice = localConversationReadOnlyNotice { return notice }
            // W201：本機能接著聊時不報備設備狀態；送不到的錯誤仍走原本的 hint。
            return nil
        case .primary: return assistantPrimaryHint == nil ? assistantOfflineLine : nil
        }
    }

    /// 接著主設備時送出失敗的提示；草稿留著，不與補回失敗重複顯示。
    var assistantPrimaryHint: String? {
        guard case .primary(_, let id, _) = assistantPlacement else { return nil }
        return primaryHintText(for: id)
    }

    /// 助理正接在主設備那條時，主設備的名字（畫面標「在主設備上」用）。
    var assistantPrimaryName: String? {
        if case .primary(_, _, let device) = assistantPlacement { return device.displayName }
        return nil
    }

    /// 玻璃 chip 上的模型名；接在主設備、那條又沒記過模型時交給主設備決定。
    var assistantModelChipTitle: String {
        if case .primary(let remote, let id, _) = assistantPlacement, assistantPrimaryModelChoice == nil,
           AssistantModelRouting.storedRoute(remote.threadRecord(id)) == nil {
            return "主設備預設"
        }
        return AssistantModelRouting.chipName(assistantRouteChoice)
    }

    /// 助理的模型選單：本機跑時被停用的引擎標「已停用」不能選；接在主設備時交給主設備判斷。
    var assistantModelOptions: [AssistantModelOption] {
        let placement = assistantPlacement
        let selectedID: String?
        if case .primary(let remote, let id, _) = placement {
            selectedID = assistantPrimaryModelChoice ?? AssistantModelRouting.storedRoute(remote.threadRecord(id))?.id
        } else {
            selectedID = assistantRouteChoice.id
        }
        let checksLocal = !placement.isPrimary
        let deviceID: String
        if case .primary(_, _, let device) = placement { deviceID = device.id } else { deviceID = "local" }
        return AssistantModelRouting.options(selectedID: selectedID, deviceID: deviceID,
                                             isDisabled: { checksLocal && self.isEngineDisabled($0) }).map { option in
            guard checksLocal, let kind = AssistantModelRouting.engineKind(for: option.route),
                  !self.engineLogins.contains(where: { $0.kind == kind && $0.isLoggedIn }) else { return option }
            return AssistantModelOption(route: option.route, title: option.title + " · 未登入",
                                        isDisabled: option.isDisabled, isSelected: option.isSelected)
        }
    }

    /// 副設備把這句交給主設備那條助理討論串（跟 Coder 看遠端設備時一樣走遠端引擎）；人設由主設備帶。
    /// 只有這次在選單明確選的模型才帶（連同引擎與路由 id）；沒選就都不帶，主設備照自己的助理規則挑
    /// （那條存的 → 主導 → Coder → 第一個沒停用的，跳過主設備停用的引擎）。不套本機停用判斷，Coder 的選取不讀不寫。
    private func sendToPrimaryAssistant(_ remote: any AssistantRemoteEngine, threadID: UUID,
                                        device: AssistantPrimaryDevice, text: String,
                                        onDelivered: @escaping @MainActor () -> Void) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !remote.isRunning(threadID),
              !primaryDeliveries.contains(threadID) else { return false }
        let choice = assistantPrimaryModelChoice.map(ChatRouteChoice.resolve)
        let turn = AssistantModelRouting.primaryTurn(choice: choice)
        deliverToPrimary(remote, device: device, threadID: threadID, text: text, model: turn.model, engine: turn.kind,
                         assistantRoute: choice?.id, onDelivered: onDelivered)
        return true
    }

    /// 送到主設備：等主設備回覆收到才算送到（`onDelivered`，呼叫端這時才清草稿）；這段時間那條標成送出中、不再送。
    /// 沒送到就不清草稿，在助理／私訊框顯示一行白話說明。
    /// W180 D2：onPrimary＝false 時是其他配對設備（私訊框的 session），說明裡不稱「主設備」。
    private func deliverToPrimary(_ remote: any AssistantRemoteEngine, device: AssistantPrimaryDevice, threadID: UUID,
                                  text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                                  onPrimary: Bool = true, onDelivered: @escaping @MainActor () -> Void) {
        primaryDeliveries.insert(threadID)
        if primaryHint?.threadID == nil || primaryHint?.threadID == threadID { primaryHint = nil }
        remote.deliver(threadID: threadID, text: text, model: model, engine: engine, assistantRoute: assistantRoute) {
            [weak self] result in
            guard let self else { return }
            self.primaryDeliveries.remove(threadID)
            switch result {
            case .success:
                onDelivered()
            case .failure(let error):
                let note = AssistantPlacement.deliveryFailureNote(error, device: device)
                self.showPrimaryHint(onPrimary ? note : note.replacingOccurrences(of: "主設備「", with: "「"),
                                     threadID: threadID)
            }
        }
    }

    /// 接主設備時的提示：送出失敗的留到下一次送出；連線類（不分哪條）的 12 秒後自己收掉。
    private func showPrimaryHint(_ text: String, threadID: UUID?) {
        let hint = AssistantPrimaryHint(threadID: threadID, text: text)
        primaryHint = hint
        guard threadID == nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.primaryHint == hint { self?.primaryHint = nil }
        }
    }

    private func primaryHintText(for threadID: UUID) -> String? {
        guard let hint = primaryHint, hint.threadID == nil || hint.threadID == threadID else { return nil }
        return hint.text
    }

    /// 主設備那條的逐字稿：遠端快取換版後還在重拉時，先用文件快照裡帶的訊息（get_document 本來就帶），不閃回空白。
    static func primaryTranscript(_ remote: any AssistantRemoteEngine, _ threadID: UUID) -> [ChatMessage] {
        let cached = remote.transcript(for: threadID)
        if !cached.isEmpty { return cached }
        return remote.threadRecord(threadID)?.messages.map(\.chatMessage) ?? []
    }

    /// W179 F（主設備這一側）：副設備把一句交給這台的助理那條（OS bridge 的 send_message）。照這台自己的助理規則送：
    /// 模型依序＝那條存的 → 主導 → Coder → 第一個沒停用的（跳過這台停用的引擎），登入檢查、人設都一樣。
    /// routeID＝副設備在選單明確選的路由（記在那條，之後照它；這台停用了那家就拒收）。回 nil＝送出了；否則是原因代碼。
    func receiveAssistantTurnFromSecondary(threadID: UUID, text: String, routeID: String?) -> String? {
        guard let id = assistantThreadID, id == threadID, let engine = localLive else { return "assistant_unavailable" }
        guard !engine.isRunning(id) else { return "assistant_busy" }
        if let routeID {
            // 遠端帶來的 id 不認得就拒收（resolve 會把未知 id 變成「Unavailable」路由，不能當成可用）。
            guard let route = ChatRouteChoice.resolveOrNil(routeID),
                  let kind = AssistantModelRouting.engineKind(for: route) else { return "assistant_model_unknown" }
            guard !isEngineDisabled(kind) else { return "assistant_engine_disabled" }
            engine.setModelPreferences(threadID: id, model: route.id,
                effort: reasoningAfterModelSwitch(route, stored: engine.threadRecord(id)?.requestedEffort),
                speedTier: (route.defaultSpeedTier ?? .fast).rawValue)
        }
        guard assistantLocalRoute != nil else { return "assistant_engines_disabled" }
        return sendToLocalAssistant(text: text) ? nil : "assistant_not_sent"
    }

    /// W179 私訊框的 Coder 對話清單：本機、未封存、不是助理、不是派到遠端設備的房間；W180 D2：子討論串也列（掛在父 session 下面）。
    /// W179 F／W180 D2：也列每一台連得到的配對設備上的討論串（標設備名，主設備在前）。依最後活動排序（新的在前）；
    /// 同名的補時間（整份清單先分辨再截最近幾條，最近清單和框頂標題才一致）。
    func dmSessionCandidates(limit: Int? = nil) -> [GlobalDMSessionCandidate] {
        guard let doc = localLive?.doc else { return [] }
        let local = Self.dmCandidates(in: doc, deviceName: nil)
        var seen = Set(local.map(\.id))
        var remote: [GlobalDMSessionCandidate] = []
        for device in dmRemoteDevices {
            guard let engine = device.engine else { continue }
            for row in Self.dmCandidates(in: engine.doc, deviceName: device.device.displayName) where !seen.contains(row.id) {
                seen.insert(row.id)
                remote.append(row)
                dmKnownDeviceIDs[row.id] = device.device.id
            }
        }
        // W182 R4：連不上的那台照樣列出最後同步到的 session（灰、只能看；選到時可以「在這台接著聊」）。
        for session in remoteSessions where session.engine == nil {
            guard let doc = session.offlineMirror.snapshot?.document else { continue }
            for var row in Self.dmCandidates(in: doc, deviceName: session.device.name) where !seen.contains(row.id) {
                row.isOffline = true
                seen.insert(row.id)
                remote.append(row)
                dmKnownDeviceIDs[row.id] = session.device.id
            }
        }
        let rows = (local + remote).sorted {
            $0.activity == $1.activity ? $0.id.uuidString < $1.id.uuidString : $0.activity > $1.activity
        }
        let named = GlobalDMSessionCandidate.disambiguated(rows, now: Date())
        return limit.map { Array(named.prefix($0)) } ?? named
    }

    /// 一份文件裡能私訊的 session：未封存、不是助理、不是派到遠端設備的房間；「專案 › 標題」。
    /// W180 D2：子討論串也列（一路往上的父 session 都要列得出來），帶父 session 的 id 與標題，清單裡掛在它下面。
    private static func dmCandidates(in doc: LiveDocumentRecord, deviceName: String?) -> [GlobalDMSessionCandidate] {
        let names = Dictionary(doc.projects.map { ($0.id, $0.id == doc.generalProjectID ? "聊天" : $0.name) },
                               uniquingKeysWith: { first, _ in first })
        let threads = Dictionary(doc.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func listed(_ thread: LiveThreadRecord, depth: Int) -> Bool {
            guard !thread.isArchived, thread.deviceID == nil, let projectID = thread.projectID,
                  projectID != doc.assistantProjectID, names[projectID] != nil else { return false }
            guard let parentID = thread.parentThreadID else { return true }
            guard depth < 4, let parent = threads[parentID] else { return false }
            return listed(parent, depth: depth + 1)
        }
        return doc.threads.compactMap { thread -> GlobalDMSessionCandidate? in
            guard listed(thread, depth: 0), let projectID = thread.projectID,
                  let projectName = names[projectID] else { return nil }
            return GlobalDMSessionCandidate(id: thread.id, projectName: projectName, title: thread.title,
                                            activity: thread.updatedAt, deviceName: deviceName,
                                            parentID: thread.parentThreadID,
                                            parentTitle: thread.parentThreadID.flatMap { threads[$0]?.title })
        }
    }

    /// W180 D2：私訊框看得到的配對設備：主設備在最前面，其他照配對清單。連得到的帶遠端引擎（跟 Coder 看遠端設備用的是
    /// 同一條連線，不另外連）；連不上或還在連的只有名字與狀態。主設備、單機沒配對過就是空的。
    var dmRemoteDevices: [GlobalDMRemoteDevice] {
        var result: [GlobalDMRemoteDevice] = []
        if let primary = assistantPrimaryDevice {
            result.append(GlobalDMRemoteDevice(device: primary, engine: assistantPrimaryEngine,
                                               connecting: assistantPrimaryConnecting, isPrimary: true))
        }
        var listed = Set(result.map(\.device.id))
        #if DEBUG
        for double in dmRemoteDeviceTestDoubles where !listed.contains(double.device.id) {
            listed.insert(double.device.id)
            result.append(GlobalDMRemoteDevice(device: double.device, engine: double.engine(),
                                               connecting: double.connecting(), isPrimary: false))
        }
        #endif
        guard isLive else { return result }
        for session in remoteSessions where !listed.contains(session.device.id) {
            listed.insert(session.device.id)
            let engine: (any AssistantRemoteEngine)? = session.engine
            result.append(GlobalDMRemoteDevice(
                device: AssistantPrimaryDevice(id: session.device.id, displayName: session.device.name),
                engine: engine, connecting: engine == nil && session.state == .connecting, isPrimary: false))
        }
        return result
    }

    /// W180 D2：這條對話在哪一台連得到的配對設備上（本機的回 nil）。
    func dmRemote(for threadID: UUID) -> GlobalDMRemoteDevice? {
        guard localLive?.threadRecord(threadID) == nil else { return nil }
        return dmRemoteDevices.first { $0.engine?.threadRecord(threadID) != nil }
    }

    /// W201：清單不報備所有設備的離線／重連；選到需要那台的對話時才在輸入位置說明。

    /// W179 私訊框：Coder 輸入框自己處理的斜線指令（計畫、目標、PR、討論串、issue、回報、蒸餾）。
    /// 私訊框不做這些，送出前擋下，不把指令原文當一般訊息送給引擎；回傳指令名給提示用。
    static func dmCoderOnlyCommand(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) else { return nil }
        return ["/plan", "/goal", "/pr", "/討論串", "/顯示討論串", "/issue", "/feedback", "/蒸餾"].contains(first) ? first : nil
    }

    #if DEBUG
    /// 自測用：模擬某條討論串的 PR 作業（commit／push／開 PR）正在進行。
    func dmSelfTestSetPendingPR(_ threadID: UUID, _ pending: Bool) {
        if pending { _ = pendingPR.begin(threadID) } else { pendingPR.finish(threadID) }
    }
    #endif

    /// W179 私訊框對某條本機 session 發話：等於在那條的輸入框打字，但主畫面不跳走。
    /// 明確的對象、本機引擎、那條自己記住的模型／思考強度／速度；Coder 的選取與輸入框草稿一律不讀不寫。
    /// W179 F：`onDelivered` 在真的送到時跑一次（本機馬上跑；別台上的等它回覆收到），呼叫端那時才清草稿。
    /// W180 D2：子討論串也能送；attachments＝本機檔案路徑，只有本機的收得下（別台的「＋」已停用並說明）。
    @discardableResult
    func sendFromDM(threadID: UUID, text: String, attachments: [String] = [],
                    onDelivered: @escaping @MainActor () -> Void = {},
                    onUndelivered: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        if threadID == assistantThreadID {
            return sendToAssistant(text: text, attachments: attachments, onDelivered: onDelivered, onUndelivered: onUndelivered)
        }
        // W179 F／W180 D2：不是本機的、是別台（主設備或其他配對設備）上的對話：走那台的遠端引擎（一樣不改 Coder 的選取）。
        if localLive?.threadRecord(threadID) == nil, let remote = dmRemote(for: threadID), let engine = remote.engine {
            guard attachments.isEmpty else { return false }
            return sendFromDMToRemote(engine, device: remote, threadID: threadID, text: text, onDelivered: onDelivered)
        }
        guard isLive, let engine = localLive, let record = engine.threadRecord(threadID),
              !record.isArchived, record.deviceID == nil,
              !engine.doc.isAssistantThread(threadID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              Self.dmCoderOnlyCommand(in: text) == nil,
              !engine.isRunning(threadID) else { return false }
        // 跟 Coder 輸入框一樣：這條的 PR 作業（checkout、快照、commit／push／開 PR）還在跑就不開新回合，
        // 免得改動混進 PR 或讓 PR 那邊的送出被拒。
        guard !pendingPR.contains(threadID) else {
            engine.appendSystemMessage(threadID: threadID, text: "PR 作業處理中，請等目前工作結束。", status: "info|PR")
            objectWillChange.send()
            return false
        }
        #if DEBUG
        if let dmLocalSendTestDouble {
            let accepted = dmLocalSendTestDouble(threadID, text, attachments)
            if accepted { onDelivered() }
            return accepted
        }
        #endif
        let preferences = ChatModelPreferences.selection(record)
        let route = preferences.route
        let kind: ClaudeSidecar.Kind
        switch route.brandGroup {
        case .anthropic: kind = .claude
        case .openAI: kind = .codex
        case .xAI: kind = .grok
        default:
            engine.appendSystemMessage(threadID: threadID, text: "這個模型還沒有接上引擎，請選其他模型。", status: "error|引擎")
            objectWillChange.send()
            return false
        }
        let status = sendLoginStatus(kind)
        guard status.isLoggedIn else {
            engine.appendSystemMessage(threadID: threadID,
                text: "這句沒有送出：\(engineLoginDisplayName(kind)) 還沒登入，到設定 › 登入。",
                status: "error|登入")
            objectWillChange.send()
            return false
        }
        let modelArgument: String?
        switch kind {
        case .claude: modelArgument = route.modelArgument
        case .codex: modelArgument = route.modelArgument ?? route.canonicalModelSlug
        case .grok: modelArgument = route.modelArgument
        }
        engine.autoApprove = permissionPreset == .approveForMe
        engine.userPermissionPreset = permissionPreset
        // W184 H4 修正（審查 #3）：帶的是這一條（threadID）自己的 ultrawork，不是主視窗 Coder 開著那條的（不同條互不影響）。
        // W184 H4 修正第三輪：私訊框按下就清草稿（照舊，onDelivered）；引擎後來說沒送到／不確定（重開、接回原本的對話失敗）就交回
        // 呼叫端照同一套放回（onUndelivered：輸入框空著就放回，已經打了新的一句就提示＋放回輸入框）。不自動重送。
        let accepted = engine.send(threadID: threadID, text: text, model: modelArgument, engine: kind,
            systemPrompt: nil, attachments: attachments,
            reasoningEffort: kind == .codex ? preferences.effort : nil,
            serviceTier: kind == .codex
                ? preferences.speed.appServerValue : nil,
            ultrawork: ultraworkSettings(for: threadID)) { [weak self] outcome in
                if let message = Self.undeliveredMessage(outcome) { onUndelivered(message) }
                self?.objectWillChange.send()
            }
        // W163：跟 Coder 輸入框一樣，「記住…」同時變成一條記憶提案（核准才寫進 user.md）；只在真的送出時提，重送不重複。
        if accepted, let remembered = UserMemoryText.rememberRequest(in: text) {
            let source = "私訊 \(threadID.uuidString.prefix(8))"
            Task.detached { _ = try? UserMemoryStore.shared.propose(text: remembered, source: source) }
        }
        if accepted {
            onDelivered()
        }
        objectWillChange.send()
        return accepted
    }
    /// Global bridge reads stay local even when Coder is displaying a remote engine.
    var localLiveForBridge: ChatLiveEngine? { localLive }

    /// W179 F／W180 D2：私訊框對別台（主設備或其他配對設備）上某條 session 發話：明確的對象、那台的遠端引擎
    /// （跟 Coder 看遠端設備時的送出一樣），模型＝這次在私訊框選的 → 那條記住的（連同引擎），其餘交給那台；
    /// 等那台回覆收到才算送到。Coder 的選取、遠端選取與輸入框草稿一律不讀不寫；不套本機的停用判斷。
    private func sendFromDMToRemote(_ remote: any AssistantRemoteEngine, device: GlobalDMRemoteDevice, threadID: UUID,
                                    text: String, onDelivered: @escaping @MainActor () -> Void) -> Bool {
        guard let record = remote.threadRecord(threadID),
              !record.isArchived, record.deviceID == nil,
              !remote.doc.isAssistantThread(threadID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.dmCoderOnlyCommand(in: text) == nil,
              !remote.isRunning(threadID), !primaryDeliveries.contains(threadID) else { return false }
        let choice = ChatModelPreferences.selection(record, overrideRouteID: dmRemoteModelChoices[threadID], deviceID: device.device.id).route
        let turn = AssistantModelRouting.primaryTurn(choice: choice)
        deliverToPrimary(remote, device: device.device, threadID: threadID, text: text, model: turn.model, engine: turn.kind,
                         assistantRoute: nil, onPrimary: device.isPrimary) {
            if let remembered = UserMemoryText.rememberRequest(in: text) {
                let source = "私訊 \(threadID.uuidString.prefix(8))"
                Task.detached { _ = try? UserMemoryStore.shared.propose(text: remembered, source: source) }
            }
            onDelivered()
        }
        return true
    }

    /// 私訊框讀某條 session：本機的讀本機，別台上的讀那台（背景拉、畫面只讀快取；換版重拉時先用文件快照）。
    func dmTranscript(for threadID: UUID) -> [ChatMessage] {
        if let local = localLive, local.threadRecord(threadID) != nil { return local.transcript(for: threadID) }
        return dmRemote(for: threadID)?.engine.map { Self.primaryTranscript($0, threadID) }
            ?? dmOfflineSession(threadID)?.offlineMirror.transcript(for: threadID) ?? []   // W182 R4：那台離線時讀離線副本
    }

    /// 私訊框：別台上那條的逐字稿還在第一次拉。
    func dmSessionLoading(_ threadID: UUID) -> Bool {
        guard let remote = dmRemote(for: threadID)?.engine else {
            return dmOfflineSession(threadID)?.offlineMirror.isLoading(threadID) ?? false   // W182 R4
        }
        return remote.isTranscriptLoading(threadID) && Self.primaryTranscript(remote, threadID).isEmpty
    }

    /// 私訊框的對象不在本機、也不在任何連得到的設備上，而那台（或某台配對設備）連不上、還在連：可能在那台上，先別換掉。
    func dmSessionAwaitingRemote(_ threadID: UUID) -> Bool {
        guard localLive?.threadRecord(threadID) == nil, dmRemote(for: threadID) == nil else { return false }
        return dmAwaitedDevice(threadID) != nil
    }

    /// 那條可能在哪一台：最後一次看到它的那台（現在連不上）；沒看過就主設備（連不上時）或第一台連不上的。
    private func dmAwaitedDevice(_ threadID: UUID) -> GlobalDMRemoteDevice? {
        let offline = dmRemoteDevices.filter { $0.engine == nil }
        if let known = dmKnownDeviceIDs[threadID] { return offline.first { $0.device.id == known } }
        return offline.first { $0.isPrimary } ?? offline.first
    }

    /// W180 修正：私訊框的對象可能在的那台（現在連不上）的名字；圖示列補上那一顆時標設備用。
    func dmSessionAwaitedDeviceName(_ threadID: UUID) -> String? {
        guard dmSessionAwaitingRemote(threadID) else { return nil }
        return dmAwaitedDevice(threadID)?.device.displayName
    }

    /// 私訊框對別台上某條 session 的一行說明：那台連線中／連不上（送出鈕關掉、草稿留著）。
    func dmSessionNote(_ threadID: UUID) -> String? {
        guard dmSessionAwaitingRemote(threadID), let device = dmAwaitedDevice(threadID) else { return nil }
        if dmOfflineSession(threadID) != nil { return RemoteOfflineContinue.dmNote(place: device.place) }   // W182 R4
        return "這條對話在\(device.place)上，現在不能送出；草稿留著。"
    }

    /// 私訊框對別台上某條 session 送出沒成功的提示；主設備連線的提示只給主設備上的。
    func dmSessionHint(_ threadID: UUID) -> String? {
        guard let remote = dmRemote(for: threadID), let hint = primaryHint,
              hint.threadID == threadID || (hint.threadID == nil && remote.isPrimary) else { return nil }
        return hint.text
    }

    /// 私訊框這條現在能不能送：別台上的要連得到、上一句也送到了。
    func dmSessionCanSend(_ threadID: UUID) -> Bool {
        !dmSessionAwaitingRemote(threadID) && !primaryDeliveries.contains(threadID)
    }

    func dmSessionIsRunning(_ threadID: UUID) -> Bool {
        if let local = localLive, local.threadRecord(threadID) != nil { return local.isRunning(threadID) }
        return dmRemote(for: threadID)?.engine?.isRunning(threadID) ?? false
    }

    func stopDMSession(_ threadID: UUID) {
        if let local = localLive, local.threadRecord(threadID) != nil {
            local.stop(threadID: threadID)
        } else {
            dmRemote(for: threadID)?.engine?.stop(threadID: threadID)
        }
        objectWillChange.send()
    }

    // MARK: - W180 A4 私訊框的模型 chip（只改那個對象，不動 Coder 輸入框）

    /// 本機那條會用的路由：那條記住的；沒記過跟著主導（同 sendFromDM）。
    private static func dmLocalRoute(_ record: LiveThreadRecord) -> ChatRouteChoice {
        ChatModelPreferences.selection(record).route
    }

    /// chip 上的模型名：本機＝那條的；別台上的＝這次在私訊框選的 → 那條記住的 → 交給那台。
    func dmSessionModelChipTitle(_ threadID: UUID) -> String {
        if let record = localLive?.threadRecord(threadID) {
            return AssistantModelRouting.chipName(Self.dmLocalRoute(record))
        }
        guard let remote = dmRemote(for: threadID) else { return "模型" }
        if let choice = dmRemoteModelChoices[threadID] { return AssistantModelRouting.chipName(ChatRouteChoice.resolve(choice, deviceID: remote.device.id)) }
        if remote.engine?.threadRecord(threadID) != nil {
            let stored = ChatModelPreferences.selection(remote.engine?.threadRecord(threadID), deviceID: remote.device.id).route
            return AssistantModelRouting.chipName(stored)
        }
        // chip 只放得下短字；「在哪一台、照什麼」寫在選單第一行。
        return remote.isPrimary ? "主設備預設" : "預設"
    }

    /// 選單列：本機的被停用的引擎標「已停用」不能選；別台上的交給那台判斷（不套本機停用）。
    func dmSessionModelOptions(_ threadID: UUID) -> [AssistantModelOption] {
        if let record = localLive?.threadRecord(threadID) {
            return AssistantModelRouting.options(selectedID: Self.dmLocalRoute(record).id,
                                                 isDisabled: { self.isEngineDisabled($0) })
        }
        let remote = dmRemote(for: threadID)
        let deviceID = remote?.device.id ?? "local"
        let selected = ChatModelPreferences.selection(remote?.engine?.threadRecord(threadID), overrideRouteID: dmRemoteModelChoices[threadID], deviceID: deviceID).route.id
        return AssistantModelRouting.options(selectedID: selected, deviceID: deviceID, isDisabled: { _ in false })
    }

    /// 選單第一行（不能點）：別台上的對話說明在哪一台跑；本機的沒有。
    func dmSessionModelHeadline(_ threadID: UUID) -> String? {
        guard let remote = dmRemote(for: threadID) else { return nil }
        return "在\(remote.place)上跑；沒選就照那條記住的"
    }

    /// 選模型只改這一條：本機的寫進那條的偏好（同 Coder 的 setModelPreferences）；別台上的記在記憶體，下一句帶過去。
    /// 回覆中不換；本機停用的引擎不能選。
    /// W180 修正：那條正好是 Coder 開著的那條時，Coder 的模型 chip 跟著重讀那條的偏好（模型是那條自己的屬性），
    /// 否則 Coder 下一次送出或改思考強度會用舊模型蓋回去；Coder 的選取、草稿與其他 session 照舊不動。
    func setDMSessionModel(_ threadID: UUID, modelID: String) {
        let route = ChatRouteChoice.resolve(modelID, deviceID: localLive?.threadRecord(threadID) != nil ? "local" : dmRemote(for: threadID)?.device.id ?? "local")
        guard let kind = AssistantModelRouting.engineKind(for: route) else { return }
        if let engine = localLive, let record = engine.threadRecord(threadID) {
            guard !engine.isRunning(threadID), !isEngineDisabled(kind),
                  record.requestedModel != route.id else { return }
            engine.setModelPreferences(threadID: threadID, model: route.id,
                effort: reasoningAfterModelSwitch(route, stored: record.requestedEffort),
                speedTier: (route.defaultSpeedTier ?? .fast).rawValue)
            if selectedRemote == nil, selectedThreadID == threadID { restoreModelPreferences() }
            objectWillChange.send()
            return
        }
        guard let remote = dmRemote(for: threadID)?.engine, !remote.isRunning(threadID) else { return }
        dmRemoteModelChoices[threadID] = route.id
        objectWillChange.send()
    }

    /// W180 修正：私訊框現在能不能換這條的模型：本機的可以；別台上的要那台連得到（連不上時 chip 停用、說明原因）。
    func dmSessionModelSelectable(_ threadID: UUID) -> Bool {
        localLive?.threadRecord(threadID) != nil || dmRemote(for: threadID) != nil
    }

    // MARK: - W180 D2 私訊框的附件

    /// 助理收得下附件：本機那條才行（接在主設備、或接不到時不行）。
    var assistantAcceptsAttachments: Bool {
        if case .local = assistantPlacement { return assistantThreadID != nil }
        return false
    }

    /// 這條對話不能帶附件的原因（nil＝可以）：本機的可以；別台上的遠端送不了檔案。
    func dmSessionAttachmentNote(_ threadID: UUID) -> String? {
        if localLive?.threadRecord(threadID) != nil { return nil }
        if let remote = dmRemote(for: threadID) {
            return remote.isPrimary ? "主設備上的對話暫不支援附件" : "\(remote.place)上的對話暫不支援附件"
        }
        return "這條對話不在這台上，暫不支援附件"
    }

    /// 貼上的圖片存成本機附件（跟 Coder 輸入框貼圖同一個地方）；ChatGPT 的附件不經這裡（只放記憶體）。
    func dmSaveAttachment(data: Data, suggestedName: String) -> URL? {
        guard isLive, let localLive else { return nil }
        return try? localLive.savePastedAttachment(data: data, suggestedName: suggestedName)
    }
    /// True while any local chat thread is running (used by the window-close confirmation gate).
    var hasRunningWork: Bool { localLive?.hasRunningWork ?? false }
    private var pendingPR = PullRequestService.PendingPR()
    private var preparingPR = false
    private var localSelectedThreadID: UUID?
    private var remoteProjectionTask: Task<Void, Never>?
    private var lastRemoteProjectionAt = Date.distantPast
    private var botStore: BotStore?
    private(set) var cliSessionStore: CLISessionStore?
    @Published var cliRailHoveredID: UUID?
    @Published var cliRenamePresented = false
    @Published var cliRenameTitle = ""
    var cliRenameID: UUID?
    @Published var cliRestoringIDs: Set<UUID> = []
    @Published var cliRestoredHistoryIDs: Set<UUID> = []
    var cliUIFixtureRecords: [CLISessionStore.Record] = []
    private var previousCLITabIDs: Set<UUID> = []
    private var cliStore: ChatLiveStore?
    var cliSessionsByThread: [UUID: [TatwoNativeCLISessionBook.Session]] = [:]
    var activeCLITabByThread: [UUID: UUID] = [:]
    private var loadedCLIThreadIDs: Set<UUID> = []
    @Published private var pluginEntries: [PluginRegistryEntry]
    private var lastPluginScanAt = Date.distantPast
    private(set) var pluginRefreshTask: Task<Void, Never>?
    var cliTabOwner: [UUID: UUID] = [:]
    var cliTabLinesByID: [UUID: [TatwoTerminalLine]] = [:]
    var cliTabPTYByID: [UUID: CLIWorkbenchTerminalSession] = [:]
    var closingCLIPTYByID: [UUID: CLIWorkbenchTerminalSession] = [:]
    var cliTabPIDByID: [UUID: Int32] = [:]
    var cliRuntime: CLITmuxRuntime?
    var cliWorkbenchDocument = CLISessionStore.Workbench()
    var cliRefreshTask: Task<Void, Never>?
    @Published var cliPendingCloseTitle: String?
    /// W110：CLI 主畫面顯示「過去的對話」而不是終端。
    @Published var cliHistoryPresented = false
    var cliPendingCloseIDs: [UUID] = []
    private var composerRevision: UInt64 = 0
    /// W184 H4 修正第二輪（審查 #1、#7）：每條 Coder 送出去、還沒確認收到的那一句（見 finishCoderDelivery）。
    @Published private(set) var coderDeliveries: [UUID: CoderDelivery] = [:]
    /// W184 H4 修正第三輪：沒送到、還沒放回的那一句（見 putBackUndelivered）。
    private var coderDeliverySnapshots: [UUID: CoderDelivery] = [:]
    @Published private var coderUndeliveredByContext: [CoderDraftIdentity: CoderUndelivered] = [:]
    private var currentCoderDraftIdentity: CoderDraftIdentity? {
        guard let id = selectedRemote?.threadID ?? selectedThreadID else { return nil }
        return CoderDraftIdentity(deviceID: selectedRemote?.deviceID, threadID: id)
    }
    private(set) var coderUndelivered: CoderUndelivered? {
        get { currentCoderDraftIdentity.flatMap { coderUndeliveredByContext[$0] } }
        set {
            if let newValue {
                coderUndeliveredByContext[CoderDraftIdentity(deviceID: newValue.deviceID, threadID: newValue.threadID)] = newValue
            } else if let key = currentCoderDraftIdentity {
                coderUndeliveredByContext[key] = nil
            }
        }
    }
    @Published var prompt = "" {
        didSet {
            // 打字後建議清單會變，三個 picker 的高亮都歸零，避免指到錯的項目。1.0 :1519
            guard prompt != oldValue else { return }
            composerRevision &+= 1
            if skillSuggestionSelectedIndex != nil { skillSuggestionSelectedIndex = nil }
            if slashCommandSelectedIndex != nil { slashCommandSelectedIndex = nil }
            if issueMentionSelectedIndex != nil { issueMentionSelectedIndex = nil }
            if activeSkillQuery != nil { reloadPluginRegistry(ifOlderThan: 60) }
        }
    }
    // 同 1.0：匯出／假資料模式下由 TATWO_ULTRAWORK_EXPORT_CHAT_MODE 決定 chat / cli / bot
    @Published var mode: ChatRunMode = {
        switch ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_CHAT_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bot": return .bot
        case "cli": return .cli
        default: return .chat
        }
    }() {
        didSet {
            if mode != oldValue {
                // 全權下操作 TATWO OS 自己時，切換模式本身就是被操作的動作之一，不能因此收回授權
                // （否則 Browser／CLI 等模式永遠測不到）。操作其他 App 的授權照舊一離開聊天就收回。
                if !(permissionPreset == .fullAccess && ComputerUseController.shared.isOperatingSelf()) {
                    ComputerUseController.shared.stop()
                }
                BrowserAgentBridge.shared.revokeRequests()
            }
        }
    }
    @Published var searchText = ""
    @Published var skin: ChatSkin = .codex
    @Published var document = TatwoNativeChatStoreDocument()
    @Published var selectedThreadID: UUID? {
        didSet {
            OSPresence.shared.select(selectedThreadID, engine: activeConversationEngine)
            if selectedThreadID != oldValue {
                // 同切換模式：全權下操作 TATWO OS 自己時，點別條討論串也是被操作的動作之一，不因此收回授權。
                if !(permissionPreset == .fullAccess && ComputerUseController.shared.isOperatingSelf(owner: oldValue)) {
                    ComputerUseController.shared.stop(owner: oldValue)
                }
                BrowserAgentBridge.shared.revokeRequests()
            }
            if selectedThreadID != oldValue {
                composerRevision &+= 1
                loadActivePlanCanvas()
            }
            guard isLive, let activeLive = activeConversationEngine,
                  let id = selectedThreadID, id != oldValue else { return }
            if let selectedRemote {
                self.selectedRemote = (selectedRemote.deviceID, id)
            } else {
                localSelectedThreadID = id
            }
            activeLive.select(id)
            isRunning = activeLive.isRunning(id)
            restoreModelPreferences()
            refreshIssueLists()
            if selectedRemote == nil { refreshGitStatus() }
            loadPersistedCLISessionBook()
        }
    }
    @Published var selectedCLISessionID: String?
    @Published var cliTabStatuses: [UUID: String] = [:]
    @Published var selectedLoopsSessionID: UUID?
    @Published var dispatchingLoopID: UUID?
    @Published var plgPaused = false
    @Published private var fixtureActiveGoalPaused = false
    @Published var activeGoalClock = Date()
    @Published var issueListShowsGlobal = false { didSet { refreshIssueLists() } }
    @Published var requestOpenInfoCard = false
    @Published var requestOpenLoopsPanel = false
    @Published var requestOpenBrowserPanel = false
    @Published var requestOpenAccountBrowser = false // Native Settings only; no MCP grant.
    @Published private(set) var requestedBrowserAgentURL: String?
    private var pendingBrowserAgentNavigation: BrowserAgentNavigation?
    private(set) var browserTabRegistry: BrowserTabRegistry = BrowserTabRegistry()
    private var apiKeyPolicyObservation: AnyCancellable?   // W181 R3
    @Published var activePlanArtifact: TatwoPlanArtifactV1?
    @Published private var localCanvasArchives: [CanvasArchiveOption] = []
    var distillState = DistillModelState()   // W180 E4：/蒸餾 遠端畫布的小狀態（ChatPageModel+Distill.swift）
    @Published var planInspectorRequest: UUID?
    /// 2026-09-11 使用者回饋：提醒遺留太久 → 顯示 4–10 秒（依字數）後自動收掉；換成新提醒就重新計時。
    @Published var composerHint: String? { didSet { scheduleComposerHintExpiry() } }
    /// W170：右上角目標卡片展開與否（/goal 之後自動展開）。
    @Published var goalCardExpanded = false
    private var composerHintExpiry: Task<Void, Never>?
    private func scheduleComposerHintExpiry() {
        composerHintExpiry?.cancel()
        guard let hint = composerHint, !hint.isEmpty else { return }
        let seconds = min(10, max(4, Double(hint.count) * 0.15))
        composerHintExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.composerHint == hint else { return }
            self.composerHint = nil
        }
    }
    @Published var slashCommandSelectedIndex: Int?
    @Published var droppedPathDisplayNames: [String: String] = [:]
    @Published var permissionPreset: TatwoPermissionPreset =
        UserDefaults.standard.string(forKey: "tatwo2.permissionPreset")
            .flatMap(TatwoPermissionPreset.init(rawValue:)) ?? .approveForMe {
        didSet {
            UserDefaults.standard.set(permissionPreset.rawValue, forKey: "tatwo2.permissionPreset")
            live?.autoApprove = permissionPreset == .approveForMe
            localLive?.userPermissionPreset = permissionPreset
            // W184 CU 第二輪（GPT-6 審查 #2）：從「全權」降下來＝當場撤銷 Computer Use（自我目標只有全權才准），
            // 不等下一次工具呼叫；排進去還沒跑的自我動作一併作廢。
            ComputerUseController.shared.permissionPresetChanged(from: oldValue, to: permissionPreset)
        }
    }
    @Published var selectedSpeedTier: TatwoModelSpeedTier = .fast { didSet { persistModelPreferences() } }
    @Published var selectedTapEffortID: String? { didSet { persistModelPreferences() } }
    @Published var selectedEffort: TatwoCodexReasoningEffort = .high {
        didSet {
            if !restoringModelPreferences { normalizeExtendedReasoningEffort() }
            persistModelPreferences()
        }
    }
    @Published var pendingArchiveIssuePrompt: (title: String, count: Int)?
    @Published var coldStartHydrationFailureMessage: String?
    @Published var allIssueListEntries: [TatwoIssueListEntryV1] = []
    @Published var archivedIssueListEntries: [TatwoIssueListEntryV1] = []
    @Published var issueListEntries: [TatwoIssueListEntryV1] = []
    @Published var focusedIssueEntryID: String?
    @Published var issueMentionSelectedIndex: Int?
    @Published var skillSuggestionSelectedIndex: Int?
    @Published var chatQueuePaused = false
    @Published var isEnablingCodexMirror = false
    @Published var isLoadingStore = false
    @Published var isRunning = false
    /// Presentation only: hiding the tray never stops or archives its rooms.
    @Published var hiddenDiscussionTrayKeys: Set<String> = []
    private var pendingIssueSubmission: (key: String, id: String)?
    @Published var droppedPaths: [String] = [] {
        didSet { if droppedPaths != oldValue { composerRevision &+= 1 } }
    }
    @Published var gitBranch = "—"
    @Published var gitChangedFileCount = 0
    @Published var gitChangedFilePreview: [String] = []
    @Published var gitChangedFiles: [ChatGitChangedFileSummary] = []
    /// 回合收尾卡的資料：這條對話最新一回合的產出索引（jobs-index 底層寫的 latest.json）。
    @Published var latestTurnArtifacts: TurnArtifactIndex?
    @Published var gitChangedLineAdditions = 0
    @Published var gitChangedLineDeletions = 0
    @Published private var gitHubRepoCheckingProjectIDs: Set<UUID> = []
    @Published private var gitHubRepoCheckMessages: [UUID: String] = [:]
    @Published var lastClaudeRouteReceiptStatus = ""
    @Published var lastCommand = "尚未執行"
    private lazy var pendingModelSelections = PendingModelSelections(root:
        localLive?.store.url.deletingLastPathComponent() ?? ChatLiveStore().url.deletingLastPathComponent())
    var modelSelectionDeviceID: String { selectedRemote?.deviceID ?? "local" }
    var pendingModelID: String? {
        let entry = pendingModelSelections.entry(deviceID: modelSelectionDeviceID, threadID: selectedThreadID)
        return entry?.pending == true ? entry?.routeID : nil
    }
    @Published var selectedDiscussionID: UUID?
    @Published var selectedModel = "gpt-6.1-sol" {
        didSet {
            if !restoringModelPreferences, selectedModel != oldValue, routeChoice.runtimeAdapter == .chatgptTap {
                selectedTapEffortID = routeChoice.tapModel.flatMap(ChatGPTTapModelCatalog.defaultEffort)
            }
            if !restoringModelPreferences { normalizeExtendedReasoningEffort() }
            persistModelPreferences()
        }
    }
    private var restoringModelPreferences = false
    @Published var codexMirrorStatus: TatwoCodexAppStateBridge.MirrorStatus = .notEnabled
    @Published var devices: [DeviceRecord] = []
    @Published var remoteSessions: [RemoteDeviceSession] = []
    @Published var remoteSidebarSections: [RemoteSidebarSection] = []
    /// W98d：請側欄展開並捲到某台設備區塊的訊號（同一台再按一次也會動，靠 nonce）；不存狀態、不做別的事。
    @Published var sidebarDeviceFocus: SidebarDeviceFocus?
    @Published var selectedRemote: (deviceID: String, threadID: UUID)? {
        didSet {
            if selectedRemote?.deviceID != oldValue?.deviceID || selectedRemote?.threadID != oldValue?.threadID {
                ComputerUseController.shared.stop()
                BrowserAgentBridge.shared.revokeRequests()
                loadActivePlanCanvas()
            }
        }
    }
    /// W100：按了遠端設備但還沒連上時記在這裡，背景連上就自動進遠端模式。
    private var pendingRemoteEntryDeviceID: String?
    @Published var pairingWindow: (code: String, expiresAt: Date)?
    @Published var pairingListenAddress: String?
    /// 設定頁「設備」卡用：加入主機的結果（設定頁看不到輸入框的 hint）。
    @Published var pairingClientMessage: String?
    @Published var gitHubAccounts: [GitHubAccountRecord] = []
    @Published var gitHubHelperInstalled = false
    @Published var gitHubLoginLog: [String] = []
    @Published var githubLoginInProgress = false
    @Published var githubDeviceCode: String?
    @Published var githubVerificationURL: URL?
    @Published var engineLogins: [EngineLoginStatus] = []
    @Published var engineLoginLog: [String] = []
    @Published var engineLoginInProgress: ClaudeSidecar.Kind?
    @Published var disabledEngines: Set<String> = EngineDisableStore.disabled()
    @Published var engineQuotas: [String: LiveQuotaDisplay] = [:]
    @Published var engineQuotaDetails: [String: EngineQuotaDetail] = [:]
    @Published var upstreamBindings: [UpstreamBindingStatus] = []
    @Published var osDocuments: [OSDocument] = OSDocuments.list()
    @Published var osDocumentText: [String: String] = [:]
    @Published var osDocumentNote: [String: String] = [:]
    @Published var osDocumentPending: [String: String] = [:]

    var canRetryColdStartHydration: Bool { true }
    var cliTabs: [TatwoNativeCLISessionBook.Session] {
        guard let selectedThreadID else { return [] }
        return cliSessionsByThread[selectedThreadID] ?? []
    }
    var activeCLITabID: UUID? {
        guard let selectedThreadID else { return nil }
        return activeCLITabByThread[selectedThreadID]
    }
    var selectedSessionReference: TatwoNativeChatSessionReference? { nil }
    var nativeGoalSnapshot: ChatNativeGoal? {
        guard isLive, selectedRemote == nil else { return nil }
        return localLive?.threadRecord(selectedThreadID)?.nativeGoal
    }
    var nativeGoalIsCurrent: Bool {
        guard let id = selectedThreadID else { return false }
        return localLive?.nativeGoalIsCurrent(id) == true
    }
    var nativeGoalControlPending: Bool {
        guard let id = selectedThreadID else { return false }
        return localLive?.nativeGoalControlPending(id) == true
    }
    var activeGoalPaused: Bool {
        isLive ? nativeGoalSnapshot?.status != "active" || !nativeGoalIsCurrent : fixtureActiveGoalPaused
    }
    var activeGoalStepProgress: (current: Int, total: Int) { isLive ? (0, 0) : (1, 5) }
    var selectedRouteCooldownStatusText: String { "" }
    var selectedWorkOSGoalStatusLabel: String { isLive ? nativeGoalSnapshot?.status ?? "unknown" : "running" }
    var activeGoalObjectiveLabel: String { isLive ? nativeGoalSnapshot?.objective ?? "" : "完成 Tatwo2 Chat UI" }
    var activeGoalElapsedLabel: String { isLive ? nativeGoalSnapshot?.elapsedLabel ?? "—" : "00:00" }
    var activeGoalHeaderProgressLabel: String { isLive ? nativeGoalSnapshot?.usageLabel ?? "—" : "1 / 5" }
    var canResumeActiveGoal: Bool {
        guard isLive else { return true }
        guard selectedRemote == nil, !nativeGoalControlPending, let goal = nativeGoalSnapshot else { return false }
        return goal.canResume || (!nativeGoalIsCurrent && goal.status == "active")
    }
    var canControlActiveGoal: Bool { !isLive || (selectedRemote == nil && !nativeGoalControlPending) }
    var canJudgeAndCompleteActiveGoal: Bool { false }
    var selectedThreadHasWorkOSGoal: Bool { isLive ? nativeGoalSnapshot != nil : fixture.hasWorkOSGoal }
    /// ultrawork 膠囊的檔位。2026-09-04 補接：原本永遠回 .off，等於膠囊點了沒反應
    /// （B2 拆模式／情境卡時說好「誰主導、誰當 sub、誰審改在膠囊選」的那顆）。
    @Published var collaborationLevel: ChatCollaborationLevel = .off
    /// B3 派工卡：展開中的房間報告（收合／展開）。匯出 dispatch 場景預設展開已完成那間，讓金樣看得到設計。
    @Published var expandedDispatchReports: Set<UUID> = ChatPageModel.isDispatchExportScene
        ? [UUID(uuidString: "00000000-0000-0000-0000-00000000B303")!] : []
    /// 主導／副審的模型 id；由膠囊面板的角色選單寫入，送出時併進上游宣告給引擎看。
    /// W184 H4 修正（審查 #3、#5）：這幾個（連同 collaborationLevel）＝Coder 開著的那條記住的 ultrawork（每條自己存；
    /// TatwoComposerModeUltrawork.swift）；換 thread 時照那條讀回來。副手整份（副審＝第一個，後面是 sub）。
    @Published var ultraworkPrimaryModelID: String?
    @Published var ultraworkSecondaryModelID: String?
    @Published var ultraworkAuxiliaryModelIDs: [String] = []
    var isCLIRuntimeEnabled: Bool {
        (isLive && SpaceWorkspaceController.shared.allows(.cli)) || Self.exportChatScene == "cli-多session"
    }
    var planFlowSelectionProjection: PlanFlowSelectionProjectionV1? { nil }
    var planWorkOSLocalActionPresentation: ChatPlanWorkOSLocalActionPresentation { .idle }
    var selectedThreadPluginIDs: [String] { isLive ? selectedThreadPluginEntries.map(\.id) : [] }
    /// `$` 技能選單：只有打了 `$` 且後面還沒空白時才有東西（1.0 :918-930）。
    /// 沒有這道 gate，那排膠囊就會常駐——2026-09-04 使用者回報的就是這個。
    var skillSuggestions: [PluginRegistryEntry] {
        guard isLive, let query = activeSkillQuery else { return [] }
        let lowered = query.lowercased()
        let skills = availableThreadPluginEntries.filter { $0.kind == .skill || $0.id == "tatwo-ultrawork" }
        let matches = skills.filter { entry in
            lowered.isEmpty
                || entry.id.lowercased().contains(lowered)
                || entry.name.lowercased().contains(lowered)
                || (entry.path ?? "").lowercased().contains(lowered)
        }
        return Array(matches.prefix(6))
    }

    private var activeSkillQuery: String? {
        guard let dollar = prompt.lastIndex(of: "$") else { return nil }
        let suffix = prompt[prompt.index(after: dollar)...]
        if suffix.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return String(suffix)
    }
    var activePendingHandoff: ChatHandoffEnvelope? { nil }
    var composerFooterState: ChatComposerFooterState { .neutral }
    // 2026-09-04：改回 1.0 的算出來的屬性（原本是 stored，只在 init 賦值一次，
    // 導致切模型永遠停在 gpt-5.5）。來源：ChatPageModel+StateAndSelection.swift:391
    var routeChoice: ChatRouteChoice { ChatRouteChoice.resolve(selectedModel, deviceID: modelSelectionDeviceID) }
    var chatGPTTapConnection: TapConnection {
        #if DEBUG
        if let chatGPTTapConnectionTestDouble { return chatGPTTapConnectionTestDouble() }
        #endif
        return ChatGPTTap.shared.connection
    }
    var chatGPTTapUnavailableReason: String? {
        if selectedRemote != nil { return "ChatGPT 只支援本機 Coder；請切回本機討論串" }
        return ChatGPTTapModelCatalog.unavailabilityReason(connection: chatGPTTapConnection)
    }
    func tapModelUnavailableReason(_ choice: ChatRouteChoice) -> String? {
        guard choice.runtimeAdapter == .chatgptTap else { return nil }
        return chatGPTTapUnavailableReason
            ?? ChatGPTTapModelCatalog.unavailabilityReason(connection: chatGPTTapConnection, routeID: choice.id)
    }
    func tapModelSelectionUnavailableReason(_ choice: ChatRouteChoice) -> String? {
        guard choice.runtimeAdapter == .chatgptTap else { return nil }
        // 選模型只改偏好：休眠或正在喚醒都選得上（模式卡先喚醒、下一輪才套用，那時已是 starting）；送出仍等就緒。
        if selectedRemote == nil, chatGPTTapConnection == .sleeping || chatGPTTapConnection == .starting { return nil }
        return tapModelUnavailableReason(choice)
    }
    /// 選到休眠中的 ChatGPT 模型就喚醒；目錄還沒有這個模型時先提示、不切換。回傳 false＝這次不切換。
    func prepareTapSelection(_ choice: ChatRouteChoice) -> Bool {
        guard choice.runtimeAdapter == .chatgptTap, chatGPTTapConnection == .sleeping else { return true }
        wakeChatGPTForModelSelection()
        if ChatGPTTapModelCatalog.modelID(choice.id) == "unavailable" {
            flashComposerHint("ChatGPT 正在啟動；就緒後請選擇模型")
            return false
        }
        return true
    }
    private func wakeChatGPTForModelSelection() {
        #if DEBUG
        if let chatGPTTapWakeTestDouble { chatGPTTapWakeTestDouble(); return }
        #endif
        ChatGPTTap.shared.start()
    }
    func openChatGPTForModelSelection() {
        mode = .chatgpt
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        ChatGPTTap.shared.start()
    }
    private func tapSendUnavailableReason(_ choice: ChatRouteChoice) -> String? {
        if choice.runtimeAdapter == .chatgptTap, selectedRemote == nil,
           chatGPTTapConnection == .sleeping || chatGPTTapConnection == .starting,
           choice.id != ChatGPTTapModelCatalog.routeID("unavailable") { return nil }
        // 舊目錄仍有已選模型時，允許 runner 在送出前刷新一次；離線與登入狀態照舊拒絕。
        if selectedRemote == nil, chatGPTTapConnection == .ready, !ChatGPTTapModelCatalog.isFresh,
           ChatGPTTapModelCatalog.snapshot.contains(where: { ChatGPTTapModelCatalog.routeID($0.id) == choice.id }) {
            return nil
        }
        return tapModelUnavailableReason(choice)
    }
    func refreshChatGPTTapModels() { ChatGPTTapModelObservation.current?.refreshIfNeeded() }
    var tapEffortIDForSend: String? {
        routeChoice.tapEfforts.first { $0.id == selectedTapEffortID }?.id
            ?? routeChoice.tapModel.flatMap(ChatGPTTapModelCatalog.defaultEffort)
    }
    func selectTapEffort(_ id: String) {
        guard routeChoice.tapEfforts.contains(where: { $0.id == id }) else { return }
        selectedTapEffortID = id
    }
    var pendingRouteChoice: ChatRouteChoice? { pendingModelID.map(ChatRouteChoice.resolve) }
    var modelPickerRouteLabel: String {
        guard let pendingRouteChoice, pendingRouteChoice.id != routeChoice.id else { return routeChoice.commandLabel }
        return "\(routeChoice.commandLabel) · 下一輪 \(pendingRouteChoice.commandLabel)"
    }
    var activeSubagentRows: [ThreadSubagentPresentationRow] { [] }
    var visibleIssueListEntries: [TatwoIssueListEntryV1] { issueListEntries.filter { $0.status != .archived } }
    var filteredProjects: [TatwoNativeChatProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = document.projects.filter {
            $0.id != document.generalProjectID && $0.id != document.assistantProjectID
        }
        guard !query.isEmpty else { return projects }
        return projects.compactMap { project in
            var result = project
            result.isExpanded = true
            if project.name.localizedCaseInsensitiveContains(query) { return result }
            // Keep ancestors so a matching child remains reachable in the
            // existing project tree. Search never changes stored expansion.
            let byID = Dictionary(project.threads.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
            var included = Set(project.threads.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.lastPreview.localizedCaseInsensitiveContains(query)
            }.map(\.id))
            for id in Array(included) {
                var parent = byID[id]?.parentThreadID
                var visited = Set<UUID>([id])
                while let next = parent, visited.insert(next).inserted {
                    included.insert(next)
                    parent = byID[next]?.parentThreadID
                }
            }
            result.threads = project.threads.filter { included.contains($0.id) }
            return result.threads.isEmpty ? nil : result
        }
    }
    var bindingSummary: String { "Chat · \(routeChoice.title)" }
    var selectedThread: TatwoNativeChatThread? {
        activeConversationDocument.projects.lazy.flatMap(\.threads).first { $0.id == selectedThreadID }
    }
    var activePendingHandoffSummary: String { activePendingHandoff?.summaryLine ?? "" }
    var activeLoopsConfig: TatwoNativeThreadLoopsConfig? { selectedThread?.loopsConfig }
    var collaborationIsEnabled: Bool { collaborationLevel != .off }
    /// `/` 指令清單。語意由 OS 上游宣告（docs/os-upstream.md）告訴各家引擎，
    /// /issue 與 /討論串由本機處理；其餘語意交原生引擎。
    static let slashCommandItems: [SlashCommandItem] = [
        SlashCommandItem(id: "/pr", cmd: "/pr", title: "/pr — 貢獻到 TATWO OS 公開倉",
            subtitle: "僅在 TATWO OS 公開倉或其 fork 使用；其他專案請用原生 Git 工具", icon: "arrow.triangle.branch"),
        SlashCommandItem(id: "/feedback", cmd: "/feedback", title: "/feedback — 回報問題",
            subtitle: "檢查原文並確認後，提交至 \(FeedbackSettings.feedbackRepository)", icon: "bubble.left.and.exclamationmark.bubble.right"),
        SlashCommandItem(id: "/plg", cmd: "/plg", title: "/plg — 依已確認的計畫開工",
            subtitle: "先確認計畫；主導能做的直接做，需要協作時再派房間", icon: "point.3.filled.connected.trianglepath.dotted"),
        SlashCommandItem(id: "/plan", cmd: "/plan", title: "/plan — 只討論不動手",
            subtitle: "純規劃釐清；沒有你的「開始」就不改任何檔", icon: "list.bullet.rectangle"),
        SlashCommandItem(id: "/goal", cmd: "/goal", title: "/goal — 開一張目標卡",
            subtitle: "目標寫進右側資訊卡，之後逐條對齊驗收", icon: "target"),
        SlashCommandItem(id: "/issue", cmd: "/issue", title: "/issue — 支線等待佇列",
            subtitle: "/issue <文字> 捕捉支線；/issue 打開佇列（不啟動執行）", icon: "tray.full"),
        SlashCommandItem(id: "/討論串", cmd: "/討論串", title: "/討論串 — 開啟子討論串",
            subtitle: "主題保留為草稿，送出後才開始工作", icon: "bubble.left.and.bubble.right"),
        SlashCommandItem(id: "/顯示討論串", cmd: "/顯示討論串", title: "/顯示討論串 — 叫回討論串列",
            subtitle: "顯示目前對話的討論串，不啟動或中斷工作", icon: "chevron.up"),
        // W180 E4：/蒸餾＝session 做完整理成技能或其他可重用的東西（不是寫死進 GBrain）。
        SlashCommandItem(id: "/蒸餾", cmd: "/蒸餾", title: "/蒸餾 — 把這條對話整理成技能",
            subtitle: "預設寫成技能；也可選清單、SOP、GBrain，確認才寫入", icon: "drop.triangle"),
    ]

    var matchingSlashCommands: [SlashCommandItem] {
        guard mode == .chat else { return [] }
        let ids = Set(ChatComposerSlashCatalog.matches(prompt: prompt).map(\.command))
        return Self.slashCommandItems.filter { ids.contains($0.cmd) }.map { item in
            guard routeChoice.runtimeAdapter == .chatgptTap, CanvasCommandPolicy.commands.contains(item.cmd) else { return item }
            return SlashCommandItem(id: item.id, cmd: item.cmd, title: item.title,
                subtitle: CanvasCommandPolicy.tapUnsupported, icon: item.icon)
        }
    }
    var chatGPTStartupNotice: String? {
        guard isRunning, routeChoice.runtimeAdapter == .chatgptTap, chatGPTTapConnection == .starting else { return nil }
        return "ChatGPT 啟動中，這句已排隊"
    }
    var sendAvailabilityDiagnostic: String {
        if let chatGPTStartupNotice { return chatGPTStartupNotice }
        if routeChoice.runtimeAdapter == .chatgptTap, CanvasCommandPolicy.command(in: prompt) != nil { return CanvasCommandPolicy.tapUnsupported }
        if isSelectedHandsThread { return "ChatGPT build 的紀錄：只由 ChatGPT 操作" }   // W183 R1
        if isLocalPRCommand { return "檢查改動並開啟 PR 草稿" }
        if isLocalFeedbackCommand { return "開啟回報草稿，不中斷目前工作" }
        if isLocalIssueCommand { return "記錄問題，不中斷目前工作" }
        if isLocalDiscussionCommand { return "開啟討論串，不啟動模型" }
        if isShowDiscussionTrayCommand { return "顯示討論串，不中斷目前工作" }
        if let reason = tapSendUnavailableReason(routeChoice) { return reason }
        if routeChoice.runtimeAdapter == .chatgptTap, !ChatGPTTapModelCatalog.isFresh {
            return "送出時會重新整理 ChatGPT 模型目錄"
        }
        if canSteerCurrentTurn { return "插話到目前工作" }
        return canSend ? "可送出" : (isRunning ? "工作執行中" : "請輸入內容")
    }
    var archivedThreadCount: Int {
        isLive ? (activeConversationEngine?.archivedThreadCount ?? 0) : 0
    }
    var selectedThreadProject: TatwoNativeChatProject? {
        activeConversationDocument.projects.first { project in
            project.threads.contains { $0.id == selectedThreadID }
        }
    }
    var selectedThreadPluginSummary: String {
        guard isLive else { return "無 plugins" }
        let selected = selectedThreadPluginEntries
        let skills = availableThreadPluginEntries.filter { $0.kind == .skill }.count
        if selected.isEmpty { return "無 MCP 常駐・\(skills) skills" }
        return "\(selected.count) MCP 常駐・\(skills) skills"
    }
    var pinnedThreadRefs: [ChatSidebarThreadRef] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.projects.filter { $0.id != document.assistantProjectID }.flatMap { project in
            project.threads.filter {
                $0.isPinned && (query.isEmpty
                    || project.name.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.lastPreview.localizedCaseInsensitiveContains(query))
            }.map { ChatSidebarThreadRef(
                project: project.id == document.generalProjectID ? nil : project, thread: $0) }
        }.sorted {
            let lhs = threadActivityDate($0.thread), rhs = threadActivityDate($1.thread)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    var activeMappings: [TatwoNativeCLIFeatureMapping] { [] }
    var availableThreadPluginEntries: [PluginRegistryEntry] {
        guard isLive else { return [] }
        let engine = selectedMCPEngine
        return pluginEntries.filter {
            $0.kind == .skill || (PluginsSource.mcpEngine(from: $0.id) == engine)
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .mcp }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    var selectedThreadLoopsSessions: [TatwoLoopsSession] { [] }
    var selectedThreadArchivedLoopsSessions: [TatwoLoopsSession] { [] }
    var selectedThreadSupervisorModelID: String { "gpt-5.6-terra" }
    var loopsLiveRows: [TatwoLoopsLiveRow] { [] }
    var activePLGRun: TatwoPLGRun? { nil }
    var selectedDispatchRuntimeProjection: TatwoDispatchRuntimeProjection { .init() }
    var selectedGoalRecord: TatwoStoredGoalRun? { nil }
    var plgError: String? { nil }
    var canAdvanceNativeDevelopmentCycle: Bool { false }
    /// `@` 搜尋結果：標題／內文／來源逐筆比對，最多 8 筆。1.0 :367
    var issueAtMentionMatches: [TatwoIssueListEntryV1] {
        guard let query = issueAtMentionQuery else { return [] }
        let matched = query.isEmpty ? issueListEntries : issueListEntries.filter {
            $0.title.lowercased().contains(query)
                || $0.body.lowercased().contains(query)
                || $0.sourceReference.lowercased().contains(query)
        }
        // 使用者 2026-09-05：@ 統一叫出，本串排上段、全域排下段
        let current = selectedThreadID?.uuidString
        let mine = matched.filter { $0.threadReference == current }
        let others = matched.filter { $0.threadReference != current }
        return Array((mine + others).prefix(10))
    }
    var effectivePermissionMappingSummary: String { permissionPreset.mappingSummary }
    var sidebarStandaloneThreads: [TatwoNativeChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = document.projects.first {
            $0.id == document.generalProjectID && $0.id != document.assistantProjectID
        }?.threads ?? []
        return threads.filter {
            !$0.isPinned && (query.isEmpty
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.lastPreview.localizedCaseInsensitiveContains(query))
        }.sorted {
            let lhs = threadActivityDate($0), rhs = threadActivityDate($1)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    var activeGoalNextActionLabel: String { isLive ? activeGoalStatusPresentationLabel : "繼續完成畫面" }
    var activeGoalStatusPresentationLabel: String {
        guard isLive else { return "進行中" }
        if nativeGoalControlPending { return "正在更新目標" }
        guard let goal = nativeGoalSnapshot else {
            if let id = selectedThreadID, localLive?.nativeGoalError(id) != nil { return "目標狀態無法確認" }
            return nativeGoalIsCurrent ? "無目標" : "目標狀態未確認"
        }
        return nativeGoalIsCurrent ? goal.statusLabel : "上次：\(goal.statusLabel)"
    }
    var activeGoalStepProgressLabel: String { "\(activeGoalStepProgress.current) / \(activeGoalStepProgress.total)" }
    var activePlanTurnAssistantMessageID: String? { nil }
    var activeWorkOSLeadLabel: String { selectedModel }
    var activeWorkOSLine: String { "單模型 chat" }
    var activeWorkOSLoopsLabel: String { "未啟用" }
    var activeWorkOSModeLabel: String { "S" }
    var canOpenThreadInCLI: Bool {
        guard selectedRemote == nil else { return false }
        guard
            isLive,
            let record = live?.threadRecord(selectedThreadID),
            let project = live?.projectRecord(record.projectID)
        else { return false }
        var isDirectory: ObjCBool = false
        return !project.workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FileManager.default.fileExists(atPath: project.workdir, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
    var isLocalPRCommand: Bool {
        TatwoSlashCommandParser.prArgument(in: prompt) != nil
    }
    var isLocalFeedbackCommand: Bool {
        TatwoSlashCommandParser.feedbackArgument(in: prompt) != nil
    }
    var isLocalIssueCommand: Bool {
        let command = prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
        return command == "/issue"
    }
    var isLocalDiscussionCommand: Bool {
        prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/討論串"
    }
    var isShowDiscussionTrayCommand: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "/顯示討論串"
    }
    private var discussionTrayKey: String {
        "\(selectedRemote?.deviceID ?? "local"):\(selectedThreadID?.uuidString ?? "preview")"
    }
    var isDiscussionTrayHidden: Bool { hiddenDiscussionTrayKeys.contains(discussionTrayKey) }
    func hideDiscussionTray() { hiddenDiscussionTrayKeys.insert(discussionTrayKey) }
    func showDiscussionTray() { hiddenDiscussionTrayKeys.remove(discussionTrayKey) }
    var isLocalNativeGoalCommand: Bool {
        routeChoice.brandGroup == .openAI && prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/goal"
    }
    var localConversationReadOnlyNotice: String? {
        localLive?.store.isReadOnly == true ? "唯讀中，不能送出；請先確認儲存空間與檔案權限，再重新開啟 App。" : nil
    }

    var canSend: Bool {
        if selectedRemote == nil && localConversationReadOnlyNotice != nil { return false }
        if isSelectedHandsThread { return false }   // W183 R1：ChatGPT 手腳的紀錄與施工房輸入框鎖住
        let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !droppedPaths.isEmpty
        if routeChoice.runtimeAdapter == .chatgptTap, CanvasCommandPolicy.command(in: prompt) != nil { return hasContent }
        if isLocalPRCommand || isLocalFeedbackCommand || isLocalIssueCommand || isLocalDiscussionCommand || isShowDiscussionTrayCommand { return hasContent }
        if prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/goal", !isLocalNativeGoalCommand { return hasContent }
        if tapSendUnavailableReason(routeChoice) != nil { return false }
        return hasContent && !nativeGoalControlPending &&
            (!isRunning || isLocalNativeGoalCommand || canSteerCurrentTurn)
    }
    var canSteerCurrentTurn: Bool {
        guard selectedRemote == nil, routeChoice.brandGroup == .openAI, let id = selectedThreadID else { return false }
        return localLive?.canSteer(id) == true
    }
    var codexMirrorStatusMessage: String {
        switch codexMirrorStatus {
        case .loaded: "Codex 鏡射已啟用"
        case .notEnabled: "Codex 鏡射未啟用"
        case .unavailable: "Codex 鏡射不可用"
        }
    }
    var isActivePlanExecutionRunning: Bool {
        guard let plan = activePlanArtifact else { return false }
        return localLive?.isExecutingPlan(plan) == true
    }
    var isActivePlanTurnWriting: Bool { isPlanModeEnabled && isRunning }
    var isPlanModeEnabled: Bool {
        guard let plan = activePlanArtifact, plan.state == .discussing else { return false }
        if plan.kind == "distill" { return plan.distillSubmission == nil }
        return plan.kind != "pr" || plan.isPRModeActive
    }
    var isSelectedThreadStandalone: Bool { selectedThreadProject == nil && selectedThread != nil }
    /// composer 尾端 `@` token 的搜尋字（nil＝沒有 @ token）。1.0 :358
    var issueAtMentionQuery: String? {
        guard let token = prompt.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              token.hasPrefix("@") else { return nil }
        return String(token.dropFirst()).lowercased()
    }
    var queuedChatTurnCount: Int { 0 }
    var remoteMode: DeviceRecord? {
        guard let deviceID = selectedRemote?.deviceID else { return nil }
        return remoteSessions.first { $0.device.id == deviceID }?.device
    }
    var remoteModeLabel: String? { remoteMode.map { "遠端：\($0.name)" } }
    func deviceConnectionProblem(_ id: String) -> String? {
        remoteSessions.first { $0.device.id.lowercased() == id.lowercased() }?.connectionProblem
    }
    var selectedProjectName: String { selectedThreadProject?.name ?? "無專案" }
    var selectedThreadPluginEntries: [PluginRegistryEntry] {
        guard isLive else { return [] }
        return availableThreadPluginEntries.filter { $0.kind == .mcp && isThreadPluginEnabled($0.id) }
    }
    var shouldOfferCodexMirrorOptIn: Bool { false }
    var shouldShowActiveGoalInlineCard: Bool { isLive && nativeGoalSnapshot != nil }
    var transcriptMessages: [ChatMessage] {
        // W182 R4：選著的遠端串那台連不上時，讀這台存的離線副本（唯讀）。
        isLive ? (activeConversationEngine?.transcript(for: selectedThreadID) ?? remoteOfflineTranscript) : fixture.messages + fixtureExtraMessages
    }

    /// Resolve the selected transcript once; remote turns never read the local engine's state.
    var chatGPTTurnState: ChatGPTCoderTurnState? {
        let messages = transcriptMessages
        guard let reply = messages.last(where: { $0.role == .assistant }),
              reply.runtimeAdapterID == TatwoChatRuntimeAdapter.chatgptTap.rawValue else { return nil }
        let state = selectedRemote == nil ? selectedThreadID.flatMap { localLive?.tapTurn[$0] } : nil
        var result = state ?? ChatGPTCoderTurnState()
        if !isRunning || !reply.text.isEmpty { result.thinking = nil }
        else if result.thinking == nil, reply.status == "writing|ChatGPT 思考中" {
            result.thinking = ChatGPTThinking(started: reply.createdAt)
        }
        if result.failure == nil {
            let draft = messages.last { $0.role == .user && $0.turnID == reply.turnID }?.text ?? ""
            result.failure = ChatGPTTurnFailure.restored(status: reply.status, draft: draft)
        }
        if result.thoughtSeconds == nil, let status = reply.status, status.hasPrefix("done|已思考 "), status.hasSuffix(" 秒") {
            result.thoughtSeconds = Int(status.dropFirst("done|已思考 ".count).dropLast(" 秒".count))
        }
        return result
    }

    func restoreChatGPTInput(_ failure: ChatGPTTurnFailure, in threadID: UUID) {
        guard selectedThreadID == threadID, !isRunning else { return }
        if let remote = selectedRemote {
            guard let engine = activeConversationEngine as? RemoteLiveEngine else { return }
            if failure.isTooLong, let original = engine.threadRecord(threadID) {
                engine.newThread(in: original.projectID, title: "新聊天") { [weak self] newID in
                    guard let self, let newID, selectedThreadID == threadID,
                          selectedRemote?.deviceID == remote.deviceID else { return }
                    let recovered = ChatGPTDraftRecovery.merge(current: prompt, returning: failure.draft)
                    selectedRemote = (remote.deviceID, newID)
                    selectedThreadID = newID
                    if let route = original.requestedModel { selectedModel = route }
                    prompt = recovered
                }
            } else { prompt = ChatGPTDraftRecovery.merge(current: prompt, returning: failure.draft) }
        } else {
            guard let engine = localLive else { return }
            let recovered = ChatGPTDraftRecovery.merge(current: prompt, returning: failure.draft)
            if failure.isTooLong, let original = engine.threadRecord(threadID) {
                let newID = engine.newThread(in: original.projectID)
                engine.setRequestedModel(original.requestedModel, threadID: newID)
                selectLocalThread(newID)
            }
            prompt = recovered
            droppedPaths = failure.paths.filter { !droppedPaths.contains($0) } + droppedPaths
            for (path, name) in failure.names where droppedPathDisplayNames[path] == nil { droppedPathDisplayNames[path] = name }
        }
    }

    /// W100：遠端逐字稿還在背景拉（或這台還沒連上）時，對話區顯示「連線中…」而不是空白。
    var isRemoteTranscriptLoading: Bool {
        guard isLive, selectedRemote != nil, let session = activeRemoteSession else { return false }
        // W182 R4：連不上但快照裡有這條：只有從磁碟讀內容那一下算載入中（沒存內容的另外寫一行說明）。
        guard let remote = session.engine else { return Self.remoteOfflineLoading(session, selectedThreadID) }
        return remote.isTranscriptLoading(selectedThreadID)
            && remote.transcript(for: selectedThreadID).isEmpty
    }

    private var activeRemoteSession: RemoteDeviceSession? {
        guard let deviceID = selectedRemote?.deviceID else { return nil }
        return remoteSessions.first { $0.device.id == deviceID }
    }

    private var activeConversationEngine: (any LiveEngineAPI)? {
        #if DEBUG
        if let double = coderRemoteEngineTestDouble, selectedRemote?.deviceID == double.deviceID { return double.engine }
        #endif
        return selectedRemote == nil ? localLive : activeRemoteSession?.engine
    }
    #if DEBUG
    /// W184 H4 修正第二輪（審查 #7、#10）：自測讓 Coder 看別台時用這個遠端引擎（真的 RemoteLiveEngine，送出交給主設備的 bridge；不開 SSH）。
    var coderRemoteEngineTestDouble: (deviceID: String, engine: RemoteLiveEngine)?
    #endif

    func receiveLocalBackgroundCompletion(_ job: BackgroundJobManager.Record) {
        localLive?.appendBackgroundCompletion(job)
    }

    private var activeConversationDocument: TatwoNativeChatStoreDocument {
        selectedRemote == nil ? document : (activeRemoteSession?.document ?? .init())
    }

    private func configureRemoteSessions() {
        for session in remoteSessions { session.shutdown() }
        resolvedAssistantPrimaryID = nil   // W179 F：配對清單變了，主設備是誰重讀一次
        assistantPrimarySettledIDs = []
        guard isLive else {
            remoteSessions = []
            remoteSidebarSections = []
            return
        }
        remoteSessions = devices.map { device in
            let session = RemoteDeviceSession(
                device: device,
                link: RemoteHostLink(environment: runtimeEnvironment),
                environment: runtimeEnvironment)
            session.onHint = { [weak self] message in
                guard let self else { return }
                // W179 F：主設備那條連線的提示也給助理與私訊框（連不上時畫面已有一行說明，這則只在接著主設備時顯示）。
                if device.id == self.assistantPrimaryDevice?.id { self.showPrimaryHint(message, threadID: nil) }
                guard self.selectedRemote?.deviceID == device.id else { return }
                self.composerHint = message
            }
            session.onUpdate = { [weak self, weak session] in
                guard let self, let session else { return }
                // W179 F：第一次連主設備有結果了（連上或連不上），之後的重試不再當「正在連」。
                if session.state != .connecting { self.assistantPrimarySettledIDs.insert(session.device.id) }
                if session.device.id == self.assistantPrimaryDevice?.id { self.primaryOfflineTick() }   // W182 R5：記前情；連回就補回、送出排隊的
                self.applyPendingModelSelectionIfPossible()
                self.scheduleRemoteSidebarProjection()
                self.completePendingRemoteEntry(session)
                guard self.selectedRemote?.deviceID == session.device.id else {
                    // W179 F：助理與私訊框接在主設備時，主設備那邊一有更新（連上、斷線、新訊息）就重畫。
                    if session.device.id == self.assistantPrimaryDevice?.id { self.objectWillChange.send() }
                    return
                }
                self.isRunning = session.engine?.isRunning(self.selectedThreadID) ?? false
                self.refreshIssueLists()
                self.distillRemoteSessionUpdated(deviceID: session.device.id)   // W180 E4：AI 回覆後 /蒸餾 畫布跟上
                self.objectWillChange.send()
            }
            return session
        }
        rebuildRemoteSidebarSections()
        let synchronousTestConnect =
            runtimeEnvironment["TATWO2_PARALLELTEST"] == "1"
            || runtimeEnvironment["TATWO2_REMOTEUITEST"] == "1"
        for session in remoteSessions {
            if synchronousTestConnect {
                _ = session.connectNow()
            } else {
                session.start()
            }
        }
        if synchronousTestConnect { rebuildRemoteSidebarSections() }
    }

    private func scheduleRemoteSidebarProjection() {
        let elapsed = Date().timeIntervalSince(lastRemoteProjectionAt)
        if elapsed >= 2 {
            rebuildRemoteSidebarSections()
            return
        }
        guard remoteProjectionTask == nil else { return }
        remoteProjectionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(0, 2 - elapsed)))
            guard !Task.isCancelled else { return }
            self.remoteProjectionTask = nil
            self.rebuildRemoteSidebarSections()
        }
    }

    func rebuildRemoteSidebarSections() {   // W182 R4：不再 private（自測裝假遠端設備後直接重算）
        remoteProjectionTask?.cancel()
        remoteProjectionTask = nil
        lastRemoteProjectionAt = Date()
        remoteSidebarSections = remoteSessions.map { session in
            let isOnline: Bool
            if case .online = session.state {
                isOnline = true
            } else {
                isOnline = false
            }
            // W182 R4：離線時照樣列出最後同步的專案與串；每條的狀態行改寫最後活動（快照裡的「執行中」已經不準）。
            let offlineLines: [UUID: String] = isOnline ? [:] : session.offlineMirror.activityLines()
            let projects = session.document.coderProjects.map { project in
                RemoteProjectRow(
                    id: project.id,
                    name: project.name,
                    threads: project.threads.map { thread in
                        let statusLine: String
                        if let liveness = thread.liveness {
                            statusLine = liveness.label
                        } else {
                            statusLine = thread.lastPreview
                        }
                        return RemoteThreadRow(
                            id: thread.id,
                            title: thread.title,
                            statusLine: offlineLines[thread.id] ?? statusLine,
                            isRunning: session.engine?.isRunning(thread.id) ?? false)
                    })
            }
            return RemoteSidebarSection(
                deviceID: session.device.id,
                deviceName: session.device.name,
                isOnline: isOnline,
                lastSeenAt: session.lastSeenAt,
                projects: projects,
                offlineSyncedAt: isOnline || session.offlineMirror.snapshot == nil ? nil : session.offlineMirror.syncedAt)   // W182 R4
        }
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment, botCoreFixture: (ChatLiveEngine, BotStore)? = nil) {
        self.runtimeEnvironment = environment
        let engineLogin = EngineLogin(environment: environment)
        self.engineLogin = engineLogin
        let deviceRegistry = DeviceRegistry(environment: environment)
        self.deviceRegistry = deviceRegistry
        self.devicePairingHost = DevicePairingHost(registry: deviceRegistry, environment: environment)
        self.githubAccountsStore = GitHubAccountsStore(environment: environment)
        let fixture = ChatFixture.resolve(environment: environment)
        self.fixture = fixture
        self.pluginEntries = PluginsSource.load(environment: environment)
        self.selectedModel = fixture.selectedModel
        self.isRunning = fixture.isRunning
        if environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil {
            self.prompt = environment["TATWO_ULTRAWORK_EXPORT_CHAT_PROMPT"] ?? ""
        }
        let liveMode = environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] == nil
            && environment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] == nil
            && environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] == nil
            && environment["TATWO2_SELFTEST"] != "1"
        // 匯出（金樣）模式給兩台假設備，讓設定頁「設備」卡看得到清單的長相
        let fixtureDevices: [DeviceRecord] = [
            DeviceRecord(id: "fixture-macbook", name: "MacBook（範例）", host: "192.0.2.10", user: "example", sshPort: 22,
                         publicKeyFingerprint: "SHA256:qJ3v9nQb1xKfP2wYzR8tL4mH7cD0eA5sV6uB9nC1xYz", addedAt: Date(timeIntervalSinceReferenceDate: 799_000_000),
                         lastSeenAt: Date(timeIntervalSinceReferenceDate: 800_000_000), workdirMap: [:]),
            DeviceRecord(id: "fixture-studio", name: "工作室 Studio（範例）", host: "device.example", user: "example", sshPort: 22,
                         publicKeyFingerprint: "SHA256:aB8cD3eF6gH9iJ2kL5mN8oP1qR4sT7uV0wX3yZ6aB9c", addedAt: Date(timeIntervalSinceReferenceDate: 798_500_000),
                         lastSeenAt: Date(timeIntervalSinceReferenceDate: 799_900_000), workdirMap: [:]),
        ]
        if liveMode { self.devices = deviceRegistry.list() } else { self.devices = fixtureDevices }
        if !liveMode {
            self.gitHubAccounts = [
                GitHubAccountRecord(username: "octocat", displayName: "octocat（範例帳號）", addedAt: Date(timeIntervalSinceReferenceDate: 799_000_000), scopes: ["repo", "workflow"], isDefault: true, folderMappings: [], mcpAlwaysOn: true),
                GitHubAccountRecord(username: "demo", displayName: "demo（範例帳號）", addedAt: Date(timeIntervalSinceReferenceDate: 799_500_000), scopes: ["repo"], isDefault: false, folderMappings: ["\(NSHomeDirectory())/Library/Application Support/tatwo2/repos/demo"], mcpAlwaysOn: false),
            ]
            self.gitHubHelperInstalled = true
        }
        if !liveMode {
            self.engineLogins = [
                EngineLoginStatus(kind: .codex, isLoggedIn: true, account: "demo-account", detail: "登入資料在 App 自己的資料夾，跟 Codex App 分開"),
                EngineLoginStatus(kind: .claude, isLoggedIn: true, account: "demo-account", detail: ""),
                EngineLoginStatus(kind: .grok, isLoggedIn: false, account: nil, detail: "按「登入」會開瀏覽器走 xAI 的授權"),
            ]
        }
        if !liveMode {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            self.engineQuotaDetails = [
                "codex": EngineQuotaDetail(tierLabel: "Pro", accountLabel: "demo-account", expiresAt: now.addingTimeInterval(86_400 * 23), subscribedAt: now.addingTimeInterval(-86_400 * 160),
                                           windows: [.init(id: "codex.primary", label: "週上限", usedPercent: 43, resetsAt: now.addingTimeInterval(3_600 * 52)),
                                                     .init(id: "spark.primary", label: "GPT-5.3-Codex-Spark 5 小時", usedPercent: 0, resetsAt: now.addingTimeInterval(3_600 * 4)),
                                                     .init(id: "spark.secondary", label: "GPT-5.3-Codex-Spark 週上限", usedPercent: 0, resetsAt: now.addingTimeInterval(86_400 * 6))],
                                           creditsBalance: nil, note: "OpenAI 官方額度", fetchedAt: now),
                "claude": EngineQuotaDetail(tierLabel: "Max ×5", accountLabel: "demo-account", expiresAt: nil, subscribedAt: now.addingTimeInterval(-86_400 * 165),
                                            windows: [.init(id: "five_hour", label: "5 小時", usedPercent: 40, resetsAt: now.addingTimeInterval(3_600 * 2)),
                                                      .init(id: "seven_day", label: "週上限", usedPercent: 19, resetsAt: now.addingTimeInterval(86_400 * 5)),
                                                      .init(id: "seven_day_opus", label: "Opus 週上限", usedPercent: 0, resetsAt: nil)],
                                            creditsBalance: nil, note: "Anthropic 官方額度", fetchedAt: now),
                "grok": EngineQuotaDetail(tierLabel: "SuperGrok", accountLabel: "demo-account", expiresAt: nil, subscribedAt: nil, windows: [], creditsBalance: nil, note: "xAI 沒有提供額度查詢接口", fetchedAt: nil),
            ]
        }
        self.isLive = liveMode
        browserTabRegistry = liveMode ? .shared : BrowserTabRegistry()
        browserTabRegistry.titleProvider = { [weak self] sessionID in
            for project in self?.document.projects ?? [] {
                if let thread = project.threads.first(where: { $0.id.uuidString.lowercased() == sessionID.lowercased() }) {
                    return (thread.title, project.name)
                }
            }
            return ("（已不存在的討論串）", "")
        }
        // W181 R3：Claude 的登入方式在背景查到（或變了）就重畫；App 一開先在背景查好（勾了 Claude 才查），畫面和送出都不等。
        apiKeyPolicyObservation = EngineAPIKeyPolicy.shared.changes.sink { [weak self] in self?.objectWillChange.send() }
        if liveMode { EngineAPIKeyPolicy.shared.refreshInBackground(optedOut: disabledEngines) }
        if let (engine, store) = botCoreFixture {
            self.live = engine
            self.localLive = engine
            connectPlanCanvas(to: engine)
            connectArchiveSelection(to: engine)
            self.botStore = store
            self.document = engine.document
            self.selectedThreadID = engine.doc.selectedThreadID
            loadActivePlanCanvas()
            self.isRunning = false
            restoreModelPreferences()
            return
        }
        if liveMode {
            // 使用者 2026-10-03：Coder 初始預設 GPT-6.1 Sol／中思考／Fast；不遷移既有討論串或更動金樣。
            selectedModel = "gpt-6.1-sol"
            selectedEffort = .medium
            selectedSpeedTier = .fast
        }
        CLISessionsTermination.model = self
        if !liveMode {
            let mk = { (id: String, label: String, path: String, state: UpstreamBindingStatus.State, detail: String) in
                UpstreamBindingStatus(target: UpstreamBindingTarget(id: id, label: label, path: path), state: state, detail: detail) }
            self.upstreamBindings = [
                mk("claude-cli", "Claude CLI（~/.claude/CLAUDE.md）", "\(NSHomeDirectory())/.claude/CLAUDE.md", .bound, "已接，跟現在的一頁一致"),
                mk("codex-cli", "Codex CLI（~/.codex/AGENTS.md）", "\(NSHomeDirectory())/.codex/AGENTS.md", .stale, "有代差：一頁規則改過，還沒重新對齊"),
                mk("app-grok", "OS 內的 Grok（獨立資料夾 GROK.md）", "…/engines/grok/GROK.md", .unbound, "還沒接"),
                mk("openclaw:workspace-dashboard", "OpenClaw workspace-dashboard", "\(NSHomeDirectory())/Library/Application Support/tatwo2/openclaw-workspaces/workspace-dashboard/AGENTS.md", .unreachable, "讀不到（資料夾不在或沒權限）"),
            ]
        }
        if !liveMode, Self.exportChatScene == "chat-typing" {
            fixtureExtraMessages = [ChatMessage(role: .user, text: "幫我看一下登入頁的額度條為什麼沒對齊", turnID: "fixture-typing")]
            self.isRunning = true
        }
        if !liveMode, Self.exportChatScene == "chat-artifacts" {
            fixtureExtraMessages = [
                ChatMessage(role: .user, text: "把設定頁的額度條改成靠左，並補一份報告", turnID: "fixture-artifacts"),
                ChatMessage(role: .assistant, text: "改好了：額度條靠左對齊，倒數置中；報告寫在 docs/goal-ui-2.0/reports/quota-bar.md。", status: "done", turnID: "fixture-artifacts"),
            ]
            latestTurnArtifacts = TurnArtifactIndex(
                threadID: UUID(uuidString: "00000000-0000-0000-0000-00000000A0A0")!, turnID: "fixture-artifacts", messageID: nil,
                endedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                artifacts: [
                    TurnArtifact(path: "App/Sources/Tatwo2/New/EngineLoginCard.swift", kind: "file", claimed: true, exists: true, sizeBytes: 18_432, sha256: nil, verifiedBy: "lead"),
                    TurnArtifact(path: "docs/goal-ui-2.0/reports/quota-bar.md", kind: "report", claimed: true, exists: true, sizeBytes: 2_310, sha256: nil),
                    TurnArtifact(path: "docs/UI定位冊/截圖/manifest.tsv", kind: "file", claimed: false, exists: true, sizeBytes: 9_870, sha256: nil),
                    TurnArtifact(path: "shots/quota-bar-after.png", kind: "file", claimed: true, exists: false, sizeBytes: nil, sha256: nil),
                ], truncated: false)
        }
        if !liveMode, Self.exportChatScene == "chat-error" {
            fixtureExtraMessages = [
                ChatMessage(role: .user, text: "跑一下測試", turnID: "fixture-error"),
                ChatMessage(role: .system, text: "回合失敗：{\"error\":{\"message\":\"Rate limit reached for gpt-6-astra: weekly limit exhausted, resets in 3d 4h\",\"type\":\"rate_limit\"},\"turnId\":\"t-8813\"}", status: "error|回合失敗", turnID: "fixture-error"),
            ]
        }
        if !liveMode, Self.exportChatScene == "remote-sidebar" {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            self.remoteSidebarSections = [
                RemoteSidebarSection(deviceID: "fixture-mini", deviceName: "mini（家裡）", isOnline: true, lastSeenAt: now,
                                     projects: [RemoteProjectRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "tatwo2",
                                                                 threads: [RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, title: "左列並行實測", statusLine: "GPT 回覆中", isRunning: true),
                                                                           RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, title: "GitHub MCP 真帳號測試", statusLine: "好", isRunning: false)]),
                                                RemoteProjectRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "一般",
                                                                 threads: [RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!, title: "PO 文 bot", statusLine: "乒", isRunning: false)])]),
                RemoteSidebarSection(deviceID: "fixture-studio", deviceName: "工作室 Studio（範例）", isOnline: false, lastSeenAt: now.addingTimeInterval(-3_600 * 5), projects: []),
            ]
        }
        if !liveMode, let first = OSDocuments.list().first {
            osDocumentText[first.id] = "# TATWO OS 2.0 憲法（示意）\n\n## 0. 一句話\nOS 是所有 AI 引擎的上游：規則、技能、工具、記錄由 OS 統一發，引擎只是肌肉。\n\n## 3. 硬規則\n1. 拆之前先討論；封存不直刪；沒有回覆就不動。\n2. 派工無監工＝不算在跑；沉默≠進度。\n"
        }
        self.githubAccountsStore.$deviceCode.assign(to: &$githubDeviceCode)
        self.githubAccountsStore.$verificationURL.assign(to: &$githubVerificationURL)
        self.githubAccountsStore.onEvent = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendGitHubLoginLog(message)
            }
        }
        refreshGitHubAccounts()
        self.devicePairingHost.onClose = { [weak self] in
            Task { @MainActor in
                self?.pairingWindow = nil
                self?.pairingListenAddress = nil
                self?.devices = self?.deviceRegistry.list() ?? []
                self?.configureRemoteSessions()
            }
        }
        if liveMode {
            let root = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let store = ChatLiveStore(root: root)
            let engine = ChatLiveEngine(store: store, environment: environment)
            self.cliSessionStore = CLISessionStore(root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/live"))
            self.previousCLITabIDs = Set(self.cliSessionStore?.sessions.map(\.id) ?? [])
            self.cliStore = store
            self.localLive = engine
            connectPlanCanvas(to: engine)
            connectArchiveSelection(to: engine)
            self.live = engine
            engine.autoApprove = permissionPreset == .approveForMe
            engine.userPermissionPreset = permissionPreset
            self.botStore = BotStore(root: root)
            self.document = engine.document
            do {
                try browserTabRegistry.migrateLegacyBookmarks(
                    at: TatwoRuntimeLayout.applicationSupportRoot().appendingPathComponent("browser-bookmarks-v1.json"),
                    sessionIDs: Set(document.projects.flatMap { $0.threads.map { $0.id.uuidString.lowercased() } }))
            } catch {
                IslandNotice.shared.info(title: "舊書籤尚未遷移", detail: error.localizedDescription)
            }
            self.selectedThreadID = engine.doc.selectedThreadID
            loadActivePlanCanvas()
            self.localSelectedThreadID = engine.doc.selectedThreadID
            self.isRunning = false
            restoreModelPreferences()
            engine.onChange = { [weak self] in
                guard let self, let live = self.live else { return }
                self.document = live.document
                if self.selectedRemote == nil {
                    self.isRunning = live.isRunning(self.selectedThreadID)
                }
                self.applyPendingModelSelectionIfPossible()
                if SpaceWorkspaceController.shared.state != nil { self.applySpaceRuntimePreferences() }
                if self.selectedRemote == nil {
                    self.refreshIssueLists()
                    if !self.isRunning { self.refreshGitStatus() }
                }
                self.objectWillChange.send()
            }
            refreshIssueLists(); refreshGitStatus()
            engine.onHint = { [weak self] hint in self?.composerHint = hint }
            engine.onRoomArchived = { [weak self, weak engine] roomID in
                guard let self, let engine else { return }
                do {
                    _ = try self.reclaimRoom(roomID)
                } catch {
                    engine.appendSystemMessage(
                        threadID: roomID,
                        text: "房間封存但工作樹回收失敗：\(error)",
                        status: "error|房間回收")
                }
            }
            engine.permissionDecider = { [weak self] tool, input in
                guard let self else { return false }
                let alert = NSAlert()
                alert.messageText = "工具執行需要核准：\(tool)"
                alert.informativeText = String(input.prefix(1200))
                alert.addButton(withTitle: "允許"); alert.addButton(withTitle: "拒絕")
                return alert.runModal() == .alertFirstButtonReturn
            }
            if environment["TATWO2_BOTTEST"] == "1" {
                scheduleBotSelfTest(environment: environment)
            }
            reloadPluginRegistry()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await SpaceWorkspaceController.shared.load(model: self)
                if SpaceWorkspaceController.shared.allows(.cli) {
                    self.initializeCLIWorkbench(environment: environment)
                    self.loadPersistedCLISessionBook()
                }
                self.applySpaceRuntimePreferences()
            }
            BrowserAgentBridge.shared.start(model: self)
            BreachDetector.shared.onAssistAI = { id in
                BrowserAgentBridge.shared.changeAIPassword(id, automaticallyAssisted: true)
            }
            BreachDetector.shared.start()
            OSAgentBridge.shared.start(model: self)
            Task { @MainActor [weak self] in
                self?.refreshEngineModelCatalogOnce()
                self?.refreshEngineLogins()
            }
            configureRemoteSessions()
            return
        }

        let threadID = UUID(uuidString: "E3DB5E91-9B88-4485-87B9-AB7B877C2E21")!
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: fixture.threadTitle,
            isPinned: true,
            lastPreview: fixture.messages.last?.text ?? "",
            workOSContractID: fixture.hasWorkOSGoal ? "fixture-contract" : nil,
            workOSGoalID: fixture.hasWorkOSGoal ? "fixture-goal" : nil)
        if fixture.sceneID == "orphan" {
            self.document = TatwoNativeChatStoreDocument(projects: [])
        } else {
            var threads = [thread]
            if Self.exportChatScene == "subthreads" || Self.isDispatchExportScene {
                // B1／B3 假資料：主串底下三條子討論串（active／idle／done）
                let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
                threads += [
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B301")!, title: "房間A 升版與遷移", lastPreview: "正在跑 doctor --fix", parentThreadID: threadID, liveness: .active, lastOutputAt: now.addingTimeInterval(-180), engineLabel: "sol"),
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B302")!, title: "房間B Discord 外掛", lastPreview: "等待 npm", parentThreadID: threadID, liveness: .idle, lastOutputAt: now.addingTimeInterval(-6 * 60), engineLabel: "sol"),
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B303")!, title: "副審", lastPreview: "報告已送出", parentThreadID: threadID, liveness: .done, lastOutputAt: now.addingTimeInterval(-20 * 60), engineLabel: "opus"),
                ]
            }
            self.document = TatwoNativeChatStoreDocument(
                projects: [
                    TatwoNativeChatProject(
                        name: "Tatwo2 UI",
                        workdir: FileManager.default.currentDirectoryPath,
                        threads: threads)
                ])
            if ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_SETTINGS_SECTION"] == "browserManagement" {
                // B5 假資料：兩條討論串留著開啟的網頁
                var lanes = TatwoBrowserLaneState()
                lanes = TatwoBrowserLaneReducer.reduce(state: lanes, action: .open(id: TatwoBrowserLaneID(rawValue: "fx-1"), binding: .unboundReadOnly, title: "TradingView"), now: Date(timeIntervalSinceReferenceDate: 800_000_000))
                let snap = BrowserLaneSnapshot(laneState: lanes, laneURLs: ["fx-1": URL(string: "https://tw.tradingview.com/symbols/BTCUSD/")!], updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
                browserTabRegistry.storeLanes(snap, for: threadID.uuidString.lowercased())
            }
        }
        self.selectedThreadID = threadID
        if Self.exportChatScene == "cli-多session" {
            mode = .cli
            cliUIFixtureRecords = CLISessionsFixture.records
            let tabs = cliUIFixtureRecords.prefix(3).map { record in
                TatwoNativeCLISessionBook.Session(id: record.id, engine: .init(rawValue: record.engine) ?? .generic, title: record.title,
                    workdir: record.cwd, createdAt: record.createdAt, updatedAt: record.lastActiveAt,
                    isRunning: record.status != .exited)
            }
            cliSessionsByThread[threadID] = tabs
            activeCLITabByThread[threadID] = tabs.first?.id
            for tab in tabs {
                cliTabOwner[tab.id] = threadID
                cliTabLinesByID[tab.id] = CLISessionsFixture.output.enumerated().map {
                    TatwoTerminalLine(id: $0.offset, spans: [.init(text: $0.element)])
                }
            }
        }
    }
    func refreshIssueLists() {
        guard let activeLive = activeConversationEngine else { return }
        allIssueListEntries = activeLive.issues(threadID: nil, global: true)
        issueListEntries = activeLive.issues(
            threadID: selectedThreadID,
            global: issueListShowsGlobal)
        archivedIssueListEntries = allIssueListEntries.filter { $0.status == .archived }
    }
    func refreshGitStatus() {
        guard selectedRemote == nil else {
            gitBranch = "—"
            gitChangedFileCount = 0
            gitChangedFilePreview = []
            gitChangedFiles = []
            gitChangedLineAdditions = 0
            gitChangedLineDeletions = 0
            return
        }
        guard let live else { return }
        refreshLatestTurnArtifacts()
        live.gitSummary(for: selectedThreadID) { [weak self] g in
            guard let self else { return }
            self.gitBranch = g.branch; self.gitChangedFileCount = g.files.count
            self.gitChangedFilePreview = Array(g.files.prefix(5))
            self.gitChangedFiles = g.files.map { ChatGitChangedFileSummary(path: $0, additions: g.perFile[$0]?.0 ?? 0, deletions: g.perFile[$0]?.1 ?? 0) }
            self.gitChangedLineAdditions = g.additions; self.gitChangedLineDeletions = g.deletions
        }
    }
    /// 讀最新回合的產出索引（背景讀檔，主執行緒只收結果）。
    func refreshLatestTurnArtifacts() {
        guard let threadID = selectedThreadID, let engine = live as? ChatLiveEngine else { latestTurnArtifacts = nil; return }
        let artifacts = engine.turnArtifacts
        Task { [weak self] in
            let index = try? await artifacts.list(threadID: threadID)   // actor：讀檔在它自己的執行緒
            guard let self, self.selectedThreadID == threadID else { return }
            self.latestTurnArtifacts = index
        }
    }

    /// 回合收尾卡點檔名：用系統預設程式打開工作樹裡的那個檔。
    func openArtifact(path: String) {
        guard !path.hasPrefix("/"), !path.contains("..") else { return }
        let engine = live as? ChatLiveEngine
        let record = selectedThreadID.flatMap { engine?.threadRecord($0) }
        let cwd = record.flatMap { t in t.cwdOverride ?? engine?.doc.projects.first { $0.id == t.projectID }?.workdir } ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { flashComposerHint("檔案不在了：\(path)"); return }
        NSWorkspace.shared.open(url)
    }

    func refreshAfterGoalRevisionPromotion() -> Bool { true }
    func scheduleColdStartHydrationAfterFirstFrame() {}
    func retryColdStartHydration() {}
    func reloadIssueList() {
        refreshIssueLists()
    }
    @Published var osDocumentSaveStatus: [String: String] = [:]
    @Published var osDocumentReadErrors: [String: String] = [:]

    func loadOSDocument(id: String) {
        osDocuments = OSDocuments.list()
        do {
            osDocumentText[id] = try OSDocuments.read(id: id)
            osDocumentReadErrors[id] = nil
        } catch {
            osDocumentText[id] = nil
            osDocumentPending[id] = nil
            osDocumentReadErrors[id] = error.localizedDescription
            flashComposerHint("讀取文件失敗：\(error.localizedDescription)")
        }
    }
    func saveOSDocument(id: String, text: String) {
        do {
            let outcome = try OSDocuments.write(id: id, text: text)
            osDocumentText[id] = text
            osDocumentPending[id] = nil
            osDocumentReadErrors[id] = nil
            osDocumentSaveStatus[id] = outcome.message
            osDocuments = OSDocuments.list()
            flashComposerHint(outcome.message)
        } catch {
            osDocumentSaveStatus[id] = "儲存失敗：\(error.localizedDescription)"
            loadOSDocument(id: id)
            flashComposerHint("儲存文件失敗：\(error.localizedDescription)")
        }
    }
    func tidyOSDocument(id: String) {
        guard isLive, let live else {
            flashComposerHint("請 AI 整理只在 live 模式可用")
            return
        }
        let source: String
        do {
            source = try OSDocuments.read(id: id)
        } catch {
            flashComposerHint("讀取文件失敗：\(error.localizedDescription)")
            return
        }
        guard let document = OSDocuments.list().first(where: { $0.id == id }) else {
            flashComposerHint("找不到文件：\(id)")
            return
        }

        let engine: ClaudeSidecar.Kind
        let modelArgument: String?
        switch routeChoice.brandGroup {
        case .anthropic:
            engine = .claude
            modelArgument = routeChoice.modelArgument
        case .openAI:
            engine = .codex
            modelArgument = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
        case .xAI:
            engine = .grok
            modelArgument = nil
        default:
            flashComposerHint("\(routeChoice.title) 還沒有可用的文件整理水電")
            return
        }
        // 送出前只看快取的登入狀態（背景更新），不在主執行緒起子程序查；沒查過就先放行，引擎自己會報錯
        let loginStatus = engineLogins.first(where: { $0.kind == engine })
            ?? EngineLoginStatus(kind: engine, isLoggedIn: true, account: nil, detail: "尚未檢查")
        guard loginStatus.isLoggedIn else {
            flashComposerHint("\(engineLoginDisplayName(engine)) 還沒登入，到設定 › 登入")
            return
        }

        let projectID = live.doc.projects.first(where: { $0.name == "一般" })?.id
            ?? live.newProject(name: "一般", workdir: OSDocuments.docsRoot)
        let title = "文件整理：\(document.title)"
        let threadID = live.doc.threads.first(where: {
            $0.projectID == projectID && $0.title == title && !$0.isArchived
        })?.id ?? live.newThread(in: projectID, title: title)
        guard !live.isRunning(threadID) else {
            flashComposerHint("\(document.title) 的文件整理還在進行中")
            return
        }

        let previousReplyID = live.transcript(for: threadID)
            .last(where: { $0.role == .assistant && $0.eventKind == .message })?.id
        let note = osDocumentNote[id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = """
        把這份文件整理乾淨、保留所有規則、不新增規則、輸出完整檔案。

        檔案：\(document.title)
        使用者這次留的話：
        \(note.isEmpty ? "（沒有另外留言）" : note)

        目前完整內容：
        \(source)
        """
        osDocumentPending[id] = nil
        live.send(
            threadID: threadID,
            text: request,
            model: modelArgument,
            engine: engine,
            systemPrompt: nil,
            attachments: [])
        flashComposerHint("已送到「一般 › \(title)」；完成後先顯示差異，不會自動覆寫")

        Task { @MainActor [weak self, weak live] in
            guard let self, let live else { return }
            for _ in 0..<2_400 {
                try? await Task.sleep(for: .milliseconds(500))
                if live.isRunning(threadID) { continue }
                guard let reply = live.transcript(for: threadID)
                    .last(where: { $0.role == .assistant && $0.eventKind == .message }),
                      reply.id != previousReplyID
                else {
                    self.flashComposerHint("\(document.title) 整理沒有取得助理完整回覆")
                    return
                }
                self.osDocumentPending[id] = reply.text
                self.flashComposerHint("\(document.title) 整理完成；請先看差異，再按套用")
                return
            }
            self.flashComposerHint("\(document.title) 整理等待逾時，原檔未變更")
        }
    }
    func revalidatePendingRemoteTarget(verifiedTargetDeviceIDs: Set<String>?, definitiveLeaseLossBlocker: String?) {}
    func removeIssueListEntry(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        live?.removeIssue(id)
        refreshIssueLists()
    }
    func restoreIssueFromArchive(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        live?.updateIssue(id) { $0.status = .queued }
        refreshIssueLists()
    }
    /// 1.0 規格（os1-root/issue.md）：雙擊＋彈窗＋按「確認」共三段；單擊 no-op、取消保留。只封存佇列項，原討論不動。
    func archiveIssueListEntry(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        let title = allIssueListEntries.first(where: { $0.id == id })?.title ?? ""
        if isLive {
            let alert = NSAlert()
            alert.messageText = "從佇列移除這則 issue？"
            alert.informativeText = "「\(title)」只會從佇列封存，原本的討論串與計畫不會被刪改。"
            alert.addButton(withTitle: "確認移除")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        live?.updateIssue(id) { $0.status = .archived }
        refreshIssueLists()
        flashComposerHint("已從佇列移除「\(title)」")
    }
    @discardableResult
    func openCLITab(engine: TatwoNativeCLISessionBook.Engine, workdir: String? = nil, callerThreadID: UUID? = nil, extraArguments: [String] = []) -> UUID? {
        guard isCLIRuntimeEnabled, selectedRemote == nil, let ownerID = callerThreadID ?? selectedThreadID else { return nil }
        guard !isLive || cliRuntime != nil else {
            flashComposerHint("CLI 正在讀取 Space 設定，請稍後再開啟")
            return nil
        }
        let cwd = workdir ?? selectedThreadProject?.workdir ?? NSHomeDirectory()
        if engine != .generic, let problem = ExternalWorkspacePolicy.engineProblem(cwd: cwd) { flashComposerHint(problem); return nil }   // W183 R6c 審查
        let number = (cliSessionsByThread[ownerID]?.count ?? 0) + 1
        let title = "\(cliEngineTitle(engine)) \(number)"
        let tab = TatwoNativeCLISessionBook.Session(
            id: UUID(),
            engine: engine,
            title: title,
            workdir: cwd,
            createdAt: Date(),
            updatedAt: Date(),
            isRunning: false)
        cliSessionsByThread[ownerID, default: []].append(tab)
        activeCLITabByThread[ownerID] = tab.id
        cliTabOwner[tab.id] = ownerID
        startCLITab(tab, launch: launchForCLI(engine: engine, workdir: cwd, extraArguments: extraArguments))
        registerCLIWorkbenchPane(tab, owner: ownerID)
        persistCLITabs(ownerID: ownerID)
        objectWillChange.send()
        return tab.id
    }
    /// W110：各家 CLI 自己寫的 session 檔位置；假資料模式不讀使用者的真實對話。
    var cliTranscriptSources: [CLITranscriptArchive.Source] {
        isLive ? CLITranscriptArchive.defaultSources(enginesRoot: engineLogin.paths.enginesRoot) : []
    }
    /// W110：接續一段過去的 CLI 對話。只是執行該引擎自己的 resume；權限照它自己的機制。
    func resumeCLITranscript(_ session: CLITranscriptSession) {
        guard let arguments = CLITranscriptArchive.resumeArguments(session) else {
            flashComposerHint(CLITranscriptArchive.resumeBlockedReason(session) ?? "這段對話無法接續"); return
        }
        var isDirectory: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory) && isDirectory.boolValue ? session.cwd : nil
        switch session.origin {
        case .osEngine:
            guard openCLITab(engine: session.engine == .claude ? .claude : .codex, workdir: cwd, extraArguments: arguments) != nil else { return }
        case .native:
            // 使用者平常那個 CLI 的記憶、技能都在他自己的環境裡；用一般 shell 分頁執行，不套 OS 的隔離家目錄。
            guard let id = openCLITab(engine: .generic, workdir: cwd) else { return }
            let line = ([session.engine.rawValue] + arguments).joined(separator: " ")
            Task { [weak self] in
                do { try await self?.cliTabPTYSession(for: id)?.sendLineAwaited(line) }
                catch { self?.flashComposerHint("接續失敗：\(error.localizedDescription)") }
            }
        }
        cliHistoryPresented = false
    }
    func selectCLITab(_ id: UUID) {
        guard let ownerID = cliTabOwner[id] else { return }
        if selectedThreadID != ownerID {
            selectedThreadID = ownerID
        }
        activeCLITabByThread[ownerID] = id
        focusCLIWorkbenchPane(id, owner: ownerID)
        cliSessionStore?.update(id) { $0.lastActiveAt = Date() }
        objectWillChange.send()
    }
    func closeCLITab(_ id: UUID) {
        Task { [weak self] in
            do { try await self?.terminateCLIWorkbenchPane(id) }
            catch { self?.composerHint = "無法結束終端：\(error.localizedDescription)" }
        }
    }
    var restorableCLITabs: [CLISessionStore.Record] {
        isLive ? (cliSessionStore?.sessions.filter { previousCLITabIDs.contains($0.id) } ?? []) : Array(cliUIFixtureRecords.dropFirst(3))
    }
    var cliTabsNeedingCloseConfirm: [CLISessionStore.Record] {
        cliSessionStore?.sessions.filter { cliTabPTYByID[$0.id]?.isRunning == true } ?? []
    }
    func terminateAllCLITabs() {
        for session in cliTabPTYByID.values { session.terminate() }
    }
    func renameCLITab(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        cliSessionStore?.update(id) { $0.title = title }
        if let owner = cliTabOwner[id], let i = cliSessionsByThread[owner]?.firstIndex(where: { $0.id == id }) {
            cliSessionsByThread[owner]?[i].title = title
            persistCLITabs(ownerID: owner)
        }
        objectWillChange.send()
    }
    func pinCLITab(_ id: UUID, pinned: Bool = true) {
        cliSessionStore?.update(id) { $0.pinned = pinned }
        objectWillChange.send()
    }
    func reorderCLITabs(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let all = (ids + (cliSessionStore?.sessions.map(\.id) ?? [])).filter { seen.insert($0).inserted }
        for (order, id) in all.enumerated() {
            cliSessionStore?.update(id) { $0.order = order }
            if !isLive, let index = cliUIFixtureRecords.firstIndex(where: { $0.id == id }) {
                cliUIFixtureRecords[index].order = order
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
        for owner in Array(cliSessionsByThread.keys) {
            cliSessionsByThread[owner]?.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
            persistCLITabs(ownerID: owner)
        }
        objectWillChange.send()
    }
    func cliTabStatus(_ id: UUID) -> CLISessionStatus {
        cliUIRecord(id)?.status ?? .exited
    }
    func cliTabScrollback(_ id: UUID) -> String { isLive ? (cliSessionStore?.scrollback(id) ?? "") : cliTabLines(for: id).map(\.plainText).joined(separator: "\n") }
    func sendCLITabOutputToChat(_ id: UUID, lines: Int = 80) {
        Task { [weak self] in
            guard let self else { return }
            let tail = isLive ? await cliWorkbenchTail(id) : cliTabScrollback(id)
            let text = CLISessionStore.textTail(tail, lines: lines)
            prompt += (prompt.isEmpty ? "" : "\n") + text
        }
    }
    @discardableResult
    func restoreCLITab(_ id: UUID) async -> UUID? {
        guard isCLIRuntimeEnabled else { return nil }
        await refreshCLIWorkbenchSessions()
        guard let record = cliSessionStore?.sessions.first(where: { $0.id == id }),
              let owner = record.threadID ?? selectedThreadID else { return nil }
        if cliTabPTYByID[id] == nil { hydrateCLIWorkbenchRecord(record, owner: owner) }
        // Dead sessions open a read-only snapshot with the SAME identity, never a new command.
        if cliTabPTYByID[id]?.isRunning != true {
            let text = await cliSessionStore?.loadScrollback(id) ?? ""
            cliTabLinesByID[id] = text.components(separatedBy: "\n").enumerated().map { TatwoTerminalLine(id: $0.offset, spans: [.init(text: $0.element)]) }
            if let session = cliTabPTYByID[id], session.display == nil {
                let display = NativeTerminalPTYNSView(session: session)
                session.display = display
                display.feed(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
        }
        guard let tab = cliSessionsByThread[owner]?.first(where: { $0.id == id }) else { return nil }
        cliSessionStore?.update(id) { $0.background = false }
        registerCLIWorkbenchPane(tab, owner: owner)
        selectedThreadID = owner
        selectCLITab(id)
        return id
    }
    func cliTabLines(for id: UUID) -> [TatwoTerminalLine] { cliTabLinesByID[id] ?? [] }
    func cliTabPTYSession(for id: UUID) -> CLIWorkbenchTerminalSession? { cliTabPTYByID[id] }
    func cliTabProcessID(for id: UUID) -> Int32? { cliTabPIDByID[id] }
    func loadPersistedCLISessionBook() {
        guard isLive, isCLIRuntimeEnabled, let threadID = selectedThreadID, !loadedCLIThreadIDs.contains(threadID) else { return }
        loadedCLIThreadIDs.insert(threadID)
        // Old tabs are historical, never silently respawn a process on navigation.
        // Import pre-store metadata once without claiming its processes are alive.
        for old in cliStore?.cliTabs(threadID: threadID) ?? [] {
            guard cliSessionStore?.sessions.contains(where: { $0.id == old.id }) == false else { continue }
            cliSessionStore?.insert(.init(id: old.id, title: old.title, engine: old.engine,
                cwd: old.cwd, createdAt: Date(), lastActiveAt: Date(), status: .exited,
                pinned: false, order: cliSessionStore?.sessions.count ?? 0, threadID: threadID, background: true))
            previousCLITabIDs.insert(old.id)
        }
        objectWillChange.send()
    }
    func prepareCLITabs() {
        guard isLive, isCLIRuntimeEnabled else { return }
        // Navigation is attach-only. Absent/dead tmux sessions must never be respawned.
        Task { [weak self] in await self?.refreshCLIWorkbenchSessions() }
    }
    func makeChatSearchIndex() -> TatwoChatSearchIndex { .init(documents: []) }
    func jumpToSearchResult(_ document: TatwoChatSearchDocument) {
        guard isLive, let threadID = document.threadID else { return }
        selectedDiscussionID = nil
        selectedThreadID = threadID
    }
    func startActiveGoalTimerIfNeeded() {}
    func stopActiveGoalTimer() {}
    func toggleActiveGoalPause() {
        guard isLive else { fixtureActiveGoalPaused.toggle(); return }
        guard canControlActiveGoal, !activeGoalPaused || canResumeActiveGoal else { return }
        changeNativeGoal(status: activeGoalPaused ? "active" : "paused")
    }
    func endActiveGoal() {
        guard isLive, canControlActiveGoal else { return }
        changeNativeGoal(status: nil)
    }
    private func changeNativeGoal(status: String?) {
        guard selectedRemote == nil, let id = selectedThreadID, let localLive else { return }
        if status == "active", !nativeGoalLoginReady() { return }
        let accepted = localLive.setNativeGoal(threadID: id, status: status) { [weak self] accepted, error in
            guard let self, self.selectedThreadID == id else { return }
            if !accepted { self.flashComposerHint(error ?? "目標操作未確認") }
        }
        if !accepted { flashComposerHint("目前無法操作目標，原狀態已保留") }
    }
    private func nativeGoalLoginReady() -> Bool {
        let status = engineLogin.status(for: .codex)
        replaceEngineLoginStatus(status)
        guard status.isLoggedIn else {
            flashComposerHint("Codex 還沒登入，到設定 › 登入")
            return false
        }
        return true
    }
    /// W180 D3：放行寫進「那則訊息所屬的討論串」（threadID 由畫訊息的那串逐字稿帶來），
    /// 不是 Coder 目前選中的那條；引擎也看那一條。遠端或不認得的討論串不放行，也不改寫到別條。
    func allowMCPTool(named tool: String, threadID: UUID?) {
        guard tool.hasPrefix("mcp__") else { return }
        let rest = tool.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return }
        let server = String(rest[..<separator.lowerBound])
        // 不是這台能寫的那條（主設備那條、正在看的遠端那條、找不到）：放行鈕本來就不畫，這裡只擋畫完才變的那一下。
        guard let threadID, canAllowMCP(threadID: threadID), let localLive else {
            flashComposerHint("這則訊息的對話不在這台，沒有放行")
            return
        }
        let engine = mcpEngine(for: threadID)
        guard let entry = pluginEntries.first(where: {
            $0.kind == .mcp && PluginsSource.mcpEngine(from: $0.id) == engine
                && PluginsSource.mcpName(from: $0.id) == server
        }) else { return }
        localLive.setEnabledMCP(entry.id, enabled: true, engine: engine, threadID: threadID)
        objectWillChange.send()
    }
    /// W180 D3：這條討論串的權限能不能在這台放行——要是本機文件裡的那條；
    /// 主設備那條（助理接在主設備時）、Coder 正在看的遠端那條，就算本機剛好留著同 id 的一份也不行。
    func canAllowMCP(threadID: UUID?) -> Bool {
        guard isLive, let threadID, selectedRemote?.threadID != threadID,
              assistantPrimaryEngine?.doc.assistantThreadID != threadID,
              let localLive else { return false }
        return localLive.threadRecord(threadID) != nil
    }
    /// W180 D3：放行鈕的位置要換成的一行白話（nil＝這台能放行，照常畫鈕）。
    func mcpAllowBlockedNote(threadID: UUID?) -> String? {
        if canAllowMCP(threadID: threadID) { return nil }
        if let threadID, assistantPrimaryEngine?.doc.assistantThreadID == threadID {
            return "這條對話在主設備上，要到主設備放行"
        }
        if let threadID, selectedRemote?.threadID == threadID { return "這條對話在遠端設備上，要到那台放行" }
        return "找不到這則訊息所屬的對話，這裡沒辦法放行"
    }
    private func connectArchiveSelection(to engine: ChatLiveEngine) {
        engine.onThreadArchived = { [weak self] archived, next in
            guard let self, self.selectedRemote == nil, self.selectedThreadID == archived else { return }
            self.selectLocalThread(next)
        }
    }
    private func connectPlanCanvas(to engine: ChatLiveEngine) {
        engine.onPlanChange = { [weak self] plan in
            guard let self, self.selectedRemote == nil, self.selectedThreadID == plan.threadID else { return }
            self.activePlanArtifact = plan
            self.refreshArchivedCanvasList()
        }
        loadActivePlanCanvas()
    }
    private func loadActivePlanCanvas() {
        activePlanArtifact = nil
        localCanvasArchives = []
        distillState.archivedCanvases = []
        if selectedRemote != nil { refreshRemoteDistillCanvas(); return }   // W180 E4：遠端只讀 /蒸餾 畫布
        guard selectedRemote == nil, let id = selectedThreadID, let engine = localLive else { return }
        do { activePlanArtifact = try engine.loadPlanArtifact(id, recoverInterrupted: !preparingPR && !pendingPR.contains(id)) }
        catch { flashComposerHint("計畫讀取失敗；原檔保留，請先修復資料") }
        refreshArchivedCanvasList()
    }
    @discardableResult
    private func persistPlanCanvas(_ plan: TatwoPlanArtifactV1) -> Bool {
        guard let engine = localLive else { return false }
        do {
            try engine.savePlanArtifact(plan)
            if selectedThreadID == plan.threadID { activePlanArtifact = plan }
            return true
        } catch {
            flashComposerHint("計畫儲存失敗，未套用修改")
            return false
        }
    }
    func exitActiveCanvasMode() {
        if selectedRemote != nil { exitRemoteDistillMode(); return }
        guard var plan = activePlanArtifact, let engine = localLive,
              !preparingPR, !pendingPR.contains(plan.threadID), !DistillHost.inFlight.contains(plan.planID) else {
            flashComposerHint("請等畫布作業完成再離開"); return
        }
        do {
            if plan.kind == "pr" {
                plan.prModeExited = true
                try engine.savePlanArtifact(plan)
            } else {
                try engine.archivePlanArtifact(plan)
                activePlanArtifact = nil
                refreshArchivedCanvasList()
            }
            flashComposerHint(plan.kind == "pr" ? "已離開 PR 模式；畫布已保留" : "已離開模式；畫布已保留，可從封存畫布還原")
        } catch { flashComposerHint("離開模式失敗；原畫布保留：\(error.localizedDescription)") }
    }

    var archivedPlanCanvases: [CanvasArchiveOption] {
        selectedRemote == nil ? localCanvasArchives : distillState.archivedCanvases.map(CanvasArchiveOption.init)
    }

    func refreshArchivedCanvasList() {
        guard selectedRemote == nil, let id = selectedThreadID, let engine = localLive else { return }
        do { localCanvasArchives = try engine.archivedPlanArtifacts(id).map(CanvasArchiveOption.init) }
        catch {
            localCanvasArchives = []
            flashComposerHint("封存畫布讀取失敗；原檔保留")
        }
    }

    func restoreArchivedCanvas(_ planID: UUID) {
        if selectedRemote != nil { restoreRemoteDistillCanvas(planID); return }
        guard let id = selectedThreadID, let engine = localLive,
              !preparingPR, !pendingPR.contains(id), !DistillHost.inFlight.contains(activePlanArtifact?.planID ?? UUID()) else { return }
        do {
            activePlanArtifact = try engine.restorePlanArtifact(id, planID: planID)
            refreshArchivedCanvasList()
            planInspectorRequest = UUID()
        } catch { flashComposerHint("還原畫布失敗；封存保留：\(error.localizedDescription)") }
    }

    var canvasModeLabel: String? {
        guard let plan = activePlanArtifact else { return nil }
        if plan.kind == "pr" { return plan.isPRModeActive ? "PR · 討論中" : nil }
        if plan.kind == "feedback" { return plan.state == .discussing ? "回報 · 整理中" : nil }
        if plan.kind == "distill" { return plan.distillSubmission == nil ? "蒸餾 · 草稿" : nil }
        return plan.executionTurnID == nil ? (plan.state == .discussing ? "計畫 · 討論中" : "計畫 · 等待開始") : nil
    }

    private func handleCanvasExitCommand() -> Bool {
        let tokens = prompt.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard tokens.count == 2, ["/plan", "/pr", "/feedback", "/蒸餾"].contains(String(tokens[0])),
              ["off", "exit", "stop", "關閉", "結束"].contains(tokens[1].lowercased()) else { return false }
        if activePlanArtifact != nil { exitActiveCanvasMode() }
        else { flashComposerHint("目前沒有畫布模式") }
        if activePlanArtifact == nil || activePlanArtifact?.prModeExited == true { prompt = "" }
        return true
    }

    func confirmActivePlan() {
        guard routeChoice.runtimeAdapter != .chatgptTap else { flashComposerHint(CanvasCommandPolicy.tapUnsupported); return }
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind != "feedback", plan.kind != "distill", plan.state == .discussing,
              localLive?.isRunning(plan.threadID) == false, !preparingPR, !pendingPR.contains(plan.threadID) else { return }
        if plan.kind == "pr" {
            do { _ = try PullRequestCoordinator.shared.identity() }
            catch { plan.prMessage = error.localizedDescription; _ = persistPlanCanvas(plan); return }
        }
        plan.prMessage = nil
        plan.confirm()
        if persistPlanCanvas(plan) {
            // W170：確認的計畫成為這串的一條目標（同名已在清單就不重複加）。
            if plan.kind == nil || plan.kind == "plan" {
                let title = plan.objective
                try? ThreadGoalStore.shared.update(plan.threadID) { list in
                    guard !list.goals.contains(where: { $0.title == title }) else { return }
                    _ = try ThreadGoalRules.add(&list, title: title, userWords: "計畫：" + title, proposed: false)
                }
            }
            if plan.kind == "pr" {
                startPRContribution(description: plan.editableText(), threadID: plan.threadID)
                return
            }
            localLive?.appendSystemMessage(threadID: plan.threadID, text: "計畫已確認；按「開始實作」或說「開始」即執行", status: "info|Plan")
        }
    }
    func startActivePlan() {
        guard routeChoice.runtimeAdapter != .chatgptTap else { flashComposerHint(CanvasCommandPolicy.tapUnsupported); return }
        guard selectedRemote == nil, let plan = activePlanArtifact, plan.acceptsStart("開始"),
              selectedThreadID == plan.threadID, localLive?.isRunning(plan.threadID) == false,
              !preparingPR, !pendingPR.contains(plan.threadID) else { return }
        // Reuse normal routing without sending or consuming the existing composer draft.
        let draft = prompt, paths = droppedPaths, names = droppedPathDisplayNames
        defer { prompt = draft; droppedPaths = paths; droppedPathDisplayNames = names }
        prompt = "開始"
        droppedPaths = []; droppedPathDisplayNames = [:]
        send()
    }
    func returnActivePRToDiscussion() {
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind == "pr",
              plan.prImplementationInterrupted == true, plan.state == .discussing,
              localLive?.isRunning(plan.threadID) == false, !preparingPR,
              !pendingPR.contains(plan.threadID) else { return }
        plan.prImplementationInterrupted = nil
        plan.prMessage = nil
        _ = persistPlanCanvas(plan)
    }
    func editablePlanTextForCanvas() -> String? { activePlanArtifact?.editableText() }
    /// Persist the human submission boundary before starting either destination.
    func saveDistillSubmission(_ id: UUID, _ submission: DistillSubmission) -> Bool {
        guard selectedRemote == nil, let engine = localLive,
              var plan = try? engine.loadPlanArtifact(submission.threadID),
              plan.planID == id, plan.kind == "distill",
              (plan.distillSubmission != nil || !engine.isRunning(plan.threadID)),
              DistillCanvas.byteEqual(plan.editableText(), submission.content) else { return false }
        if let previous = plan.distillSubmission, previous.id != submission.id { return false }
        plan.distillSubmission = submission
        plan.confirm()
        return persistPlanCanvas(plan)
    }
    func finishFeedbackPlan(_ id: UUID) {
        guard var plan = activePlanArtifact, plan.planID == id, plan.kind == "feedback", plan.state == .discussing else { return }
        plan.confirm()
        _ = persistPlanCanvas(plan)
    }
    func ensureNativeTerminal(reset: Bool = false) {
        // Reset is deliberately not a command replay operation in the durable workbench.
        loadPersistedCLISessionBook()
        prepareCLITabs()
    }
    func handlePlanQuestionAnswerNotification(_ notification: Notification) {}
    @discardableResult
    func saveEditedPlanCanvasText(_ text: String) -> Bool {
        if selectedRemote != nil { return saveRemoteDistillText(text) }   // W180 E4：遠端只改得到 /蒸餾 畫布
        guard selectedRemote == nil, var plan = activePlanArtifact, !pendingPR.contains(plan.threadID),
              plan.kind != "distill" || plan.distillSubmission == nil,
              plan.kind != "pr" || plan.state == .discussing else { return false }
        guard localLive?.isRunning(plan.threadID) == false else {
            flashComposerHint("請等回覆完成再編輯計畫"); return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashComposerHint("計畫不可空白"); return false
        }
        let environment = plan.kind == "feedback" ? plan.sections.first { $0.title == "環境" } : nil
        plan.applyEditedText(text)
        if let environment {
            plan.sections.removeAll { $0.title == "環境" }
            plan.sections.insert(environment, at: min(1, plan.sections.count))
        }
        return persistPlanCanvas(plan)
    }
    func shutdownForContainerClose() {
        ComputerUseController.shared.stop()
        BrowserAgentBridge.shared.revokeRequests()
        devicePairingHost.cancelPairingWindow()
        OSAgentBridge.shared.stopBackgroundJobs()
        cliRefreshTask?.cancel()
        for session in cliTabPTYByID.values { session.detach() }
        saveCLIWorkbench()
        cliTabPTYByID.removeAll()
        cliTabPIDByID.removeAll()
        remoteProjectionTask?.cancel()
        for session in remoteSessions { session.shutdown() }
        localLive?.shutdownAll()
    }
    func stop() {
        // Local revocation precedes any sidecar/transport cancellation.
        ComputerUseController.shared.stop(owner: selectedThreadID)
        BrowserAgentBridge.shared.revokeRequests()
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID else { return }
        activeLive.stop(threadID: id)
        isRunning = activeLive.isRunning(id)
    }

    private func computerUseScope(_ caller: UUID) -> String? {
        // First vertical slice is a user-owned local Chat, not a delegated room
        // or a background Bot. Space/other routes remain explicitly unverified.
        // 開始一定要在聊天模式；已經在操作 TATWO OS 自己（全權）時，模式被它自己切走不算離開情境。
        let selfOperated = permissionPreset == .fullAccess && ComputerUseController.shared.isOperatingSelf(owner: caller)
        guard isLive, mode == .chat || selfOperated, selectedRemote == nil, selectedThreadID == caller || selfOperated,
              let record = live?.threadRecord(caller), !record.isArchived,
              record.parentThreadID == nil, record.deviceID == nil,
              record.roomReadOnly != true, botIDForBridge(threadID: caller) == nil else { return nil }
        let domain = botLibraryForBridge?.snapshot.spaceWorkspace.selectedDomainID ?? "none"
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return "\(caller.uuidString)|\(record.projectID?.uuidString ?? "none")|\(domain)|\(workdir)"
    }

    func browserAgentRequestScope(_ caller: UUID) -> String? {
        // isRunning stays true until the native terminal event, even after
        // local Stop. That UI liveness state is not permission for new tools.
        guard (localLive as? ChatLiveEngine)?.acceptsBrowserAgentRequests(caller) == true else { return nil }
        return computerUseScope(caller)
    }

    /// Semantic page tools have their own effect/Island gate, not an AX/input grant.
    /// Keep the same local, selected, running Chat boundary; read-only callers may
    /// discover tools and the WebMCP policy rejects every non-read-only invocation.
    func webMCPRequestScope(_ caller: UUID) -> String? {
        guard localLive?.acceptsBrowserAgentRequests(caller) == true,
              isLive, mode == .chat, selectedRemote == nil, selectedThreadID == caller,
              let record = live?.threadRecord(caller), !record.isArchived,
              record.parentThreadID == nil, record.deviceID == nil,
              botIDForBridge(threadID: caller) == nil else { return nil }
        let domain = botLibraryForBridge?.snapshot.spaceWorkspace.selectedDomainID ?? "none"
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return "\(caller.uuidString)|\(record.projectID?.uuidString ?? "none")|\(domain)|\(workdir)"
    }

    /// W58 semantic login only. Local selected Bot conversations may use their own accounts;
    /// this does not widen Computer Use or WebMCP. Read-only is rejected by the login policy.
    func aiVaultRequestScope(_ caller: UUID) -> String? {
        guard localLive?.acceptsBrowserAgentRequests(caller) == true,
              isLive, mode == .chat, selectedRemote == nil, selectedThreadID == caller,
              let record = live?.threadRecord(caller), !record.isArchived,
              record.parentThreadID == nil, record.deviceID == nil else { return nil }
        let domain = botLibraryForBridge?.snapshot.spaceWorkspace.selectedDomainID ?? "none"
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return "\(caller.uuidString)|\(record.projectID?.uuidString ?? "none")|\(domain)|\(workdir)|\(botIDForBridge(threadID: caller) ?? "none")"
    }

    func queueBrowserAgentNavigation(_ navigation: BrowserAgentNavigation) {
        pendingBrowserAgentNavigation = navigation
        requestedBrowserAgentURL = navigation.url.absoluteString
        requestOpenBrowserPanel = true
    }

    func consumeBrowserAgentPanelRequest() -> Bool {
        requestOpenBrowserPanel = false
        guard let navigation = pendingBrowserAgentNavigation,
              BrowserAgentBridge.shared.isRequestCurrent(navigation.request) else { return false }
        return true
    }

    func consumeBrowserAgentNavigation(for sessionID: String?) -> BrowserAgentNavigation? {
        guard let navigation = pendingBrowserAgentNavigation,
              sessionID.flatMap(UUID.init(uuidString:)) == navigation.request.caller else { return nil }
        // Panel opening and URL consumption are separate SwiftUI callbacks;
        // either may run first. Keep the same (eventually finished) token for
        // the panel check, while consuming the URL at most once.
        defer { requestedBrowserAgentURL = nil }
        guard BrowserAgentBridge.shared.isRequestCurrent(navigation.request),
              requestedBrowserAgentURL == navigation.url.absoluteString else { return nil }
        return navigation
    }

    /// Validate the actual Chat entry, not only the MCP or the native input
    /// parser. Shape validation grants no permission and consumes no observation.
    nonisolated static func validateComputerToolParameters(_ method: String, params: [String: Any],
                                                           caller: UUID, allowSelfTarget: Bool = false) throws {
        guard let rawCaller = params["callerThreadID"] as? String,
              UUID(uuidString: rawCaller) == caller else {
            throw ComputerUseFailure("computer_invalid_caller")
        }
        let allowed: Set<String>
        switch method {
        case "computer_start": allowed = ["callerThreadID", "bundleIdentifier"]
        case "computer_stop", "computer_list_apps": allowed = ["callerThreadID"]
        case "computer_observe":
            // W184 CU：選填 windowID（computer_window_not_uniquely_identified 附的候選清單裡的視窗編號）。
            _ = try ComputerUseNative.windowIDParameter(params["windowID"])
            allowed = ["callerThreadID", "sessionID", "windowID"]
        case "computer_action" where params["steps"] != nil:
            guard let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_batch")
            }
            _ = try ComputerUseController.batchRequests(params)
            allowed = ["callerThreadID", "sessionID", "observationID", "steps", "image"]
        case "computer_action":
            guard let action = params["action"] as? String,
                  let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_action")
            }
            _ = try ComputerUseNative.request(action: action, params: params)
            allowed = Set(params.keys) // Per-action fields were checked by the shared production parser.
        case "computer_batch":
            guard let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_batch")
            }
            _ = try ComputerUseController.batchRequests(params)
            allowed = ["callerThreadID", "sessionID", "observationID", "steps", "image"]
        default: throw ComputerUseFailure("computer_unknown_tool")
        }
        guard Set(params.keys).isSubset(of: allowed) else { throw ComputerUseFailure("computer_invalid_arguments") }
        if method == "computer_start" { _ = try ComputerUseTarget.requested(params["bundleIdentifier"], allowSelf: allowSelfTarget) }
        if method == "computer_observe" || method == "computer_action" || method == "computer_batch" {
            guard let session = params["sessionID"] as? String, UUID(uuidString: session) != nil else {
                throw ComputerUseFailure("computer_session_required")
            }
        }
    }

    func performComputerTool(_ method: String, params: [String: Any], caller: UUID,
                             requestIsConnected: @escaping @Sendable () -> Bool) async throws -> [String: Any] {
        guard let scope = computerUseScope(caller) else { throw ComputerUseFailure("computer_local_chat_required") }
        try Self.validateComputerToolParameters(method, params: params, caller: caller,
                                                allowSelfTarget: permissionPreset == .fullAccess)
        guard let record = live?.threadRecord(caller) else { throw ComputerUseFailure("computer_local_chat_required") }
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return try await ComputerUseController.shared.perform(method, params: params, caller: caller, scope: scope,
                                                              workspace: URL(fileURLWithPath: workdir, isDirectory: true),
                                                              allowSelfTarget: permissionPreset == .fullAccess,
                                                              selfTargetPermitted: { [weak self] in self?.permissionPreset == .fullAccess },
                                                              requestIsConnected: requestIsConnected) { [weak self] in
            self?.computerUseScope(caller) == scope && requestIsConnected()
        }
    }
    func startPairingWindow() {
        pairingWindow = nil
        pairingListenAddress = nil
        let host = devicePairingHost
        Task {
            do {
                let value = try await Task.detached {
                    try host.startPairingWindow()
                }.value
                pairingWindow = (value.code, value.expiresAt)
                pairingListenAddress = value.listenAddress
                flashComposerHint("配對碼 \(value.code)，請連到 \(value.listenAddress)；5 分鐘後失效。")
            } catch {
                flashComposerHint("無法開啟配對視窗：\(error.localizedDescription)")
            }
        }
    }
    func cancelPairingWindow() {
        devicePairingHost.cancelPairingWindow()
        pairingWindow = nil
        pairingListenAddress = nil
    }

    func refreshGitHubAccounts() {
        guard isLive else { return }   // 匯出（金樣）模式用固定假帳號
        do {
            gitHubAccounts = try githubAccountsStore.loadAccounts()
            gitHubHelperInstalled = githubAccountsStore.isHelperInstalled()
        } catch {
            appendGitHubLoginLog("讀取 GitHub 帳號失敗：\(error.localizedDescription)")
        }
    }

    func importGitHubAccountsFromGH() {
        appendGitHubLoginLog("開始讀取 gh 已登入帳號")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let imported = try await Task.detached {
                    try await store.importFromGH()
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已從 gh 匯入 \(imported.count) 個帳號")
            } catch {
                self?.appendGitHubLoginLog("gh 匯入失敗：\(error.localizedDescription)")
            }
        }
    }

    func loginGitHubViaGH() {
        guard !githubLoginInProgress else { return }
        githubLoginInProgress = true
        githubDeviceCode = nil
        githubVerificationURL = nil
        gitHubLoginLog = []
        appendGitHubLoginLog("請在瀏覽器完成 GitHub 登入")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            defer { self?.githubLoginInProgress = false }
            do {
                let account = try await Task.detached {
                    try await store.loginViaGH()
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已登入 \(account.username)")
            } catch {
                self?.appendGitHubLoginLog("gh 登入失敗：\(error.localizedDescription)")
            }
        }
    }

    func submitGitHubLoginInput(_ text: String) {
        if githubAccountsStore.submitLoginInput(text) {
            appendGitHubLoginLog(text.isEmpty ? "已送出 Enter" : "已送出登入輸入")
        } else {
            appendGitHubLoginLog("目前沒有可接收輸入的 gh 登入程序")
        }
    }

    func addGitHubToken(_ token: String) {
        appendGitHubLoginLog("正在驗證 GitHub token")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let account = try await Task.detached {
                    try await store.addToken(token)
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已加入 \(account.username)")
            } catch {
                self?.appendGitHubLoginLog("加入 token 失敗：\(error.localizedDescription)")
            }
        }
    }

    func removeGitHubAccount(_ account: GitHubAccountRecord) {
        removeGitHubAccount(account.username)
    }

    func removeGitHubAccount(_ username: String) {
        do {
            try githubAccountsStore.removeAccount(username)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已移除 \(username)")
        } catch {
            appendGitHubLoginLog("移除帳號失敗：\(error.localizedDescription)")
        }
    }

    func setDefaultGitHubAccount(_ account: GitHubAccountRecord) {
        setDefaultGitHubAccount(account.username)
    }

    func setDefaultGitHubAccount(_ username: String) {
        do {
            try githubAccountsStore.setDefault(username)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已將 \(username) 設為預設帳號")
        } catch {
            appendGitHubLoginLog("設定預設帳號失敗：\(error.localizedDescription)")
        }
    }

    func toggleGitHubMCPAlwaysOn(_ username: String) {
        guard let account = gitHubAccounts.first(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else { return }
        do {
            try githubAccountsStore.setGitHubMCPAlwaysOn(
                username: account.username,
                on: !account.mcpAlwaysOn)
            refreshGitHubAccounts()
            pluginEntries = PluginsSource.scanNow(environment: runtimeEnvironment)
            appendGitHubLoginLog(
                "\(account.username) MCP 已\(account.mcpAlwaysOn ? "關閉常駐" : "開啟常駐")")
        } catch {
            appendGitHubLoginLog("切換 \(username) MCP 常駐失敗：\(error.localizedDescription)")
        }
    }

    func addGitHubFolderMapping(account: String, path: String) {
        do {
            try githubAccountsStore.addFolderMapping(account: account, path: path)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已加入 \(account) 的資料夾對映")
        } catch {
            appendGitHubLoginLog("加入資料夾對映失敗：\(error.localizedDescription)")
        }
    }

    func addGitHubFolderMapping(account: GitHubAccountRecord, path: String) {
        addGitHubFolderMapping(account: account.username, path: path)
    }

    func removeGitHubFolderMapping(account: String, path: String) {
        do {
            try githubAccountsStore.removeFolderMapping(account: account, path: path)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已移除 \(account) 的資料夾對映")
        } catch {
            appendGitHubLoginLog("移除資料夾對映失敗：\(error.localizedDescription)")
        }
    }

    func removeGitHubFolderMapping(account: GitHubAccountRecord, path: String) {
        removeGitHubFolderMapping(account: account.username, path: path)
    }

    func installGitHubHelper() {
        do {
            try githubAccountsStore.installHelper()
            refreshGitHubAccounts()
            appendGitHubLoginLog("OS 已接管 git 憑證")
        } catch {
            appendGitHubLoginLog("安裝 git credential helper 失敗：\(error.localizedDescription)")
        }
    }

    func restoreGitHubHelper() {
        do {
            try githubAccountsStore.restoreHelper()
            refreshGitHubAccounts()
            appendGitHubLoginLog("已還原原本的 git credential helper")
        } catch {
            appendGitHubLoginLog("還原 git credential helper 失敗：\(error.localizedDescription)")
        }
    }

    func verifyGitHubAccount(_ account: GitHubAccountRecord) {
        verifyGitHubAccount(account.username)
    }

    func verifyGitHubAccount(_ username: String) {
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let verified = try await Task.detached {
                    try await store.verify(username)
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog(
                    "\(username) 驗證通過：登入名 \(verified.username)，scopes \(verified.scopes.joined(separator: ", "))")
            } catch {
                self?.appendGitHubLoginLog("\(username) 驗證失敗：\(error.localizedDescription)")
            }
        }
    }

    private func appendGitHubLoginLog(_ message: String) {
        let sanitized = message
            .replacingOccurrences(
                of: #"gh[oprsu]_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
            .replacingOccurrences(
                of: #"github_pat_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
        gitHubLoginLog.append(sanitized)
        if gitHubLoginLog.count > 100 {
            gitHubLoginLog.removeFirst(gitHubLoginLog.count - 100)
        }
    }

    func pairWithHost(host: String, port: Int, code: String, name: String) {
        let client = DevicePairingClient(registry: deviceRegistry)
        Task {
            do {
                let record = try await Task.detached {
                    try client.pair(host: host, port: port, code: code, name: name)
                }.value
                devices = deviceRegistry.list()
                configureRemoteSessions()
                flashComposerHint("已配對「\(record.name)」，並通過 SSH BatchMode 登入驗證。")
                pairingClientMessage = "已配對「\(record.name)」，SSH 登入驗證通過。"
            } catch {
                devices = deviceRegistry.list()
                flashComposerHint("配對失敗：\(error.localizedDescription)")
                pairingClientMessage = "配對失敗：\(error.localizedDescription)"
            }
        }
    }
    func removeDevice(_ id: String) {
        do {
            try deviceRegistry.remove(id: id)
            devices = deviceRegistry.list()
            if selectedRemote?.deviceID == id { exitRemoteMode() }
            retireRemoteOfflineCache(deviceID: id, environment: runtimeEnvironment)   // W182 R4：那台的離線副本一起移到垃圾桶
            configureRemoteSessions()
            flashComposerHint("已移除設備。")
        } catch {
            devices = deviceRegistry.list()
            flashComposerHint("移除設備失敗：\(error.localizedDescription)")
        }
    }
    func removeDevice(id: String) {
        removeDevice(id)
    }
    func deviceRecordsForBridge() -> [DeviceRecord] {
        let rows = deviceRegistry.list()
        devices = rows
        return rows
    }
    /// W100：還沒連上就不在主執行緒等 SSH。改成背景連線＋顯示「正在連線」，
    /// 連上後由 `completePendingRemoteEntry` 自動進遠端模式。
    @discardableResult
    func enterRemoteMode(_ device: DeviceRecord) -> Bool {
        guard isLive else {
            flashComposerHint("目前不是 live 模式，無法選取遠端討論串")
            return false
        }
        if !remoteSessions.contains(where: { $0.device.id == device.id }) {
            devices = deviceRegistry.list()
            configureRemoteSessions()
        }
        guard let session = remoteSessions.first(where: { $0.device.id == device.id }) else {
            flashComposerHint("「\(device.name)」現在連不上，這個工作暫時不能開始。")
            return false
        }
        if session.engine != nil,
           let threadID = session.document.coderThreadID(preferred: session.engine?.doc.selectedThreadID) {
            pendingRemoteEntryDeviceID = nil
            return selectRemote(deviceID: device.id, threadID: threadID)
        }
        pendingRemoteEntryDeviceID = device.id
        session.start()
        flashComposerHint("這個工作要在「\(device.name)」上做，現在還不能開始。")
        return false
    }

    /// 背景連線完成後，把當初按下的那台自動帶進遠端模式。
    private func completePendingRemoteEntry(_ session: RemoteDeviceSession) {
        guard pendingRemoteEntryDeviceID == session.device.id,
              let engine = session.engine,
              let threadID = session.document.coderThreadID(preferred: engine.doc.selectedThreadID)
        else { return }
        pendingRemoteEntryDeviceID = nil
        _ = selectRemote(deviceID: session.device.id, threadID: threadID)
    }

    /// W98d：設備頁按「遠端設備專案」時，請側欄把那台設備的區塊展開並捲過去（展開狀態是側欄的
    /// @State，靠這個訊號同步）；只帶路，不自己進遠端模式。
    func requestSidebarDeviceSection(_ deviceID: String) {
        sidebarDeviceFocus = SidebarDeviceFocus(deviceID: deviceID, nonce: (sidebarDeviceFocus?.nonce ?? 0) + 1)
    }

    func exitRemoteMode() {
        guard selectedRemote != nil else { return }
        selectLocalThread(localSelectedThreadID)
        flashComposerHint("已回到本機")
    }

    @discardableResult
    func selectRemote(deviceID: String, threadID: UUID) -> Bool {
        guard
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine,
            remote.threadRecord(threadID) != nil
        else {
            // W182 R4：那台連不上，但離線副本裡有這條：照樣打開（唯讀，輸入框換成「在這台接著聊」）。
            if let session = remoteSessions.first(where: { $0.device.id == deviceID }), session.engine == nil,
               session.offlineMirror.hasThread(threadID) {
                return selectOfflineRemote(deviceID: deviceID, threadID: threadID)
            }
            flashComposerHint("那台現在連不上，或這條對話已不在了；暫時不能打開。")
            return false
        }
        if remote.doc.isAssistantThread(threadID) {
            mode = .tatwo
            return true
        }
        if selectedRemote == nil { localSelectedThreadID = selectedThreadID }
        selectedRemote = (deviceID, threadID)
        selectedDiscussionID = nil
        selectedThreadID = threadID
        remote.select(threadID)
        isRunning = remote.isRunning(threadID)
        refreshIssueLists()
        flashComposerHint("已選取遠端：\(session.device.name)")
        objectWillChange.send()
        return true
    }

    func selectLocalThread(_ threadID: UUID?) {
        if let threadID, localLive?.doc.isAssistantThread(threadID) == true {
            mode = .tatwo
            return
        }
        selectedRemote = nil
        selectedDiscussionID = nil
        let target = threadID
            ?? document.coderThreadID(preferred: localLive?.doc.selectedThreadID)
        selectedThreadID = target
        if let target { localLive?.select(target) }
        localSelectedThreadID = target
        isRunning = localLive?.isRunning(target) ?? false
        refreshIssueLists()
        refreshGitStatus()
        objectWillChange.send()
    }

    /// W182 R4：打開連不上那台的一條（離線副本裡的，唯讀）；連回來時同一個選取自動變成可以送出。
    private func selectOfflineRemote(deviceID: String, threadID: UUID) -> Bool {
        if selectedRemote == nil { localSelectedThreadID = selectedThreadID }
        selectedRemote = (deviceID, threadID)
        selectedDiscussionID = nil
        selectedThreadID = threadID
        isRunning = false
        refreshIssueLists()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func pushThreadToDevice(
        _ threadID: UUID,
        _ deviceID: String,
        completion: (@MainActor (UUID?) -> Void)? = nil
    ) -> UUID? {
        guard
            let localLive,
            let source = localLive.threadRecord(threadID),
            let project = localLive.projectRecord(source.projectID),
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine
        else {
            flashComposerHint("併回失敗：本機討論串或遠端設備不可用")
            completion?(nil)
            return nil
        }
        let systemText = "已併回 \(session.device.name)，來源：\(source.title)"
        var messages = localLive.transcript(for: threadID)
            .map(RemoteThreadTransferMessage.init)
        messages.append(RemoteThreadTransferMessage(
            role: "system",
            text: systemText,
            createdAt: Date()))
        let deviceName = session.device.name
        let projectName = project.name
        let workdir = source.cwdOverride ?? project.workdir
        let candidates: [RemoteThreadTransfer.Candidate]
        var paths: [String]
        do {
            candidates = try RemoteThreadTransfer.candidates(
                threadID: threadID, artifactsRoot: localLive.turnArtifacts.root, workdir: workdir)
            paths = candidates.filter(\.automatic).map(\.path)
            let uncertain = candidates.filter { !$0.automatic }
            if !uncertain.isEmpty {
                let alert = NSAlert()
                alert.messageText = "選擇要併回的檔案"
                alert.informativeText = "以下檔案無法確定屬於本討論串，預設不勾選。"
                alert.addButton(withTitle: "繼續")
                alert.addButton(withTitle: "取消")
                let buttons = uncertain.map { NSButton(checkboxWithTitle: $0.path, target: nil, action: nil) }
                let stack = NSStackView(views: buttons)
                stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
                stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(buttons.count * 26))
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: min(300, stack.frame.height)))
                scroll.hasVerticalScroller = true; scroll.documentView = stack
                alert.accessoryView = scroll
                guard alert.runModal() == .alertFirstButtonReturn else {
                    completion?(nil)
                    return nil
                }
                paths += zip(uncertain, buttons).filter { $0.1.state == .on }.map { $0.0.path }
            }
        } catch {
            flashComposerHint("併回 \(deviceName) 失敗：\(error.localizedDescription)")
            completion?(nil)
            return nil
        }
        let observed = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            candidate.observedSHA256.map { (candidate.path, $0) }
        })
        // W100：baseline 比對與 push RPC 都會等 SSH，一律在背景跑；主執行緒只收結果。
        let link = session.link
        let selected = paths
        flashComposerHint("正在併回 \(deviceName)…")
        Task { @MainActor [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                Result { () throws -> [RemoteThreadTransferFile] in
                    var baselines: [String: String] = [:]
                    if !selected.isEmpty {
                        let original = try RemoteThreadTransfer.sourceBaselines(in: workdir, paths: selected)
                        let response = try link.call(method: "push_thread", params: [
                            "phase": "baseline", "projectName": projectName, "paths": selected,
                        ])
                        guard let peer = response["baselines"] as? [String: String] else { throw RemoteHostLinkError.invalidResponse }
                        let conflicts = selected.filter { peer[$0] == nil || peer[$0] != original[$0] }
                        guard conflicts.isEmpty else { throw RemoteThreadTransfer.TransferError.conflicts(conflicts) }
                        baselines = peer
                    }
                    return try RemoteThreadTransfer.changedFiles(
                        in: workdir, paths: selected, baselines: baselines, observedHashes: observed)
                }
            }.value
            guard let self else { return }
            guard case .success(let files) = prepared else {
                if case .failure(let error) = prepared {
                    self.flashComposerHint("併回 \(deviceName) 失敗：\(error.localizedDescription)")
                }
                completion?(nil)
                return
            }
            remote.pushThread(
                projectName: projectName,
                title: source.title,
                messages: messages,
                files: files
            ) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let remoteThreadID):
                    localLive.appendSystemMessage(
                        threadID: threadID,
                        text: systemText,
                        status: "info|設備搬移")
                    self.flashComposerHint("已併回 \(deviceName)")
                    completion?(remoteThreadID)
                case .failure(let error):
                    self.flashComposerHint("併回 \(deviceName) 失敗：\(error.localizedDescription)")
                    completion?(nil)
                }
            }
        }
        return nil
    }

    @discardableResult
    func pullThreadFromDevice(
        _ deviceID: String,
        _ remoteThreadID: UUID,
        completion: (@MainActor (UUID?) -> Void)? = nil
    ) -> UUID? {
        guard
            let localLive,
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine
        else {
            flashComposerHint("拉到這台失敗：遠端設備不可用")
            completion?(nil)
            return nil
        }
        // W100：pull 是網路動作，走背景 RPC；主執行緒只在完成回呼裡寫入本機。
        let deviceName = session.device.name
        flashComposerHint("正在拉到這台…")
        remote.pullThread(threadID: remoteThreadID) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failure(let error):
                self.flashComposerHint("拉到這台失敗：\(error.localizedDescription)")
                completion?(nil)
            case .success(let transfer):
                do {
                    let localThreadID = try localLive.importTransferredThread(
                        projectName: transfer.projectName,
                        title: transfer.title,
                        messages: transfer.messages,
                        files: transfer.files)
                    localLive.appendSystemMessage(threadID: localThreadID, text: "已拉到這台，來源：\(transfer.title)（\(deviceName)）", status: "info|設備搬移")
                    self.selectLocalThread(localThreadID)
                    self.flashComposerHint("已拉到這台，來源：\(transfer.title)")
                    completion?(localThreadID)
                } catch {
                    self.flashComposerHint("拉到這台失敗：\(error.localizedDescription)")
                    completion?(nil)
                }
            }
        }
        return nil
    }

    @discardableResult
    private func rejectRemoteWrite(_ action: String) -> Bool {
        guard selectedRemote != nil else { return false }
        flashComposerHint("遠端討論串不支援 \(action)")
        return true
    }
    func updateGatewayLiveStatus(_ status: TatwoGatewayLiveStatus?) {}
    func updatePlanFlowSelection(_ selection: TatwoPlanArtifactV1.PlanFlowSelectionV1) {}
    @discardableResult
    func handleFeedbackCommand() -> Bool {
        guard let argument = TatwoSlashCommandParser.feedbackArgument(in: prompt) else { return false }
        if !argument.isEmpty {
            guard !rejectRemoteWrite("/feedback"), let id = selectedThreadID, let engine = localLive else {
                flashComposerHint("請先開啟本機討論串"); return true
            }
            guard !engine.isRunning(id), !pendingPR.contains(id) else {
                flashComposerHint("請等目前回合結束再回報"); return true
            }
            let environment = FeedbackEnvironment.current(engine: routeChoice.engine.rawValue)
            let body = "App: \(environment.appVersion) (\(environment.appBuild))\nmacOS: \(environment.macOS)\nEngine: \(environment.engine)"
            let plan = TatwoPlanArtifactV1(threadID: id, objective: argument,
                sections: [.init(title: "環境", body: body)], kind: "feedback")
            guard persistPlanCanvas(plan) else { return true }
            planInspectorRequest = UUID()
            return false // Continue through the ordinary AI send path; keep the draft if rejected.
        }
        if FeedbackCoordinator.shared.present(source: "Chat", initialText: argument) { prompt = "" }
        if (try? githubAccountsStore.loadAccounts())?.first == nil {
            flashComposerHint("請先登入github才能提交issue")
        }
        return true
    }

    func send() {
        if selectedRemote == nil && localConversationReadOnlyNotice != nil { return }
        if handleCanvasExitCommand() { return }
        if routeChoice.runtimeAdapter == .chatgptTap, CanvasCommandPolicy.command(in: prompt) != nil {
            flashComposerHint(CanvasCommandPolicy.tapUnsupported); return
        }
        if handleFeedbackCommand() { return }
        let eventSource = OSEventSources.begin(origin: "composer", actor: "你", surface: "coder"); defer { OSEventSources.send = eventSource }
        // W163：「記住…」同時變成一條使用者記憶提案（核准才寫進 user.md）；這句話照樣送給 AI。
        if let remembered = UserMemoryText.rememberRequest(in: prompt) {
            let thread = selectedThreadID?.uuidString.prefix(8) ?? "聊天"
            Task.detached { _ = try? UserMemoryStore.shared.propose(text: remembered, source: "聊天 \(thread)") }
            flashComposerHint("已記成提案；到 設定 › OS › 文件 › 記憶提案 核准")
        }
        if DistillCanvas.argument(in: prompt) != nil, selectedRemote != nil {
            // W180 E4：遠端（主設備上的）session 也能 /蒸餾：畫布開在那台，開好才照一般路徑送出這句。
            if !continueRemoteDistillSend() { return }
        } else if DistillCanvas.argument(in: prompt) != nil {
            guard !rejectRemoteWrite("/蒸餾"), let id = selectedThreadID, let engine = localLive else {
                flashComposerHint("請先開啟本機討論串"); return
            }
            guard !engine.isRunning(id), !pendingPR.contains(id) else {
                flashComposerHint("請等目前回合結束再蒸餾"); return
            }
            // W180 E4：上一份還在寫入就不開；已寫入、還能還原的留在新畫布的「之前的寫入」。
            guard openLocalDistillCanvas(id, argument: DistillCanvas.argument(in: prompt) ?? "") else { return }
            planInspectorRequest = UUID()
            // Both bare and parameterized commands go to the current lead engine.
        }
        let planCommand = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if planCommand.split(whereSeparator: \.isWhitespace).first == "/plan" {
            guard !rejectRemoteWrite("/plan"), let id = selectedThreadID, let engine = localLive else {
                flashComposerHint("請先開啟本機討論串"); return
            }
            let objective = String(planCommand.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if objective.isEmpty {
                if activePlanArtifact != nil { planInspectorRequest = UUID(); prompt = "" }
                else { flashComposerHint("/plan 後面接你想討論的計畫") }
                return
            }
            guard !engine.isRunning(id), !pendingPR.contains(id) else {
                flashComposerHint("請等目前回合結束再建立計畫"); return
            }
            let plan = TatwoPlanArtifactV1(threadID: id, objective: String(objective.prefix(60)))
            guard persistPlanCanvas(plan) else { return }
            planInspectorRequest = UUID()
        }
        if planCommand.split(whereSeparator: \.isWhitespace).first == "/plg",
           let plan = activePlanArtifact, plan.state == .discussing,
           plan.kind == nil || plan.kind == "plan" {
            flashComposerHint("請先確認計畫，或離開模式後再 /plg"); return
        }
        if isPlanModeEnabled && isLocalNativeGoalCommand {
            flashComposerHint(activePlanArtifact?.kind == "pr" ? "PR 討論中；請按畫布「確認計畫」或「離開模式」" : "計畫討論中；確認計畫並說「開始」或離開模式後再執行"); return
        }
        if isActivePlanTurnWriting {
            flashComposerHint("請等計畫回覆完成再送出"); return
        }
        if isLocalPRCommand {
            let title = TatwoSlashCommandParser.prArgument(in: prompt) ?? ""
            guard let id = selectedThreadID, let engine = activeConversationEngine else {
                flashComposerHint("請先開啟本機專案討論串。")
                return
            }
            guard selectedRemote == nil else {
                engine.appendSystemMessage(threadID: id, text: "/pr 僅支援本機專案討論串。", status: "info|PR")
                return
            }
            guard !engine.isRunning(id), !pendingPR.contains(id), !preparingPR else {
                engine.appendSystemMessage(threadID: id, text: "請等目前工作結束再 /pr", status: "info|PR")
                return
            }
            if !title.isEmpty {
                var plan = TatwoPlanArtifactV1(threadID: id, objective: title, kind: "pr")
                plan.prMessage = "/pr 用來貢獻到 TATWO OS 公開倉 \(PullRequestService.repository)。確認時會檢查目前專案；其他專案請使用原生 Git 工具，這裡不會切換或 clone 另一個專案。"
                guard persistPlanCanvas(plan) else { return }
                planInspectorRequest = UUID()
            } else {
                prompt = ""
                guard let project = selectedThreadProject else {
                    engine.appendSystemMessage(threadID: id, text: "請先開啟本機專案討論串。", status: "info|PR")
                    return
                }
                let cwd = engine.threadRecord(id)?.cwdOverride ?? project.workdir
                PullRequestCoordinator.shared.present(directory: URL(fileURLWithPath: cwd), title: title) { text in
                    engine.appendSystemMessage(threadID: id, text: text, status: "info|PR")
                }
                return
            }
        }
        if isShowDiscussionTrayCommand {
            showDiscussionTray()
            prompt = ""
            flashComposerHint(dispatchRooms.isEmpty ? "目前沒有子討論串；可用 /討論串 主題 新增" : "已顯示討論串")
            return
        }
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID else { return }
        guard !pendingPR.contains(id) else {
            activeLive.appendSystemMessage(threadID: id, text: "PR 作業處理中，請等目前工作結束。", status: "info|PR")
            return
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLocalDiscussionCommand {
            if rejectRemoteWrite("建立討論串") { return }
            let topic = String(trimmedPrompt.dropFirst("/討論串".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else {
                flashComposerHint("/討論串 後面接主題，例如：/討論串 登入問題")
                return
            }
            guard let discussionID = localLive?.createDiscussion(parentThreadID: id) else {
                flashComposerHint("無法建立討論串，原草稿已保留")
                return
            }
            localLive?.rename(discussionID, Self.dispatchTitle(topic))
            selectedDiscussionID = discussionID
            selectedThreadID = discussionID
            prompt = topic
            return
        }
        if isLocalIssueCommand {
            if rejectRemoteWrite("issue") { return }
            // 1.0 語意：/issue 是「快速記到右側資訊卡的 issue 清單」，不是叫模型改檔
            let rest = String(trimmedPrompt.dropFirst("/issue".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else {
                refreshIssueLists()
                requestOpenInfoCard = true
                prompt = ""
                return
            }
            if addIssueFromText(rest, attachments: droppedPaths) {
                prompt = ""
                droppedPaths = []
                droppedPathDisplayNames = [:]
            }
            return
        }
        // W170：/goal 在每一家引擎都是「加一條到這串的目標清單」，只加不蓋；選 OpenAI 時照舊再交給 Codex 原生 goal。
        if prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/goal" {
            let shouldStartNativeGoal = isLocalNativeGoalCommand
            if rejectRemoteWrite("目標") { return }
            let text = String(trimmedPrompt.dropFirst("/goal".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if isLocalNativeGoalCommand { localLive?.refreshNativeGoal(id) }
                goalCardExpanded = true; flashComposerHint("/goal 後面接一句目標；清單在輸入框上方"); return
            }
            do {
                let hasActive = ThreadGoalStore.shared.list(id).goals.contains { $0.status == .active && $0.parent == nil }
                let goal = try ThreadGoalStore.shared.update(id) {
                    try ThreadGoalRules.add(&$0, title: text, userWords: text, proposed: false)
                }
                if !hasActive {
                    try? ThreadGoalStore.shared.update(id) {
                        try ThreadGoalRules.setStatus(&$0, id: goal.id, to: .active, evidence: nil, actor: .user)
                    }
                }
                goalCardExpanded = true
                flashComposerHint("已加入第 \(goal.id) 條目標")
                // 目標已經記在清單裡：輸入框一律清空，不留草稿（留著再按一次會多加一條）。
                prompt = ""
                // 選 OpenAI 時順便交給 Codex 原生 goal；那邊沒接上不影響清單，只補一句說明。
                if shouldStartNativeGoal, engineLogin.status(for: .codex).isLoggedIn {
                    let accepted = localLive?.setNativeGoal(threadID: id, status: "active", objective: text,
                        model: routeChoice.modelArgument) { [weak self] accepted, _ in
                            guard let self, !accepted, self.selectedThreadID == id else { return }
                            self.flashComposerHint("已加入第 \(goal.id) 條目標（Codex 原生目標沒接上，不影響清單）")
                        } == true
                    if !accepted { flashComposerHint("已加入第 \(goal.id) 條目標（Codex 原生目標沒接上，不影響清單）") }
                }
            } catch { flashComposerHint("目標沒加上：\(error)") }
            return
        }
        if activeLive.isRunning(id) {
            guard canSteerCurrentTurn, let localLive else { return }
            let draft = prompt, attachments = droppedPaths, revision = composerRevision
            _ = localLive.steer(threadID: id, text: draft, attachments: attachments) { [weak self] accepted, error in
                guard let self, self.selectedThreadID == id else { return }
                if accepted {
                    // Never erase text or files edited while waiting for the
                    // native acknowledgement.
                    if self.composerRevision == revision && self.prompt == draft && self.droppedPaths == attachments {
                        self.prompt = ""
                        self.droppedPaths = []
                        self.droppedPathDisplayNames = [:]
                    }
                } else {
                    self.flashComposerHint(error ?? "插話未送出，草稿已保留")
                }
            }
            return
        }
        let engine: ClaudeSidecar.Kind
        let isTap = routeChoice.runtimeAdapter == .chatgptTap
        switch routeChoice.brandGroup {
        case .chatgptTap:
            if let reason = tapSendUnavailableReason(routeChoice) {
                flashComposerHint(reason)
                return
            }
            // Kind 是共用 send API 的相容參數；routeID 明確指定 chatgptTap，絕不走 CLI。
            engine = .codex
        case .anthropic: engine = .claude
        case .openAI: engine = .codex
        case .xAI: engine = .grok
        default:
            engine = .claude
            flashComposerHint("\(routeChoice.title) 還沒有水電，先用 Claude 回覆")
        }
        if selectedRemote == nil && !isTap {
            let loginStatus = sendLoginStatus(engine)
            guard loginStatus.isLoggedIn else {
                let hint = "\(engineLoginDisplayName(engine)) 還沒登入，到設定 › 登入"
                flashComposerHint(hint)
                // 觀測缺口（2026-09-06 review）：只閃提示的話對話裡什麼都沒有，人和測試都看不出這句為什麼沒送。進一列錯誤卡。
                if let threadID = selectedThreadID { localLive?.appendSystemMessage(threadID: threadID, text: "這句沒有送出：\(hint)。", status: "error|登入") }
                return
            }
        } else if selectedRemote != nil && !droppedPaths.isEmpty {
            _ = rejectRemoteWrite("附件")
            return
        }
        let text = prompt
        let modelArg: String?
        if isTap {
            modelArg = routeChoice.id
        } else {
            switch engine {
            case .claude: modelArg = routeChoice.modelArgument
            case .codex: modelArg = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
            case .grok: modelArg = routeChoice.modelArgument   // 真模型 id（grok-4.7）；CLI 會拒絕未知 id，所以成功即 attestation
            }
        }
        let atts = droppedPaths
        // W184 H4 修正第三輪（主導：「按了送出、字還在框裡，看起來就是壞了」）：跟一般聊天 App 一樣，按下送出輸入框立刻清空
        // （字與附件），那一句馬上出現在對話裡；送出前記下這一份（字、附件、附件名）。引擎（本機：這一輪的第一個原生事件；遠端：
        // 那台回覆收下）確認收到＝什麼都不用做；沒送到或不確定＝放回來（輸入框還空著）或提示＋「放回輸入框」（已經打了新的一句，
        // 不蓋掉）。不自動重送。
        let token = UUID()
        coderDeliveries[id] = CoderDelivery(token: token, text: text, attachments: atts, names: droppedPathDisplayNames)
        coderDeliveries[id]?.deviceID = selectedRemote?.deviceID
        coderDeliverySnapshots[token] = coderDeliveries[id]
        // W184 H4 修正（審查 #2）：ultrawork 是這條（id）這一輪明確帶的資料（本機接在那一句後面；遠端序列化給那台），不再當 systemPrompt。
        let accepted = activeLive.send(
            threadID: id,
            text: text,
            model: modelArg,
            engine: engine,
            systemPrompt: nil,
            attachments: atts,
            reasoningEffort: isTap ? tapEffortIDForSend : ((engine == .codex || engine == .claude) ? selectedEffort.codexRawValue : nil),
            serviceTier: !isTap && (engine == .codex || engine == .claude) ? selectedSpeedTier.appServerValue : nil,
            ultrawork: isTap ? nil : ultraworkSettings(for: id)) { [weak self] outcome in
                self?.finishCoderDelivery(id, token: token, outcome)
            }
        if accepted {
            prompt = ""
            droppedPaths = []
            droppedPathDisplayNames = [:]
        } else if coderDeliveries[id]?.token == token {
            coderDeliveries[id] = nil   // 當場沒收（例：同一條上一句還在路上）：草稿本來就還在輸入框
            coderDeliverySnapshots[token] = nil
        }
        isRunning = activeLive.isRunning(id)
    }

    /// W184 H4 修正第二輪（審查 #1、#7）／第三輪：Coder 送出去、還沒確認收到的那一句的快照（每條一句）；沒送到時照它放回。
    struct CoderDelivery: Equatable {
        let token: UUID
        let text: String
        let attachments: [String]
        let names: [String: String]
        var deviceID: String? = nil
    }

    #if DEBUG
    func beginCoderDeliveryForSelfTest(_ id: UUID, text: String, attachments: [String], deviceID: String?) -> UUID {
        let token = UUID()
        var sent = CoderDelivery(token: token, text: text, attachments: attachments,
                                 names: Dictionary(uniqueKeysWithValues: attachments.map { ($0, ($0 as NSString).lastPathComponent) }))
        sent.deviceID = deviceID
        coderDeliveries[id] = sent
        coderDeliverySnapshots[token] = sent
        return token
    }
    func finishCoderDeliveryForSelfTest(_ id: UUID, token: UUID) {
        finishCoderDelivery(id, token: token, .unknown("fixture delivery unknown"))
    }
    #endif

    /// W184 H4 修正第三輪：沒送到、但輸入框那時已經有新的字（不蓋掉）的那一句：抽屜顯示「上一句沒送到：…」＋「放回輸入框」。
    struct CoderUndelivered: Equatable {
        let threadID: UUID
        let text: String
        let attachments: [String]
        let names: [String: String]
        var deviceID: String? = nil
    }

    /// 確認收到：什麼都不用做（按下送出時已經清了）。沒送到／不確定：不自動重送——輸入框還空著（而且還是那一條）就放回來、
    /// 說一聲；已經打了新的一句（或換到別條）就不蓋掉，改成抽屜裡一行提示＋「放回輸入框」（restoreUndeliveredDraft）。
    private func finishCoderDelivery(_ id: UUID, token: UUID, _ outcome: LiveSendDelivery) {
        guard let sent = coderDeliverySnapshots.removeValue(forKey: token) ?? coderDeliveries[id], sent.token == token else { return }
        if coderDeliveries[id]?.token == token { coderDeliveries[id] = nil }
        switch outcome {
        case .delivered:
            localLive?.rememberTapFailureNames(id, draft: sent.text, names: sent.names)
        case .notDelivered, .unknown:
            putBackUndelivered(id, sent, message: Self.undeliveredMessage(outcome) ?? "這句沒送到")
        }
        if currentCoderDraftIdentity == CoderDraftIdentity(deviceID: sent.deviceID, threadID: id),
           let live = activeConversationEngine { isRunning = live.isRunning(id) }
    }

    private func putBackUndelivered(_ id: UUID, _ sent: CoderDelivery, message: String) {
        let sentContext = CoderDraftIdentity(deviceID: sent.deviceID, threadID: id)
        let composerEmpty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && droppedPaths.isEmpty
        if currentCoderDraftIdentity == sentContext, composerEmpty {
            prompt = sent.text
            droppedPaths = sent.attachments
            droppedPathDisplayNames = sent.names
            if coderUndelivered?.threadID == id { coderUndelivered = nil }
            flashComposerHint(message)
        } else {
            coderUndelivered = CoderUndelivered(threadID: id, text: sent.text, attachments: sent.attachments, names: sent.names, deviceID: sent.deviceID)
        }
    }

    /// 抽屜裡那一行（只在那一條開著時）：「上一句沒送到：前 20 個字…」。
    var coderUndeliveredNotice: String? {
        guard let undelivered = coderUndelivered else { return nil }
        return "上一句沒送到：" + Self.undeliveredPreview(undelivered.text)
    }

    /// 前 20 個字（換行換成空白；超過才加「…」）。
    static func undeliveredPreview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 20 ? String(flat.prefix(20)) + "…" : flat
    }

    /// 「放回輸入框」：把沒送到的那一句接在現在的草稿前面（附件也放回來，排在前面）；不送出。
    func restoreUndeliveredDraft() {
        guard let undelivered = coderUndelivered else { return }
        let current = prompt
        prompt = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? undelivered.text : undelivered.text + "\n" + current
        droppedPaths = undelivered.attachments.filter { !droppedPaths.contains($0) } + droppedPaths
        for (path, name) in undelivered.names where droppedPathDisplayNames[path] == nil { droppedPathDisplayNames[path] = name }
        coderUndelivered = nil
    }
    func appendDroppedPath(_ path: String) {
        if rejectRemoteWrite("附件") { return }
        guard !droppedPaths.contains(path) else { return }
        droppedPaths.append(path)
        droppedPathDisplayNames[path] = (path as NSString).lastPathComponent
    }

    // Bot memory is App-facing; MCP only receives the six non-confirmation operations.
    var botLibraryForBridge: BotLibrary? { botStore?.library }
    /// Bot 頁資訊卡的真來源：綁定的討論串／專案／issue；沒有就 nil（畫面顯示 —），不用 fixture。
    struct BotUISource { var project: String?; var thread: String?; var threadID: UUID?; var issues: [String] = [] }
    func botSourceForUI(botID: String) -> BotUISource {
        guard botLibraryForBridge?.bot(id: botID) != nil,
              let tid = botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID),
              let engine = localLive as? ChatLiveEngine, let record = engine.threadRecord(tid) else { return .init() }
        let project = engine.doc.projects.first { $0.id == record.projectID }?.name
        return .init(project: project, thread: record.title, threadID: tid, issues: record.issues.map(\.title))
    }
    func botTranscriptForUI(botID: String) -> [ChatMessage] {
        guard botLibraryForBridge?.bot(id: botID) != nil else { return [] }
        return localLive?.transcript(for: botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID)) ?? []
    }
    private var botThreadBindings: [String: UUID] = [:]
    var spaceSubmissionsInFlight = Set<UUID>()
    var botSendTestHook: ((UUID, String, String?) -> Void)?
    func botIDForBridge(threadID: UUID) -> String? {
        botThreadBindings.first(where: { $0.value == threadID })?.key
            ?? botStore?.library.snapshot.spaceWorkspace.domains.values
                .flatMap(\.interfaces).first(where: { $0.conversationID == threadID })?.botID
            ?? botStore?.document.threadIDsByBotID.first(where: { $0.value == threadID })?.key
    }
    @discardableResult
    func sendAsBot(botID: String, text: String, spaceID: String? = nil, interfaceID: UUID? = nil) -> UUID? {
        guard isLive, selectedRemote == nil, let live = live as? ChatLiveEngine,
              let library = botStore?.library, let bot = library.bot(id: botID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard library.snapshot.spaceWorkspaceError == nil else {
            flashComposerHint("Space 資料需要復原，未送出也未改寫既有對話")
            return nil
        }
        // Grok's current sidecar ignores permissionMode and cannot enforce ask/auto.
        guard bot.engine != "grok" || bot.permissions.approval == "full" else {
            flashComposerHint("Bot Grok 權限檔位尚不支援；未送出")
            return nil
        }
        let interface: SpaceWorkInterfaceRecord?
        if let spaceID, let interfaceID {
            guard let owned = library.snapshot.spaceWorkspace.domains[spaceID]?.interfaces
                .first(where: { $0.id == interfaceID && $0.spaceID == spaceID && $0.botID == botID }),
                  bot.spaceIDs.contains(spaceID) else {
                flashComposerHint("工作介面與 Space／Bot 關聯不符，未送出")
                return nil
            }
            interface = owned
        } else {
            guard spaceID == nil, interfaceID == nil else { return nil }
            interface = nil
        }
        let existing = interface?.conversationID
            ?? botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID)
        let threadID: UUID
        do {
            threadID = try live.prepareBotThread(existing: existing, bot: bot,
                registeredMCP: registeredPluginIDs, reservedID: interface?.conversationID,
                selectThread: interface == nil)
        }
        catch { flashComposerHint(String(describing: error)); return nil }
        if interface == nil {
            botThreadBindings[botID] = threadID
            selectedThreadID = threadID
        }
        let thread = live.threadRecord(threadID)
        let needsPrompt = thread?.sessionIDs[bot.engine] == nil && !(bot.engine == "claude" && thread?.sessionID != nil)
        let persona = needsPrompt ? BotMemory(library: library).systemPrompt(botID: botID) : nil
        let engine = ClaudeSidecar.Kind(rawValue: bot.engine) ?? .claude
        // Test hook is set only by in-process acceptance; never reads an environment bypass.
        if let hook = botSendTestHook { hook(threadID, text, persona); return threadID }
        guard live.send(threadID: threadID, text: text, model: bot.model, engine: engine, systemPrompt: persona) else {
            flashComposerHint("未送出，需求草稿仍保留，可重試")
            return nil
        }
        isRunning = live.isRunning(selectedThreadID)
        Task { @MainActor [weak self, weak live] in
            try? await library.recordSession(botID: botID, threadID: threadID.uuidString, engine: bot.engine)
            while let live, live.isRunning(threadID) { try? await Task.sleep(for: .milliseconds(250)) }
            // 同一回合完成：session 與 state 共用一個時間戳（r6 BOTCORETEST 抓到分別取時跨秒就不等）
            let completedAt = BotLibrary.timestamp()
            try? await library.recordSession(botID: botID, threadID: threadID.uuidString, engine: bot.engine, at: completedAt)
            try? await BotMemory(library: library).updateState(botID: botID, patch: .init(lastSessionAt: completedAt, lastThreadID: threadID.uuidString))
            self?.objectWillChange.send()
        }
        return threadID
    }

    private func scheduleBotSelfTest(environment: [String: String]) {
        guard let botStore else { return }
        print("BOTTEST seed spaces=\(botStore.spaces.count) bots=\(botStore.bots.count)")
        let botID = botStore.bots.first(where: { $0.name == "PO文 bot" })?.id
        guard let botID, let threadID = sendAsBot(botID: botID, text: "只回一個詞：乒") else {
            print("BOTTEST ERROR bot/thread unavailable")
            exit(1)
        }
        Task { @MainActor [weak self] in
            guard let self else { exit(1) }
            var ticks = 0
            while self.isRunning && ticks < 240 {
                try? await Task.sleep(for: .milliseconds(500))
                ticks += 1
            }
            let transcript = self.live?.transcript(for: threadID) ?? []
            for message in transcript {
                print("BOTTEST \(message.role.storageValue.uppercased()) \(message.text.replacingOccurrences(of: "\n", with: "⏎"))")
            }
            let savedBytes = (try? Data(contentsOf: botStore.url))?.count ?? 0
            print("BOTTEST bots.json bytes=\(savedBytes) thread=\(threadID.uuidString)")
            self.shutdownForContainerClose()
            try? await Task.sleep(for: .milliseconds(250))
            exit(!transcript.isEmpty && savedBytes > 0 ? 0 : 1)
        }
    }
    func flashComposerHint(_ message: String) { composerHint = message }
    private static var engineModelCatalogStarted = false
    func refreshEngineModelCatalogOnce() {
        guard isLive, !Self.engineModelCatalogStarted else { return }
        Self.engineModelCatalogStarted = true
        refreshEngineModelCatalog()
    }
    func refreshEngineModelCatalog(force: Bool = false) {
        guard isLive else { return }
        #if DEBUG
        catalogRefreshStartsForSelfTest += 1
        if let catalogRefreshTestDouble { catalogRefreshTestDouble(); return }
        #endif
        EngineModelCatalogProbe.shared.refresh(force: force) { [weak self] in self?.objectWillChange.send() }
    }

    func refreshEngineLogins() {
        guard isLive, !engineLoginRefreshInFlight else { return }   // 匯出（金樣）模式用固定假狀態
        engineLoginRefreshInFlight = true
        #if DEBUG
        loginRefreshStartsForSelfTest += 1
        if let loginRefreshTestDouble {
            for status in loginRefreshTestDouble() { replaceEngineLoginStatus(status) }
            engineLoginRefreshInFlight = false
            return
        }
        #endif
        let login = engineLogin
        Task.detached { [weak self] in
            EngineAPIKeyPolicy.shared.refresh(optedOut: EngineDisableStore.disabled())   // W181 R3：勾了才重查登入方式
            let list = login.statuses()
            await MainActor.run {
                guard let self else { return }
                self.engineLoginRefreshInFlight = false
                for status in list { self.replaceEngineLoginStatus(status) }
            }
        }
    }
    func loginEngine(_ kind: ClaudeSidecar.Kind) {
        engineLoginLog = []
        engineLoginInProgress = kind
        let login = engineLogin
        Task.detached { [weak self] in
            let status = login.login(kind) { line in
                Task { @MainActor [weak self] in
                    self?.engineLoginLog.append(line)
                }
            }
            EngineAPIKeyPolicy.shared.refresh(optedOut: EngineDisableStore.disabled())   // W181 R3
            await MainActor.run {
                self?.completeEngineLogin(status)
            }
        }
    }
    private func completeEngineLogin(_ status: EngineLoginStatus) {
        replaceEngineLoginStatus(status)
        engineLoginInProgress = nil
        if status.isLoggedIn { refreshEngineModelCatalog(force: true) }
    }
    /// 快速記一個問題到右側清單（/issue 與資訊卡的快速欄共用）。第一行是標題，其餘是內文。
    @discardableResult
    func addIssueFromText(_ text: String, attachments: [String] = []) -> Bool {
        guard isLive, selectedRemote == nil, let engine = localLive as? ChatLiveEngine,
              let id = selectedThreadID else { return false }
        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return false }
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? rest
        let rawBody = rest.count > firstLine.count ? String(rest.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let legacy = IssueImageAssets.extractingLegacyImages(from: rawBody)
        let bodyText = legacy.text
        let key = ([id.uuidString, rest] + attachments).joined(separator: "\u{0}")
        if pendingIssueSubmission?.key != key { pendingIssueSubmission = (key, UUID().uuidString) }
        do {
            let images = try IssueImageAssets.stage(paths: attachments + legacy.paths, root: issueImageRoot)
            var entry = TatwoIssueListEntryV1(id: pendingIssueSubmission!.id,
                title: String(firstLine.prefix(60)), body: bodyText,
                sourceReference: id.uuidString, threadReference: id.uuidString,
                projectReference: engine.threadRecord(id)?.projectID?.uuidString)
            entry.imageAssetPaths = images
            try engine.addIssueChecked(threadID: id, entry: entry)
            pendingIssueSubmission = nil
        } catch {
            flashComposerHint("問題未保存，文字與附件已保留：\(error.localizedDescription)")
            return false
        }
        refreshIssueLists()
        flashComposerHint("已記到右側的問題清單：「\(firstLine.prefix(30))」；打 @ 可以隨時叫出來")
        return true
    }

    func toggleEngineDisabled(_ kind: ClaudeSidecar.Kind) {
        let now = !EngineDisableStore.isDisabled(kind)
        EngineDisableStore.set(kind, disabled: now)
        disabledEngines = EngineDisableStore.disabled()
        // W181 R3：勾了只是不用 API 金鑰（按量計費），訂閱登入照常能跑。
        if kind != .grok { GBrainService.shared.applyAPIKeyPreference() }   // GBrain 的金鑰照新設定帶或不帶
        guard now else {
            flashComposerHint("\(EngineDisableStore.displayName(kind)) 可以用 API 金鑰了（用 API 金鑰會按量計費）"); return
        }
        // 登入方式在背景查（Claude 要起 `claude auth status`，不能卡主執行緒），查到才說對的話。
        let policy = EngineAPIKeyPolicy.shared
        Task.detached { [weak self] in
            let method = policy.method(kind)
            await MainActor.run { self?.flashComposerHint(EngineAPIKeyPolicy.optOutHint(kind, method)) }
        }
    }
    /// W181 R3：這台送不出這家（勾了不用 API 金鑰、而且這家在這台只有 API 金鑰或判斷不出來）。助理、私訊框、選單都看這個。
    func isEngineDisabled(_ kind: ClaudeSidecar.Kind) -> Bool {
        EngineDisableStore.blocksSend(kind, optedOut: disabledEngines, allowStale: true)
    }
    /// W181 R3：設定上勾了「不用 API 金鑰」（按鈕與狀態字用；不等於送不出）。
    func isAPIKeyOptedOut(_ kind: ClaudeSidecar.Kind) -> Bool { disabledEngines.contains(kind.rawValue) }

    /// 登入頁的額度條：跟首頁額度卡同一個來源（Claude／OpenAI 走訂閱 API，Grok 只有 App 自己的記錄）。
    /// 登入頁「允許讀取額度…」：只有這裡會讓 macOS 跳鑰匙圈授權視窗（W106）。
    func authorizeClaudeQuotaRead() {
        let paths = engineLogin.paths
        Task { [weak self] in
            if await ClaudeCredentialStore.authorizeInteractively(paths: paths) { self?.refreshEngineQuotas() }
        }
    }

    func refreshEngineQuotas() {
        let providers = [
            UsageProviderStatus(id: "claude", displayName: "Claude", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
            UsageProviderStatus(id: "codex-gpt", displayName: "OpenAI", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
            UsageProviderStatus(id: "grok", displayName: "Grok", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
        ]
        Task { [weak self] in
            let snapshot = await TatwoQuotaSnapshotCache.shared.load(providers: providers)
            await MainActor.run { self?.engineQuotas = snapshot.rows }
        }
        guard isLive else { return }
        let paths = engineLogin.paths
        Task.detached { [weak self] in
            let openAI = EngineQuotaFetcher.openAI(paths: paths)
            let anthropic = EngineQuotaFetcher.anthropic(paths: paths)
            let grok = EngineQuotaFetcher.grok()
            await MainActor.run {
                self?.engineQuotaDetails = ["codex": openAI, "claude": anthropic, "grok": grok]
            }
        }
    }

    /// 使用者在登入頁按了「使用重置券」並二次確認後才會走到這裡。
    func consumeOpenAIResetCredit() {
        let paths = engineLogin.paths
        Task.detached { [weak self] in
            let message = EngineQuotaFetcher.consumeOpenAIResetCredit(paths: paths)
            await MainActor.run { self?.flashComposerHint(message); self?.refreshEngineQuotas() }
        }
    }

    /// 設定 › OS：各家引擎有沒有接到 OS、有沒有代差。
    func refreshUpstreamBindings() {
        guard isLive else { return }
        let env = runtimeEnvironment
        Task.detached { [weak self] in
            let list = OSUpstreamBinding.statuses(environment: env)
            await MainActor.run { self?.upstreamBindings = list }
        }
    }
    /// Legacy caller cannot bypass the preview and human confirmation in OSBindingCard.
    func installUpstreamBindings() {
        flashComposerHint("請到設定 › OS 先預覽差異，再確認寫入修復")
    }
    var osBindingEnvironment: [String: String] { runtimeEnvironment }
    var osRootPath: String { OSUpstreamBinding.osRoot(environment: runtimeEnvironment) }
    /// OS 總覽頁用：已登記的 MCP／外掛 id（pluginEntries 本身是 private）
    var registeredPluginIDs: [String] { pluginEntries.map(\.id) }

    /// 登入程序要你貼認證碼時（Grok），從設定頁送進去。
    func submitEngineLoginInput(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if engineLogin.submitLoginInput(text) { engineLoginLog.append("已送出認證碼") }
        else { engineLoginLog.append("現在沒有登入在進行，先按「登入」") }
    }
    func logoutEngine(_ kind: ClaudeSidecar.Kind) {
        let login = engineLogin
        Task.detached { [weak self] in
            let status = login.logout(kind) { line in
                Task { @MainActor [weak self] in
                    self?.engineLoginLog.append(line)
                }
            }
            EngineAPIKeyPolicy.shared.refresh(optedOut: EngineDisableStore.disabled())   // W181 R3
            await MainActor.run {
                self?.replaceEngineLoginStatus(status)
            }
        }
    }
    private func replaceEngineLoginStatus(_ status: EngineLoginStatus) {
        engineLoginCheckedAt[status.kind] = Date()
        if let index = engineLogins.firstIndex(where: { $0.kind == status.kind }) {
            engineLogins[index] = status
        } else {
            engineLogins.append(status)
            engineLogins.sort {
                EngineLogin.kinds.firstIndex(of: $0.kind) ?? .max
                    < EngineLogin.kinds.firstIndex(of: $1.kind) ?? .max
            }
        }
    }
    private func engineLoginDisplayName(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }
    func setSingleModel(_ routeID: String, syncCollaborationLead: Bool = false) {
        let choice = ChatRouteChoice.resolve(routeID, deviceID: modelSelectionDeviceID)
        if let reason = tapModelSelectionUnavailableReason(choice) {
            flashComposerHint(reason)
            return
        }
        guard prepareTapSelection(choice) else { return }
        if isRunning {
            guard let threadID = selectedThreadID else { return }
            do {
                try pendingModelSelections.set(deviceID: modelSelectionDeviceID, threadID: threadID,
                    routeID: choice.id == selectedModel ? nil : choice.id, pending: true)
            } catch { flashComposerHint("下一輪模型未能儲存；請稍後再選。" ); return }
            objectWillChange.send()
            flashComposerHint(pendingModelID == nil
                ? "已取消下一輪模型切換；目前回覆仍由 \(routeChoice.title) 執行。"
                : "目前回覆仍由 \(routeChoice.title) 執行；\(choice.title) 會從下一輪開始。")
            return
        }
        if let threadID = selectedThreadID {
            do { try pendingModelSelections.set(deviceID: modelSelectionDeviceID, threadID: threadID, routeID: nil, pending: false) }
            catch { flashComposerHint("模型選擇未能儲存；請稍後再選。"); return }
        }
        selectedModel = choice.id
        // 模型選單只管這條討論串的路由；主導／副審身份走 ultrawork 膠囊，不在這裡連動。
        _ = syncCollaborationLead
    }

    /// Preferences belong to the existing thread document, not another global
    /// settings store. Hydration must not write defaults over explicit choices.
    func restoreModelPreferences() {
        restoreUltraworkPreferences()   // W184 H4 修正（審查 #3）：ultrawork 也照這條記住的讀回來
        guard isLive, let engine = activeConversationEngine else { return }
        restoringModelPreferences = true
        defer { restoringModelPreferences = false }
        let thread = engine.threadRecord(selectedThreadID)
        let remoteSelection = selectedRemote.flatMap { pendingModelSelections.entry(deviceID: $0.deviceID, threadID: $0.threadID) }
        let preferences = ChatModelPreferences.selection(thread,
            overrideRouteID: remoteSelection?.pending == false ? remoteSelection?.routeID : nil, deviceID: modelSelectionDeviceID)
        let choice = preferences.route
        selectedModel = choice.id
        // 冷啟動時目錄可能還沒回來；先保留這條的原生 ID，送出前再按當時的目錄驗證。
        selectedTapEffortID = choice.runtimeAdapter == .chatgptTap
            ? (preferences.effort.isEmpty ? nil : preferences.effort) : nil
        selectedEffort = TatwoCodexReasoningEffort(rawValue: preferences.effort) ?? choice.defaultEffort
        selectedSpeedTier = preferences.speed
        normalizeExtendedReasoningEffort()
    }

    private func normalizeExtendedReasoningEffort() {
        guard routeChoice.runtimeAdapter != .chatgptTap else { return }
        let profile = routeChoice.profile
        guard let notice = profile.reasoningDowngradeNotice(for: selectedEffort.rawValue) else { return }
        selectedEffort = profile.nativeReasoningEffort(for: selectedEffort) ?? profile.defaultEffort
        flashComposerHint(notice)
    }

    private func reasoningAfterModelSwitch(_ route: ChatRouteChoice, stored: String?) -> String {
        guard let stored, let requested = TatwoCodexReasoningEffort(rawValue: stored),
              requested == .max || requested == .ultra else { return route.defaultEffort.codexRawValue }
        if let notice = route.profile.reasoningDowngradeNotice(for: stored) { flashComposerHint(notice) }
        return route.profile.compatibleReasoningValue(stored) ?? route.defaultEffort.codexRawValue
    }

    private func persistModelPreferences() {
        guard isLive, !restoringModelPreferences, let threadID = selectedThreadID else { return }
        if let selectedRemote {
            do { try pendingModelSelections.set(deviceID: selectedRemote.deviceID, threadID: threadID, routeID: selectedModel, pending: false) }
            catch { flashComposerHint("這台設備的模型選擇未能儲存。") }
            return
        }
        guard let live = localLive else { return }
        // TAP 保存原生 effort ID；不經 Codex 正規化，也不帶 Codex 速度。
        live.setModelPreferences(threadID: threadID, model: selectedModel,
                                 effort: routeChoice.runtimeAdapter == .chatgptTap ? selectedTapEffortID ?? "" : selectedEffort.rawValue,
                                 speedTier: routeChoice.runtimeAdapter == .chatgptTap ? "" : selectedSpeedTier.rawValue)
    }

    /// 回合結束時把「下一輪再換」落地（1.0 ChatPageModel+StateAndSelection.swift:513）。
    func applyPendingModelSelectionIfPossible() {
        for entry in pendingModelSelections.queued {
            let engine: (any LiveEngineAPI)?
            if entry.deviceID == "local" { engine = localLive }
            else if let session = remoteSessions.first(where: { $0.device.id == entry.deviceID }),
                    case .online = session.state { engine = session.engine }
            else { continue }
            guard let engine, let record = engine.threadRecord(entry.threadID), !record.isArchived,
                  !engine.isRunning(entry.threadID) else { continue }
            do {
                // Remove from the pending phase before persist invokes onChange again.
                try pendingModelSelections.set(deviceID: entry.deviceID, threadID: entry.threadID, routeID: entry.routeID, pending: false)
                if entry.deviceID == "local", let live = localLive {
                    let route = ChatRouteChoice.resolve(entry.routeID)
                    live.setModelPreferences(threadID: entry.threadID, model: route.id,
                        effort: reasoningAfterModelSwitch(route, stored: record.requestedEffort),
                        speedTier: (route.defaultSpeedTier ?? .fast).rawValue)
                    try pendingModelSelections.set(deviceID: entry.deviceID, threadID: entry.threadID, routeID: nil, pending: false)
                }
                if entry.deviceID == modelSelectionDeviceID, entry.threadID == selectedThreadID { restoreModelPreferences() }
                objectWillChange.send()
            } catch { flashComposerHint("下一輪模型未能儲存；原選擇仍保留。") }
        }
    }

    func restoreMostRecentArchivedThread() {
        if rejectRemoteWrite("還原封存討論串") { return }
        guard isLive, let restored = live?.restoreMostRecentArchivedThread() else { return }
        selectedDiscussionID = nil
        selectedThreadID = restored
    }
    // MARK: W104 變更面板
    /// 目前這條（本機）聊天的工作資料夾裡有沒有未提交的變更；nil＝沒有、不是 git、或是遠端聊天。頂列的「變更」鈕只在有值時出現。
    @Published private(set) var workspaceChangeSummary: WorkspaceChangeSummary?
    private var workspaceChangeGeneration = 0

    /// 這條聊天實際在哪個資料夾工作（跟引擎、Computer Use 用的是同一個規則）。遠端聊天不看。
    var selectedThreadWorkdir: String? {
        guard isLive, selectedRemote == nil, let id = selectedThreadID, let record = live?.threadRecord(id) else { return nil }
        return record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
    }

    func loadWorkspaceChanges() async -> WorkspaceChanges {
        guard let workdir = selectedThreadWorkdir else { return .empty(.notGit, root: "") }
        let changes = await Task.detached(priority: .userInitiated) { WorkspaceChangeReader.read(workdir: workdir) }.value
        workspaceChangeSummary = changes.state == .changed
            ? WorkspaceChangeSummary(files: changes.fileCount, added: changes.added, removed: changes.removed) : nil
        return changes
    }

    /// 切換討論串、或一輪回覆結束時呼叫。git 在背景跑；期間又切走的結果直接丟掉。
    func refreshWorkspaceChangeSummary() {
        workspaceChangeGeneration &+= 1
        let generation = workspaceChangeGeneration
        guard let workdir = selectedThreadWorkdir else { workspaceChangeSummary = nil; return }
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { WorkspaceChangeReader.summary(workdir: workdir) }.value
            guard let self, self.workspaceChangeGeneration == generation else { return }
            self.workspaceChangeSummary = summary
        }
    }
    /// issue 的圖片備註存在 live 根目錄的 issue-images/ 底下，entry 只記相對路徑。
    var issueImageRoot: URL {
        let base = runtimeEnvironment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        let dir = base.appendingPathComponent("issue-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func issueImageURLs(for entry: TatwoIssueListEntryV1) -> [URL] {
        entry.imageAssetPaths.compactMap { issueImageURL(relativeAssetPath: $0) }
    }
    func importLegacyIssueImages(_ entry: TatwoIssueListEntryV1) {
        guard selectedRemote == nil, let engine = localLive as? ChatLiveEngine else { return }
        let legacy = IssueImageAssets.extractingLegacyImages(from: entry.body)
        guard !legacy.paths.isEmpty else { return }
        do {
            let added = try IssueImageAssets.stage(paths: legacy.paths, root: issueImageRoot)
            var seen = Set<String>()
            let images = (entry.imageAssetPaths + added).filter { seen.insert($0).inserted }
            try engine.updateIssueImagesChecked(id: entry.id, body: legacy.text, images: images)
            refreshIssueLists()
        } catch { flashComposerHint("舊圖片尚未匯入，原文保留：\(error.localizedDescription)") }
    }
    func packIssueIntoComposer(_ entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        let urls = issueImageURLs(for: entry)
        guard urls.count == entry.imageAssetPaths.count else {
            flashComposerHint("有圖片已遺失，請重新附加；原草稿已保留")
            return
        }
        prompt = (prompt.isEmpty ? "" : prompt + "\n") + "【\(entry.title)】\n\(entry.body)"
        for url in urls {
            appendDroppedPath(url.path)
            droppedPathDisplayNames[url.path] = IssueImageAssets.displayName(url.lastPathComponent)
        }
    }
    func setGitHubRepoBindings(_ bindings: [TatwoGitHubRepoBinding], for projectID: UUID) {
        if rejectRemoteWrite("修改 GitHub 綁定") { return }
        guard isLive, let live else { return }
        var seen = Set<String>()
        let repos = bindings.compactMap { binding -> String? in
            let url = binding.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            return url
        }
        gitHubRepoCheckMessages[projectID] = nil
        live.setGitHubRepos(repos, for: projectID)
    }
    /// 匯出交接包：2.0 沒有 1.0 的合約收據鏈，改成把這條討論串存成 Markdown，
    /// 你可以直接丟給別人或別台機器。存到專案資料夾，沒有專案就存桌面。
    func exportHandoffPack() {
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID, let thread = selectedThread else {
            flashComposerHint("先選一條討論串再匯出"); return
        }
        var lines = ["# \(thread.title)", "", "匯出時間：\(Self.exportStamp())"]
        if let project = selectedThreadProject { lines += ["專案：\(project.name)", "工作目錄：\(project.workdir)"] }
        lines += ["", "---", ""]
        for m in activeLive.transcript(for: id) {
            let who = m.role == .user ? "使用者" : (m.role == .system ? "系統" : "AI")
            lines += ["## \(who)\(m.status.map { "（\($0)）" } ?? "")", "", m.text, ""]
        }
        let dir = selectedThreadProject?.workdir ?? (NSHomeDirectory() + "/Desktop")
        let safe = thread.title.replacingOccurrences(of: "/", with: "-")
        let path = "\(dir)/交接包-\(safe).md"
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            flashComposerHint("已匯出：\(path)")
        } catch {
            flashComposerHint("匯出失敗：\(error.localizedDescription)")
        }
    }

    private static func exportStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date())
    }
    /// Captures route and thread before asynchronous checkout; never sends to a newly selected room.
    private func startPRContribution(description: String, threadID: UUID) {
        guard routeChoice.runtimeAdapter != .chatgptTap else { flashComposerHint(CanvasCommandPolicy.tapUnsupported); return }
        guard let engine = localLive, !engine.isRunning(threadID),
              let sourcePlan = try? engine.loadPlanArtifact(threadID), sourcePlan.kind == "pr", sourcePlan.state == .confirmed,
              pendingPR.begin(threadID) else { return }
        let kind: ClaudeSidecar.Kind
        switch routeChoice.brandGroup {
        case .anthropic: kind = .claude
        case .openAI: kind = .codex
        case .xAI: kind = .grok
        default: kind = .claude
        }
        let login = sendLoginStatus(kind)
        guard login.isLoggedIn else {
            pendingPR.finish(threadID)
            resetPRPlan(threadID, planID: sourcePlan.planID, message: "這句沒有送出：請先登入目前引擎。")
            return
        }
        let model: String?
        switch kind {
        case .claude: model = routeChoice.modelArgument
        case .codex: model = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
        case .grok: model = routeChoice.modelArgument
        }
        let effort = kind == .codex || kind == .claude ? selectedEffort.codexRawValue : nil
        let tier = kind == .codex || kind == .claude ? selectedSpeedTier.appServerValue : nil
        let ultrawork = ultraworkSettings(for: threadID)   // W184 H4 修正（審查 #2）：這條的 ultrawork，這一輪明確帶著
        let cwd = engine.threadRecord(threadID)?.cwdOverride ?? selectedThreadProject?.workdir
        let repository = PullRequestService.repository
        preparingPR = true
        Task {
            var targetID = threadID
            defer { preparingPR = false }
            do {
                let identity = try PullRequestCoordinator.shared.identity()
                guard let cwd, try await PullRequestService().isContributionCheckout(
                    URL(fileURLWithPath: cwd, isDirectory: true), repository: repository, identity: identity) else {
                    throw PullRequestFailure(message: "/pr 只用來貢獻到 TATWO OS 公開倉 \(repository)。目前專案不是該倉或其 fork；請使用原生 Git 工具提交目前專案。")
                }
                let checkout = try await PullRequestService().contributionCheckout(
                    current: URL(fileURLWithPath: cwd, isDirectory: true),
                    repository: repository, identity: identity)
                if !checkout.useCurrent {
                    let pid = engine.doc.projects.first { $0.workdir == checkout.directory.path }?.id
                        ?? engine.newProject(name: checkout.directory.lastPathComponent, workdir: checkout.directory.path)
                    targetID = engine.newThread(in: pid)
                    pendingPR.finish(threadID)
                    _ = pendingPR.begin(targetID)
                    selectLocalThread(targetID)
                    engine.appendSystemMessage(threadID: targetID,
                        text: "已取得 TATWO OS 原始碼，開始處理：" + description, status: "info|PR")
                }
                let id = targetID
                if id != threadID {
                    var moved = TatwoPlanArtifactV1(planID: sourcePlan.planID, threadID: id, objective: sourcePlan.objective,
                        sections: sourcePlan.sections, createdAt: sourcePlan.createdAt, state: .confirmed, kind: "pr")
                    moved.executionTurnID = sourcePlan.executionTurnID
                    try engine.savePlanArtifact(moved)
                    var original = sourcePlan
                    original.prContinuationThreadID = id
                    original.prMessage = TatwoPlanArtifactV1.prMovedMessage
                    try engine.savePlanArtifact(original)
                }
                planInspectorRequest = UUID()
                engine.onTurnComplete[id] = { [weak self, weak engine] succeeded, reply in
                    guard let self, let engine, self.pendingPR.contains(id) else { return }
                    guard succeeded else {
                        self.pendingPR.finish(id)
                        self.resetPRPlan(id, planID: sourcePlan.planID, message: "引擎回合失敗或已停止，未開 PR。請檢查已改動檔案後再確認。")
                        return
                    }
                    Task {
                        defer { self.pendingPR.finish(id) }
                        do {
                            guard !engine.isRunning(id) else { throw PullRequestFailure(message: "討論串仍在工作，未開 PR。") }
                            guard var plan = try engine.loadPlanArtifact(id), plan.planID == sourcePlan.planID,
                                  plan.state == .confirmed else { return }
                            guard let sections = PRPlanReview.sections(reply) else {
                                throw PullRequestFailure(message: "缺少完整 tatwo-pr 五段摘要；未送 PR，請補齊後再確認。")
                            }
                            let snapshot = try await PullRequestService.snapshot(at: checkout.directory)
                            plan.sections = sections; plan.state = .ready
                            plan.updatedAt = TatwoPlanArtifactV1.storagePrecision(Date())
                            plan.prReview = PRPlanReview(directory: checkout.directory, repository: repository,
                                account: identity.username, snapshot: snapshot)
                            plan.sourceAssistantMessageID = engine.transcript(for: id).last { $0.role == .assistant }?.id
                            try engine.savePlanArtifact(plan)
                        } catch {
                            self.resetPRPlan(id, planID: sourcePlan.planID, message: error.localizedDescription)
                        }
                    }
                }
                guard engine.send(threadID: id, text: description + "\n\n" + PullRequestService.contributionInstruction,
                    model: model, engine: kind, systemPrompt: nil, attachments: [],
                    reasoningEffort: effort, serviceTier: tier, ultrawork: ultrawork) else {
                    engine.onTurnComplete[id] = nil
                    throw PullRequestFailure(message: "引擎未接受這次工作，未開 PR。")
                }
            } catch {
                pendingPR.finish(targetID)
                resetPRPlan(targetID, planID: sourcePlan.planID, message: error.localizedDescription)
            }
        }
    }

    private func resetPRPlan(_ id: UUID, planID: UUID, message: String) {
        guard let engine = localLive, var plan = try? engine.loadPlanArtifact(id), plan.planID == planID else { return }
        plan.state = .discussing; plan.executionTurnID = nil; plan.prMessage = message
        _ = persistPlanCanvas(plan)
        engine.appendSystemMessage(threadID: id, text: message, status: "error|PR")
    }

    /// A human has checked the uncertain result; refresh the review without submitting.
    func retryActivePRSubmission() {
        guard selectedRemote == nil, let plan = activePlanArtifact, plan.kind == "pr", plan.state == .ready,
              let review = plan.prReview, review.attempted, review.submittedURL == nil,
              let engine = localLive, !engine.isRunning(plan.threadID), pendingPR.begin(plan.threadID) else { return }
        Task {
            defer { pendingPR.finish(plan.threadID) }
            do {
                let identity = try PullRequestCoordinator.shared.identity()
                guard identity.username == review.account, PullRequestService.repository == review.repository else {
                    throw PullRequestFailure(message: "帳號或倉庫設定已變更；未解除結果未確認狀態。")
                }
                let snapshot = try await PullRequestService().preflight(directory: review.directory, repository: review.repository, identity: identity)
                guard var current = try engine.loadPlanArtifact(plan.threadID), current.planID == plan.planID,
                      current.prReview == review else { return }
                current.prReview = PRPlanReview(directory: review.directory, repository: review.repository, account: review.account, snapshot: snapshot)
                current.prMessage = "已重新檢查目前改動；請審查檔案清單後按「送 PR」。"
                _ = persistPlanCanvas(current)
            } catch {
                guard var current = try? engine.loadPlanArtifact(plan.threadID), current.planID == plan.planID else { return }
                current.prMessage = error.localizedDescription
                _ = persistPlanCanvas(current)
            }
        }
    }

    func submitActivePRPlan() {
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind == "pr", plan.state == .ready,
              var review = plan.prReview, !review.attempted, let engine = localLive,
              !engine.isRunning(plan.threadID), pendingPR.begin(plan.threadID) else { return }
        do {
            let identity = try PullRequestCoordinator.shared.identity()
            guard identity.username == review.account, PullRequestService.repository == review.repository else {
                throw PullRequestFailure(message: "帳號或倉庫設定已變更，請切回卡片顯示的帳號與倉庫。")
            }
            let title = plan.sections.first { $0.title == "標題" }?.body ?? ""
            let description = plan.sections.filter { $0.title != "標題" }.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
            review.attempted = true; plan.prReview = review; plan.prMessage = "送出中…"
            guard persistPlanCanvas(plan) else { pendingPR.finish(plan.threadID); return }
            Task {
                defer { pendingPR.finish(plan.threadID) }
                do {
                    let url = try await PullRequestCoordinator.shared.submitPlan(directory: review.directory, repository: review.repository,
                        identity: identity, snapshot: review.snapshot, title: title, description: description)
                    plan.prReview?.submittedURL = url; plan.prMessage = nil
                } catch {
                    let retryable = plan.prReview?.recordSubmissionFailure(error) == true
                    plan.prMessage = error.localizedDescription + (retryable
                        ? "\n尚未提交程式碼，可按「送 PR」重試。"
                        : "\n未自動重送；請先確認本機分支與 GitHub 結果。")
                }
                _ = persistPlanCanvas(plan)
            }
        } catch {
            pendingPR.finish(plan.threadID); plan.prMessage = error.localizedDescription; _ = persistPlanCanvas(plan)
        }
    }

    func createProjectFromExistingFolder() -> UUID? {
        if rejectRemoteWrite("新增專案") { return nil }
        guard isLive, let live else { return nil }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "選這個資料夾當專案"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if ExternalWorkspacePolicy.contains(url.path) { flashComposerHint(ExternalWorkspacePolicy.projectRefusal); return nil }   // W183 R6c 審查
        let pid = live.newProject(name: url.lastPathComponent, workdir: url.path)
        selectedThreadID = live.newThread(in: pid)
        return pid
    }
    func newChat() {
        if selectedRemote == nil {
            guard isLive, let localLive else { return }
            selectLocalThread(localLive.newThread(in: nil))
            return
        }
        // W100：遠端建立討論串走背景，拿到主機回的 ID 之後才選取（選取方式與改版前相同）。
        guard isLive, let deviceID = selectedRemote?.deviceID,
              let remote = activeRemoteSession?.engine else { return }
        remote.newThread(in: selectedThreadProject?.id, title: "新聊天") { [weak self] (newID: UUID?) in
            guard let self, let newID else { return }
            self.selectedRemote = (deviceID, newID)
            self.selectedThreadID = newID
        }
    }
    func threadActivityDate(_ thread: TatwoNativeChatThread) -> Date {
        localLive?.activityDate(thread.id) ?? .distantPast
    }
    func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        localLive?.setExpanded(projectID, isExpanded)
    }
    func createThread(inProject projectID: UUID) {
        // This action belongs to local project rows, even while a remote
        // conversation is selected. Remote rows have their own actions.
        guard isLive, let localLive,
              document.projects.contains(where: { $0.id == projectID }) else { return }
        selectLocalThread(localLive.newThread(in: projectID))
    }
    func selectDiscussion(projectID: UUID, threadID: UUID, discussionID: UUID) {
        guard
            isLive,
            let activeLive = activeConversationEngine,
            let discussion = activeLive.threadRecord(discussionID),
            discussion.projectID == projectID,
            discussion.parentThreadID == threadID,
            !discussion.isArchived
        else { return }
        if activeLive.doc.isAssistantThread(discussionID) {
            mode = .tatwo
            return
        }
        selectedDiscussionID = discussionID
        if let deviceID = selectedRemote?.deviceID {
            selectedRemote = (deviceID, discussionID)
        }
        selectedThreadID = discussionID
    }
    func compressDiscussion(_ discussionID: UUID) {
        if rejectRemoteWrite("壓縮支線") { return }
        guard isLive, let parentID = live?.compressDiscussion(discussionID) else { return }
        selectedDiscussionID = nil
        selectedThreadID = parentID
    }
    func select(projectID: UUID, threadID: UUID) { selectLocalThread(threadID) }
    func toggleSelectedThreadPinned() {
        if rejectRemoteWrite("釘選討論串") { return }
        if let id = selectedThreadID { live?.togglePinned(id) }
    }
    func selectStandaloneThread(_ threadID: UUID) { selectLocalThread(threadID) }
    @discardableResult
    func reloadPluginRegistry(ifOlderThan age: TimeInterval = 0, now: Date = Date()) -> Task<Void, Never>? {
        guard isLive else { return nil }
        if let pluginRefreshTask { return pluginRefreshTask }
        guard now.timeIntervalSince(lastPluginScanAt) > age else { return nil }
        let environment = runtimeEnvironment
        pluginRefreshTask = Task { @MainActor [weak self] in
            // Skills are local files; publish them before the potentially slow MCP probe.
            let scanned = await Task.detached(priority: .utility) {
                PluginsSource.scanNow(environment: environment)
            }.value
            self?.pluginEntries = scanned
            self?.skillSuggestionSelectedIndex = nil
            let fresh = await Task.detached(priority: .utility) {
                PluginsSource.refreshNow(environment: environment)
            }.value
            self?.pluginEntries = fresh
            self?.lastPluginScanAt = Date()
            self?.pluginRefreshTask = nil
        }
        return pluginRefreshTask
    }
    func isThreadPluginEnabled(_ pluginID: String) -> Bool {
        guard let engine = PluginsSource.mcpEngine(from: pluginID) else { return true }
        guard engine == selectedMCPEngine,
              let name = PluginsSource.mcpName(from: pluginID)
        else { return false }
        let stored = live?.threadRecord(selectedThreadID)?.enabledMCP ?? []
        return PluginsSource.effectiveEnabledNames(
            stored: stored,
            engine: engine,
            environment: runtimeEnvironment).contains(name)
    }
    func applySkillSuggestion(_ entry: PluginRegistryEntry) {
        let token = "$\(entry.id)"
        guard let dollar = prompt.lastIndex(of: "$") else {
            prompt = prompt.isEmpty ? "\(token) " : "\(prompt) \(token) "
            return
        }
        let prefix = prompt[..<dollar]
        let suffix = prompt[prompt.index(after: dollar)...]
        if suffix.contains(where: { $0.isWhitespace || $0.isNewline }) {
            prompt = prompt.isEmpty ? "\(token) " : "\(prompt) \(token) "
        } else {
            prompt = String(prefix) + token + " "
        }
    }
    /// W184 H4 修正（審查 #3）：檔位記在 Coder 開著的那一條（每條自己存、重開 App 還在；私訊框開同一條才一起變）；開、關不換這條的模型。
    func setCollaborationLevel(_ level: ChatCollaborationLevel) {
        setUltraworkLevel(level, for: selectedThreadID)
        flashComposerHint(level == .off
            ? "ultrawork 關閉；這條討論串只有你和主導。"
            : "ultrawork \(level.title)：主導可以用 dispatch_rooms 開房間派工。")
    }
    func setPrimaryModel(_ modelID: String) { setUltraworkRole(modelID, slot: .primary, for: selectedThreadID) }
    func setSecondaryModel(_ modelID: String) { setUltraworkRole(modelID, slot: .auxiliary(0), for: selectedThreadID) }
    /// app-wide 的角色只是「這條還沒記過角色」時的預設；記過的（每條自己的）不蓋（W184 H4 修正：審查 #3）。
    func applyStoredUltraworkRoleDefaults(primaryModelID: String, secondaryModelID: String?) {
        var settings = ultraworkSettings(for: selectedThreadID)
        guard settings.primaryModelID == nil else { return }
        settings.primaryModelID = primaryModelID
        if settings.auxiliaryModelIDs.isEmpty, let secondaryModelID { settings.auxiliaryModelIDs = [secondaryModelID] }
        setUltraworkSettings(settings, for: selectedThreadID)
    }

    /// 開了 ultrawork 時，「檔位＋誰主導＋每一個副手」＝Coder 開著的那條這一輪接在那一句後面的那一段（UltraworkTurnSettings.briefing；
    /// 2.0 的作法：不在 App 寫流程，靠宣告讓各家有共識）。W184 H4 修正（審查 #2）：不再當 sidecar 啟動時的 systemPrompt——每一輪由
    /// ChatLiveEngine.send 的 ultrawork 帶（send()、sendFromDM、PR 那一輪都是）。
    var ultraworkTurnBriefing: String? { ultraworkSettings(for: selectedThreadID).briefing }
    func pasteClipboardImage() -> Bool { pasteClipboardImage(from: .general, preferText: false) }
    func pasteClipboardImage(from pasteboard: NSPasteboard) -> Bool {
        pasteClipboardImage(from: pasteboard, preferText: true)
    }
    func pasteClipboardImage(from pasteboard: NSPasteboard, preferText: Bool) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if ComposerPastePolicy.prefersText(from: pasteboard, fileURLs: urls, preferText: preferText) { return false }
        if rejectRemoteWrite("附件") { return false }
        if isLive, !urls.isEmpty {
            for url in urls { appendDroppedPath(url.path) }
            return true
        }
        guard isLive, let img = NSImage(pasteboard: pasteboard), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        appendDroppedImageData(png, suggestedName: "剪貼簿.png"); return true
    }
    func removeDroppedPath(_ path: String) { droppedPaths.removeAll { $0 == path }; droppedPathDisplayNames[path] = nil }
    func effectivePermissionLabel(compact: Bool) -> String { permissionPreset.shortDisplayName }
    func appendDroppedImageData(_ data: Data, suggestedName: String) {
        if rejectRemoteWrite("附件") { return }
        guard let localLive else { return }
        do {
            let url = try localLive.savePastedAttachment(data: data, suggestedName: suggestedName)
            appendDroppedPath(url.path)
        } catch {
            flashComposerHint("圖片無法保存，請重試")
        }
    }
    func resolveArchiveIssuePrompt(keepIssues: Bool) { pendingArchiveIssuePrompt = nil }
    func captureCurrentDiscussionIntoIssueList() {
        if rejectRemoteWrite("issue") { return }
        if let id = selectedThreadID { live?.captureIssue(threadID: id); refreshIssueLists() }
    }
    func updateIssueListEntryBody(_ id: String, body: String) {
        if rejectRemoteWrite("issue") { return }
        live?.updateIssue(id) { $0.body = body }
        refreshIssueLists()
    }
    /// 匯入交接包：選一個檔，內容進輸入框讓你自己決定要不要送出（不自動執行）。
    func importHandoffPack() {
        if rejectRemoteWrite("匯入交接包") { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選一個交接包（Markdown 或純文字）"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        prompt = prompt.isEmpty ? text : prompt + "\n\n" + text
        flashComposerHint("已帶入 \(url.lastPathComponent)；確認後再送出。")
    }
    func selectCLISession(projectID: UUID, sessionID: UUID) {
        guard
            let project = document.projects.first(where: { $0.id == projectID }),
            let session = project.sessions.first(where: { $0.id == sessionID })
        else { return }
        openCLITab(engine: cliBookEngine(session.engine), workdir: session.cwd)
    }
    func createCLISession(in projectID: UUID, engine: TatwoNativeCLIEngine) {
        guard let project = document.projects.first(where: { $0.id == projectID }) else { return }
        openCLITab(engine: cliBookEngine(engine), workdir: project.workdir)
    }
    func handoffCLISessionToThread(project: TatwoNativeChatProject, session: TatwoNativeCLISession) {}
    func mergeDiscussionIntoParent(_ discussionID: UUID) {
        if rejectRemoteWrite("合併支線") { return }
        guard isLive, let parentID = live?.mergeDiscussionIntoParent(discussionID) else { return }
        selectedDiscussionID = nil
        selectedThreadID = parentID
    }
    func requestRenameSelectedThread() {
        if rejectRemoteWrite("改名") { return }
        guard isLive, let id = selectedThreadID, let current = live?.threadRecord(id)?.title else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名對話串"
        alert.informativeText = "只改 Tatwo2 的討論串標題。"
        alert.addButton(withTitle: "重新命名")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: current)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        live?.rename(id, String(title.prefix(80)))
    }
    func setThreadPlugin(_ pluginID: String, enabled: Bool) {
        if rejectRemoteWrite("修改 MCP") { return }
        guard isLive, PluginsSource.mcpEngine(from: pluginID) != nil else { return }
        live?.setEnabledMCP(pluginID, enabled: enabled, engine: selectedMCPEngine)
        objectWillChange.send()
    }
    private var selectedMCPEngine: PluginsSource.MCPEngine { mcpEngine(for: selectedThreadID) }
    /// 那條討論串最近用的引擎；還沒跑過就看它選的模型（選中那條看目前的模型選擇）。
    private func mcpEngine(for threadID: UUID?) -> PluginsSource.MCPEngine {
        let record = live?.threadRecord(threadID)
        if let raw = record?.engine,
           let engine = PluginsSource.MCPEngine(rawValue: raw) { return engine }
        let route = threadID == selectedThreadID ? routeChoice
            : record?.requestedModel.map(ChatRouteChoice.resolve) ?? routeChoice
        switch route.brandGroup {
        case .openAI: return .codex
        case .anthropic: return .claude
        default: return .grok
        }
    }
    func currentConversationWorkspaceURL() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
    func createLoopsSessionForSelectedThread() {}
    func selectLoopsSession(_ id: UUID) {}
    func archiveLoopsSession(_ id: UUID) {}
    func restoreLoopsSession(_ id: UUID) {}
    func appendHumanLoopNote(_ id: UUID, text: String) {}
    func dispatchLoopSub(_ id: UUID) {}
    func advanceLoopRound(_ id: UUID) {}
    func authorizePLG() {}
    func evaluatePLGMainline(_ accepted: Bool) {}
    func rollbackPLG() {}
    func confirmPLGPlanAndStartLoops() {}
    func endPLGRun() {}
    func togglePLGPause() { plgPaused.toggle() }
    func advanceNativeDevelopmentCycle() -> Bool { false }
    func clearPendingHandoff() {}
    func chooseAttachments() {
        if rejectRemoteWrite("附件") { return }
        guard isLive else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "附加"
        if panel.runModal() == .OK { for url in panel.urls { appendDroppedPath(url.path) } }
    }
    func enableCodexThreadMirror() {}
    func issueImageURL(relativeAssetPath: String) -> URL? {
        guard !relativeAssetPath.hasPrefix("/"),
              !relativeAssetPath.split(separator: "/").contains("..") else { return nil }
        let url = issueImageRoot.appendingPathComponent(relativeAssetPath)
        guard url.resolvingSymlinksInPath().path.hasPrefix(
            issueImageRoot.resolvingSymlinksInPath().path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func addImageNotes(to entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        guard isLive, let live else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.message = "選要附在這則 issue 的圖片"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var added: [String] = []
        for url in panel.urls {
            let name = "\(entry.id)-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
            let dest = issueImageRoot.appendingPathComponent(name)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { added.append(name) }
        }
        guard !added.isEmpty else { flashComposerHint("圖片複製失敗"); return }
        live.updateIssue(entry.id) { $0.imageAssetPaths.append(contentsOf: added) }
        refreshIssueLists()
        flashComposerHint("已附加 \(added.count) 張圖片")
    }
    func createDiscussionForSelectedThread() {
        if rejectRemoteWrite("建立支線") { return }
        guard
            isLive,
            let parentID = selectedThreadID,
            let discussionID = live?.createDiscussion(parentThreadID: parentID)
        else { return }
        selectedDiscussionID = discussionID
        selectedThreadID = discussionID
    }
    func applySlashCommandSuggestion(_ item: SlashCommandItem) {
        // 只替換已打好的那半截指令，不動使用者其他字（1.0 :3100）
        prompt = ChatComposerSlashCatalog.inserting(command: item.cmd, into: prompt)
    }
    func archiveSelectedThread() {
        if rejectRemoteWrite("封存") { return }
        guard isLive, let threadID = selectedThreadID else { return }
        let next = live?.archive(threadID)
        selectedDiscussionID = nil
        selectedThreadID = next
    }
    func checkGitHubRepoUpdates(for projectID: UUID) {
        guard
            isLive,
            !gitHubRepoCheckingProjectIDs.contains(projectID),
            let project = live?.projectRecord(projectID),
            !project.githubRepos.isEmpty
        else { return }
        gitHubRepoCheckingProjectIDs.insert(projectID)
        gitHubRepoCheckMessages[projectID] = nil
        let workdir = project.workdir
        Task { @MainActor [weak self] in
            let message = await Task.detached(priority: .utility) {
                Self.readGitHubRepoStatus(workdir: workdir)
            }.value
            guard let self else { return }
            self.gitHubRepoCheckMessages[projectID] = message
            self.gitHubRepoCheckingProjectIDs.remove(projectID)
        }
    }
    func isCheckingGitHubRepo(for projectID: UUID) -> Bool {
        gitHubRepoCheckingProjectIDs.contains(projectID)
    }
    func gitHubRepoCheckMessage(for projectID: UUID) -> String? {
        gitHubRepoCheckMessages[projectID]
    }
    func copySelectedThreadSummary() {
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID, let thread = activeLive.threadRecord(id) else { return }
        let rows = activeLive.transcript(for: id).suffix(20)
        let body = rows.map { "\($0.role.storageValue)：\($0.text)" }.joined(separator: "\n")
        let summary = body.isEmpty ? "標題：\(thread.title)" : "標題：\(thread.title)\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        flashComposerHint("已複製摘要")
    }
    func duplicateSelectedThread(asBranch: Bool) {
        if rejectRemoteWrite(asBranch ? "建立支線副本" : "複製討論串") { return }
        guard
            isLive,
            let sourceID = selectedThreadID,
            let copyID = live?.duplicate(sourceID, asBranch: asBranch)
        else { return }
        selectedDiscussionID = asBranch ? copyID : nil
        selectedThreadID = copyID
    }
    /// →/↓ 下一個、←/↑ 上一個、Enter 插入。優先序：@ issue → / 指令 → $ 技能。1.0 :1344
    func handleComposerSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        if issueAtMentionQuery != nil, !issueAtMentionMatches.isEmpty { return handleIssueMentionKey(key) }
        if !matchingSlashCommands.isEmpty { return handleSlashSuggestionKey(key) }
        return handleSkillSuggestionKey(key)
    }

    func handleSkillSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = skillSuggestions
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: skillSuggestionSelectedIndex, count: suggestions.count)
            return true
        case .prev:
            guard skillSuggestionSelectedIndex != nil else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: skillSuggestionSelectedIndex, count: suggestions.count)
            return true
        case .commit:
            guard let cur = skillSuggestionSelectedIndex, cur < suggestions.count else { return false }
            applySkillSuggestion(suggestions[cur])
            return true
        }
    }

    func handleSlashSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = matchingSlashCommands
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.next(
                current: slashCommandSelectedIndex, count: suggestions.count)
            return true
        case .prev:
            guard slashCommandSelectedIndex != nil else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: slashCommandSelectedIndex, count: suggestions.count)
            return true
        case .commit:
            guard let cur = slashCommandSelectedIndex ?? (suggestions.count == 1 ? 0 : nil), cur < suggestions.count else { return false }
            applySlashCommandSuggestion(suggestions[cur])
            return true
        }
    }

    func handleIssueMentionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let matches = issueAtMentionMatches
        switch key {
        case .next:
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: issueMentionSelectedIndex, count: matches.count)
            return true
        case .prev:
            guard issueMentionSelectedIndex != nil else { return false }
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: issueMentionSelectedIndex, count: matches.count)
            return true
        case .commit:
            guard let index = issueMentionSelectedIndex, index >= 0, index < matches.count else { return false }
            issueMentionSelectedIndex = nil
            pickIssueMention(matches[index])
            return true
        }
    }
    func handoffThreadToCLISession(project: TatwoNativeChatProject?, thread: TatwoNativeChatThread, engine: TatwoNativeCLIEngine = .codex) {}
    func openThreadProjectInCLI() {
        guard
            canOpenThreadInCLI,
            let thread = live?.threadRecord(selectedThreadID),
            let project = live?.projectRecord(thread.projectID),
            let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: project.workdir, isDirectory: true)],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.flashComposerHint("無法在終端機開啟：\(error.localizedDescription)")
            }
        }
    }
    /// 點選 @ 結果：清掉 @token、把該筆釘進右側資訊卡。1.0 :379
    func pickIssueMention(_ entry: TatwoIssueListEntryV1) {
        if let token = prompt.split(whereSeparator: { $0.isWhitespace }).last, token.hasPrefix("@") {
            prompt.removeSubrange(token.startIndex..<token.endIndex)
        }
        focusedIssueEntryID = entry.id
        requestOpenInfoCard = true
    }
    func removeIssueImageNote(_ relativePath: String, from entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        guard isLive, let engine = localLive as? ChatLiveEngine else { return }
        // Assets may also belong to another issue, composer draft or transcript.
        // Remove this reference only; never move shared bytes underneath readers.
        do {
            try engine.updateIssueImagesChecked(id: entry.id, body: entry.body,
                images: entry.imageAssetPaths.filter { $0 != relativePath })
            refreshIssueLists()
        } catch { flashComposerHint("圖片引用未移除，請重試：\(error.localizedDescription)") }
    }
    func resumeQueuedChatTurns() { chatQueuePaused = false }

    func openCLITestTab(
        executable: String,
        arguments: [String],
        title: String,
        workdir: String
    ) -> UUID? {
        guard let ownerID = selectedThreadID else { return nil }
        let tab = TatwoNativeCLISessionBook.Session(
            id: UUID(),
            engine: .generic,
            title: title,
            workdir: workdir,
            createdAt: Date(),
            updatedAt: Date(),
            isRunning: false)
        cliSessionsByThread[ownerID, default: []].append(tab)
        activeCLITabByThread[ownerID] = tab.id
        cliTabOwner[tab.id] = ownerID
        startCLITab(
            tab,
            launch: TatwoNativeTerminalLaunch(
                executable: executable,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: workdir, isDirectory: true)))
        registerCLIWorkbenchPane(tab, owner: ownerID)
        objectWillChange.send()
        return tab.id
    }

    private func startCLITab(
        _ tab: TatwoNativeCLISessionBook.Session,
        launch: TatwoNativeTerminalLaunch,
        seedText: String? = nil
    ) {
        guard isLive, isCLIRuntimeEnabled, let store = cliSessionStore, let runtime = cliRuntime else { return }
        let owner = cliTabOwner[tab.id]
        let project = owner.flatMap { live?.threadRecord($0)?.projectID }
        store.insert(.init(id: tab.id, title: tab.title, engine: tab.engine.rawValue,
            cwd: tab.workdir ?? NSHomeDirectory(), createdAt: tab.createdAt,
            lastActiveAt: Date(), status: .unknown, pinned: false, order: store.sessions.count,
            threadID: owner, projectID: project, tmuxName: CLITmuxRuntime.name(tab.id), background: false))
        let session = makeCLIWorkbenchSession(id: tab.id, runtime: runtime, store: store)
        cliTabPTYByID[tab.id] = session
        session.start(launch: launch)
    }

    private func updateCLITabRunning(_ id: UUID, isRunning: Bool) {
        guard
            let ownerID = cliTabOwner[id],
            let index = cliSessionsByThread[ownerID]?.firstIndex(where: { $0.id == id })
        else { return }
        cliSessionsByThread[ownerID]?[index].isRunning = isRunning
        cliSessionsByThread[ownerID]?[index].updatedAt = Date()
        objectWillChange.send()
    }

    private func persistCLITabs(ownerID: UUID) {
        let records = (cliSessionsByThread[ownerID] ?? []).map {
            LiveCLITabRecord(
                id: $0.id,
                engine: $0.engine.rawValue,
                cwd: $0.workdir ?? NSHomeDirectory(),
                title: $0.title)
        }
        cliStore?.updateCLITabs(threadID: ownerID, tabs: records)
    }

    private func launchForCLI(
        engine: TatwoNativeCLISessionBook.Engine,
        workdir: String,
        extraArguments: [String] = []
    ) -> TatwoNativeTerminalLaunch {
        let paths = engineLogin.paths
        var environment = runtimeEnvironment
        environment["PATH"] = paths.runtimeBinDirectory.path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TATWO2_OS_SOCKET"] = OSAgentBridge.resolveSocketPath(environment: runtimeEnvironment)
        environment["TATWO2_BROWSER_SOCKET"] = BrowserAgentBridge.resolveSocketPath(environment: runtimeEnvironment)
        let executable: String
        let arguments: [String]
        switch engine {
        case .claude:
            executable = paths.claudeExecutable.path
            environment["CLAUDE_CONFIG_DIR"] = paths.claudeConfigDirectory.path
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = NativeStagingIsolation.sidecarClaudeNamespace(
                environment: environment, configDirectory: paths.claudeConfigDirectory.path)
            arguments = permissionPreset == .askFirst ? ["--permission-mode", "default"] : permissionPreset.claudeArguments
        case .codex:
            executable = paths.codexExecutable.path
            environment["CODEX_HOME"] = paths.codexHome.path
            arguments = permissionPreset.codexArguments
        case .grok:
            executable = paths.runtimeBinDirectory.appendingPathComponent("grok-isolated").path
            environment["TATWO2_GROK_HOME"] = paths.grokHome.path
            arguments = permissionPreset.grokArguments
        case .generic:
            executable = "/bin/zsh"
            arguments = ["-l", "-i"]
        }
        // W181 R3：勾了「不用 API 金鑰」的那家，CLI 分頁也拿掉它的 API 金鑰變數（跟 sidecar 一樣）；沒勾不動。
        if let kind = ClaudeSidecar.Kind(rawValue: engine.rawValue) {
            EngineAPIKeyPolicy.removeAPIKeys(from: &environment, for: kind, optedOut: disabledEngines)
        }
        return TatwoNativeTerminalLaunch(executable: executable, arguments: arguments + (engine == .generic ? [] : extraArguments),
            workingDirectory: URL(fileURLWithPath: workdir, isDirectory: true), environment: environment)
    }

    private func cliBookEngine(_ engine: TatwoNativeCLIEngine) -> TatwoNativeCLISessionBook.Engine {
        switch engine {
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .openclaw, .sandbox: return .generic
        }
    }

    private func cliEngineTitle(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .generic: return "Shell"
        }
    }

    nonisolated private static func readGitHubRepoStatus(workdir: String) -> String {
        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workdir, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_ASKPASS"] = "/usr/bin/false"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (
                    process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return (-1, "")
            }
        }

        let fetch = run(["fetch", "--dry-run"])
        let status = run(["status", "-sb"])
        guard status.status == 0 else {
            return "git status -sb 失敗（exit \(status.status)）"
        }

        func count(after marker: String) -> Int {
            guard let range = status.output.range(of: marker) else { return 0 }
            let suffix = status.output[range.upperBound...]
            return Int(String(suffix.prefix(while: \.isNumber))) ?? 0
        }

        let behind = count(after: "behind ")
        let ahead = count(after: "ahead ")
        var parts = [
            "落後 \(behind) commit",
            ahead > 0 ? "有未推 \(ahead) commit" : "無未推 commit",
        ]
        if fetch.status != 0 {
            parts.append("git fetch --dry-run 失敗（exit \(fetch.status)）")
        }
        return parts.joined(separator: "；")
    }


    // MARK: - 驗收用小門（只在 TATWO2_ACCEPT 無頭驗收時使用；不影響畫面）
    func acceptanceNewProject(name: String, workdir: String) -> UUID? { live?.newProject(name: name, workdir: workdir) }
    func acceptanceNewThread(in projectID: UUID?, title: String) -> UUID? {
        guard let live else { return nil }
        let id = live.newThread(in: projectID, title: title); selectedThreadID = id; return id
    }
    func acceptanceRename(_ id: UUID, _ title: String) { live?.rename(id, title) }
    func acceptanceAddIssue(threadID: UUID, title: String, body: String) {
        guard let live else { return }
        live.captureIssue(threadID: threadID)
        if let last = live.issues(threadID: threadID, global: false).first { live.updateIssue(last.id) { $0.title = title; $0.body = body } }
        refreshIssueLists()
    }
    func acceptanceBotID(named name: String) -> String? { botStore?.bots.first { $0.name == name }?.id }
}
