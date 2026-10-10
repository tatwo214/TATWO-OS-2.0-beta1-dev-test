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
        var defaultModel: String? = nil
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var devices: [String: [Catalog]] = [:]
        var rememberedNames: [String: [String: String]] = [:]
        var revisions: [String: UInt64] = [:]
    }
    private static let state = State()
    static func engineID(_ profile: TatwoChatRouteProfile) -> String { profile.family == "本機模型" ? "ollama" : profile.runtimeAdapter == .grokCLI ? "grok" : profile.engine.rawValue.lowercased() }
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
              ["codex", "claude", "grok"].contains(catalog.engine), !catalog.models.isEmpty else { return false }
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
    static func modelKey(_ id: String, engine: String, catalog: Catalog) -> String {
        let key = ChatProviderModelIdentity.lookupKey(id)
        if engine == "grok", let fallback = TatwoChatRouteProfile.defaults.first(where: { engineID($0) == engine && ChatProviderModelIdentity.lookupKey($0.id) == key }) {
            return ChatProviderModelIdentity.lookupKey(fallback.modelArgument ?? id)
        }
        guard engine == "claude" else { return key }
        let native = key.hasPrefix("claude") ? String(key.dropFirst(6)) : key
        if native == "default", let preferred = catalog.defaultModel, preferred != id {
            return modelKey(preferred, engine: engine, catalog: catalog)
        }
        if ["fable", "sonnet", "opus", "haiku"].contains(native) {
            let full = catalog.models.map { ChatProviderModelIdentity.lookupKey($0.model).replacingOccurrences(of: "^claude", with: "", options: .regularExpression) }
                .filter { $0.hasPrefix(native) && $0 != native }
            if Set(full).count == 1, let only = full.first { return only }
            if let fallback = TatwoChatRouteProfile.defaults.first(where: { $0.engine == .claude && $0.canonicalModelSlug.hasPrefix(native + "-") }) {
                return ChatProviderModelIdentity.lookupKey(fallback.canonicalModelSlug)
            }
        }
        return native
    }
    private static func named(_ model: Model, engine: String, catalog: Catalog) -> Model {
        guard engine == "claude" else { return model }
        var result = model
        let key = modelKey(model.model, engine: engine, catalog: catalog)
        let code = catalog.models.first { $0.model.contains("-") && modelKey($0.model, engine: engine, catalog: catalog) == key }?.model
            ?? TatwoChatRouteProfile.defaults.first { ChatProviderModelIdentity.lookupKey($0.canonicalModelSlug) == key }?.canonicalModelSlug ?? model.model
        let clean = code.replacingOccurrences(of: #"^claude-|-[0-9]{8}$|\[1m\]$"#, with: "", options: .regularExpression)
        if model.displayName.range(of: #"(?i)(fable|sonnet|opus|haiku)\s+[0-9]"#, options: .regularExpression) == nil,
           clean.range(of: #"^(fable|sonnet|opus|haiku)[-_.]?[0-9]+(?:[-_.][0-9]+)*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let series = clean.prefix(while: { $0.isLetter }), version = clean.dropFirst(series.count).trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
            result.displayName = series.capitalized + " " + version.replacingOccurrences(of: "[-_]", with: ".", options: .regularExpression)
        }
        return result
    }
    static func profiles(deviceID: String = "local") -> [TatwoChatRouteProfile] {
        let catalogs = catalogs(deviceID: deviceID)
        var result: [TatwoChatRouteProfile] = []
        for fallback in TatwoChatRouteProfile.defaults {
            let kind = engineID(fallback)
            guard let catalog = catalogs.first(where: { $0.engine == kind && (kind != "claude" || !$0.models.isEmpty) }) else {
                result.append(copy(fallback, capability: nil, source: "備援表 · Codex 0.160.0 / Agent SDK 0.3.280（尚未取得引擎回報）"))
                continue
            }
            if let model = catalog.models.first(where: { modelKey($0.model, engine: kind, catalog: catalog) == modelKey(fallback.modelArgument ?? fallback.id, engine: kind, catalog: catalog) }) {
                guard !result.contains(where: { engineID($0) == kind && modelKey($0.modelArgument ?? $0.id, engine: kind, catalog: catalog) == modelKey(model.model, engine: kind, catalog: catalog) }) else { continue }
                result.append(copy(fallback, capability: named(model, engine: kind, catalog: catalog), source: catalog.source + " · " + catalog.identity))
            }
        }
        for catalog in catalogs {
            for model in catalog.models where !result.contains(where: { engineID($0) == catalog.engine && modelKey($0.modelArgument ?? $0.id, engine: catalog.engine, catalog: catalog) == modelKey(model.model, engine: catalog.engine, catalog: catalog) }) {
                if catalog.engine != "claude", catalogs.contains(where: { $0.engine == "claude" && !$0.models.isEmpty }),
                   [model.model, model.displayName].contains(where: { $0.range(of: "^(claude|fable|haiku|sonnet|opus)", options: [.regularExpression, .caseInsensitive]) != nil }) { continue }
                let base = TatwoChatRouteProfile(id: model.model, displayName: model.displayName, family: catalog.engine == "ollama" ? "本機模型" : catalog.engine == "claude" ? "Claude native" : "Codex/GPT",
                    engine: TatwoNativeChatEngine(rawValue: catalog.engine.capitalized) ?? .codex, runtimeAdapter: catalog.engine == "ollama" ? .unavailable : catalog.engine == "grok" ? .grokCLI : nil, modelArgument: model.model,
                    contextWindowLabel: "引擎回報", supportsImageInput: model.images, pluginFit: "引擎支援", sessionRisk: "引擎回報",
                    defaultEffort: .low, allowedEfforts: [], notes: [])
                result.append(copy(base, capability: named(model, engine: catalog.engine, catalog: catalog), source: catalog.source + " · " + catalog.identity))
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
