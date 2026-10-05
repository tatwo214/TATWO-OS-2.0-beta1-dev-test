import Combine
import Foundation
import SwiftUI

extension ChatPageModel {
    /// Lifecycle requests reach retained pages even while ordinary updates are hidden.
    static func presentationChanges(_ model: ChatPageModel) -> [AnyPublisher<Void, Never>] {
        func watch<Value: Equatable>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return [watch(model.$mode), watch(model.$requestOpenBrowserPanel), watch(model.$requestOpenAccountBrowser),
                watch(model.$requestOpenInfoCard), watch(model.$requestOpenLoopsPanel), watch(model.$selectedThreadID),
                watch(model.$isRunning), watch(model.$collaborationLevel), watch(model.$planInspectorRequest),
                watch(model.$coldStartHydrationFailureMessage)]
    }
}

/// Own the stores without observing tab content in ChatPage's GeometryReaders.
/// Browser leaf views continue to observe the full stores directly.
@MainActor final class ChatBrowserLayoutObservation: ObservableObject {
    let store: BrowserWorkSpaceStore
    let inspectorStore: BrowserWorkSpaceStore
    let inspectorRuntime: BrowserWorkSpaceRuntime
    private var watch: AnyCancellable?
    init(model: ChatPageModel) {
        self.store = BrowserWorkSpaceStore(registry: model.browserTabRegistry)
        let registry = BrowserTabRegistry.chatInspectorRegistry(source: model.browserTabRegistry)
        inspectorStore = BrowserWorkSpaceStore(registry: registry)
        inspectorRuntime = BrowserWorkSpaceRuntime.forChat("chat-browser-inspector", registry: registry, adoptsWorkSpaceTabs: true)
        let store = self.store
        watch = Publishers.MergeMany([
            store.$selectedSpaceID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$focusMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sidebarInteractionActive.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$hoverRailShown.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$spaces.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.objectWillChange.send() }
    }
}
