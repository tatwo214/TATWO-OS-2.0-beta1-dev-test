import Foundation

/// The registry binds a TAP code to its transport; the engine only sees participants.
@MainActor struct GroupTapAdapter {
    let id: String
    var unavailable: () -> String? = { nil }
    let invoke: (UUID, String, @escaping (Result<String, Error>) -> Void) -> Void
    let stop: (UUID) -> Void
    func participant(_ thread: UUID) -> GroupParticipant {
        GroupParticipant(id: id, join: true, unavailable: unavailable, invoke: { text, done in invoke(thread, text, done) }, stop: { stop(thread) })
    }
}

/// Check at the synchronous transport boundary, after every readiness/model/mapping await.
@MainActor class GroupGuardedTap: ConversationTap {
    let tap: any ConversationTap; let rejection: () -> String?
    init(tap: any ConversationTap, rejection: @escaping () -> String? = { nil }) { self.tap = tap; self.rejection = rejection }
    var tapID: String { tap.tapID }
    var displayName: String { tap.displayName }
    var connection: TapConnection { tap.connection }
    func conversations(offset: Int, limit: Int) async throws -> (items: [TapConversation], total: Int) { try await tap.conversations(offset: offset, limit: limit) }
    func messages(conversationID: String) async throws -> [TapMessage] { try await tap.messages(conversationID: conversationID) }
    func thread(conversationID: String, branch: String?) async throws -> TapThread { try await tap.thread(conversationID: conversationID, branch: branch) }
    func models() async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?) {
        if let reason = rejection() { throw TapError.remote(reason) }
        let catalog = try await tap.models()
        if let reason = rejection() { throw TapError.remote(reason) }
        return catalog
    }
    func pinned() async throws -> [TapFolder] { try await tap.pinned() }
    func projects() async throws -> [TapFolder] {
        if let reason = rejection() { throw TapError.remote(reason) }
        let folders = try await tap.projects()
        if let reason = rejection() { throw TapError.remote(reason) }
        return folders
    }
    func createProject(name: String, description: String) async throws -> TapFolder {
        if let reason = rejection() { throw TapError.remote(reason) }
        let folder = try await tap.createProject(name: name, description: description)
        if let reason = rejection() { throw TapError.remote(reason) }
        return folder
    }
    func projectDetails(projectID: String) async throws -> TapFolder { try await tap.projectDetails(projectID: projectID) }
    func conversations(inProject projectID: String) async throws -> [TapConversation] { try await tap.conversations(inProject: projectID) }
    func send(text: String, conversationID: String?, model: String?, effort: String?, attachments: [TapAttachment], tool: String?, gizmoID: String?, temporary: Bool, parentID: String?) -> AsyncStream<TapStreamEvent> { if let reason = rejection() { return AsyncStream { $0.yield(.notSubmitted(reason)); $0.finish() } }; let send = { self.tap.send(text: text, conversationID: conversationID, model: model, effort: effort, attachments: attachments, tool: tool, gizmoID: gizmoID, temporary: temporary, parentID: parentID) }
        if let chatGPT = tap as? ChatGPTTap { return chatGPT.withQueuedSendRejection(rejection, send) }
        return send() }
    func tools() async throws -> [TapTool] { try await tap.tools() }
    func home() async throws -> (greeting: String?, suggestions: [TapSuggestion]) { try await tap.home() }
    func gpts() async throws -> [TapFolder] { try await tap.gpts() }
    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool) -> AsyncStream<TapStreamEvent> { tap.regenerate(conversationID: conversationID, model: model, effort: effort, temporary: temporary) }
    func rename(conversationID: String, title: String) async throws { try await tap.rename(conversationID: conversationID, title: title) }
    func feedback(conversationID: String, messageID: String, good: Bool) async throws { try await tap.feedback(conversationID: conversationID, messageID: messageID, good: good) }
    func setPinned(conversationID: String, pinned: Bool) async throws { try await tap.setPinned(conversationID: conversationID, pinned: pinned) }
    func branch(conversationID: String) async throws -> String? { try await tap.branch(conversationID: conversationID) }
    func archive(conversationID: String) async throws { try await tap.archive(conversationID: conversationID) }
    func delete(conversationID: String) async throws { try await tap.delete(conversationID: conversationID) }
    func search(query: String) async throws -> [TapConversation] { try await tap.search(query: query) }
    func imageData(pointer: String, conversationID: String?) async throws -> Data { try await tap.imageData(pointer: pointer, conversationID: conversationID) }
    func library(tab: TapLibraryTab, query: String, cursor: String?) async throws -> (items: [TapLibraryItem], cursor: String?) { try await tap.library(tab: tab, query: query, cursor: cursor) }
    func libraryData(itemID: String, full: Bool) async throws -> Data { try await tap.libraryData(itemID: itemID, full: full) }
    func stop() { tap.stop() }
    func stop(requestID: String) { tap.stop(requestID: requestID) }
}
