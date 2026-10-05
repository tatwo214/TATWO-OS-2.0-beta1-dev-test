import SwiftUI
import Combine

/// Session space 借用既有分頁的選取適配，不擁有新的分頁、profile 或瀏覽器實作。
@MainActor
final class BrowserSessionProjection: ObservableObject {
    struct Identity: Hashable { let source: ObjectIdentifier; let pick: BrowserChatSessionSelection.Pick }
    let pick: BrowserChatSessionSelection.Pick
    let store: BrowserWorkSpaceStore
    let runtime: BrowserWorkSpaceRuntime
    private let selection: BrowserChatSessionSelection
    private let bound: Bool
    private var observation: AnyCancellable?

    init(pick: BrowserChatSessionSelection.Pick, registry: BrowserTabRegistry,
         selection: BrowserChatSessionSelection = .shared) {
        self.pick = pick
        self.selection = selection
        store = BrowserWorkSpaceStore(registry: registry)
        runtime = BrowserWorkSpaceRuntime.forChat("chat-browser-inspector", registry: registry, adoptsWorkSpaceTabs: true)
        bound = Self.selectExisting(pick, in: store)
        if bound {
            // @Published 在 willSet 發送，因此用傳入的 alias，不讀尚未更新的 selectedID。
            observation = store.$selectedID.dropFirst().sink { [weak self] alias in self?.publishSelection(alias) }
        }
    }

    static func owns(_ tabID: UUID?, spaceID: UUID, registry: BrowserTabRegistry) -> Bool {
        guard let tabID,
              let space = registry.spaces.first(where: { $0.id == spaceID && !$0.isSessionSpace }),
              BrowserChatSessionSelection.threadID(ofSpaceNamed: space.name) != nil else { return false }
        return registry.tabs.contains { $0.id == tabID && $0.owner == .workSpace(spaceID: spaceID) && !$0.usesAgentContext }
    }

    @discardableResult
    static func selectExisting(_ pick: BrowserChatSessionSelection.Pick, in store: BrowserWorkSpaceStore) -> Bool {
        guard owns(pick.tabID, spaceID: pick.spaceID, registry: store.registry),
              let space = store.spaces.first(where: { $0.registryID == pick.spaceID && !$0.isSessionSpace }) else { return false }
        // 僅選既有記錄；不呼叫會收編游離分頁的 selectThreadSpace，也不改 owner。
        store.selectSpace(space.id)
        store.select(registryID: pick.tabID)
        return store.currentSpaceUUID == pick.spaceID && store.selectedRegistryID == pick.tabID
    }

    var isUsable: Bool {
        bound && store.currentSpaceUUID == pick.spaceID &&
            Self.owns(store.selectedRegistryID, spaceID: pick.spaceID, registry: store.registry)
    }

    var acceptsCommands: Bool {
        isUsable && selection.pick == pick && store.selectedRegistryID == pick.tabID
    }

    func selectForeground(_ id: UUID) {
        guard acceptsCommands, Self.owns(id, spaceID: pick.spaceID, registry: store.registry) else { return }
        store.select(registryID: id)
    }

    private func publishSelection(_ alias: Int) {
        // 舊 surface 的延後通知不能覆蓋使用者剛選的新 session。
        guard selection.pick == pick else { return }
        guard store.currentSpaceUUID == pick.spaceID,
              let tabID = store.tabs.first(where: { $0.id == alias })?.registryID,
              Self.owns(tabID, spaceID: pick.spaceID, registry: store.registry) else {
            selection.pick = nil
            return
        }
        let next = BrowserChatSessionSelection.Pick(spaceID: pick.spaceID, tabID: tabID)
        if selection.pick != next { selection.pick = next }
    }
}

// MARK: - Shared view routing
extension BrowserWorkSpaceDesignView {
    @ViewBuilder var sessionRoutedContent: some View {
        if session == nil, onClose == nil, store.selectedSpace.isSessionSpace, let pick = chatSessionSelection.pick {
            BrowserChatSessionSurface(pick: pick, source: store.registry, sidebarStore: sidebarStore)
                // 換 tab/session 就銷毀舊 command/find/focus；CEF runtime 與原生分頁仍重用。
                .id(BrowserSessionProjection.Identity(source: ObjectIdentifier(store.registry), pick: pick))
        } else {
            workspaceBody
        }
    }

    func selectForegroundTab(_ id: UUID) {
        if let session { session.selectForeground(id) }
        else { store.select(registryID: id) }
    }

    func send(_ action: EmbeddedBrowserCommand.Action) {
        guard session?.acceptsCommands != false else { return }
        commandTabID = store.selectedRegistryID
        command = EmbeddedBrowserCommand(action: action)
    }
}
