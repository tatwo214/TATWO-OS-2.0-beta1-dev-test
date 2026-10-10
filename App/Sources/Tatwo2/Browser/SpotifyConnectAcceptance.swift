#if DEBUG
import AppKit
import Combine

/// In-memory stdin/stdout transport. No helper binary, credentials or Spotify connection.
@MainActor
enum SpotifyConnectAcceptance {
    @MainActor private final class Fixture {
        var time = Date(timeIntervalSince1970: 1000)
        var commands: [[String: Any]] = []
        var reconnects = 0
        var cancelledResumes = 0
        var logs: [String] = []
        lazy var app = SpotifyConnect(transport: { [unowned self] line in
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "reconnect" { reconnects += 1 }
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "cancel_resume" { cancelledResumes += 1 }
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                commands.append(object)
            }
        }, now: { [unowned self] in time }, log: { [unowned self] in logs.append($0) })
        func event(_ name: String, _ fields: [String: Any] = [:]) {
            var object = fields
            object["event"] = name
            if name == "transfer_failed" {
                if object["not_found"] == nil { object["not_found"] = false }
                if object["message"] == nil { object["message"] = "fixture failure" }
            }
            if name == "reconnecting", object["delay"] == nil { object["delay"] = 1 }
            let data = try! JSONSerialization.data(withJSONObject: object) + Data([10])
            // Exercise the production line framer, including fragmented stdout.
            let middle = data.count / 2
            app.receive(data.prefix(middle))
            app.receive(data.suffix(data.count - middle))
        }
        var lastID: String { commands.last?["id"] as? String ?? "" }
        func connect(_ id: String = "device-A", resume: Bool = false) {
            event("connected", ["device": SpotifyConnect.deviceName, "device_id": id, "resume": resume])
        }
        func complete() {
            event("active")
            event("transferred", ["id": lastID])
        }
        func stolen(web: Bool = true) {
            // librespot can send inactive before the cluster identifies the thief.
            event("inactive")
            event("device", ["active": false, "web": web, "playing": true])
        }
    }

    static func run() throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else {
            throw BotLibraryError.invalid("w209spotify requires isolated staging")
        }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failed += 1 }
            print("W209SPOTIFY \(value ? "PASS" : "FAIL") \(label)")
        }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!
        func media(_ code: Int, down: Bool = true) -> NSEvent {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | ((down ? 0x0a : 0x0b) << 8),
                data2: 0)!
        }
        let mediaOnly = Fixture(); mediaOnly.connect()
        var queuedAIRequests = ["general-page-agent-request"]
        if TatwoCEFTabHostView.allowsHumanRecovery(media(16), host: "ordinary.example", spotifyInput: mediaOnly.app.spotifyInput) {
            queuedAIRequests.removeAll()
        }
        check(queuedAIRequests == ["general-page-agent-request"] && mediaOnly.commands.isEmpty,
              "W210-7 media key on general AI-controlled page never revokes queued AI requests")
        if TatwoCEFTabHostView.allowsHumanRecovery(media(16), host: SpotifyConnect.spotifyHost, spotifyInput: mediaOnly.app.spotifyInput) {
            queuedAIRequests.removeAll()
        }
        check(queuedAIRequests == ["general-page-agent-request"] && mediaOnly.commands.count == 1,
              "W210-7 Spotify media key transfers only to Spotify without human takeover")
        check(TatwoCEFTabHostView.allowsHumanRecovery(key, host: "ordinary.example", spotifyInput: mediaOnly.app.spotifyInput),
              "W210-7 ordinary keyboard input retains human takeover behavior")
        let gesture = Fixture()
        gesture.connect()
        gesture.app.spotifyInput(click, host: "not-spotify.example", isPageTarget: true)
        gesture.app.spotifyInput(click, host: SpotifyConnect.spotifyHost, isPageTarget: false)
        check(gesture.commands.isEmpty, "foreign host and browser chrome do not transfer")
        gesture.app.spotifyInput(click, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.isEmpty, "S3 mouse click waits for web playback and cannot transfer a pause")
        gesture.event("device", ["active": false, "web": true, "playing": true])
        check(gesture.commands.count == 1 && gesture.commands[0]["device_id"] as? String == "device-A"
              && gesture.commands[0]["resume"] as? Bool == false, "observed web playback after page click transfers to live device")
        gesture.app.spotifyInput(key, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.count == 1, "rapid gestures coalesce while a transfer is pending")
        gesture.complete()
        gesture.event("paused")
        gesture.app.spotifyInput(key, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.count == 1 && !gesture.app.isPlaying, "active-device key gesture does not force playback")
        gesture.stolen(web: false)
        gesture.app.spotifyInput(key, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.count == 2, "page keyboard gesture transfers")
        gesture.complete()
        gesture.stolen(web: false)
        gesture.app.spotifyInput(media(0), host: SpotifyConnect.spotifyHost, isPageTarget: true)
        gesture.app.spotifyInput(media(16, down: false), host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.count == 2, "volume keys and media key-up do not transfer")
        gesture.app.spotifyInput(media(16), host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(gesture.commands.count == 3, "native media play key transfers")
        check(gesture.app.playbackNotice == nil, "normal gestures never show failure text")

        for inactiveFirst in [false, true] {
            let pause = Fixture(); pause.connect(); pause.event("active"); pause.event("playing")
            if inactiveFirst { pause.event("inactive") }
            pause.app.spotifyInput(click, host: SpotifyConnect.spotifyHost, isPageTarget: true)
            pause.event("device", ["active": false, "web": true, "playing": false])
            pause.event("paused")
            check(pause.commands.isEmpty && !pause.app.isPlaying,
                  "S3 pause click never transfers even while ownership is temporarily false")
            check(!BrowserAudibleTabs.shared.playingElsewhere.contains(SpotifyConnect.spotifyHost),
                  "S3 paused event clears browser audible state")
            pause.app.spotifyInput(click, host: SpotifyConnect.spotifyHost, isPageTarget: true)
            pause.event("device", ["active": false, "web": true])
            check(pause.commands.isEmpty, "S3 missing remote playback confirmation cannot start playback")
        }

        let deferred = Fixture()
        deferred.app.spotifyTabOpened()
        check(deferred.commands.isEmpty && deferred.app.playbackNotice == nil, "tab-open waits for helper without a false failure")
        deferred.connect()
        check(deferred.commands.count == 1, "tab-open transfers when connected, with no old four-second timer")
        check(deferred.commands.last?["reason"] as? String == "tab-open", "S2 tab-open reason reaches helper")
        check(gesture.commands.last?["reason"] as? String == "gesture", "S2 explicit gesture reason reaches helper")
        deferred.complete()
        deferred.stolen()
        check(deferred.commands.count == 1, "tab-open without a human gesture never retakes")

        let resume = Fixture()
        resume.connect()
        resume.event("active"); resume.event("playing")
        resume.event("reconnecting")
        resume.connect("device-B", resume: true)
        check(resume.commands.count == 1 && resume.commands[0]["resume"] as? Bool == true
              && resume.commands[0]["device_id"] as? String == "device-B", "reconnect resumes through the new helper device")
        resume.complete(); resume.event("playing")
        check(resume.app.isActive && resume.app.isPlaying
              && resume.logs.contains { $0.contains("reason=reconnect-resume result=success") }, "resume ownership and result are recorded")
        check(BrowserAudibleTabs.shared.playingElsewhere.contains(SpotifyConnect.spotifyHost),
              "helper playback still marks Spotify tabs as audible")
        let noResume = Fixture()
        noResume.connect(resume: false)
        noResume.event("reconnecting")
        noResume.connect("device-C", resume: false)
        check(noResume.commands.isEmpty, "non-owner reconnect does not steal")
        let resumeGesture = Fixture()
        resumeGesture.connect(resume: true)
        let resumeID = resumeGesture.lastID
        resumeGesture.event("active")
        resumeGesture.app.spotifyInput(key, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(resumeGesture.commands.count == 2 && resumeGesture.commands[1]["resume"] as? Bool == false,
              "gesture cancels an in-flight automatic resume even after takeover")
        resumeGesture.event("transfer_failed", ["id": resumeID, "message": "superseded by gesture"])
        resumeGesture.complete(); resumeGesture.event("paused")
        check(!resumeGesture.app.isPlaying && resumeGesture.app.playbackNotice == nil,
              "superseded resume cannot overwrite the gesture or show a stale failure")
        let offlineGesture = Fixture()
        offlineGesture.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        offlineGesture.connect(resume: true)
        check(offlineGesture.commands.count == 1 && offlineGesture.commands[0]["resume"] as? Bool == false,
              "offline gesture supersedes forced reconnect resume")
        let offlineTab = Fixture()
        offlineTab.app.spotifyTabOpened()
        offlineTab.connect("recovered-device", resume: true)
        check(offlineTab.commands.count == 1 && offlineTab.commands[0]["resume"] as? Bool == true,
              "automatic tab-open does not discard an owner's saved reconnect position")

        let retry = Fixture()
        retry.connect()
        retry.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        let oldID = retry.lastID
        retry.event("transfer_failed", ["id": oldID, "not_found": true, "message": "Response status code: 410"])
        check(retry.reconnects == 1 && retry.commands.count == 1 && retry.app.playbackNotice == nil,
              "410 waits for connected, no false failure notice")
        retry.event("reconnecting"); retry.connect("new-device")
        check(retry.commands.count == 2 && retry.commands[1]["device_id"] as? String == "new-device",
              "410 retry uses current device id")
        retry.event("transfer_failed", ["id": retry.lastID, "not_found": true, "message": "Response status code: 404"])
        check(retry.reconnects == 1 && retry.app.playbackNotice == "Spotify 這次沒接手，再按一次播放"
              && retry.logs.contains { $0.contains("reason=gesture result=failed") },
              "second failure stops retry, logs result and shows the one-line notice")
        retry.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        retry.complete()
        check(retry.app.playbackNotice == nil, "later successful gesture clears failure text")
        let notFound = Fixture()
        notFound.connect(); notFound.app.spotifyTabOpened()
        notFound.event("transfer_failed", ["id": notFound.lastID, "not_found": true])
        notFound.connect("another-device")
        notFound.complete()
        check(notFound.commands.count == 2 && notFound.app.playbackNotice == nil,
              "librespot NotFound protocol retries once and successful retry stays quiet")
        let resumeRetry = Fixture()
        resumeRetry.connect(resume: true)
        resumeRetry.event("transfer_failed", ["id": resumeRetry.lastID, "not_found": true])
        resumeRetry.connect("resume-retry-device", resume: true)
        resumeRetry.event("transfer_failed", ["id": resumeRetry.lastID, "not_found": true])
        check(resumeRetry.commands.count == 2 && resumeRetry.reconnects == 1 && resumeRetry.cancelledResumes == 1
              && resumeRetry.app.playbackNotice != nil,
              "reconnect resume keeps the one-retry budget rather than restarting it on each connected event")
        resumeRetry.connect("later-non-owner-device")
        check(resumeRetry.commands.count == 2, "terminal resume failure abandons the snapshot instead of stealing on a later reconnect")
        let slowRetry = Fixture()
        slowRetry.connect(); slowRetry.app.spotifyTabOpened()
        let slowID = slowRetry.lastID
        slowRetry.event("transfer_failed", ["id": slowID, "not_found": true, "message": "Response status code: 404"])
        slowRetry.time.addTimeInterval(13)
        slowRetry.app.expireTransfer(id: slowID)
        check(slowRetry.app.playbackNotice == nil, "retry waits for registration longer than the old attempt timeout")
        slowRetry.connect("slow-device"); slowRetry.complete()
        check(slowRetry.commands.count == 2 && slowRetry.app.playbackNotice == nil,
              "slow but successful re-registration retries normally")
        let authFailure = Fixture()
        authFailure.connect(); authFailure.app.spotifyTabOpened()
        authFailure.event("needs_login")
        check(authFailure.app.playbackNotice != nil && authFailure.app.status == .signedOut,
              "actual authentication failure cannot silently leave a pending transfer")

        for reason in ["active", "leave-page"] {
            let clearing = Fixture(); clearing.connect()
            clearing.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
            clearing.time.addTimeInterval(13); clearing.app.expireTransfer(id: clearing.lastID)
            check(clearing.app.playbackNotice != nil, "W210-L notice counterexample starts with a real failed transfer")
            if reason == "active" { clearing.event("active") }
            else { clearing.app.spotifyPageChanged(host: "ordinary.example") }
            check(clearing.app.playbackNotice == nil, "W210-L Spotify notice clears on " + reason)
        }

        let guardTest = Fixture()
        guardTest.connect()
        guardTest.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        guardTest.complete()
        for _ in 0..<3 { guardTest.stolen(); guardTest.complete() }
        check(guardTest.commands.last?["reason"] as? String == "retake", "S2 retake reason reaches helper")
        check(guardTest.commands.count == 3, "web-player retake is capped at two per rolling minute")
        guardTest.time.addTimeInterval(61)
        guardTest.stolen(); guardTest.complete()
        check(guardTest.commands.count == 4, "retake budget resets after a rolling minute")
        guardTest.stolen(web: false); guardTest.complete()
        check(guardTest.commands.count == 4, "phone or native device is never retaken")
        guardTest.time.addTimeInterval(60)
        guardTest.stolen()
        check(guardTest.commands.count == 4, "no retake after two minutes without an OS gesture")
        check(guardTest.logs.filter { $0.contains("reason=retake") && $0.contains("result=requested") }.count == 3,
              "each retake has a reason and bounded request log")

        let network = Fixture()
        network.connect()
        network.app.networkChanged(satisfied: true)
        network.app.networkChanged(satisfied: false)
        network.app.networkChanged(satisfied: true)
        network.app.networkChanged(satisfied: true)
        check(network.reconnects == 1, "network recovery sends one immediate reconnect, initial path does not")
        network.event("reconnecting")
        network.app.networkChanged(satisfied: false); network.app.networkChanged(satisfied: true)
        check(network.reconnects == 2, "network recovery interrupts connecting/backoff too")
        network.event("needs_login")
        network.app.networkChanged(satisfied: false); network.app.networkChanged(satisfied: true)
        check(network.reconnects == 2, "signed-out helper is not reconnected by a network change")
        let timeout = Fixture()
        timeout.connect(); timeout.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        let timeoutID = timeout.lastID
        timeout.app.expireTransfer(id: timeoutID)
        check(timeout.app.playbackNotice == nil, "no early timeout notice")
        timeout.time.addTimeInterval(13)
        timeout.app.expireTransfer(id: timeoutID)
        check(timeout.app.playbackNotice != nil, "silent helper timeout is a real visible failure")
        let stale = Fixture()
        stale.connect(); stale.app.spotifyGesture(host: SpotifyConnect.spotifyHost)
        stale.event("transfer_failed", ["id": "old-request", "not_found": true, "message": "Response status code: 410"])
        check(stale.reconnects == 0 && stale.app.playbackNotice == nil, "unrelated old responses cannot fail a current transfer")
        let missingDevice = Fixture()
        missingDevice.connect("")
        missingDevice.app.spotifyTabOpened()
        check(missingDevice.commands.isEmpty && missingDevice.app.playbackNotice != nil,
              "invalid helper device id fails visibly instead of waiting silently")
        let quiet = Fixture()
        quiet.connect(); quiet.event("active")
        var notifications = 0
        let observation = quiet.app.objectWillChange.sink { notifications += 1 }
        quiet.event("device", ["active": true, "web": false])
        quiet.event("device", ["active": true, "web": false])
        quiet.app.spotifyInput(key, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        quiet.app.spotifyInput(click, host: SpotifyConnect.spotifyHost, isPageTarget: true)
        check(notifications == 0, "unchanged cluster state does not redraw all native browser surfaces")
        observation.cancel()
        check(deferred.logs.contains { $0.contains("reason=tab-open result=success") }
              && gesture.logs.contains { $0.contains("reason=gesture result=success") },
              "tab-open and gesture results use the same transfer logging")
        let unconfirmed = Fixture(); unconfirmed.app.spotifyTabOpened()
        unconfirmed.event("connected", ["device_id": "unconfirmed-device", "unconfirmed": true, "resume": false])
        check(unconfirmed.app.status == .connected && unconfirmed.commands.count == 1
              && unconfirmed.logs.contains("helper event=connected unconfirmed=true"), "S1b unconfirmed registration enables transfer and records the fallback")
        unconfirmed.event("transfer_failed", ["id": unconfirmed.lastID, "not_found": true])
        check(unconfirmed.reconnects == 1, "S1b unconfirmed not-found uses the existing reconnect retry")
        unconfirmed.event("connected", ["device_id": "retried-device", "unconfirmed": true, "resume": false])
        check(unconfirmed.commands.count == 2 && unconfirmed.commands.last?["device_id"] as? String == "retried-device",
              "S1b unconfirmed retry transfers to the current device")
        unconfirmed.event("transfer_failed", ["id": unconfirmed.lastID, "not_found": true])
        check(unconfirmed.reconnects == 1 && unconfirmed.app.playbackNotice != nil, "S1b unconfirmed registration cannot restart the one-retry budget")
        let diagnostics = Fixture(); diagnostics.connect()
        for kind in ["playing", "paused", "active", "inactive"] {
            diagnostics.event(kind, ["name": "PRIVATE TRACK", "uri": "PRIVATE-URI", "account": "PRIVATE-ACCOUNT"])
            check(diagnostics.logs.contains("helper event=" + kind), "S4 records helper event " + kind)
        }
        diagnostics.event("device", ["active": false, "web": true, "name": "PRIVATE DEVICE"])
        check(diagnostics.logs.contains("helper event=device active=false web=true"), "S4 device log contains only booleans")
        for fields in [["pause": true, "play": false], ["pause": false, "play": true], ["pause": false, "play": false]] {
            diagnostics.event("transfer_options", fields)
            check(diagnostics.logs.contains("helper event=transfer_options pause=\(fields["pause"]!) play=\(fields["play"]!)"),
                  "S4 logs actual helper transfer options")
        }
        for reason in ["registration-timeout", "task-ended", "connect-failed", "requested", "session-invalid"] {
            diagnostics.event("reconnecting", ["reason": reason])
            check(diagnostics.logs.contains("helper event=reconnecting reason=" + reason), "S4 records reconnect reason " + reason)
        }
        diagnostics.event("reconnecting", ["reason": "PRIVATE-ACCOUNT"])
        diagnostics.event("error", ["message": "PRIVATE-URI"])
        diagnostics.app.spotifyGesture(host: SpotifyConnect.spotifyHost); diagnostics.connect()
        diagnostics.event("transfer_failed", ["id": diagnostics.lastID, "message": "PRIVATE-URI"])
        check(diagnostics.logs.contains("helper event=reconnecting reason=unknown")
              && !diagnostics.logs.joined().contains("PRIVATE"), "S4 helper payload cannot leak private identifiers into app.log")
        print("W209SPOTIFY SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
