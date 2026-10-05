/// 共用工具目錄的刷新生命週期；不持有 Pod、偏好或聊天內容。
/// 同時只讀一次；連線換代／外掛異動使舊回應失效，最多補讀一次最新狀態。
@MainActor
final class ChatGPTToolCatalog<Value> {
    private let load: @MainActor () async throws -> Value
    private let publish: @MainActor (Value) -> Void
    private var ready = false
    private var generation: UInt64 = 0
    private var pending = false
    private(set) var isRefreshing = false

    init(load: @escaping @MainActor () async throws -> Value,
         publish: @escaping @MainActor (Value) -> Void) {
        self.load = load
        self.publish = publish
    }

    func connectionChanged(ready: Bool, renewed: Bool = false) {
        guard self.ready != ready || (ready && renewed) else { return }
        self.ready = ready
        generation &+= 1
        pending = ready
        if ready { refresh() }
    }

    func refresh(invalidate: Bool = false) {
        if invalidate { generation &+= 1 }
        guard ready else { return }
        // 選單／Space 同時要求刷新時共用這次；明確失效則排在舊請求後補讀。
        if isRefreshing {
            if invalidate { pending = true }
            return
        }
        pending = true
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            while ready && pending {
                pending = false
                let requestGeneration = generation
                do {
                    let value = try await load()
                    guard ready, generation == requestGeneration else { continue }
                    publish(value)
                } catch {
                    // 不清掉上一份、不自動無限重試；下次開選單／外掛頁可再讀。
                }
            }
        }
    }
}
