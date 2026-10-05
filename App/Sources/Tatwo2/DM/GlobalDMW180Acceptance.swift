#if DEBUG
import AppKit
import Combine
import Foundation

/// `TATWO2_SELFTEST=w180dm`：無頭驗收 W180 私訊框——A3 對象圖示列的順序與行為、A4 模型 chip（三種對象各自的設定路徑，
/// 選了只改那個對象）、D2 附件路徑（別台上的停用並說明）、子討論串與所有配對設備的 session、「到 Island 核准」帶 id。
/// 只在完整隔離的 staging 環境跑；不建視窗、不啟動引擎（隔離的引擎資料夾必須未登入，不燒額度）；別台是記憶體替身，不連 SSH；
/// ChatGPT 是記憶體裡的假 Pod，不開網頁。
enum GlobalDMW180Acceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w180dm needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w180dm requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W180DM \(condition ? "PASS" : "FAIL") \(label)")
        }

        // 本機：兩條 session（A、B）＋A 底下一條子討論串；Coder 選著 A、輸入框有草稿。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "W180 專案", workdir: root.path)
        let threadA = engine.newThread(in: project, title: "A 串")
        let threadB = engine.newThread(in: project, title: "B 串")
        guard let sub = engine.createDiscussion(parentThreadID: threadA),
              let localAssistant = engine.doc.assistantThreadID else {
            throw BotLibraryError.invalid("fixture threads missing")
        }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        model.select(projectID: project, threadID: threadA)
        model.prompt = "Coder 草稿"
        model.disabledEngines = []   // 只改這個 model 的記憶體狀態，不讀寫使用者的停用設定
        let coderModel = model.selectedModel

        // 別台（記憶體替身）：主設備有一條 session＋它的子討論串；第二台連得到、一條 session；第三台連不上。
        let now = Date()
        var primaryDoc = LiveDocumentRecord()
        let remoteProject = LiveProjectRecord(name: "Remote project", workdir: "/tmp")
        primaryDoc.projects.append(remoteProject)
        var remoteThread = LiveThreadRecord(projectID: remoteProject.id, title: "遠端串")
        remoteThread.updatedAt = now.addingTimeInterval(-600)
        var remoteChild = LiveThreadRecord(projectID: remoteProject.id, title: "遠端子串")
        remoteChild.parentThreadID = remoteThread.id
        remoteChild.updatedAt = now.addingTimeInterval(-500)
        primaryDoc.threads += [remoteThread, remoteChild]
        let primary = AssistantRemoteAcceptanceDouble(doc: primaryDoc)
        var secondDoc = LiveDocumentRecord()
        let secondProject = LiveProjectRecord(name: "Second project", workdir: "/tmp")
        secondDoc.projects.append(secondProject)
        var secondThread = LiveThreadRecord(projectID: secondProject.id, title: "第二台串")
        secondThread.updatedAt = now.addingTimeInterval(-300)
        secondDoc.threads.append(secondThread)
        let second = AssistantRemoteAcceptanceDouble(doc: secondDoc)
        var secondReachable = true
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: "primary-one", displayName: "Primary One"),
                                            engine: { () -> (any AssistantRemoteEngine)? in primary },
                                            connecting: { false })
        model.dmRemoteDeviceTestDoubles = [
            (device: AssistantPrimaryDevice(id: "second-two", displayName: "Second Two"),
             engine: { () -> (any AssistantRemoteEngine)? in secondReachable ? second : nil }, connecting: { false }),
            (device: AssistantPrimaryDevice(id: "third-three", displayName: "Third Three"),
             engine: { () -> (any AssistantRemoteEngine)? in nil }, connecting: { false }),
        ]

        // MARK: D2 子討論串、所有配對設備
        let all = model.dmSessionCandidates()
        check(all.first { $0.id == sub }.map { $0.parentID == threadA && $0.label == "W180 專案 › A 串 › 支線 1" } == true,
              "D2 a local sub-thread is listed under its parent")
        check(all.first { $0.id == remoteThread.id }?.deviceName == "Primary One"
              && all.first { $0.id == remoteChild.id }.map { $0.parentID == remoteThread.id && $0.deviceName == "Primary One" } == true,
              "D2 primary sessions and their sub-threads are listed with the device name")
        check(all.first { $0.id == secondThread.id }.map { $0.deviceName == "Second Two" && $0.isRemote } == true,
              "D2 sessions on another paired device are listed too (not only the primary)")
        check(!all.contains { $0.id == localAssistant } && Set(all.map(\.id)).count == all.count,
              "D2 no assistant, no duplicates")

        let suite = "ai.tatwo.selftest.w180dm.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant"),
                               TapEffort(id: "fixture|pro", title: "Pro", isMax: true)]),
            TapModel(id: "fixture-legacy", title: "Legacy fixture", detail: ""),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|instant")
        let pod = GlobalDMW180Pod()
        let tap = ChatGPTTap(transport: pod, connection: .ready)
        let chatSession = ChatGPTConversationSession(tap: tap)
        let store = GlobalDMStore(defaults: defaults, chatGPT: { chatSession }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() })
        store.attach(model)

        let rows = store.sessionRows(everything: true)
        let rowIndex = { (id: UUID) in rows.firstIndex { $0.id == id } }
        if let a = rowIndex(threadA), let s = rowIndex(sub), let r = rowIndex(remoteThread.id), let rc = rowIndex(remoteChild.id) {
            check(s == a + 1 && rows[s].depth == 1 && rows[a].depth == 0 && rc == r + 1 && rows[rc].depth == 1,
                  "D2 picker rows hang each sub-thread right under its parent")
        } else {
            check(false, "D2 picker rows hang each sub-thread right under its parent")
        }
        check(store.sessionRows().allSatisfy { $0.depth > 0 || $0.session.parentID == nil }
              && store.recentSessions().allSatisfy { $0.parentID == nil },
              "D2 the recent list counts top-level sessions; sub-threads only hang under them")
        let searched = store.sessionRows(query: "支線")
        check(searched.map(\.id) == [sub], "D2 search finds a sub-thread by its own title")

        // MARK: A3 圖示列
        // W181：圖示列先只放 TATWO 助理與 ChatGPT；下面驗的是其他圓鈕打開時的完整清單（程式留著）。
        // W183 R8b：第三顆圓鈕 Browser 接在 ChatGPT 後面。
        check(store.iconItems().map(\.kind) == [.assistant, .chatGPT, .browser] && !GlobalDMStore.showsOtherTargets,
              "A3 W181 the strip shows only the TATWO assistant and ChatGPT (W183 R8b: plus Browser)")
        let items = store.iconItems(showingOthers: true)
        let kinds = items.map(\.kind)
        let sessionKinds = kinds.filter { if case .session = $0 { return true } else { return false } }
        check(Array(kinds.prefix(4)) == [.assistant, .chatGPT, .browser, .coder]
              && Array(kinds.suffix(3)) == [.later, .later, .directKeys]
              && sessionKinds.count == GlobalDMStore.iconSessionLimit
              && kinds.count == 4 + GlobalDMStore.iconSessionLimit + 3,
              "A3 icon order: assistant, ChatGPT, Coder, recent sessions, later (Bot team, LINE), direct keys")
        check(Array(items.map(\.letter).prefix(4)) == ["T", "G", "B", "C"] && items.last?.letter == "⌘"
              && items.filter { $0.kind == .later }.allSatisfy { !$0.isEnabled },
              "A3 letters T/G/C/⌘; the later icons are grey and not clickable")
        let sessionIcons = items.filter { if case .session = $0.kind { return true } else { return false } }
        check(sessionIcons.allSatisfy { icon in all.contains { "thread:" + $0.id.uuidString == icon.id && $0.parentID == nil } },
              "A3 session icons are recent top-level sessions")
        store.select(.thread(remoteThread.id))
        let withRemote = store.iconItems(showingOthers: true)
        check(withRemote.contains { $0.kind == .session(remoteThread.id) && $0.device == "Primary One" && $0.letter == "RP" }
              && withRemote.filter { if case .session = $0.kind { return true } else { return false } }.count
                 == GlobalDMStore.iconSessionLimit,
              "A3 the current session always has an icon (with the device mark and the project abbreviation)")
        store.select(.assistant)
        check(!store.isPickerOpen, "A3 closed picker at start")
        if let coder = items.first(where: { $0.kind == .coder }) {
            store.activate(coder)
            check(store.isPickerOpen && store.isSelected(coder) && store.target == .assistant,
                  "A3 the Coder icon opens the session picker in the box (the target stays)")
            let ringed = store.iconItems(showingOthers: true).filter { store.isSelected($0) }
            check(ringed.map(\.kind) == [.coder] && items.first.map { store.isCurrentTarget($0) && !store.isSelected($0) } == true,
                  "A3 only one accent ring: while the picker is open the current target keeps just the glass fill")
            store.activate(coder)
            check(!store.isPickerOpen, "A3 clicking the Coder icon again folds it")
        } else {
            check(false, "A3 Coder icon exists")
        }
        if let later = items.first(where: { $0.kind == .later }) {
            store.activate(later)
            check(store.target == .assistant && !store.isPickerOpen, "A3 later icons do nothing")
        } else {
            check(false, "A3 later icons do nothing (later icon exists)")
        }
        store.isPickerOpen = true
        store.select(.thread(threadB))
        check(store.target == .thread(threadB) && !store.isPickerOpen, "A3 picking a session switches and folds the picker")
        if let keys = items.first(where: { $0.kind == .directKeys }) {
            store.activate(keys)
            check(store.isEditingDirectKeys && store.isSelected(keys)
                  && store.iconItems(showingOthers: true).filter { store.isSelected($0) }.map(\.kind) == [.directKeys],
                  "A3 the ⌘ icon opens the direct-key page")
            store.isEditingDirectKeys = false
        } else {
            check(false, "A3 the ⌘ icon opens the direct-key page (icon exists)")
        }
        let secondary = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false },
                                      chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false)
        secondary.attach(model)
        let secondaryItems = secondary.iconItems(showingOthers: true)
        check(secondaryItems.last?.kind == .later && secondaryItems.first { $0.kind == .chatGPT }?.isEnabled == false,
              "A3 the right column has no direct-key icon; ChatGPT off is grey")
        check(GlobalDMSessionCandidate.abbreviation("TATWO OS") == "TO"
              && GlobalDMSessionCandidate.abbreviation("web") == "We"
              && GlobalDMSessionCandidate.abbreviation("聊天") == "聊"
              && GlobalDMSessionCandidate.abbreviation("") == "C",
              "A3 project abbreviations")

        // MARK: A4 模型 chip：本機 session
        let bBefore = engine.threadRecord(threadB)?.requestedModel
        let aBefore = engine.threadRecord(threadA)?.requestedModel
        let assistantBefore = engine.threadRecord(localAssistant)?.requestedModel
        let bOptions = store.modelOptions(for: .thread(threadB))
        if let other = bOptions.first(where: { !$0.isSelected && !$0.isDisabled }) {
            store.chooseModel(other.route.id, for: .thread(threadB))
            check(engine.threadRecord(threadB)?.requestedModel == other.route.id
                  && store.modelChipTitle == AssistantModelRouting.chipName(other.route),
                  "A4 a local session's model is set on that session (setModelPreferences)")
            check(engine.threadRecord(threadA)?.requestedModel == aBefore
                  && engine.threadRecord(localAssistant)?.requestedModel == assistantBefore
                  && model.selectedModel == coderModel && model.selectedThreadID == threadA && model.prompt == "Coder 草稿",
                  "A4 picking it leaves the Coder composer, the assistant and other sessions alone")
            if let blocked = ChatRouteChoice.all.first(where: { $0.id != other.route.id }),
               let kind = AssistantModelRouting.engineKind(for: blocked) {
                model.disabledEngines = [kind.rawValue]
                let marked = store.modelOptions(for: .thread(threadB)).first { $0.route.id == blocked.id }
                store.chooseModel(blocked.id, for: .thread(threadB))
                check(marked.map { $0.isDisabled && $0.title.hasSuffix("已停用") } == true
                      && engine.threadRecord(threadB)?.requestedModel == other.route.id,
                      "A4 a disabled engine is marked 已停用 and cannot be picked")
                model.disabledEngines = []
            } else {
                check(false, "A4 a disabled engine is marked 已停用 and cannot be picked (no second route to disable)")
            }
        } else {
            check(false, "A4 local session model options (bBefore \(bBefore ?? "nil"))")
        }

        // 助理：助理的模型選單（本機那條）。
        store.select(.assistant)
        let assistantOptions = store.modelOptions(for: .assistant)
        check(assistantOptions.map(\.id) == AssistantModelRouting.options(selectedID: nil, isDisabled: { _ in false }).map(\.id)
              && assistantOptions.filter(\.isSelected).map(\.id) == [model.assistantRouteChoice.id]
              && store.modelHeadline(for: .assistant) == nil,
              "A4 the assistant uses the assistant's model menu")
        if let pick = assistantOptions.first(where: { !$0.isSelected && !$0.isDisabled }) {
            let bNow = engine.threadRecord(threadB)?.requestedModel
            store.chooseModel(pick.route.id, for: .assistant)
            check(engine.threadRecord(localAssistant)?.requestedModel == pick.route.id
                  && engine.threadRecord(threadB)?.requestedModel == bNow && model.selectedModel == coderModel,
                  "A4 the assistant's pick changes only the assistant")
        } else {
            check(false, "A4 the assistant's pick changes only the assistant (no other route)")
        }

        // 私訊框改的正好是 Coder 開著的那條（A）：Coder 的模型 chip 跟著那條的新模型，之後在 Coder 改思考強度
        // 也不會把舊模型寫回去；Coder 的選取與草稿不動。
        if let pickA = store.modelOptions(for: .thread(threadA)).first(where: { !$0.isSelected && !$0.isDisabled }) {
            store.chooseModel(pickA.route.id, for: .thread(threadA))
            check(engine.threadRecord(threadA)?.requestedModel == pickA.route.id && model.selectedModel == pickA.route.id
                  && model.routeChoice.id == pickA.route.id
                  && model.selectedThreadID == threadA && model.prompt == "Coder 草稿",
                  "A4 picking the session Coder has open moves Coder's model chip with it")
            let effort: TatwoCodexReasoningEffort = model.selectedEffort == .low ? .medium : .low
            model.selectedEffort = effort
            check(engine.threadRecord(threadA)?.requestedModel == pickA.route.id
                  && engine.threadRecord(threadA)?.requestedEffort == effort.rawValue,
                  "A4 a later Coder effort change keeps the DM's model on that session")
        } else {
            check(false, "A4 picking the session Coder has open moves Coder's model chip with it (no other route)")
        }

        // 別台上的對話：選的模型記在記憶體，下一句帶過去（引擎一起）；那台的文件不先改。
        let remoteTarget = GlobalDMTarget.thread(remoteThread.id)
        check(store.modelHeadline(for: remoteTarget) == "在主設備「Primary One」上跑；沒選就照那條記住的"
              && store.modelOptions(for: remoteTarget).allSatisfy { !$0.isDisabled },
              "A4 a primary session's menu says where it runs and leaves the judgement to that device")
        if let route = ChatRouteChoice.all.first(where: { AssistantModelRouting.engineKind(for: $0) == .codex })
            ?? ChatRouteChoice.all.first(where: { AssistantModelRouting.engineKind(for: $0) != nil }),
           let kind = AssistantModelRouting.engineKind(for: route) {
            store.chooseModel(route.id, for: remoteTarget)
            check(model.dmRemoteModelChoices[remoteThread.id] == route.id
                  && primary.threadRecord(remoteThread.id)?.requestedModel == nil
                  && model.dmRemoteModelChoices[secondThread.id] == nil,
                  "A4 a remote pick is held for that session only")
            let sentBefore = primary.sent.count
            let sent = model.sendFromDM(threadID: remoteThread.id, text: "遠端一句")
            let params = primary.sent.last?.params ?? [:]
            check(sent && primary.sent.count == sentBefore + 1
                  && params["model"] as? String == AssistantModelRouting.modelArgument(route, kind: kind)
                  && params["engine"] as? String == kind.rawValue && params["assistantRoute"] == nil,
                  "A4 the next remote turn carries the pick (model and engine), like the F-room primary turn")
            primary.finishDeliveries()
        } else {
            check(false, "A4 remote fixture route")
        }

        // ChatGPT：思考強度／模型選單照 ChatGPT 的清單；選了只改私訊框這邊（ChatGPT Space 的選擇不動）。
        let spaceModelKey = UserDefaults.standard.string(forKey: ChatGPTSpaceModel.modelKey)
        let spaceEffortKey = UserDefaults.standard.string(forKey: ChatGPTSpaceModel.effortKey)
        store.select(.chatGPT)
        store.openFloating()
        let defaultArguments = ChatGPTModelMenu.sendArguments(store.chatGPTCatalog, store.chatGPTChoice)
        check(store.chatGPTCatalog == catalog && store.modelChipTitle == "即時"
              && defaultArguments.model == nil && defaultArguments.effort == "fixture|instant",
              "A4 ChatGPT starts on ChatGPT's own default (last used)")
        let sections = ChatGPTModelMenu.sections(store.chatGPTCatalog, store.chatGPTChoice)
        check(sections.map(\.title) == ["思考強度", "版本", "其他模型"]
              && sections.first?.items.map(\.title) == ["即時", "Pro"] && sections.first?.items.first?.isSelected == true,
              "A4 ChatGPT menu: efforts of the current model, versions, other models")
        if let pro = sections.first?.items.last {
            store.chooseChatGPT(pro.choice)
        }
        check(store.modelChipTitle == "Pro"
              && ChatGPTModelMenu.sections(store.chatGPTCatalog, store.chatGPTChoice).last?.items.first?.title == "回到 ChatGPT 的預設",
              "A4 picking Pro changes the chip and offers a way back")
        store.setDraft("問 ChatGPT", for: .chatGPT)
        let fixtureFile = root.appendingPathComponent("w180-fixture.txt")
        try Data("fixture".utf8).write(to: fixtureFile)
        store.addAttachments([fixtureFile])
        check(store.attachments(for: .chatGPT).count == 1 && store.attachments(for: .chatGPT).first?.fileURL == nil
              && store.attachments(for: .chatGPT).first?.data == Data("fixture".utf8),
              "D2 ChatGPT attachments are read into memory, not referenced by path")
        let chatSent = store.send()
        let command = pod.commands.last { $0["cmd"] as? String == "send" } ?? [:]
        let files = command["files"] as? [[String: Any]] ?? []
        check(chatSent && command["effort"] as? String == "fixture|pro" && command["model"] == nil
              && files.count == 1 && files.first?["name"] as? String == "w180-fixture.txt"
              && store.attachments(for: .chatGPT).isEmpty && store.draft(for: .chatGPT).isEmpty,
              "A4/D2 ChatGPT send carries the picked effort and the file through TAP; draft and files clear")
        check(UserDefaults.standard.string(forKey: ChatGPTSpaceModel.modelKey) == spaceModelKey
              && UserDefaults.standard.string(forKey: ChatGPTSpaceModel.effortKey) == spaceEffortKey,
              "A4 ChatGPT Space's own selection is untouched")
        store.stop()
        store.close()
        let legacyPod = GlobalDMW180Pod()
        let legacyTap = ChatGPTTap(transport: legacyPod, connection: .ready)
        let legacySession = ChatGPTConversationSession(tap: legacyTap)
        let legacyStore = GlobalDMStore(defaults: defaults, chatGPT: { legacySession }, chatGPTAllowed: { true },
                                        chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false)
        legacyStore.attach(model)
        legacyStore.select(.chatGPT)
        legacyStore.openFloating()
        legacyStore.chooseChatGPT(ChatGPTModelChoice(modelID: "fixture-legacy"))
        legacyStore.setDraft("舊模型", for: .chatGPT)
        _ = legacyStore.send()
        let legacyCommand = legacyPod.commands.last { $0["cmd"] as? String == "send" } ?? [:]
        check(legacyCommand["model"] as? String == "fixture-legacy" && legacyCommand["effort"] == nil
              && legacyStore.modelChipTitle == "Legacy fixture",
              "A4 a picked older model is sent by its own id")
        legacyStore.stop()
        legacyStore.close()

        // MARK: D2 附件路徑
        store.select(.thread(remoteThread.id))
        check(store.attachmentBlock(for: remoteTarget) == "主設備上的對話暫不支援附件",
              "D2 a primary session cannot take attachments and says why")
        store.addAttachments([fixtureFile])
        check(store.attachments(for: remoteTarget).isEmpty && store.notice == "主設備上的對話暫不支援附件",
              "D2 adding a file to a primary session is refused with the note (nothing pretends to send)")
        let refusedBefore = primary.sent.count
        check(!model.sendFromDM(threadID: remoteThread.id, text: "帶附件", attachments: [fixtureFile.path])
              && primary.sent.count == refusedBefore,
              "D2 a remote send with files is not sent at all")
        check(store.attachmentBlock(for: .thread(secondThread.id)) == "「Second Two」上的對話暫不支援附件",
              "D2 the same on another paired device")
        store.select(.thread(threadB))
        check(store.attachmentBlock(for: .thread(threadB)) == nil && store.attachmentBlock(for: .thread(sub)) == nil
              && store.attachmentBlock(for: .assistant) == nil && store.attachmentBlock(for: .chatGPT) == nil,
              "D2 local sessions, sub-threads, the local assistant and ChatGPT take attachments")
        store.addAttachments([fixtureFile, fixtureFile])
        check(store.attachments(for: .thread(threadB)).map(\.fileURL) == [fixtureFile],
              "D2 a local session keeps the file path (same file once)")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BotLibraryError.invalid("fixture image")
        }
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setData(png, forType: .png)
        let pasted = store.pasteAttachment(from: board)
        let pastedFile = store.attachments(for: .thread(threadB)).last
        check(pasted && pastedFile?.isImage == true && pastedFile?.fileURL.map { fm.fileExists(atPath: $0.path) } == true
              && pastedFile?.fileURL?.path.hasPrefix(root.path) == true,
              "D2 a pasted image becomes a local attachment file (same store as the Coder composer)")
        board.releaseGlobally()
        store.setDraft("看附件", for: .thread(threadB))
        let bRows = engine.transcript(for: threadB).count
        check(!store.send() && store.attachments(for: .thread(threadB)).count == 2 && store.draft(for: .thread(threadB)) == "看附件"
              && engine.transcript(for: threadB).count == bRows + 1 && model.selectedThreadID == threadA,
              "D2 a send that did not go out (logged out) keeps the draft and the files")
        if let first = store.attachments(for: .thread(threadB)).first {
            store.removeAttachment(first.id)
        }
        check(store.attachments(for: .thread(threadB)).count == 1, "D2 × removes one attachment")

        // 送到了：本機 session 與本機助理的附件路徑真的交到送出那一步（記錄替身，不啟動引擎），之後草稿與附件清掉。
        var localSends: [(threadID: UUID, text: String, attachments: [String])] = []
        model.dmLocalSendTestDouble = { threadID, text, attachments in
            localSends.append((threadID, text, attachments))
            return true
        }
        let bPaths = store.attachments(for: .thread(threadB)).compactMap { $0.fileURL?.path }
        check(bPaths.count == 1 && store.send() && localSends.last.map {
                  $0.threadID == threadB && $0.text == "看附件" && $0.attachments == bPaths } == true
              && store.attachments(for: .thread(threadB)).isEmpty && store.draft(for: .thread(threadB)).isEmpty
              && model.selectedThreadID == threadA,
              "D2 a local session send hands the file paths over; draft and files clear")
        store.select(.assistant)
        store.addAttachments([fixtureFile])
        store.setDraft("助理看檔案", for: .assistant)
        check(store.send() && localSends.last.map {
                  $0.threadID == localAssistant && $0.text == "助理看檔案" && $0.attachments == [fixtureFile.path] } == true
              && store.attachments(for: .assistant).isEmpty && store.draft(for: .assistant).isEmpty,
              "D2 a local assistant send hands the file path over; draft and files clear")
        model.dmLocalSendTestDouble = nil

        // 帶不了附件的對象：⌘V 的剪貼簿同時有文字時照常貼文字（有檔案時說明沒附上）；純圖片只說明。
        store.select(.thread(remoteThread.id))
        let mixed = NSPasteboard.withUniqueName()
        mixed.clearContents()
        mixed.setData(png, forType: .png)
        mixed.setString("儲存格文字", forType: .string)
        let mixedHandled = store.pasteAttachment(from: mixed)
        check(!mixedHandled && store.attachments(for: remoteTarget).isEmpty && store.notice == nil,
              "D2 a blocked target still pastes the text of a text+image clipboard")
        mixed.clearContents()
        mixed.writeObjects([fixtureFile as NSURL])
        mixed.setString(fixtureFile.lastPathComponent, forType: .string)
        let fileHandled = store.pasteAttachment(from: mixed)
        check(!fileHandled && store.attachments(for: remoteTarget).isEmpty
              && store.notice == "主設備上的對話暫不支援附件；只貼上文字",
              "D2 a blocked target pastes a copied file's name as text and says the file was not attached")
        mixed.clearContents()
        mixed.setData(png, forType: .png)
        let imageHandled = store.pasteAttachment(from: mixed)
        check(imageHandled && store.attachments(for: remoteTarget).isEmpty && store.notice == "主設備上的對話暫不支援附件",
              "D2 a blocked target with an image-only clipboard only explains")
        mixed.releaseGlobally()

        // 別台：第二台送出走它的遠端引擎；失敗的說明不稱「主設備」；連不上時對象留著、一行說明、不送。
        let secondSent = model.sendFromDM(threadID: secondThread.id, text: "給第二台")
        check(secondSent && second.sent.last.map { $0.threadID == secondThread.id && $0.text == "給第二台" } == true
              && primary.sent.allSatisfy { $0.threadID != secondThread.id },
              "D2 a session on another paired device is sent through that device")
        second.finishDeliveries()
        store.select(.thread(secondThread.id))
        store.setDraft("第二台失敗", for: .thread(secondThread.id))
        second.nextFailure = RemoteHostLinkError.remoteError("invalid_params")
        _ = store.send()
        second.finishDeliveries()
        let hint = model.dmSessionHint(secondThread.id) ?? ""
        check(store.draft(for: .thread(secondThread.id)) == "第二台失敗" && hint.contains("「Second Two」")
              && !hint.contains("主設備"),
              "D2 a refused send on another device keeps the draft and names that device")
        secondReachable = false
        store.validateTarget()
        check(store.target == .thread(secondThread.id)
              && model.dmSessionNote(secondThread.id) == "這條對話在「Second Two」上，現在不能送出；草稿留著。"
              && !model.dmSessionCanSend(secondThread.id)
,
              "D2 offline device: the target stays, one line explains, no send")
        check(!store.canChooseModel && store.modelChipHelp == "那台連上後才能換模型",
              "A4 the model chip is off while that device is offline, and says why")
        check(store.iconItems(showingOthers: true).contains { $0.kind == .session(secondThread.id) && $0.letter == "SP" && $0.device == "Second Two" },
              "A3 the offline session's icon keeps its last seen project letters and device mark")
        let unseen = UUID()
        let probe = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false)
        probe.attach(model)
        probe.select(.thread(unseen))
        check(probe.iconItems(showingOthers: true).contains { $0.kind == .session(unseen) && $0.letter == "?" && $0.device != nil },
              "A3 a never-seen offline session is '?' with a device mark, not Coder's C")
        probe.select(.assistant)
        secondReachable = true

        // MARK: D2 「到 Island 核准」只帶這個對象的那一則
        // 第一則沒記討論串（例如別的來源）、第二則是別條 session 的：都不能被定位、也不重排。
        var holds: [Bool] = []
        let island = IslandNotice(fallback: { _, _, _ in nil }, holdOpen: { holds.append($0) }, log: { _ in },
                                  fullView: { _, _ in nil })
        island.hostAvailable = true
        store.select(.thread(threadB))
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        func askIsland(_ id: UUID, thread: UUID?) -> Task<IslandNotice.Decision, Never> {
            Task { @MainActor in await island.ask(title: "核准 \(id.uuidString.prefix(4))", detail: "fixture",
                                                  allowLabel: "允許", timeout: 30, requestID: id, threadID: thread) }
        }
        var asks = [askIsland(firstID, thread: nil), askIsland(secondID, thread: threadA)]
        try await Task.sleep(for: .milliseconds(80))
        check(island.pendingRequestIDs == [firstID, secondID] && island.current?.id == firstID,
              "D2 Island lists pending requests in order")
        holds.removeAll()
        check(store.revealApprovalInIsland(in: island) == nil && island.pendingRequestIDs == [firstID, secondID]
              && holds.isEmpty,
              "D2 到 Island 核准 never reveals or reorders another target's request (falls back to opening the Island)")
        asks.append(askIsland(thirdID, thread: threadB))
        try await Task.sleep(for: .milliseconds(80))
        check(island.pendingRequestIDs(threadID: threadB) == [thirdID] && island.pendingRequestIDs(threadID: threadA) == [secondID],
              "D2 Island knows which thread each tagged request came from")
        holds.removeAll()
        let revealed = store.revealApprovalInIsland(in: island)
        check(revealed == thirdID && holds.last == true && island.pendingRequestIDs == [firstID, thirdID, secondID],
              "D2 到 Island 核准 opens the Island at this target's request (with its id), next after the current one")
        island.resolve(.cancel, id: firstID)
        check(island.current?.id == thirdID, "D2 the revealed request shows right after the current one")
        check(!island.reveal(id: UUID()), "D2 an unknown request is not revealed")
        store.select(.chatGPT)
        check(store.revealApprovalInIsland(in: island) == nil, "D2 ChatGPT has no Island request to reveal")
        store.select(.assistant)
        island.resolve(.cancel, id: thirdID)
        island.resolve(.cancel, id: secondID)
        for ask in asks { _ = await ask.value }
        check(island.pendingRequestIDs.isEmpty, "D2 every fixture request is closed")

        // OS 不記錄：私訊框的模型選擇與附件都只在記憶體；UserDefaults 只有總開關與對象 id。
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        check(keys.isSubset(of: [GlobalDMStore.enabledKey, GlobalDMStore.lastTargetKey]),
              "defaults hold only the switch and last target")
        try? fm.removeItem(at: fixtureFile)

        print("W180DM SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }
}

/// 記憶體裡的假 Pod：已連上、只記下收到的指令（解出 JSON）；不啟動 CEF、不連外。
@MainActor final class GlobalDMW180Pod: ChatGPTPodTransport {
    var onEvent: ((String) -> Void)?
    var isRunning = true
    var isHosted = false
    private(set) var commands: [[String: Any]] = []
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func run(_ script: String) {
        guard let range = script.range(of: ".command("),
              let data = String(script[range.upperBound...].dropLast()).data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        commands.append(command)
    }
}
#endif
