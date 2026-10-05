import Foundation

#if DEBUG
enum LoginFlowAcceptance {
    @MainActor static func run(root: URL, env: [String: String], check: (String, Bool) -> Void) {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        check("send-01 unknown login permits engine verification", model.sendLoginStatusForSelfTest(.claude).isLoggedIn)
        let positive = EngineLoginStatus(kind: .claude, isLoggedIn: true, account: nil, detail: "fixture")
        let negative = EngineLoginStatus(kind: .claude, isLoggedIn: false, account: nil, detail: "fixture")
        model.seedSendLoginStatusForSelfTest(positive, checkedAt: Date())
        check("send-01 recent background login reused", model.sendLoginStatusForSelfTest(.claude) == positive)
        model.seedSendLoginStatusForSelfTest(negative, checkedAt: Date())
        check("send-01 recent logged-out result keeps draft gated", !model.sendLoginStatusForSelfTest(.claude).isLoggedIn)
        model.seedSendLoginStatusForSelfTest(negative, checkedAt: Date().addingTimeInterval(-120))
        check("send-01 expired result permits engine verification", model.sendLoginStatusForSelfTest(.claude).isLoggedIn)
    }
}
#endif
