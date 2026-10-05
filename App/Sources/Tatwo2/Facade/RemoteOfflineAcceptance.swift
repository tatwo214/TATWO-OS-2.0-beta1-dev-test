#if DEBUG
import AppKit
import Foundation

/// `TATWO2_SELFTEST=w182offline`：主設備（配對設備）斷線時，Coder 照樣列出最後同步的專案與對話、可以讀、
/// 「在這台接著聊」。只在完整隔離的 staging 跑；遠端設備是假的（走真的 RemoteDeviceSession 連上／斷線路徑，
/// 連線用給好的 get_document 結果、不開 SSH）；不送任何引擎（引擎資料夾必須是未登入）。
enum RemoteOfflineAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w182offline needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w182offline requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W182OFFLINE \(condition ? "PASS" : "FAIL") \(label)")
        }
        func settle(_ done: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return done()
        }

        // 清除走「移到垃圾桶」：自測改搬到自己的資料夾，不碰真的垃圾桶。
        let trash = staging.appendingPathComponent("w182-trash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        RemoteOfflineCache.testRetire = { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString))
        }
        defer { RemoteOfflineCache.testRetire = nil }
        let mainIOBefore = RemoteOfflineCache.mainThreadIOCount

        // 本機：一條 Coder 串 A、一個跟那台同名（大小寫不同）的專案。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let localProject = engine.newProject(name: "Local project", workdir: root.path)
        let threadA = engine.newThread(in: localProject, title: "A 串")
        let sharedLocal = engine.newProject(name: "Shared project", workdir: root.path)
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        model.select(projectID: localProject, threadID: threadA)

        // 那台（假的）：同名專案、只有那台有的專案、一般（聊天）、助理；四條串。
        let now = Date()
        func rows(_ count: Int, _ prefix: String) -> [LiveMessageRecord] {
            (0..<count).map { index in
                LiveMessageRecord(ChatMessage(role: index % 2 == 0 ? .user : .assistant, text: "\(prefix) \(index)",
                                              createdAt: now.addingTimeInterval(Double(index) - 3_600)))
            }
        }
        var remoteDoc = LiveDocumentRecord()
        let remoteGeneral = remoteDoc.ensureGeneralProject()
        let remoteAssistant = remoteDoc.ensureAssistantThread()
        let shared = LiveProjectRecord(name: "shared project", workdir: "/tmp/w182-remote-shared")
        let only = LiveProjectRecord(name: "Remote only", workdir: "/tmp/w182-remote-only")
        remoteDoc.projects += [shared, only]
        var t1 = LiveThreadRecord(projectID: shared.id, title: "同名專案的串")
        t1.messages = rows(250, "T1")
        t1.subStatus = "running"
        t1.lastOutputAt = now
        t1.updatedAt = now.addingTimeInterval(-120)
        var t2 = LiveThreadRecord(projectID: only.id, title: "只在那台的專案")
        t2.messages = rows(6, "T2") + [LiveMessageRecord(ChatMessage(role: .assistant, text: "tool output", eventKind: .toolUse,
                                                                      createdAt: now.addingTimeInterval(-60)))]
        t2.updatedAt = now.addingTimeInterval(-300)
        var t3 = LiveThreadRecord(projectID: remoteGeneral, title: "聊天那條")
        t3.messages = rows(4, "T3")
        t3.updatedAt = now.addingTimeInterval(-400)
        var t4 = LiveThreadRecord(projectID: only.id, title: "沒讀過的串")
        t4.messages = rows(3, "T4")
        t4.updatedAt = now.addingTimeInterval(-500)
        // 封存的串（離線時不列，快照也不存）與一條沒讀過、給私訊框連點測試用的串。
        var t6 = LiveThreadRecord(projectID: only.id, title: "封存的串")
        t6.messages = [LiveMessageRecord(ChatMessage(role: .assistant, text: String(repeating: "封", count: 5_000)))]
        t6.isArchived = true
        var t7 = LiveThreadRecord(projectID: only.id, title: "連點兩下的串")
        t7.messages = rows(2, "T7") + [LiveMessageRecord(ChatMessage(role: .assistant, text: String(repeating: "長", count: 3_000),
                                                                      createdAt: now.addingTimeInterval(-600)))]
        t7.updatedAt = now.addingTimeInterval(-600)
        remoteDoc.threads += [t1, t2, t3, t4, t6, t7]
        let device = DeviceRecord(id: "w182-primary-one", name: "Primary One", host: "192.0.2.10", user: "example", sshPort: 22,
                                  publicKeyFingerprint: "SHA256:w182fixture", addedAt: now.addingTimeInterval(-86_400),
                                  lastSeenAt: now.addingTimeInterval(-7_200), workdirMap: [:])
        func newerDoc(_ doc: LiveDocumentRecord) -> LiveDocumentRecord {
            var copy = doc
            copy.threads.append(LiveThreadRecord(projectID: only.id, title: "換版後的串"))
            return copy
        }
        func documentResult(_ doc: LiveDocumentRecord, revision: Int64) throws -> [String: Any] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return ["document": try JSONSerialization.jsonObject(with: encoder.encode(doc)),
                    "revision": NSNumber(value: revision), "runningThreadIDs": [String]()]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cache = RemoteOfflineCache(root: RemoteOfflineCache.defaultRoot(environment: environment))
        let docURL = cache.documentURL(device.id)
        func transcriptFile(_ threadID: UUID) -> RemoteOfflineTranscript? {
            (try? Data(contentsOf: cache.transcriptURL(device.id, threadID))).flatMap {
                try? decoder.decode(RemoteOfflineTranscript.self, from: $0)
            }
        }

        // (1) 連上：快照寫進 live/remote-cache/<設備id>/document.json。
        let session = RemoteDeviceSession(device: device, link: RemoteHostLink(environment: environment), environment: environment)
        model.w182AdoptRemoteSessionsForTest([session])
        await RemoteOfflineCache.flush()
        check(session.offlineMirror.diskLoaded && session.offlineMirror.snapshot == nil
              && model.remoteSidebarSections.first?.offlineSyncedAt == nil,
              "(0) never synced: no offline copy, nothing listed, nothing breaks")
        session.w182TestConnect(initial: try documentResult(remoteDoc, revision: 1))
        await RemoteOfflineCache.flush()
        let written = (try? Data(contentsOf: docURL)).flatMap { try? decoder.decode(RemoteOfflineSnapshot.self, from: $0) }
        check(docURL.standardizedFileURL.path == URL(fileURLWithPath: livePath).appendingPathComponent("remote-cache/w182-primary-one/document.json")
                  .standardizedFileURL.path,
              "(1) the snapshot lives in live/remote-cache/<device id>/document.json")
        check(written?.revision == 1 && written?.deviceName == "Primary One"
              && Set(written?.document.projects.map(\.name) ?? []).isSuperset(of: ["shared project", "Remote only", "一般"])
              && Set(written?.document.threads.map(\.id) ?? []).isSuperset(of: [t1.id, t2.id, t3.id, t4.id])
              && written?.document.threads.first { $0.id == t1.id }.map { $0.title == t1.title && $0.subStatus == "running"
                  && abs($0.updatedAt.timeIntervalSince(t1.updatedAt)) < 1 } == true,
              "(1) connected: projects, thread titles, status and last activity are saved")
        check(written?.document.threads.allSatisfy { $0.messages.count <= 1 } == true
              && written?.document.threads.first { $0.id == t7.id }?.messages.first.map {
                  $0.text.count == RemoteOfflineSnapshot.previewChars + 1 && $0.text.hasPrefix("長長") } == true,
              "(1) the snapshot keeps one short preview per thread (contents are stored separately)")
        check(written?.document.threads.contains { $0.id == t6.id } == false
              && written?.document.threads.contains { $0.id == remoteAssistant } == true,
              "(1) archived threads are not saved (never shown offline); the assistant's thread stays")
        // W182 R4＋R5 併入：主設備的助理那條多留最近 40 則問答（每則截到 2000 字），給斷線接手當前情。
        do {
            var assistantDoc = LiveDocumentRecord()
            let assistantID = assistantDoc.ensureAssistantThread()
            if let index = assistantDoc.threads.firstIndex(where: { $0.id == assistantID }) {
                assistantDoc.threads[index].messages = rows(45, "A")
                    + [LiveMessageRecord(ChatMessage(role: .assistant, text: String(repeating: "助", count: 3_000)))]
            }
            let slim = RemoteOfflineSnapshot(deviceID: "w182-assistant", deviceName: "A", syncedAt: now, revision: 1,
                                             document: assistantDoc).slimmed()
            let kept = slim.document.threads.first { $0.id == assistantID }?.messages ?? []
            check(kept.count == RemoteOfflineSnapshot.assistantContextRows && kept.first?.text == "A 6"
                  && kept.last?.text.count == RemoteOfflineSnapshot.assistantContextChars + 1,
                  "(1b) the primary's assistant thread keeps its last 40 turns (each capped) for the offline hand-over")
        }
        check(model.remoteSidebarSections.first.map { $0.isOnline && $0.offlineSyncedAt == nil } == true,
              "(1) online: the sidebar section is the normal one")

        // (2) 讀過的內容存起來（每條最後 200 則）。
        guard let remote = session.engine else { throw BotLibraryError.invalid("fake connect did not install the engine") }
        for thread in [t1, t2, t3] { remote.onTranscriptFetched?(thread.id, thread.messages) }
        await RemoteOfflineCache.flush()
        let t1File = transcriptFile(t1.id)
        check(t1File?.messages.count == 200 && t1File?.totalMessages == 250
              && t1File?.messages.first?.text == "T1 50" && t1File?.messages.last?.text == "T1 249",
              "(2) read content is cached: the last 200 of 250 messages")
        check(transcriptFile(t2.id)?.messages.count == 7 && transcriptFile(t3.id) != nil && transcriptFile(t4.id) == nil,
              "(2) only threads that were read are cached")

        // (3) 斷線：照樣列出專案與串，整區寫最後同步時間；狀態行寫最後活動，不留「執行中」。
        session.w182TestDisconnect()
        var section = model.remoteSidebarSections.first
        let listed = Set(section?.projects.flatMap(\.threads).map(\.id) ?? [])
        check(section?.isOnline == false && section?.offlineSyncedAt != nil && listed.isSuperset(of: [t1.id, t2.id, t3.id, t4.id]),
              "(3) offline: projects and threads are still listed with the last sync time")
        check(section?.projects.flatMap(\.threads).first { $0.id == t1.id }.map { $0.statusLine.hasPrefix("最後活動") && !$0.isRunning } == true,
              "(3) offline rows show the last activity, not a stale running state")
        check(!listed.contains(remoteAssistant), "(3) the assistant's thread stays out of the Coder list")

        // (4) 點離線的串：唯讀、有快取就顯示；不送出。
        check(model.selectRemote(deviceID: device.id, threadID: t1.id) && model.remoteOfflineReadOnly?.threadID == t1.id
              && model.remoteMode?.id == device.id && model.selectedThreadID == t1.id,
              "(4) an offline thread opens read-only")
        check(model.transcriptMessages.map(\.text) == t1.messages.suffix(200).map(\.text)
              && !model.isRemoteTranscriptLoading && model.remoteOfflineEmptyNote == nil,
              "(4) the read-only view shows the cached content")
        let localThreadCount = engine.doc.threads.count
        model.prompt = "離線時打的字"
        model.send()
        check(model.prompt == "離線時打的字" && engine.doc.threads.count == localThreadCount,
              "(4) nothing is sent from the read-only view; the draft stays")
        model.prompt = ""

        // (5) 沒快取的：寫一行說明。
        _ = model.selectRemote(deviceID: device.id, threadID: t4.id)
        check(model.transcriptMessages.isEmpty && model.remoteOfflineEmptyNote == RemoteOfflineContinue.notReadNote
              && !model.isRemoteTranscriptLoading && RemoteOfflineContinue.notReadNote == "這則離線前沒讀過，連上後才看得到",
              "(5) a thread never read before going offline says so")

        // (6) App 重開（新的 session、主設備沒開）：從磁碟讀回來，照樣列出、可以讀。
        let restarted = RemoteDeviceSession(device: device, link: RemoteHostLink(environment: environment), environment: environment)
        model.w182AdoptRemoteSessionsForTest([restarted])
        await RemoteOfflineCache.flush()
        section = model.remoteSidebarSections.first
        check(restarted.engine == nil && restarted.offlineMirror.snapshot?.revision == 1 && section?.offlineSyncedAt != nil
              && Set(section?.projects.flatMap(\.threads).map(\.id) ?? []).isSuperset(of: [t1.id, t2.id, t3.id, t4.id]),
              "(6) after an App restart with the primary off, the offline copy is listed from disk")
        check(restarted.lastSeenAt >= written?.syncedAt ?? .distantFuture, "(6) the last sync time survives the restart")
        _ = model.selectRemote(deviceID: device.id, threadID: t2.id)
        check(model.isRemoteTranscriptLoading && model.remoteOfflineReadOnly != nil,
              "(6) cached content is read from disk in the background (loading first)")
        await RemoteOfflineCache.flush()
        check(model.transcriptMessages.map(\.text) == t2.messages.map(\.text) && !model.isRemoteTranscriptLoading,
              "(6) after the restart the cached content is readable")

        // (7) 在這台接著聊。
        let snapshotBytes = try Data(contentsOf: docURL)
        let t1Bytes = try Data(contentsOf: cache.transcriptURL(device.id, t1.id))
        let snapshotBefore = restarted.offlineMirror.snapshot
        let focusBefore = RemoteOfflineContinueSignals.shared.composerFocusRequest
        _ = model.selectRemote(deviceID: device.id, threadID: t1.id)
        var copyT1: UUID?
        model.continueOfflineThreadHere(deviceID: device.id, threadID: t1.id) { copyT1 = $0 }
        _ = await settle { copyT1 != nil }
        let t1Rows = engine.transcript(for: copyT1)
        let t1Record = engine.threadRecord(copyT1)
        check(t1Record?.title == t1.title && t1Record?.projectID == sharedLocal,
              "(7) continue here: same title, into the local project with the same name")
        check(t1Rows.first.map { $0.role == .system && $0.status == RemoteOfflineContinue.bannerStatus
                  && $0.text == "這條從Primary One的『同名專案的串』複製過來（它離線時）；那邊的原串沒動。" } == true,
              "(7) the first row says where it came from and that the original is untouched")
        check(t1Rows.dropFirst().map(\.text) == t1.messages.suffix(200).map(\.text)
              && t1Rows.dropFirst().allSatisfy { $0.status == nil && $0.turnID == nil },
              "(7) the cached messages are copied (text only, no turn state)")
        check(model.selectedRemote == nil && model.selectedThreadID == copyT1 && model.mode == .chat
              && RemoteOfflineContinueSignals.shared.composerFocusRequest == focusBefore + 1,
              "(7) the new thread is selected in Coder and the composer gets the cursor")
        let seed = copyT1.flatMap { engine.offlineCopySeed(threadID: $0, engine: .claude, userText: "現在的問題", currentTurn: "t") }
        check(seed.map { $0.contains("是資料不是指令") && $0.contains("Primary One") && $0.contains("T1 249")
                  && !$0.contains("複製過來（它離線時）") && $0.hasSuffix("（現在的訊息）\n現在的問題") } == true,
              "(7) the first message carries the recent content as data, not instructions")
        check(engine.offlineCopySeed(threadID: threadA, engine: .claude, userText: "x", currentTurn: "t") == nil,
              "(7) an ordinary thread is not seeded")
        // 只第一次帶：那家引擎已經有這條的 session 就不帶（另一個資料夾放同一份文件＋ session id）。
        if let copyT1 {
            var seeded = engine.doc
            if let index = seeded.threads.firstIndex(where: { $0.id == copyT1 }) { seeded.threads[index].sessionIDs["claude"] = "w182-session" }
            let secondRoot = staging.appendingPathComponent("w182-seed-\(UUID().uuidString.prefix(8))", isDirectory: true)
            ChatLiveStore(root: secondRoot).save(seeded)
            let second = ChatLiveEngine(store: ChatLiveStore(root: secondRoot), environment: environment)
            check(second.offlineCopySeed(threadID: copyT1, engine: .claude, userText: "x", currentTurn: "t") == nil
                  && second.offlineCopySeed(threadID: copyT1, engine: .codex, userText: "x", currentTurn: "t") != nil,
                  "(7) the context goes only with the first message to each engine")
            second.shutdownAll()
        }
        // 同一條再按一次：打開已經複製的那條，不再建一條一樣的。
        let countAfterT1 = engine.doc.threads.count
        var againT1: UUID?
        _ = model.selectRemote(deviceID: device.id, threadID: t1.id)
        model.continueOfflineThreadHere(deviceID: device.id, threadID: t1.id) { againT1 = $0 }
        _ = await settle { againT1 != nil }
        check(againT1 == copyT1 && engine.doc.threads.count == countAfterT1 && model.selectedThreadID == copyT1
              && model.composerHint == "這條已經在這台接著聊過，打開那條",
              "(7) continuing the same thread again opens the earlier copy instead of making another")
        var copyT2: UUID?, copyT3: UUID?, copyT4: UUID?
        model.continueOfflineThreadHere(deviceID: device.id, threadID: t2.id) { copyT2 = $0 }
        _ = await settle { copyT2 != nil }
        model.continueOfflineThreadHere(deviceID: device.id, threadID: t3.id) { copyT3 = $0 }
        _ = await settle { copyT3 != nil }
        model.continueOfflineThreadHere(deviceID: device.id, threadID: t4.id) { copyT4 = $0 }
        _ = await settle { copyT4 != nil }
        let t2Project = engine.projectRecord(engine.threadRecord(copyT2)?.projectID)
        check(t2Project?.name == "Remote only" && t2Project?.workdir == NSHomeDirectory()
              && t2Project?.id != engine.doc.generalProjectID
              && engine.transcript(for: copyT2).first?.text.contains("原資料夾在Primary One") == true,
              "(7) no local project with that name: one is created in this home folder and the banner says where the folder is")
        check(engine.transcript(for: copyT2).dropFirst().map(\.text) == t2.messages.prefix(6).map(\.text),
              "(7) tool calls and outputs are not copied")
        check(engine.threadRecord(copyT3)?.projectID == engine.doc.generalProjectID,
              "(7) a thread that was in 一般/聊天 there goes to 聊天 here")
        check([copyT1, copyT2, copyT4].allSatisfy { $0 != nil && engine.threadRecord($0)?.projectID != engine.doc.generalProjectID },
              "(7) never into 聊天 unless it was there")
        check(engine.transcript(for: copyT4).count == 1 && engine.transcript(for: copyT4).first?.text.contains("離線前沒讀過內容") == true
              && copyT4.flatMap { engine.offlineCopySeed(threadID: $0, engine: .claude, userText: "x", currentTurn: "t") } == nil,
              "(7) a never-read thread copies the title with a note and no context")

        // (8) 原快照不變。
        check((try? Data(contentsOf: docURL)) == snapshotBytes
              && (try? Data(contentsOf: cache.transcriptURL(device.id, t1.id))) == t1Bytes
              && restarted.offlineMirror.snapshot == snapshotBefore,
              "(8) continuing here leaves the offline copy untouched")

        // (9) 私訊框：離線的那台照樣列出（灰），選到時唯讀＋「在這台接著聊」（同一個函式），Coder 選取不動。
        let suite = "ai.tatwo.selftest.w182offline.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false }, directKeys: false)
        store.attach(model)
        let candidates = model.dmSessionCandidates()
        check(candidates.contains { $0.id == t2.id && $0.isOffline && $0.deviceName == "Primary One" }
              && !candidates.contains { $0.id == remoteAssistant },
              "(9) DM lists the offline device's sessions (grey), not its assistant")
        store.select(.thread(t2.id))
        store.validateTarget()
        check(store.target == .thread(t2.id)
              && store.iconItems(showingOthers: true).contains { $0.kind == .session(t2.id) && $0.tint == .offline && $0.isEnabled },
              "(9) DM keeps the offline session as a grey, clickable icon")
        check(model.dmSessionNote(t2.id)?.contains("只能看") == true && !model.dmSessionCanSend(t2.id)
              && model.dmTranscript(for: t2.id).map(\.text) == t2.messages.map(\.text),
              "(9) DM: read-only with the cached content")
        check(model.dmOfflineEmptyText(t4.id) == RemoteOfflineContinue.notReadNote, "(9) DM: a never-read session says so")
        let coderBefore = model.selectedThreadID
        let engineSelectionBefore = engine.doc.selectedThreadID
        let action = model.dmOfflineContinueAction(t2.id, store: store)
        check(action?.title == "在這台接著聊", "(9) DM offers 在這台接著聊")
        action?.run()
        _ = await settle { store.target != .thread(t2.id) }
        if case .thread(let dmCopy) = store.target {
            check(dmCopy != t2.id && engine.transcript(for: dmCopy).dropFirst().map(\.text) == t2.messages.prefix(6).map(\.text)
                  && model.selectedThreadID == coderBefore && engine.doc.selectedThreadID == engineSelectionBefore,
                  "(9) DM continue uses the same function, switches the DM to the copy and leaves Coder alone")
        } else {
            check(false, "(9) DM continue uses the same function, switches the DM to the copy and leaves Coder alone")
        }
        // 私訊框的 chip 連點兩下：只建一條。
        let countBeforeDouble = engine.doc.threads.count
        store.select(.thread(t7.id))
        store.validateTarget()
        let doubleTap = model.dmOfflineContinueAction(t7.id, store: store)
        doubleTap?.run()
        doubleTap?.run()
        _ = await settle { store.target != .thread(t7.id) }
        await RemoteOfflineCache.flush()
        check(doubleTap != nil && engine.doc.threads.count == countBeforeDouble + 1
              && RemoteOfflineContinueSignals.shared.continuing.isEmpty,
              "(9) tapping 在這台接著聊 twice makes one copy")

        // (10) 上限。
        check(RemoteOfflineCache.standard.threads == 30 && RemoteOfflineCache.standard.messagesPerThread == 200
              && RemoteOfflineCache.standard.bytes == 20 * 1024 * 1024, "(10) limits: 30 threads, last 200 messages each, 20 MB per device")
        let capsRoot = staging.appendingPathComponent("w182-caps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let capResult = await Task.detached(priority: .userInitiated) { () -> (Int, Bool, Int, Bool, String) in
            let few = RemoteOfflineCache(root: capsRoot, limits: .init(threads: 3, messagesPerThread: 5, bytes: 10_000_000, charsPerMessage: 50))
            let ids = (0..<5).map { _ in UUID() }
            let base = Date(timeIntervalSinceNow: -600)
            let long = String(repeating: "長", count: 80)
            var kept: [RemoteOfflineCacheEntry] = []
            for (index, id) in ids.enumerated() {
                let messages = (0..<8).map { LiveMessageRecord(ChatMessage(role: .user, text: $0 == 7 ? long : "m\($0)")) }
                kept = (try? few.writeTranscript(deviceID: "caps", threadID: id, messages: messages,
                                                 savedAt: base.addingTimeInterval(Double(index)))) ?? []
            }
            let newest = Set(kept.map(\.threadID)) == Set(ids.suffix(3))
            let file = few.readTranscript(deviceID: "caps", threadID: ids[4])
            let truncated = file?.messages.last?.text ?? ""
            let small = RemoteOfflineCache(root: capsRoot, limits: .init(threads: 30, messagesPerThread: 200, bytes: 6_000, charsPerMessage: 20_000))
            var bytesKept: [RemoteOfflineCacheEntry] = []
            for index in 0..<6 {
                let messages = (0..<10).map { LiveMessageRecord(ChatMessage(role: .assistant, text: String(repeating: "x", count: 100) + "\($0)")) }
                bytesKept = (try? small.writeTranscript(deviceID: "bytes", threadID: UUID(), messages: messages,
                                                        savedAt: base.addingTimeInterval(Double(index)))) ?? []
            }
            let totalBytes = bytesKept.reduce(0) { $0 + $1.bytes }
            return (kept.count, newest && file?.messages.count == 5 && file?.totalMessages == 8, bytesKept.count,
                    totalBytes <= 6_000 && !bytesKept.isEmpty, truncated)
        }.value
        check(capResult.0 == 3 && capResult.1, "(10) over the thread limit: the oldest are dropped; each keeps its last N messages")
        check(capResult.2 < 6 && capResult.3, "(10) over the size limit: the oldest are dropped until it fits")
        check(capResult.4 == String(repeating: "長", count: 50) + RemoteOfflineCache.truncatedSuffix,
              "(10) a very long message keeps only its beginning")

        // (10) 照「最近讀過」丟：又讀到、內容沒變的那條不會先被丟；被丟掉的那條再讀到會寫回磁碟。
        let lruCache = RemoteOfflineCache(root: capsRoot, limits: .init(threads: 3, messagesPerThread: 200, bytes: 10_000_000))
        let lru = RemoteOfflineMirror(deviceID: "lru", deviceName: "LRU", cache: lruCache)
        let lruBase = Date(timeIntervalSinceNow: -1_000)
        let lruIDs = (0..<7).map { _ in UUID() }   // A B C D E F G
        func lruRecords(_ index: Int) -> [LiveMessageRecord] { [LiveMessageRecord(ChatMessage(role: .user, text: "lru \(index)"))] }
        func lruRead(_ index: Int, at offset: TimeInterval) async {
            lru.record(transcript: lruRecords(index), threadID: lruIDs[index], now: lruBase.addingTimeInterval(offset))
            await RemoteOfflineCache.flush()
        }
        func onDisk(_ index: Int) -> Bool { fm.fileExists(atPath: lruCache.transcriptURL("lru", lruIDs[index]).path) }
        await lruRead(0, at: 0); await lruRead(1, at: 1); await lruRead(2, at: 2)
        await lruRead(0, at: 40)   // A 又讀到一次，內容沒變
        await lruRead(3, at: 41)   // 超過 3 條：丟最久沒讀的 B，不是最早寫的 A
        check(onDisk(0) && !onDisk(1) && onDisk(2) && onDisk(3),
              "(10) reading a thread again counts as recent: the least recently read one is dropped, not the one read again")
        await lruRead(4, at: 42); await lruRead(5, at: 43)   // 這下 A 最久沒讀，被丟
        let droppedA = !onDisk(0) && !lru.hasTranscript(lruIDs[0])
        await lruRead(0, at: 44)   // 被丟掉的 A 又讀到（內容一樣）
        await lruRead(6, at: 45)
        check(droppedA && onDisk(0) && lru.transcript(for: lruIDs[0])?.map(\.text) == ["lru 0"] && lru.entries[lruIDs[0]] != nil,
              "(10) a thread dropped by the limit is written back to disk when it is read again")

        // (10) 那台一直換版時文件最多每 20 秒寫一次；斷線時補寫最後那份。
        let throttle = RemoteOfflineMirror(deviceID: "throttle", deviceName: "Throttle", cache: lruCache)
        let throttleAt = Date(timeIntervalSinceNow: -100)
        throttle.record(document: remoteDoc, revision: 1, now: throttleAt, force: true)
        throttle.record(document: newerDoc(remoteDoc), revision: 2, now: throttleAt.addingTimeInterval(5))
        await RemoteOfflineCache.flush()
        let throttledRevision = await Task.detached { lruCache.readSnapshot(deviceID: "throttle")?.revision }.value
        throttle.flushPendingDocument()
        await RemoteOfflineCache.flush()
        let flushed = await Task.detached { lruCache.readSnapshot(deviceID: "throttle") }.value
        check(throttledRevision == 1 && flushed?.revision == 2
              && flushed.map { abs($0.syncedAt.timeIntervalSince(throttleAt.addingTimeInterval(5))) < 1 } == true,
              "(10) a busy primary's document is written at most every 20 s; the last one is written when the link drops")

        // (10) 文件自己有上限：太大就不寫（磁碟那份不動），讀到太大的也當沒有（寫與讀同一條規則）。
        let docLimit = await Task.detached { () -> (Bool, Bool, Bool) in
            let tiny = RemoteOfflineCache(root: capsRoot, limits: .init(documentBytes: 2_000))
            var big = LiveDocumentRecord()
            let project = LiveProjectRecord(name: "Big project", workdir: "/tmp/w182-big")
            big.projects = [project]
            big.threads = (0..<40).map { LiveThreadRecord(projectID: project.id, title: "串 \($0)") }
            let snapshot = RemoteOfflineSnapshot(deviceID: "tiny", deviceName: "Tiny", syncedAt: Date(), revision: 1, document: big)
            var refused = false
            do { try tiny.writeSnapshot(snapshot.slimmed()) } catch { refused = true }
            let notWritten = !FileManager.default.fileExists(atPath: tiny.documentURL("tiny").path)
            let roomy = RemoteOfflineCache(root: capsRoot)
            _ = try? roomy.writeSnapshot(snapshot.slimmed())
            return (refused, notWritten, tiny.readSnapshot(deviceID: "tiny") == nil && roomy.readSnapshot(deviceID: "tiny") != nil)
        }.value
        check(docLimit.0 && docLimit.1 && docLimit.2,
              "(10) the document has its own cap: too big is not written, and a too-big file reads as none")

        // (11) 檔案壞了：當沒有，不當機。
        let broken = DeviceRecord(id: "w182-broken-two", name: "Broken Two", host: "192.0.2.11", user: "example", sshPort: 22,
                                  publicKeyFingerprint: "SHA256:w182broken", addedAt: now, lastSeenAt: now.addingTimeInterval(-600),
                                  workdirMap: [:])
        try fm.createDirectory(at: cache.threadsFolder(broken.id), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: cache.documentURL(broken.id))
        try Data("garbage".utf8).write(to: cache.transcriptURL(broken.id, UUID()))
        let brokenSession = RemoteDeviceSession(device: broken, link: RemoteHostLink(environment: environment), environment: environment)
        // 再開一次（記憶體是空的）：內容檔壞了要從磁碟讀才看得出來。
        let again = RemoteDeviceSession(device: device, link: RemoteHostLink(environment: environment), environment: environment)
        model.w182AdoptRemoteSessionsForTest([again, brokenSession])
        await RemoteOfflineCache.flush()
        let brokenSection = model.remoteSidebarSections.first { $0.deviceID == broken.id }
        check(brokenSession.offlineMirror.diskLoaded && brokenSession.offlineMirror.snapshot == nil
              && brokenSection?.offlineSyncedAt == nil && brokenSection?.projects.isEmpty == true,
              "(11) a broken offline file is treated as none: no crash, the plain offline line")
        try Data("garbage".utf8).write(to: cache.transcriptURL(device.id, t3.id))
        _ = model.selectRemote(deviceID: device.id, threadID: t3.id)
        _ = model.transcriptMessages
        await RemoteOfflineCache.flush()
        check(model.transcriptMessages.isEmpty && model.remoteOfflineEmptyNote == RemoteOfflineContinue.notReadNote,
              "(11) a broken content file reads as never read")

        // (12) 連回來：快照換成最新的、側欄恢復正常、開著的唯讀畫面變成可以送出。
        _ = model.selectRemote(deviceID: device.id, threadID: t2.id)
        check(model.remoteOfflineReadOnly?.threadID == t2.id, "(12) before reconnecting the view is read-only")
        var newer = remoteDoc
        let t5 = LiveThreadRecord(projectID: only.id, title: "連回來才有的串")
        newer.threads.append(t5)
        again.w182TestConnect(initial: try documentResult(newer, revision: 2))
        check(model.remoteOfflineReadOnly == nil && model.selectedRemote?.threadID == t2.id && model.remoteMode?.id == device.id,
              "(12) reconnected: the open read-only view can send again")
        section = model.remoteSidebarSections.first { $0.deviceID == device.id }
        check(section?.isOnline == true && section?.offlineSyncedAt == nil
              && section?.projects.flatMap(\.threads).contains { $0.id == t5.id } == true,
              "(12) the sidebar is back to normal with the latest threads")
        await RemoteOfflineCache.flush()
        let latest = (try? Data(contentsOf: docURL)).flatMap { try? decoder.decode(RemoteOfflineSnapshot.self, from: $0) }
        check(latest?.revision == 2 && latest?.document.threads.contains { $0.id == t5.id } == true,
              "(12) the snapshot on disk is replaced by the latest")
        check(!model.dmSessionCandidates().contains { $0.isOffline }, "(12) DM rows are live again")
        let copyRowsBefore = engine.transcript(for: copyT1).count
        model.selectLocalThread(copyT1)
        check(engine.transcript(for: copyT1).count == copyRowsBefore,
              "(12) reconnect stays quiet; nothing is merged automatically")
        if let copyT1 {
            engine.appendSystemMessage(threadID: copyT1, text: "已併回 Primary One，來源：\(t1.title)", status: "info|設備搬移")
        }
        model.selectLocalThread(copyT2)
        again.w182TestDisconnect()
        check(model.remoteSidebarSections.first { $0.deviceID == device.id }?.offlineSyncedAt != nil,
              "(12) offline again: no reconnect note, the offline copy is listed again")

        // (13) 設定 › 設備「清除這台的離線副本」：移到垃圾桶（可放回），側欄回到只有「離線」一行。
        var clearMessage: String?
        model.clearRemoteOfflineCache(deviceID: device.id) { clearMessage = $0 }
        _ = await settle { clearMessage != nil }
        await RemoteOfflineCache.flush()
        let retired = (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
        section = model.remoteSidebarSections.first { $0.deviceID == device.id }
        check(!fm.fileExists(atPath: cache.folder(device.id).path) && retired.contains { $0.hasPrefix("w182-primary-one") }
              && clearMessage?.contains("垃圾桶") == true,
              "(13) clearing moves this device's offline copy to the Trash (restorable), not deleted")
        check(again.offlineMirror.snapshot == nil && section?.offlineSyncedAt == nil && section?.projects.isEmpty == true,
              "(13) after clearing the sidebar is back to the plain offline line")

        // (13) 設定 › 設備「移除」那台：它的離線副本一起移到垃圾桶，那台的連線物件停記（晚到的不寫回來）；
        //      沒有連線物件的也清得掉。重新配對同一個 id 不會冒出舊快照。
        let removed = DeviceRecord(id: "w182-removed-three", name: "Removed Three", host: "192.0.2.12", user: "example", sshPort: 22,
                                   publicKeyFingerprint: "SHA256:w182removed", addedAt: now, lastSeenAt: now, workdirMap: [:])
        let orphanID = "w182-orphan-four"
        let removalSnapshots = [removed.id, orphanID].map {
            RemoteOfflineSnapshot(deviceID: $0, deviceName: $0, syncedAt: Date(), revision: 3, document: remoteDoc).slimmed()
        }
        await Task.detached {
            for snapshot in removalSnapshots { _ = try? cache.writeSnapshot(snapshot) }
        }.value
        let removedSession = RemoteDeviceSession(device: removed, link: RemoteHostLink(environment: environment), environment: environment)
        model.w182AdoptRemoteSessionsForTest([again, removedSession])
        await RemoteOfflineCache.flush()
        let loadedBeforeRemoval = removedSession.offlineMirror.snapshot?.revision == 3
        var removedResult: Result<Bool, Error>?
        model.retireRemoteOfflineCache(deviceID: removed.id, environment: environment) { removedResult = $0 }
        _ = await settle { removedResult != nil }
        removedSession.offlineMirror.record(document: remoteDoc, revision: 4, force: true)   // 晚到的輪詢結果
        removedSession.offlineMirror.record(transcript: t1.messages, threadID: t1.id)
        await RemoteOfflineCache.flush()
        let retiredNames = (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
        func trashed(_ result: Result<Bool, Error>?) -> Bool {
            guard case .success(true)? = result else { return false }
            return true
        }
        check(loadedBeforeRemoval && trashed(removedResult)
              && !fm.fileExists(atPath: cache.folder(removed.id).path) && retiredNames.contains { $0.hasPrefix(removed.id) }
              && removedSession.offlineMirror.isRetired && removedSession.offlineMirror.snapshot == nil
              && model.composerHint?.contains("離線副本也移到垃圾桶") == true,
              "(13) removing a device moves its offline copy to the Trash and late results do not write it back")
        var orphanResult: Result<Bool, Error>?
        model.retireRemoteOfflineCache(deviceID: orphanID, environment: environment) { orphanResult = $0 }
        _ = await settle { orphanResult != nil }
        check(trashed(orphanResult) && !fm.fileExists(atPath: cache.folder(orphanID).path) && ((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).contains { $0.hasPrefix(orphanID) },
              "(13) a removed device without a connection object is cleaned up too")
        let repaired = RemoteDeviceSession(device: removed, link: RemoteHostLink(environment: environment), environment: environment)
        model.w182AdoptRemoteSessionsForTest([again, repaired])
        await RemoteOfflineCache.flush()
        check(repaired.offlineMirror.diskLoaded && repaired.offlineMirror.snapshot == nil
              && model.remoteSidebarSections.first { $0.deviceID == removed.id }?.projects.isEmpty == true,
              "(13) pairing the same id again shows no old snapshot")

        // (14) 主執行緒不碰離線副本的檔案。
        check(RemoteOfflineCache.mainThreadIOCount == mainIOBefore, "(14) no offline-cache file I/O on the main thread")

        print("W182OFFLINE SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
