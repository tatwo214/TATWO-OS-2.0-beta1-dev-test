import Combine
import Foundation

/// 模型資料只快取在記憶體。選模或送出時喚醒；送出須就緒，登入狀態與可用目錄分開。
enum ChatGPTTapModelCatalog {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var models: [TapModel] = []
        var rememberedTitles: [String: String] = [:]
        var currentEffortID: String?
        var fetchedAt: Date?
        var revision: UInt64 = 0
    }
    private static let cache = Cache()
    static let prefix = "chatgpt-tap:"
    static var revision: UInt64 {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.revision
    }
    static func routeID(_ modelID: String) -> String { prefix + modelID }
    static func isRouteID(_ id: String) -> Bool { id.hasPrefix(prefix) }
    static func modelID(_ routeID: String) -> String { String(routeID.dropFirst(prefix.count)) }
    static var snapshot: [TapModel] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.models
    }
    static let maxAge: TimeInterval = 300
    static var isFresh: Bool {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.fetchedAt.map { Date().timeIntervalSince($0) < maxAge } ?? false
    }
    static func replace(_ models: [TapModel], currentEffortID: String? = nil, fetchedAt: Date = Date()) {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.models != models || cache.currentEffortID != currentEffortID { cache.revision &+= 1 }
        for model in models { cache.rememberedTitles[model.id] = modelTitle(model.title) }
        cache.models = models
        cache.currentEffortID = currentEffortID
        cache.fetchedAt = models.isEmpty ? nil : fetchedAt
    }
    /// 回覆紀錄只回填名稱；不讓歷史快照變成可送出的模型或推理能力。
    static func rememberDisplayName(_ title: String, routeID: String) {
        guard isRouteID(routeID), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title != "ChatGPT 模型" else { return }
        cache.lock.lock(); defer { cache.lock.unlock() }
        let normalized = modelTitle(title)
        let id = modelID(routeID)
        guard cache.rememberedTitles[id] != normalized else { return }
        cache.rememberedTitles[id] = normalized
        cache.revision &+= 1
    }
    static func rememberedTitle(_ modelID: String) -> String? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.rememberedTitles[modelID]
    }
    static func unavailabilityReason(connection: TapConnection, routeID: String? = nil) -> String? {
        switch connection {
        case .needsLogin: return "請打開 ChatGPT 登入"
        case .sleeping: return "ChatGPT 已休眠；選擇模型會自動喚醒"
        case .off: return "ChatGPT 已停用；請在設定開啟 ChatGPT 連接功能"
        case .starting: return "ChatGPT 啟動中；請稍候"
        case .failed: return "ChatGPT 連線失敗；請打開 ChatGPT 重新連線"
        case .ready:
            guard isFresh, !snapshot.filter(isCoderModel).isEmpty else {
                return "ChatGPT 模型目錄未就緒或已過期；開啟模型選單重新整理"
            }
            if let routeID, !snapshot.filter(isCoderModel).contains(where: { self.routeID($0.id) == routeID }) {
                return "這個 ChatGPT 模型已不在目錄中；請重新選擇"
            }
            return nil
        }
    }
    @MainActor
    static func refreshForSend(tap: any ConversationTap) async throws {
        guard tap.connection == .ready else { throw TapError.notReady }
        guard !isFresh else { return }
        do {
            let models = try await tap.models()
            try Task.checkCancellation()
            guard tap.connection == .ready else { throw TapError.notReady }
            replace(models.items, currentEffortID: models.currentEffortID)
            guard isFresh else { throw TapError.remote("ChatGPT 模型目錄是空的") }
        } catch {
            throw TapError.remote("ChatGPT 模型目錄重新整理失敗，這句未送出：\(error.localizedDescription)")
        }
    }

    static func defaultEffort(for model: TapModel) -> String? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return model.efforts.first { $0.id == cache.currentEffortID }?.id ?? model.efforts.first?.id
    }
    static var choices: [ChatRouteChoice] {
        let models = snapshot.filter(isCoderModel)
        return models.isEmpty
            ? [choice(model: TapModel(id: "unavailable", title: "打開後選擇模型", detail: ""))]
            : models.map(choice)
    }
    static func isCoderModel(_ model: TapModel) -> Bool {
        let name = model.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = model.id.lowercased().replacingOccurrences(of: "_", with: "-")
        return !name.contains("deep research") && !name.contains("深入研究")
            && !id.contains("deep-research") && !id.contains("deepresearch")
    }
    static func modelTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "o 3-pro" ? "o3-pro" : title
    }
    static func effortTitle(_ effort: TapEffort) -> String {
        let titles = ["instant": "即時", "auto": "自動", "light": "輕量", "standard": "標準",
                      "extended": "延長", "thinking": "思考", "pro": "專業", "heavy": "深入",
                      "thorough": "深入", "quick": "快速", "low": "低", "medium": "中", "high": "高",
                      "xhigh": "最高", "minimal": "最低"]
        if let title = titles[effort.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            ?? titles[effort.id.lowercased()] { return title }
        return effort.title.range(of: "[\\p{Han}]", options: .regularExpression) != nil ? effort.title : "其他強度"
    }
    static func choice(model: TapModel) -> ChatRouteChoice {
        ChatRouteChoice(profile: TatwoChatRouteProfile(
            id: routeID(model.id), displayName: modelTitle(model.title), family: "ChatGPT",
            engine: .codex, runtimeAdapter: .chatgptTap, canonicalModelSlug: routeID(model.id),
            modelArgument: routeID(model.id), contextWindowLabel: "ChatGPT 訂閱",
            supportsImageInput: false, pluginFit: "ChatGPT", sessionRisk: "獨立登入",
            defaultEffort: .medium, allowedEfforts: [], allowedSpeedTiers: [], notes: []))
    }
}

@MainActor
final class ChatGPTTapModelObservation {
    /// Coder 開啟選單時沿用 LiveEngine 已持有的觀察器，不另開 Pod 或登入檢查。
    static weak var current: ChatGPTTapModelObservation?
    private var observation: AnyCancellable?
    private var noticeWatch: AnyCancellable?
    private var refresh: Task<Void, Never>?
    private var generation = 0
    private weak var tap: ChatGPTTap?
    private let onChange: () -> Void
    init(tap: ChatGPTTap? = nil, onNotice: @escaping (String) -> Void = { _ in }, onChange: @escaping () -> Void) {
        let tap = tap ?? ChatGPTTap.shared
        self.tap = tap
        self.onChange = onChange
        noticeWatch = tap.$recoveryNotice.compactMap { $0 }.sink(receiveValue: onNotice)
        observation = tap.$connection.removeDuplicates().sink { [weak self, weak tap] connection in
            guard let self, let tap else { return }
            self.generation += 1
            let generation = self.generation
            self.refresh?.cancel()
            // Keep display choices in memory while sleeping or waking; send admission still requires ready.
            if connection != .sleeping, connection != .starting { ChatGPTTapModelCatalog.replace([]) }
            onChange()
            guard connection == .ready else { return }
            self.reload(tap, generation: generation)
        }
        Self.current = self
    }
    func refreshIfNeeded() {
        guard let tap, tap.connection == .ready,
              !ChatGPTTapModelCatalog.isFresh else { return }
        generation += 1
        refresh?.cancel()
        reload(tap, generation: generation)
    }
    private func reload(_ tap: ChatGPTTap, generation: Int) {
        refresh = Task { @MainActor [weak self, weak tap] in
            guard let tap else { return }
            let models = try? await tap.models()
            guard !Task.isCancelled, self?.generation == generation, tap.connection == .ready else { return }
            ChatGPTTapModelCatalog.replace(models?.items ?? [], currentEffortID: models?.currentEffortID)
            self?.onChange()
            // 到期只刷新可用性，不喚醒 Pod，也不自動送出或重新整理。
            try? await Task.sleep(for: .seconds(ChatGPTTapModelCatalog.maxAge))
            guard !Task.isCancelled, self?.generation == generation else { return }
            self?.onChange()
        }
    }
    deinit { refresh?.cancel() }
}
