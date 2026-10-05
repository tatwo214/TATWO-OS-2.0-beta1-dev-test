#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// W197：正式 Space 與原生按鈕，唯一替身是同一個 Pod 的網頁與傳輸。
@MainActor enum W197DotsAcceptance {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.remote("W197 requires isolated staging and artifacts") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        _ = TatwoThemeStore.shared
        let palette = TatwoActivePalette.current
        TatwoActivePalette.current = TatwoTheme.aurora.palette
        defer { NSApp.appearance = appearance; TatwoActivePalette.current = palette }

        let voicePod = FakeTapPod(running: true), voiceTap = ChatGPTTap(transport: voicePod)
        let owner = UUID()
        let claim = voiceTap.claimVoice(owner: owner, holderNotice: "fixture owner")!
        check(voiceTap.voiceClaim == claim && voicePod.commands.isEmpty,
              "W207 voice is owned before any start command")
        check(voiceTap.claimVoice(owner: UUID()) == nil && voiceTap.beginMenuHold() == nil && voiceTap.beginConnectorHold() == nil,
              "W207 voice excludes other owners and page holders")
        voiceTap.releaseVoice(.init(owner: UUID(), generation: claim.generation))
        check(voiceTap.voiceClaim == claim, "W207 another owner cannot release voice")
        voiceTap.releaseVoice(claim)
        check(voiceTap.voiceClaim == nil && voiceTap.voiceHolderNotice == nil && !voiceTap.voiceOpen && !voiceTap.requestVoiceEnd(),
              "W207 releasing voice clears ownership and stop callbacks")
        let next = voiceTap.claimVoice(owner: owner)!
        voiceTap.releaseVoice(claim)
        check(voiceTap.voiceClaim == next && next.generation > claim.generation, "W207 an old generation cannot release the new voice")
        voiceTap.forceEndVoice(next)
        check(voiceTap.voiceClaim == nil && !voicePod.isRunning, "W207 closing the voice page releases ownership")

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let pod = Pod(running: true)
            let tap = ChatGPTTap(transport: pod)
            let model = ChatGPTSpaceModel(testTap: tap)
            model.dotsPageForSelfTest = AnyView(FakePage(pod: pod))
            var opened: [URL] = []
            model.dotsBrowserOpenForSelfTest = { opened.append($0) }
            let rig = TatwoComposerModeAcceptance.ClickRig(
                HStack(spacing: 0) {
                    ChatGPTSpaceSidebarList(model: model).frame(width: 220)
                    Divider()
                    ChatGPTSpaceMainPane(model: model)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light),
                size: CGSize(width: 1060, height: 700))
            rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await rig.settle()
            model.select("fixture-original")
            await rig.settle()
            model.draft = "尚未送出的草稿"
            let original = model.messages
            let epoch = model.viewEpoch
            check(!original.isEmpty, "W197 original conversation is loaded through real TAP")

            func press(_ id: String) async -> Bool {
                guard let frame = model.dotsControlFramesForSelfTest[id], frame.width > 10 else { return false }
                let point = rig.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                }
                guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
                NSApp.postEvent(up, atStart: false)
                rig.window.sendEvent(down)
                let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date.distantPast, inMode: .default, dequeue: true)
                try? await Task.sleep(for: .milliseconds(50))
                if let pending { rig.window.sendEvent(pending) }
                await rig.settle()
                return true
            }
            func shot(_ name: String) throws {
                guard let rendered = rig.capture(), let png = rendered.bitmap.representation(using: .png, properties: [:]) else {
                    throw TapError.remote("W197 screenshot unavailable")
                }
                try png.write(to: folder.appendingPathComponent(name + ".png"))
                if dark { check(TatwoThemeSelfTestScope.hasReadableDarkPixels(rendered.bitmap), "W197 dark screenshot contains dark surfaces and readable text") }
                print("W197 PNG \(folder.appendingPathComponent(name + ".png").path)")
            }
            let theme = dark ? "dark" : "light"
            check(await press("chatgpt.dots"), "W197 sidebar Dots entry receives a native mouse click \(theme)")
            check(model.dotsPresented && pod.opens == 1 && pod.pagePresented && !pod.hidden,
                  "W197 clicking Dots presents the same live Pod, without starting another profile \(theme)")
            // 舊文件的延遲回報不能把 Dots 當成導回；loading 回報也不能放開遮罩。
            pod.onDisplayFrame?("https://chatgpt.com/", 0, false, 200)
            pod.onDisplayFrame?("https://chatgpt.com/dots", 1, true, 200)
            check(tap.dotsState == .loading, "W197 ignores stale and loading frame updates")
            pod.frame("https://chatgpt.com/dots")
            await rig.settle()
            check(tap.dotsState == .ready && pod.pagePresented && !pod.hidden, "W197 loaded Dots is visible and unthrottled \(theme)")
            try shot("dots-" + theme)
            check(await press("chatgpt.dots.browser") && opened == [ChatGPTDotsState.url], "W197 browser button opens the fixed Dots URL \(theme)")

            let queue = tap.send(requestID: "queued-" + theme, text: "queued fixture", conversationID: "fixture-original")
            check(pod.sent.isEmpty && tap.beginConnectorHold() == nil && tap.beginMenuHold() == nil && tap.claimVoice(owner: UUID()) == nil,
                  "W197 Dots holds off sends, connector, plugin menu and voice")
            do { _ = try await tap.messages(conversationID: "fixture-original"); check(false, "W197 Dots refuses TAP reads") }
            catch { check(true, "W197 Dots refuses TAP reads") }
            pod.emit(["type":"stream", "id":"queued-" + theme, "kind":"text", "full":"must not import"])
            check(model.messages == original, "W197 display-only web events never enter native conversation")

            check(await press("chatgpt.dots.back"), "W197 native Back button is clickable \(theme)")
            check(!model.dotsPresented && !pod.pagePresented && pod.restored.last?.path == "/c/fixture-original"
                  && model.selectedID == "fixture-original" && model.messages == original && model.draft == "尚未送出的草稿" && model.viewEpoch == epoch,
                  "W197 Back parks the web surface and preserves original conversation, conversation identity and draft \(theme)")
            check(pod.sent.isEmpty, "W197 queued send waits until the restored document reports hello")
            pod.emit(["type":"hello", "loggedIn":true])
            check(pod.sent == ["queued-" + theme], "W197 restored ChatGPT resumes the queued send")
            pod.emit(["type":"stream", "id":"queued-" + theme, "kind":"finished"])
            var imported = false
            for await event in queue { if case .text = event { imported = true } }
            check(!imported, "W197 Dots content is dropped even for an existing stream ID")
            try shot("dots-return-" + theme)

            check(await press("chatgpt.dots"), "W197 Dots can reopen")
            pod.frame("https://chatgpt.com/")
            await rig.settle()
            check(tap.dotsState == .unavailable && !pod.pagePresented, "W197 redirected account replaces the web page with plain unavailable copy")
            try shot("dots-unavailable-" + theme)
            _ = await press("chatgpt.dots.back")
            pod.emit(["type":"hello", "loggedIn":true])
            check(pod.hidden && !pod.pagePresented, "W197 Back with no pending work restores native-hidden throttling")

            _ = await press("chatgpt.dots")
            pod.frame("https://chatgpt.com/dots")
            await rig.settle()
            model.select("fixture-other")
            await rig.settle()
            check(!model.dotsPresented && model.selectedID == "fixture-other", "W197 selecting another sidebar conversation closes Dots")
            pod.emit(["type":"hello", "loggedIn":true])
            await rig.settle()
            check(!model.messages.isEmpty && model.failure == nil, "W197 sidebar conversation loads after restored ChatGPT hello")

            _ = await press("chatgpt.dots")
            pod.frame("https://chatgpt.com/dots")
            pod.emit(["type":"dotsAvailability", "unavailable":true])
            pod.frame("https://chatgpt.com/dots")
            await rig.settle()
            check(tap.dotsState == .unavailable && !pod.pagePresented, "W197 page-level unavailable boolean stays unavailable after later frame updates")
            model.disappear()
            await rig.settle()
            check(!model.dotsPresented && !pod.pagePresented && !pod.spaceVisible, "W197 leaving Space releases Dots presentation while the original page restores")
            pod.emit(["type":"hello", "loggedIn":true])
            check(tap.usageCount == 0 && pod.hidden && tap.sleepIfIdle() && !pod.isRunning,
                  "W197 restored offscreen Pod releases all leases and can sleep")
            rig.close()
            tap.sleep()
        }
        for (url, status) in [("https://chatgpt.com/dots",403), ("https://chatgpt.com/dots",404), ("https://chatgpt.com/dots/unavailable",200),
                              ("https://chatgpt.com/auth/login",200), ("https://example.com/dots",200)] {
            check(ChatGPTDotsState.loaded(url: url, status: status) == .unavailable, "W197 unavailable route/status classifier \(status)")
        }
        let busy = Pod(running: true), tap = ChatGPTTap(transport: busy)
        let stream = tap.send(requestID: "busy", text: "fixture", conversationID: nil)
        await tap.openDots(returnURL: ChatGPTTap.homeURL)
        check(busy.opens == 0 && tap.dotsState == .blocked("ChatGPT 正在忙，等它結束再開 Dots"), "W197 active conversation is never navigated away")
        busy.emit(["type":"stream", "id":"busy", "kind":"finished"])
        withExtendedLifetime(stream) {}
        tap.sleep()

        let quick = Pod(running: true), quickTap = ChatGPTTap(transport: quick)
        await quickTap.openDots(returnURL: ChatGPTTap.homeURL)
        quickTap.closeDots()
        let reopen = Task { await quickTap.openDots(returnURL: ChatGPTTap.homeURL) }
        try await Task.sleep(for: .milliseconds(80))
        check(quick.opens == 1, "W197 rapid reopen waits for the previous return")
        quick.emit(["type":"hello", "loggedIn":true])
        await reopen.value
        check(quick.opens == 2 && quickTap.dotsState == .loading, "W197 rapid reopen acquires the same Pod after restoration")
        quickTap.closeDots()
        quickTap.closeDots()
        quick.emit(["type":"hello", "loggedIn":true])
        check(quickTap.usageCount == 0, "W197 repeated close still finishes restoration and releases its lease")
        let quickModel = ChatGPTSpaceModel(testTap: quickTap)
        await quickTap.openDots(returnURL: ChatGPTTap.homeURL)
        check(quickModel.dotsPresented, "W207 Dots presentation follows the live holder")
        quickTap.sleep()
        check(!quickModel.dotsPresented && quickTap.usageCount == 0,
              "W207 sleeping the shared Pod closes derived Dots presentation and releases its holder")

        let queuedPod = Pod(running: true), queuedTap = ChatGPTTap(transport: queuedPod, voiceQueueLimit: .milliseconds(50))
        await queuedTap.openDots(returnURL: ChatGPTTap.homeURL)
        let queuedSession = ChatGPTConversationSession(tap: queuedTap)
        var restored = false
        queuedSession.returned = { _ in restored = true; return true }
        queuedSession.send("synthetic Dots queue")
        try await Task.sleep(for: .milliseconds(150))
        check(!queuedSession.isSending && restored && queuedPod.sent.isEmpty,
              "W203 Dots queue expires, returns DM draft and never sends")
        queuedTap.closeDots(); queuedPod.emit(["type": "hello", "loggedIn": true])
        check(queuedPod.sent.isEmpty, "W203 returning from Dots never sends an expired queued ticket")
        queuedTap.sleep()

        let cancelled = Pod(running: true), cancelledTap = ChatGPTTap(transport: cancelled)
        await cancelledTap.openDots(returnURL: ChatGPTTap.homeURL)
        cancelledTap.closeDots()
        let pendingOpen = Task { await cancelledTap.openDots(returnURL: ChatGPTTap.homeURL) }
        try await Task.sleep(for: .milliseconds(80))
        pendingOpen.cancel()
        await pendingOpen.value
        let waiting = cancelledTap.send(requestID: "cancelled-reopen", text: "fixture", conversationID: nil)
        check(cancelled.sent.isEmpty, "W197 cancelling a rapid reopen preserves the previous return hold")
        cancelled.emit(["type":"hello", "loggedIn":true])
        check(cancelled.sent == ["cancelled-reopen"], "W197 cancelled reopen releases sends only after original page hello")
        cancelled.emit(["type":"stream", "id":"cancelled-reopen", "kind":"finished"])
        withExtendedLifetime(waiting) {}
        cancelledTap.sleep()

        let stuck = Pod(running: true), stuckTap = ChatGPTTap(transport: stuck, startupTimeout: .milliseconds(40))
        await stuckTap.openDots(returnURL: ChatGPTTap.homeURL)
        stuckTap.closeDots()
        stuckTap.closeDots()
        try await Task.sleep(for: .milliseconds(100))
        check(stuckTap.connection == .sleeping && !stuck.isRunning && stuckTap.usageCount == 0,
              "W197 missing restore hello closes the old page and releases every lease even after repeated Back")
    }

    private struct FakePage: View {
        let pod: Pod
        var body: some View {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "circle.grid.2x2.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Dots").font(.system(size: 30, weight: .medium))
                Text("自測假頁面").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(["今天的安排", "最近的工作", "新的想法"], id: \.self) { title in
                        Text(title).font(.system(size: 13)).padding(16).chatGlassChip()
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { pod.pagePresented = true }
            .onDisappear { pod.pagePresented = false }
        }
    }

    private final class Pod: FakeTapPod {
        var opens = 0
        var restored: [URL] = []
        var sent: [String] = []

        override func displayPage(_ javascript: String) throws { opens += 1; displayGeneration += 1 }
        override func restoreDisplayedPage(_ url: URL) { restored.append(url) }
        func frame(_ url: String, status: Int = 200) { onDisplayFrame?(url, displayGeneration, false, status) }

        override func respond(_ command: [String: Any], id: String, cmd: String) {

            if cmd == "send" { sent.append(id); return }
            let result: [String: Any]
            switch cmd {
            case "get": result = ["messages":[["id":"fixture-message", "role":"assistant", "text":"原本的 ChatGPT 對話"]]]
            case "list": result = ["items":[["id":"fixture-original", "title":"原本的對話"]], "total":1]
            default: result = [:]
            }
            emit(["type":"result", "id":id, "ok":true, "data":result])
        }
    }
}
#endif
