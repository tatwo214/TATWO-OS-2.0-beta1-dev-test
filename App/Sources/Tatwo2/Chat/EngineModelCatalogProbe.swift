import Foundation

@MainActor final class EngineModelCatalogProbe {
    static let shared = EngineModelCatalogProbe()
    private var probes: [ClaudeSidecar.Kind: ClaudeSidecar] = [:]
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
