import Foundation

@MainActor final class EngineModelCatalogProbe {
    static let shared = EngineModelCatalogProbe()
    private var probes: [ClaudeSidecar.Kind: ClaudeSidecar] = [:]
    func read(_ kind: ClaudeSidecar.Kind, executable: URL? = nil) async -> EngineModelCatalog.Catalog? {
        let sidecar = ClaudeSidecar(kind: kind)
        var result: EngineModelCatalog.Catalog?
        var ended = false
        sidecar.onEvent = { event in
            if case .sdk(let message) = event { result = EngineModelCatalog.decode([message]).first; if result != nil { ended = true } }
            if case .closed = event { ended = true }
            if case .error = event { ended = true }
        }
        defer { sidecar.onEvent = nil; sidecar.close() }
        do { try sidecar.start(cwd: ClaudeSidecar.engineHomeRoot().path, resume: nil, model: nil, catalogOnly: true, runtimeOverride: executable.map { .init(executable: $0, version: nil, source: "本機", reason: nil) }) } catch { return nil }
        for _ in 0..<200 { if ended || Task.isCancelled { break }; try? await Task.sleep(for: .milliseconds(100)) }
        return result
    }
    func refresh(force: Bool = false, onChange: @escaping () -> Void) {
        guard !NativeStagingIsolation.isEnabled(ProcessInfo.processInfo.environment) else { return }
        if force {
            for sidecar in probes.values { sidecar.onRuntimeSelection = nil; sidecar.onEvent = nil; sidecar.close() }
            probes.removeAll()
        }
        for kind in [ClaudeSidecar.Kind.codex, .claude] where probes[kind] == nil {
            let sidecar = ClaudeSidecar(kind: kind)
            probes[kind] = sidecar
            sidecar.onRuntimeSelection = onChange
            sidecar.onEvent = { [weak self, weak sidecar] event in
                switch event {
                case .sdk(let message):
                    if EngineModelCatalog.receive(message) { onChange() }
                case .closed, .error:
                    sidecar?.onRuntimeSelection = nil
                    sidecar?.onEvent = nil
                    self?.probes.removeValue(forKey: kind)
                default: break
                }
            }
            do { try sidecar.start(cwd: ClaudeSidecar.engineHomeRoot().path, resume: nil, model: nil, catalogOnly: true) }
            catch { sidecar.onRuntimeSelection = nil; sidecar.onEvent = nil; probes.removeValue(forKey: kind) }
            Task { [weak self, weak sidecar] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, let sidecar, self.probes[kind] === sidecar else { return }
                sidecar.onRuntimeSelection = nil; sidecar.onEvent = nil; sidecar.close(); self.probes.removeValue(forKey: kind)
            }
        }
    }
}
