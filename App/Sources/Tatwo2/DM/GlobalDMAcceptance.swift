#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI

/// `TATWO2_SELFTEST=w179dm`：無頭驗收全域私訊框的狀態與送出路徑。只在完整隔離的 staging 環境跑，
/// 不建視窗、不啟動任何引擎（隔離的引擎資料夾必須是未登入，否則直接停下，不燒額度）。
enum GlobalDMAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w179dm needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w179dm requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        let loginStatuses = login.statuses()
        guard loginStatuses.allSatisfy({ !$0.isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W179DM \(condition ? "PASS" : "FAIL") \(label)")
        }

        // 兩條本機討論串 A、B，加一條子討論串；Coder 選著 A、輸入框有草稿。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "DM 專案", workdir: root.path)
        let threadA = engine.newThread(in: project, title: "A 串")
        let threadB = engine.newThread(in: project, title: "B 串")
        guard let sub = engine.createDiscussion(parentThreadID: threadA),
              let assistantID = engine.doc.assistantThreadID else {
            throw BotLibraryError.invalid("fixture threads missing")
        }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        // Seed the independently verified logged-out snapshot. The production
        // send preflight now uses background results instead of inspecting credentials.
        for status in loginStatuses { model.seedSendLoginStatusForSelfTest(status, checkedAt: Date()) }
        model.select(projectID: project, threadID: threadA)
        model.prompt = "Coder 草稿 A"
        let aCount = engine.transcript(for: threadA).count
        let bCount = engine.transcript(for: threadB).count
        let subCount = engine.transcript(for: sub).count

        // sendFromDM(B)：選取仍是 A、Coder 草稿不動；訊息（未登入時是錯誤）落在 B。
        let sent = model.sendFromDM(threadID: threadB, text: "給 B 的話")
        let bRows = engine.transcript(for: threadB)
        check(model.selectedThreadID == threadA && engine.doc.selectedThreadID == threadA,
              "sendFromDM(B) keeps Coder selection on A")
        check(model.prompt == "Coder 草稿 A", "sendFromDM(B) keeps the Coder composer draft")
        check(engine.transcript(for: threadA).count == aCount, "nothing lands in A")
        check(sent ? bRows.contains { $0.role == .user && $0.text == "給 B 的話" }
                   : bRows.count == bCount + 1 && bRows.last?.status == "error|登入",
              "B receives the message (logged-out: the error lands in B, not A)")
        check(!model.sendFromDM(threadID: threadB, text: " \n ") && engine.transcript(for: threadB).count == bRows.count,
              "empty text is rejected without touching B")
        // W180 D2：子討論串也能當對象（跟 Coder 一樣送；未登入時錯誤落在子串，不在 A）。
        let subSent = model.sendFromDM(threadID: sub, text: "給子串")
        let subRows = engine.transcript(for: sub)
        check(model.selectedThreadID == threadA && engine.transcript(for: threadA).count == aCount
              && (subSent ? subRows.contains { $0.role == .user && $0.text == "給子串" }
                          : subRows.count == subCount + 1 && subRows.last?.status == "error|登入"),
              "sub-thread is a DM target (W180 D2)")
        check(!model.sendFromDM(threadID: UUID(), text: "不存在"), "unknown thread is rejected")
        let assistantCount = engine.transcript(for: assistantID).count
        _ = model.sendFromDM(threadID: assistantID, text: "給助理")
        check(engine.transcript(for: assistantID).count == assistantCount + 1
              && engine.transcript(for: threadA).count == aCount && model.selectedThreadID == threadA,
              "assistant id routes to the assistant thread only")

        // 跟 Coder 輸入框一樣：PR 作業進行中的串不開新回合，說明落在那條串（私訊框看得到）；斜線指令不送。
        model.dmSelfTestSetPendingPR(threadB, true)
        let prBefore = engine.transcript(for: threadB).count
        let prRejected = !model.sendFromDM(threadID: threadB, text: "PR 中插話")
        let prRows = engine.transcript(for: threadB)
        check(prRejected && prRows.count == prBefore + 1 && prRows.last?.status == "info|PR"
              && prRows.last?.text == "PR 作業處理中，請等目前工作結束。"
              && !prRows.contains { $0.role == .user && $0.text == "PR 中插話" } && model.selectedThreadID == threadA,
              "pending PR blocks a DM send and says why in that thread")
        check(GlobalDMBubble.rows(prRows).last.map { $0.kind == .note && $0.text.hasPrefix("PR 作業處理中") } == true,
              "the DM shows the PR note")
        model.dmSelfTestSetPendingPR(threadB, false)
        let slashBefore = engine.transcript(for: threadB).count
        check(["/goal 做完", "/plan 下一步", "/pr", "/討論串 登入", "/issue 壞了", "/蒸餾"].allSatisfy {
                  !model.sendFromDM(threadID: threadB, text: $0) }
              && engine.transcript(for: threadB).count == slashBefore
              && ChatPageModel.dmCoderOnlyCommand(in: "/goal 做完") == "/goal"
              && ChatPageModel.dmCoderOnlyCommand(in: "請看 /goal") == nil,
              "Coder-only slash commands are not sent from the DM")

        // 最近的 session：排除助理、子討論串、封存；依活動排序；最多 5 條。
        var extras: [UUID] = []
        for index in 1...4 { extras.append(engine.newThread(in: project, title: "C\(index) 串")) }
        _ = engine.archive(extras[0])
        model.select(projectID: project, threadID: threadA)
        let all = model.dmSessionCandidates()
        let recent = model.dmSessionCandidates(limit: GlobalDMStore.recentLimit)
        check(recent.count == 5, "recent list is capped at 5")
        check(!all.contains { $0.id == assistantID } && all.first { $0.id == sub }?.parentID == threadA,
              "session list excludes the assistant; sub-threads hang under their parent (W180 D2)")
        check(!all.contains { $0.id == extras[0] }, "session list excludes archived threads")
        check(all.contains { $0.id == threadA } && all.contains { $0.id == threadB }
              && all.first { $0.id == threadB }?.label == "DM 專案 › B 串", "sessions are labelled 專案 › 標題")
        check(zip(all, all.dropFirst()).allSatisfy { $0.activity >= $1.activity }, "sessions sorted by last activity")

        // 私訊框狀態：預設對象、各自草稿、記住上次對象。
        let suite = "ai.tatwo.selftest.w179dm.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let offlinePod = GlobalDMAcceptancePod()
        // W194（.054）起「休眠」送出會排隊並喚醒，開框也會試著叫醒；「沒連上」改用叫醒一定失敗的 Pod 驗（休眠送出另外驗，見下面 sleepy）。
        offlinePod.failStart = true
        let offlineTap = ChatGPTTap(transport: offlinePod, connection: .failed("fixture offline"))
        let offlineSession = ChatGPTConversationSession(tap: offlineTap)
        var chatGPTCreated = 0
        let store = GlobalDMStore(defaults: defaults, chatGPT: { chatGPTCreated += 1; return offlineSession },
                                  chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() })
        store.attach(model)
        check(store.isEnabled && store.target == .assistant && !store.isPresented,
              "defaults: enabled, closed, TATWO assistant")
        store.setDraft("問助理", for: .assistant)
        store.select(.thread(threadB))
        store.setDraft("給 B", for: .thread(threadB))
        let marker = "問 ChatGPT 私訊標記 \(UUID().uuidString)"
        store.select(.chatGPT)
        store.setDraft(marker, for: .chatGPT)
        store.select(.assistant)
        check(store.draft(for: .assistant) == "問助理" && store.draft(for: .thread(threadB)) == "給 B"
              && store.draft(for: .chatGPT) == marker, "each target keeps its own draft across switches")
        check(chatGPTCreated == 0, "ChatGPT session is not created until the box shows it")
        store.select(.thread(threadB))
        check(defaults.string(forKey: GlobalDMStore.lastTargetKey) == "thread:" + threadB.uuidString
              && GlobalDMStore(defaults: defaults).target == .thread(threadB), "last target is remembered")
        check(store.title(for: .thread(threadB)) == "DM 專案 › B 串" && store.recentSessions().count == 5
              && !store.recentSessions().contains { $0.id == assistantID }, "store recent list has no assistant")
        check(store.searchSessions("C3").map(\.id) == [extras[2]], "other-project search finds a session")
        let bBefore = engine.transcript(for: threadB).count
        check(!store.send() && store.draft(for: .thread(threadB)) == "給 B"
              && engine.transcript(for: threadB).count == bBefore + 1 && model.selectedThreadID == threadA
              && model.prompt == "Coder 草稿 A", "store send to B keeps draft on failure and never moves Coder")
        store.setDraft("/plan 下一步", for: .thread(threadB))
        let slashStoreBefore = engine.transcript(for: threadB).count
        check(!store.send() && store.draft(for: .thread(threadB)) == "/plan 下一步"
              && store.notice?.contains("/plan") == true && engine.transcript(for: threadB).count == slashStoreBefore,
              "store keeps a slash-command draft and explains it belongs in Coder")
        store.select(.assistant)
        check(store.notice == nil, "switching target clears the notice")
        store.select(.thread(threadB))
        store.setDraft("給 B", for: .thread(threadB))
        store.select(.thread(extras[0]))
        store.validateTarget()
        check(store.target == .assistant, "archived target falls back to the assistant")

        // ⌥⌘：收到通知會開、再收一次會關（無頭：沒有看得到的主視窗 → 浮動框）。
        let controller = GlobalDMPanelController(store: store, hostsWindows: false)
        controller.install()
        NotificationCenter.default.post(name: .tatwoToggleGlobalDM, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        check(store.isFloatingOpen && !store.isOpen, "tatwoToggleGlobalDM opens the DM")
        NotificationCenter.default.post(name: .tatwoToggleGlobalDM, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        check(!store.isFloatingOpen && !store.isOpen, "second tatwoToggleGlobalDM closes it")
        controller.uninstall()
        NotificationCenter.default.post(name: .tatwoToggleGlobalDM, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        check(!store.isPresented, "uninstalled controller ignores the hotkey")
        typealias Toggle = GlobalDMToggleAction
        check(Toggle.resolve(enabled: true, floatingOpen: false, appActive: true, mainWindowVisible: true) == .toggleDocked
              && Toggle.resolve(enabled: true, floatingOpen: false, appActive: false, mainWindowVisible: true) == .openFloating
              && Toggle.resolve(enabled: true, floatingOpen: false, appActive: true, mainWindowVisible: false) == .openFloating
              && Toggle.resolve(enabled: true, floatingOpen: true, appActive: true, mainWindowVisible: true) == .closeFloating
              && Toggle.resolve(enabled: false, floatingOpen: false, appActive: true, mainWindowVisible: true) == .ignore,
              "hotkey decision: foreground+visible docks, otherwise floats; second press closes")
        check(Toggle.resolve(enabled: true, floatingOpen: false, dockedFocused: true, appActive: false,
                             mainWindowVisible: true) == .toggleDocked
              && Toggle.resolve(enabled: true, floatingOpen: false, dockedFocused: true, appActive: false,
                                mainWindowVisible: false) == .toggleDocked,
              "hotkey closes a focused docked box opened while another app is in front")
        store.toggleDocked()
        check(store.isOpen && !store.isFloatingOpen, "docked toggle opens the in-window box")
        store.openFloating()
        check(!store.isOpen && store.isFloatingOpen, "floating box replaces the docked one")
        store.isEnabled = false
        check(!store.isPresented && defaults.object(forKey: GlobalDMStore.enabledKey) as? Bool == false,
              "master switch off closes everything and persists")
        store.isEnabled = true

        // ChatGPT 未連上：不送出、不崩潰、草稿留著；開框時登記使用中、關掉或換對象就還。
        store.select(.chatGPT)
        store.openFloating()
        check(chatGPTCreated == 1 && offlineTap.usageCount == 1, "open box with ChatGPT target holds one TAP lease")
        check(!store.send() && store.draft(for: .chatGPT) == marker && offlineSession.messages.isEmpty
              && offlinePod.commands.isEmpty, "unconnected ChatGPT does not send and keeps the draft")
        if case .failed = offlineSession.state { check(true, "unconnected ChatGPT reports a failed state") }
        else { check(false, "unconnected ChatGPT reports a failed state") }
        store.select(.assistant)
        check(offlineTap.usageCount == 0, "switching away releases the TAP lease")
        store.select(.chatGPT)
        store.close()
        check(offlineTap.usageCount == 0 && !store.isPresented, "closing releases the TAP lease")
        // 主視窗裡的框：子面板真的在畫面上才算使用中；主視窗縮到 Dock／隱藏／關掉（控制器拿下子面板）就還，框的狀態照留。
        store.openDocked()
        check(offlineTap.usageCount == 0, "docked box without a visible main window holds no TAP lease")
        store.isDockedVisible = true
        check(offlineTap.usageCount == 1, "visible docked box with ChatGPT target holds one TAP lease")
        store.isDockedVisible = false
        check(offlineTap.usageCount == 0 && store.isOpen,
              "hiding the main window releases the TAP lease and keeps the box state")
        store.close()

        // W194（.054）：ChatGPT 休眠時送出＝排隊並喚醒網頁，不再要使用者稍後重送（Coder 與私訊框同一條規則）。
        let sleepyPod = GlobalDMAcceptancePod()
        let sleepyTap = ChatGPTTap(transport: sleepyPod, connection: .sleeping)
        let sleepySession = ChatGPTConversationSession(tap: sleepyTap)
        let sleepyStore = GlobalDMStore(defaults: defaults, chatGPT: { sleepySession }, chatGPTAllowed: { true },
                                        chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() })
        sleepyStore.attach(model)
        sleepyStore.select(.chatGPT)
        sleepyStore.openFloating()
        sleepyStore.setDraft("休眠時送出 \(UUID().uuidString)", for: .chatGPT)
        let sleepySent = sleepyStore.send()
        var sleepyQueued = false
        if case .queued = sleepySession.state { sleepyQueued = true }
        check(sleepySent && sleepyQueued && sleepyPod.startCount == 1 && sleepyTap.connection == .starting,
              "sleeping ChatGPT: send queues and wakes the page instead of failing")
        sleepyStore.close()

        // 目前 Space 把 ChatGPT 分頁關掉：不拿租約、不叫醒、不送出、不切到 ChatGPT Space。
        let offPod = GlobalDMAcceptancePod()
        let offTap = ChatGPTTap(transport: offPod, connection: .sleeping)
        let offSession = ChatGPTConversationSession(tap: offTap)
        let offStore = GlobalDMStore(defaults: defaults, chatGPT: { offSession }, chatGPTAllowed: { false })
        offStore.attach(model)
        offStore.select(.chatGPT)
        offStore.openFloating()
        offStore.setDraft("hi", for: .chatGPT)
        let modeBefore = model.mode
        offStore.openChatGPTSpace()
        check(!offStore.chatGPTAvailable && offTap.usageCount == 0 && !offStore.send() && offSession.messages.isEmpty
              && offPod.startCount == 0 && offPod.commands.isEmpty && model.mode == modeBefore && offStore.isFloatingOpen,
              "ChatGPT Space off: no lease, no wake-up, no send, no mode switch")
        offStore.close()

        let loginPod = GlobalDMAcceptancePod()
        let loginTap = ChatGPTTap(transport: loginPod, connection: .needsLogin)
        let loginSession = ChatGPTConversationSession(tap: loginTap)
        let loginStore = GlobalDMStore(defaults: defaults, chatGPT: { loginSession },
                                       chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() })
        loginStore.attach(model)
        loginStore.select(.chatGPT)
        loginStore.openFloating()
        check(loginStore.chatGPTNeedsLogin && loginSession.state == .needsLogin && loginPod.startCount == 0,
              "needs-login ChatGPT shows the login row without opening a page from the DM")
        loginStore.setDraft("hi", for: .chatGPT)
        check(!loginStore.send() && loginSession.messages.isEmpty && loginPod.commands.isEmpty,
              "needs-login ChatGPT does not send")
        loginStore.close()

        // OS 不記錄 ChatGPT 對話：草稿標記不在任何檔案，UserDefaults 只有總開關與對象 id。
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        check(keys.isSubset(of: [GlobalDMStore.enabledKey, GlobalDMStore.lastTargetKey]),
              "defaults hold only the switch and last target")
        check(!directoryContains(staging, marker: marker), "ChatGPT text is never written to disk")

        store.select(.assistant)
        let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let bubbles = GlobalDMBubble.rows([
            ChatMessage(role: .user, text: "請確認附件"),
            ChatMessage(role: .assistant, text: "已收到設計稿.png；可以在模式選擇調整下一輪。")])
        for dark in [false, true] {
            let name = dark ? "dm-composer-dark.png" : "dm-composer-light.png"
            func pane() -> some View {
                GlobalDMChatAcceptanceFrame {
                    VStack(spacing: 0) {
                        GlobalDMMessageList(bubbles: bubbles, emptyText: "")
                        GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: false, canSend: true, initiallyFocused: false)
                    }
                }
            }
            if dark {
                check(TatwoThemeSelfTestScope.saveDarkEvidence(name, size: GlobalDMLayout.box, to: artifacts, content: pane), "I3 DM composer darkAqua evidence")
            } else if let shot = GlobalDMChatAcceptance.renderSync(pane(), size: GlobalDMLayout.box) {
                GlobalDMChatAcceptance.save(shot, name, to: artifacts)
                shot.close()
                check(true, "I3 DM composer light evidence")
            } else { check(false, "I3 DM composer light evidence") }
        }
        print("W179DM SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    private static func directoryContains(_ directory: URL, marker: String) -> Bool {
        let needle = Data(marker.utf8)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return false
        }
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 8_000_000,
                  let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: needle) != nil { return true }
        }
        return false
    }
}

/// 記憶體裡的假 Pod：沒連上（isRunning=false）、記錄收到的指令；不啟動 CEF、不連外。
@MainActor final class GlobalDMAcceptancePod: ChatGPTPodTransport {
    var onEvent: ((String) -> Void)?
    var isRunning = false
    var isHosted = false
    private(set) var startCount = 0
    private(set) var commands: [String] = []
    /// W194（.054）：開框會試著叫醒 ChatGPT；要驗「真的連不上」就讓叫醒一定失敗。
    var failStart = false
    func start() throws {
        startCount += 1
        if failStart { throw TapPodError.profileUnavailable }
    }
    func stop() { isRunning = false }
    func run(_ script: String) { commands.append(script) }
}
#endif
