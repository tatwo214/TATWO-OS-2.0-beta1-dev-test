#if DEBUG
import Foundation

/// W189 A: real facade and persisted artifacts, isolated from accounts and engines.
@MainActor enum CommandModeAcceptance {
    static func run() throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let path = environment["TATWO2_LIVE_ROOT"] else { throw CocoaError(.fileWriteNoPermission) }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(root: root)))
        let id = engine.doc.selectedThreadID!
        model.selectedThreadID = id
        // The fixture initializer intentionally omits the production onChange subscription.
        engine.onChange = { [weak engine, weak model] in
            guard let engine, let model else { return }
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
        }
        var failures = 0, checks = 0
        var groups: [String: (checks: Int, failures: Int)] = [:]
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures += 1 }
            let group = String(name.split(separator: " ")[0].split(separator: "/")[0])
            let previous = groups[group] ?? (checks: 0, failures: 0)
            groups[group] = (previous.checks + 1, previous.failures + (condition ? 0 : 1))
            print("W189COMMANDS \(condition ? "PASS" : "FAIL") \(name)")
        }
        for kind in ["pr", "plan", "feedback", "distill"] {
            for alias in ["off", "exit", "stop", "關閉", "結束"] {
                let plan = TatwoPlanArtifactV1(threadID: id, objective: "fixture", kind: kind)
                try engine.savePlanArtifact(plan)
                model.prompt = "/plan " + alias
                model.send()
                let saved = try engine.loadPlanArtifact(id)
                check("F1/S1/S2/send-02 \(kind) \(alias) releases context", engine.planContext(saved, userText: "sample") == nil)
                check("F1 \(kind) \(alias) consumes command", model.prompt.isEmpty)
                if kind == "pr" {
                    check("F1 PR exit preserves canvas", saved?.planID == plan.planID && saved?.prModeExited == true)
                } else {
                    check("S2 exit does not create off plan", saved == nil)
                    let archive = try engine.archivedPlanArtifacts(id).first { $0.planID == plan.planID }
                    check("F1 archived canvas keeps complete artifact", archive == plan)
                    check("F1 exit exposes archived canvas in composer", model.archivedPlanCanvases.contains { $0.planID == plan.planID })
                    model.restoreArchivedCanvas(plan.planID)
                    check("F1 archive restores complete artifact", try engine.loadPlanArtifact(id) == plan)
                    check("F1 restore removes obsolete archive menu item", !model.archivedPlanCanvases.contains { $0.planID == plan.planID })
                }
            }
        }
        var feedback = TatwoPlanArtifactV1(threadID: id, objective: "fixture", kind: "feedback")
        check("F2/S3 draft feedback remains guarded", engine.planContext(feedback, userText: "sample") != nil)
        try engine.savePlanArtifact(feedback)
        model.finishFeedbackPlan(feedback.planID)
        feedback = try engine.loadPlanArtifact(id)!
        check("F2/S3/send-02 submitted feedback releases context", feedback.state == .confirmed && engine.planContext(feedback, userText: "sample") == nil)
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        check("F2/S3 submitted feedback stays released after restart", reopened.planContext(try reopened.loadPlanArtifact(id), userText: "sample") == nil)
        var plan = TatwoPlanArtifactV1(threadID: id, objective: "fixture")
        check("F4 discussing plg cannot start", !plan.acceptsStart("/plg"))
        plan.confirm()
        check("F4 confirmed plg starts", plan.acceptsStart("/plg") && plan.acceptsStart("/plg sample"))
        check("F4 plg receives execution context", engine.planContext(plan, userText: "/plg")?.contains("現在可以動手") == true)
        plan.executionTurnID = "fixture-turn"
        check("F4 plg stays one shot", !plan.acceptsStart("/plg"))
        for command in ["/plan", "/pr", "/feedback"] {
            let translated = ChatLiveEngine.engineText(command + " sample")
            check("F6 \(command) translates before Claude", !translated.hasPrefix("/") && translated.contains("sample"))
            check("F6 exact token only \(command)", ChatLiveEngine.engineText(command + "-sample") == command + "-sample")
        }
        let old = TatwoPlanArtifactV1(threadID: id, objective: "fixture", state: .ready, kind: "pr")
        try engine.savePlanArtifact(old)
        let replacement = TatwoPlanArtifactV1(threadID: id, objective: "sample", kind: "plan")
        try engine.savePlanArtifact(replacement)
        check("F7 replacing ready PR preserves archive", try engine.archivedPlanArtifacts(id).contains { $0.planID == old.planID })
        let next = TatwoPlanArtifactV1(threadID: id, objective: "sample", kind: "distill")
        try engine.savePlanArtifact(next)
        check("F7 replacing another canvas preserves archive", try engine.archivedPlanArtifacts(id).contains { $0.planID == replacement.planID })
        model.prompt = "/go"
        model.slashCommandSelectedIndex = nil
        let consumed = model.handleSlashSuggestionKey(.commit)
        check("F8 Enter selects sole goal suggestion", consumed && model.prompt == "/goal ")
        model.prompt = "/"
        model.slashCommandSelectedIndex = nil
        check("F8 multiple unselected suggestions do not consume Enter", !model.handleSlashSuggestionKey(.commit))
        model.prompt = "/issue"
        model.requestOpenInfoCard = false
        model.send()
        check("F10/S5 empty issue opens queue", model.requestOpenInfoCard && model.prompt.isEmpty)
        let child = engine.createDiscussion(parentThreadID: id)!
        model.selectedThreadID = id
        check("F11 fresh child appears in discussion tray", model.dispatchRooms.contains { $0.id == child })
        model.prompt = "/顯示討論串"
        model.send()
        check("F11 tray reports existing child", model.composerHint == "已顯示討論串")
        check("S6 second line does not suggest", ChatComposerSlashCatalog.matches(prompt: "sample\n/g").isEmpty)
        check("S6 leading newline does not suggest", ChatComposerSlashCatalog.matches(prompt: "\n/g").isEmpty)
        check("S6 first line still suggests", ChatComposerSlashCatalog.matches(prompt: "  /g").map(\.command) == ["/goal"])
        var interrupted = TatwoPlanArtifactV1(threadID: id, objective: "sample", state: .ready, kind: "pr")
        interrupted.prReview = PRPlanReview(directory: root, repository: "fixture/sample", account: "fixture",
            snapshot: .init(head: "fixture", status: "M", diff: "sample", stat: "1", origin: "fixture/sample"))
        interrupted.prReview?.attempted = true
        interrupted.prMessage = "送出中…"
        check("F12 interrupted submission recovers uncertainty", interrupted.recoverInterruptedPR(hasActiveTurn: false) && interrupted.prMessage?.contains("結果未確認") == true)
        check("F12 never silently retries", interrupted.prReview?.attempted == true && interrupted.prReview?.submittedURL == nil)
        let originalRoute = model.routeChoice
        model.selectedModel = "chatgpt-tap:fixture"
        for command in ["/plan", "/pr", "/feedback", "/蒸餾"] {
            try engine.savePlanArtifact(next)
            let draft = command + " sample"
            model.prompt = draft
            model.send()
            check("F5 TAP \(command) leaves canvas unchanged", try engine.loadPlanArtifact(id)?.planID == next.planID)
            check("F5 TAP \(command) keeps draft with explicit support hint", model.prompt == draft && model.composerHint == "ChatGPT（TAP）目前不支援這個指令，請改用 Codex 或 Claude")
            model.prompt = command
            check("F5 TAP \(command) menu explains unsupported", model.matchingSlashCommands.first?.subtitle == "ChatGPT（TAP）目前不支援這個指令，請改用 Codex 或 Claude")
        }
        model.selectedModel = originalRoute.id
        #if DEBUG
        model.selectedModel = "opus-5.5"
        for kind in ["plan", "pr", "feedback", "distill"] {
            var completed = TatwoPlanArtifactV1(threadID: id, objective: "sample", state: .confirmed, kind: kind)
            completed.executionTurnID = "fixture-turn"
            if kind == "pr" { completed.prModeExited = true }
            if kind == "distill" {
                completed.distillSubmission = DistillSubmission(threadID: id, content: "sample", title: "sample", slug: "sample", gbrain: false, skillet: false)
            }
            try engine.savePlanArtifact(completed)
            engine.commandSelfTestSetRunning(id, true)
            check("F3 unrelated running turn does not reopen completed plan indicator", !model.isActivePlanExecutionRunning)
            model.prompt = "/issue sample \(kind)"
            model.send()
            check("F3/Sol F3 completed \(kind) allows running issue", model.prompt.isEmpty)
            model.prompt = "/goal sample \(kind)"
            model.send()
            check("F3 completed \(kind) allows running goal", model.prompt.isEmpty)
            model.prompt = "/顯示討論串"
            model.send()
            check("F3 completed \(kind) allows running tray", model.prompt.isEmpty)
            model.prompt = "/討論串 sample"
            model.send()
            check("F3 completed \(kind) allows running discussion creation", model.selectedThreadID != id && model.prompt == "sample")
            model.selectedThreadID = id
            engine.commandSelfTestSetRunning(id, false)
        }
        try engine.savePlanArtifact(TatwoPlanArtifactV1(threadID: id, objective: "sample"))
        engine.commandSelfTestSetRunning(id, true)
        model.prompt = "/issue sample"
        model.send()
        check("F3 writing discussion still blocks overlapping send", model.prompt == "/issue sample" && model.composerHint == "請等計畫回覆完成再送出")
        engine.commandSelfTestSetRunning(id, false)
        model.selectedModel = originalRoute.id
        #endif
        #if DEBUG
        let defaultsName = "ai.tatwo.selftest.w189commands.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let dm = GlobalDMStore(defaults: defaults, chatGPTAllowed: { false })
        dm.attach(model)
        dm.select(.assistant)
        var assistantCalls = 0
        model.dmLocalSendTestDouble = { _, _, _ in assistantCalls += 1; return true }
        for command in ["/plan", "/goal", "/pr", "/feedback", "/蒸餾", "/issue", "/討論串", "/顯示討論串"] {
            let draft = command + " sample"
            dm.setDraft(draft, for: .assistant)
            check("DM-09 \(command) rejected with draft preserved", !dm.send() && dm.draft(for: .assistant) == draft && dm.notice?.contains("不支援") == true)
        }
        check("DM-09 no raw commands reach assistant engine", assistantCalls == 0)
        model.dmLocalSendTestDouble = nil
        #endif
        let remotePlan = TatwoPlanArtifactV1(threadID: id, objective: "sample", kind: "distill")
        try engine.savePlanArtifact(remotePlan)
        let archiveRequest = try DistillRemoteRequest.parse(method: "distill_edit", params: ["threadID": id.uuidString, "planID": remotePlan.planID.uuidString, "canvasAction": "archive"])
        let archivedReply = try model.distillRemoteBegin(archiveRequest)
        let afterRemoteArchive = try engine.loadPlanArtifact(id)
        check("F1 remote archive preserves canvas", archivedReply.canvas == nil && archivedReply.archives?.contains(remotePlan) == true && afterRemoteArchive == nil && model.activePlanArtifact == nil)
        let restoreRequest = try DistillRemoteRequest.parse(method: "distill_edit", params: ["threadID": id.uuidString, "planID": remotePlan.planID.uuidString, "canvasAction": "restore"])
        let restoredReply = try model.distillRemoteBegin(restoreRequest)
        check("F1 remote restore preserves exact canvas", restoredReply.canvas == remotePlan)
        for (command, kind) in [("/pr", "pr"), ("/plan", "plan"), ("/feedback", "feedback"), ("/蒸餾", "distill")] {
            let canvas = TatwoPlanArtifactV1(threadID: id, objective: "sample", kind: kind)
            try engine.savePlanArtifact(canvas)
            model.prompt = command + " off"
            model.send()
            let saved = try engine.loadPlanArtifact(id)
            check("F1 \(command) off consumes command and releases rules", model.prompt.isEmpty && engine.planContext(saved, userText: "sample") == nil)
            let archived = try engine.archivedPlanArtifacts(id)
            let preserved = kind == "pr" ? saved?.planID == canvas.planID : archived.contains(canvas)
            check("F1 \(command) off preserves complete canvas", preserved)
            let accepted = engine.send(threadID: id, text: command + " sample", model: "chatgpt-tap:fixture", engine: .codex)
            check("F5 direct TAP \(command) rejects before Pod invocation", !accepted && engine.transcript(for: id).last?.text == CanvasCommandPolicy.tapUnsupported)
        }
        let reviewSections = [TatwoPlanArtifactV1.Section(title: "做什麼", body: "sample")]
        let noAccount = TatwoPlanArtifactV1(threadID: id, objective: "sample", sections: reviewSections, kind: "pr")
        try engine.savePlanArtifact(noAccount)
        model.confirmActivePlan()
        check("F1/S1 GitHub login failure keeps exit available", model.activePlanArtifact?.prMessage != nil && model.canvasModeLabel != nil)
        model.prompt = "/pr 結束"
        model.send()
        check("F1/S1 can exit after GitHub preflight failure", try engine.loadPlanArtifact(id)?.prModeExited == true)
        var waiting = TatwoPlanArtifactV1(threadID: id, objective: "sample", state: .ready, kind: "pr")
        waiting.prReview = PRPlanReview(directory: root, repository: "fixture/sample", account: "fixture",
            snapshot: .init(head: "fixture", status: "M", diff: "sample", stat: "1", origin: "fixture/sample"))
        try engine.savePlanArtifact(waiting)
        try engine.savePlanArtifact(TatwoPlanArtifactV1(threadID: id, objective: "sample"))
        check("F7 pending send PR preserves review and diff", try engine.archivedPlanArtifacts(id).contains(waiting))
        check("F7 restored pending PR retains submit state", try engine.restorePlanArtifact(id, planID: waiting.planID) == waiting)
        var written = TatwoPlanArtifactV1(threadID: id, objective: "sample", state: .confirmed, kind: "distill")
        written.distillText = "# sample"
        written.distillOutput = .skill
        written.distillSubmission = DistillSubmission(threadID: id, content: "# sample", title: "sample", slug: "sample", gbrain: false, skillet: false,
            output: .skill, archivePath: root.appendingPathComponent("fixture").path, status: "done", planID: written.planID)
        written.distillEarlier = [DistillSubmission(threadID: id, content: "# fixture", title: "fixture", slug: "fixture", gbrain: false, skillet: false,
            output: .skill, archivePath: root.appendingPathComponent("example").path, status: "done", planID: UUID())]
        try engine.savePlanArtifact(written)
        try engine.savePlanArtifact(TatwoPlanArtifactV1(threadID: id, objective: "sample", kind: "feedback"))
        check("F7 distill archive preserves current and earlier rollback receipts", try engine.archivedPlanArtifacts(id).contains(written))
        check("F7 restored distill keeps full rollback data", try engine.restorePlanArtifact(id, planID: written.planID) == written)
        written.distillSubmission?.status = "writing"
        try engine.savePlanArtifact(written)
        var rejectedWriting = false
        do { try engine.savePlanArtifact(TatwoPlanArtifactV1(threadID: id, objective: "sample")) }
        catch { rejectedWriting = true }
        let retainedWriting = try engine.loadPlanArtifact(id)
        check("F7 in-flight write is never replaced", rejectedWriting && retainedWriting == written)
        let activeURL = engine.store.url.deletingLastPathComponent().appendingPathComponent("plans").appendingPathComponent("\(id.uuidString).json")
        let original = try Data(contentsOf: activeURL), corrupt = Data("fixture unreadable".utf8)
        try corrupt.write(to: activeURL, options: .atomic)
        var rejectedCorrupt = false
        do { try engine.savePlanArtifact(TatwoPlanArtifactV1(threadID: id, objective: "sample")) }
        catch { rejectedCorrupt = true }
        let retainedCorrupt = try Data(contentsOf: activeURL)
        try original.write(to: activeURL, options: .atomic)
        check("F7 unreadable active canvas is retained exactly", rejectedCorrupt && retainedCorrupt == corrupt)

        for group in groups.keys.sorted() {
            let result = groups[group]!
            print("W189COMMANDS \(group) SUMMARY checks=\(result.checks) failures=\(result.failures)")
        }
        print("W189COMMANDS SUMMARY checks=\(checks) failures=\(failures)")
        return failures == 0
    }
}
#endif
