#if DEBUG
import Foundation

/// `TATWO2_SELFTEST=w179remote`：助理與私訊框在副設備上走主設備。無頭驗收，只在完整隔離的 staging 環境跑；
/// 主設備用記憶體裡的最小替身（不連 SSH），本機引擎資料夾必須是未登入（不燒額度）。
/// 停用設定只改這個 model 的記憶體狀態，不寫使用者的停用設定。
enum AssistantRemoteAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w179remote needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w179remote requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        let disableKey = "tatwo2.disabledEngines"
        let disableBefore = UserDefaults.standard.stringArray(forKey: disableKey)

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W179REMOTE \(condition ? "PASS" : "FAIL") \(label)")
        }

        // 本機：一條 Coder 串 A（Coder 選著、輸入框有草稿）＋本機助理那條。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "Local project", workdir: root.path)
        let threadA = engine.newThread(in: project, title: "A 串")
        guard let localAssistant = engine.doc.assistantThreadID else {
            throw BotLibraryError.invalid("local assistant identity missing")
        }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        model.select(projectID: project, threadID: threadA)
        model.prompt = "Coder 草稿"
        model.disabledEngines = []   // 只改這個 model 的記憶體狀態，不讀寫使用者的停用設定
        let everyEngine: Set<String> = [ClaudeSidecar.Kind.claude.rawValue, ClaudeSidecar.Kind.codex.rawValue,
                                        ClaudeSidecar.Kind.grok.rawValue]

        // (1) 主設備／單機行為不變：沒有主設備時接本機那條。
        check(!model.assistantPlacement.isPrimary && model.assistantPlacementNote == nil
              && model.assistantPrimaryDevice == nil, "(1) standalone keeps the local assistant")

        // (2) 預設模型跳過停用的引擎：助理存的選擇 → 主導 → Coder 輸入框 → 第一個沒停用的。
        let lead = UltraworkRoleConfigurationStore().load().primaryModelID
        let leadRoute = ChatRouteChoice.resolve(lead)
        let leadKind = AssistantModelRouting.engineKind(for: leadRoute)
        check(leadKind != nil && model.assistantRouteChoice.id == leadRoute.id, "(2) no engine disabled: lead model")
        if let leadKind, let other = ChatRouteChoice.all.first(where: {
            AssistantModelRouting.engineKind(for: $0).map { $0 != leadKind } ?? false }) {
            model.selectedModel = other.id
            model.disabledEngines = [leadKind.rawValue]
            check(model.assistantRouteChoice.id == other.id, "(2) lead engine disabled: falls to the Coder model")
            check(model.assistantModelOptions.contains { $0.route.id == leadRoute.id && $0.isDisabled && $0.title == AssistantModelRouting.friendlyName(leadRoute) + " · 已停用 · 未登入" }
                  && model.assistantModelOptions.contains { $0.route.id == other.id && !$0.isDisabled },
                  "(2) menu marks the disabled engine and keeps the others selectable")
            model.setAssistantModel(leadRoute.id)
            check(engine.threadRecord(localAssistant)?.requestedModel == nil, "(2) a disabled engine cannot be picked")
            model.disabledEngines = []
        } else {
            check(false, "(2) fixture routes")
        }
        let routeFor: (ClaudeSidecar.Kind) -> String? = { kind in
            ChatRouteChoice.all.first { AssistantModelRouting.engineKind(for: $0) == kind }?.id
        }
        if let claudeRoute = routeFor(.claude), let codexRoute = routeFor(.codex) {
            check(AssistantModelRouting.pick(stored: codexRoute, lead: codexRoute, coder: claudeRoute,
                                             isDisabled: { $0 == .codex })?.id == claudeRoute
                  && AssistantModelRouting.pick(stored: claudeRoute, lead: codexRoute, coder: codexRoute,
                                                isDisabled: { $0 == .codex })?.id == claudeRoute
                  && AssistantModelRouting.pick(stored: nil, lead: codexRoute, coder: codexRoute,
                                                isDisabled: { $0 != .grok }).flatMap { AssistantModelRouting.engineKind(for: $0) } == .grok
                  && AssistantModelRouting.pick(stored: nil, lead: codexRoute, coder: claudeRoute, isDisabled: { _ in true }) == nil,
                  "(2) pick order: stored, lead, Coder, first enabled; all disabled is nil")
        } else {
            check(false, "(2) pick fixture routes")
        }
        check(!model.assistantModelOptions.contains { $0.title == $0.title.lowercased() && $0.title.contains(where: \.isNumber)
                  && !$0.title.contains(" ") },
              "menu shows friendly names, not raw route ids")

        // 主設備替身：助理那條＋兩條同名 session（不同時間）＋一條普通 session。
        let primaryDevice = AssistantPrimaryDevice(id: UUID().uuidString.lowercased(), displayName: "Primary One")
        var remoteDoc = LiveDocumentRecord()
        let primaryAssistant = remoteDoc.ensureAssistantThread()
        let remoteProject = LiveProjectRecord(name: "Remote project", workdir: "/tmp")
        remoteDoc.projects.append(remoteProject)
        let now = Date()
        var remoteSession = LiveThreadRecord(projectID: remoteProject.id, title: "遠端串")
        remoteSession.updatedAt = now.addingTimeInterval(-60)
        var twinOld = LiveThreadRecord(projectID: remoteProject.id, title: "同名串")
        twinOld.updatedAt = now.addingTimeInterval(-86_400 * 2)
        var twinNew = LiveThreadRecord(projectID: remoteProject.id, title: "同名串")
        twinNew.updatedAt = now.addingTimeInterval(-3 * 3_600)
        remoteDoc.threads += [remoteSession, twinOld, twinNew]
        let primary = AssistantRemoteAcceptanceDouble(doc: remoteDoc)
        var reachable = true
        var connecting = false
        var connected: AssistantRemoteAcceptanceDouble = primary
        model.assistantPrimaryTestDouble = (device: primaryDevice,
                                            engine: { () -> (any AssistantRemoteEngine)? in reachable ? connected : nil },
                                            connecting: { connecting })

        // (3) 副設備＋主設備連得到：TATWO 送出進主設備那條，本機文件不多一條，Coder 不動。
        model.disabledEngines = everyEngine   // 這台三家都停用（使用者的現況）；只改記憶體
        let localThreads = engine.doc.threads.count
        let localProjects = engine.doc.projects.count
        let localAssistantRows = engine.transcript(for: localAssistant).count
        if case .primary(_, let id, let device) = model.assistantPlacement {
            check(id == primaryAssistant && device == primaryDevice, "(3) placement is the primary's assistant thread")
        } else {
            check(false, "(3) placement is the primary's assistant thread")
        }
        check(model.assistantPrimaryName == "Primary One" && model.assistantCanSend && model.assistantPlacementNote == nil,
              "(3) pane shows it lives on the primary and can send")
        model.assistantPrompt = "助理你好"
        model.sendAssistantDraft()
        check(primary.sent.last.map { $0.threadID == primaryAssistant && $0.text == "助理你好" } == true
              && model.assistantPrompt == "助理你好" && model.assistantIsDelivering && !model.assistantCanSend,
              "(3) the draft stays until the primary confirms; sending is blocked meanwhile")
        let inFlight = primary.sent.count
        model.sendAssistantDraft()
        check(primary.sent.count == inFlight, "(3) no second send while the first is on its way")
        primary.finishDeliveries()
        check(model.assistantPrompt.isEmpty && model.assistantCanSend && !model.assistantIsDelivering
              && model.assistantPrimaryHint == nil, "(3) TATWO send lands in the primary thread")
        check(primary.sent.last.map { Set($0.params.keys) == ["threadID", "text"] } == true,
              "(3) nothing picked: only the text goes; persona, model, effort and speed are the primary's (local disable not applied)")
        check(engine.doc.threads.count == localThreads && engine.doc.projects.count == localProjects
              && engine.transcript(for: localAssistant).count == localAssistantRows,
              "(3) local document gets no extra thread or message")
        check(model.assistantMessages.map(\.text) == primary.transcript(for: primaryAssistant).map(\.text)
              && model.assistantMessages.last?.text == "助理你好", "(3) both devices read the same conversation")
        check(model.selectedThreadID == threadA && engine.doc.selectedThreadID == threadA && model.prompt == "Coder 草稿"
              && model.remoteMode == nil, "(3) Coder selection, remote mode and draft unchanged")
        check(model.assistantModelChipTitle == "主設備預設" && !model.assistantModelOptions.contains { $0.isDisabled },
              "(3) chip defers to the primary; local disable is not applied to its menu")

        // 送出失敗：草稿留著、一行白話說明；連線斷掉也一樣；下一次送到就收掉。草稿送出途中被改過就不動。
        primary.nextFailure = RemoteHostLinkError.remoteError("assistant_busy")
        model.assistantPrompt = "忙的時候"
        model.sendAssistantDraft()
        primary.finishDeliveries()
        check(model.assistantPrompt == "忙的時候" && model.assistantCanSend
              && model.assistantPrimaryHint?.contains("還在回上一句") == true,
              "(3) a send the primary refuses keeps the draft and says why in one line")
        primary.nextFailure = RemoteHostLinkError.tunnelUnavailable
        model.sendAssistantDraft()
        primary.finishDeliveries()
        check(model.assistantPrompt == "忙的時候" && model.assistantPrimaryHint?.contains("連線不穩") == true,
              "(3) a send lost on the way keeps the draft too")
        model.sendAssistantDraft()
        model.assistantPrompt = "忙的時候，改過"
        primary.finishDeliveries()
        check(model.assistantPrompt == "忙的時候，改過" && model.assistantPrimaryHint == nil,
              "(3) a draft edited while sending is kept; a delivered send clears the note")
        model.assistantPrompt = ""

        // 遠端快取換版被清掉、還在重拉：用文件快照裡的訊息，不閃回歡迎畫面；真的什麼都沒有才顯示連線中。
        primary.cacheCleared = true
        primary.loading = [primaryAssistant]
        let snapshotIDs = primary.threadRecord(primaryAssistant)?.messages.map(\.id) ?? []
        check(!snapshotIDs.isEmpty && model.assistantMessages.map(\.id) == snapshotIDs && !model.assistantTranscriptLoading,
              "(3) a refetch after a new revision shows the snapshot, not the empty welcome")
        let fullDoc = primary.doc
        if let index = primary.doc.threads.firstIndex(where: { $0.id == primaryAssistant }) {
            primary.doc.threads[index].messages = []
        }
        check(model.assistantMessages.isEmpty && model.assistantTranscriptLoading,
              "(3) nothing in hand yet: loading, not the welcome screen")
        primary.doc = fullDoc
        primary.cacheCleared = false
        primary.loading = []

        // 每一條選單路由都照選的那家到主設備（含 Claude 沒有 claude- 開頭模型參數的，例 Sonnet 類），
        // 參數用真的 RemoteLiveEngine 形狀，主設備那一側用真的 bridge 判斷；那條上次用的是別家也一樣。
        var routesReachPrimary = true
        var sawClaudeWithoutModelID = false
        for route in ChatRouteChoice.all {
            let picked = ChatRouteChoice.resolve(route.id)   // 選單送出去的就是這條（別名歸到同一條）
            guard let kind = AssistantModelRouting.engineKind(for: picked) else { continue }
            model.setAssistantModel(route.id)
            model.assistantPrompt = "用 \(route.id)"
            model.sendAssistantDraft()
            primary.finishDeliveries()
            guard let params = primary.sent.last?.params, primary.sent.last?.text == "用 \(route.id)" else {
                routesReachPrimary = false
                continue
            }
            let modelSent = params["model"] as? String
            let engineSent = params["engine"] as? String
            let routeSent = params["assistantRoute"] as? String
            let other: ClaudeSidecar.Kind = kind == .codex ? .claude : .codex
            let resolved = OSAgentBridge.sendMessageEngine(modelArgument: modelSent, requested: engineSent,
                                                           threadEngine: other.rawValue)
            let followsAssistantRules = OSAgentBridge.routesToAssistant(isAssistantThread: true, modelArgument: modelSent,
                                                                        assistantRoute: routeSent,
                                                                        reasoningEffort: nil, serviceTier: nil)
            if kind == .claude, modelSent == nil { sawClaudeWithoutModelID = true }
            let localUntouched = engine.threadRecord(localAssistant)?.requestedModel == nil
            let delivered = model.assistantPrompt.isEmpty
            let reached = resolved == kind && routeSent == picked.id && followsAssistantRules
            routesReachPrimary = routesReachPrimary && reached && delivered && localUntouched
        }
        check(routesReachPrimary, "(3) every menu route reaches the primary as its own engine, even if the thread last used another")
        check(sawClaudeWithoutModelID || !ChatRouteChoice.all.contains {
                  AssistantModelRouting.engineKind(for: $0) == .claude && AssistantModelRouting.modelArgument($0, kind: .claude) == nil },
              "(3) Claude routes without a claude- model id are covered")
        var stored = primary.doc
        if let index = stored.threads.firstIndex(where: { $0.id == remoteSession.id }) {
            stored.threads[index].requestedModel = routeFor(.codex).map {
                AssistantModelRouting.modelArgument(ChatRouteChoice.resolve($0), kind: .codex) ?? $0 }
        }
        primary.doc = stored

        // DM：助理對象也是主設備那條；主設備回覆收到才清草稿。
        let suite = "ai.tatwo.selftest.w179remote.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false }, directKeys: false)
        store.attach(model)
        store.select(.assistant)
        store.setDraft("私訊助理", for: .assistant)
        let dmSent = store.send()
        let dmKeptWhileSending = store.draft(for: .assistant) == "私訊助理"
        primary.finishDeliveries()
        check(dmSent && dmKeptWhileSending && store.draft(for: .assistant).isEmpty
              && primary.sent.last.map { $0.threadID == primaryAssistant && $0.text == "私訊助理" } == true
              && engine.transcript(for: localAssistant).count == localAssistantRows,
              "(3) DM assistant target sends to the primary thread")

        // (4) 私訊框清單含主設備的 session（標設備名），同名的補時間；送出進遠端、Coder 選取不變。
        let candidates = model.dmSessionCandidates()
        let remoteRow = candidates.first { $0.id == remoteSession.id }
        check(remoteRow?.displayLabel == "Primary One · Remote project › 遠端串" && remoteRow?.isRemote == true,
              "(4) primary sessions are listed with the device name")
        check(candidates.contains { $0.id == threadA && $0.displayLabel == "Local project › A 串" && !$0.isRemote }
              && !candidates.contains { $0.id == primaryAssistant || $0.id == localAssistant },
              "(4) local sessions unchanged; neither assistant is a session")
        let twins = candidates.filter { $0.title == "同名串" }
        check(twins.count == 2 && Set(twins.map(\.displayLabel)).count == 2
              && twins.contains { $0.displayLabel.contains("小時前") },
              "(4) same-title sessions get a relative time")
        let sameHour = [twinOld, twinNew].map { row -> GlobalDMSessionCandidate in
            GlobalDMSessionCandidate(id: row.id, projectName: "P", title: "同名", activity: now.addingTimeInterval(-7_200))
        } + [GlobalDMSessionCandidate(id: UUID(), projectName: "P", title: "同名", activity: now.addingTimeInterval(-7_300))]
        let named = GlobalDMSessionCandidate.disambiguated(sameHour, now: now)
        check(Set(named.map(\.displayLabel)).count == 3 && named.allSatisfy { $0.disambiguator != nil },
              "(4) same title and same relative time still get distinct labels")
        let recentIDs = model.dmSessionCandidates(limit: GlobalDMStore.recentLimit).map(\.displayLabel)
        check(recentIDs == Array(candidates.prefix(GlobalDMStore.recentLimit)).map(\.displayLabel),
              "(4) the recent list and the header name a session the same way")
        check(store.recentSessions().contains { $0.id == remoteSession.id }
              && store.title(for: .thread(remoteSession.id)) == "Primary One · Remote project › 遠端串",
              "(4) DM picker and header show the primary session")
        let beforeRemote = primary.sent.count
        let remoteSent = model.sendFromDM(threadID: remoteSession.id, text: "給遠端串")
        primary.finishDeliveries()
        check(remoteSent && primary.sent.count == beforeRemote + 1
              && primary.sent.last.map { $0.threadID == remoteSession.id && $0.text == "給遠端串" } == true,
              "(4) DM send to a primary session goes through the remote engine")
        let storedRoute = AssistantModelRouting.storedRoute(primary.threadRecord(remoteSession.id))
        let storedModel = storedRoute.flatMap { AssistantModelRouting.modelArgument($0, kind: .codex) }
        let sessionParams = primary.sent.last?.params ?? [:]
        let sessionModel = sessionParams["model"] as? String
        let sessionEngine = sessionParams["engine"] as? String
        check(storedModel != nil && sessionModel == storedModel && sessionEngine == ClaudeSidecar.Kind.codex.rawValue
              && sessionParams["assistantRoute"] == nil,
              "(4) the session's own stored model goes with it")
        check(model.selectedThreadID == threadA && engine.doc.selectedThreadID == threadA && model.remoteMode == nil
              && model.prompt == "Coder 草稿" && engine.doc.threads.count == localThreads,
              "(4) Coder selection unchanged by a remote DM send")
        check(model.dmTranscript(for: remoteSession.id).last?.text == "給遠端串" && !model.dmSessionIsRunning(remoteSession.id),
              "(4) DM reads the remote transcript")
        check(!model.sendFromDM(threadID: remoteSession.id, text: "/goal 做完") && primary.sent.count == beforeRemote + 1,
              "(4) Coder-only slash commands stay out of remote sessions too")
        store.select(.thread(remoteSession.id))
        store.setDraft("遠端失敗", for: .thread(remoteSession.id))
        primary.nextFailure = RemoteHostLinkError.remoteError("invalid_params")
        _ = store.send()
        primary.finishDeliveries()
        check(store.draft(for: .thread(remoteSession.id)) == "遠端失敗"
              && model.dmSessionHint(remoteSession.id) == "主設備「Primary One」沒收下這句：那台不接受這次送出的參數，請確認版本與送出設定；草稿留著。",
              "(4) a DM send the primary refuses keeps the draft and says why")
        model.stopDMSession(remoteSession.id)
        model.stopAssistant()
        check(primary.stopped == [remoteSession.id, primaryAssistant], "(4) stop goes to the primary")

        // (5) 連不上＋本機全停用：一行說明、不送、草稿保留；清單不列主設備的 session，但選著的那條留著。
        reachable = false
        let sentBefore = primary.sent.count
        check(model.assistantPlacementNote == "助理在主設備「Primary One」上，現在連不上；連上後會自動接回。"
              && !model.assistantCanSend, "(5) offline + all local disabled: plain one-line note")
        model.assistantPrompt = "等等再送"
        model.sendAssistantDraft()
        check(model.assistantPrompt == "等等再送" && primary.sent.count == sentBefore
              && engine.transcript(for: localAssistant).count == localAssistantRows,
              "(5) nothing is sent, no error card, the draft stays")
        store.validateTarget()
        check(store.target == .thread(remoteSession.id)
              && store.title(for: .thread(remoteSession.id)) == "Primary One · Remote project › 遠端串"
              && model.dmSessionNote(remoteSession.id) == "這條對話在主設備「Primary One」上，現在不能送出；草稿留著。"
              && !model.dmSessionCanSend(remoteSession.id) && store.draft(for: .thread(remoteSession.id)) == "遠端失敗",
              "(5) offline: the DM keeps a primary session as its target, with its last name, a note and no send")
        store.select(.assistant)
        store.setDraft("離線草稿", for: .assistant)
        check(!store.send() && store.draft(for: .assistant) == "離線草稿", "(5) DM keeps the draft while offline")
        check(!model.dmSessionCandidates().contains { $0.isRemote }, "(5) offline: primary sessions leave the list")
        connecting = true
        model.disabledEngines = [ClaudeSidecar.Kind.codex.rawValue]
        check(!model.assistantPlacement.isPrimary && !model.assistantCanSend
              && model.assistantPlacementNote == "助理在主設備「Primary One」上，現在還不能送出；草稿留著。",
              "(5) connecting: action-local blocker keeps the draft; no connection progress notice")
        connecting = false

        // (6) W201：連不上但本機還能接著聊，安靜接手；本機送出能力仍照原規則。
        check(!model.assistantPlacement.isPrimary && model.assistantCanSend
              && model.assistantPlacementNote == nil,   // W182 R5
              "(6) offline with a local engine enabled: local assistant")
        reachable = true
        check(model.assistantPlacement.isPrimary && model.assistantPlacementNote == nil, "(6) reconnects to the primary automatically")
        var olderDoc = LiveDocumentRecord()
        olderDoc.projects.append(remoteProject)
        connected = AssistantRemoteAcceptanceDouble(doc: olderDoc)
        check(!model.assistantPlacement.isPrimary && model.assistantPlacementNote == nil,
              "(6) a primary without an assistant quietly uses the available local assistant")
        connected = primary

        // (7) 私訊框排版：附件不露路徑；有表格、清單才用 Coder 的排版元件。
        let attachment = GlobalDMMessageText.displayText(
            "看這張\n\n<image name=[a.png] path=\"/tmp/w179/a.png\">\n<file name=[b.txt] path=\"/tmp/w179/b.txt\">")
        check(attachment == "看這張\n\n[圖片：a.png]\n[檔案：b.txt]", "(7) attachment tags become short words without paths")
        let bubbles = GlobalDMBubble.rows([ChatMessage(role: .user, text: "附上 <image name=[x] path=\"/tmp/w179/x.png\">")])
        check(bubbles.first?.text == "附上 [圖片：x]", "(7) DM bubbles never show attachment paths")
        check(GlobalDMMessageText.needsBlockLayout("| a | b |\n|---|---|\n| 1 | 2 |")
              && GlobalDMMessageText.needsBlockLayout("清單：\n- 一\n- 二")
              && GlobalDMMessageText.needsBlockLayout("1. 第一步")
              && !GlobalDMMessageText.needsBlockLayout("**粗體** 和 `code`"), "(7) block layout only for tables/lists")
        check(String(GlobalDMMessageText.inline("**粗體** 和 `code`").characters) == "粗體 和 code",
              "(7) inline Markdown hides the ** and ` marks")

        // (9) 主設備那一側（這個 model 當主設備）：副設備交來助理那條的一句照這台自己的規則。只到登入檢查（未登入），不燒額度。
        model.assistantPrimaryTestDouble = nil
        let primaryRows = engine.transcript(for: localAssistant).count
        model.disabledEngines = everyEngine
        check(model.receiveAssistantTurnFromSecondary(threadID: localAssistant, text: "副設備來的", routeID: nil)
                  == "assistant_engines_disabled" && engine.transcript(for: localAssistant).count == primaryRows,
              "(9) primary: all engines disabled → refused with a reason, nothing sent")
        model.disabledEngines = [ClaudeSidecar.Kind.codex.rawValue, ClaudeSidecar.Kind.grok.rawValue]
        if let codexRoute = routeFor(.codex) {
            check(model.receiveAssistantTurnFromSecondary(threadID: localAssistant, text: "副設備來的", routeID: codexRoute)
                      == "assistant_engine_disabled" && engine.threadRecord(localAssistant)?.requestedModel == nil
                      && engine.transcript(for: localAssistant).count == primaryRows,
                  "(9) primary: a route on an engine disabled here is refused")
        }
        // 現行送出會讓尚未讀取登入狀態的引擎自行檢查；隔離測試先讀取真實未登入 fixture。
        model.seedSendLoginStatusForSelfTest(login.status(for: .claude), checkedAt: Date())
        let loginNote = "Claude 還沒登入"
        let loginResult = model.receiveAssistantTurnFromSecondary(threadID: localAssistant, text: "副設備來的", routeID: nil)
        check(loginResult == "assistant_not_sent" && engine.transcript(for: localAssistant).last?.text.contains(loginNote) == true,
              "(9) primary: no route → its own order skips its disabled engines (reaches the login check for Claude)")
        if let sonnetLike = ChatRouteChoice.all.first(where: {
            AssistantModelRouting.engineKind(for: $0) == .claude && AssistantModelRouting.modelArgument($0, kind: .claude) == nil }) {
            check(model.receiveAssistantTurnFromSecondary(threadID: localAssistant, text: "副設備來的", routeID: sonnetLike.id)
                      == "assistant_not_sent" && engine.threadRecord(localAssistant)?.requestedModel == sonnetLike.id
                      && engine.transcript(for: localAssistant).last?.text.contains(loginNote) == true,
                  "(9) primary: an explicit Claude route without a claude- model id is kept as Claude")
        }
        check(model.receiveAssistantTurnFromSecondary(threadID: threadA, text: "不是助理", routeID: nil) == "assistant_unavailable",
              "(9) primary: only the assistant thread takes this path")
        let rowsBeforeUnknown = engine.transcript(for: localAssistant).count
        check(model.receiveAssistantTurnFromSecondary(threadID: localAssistant, text: "副設備來的", routeID: "no-such-route-9")
                  == "assistant_model_unknown" && engine.transcript(for: localAssistant).count == rowsBeforeUnknown,
              "(9) primary: a route id it does not know is refused, nothing sent")
        check(OSAgentBridge.routesToAssistant(isAssistantThread: true, modelArgument: nil, assistantRoute: nil,
                                              reasoningEffort: nil, serviceTier: nil)
              && OSAgentBridge.routesToAssistant(isAssistantThread: true, modelArgument: "gpt-x", assistantRoute: "gpt",
                                                 reasoningEffort: nil, serviceTier: nil)
              && !OSAgentBridge.routesToAssistant(isAssistantThread: true, modelArgument: "gpt-x", assistantRoute: nil,
                                                  reasoningEffort: nil, serviceTier: nil)
              && !OSAgentBridge.routesToAssistant(isAssistantThread: true, modelArgument: nil, assistantRoute: nil,
                                                  reasoningEffort: "high", serviceTier: nil)
              && !OSAgentBridge.routesToAssistant(isAssistantThread: false, modelArgument: nil, assistantRoute: nil,
                                                  reasoningEffort: nil, serviceTier: nil),
              "(9) bridge: which send_message turns follow the primary's assistant rules")
        // 基準版本已優先採用明確的 requested engine；驗收跟現行規則一致，bridge 不改。
        check(OSAgentBridge.sendMessageEngine(modelArgument: nil, requested: "claude", threadEngine: "codex") == .claude
              && OSAgentBridge.sendMessageEngine(modelArgument: nil, requested: nil, threadEngine: "codex") == .codex
              && OSAgentBridge.sendMessageEngine(modelArgument: "gpt-6-astra", requested: "claude", threadEngine: nil) == .claude
              && OSAgentBridge.sendMessageEngine(modelArgument: nil, requested: "bogus", threadEngine: nil) == .claude,
              "(9) bridge: a turn without a model id uses the sender's engine, then the thread's")
        model.disabledEngines = []

        // (8) 停用設定一個字都沒寫。
        check(UserDefaults.standard.stringArray(forKey: disableKey) == disableBefore, "(8) engine-disable settings untouched")

        print("W179REMOTE SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}

/// 主設備的最小替身：記得收到的每一輪（參數用真的 RemoteLiveEngine 形狀）、停止要求；不啟動引擎、不連線。
/// 送出先掛著，`finishDeliveries()` 才回覆（模擬主設備回覆收到前的那段時間）；`nextFailure` 有值時下一個回覆當失敗。
@MainActor
final class AssistantRemoteAcceptanceDouble: AssistantRemoteEngine {
    struct Sent {
        let threadID: UUID
        let text: String
        let params: [String: Any]
    }

    var doc: LiveDocumentRecord
    private(set) var sent: [Sent] = []
    private(set) var stopped: [UUID] = []
    var nextFailure: Error?
    /// 模擬遠端快取換版被清掉（transcript 回空）與背景重拉中。
    var cacheCleared = false
    var loading: Set<UUID> = []
    private var messages: [UUID: [ChatMessage]] = [:]
    private var pending: [(threadID: UUID, text: String, completion: @MainActor (Result<Void, Error>) -> Void)] = []

    init(doc: LiveDocumentRecord) { self.doc = doc }

    func transcript(for threadID: UUID?) -> [ChatMessage] {
        cacheCleared ? [] : threadID.flatMap { messages[$0] } ?? []
    }
    func isTranscriptLoading(_ threadID: UUID?) -> Bool { threadID.map { loading.contains($0) } ?? false }
    func isRunning(_ threadID: UUID?) -> Bool { false }
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? { doc.threads.first { $0.id == threadID } }

    func deliver(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        sent.append(Sent(threadID: threadID, text: text,
                         params: RemoteLiveEngine.deliverParams(threadID: threadID, text: text, model: model, engine: engine,
                                                                assistantRoute: assistantRoute)))
        pending.append((threadID, text, completion))
    }

    /// 主設備回覆：成功的把那句記進逐字稿與文件快照（get_document 帶的訊息）。
    func finishDeliveries() {
        let batch = pending
        pending = []
        for item in batch {
            if let failure = nextFailure {
                nextFailure = nil
                item.completion(.failure(failure))
                continue
            }
            guard let index = doc.threads.firstIndex(where: { $0.id == item.threadID }) else {
                item.completion(.failure(RemoteHostLinkError.remoteError("invalid_params")))
                continue
            }
            let message = ChatMessage(role: .user, text: item.text)
            messages[item.threadID, default: []].append(message)
            doc.threads[index].messages.append(LiveMessageRecord(message))
            item.completion(.success(()))
        }
    }

    func stop(threadID: UUID) { stopped.append(threadID) }
}
#endif
