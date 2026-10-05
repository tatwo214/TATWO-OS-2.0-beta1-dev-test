#if DEBUG
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// `TATWO2_SELFTEST=w184chat` 的 W184 G3b 那一段：私訊框對象是 ChatGPT 時照 ChatGPT iPhone App（使用者 09-29 17:35／17:50）——
/// 頂列（頁面圓鈕照舊、≡、模型名、新對話）、左側抽屜（左緣指到滑出、按 ≡ 開、主畫面往右推；圖庫／專案／外掛程式／已排程、已釘選、最近、
/// 「聊天」＋齒輪）、點過去的對話會切換、新對話（草稿留在原本那則）、＋ 小卡（照片、檔案、貼上、外掛程式 › 工具與 App、認真思考；
/// ChatGPT Space 同一張）、「/」指令（打 / 出現、上下鍵、Enter 變小卡、Esc 只收小視窗）、空白時的建議、訊息上下緣漸出。
/// 清單用假的（GlobalDMChatGPTFakeDirectory）、對話用記憶體裡的假 Pod；不開網頁、不連外、不叫出主視窗。
/// W184 G3b 第二輪：「/」與 ＋ 只放 ChatGPT 那邊有的（ChatGPT Space 同一份規則）；審查 1–8 的行為測試（晚到的附件、讀取中／讀不到／Work、
/// 接在看到的那一支後面、同一則在 Space 送完私訊框重讀、組字與修飾鍵、Browser 拿著鍵盤時的 Esc、內橫右欄自己的控制）；主導看 PNG 的三條
/// （「/」清單真的畫出來、抽屜整個高度＋右邊一張稍暗的圓角卡、頂列「ChatGPT 6 Pro ⌄」）。
/// W184 G3c（使用者 09-30 實測 .031）：≡ 拿掉（抽屜只靠左緣、左緣不畫槓）、抽屜蓋在上面（主畫面不動、不變暗）、頂列只剩右上的臨時聊天、
/// 模型膠囊回到輸入框——這一段照新的樣子改；臨時聊天、輸入框特寫、訊息上緣頂天在 GlobalDMChatGPTG3cAcceptance.swift。
extension GlobalDMChatAcceptance {
    @MainActor static func chatGPTNavigationChecks(root: URL, model: ChatPageModel, artifacts: URL?, axWorks: Bool) async
        -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ condition: Bool, _ label: String) { results.append((condition, label)) }
        func checkIDs(_ found: Set<String>, has required: Set<String>, lacks forbidden: Set<String> = [], _ label: String) {
            guard axWorks else { return }
            let missing = required.subtracting(found).sorted()
            let extra = forbidden.intersection(found).sorted()
            check(missing.isEmpty && extra.isEmpty,
                  label + (missing.isEmpty ? "" : " — missing \(missing)") + (extra.isEmpty ? "" : " — should not be there \(extra)"))
        }
        func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
        }

        let suite = "ai.tatwo.selftest.w184g3b.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "G3b fixture: defaults suite"); return results }
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = [
            TapTool(id: "search", title: "網路搜尋", detail: "找即時的答案", rank: 2),
            TapTool(id: "picture_v2", title: "建立圖片", detail: "把想法變成圖片", rank: 1),
            TapTool(id: "research", title: "深入研究", detail: "取得詳細報告，說明很長很長很長很長很長很長很長很長很長很長很長很長", rank: 3),
            TapTool(id: "canvas", title: "Sketch", detail: "", rank: 4),
            TapTool(id: "study", title: "學習", detail: ""),
            TapTool(id: "connector:gh", title: "GitHub", detail: "程式碼與議題", isApp: true),
            TapTool(id: "connector:notion", title: "Notion", detail: "筆記", isApp: true),
        ]
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant"), TapEffort(id: "fixture|high", title: "Thinking", level: "High"),
                               TapEffort(id: "fixture|pro", title: "Pro", version: "6", level: "Pro", isMax: true, showsVersion: true)]),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|pro", tools: tools)
        let pod = GlobalDMChatGPTComposerPod()
        let tap = ChatGPTTap(transport: pod, connection: .ready)
        let session = ChatGPTConversationSession(tap: tap)
        let store = GlobalDMStore(defaults: defaults, chatGPT: { session }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: defaults)
        store.attach(model)
        store.select(.chatGPT)
        store.openFloating()
        let now = Date()
        let directory = GlobalDMChatGPTFakeDirectory(
            conversations: [TapConversation(id: "c-today", title: "今天的對話：旅行清單", updatedAt: now),
                            TapConversation(id: "c-older", title: "上週的對話：讀書計畫", updatedAt: now.addingTimeInterval(-3 * 86_400)),
                            TapConversation(id: "c-oldest", title: "更早的對話", updatedAt: now.addingTimeInterval(-40 * 86_400))],
            projects: [TapFolder(id: "p-os", title: "範例專案", kind: .project)],
            pinned: [TapFolder(id: "p-os", title: "範例專案", kind: .project), TapFolder(id: "c-pin", title: "釘選的對話", kind: .conversation)],
            suggestions: [])
        directory.projectItems["p-os"] = [TapConversation(id: "c-project", title: "專案裡的對話", updatedAt: now)]
        let size = CGSize(width: GlobalDMLayout.box.width, height: GlobalDMLayout.box.height)

        // MARK: 頂列、主畫面（建議）
        store.setDraft("", for: .chatGPT)
        let items = GlobalDMChatGPTSuggestions<GlobalDMChatGPTFakeDirectory>.items(suggestions: [], recent: directory.directoryConversations)
        let suggested = GlobalDMChatGPTSuggestions<GlobalDMChatGPTFakeDirectory>.items(
            suggestions: [TapSuggestion(id: "s1", title: "幫我規劃今天", prompt: "幫我規劃今天的行程")], recent: directory.directoryConversations)
        check(items.map(\.id) == ["conversation:c-today", "conversation:c-older", "conversation:c-oldest"]
              && suggested.map(\.id) == ["suggestion:s1"] && suggested.first?.prompt == "幫我規劃今天的行程",
              "G3b empty chat: suggestions from ChatGPT first; without them the 3 most recent conversations")
        if let shot = renderSync(mainScreen(store: store, session: session, directory: directory), size: size) {
            let settled = await settle(shot)
            save(settled, "chatgpt-main.png", to: artifacts)
            checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.temporary", "tatwo.dm.model",
                                                     "tatwo.dm.chatgpt.suggestions", "tatwo.dm.attach", "tatwo.dm.webSearch",
                                                     "tatwo.dm.voice", "tatwo.dm.input"], lacks: ["tatwo.dm.dictate", "tatwo.dm.chatgpt.newChat"],
                     "G3c drawn main screen: 臨時聊天 top right (no ≡, no model name, no new chat on the top bar); suggestions; ＋ … search, model, voice mode (no dictation)")
            settled.close()
        }
        // W184 G3c：膠囊回到輸入框（照 ChatGPT Space 的輸入框）：字跟 Space 的膠囊一樣（頂列那時前面加的「ChatGPT」拿掉）、同字級。
        // 畫出來量：私訊框那顆跟 Space 那顆（「6 Pro ⌄」：黑字「6」、紫字「Pro」、灰的 ⌄）有字的範圍一樣寬（多了「ChatGPT 」會寬 60 以上）。
        let dmPicker = renderSync(ChatGPTPickerCapsule(label: store.pickerLabel, isOpen: false, metrics: .dmPhone, identifier: "tatwo.dm.model") {},
                                  size: CGSize(width: 260, height: 44))
        let spacePicker = renderSync(ChatGPTPickerCapsule(label: store.pickerLabel, isOpen: false, metrics: .space) {},
                                     size: CGSize(width: 260, height: 44))
        let dmInk = dmPicker.map { inkWidth($0) } ?? 0, spaceInk = spacePicker.map { inkWidth($0) } ?? 0
        check(dmInk > 30 && abs(dmInk - spaceInk) <= 3 && ChatGPTComposerMetrics.dmPhone.pickerText == ChatGPTComposerMetrics.space.pickerText,
              "G3c the DM model capsule reads like ChatGPT Space's (「6 Pro ⌄」, same words and size; the top bar's 「ChatGPT」 prefix is gone) [ink \(Int(dmInk)) vs Space \(Int(spaceInk))]")
        dmPicker?.close()
        spacePicker?.close()

        // MARK: 抽屜：釘住（VoiceOver 按左緣那一格）、左緣指到（滑鼠離開就收）、Esc；W184 G3c：蓋在主畫面上（主畫面不動）
        store.toggleChatGPTDrawer()
        let pinnedOpen = store.isChatGPTDrawerOpen && store.chatGPTDrawerPinned
        store.chatGPTDrawerHoverEnded()
        let stillOpen = store.isChatGPTDrawerOpen
        let escClosed = store.dismissChatGPTLayers() && !store.isChatGPTDrawerOpen
        store.openChatGPTDrawer(pinned: false)
        let hoverOpen = store.isChatGPTDrawerOpen && !store.chatGPTDrawerPinned
        store.chatGPTDrawerHoverEnded()
        check(pinnedOpen && stillOpen && escClosed && hoverOpen && !store.isChatGPTDrawerOpen
              && GlobalDMChatGPTDrawerLayout.handleStrip == 22 && GlobalDMChatGPTDrawerLayout.width(for: size.width) <= 340,
              "G3b drawer: pinned (VoiceOver on the left edge) opens and keeps it (Esc or a click outside closes); the 22pt left edge opens it and leaving closes it")
        // W184 G3c（使用者：「左側展開時會把對話筐推去右邊修正對話筐為不動」）：抽屜蓋在上面。主畫面換成一整塊測試綠、右邊一塊紅：
        // 打開時紅塊的位置不變（主畫面沒被推走）、抽屜那一段不是綠的（抽屜在上面）；收著時整條都是主畫面。
        let drawerWidth = GlobalDMChatGPTDrawerLayout.width(for: size.width)
        store.openChatGPTDrawer(pinned: true)
        let covered = overlayProbe(store: store, directory: directory, size: size, drawerWidth: drawerWidth)
        store.closeChatGPTDrawer()
        let uncovered = overlayProbe(store: store, directory: directory, size: size, drawerWidth: drawerWidth)
        let markerStill: Bool = covered.marker.map { abs($0 - (size.width - 60)) <= 1 } ?? false
        check(markerStill && uncovered.marker == covered.marker && !covered.greenUnderDrawer && uncovered.greenUnderDrawer,
              "G3c (drawn) the drawer covers the left side and the main screen stays put (marker at \(covered.marker.map { Int($0) } ?? -1) "
              + "open and \(uncovered.marker.map { Int($0) } ?? -1) closed; 反例：以前主畫面被推開 \(Int(drawerWidth)))")
        store.openChatGPTDrawer(pinned: true)
        // 抽屜是整支手機的高度（頂列那一帶也是抽屜）；W184 G3c：抽屜外面的主畫面跟收著時一樣（不變暗、不動）。
        if let shot = renderSync(drawerPhone(store: store, session: session, directory: directory), size: size) {
            let settled = await settle(shot)
            save(settled, "chatgpt-drawer.png", to: artifacts)
            let drawerTop = luma(settled, x: drawerWidth / 2, y: 6), drawerHead = luma(settled, x: drawerWidth - 30, y: 70)
            let outside = luma(settled, x: drawerWidth + 50, y: size.height / 2)
            let closedOutside = drawerClosedLuma(store: store, session: session, directory: directory, x: drawerWidth + 50, y: size.height / 2, size: size)
            check(drawerTop > 0.97 && drawerHead > 0.97 && abs(outside - closedOutside) < 0.02,
                  "G3c (drawn) the drawer is the whole phone's height and the main screen beside it is as it was (not dimmed, not moved) "
                  + "[top \(fmt(drawerTop)) \(fmt(drawerHead)) beside \(fmt(outside)) vs closed \(fmt(closedOutside))]")
            checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.drawer.panel", "tatwo.dm.chatgpt.drawer.searchButton",
                                                     "tatwo.dm.chatgpt.drawer.library", "tatwo.dm.chatgpt.drawer.projects",
                                                     "tatwo.dm.chatgpt.drawer.plugins", "tatwo.dm.chatgpt.drawer.scheduled",
                                                     "tatwo.dm.chatgpt.drawer.conversation", "tatwo.dm.chatgpt.drawer.newChat",
                                                     "tatwo.dm.chatgpt.drawer.settings"],
                     "G3b drawn drawer: ChatGPT + search; 圖庫, 專案, 外掛程式, 已排程; 已釘選; 最近; 「聊天」 and the gear")
            settled.close()
        }
        check(directory.prepared > 0, "G3b drawer: opening it asks ChatGPT Space's list to load (once is enough)")
        store.closeChatGPTDrawer()

        // MARK: 點過去的對話＝私訊框切到那一則；草稿留在原本那則；新對話
        store.setDraft("新對話的草稿", for: .chatGPT)
        store.chooseChatGPTTool(tools[1])
        let switched = store.openChatGPTConversation("c-older")
        await waitUntil { session.messages.count == 2 }
        let getsOlder = pod.commands.contains { $0["cmd"] as? String == "get" && $0["conversationID"] as? String == "c-older" }
        check(switched && session.conversationID == "c-older" && getsOlder && session.messages.count == 2
              && store.draft(for: .chatGPT).isEmpty && store.chatGPTTool == nil && !store.isChatGPTDrawerOpen,
              "G3b drawer: a past conversation switches the DM to it (loaded into memory); its own draft (empty) comes back")
        store.setDraft("上週那則的草稿", for: .chatGPT)
        let newChat = store.newChatGPTConversation()
        check(newChat && session.conversationID == nil && session.messages.isEmpty && store.draft(for: .chatGPT) == "新對話的草稿"
              && store.chatGPTTool?.id == "picture_v2",
              "G3b new chat: clears the current one (memory only); the new chat's own unsent draft and tool card come back")
        let back = store.openChatGPTConversation("c-older")
        await waitUntil { session.messages.count == 2 }
        let olderDraft = store.draft(for: .chatGPT) == "上週那則的草稿" && store.chatGPTTool == nil
        _ = store.newChatGPTConversation()
        check(back && olderDraft && store.draft(for: .chatGPT) == "新對話的草稿",
              "G3b drafts stay with their own conversation (switching around never mixes them)")
        store.setDraft("", for: .chatGPT)
        store.chooseChatGPTTool(nil)
        // 回答中不換對話（說一句原因）。
        store.setDraft("正在回答的問題", for: .chatGPT)
        _ = store.send()
        let blocked = !store.openChatGPTConversation("c-today") && store.notice == "ChatGPT 正在回答；等它結束再換對話"
            && session.conversationID == nil
        pod.answer("回答")
        await waitUntil { !session.isSending }
        check(blocked, "G3b while ChatGPT answers the DM does not switch conversations (one sentence why)")
        // 圖庫、外掛程式、已排程：到 ChatGPT Space 打開那一頁（這裡用一個 ChatGPT 分頁關著的框，不叫出主視窗）。
        let quietSuite = "ai.tatwo.selftest.w184g3b.quiet.\(UUID().uuidString)"
        if let quietDefaults = UserDefaults(suiteName: quietSuite) {
            let quiet = GlobalDMStore(defaults: quietDefaults, chatGPT: { session }, chatGPTAllowed: { false },
                                      chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: quietDefaults)
            quiet.openChatGPTSpacePage(.library, in: directory)
            quiet.openChatGPTSpacePage(.scheduled, in: directory)
            check(directory.openedPages == [.library, .scheduled], "G3b drawer: 圖庫 and 已排程 open that page in ChatGPT Space")
            quietDefaults.removePersistentDomain(forName: quietSuite)
        }

        // MARK: W184 G3b 第二輪（審查 #3、#8）：讀取中不能送、讀不到說出來且可以重試、Work 模式的對話不接著聊
        func sends() -> Int { pod.commands.filter { $0["cmd"] as? String == "send" }.count }
        pod.holdsGet = true
        _ = store.openChatGPTConversation("c-today")
        await waitUntil { pod.heldGet != nil }
        let loadingShown = session.loadState == .loading && session.messages.isEmpty
        store.setDraft("讀取中打的字", for: .chatGPT)
        let sendsWhileLoading = sends()
        let refusedWhileLoading = !store.send() && sends() == sendsWhileLoading && store.draft(for: .chatGPT) == "讀取中打的字"
        pod.holdsGet = false
        pod.releaseGet()
        await waitUntil { session.loadState == .loaded }
        check(loadingShown && refusedWhileLoading && session.loadState == .loaded && session.messages.count == 2,
              "G3b 第二輪 a conversation still loading cannot be sent to (the draft stays); it shows up once read (反例：以前讀取中送出、讀回來被丟掉)")
        store.setDraft("", for: .chatGPT)
        pod.failsGet = true
        _ = store.openChatGPTConversation("c-oldest")
        await waitUntil { if case .failed = session.loadState { return true } else { return false } }
        let failedShown: Bool = { if case .failed = session.loadState { return true } else { return false } }()
        store.setDraft("讀不到那則打的字", for: .chatGPT)
        let sendsWhileFailed = sends()
        let refusedWhileFailed = !store.send() && sends() == sendsWhileFailed
        pod.failsGet = false
        let retried = store.openChatGPTConversation("c-oldest")   // 同一則再點一次＝重讀
        await waitUntil { session.loadState == .loaded }
        check(failedShown && refusedWhileFailed && retried && session.loadState == .loaded && session.messages.count == 2,
              "G3b 第二輪 a failed read is not shown as an empty chat: it says so, blocks sending, and the same conversation again retries")
        store.setDraft("", for: .chatGPT)
        pod.workConversations = ["c-work"]
        _ = store.openChatGPTConversation("c-work")
        await waitUntil { session.loadState == .loaded }
        store.setDraft("Work 那則接著問", for: .chatGPT)
        let sendsBeforeWork = sends()
        let workRefused = session.isWork && !store.send() && sends() == sendsBeforeWork && store.draft(for: .chatGPT) == "Work 那則接著問"
        check(workRefused, "G3b 第二輪 a Work-mode conversation from the drawer shows but is not continued here (Chat only; the draft stays)")
        store.setDraft("", for: .chatGPT)

        // MARK: W184 G3b 第二輪（審查 #4）：接在私訊框看到的那一支後面；同一則在 ChatGPT Space 送完，私訊框重讀正本
        let olderV2: [[String: Any]] = [["id": "v1", "role": "user", "text": "（語音）今天天氣如何"], ["id": "v2", "role": "assistant", "text": "晴天，最高 27 度。"]]
        pod.getOverrides["c-older"] = olderV2
        _ = store.openChatGPTConversation("c-older")
        await waitUntil { session.loadState == .loaded && session.conversationID == "c-older" }
        // 別的裝置後來又接著問過（這裡沒有通知）：私訊框送出時接在它看到的 v2 後面（多一個版本），不拿沒看過的上下文回答。
        pod.getOverrides["c-older"] = olderV2 + [["id": "v3", "role": "user", "text": "手機上接著問的"], ["id": "v4", "role": "assistant", "text": "手機上的回答"]]
        store.setDraft("接著看到的問", for: .chatGPT)
        _ = store.send()
        let firstParent = pod.commands.last { $0["cmd"] as? String == "send" }?["parentID"] as? String
        pod.answer("接在看到的那一支後面", conversationID: "c-older")
        await waitUntil { !session.isSending }
        // ChatGPT Space（同一個 TAP 上的另一個對話）在同一則送完一輪：私訊框沒在送＝自己重讀，換上最新的內容與末端。
        let spaceSide = ChatGPTConversationSession(tap: tap)
        spaceSide.open(conversationID: "c-older")
        await waitUntil { spaceSide.loadState == .loaded }
        pod.getOverrides["c-older"] = olderV2 + [["id": "v5", "role": "user", "text": "Space 那邊問的"], ["id": "v6", "role": "assistant", "text": "Space 那邊的回答"]]
        spaceSide.send("Space 那邊問的")
        await waitUntil { pod.commands.contains { $0["cmd"] as? String == "send" && $0["text"] as? String == "Space 那邊問的" } }
        pod.answer("Space 那邊的回答", conversationID: "c-older")
        await waitUntil { !spaceSide.isSending }
        await waitUntil { session.messages.last?.text == "Space 那邊的回答" }
        let refreshed = session.messages.map(\.id) == ["v1", "v2", "v5", "v6"] && tap.conversationUpdate?.conversationID == "c-older"
        store.setDraft("看過最新的再問", for: .chatGPT)
        _ = store.send()
        let secondParent = pod.commands.last { $0["cmd"] as? String == "send" }?["parentID"] as? String
        pod.answer("接在最新的後面", conversationID: "c-older")
        await waitUntil { !session.isSending }
        check(firstParent == "v2" && refreshed && secondParent == "v6",
              "G3b 第二輪 same conversation in ChatGPT Space and the DM: the DM sends after the branch it saw (parent \(firstParent ?? "nil")); "
              + "when Space finishes a turn there the DM re-reads it and continues after the newest (parent \(secondParent ?? "nil"))")

        // MARK: W184 G3b 第二輪（審查 #1）：晚到的附件回到開始收的那一則（反例：以前掉進中途換過去的那一則）
        store.setDraft("", for: .chatGPT)
        let lateData = tinyPNG()
        let lateProvider = NSItemProvider()
        lateProvider.suggestedName = "晚到的圖"
        lateProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { completion(lateData, nil) }
            return nil
        }
        let lateAccepted = store.attachChatGPT(providers: [lateProvider])
        _ = store.openChatGPTConversation("c-today")   // 還沒收到就換到另一則
        await waitUntil { store.chatGPTShelf["c-older"]?.files.isEmpty == false }
        let landedInOrigin = store.chatGPTShelf["c-older"]?.files.count == 1 && store.attachments(for: .chatGPT).isEmpty
        _ = store.openChatGPTConversation("c-older")   // 換回來：跟那一則的草稿一起回來
        await waitUntil { session.loadState == .loaded }
        check(lateAccepted && landedInOrigin && store.attachments(for: .chatGPT).count == 1,
              "G3b 第二輪 a late attachment goes back to the conversation it was dropped into, not the one switched to meanwhile")
        store.replaceChatGPTAttachments([])

        // MARK: W184 G3b 第二輪（審查 #5）：私訊框新建的對話會通知清單；抽屜搜尋先問伺服器（查全部），查不了只查已載入的（說一句）
        _ = store.newChatGPTConversation()
        store.setDraft("私訊框新開的一則", for: .chatGPT)
        _ = store.send()
        pod.answer("新的一則", conversationID: "c-dm-new")
        await waitUntil { !session.isSending }
        let announced = tap.conversationUpdate?.conversationID == "c-dm-new"
        let loaded = directory.directoryConversations
        let unloaded = TapConversation(id: "c-51", title: "第 51 則：很舊的對話", updatedAt: now.addingTimeInterval(-400 * 86_400))
        let server = GlobalDMChatGPTDrawer<GlobalDMChatGPTFakeDirectory>.results(query: "很舊", loaded: loaded, server: [unloaded], serverQuery: "很舊")
        let local = GlobalDMChatGPTDrawer<GlobalDMChatGPTFakeDirectory>.results(query: "讀書", loaded: loaded, server: nil, serverQuery: "讀書")
        let stale = GlobalDMChatGPTDrawer<GlobalDMChatGPTFakeDirectory>.results(query: "讀書", loaded: loaded, server: [unloaded], serverQuery: "很舊")
        directory.hasMore = true
        await directory.directoryLoadMore()
        check(announced && server.map(\.id) == ["c-51"] && local.map(\.id) == ["c-older"] && stale.map(\.id) == ["c-older"]
              && directory.directoryHasMore && directory.loadMoreCalls == 1,
              "G3b 第二輪 drawer list: a conversation the DM created is announced for the list; search asks ChatGPT for all (old ones too), "
              + "else only the loaded ones; 「載入更多」 loads the next page")
        _ = store.newChatGPTConversation()

        // MARK: ＋ 小卡（照 iPhone App；ChatGPT Space 同一張）
        // W184 G3b 第二輪（使用者：「快捷指令直接參照chatgpt那邊有什麼」）：只放 ChatGPT 那邊有的——私訊框自己加的「貼上剪貼簿圖片」拿掉；
        // 外掛程式那一頁照 ChatGPT 網頁「＋」的分層（有名次的前 4 個工具、最近用過的 App、其他收進「更多」），清單從沒讀到過＝一行說明。
        let dmMain = ChatGPTQuickMenu.plusSections(tools: tools, recentApps: ["connector:notion"], selectedToolID: nil,
                                                   thinking: false, showingPlugins: false)
        let spaceMain = ChatGPTQuickMenu.plusSections(tools: tools, recentApps: [], selectedToolID: nil,
                                                      thinking: true, showingPlugins: false)
        let plugins = ChatGPTQuickMenu.plusSections(tools: tools, recentApps: ["connector:notion"], selectedToolID: "search",
                                                    thinking: false, showingPlugins: true)
        let neverRead = ChatGPTQuickMenu.plusSections(tools: [], recentApps: [], selectedToolID: nil, thinking: nil, showingPlugins: true)
        check(dmMain.flatMap(\.rows).map(\.id) == ["photos", "files", "plugins", "thinking"]
              && spaceMain.flatMap(\.rows).map(\.id) == ["photos", "files", "plugins", "thinking"]
              && spaceMain.flatMap(\.rows).last?.selected == true && dmMain.flatMap(\.rows).first(where: { $0.id == "plugins" })?.opens == true,
              "G3b ＋ card like the iPhone app: 照片, 檔案, 外掛程式 ›, 認真思考 ✓ (no DM-only 貼上; ⌘V still pastes) — ChatGPT Space gets the same card")
        check(plugins.first?.rows.first?.id == "back"
              && plugins.first(where: { $0.id == "tools" })?.rows.map(\.id) == ["tool:picture_v2", "tool:search", "tool:research", "tool:canvas"]
              && plugins.first(where: { $0.id == "apps" })?.rows.map(\.id) == ["tool:connector:notion"]
              && plugins.first(where: { $0.id == "more" })?.rows.map(\.id) == ["tool:study", "tool:connector:gh"]
              && plugins.flatMap(\.rows).first(where: { $0.id == "tool:search" })?.selected == true
              && neverRead.map(\.id) == ["back", "none"] && neverRead.last?.rows.first?.info == true,
              "G3b ＋ › 外掛程式 turns the card into ChatGPT's own tool and App list, layered like ChatGPT's ＋ (top 4 tools, recent Apps, 更多); never read = one line, no made-up list")
        store.isChatGPTModelCardOpen = true
        store.setChatGPTPlusOpen(true)
        let cardClosed = !store.isChatGPTModelCardOpen
        store.pickChatGPTPlus("plugins")
        let onPlugins = store.chatGPTPlusShowingMore
        store.pickChatGPTPlus("back")
        let offPlugins = !store.chatGPTPlusShowingMore
        store.pickChatGPTPlus("tool:picture_v2")
        check(cardClosed && onPlugins && offPlugins && store.chatGPTTool?.id == "picture_v2" && !store.isChatGPTPlusOpen,
              "G3b ＋ card actions: opening it closes the model card; 外掛程式 › and ‹ back; picking a tool makes the tool card and closes")
        store.chooseChatGPTTool(nil)
        let thinkingTarget = store.thinkingEffortID
        let startsHard = store.thinkingHard
        store.pickChatGPTPlus("thinking")
        let fast = !store.thinkingHard && store.pickerEffortID == "fixture|instant"
        store.pickChatGPTPlus("thinking")
        check(thinkingTarget == "fixture|high" && startsHard && fast && store.thinkingHard && store.pickerEffortID == "fixture|high",
              "G3b 認真思考: ticked = the model's thinking level or higher (Pro counts); unticking picks the fastest, ticking picks thinking")
        store.setChatGPTPlusOpen(true)
        check(store.dismissChatGPTLayers() && !store.isChatGPTPlusOpen && store.isFloatingOpen,
              "G3b Esc closes the ＋ card only (the DM stays open)")
        if let shot = renderSync(quickMenuFrame(ChatGPTQuickMenu(sections: dmMain, metrics: .dmPhone, identifier: "tatwo.dm.plusMenu") { _ in }),
                                 size: CGSize(width: 340, height: 360)) {
            save(shot, "chatgpt-plus-card.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.plusMenu", "chatgpt.quickMenu.photos", "chatgpt.quickMenu.files",
                                                  "chatgpt.quickMenu.plugins", "chatgpt.quickMenu.thinking"],
                     "G3b drawn ＋ card (custom, not a system menu)")
            shot.close()
        }
        if let shot = renderSync(quickMenuFrame(ChatGPTQuickMenu(sections: plugins, metrics: .dmPhone, identifier: "tatwo.dm.plusMenu") { _ in }),
                                 size: CGSize(width: 340, height: 420)) {
            save(shot, "chatgpt-plus-plugins.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["chatgpt.quickMenu.back", "chatgpt.quickMenu.tool:research", "chatgpt.quickMenu.tool:connector:gh"],
                     "G3b drawn ＋ › 外掛程式 (tools and Apps, one line each, long descriptions cut)")
            let rowHeight = ChatGPTComposerMetrics.dmPhone.menuDetailRowHeight
            check(shot.size.height > 0 && rowHeight == DMPhone.touch + 16,
                  "G3b ＋ card rows stay one line (title + one cut description; fixed row height \(Int(rowHeight)))")
            shot.close()
        }

        // MARK: 「/」指令（W184 G3b 第二輪：ChatGPT Space 的輸入框同一份規則、同一個清單元件、同一份資料）
        store.setDraft("/", for: .chatGPT)
        let slashAll = store.chatGPTSlashOpen && store.chatGPTSlashTools.map(\.id) == ["picture_v2", "search", "research", "canvas", "study",
                                                                                          "connector:gh", "connector:notion"]
        store.setDraft("/sea", for: .chatGPT)
        let slashFiltered = store.chatGPTSlashTools.map(\.id) == ["search", "research"]
        store.setDraft("/", for: .chatGPT)
        store.chatGPTSlashIndex = 0
        let down = store.handleChatGPTSlashKey(.next) && store.chatGPTSlashHighlight == 1
        let up = store.handleChatGPTSlashKey(.prev) && store.chatGPTSlashHighlight == 0
        // 第一列再按上一列不吃（交還輸入框）。
        let topFree = !store.handleChatGPTSlashKey(.prev) && store.chatGPTSlashHighlight == 0
        _ = store.handleChatGPTSlashKey(.next)
        let entered = store.handleChatGPTSlashKey(.commit) && store.chatGPTTool?.id == "search" && store.draft(for: .chatGPT).isEmpty
            && !store.chatGPTSlashOpen
        let grouped = ChatGPTSlash.sections(ChatGPTQuickMenu.slashTools(tools, query: ""), catalogEmpty: false, selectedID: nil)
        check(slashAll && slashFiltered && down && up && topFree && entered
              && grouped.map(\.id) == ["tools", "apps"] && grouped.map(\.title) == ["工具", "App"],
              "G3b 「/」: typing / at the start opens ChatGPT's own list (tools in ChatGPT's order, then Apps); ↓↑ move (↑ on the first row is left to the text cursor); Enter makes the tool card and clears 「/…」")
        store.chooseChatGPTTool(nil)
        store.setDraft("/", for: .chatGPT)
        let escSlash = store.dismissChatGPTLayers() && !store.chatGPTSlashOpen && store.draft(for: .chatGPT) == "/" && store.isFloatingOpen
        store.setDraft("/r", for: .chatGPT)
        let reopens = store.chatGPTSlashOpen
        store.setDraft("/", for: .chatGPT)
        // 主導看 PNG：Esc 收過一次、之後草稿改過又回到「/」＝那次收起作廢，清單照樣出來（以前會一直收著，PNG 就拍不到清單）。
        let reopensAtSlash = store.chatGPTSlashOpen
        store.setDraft("hello /r", for: .chatGPT)
        let notMidText = !store.chatGPTSlashOpen && !store.handleChatGPTSlashKey(.commit)
        store.setDraft("/re x", for: .chatGPT)
        let notAfterSpace = !store.chatGPTSlashOpen
        check(escSlash && reopens && reopensAtSlash && notMidText && notAfterSpace,
              "G3b 「/」: Esc closes only the list (draft and DM stay; typing again reopens, back to 「/」 too); not in mid-text or after a space; Enter then sends normally")
        // ChatGPT 的清單從沒讀到過：「/」照樣出來，只有一行說明（不自己編預設清單）；Enter 不把「/」當訊息送出。
        let bareSuite = "ai.tatwo.selftest.w184g3b.bare.\(UUID().uuidString)"
        if let bareDefaults = UserDefaults(suiteName: bareSuite) {
            let bareSession = ChatGPTConversationSession(tap: tap)
            let bare = GlobalDMStore(defaults: bareDefaults, chatGPT: { bareSession }, chatGPTAllowed: { true },
                                     chatGPTCatalog: { Just(ChatGPTModelCatalog()).eraseToAnyPublisher() }, directKeys: false,
                                     recentApps: bareDefaults)
            bare.attach(model)
            bare.select(.chatGPT)
            bare.openFloating()
            bare.setDraft("/", for: .chatGPT)
            let notice = ChatGPTSlash.sections([], catalogEmpty: true, selectedID: nil)
            check(bare.chatGPTSlashOpen && bare.chatGPTSlashTools.isEmpty && bare.handleChatGPTSlashKey(.commit) && !bare.handleChatGPTSlashKey(.next)
                  && notice.first?.rows.map(\.id) == ["none"] && notice.first?.rows.first?.info == true,
                  "G3b 第二輪 「/」 before ChatGPT's list was ever read: one line saying so (no made-up list); Enter does not send 「/」")
            bare.close()
            bareDefaults.removePersistentDomain(forName: bareSuite)
        }
        // 主導看 PNG：「/」清單真的畫在畫面上（比同一個畫面沒有「/」時：輸入框上面那一塊多出一大片清單的白底）。
        store.setDraft("/", for: .chatGPT)
        let listRect = CGRect(x: 40, y: 260, width: 240, height: 200)
        if let shot = renderSync(GlobalDMChatAcceptanceFrame {
            GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory)
        }, size: size) {
            let settled = await settle(shot)
            save(settled, "chatgpt-slash.png", to: artifacts)
            let withList = share(settled, in: listRect) { $0 > 0.985 }
            settled.close()
            store.setDraft("", for: .chatGPT)
            var withoutList = 1.0
            if let plain = renderSync(GlobalDMChatAcceptanceFrame {
                GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory)
            }, size: size) {
                let settledPlain = await settle(plain)
                withoutList = share(settledPlain, in: listRect) { $0 > 0.985 }
                settledPlain.close()
            }
            check(withList > 0.3 && withoutList < 0.1,
                  "G3b 第二輪 (drawn) the 「/」 list is really on screen above the input [white \(fmt(withList)) vs \(fmt(withoutList)) without 「/」]")
        }
        store.setDraft("", for: .chatGPT)

        // MARK: W184 G3b 第二輪（審查 #6）：真的鍵盤事件——組字中全部交回輸入法；只有沒修飾鍵的 ↑↓（與 Enter）給「/」清單，←→、Shift 選取照常
        let keyLog = GlobalDMChatGPTKeyLog()
        let probe = ChatComposerTextView(text: .constant("/se"), contentHeight: .constant(24), isFocused: false, placeholder: "",
                                         isMonospaced: false, minimumHeight: 24, maximumHeight: 120, onSubmit: {}, onFocusChange: { _ in },
                                         onSuggestionKey: { key in keyLog.keys.append(key); return true }, suggestionKeysVerticalOnly: true)
        if let shot = renderSync(probe.frame(width: 300, height: 40), size: CGSize(width: 300, height: 40)),
           let text = firstTextView(in: shot.host) {
            shot.window.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            if let event = keyEvent(125, 0xF701, in: shot.window) { text.keyDown(with: event) }                    // ↓
            let afterDown = keyLog.keys
            if let event = keyEvent(123, 0xF702, flags: [.shift], in: shot.window) { text.keyDown(with: event) }  // Shift＋←：選取
            let selectedByShift = text.selectedRange().length
            if let event = keyEvent(123, 0xF702, in: shot.window) { text.keyDown(with: event) }                    // ←：移游標
            let afterLeft = keyLog.keys
            text.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let composing = text.hasMarkedText()
            if let event = keyEvent(125, 0xF701, in: shot.window) { text.keyDown(with: event) }                    // 組字中 ↓：給輸入法
            let afterMarked = keyLog.keys
            text.unmarkText()
            if let event = keyEvent(126, 0xF700, in: shot.window) { text.keyDown(with: event) }                    // ↑
            check(afterDown == [.next] && selectedByShift == 1 && afterLeft == [.next] && composing && afterMarked == [.next]
                  && keyLog.keys == [.next, .prev],
                  "G3b 第二輪 real key events: only plain ↓↑ reach the 「/」 list; Shift＋← selects text, ← moves the caret, and while composing (IME) the keys go to the input method")
            shot.close()
        } else {
            check(false, "G3b 第二輪 fixture: the input's NSTextView")
        }

        // MARK: W184 G3b 第二輪（審查 #7）：內橫右欄的網頁（CEF）拿著鍵盤、滑鼠指到左緣開了抽屜：Esc 先收抽屜，下一個 Esc 才給網頁
        let escWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        escWindow.isReleasedWhenClosed = false
        let pageHost = GlobalDMChatGPTFakePageHost(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let page = GlobalDMChatGPTFakePage(frame: pageHost.bounds)
        pageHost.addSubview(page)
        escWindow.contentView = pageHost
        escWindow.makeFirstResponder(page)
        store.browsesBeside = true
        store.showBrowser()
        store.openChatGPTDrawer(pinned: false)
        let drawerUp = store.isChatGPTDrawerOpen && store.isBrowsingBeside && escWindow.firstResponder === page
        var firstRouted: NSEvent?
        var secondRouted: NSEvent?
        if let esc = keyEvent(53, 0x1B, in: escWindow) {
            firstRouted = GlobalDMPanelController.routeEscape(esc, window: escWindow, floating: nil, store: store, form: .innerLandscape)
            let closedFirst = !store.isChatGPTDrawerOpen
            secondRouted = GlobalDMPanelController.routeEscape(esc, window: escWindow, floating: nil, store: store, form: .innerLandscape)
            check(drawerUp && firstRouted == nil && closedFirst && secondRouted != nil,
                  "G3b 第二輪 Esc while the web page (CEF) holds the keyboard: the visible ChatGPT drawer closes first; the next Esc goes to the page")
        } else {
            check(false, "G3b 第二輪 fixture: an Esc key event")
        }
        escWindow.contentView = nil
        escWindow.close()
        store.select(.chatGPT)
        store.browsesBeside = false

        // MARK: W184 G3b 第二輪（審查 #2）：內橫右欄的 ChatGPT 有自己的控制（綁右欄自己的 store）；模型面板開在右欄裡
        // W184 G3c：右欄自己那一排只剩臨時聊天（蓋在訊息列表上）；模型膠囊在右欄的輸入框裡，面板浮在它上面。
        let rightSuite = "ai.tatwo.selftest.w184g3b.right.\(UUID().uuidString)"
        if let rightDefaults = UserDefaults(suiteName: rightSuite) {
            let rightSession = ChatGPTConversationSession(tap: tap)
            let right = GlobalDMStore(defaults: rightDefaults, chatGPT: { rightSession }, chatGPTAllowed: { true },
                                      chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: rightDefaults)
            right.attach(model)
            right.select(.chatGPT)
            right.openFloating()
            let columnSize = CGSize(width: 466, height: 610)
            // 內橫右欄本身（GlobalDMDuoBox 右欄不是 Browser 時畫的就是這一個）。
            func rightColumn() -> AnyView {
                AnyView(GlobalDMBox(store: right, model: model, surface: .floating, role: .duoTrailing)
                    .frame(width: columnSize.width, height: columnSize.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
            }
            // 右上臨時聊天那一顆（上 10、44 見方、右邊留 20）；面板（思考強度那一頁，白底）浮在輸入框裡的膠囊上面：量膠囊上方那一塊。
            let headerRect = CGRect(x: columnSize.width - 20 - 44, y: 10, width: 44, height: 44)
            let panelRect = CGRect(x: 200, y: 380, width: 250, height: 150)
            var headerInk = 0.0, panelBefore = 0.0, panelAfter = 0.0
            if let shot = renderSync(rightColumn(), size: columnSize) {
                let settled = await settle(shot)
                save(settled, "chatgpt-duo-right.png", to: artifacts)
                headerInk = share(settled, in: headerRect) { $0 < 0.45 }
                panelBefore = share(settled, in: panelRect) { $0 > 0.985 }
                checkIDs(identifiers(in: settled), has: ["tatwo.dm.chatgpt.trailingBar", "tatwo.dm.chatgpt.temporary", "tatwo.dm.model"],
                         lacks: ["tatwo.dm.chatgpt.newChat"],
                         "G3c drawn right column: its own 臨時聊天 on top and its own model capsule in the composer")
                settled.close()
            }
            right.toggleChatGPTModelCard()
            let rightCardOpen = right.isChatGPTModelCardOpen && !store.isChatGPTModelCardOpen
            if let shot = renderSync(rightColumn(), size: columnSize) {
                let settled = await settle(shot)
                save(settled, "chatgpt-duo-right-model.png", to: artifacts)
                panelAfter = share(settled, in: panelRect) { $0 > 0.985 }
                settled.close()
            }
            check(headerInk > 0.01 && rightCardOpen && panelAfter > panelBefore + 0.3,
                  "G3b 第二輪 (drawn) the 內橫 right column's ChatGPT: its own 臨時聊天 on top, and its own model capsule opens its own panel above it "
                  + "[header ink \(fmt(headerInk)); panel white \(fmt(panelBefore))→\(fmt(panelAfter))] (反例：以前右欄沒有模型入口)")
            right.closeChatGPTModelCard()
            right.close()
            rightDefaults.removePersistentDomain(forName: rightSuite)
        } else {
            check(false, "G3b 第二輪 fixture: right column defaults suite")
        }

        // MARK: 輸入框特寫（W184 G3b 追加，使用者：「輸入筐字體太大跟chatgpt classic一樣即可 並且只留ai對話 不用麥克風輸入法」）
        // 打的字與佔位字＝ChatGPT Space 輸入框的字級（ChatGPTComposerMetrics.space.inputText，量畫出來的輸入框本身）；沒有聽寫鈕，
        // 語音模式／送出照舊。沒字、有字各一張。
        let spaceInput = ChatGPTComposerMetrics.space.inputText
        var composerSizes: [[CGFloat]] = []
        for (name, text) in [("chatgpt-composer-empty.png", ""), ("chatgpt-composer-text.png", "幫我把今天的待辦排一下優先順序")] {
            store.setDraft(text, for: .chatGPT)
            if let shot = renderSync(GlobalDMComposer(store: store, placeholder: "問問 ChatGPT", isRunning: false, canSend: true,
                                                      chatGPTSession: session),
                                     size: CGSize(width: size.width, height: 150)) {
                let settled = await settle(shot)
                save(settled, name, to: artifacts)
                composerSizes.append(inputPointSizes(in: settled.host))
                checkIDs(identifiers(in: settled), has: ["tatwo.dm.input", "tatwo.dm.attach", "tatwo.dm.webSearch", "tatwo.dm.model",
                                                         text.isEmpty ? "tatwo.dm.voice" : "tatwo.dm.send"],
                         lacks: ["tatwo.dm.dictate"],
                         "G3b 追加 drawn composer (\(text.isEmpty ? "empty" : "typed")): ＋ … search, model (G3c) and voice mode／send; no dictation button")
                settled.close()
            }
        }
        check(spaceInput == 15 && ChatGPTComposerMetrics.dmPhone.inputText == spaceInput && composerSizes.count == 2
              && composerSizes.allSatisfy { $0 == [spaceInput] },
              "G3b 追加 drawn: the DM ChatGPT input (typed text and placeholder) is ChatGPT Space's size [DM \(composerSizes) vs Space \(Int(spaceInput))pt; was 17]")
        store.setDraft("", for: .chatGPT)

        // MARK: 上下緣漸出（所有對象的訊息列表；每一則照它在捲動區裡的位置自己淡出，不遮整個 ScrollView）
        let vp: CGFloat = 400
        func alpha(_ y: CGFloat, top: CGFloat = 1, bottom: CGFloat = 1) -> Double {
            GlobalDMMessageList.fadeAlpha(y: y, viewport: vp, top: top, bottom: bottom)
        }
        let ramp = [alpha(0), alpha(12), alpha(24), alpha(200), alpha(vp - 12), alpha(vp), alpha(-5)]
        let ends = [alpha(0, top: 0), alpha(vp, bottom: 0), alpha(0, top: 0.5)]
        let crossing = GlobalDMMessageList.fadeStops(rowMinY: -12, rowHeight: 60, viewport: vp, top: 1, bottom: 1).map(\.location)
        check(ramp == [0, 0.5, 1, 1, 0.5, 0, 0] && ends == [1, 1, 0.5] && crossing == [0, 0.2, 0.6, 1],
              "G3b fade mask: the top and bottom 24pt ramp in (not a hard cut); a message crossing the edge fades inside itself [\(ramp) \(crossing)]")
        // 真的畫一則被遮的（純 SwiftUI 的遮罩；捲動區上緣在它裡面 12 的地方）：上面淡、下面完整。
        let sample = Color.black.frame(width: 40, height: 200).mask {
            LinearGradient(stops: GlobalDMMessageList.fadeStops(rowMinY: -12, rowHeight: 200, viewport: vp, top: 1, bottom: 1),
                           startPoint: .top, endPoint: .bottom)
        }
        if let shot = renderSync(sample, size: CGSize(width: 40, height: 200)) {
            let top = darkness(shot, y: 2), half = darkness(shot, y: 24), inner = darkness(shot, y: 60)
            check(top < 0.2 && half > 0.3 && half < 0.7 && inner > 0.9,
                  "G3b fade mask (drawn): a message under the top edge fades in, below 24 it is whole [\(fmt(top))→\(fmt(half))→\(fmt(inner))]")
            shot.close()
        }
        // 強度（每一則自己算）：第一則在內容最上面（上緣 = listTop）不淡、捲開 12 淡一半、24 以上全淡；最後一則在最下面（下緣 = 底 − listBottom）
        // 不淡；中間的每一則兩邊都照常淡。
        let padTop = GlobalDMChatLayout.listTop, padBottom = GlobalDMChatLayout.listBottom
        func strength(_ minY: CGFloat, _ maxY: CGFloat, first: Bool, last: Bool) -> [CGFloat] {
            let value = GlobalDMMessageList.fadeStrength(rowMinY: minY, rowMaxY: maxY, viewport: vp, isFirst: first, isLast: last)
            return [value.top, value.bottom]
        }
        let strengths = [strength(padTop, padTop + 40, first: true, last: false), strength(padTop - 12, padTop + 28, first: true, last: false),
                         strength(padTop - 60, padTop - 20, first: true, last: false),
                         strength(vp - padBottom - 40, vp - padBottom, first: false, last: true),
                         strength(vp - padBottom - 28, vp - padBottom + 12, first: false, last: true), strength(100, 140, first: false, last: false),
                         strength(padTop, vp - padBottom, first: true, last: true)]
        check(strengths == [[0, 1], [0.5, 1], [1, 1], [1, 0], [1, 0.5], [1, 1], [0, 0]],
              "G3b fade: at the bottom the bottom edge is not faded (last message fully clear); at the top the top edge is not; in between both fade [\(strengths)]")
        let long = (0..<14).map { index in
            TapMessage(id: "u\(index)", role: .user, text: String(repeating: "很長的一段自己的訊息。", count: 6) + "#\(index)")
        }
        GlobalDMMessageList.rowTopsForSelfTest = [:]   // 只看這一個列表量到的
        if let shot = renderSync(GlobalDMChatAcceptanceFrame {
            GlobalDMMessageList(bubbles: GlobalDMBubble.rows(long, answering: false), emptyText: "", fallbackAvatar: .chatGPT, chatGPTLook: true)
        }, size: size) {
            let settled = await settle(shot)
            save(settled, "chatgpt-fade.png", to: artifacts)
            // 捲到最底（預設）：上緣淡出（文字淡出，不是一刀切）；內容照樣畫得出來（遮罩沒把整個列表遮成透明）。
            // 量右半邊（自己的泡泡靠右、深色底），幾條線平均，避開泡泡之間的空隙。
            func band(_ from: CGFloat, _ to: CGFloat) -> Double {
                let ys = stride(from: from, to: to, by: 2).map { darkness(settled, y: $0, xFrom: 0.55) }
                return ys.reduce(0, +) / Double(max(1, ys.count))
            }
            let listTop = DMPhone.headerHeight
            let topBand = band(listTop, listTop + 10), middleBand = band(size.height / 2 - 60, size.height / 2 + 60)
            // 遮罩量到的位置真的跟著捲動（有一則的上緣在捲動區外面＝負的）。
            let highest = GlobalDMMessageList.rowTopsForSelfTest.values.min()
            check(middleBand > 0.3 && topBand < middleBand * 0.6 && (highest ?? 0) < 0,
                  "G3b (drawn) scrolled to the bottom: messages still draw and the top edge fades [top \(fmt(topBand)) middle \(fmt(middleBand)) highest row \(highest.map { Int($0) } ?? 0) of \(GlobalDMMessageList.rowTopsForSelfTest.count) rows]")
            settled.close()
        }

        store.close()
        return results
    }

    /// 主畫面：頂列（頁面圓鈕、W184 G3c 右上的臨時聊天）＋ChatGPT 那一欄（空白＝建議＋輸入框）；欄在頂列底下一層、
    /// 訊息列表往上延伸頂列的高度（同 GlobalDMPhoneBox 的疊法；清單用假的，所以不直接畫 GlobalDMPhoneBox）。
    @MainActor private static func mainScreen(store: GlobalDMStore, session: ChatGPTConversationSession,
                                              directory: GlobalDMChatGPTFakeDirectory) -> some View {
        VStack(spacing: 0) {
            GlobalDMTopBar(store: store, form: .outerPortrait)
                .environment(\.globalDMChatGPTTopWidth, GlobalDMLayout.box.width)
            GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory)
                .zIndex(-1)
                .environment(\.globalDMListBleed, DMPhone.headerHeight)
        }
        .frame(width: GlobalDMLayout.box.width, height: GlobalDMLayout.box.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DMPhone.screenRadius, style: .continuous))
    }

    /// 抽屜打開的整支手機（頂列＋ChatGPT 那一欄，外面包抽屜那一層；同 GlobalDMPhoneBox 的疊法），裁成框的 52 圓角。
    @MainActor private static func drawerPhone(store: GlobalDMStore, session: ChatGPTConversationSession,
                                               directory: GlobalDMChatGPTFakeDirectory) -> some View {
        GlobalDMChatGPTDrawerHost(store: store, enabled: true, directory: directory) {
            VStack(spacing: 0) {
                GlobalDMTopBar(store: store, form: .outerPortrait)
                    .environment(\.globalDMChatGPTTopWidth, GlobalDMLayout.box.width)
                GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory)
                    .zIndex(-1)
                    .environment(\.globalDMListBleed, DMPhone.headerHeight)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: GlobalDMLayout.box.width, height: GlobalDMLayout.box.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DMPhone.screenRadius, style: .continuous))
    }

    /// 同一支手機抽屜收著時，主畫面某一點的亮度（W184 G3c：跟抽屜打開時抽屜外面的同一點比，要一樣——不變暗、不動）。
    @MainActor private static func drawerClosedLuma(store: GlobalDMStore, session: ChatGPTConversationSession,
                                                    directory: GlobalDMChatGPTFakeDirectory, x: CGFloat, y: CGFloat, size: CGSize) -> Double {
        let wasOpen = store.isChatGPTDrawerOpen, pinned = store.chatGPTDrawerPinned
        store.closeChatGPTDrawer()
        defer { if wasOpen { store.openChatGPTDrawer(pinned: pinned) } }
        guard let shot = renderSync(drawerPhone(store: store, session: session, directory: directory), size: size) else { return 0 }
        defer { shot.close() }
        return luma(shot, x: x, y: y)
    }

    /// 一個點的亮度（0＝黑、1＝白），x、y 用點。
    @MainActor static func luma(_ rendered: Rendered, x: CGFloat, y: CGFloat) -> Double {
        let rep = rendered.bitmap
        let scale = CGFloat(rep.pixelsWide) / rendered.size.width
        let px = min(max(0, Int(x * scale)), rep.pixelsWide - 1), py = min(max(0, Int(y * scale)), rep.pixelsHigh - 1)
        guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return 0 }
        return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    /// 一塊區域裡符合條件（亮度判斷）的像素佔多少（0–1）；每 2 點取一個。
    @MainActor static func share(_ rendered: Rendered, in rect: CGRect, where test: (Double) -> Bool) -> Double {
        var hits = 0, total = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                total += 1
                if test(luma(rendered, x: x, y: y)) { hits += 1 }
            }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    /// 畫面裡第一個 NSTextView（輸入框本身）。
    @MainActor static func firstTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }

    /// 真的鍵盤事件（keyDown），方向鍵帶 AppKit 的功能鍵字元。
    @MainActor static func keyEvent(_ keyCode: UInt16, _ scalar: UInt32, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        let text = UnicodeScalar(scalar).map { String(Character($0)) } ?? ""
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                isARepeat: false, keyCode: keyCode)
    }

    /// 一張 2×2 的 PNG（晚到的附件用；只在記憶體）。
    @MainActor static func tinyPNG() -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// W184 G3c：抽屜是蓋上還是推開——主畫面換成一整塊中灰、離右緣 60 放一塊 40 見方的測試綠；量綠塊從哪一欄開始（主畫面動了它就跟著動）、
    /// 抽屜那一段（抽屜寬的一半）是不是還是灰的（抽屜在上面＝不是灰）。顏色都不是純原色（純紅在顏色空間換算時會偏）。
    @MainActor private static func overlayProbe(store: GlobalDMStore, directory: GlobalDMChatGPTFakeDirectory, size: CGSize,
                                                drawerWidth: CGFloat) -> (marker: CGFloat?, greenUnderDrawer: Bool) {
        let rgb = fixtureRGB, gray = (128, 128, 128)
        let view = GlobalDMChatGPTDrawerHost(store: store, enabled: true, directory: directory) {
            ZStack(alignment: .topLeading) {
                Color(red: Double(gray.0) / 255, green: Double(gray.1) / 255, blue: Double(gray.2) / 255)
                Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
                    .frame(width: 40, height: 40).offset(x: size.width - 60, y: size.height / 2 - 20)
            }
        }
        guard let shot = renderSync(view, size: size) else { return (nil, false) }
        defer { shot.close() }
        let rep = shot.bitmap
        let scale = CGFloat(rep.pixelsWide) / size.width
        let y = rep.pixelsHigh / 2
        func near(_ x: Int, _ target: (Int, Int, Int)) -> Bool {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(Int(color.redComponent * 255) - target.0) < 30 && abs(Int(color.greenComponent * 255) - target.1) < 30
                && abs(Int(color.blueComponent * 255) - target.2) < 30
        }
        let marker = (0..<rep.pixelsWide).first { near($0, rgb) }.map { CGFloat($0) / scale }
        return (marker, near(Int(drawerWidth / 2 * scale), gray))
    }

    /// 畫出來的輸入框裡每一個 NSTextView 的字級（打的字與佔位字同一個字型）。
    @MainActor static func inputPointSizes(in view: NSView) -> [CGFloat] {
        var sizes: [CGFloat] = []
        if let text = view as? NSTextView, let font = text.font { sizes.append(font.pointSize) }
        for sub in view.subviews { sizes += inputPointSizes(in: sub) }
        return sizes
    }

    @MainActor private static func quickMenuFrame(_ menu: ChatGPTQuickMenu) -> some View {
        menu.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
    }

    /// 一條橫線上有多暗（0＝白、1＝黑；只看 xFrom 以右的那一段），y 用點。
    @MainActor static func darkness(_ rendered: Rendered, y: CGFloat, xFrom: CGFloat = 0) -> Double {
        let rep = rendered.bitmap
        let scale = CGFloat(rep.pixelsWide) / rendered.size.width
        let row = min(max(0, Int(y * scale)), rep.pixelsHigh - 1)
        let start = Int(CGFloat(rep.pixelsWide) * xFrom)
        var total = 0.0
        var count = 0
        for x in start..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { continue }
            total += 1 - (color.redComponent + color.greenComponent + color.blueComponent) / 3
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }

    static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// 抽屜與建議的假清單（W184 G3b 自測）：記下讀了幾次、打開了哪一頁、齒輪按了幾次。
@MainActor final class GlobalDMChatGPTFakeDirectory: ChatGPTConversationDirectory {
    var directoryProjectsLoadState: ChatGPTListLoadState { .loaded }
    func directoryRetryProjects() { directoryPrepare() }
    func directoryProjectLoadState(_ id: String) -> ChatGPTListLoadState {
        directoryConversations(inProject: id) == nil ? .idle : .loaded
    }
    func directoryRetryProject(_ id: String) {}
    var directoryListLoadState: ChatGPTListLoadState { .loaded }
    func directoryRetryList() { directoryPrepare() }

    @Published var directoryConversations: [TapConversation]
    @Published var directoryProjects: [TapFolder]
    @Published var directoryPinned: [TapFolder]
    @Published var directorySuggestions: [TapSuggestion]
    @Published var directoryExpandedProjects: Set<String> = []
    var projectItems: [String: [TapConversation]] = [:]
    private(set) var prepared = 0
    private(set) var openedPages: [ChatGPTPage] = []
    private(set) var settingsOpened = 0

    init(conversations: [TapConversation], projects: [TapFolder], pinned: [TapFolder], suggestions: [TapSuggestion]) {
        directoryConversations = conversations
        directoryProjects = projects
        directoryPinned = pinned
        directorySuggestions = suggestions
    }

    func directoryConversations(inProject id: String) -> [TapConversation]? { projectItems[id] }

    func directoryToggleProject(_ id: String) {
        if directoryExpandedProjects.contains(id) { directoryExpandedProjects.remove(id) } else { directoryExpandedProjects.insert(id) }
    }

    func directoryPrepare() { prepared += 1 }
    func directoryOpen(_ page: ChatGPTPage) { openedPages.append(page) }
    func directoryOpenSettings() { settingsOpened += 1 }
    /// W184 G3b 第二輪：還有沒載入的（「載入更多」）、載入了幾次、伺服器搜尋回什麼（nil＝查不了）。
    var hasMore = false
    private(set) var loadMoreCalls = 0
    var searchAnswer: [TapConversation]?
    var directoryHasMore: Bool { hasMore }
    func directoryLoadMore() async { loadMoreCalls += 1 }
    func directorySearch(_ query: String) async -> [TapConversation]? { searchAnswer }
}

/// W184 G3b 第二輪（審查 #7）：假的網頁容器（CEF 那一層）與裡面拿著鍵盤的頁面。
final class GlobalDMChatGPTFakePageHost: NSView, GlobalDMNativePageHost {}

final class GlobalDMChatGPTFakePage: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// W184 G3b 第二輪（審查 #6）：輸入框交給「/」清單的鍵（記下來比對）。
final class GlobalDMChatGPTKeyLog {
    var keys: [ChatComposerSuggestionKey] = []
}
#endif
