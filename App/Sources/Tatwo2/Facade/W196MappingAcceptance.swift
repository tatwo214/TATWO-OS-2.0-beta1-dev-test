#if DEBUG
import AppKit
import SwiftUI
import Darwin

@MainActor enum W196MappingAcceptance {
    private final class IdlePod: FakeTapPod {
        var gets: [String] = []
        var listItems: [[String: Any]] = []
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            switch command["cmd"] as? String {
            case "get":
                gets.append(command["conversationID"] as? String ?? "")
                emit(["type": "result", "id": id, "ok": true,
                      "data": ["messages": [["id": "fixture-answer", "role": "assistant", "text": "Mapped fixture answer"]]]])
            case "list":
                // .056 合併：W199 在網頁就緒時重讀清單（拿背景租約）；真網頁會回，假網頁也回一份空清單。
                emit(["type": "result", "id": id, "ok": true, "data": ["items": listItems, "total": listItems.count]])
            default:
                // 釘選、專案、模型等其他清單：真網頁也會回；這裡立刻回「不支援」，呼叫端照原本的 try? 略過。
                emit(["type": "result", "id": id, "ok": false, "message": "fixture: unsupported"])
            }
        }

    }

    static func run(_ parentCheck: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let liveRoot = env["TATWO2_LIVE_ROOT"], let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw TapError.remote("W196 requires isolated staging and artifacts")
        }
        func check(_ value: Bool, _ name: String) { parentCheck(value, "W196 " + name) }
        let root = URL(fileURLWithPath: liveRoot).appendingPathComponent("w196")
        let projectFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let tap = W185FakeConversationTap()
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "Mapping fixture", workdir: projectFolder.path)
        let thread = engine.newThread(in: project, title: "Mapping thread")
        let unmapped = engine.newThread(in: project, title: "Unmapped thread")
        let standalone = engine.newThread(in: nil, title: "Inbox thread")
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        model.mode = .chat
        model.selectedThreadID = thread
        engine.onChange = { model.document = engine.document }
        let displayPod = IdlePod()
        let space = ChatGPTSpaceModel(testTap: ChatGPTTap(transport: displayPod))
        let mapping = TapProjectMapper(tap: tap, inboxFolder: store.url.deletingLastPathComponent().appendingPathComponent("tap-inbox"))
        let context = TapProjectContext(id: project, name: "Mapping fixture", folder: projectFolder)
        let destination = try await mapping.destination(project: context, threadID: thread)
        try await mapping.record("w196-conversation", threadID: thread, destination: destination)
        tap.seedConversation("w196-conversation", in: destination.map.chatgpt_project_id)
        let mapFile = TapProjectMapStore.mapFile(at: projectFolder)
        let originalMap = try Data(contentsOf: mapFile)
        check(HandsTapMap.name(workdir: projectFolder.path) == context.tapName,
              "W299 F2-13 project card reads current TATWO map")
        let object = try JSONSerialization.jsonObject(with: originalMap) as? [String: Any]
        check(Set(object?.keys.map { $0 } ?? []) == Set(["chatgpt_project_id", "name", "threads", "updated_at"]),
              "C2 existing four-field storage format retained")
        space.select("w196-conversation")
        let forward = await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0).resolve()
        let reverse = await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .chatGPT, revision: 0).resolve()
        check(forward == reverse && forward?.threadID == thread && forward?.osProject == context.name,
              "C4 same stored IDs resolve both directions")
        model.selectedThreadID = unmapped
        check(await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0).resolve() == nil,
              "C4 unmapped OS thread resolves nothing")
        space.select("unmapped-conversation")
        check(await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .chatGPT, revision: 0).resolve() == nil,
              "C4 unrelated ChatGPT conversation resolves nothing")
        model.selectedThreadID = thread
        model.selectedRemote = ("fixture-device", thread)
        check(await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0).resolve() == nil,
              "C4 remote selection cannot reuse a local thread mapping")
        model.selectedRemote = nil

        let wakingPod = IdlePod()
        let wakingTap = ChatGPTTap(transport: wakingPod, connection: .sleeping)
        let wakingSpace = ChatGPTSpaceModel(testTap: wakingTap)
        wakingSpace.openMappedConversation("w196-conversation")
        for _ in 0..<50 where wakingPod.starts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        check(wakingPod.starts == 1 && wakingTap.hasActiveUsers && wakingPod.gets.isEmpty && wakingSpace.failure == nil,
              "C4 mapped navigation wakes sleeping TAP before requesting messages, without flashing a read failure")
        wakingPod.emit(["type": "hello", "loggedIn": true])
        for _ in 0..<50 where wakingSpace.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        check(wakingSpace.selectedID == "w196-conversation" && wakingPod.gets == ["w196-conversation"]
              && wakingSpace.messages.last?.text == "Mapped fixture answer" && !wakingTap.hasActiveUsers,
              "C4 mapped navigation loads the correct saved messages after readiness and releases its lease")
        wakingTap.sleep()

        let inbox = try await mapping.destination(project: nil, threadID: standalone)
        try await mapping.record("w196-inbox", threadID: standalone, destination: inbox)
        model.selectedThreadID = standalone
        space.select("w196-inbox")
        let inboxLink = await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .coder, revision: 0).resolve()
        check(inboxLink?.chatGPTProject == "TATWO · 收件匣" && inboxLink?.osProject == "無專案",
              "C2 standalone thread maps through the actual inbox location")
        check(await ChatGPTSessionMappingRequest(pageModel: model, spaceModel: space, side: .chatGPT, revision: 0).resolve() == inboxLink,
              "C4 inbox mapping reverses to the standalone OS thread")
        let outgoing = ChatGPTTapTurnRunner.outgoing(text: "fixture", project: nil, first: true, history: [])
        check(!outgoing.contains("project_id=") && !outgoing.contains("000000000185") && outgoing.contains("未分類"),
              "C3 inbox preamble never invents an authorized OS project ID")

        // 舊表畫面讀取不能遷移、改寫；壞表或連結不能冒出可點的對應。
        let legacyFolder = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyFolder.appendingPathComponent(".tatwo"), withIntermediateDirectories: true)
        let legacyFile = legacyFolder.appendingPathComponent(".tatwo/tap-map.json")
        try HandsFiles.writeAtomically(originalMap, to: legacyFile)
        let legacyMap = TapProjectMapStore.displayMap(at: legacyFolder)
        let legacyAfter = try Data(contentsOf: legacyFile)
        check(legacyMap?.threads[thread.uuidString] == "w196-conversation" && legacyAfter == originalMap
              && !FileManager.default.fileExists(atPath: TapProjectMapStore.mapFile(at: legacyFolder).path),
              "C4 legacy map display is read-only and preserves old bytes")
        let brokenCurrent = TapProjectMapStore.mapFile(at: legacyFolder)
        try FileManager.default.createDirectory(at: brokenCurrent.deletingLastPathComponent(), withIntermediateDirectories: true)
        var preferred = destination.map
        preferred.name = "TATWO · Current"
        let preferredBytes = try JSONEncoder().encode(preferred)
        try HandsFiles.writeAtomically(preferredBytes, to: brokenCurrent)
        let displayed = HandsTapMap.name(workdir: legacyFolder.path)
        let currentAfter = try Data(contentsOf: brokenCurrent), oldAfter = try Data(contentsOf: legacyFile)
        check(displayed == preferred.name && currentAfter == preferredBytes && oldAfter == originalMap,
              "W299 F2-13 project card prefers current map without rewriting either path")
        try Data("invalid".utf8).write(to: brokenCurrent)
        check(TapProjectMapStore.displayMap(at: legacyFolder)?.threads[thread.uuidString] == "w196-conversation"
              && HandsTapMap.name(workdir: legacyFolder.path) == legacyMap?.name,
              "W207 both mapping rows fall back from a broken current map to the same safe legacy map")
        var badName = try JSONDecoder().decode(TapProjectMap.self, from: originalMap)
        badName.name = "Unexpected title"
        try JSONEncoder().encode(badName).write(to: legacyFile)
        check(TapProjectMapStore.displayMap(at: legacyFolder) == nil && HandsTapMap.name(workdir: legacyFolder.path) == nil,
              "W207 both mapping rows reject a map without the expected name prefix")
        try originalMap.write(to: legacyFile)
        let linkedFolder = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: legacyFolder)
        check(TapProjectMapStore.displayMap(at: linkedFolder) == nil, "privacy map display refuses symlink folders")
        let malformedFolder = root.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: malformedFolder.appendingPathComponent(".tatwo"), withIntermediateDirectories: true)
        try HandsFiles.writeAtomically(Data("invalid".utf8), to: malformedFolder.appendingPathComponent(".tatwo/tap-map.json"))
        check(TapProjectMapStore.displayMap(at: malformedFolder) == nil, "C4 malformed map is hidden")

        model.selectedThreadID = thread
        space.select("w196-conversation")
        let journal = HandsRoomJournal(url: root.appendingPathComponent("room.json"))
        try journal.append(HandsRoomCall(id: UUID(), at: Date(), projectID: project, grantTag: "fixture", tool: "list_projects",
                                        summary: "1 個專案", workspaceID: nil, approval: nil))
        let artifactRoot = URL(fileURLWithPath: artifacts)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let theme = TatwoThemeSelfTestScope()
        let originalAppearance = NSApp.appearance
        theme.use(.aurora)
        defer { theme.restore(); NSApp.appearance = originalAppearance }
        for scheme in [ColorScheme.light, .dark] {
            NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            let coderProbe = ChatGPTSessionMappingRow.Probe(), spaceProbe = ChatGPTSessionMappingRow.Probe()
            var coderRow = ChatGPTSessionMappingRow(pageModel: model, spaceModel: space, side: .coder, displayTap: tap)
            var spaceRow = ChatGPTSessionMappingRow(pageModel: model, spaceModel: space, side: .chatGPT, displayTap: tap)
            coderRow.testProbe = coderProbe
            spaceRow.testProbe = spaceProbe
            var source: String?
            var room = ChatGPTRoomRow(projectID: project, workdir: projectFolder.path, openThread: { _ in }, roomJournal: journal)
                .sourceProject(context.name)
            room.testSource = { source = $0 }
            let view = VStack(alignment: .leading, spacing: 20) {
                Text("Coder").font(.headline).padding(.horizontal, 24)
                coderRow
                Text("ChatGPT Space").font(.headline).padding(.horizontal, 24)
                spaceRow
                room.padding(.horizontal, 24)
                Spacer(minLength: 0)
            }.padding(.vertical, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let rig = TatwoComposerModeAcceptance.ClickRig(view, size: CGSize(width: 780, height: 320))
            rig.window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            await rig.settle(30)
            check(coderProbe.link == forward && coderProbe.label == "ChatGPT：TATWO · Mapping fixture › fixture"
                  && spaceProbe.link == reverse && spaceProbe.label == "OS：Mapping fixture › Mapping thread",
                  "C4 actual rows display both project and thread in \(scheme)")
            displayPod.listItems = [["id": "w196-conversation", "title": "Updated conversation"]]
            await space.reloadConversationList(); await rig.settle(12)
            check(coderProbe.label == "ChatGPT：TATWO · Mapping fixture › Updated conversation",
                  "W207 direct title lookup follows a changed directory result")
            displayPod.listItems = []
            await space.reloadConversationList(); await rig.settle(12)
            check(coderProbe.label == "ChatGPT：TATWO · Mapping fixture › fixture",
                  "W207 removed directory title falls back to the fetched title without stale cache")
            check(source == context.name, "C3 actual ChatGPT room row displays source project in \(scheme)")
            if scheme == .dark {
                check(rig.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                      && rig.capture().map { TatwoThemeSelfTestScope.hasReadableDarkPixels($0.bitmap) } == true,
                      "C4 dark evidence uses native dark appearance and readable glass theme")
            }
            try shot(rig, to: artifactRoot.appendingPathComponent("w196-mapping-\(scheme).png"))
            model.mode = .chat
            space.select("unmapped-conversation")
            await rig.settle(12)
            if let button = coderProbe.button {
                await rig.click(rig.host.convert(NSPoint(x: button.midX, y: button.midY), to: nil))
            }
            check(model.mode == .chatgpt && space.selectedID == "w196-conversation" && space.messages.last?.text == "Mapped fixture answer",
                  "C4 native click opens the mapped ChatGPT conversation in \(scheme)")
            model.selectedThreadID = unmapped
            await rig.settle(12)
            if let button = spaceProbe.button {
                await rig.click(rig.host.convert(NSPoint(x: button.midX, y: button.midY), to: nil))
            }
            check(model.mode == .chat && model.selectedThreadID == thread && engine.doc.selectedThreadID == thread,
                  "C4 native click opens the mapped OS thread in \(scheme)")
            model.selectedThreadID = unmapped
            space.select("unmapped-conversation")
            await rig.settle(12)
            check(coderProbe.link == nil && spaceProbe.link == nil && coderProbe.button == nil && spaceProbe.button == nil,
                  "C4 switching to unmapped conversations hides both actual rows in \(scheme)")
            try shot(rig, to: artifactRoot.appendingPathComponent("w196-unmapped-\(scheme).png"))
            model.selectedThreadID = thread
            space.select("w196-conversation")
            rig.close()
        }
        check(try Data(contentsOf: mapFile) == originalMap, "C4 display and navigation leave stored map bytes unchanged")
        let summary = HandsTools.summarize(arguments: ["title": "PRIVATE_TITLE_CANARY", "project_id": project.uuidString],
                                          tool: "open_workspace", redact: { $0 })
        check(!summary.contains("PRIVATE_TITLE_CANARY"), "privacy tool argument audit omits titles")
    }

    private static func shot(_ rig: TatwoComposerModeAcceptance.ClickRig, to url: URL) throws {
        guard let png = rig.capture()?.bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw TapError.remote("W196 screenshot failed")
        }
        try png.write(to: url)
    }
}
#endif
