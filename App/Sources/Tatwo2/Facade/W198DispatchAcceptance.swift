#if DEBUG
import Darwin
import Foundation

/// Real native dispatch/bridge/TAP over a fake Pod, wholly under the isolated root.
@MainActor
enum W198DispatchAcceptance {
    static func run() async throws -> Bool {
        let syntheticMailbox = ["fixture", "example.invalid"].joined(separator: "@")
        var failures = 0, passed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures += 1 }
            print("W198 \(condition ? "PASS" : "FAIL") \(label)")
        }
        defer { print("W198 SUMMARY failures=\(failures) passed=\(passed)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let liveRoot = env["TATWO2_LIVE_ROOT"] else { throw ChatGPTDispatch.Failure("isolated_root_required") }
        let root = URL(fileURLWithPath: liveRoot).appendingPathComponent("w198-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(previous) }
        ChatGPTTapModelCatalog.replace([])
        let pod = DispatchTapPod()
        let tap = ChatGPTTap(transport: pod, connection: .sleeping, stopDeadline: .milliseconds(100))
        let journal = HandsRoomJournal(url: root.appendingPathComponent("chatgpt-room.json"))
        let dispatcher = ChatGPTDispatch(tap: tap, mapper: TapProjectMapper(tap: tap, inboxFolder: root.appendingPathComponent("inbox")), journal: journal)
        defer { tap.sleep() }
        let room = root.appendingPathComponent("room")
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        let project = engine.newProject(name: "Dispatch Fixture", workdir: root.path)
        let parent = engine.newThread(in: project), caller = engine.newThread(in: project)
        engine.configureRoom(threadID: caller, parentThreadID: parent, roomBrief: "fixture", engine: "codex", cwdOverride: room.path)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        let bridge = OSAgentBridge.chatGPTDispatchTestBridge(model: model, dispatcher: dispatcher)
        defer { engine.shutdownAll() }
        let arguments: [String: Any] = ["text": "unique-ticket-body Review the fixture and report evidence.", "model": "fixture-model", "title": "Fixture review", "timeoutSeconds": 5]
        func bridgeCall(_ method: String, _ args: [String: Any], from: OSSocketCaller = .engine(caller)) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": args])
            let response = await Task.detached { bridge.respondForSelfTest(caller: from, request: data) }.value
            return try JSONSerialization.jsonObject(with: response) as! [String: Any]
        }
        let success = Task { try await bridgeCall("chatgpt_dispatch", arguments) }
        try await until { pod.sends.count == 1 }
        let sent = pod.sends[0], id = sent["id"] as! String
        check(pod.starts == 1 && !pod.hidden && pod.hiddenCommands == 0, "sleeping Pod wakes with W195 background lease before preparation and send")
        check(sent["conversationID"] == nil && sent["gizmoID"] as? String == "g-p-fixture" && sent["model"] as? String == "fixture-model",
              "NEW conversation uses native catalog model and defined inbox project")
        check(pod.projectName == "TATWO · 收件匣", "omitted destination uses TATWO inbox")
        let outgoing = sent["text"] as! String
        check(outgoing.hasPrefix(arguments["text"] as! String) && outgoing.contains(room.lastPathComponent) && !outgoing.contains(room.path) && !outgoing.contains("/Users/") && !outgoing.contains("/Volumes/")
              && outgoing.contains("project_id=" + project.uuidString) && outgoing.contains("write_report")
              && outgoing.contains("只使用已授權"), "fixed instructions carry calling room, authorized tools and correct report routing")
        pod.emit(["type": "stream", "id": id, "kind": "conversation", "conversationID": "fixture-conversation"])
        pod.emit(["type": "stream", "id": id, "kind": "text", "messageID": "analysis", "full": "First draft"])
        pod.emit(["type": "stream", "id": id, "kind": "text", "messageID": "analysis", "full": "First final"])
        pod.emit(["type": "stream", "id": id, "kind": "text", "messageID": "final", "full": "Second reply\nline2\nline3\nline4\nline5\nline6"])
        pod.emit(["type": "stream", "id": id, "kind": "finished"])
        let response = try await success.value
        let receipt = response["result"] as! [String: Any]
        check(receipt["status"] as? String == "completed" && receipt["conversationID"] as? String == "fixture-conversation", "completion returns conversation ID and completed status")
        let reply = URL(fileURLWithPath: receipt["replyPath"] as! String)
        let content = try String(contentsOf: reply, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: reply.path)
        // Compare resolved paths: a /private/var scratch root and its /var spelling are the same folder.
        check(reply.deletingLastPathComponent().resolvingSymlinksInPath().path == room.appendingPathComponent("chatgpt-dispatch").resolvingSymlinksInPath().path
              && reply.lastPathComponent == (receipt["dispatchID"] as! String) + ".md"
              && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600
              && content.hasSuffix("First final\n\nSecond reply\nline2\nline3\nline4\nline5\nline6") && !content.contains("First draft"),
              "private Markdown contains full latest snapshots of all reply messages at declared calling-room path")
        check((receipt["summary"] as? String)?.components(separatedBy: "\n").count == 5 && pod.renames.last == "Fixture review", "five-line summary and requested title are returned/applied")
        // No parent ignore file: actual dispatcher output in an otherwise empty repository.
        func git(_ args: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args; process.currentDirectoryURL = room
            process.standardOutput = output; process.standardError = Pipe()
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ChatGPTDispatch.Failure("fixture_git_failed") }
            return String(decoding: data, as: UTF8.self)
        }
        _ = try git(["init", "-q"]); _ = try git(["add", "-A"])
        check(try git(["diff", "--cached", "--name-only"]).isEmpty,
              "W205-3 git add -A in empty foreign repo never stages actual reply or ignore file")
        let row = journal.rows(projectID: project).last!
        let rawRow = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        check(row.tool == "chatgpt_dispatch" && row.projectID == project
              && row.summary.contains(caller.uuidString) && row.summary.contains("模型：fixture-model")
              && row.summary.contains("派工：完成") && row.summary.contains(reply.lastPathComponent)
              && !rawRow.contains("unique-ticket-body") && !rawRow.contains("Second reply"), "ChatGPT room retains caller/model/status/path metadata without ticket or reply text")
        try await until { !tap.hasActiveUsers }
        check(pod.hidden, "completed dispatch releases background lease")
        let longTitle = String(repeating: "派", count: 200)
        check((try? ChatGPTDispatch.Request.parse(["text": "x", "model": "m", "title": longTitle])) != nil
              && (try? ChatGPTDispatch.Request.parse(["text": "x", "model": "m", "title": longTitle + "工"])) == nil,
              "title limit counts characters like the MCP schema, not UTF-8 bytes")

        let count = pod.sends.count
        for secret in [["sk", "proj", String(repeating: "A", count: 30)].joined(separator: "-"), "password: short", ["-----BEGIN ", "PRIVATE KEY-----", "\nfixture\n", "-----END ", "PRIVATE KEY-----"].joined(), "Bearer\nabcdefgh12345678", String(repeating: "Abc123", count: 12), "/Users/fixture/private.txt"] {
            var args = arguments; args["text"] = secret
            let result = try await bridgeCall("chatgpt_dispatch", args)["result"] as! [String: Any]
            check(result["status"] as? String == "not_submitted" && result["replyPath"] is NSNull && pod.sends.count == count,
                  "secret/password/private-key/base64/bearer/PII rejected without TAP send")
        }
        for (fixture, category) in [(syntheticMailbox, "contact_data_rejected"), ("+886 912 345 678", "contact_data_rejected"),
                                     ("phone=2025550143", "contact_data_rejected"), ("phone=12345678", "contact_data_rejected"),
                                     ("0912-345-678", "contact_data_rejected"), ("/Volumes/fixture/private.txt", "local_path_rejected"),
                                     ("password=abc", "credentials_rejected")] {
            var args = arguments; args["text"] = "Review synthetic fixture. " + fixture
            let result = try await bridgeCall("chatgpt_dispatch", args)["result"] as! [String: Any]
            check(result["status"] as? String == "not_submitted" && result["reason"] as? String == "chatgpt_dispatch_" + category
                  && pod.sends.count == count, "W203-3 dispatch rejects full contact/path/short-password ticket with category")
        }
        for tail in ["password:", "pwd=   "] {
            var args = arguments; args["text"] = "synthetic ticket\n" + tail; args["timeoutSeconds"] = 1
            check(ChatGPTDispatch.rejectionCategory(args["text"] as! String) == nil, "W207 bare credential label reaches the payload seam")
            let result = try await bridgeCall("chatgpt_dispatch", args)["result"] as! [String: Any]
            check(result["status"] as? String == "not_submitted" && result["reason"] as? String == "chatgpt_dispatch_credentials_rejected"
                  && pod.sends.count == count, "W207 final payload scan rejects credentials spanning ticket and OS note")
        }
        let unsafeRoom = root.appendingPathComponent("password=fixture")
        try FileManager.default.createDirectory(at: unsafeRoom, withIntermediateDirectories: true)
        let noteResult = await dispatcher.dispatch(try ChatGPTDispatch.Request.parse(arguments), caller: caller, room: unsafeRoom,
                                                   projectID: project, destination: nil)
        check(noteResult.status == "not_submitted" && noteResult.reason == "chatgpt_dispatch_credentials_rejected"
              && pod.sends.count == count, "W203-3 final OS-added room note is scanned before TAP send")
        let homeNamed = root.appendingPathComponent(NSUserName())
        check(ChatGPTDispatch.roomLabel(homeNamed) == "~" && ChatGPTDispatch.roomLabel(room) == room.lastPathComponent
              && ChatGPTDispatch.roomLabel(unsafeRoom) == unsafeRoom.lastPathComponent
              && ChatGPTDispatch.rejectionCategory("ticket" + ChatGPTDispatch.instructions.replacingOccurrences(of: "{{room}}", with: ChatGPTDispatch.roomLabel(homeNamed))) == nil,
              "W342 home-named calling room is labelled ~ so the account name is neither sent nor blocks the ticket")
        check(ChatGPTDispatch.roomLabel(root.appendingPathComponent("a\nb\u{2028}c")) == "a b c", "W344 room label drops control and line separator characters")

        var metadataSecret = arguments; metadataSecret["model"] = "password=short"
        let metadataResult = try await bridgeCall("chatgpt_dispatch", metadataSecret)["result"] as! [String: Any]
        let metadataRow = journal.rows(projectID: project).last!
        let encodedMetadata = String(decoding: try JSONEncoder().encode(metadataRow), as: UTF8.self)
        check(metadataResult["status"] as? String == "not_submitted" && metadataRow.summary.contains("模型：[rejected]")
              && !encodedMetadata.contains("password=short"),
              "rejected secret in model metadata is never written to journal")
        let file = room.appendingPathComponent("ticket.md")
        try Data("file ticket fixture".utf8).write(to: file)
        var fileArgs = arguments; fileArgs["text"] = nil; fileArgs["ticketPath"] = "ticket.md"
        let fileTask = Task { try await bridgeCall("chatgpt_dispatch", fileArgs) }
        try await until { pod.sends.count == count + 1 }
        check((pod.sends.last?["text"] as? String)?.hasPrefix("file ticket fixture") == true, "ticket file is safely read inside calling room")
        let foreign = try await bridgeCall("chatgpt_dispatch_stop", [:], from: .engine(UUID()))
        check((foreign["result"] as? [String: Any])?["stopped"] as? Bool == false, "another engine cannot stop caller dispatch")
        let stopped = try await bridgeCall("chatgpt_dispatch_stop", [:])
        let fileResult = try await fileTask.value["result"] as! [String: Any]
        check((stopped["result"] as? [String: Any])?["stopped"] as? Bool == true
              && fileResult["status"] as? String == "failed" && fileResult["stopped"] as? Bool == true
              && pod.stops.last == pod.sends.last?["id"] as? String, "in-flight stop targets own TAP request and returns uncertain stopped receipt")
        try await until { !tap.hasActiveUsers }
        // Outside, symlink, hardlink and FIFO inputs must never reach TAP.
        let outside = root.appendingPathComponent("outside.md")
        try Data("outside fixture".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: room.appendingPathComponent("link.md"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: room.appendingPathComponent("hard.md"))
        _ = mkfifo(room.appendingPathComponent("pipe.md").path, 0o600)
        for path in ["../outside.md", outside.path, "link.md", "hard.md", "pipe.md"] {
            var args = fileArgs; args["ticketPath"] = path
            let result = try await bridgeCall("chatgpt_dispatch", args)["result"] as! [String: Any]
            check(result["status"] as? String == "not_submitted" && pod.sends.count == count + 1, "outside/symlink/hardlink/FIFO ticket rejected without send")
        }
        for from in [OSSocketCaller.externalAI, .app, .helper, .job(caller), .ssh, .other(pid: nil)] {
            let result = try await bridgeCall("chatgpt_dispatch", arguments, from: from)
            let stop = try await bridgeCall("chatgpt_dispatch_stop", [:], from: from)
            check(result["error"] as? String == "caller_not_trusted" && stop["error"] as? String == "caller_not_trusted", "native caller classification denies dispatch/stop for \(from.label)")
        }
        var spoof = arguments; spoof["callerThreadID"] = UUID().uuidString
        let mismatch = try await bridgeCall("chatgpt_dispatch", spoof)
        check(mismatch["error"] as? String == "caller_thread_mismatch", "bound caller cannot impersonate another construction room")
        for invalid in [["text": "a", "ticketPath": "ticket.md", "model": "fixture-model", "title": "x"],
                        ["text": "a", "model": "fixture-model", "title": "x", "timeoutSeconds": true],
                        ["text": "a", "model": "fixture-model", "title": "x", "timeoutSeconds": 0],
                        ["text": "a", "model": "fixture-model", "title": "x", "projectID": "bad"]] as [[String: Any]] {
            let result = try await bridgeCall("chatgpt_dispatch", invalid)
            check(result["error"] as? String == "chatgpt_dispatch_invalid_arguments", "native argument validation rejects malformed request")
        }
        for (field, value) in [("text", ""), ("text", "   "), ("text", false), ("text", "x\0"),
                               ("text", String(repeating: "x", count: 65537)), ("title", "x\nspoof"),
                               ("title", String(repeating: "x", count: 201)), ("model", "x\tspoof"),
                               ("model", 1), ("timeoutSeconds", "60"), ("timeoutSeconds", 1801),
                               ("timeoutSeconds", 1.5), ("timeoutSeconds", 1e100), ("ticketPath", "")] as [(String, Any)] {
            var invalid = arguments; invalid[field] = value
            if field == "ticketPath" { invalid["text"] = nil }
            let result = try await bridgeCall("chatgpt_dispatch", invalid)
            check(result["error"] as? String == "chatgpt_dispatch_invalid_arguments", "W207 native owner rejects each formerly duplicated MCP field rule")
        }
        for invalid in [[:], ["model": "fixture-model", "title": "x"], ["text": "x", "title": "x"], ["text": "x", "model": "fixture-model"]] as [[String: Any]] {
            let result = try await bridgeCall("chatgpt_dispatch", invalid)
            check(result["error"] as? String == "chatgpt_dispatch_invalid_arguments", "W207 native owner retains all required-field checks")
        }
        // Submitted timeout must preserve partial data without claiming completion.
        var short = arguments; short["timeoutSeconds"] = 1; short["text"] = "unique timeout fixture"
        let timeoutTask = Task { try await bridgeCall("chatgpt_dispatch", short) }
        try await until { pod.sends.count == count + 2 }
        let timeoutID = pod.sends.last!["id"] as! String
        pod.emit(["type": "stream", "id": timeoutID, "kind": "conversation", "conversationID": "timeout-conversation"])
        pod.emit(["type": "stream", "id": timeoutID, "kind": "text", "full": "partial fixture"])
        let timed = try await timeoutTask.value["result"] as! [String: Any]
        check(timed["status"] as? String == "timed_out" && pod.stops.last == timeoutID
              && timed["replyPath"] is String, "submitted timeout stops own request and saves explicitly partial reply")
        let partialPath = timed["replyPath"] as! String
        let partial = try String(contentsOfFile: partialPath, encoding: .utf8)
        check(partial.contains("status: timed_out") && partial.hasSuffix("partial fixture"), "partial Markdown labels timed_out instead of completed")
        let beforeRetry = pod.sends.count
        let retry = try await bridgeCall("chatgpt_dispatch", short)["result"] as! [String: Any]
        check(retry["dispatchID"] as? String == timed["dispatchID"] as? String && retry["status"] as? String == "timed_out"
              && pod.sends.count == beforeRetry, "W203-3 retry after timeout returns same receipt without resending the ticket")
        check(dispatcher.releaseUncertain(caller: UUID()) == 0, "W205-4 another caller cannot clear a real uncertain receipt")
        // 先前停止的那張已送出、仍未確認（Sol .058 S-A），加上這張逾時的＝2。
        check(dispatcher.releaseUncertain(caller: caller) == 2, "W205-4 caller can explicitly clear its real uncertain receipts, including one it stopped after sending")
        pod.emit(["type": "stream", "id": timeoutID, "kind": "finished"])
        check(try String(contentsOfFile: partialPath, encoding: .utf8) == partial, "late completion cannot overwrite timeout receipt")
        try await until { !tap.hasActiveUsers }
        tap.sleep(); pod.autoHello = false
        let beforeWake = pod.sends.count
        let wakeTask = Task { try await bridgeCall("chatgpt_dispatch", arguments) }
        try await until { tap.connection == .starting }
        _ = try await bridgeCall("chatgpt_dispatch_stop", [:])
        let wakeResult = try await wakeTask.value["result"] as! [String: Any]
        pod.emit(["type": "hello", "loggedIn": true])
        try await Task.sleep(for: .milliseconds(50))
        check(wakeResult["status"] as? String == "not_submitted" && wakeResult["stopped"] as? Bool == true && pod.sends.count == beforeWake,
              "stop during W195 wake and late hello never submits cancelled ticket")
        tap.sleep()
        var wakeTimeoutArgs = short; wakeTimeoutArgs["text"] = "unique unsent wake timeout fixture"
        let wakeTimeout = try await bridgeCall("chatgpt_dispatch", wakeTimeoutArgs)["result"] as! [String: Any]
        check(wakeTimeout["status"] as? String == "timed_out" && pod.sends.count == beforeWake, "dispatch deadline includes wake budget and returns without send")
        pod.autoHello = true; tap.sleep()
        var missing = arguments; missing["model"] = "nonexistent-model"
        let unavailable = try await bridgeCall("chatgpt_dispatch", missing)["result"] as! [String: Any]
        check(unavailable["status"] as? String == "not_submitted" && pod.sends.count == beforeWake, "uncatalogued model never falls back to another model")
        // Two named failure events preserve TAP's proof distinction and never auto-retry.
        for provenUnsent in [true, false] {
            let prior = pod.sends.count
            var failureArgs = arguments; failureArgs["text"] = "failure fixture " + String(provenUnsent)
            let operation = Task { try await bridgeCall("chatgpt_dispatch", failureArgs) }
            try await until { pod.sends.count == prior + 1 }
            let id = pod.sends.last!["id"] as! String
            pod.emit(["type": "stream", "id": id, "kind": "failed", "message": "fixture failure", "submitted": !provenUnsent])
            let result = try await operation.value["result"] as! [String: Any]
            check(result["status"] as? String == (provenUnsent ? "not_submitted" : "failed") && pod.sends.count == prior + 1,
                  "explicit TAP failure distinguishes proven unsent from uncertain submitted and sends only once")
            if provenUnsent {
                let retried = Task { try await bridgeCall("chatgpt_dispatch", failureArgs) }
                try await Task.sleep(for: .milliseconds(300))
                let actuallySent = pod.sends.count == prior + 2
                check(actuallySent, "W205-4 proven unsent identical ticket really sends on explicit retry")
                if actuallySent { _ = try await bridgeCall("chatgpt_dispatch_stop", [:]) }
                _ = try await retried.value
            }

        }
        // Destination uses an existing TATWO project identity, always a new conversation.
        var explicit = arguments; explicit["projectID"] = project.uuidString
        let priorExplicit = pod.sends.count
        let explicitTask = Task { try await bridgeCall("chatgpt_dispatch", explicit) }
        try await until { pod.sends.count == priorExplicit + 1 }
        let explicitID = pod.sends.last!["id"] as! String
        check(pod.projectName == "TATWO · Dispatch Fixture" && pod.sends.last?["conversationID"] == nil,
              "explicit TATWO project resolves through existing TAP interface without reusing a conversation")
        pod.emit(["type": "stream", "id": explicitID, "kind": "conversation", "conversationID": "explicit-conversation"])
        pod.emit(["type": "stream", "id": explicitID, "kind": "text", "full": "explicit project reply"])
        pod.emit(["type": "stream", "id": explicitID, "kind": "finished"])
        check((try await explicitTask.value["result"] as? [String: Any])?["status"] as? String == "completed", "explicit project reply saves successfully")
        pod.projects.removeAll { $0["title"] as? String == "TATWO · Dispatch Fixture" }
        let priorMissingTarget = pod.sends.count
        let missingTarget = try await bridgeCall("chatgpt_dispatch", explicit)["result"] as! [String: Any]
        check(missingTarget["status"] as? String == "not_submitted" && pod.sends.count == priorMissingTarget,
              "deleted explicit target rejects before send instead of silently delivering into inbox")
        // A preexisting malicious ignore file cannot disable protection or escape the pinned directory.
        let ignoreFile = room.appendingPathComponent("chatgpt-dispatch/.gitignore")
        let savedIgnore = root.appendingPathComponent("saved-ignore")
        let outsideIgnore = root.appendingPathComponent("outside-ignore")
        try Data("synthetic-untouched".utf8).write(to: outsideIgnore)
        try FileManager.default.moveItem(at: ignoreFile, to: savedIgnore)
        let beforeBadIgnore = pod.sends.count
        for variant in ["symlink", "hardlink", "fifo", "unignore"] {
            switch variant {
            case "symlink": try FileManager.default.createSymbolicLink(at: ignoreFile, withDestinationURL: outsideIgnore)
            case "hardlink": try FileManager.default.linkItem(at: outsideIgnore, to: ignoreFile)
            case "fifo": _ = mkfifo(ignoreFile.path, 0o600)
            default:
                try Data("!*.md\n".utf8).write(to: ignoreFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ignoreFile.path)
            }
            let blocked = try await bridgeCall("chatgpt_dispatch", arguments)["result"] as! [String: Any]
            let outsideUnchanged = try String(contentsOf: outsideIgnore, encoding: .utf8) == "synthetic-untouched"
            check(blocked["status"] as? String == "not_submitted" && pod.sends.count == beforeBadIgnore && outsideUnchanged,
                  "W205-3 hostile ignore \(variant) fails closed without send or outside write")
            try FileManager.default.removeItem(at: ignoreFile)
        }
        try FileManager.default.moveItem(at: savedIgnore, to: ignoreFile)
        // No output clobber or escape when the declared folder is hostile.
        let outputDir = room.appendingPathComponent("chatgpt-dispatch")
        let archivedDir = room.appendingPathComponent("saved-replies")
        try FileManager.default.moveItem(at: outputDir, to: archivedDir)
        let trapDir = root.appendingPathComponent("outside-replies")
        try FileManager.default.createDirectory(at: trapDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputDir, withDestinationURL: trapDir)
        let beforeTrap = pod.sends.count
        let trapped = try await bridgeCall("chatgpt_dispatch", arguments)["result"] as! [String: Any]
        let trapContentsBefore = try FileManager.default.contentsOfDirectory(atPath: trapDir.path)
        check(trapped["status"] as? String == "not_submitted" && pod.sends.count == beforeTrap
              && trapContentsBefore.isEmpty,
              "symlink output directory rejects before send without writing outside room")
        try FileManager.default.removeItem(at: outputDir)
        try FileManager.default.moveItem(at: archivedDir, to: outputDir)
        // Replacing the folder after send must yield failed rather than a false reply path.
        var collisionArgs = arguments; collisionArgs["text"] = "unique output collision fixture"
        let collisionTask = Task { try await bridgeCall("chatgpt_dispatch", collisionArgs) }
        try await until { pod.sends.count == beforeTrap + 1 }
        let collisionID = pod.sends.last!["id"] as! String
        try FileManager.default.moveItem(at: outputDir, to: archivedDir)
        try FileManager.default.createSymbolicLink(at: outputDir, withDestinationURL: trapDir)
        pod.emit(["type": "stream", "id": collisionID, "kind": "conversation", "conversationID": "changed-folder"])
        pod.emit(["type": "stream", "id": collisionID, "kind": "text", "full": "changed folder reply"])
        pod.emit(["type": "stream", "id": collisionID, "kind": "finished"])
        let collision = try await collisionTask.value["result"] as! [String: Any]
        let trapContentsAfter = try FileManager.default.contentsOfDirectory(atPath: trapDir.path)
        check(collision["status"] as? String == "failed" && collision["replyPath"] is NSNull
              && trapContentsAfter.isEmpty,
              "output directory replacement fails closed with no false completion or outside write")
        try FileManager.default.removeItem(at: outputDir)
        try FileManager.default.moveItem(at: archivedDir, to: outputDir)
        // Journal failures before submission fail closed.
        let unsafeJournal = root.appendingPathComponent("unsafe-journal.json")
        try FileManager.default.createSymbolicLink(at: unsafeJournal.deletingPathExtension(), withDestinationURL: trapDir)
        let rejectedJournal = ChatGPTDispatch(tap: tap, mapper: TapProjectMapper(tap: tap, inboxFolder: root.appendingPathComponent("unused-inbox")), journal: HandsRoomJournal(url: unsafeJournal))
        let request = try ChatGPTDispatch.Request.parse(arguments)
        let auditResult = await rejectedJournal.dispatch(request, caller: caller, room: room, projectID: project, destination: nil)
        check(auditResult.status == "not_submitted" && auditResult.reason == "chatgpt_dispatch_journal_unavailable"
              && pod.sends.count == beforeTrap + 1, "unavailable journal prevents TAP send")
        // Busy is bound to the caller and does not replace its existing work.
        let busyStart = pod.sends.count
        var busyArgs = arguments; busyArgs["text"] = "unique busy fixture"
        let busyTask = Task { try await bridgeCall("chatgpt_dispatch", busyArgs) }
        try await until { pod.sends.count == busyStart + 1 }
        let busy = try await bridgeCall("chatgpt_dispatch", arguments)["result"] as! [String: Any]
        check(busy["status"] as? String == "not_submitted" && busy["reason"] as? String == "chatgpt_dispatch_busy"
              && pod.sends.count == busyStart + 1, "second dispatch from same caller is refused without replacing first")
        _ = try await bridgeCall("chatgpt_dispatch_stop", [:]); _ = try await busyTask.value
        // Virtual wall time crosses the old 15m threshold; a real active native dispatch remains work.
        let watchdog = DispatchWatchdog.attach(to: engine, environment: ["TATWO2_WATCHDOG_INTERVAL_SEC": "3600"])
        defer { watchdog.stop() }
        engine.markSubStatus(caller, "running")
        var longArgs = arguments; longArgs["text"] = "unique long watchdog fixture"; longArgs["timeoutSeconds"] = 1800
        let longStart = pod.sends.count
        let longTask = Task { try await bridgeCall("chatgpt_dispatch", longArgs) }
        try await until { pod.sends.count == longStart + 1 }
        let longID = pod.sends.last!["id"] as! String
        let afterFifteenMinutes = (engine.threadRecord(caller)?.lastOutputAt ?? Date()).addingTimeInterval(901)
        watchdog.tick(now: afterFifteenMinutes, uptime: HandsMonotonic.now() + 901)
        check(engine.threadRecord(caller)?.subStatus == "running" && !pod.stops.contains(longID),
              "W205-5 ongoing 1800s dispatch protects caller past watchdog 15m threshold")
        check(dispatcher.isActive(caller: caller, uptime: HandsMonotonic.now() + 1790)
              && !dispatcher.isActive(caller: caller, uptime: HandsMonotonic.now() + 1801),
              "W205-5 dispatcher activity is bounded by its monotonic deadline")
        let oldOutput = Date().addingTimeInterval(-901)
        check(ThreadLiveness.from(status: "running", lastOutputAt: oldOutput, dispatchActive: true) == .active
              && ThreadLiveness.from(status: "running", lastOutputAt: oldOutput, dispatchActive: false) == .stalled
              && ThreadLiveness.from(status: "done", lastOutputAt: oldOutput, dispatchActive: true) == .done
              && ThreadLiveness.from(status: "failed", lastOutputAt: oldOutput, dispatchActive: true) == .failed,
              "W205-5 dispatch activity lights do not override terminal states or survive lease expiration")
        engine.stop(threadID: caller)
        let longResult = try await longTask.value["result"] as! [String: Any]
        check(longResult["stopped"] as? Bool == true && pod.stops.contains(longID) && !dispatcher.isActive(caller: caller),
              "W205-5 caller stop synchronously stops its TAP dispatch")
        let stoppedRetry = try await bridgeCall("chatgpt_dispatch", longArgs)["result"] as! [String: Any]
        check(stoppedRetry["dispatchID"] as? String == longResult["dispatchID"] as? String && pod.sends.count == longStart + 1,
              "user stop after sending keeps the result unconfirmed; the identical ticket is not resent")
        _ = try await bridgeCall("chatgpt_dispatch_stop", [:])
        engine.markSubStatus(caller, "running")
        watchdog.tick(now: (engine.threadRecord(caller)?.lastOutputAt ?? Date()).addingTimeInterval(901))
        check(engine.threadRecord(caller)?.subStatus == "stalled", "W205-5 normal watchdog resumes once dispatch stops")
        engine.markSubStatus(caller, "running")
        var expiryArgs = longArgs; expiryArgs["text"] = "unique expired watchdog fixture"
        let expiryStart = pod.sends.count
        let expiryTask = Task { try await bridgeCall("chatgpt_dispatch", expiryArgs) }
        try await until { pod.sends.count == expiryStart + 1 }
        let expiryID = pod.sends.last!["id"] as! String
        watchdog.tick(now: (engine.threadRecord(caller)?.lastOutputAt ?? Date()).addingTimeInterval(1801), uptime: HandsMonotonic.now() + 1801)
        let expiryResult = try await expiryTask.value["result"] as! [String: Any]
        let expiryRetry = try await bridgeCall("chatgpt_dispatch", expiryArgs)["result"] as! [String: Any]
        check(pod.stops.contains(expiryID) && expiryRetry["dispatchID"] as? String == expiryResult["dispatchID"] as? String
              && pod.sends.count == expiryStart + 1, "W205-4 watchdog after lease expiry cancels but preserves unknown receipt")
        _ = try await bridgeCall("chatgpt_dispatch_stop", [:])
        // Explicit provider failure is terminal; it does not acquire an uncertainty lock.
        var failedArgs = arguments; failedArgs["text"] = "unique terminal provider failure fixture"
        for attempt in 1...2 {
            let before = pod.sends.count
            let operation = Task { try await bridgeCall("chatgpt_dispatch", failedArgs) }
            try await until { pod.sends.count == before + 1 }
            pod.emit(["type": "stream", "id": pod.sends.last!["id"] as! String, "kind": "failed", "message": "synthetic rejected turn", "reason": "provider_failed", "submitted": true])
            let result = try await operation.value["result"] as! [String: Any]
            check(result["status"] as? String == "failed", "W205-4 definite provider failure permits explicit same-ticket retry attempt=\(attempt)")
        }
        check(dispatcher.releaseUncertain(caller: UUID()) == 0, "W205-4 foreign caller cannot release original uncertainty")
        var unknownArgs = arguments; unknownArgs["text"] = "unique unknown failed event fixture"
        let unknownStart = pod.sends.count
        let unknownTask = Task { try await bridgeCall("chatgpt_dispatch", unknownArgs) }
        try await until { pod.sends.count == unknownStart + 1 }
        pod.emit(["type": "stream", "id": pod.sends.last!["id"] as! String, "kind": "failed", "message": "synthetic send outcome unknown"])
        let unknownResult = try await unknownTask.value["result"] as! [String: Any]
        let unknownRetry = try await bridgeCall("chatgpt_dispatch", unknownArgs)["result"] as! [String: Any]
        check(unknownRetry["dispatchID"] as? String == unknownResult["dispatchID"] as? String && pod.sends.count == unknownStart + 1,
              "W205-4 generic failed event remains unknown and cannot silently resend")
        _ = try await bridgeCall("chatgpt_dispatch_stop", [:])
        var closeArgs = arguments; closeArgs["text"] = "unique caller closure fixture"
        let closeStart = pod.sends.count
        let closeTask = Task { try await bridgeCall("chatgpt_dispatch", closeArgs) }
        try await until { pod.sends.count == closeStart + 1 }
        let closeID = pod.sends.last!["id"] as! String
        engine.tapSelfTestSidecarClosed(caller)
        let closeResult = try await closeTask.value["result"] as! [String: Any]
        check(closeResult["stopped"] as? Bool == true && pod.stops.contains(closeID),
              "W205-5 unexpected caller closure synchronously stops its TAP request")
        let closeRetry = try await bridgeCall("chatgpt_dispatch", closeArgs)["result"] as! [String: Any]
        check(closeRetry["dispatchID"] as? String == closeResult["dispatchID"] as? String && pod.sends.count == closeStart + 1,
              "W205-4 unexpected caller loss keeps unconfirmed receipt locked against tool retry")
        let clear = try await bridgeCall("chatgpt_dispatch_stop", [:])["result"] as! [String: Any]
        check(clear["releasedUncertain"] as? Int == 1, "W205-4 explicit owner stop tool releases its inspected uncertain receipt")
        dispatcher.fillUncertainForSelfTest(caller: caller)
        var fullArgs = arguments; fullArgs["text"] = "unique full ledger fixture"
        let fullStart = pod.sends.count
        let full = try await bridgeCall("chatgpt_dispatch", fullArgs)["result"] as! [String: Any]
        check(full["status"] as? String == "not_submitted" && (full["reason"] as? String)?.contains("unconfirmed_full") == true
              && pod.sends.count == fullStart && dispatcher.releaseUncertain(caller: UUID()) == 0,
              "a full unconfirmed ledger refuses new dispatches instead of evicting old protection; only the owner releases")
        let otherCaller = engine.newThread(in: project, title: "Another room")
        let other = Task { await dispatcher.dispatch(request, caller: otherCaller, room: room, projectID: project, destination: nil) }
        try await until { pod.sends.count == fullStart + 1 }
        pod.stream("conversation", ["conversationID": "other-room-conversation"])
        pod.stream("text", ["messageID": "other-room-answer", "full": "synthetic answer"])
        pod.stream("finished")
        check(await other.value.status == "completed", "W207 a full room ledger cannot block a different room")
        check(dispatcher.releaseUncertain(caller: caller) == ChatGPTDispatch.uncertainCapacity,
              "W207 another room never evicts the full room's uncertain receipts")
        dispatcher.fillUncertainForSelfTest(caller: otherCaller)
        _ = engine.archive(otherCaller)
        check(dispatcher.releaseUncertain(caller: otherCaller) == 0,
              "W207 closing a room releases its receipts through the actual archive path")
        // Read-only local reviewers have no dispatch authority in the native handler.
        engine.configureReadOnlyRoom(threadID: caller, parentThreadID: parent, roomBrief: "readonly fixture", cwd: room.path)
        let readOnly = try await bridgeCall("chatgpt_dispatch", arguments)
        check(readOnly["error"] as? String == "chatgpt_dispatch_local_engine_room_required", "read-only room cannot dispatch writable external work")
        check(journal.rows(projectID: project).contains { $0.tool == "chatgpt_dispatch" && $0.summary.hasPrefix("派工：逾時") }, "journal includes timeout terminal records")
        return failures == 0
    }
    private static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw ChatGPTDispatch.Failure("fixture_wait_timeout") }
    }

}
#endif
