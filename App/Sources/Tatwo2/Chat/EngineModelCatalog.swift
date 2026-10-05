import Foundation

/// Capabilities belong to the device running the engine, and to its executable identity.
enum EngineModelCatalog {
    struct Model: Codable, Sendable, Equatable {
        var model: String
        var displayName: String
        var efforts: [String]
        var defaultEffort: String
        var speeds: [String]
        var defaultSpeed: String
        var images: Bool
    }
    struct Catalog: Codable, Sendable, Equatable {
        var engine: String
        var identity: String
        var source: String
        var models: [Model]
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var devices: [String: [Catalog]] = [:]
        var rememberedNames: [String: [String: String]] = [:]
        var revisions: [String: UInt64] = [:]
    }
    private static let state = State()
    static func catalogs(deviceID: String = "local") -> [Catalog] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.devices[deviceID] ?? []
    }
    static func replace(_ catalogs: [Catalog], deviceID: String = "local") {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.devices[deviceID] != catalogs else { return }
        state.devices[deviceID] = catalogs
        state.revisions[deviceID, default: 0] &+= 1
        for catalog in catalogs {
            for model in catalog.models where !model.displayName.isEmpty {
                state.rememberedNames[deviceID, default: [:]][ChatProviderModelIdentity.lookupKey(model.model)] = model.displayName
            }
        }
    }
    static func revision(deviceID: String) -> UInt64 {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.revisions[deviceID, default: 0]
    }
    static func rememberedName(_ modelID: String, deviceID: String) -> String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.rememberedNames[deviceID]?[ChatProviderModelIdentity.lookupKey(modelID)]
    }
    @discardableResult static func receive(_ message: [String: Any], deviceID: String = "local") -> Bool {
        guard message["type"] as? String == "system", message["subtype"] as? String == "model_catalog",
              let data = try? JSONSerialization.data(withJSONObject: message),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              ["codex", "claude"].contains(catalog.engine), !catalog.models.isEmpty else { return false }
        var current = catalogs(deviceID: deviceID).filter { $0.engine != catalog.engine }
        current.append(catalog); replace(current, deviceID: deviceID)
        return true
    }
    static func wire() -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(catalogs()))) ?? []
    }
    nonisolated static func decode(_ value: Any?) -> [Catalog] {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
        return (try? JSONDecoder().decode([Catalog].self, from: data)) ?? []
    }
    static func profiles(deviceID: String = "local") -> [TatwoChatRouteProfile] {
        let catalogs = catalogs(deviceID: deviceID)
        var result: [TatwoChatRouteProfile] = []
        for fallback in TatwoChatRouteProfile.defaults {
            let kind = fallback.runtimeAdapter == .claudeCLI ? "claude" : fallback.runtimeAdapter == .codexExec ? "codex" : "other"
            guard let catalog = catalogs.first(where: { $0.engine == kind }) else {
                result.append(copy(fallback, capability: nil, source: "備援表 · Codex 0.160.0 / Agent SDK 0.3.280（尚未取得引擎回報）"))
                continue
            }
            if let model = catalog.models.first(where: { ChatProviderModelIdentity.lookupKey($0.model) == ChatProviderModelIdentity.lookupKey(fallback.modelArgument ?? fallback.id) }) {
                result.append(copy(fallback, capability: model, source: catalog.source + " · " + catalog.identity))
            }
        }
        for catalog in catalogs {
            for model in catalog.models where !result.contains(where: { $0.engine.rawValue == catalog.engine && $0.modelArgument == model.model }) {
                let base = TatwoChatRouteProfile(id: model.model, displayName: model.displayName, family: catalog.engine == "claude" ? "Claude native" : "Codex/GPT",
                    engine: catalog.engine == "claude" ? .claude : .codex, modelArgument: model.model,
                    contextWindowLabel: "引擎回報", supportsImageInput: model.images, pluginFit: "引擎支援", sessionRisk: "引擎回報",
                    defaultEffort: .low, allowedEfforts: [], notes: [])
                result.append(copy(base, capability: model, source: catalog.source + " · " + catalog.identity))
            }
        }
        return result
    }
    static func resolvedProfile(_ fallback: TatwoChatRouteProfile, deviceID: String) -> TatwoChatRouteProfile {
        if let actual = profiles(deviceID: deviceID).first(where: { $0.id == fallback.id }) { return actual }
        return TatwoChatRouteProfile(id: fallback.id, displayName: rememberedName(fallback.modelArgument ?? fallback.id, deviceID: deviceID) ?? fallback.displayName, family: fallback.family,
            engine: fallback.engine, runtimeAdapter: .unavailable, canonicalModelSlug: fallback.canonicalModelSlug,
            modelArgument: fallback.modelArgument, contextWindowLabel: "目前引擎不支援", supportsImageInput: false,
            pluginFit: "請換選單中的模型", sessionRisk: "blocked", defaultEffort: .low, allowedEfforts: [],
            notes: ["實際執行設備的模型清單未提供這個模型；請改選選單中的模型。"])
    }
    private static func copy(_ base: TatwoChatRouteProfile, capability: Model?, source: String) -> TatwoChatRouteProfile {
        let efforts = capability.map { $0.efforts.compactMap(TatwoCodexReasoningEffort.init(rawValue:)) } ?? base.allowedEfforts
        let speeds = capability.map { $0.speeds.compactMap(TatwoModelSpeedTier.init(rawValue:)) } ?? base.allowedSpeedTiers
        return TatwoChatRouteProfile(id: base.id, displayName: base.id == "codex-auto-review" ? base.displayName : capability?.displayName ?? base.displayName, family: base.family,
            engine: base.engine, runtimeAdapter: base.runtimeAdapter, canonicalModelSlug: base.canonicalModelSlug,
            modelArgument: capability?.model ?? base.modelArgument, contextWindowLabel: base.contextWindowLabel,
            supportsImageInput: capability?.images ?? base.supportsImageInput, pluginFit: base.pluginFit, sessionRisk: base.sessionRisk,
            defaultEffort: capability.flatMap { TatwoCodexReasoningEffort(rawValue: $0.defaultEffort) } ?? base.defaultEffort,
            allowedEfforts: efforts, defaultSpeedTier: capability.flatMap { TatwoModelSpeedTier(rawValue: $0.defaultSpeed) } ?? (capability == nil ? base.defaultSpeedTier : nil),
            allowedSpeedTiers: speeds, notes: [source] + base.notes)
    }
}
