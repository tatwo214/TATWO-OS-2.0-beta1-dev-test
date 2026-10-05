#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184chat`（W184 C）：私訊框的訊息列、提示列、輸入列照手機 App（對照稿 Main、Outer-ChatGPT、Open-Portrait-Chat）。
/// 規則用純函式驗（GlobalDMChatLayout、GlobalDMNoticeRule）；再把各畫面真的畫出來：量字落在哪（我說的靠右、最寬 78%；回覆全寬；
/// 貼底排）、走一遍無障礙樹核對識別碼；畫面證據 PNG 寫進 TATWO2_SELFTEST_ARTIFACTS。
/// 只在完整隔離的 staging 跑；引擎資料夾必須是未登入（不送出、不燒額度）；ChatGPT 用記憶體裡的假 Pod，不連外。
/// 視窗全透明、不接滑鼠（看不見、不擋使用者）。這個環境連最簡單的字都畫不出來時，畫面那一段照既有做法跳過並寫原因（不算通過也不算失敗）；規則那一段照跑。
enum GlobalDMChatAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w184chat needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w184chat requires a fresh live root")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        // 畫面證據只寫進 lead-verify 給的資料夾；沒給就不寫。
        let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W184CHAT \(condition ? "PASS" : "FAIL") \(label)")
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool { abs(a - b) <= tolerance }
        let layout = GlobalDMChatLayout.self

        // MARK: C1 訊息列（規則）
        let boxWidth = GlobalDMLayout.box.width
        let rowWidth = boxWidth - DMPhone.margin * 2
        check(layout.userBubbleMaxFraction == 0.78 && near(layout.userBubbleMaxWidth(rowWidth: rowWidth), rowWidth * 0.78),
              "C1 my messages are a bubble at most 78% of the row")
        check(layout.userBubbleVerticalPadding == 9 && layout.userBubbleHorizontalPadding == 14
              && layout.userBubbleRadius == 20 && layout.userLineHeight == 23,
              "C1 my bubble: padding 9/14, corner 20, line height 23 (mock)")
        check(!layout.showsReplyAvatar && layout.replyLineHeight == 25 && GlobalDMMessageText.pointSize == DMPhone.TextSize.body
              && layout.replyLineSpacing > layout.userLineSpacing,
              "C1 replies: full width, no bubble, no avatar, 17pt with line height 25")
        check(layout.listTop == 10 && layout.listBottom == 16 && layout.messageSpacing == 18
              && layout.sideMargin(for: .single) == DMPhone.margin && layout.sideMargin(for: .duoLeading) == DMPhone.wideMargin
              && layout.sideMargin(for: .duoTrailing) == DMPhone.wideMargin && DMPhone.margin == 16 && DMPhone.wideMargin == 20,
              "C1 message area: top 10, sides 16 (20 in the two columns), bottom 16, 18 between messages")
        let memoryNote = TatwoMemoryUsageNote(items: [.init(id: "pref-1", title: "回覆用繁體中文"),
                                                      .init(id: "pref-2", title: "先講結論")], query: "現在在跑什麼")
        let memoryMessage = ChatMessage(id: "m1", role: .system, text: memoryNote.encoded(), status: TatwoMemoryUsageNote.status)
        let spaced = GlobalDMBubble.rows([ChatMessage(id: "u1", role: .user, text: "現在在跑什麼？"),
                                          ChatMessage(id: "a1", role: .assistant, text: "兩件事在跑。"),
                                          memoryMessage,
                                          ChatMessage(id: "u2", role: .user, text: "好")])
        check(spaced.map(\.kind) == [.mine, .theirs, .note, .mine] && spaced[2].isMemoryUsage
              && layout.gaps(spaced) == [0, layout.messageSpacing, layout.metaSpacing, layout.messageSpacing] && layout.metaSpacing == 6,
              "C1 the 用了 N 條記憶 line sits 6 under its reply; messages are 18 apart; nothing above the first")
        let permission = GlobalDMBubble.rows([ChatMessage(id: "a1", role: .assistant, text: "好"),
                                              ChatMessage(id: "n1", role: .system, text: "已允許 Bash", status: "info|權限")])
        check(layout.gaps(permission) == [0, layout.messageSpacing] && !permission[1].isMemoryUsage,
              "C1 other system notes keep the full 18")
        let kept = GlobalDMBubble.rows([ChatMessage(id: "u1", role: .user, text: "〔在「Second Two」離線時〕記下這件事"),
                                        ChatMessage(id: "e1", role: .system, text: "引擎回報錯誤", status: "error|sidecar"),
                                        memoryMessage], running: true)
        check(kept.map(\.kind) == [.mine, .error, .note, .typing] && kept[0].text.hasPrefix("〔在「Second Two」離線時〕"),
              "C1 error card, system note, 用了 N 條記憶, the 〔在「X」離線時〕 mark and typing dots are all still there")
        let tokens: Set<CGFloat> = [DMPhone.TextSize.body, DMPhone.TextSize.secondary, DMPhone.TextSize.footnote, DMPhone.TextSize.caption]
        check(tokens == [17, 15, 13, 11] && layout.textSizes.allSatisfy(tokens.contains) && !layout.textSizes.isEmpty,
              "C1-C3 every font size in the message list, notices and composer is a token (17/15/13/11)")
        check(layout.noteTypography == ChatNoteTypography(text: 13, label: 11, mark: 11)
              && ChatNoteTypography.standard == ChatNoteTypography(text: 12, label: 10.5, mark: 11),
              "C1 用了 N 條記憶 and system notes are 13pt in the DM; Coder and TATWO keep their 12pt")

        // MARK: C2 輸入框（規則）
        check(layout.composerRadius == GlobalDMLayout.cornerRadius - GlobalDMLayout.composerInset && layout.composerRadius == 40
              && layout.composerRadius == DMPhone.barRadius && layout.composerInset == 12 && DMPhone.screenRadius == 52,
              "C2 composer sits 12 from the box edges; corner 52 − 12 = 40 (concentric)")
        check(layout.composerTop == 12 && layout.composerTrailing == 12 && layout.composerBottom == 10 && layout.composerLeading == 16
              && layout.composerLayerSpacing == 10 && layout.composerItemSpacing == 8,
              "C2 composer padding 12/12/10/16; two layers 10 apart; row items 8 apart")
        check(layout.controlSize == 36 && layout.chipHeight == 32 && layout.plusOutset == -6 && layout.messageSize == 17,
              "C2 ＋ and send/stop are 36pt circles, chips 32 high, ＋ sticks out 6, text and placeholder 17pt")
        check(layout.inputMinimumHeight >= 24 && layout.inputMaximumHeight >= layout.inputMinimumHeight * 4,
              "C2 the text grows from one line to about five")
        check(layout.showsChatGPTCaption(for: .chatGPT) && !layout.showsChatGPTCaption(for: .assistant)
              && !layout.showsChatGPTCaption(for: .thread(UUID()))
              && GlobalDMChatGPTCaption.text == "OS 不記錄對話內容・用你自己的 ChatGPT 帳號",
              "C2 the ChatGPT line (OS keeps no record · your own account) is only for ChatGPT")

        // MARK: C3 提示列（規則；文字取自真的來源）
        let device = AssistantPrimaryDevice(id: "primary-one", displayName: "Primary One")
        var notices: [(id: String, text: String, action: String?)] = [
            ("tatwo.dm.primaryOffline", AssistantPlacement.unreachableNote(device, .offline), nil),
            ("tatwo.dm.primaryOffline", AssistantPlacement.unreachableNote(device, .connecting), nil),
            ("tatwo.dm.primaryOffline", AssistantPlacement.unreachableNote(device, .noAssistant), nil),
            ("tatwo.dm.primaryOffline", RemoteOfflineContinue.dmNote(place: "主設備「Primary One」"), RemoteOfflineContinue.chipTitle),
            ("tatwo.dm.primaryHint", AssistantPlacement.deliveryFailureNote(URLError(.timedOut), device: device), nil),
        ]
        for code in ["assistant_busy", "assistant_engines_disabled", "assistant_engine_disabled", "assistant_not_sent",
                     "invalid_params", "anything_else"] {
            notices.append(("tatwo.dm.primaryHint",
                            AssistantPlacement.deliveryFailureNote(RemoteHostLinkError.remoteError(code), device: device), nil))
        }
        notices += [
            ("tatwo.dm.approval", "等你核准", "到 Island 核准"),
            ("tatwo.dm.chatgptOff", "ChatGPT Space 已關閉；到設定打開 ChatGPT 分頁才能用", nil),
            ("tatwo.dm.chatgptLogin", "ChatGPT 要先登入", "到 ChatGPT Space 登入"),
            ("tatwo.dm.chatgptFailed", "ChatGPT 還沒連上，請稍後再送", nil),
            ("tatwo.dm.notice", "主設備上的對話暫不支援附件", nil),
            ("tatwo.dm.notice", "/plan 要在 Coder 的輸入框用；私訊框只送一般訊息。", nil),
            ("tatwo.dm.notice", "已記成提案；到 設定 › OS › 文件 › 記憶提案 核准", nil),
            ("tatwo.dm.notice", "剪貼簿沒有圖片或檔案", nil),
        ]
        let wordy = notices.filter { !GlobalDMNoticeRule.isOneSentence($0.text) }
        check(wordy.isEmpty, "C3 every notice kind is one plain sentence (\(notices.count) texts from the real sources)"
              + (wordy.isEmpty ? "" : ": " + wordy.map(\.text).joined(separator: " | ")))
        check(notices.allSatisfy { ($0.action == nil ? 0 : 1) <= GlobalDMNoticeRule.maximumActions } && GlobalDMNoticeRule.maximumActions == 1,
              "C3 each notice has at most one button")
        check(!GlobalDMNoticeRule.isOneSentence("第一句。第二句。") && !GlobalDMNoticeRule.isOneSentence("兩行\n文字")
              && !GlobalDMNoticeRule.isOneSentence("") && GlobalDMNoticeRule.isOneSentence("前半句；後半句。"),
              "C3 the one-sentence rule rejects two sentences, two lines and nothing")
        check(layout.noticeMinHeight == 48 && layout.noticeRadius == 24 && layout.noticeRadius - layout.noticeInset == layout.chipHeight / 2,
              "C3 a notice row is at least 48 high, corner 24 concentric with its 32pt chip")

        // MARK: 畫出來：量位置、核對識別碼、畫面證據
        let probe = renderSync(Text("測試 Test").font(.system(size: DMPhone.TextSize.body)).foregroundStyle(Color.black),
                               size: CGSize(width: 200, height: 60))
        guard let probe, ink(probe) != nil else {
            print("W184CHAT SKIP rendering: this environment cannot draw text offscreen (no window server); rules above still ran")
            print("W184CHAT SUMMARY failures=\(failed) passed=\(passed)")
            return failed == 0
        }
        probe.close()

        // 訊息區本身（白底、淺色）：量字的墨水落在哪。
        let listSize = CGSize(width: boxWidth, height: 360)
        let side = DMPhone.margin
        func listInk(_ bubbles: [GlobalDMBubble], role: GlobalDMBoxRole = .single) -> CGRect? {
            let view = GlobalDMMessageList(bubbles: bubbles, emptyText: "")
                .environment(\.globalDMBoxRole, role)
            guard let rendered = renderSync(view, size: listSize) else { return nil }
            defer { rendered.close() }
            return ink(rendered)
        }
        let short = listInk([GlobalDMBubble(id: "s", kind: .mine, text: "好的")])
        let bubbleTextRight = boxWidth - side - layout.userBubbleHorizontalPadding
        check(short.map { $0.minX > boxWidth / 2 && near($0.maxX, bubbleTextRight, 3) } == true,
              "C1 (drawn) a short message of mine sits at the right, text ending 14 inside the 16 margin"
              + (short.map { " [ink x \(Int($0.minX))–\(Int($0.maxX))]" } ?? " [nothing drawn]"))
        check(short.map { $0.maxY > listSize.height * 0.8 } == true,
              "C1 (drawn) messages sit at the bottom, next to the composer (new ones at the bottom)"
              + (short.map { " [ink y \(Int($0.minY))–\(Int($0.maxY)) of \(Int(listSize.height))]" } ?? ""))
        let longMine = listInk([GlobalDMBubble(id: "l", kind: .mine, text: String(repeating: "很長的一句訊息", count: 10))])
        let leftmostMine = boxWidth - side - layout.userBubbleMaxWidth(rowWidth: rowWidth) + layout.userBubbleHorizontalPadding
        check(longMine.map { $0.minX >= leftmostMine - 3 && near($0.maxX, bubbleTextRight, 3) && $0.height > 40 } == true,
              "C1 (drawn) a long message of mine wraps inside 78% of the row, on the right"
              + (longMine.map { " [ink x \(Int($0.minX))–\(Int($0.maxX)), left limit \(Int(leftmostMine))]" } ?? " [nothing drawn]"))
        let longReply = String(repeating: "回覆是全寬的文字沒有泡泡", count: 6)
        let reply = listInk([GlobalDMBubble(id: "r", kind: .theirs, text: longReply)])
        check(reply.map { near($0.minX, side, 3) && $0.maxX >= side + rowWidth * 0.9 } == true,
              "C1 (drawn) a reply runs the full width from the 16 margin (no bubble, no avatar)"
              + (reply.map { " [ink x \(Int($0.minX))–\(Int($0.maxX))]" } ?? " [nothing drawn]"))
        let wide = listInk([GlobalDMBubble(id: "r", kind: .theirs, text: longReply)], role: .duoLeading)
        check(wide.map { near($0.minX, DMPhone.wideMargin, 3) } == true,
              "C1 (drawn) in the two columns the margin is 20" + (wide.map { " [ink x from \(Int($0.minX))]" } ?? " [nothing drawn]"))

        // 真的資料：隔離的引擎與助理那條、私訊框自己的 store（只在記憶體；UserDefaults 用暫時的 suite）。
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "DM 專案", workdir: root.path)
        _ = engine.newThread(in: project, title: "A 串")
        guard let assistantID = engine.doc.assistantThreadID else { throw BotLibraryError.invalid("assistant thread missing") }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        let suite = "ai.tatwo.selftest.w184chat.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw BotLibraryError.invalid("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let pod = GlobalDMChatAcceptancePod()
        let chatSession = ChatGPTConversationSession(tap: ChatGPTTap(transport: pod, connection: .ready))
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant"), TapEffort(id: "fixture|pro", title: "Pro", isMax: true)]),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|pro")
        let store = GlobalDMStore(defaults: defaults, chatGPT: { chatSession }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() })
        store.attach(model)
        store.select(.assistant)
        for (condition, label) in await w200Checks(model: model, artifacts: artifacts) { check(condition, label) }


        let assistantBubbles = GlobalDMBubble.rows([
            ChatMessage(id: "u1", role: .user, text: "現在在跑什麼？"),
            ChatMessage(id: "a1", role: .assistant, text: "有兩件事在跑：ChatGPT 連接器的關口，和剛裝好的新版。\n沒有別的要你處理。"),
            memoryMessage,
            ChatMessage(id: "u2", role: .user, text: "ChatGPT 那邊連好了嗎？"),
            ChatMessage(id: "a2", role: .assistant, text: "［連線］按一下就好。登入完成後會自動接著連線。"),
        ])
        func assistantPane(note: String? = nil, hint: String? = nil, noteAction: GlobalDMNoteAction? = nil,
                           bubbles: [GlobalDMBubble]) -> GlobalDMThreadPane {
            GlobalDMThreadPane(store: store, bubbles: bubbles, emptyText: "", placeholder: "問助理任何事…",
                               note: note, hint: hint, canSend: true, noteAction: noteAction)
        }
        let paneSize = CGSize(width: boxWidth, height: GlobalDMLayout.box.height)
        let composerIDs: Set<String> = ["tatwo.dm.input", "tatwo.dm.send", "tatwo.dm.attach", "tatwo.dm.model"]

        // 助理對話（含「用了 N 條記憶」、等你核准列）：核准只在 Island，這裡用引擎真的「等核准」狀態畫。
        var approvalIDs = Set<String>()
        engine.withPendingPermission(assistantID) {
            check(store.isAwaitingApproval, "C3 fixture: the assistant is waiting for an approval")
            guard let shot = renderSync(GlobalDMChatAcceptanceFrame { assistantPane(bubbles: assistantBubbles) }, size: paneSize) else { return }
            defer { shot.close() }
            save(shot, "assistant.png", to: artifacts)
            approvalIDs = identifiers(in: shot)
        }
        let axWorks = !approvalIDs.isEmpty
        if !axWorks { print("W184CHAT SKIP identifiers: no accessibility tree offscreen in this environment (source contract in tests/w184-chat.test.mjs)") }
        func checkIDs(_ found: Set<String>, has required: Set<String>, lacks forbidden: Set<String> = [], _ label: String) {
            guard axWorks else { return }
            let missing = required.subtracting(found).sorted()
            let extra = forbidden.intersection(found).sorted()
            check(missing.isEmpty && extra.isEmpty, label + (missing.isEmpty ? "" : " — missing \(missing)") + (extra.isEmpty ? "" : " — unexpected \(extra)"))
        }
        checkIDs(approvalIDs, has: composerIDs.union(["tatwo-memory-strength", "tatwo.dm.approval", "tatwo.dm.approval.action",
                                                      "tatwo-memory-usage"]),
                 lacks: ["tatwo.dm.chatgptCaption"],
                 "C2/C3 assistant: input, ＋, 記憶, 模型, 送出, 等你核准＋到 Island 核准, 用了 N 條記憶 are there; no ChatGPT line")

        // W201：副設備能自動接著聊時，不出設備離線提示。
        let offlineBubbles = GlobalDMBubble.rows([
            ChatMessage(id: "u1", role: .user, text: "〔在「Second Two」離線時〕幫我記下明天要驗收"),
            ChatMessage(id: "a1", role: .assistant, text: "記下了。連回主設備後這段會補回去。"),
        ])
        if let shot = renderSync(GlobalDMChatAcceptanceFrame {
            assistantPane(note: nil, bubbles: offlineBubbles)
        }, size: paneSize) {
            save(shot, "primary-offline.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: composerIDs,
                     lacks: ["tatwo.dm.primaryOffline", "tatwo.dm.primaryOffline.action"], "C3 primary offline: local fallback stays quiet")
            shot.close()
        }

        // 離線副本「在這台接著聊」、送不到主設備、一般提示：各一句＋最多一顆鈕。
        store.showNotice("剪貼簿沒有圖片或檔案")
        if let shot = renderSync(GlobalDMChatAcceptanceFrame {
            assistantPane(note: RemoteOfflineContinue.dmNote(place: "主設備「Primary One」"),
                          hint: AssistantPlacement.deliveryFailureNote(URLError(.timedOut), device: device),
                          noteAction: GlobalDMNoteAction(title: RemoteOfflineContinue.chipTitle) {}, bubbles: [])
        }, size: paneSize) {
            save(shot, "notices.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.primaryOffline", "tatwo.dm.primaryOffline.action",
                                                  "tatwo.dm.primaryHint", "tatwo.dm.notice"],
                     lacks: ["tatwo.dm.primaryHint.action", "tatwo.dm.notice.action"],
                     "C3 在這台接著聊 has its one chip; the delivery hint and the plain notice have none")
            shot.close()
        }

        // 輸入框有附件（本機助理收得了檔案；只記路徑，不讀檔）。換一次對象把上面那句一般提示清掉。
        store.select(.chatGPT)
        store.select(.assistant)
        check(store.notice == nil, "C3 fixture: switching target clears the plain notice")
        store.addAttachments([root.appendingPathComponent("截圖.png"), root.appendingPathComponent("驗收清單.pdf")])
        check(store.attachments(for: .assistant).count == 2 && store.hasContentToSend, "C2 fixture: two attachments on the assistant")
        if let shot = renderSync(GlobalDMChatAcceptanceFrame { assistantPane(bubbles: Array(assistantBubbles.prefix(2))) }, size: paneSize) {
            save(shot, "attachments.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: composerIDs.union(["tatwo.dm.attachments"]), "C2 attachments: the chip row is there")
            shot.close()
        }
        for file in store.attachments(for: .assistant) { store.removeAttachment(file.id) }

        // 回覆中：送出換成停止。
        if let shot = renderSync(GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: true, canSend: true),
                                 size: CGSize(width: boxWidth, height: 160)) {
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.stop", "tatwo.dm.input"], lacks: ["tatwo.dm.send"],
                     "C2 while replying the send button becomes stop")
            shot.close()
        }

        // ChatGPT 對話（含說明行）：假 Pod 回一句；記憶 chip 不出現。
        store.select(.chatGPT)
        chatSession.send("（TATWO TAP 測試）請只回覆四個字：TAP OK")
        pod.answer("TAP OK")
        for _ in 0..<40 where chatSession.isSending { try? await Task.sleep(for: .milliseconds(25)) }
        check(chatSession.messages.map(\.text) == ["（TATWO TAP 測試）請只回覆四個字：TAP OK", "TAP OK"] && !chatSession.isSending,
              "C1 fixture: a ChatGPT exchange through the in-memory Pod")
        if let shot = renderSync(GlobalDMChatAcceptanceFrame {
            GlobalDMChatGPTPane(store: store, session: chatSession, isAvailable: true)
        }, size: paneSize) {
            save(shot, "chatgpt.png", to: artifacts)
            // W184 G3：對象是 ChatGPT 時輸入框＝ChatGPT Space 的元件；送出鍵那一格照網頁（空白＝語音模式 tatwo.dm.voice，有字才是 tatwo.dm.send，
            // 兩種都在 G3 那一段畫出來核對）。守：說明行在、沒有記憶 chip、輸入框與 ＋ 都在。
            // W184 G3b：模型名搬到頂列中間（這裡只畫窗格，頂列那一邊在 G3b 那一段核對）；輸入框右邊是網路搜尋開關。
            checkIDs(identifiers(in: shot), has: composerIDs.subtracting(["tatwo.dm.send", "tatwo.dm.model"])
                        .union(["tatwo.dm.chatgptCaption", "tatwo.dm.voice", "tatwo.dm.webSearch"]),
                     lacks: ["tatwo-memory-strength"],
                     "C2 ChatGPT: the line above the composer is there; no memory chip")
            shot.close()
        }
        if let shot = renderSync(GlobalDMChatGPTPane(store: store, session: chatSession, isAvailable: false), size: paneSize) {
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.chatgptOff"], lacks: ["tatwo.dm.chatgptOff.action"],
                     "C3 ChatGPT Space off: one sentence, no button")
            shot.close()
        }
        let loginSession = ChatGPTConversationSession(tap: ChatGPTTap(transport: GlobalDMChatAcceptancePod(), connection: .needsLogin))
        if let shot = renderSync(GlobalDMChatGPTPane(store: store, session: loginSession, isAvailable: true), size: paneSize) {
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.chatgptLogin", "tatwo.dm.chatgptLogin.action"],
                     "C3 ChatGPT needs login: one sentence and the one 到 ChatGPT Space 登入 chip")
            shot.close()
        }
        let sleepyPod = GlobalDMChatAcceptancePod()
        sleepyPod.isRunning = false
        let failedSession = ChatGPTConversationSession(tap: ChatGPTTap(transport: sleepyPod, connection: .failed("isolated connection fixture")))
        failedSession.send("還沒連上時送出")
        if let shot = renderSync(GlobalDMChatGPTPane(store: store, session: failedSession, isAvailable: true), size: paneSize) {
            if case .failed = failedSession.state {
                checkIDs(identifiers(in: shot), has: ["tatwo.dm.chatgptFailed"], lacks: ["tatwo.dm.chatgptFailed.action"],
                         "C3 ChatGPT failed: the reason in one line, no button")
            } else {
                check(false, "C3 fixture: a disconnected ChatGPT send fails without losing the draft")
            }
            shot.close()
        }
        store.select(.assistant)

        // W184 G3：對象是 ChatGPT 時的輸入框＝ChatGPT Space 輸入框的元件（GlobalDMChatGPTComposerAcceptance.swift）。
        for (condition, label) in await chatGPTComposerChecks(root: root, model: model, artifacts: artifacts, axWorks: axWorks) {
            check(condition, label)
        }
        // W184 G3b：對象是 ChatGPT 時照 ChatGPT iPhone App（頂列、抽屜、＋ 小卡、「/」、建議、上下緣漸出；GlobalDMChatGPTNavigationAcceptance.swift）。
        for (condition, label) in await chatGPTNavigationChecks(root: root, model: model, artifacts: artifacts, axWorks: axWorks) {
            check(condition, label)
        }
        // W184 G3c：ChatGPT 私訊框（≡ 與左緣槓拿掉、抽屜蓋上、右上臨時聊天、輸入框同心與功能鍵）與訊息上緣頂天（GlobalDMChatGPTG3cAcceptance.swift）。
        for (condition, label) in await chatGPTG3cChecks(root: root, model: model, artifacts: artifacts, axWorks: axWorks) {
            check(condition, label)
        }

        print("W184CHAT SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    // MARK: - 畫圖、量墨水、無障礙樹

    /// 畫好的一張：視窗在螢幕外，用完關掉。
    @MainActor struct Rendered {
        let host: NSView
        let window: NSWindow
        let bitmap: NSBitmapImageRep
        let size: CGSize
        func close() { window.orderOut(nil); window.contentView = nil; window.close() }
    }

    /// 同步畫（等核准的狀態只在引擎的回呼裡，所以不能 await）：淺色、白底的無邊框視窗，放在螢幕上但全透明、不接滑鼠
    /// （SwiftUI 要視窗在畫面上才建無障礙樹；同 Bot 頁、空狀態自測的做法，只是看不見）；讓 SwiftUI 跑幾輪再截。
    @MainActor static func renderSync<V: View>(_ view: V, size: CGSize, scheme: ColorScheme = .light) -> Rendered? {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height)
            .background(scheme == .dark ? LiquidGlassTokens.browserOmniboxDarkTint : Color.white)
            .environment(\.colorScheme, scheme)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // 自測主動開 App 的 AX 樹；不靠 VoiceOver 或系統授權，不拿任何其他 App 的畫面。
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            window.orderOut(nil)
            window.close()
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Rendered(host: host, window: window, bitmap: bitmap, size: size)
    }

    /// 深色字（墨水）占的範圍，單位是點、y 從上往下；白底上一個深色都沒有是 nil。每個像素看 RGB 三個值都深才算（不管位元組順序）。
    @MainActor static func ink(_ rendered: Rendered) -> CGRect? {
        let rep = rendered.bitmap
        guard rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh, samples = rep.samplesPerPixel, row = rep.bytesPerRow
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height {
            let line = data + y * row
            for x in 0..<width {
                let pixel = line + x * samples
                var dark = 0
                for s in 0..<samples where pixel[s] < 110 { dark += 1 }
                // 不透明的深色像素：RGB 三個深、alpha 亮（有 alpha 時剛好 3 個深）；沒有 alpha 時三個都深。
                guard dark == 3 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let sx = CGFloat(width) / rendered.size.width, sy = CGFloat(height) / rendered.size.height
        return CGRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
                      width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
    }

    /// 走一遍無障礙樹（SwiftUI 的節點與 AppKit 的子 view），收集識別碼；等 SwiftUI 建好樹，最多等 1 秒。
    @MainActor static func identifiers(in rendered: Rendered) -> Set<String> {
        func attribute(_ object: NSObject, _ name: String, legacy: String) -> Any? {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() {
                // 空的（空陣列、空字串）再問一次舊式 API：SwiftUI 的節點常常只在那邊回。
                if let array = value as? [Any] {
                    if !array.isEmpty { return array }
                } else if let text = value as? String {
                    if !text.isEmpty { return text }
                } else {
                    return value
                }
            }
            let old = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: old) else { return nil }
            return object.perform(old, with: legacy)?.takeUnretainedValue()
        }
        var found = Set<String>()
        var previous: Set<String>? = nil
        var nodes = 0
        var roles: [String: Int] = [:]
        for _ in 0..<20 {
            var seen = Set<ObjectIdentifier>()
            var pass = Set<String>()
            roles = [:]
            func visit(_ element: Any, depth: Int) {
                guard depth < 80, seen.count < 6000, let object = element as? NSObject,
                      seen.insert(ObjectIdentifier(object)).inserted else { return }
                // 補走 AppKit subviews 時也遵守原生 AX hidden；VoiceOver 不走這些子樹。
                if let view = object as? NSView, view.isAccessibilityHidden() { return }
                if let id = attribute(object, "accessibilityIdentifier", legacy: "AXIdentifier") as? String, !id.isEmpty {
                    pass.insert(id)
                }
                if let role = attribute(object, "accessibilityRole", legacy: "AXRole") as? String {
                    roles[role, default: 0] += 1
                }
                for child in attribute(object, "accessibilityChildren", legacy: "AXChildren") as? [Any] ?? [] {
                    visit(child, depth: depth + 1)
                }
                if let view = object as? NSView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
            }
            // 從視窗走（同 Bot 頁、空狀態自測）；再補走 hosting view 本身。
            visit(rendered.window, depth: 0)
            visit(rendered.host, depth: 0)
            nodes = seen.count
            found.formUnion(pass)
            // 樹建好了＝連兩輪一樣（而且有東西）。
            if !pass.isEmpty, pass == previous { break }
            previous = pass
            rendered.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if found.isEmpty {
            let seenRoles = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            print("W184CHAT NOTE accessibility walk visited \(nodes) nodes and found no identifier; roles: \(seenRoles)")
        }
        return found
    }

    /// 畫面證據：PNG 寫進 lead-verify 給的資料夾（報告附路徑）。
    @MainActor static func save(_ rendered: Rendered, _ name: String, to folder: URL?) {
        guard let folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let png = rendered.bitmap.representation(using: .png, properties: [:]) else { return }
            let url = folder.appendingPathComponent(name)
            try png.write(to: url)
            print("W184CHAT NOTE evidence \(url.path)")
        } catch {
            print("W184CHAT NOTE evidence \(name) not written: \(error.localizedDescription)")
        }
    }
}

/// 畫面證據用的框：iPhone Duo 外螢幕 466×678、圓角 52；頂列（房 AB 的）留位置不畫。W184 G3 的那一段也用它（不再是 private）。
struct GlobalDMChatAcceptanceFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: DMPhone.headerHeight)
            content()
        }
        .frame(width: GlobalDMLayout.box.width, height: GlobalDMLayout.box.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DMPhone.screenRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DMPhone.screenRadius, style: .continuous)
            .strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
    }
}

/// 記憶體裡的假 Pod：已連上；記下送出的請求代號，`answer` 假裝 ChatGPT 回了一段字。不啟動 CEF、不連外。
@MainActor final class GlobalDMChatAcceptancePod: FakeTapPod {
    init() { super.init(running: true) }
    var sentIDs: [String] { sends.compactMap { $0["id"] as? String } }
    func answer(_ text: String) {
        stream("text", ["messageID": "fixture-reply", "full": text])
        stream("finished")
    }
}

#endif
