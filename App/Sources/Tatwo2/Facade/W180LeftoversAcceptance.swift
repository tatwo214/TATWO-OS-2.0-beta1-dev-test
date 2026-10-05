#if DEBUG
import Darwin
import Foundation

/// W180 R2 自測（`TATWO2_SELFTEST=w180leftovers`）：
/// B3 清舊簽章副本的挑選與刪除（假資料夾、不同修改時間、硬連結當「正在用的那份」、捷徑與旁邊的資料夾不動）；
/// D3 權限放行寫進「那則訊息所屬的討論串」（引擎層與 ChatPageModel 層；要在 lead-verify 的隔離環境跑）。
enum W180LeftoversAcceptance {
    @MainActor private final class Tally {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W180LEFTOVERS \(condition ? "PASS" : "FAIL") \(label)")
        }
    }

    @MainActor static func run() async throws -> Bool {
        let tally = Tally()
        try cloneChecks(tally)
        try await threadChecks(tally)
        print("W180LEFTOVERS SUMMARY failures=\(tally.failed) passed=\(tally.passed)")
        return tally.failed == 0
    }

    // MARK: B3

    @MainActor private static func cloneChecks(_ t: Tally) throws {
        typealias Cleaner = CodeSignCloneCleaner
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("w180-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date()

        t.check(Cleaner.folder(userTempDirectory: "/var/folders/ab/cd1234/T/").path
                == "/var/folders/ab/cd1234/X/ai.tatwo.tatwo2.code_sign_clone", "B3 folder is T/../X/<bundle id>.code_sign_clone")
        t.check(Cleaner.userTempDirectory()?.hasSuffix("/T/") == true, "B3 user temp dir resolves like getconf DARWIN_USER_TEMP_DIR")

        let folder = Cleaner.folder(userTempDirectory: root.appendingPathComponent("folders/ab/T").path + "/")
        t.check(folder.path == root.appendingPathComponent("folders/ab/X/ai.tatwo.tatwo2.code_sign_clone").standardizedFileURL.path,
                "B3 fake folder sits next to the fake T")
        let appExe = root.appendingPathComponent("Applications/TATWO OS.app/Contents/MacOS/tatwo2")
        try fm.createDirectory(at: appExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("running build".utf8).write(to: appExe)

        func makeClone(_ name: String, age: TimeInterval, linkRunning: Bool) throws {
            let clone = folder.appendingPathComponent(name, isDirectory: true)
            let contents = clone.appendingPathComponent("TATWO OS.app.bundle/Contents", isDirectory: true)
            let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            let exe = macos.appendingPathComponent("tatwo2")
            if linkRunning { try fm.linkItem(at: appExe, to: exe) } else { try Data("old build \(name)".utf8).write(to: exe) }
            try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: clone.path)
        }
        let old1 = "code_sign_clone.old111", old2 = "code_sign_clone.old222"
        let inUse = "code_sign_clone.inuse3", newest = "code_sign_clone.new444"
        try makeClone(old1, age: 3 * 86_400, linkRunning: false)
        try makeClone(old2, age: 2 * 86_400, linkRunning: false)
        try makeClone(inUse, age: 86_400, linkRunning: true)
        try makeClone(newest, age: 7_200, linkRunning: false)
        // 不該碰的：指到外面的捷徑、同名開頭的檔案、其他檔、別的 App 的副本資料夾。
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        let link = folder.appendingPathComponent("code_sign_clone.link55")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-9 * 86_400)], ofItemAtPath: outside.path)
        let file = folder.appendingPathComponent("code_sign_clone.file66")
        try Data("not a folder".utf8).write(to: file)
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("other".utf8).write(to: notes)
        let sibling = folder.deletingLastPathComponent()
            .appendingPathComponent("com.example.other.code_sign_clone/code_sign_clone.zz9", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-9 * 86_400)], ofItemAtPath: sibling.path)

        let scanned = Cleaner.scan(folder: folder, executableName: "tatwo2")
        t.check(Set(scanned.map(\.url.lastPathComponent)) == [old1, old2, inUse, newest],
                "B3 scan lists only real clone folders (no symlink, no file, no other names)")
        let running = Cleaner.FileIdentity.of(appExe.path)
        t.check(running != nil && scanned.first { $0.url.lastPathComponent == inUse }?.executables.contains(running!) == true
                && scanned.first { $0.url.lastPathComponent == old1 }?.executables.contains(running!) == false,
                "B3 the hard-linked executable is recognised as the running one")

        let blind = Cleaner.plan(scanned, running: nil, now: now)
        t.check(blind.remove.isEmpty && blind.keep.count == 4, "B3 running copy unknown: keep everything")
        let plan = Cleaner.plan(scanned, running: running, now: now)
        t.check(Set(plan.remove.map(\.url.lastPathComponent)) == [old1, old2], "B3 plan removes only the old ones")
        t.check(Set(plan.keep.map(\.url.lastPathComponent)) == [inUse, newest], "B3 plan keeps the newest and the one in use")

        func fake(_ name: String, _ age: TimeInterval, _ exe: [Cleaner.FileIdentity] = []) -> Cleaner.Candidate {
            Cleaner.Candidate(url: URL(fileURLWithPath: "/fake/" + name), modified: now.addingTimeInterval(-age), executables: exe)
        }
        let someone = Cleaner.FileIdentity(device: 1, inode: 42)
        let recent = Cleaner.plan([fake("c60", 60), fake("c300", 300), fake("c7200", 7_200)], running: someone, now: now)
        t.check(recent.remove.map(\.url.lastPathComponent) == ["c7200"], "B3 clones younger than 10 minutes are kept")
        let oldestInUse = Cleaner.plan([fake("a", 9_000, [someone]), fake("b", 8_000), fake("c", 7_000)], running: someone, now: now)
        t.check(oldestInUse.remove.map(\.url.lastPathComponent) == ["b"], "B3 the one in use is kept even when it is the oldest")
        t.check(Cleaner.plan([], running: someone, now: now) == Cleaner.Plan(), "B3 empty folder: nothing to do")

        let outcome = Cleaner.clean(folder: folder, executableName: "tatwo2", running: running, now: now)
        t.check(Set(outcome.removed) == [old1, old2] && outcome.failed.isEmpty && Set(outcome.kept) == [inUse, newest],
                "B3 clean removed the two old clones")
        let exists = { (url: URL) in fm.fileExists(atPath: url.path) }
        t.check(!exists(folder.appendingPathComponent(old1)) && !exists(folder.appendingPathComponent(old2))
                && exists(folder.appendingPathComponent(inUse)) && exists(folder.appendingPathComponent(newest)),
                "B3 on disk: old ones gone, newest and in-use stay")
        let linkKind = (try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) ?? nil
        t.check(linkKind == .typeSymbolicLink && exists(outside.appendingPathComponent("keep.txt")),
                "B3 symlink and what it points to are untouched")
        t.check(exists(file) && exists(notes) && exists(sibling) && exists(appExe), "B3 other files, other App's clones and the App itself untouched")
        let again = Cleaner.clean(folder: folder, executableName: "tatwo2", running: running, now: now)
        t.check(again.removed.isEmpty && again.failed.isEmpty && Set(again.kept) == [inUse, newest], "B3 second run removes nothing")
        let missing = Cleaner.clean(folder: root.appendingPathComponent("no-such-folder"), executableName: "tatwo2", running: running)
        t.check(missing.removed.isEmpty && missing.skipped != nil, "B3 no folder: nothing done, no error")
        let unknown = Cleaner.clean(folder: folder, executableName: "tatwo2", running: nil)
        t.check(unknown.removed.isEmpty && unknown.skipped != nil && exists(folder.appendingPathComponent(inUse)),
                "B3 running copy unknown: nothing removed")

        let logs = root.appendingPathComponent("logs", isDirectory: true)
        Cleaner.appendLog("build 1 " + outcome.logLine, in: logs, now: now)
        let log = (try? String(contentsOf: logs.appendingPathComponent("code-sign-clone.log"), encoding: .utf8)) ?? ""
        t.check(log.contains("刪 2 份、留 2 份") && log.split(separator: "\n").count == 1, "B3 one line in the App's own log")
    }

    // MARK: D3

    @MainActor private static func threadChecks(_ t: Tally) async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let liveRoot = env["TATWO2_LIVE_ROOT"] else {
            t.check(false, "D3 needs the isolated staging environment (lead-verify)")
            return
        }
        let fm = FileManager.default
        // 只寫進隔離環境自己的引擎資料夾（驗過在 staging 根目錄底下）。
        let codexHome = EnginePaths(environment: env).codexHome
        let config = codexHome.appendingPathComponent("config.toml")
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let servers = "\n[mcp_servers.w180alpha]\ncommand = \"true\"\n\n[mcp_servers.w180beta]\ncommand = \"true\"\n"
        try Data((existing + servers).utf8).write(to: config)

        let root = URL(fileURLWithPath: liveRoot).appendingPathComponent("w180-d3-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        let project = engine.newProject(name: "D3 test project", workdir: root.path)
        let selected = engine.newThread(in: project, title: "Coder selected")
        let other = engine.newThread(in: project, title: "Engine target")
        let messageThread = engine.newThread(in: project, title: "Message thread")
        engine.select(selected)
        func mcp(_ id: UUID?) -> [String] { engine.threadRecord(id)?.enabledMCP ?? [] }
        let alpha = "mcp:codex:w180alpha", beta = "mcp:codex:w180beta"

        engine.setEnabledMCP(alpha, enabled: true, engine: .codex, threadID: other)
        t.check(mcp(other).contains(alpha), "D3 engine: allow lands on the given thread")
        t.check(!mcp(selected).contains(alpha) && engine.doc.selectedThreadID == selected,
                "D3 engine: the selected thread is untouched and stays selected")
        engine.setEnabledMCP(beta, enabled: true, engine: .codex)
        t.check(mcp(selected).contains(beta) && !mcp(other).contains(beta),
                "D3 engine: the sidebar's selected-thread call still writes the selected one")

        guard let openAI = ChatRouteChoice.all.first(where: { $0.brandGroup == .openAI }),
              let anthropic = ChatRouteChoice.all.first(where: { $0.brandGroup == .anthropic }) else {
            t.check(false, "D3 route catalogue has an OpenAI and an Anthropic model")
            return
        }
        // Coder 選中那條用 Claude、訊息那條用 Codex：放行若還看選中那條的引擎，就會找不到 Codex 的 w180alpha。
        engine.setRequestedModel(anthropic.id, threadID: selected)
        engine.setRequestedModel(openAI.id, threadID: messageThread)
        let library = BotLibrary(root: root.appendingPathComponent("bots"), skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        var modelEnvironment = env
        modelEnvironment["TATWO2_SOURCETEST"] = "1"   // 外掛清單同步掃（不背景探測）
        let model = ChatPageModel(environment: modelEnvironment, botCoreFixture: (engine, BotStore(library: library)))
        t.check(model.selectedThreadID == selected, "D3 model: Coder has the other thread selected")

        model.allowMCPTool(named: "mcp__w180alpha__ping", threadID: messageThread)
        t.check(mcp(messageThread).contains(alpha), "D3 model: allow writes the thread the message belongs to (its own engine)")
        t.check(!mcp(selected).contains(alpha) && model.selectedThreadID == selected,
                "D3 model: Coder's selected thread is untouched")

        if let assistant = engine.doc.assistantThreadID, model.assistantTranscriptThreadID == assistant {
            t.check(true, "D3 TATWO pane draws the local assistant thread")
            engine.setRequestedModel(openAI.id, threadID: assistant)
            model.allowMCPTool(named: "mcp__w180beta__ping", threadID: model.assistantTranscriptThreadID)
            t.check(mcp(assistant).contains(beta) && !mcp(messageThread).contains(beta),
                    "D3 model: allow from the TATWO pane writes the assistant thread, not Coder's")
        } else {
            t.check(false, "D3 TATWO pane draws the local assistant thread")
        }

        let before = engine.doc.threads.map(\.enabledMCP)
        model.allowMCPTool(named: "mcp__w180alpha__ping", threadID: UUID())
        model.allowMCPTool(named: "mcp__w180alpha__ping", threadID: nil)
        t.check(engine.doc.threads.map(\.enabledMCP) == before, "D3 model: unknown or missing thread writes nothing anywhere")
        t.check(model.mcpAllowBlockedNote(threadID: nil) == "找不到這則訊息所屬的對話，這裡沒辦法放行"
                && model.mcpAllowBlockedNote(threadID: UUID()) != nil,
                "D3 model: unknown or missing thread shows a plain line instead of the button")

        // 放行鈕與寫入用同一條規則：本機文件裡的那條才畫鈕、才寫。
        t.check(model.canAllowMCP(threadID: messageThread) && model.mcpAllowBlockedNote(threadID: messageThread) == nil,
                "D3 model: a thread of this Mac gets the allow button")

        // Coder 正在看遠端設備上的那條，本機剛好也留著同 id 的一份：鈕換成說明，按了也不寫進本機那份。
        model.selectedRemote = (deviceID: "w180-fake-remote", threadID: messageThread)
        let remoteNote = model.mcpAllowBlockedNote(threadID: messageThread)
        let messageBefore = mcp(messageThread)
        model.allowMCPTool(named: "mcp__w180beta__ping", threadID: messageThread)
        t.check(!model.canAllowMCP(threadID: messageThread) && remoteNote == "這條對話在遠端設備上，要到那台放行"
                && mcp(messageThread) == messageBefore,
                "D3 model: the remote thread on screen is refused even when this Mac keeps a copy with the same id")
        model.selectedRemote = nil
        t.check(model.canAllowMCP(threadID: messageThread) && model.selectedThreadID == selected,
                "D3 model: back on this Mac, the same thread can be allowed again")

        // 助理接在主設備（MacBook 的預設）：TATWO 頁畫的是主設備那條。主設備那條的 id 就算跟本機某條一樣，也不放行、不寫本機那條。
        var remoteDoc = LiveDocumentRecord()
        let remoteAssistant = remoteDoc.ensureAssistantThread()
        if let index = remoteDoc.threads.firstIndex(where: { $0.id == remoteAssistant }) { remoteDoc.threads[index].id = other }
        let primary = AssistantRemoteAcceptanceDouble(doc: remoteDoc)
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: "w180-primary", displayName: "Primary One"),
                                            engine: { () -> (any AssistantRemoteEngine)? in primary },
                                            connecting: { false })
        let otherBefore = mcp(other)
        if case .primary(_, let id, _) = model.assistantPlacement, id == other, model.assistantTranscriptThreadID == other {
            t.check(true, "D3 TATWO pane draws the primary's assistant thread")
        } else {
            t.check(false, "D3 TATWO pane draws the primary's assistant thread")
        }
        let primaryNote = model.mcpAllowBlockedNote(threadID: model.assistantTranscriptThreadID)
        model.allowMCPTool(named: "mcp__w180beta__ping", threadID: model.assistantTranscriptThreadID)
        t.check(!model.canAllowMCP(threadID: other) && primaryNote == "這條對話在主設備上，要到主設備放行"
                && mcp(other) == otherBefore,
                "D3 model: the primary's assistant thread is refused even when this Mac has a thread with the same id")
        model.assistantPrimaryTestDouble = nil
        t.check(model.canAllowMCP(threadID: other), "D3 model: without the primary, that local thread can be allowed again")
    }
}
#endif
