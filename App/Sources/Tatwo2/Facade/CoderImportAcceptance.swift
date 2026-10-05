#if DEBUG
import CryptoKit
import Foundation

/// W180 E3 自測：`TATWO2_SELFTEST=w180import`（匯入）、`w180spaces`（專案空間）。
/// 只在完整隔離的 staging 環境跑；對話檔是自己合成的，不讀使用者真的 CLI 紀錄，也不送出任何一句給引擎。
enum CoderImportAcceptance {
    private final class Tally {
        let tag: String
        var passed = 0, failed = 0
        init(_ tag: String) { self.tag = tag }
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(tag) \(condition ? "PASS" : "FAIL") \(label)")
        }
        func finish() -> Bool { print("\(tag) SUMMARY passed=\(passed) failures=\(failed)"); return failed == 0 }
    }

    @MainActor static func run(_ name: String) async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("\(name) needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("\(name) requires a fresh live root inside TATWO_STAGING_ROOT")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = staging.appendingPathComponent("w180-fixture-\(UUID().uuidString.prefix(6))")
        if name == "w180spaces" { return try await spaces(root: root, environment: environment) }
        return try await imports(root: root, fixture: fixture, environment: environment)
    }

    // MARK: - 合成的 CLI 紀錄

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func claudeFile(_ dir: URL, id: String, cwd: String, entry: String = "cli", title: String,
                                   turns: Int = 1, userText: String = "請幫我看一下這個專案的狀態", toolBytes: Int = 400,
                                   commandOutput: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines = [line(["type": "user", "cwd": cwd, "entrypoint": entry, "sessionId": id, "timestamp": "2026-09-20T01:00:00.000Z",
                           "message": ["role": "user", "content": "<system-reminder>內部提醒</system-reminder>第一句：\(userText)"]])]
        lines.append(line(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "前情摘要：之前談過側欄"]]))
        if commandOutput {
            // Claude Code 的斜線指令、! 模式與背景工作通知：都是 type=user 的字串，但那是指令輸出，不是你說的話。
            for text in ["<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>",
                         "<local-command-stdout>SECRET-MARKER model set</local-command-stdout>",
                         "<bash-input>cat .env</bash-input>",
                         "<bash-stdout>SECRET-MARKER=1</bash-stdout><bash-stderr></bash-stderr>",
                         "<task-notification><task-id>t1</task-id><result>SECRET-MARKER</result></task-notification>"] {
                lines.append(line(["type": "user", "message": ["role": "user", "content": text]]))
            }
        }
        for index in 0..<turns {
            lines.append(line(["type": "user", "timestamp": "2026-09-20T01:0\(index % 10):00.000Z",
                               "message": ["role": "user", "content": "第 \(index) 輪：\(userText)"]]))
            lines.append(line(["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "第 \(index) 輪回覆"], ["type": "tool_use", "name": "sample", "input": ["command": "git status"]]]]]))
            lines.append(line(["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "content": "TOOL-OUTPUT-MARKER " + String(repeating: "x", count: toolBytes)]]]]))
        }
        lines.append(line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "完成，最後一句"]]]]))
        lines.append(line(["type": "ai-title", "aiTitle": title, "sessionId": id]))
        let url = dir.appendingPathComponent("\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private static func codexFile(_ dir: URL, id: String, cwd: String, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            line(["type": "session_meta", "timestamp": "2026-09-20T02:00:00.000Z", "payload": ["id": id, "cwd": cwd, "source": "cli"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]),
            line(["type": "response_item", "payload": ["type": "function_call", "name": "sample", "arguments": "{\"cmd\":\"ls\"}"]]),
            line(["type": "response_item", "payload": ["type": "function_call_output", "output": "TOOL-OUTPUT-MARKER a b"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Codex 回覆"]]]]),
        ]
        let url = dir.appendingPathComponent("rollout-2026-09-20T02-00-00-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private static func fingerprint(_ url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "@\(date.timeIntervalSince1970)"
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    @MainActor private static func waitIdle(_ job: CoderImportJob) async -> Bool {
        for _ in 0..<1_500 where job.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        return !job.isRunning
    }

    @MainActor private static func makeModel(root: URL, environment: [String: String]) async -> (ChatPageModel, ChatLiveEngine) {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        return (ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library))), engine)
    }

    // MARK: - w180import

    @MainActor private static func imports(root: URL, fixture: URL, environment: [String: String]) async throws -> Bool {
        let t = Tally("W180IMPORT")
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let existingDir = fixture.appendingPathComponent("work/existing"), freshDir = fixture.appendingPathComponent("work/fresh-project")
        let missingDir = fixture.appendingPathComponent("work/gone")
        for dir in [existingDir, freshDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let claudeRoot = fixture.appendingPathComponent("claude/projects"), codexRoot = fixture.appendingPathComponent("codex/sessions")
        let ids = (0..<5).map { _ in UUID().uuidString.lowercased() }
        let claudeA = try claudeFile(claudeRoot.appendingPathComponent("-existing"), id: ids[0], cwd: existingDir.path, title: "既有專案的對話",
                                     turns: 3, commandOutput: true)
        let codexB = try codexFile(codexRoot.appendingPathComponent("2026/09/20"), id: ids[1], cwd: freshDir.path, text: "Codex 第一句")
        let homeC = try claudeFile(claudeRoot.appendingPathComponent("-home"), id: ids[2], cwd: home, title: "家目錄的對話")
        let goneD = try claudeFile(claudeRoot.appendingPathComponent("-gone"), id: ids[3], cwd: missingDir.path, title: "資料夾不在的對話")
        let batchE = try claudeFile(claudeRoot.appendingPathComponent("-existing"), id: ids[4], cwd: existingDir.path, entry: "sdk-cli", title: "房間")
        let old = Date().addingTimeInterval(-3_600)
        for url in [claudeA, codexB, homeC, goneD, batchE] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        // 5 MB 以上：一半是工具輸出，剛寫入（算「還在進行」）。
        let bigID = UUID().uuidString.lowercased()
        let big = try claudeFile(claudeRoot.appendingPathComponent("-existing"), id: bigID, cwd: existingDir.path, title: "很大的對話",
                                 turns: 1_100, userText: String(repeating: "長段落/內容\n\"引號\"\\", count: 120), toolBytes: 1_700)
        let tinyRoot = fixture.appendingPathComponent("many/sessions")
        let tinies = try (0..<(CoderImport.maxSessionsPerBatch + 2)).map {
            try codexFile(tinyRoot.appendingPathComponent("2026/09/2\($0 % 10)"), id: UUID().uuidString.lowercased(), cwd: freshDir.path, text: "小段 \($0)")
        }
        for url in tinies { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        let watched = [claudeA, codexB, homeC, goneD, batchE, big] + tinies
        let before = watched.map(fingerprint)

        let sources = [CLITranscriptArchive.Source(root: claudeRoot, engine: .claude, origin: .native),
                       CLITranscriptArchive.Source(root: codexRoot, engine: .codex, origin: .native)]
        let listed = CLITranscriptArchive.list(sources: sources)
        let eligible = listed.filter(CoderImport.eligible)
        t.check(listed.count == 6 && eligible.count == 5 && !eligible.contains { $0.sessionID == ids[4] },
                "list: 6 sessions, non-interactive one not importable (\(listed.count)/\(eligible.count))")
        func session(_ id: String) -> CLITranscriptSession? { listed.first { $0.sessionID == id } }

        let (model, engine) = await makeModel(root: root, environment: environment)
        defer { engine.shutdownAll() }
        t.check(model.coderImportSources.allSatisfy { $0.origin == .native } && model.coderImportSources.count == 2,
                "import sources are the user's own CLI only (no OS engine homes)")
        let existingProject = engine.newProject(name: "既有", workdir: existingDir.path)
        let generalID = engine.doc.generalProjectID
        let generalBefore = engine.doc.threads.filter { $0.projectID == generalID }.count
        let job = CoderImportJob.shared
        let docURL = engine.store.url

        // (1) 既有資料夾：沿用專案；串頂說明、則數、出處、工具輸出沒進來、updatedAt＝原檔時間。
        guard let a = session(ids[0]) else { throw BotLibraryError.invalid("fixture A missing") }
        model.importCLISessions([a])
        t.check(await waitIdle(job), "import A finishes")
        let threadA = engine.doc.threads.first { $0.importedFrom?.sessionID == ids[0] }
        let rowsA = threadA.map { engine.transcript(for: $0.id) } ?? []
        let sourceA = threadA?.importedFrom
        t.check(threadA?.projectID == existingProject && threadA?.engine == "claude", "A lands in the existing project, engine claude")
        t.check(model.mode == .chat && model.selectedThreadID == threadA?.id && engine.doc.selectedThreadID == threadA?.id,
                "A is selected in Coder")
        t.check(rowsA.first?.status == CoderImport.bannerStatus && sourceA.map {
                    rowsA.first?.text.contains("放了最近 \($0.keptMessages) 則（共 \($0.totalMessages) 則）") == true } == true
                && rowsA.first?.text.contains("看原檔") == true, "banner: 放了最近 N 則（共 M 則）＋看原檔")
        t.check(sourceA?.totalMessages == 9 && sourceA?.keptMessages == 9 && rowsA.count == 10,
                "A keeps user, assistant and summary rows (\(sourceA?.keptMessages ?? -1)/\(sourceA?.totalMessages ?? -1))")
        t.check(!rowsA.contains { $0.text.contains("TOOL-OUTPUT-MARKER") || $0.text.contains("git status") },
                "tool calls and outputs are not copied")
        t.check(!rowsA.contains { $0.text.contains("SECRET-MARKER") || $0.text.contains("cat .env") || $0.text.contains("/model") },
                "slash-command, ! bash and task-notification output (type=user strings) are not copied or counted")
        t.check(rowsA.first.map { $0.text.split(separator: "\n").prefix(2).contains { $0.contains("放了最近") } } == true,
                "banner: the first two lines (visible when collapsed) carry 放了最近 N 則")
        t.check(rowsA.contains { $0.status == CoderImport.summaryStatus && $0.text.contains("前情摘要") }
                && rowsA.last?.text == "完成，最後一句" && !rowsA.contains { $0.text.contains("內部提醒") },
                "summary kept, order kept, engine wrappers stripped")
        t.check(threadA.map { abs($0.updatedAt.timeIntervalSince(a.modifiedAt)) < 1.5 } == true,
                "updatedAt uses the source file time, not the import time")

        // (2) 同一段再匯入＝打開那一條；封存了也還原。
        let otherThread = engine.newThread(in: existingProject, title: "別的串")
        model.selectLocalThread(otherThread)
        let countAfterA = engine.doc.threads.count
        model.importCLISessions([a])
        t.check(await waitIdle(job), "re-import finishes")
        t.check(engine.doc.threads.count == countAfterA && model.selectedThreadID == threadA?.id && job.status.contains("已經匯入過"),
                "same session twice → one thread, reopened")
        if let id = threadA?.id { _ = engine.archive(id) }
        model.importCLISessions([a])
        _ = await waitIdle(job)
        t.check(engine.threadRecord(threadA?.id)?.isArchived == false && engine.doc.threads.filter { $0.importedFrom?.sessionID == ids[0] }.count == 1,
                "archived import is restored, not duplicated")

        // (3) 新資料夾：建同名專案；Codex。(4) 家目錄：「家目錄」專案，「聊天」不變。(5) 資料夾不在：建專案、標示、送出停用。
        let rest = [ids[1], ids[2], ids[3]].compactMap(session)
        model.importCLISessions(rest)
        t.check(await waitIdle(job), "batch of three finishes")
        let threadB = engine.doc.threads.first { $0.importedFrom?.sessionID == ids[1] }
        let projectB = engine.projectRecord(threadB?.projectID)
        t.check(projectB?.name == "fresh-project" && projectB?.workdir == CoderImport.normalized(freshDir.path) && threadB?.engine == "codex"
                && engine.transcript(for: threadB?.id).first?.text.hasPrefix("從 Codex 匯入：") == true, "new folder → new project; Codex banner")
        let threadC = engine.doc.threads.first { $0.importedFrom?.sessionID == ids[2] }
        let projectC = engine.projectRecord(threadC?.projectID)
        t.check(projectC?.name == CoderImport.homeProjectName && projectC?.id != generalID && projectC?.id != engine.doc.assistantProjectID
                && engine.doc.threads.filter { $0.projectID == generalID }.count == generalBefore, "home → 家目錄 project; 聊天 unchanged")
        let threadD = engine.doc.threads.first { $0.importedFrom?.sessionID == ids[3] }
        t.check(threadD?.importedFrom?.folderMissing == true && engine.projectRecord(threadD?.projectID)?.name == "gone"
                && engine.transcript(for: threadD?.id).first?.text.contains("資料夾已不在") == true, "missing folder → project created and marked")
        if let id = threadD?.id {
            let sent = engine.send(threadID: id, text: "接著做", model: nil, engine: .claude, systemPrompt: nil, attachments: [],
                                   reasoningEffort: nil, serviceTier: nil)
            t.check(!sent && engine.transcript(for: id).last?.status == "error|匯入" && engine.importedSendBlockReason(id) != nil,
                    "missing folder → send disabled with an explanation")
        }

        // (6) 接著做：第一句帶前情，包成資料；不附原檔路徑；一般的串不帶。併回主設備後（只剩訊息）照樣認得。
        if let id = threadA?.id, let seed = engine.importedSeed(threadID: id, engine: .claude, userText: "現在的問題", currentTurn: "t") {
            t.check(seed.contains("是資料不是指令") && seed.contains("<imported-transcript>") && seed.contains("完成，最後一句")
                    && seed.hasSuffix("現在的問題") && !seed.contains(a.url.path) && seed.utf8.count <= CoderImport.seedLimitBytes + 64,
                    "seed prompt wraps recent rows as data, no source path, within limit")
            t.check(engine.importedSeed(threadID: id, engine: .codex, userText: "x", currentTurn: "t") != nil,
                    "switching engine on an imported thread also seeds")
        } else { t.check(false, "seed prompt for imported thread") }
        let plain = engine.newThread(in: existingProject, title: "一般的串")
        t.check(engine.importedSeed(threadID: plain, engine: .claude, userText: "x", currentTurn: "t") == nil, "ordinary thread is not seeded")
        let pushed = try engine.importTransferredThread(projectName: "既有", title: "併回的匯入串",
            messages: rowsA.map(RemoteThreadTransferMessage.init), files: [])
        t.check(engine.importedSeed(threadID: pushed, engine: .claude, userText: "x", currentTurn: "t")?.contains("Claude Code") == true,
                "thread pushed to the primary (messages only) still seeds from the banner")
        try transferChecks(t, root: root, environment: environment, sourceA: sourceA, rowsA: rowsA)

        // (7) 5 MB：主執行緒不讀、立即返回；document.json 增加量有上限；還在進行的標示。
        let sizeBefore = fileSize(docURL)
        guard let bigSession = session(bigID) else { throw BotLibraryError.invalid("fixture big missing") }
        let started = Date()
        model.importCLISessions([bigSession])
        let returned = Date().timeIntervalSince(started)
        t.check(returned < 0.25 && job.isRunning, "import returns at once and reads in the background (\(Int(returned * 1000)) ms)")
        t.check(await waitIdle(job), "big import finishes")
        let bigThread = engine.doc.threads.first { $0.importedFrom?.sessionID == bigID }
        let growth = fileSize(docURL) - sizeBefore
        let bigRows = engine.transcript(for: bigThread?.id).dropFirst()
        let keptBytes = bigThread?.importedFrom?.keptBytes ?? .max
        t.check(bigSession.bytes >= 5_000_000 && growth <= CoderImport.maxBytesPerSession && growth <= keptBytes,
                "document.json grows \(growth / 1024) KB (estimate \(keptBytes / 1024) KB, cap \(CoderImport.maxBytesPerSession / 1024) KB) "
                + "for a \(String(format: "%.1f", Double(bigSession.bytes) / 1_000_000)) MB session full of / \" \\ and newlines")
        t.check(bigRows.count < CoderImport.maxMessages && bigRows.allSatisfy { $0.text.count <= CoderImport.maxCharsPerMessage }
                && bigRows.reduce(0) { $0 + $1.text.utf8.count } <= CoderImport.maxBytesPerSession
                && (bigThread?.importedFrom?.totalMessages ?? 0) > (bigThread?.importedFrom?.keptMessages ?? 0),
                "limits: byte cap reached before \(CoderImport.maxMessages) rows, ≤\(CoderImport.maxCharsPerMessage) chars each, ≤128 KB (\(bigRows.count) rows)")
        t.check(bigThread?.importedFrom?.liveAtImport == true
                && engine.transcript(for: bigThread?.id).first?.text.contains("匯入時這段還在進行") == true, "still-running session is marked")

        // (8) 取消：什麼都不寫。(9) 一批最多 30 段。
        let tinySessions = CLITranscriptArchive.list(sources: [.init(root: tinyRoot, engine: .codex, origin: .native)])
        let countBeforeCancel = engine.doc.threads.count
        model.importCLISessions(Array(tinySessions.prefix(2)))
        job.cancel()
        _ = await waitIdle(job)
        t.check(engine.doc.threads.count == countBeforeCancel && job.status.contains("已取消"), "cancel imports nothing")
        // 選一條串本身（既有的 selectedThreadID didSet＋selectLocalThread）就會存檔；先量這個，匯入只能多一次。
        let selecting = WriteCounter(engine)
        model.selectLocalThread(otherThread)
        selecting.stop()
        let writes = WriteCounter(engine)
        model.importCLISessions(tinySessions)
        _ = await waitIdle(job)
        writes.stop()
        t.check(tinySessions.count == CoderImport.maxSessionsPerBatch + 2
                && engine.doc.threads.count == countBeforeCancel + CoderImport.maxSessionsPerBatch && job.status.contains("還有 2 段沒匯入"),
                "one batch imports at most \(CoderImport.maxSessionsPerBatch) sessions")
        t.check(selecting.count > 0 && writes.count == 1 + selecting.count,
                "a batch of \(CoderImport.maxSessionsPerBatch) writes document.json \(writes.count) times = import once + selecting the thread (\(selecting.count))")
        let direct = WriteCounter(engine)
        let synthetic = (0..<CoderImport.maxSessionsPerBatch).map { index in
            (digest: CoderImport.Digest(rows: [.init(kind: .user, text: "合成 \(index)", timestamp: nil)], total: 1,
                                        bytes: CoderImport.storedBytes("合成 \(index)")),
             source: CoderImportSource(engine: "codex", sessionID: UUID().uuidString.lowercased(), path: freshDir.path + "/synthetic-\(index)",
                                       title: "合成 \(index)", cwd: freshDir.path, sourceModifiedAt: old, importedAt: Date(),
                                       totalMessages: 1, keptMessages: 1))
        }
        let syntheticIDs = engine.importCLISessions(synthetic)
        direct.stop()
        t.check(direct.count == 1 && Set(syntheticIDs).count == CoderImport.maxSessionsPerBatch, "engine batch API saves once (\(direct.count))")

        // (9b) 總量上限：滿了就不讀、不寫；放不下這批也不寫。
        guard let leftover = tinySessions.last else { throw BotLibraryError.invalid("tiny fixture missing") }
        let used = model.coderImportUsedBytes
        let countBeforeCap = engine.doc.threads.count
        t.check(used > 0 && CoderImport.usageText(used: used).hasPrefix("Coder 裡匯入的內容：已用 "), "usage counts imported threads (\(used / 1024) KB)")
        model.importCLISessions([leftover], totalCap: used)
        t.check(!job.isRunning && job.status.contains("已經滿了") && engine.doc.threads.count == countBeforeCap, "total cap reached → nothing read or written")
        model.importCLISessions([leftover], totalCap: used + 1)
        _ = await waitIdle(job)
        t.check(job.status.contains("這批放不下") && engine.doc.threads.count == countBeforeCap, "batch that does not fit the total cap → nothing written")

        // (10) 私訊框「最近 session」不被匯入洗掉；只能看的判斷；舊文件相容；原檔不變。
        let fresh = engine.newThread(in: existingProject, title: "剛開的串")
        engine.appendSystemMessage(threadID: fresh, text: "touch", status: "info|test")
        t.check(model.dmSessionCandidates(limit: 1).first?.id == fresh, "DM recent list is led by real activity, not imports")
        t.check(CoderImport.viewOnly(disabledEngines: ["claude", "codex", "grok"], isSecondary: true)
                && !CoderImport.viewOnly(disabledEngines: ["claude", "codex", "grok"], isSecondary: false)
                && !CoderImport.viewOnly(disabledEngines: ["claude", "codex"], isSecondary: true)
                && sourceA.map { CoderImport.bannerText($0, viewOnlyHint: CoderImport.viewOnlyHint).hasPrefix(CoderImport.viewOnlyHint + "\n") } == true
                && !model.coderImportViewOnly, "view-only rule: secondary role and every engine disabled; hint is the first line")
        let savedDisabled = model.disabledEngines
        model.disabledEngines = ["claude", "codex", "grok"]   // 只改記憶體
        t.check(!model.coderImportViewOnly, "primary or standalone with every engine disabled is not view-only")
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: "primary-one", displayName: "Primary One"),
                                            engine: { nil }, connecting: { false })
        let secondaryViewOnly = model.coderImportViewOnly
        model.importCLISessions([leftover], totalCap: .max)
        _ = await waitIdle(job)
        model.assistantPrimaryTestDouble = nil
        model.disabledEngines = savedDisabled
        let viewOnlyThread = engine.doc.threads.first { $0.importedFrom?.path == leftover.url.path }?.id
        let viewOnlyBanner = engine.transcript(for: viewOnlyThread).first?.text ?? ""
        t.check(secondaryViewOnly && viewOnlyBanner.hasPrefix(CoderImport.viewOnlyHint + "\n") && job.status.contains(CoderImport.viewOnlyHint),
                "secondary with every engine disabled: hint is the first banner line")
        if let viewOnlyThread { engine.dropViewOnlyHint(viewOnlyThread) }
        let afterDrop = engine.transcript(for: viewOnlyThread).first?.text ?? ""
        t.check(!afterDrop.contains(CoderImport.viewOnlyHint) && afterDrop.contains("放了最近"), "once this device sends, the stale hint is dropped")
        let legacyRoot = root.appendingPathComponent("legacy")
        let legacyEngine = ChatLiveEngine(store: ChatLiveStore(root: legacyRoot), environment: environment)
        _ = legacyEngine.newThread(in: legacyEngine.newProject(name: "舊", workdir: legacyRoot.path), title: "舊串")
        legacyEngine.shutdownAll()
        let legacyBytes = try Data(contentsOf: legacyRoot.appendingPathComponent("document.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyDoc = try decoder.decode(LiveDocumentRecord.self, from: legacyBytes)
        t.check(!String(decoding: legacyBytes, as: UTF8.self).contains("importedFrom") && legacyDoc.threads.allSatisfy { $0.importedFrom == nil }
                && (try? encoder.encode(legacyDoc)) == legacyBytes, "old document.json decodes and saves back byte-for-byte")
        let broken = try decoder.decode(LiveThreadRecord.self, from: Data(#"{"title":"壞出處","importedFrom":42}"#.utf8))
        t.check(broken.title == "壞出處" && broken.importedFrom == nil, "a broken importedFrom never breaks the document")
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        t.check(reopened.doc.threads.first { $0.id == threadA?.id }?.importedFrom?.dedupeKey == sourceA?.dedupeKey, "importedFrom survives reopen")
        reopened.shutdownAll()
        t.check(watched.map(fingerprint) == before, "source files: sha256 and modification time unchanged")
        return t.finish()
    }

    /// 數 document.json 寫了幾次（每次 persist 都叫一次 onChange）。
    @MainActor private final class WriteCounter {
        private(set) var count = 0
        private let engine: ChatLiveEngine
        private let original: (() -> Void)?
        init(_ engine: ChatLiveEngine) {
            self.engine = engine
            original = engine.onChange
            engine.onChange = { [weak self] in self?.count += 1; self?.original?() }
        }
        func stop() { engine.onChange = original }
    }

    /// 併回主設備（只帶訊息）：匯入串不落「一般」＝「聊天」；只跟原本那台有關的行拿掉；一般的串照舊。
    @MainActor private static func transferChecks(_ t: Tally, root: URL, environment: [String: String],
                                                  sourceA: CoderImportSource?, rowsA: [ChatMessage]) throws {
        guard var source = sourceA else { t.check(false, "transfer fixture"); return }
        source.folderMissing = true
        let primary = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("primary")), environment: environment)
        defer { primary.shutdownAll() }
        let banner = RemoteThreadTransferMessage(role: "system", text: CoderImport.bannerText(source, viewOnlyHint: CoderImport.viewOnlyHint),
                                                 createdAt: Date())
        let packet = [banner] + rowsA.dropFirst().map(RemoteThreadTransferMessage.init)
        func inChat() -> Int {
            primary.doc.threads.filter { $0.projectID == primary.doc.generalProjectID || primary.projectRecord($0.projectID)?.name == "一般" }.count
        }
        let chatBefore = inChat()
        let home = try primary.importTransferredThread(projectName: CoderImport.homeProjectName, title: "家目錄的匯入串", messages: packet, files: [])
        let homeProject = primary.projectRecord(primary.threadRecord(home)?.projectID)
        let homeBanner = primary.transcript(for: home).first
        t.check(homeProject?.name == CoderImport.homeProjectName && homeProject?.workdir == CoderImport.normalized(NSHomeDirectory())
                && inChat() == chatBefore, "pushed import from 家目錄 → the primary's 家目錄 project, 聊天 unchanged")
        t.check(homeBanner?.status == CoderImport.bannerStatus && homeBanner.map { !$0.text.contains(CoderImport.viewOnlyHint)
                && !$0.text.contains("資料夾已不在") && $0.text.contains("放了最近") } == true,
                "pushed banner drops the sender-only lines (view-only hint, missing folder)")
        let other = try primary.importTransferredThread(projectName: "只在另一台的資料夾", title: "別台資料夾", messages: packet, files: [])
        let again = try primary.importTransferredThread(projectName: "只在另一台的資料夾", title: "別台資料夾 2", messages: packet, files: [])
        let otherProject = primary.projectRecord(primary.threadRecord(other)?.projectID)
        t.check(otherProject?.name == "只在另一台的資料夾" && otherProject?.workdir == CoderImport.normalized(NSHomeDirectory())
                && primary.threadRecord(again)?.projectID == otherProject?.id
                && primary.transcript(for: other).first?.text.hasPrefix("從另一台併過來的匯入串：原資料夾在另一台") == true
                && inChat() == chatBefore, "pushed import with an unknown project → same-name project here (noted), never 聊天")
        t.check(primary.importedSeed(threadID: other, engine: .claude, userText: "x", currentTurn: "t") != nil, "pushed import still seeds")
        let plain = try primary.importTransferredThread(projectName: "只在另一台的資料夾-x", title: "一般的串",
                                                        messages: [.init(role: "user", text: "hi", createdAt: Date())], files: [])
        t.check(primary.projectRecord(primary.threadRecord(plain)?.projectID)?.name == "一般", "ordinary transfers keep the old rule")
    }

    // MARK: - w180spaces

    @MainActor private static func spaces(root: URL, environment: [String: String]) async throws -> Bool {
        let t = Tally("W180SPACES")
        let spacesRoot = root.appendingPathComponent("spaces-test")
        let spaces = CoderProjectSpaces(root: spacesRoot)
        let p1 = UUID(), p2 = UUID(), p3 = UUID(), gone = UUID()
        let items = [p1, p2, p3]
        t.check(spaces.selectedSpace == nil && spaces.selectedName == "全部專案" && spaces.visible(items, id: { $0 }) == items
                && spaces.showsRemote(p1, deviceID: "dev-a"), "default 全部專案 shows everything unchanged")
        let work = spaces.addSpace(named: "工作")
        t.check(spaces.selectedSpace?.id == work && spaces.visible(items, id: { $0 }).isEmpty, "new space is selected and empty")
        spaces.setMember(localProject: p3, in: work, true)
        spaces.setMember(localProject: gone, in: work, true)
        spaces.move(localProject: p1, to: work)
        t.check(spaces.visible(items, id: { $0 }) == [p1, p3], "filter keeps members in original order; deleted ids are skipped")
        spaces.setMember(remoteProject: p2, deviceID: "dev-a", in: work, true)
        t.check(spaces.showsRemote(p2, deviceID: "dev-a") && !spaces.showsRemote(p2, deviceID: "dev-b") && !spaces.showsRemote(p1, deviceID: "dev-a"),
                "remote device blocks filter by (device, project)")
        let other = spaces.addSpace(named: "工作")
        t.check(spaces.space(other)?.name == "工作 2", "duplicate names get a number")
        spaces.move(localProject: p1, to: other)
        t.check(!spaces.contains(localProject: p1, in: work) && spaces.contains(localProject: p1, in: other), "move is exclusive")
        spaces.adoptLocalProject(p2)
        t.check(spaces.contains(localProject: p2, in: other), "new project joins the selected space")
        spaces.select(nil)
        spaces.adoptLocalProject(p3)
        t.check(!spaces.contains(localProject: p3, in: other) && spaces.visible(items, id: { $0 }) == items, "全部專案 adopts nothing")
        spaces.select(work)
        spaces.rename(work, to: "  客戶 A  ")
        let reloaded = CoderProjectSpaces(root: spacesRoot)
        t.check(reloaded.selectedSpace?.name == "客戶 A" && reloaded.file == spaces.file, "saved atomically and reloads the same")
        spaces.archive(work)
        t.check(spaces.selectedSpace == nil && spaces.space(work)?.isArchived == true && spaces.file.spaces.count == 2,
                "archive keeps the space (no delete) and falls back to 全部專案")
        spaces.restore(work)
        t.check(spaces.activeSpaces.contains { $0.id == work }, "archived space can be restored")

        let fileURL = spacesRoot.appendingPathComponent("coder-spaces.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL)
        let broken = CoderProjectSpaces(root: spacesRoot)
        t.check(broken.selectedSpace == nil && broken.loadProblem != nil && broken.visible(items, id: { $0 }) == items
                && (try? Data(contentsOf: fileURL)) == garbage
                && (try? Data(contentsOf: fileURL.appendingPathExtension("bak"))) == garbage,
                "broken file → 全部專案, original untouched, .bak kept")
        broken.addSpace(named: "重建")
        t.check((try? JSONDecoder().decode(CoderProjectSpacesFile.self, from: Data(contentsOf: fileURL))) != nil
                && (try? Data(contentsOf: fileURL.appendingPathExtension("bak"))) == garbage, "first change rewrites the file; .bak stays")

        // 私訊框的 Coder 對象不受空間影響；模型的專案清單也不變（只有側欄那一層過濾）。
        let (model, engine) = await makeModel(root: root, environment: environment)
        defer { engine.shutdownAll() }
        let inSpace = engine.newProject(name: "放進空間", workdir: root.path)
        let outside = engine.newProject(name: "沒放", workdir: root.path)
        let threadOutside = engine.newThread(in: outside, title: "空間外的串")
        let shared = CoderProjectSpaces.shared
        let space = shared.addSpace(named: "自測")
        shared.setMember(localProject: inSpace, in: space, true)
        model.document = engine.document
        t.check(shared.visible(model.filteredProjects, id: \.id).map(\.id) == [inSpace]
                && model.filteredProjects.contains { $0.id == outside }, "sidebar filter hides projects outside the space; model list unchanged")
        t.check(model.dmSessionCandidates().contains { $0.id == threadOutside }, "DM Coder targets ignore the project space")
        shared.select(nil)
        t.check(shared.visible(model.filteredProjects, id: \.id).map(\.id) == model.filteredProjects.map(\.id), "back to 全部專案 = identical list")
        return t.finish()
    }
}
#endif
