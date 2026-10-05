import Foundation

extension TatwoNativeChatStoreDocument {
    /// Coder and CLI keep general projects, but never expose the assistant's home.
    var coderProjects: [TatwoNativeChatProject] {
        projects.filter { $0.id != assistantProjectID }
    }

    /// A saved selection can also point at the assistant (or a removed thread).
    func coderThreadID(preferred: UUID?) -> UUID? {
        let threads = coderProjects.lazy.flatMap(\.threads)
        if let preferred, threads.contains(where: { $0.id == preferred }) { return preferred }
        return threads.first?.id
    }
}

extension LiveDocumentRecord {
    func isAssistantThread(_ threadID: UUID) -> Bool {
        guard let assistantProjectID else { return false }
        return threads.contains { $0.id == threadID && $0.projectID == assistantProjectID }
    }
}
