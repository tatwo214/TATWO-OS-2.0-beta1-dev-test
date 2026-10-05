import Foundation
import SwiftUI

/// W184 H4 修正（GPT-6 H4 審查 #2、#3、#5）：一條 thread 的 ultrawork 設定＝檔位（S～XXL，0＝關）＋主導＋每一個副手（副審、sub…）。
/// - 存在那條 thread 的偏好裡（LiveThreadRecord.ultrawork；跟模型、速度、記憶同一個地方，重開 App 還在）；私訊框與主視窗開的是同一條
///   才一起變，不同條互不影響。
/// - 每一輪明確帶著走：本機接在送進 sidecar 的那一句後面（不顯示在對話裡，同目標、記憶），不再只在 sidecar 啟動時讀一次 systemPrompt；
///   遠端序列化成 send_message 的 ultrawork 欄位，主設備收下就記在那條、照樣接在那一句後面。從開著變成關掉的那一輪說一聲「關了」。
/// - 角色：第一次開的時候照 app-wide 的上次設定（UltraworkRoleConfigurationStore，只是「還沒記過」時的預設）記下一整份
///   （主導＋XXL 的四個副手），之後別條改不影響這條；角色陣列整份存、整份送（不是只有 index 0）。
/// - 開、關 ultrawork 不換這條的模型（模型是 selectedModel／requestedModel，ultrawork 只寫這個欄位）。
/// （資料本身——level、primaryModelID、auxiliaryModelIDs——定義在 Facade/ChatLiveStore.swift，跟對話紀錄一起編；這裡是怎麼用。）
extension UltraworkTurnSettings {
    static let off = UltraworkTurnSettings(level: 0, primaryModelID: nil, auxiliaryModelIDs: [])
    /// XXL 的副手數（副審＋sub）：存的時候一律補滿，換到哪一檔都有人。
    static var maxAuxiliaries: Int { UltraworkRoleConfiguration.auxiliaryCount(for: .xxl) }

    var collaborationLevel: ChatCollaborationLevel { ChatCollaborationLevel(rawValue: level) ?? .off }
    var isOn: Bool { collaborationLevel != .off }

    /// 還沒記過的角色照 seed 補齊（主導＋XXL 的副手數）。
    func filled(seed: UltraworkRoleConfiguration) -> UltraworkTurnSettings {
        var copy = self
        if copy.primaryModelID == nil { copy.primaryModelID = seed.primaryModelID }
        while copy.auxiliaryModelIDs.count < Self.maxAuxiliaries {
            copy.auxiliaryModelIDs.append(seed.auxiliaryModelID(at: copy.auxiliaryModelIDs.count))
        }
        return copy
    }

    func roleModelID(_ slot: UltraworkRoleSlot, seed: UltraworkRoleConfiguration) -> String {
        switch slot {
        case .primary:
            return primaryModelID ?? seed.primaryModelID
        case let .auxiliary(index):
            return auxiliaryModelIDs.indices.contains(index) ? auxiliaryModelIDs[index] : seed.auxiliaryModelID(at: index)
        }
    }

    /// 換一個角色的模型（其他角色照舊；還沒記過的先照 seed 補齊）。
    func setting(_ modelID: String, for slot: UltraworkRoleSlot, seed: UltraworkRoleConfiguration) -> UltraworkTurnSettings {
        var copy = filled(seed: seed)
        switch slot {
        case .primary:
            copy.primaryModelID = modelID
        case let .auxiliary(index):
            guard index >= 0 else { return copy }
            while copy.auxiliaryModelIDs.count <= index {
                copy.auxiliaryModelIDs.append(seed.auxiliaryModelID(at: copy.auxiliaryModelIDs.count))
            }
            copy.auxiliaryModelIDs[index] = modelID
        }
        return copy
    }

    /// 這一檔真的上場的副手（照檔位的人數：M 一個副審、L 再加一個 sub…）。
    var activeAuxiliaries: [String] {
        Array(auxiliaryModelIDs.prefix(UltraworkRoleConfiguration.auxiliaryCount(for: collaborationLevel)))
    }

    static func auxiliaryRole(_ index: Int) -> String { index == 0 ? "副審" : "sub \(index)" }

    static let dispatchLine = "可用 tatwo2_os 的 dispatch_rooms 建子討論串；施工才建工作樹。純副審明確指定 readOnly:true，目前支援本機 claude 引擎，只提供 Read/Grep/Glob；其他路徑不會偷偷改成可寫入模式。主導仍負責修正，不需要協作時直接完成工作。"
    static let offBriefing = "## 這一輪的 ultrawork 設定\n已關閉：這一輪不派工（不要用 dispatch_rooms 開房間），前面宣告的主導、副審、sub 不再適用。"

    /// 開著的這一輪接在那一句後面的那一段：檔位、主導、這一檔上場的每一個副手。
    var briefing: String? {
        guard isOn else { return nil }
        var lines = ["## 這一輪的 ultrawork 設定",
                     "檔位：\(collaborationLevel.title)（\(collaborationLevel.subtitle)）"]
        if let primaryModelID { lines.append("主導：\(primaryModelID)") }
        for (index, id) in activeAuxiliaries.enumerated() { lines.append("\(Self.auxiliaryRole(index))：\(id)") }
        lines.append(Self.dispatchLine)
        return lines.joined(separator: "\n")
    }

    /// 這一輪接在那一句後面的：開著＝整段設定；剛從開著變成關＝一句「關了」；一直關著＝什麼都不接。
    static func turnBlock(current: UltraworkTurnSettings?, lastSent: UltraworkTurnSettings?) -> String? {
        if let briefing = current?.briefing { return briefing }
        return lastSent?.isOn == true ? offBriefing : nil
    }

    /// 遠端 send_message 的 ultrawork 欄位：檔位、主導、每一個副手（整份）。
    var wireObject: [String: Any] {
        var object: [String: Any] = ["level": level, "auxiliary": auxiliaryModelIDs]
        if let primaryModelID { object["primary"] = primaryModelID }
        return object
    }

    /// 主設備收：認不得的（檔位不是 0～5、角色不是認得的模型、超過 8 個）當沒帶——這句照常送、照那條記住的。
    /// 模型名一律換成路由的正式名稱（會接進送給引擎的那一句，不收任意文字）。
    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #3）：欄位「不在」跟「在但型別不對」分開：不在＝那一項沒帶（主導 nil、副手空）；
    /// 在但型別不對、內容認不得（例 `"auxiliary": "壞資料"`、檔位是 true）＝整份當沒帶（回 nil），不拿空的蓋掉那條原本的設定。
    static func accepting(_ value: Any?) -> UltraworkTurnSettings? {
        guard let object = value as? [String: Any], let number = object["level"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let level = object["level"] as? Int,
              ChatCollaborationLevel(rawValue: level) != nil else { return nil }
        func model(_ raw: Any?) -> String? {
            guard let text = raw as? String, !text.isEmpty, text.count <= 80 else { return nil }
            return ChatRouteChoice.resolveOrNil(text)?.canonicalModelSlug
        }
        var primary: String?
        if let raw = object["primary"] {
            guard let resolved = model(raw) else { return nil }
            primary = resolved
        }
        var auxiliary: [String] = []
        if let raw = object["auxiliary"] {
            guard let list = raw as? [Any], list.count <= 8 else { return nil }
            auxiliary = list.compactMap { model($0) }
            guard auxiliary.count == list.count else { return nil }
        }
        return UltraworkTurnSettings(level: level, primaryModelID: primary, auxiliaryModelIDs: auxiliary)
    }
}

/// W184 H4 修正（審查 #2、#3）：別台上那條（副設備的 Coder 走主設備、私訊框的別台 session）在這台改了、還沒送到的 ultrawork。
/// 下一句由 RemoteLiveEngine 帶過去（send／deliver 的 ultrawork 欄位），主設備收下就記在那條；之後照那台記的。只在記憶體
/// （同 TatwoMemoryStrengthPending）。
/// W184 H4 修正第二輪（GPT-6 H4b 審查 #2）：
/// - 每一次明確的選擇都記下來（就算跟那台現在的一樣），帶一個世代；送出時帶著世代，那台收下時只確認那一個世代——送的途中又改過
///   （包括改回原本的值）就留著新的，下一句再帶，最新的選擇不會被舊回覆蓋掉。
/// - 那台收下時先記成「已確認」（畫面照它），不等下一次刷新成功；刷新到「收下之後才開始拉」的文件，才把已確認的那一份交還給文件。
@MainActor
final class TatwoUltraworkPending: ObservableObject {
    static let shared = TatwoUltraworkPending()

    struct Entry: Equatable {
        var settings: UltraworkTurnSettings
        var generation: Int
        /// 那台回覆收下的時間（RemoteLiveEngine.clock()）；nil＝還沒送到。
        var confirmedAt: TimeInterval?
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    private var lastGeneration = 0

    /// 畫面與送出看的那一份（還沒送到的，或已確認、文件還沒跟上的）；nil＝照那台文件裡記的。
    func value(for threadID: UUID) -> UltraworkTurnSettings? { entries[threadID]?.settings }

    /// 還沒送到的那一份與它的世代（送出時帶；已確認的不用再帶）。
    func outgoing(for threadID: UUID) -> (settings: UltraworkTurnSettings, generation: Int)? {
        guard let entry = entries[threadID], entry.confirmedAt == nil else { return nil }
        return (entry.settings, entry.generation)
    }

    /// 明確的選擇：一律記下（新世代），等下一句帶過去。
    func set(_ settings: UltraworkTurnSettings, for threadID: UUID) {
        lastGeneration += 1
        entries[threadID] = Entry(settings: settings, generation: lastGeneration, confirmedAt: nil)
    }

    /// 那台回覆收下了第 generation 份：先記成已確認（畫面照它）；送的途中又改過（世代變了）就不動，留著新的。
    func delivered(_ threadID: UUID, generation: Int, at time: TimeInterval) {
        guard entries[threadID]?.generation == generation, entries[threadID]?.confirmedAt == nil else { return }
        entries[threadID]?.confirmedAt = time
    }

    /// 刷新到的文件是在確認之後才開始拉的：那台的紀錄已經含這一份（或之後別處改的）→ 交還給文件。還沒送到的不動。
    func reconcile(threadIDs: Set<UUID>, fetchStartedAt: TimeInterval) {
        for (id, entry) in entries where threadIDs.contains(id) {
            if let confirmedAt = entry.confirmedAt, fetchStartedAt >= confirmedAt { entries[id] = nil }
        }
    }

    func clear(_ threadID: UUID) { entries[threadID] = nil }
}

// MARK: - ChatPageModel：每一條自己的 ultrawork

@MainActor
extension ChatPageModel {
    /// 那一條在哪：本機（這台的對話檔）、別台（Coder 看遠端設備時開著的那條、私訊框的別台 session）、還沒有 thread、接不到那台。
    enum UltraworkLocation {
        case local(ChatLiveEngine, UUID)
        case remote(LiveDocumentRecord, UUID)
        case unbound
        case unavailable
    }

    func ultraworkLocation(_ threadID: UUID?) -> UltraworkLocation {
        guard let threadID else { return .unbound }
        if let engine = localLiveForBridge, engine.threadRecord(threadID) != nil { return .local(engine, threadID) }
        if let remote = selectedRemote, remote.threadID == threadID,
           let engine = remoteSessions.first(where: { $0.device.id == remote.deviceID })?.engine,
           engine.threadRecord(threadID) != nil {
            return .remote(engine.doc, threadID)
        }
        if let engine = dmRemote(for: threadID)?.engine { return .remote(engine.doc, threadID) }
        return .unavailable
    }

    /// 那一條的 ultrawork：卡上看到的＝送出時帶的（本機讀那條的紀錄；別台的＝這台改了還沒送到的 → 那台記的；沒有 thread＝記憶體裡的）。
    func ultraworkSettings(for threadID: UUID?) -> UltraworkTurnSettings {
        switch ultraworkLocation(threadID) {
        case .local(let engine, let id):
            return engine.threadRecord(id)?.ultrawork ?? .off
        case .remote(let doc, let id):
            return TatwoUltraworkPending.shared.value(for: id) ?? doc.threads.first { $0.id == id }?.ultrawork ?? .off
        case .unbound:
            return UltraworkTurnSettings(level: collaborationLevel.rawValue, primaryModelID: ultraworkPrimaryModelID,
                                         auxiliaryModelIDs: ultraworkAuxiliaryModelIDs)
        case .unavailable:
            return .off
        }
    }

    /// 這一條的 ultrawork 能不能在這台改（別台連不上＝不能）。
    func canSetUltrawork(for threadID: UUID?) -> Bool {
        if case .unavailable = ultraworkLocation(threadID) { return false }
        return true
    }

    /// 只改那一條：本機的寫進那條的偏好；別台的先記在這台，跟下一句一起帶過去。那條正好是 Coder 開著的那條：Coder 的卡、Plan、chip 跟著變。
    func setUltraworkSettings(_ settings: UltraworkTurnSettings, for threadID: UUID?) {
        switch ultraworkLocation(threadID) {
        case .local(let engine, let id):
            engine.setUltrawork(threadID: id, settings)
        case .remote(_, let id):
            // W184 H4 修正第二輪（審查 #2）：每一次明確的選擇都記（就算跟那台現在的一樣：送的途中改回原值也要留著）。
            TatwoUltraworkPending.shared.set(settings, for: id)
        case .unbound:
            break
        case .unavailable:
            return
        }
        if threadID == selectedThreadID { applyUltraworkMirror(settings) }
        objectWillChange.send()
    }

    /// 換檔位（Off＝關）：第一次開的時候照 app-wide 的上次設定記下整份角色；開、關都不換這條的模型。
    func setUltraworkLevel(_ level: ChatCollaborationLevel, for threadID: UUID?) {
        var settings = ultraworkSettings(for: threadID)
        settings.level = level.rawValue
        if level != .off { settings = settings.filled(seed: UltraworkRoleConfigurationStore().load()) }
        setUltraworkSettings(settings, for: threadID)
    }

    func ultraworkRoleModelID(_ slot: UltraworkRoleSlot, for threadID: UUID?) -> String {
        ultraworkSettings(for: threadID).roleModelID(slot, seed: UltraworkRoleConfigurationStore().load())
    }

    /// 換一個角色的模型（主導、副審、每一個 sub 各自記；只改那一條）。
    func setUltraworkRole(_ modelID: String, slot: UltraworkRoleSlot, for threadID: UUID?) {
        let settings = ultraworkSettings(for: threadID).setting(modelID, for: slot, seed: UltraworkRoleConfigurationStore().load())
        setUltraworkSettings(settings, for: threadID)
    }

    /// Coder 開著的那條換了：卡、Plan、chip 看的那幾個值照那條讀回來（沒有 thread＝留著記憶體裡的）。
    func restoreUltraworkPreferences() {
        guard selectedThreadID != nil else { return }
        applyUltraworkMirror(ultraworkSettings(for: selectedThreadID))
    }

    func applyUltraworkMirror(_ settings: UltraworkTurnSettings) {
        if collaborationLevel != settings.collaborationLevel { collaborationLevel = settings.collaborationLevel }
        if ultraworkPrimaryModelID != settings.primaryModelID { ultraworkPrimaryModelID = settings.primaryModelID }
        let secondary = settings.auxiliaryModelIDs.first
        if ultraworkSecondaryModelID != secondary { ultraworkSecondaryModelID = secondary }
        if ultraworkAuxiliaryModelIDs != settings.auxiliaryModelIDs { ultraworkAuxiliaryModelIDs = settings.auxiliaryModelIDs }
    }

    /// W184 H4 修正（審查 #9）：這一條的這一輪實際在哪台跑，就照那台判斷引擎能不能用：本機的照這台（isEngineDisabled）；
    /// 別台上的（MacBook 的 Coder 走主設備）照那台自己回報的（get_document 附的 blockedEngines）——不拿這台的停用錯擋那台；
    /// 舊版主設備沒回報＝不知道，不擋（那台自己會擋，同私訊框、助理接主設備的規則）。
    func coderRouteBlocked(_ kind: ClaudeSidecar.Kind) -> Bool {
        guard let remote = selectedRemote else { return isEngineDisabled(kind) }
        let engine = remoteSessions.first { $0.device.id == remote.deviceID }?.engine
        return engine?.hostBlockedEngines?.contains(kind.rawValue) ?? false
    }

    /// Coder 看的是別台上的那條：那台叫什麼（「「名字」」）；本機的＝nil。
    var coderRemotePlace: String? {
        guard let remote = selectedRemote else { return nil }
        let name = remoteSessions.first { $0.device.id == remote.deviceID }?.device.name
        return name.map { "「\($0)」" } ?? "別台"
    }
}
