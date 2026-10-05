import Foundation

#if DEBUG
enum UndeliveredFlowAcceptance {
    @MainActor static func run(root: URL, env: [String: String], check: (String, Bool) -> Void) {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let a = engine.newThread(in: nil), b = engine.newThread(in: nil), idle = engine.newThread(in: nil)
        let pathA = root.appendingPathComponent("fixture.txt").path
        let pathB = root.appendingPathComponent("sample.txt").path
        let tokenA = model.beginCoderDeliveryForSelfTest(a, text: "fixture-a", attachments: [pathA], deviceID: nil)
        let tokenB = model.beginCoderDeliveryForSelfTest(b, text: "fixture-b", attachments: [pathB], deviceID: nil)
        model.selectedThreadID = idle; model.prompt = "draft"
        model.finishCoderDeliveryForSelfTest(a, token: tokenA)
        model.finishCoderDeliveryForSelfTest(b, token: tokenB)
        for (id, text, path) in [(a, "fixture-a", pathA), (b, "fixture-b", pathB)] {
            model.selectedThreadID = id
            model.prompt = "draft"; model.droppedPaths = []; model.droppedPathDisplayNames = [:]
            check("F2 separate local notice \(text)", model.coderUndeliveredNotice == "上一句沒送到：" + text)
            model.restoreUndeliveredDraft()
            check("F2 separate local draft and attachment \(text)", model.prompt == text + "\ndraft" && model.droppedPaths == [path])
            check("F2 restored attachment name \(text)", model.droppedPathDisplayNames[path] == (path as NSString).lastPathComponent)
        }
        let shared = engine.newThread(in: nil)
        let remoteA = model.beginCoderDeliveryForSelfTest(shared, text: "example-a", attachments: [pathA], deviceID: "fixture-a")
        let remoteB = model.beginCoderDeliveryForSelfTest(shared, text: "example-b", attachments: [pathB], deviceID: "fixture-b")
        model.selectedRemote = nil; model.selectedThreadID = idle; model.prompt = "draft"; model.droppedPaths = []
        model.finishCoderDeliveryForSelfTest(shared, token: remoteA)
        model.finishCoderDeliveryForSelfTest(shared, token: remoteB)
        for (device, text, path) in [("fixture-a", "example-a", pathA), ("fixture-b", "example-b", pathB)] {
            model.selectedRemote = (device, shared)
            // Coder's local selection need not equal the remote thread ID.
            model.selectedThreadID = idle
            model.prompt = "draft"; model.droppedPaths = []; model.droppedPathDisplayNames = [:]
            check("F2 separate device notice \(device)", model.coderUndeliveredNotice == "上一句沒送到：" + text)
            model.restoreUndeliveredDraft()
            check("F2 separate device draft and attachment \(device)", model.prompt == text + "\ndraft" && model.droppedPaths == [path])
        }
        model.selectedRemote = nil; model.selectedThreadID = idle
        check("F2 unrelated thread has no recovery notice", model.coderUndeliveredNotice == nil)
    }
}
#endif
