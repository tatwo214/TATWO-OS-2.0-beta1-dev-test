import Foundation

/// W180 E1：記憶強度 chip 的對象。助理＝TATWO 輸入框與私訊框的助理；Coder＝Coder 輸入框開著的那條；thread＝私訊框的某條 session。
enum TatwoMemoryChipTarget: Equatable, Sendable {
    case assistant
    case coder
    case thread(UUID)
}

/// chip 上要畫的樣子。
struct TatwoMemoryChipState: Equatable {
    let strength: TatwoMemoryStrength
    /// 在別台（主設備或其他配對設備）上跑：選的值只記在這台記憶體，跟下一句一起帶過去。
    let remotePlace: String?
    let isEnabled: Bool
    /// 選單第一行（不能點）。
    var headline: String {
        if let remotePlace { return "在\(remotePlace)上跑；選了跟下一句一起帶過去" }
        return "記憶強度（只改這一條）"
    }
}

/// W180 E1：別台上那條在這台選的記憶強度，還沒送到之前放這裡（只在記憶體，不寫本機的對話檔）。
/// 下一句送出時由 RemoteLiveEngine 帶過去（send／deliver 的 memoryStrength 參數），送到就清掉，之後照那台記的。
@MainActor
final class TatwoMemoryStrengthPending: ObservableObject {
    static let shared = TatwoMemoryStrengthPending()
    @Published private(set) var values: [UUID: TatwoMemoryStrength] = [:]

    func value(for threadID: UUID) -> TatwoMemoryStrength? { values[threadID] }

    func set(_ strength: TatwoMemoryStrength, for threadID: UUID) { values[threadID] = strength }

    /// 那台回覆收到了：送出去的就是現在記的那個才清（送的途中又改過就留著，下一句再帶）。
    func delivered(_ threadID: UUID, _ sent: TatwoMemoryStrength?) {
        guard let sent, values[threadID] == sent else { return }
        values[threadID] = nil
    }

    func clear(_ threadID: UUID) { values[threadID] = nil }
}

extension ChatPageModel {
    private enum MemoryLocation {
        case local(ChatLiveEngine, UUID)
        case remote(doc: LiveDocumentRecord, id: UUID, place: String)
    }

    private func memoryLocation(_ target: TatwoMemoryChipTarget) -> MemoryLocation?? {
        switch target {
        case .assistant:
            switch assistantPlacement {
            case .local:
                guard let engine = localLiveForBridge, let id = assistantThreadID else { return nil }
                return .some(.local(engine, id))
            case .primary(let remote, let id, let device):
                return .some(.remote(doc: remote.doc, id: id, place: "主設備「\(device.displayName)」"))
            case .unreachable:
                return .some(nil)
            }
        case .coder:
            guard mode == .chat, let id = selectedThreadID else { return nil }
            if let remote = selectedRemote {
                guard let session = remoteSessions.first(where: { $0.device.id == remote.deviceID }),
                      let engine = session.engine else { return .some(nil) }
                return .some(.remote(doc: engine.doc, id: remote.threadID, place: "「\(session.device.name)」"))
            }
            guard let engine = localLiveForBridge else { return nil }
            return .some(.local(engine, id))
        case .thread(let id):
            if let engine = localLiveForBridge, engine.threadRecord(id) != nil { return .some(.local(engine, id)) }
            guard let remote = dmRemote(for: id), let engine = remote.engine else { return .some(nil) }
            return .some(.remote(doc: engine.doc, id: id, place: remote.place))
        }
    }

    /// chip 的樣子；nil＝不顯示（Bot 串、不是 Coder 對話、沒有對象）。接不到那台時照預設畫、但不能點。
    func memoryChipState(_ target: TatwoMemoryChipTarget) -> TatwoMemoryChipState? {
        guard let location = memoryLocation(target) else { return nil }
        switch location {
        case .local(let engine, let id)?:
            guard let record = engine.threadRecord(id), !record.isMemoryBotThread else { return nil }
            return TatwoMemoryChipState(strength: engine.doc.memoryStrength(for: id), remotePlace: nil, isEnabled: true)
        case .remote(let doc, let id, let place)?:
            guard let record = doc.threads.first(where: { $0.id == id }), !record.isMemoryBotThread else { return nil }
            let strength = TatwoMemoryStrengthPending.shared.value(for: id) ?? doc.memoryStrength(for: id)
            return TatwoMemoryChipState(strength: strength, remotePlace: place, isEnabled: true)
        case nil:
            // 連線中／連不上：照助理的預設畫，不能點。
            return TatwoMemoryChipState(strength: target == .assistant ? .medium : .light, remotePlace: nil, isEnabled: false)
        }
    }

    /// 只改那一條：本機的直接寫進那條；別台上的先記在這台，跟下一句一起帶過去。Coder 的選取、其他串都不動。
    func setMemoryStrength(_ strength: TatwoMemoryStrength, for target: TatwoMemoryChipTarget) {
        guard let location = memoryLocation(target) else { return }
        switch location {
        case .local(let engine, let id)?:
            guard let record = engine.threadRecord(id), !record.isMemoryBotThread else { return }
            engine.setMemoryStrength(threadID: id, strength)
        case .remote(let doc, let id, _)?:
            guard let record = doc.threads.first(where: { $0.id == id }), !record.isMemoryBotThread else { return }
            if doc.memoryStrength(for: id) == strength, record.memoryStrength != nil {
                TatwoMemoryStrengthPending.shared.clear(id)
            } else {
                TatwoMemoryStrengthPending.shared.set(strength, for: id)
            }
        case nil:
            return
        }
        objectWillChange.send()
    }

    /// 呼叫記憶工具的是哪一條：出處（助理或 Coder、哪家引擎、哪一條）與能不能用（本機那份；工具只在跑引擎的這台被叫）。
    /// Bot 串一律不給記憶工具（對外的 Bot 不能讀使用者的私人記憶，也不能寫進去）；唯讀副審只能讀、不能記下。
    func memoryToolOrigin(_ threadID: UUID?) -> TatwoMemoryOrigin {
        guard let threadID, let engine = localLiveForBridge, let record = engine.threadRecord(threadID) else {
            return TatwoMemoryOrigin(who: "OS 裡的 AI", engine: nil, threadID: threadID)
        }
        if record.isMemoryBotThread {
            return TatwoMemoryOrigin(who: "Bot", engine: record.engine, threadID: threadID, isBot: true)
        }
        let who = engine.doc.isAssistantThread(threadID) ? "TATWO 助理" : "Coder「\(String(record.title.prefix(20)))」"
        return TatwoMemoryOrigin(who: who, engine: record.engine, threadID: threadID, readOnly: record.roomReadOnly == true)
    }
}
