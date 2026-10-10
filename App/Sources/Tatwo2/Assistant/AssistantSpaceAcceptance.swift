#if DEBUG
import Foundation

enum AssistantSpaceAcceptance {
    @MainActor static func run() async throws -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"] else {
            throw BotLibraryError.invalid("isolated TATWO2_LIVE_ROOT required")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // 只在 staging 隔離環境跑（不寫死任何機器的路徑；公開匯出也不帶私人路徑）。
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else {
            throw BotLibraryError.invalid("run inside an isolated staging environment")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("self-test requires a fresh directory")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // All optional readers/generators remain inside this test root, not the installed OS.
        for (key, suffix) in [
            "TATWO2_OS_ROOT": "os", "TATWO2_ENGINES_ROOT": "engines",
            "TATWO2_OS_UPSTREAM_PATH": "os/os-upstream.md",
            "TATWO2_DOCS_ROOT": "os", "TATWO2_CODEX_SOURCE_HOME": "engines/codex",
            "CODEX_HOME": "engines/codex", "CLAUDE_CONFIG_DIR": "engines/claude",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "engines/claude",
            "TATWO2_SKILLET_PATH": "os/skillet.md", "TATWO2_RESOURCES_ROOT": "resources",
            "HOME": "home", "CFFIXED_USER_HOME": "home", "TATWO_STAGING_SCRATCH_HOME": "home",
        ] { setenv(key, root.appendingPathComponent(suffix).path, 1) }
        let container = root.deletingLastPathComponent()
        setenv("TATWO_STAGING_ROOT", container.path, 1)
        // Short, unused socket paths keep the native staging validator happy even with a long test name.
        let socketID = String(UUID().uuidString.prefix(8))
        setenv("TATWO2_OS_SOCKET", container.appendingPathComponent("\(socketID)-os").path, 1)
        setenv("TATWO2_BROWSER_SOCKET", container.appendingPathComponent("\(socketID)-web").path, 1)
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.validationError(environment) == nil else {
            throw BotLibraryError.invalid("invalid isolated self-test environment")
        }
        try fm.createDirectory(at: root.appendingPathComponent("os"), withIntermediateDirectories: true)
        try Data("# Isolated self-test upstream\n".utf8)
            .write(to: root.appendingPathComponent("os/os-upstream.md"))
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W179SPACE \(condition ? "PASS" : "FAIL") \(label)")
        }

        let freshLibrary = BotLibrary(root: root.appendingPathComponent("new-space"),
                                      skillsRoot: root.appendingPathComponent("skills"))
        let freshController = SpaceWorkspaceController()
        await freshController.load(library: freshLibrary)
        check(ChatRunMode.allCases.first == .tatwo && freshController.visibleModes.first == .tatwo
              && SpaceDomainRecord(id: "new").tabOrder.first == .tatwo, "(a) fresh TATWO first")
        check(ChatRunMode(rawValue: "tatwo") == .tatwo && ChatRunMode.tatwo.displayName == "TATWO",
              "tatwo round-trip is builtin, not custom")

        // Real legacy space-workspaces.json, two domains with different custom orderings.
        let oldRoot = root.appendingPathComponent("old-space")
        let oldLibrary = BotLibrary(root: oldRoot, skillsRoot: root.appendingPathComponent("skills"))
        await oldLibrary.ready()
        let botStore = BotStore(library: oldLibrary)
        let domainNames = ["One", "Two"]
        let firstDomain = try await botStore.createSpace(name: domainNames[0], density: "comfortable", ownerBotID: nil)
        let secondDomain = try await botStore.createSpace(name: domainNames[1], density: "comfortable", ownerBotID: nil)
        let orders = [
            firstDomain.id: ["browser", "custom-work", "bot", "chatgpt", "cli", "chat"],
            secondDomain.id: ["cli", "chat", "custom-work", "bot"],
        ]
        let domains = orders.mapValues { order -> [String: Any] in
            ["tabOrder": order, "disabledTabs": ["browser"], "customTabs": ["custom-work": "Custom"]]
        }
        var legacyDomains = domains
        for id in orders.keys { legacyDomains[id]?["id"] = id }
        let legacy: [String: Any] = ["version": 1, "selectedDomainID": firstDomain.id, "domains": legacyDomains]
        let workspaceURL = oldRoot.appendingPathComponent("space-workspaces.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: workspaceURL)
        let reloadedLibrary = BotLibrary(root: oldRoot, skillsRoot: root.appendingPathComponent("skills"))
        let oldController = SpaceWorkspaceController()
        await oldController.load(library: reloadedLibrary)
        for (id, originalOrder) in orders {
            let expected = ["tatwo"] + originalOrder
                + ["chat", "cli", "bot", "browser", "chatgpt"].filter { !originalOrder.contains($0) }
            let saved = reloadedLibrary.snapshot.spaceWorkspace.domains[id]
            check(saved?.tabOrder.map(\.rawValue) == expected && saved?.disabledTabs == [.browser],
                  "(b) legacy \(id == firstDomain.id ? "first" : "second") domain preserves existing order")
            oldController.selectDomain(id)
            check(oldController.visibleModes.first == .tatwo
                  && oldController.visibleModes.contains(.custom("custom-work")),
                  "restored controller keeps TATWO and custom Space")
        }
        await oldController.flushWrites()
        let migrated = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: Data(contentsOf: workspaceURL))
        let roundTrip = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: JSONEncoder().encode(migrated))
        check(try roundTrip.validated() == migrated, "legacy migration round-trip is idempotent")

        let legacyChat = try JSONDecoder().decode(LiveDocumentRecord.self,
            from: Data(#"{"projects":[],"threads":[]}"#.utf8))
        check(legacyChat.assistantProjectID == nil, "old chat document decodes without assistant identity")
        let store = ChatLiveStore(root: root)
        let engine = ChatLiveEngine(store: store, environment: environment)
        let initialCoderID = engine.doc.selectedThreadID
        let project = engine.newProject(name: "Coder project", workdir: root.path)
        let coderID = engine.newThread(in: project, title: "Coder original")
        guard let assistantID = engine.doc.assistantThreadID,
              let assistantProjectID = engine.doc.assistantProjectID else {
            throw BotLibraryError.invalid("assistant identity missing")
        }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        check(model.mode == .chat, "startup remains Coder")
        check(model.assistantRouteChoice.id == ChatRouteChoice.resolve(
            UltraworkRoleConfigurationStore().load().primaryModelID).id,
              "new assistant follows user-configured default lead model")
        var document = engine.doc
        check(document.ensureAssistantThread() == assistantID && document == engine.doc,
              "(c) ensuring assistant twice changes nothing")
        engine.appendSystemMessage(threadID: assistantID, text: "Persistent assistant history", status: "info|test")
        engine.togglePinned(assistantID)
        model.document = engine.document
        for query in ["", "TATWO", "Persistent"] {
            model.searchText = query
            check(!model.filteredProjects.contains { $0.id == assistantProjectID }
                  && !model.pinnedThreadRefs.contains { $0.thread.id == assistantID }
                  && !model.sidebarStandaloneThreads.contains { $0.id == assistantID },
                  "(d) Coder projects/pinned/chats exclude assistant (query=\(query))")
        }
        model.searchText = ""
        check(model.filteredProjects.contains { $0.id == project }, "Coder project remains visible")

        // Exercise the real remote decoder/projection with a fake get_document response; no SSH.
        var remoteRecord = engine.doc
        remoteRecord.projects.sort { $0.id == assistantProjectID && $1.id != assistantProjectID }
        remoteRecord.selectedThreadID = assistantID
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601 // OSAgentBridge.jsonObject uses the same wire format.
        let wireDocument = try JSONSerialization.jsonObject(with: encoder.encode(remoteRecord))
        let remote = try RemoteLiveEngine(link: RemoteHostLink(environment: environment),
            store: ChatLiveStore(root: root.appendingPathComponent("remote-cache")),
            initial: ["document": wireDocument, "revision": 1, "runningThreadIDs": []])
        defer { remote.shutdownAll() }
        let remoteDocument = remote.document
        check((wireDocument as? [String: Any])?["assistantProjectID"] as? String == assistantProjectID.uuidString
              && remote.doc.assistantProjectID == assistantProjectID
              && remoteDocument.assistantProjectID == assistantProjectID,
              "(g) remote get_document JSON decoder and projection preserve assistant identity")
        check(remoteDocument.generalProjectID == nil, "remote generalProjectID behavior remains unchanged")
        model.document = remoteDocument
        for query in ["", "TATWO", "Persistent"] {
            model.searchText = query
            check(!model.filteredProjects.contains { $0.id == assistantProjectID }
                  && !model.pinnedThreadRefs.contains { $0.thread.id == assistantID }
                  && !model.sidebarStandaloneThreads.contains { $0.id == assistantID }
                  && !model.document.coderProjects.contains { $0.id == assistantProjectID },
                  "(g) remote Coder/CLI lists exclude assistant (query=\(query))")
        }
        model.searchText = ""
        for (name, projection) in [("local", engine.document), ("remote", remoteDocument)] {
            for preferred in [nil, assistantID, UUID(), coderID] as [UUID?] {
                let expected = preferred == coderID ? coderID : initialCoderID
                check(expected != nil && projection.coderThreadID(preferred: preferred) == expected,
                      "(h) \(name) fallback excludes assistant, including saved selection")
            }
            var assistantOnly = projection
            assistantOnly.projects = projection.projects.filter { $0.id == assistantProjectID }
            check(assistantOnly.coderThreadID(preferred: assistantID) == nil,
                  "(h) \(name) assistant-only document has no Coder fallback")
        }
        model.document = engine.document
        engine.select(assistantID) // Simulate an older document with an unsafe saved selection.
        model.selectLocalThread(nil)
        check(model.selectedThreadID == initialCoderID && engine.doc.selectedThreadID == initialCoderID,
              "(h) local fallback repairs saved assistant selection")
        model.select(projectID: project, threadID: coderID)
        model.mode = .chat
        model.select(projectID: assistantProjectID, threadID: assistantID)
        check(model.mode == .tatwo && model.selectedThreadID == coderID
              && engine.doc.selectedThreadID == coderID, "(i) select assistant id opens TATWO, preserves Coder")
        model.mode = .chat
        model.selectLocalThread(assistantID) // Same entry point as os.sock select_thread.
        check(model.mode == .tatwo && model.selectedThreadID == coderID
              && engine.doc.selectedThreadID == coderID, "(i) select_thread entry redirects assistant to TATWO")
        model.mode = .chat
        model.prompt = "Coder draft"
        model.assistantPrompt = "Assistant draft"
        let coderModel = model.selectedModel
        let coderPreferences = engine.threadRecord(coderID)
        model.mode = .tatwo
        check(model.assistantThreadID == assistantID && model.selectedThreadID == coderID
              && engine.doc.selectedThreadID == coderID, "(e) entering TATWO does not select assistant")
        model.setAssistantModel("gpt-6-astra")
        check(model.selectedModel == coderModel
              && engine.threadRecord(coderID)?.requestedModel == coderPreferences?.requestedModel
              && engine.threadRecord(coderID)?.requestedEffort == coderPreferences?.requestedEffort
              && engine.threadRecord(coderID)?.requestedSpeedTier == coderPreferences?.requestedSpeedTier,
              "assistant model preference does not alter Coder model")
        model.mode = .chat
        check(model.selectedThreadID == coderID && engine.doc.selectedThreadID == coderID
              && model.prompt == "Coder draft" && model.assistantPrompt == "Assistant draft",
              "(e) return to Coder preserves selection and both drafts")
        check(model.assistantRouteChoice.id == "gpt-6-astra", "assistant uses its saved model choice")

        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        check(reopened.doc.assistantProjectID == assistantProjectID && reopened.doc.assistantThreadID == assistantID
              && reopened.doc.projects.filter { $0.id == assistantProjectID }.count == 1
              && reopened.doc.threads.filter { $0.projectID == assistantProjectID }.count == 1
              && reopened.transcript(for: assistantID).last?.text == "Persistent assistant history",
              "(c) reopen preserves one assistant project/thread and history")
        check(reopened.doc.selectedThreadID == coderID, "reopen preserves Coder selection")
        let overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(overrides.merging(["tatwo2.sidecarPath.codex": FileManager.default.currentDirectoryPath + "/Engines/codex-sidecar/sidecar.mjs"]) { _, new in new }, forName: UserDefaults.argumentDomain)
        let previousLaunch = ClaudeSidecar.fixtureLaunch
        defer { reopened.shutdownAll(); ClaudeSidecar.fixtureLaunch = previousLaunch; UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain) }
        @MainActor func launchedPrompt(_ thread: UUID, persona: String? = nil) async throws -> String? {
            var arguments: [String] = []
            ClaudeSidecar.fixtureLaunch = { _, args, _, _ in arguments = args }
            check(reopened.fixtureStartSidecar(thread, engine: .codex, systemPrompt: persona), "(f) prompt captured through production launch")
            try await DeviceFleetEighthRoundAcceptance.waitForLaunch { !arguments.isEmpty }
            guard let index = arguments.firstIndex(of: "--system-prompt"), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let assistantPrompt = try await launchedPrompt(assistantID)
        let coderPrompt = try await launchedPrompt(coderID, persona: "Existing persona")
        check(OSUpstream.assistantPersona()?.hasPrefix("# TATWO 助理") == true
              && assistantPrompt?.contains("# TATWO 助理") == true, "(f) assistant prompt contains packaged persona")
        check(coderPrompt?.contains("# TATWO 助理") == false
              && coderPrompt == OSUpstream.compose(threadSystemPrompt: "Existing persona"),
              "(f) ordinary thread prompt unchanged")
        check(!model.sendToAssistant(text: " \n") && engine.transcript(for: coderID).isEmpty,
              "explicit-target send rejects empty input without touching Coder")
        model.seedSendLoginStatusForSelfTest(.init(kind: .codex, isLoggedIn: false, account: nil, detail: "synthetic logged out"), checkedAt: Date())
        model.sendAssistantDraft()
        check(model.assistantPrompt == "Assistant draft"
              && model.assistantMessages.last?.status == "error|登入"
              && engine.transcript(for: coderID).isEmpty && engine.doc.selectedThreadID == coderID,
              "logged-out send keeps assistant draft and routes error only to assistant")
        print("W179SPACE SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
