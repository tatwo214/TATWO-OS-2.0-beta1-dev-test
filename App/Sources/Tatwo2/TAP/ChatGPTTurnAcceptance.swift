#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI

/// Real event consumers and views with an in-memory Pod. No CEF, account, or network.
extension GlobalDMChatAcceptance {
    @MainActor static func w200Checks(model: ChatPageModel, artifacts: URL?) async -> [(Bool, String)] {
        let syntheticMailbox = ["fixture", "example.invalid"].joined(separator: "@")
        var checks: [(Bool, String)] = []
        func check(_ condition: Bool, _ text: String) { checks.append((condition, "W200 " + text)) }
        func settle() async { try? await Task.sleep(for: .milliseconds(50)) }
        func shot<V: View>(_ view: V, _ name: String, _ scheme: ColorScheme, ids: Set<String>) {
            guard let rendered = renderSync(view, size: CGSize(width: 760, height: 760), scheme: scheme) else {
                check(false, name + " rendered")
                return
            }
            save(rendered, "w200-" + name + ".png", to: artifacts)
            let found = identifiers(in: rendered)
            check(ids.isSubset(of: found), name + " visible controls")
            check(rendered.bitmap.pixelsWide > 0, name + " has pixels")
            rendered.close()
        }
        let redacted = ChatGPTLocalText.clean("ChatGPT：合成錯誤 \"token\":\"QUOTED_SECRET_FIXTURE\" authorization=Bearer SHORT_SECRET /path?q=QUERY_SECRET", limit: 160)
        check(!redacted.contains("QUOTED_SECRET_FIXTURE") && !redacted.contains("SHORT_SECRET") && !redacted.contains("QUERY_SECRET"), "native error redacts quoted credentials and relative query values")
        for secret in ["password=abc", "\"password\":\"xyz\"", "/Users/fixture/private.txt", "/Volumes/fixture/private.txt",
                       syntheticMailbox, "+886 912 345 678", "0912-345-678"] {
            check(!ChatGPTLocalText.clean("synthetic error " + secret, limit: 160).contains(secret),
                  "W203-4 native privacy rules mask short password/path/contact")
        }
        check(ChatGPTLocalText.clean("error 1700000000", limit: 160).contains("1700000000"), "W205-6 bare timestamp remains readable")
        for text in ["iPhone 14 (2022)", "mobile 1080 1920", "smartphone 12345678", "xA123456789", "A123456789x"] {
            check(ChatGPTLocalText.clean(text, limit: 160) == text, "W207 native privacy preserves phone false positives")
        }
        for text in ["A123456789", "b223456789", "(02)2345-6789", "(049)234-5678", "phone=12345678"] {
            check(ChatGPTLocalText.clean(text, limit: 160) == "[聯絡資料]", "W207 native privacy masks Taiwan identity and formatted phones")
        }
        let serverThinking = ChatGPTThinking(started: Date(timeIntervalSince1970: 0), server: true)
        let quotedPassword = ChatGPTLocalText.clean("error password=\"short secret phrase\" tail", limit: 160)
        check(!quotedPassword.contains("short") && !quotedPassword.contains("secret") && !quotedPassword.contains("phrase"),
              "W203-4 native quoted short passwords are entirely removed")
        check(!ChatGPTLocalText.clean("error \"token\":\"SHORT_SECRET", limit: 160).contains("SHORT_SECRET")
              && !ChatGPTLocalText.clean("error password=\"first\nsecond\"", limit: 160).contains("second"),
              "W203-4 unclosed and multiline quoted credentials retain fail-closed masking")
        check(!ChatGPTLocalText.clean("error 2025550143 phone=12345678", limit: 160).contains("12345678")
              && !ChatGPTLocalText.clean("error (202) 555-0143", limit: 160).contains("(202) 555-0143"),
              "W203-4 native formatted and labeled telephone numbers are removed")
        check(serverThinking.label(at: Date(timeIntervalSince1970: 59)).contains("59 秒")
              && serverThinking.label(at: Date(timeIntervalSince1970: 60)).contains("1 分"),
              "W203-6 server thinking uses seconds before a minute")
        let pod = W200TurnPod(running: true)
        let tap = ChatGPTTap(transport: pod)
        let space = ChatGPTSpaceModel(testTap: tap)
        let project = TapFolder(id: "g-p-w200-fixture", title: "合成專案", kind: .project)
        space.newChat(with: project)
        let fileData = Data("synthetic draft attachment".utf8)
        space.draft = "合成問題：接著聊"
        space.addData(fileData, name: "fixture", mime: "text/plain")
        space.send()
        await settle()
        pod.stream("accepted")
        pod.stream("progress", ["title": "核對合成資料", "server": false])
        await settle()
        var repeatChanges = 0
        let repeatWatch = space.objectWillChange.sink { repeatChanges += 1 }
        pod.stream("progress", ["title": "核對合成資料", "server": false]); await settle()
        check(repeatChanges == 0, "W207 unchanged native progress does not publish a Space redraw")
        repeatWatch.cancel()
        let firstSecond = space.thinking?.seconds() ?? -1
        try? await Task.sleep(for: .milliseconds(1100))
        check(space.waitingForFirstWords && space.thinking?.title == "核對合成資料"
              && (space.thinking?.seconds() ?? -1) > firstSecond, "Space progress title and elapsed seconds update")
        shot(ChatGPTSpaceMainPane(model: space), "space-thinking-light", .light, ids: ["chatgpt.thinkingProgress"])
        shot(ChatGPTSpaceMainPane(model: space), "space-thinking-dark", .dark, ids: ["chatgpt.thinkingProgress"])
        pod.stream("conversation", ["conversationID": W200TurnPod.conversation])
        pod.stream("failed", ["message": "ChatGPT：合成對話太長", "reason": "conversation_too_long"])
        await settle()
        check(!space.isSending && !space.waitingForFirstWords && space.thinking == nil, "Space error removes thinking immediately")
        let spaceFailure = space.messages.last?.turnFailure
        check(spaceFailure?.displayText == "這則對話太長，ChatGPT 無法繼續。" && spaceFailure?.actionTitle == "開新對話接著聊", "Space persistent too-long row")
        shot(ChatGPTSpaceMainPane(model: space), "space-too-long-light", .light, ids: ["chatgpt.turnFailure"])
        shot(ChatGPTSpaceMainPane(model: space), "space-too-long-dark", .dark, ids: ["chatgpt.turnFailure"])
        let sendsBefore = pod.sends.count
        if let failure = spaceFailure { space.recover(failure) }
        check(space.selectedID == nil && space.activeGPT?.id == project.id && space.draft == "合成問題：接著聊"
              && pod.sends.count == sendsBefore, "Space opens a new chat in the same project, restores input, never auto-sends")
        check(space.attachments.first?.data == fileData && space.attachments.count == 1,
              "W207 Space manual failed-turn recovery restores its attachment exactly once")
        if let file = space.attachments.first { space.removeAttachment(file.id) }
        space.send(); await settle()
        pod.stream("progress", ["title": "檢查合成資料", "server": true]); await settle()
        check(space.thinking?.server == true, "Space server thinking uses minute label")
        pod.stream("text", ["messageID": "partial", "full": "合成部分回答"]); await settle()
        pod.stream("failed", ["message": "ChatGPT：合成服務暫時無法回答"]); await settle()
        check(space.messages.last?.text == "合成部分回答" && space.messages.last?.turnFailure != nil, "Space partial answer remains with its persistent error")
        shot(ChatGPTSpaceMainPane(model: space), "space-generic-error-light", .light, ids: ["chatgpt.turnFailure"])
        shot(ChatGPTSpaceMainPane(model: space), "space-generic-error-dark", .dark, ids: ["chatgpt.turnFailure"])
        let generic = space.messages.last?.turnFailure
        check(generic?.actionTitle == "放回輸入框", "Space other failure offers input recovery")
        if let failure = generic { space.recover(failure) }
        check(space.draft == "合成問題：接著聊" && pod.sends.count == sendsBefore + 1, "Space retry fills input without send")
        space.send(); await settle()
        pod.stream("progress", ["title": "準備合成回答", "server": false]); await settle()
        try? await Task.sleep(for: .milliseconds(1100))
        pod.stream("conversation", ["conversationID": W200TurnPod.conversation])
        pod.stream("text", ["messageID": "fixture-reply", "full": "合成回答"]); await settle()
        check(space.thinking == nil && (space.messages.last?.thoughtSeconds ?? -1) >= 1, "Space first answer collapses thinking to elapsed duration")
        pod.stream("finished"); await settle()
        check((space.messages.last?.thoughtSeconds ?? -1) >= 1, "Space canonical reload retains thought duration")
        // Sol .059：送出流程自己寫的那一行不重複；別的操作就算錯誤字一樣也照常顯示。
        space.draft = "合成未送出問題"
        space.send(); await settle()
        pod.stream("failed", ["message": "ChatGPT：合成需要登入", "submitted": false]); await settle()
        check(space.messages.contains { $0.turnFailure != nil } && space.failure != nil && space.composerFailure == nil,
              "Space same-turn failure is not repeated above the composer")
        space.failure = "重新命名沒有完成：ChatGPT：合成需要登入"
        check(space.composerFailure == space.failure, "Space another operation's error still shows even with the same provider text")
        space.failure = nil
        space.draft = "合成第二題"
        space.send(); await settle()
        space.draft = "使用者在等待時打的新字"
        pod.stream("failed", ["message": "ChatGPT：合成需要登入", "submitted": false]); await settle()
        check(space.messages.contains { $0.turnFailure != nil } && space.composerFailure != nil,
              "Space a later unsent turn whose row was replaced still shows its notice beside an older failure row")
        space.failure = nil

        let backgroundPod = W200TurnPod(running: true)
        let backgroundTap = ChatGPTTap(transport: backgroundPod)
        let background = ChatGPTSpaceModel(testTap: backgroundTap)
        var notices: [String] = []
        background.failureNoticeForSelfTest = { notices.append($0) }
        background.select(W200TurnPod.conversation); await settle()
        background.draft = "合成背景問題"
        background.send(); await settle()
        background.select("fixture-other"); await settle()
        let island = IslandNotice.shared
        let priorIslandHost = island.hostAvailable
        island.hostAvailable = true
        defer { island.hostAvailable = priorIslandHost }
        let failedAt = ContinuousClock.now
        backgroundPod.stream("failed", ["message": "ChatGPT：合成對話太長 password=abc \(syntheticMailbox)", "reason": "conversation_too_long"])
        await settle()
        check(!background.isSending && failedAt.duration(to: .now) < .seconds(5) && notices.count == 1
              && notices[0].hasPrefix("ChatGPT 沒有完成：") && !notices[0].contains("password=abc") && !notices[0].contains(syntheticMailbox),
              "W203-2 background failure emits one sanitized Island within five seconds")
        check(island.current?.title == notices.first && island.current?.kind == .info,
              "W203-2 actual Island queue presents the background failure")
        shot(IslandNoticeContent(isExpanded: true), "background-island-dark", .dark, ids: [])
        if let request = island.current { island.resolve(.cancel, id: request.id) }
        check(background.messages.last?.turnFailure == nil, "W203-2 background failure never contaminates the other conversation")
        background.select(W200TurnPod.conversation); await settle()
        check(background.messages.last?.turnFailure?.isTooLong == true && background.messages.last?.turnFailure?.draft == "合成背景問題",
              "W203-2 switching back retains error and recovery across canonical reload")
        shot(ChatGPTSpaceMainPane(model: background), "background-error-dark", .dark, ids: ["chatgpt.turnFailure"])
        backgroundTap.sleep()

        let dmPod = W200TurnPod(running: true)
        let dmTap = ChatGPTTap(transport: dmPod)
        let session = ChatGPTConversationSession(tap: dmTap)
        let directory = ChatGPTSpaceModel(testTap: dmTap)
        let suite = "ai.tatwo.selftest.w200." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return checks + [(false, "W200 isolated defaults")] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalDMStore(defaults: defaults, chatGPT: { session }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(ChatGPTModelCatalog(models: [], defaultModelID: nil)).eraseToAnyPublisher() })
        store.attach(model)
        store.select(.chatGPT)
        session.open(conversationID: W200TurnPod.conversation)
        await settle()
        check(session.projectID == project.id, "DM conversation JSON supplies project context")
        session.send("合成私訊問題", attachments: [TapAttachment(name: "fixture", mime: "text/plain", data: fileData)])
        dmPod.stream("accepted")
        dmPod.stream("progress", ["title": "核對私訊資料", "server": false]); await settle()
        let dmSecond = session.thinking?.seconds() ?? -1
        try? await Task.sleep(for: .milliseconds(1100))
        check(session.thinking?.title == "核對私訊資料" && (session.thinking?.seconds() ?? -1) > dmSecond, "DM progress title and seconds update")
        shot(GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory), "dm-thinking-light", .light, ids: ["chatgpt.thinkingProgress"])
        shot(GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory), "dm-thinking-dark", .dark, ids: ["chatgpt.thinkingProgress"])
        dmPod.stream("failed", ["message": "ChatGPT：合成對話太長", "reason": "conversation_too_long"]); await settle()
        check(!session.isSending && session.thinking == nil && session.messages.last?.turnFailure?.isTooLong == true, "DM error ends thinking and remains in the conversation")
        shot(GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory), "dm-too-long-light", .light, ids: ["chatgpt.turnFailure"])
        shot(GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: directory), "dm-too-long-dark", .dark, ids: ["chatgpt.turnFailure"])
        // Claude .059：私訊框同一回合的失敗不重複；別的錯誤（還沒連上）就算對話裡有失敗列也照常顯示。
        check(session.failureNotice == nil, "DM same-turn failure is not repeated as a notice")
        dmTap.setEnabled(false)
        session.send("合成私訊問題"); await settle()
        check(session.failureNotice == "ChatGPT 還沒連上，請稍後再送", "DM another error still shows beside an old failure row")
        dmTap.setEnabled(true); dmPod.emit(["type": "hello", "loggedIn": true]); await settle()
        check(dmTap.connection == .ready, "DM fixture tap reconnects after the notice check")
        let oldFailure = session.messages.last?.turnFailure
        let oldFailureID = session.messages.last?.id
        session.returned = { draft in
            store.setDraft(draft.text, for: .chatGPT)
            return true
        }
        session.send("合成網站未收問題"); await settle()
        dmPod.stream("failed", ["message": "ChatGPT：合成網站沒收", "submitted": false]); await settle()
        check(session.messages.contains { $0.id == oldFailureID && $0.turnFailure != nil }
              && session.failureNotice?.contains("已放回輸入框") == true,
              "W207 DM old failure row cannot hide a later website-not-submitted notice")
        let dmSends = dmPod.sends.count
        if let oldFailure { store.restoreChatGPTFailure(oldFailure, session: session) }
        check(store.attachments(for: .chatGPT).first?.data == fileData && store.attachments(for: .chatGPT).count == 1,
              "W207 DM manual failed-turn recovery restores its attachment exactly once")
        store.replaceChatGPTAttachments([])
        check(session.conversationID == nil && session.projectID == project.id && store.draft(for: .chatGPT) == "合成私訊問題"
              && dmPod.sends.count == dmSends, "DM new same-project chat restores composer without send")
        session.send("合成私訊問題"); await settle()
        check(dmPod.sends.last?["gizmoID"] as? String == project.id, "DM next manual send actually targets that project")
        dmPod.stream("failed", ["message": "ChatGPT：合成一般錯誤"]); await settle()
        if let failure = session.messages.last?.turnFailure {
            check(failure.actionTitle == "放回輸入框", "DM generic error recovery label")
            store.setDraft(session.recover(failure), for: .chatGPT)
        } else { check(false, "DM generic error row exists") }
        check(store.draft(for: .chatGPT) == "合成私訊問題" && dmPod.sends.count == dmSends + 1, "DM retry only restores input")
        session.send("合成私訊問題"); await settle()
        dmPod.stream("progress", ["title": "準備私訊回答", "server": true]); await settle()
        check(session.thinking?.label(at: Date()).contains("伺服器上思考中") == true, "DM server thinking label")
        try? await Task.sleep(for: .milliseconds(1100))
        dmPod.stream("text", ["messageID": "fixture-reply", "full": "合成回答"]); await settle()
        check(session.thinking == nil && (session.messages.last?.thoughtSeconds ?? -1) >= 1
              && GlobalDMBubble.rows(session.messages, answering: true).contains(where: { $0.text.hasPrefix("已思考 ") }), "DM first answer shows completed thinking duration")
        dmPod.stream("progress", ["title": "晚到的標題", "server": false]); await settle()
        check(session.thinking == nil, "DM late progress after answer does not restart thinking")
        dmPod.stream("finished"); await settle()

        // Native transport itself loses all events after HTTP acceptance. The clock is shortened
        // for this fixture; production still uses three minutes and the 35-minute hard limit.
        let quietPod = W200TurnPod(running: true)
        quietPod.evidence = false
        let quietTap = ChatGPTTap(transport: quietPod, silenceOverride: .milliseconds(10), progressSilence: .milliseconds(60))
        let quiet = ChatGPTConversationSession(tap: quietTap)
        quiet.send("合成無進度問題"); quietPod.stream("accepted")
        try? await Task.sleep(for: .milliseconds(180))
        check(quiet.messages.last?.turnFailure?.reason == "no_progress" && quiet.thinking == nil && !quiet.isSending,
              "native lost-event-channel watchdog completes the UI stream")
        check(!quietPod.commands.contains { $0["cmd"] as? String == "checkProgress" }, "native channel fallback needs no progress round trip")
        let alivePod = W200TurnPod(running: true)
        alivePod.evidence = true
        let aliveTap = ChatGPTTap(transport: alivePod, silenceOverride: .milliseconds(10), progressSilence: .milliseconds(60))
        let alive = ChatGPTConversationSession(tap: aliveTap)
        alive.send("合成伺服器思考問題"); alivePod.stream("accepted")
        try? await Task.sleep(for: .milliseconds(180))
        check(alive.isSending && alive.messages.last?.turnFailure == nil, "native confirmed thinking evidence keeps waiting")
        alivePod.stream("finished"); await settle()
        return checks
    }
}

@MainActor private final class W200TurnPod: FakeTapPod {
    static let conversation = "11111111-1111-4111-8111-111111111111"
    var evidence = true
    private var heartbeat: Task<Void, Never>?

    override func respond(_ command: [String: Any], id: String, cmd: String) {

        guard cmd != "send" else { return }
        let value: [String: Any]
        switch cmd {
        case "get": value = ["messages": [["id": "fixture-reply", "role": "assistant", "text": "合成回答"]], "projectID": "g-p-w200-fixture"]
        case "stop": value = ["submitted": true]
        case "list": value = ["items": [], "total": 0]
        default: value = ["items": [], "models": []]
        }
        emit(["type": "result", "id": id, "ok": true, "data": value])
    }
    override func stop() { heartbeat?.cancel(); super.stop() }
    override func stream(_ kind: String, _ fields: [String: Any] = [:]) {
        guard let id = sends.last?["id"] as? String else { return }
        if ["finished", "failed"].contains(kind) { heartbeat?.cancel() }
        if kind == "accepted", evidence {
            heartbeat?.cancel()
            heartbeat = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.emit(["type": "stream", "id": id, "kind": "activity"])
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        }
        super.stream(kind, fields)
    }

}
#endif
