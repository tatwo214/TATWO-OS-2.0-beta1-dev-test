import Combine
import Foundation

/// 模型資料只快取在記憶體；讀失敗保留清單，送出須重新確認。
enum ChatGPTTapModelCatalog {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var models: [TapModel] = []
        var rememberedTitles: [String: String] = [:]
        var currentEffortID: String?
        var defaultModelID: String?
        var fetchedAt: Date?
        var loading = false
        var failureReason: String?
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
    static func replace(_ models: [TapModel], currentEffortID: String? = nil, defaultModelID: String? = nil, fetchedAt: Date = Date()) {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.models != models || cache.currentEffortID != currentEffortID || cache.defaultModelID != defaultModelID { cache.revision &+= 1 }
        for model in models { cache.rememberedTitles[model.id] = model.title }
        cache.models = models
        cache.currentEffortID = currentEffortID
        cache.defaultModelID = defaultModelID
        cache.fetchedAt = models.isEmpty ? nil : fetchedAt
        cache.failureReason = nil
    }
    static func recordFailure(_ error: Error) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.failureReason = ChatGPTTap.modelReadFailureReason(error)
        cache.fetchedAt = nil
        cache.revision &+= 1
    }
    static func loading(_ value: Bool) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.loading = value
    }
    @MainActor static func readModels(_ tap: any ConversationTap) async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?) {
        do { return try await tap.models() }
        catch { try Task.checkCancellation(); try await Task.sleep(for: .seconds(1)); return try await tap.models() }
    }
    static var failureReason: String? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.loading ? "ChatGPT 模型讀取中" : cache.failureReason
    }
    static func effectiveModel(_ routeID: String) -> TapModel? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return ChatGPTModelMenu.effectiveModel(.init(models: cache.models.filter(isCoderModel), defaultModelID: cache.defaultModelID),
                                              .init(modelID: modelID(routeID)))
    }
    /// 回覆紀錄只回填名稱；不讓歷史快照變成可送出的模型或推理能力。
    static func rememberDisplayName(_ title: String, routeID: String) {
        guard isRouteID(routeID), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title != "ChatGPT 模型" else { return }
        cache.lock.lock(); defer { cache.lock.unlock() }
        let id = modelID(routeID)
        guard cache.rememberedTitles[id] != title else { return }
        cache.rememberedTitles[id] = title
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
            guard !snapshot.filter(isCoderModel).isEmpty else {
                return failureReason ?? "ChatGPT 模型目錄未就緒或已過期；開啟模型選單重新整理"
            }
            if !isFresh, failureReason == nil { return "ChatGPT 模型目錄已過期，待更新" }
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
            guard !models.items.filter(isCoderModel).isEmpty else { throw TapError.remote("ChatGPT 模型目錄是空的") }
            replace(models.items, currentEffortID: models.currentEffortID, defaultModelID: models.defaultID)
        } catch {
            recordFailure(error)
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
    static func effortTitle(_ effort: TapEffort) -> String {
        let titles = ["instant": "即時", "auto": "自動", "light": "輕量", "standard": "標準",
                      "extended": "延長", "thinking": "思考", "pro": "專業", "heavy": "深入",
                      "thorough": "深入", "quick": "快速", "low": "低", "medium": "中", "high": "高",
                      "xhigh": "最高", "minimal": "最低"]
        if let title = titles[effort.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            ?? titles[effort.id.lowercased()] { return title }
        return effort.title
    }
    static func choice(model: TapModel) -> ChatRouteChoice {
        ChatRouteChoice(profile: TatwoChatRouteProfile(
            id: routeID(model.id), displayName: model.title, family: "ChatGPT",
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
    private var isLoading = false
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
            if connection == .needsLogin || connection == .off { ChatGPTTapModelCatalog.replace([]) }
            self.isLoading = false
            ChatGPTTapModelCatalog.loading(connection == .ready)
            onChange()
            guard connection == .ready else { return }
            self.reload(tap, generation: generation)
        }
        Self.current = self
    }
    func refreshIfNeeded() {
        guard let tap, tap.connection == .ready, !ChatGPTTapModelCatalog.isFresh, !isLoading else { return }
        generation += 1
        refresh?.cancel()
        reload(tap, generation: generation)
    }
    private func reload(_ tap: ChatGPTTap, generation: Int) {
        isLoading = true
        ChatGPTTapModelCatalog.loading(true); onChange()
        refresh = Task { @MainActor [weak self, weak tap] in
            guard let tap else { return }
            do {
                let models = try await ChatGPTTapModelCatalog.readModels(tap)
                guard !Task.isCancelled, self?.generation == generation, tap.connection == .ready else { return }
                ChatGPTTapModelCatalog.replace(models.items, currentEffortID: models.currentEffortID, defaultModelID: models.defaultID)
            } catch {
                guard !Task.isCancelled, self?.generation == generation, tap.connection == .ready else { return }
                ChatGPTTapModelCatalog.recordFailure(error)
            }
            guard !Task.isCancelled, self?.generation == generation, tap.connection == .ready else { return }
            self?.isLoading = false
            ChatGPTTapModelCatalog.loading(false)
            self?.onChange()
            // 到期只更新「待更新」標示；開選單才重讀，不喚醒 Pod。
            try? await Task.sleep(for: .seconds(ChatGPTTapModelCatalog.maxAge))
            guard !Task.isCancelled, self?.generation == generation else { return }
            self?.onChange()
        }
    }
    deinit { refresh?.cancel(); ChatGPTTapModelCatalog.loading(false) }
}
