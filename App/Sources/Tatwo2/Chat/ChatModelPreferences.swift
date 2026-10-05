import Foundation

enum ChatModelPreferences {
    struct Selection {
        var route: ChatRouteChoice
        var effort: String
        var speed: TatwoModelSpeedTier
    }
    static func selection(_ thread: LiveThreadRecord?, overrideRouteID: String? = nil, deviceID: String = "local") -> Selection {
        let route = ChatRouteChoice.resolve(overrideRouteID ?? thread?.requestedModel ?? thread?.model ?? "gpt-6.1-sol", deviceID: deviceID)
        let effort = thread?.requestedEffort ?? (route.runtimeAdapter == .chatgptTap
            ? route.tapModel.flatMap(ChatGPTTapModelCatalog.defaultEffort) ?? ""
            : (route.id == "gpt-6.1-sol" ? TatwoCodexReasoningEffort.medium : route.defaultEffort).rawValue)
        return Selection(route: route, effort: effort,
            speed: thread?.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:)) ?? route.defaultSpeedTier ?? .fast)
    }
    /// A route can share a provider model with another route (Auto Review).
    /// Keep the user's route identity when its provider argument is unchanged.
    static func requestedRouteID(providerModel: String, previous: String?) -> String {
        if let previous, let route = ChatRouteChoice.resolveOrNil(previous),
           route.modelArgument == providerModel || route.id == providerModel {
            return route.id
        }
        return ChatRouteChoice.resolve(providerModel).id
    }
}
