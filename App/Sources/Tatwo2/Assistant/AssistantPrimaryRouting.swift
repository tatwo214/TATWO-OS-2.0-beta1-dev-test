import Foundation

/// W179 F：副設備眼中的主設備（身分檔記的主設備 id，對上配對清單裡那一台）。
struct AssistantPrimaryDevice: Equatable, Sendable {
    let id: String
    let displayName: String
}

/// W179 F：助理與私訊框接到主設備那條討論串時用到的讀取與送出。遠端引擎（RemoteLiveEngine）照這個形狀；
/// 自測用最小替身，不連 SSH。
@MainActor
protocol AssistantRemoteEngine: AnyObject {
    var doc: LiveDocumentRecord { get }
    func transcript(for threadID: UUID?) -> [ChatMessage]
    /// 逐字稿還在背景拉（快取是空的）；畫面這時顯示「連線中…」，不顯示空白的歡迎畫面。
    func isTranscriptLoading(_ threadID: UUID?) -> Bool
    func isRunning(_ threadID: UUID?) -> Bool
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord?
    /// 送到主設備，等主設備回覆收到（文件也刷新好）才回報；失敗帶原因，呼叫端留著草稿、顯示一行說明。
    func deliver(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void)
    func stop(threadID: UUID)
}

extension RemoteLiveEngine: AssistantRemoteEngine {}

/// W179 F：接主設備時助理與私訊框的一行提示；threadID nil＝不分哪條（主設備連線的提示）。
struct AssistantPrimaryHint: Equatable {
    let id = UUID()
    let threadID: UUID?
    let text: String
}

/// W179 F：副設備接不到主設備那條助理的原因。
enum AssistantPrimaryGap: Equatable, Sendable {
    /// 正在連主設備（App 剛開的第一次；本機也全停用時含每次重試）：不送、不退回本機那條。
    case connecting
    /// 連不上主設備。
    case offline
    /// 連上了，但主設備的 TATWO OS 還沒有助理（舊版）。
    case noAssistant
}

/// W179 F：助理只有一個、住在主設備。這一刻 TATWO 與私訊框的助理接在哪裡。
enum AssistantPlacement {
    /// 本機助理討論串：主設備、單機，或副設備接不到主設備但本機還有沒停用的引擎（畫面有一行說明）。
    case local
    /// 副設備連得到主設備：用主設備那條（同一段對話），送出走遠端引擎。
    case primary(engine: any AssistantRemoteEngine, threadID: UUID, device: AssistantPrimaryDevice)
    /// 副設備接不到主設備那條（連線中；或連不上、主設備還沒有助理而本機三家也都停用）：只顯示一行說明，不送、草稿留著。
    case unreachable(AssistantPrimaryDevice, AssistantPrimaryGap)

    var isPrimary: Bool {
        if case .primary = self { return true }
        return false
    }

    static func unreachableNote(_ device: AssistantPrimaryDevice, _ gap: AssistantPrimaryGap) -> String {
        switch gap {
        case .offline: "助理在主設備「\(device.displayName)」上，現在連不上；連上後會自動接回。"
        case .connecting: "助理在主設備「\(device.displayName)」上，現在還不能送出；草稿留著。"
        case .noAssistant: "主設備「\(device.displayName)」的 TATWO OS 還沒有助理，更新主設備後會自動接上。"
        }
    }

    /// 送到主設備沒成功時的一行白話說明（草稿一律留著）。主設備回的原因代碼見 OSAgentBridge 的 send_message。
    static func deliveryFailureNote(_ error: Error, device: AssistantPrimaryDevice) -> String {
        let name = device.displayName
        guard case RemoteHostLinkError.remoteError(let code) = error else {
            return "這句沒送到主設備「\(name)」（連線不穩）；草稿留著，等一下再送。"
        }
        switch code {
        case "assistant_busy": return "主設備「\(name)」的助理還在回上一句，這句沒送出；草稿留著，等它回完再送。"
        case "assistant_engines_disabled": return "主設備「\(name)」上的模型都停用了，這句沒送出；草稿留著。"
        case "assistant_engine_disabled": return "你選的模型在主設備「\(name)」上停用了，這句沒送出；換一個模型再送。"
        case "assistant_not_sent": return "主設備「\(name)」沒送出這句（原因寫在對話裡）；草稿留著。"
        default:
            if let reason = RemoteSendRejection.reason(for: code) {
                return "主設備「\(name)」沒收下這句：\(reason)；草稿留著。"
            }
            return "主設備「\(name)」沒收下這句；草稿留著，等一下再送。"
        }
    }
}

enum AssistantPrimaryResolver {
    /// 這台是副設備時回主設備 id（小寫）；主設備、單機、還沒指派或身分檔讀不到都是 nil。只讀，不修任何東西。
    static func primaryDeviceID(environment: [String: String]) -> String? {
        let registry = DeviceRegistry(environment: environment)
        let fleet = DeviceFleetStore(registry: registry, environment: environment)
        do { if let trust = try fleet.trust(), trust.kind != .owner { return nil } }
        catch { return nil }
        guard let identity = try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment)),
              identity.role == .secondary,
              let primary = identity.primaryDeviceID?.lowercased(),
              primary != identity.deviceID.lowercased() else { return nil }
        return primary
    }

    /// 配對清單裡的主設備：先照 id 對；舊紀錄 id 對不上時，只有一台標主設備才用它。沒配對過就是 nil（當單機）。
    static func device(primaryID: String, in records: [DeviceRecord]) -> DeviceRecord? {
        return records.first { $0.id.lowercased() == primaryID }
    }
}

/// 助理模型選單的一列。
struct AssistantModelOption: Identifiable {
    let route: ChatRouteChoice
    let title: String
    let isDisabled: Bool
    let isSelected: Bool
    var id: String { route.id }
}

/// W179 F：助理的模型怎麼挑、怎麼顯示、送到主設備時帶什麼。
enum AssistantModelRouting {
    /// 路由對應的引擎；還沒接上引擎的路由是 nil。
    static func engineKind(for route: ChatRouteChoice) -> ClaudeSidecar.Kind? {
        switch route.brandGroup {
        case .anthropic: return .claude
        case .openAI: return .codex
        case .xAI: return .grok
        default: return nil
        }
    }

    /// 助理跑在哪一台，就在那一台挑沒被停用的路由。依序：助理討論串自己存的選擇 → 主導模型 →
    /// Coder 輸入框目前的模型 → 第一個沒被停用的路由；三家都停用回 nil。
    static func pick(stored: String?, lead: String, coder: String,
                     isDisabled: (ClaudeSidecar.Kind) -> Bool) -> ChatRouteChoice? {
        let preferred = [stored, lead, coder].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(ChatRouteChoice.resolve)
        return (preferred + ChatRouteChoice.all).first { route in
            engineKind(for: route).map { !isDisabled($0) } ?? false
        }
    }

    /// 選單上的名字：路由名本來就是給人看的（有大寫或空白）就照用；
    /// 全小寫的原始路由名補成首字大寫、字母和版本號之間空一格（例「abc5.1」→「Abc 5.1」）。
    static func friendlyName(_ route: ChatRouteChoice) -> String {
        if route.brandGroup == .local { return route.title }
        let title = route.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title == title.lowercased(), !title.contains(" "),
              let first = title.first, first.isLetter else { return title }
        var result = first.uppercased()
        var previous = first
        for character in title.dropFirst() {
            if character.isNumber, previous.isLetter { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    /// 玻璃 chip 上放得下的短名（照 Coder chip：GPT 系列去掉「GPT-」前綴，Claude 去掉品牌字）。
    static func chipName(_ route: ChatRouteChoice) -> String {
        if route.runtimeAdapter == .chatgptTap { return route.commandLabel }
        var name = friendlyName(route)
        if name.hasPrefix("Claude ") { name.removeFirst("Claude ".count) }
        if name.hasPrefix("GPT-"), name.contains(" ") { name.removeFirst("GPT-".count) }
        return name
    }

    /// 選單列：本機跑時被停用的引擎標「已停用」且不能選；接到主設備時不套本機的停用判斷（呼叫端傳永遠 false）。
    static func options(selectedID: String?, deviceID: String = "local", isDisabled: (ClaudeSidecar.Kind) -> Bool) -> [AssistantModelOption] {
        ChatRouteChoice.choices(deviceID: deviceID).compactMap { route -> AssistantModelOption? in
            guard let kind = engineKind(for: route) else { return nil }
            let disabled = isDisabled(kind)
            let name = friendlyName(route)
            return AssistantModelOption(route: route, title: disabled ? "\(name) · 已停用" : name,
                                        isDisabled: disabled, isSelected: route.id == selectedID)
        }
    }

    /// 那條討論串自己記住的模型；沒記過或認不得就是 nil。
    static func storedRoute(_ record: LiveThreadRecord?) -> ChatRouteChoice? {
        guard let raw = record?.requestedModel ?? record?.model,
              let route = ChatRouteChoice.resolveOrNil(raw),
              engineKind(for: route) != nil else { return nil }
        return route
    }

    /// 送給引擎的模型參數（跟 Coder 輸入框同一套換算）。
    static func modelArgument(_ route: ChatRouteChoice, kind: ClaudeSidecar.Kind) -> String? {
        switch kind {
        case .claude: return route.modelArgument
        case .codex: return route.modelArgument ?? route.canonicalModelSlug
        case .grok: return route.modelArgument
        }
    }

    /// 送到主設備的一輪要帶的模型與引擎：只有明確的路由才帶（助理＝這次在選單選的；私訊框的 Coder session＝
    /// 那條自己記住的）；沒有就都不帶，讓主設備照自己的規則挑（助理那條依主設備的順序、跳過主設備停用的引擎）。
    /// 引擎一起帶：模型參數是 nil 的路由（例 Claude 路由沒有 claude- 開頭的參數）主設備才知道是哪一家。
    /// 思考強度、速度由主設備照那條的紀錄補；不套本機的停用判斷。
    static func primaryTurn(choice: ChatRouteChoice?) -> (model: String?, kind: ClaudeSidecar.Kind?) {
        guard let route = choice, let kind = engineKind(for: route) else { return (nil, nil) }
        return (modelArgument(route, kind: kind), kind)
    }
}
