#if DEBUG
import Foundation

/// In-memory transport only. No account, CEF, microphone, or network.
@MainActor enum W217VoiceAcceptance {
    static func run() async throws -> Bool {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("W217VOICE \(condition ? "PASS" : "FAIL") \(name)")
        }
        func wait(_ seconds: Double, _ predicate: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }
        for entry in ["Space", "DM"] {
            for failure in ["permission", "pageSilent", "403", "timeout", "neverLive"] {
                let pod = Pod(failure)
                let tap = ChatGPTTap(transport: pod, connection: .ready)
                let voice = entry == "Space" ? ChatGPTSpaceModel(testTap: tap).voice : ChatGPTConversationSession(tap: tap).voice
                voice.stopTimeout = .milliseconds(50)
                voice.stateTimeout = .milliseconds(50)
                voice.stopPause = .milliseconds(10)
                voice.startTimeout = .seconds(6)
                var finishes = 0
                voice.finished = { _ in finishes += 1 }
                check(voice.startVoice(), "\(entry).\(failure).starts")
                let recovered = await wait(7) { !voice.voiceActive && tap.voiceClaim == nil && !tap.voiceOpen }
                check(recovered && !voice.voiceLive && !voice.voiceStopping && finishes == 1,
                      "\(entry).\(failure).boundedRecovery")
                check(voice.voiceStatus.contains("語音沒開起來") && !voice.voiceStatus.contains("\n"),
                      "\(entry).\(failure).oneLineReason")
                // Reopen the fake page just as the production Pod does after a forced close.
                if !pod.isRunning { try pod.start(); pod.emit(["type": "hello", "loggedIn": true]) }
                pod.failure = "success"
                // The failed request resumes asynchronously; its paging defer must finish before retry.
                let retryReady = await wait(1) { voice.canStart }
                if !retryReady { print("W217VOICE retry blocked: \(tap.voiceStartBlocker ?? "voice active")") }
                check(retryReady && voice.canStart && voice.startVoice(), "\(entry).\(failure).retry")
                let retryLive = await wait(1) { voice.voiceLive }
                check(retryLive, "\(entry).\(failure).retryBecomesLive")
                voice.stopVoice()
                _ = await wait(1) { !voice.voiceActive }
                check(!voice.voiceActive && tap.voiceClaim == nil, "\(entry).\(failure).stopAfterRetry")
                tap.sleep()
            }
        }
        for phase in ["starting", "listening", "pollSilent", "stopSilent"] {
            let pod = Pod(phase == "starting" ? "pageSilent" : "success")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            let voice = ChatGPTVoiceMode(tap: tap)
            _ = voice.startVoice()
            _ = await wait(1) { !pod.commands.isEmpty }
            if phase != "starting" { _ = await wait(1) { voice.voiceLive } }
            if phase == "pollSilent" { pod.silent = true }
            if phase == "stopSilent" || phase == "starting" { pod.silent = true }
            voice.stopVoice()
            if phase == "stopSilent" { voice.stopVoice() }
            let stoppedAt = ContinuousClock.now
            let stopped = await wait(4) { !voice.voiceActive && tap.voiceClaim == nil }
            check(stopped && !voice.voiceLive && !voice.voiceStopping, "\(phase).stopAlwaysEnds")
            check(stopped && stoppedAt.duration(to: .now) < .milliseconds(3200), "\(phase).stopWithinThreeSeconds")
            check(!pod.isRunning || !pod.live, "\(phase).microphoneCannotRemainLive")
            tap.sleep()
        }
        do {
            let pod = Pod("success")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            tap.voiceMicrophonePermission = { false }
            let voice = ChatGPTVoiceMode(tap: tap)
            _ = voice.startVoice()
            let denied = await wait(1) { !voice.voiceActive && tap.voiceClaim == nil }
            check(denied && voice.voiceStatus.contains("沒有麥克風權限") && pod.commands.isEmpty,
                  "permission.deniedNeverReachesPage")
            tap.sleep()
        }
        do {
            let pod = Pod("success")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            var decision: CheckedContinuation<Bool, Never>?
            tap.voiceMicrophonePermission = { await withCheckedContinuation { decision = $0 } }
            let voice = ChatGPTVoiceMode(tap: tap)
            voice.stopTimeout = .milliseconds(50)
            voice.stateTimeout = .milliseconds(50)
            voice.stopPause = .milliseconds(10)
            _ = voice.startVoice()
            _ = await wait(1) { decision != nil }
            voice.stopVoice()
            let stopped = await wait(4) { !voice.voiceActive && tap.voiceClaim == nil }
            check(stopped && !pod.live, "permission.pendingStopReleasesClaim")
            if !pod.isRunning { try pod.start(); pod.emit(["type": "hello", "loggedIn": true]) }
            tap.voiceMicrophonePermission = { true }
            _ = voice.startVoice()
            _ = await wait(1) { voice.voiceLive }
            decision?.resume(returning: true)
            try? await Task.sleep(for: .milliseconds(100))
            check(voice.voiceLive && pod.commands.filter { $0["cmd"] as? String == "voice" && $0["stop"] == nil }.count == 1,
                  "permission.lateGrantCannotStartOrStopNewSession")
            voice.stopVoice()
            _ = await wait(1) { !voice.voiceActive }
            tap.sleep()
        }
        do {
            let pod = Pod("success")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            let voice = ChatGPTVoiceMode(tap: tap)
            voice.stateTimeout = .milliseconds(50)
            voice.statePause = .milliseconds(50)
            _ = voice.startVoice()
            _ = await wait(1) { voice.voiceLive }
            pod.silent = true
            let ended = await wait(3) { !voice.voiceActive && tap.voiceClaim == nil }
            check(ended && !pod.live, "pollFailureAutomaticallyClosesPage")
            tap.sleep()
        }
        for entry in ["Space", "DM"] {
            for misses in [1, 2, 3] {
                let pod = Pod("success")
                let tap = ChatGPTTap(transport: pod, connection: .ready)
                let voice = entry == "Space" ? ChatGPTSpaceModel(testTap: tap).voice : ChatGPTConversationSession(tap: tap).voice
                voice.stateTimeout = .milliseconds(50)
                voice.statePause = .milliseconds(100)
                var finishes = 0
                voice.finished = { _ in finishes += 1 }
                _ = voice.startVoice()
                _ = await wait(1) { voice.voiceLive }
                pod.stateMisses = misses
                let prefix = "\(entry).live.\(misses)Timeouts"
                _ = await wait(2) { pod.stateMisses == 0 }
                try? await Task.sleep(for: .milliseconds(80))
                if misses < 3 {
                    check(voice.voiceActive && voice.voiceLive && pod.isRunning && finishes == 0, "\(prefix).survives")
                    _ = await wait(1) { pod.successfulStates > 0 }
                    pod.stateMisses = 2
                    _ = await wait(2) { pod.stateMisses == 0 }
                    try? await Task.sleep(for: .milliseconds(80))
                    check(voice.voiceLive && finishes == 0, "\(prefix).successfulStateResetsMisses")
                    voice.stopVoice()
                    _ = await wait(1) { !voice.voiceActive }
                } else {
                    let ended = await wait(1) { !voice.voiceActive && tap.voiceClaim == nil }
                    check(ended && pod.stateMisses == 0 && !pod.live && !pod.isRunning && finishes == 1, "\(prefix).closes")
                    check(voice.voiceStatus.contains("網頁狀態沒有回應") && !voice.voiceStatus.contains("\n"), "\(prefix).oneLineReason")
                }
                tap.sleep()
            }
        }
        do {
            let pod = Pod("success")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            tap.voiceMicrophonePermission = {
                try? await Task.sleep(for: .seconds(10))
                return true
            }
            let voice = ChatGPTVoiceMode(tap: tap)
            _ = voice.startVoice()
            try? await Task.sleep(for: .seconds(7))
            check(voice.voiceActive && pod.commands.isEmpty && tap.voiceClaim != nil, "permission.tenSecondPrompt.notTimedOut")
            let started = await wait(4) { voice.voiceLive }
            check(started && pod.live, "permission.tenSecondPrompt.startsNormally")
            voice.stopVoice()
            _ = await wait(1) { !voice.voiceActive }
            tap.sleep()
        }
        for delay in [5, 12] {
            let pod = Pod("pageSilent")
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            let voice = ChatGPTVoiceMode(tap: tap)
            _ = voice.startVoice()
            _ = await wait(1) { !pod.commands.isEmpty }
            if delay == 5 {
                try? await Task.sleep(for: .seconds(5))
                pod.live = true
                if let command = pod.commands.first, let id = command["id"] as? String {
                    pod.emit(["type": "result", "id": id, "ok": true, "data": ["live": true]])
                }
                let started = await wait(1) { voice.voiceLive }
                check(started && pod.live, "page.fiveSecondStart.succeeds")
                voice.stopVoice()
                _ = await wait(1) { !voice.voiceActive }
            } else {
                try? await Task.sleep(for: .seconds(10))
                check(voice.voiceActive && !voice.voiceLive, "page.twelveSecondDeadline.doesNotExpireEarly")
                let ended = await wait(3) { !voice.voiceActive && tap.voiceClaim == nil }
                check(ended && !pod.live && !voice.voiceStopping, "page.twelveSecondDeadline.recovers")
                check(voice.voiceStatus.contains("語音沒開起來") && !voice.voiceStatus.contains("\n"), "page.twelveSecondDeadline.oneLineReason")
            }
            tap.sleep()
        }
        print("W217VOICE SUMMARY \(checks) checks, \(failures) failures")
        return failures == 0
    }

    @MainActor final class Pod: FakeTapPod {
        var failure: String
        var silent = false, live = false
        var stateMisses = 0, successfulStates = 0
        init(_ failure: String) { self.failure = failure; super.init(running: true) }
        override func stop() { super.stop(); live = false }
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            if silent { return }
            if cmd == "voiceState" {
                if stateMisses > 0 { stateMisses -= 1; return }
                successfulStates += 1
            }
            if cmd == "voice", command["stop"] as? Bool != true {
                switch failure {
                case "permission", "403", "timeout":
                    let reason = failure == "permission" ? "沒有麥克風權限" : failure == "403" ? "事件通道被拒（403）" : "連線逾時"
                    emit(["type": "result", "id": id, "ok": false, "message": reason]); return
                case "pageSilent": return
                default: live = failure != "neverLive"
                }
            } else if cmd == "voice" { live = false }
            emit(["type": "result", "id": id, "ok": true, "data": ["live": live]])
        }
    }
}
#endif
