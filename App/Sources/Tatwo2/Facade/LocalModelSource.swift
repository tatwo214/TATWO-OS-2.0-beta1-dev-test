import Foundation

enum LocalModelSource {
    enum Engine { case ollama, mlx }
    typealias Source = () async -> (String, EngineModelCatalog.Catalog?)
    private struct Tags: Decodable { let models: [Tag]; struct Tag: Decodable { let name: String } }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func installed(paths: [String]? = nil) -> Bool {
        if paths == nil && NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) { return false }
        let candidates = paths ?? ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/ollama" }
        return candidates.contains { $0.hasSuffix(".app") ? FileManager.default.fileExists(atPath: $0) : FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read(_ engine: Engine = .ollama, session: URLSession? = nil) async -> (String, EngineModelCatalog.Catalog?) {
        guard engine == .ollama else { return ("MLX 尚未接入", nil) }
        guard session != nil || !NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else { return ("本機模型服務沒開", nil) }
        let client = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { if session == nil { client.invalidateAndCancel() } }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (data, response) = try? await client.data(for: request) else { return ("本機模型服務沒開", nil) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data), tags.models.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return ("本機模型清單查不到", nil) }
        let models = tags.models.map { EngineModelCatalog.Model(model: $0.name, displayName: $0.name, efforts: [], defaultEffort: "", speeds: [], defaultSpeed: "", images: false) }
        return ("只同步清單", .init(engine: "ollama", identity: "127.0.0.1:11434", source: "Ollama /api/tags", models: models))
    }
}
