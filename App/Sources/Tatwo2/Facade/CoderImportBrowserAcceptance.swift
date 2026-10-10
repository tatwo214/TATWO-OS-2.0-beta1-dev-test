#if DEBUG
import AppKit
import CryptoKit
import Foundation
import SQLite3
import SwiftUI

/// W181 R1 自測：`TATWO2_SELFTEST=w181import`。只在完整隔離的 staging 環境跑；Codex 資料庫、global state、
/// Claude Code 專案資料夾都是自己合成的，不讀使用者真的紀錄，也不送出任何一句給引擎。
/// 驗：專案清單與順序照來源、子代理與背景對話不列、標題來源的先後、整個專案匯入同名 Coder 專案、原檔（含 sqlite）不變、
/// Esc／完成／✕／⌘W 都只關 sheet（事件用 NSApp.postEvent 排進事件佇列，走跟真的滑鼠鍵盤一樣的派送：
/// 本機事件監聽 → NSApp.sendEvent → 視窗 → hitTest；主視窗收不到 Esc）。
enum CoderImportBrowserAcceptance {
    private final class Tally {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W181IMPORT \(condition ? "PASS" : "FAIL") \(label)")
        }
        func finish() -> Bool { print("W181IMPORT SUMMARY passed=\(passed) failures=\(failed)"); return failed == 0 }
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w181import needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w181import requires a fresh live root inside TATWO_STAGING_ROOT")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = staging.appendingPathComponent("w181-fixture-\(UUID().uuidString.prefix(6))")
        let t = Tally()
        let world = try Fixture(fixture)
        let before = world.fingerprints()

        let codex = CoderImportCatalog.load(.codex, roots: world.roots)
        let claude = CoderImportCatalog.load(.claude, roots: world.roots)
        catalogChecks(t, world, codex: codex, claude: claude)
        t.check(world.fingerprints() == before, "listing and preview leave every source file (incl. state_5.sqlite and its -wal) unchanged")
        world.closeWriter()
        // Codex 沒開：旁邊沒有 -wal／-shm。唯讀讀者開不起來時改用 immutable，照樣讀得到，也不建任何檔、不改主檔。
        let closedBefore = world.fingerprints()
        let closedCodex = CoderImportCatalog.load(.codex, roots: world.roots)
        t.check(closedCodex.map(\.name) == codex.map(\.name) && closedCodex.flatMap(\.conversations).count == codex.flatMap(\.conversations).count,
                "Codex closed (no -wal/-shm): the list still reads through an immutable open")
        t.check(!world.sidecarsExist() && world.fingerprints() == closedBefore,
                "reading a closed Codex database creates no -wal/-shm and leaves state_5.sqlite unchanged")

        let (model, engine) = await makeModel(root: root, environment: environment)
        defer { engine.shutdownAll() }
        let afterClose = world.fingerprints()
        await importChecks(t, world, model: model, engine: engine, codex: codex, claude: claude)
        t.check(world.fingerprints() == afterClose, "importing leaves every source file unchanged")
        await sheetChecks(t, world, model: model)
        return t.finish()
    }

    // MARK: - 清單

    private static func catalogChecks(_ t: Tally, _ world: Fixture, codex: [CoderImportProject], claude: [CoderImportProject]) {
        t.check(CodexAppProjects.stateDatabase(in: world.codexHome)?.lastPathComponent == "state_5.sqlite"
                && !codex.contains { $0.name == "舊版專案" }, "Codex: the highest-numbered state_N.sqlite is read")
        t.check(codex.map(\.name) == ["Gamma 名稱不同", "Beta 專案", "Alpha 專案", "Delta 專案", "空的專案", "Echo 專案", CoderImportCatalog.projectlessName],
                "Codex projects: pinned first, then project-order, remote project skipped, 沒有專案的對話 last (\(codex.map(\.name)))")
        t.check(codex.first?.isPinned == true && codex.last?.isProjectless == true && codex.filter(\.isProjectless).count == 1,
                "Codex: pinned flag and a single projectless group")
        let alpha = codex.first { $0.name == "Alpha 專案" }
        t.check(alpha?.conversations.map(\.title) == ["Alpha 正式名稱", "Alpha 第二則的標題", "Alpha 原檔不在"]
                && alpha?.root == world.alphaRoot.path, "Codex: assignment, root match and titles (name → title), newest first")
        t.check(alpha?.conversations.last?.fileExists == false && alpha?.conversations.first?.fileExists == true,
                "Codex: a thread whose rollout file is gone is listed but marked")
        t.check(codex.first { $0.name == "Beta 專案" }?.conversations.map(\.title) == ["Beta 第一句話"], "Codex: project_id column; title falls back to the first message")
        let everyCodex = codex.flatMap(\.conversations).map(\.session.sessionID)
        t.check(!everyCodex.contains { Fixture.hiddenCodexIDs.contains($0) },
                "Codex: exec, subagent, archived, spawned-child, codex_exec and never-used (no title, no message) threads are not listed")
        t.check(codex.last?.conversations.map(\.session.sessionID) == ["x9", "x12"] && codex.last?.root == world.chatsRoot.path,
                "Codex: explicit projectless threads go to 沒有專案的對話; its folder is Codex's own workspace root hint")
        t.check(codex.first { $0.name == "Gamma 名稱不同" }?.conversations.count == 32
                && codex.first { $0.name == "空的專案" }?.conversations.isEmpty == true, "Codex: counts per project (32, empty project kept)")

        t.check(claude.map(\.name) == [CoderImport.homeProjectName, "claude-alpha", "claude-alpha"]
                && claude.last?.root == world.otherAlphaDir.path,
                "Claude Code projects: folder names, newest activity first; background-only folder not listed; same last folder name kept apart (\(claude.map(\.name)))")
        let titles = Dictionary(uniqueKeysWithValues: claude.flatMap(\.conversations).map { ($0.session.sessionID, $0.title) })
        t.check(titles[world.cid(1)] == "代理名稱 c1" && titles[world.cid(2)] == "自訂標題 c2" && titles[world.cid(3)] == "AI 標題 c3"
                && titles[world.cid(4)] == "摘要 c4" && titles[world.cid(5)] == "c5 的第一句",
                "Claude Code title order: agent name → custom title (tail of a big file) → AI title → summary → first real message")
        t.check(titles[world.cid(8)] == "桌面標題 c8", "Claude Code: the desktop app's title wins for the same session")
        t.check(titles[world.cid(6)] == nil && titles[world.cid(7)] == nil && titles[world.cid(9)] == nil
                && !titles.keys.contains("agent-1"), "Claude Code: sidechain, -p (sdk-cli), archived desktop session and subagents are not listed")

        if let first = alpha?.conversations.first {
            let preview = CoderImportCatalog.previewItems(first.session)
            t.check(preview.items.map(\.kind) == [.user, .assistant] && !preview.items.contains { $0.text.contains("TOOL-OUTPUT-MARKER") },
                    "preview shows talk only (no tool output)")
        } else { t.check(false, "preview fixture") }
        if let first = alpha?.conversations.first {
            // 「讀完整紀錄」：W110 整份讀；篩選照 W110 的規則（預設不顯示工具，搜尋也找工具名）。
            let record = CLITranscriptArchive.read(first.session) { _ in }
            let talk = CoderImportCatalog.filter(record, query: "", showsTools: false)
            let tools = CoderImportCatalog.filter(record, query: "TOOL-OUTPUT", showsTools: true)
            t.check(record.contains { $0.kind == .toolResult } && !talk.contains { $0.kind == .toolResult || $0.kind == .toolCall }
                    && talk.count == 2 && tools.count == 1, "full record: whole file read (W110); tools hidden by default, searchable when shown")
        } else { t.check(false, "full record fixture") }
        if let big = claude.flatMap(\.conversations).first(where: { $0.session.sessionID == world.cid(2) }) {
            let preview = CoderImportCatalog.previewItems(big.session, maxBytes: 64 * 1024)
            t.check(preview.partial && !preview.items.isEmpty && preview.items.count <= CoderImportCatalog.previewRows,
                    "preview of a big file reads only its tail (\(preview.items.count) rows, partial)")
        } else { t.check(false, "big preview fixture") }
        let cap = CoderImport.maxImportedBytesTotal
        t.check(CoderImportCatalog.nearCapNotice(used: 0) == nil && CoderImportCatalog.nearCapNotice(used: cap / 2) == nil
                && CoderImportCatalog.nearCapNotice(used: cap * 9 / 10)?.contains("快滿了") == true
                && CoderImportCatalog.nearCapNotice(used: cap)?.contains("已經滿了") == true,
                "usage: silent until near the cap; never 'Zero KB'")

        // ~/.codex 是捷徑時：清單裡的原檔路徑是解開後的（跟 E3 存的一樣），內容跟直接讀一樣。
        let linked = CoderImportCatalog.load(.codex, roots: world.linkedRoots)
        let linkedPaths = linked.flatMap(\.conversations).filter(\.fileExists).map(\.session.url.path)
        t.check(linked.map(\.name) == codex.map(\.name) && !linkedPaths.isEmpty
                && linkedPaths.allSatisfy { !$0.contains("/codex-link/") && $0.hasPrefix(CoderImportCatalog.resolvedPath(world.codexHome.path) + "/") },
                "Codex home behind a symlink: same projects, rollout paths resolved")

        // 專案歸屬（純規則）：同資料夾沿用、同名不同資料夾加區別、家目錄交給「家目錄」、沒有根目錄才靠名字。
        let existing: [CoderImport.ProjectInfo] = [.init(id: UUID(), name: "工具", workdir: "/b/工具"),
                                                   .init(id: UUID(), name: "TATWO OS", workdir: "/y/tatwo"),
                                                   .init(id: UUID(), name: "暫存", workdir: "/private/tmp/jobs/暫存")]
        let home = NSHomeDirectory()
        t.check(CoderImportCatalog.placement(name: "工具", root: "/a/工具", projects: existing, home: home) == .init(name: "工具（a）", workdir: "/a/工具")
                && CoderImportCatalog.placement(name: "tatwo os", root: "/x/w181", projects: existing, home: home) == .init(name: "tatwo os（w181）", workdir: "/x/w181")
                && CoderImportCatalog.placement(name: "另一個名字", root: "/b/工具/", projects: existing, home: home) == .init(name: "工具", workdir: "/b/工具")
                && CoderImportCatalog.placement(name: "工具", root: "/b/工具", projects: existing, home: home) == .init(name: "工具", workdir: "/b/工具")
                && CoderImportCatalog.placement(name: "隨便", root: home, projects: existing, home: home).name == CoderImport.homeProjectName
                && CoderImportCatalog.placement(name: "Tatwo Os", root: "", projects: existing, home: home) == .init(name: "TATWO OS", workdir: "/y/tatwo")
                && CoderImportCatalog.placement(name: "暫存", root: "/a/jobs/暫存", projects: existing, home: home) == .init(name: "暫存（jobs）", workdir: "/a/jobs/暫存"),
                "placement: same folder reuses, same name in another folder gets a distinct name, home → 家目錄, no root → by name")
    }

    // MARK: - 匯入

    @MainActor private static func importChecks(_ t: Tally, _ world: Fixture, model: ChatPageModel, engine: ChatLiveEngine,
                                                codex: [CoderImportProject], claude: [CoderImportProject]) async {
        let job = CoderImportJob.shared
        let general = engine.doc.generalProjectID
        let generalBefore = engine.doc.threads.filter { $0.projectID == general }.count
        func threads(in name: String) -> [LiveThreadRecord] {
            let ids = Set(engine.doc.projects.filter { $0.name == name }.map(\.id))
            return engine.doc.threads.filter { $0.projectID.map(ids.contains) == true && $0.importedFrom != nil }
        }
        guard let alpha = codex.first(where: { $0.name == "Alpha 專案" }), let beta = codex.first(where: { $0.name == "Beta 專案" }),
              let gamma = codex.first(where: { $0.name == "Gamma 名稱不同" }), let loose = codex.first(where: \.isProjectless),
              let claudeAlpha = claude.first(where: { $0.name == "claude-alpha" && $0.root == world.claudeAlphaDir.path }),
              let claudeOther = claude.first(where: { $0.name == "claude-alpha" && $0.root == world.otherAlphaDir.path }),
              let delta = codex.first(where: { $0.name == "Delta 專案" }),
              let claudeHome = claude.first(where: { $0.name == CoderImport.homeProjectName }) else {
            t.check(false, "import fixtures"); return
        }

        model.importCoderProject(alpha)
        t.check(await waitIdle(job), "Alpha project import finishes")
        let alphaProjects = engine.doc.projects.filter { $0.name == "Alpha 專案" }
        t.check(alphaProjects.count == 1 && alphaProjects.first?.workdir == CoderImport.normalized(world.alphaRoot.path),
                "whole Codex project → a Coder project with the Codex name, folder = the project root")
        t.check(Set(threads(in: "Alpha 專案").map(\.title)) == ["Alpha 正式名稱", "Alpha 第二則的標題"],
                "imported threads carry Codex's own titles; the one without a file is skipped")
        t.check(model.selectedThreadID != nil && threads(in: "Alpha 專案").contains { $0.id == model.selectedThreadID }, "an imported thread is selected")

        // 同一個資料夾已經有 Coder 專案（名字不同）：沿用它，不另建同名專案（W181 審查：照資料夾，不照名字）。
        let betaExisting = engine.newProject(name: "我的 Beta", workdir: CoderImport.normalized(beta.root))
        model.importCoderProject(beta)
        t.check(await waitIdle(job), "Beta project import finishes")
        t.check(engine.doc.threads.first { $0.importedFrom?.sessionID == "x3" }?.projectID == betaExisting
                && engine.doc.projects.filter { $0.name == "Beta 專案" }.isEmpty,
                "an existing Coder project in the same folder is reused even with another name (no duplicate project)")

        model.importCoderProject(gamma)
        t.check(await waitIdle(job), "Gamma project import finishes")
        let firstBatch = threads(in: "Gamma 名稱不同")
        t.check(firstBatch.count == CoderImport.maxSessionsPerBatch && !firstBatch.contains { ["g1", "g2"].contains($0.importedFrom?.sessionID) }
                && job.status.contains("還有 2 則"), "over one batch: the most recent \(CoderImport.maxSessionsPerBatch) are imported and the rest is explained")
        t.check(firstBatch.allSatisfy { $0.importedFrom?.folderMissing == true }
                && engine.transcript(for: firstBatch.first?.id).first?.text.contains("資料夾已不在") == true
                && engine.doc.projects.first { $0.name == "Gamma 名稱不同" }?.workdir == CoderImport.normalized(world.gammaRoot.path),
                "project root missing → named project created, threads marked 資料夾已不在 (E3 rule)")
        model.importCoderProject(gamma)
        _ = await waitIdle(job)
        let count = engine.doc.threads.count
        model.importCoderProject(gamma)
        _ = await waitIdle(job)
        t.check(threads(in: "Gamma 名稱不同").count == 32 && engine.doc.threads.count == count && job.status.contains("已經匯入過"),
                "pressing again imports the rest, then only reopens")

        let projectCount = engine.doc.projects.count
        model.importCoderProject(loose)
        t.check(await waitIdle(job), "projectless import finishes")
        let looseNames = Set(engine.doc.threads.filter { ["x9", "x12"].contains($0.importedFrom?.sessionID) }
            .compactMap { engine.projectRecord($0.projectID)?.name })
        t.check(looseNames == [CodexAppProjects.projectlessCoderName] && engine.doc.projects.count == projectCount + 1
                && engine.doc.projects.first { $0.name == CodexAppProjects.projectlessCoderName }?.workdir == CoderImport.normalized(world.chatsRoot.path),
                "沒有專案的對話 → one Coder project (\(CodexAppProjects.projectlessCoderName)), not one project per scratch folder")

        if let c1 = claudeAlpha.conversations.first(where: { $0.session.sessionID == world.cid(1) }) {
            model.importCoderConversation(c1, in: claudeAlpha)
            t.check(await waitIdle(job), "single Claude Code import finishes")
            t.check(engine.doc.threads.first { $0.importedFrom?.sessionID == world.cid(1) }
                        .map { ($0.title, engine.projectRecord($0.projectID)?.name) } ?? ("", nil) == ("代理名稱 c1", "claude-alpha"),
                    "one Claude Code conversation → the project named after its folder, official title")
        } else { t.check(false, "claude single fixture") }
        model.importCoderProject(claudeHome)
        t.check(await waitIdle(job), "Claude home project import finishes")
        t.check(engine.doc.threads.first { $0.importedFrom?.sessionID == world.cid(10) }
                    .flatMap { engine.projectRecord($0.projectID)?.name } == CoderImport.homeProjectName
                && engine.doc.threads.filter { $0.projectID == general }.count == generalBefore,
                "home folder → 家目錄 project; 聊天 (一般) unchanged")

        // 同名、不同資料夾：不能併進別的資料夾（W181 審查）。
        model.importCoderProject(claudeOther)
        t.check(await waitIdle(job), "second same-named Claude Code project import finishes")
        let other = engine.doc.threads.first { $0.importedFrom?.sessionID == world.cid(11) }
        let otherProject = engine.projectRecord(other?.projectID)
        let alphaProject = engine.doc.threads.first { $0.importedFrom?.sessionID == world.cid(1) }.flatMap { engine.projectRecord($0.projectID) }
        t.check(otherProject?.name == "claude-alpha（other）" && otherProject?.workdir == CoderImport.normalized(world.otherAlphaDir.path)
                && other?.importedFrom?.cwd == CoderImport.normalized(world.otherAlphaDir.path)
                && alphaProject?.name == "claude-alpha" && alphaProject?.workdir == CoderImport.normalized(world.claudeAlphaDir.path)
                && otherProject?.id != alphaProject?.id,
                "two Claude Code folders with the same last name → two Coder projects, each thread keeps its own folder (\(otherProject?.name ?? "nil"))")
        let lookalike = engine.newProject(name: "delta 專案", workdir: CoderImport.normalized(world.betaCoderDir.appendingPathComponent("delta-elsewhere").path))
        model.importCoderProject(delta)
        t.check(await waitIdle(job), "Delta project import finishes")
        let x11 = engine.doc.threads.first { $0.importedFrom?.sessionID == "x11" }
        t.check(x11?.projectID != lookalike && engine.projectRecord(x11?.projectID)?.name == "Delta 專案（delta）"
                && engine.projectRecord(x11?.projectID)?.workdir == CoderImport.normalized(world.deltaRoot.path),
                "a Coder project with the same name (any case) but another folder is not reused; a distinct project is made for the source root")

        // ~/.codex 是捷徑：E3 的舊匯入存的是解開後的路徑；新瀏覽器照家別＋session id 認得「已匯入」，「看原檔」找得到是 Codex 的哪一則。
        let listed = CLITranscriptArchive.list(sources: [.init(root: world.codexLink.appendingPathComponent("sessions"), engine: .codex, origin: .native)])
        guard let echoSession = listed.first(where: { $0.sessionID == "x15" }) else { t.check(false, "E3-style listing through the symlink"); return }
        model.importCLISessions([echoSession])   // E3 的舊入口（照資料夾對專案）
        t.check(await waitIdle(job), "E3-style import through the symlink finishes")
        let linked = CoderImportCatalog.load(.codex, roots: world.linkedRoots)
        guard let echo = linked.first(where: { $0.name == "Echo 專案" }), let echoItem = echo.conversations.first,
              let source = engine.doc.threads.first(where: { $0.importedFrom?.sessionID == "x15" })?.importedFrom else {
            t.check(false, "echo fixtures"); return
        }
        t.check(model.coderImportIsImported(echoItem) && source.path == echoItem.session.url.path,
                "an E3 import through the symlinked ~/.codex shows as 已匯入 in the new browser")
        let focus = CoderImportFocus(source)
        let pathOnly = model.coderImportSource(path: world.codexLink.appendingPathComponent(
            String(source.path.dropFirst(CoderImportCatalog.resolvedPath(world.codexHome.path).count + 1))).path)
        t.check(CoderImportCatalog.locate(focus, in: linked)?.conversation.id == echoItem.id && focus.engine == .codex
                && CoderImportCatalog.locate(CoderImportFocus(engine: .claude, sessionID: "x15", path: source.path), in: linked) == nil
                && pathOnly?.sessionID == "x15",
                "看原檔 finds the Codex conversation by engine + session id (not by guessing from the path); a symlinked path finds its source")
        let before = engine.doc.threads.count
        model.importCoderProject(echo)
        _ = await waitIdle(job)
        t.check(engine.doc.threads.count == before && job.status.contains("已經匯入過"),
                "已匯入・打開 reopens the E3 thread instead of importing a blank duplicate")
    }

    // MARK: - 關得掉

    /// 主視窗替身：數 Esc（cancelOperation、收到的 Esc 鍵）與關窗有沒有傳到它。
    @MainActor private final class ParentWindow: NSWindow {
        var cancels = 0, closes = 0, escapes = 0
        func reset() { cancels = 0; closes = 0; escapes = 0 }
        override func cancelOperation(_ sender: Any?) { cancels += 1 }
        override func performClose(_ sender: Any?) { closes += 1 }
        override func close() { closes += 1; super.close() }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.keyCode == 53 { escapes += 1 }
            super.sendEvent(event)
        }
    }

    /// 主視窗內容的替身：跟 App 裡的 SwiftUI 內容一樣把按鍵交給 interpretKeyEvents，Esc 會走到視窗的 cancelOperation。
    @MainActor private final class KeyForwardingView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    }

    /// 私訊框替身：App 的私訊框是主視窗的子視窗（ordered .above），會被重新掛到最上面，也會自己拿走鍵盤焦點。
    @MainActor private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    @MainActor private static func sheetChecks(_ t: Tally, _ world: Fixture, model: ChatPageModel) async {
        // 像使用者那樣：主視窗貼著螢幕上緣（sheet 的 ✕／完成就在最上面那一條）。
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: min(1_280, visible.width), height: min(860, visible.height))
        let parent = ParentWindow(contentRect: NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.titlebarAppearsTransparent = true
        parent.titleVisibility = .hidden
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        var escapeWindows: [NSWindow?] = []
        let spy = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { escapeWindows.append(event.window) }
            return event
        }
        defer { if let spy { NSEvent.removeMonitor(spy) } }

        func present() async -> NSWindow? {
            CoderSheetTestFrames.frames = [:]
            CoderSheetPresenter.presentImport(model: model, roots: world.roots, parent: parent)
            for _ in 0..<60 {
                if CoderSheetTestFrames.frames["close"] != nil, CoderSheetTestFrames.frames["done"] != nil, parent.attachedSheet != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return CoderSheetPresenter.current
        }
        func closedOnlySheet() -> Bool {
            CoderSheetPresenter.current == nil && parent.attachedSheet == nil && parent.isVisible
                && parent.cancels == 0 && parent.closes == 0 && parent.escapes == 0
        }
        func settle() async { try? await Task.sleep(nanoseconds: 500_000_000) }
        func label(_ key: String) -> String { key == "close" ? "✕" : "完成" }

        // ✕、完成：畫面上看得到、最上面是 sheet（沒有別的視窗蓋住），真的滑鼠路徑點一下就只關 sheet。
        for key in ["close", "done"] {
            guard let sheet = await present(), let point = windowPoint(key, in: sheet) else { t.check(false, "sheet \(key) shows"); continue }
            let screenPoint = sheet.convertPoint(toScreen: point)
            t.check((sheet.screen ?? NSScreen.main)?.visibleFrame.contains(screenPoint) == true,
                    "\(label(key)) is on screen (\(Int(screenPoint.x)),\(Int(screenPoint.y)))")
            t.check(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == sheet.windowNumber,
                    "\(label(key)) is the topmost window at its spot (nothing covers it)")
            click(point, in: sheet)
            await settle()
            t.check(closedOnlySheet(), "clicking \(label(key)) (posted mouse down/up, same dispatch as a real click) closes only the sheet")
            if CoderSheetPresenter.current != nil { CoderSheetPresenter.close() }
        }

        // 私訊框拿走鍵盤焦點、又被重新掛到主視窗最上面：sheet 不是 key，✕ 仍然第一下就關、完成那一點仍是 sheet 在最上面。
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        if let sheet = await present(), let done = windowPoint("done", in: sheet), let close = windowPoint("close", in: sheet) {
            let doneOnScreen = sheet.convertPoint(toScreen: done)
            panel.setFrame(NSRect(x: doneOnScreen.x - 120, y: doneOnScreen.y - 60, width: 240, height: 120), display: true)
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            parent.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKey()
            try? await Task.sleep(nanoseconds: 300_000_000)
            t.check(NSWindow.windowNumber(at: doneOnScreen, belowWindowWithWindowNumber: 0) == sheet.windowNumber,
                    "a child panel re-attached above the main window does not cover the sheet's 完成")
            t.check(!sheet.isKeyWindow, "the sheet lost key focus to the child panel (setup)")
            click(close, in: sheet)
            await settle()
            t.check(closedOnlySheet(), "✕ closes the sheet on the first click even when the sheet is not key")
        } else { t.check(false, "sheet for the not-key case") }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        if CoderSheetPresenter.current != nil { CoderSheetPresenter.close() }

        // Esc：排進事件佇列（本機事件監聽也看得到），只關 sheet；主視窗沒收到 Esc、也沒被叫 cancelOperation。
        if let sheet = await present() {
            t.check(sheet.isKeyWindow || NSApp.keyWindow === sheet, "the sheet is the key window")
            escapeWindows = []
            pressEscape(windowNumber: sheet.windowNumber)
            await settle()
            t.check(closedOnlySheet() && !escapeWindows.isEmpty && escapeWindows.allSatisfy { $0 === sheet },
                    "Esc closes only the sheet; the main window never gets the key or cancelOperation (\(escapeWindows.count) Esc seen)")
        } else { t.check(false, "sheet for Esc") }

        // Sheet 關掉後，新的 Esc 與自動重複照常送給主視窗；主視窗不關窗。
        if let sheet = await present() {
            let start = ProcessInfo.processInfo.systemUptime
            postKey(.keyDown, window: sheet.windowNumber, at: start)
            postKey(.keyDown, window: parent.windowNumber, at: start + 0.05, repeat: true)
            postKey(.keyDown, window: parent.windowNumber, at: start + 0.09, repeat: true)
            postKey(.keyUp, window: parent.windowNumber, at: start + 0.12)
            await settle()
            t.check(parent.isVisible && parent.attachedSheet == nil && parent.closes == 0 && parent.escapes == 2, "held Esc reaches main responder after sheet closes and keeps window visible")
        } else { t.check(false, "sheet for held Esc") }
        if let sheet = await present() {
            let start = ProcessInfo.processInfo.systemUptime
            postKey(.keyDown, window: sheet.windowNumber, at: start)
            postKey(.keyUp, window: sheet.windowNumber, at: start + 0.03)
            try? await Task.sleep(nanoseconds: 60_000_000)
            postKey(.keyDown, window: parent.windowNumber, at: start + 0.08)
            postKey(.keyUp, window: parent.windowNumber, at: start + 0.1)
            await settle()
            t.check(parent.isVisible && parent.attachedSheet == nil && parent.closes == 0 && parent.escapes == 1, "Esc within 0.1 s after closing sheet reaches main responder")
            // 再按一次仍送到主視窗；替身主視窗只記數，不關窗。
            parent.makeKeyAndOrderFront(nil)
            let later = ProcessInfo.processInfo.systemUptime
            postKey(.keyDown, window: parent.windowNumber, at: later)
            postKey(.keyUp, window: parent.windowNumber, at: later + 0.03)
            await settle()
            t.check(parent.escapes == 2 && parent.closes == 0, "a later fresh Esc also reaches main responder without closing window")
            parent.reset()
        } else { t.check(false, "sheet for double Esc") }

        if await present() != nil {
            NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            await settle()
            t.check(closedOnlySheet(), "a nil-targeted cancelOperation stops at the sheet")
        } else { t.check(false, "sheet for cancelOperation") }

        if let sheet = await present() {
            sheet.performClose(nil)   // ⌘W／選單「關閉」
            await settle()
            t.check(closedOnlySheet(), "⌘W (performClose) closes only the sheet and ends it properly (parent not left sheet-blocked)")
        } else { t.check(false, "sheet for ⌘W") }

        CoderSheetPresenter.presentSpaces(model: model, parent: parent)
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let sheet = CoderSheetPresenter.current {
            pressEscape(windowNumber: sheet.windowNumber)
            await settle()
            t.check(closedOnlySheet(), "the 專案空間 sheet uses the same window: Esc closes only it")
        } else { t.check(false, "spaces sheet") }

        await appContextChecks(t, world, model: model)

        // 真的滑鼠（HID 事件，會動到這台的游標、要「輔助使用」權限）：只在明確打開時跑，主導在實機驗收用。
        guard ProcessInfo.processInfo.environment["TATWO2_W181_REAL_MOUSE"] == "1" else { return }
        guard AXIsProcessTrusted() else { print("W181IMPORT SKIP real mouse: this process has no Accessibility permission"); return }
        for key in ["close", "done"] {
            guard let sheet = await present(), let point = windowPoint(key, in: sheet) else { continue }
            let screenPoint = sheet.convertPoint(toScreen: point)
            let height = NSScreen.screens.first?.frame.height ?? 0
            let location = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 250_000_000)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await settle()
            t.check(closedOnlySheet(), "real HID mouse click on \(label(key)) closes only the sheet")
            if CoderSheetPresenter.current != nil { CoderSheetPresenter.close() }
        }
    }

    /// 真的 App 情境：真的 Island 面板（同一個類別、層級、位置，跟 App 一樣沒設 ignoresMouseEvents）＋真的 TATWO 主視窗
    /// （TatwoWorkOSWindow）貼在螢幕上緣，靠左與置中兩種擺法。用 WindowServer 的點擊判定
    /// （windowNumber(at:)：哪個視窗會收到這一點的滑鼠按下）確認 ✕／完成那一點收到點擊的是 sheet；Esc 不會關掉主視窗。
    @MainActor private static func appContextChecks(_ t: Tally, _ world: Fixture, model: ChatPageModel) async {
        guard let screen = NSScreen.main else { t.check(false, "a screen for the app-context checks"); return }
        TatwoInterruptGate.activityProvider = { false }
        let island = TatwoIslandShellPanel(contentRect: TatwoIslandShellMetrics.overlayFrame(in: screen.frame),
                                           viewController: NSHostingController(rootView: TatwoIslandShellView(state: TatwoIslandShellState())))
        island.setFrame(TatwoIslandShellMetrics.overlayFrame(in: screen.frame), display: true)
        island.orderFrontRegardless()
        defer { island.orderOut(nil) }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1_280, visible.width), height: min(860, visible.height))
        let main = TatwoWorkOSWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.titlebarAppearsTransparent = true
        main.titleVisibility = .hidden
        let content = KeyForwardingView(frame: NSRect(origin: .zero, size: size))
        main.contentView = content
        defer { main.orderOut(nil) }
        for (name, x) in [("left", visible.minX), ("centered", visible.midX - size.width / 2)] {
            main.setFrame(NSRect(x: x, y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
            main.makeKeyAndOrderFront(nil)
            main.makeFirstResponder(content)
            try? await Task.sleep(nanoseconds: 300_000_000)
            CoderSheetTestFrames.frames = [:]
            CoderSheetPresenter.presentImport(model: model, roots: world.roots, parent: main)
            for _ in 0..<60 where CoderSheetTestFrames.frames["done"] == nil || main.attachedSheet == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let sheet = CoderSheetPresenter.current else { t.check(false, "sheet on the real main window (\(name))"); continue }
            for key in ["close", "done"] {
                guard let point = windowPoint(key, in: sheet) else { t.check(false, "\(key) frame (\(name))"); continue }
                let spot = sheet.convertPoint(toScreen: point)
                let hit = NSWindow.windowNumber(at: spot, belowWindowWithWindowNumber: 0)
                let underIsland = island.frame.contains(spot)
                t.check(hit == sheet.windowNumber,
                        "real Island + real main window (\(name)): a click on \(key == "close" ? "✕" : "完成") lands on the sheet"
                        + "\(underIsland ? " (inside the Island panel's frame, transparent part)" : "") hit=\(hit) sheet=\(sheet.windowNumber) island=\(island.windowNumber)")
            }
            if name == "centered" {
                let start = ProcessInfo.processInfo.systemUptime
                postKey(.keyDown, window: sheet.windowNumber, at: start)
                postKey(.keyDown, window: main.windowNumber, at: start + 0.05, repeat: true)
                postKey(.keyUp, window: main.windowNumber, at: start + 0.08)
                try? await Task.sleep(nanoseconds: 500_000_000)
                t.check(CoderSheetPresenter.current == nil && main.attachedSheet == nil && main.isVisible,
                        "Esc (held) on the sheet over a real TatwoWorkOSWindow closes only the sheet; the TATWO window stays open")
                // W290：保護期過後，新的 Esc 到主視窗也不會關窗。
                try? await Task.sleep(nanoseconds: 300_000_000)
                main.makeFirstResponder(content)
                let later = ProcessInfo.processInfo.systemUptime
                postKey(.keyDown, window: main.windowNumber, at: later)
                postKey(.keyUp, window: main.windowNumber, at: later + 0.03)
                try? await Task.sleep(nanoseconds: 500_000_000)
                t.check(main.isVisible, "a fresh Esc later keeps the real TatwoWorkOSWindow visible")
            }
            if CoderSheetPresenter.current != nil { CoderSheetPresenter.close() }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    @MainActor private static func postKey(_ type: NSEvent.EventType, window: Int, at time: TimeInterval, repeat isRepeat: Bool = false) {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window, context: nil,
                                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: isRepeat, keyCode: 53) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// SwiftUI 回報的位置（hosting view 左上為原點）換成 sheet 的視窗座標。
    @MainActor private static func windowPoint(_ key: String, in sheet: NSWindow) -> NSPoint? {
        guard let frame = CoderSheetTestFrames.frames[key], let host = sheet.contentView, frame.width > 0 else { return nil }
        let local = NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
        return host.convert(local, to: nil)
    }

    /// 排進事件佇列（不是直接呼叫 sendEvent）：跟真的點擊一樣先過 App 的本機事件監聽，再由 NSApp 派給視窗、做 hitTest。
    @MainActor private static func click(_ point: NSPoint, in window: NSWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + Double(index) * 0.06,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    @MainActor private static func pressEscape(windowNumber: Int) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: windowNumber, context: nil, characters: "\u{1b}",
                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    @MainActor private static func waitIdle(_ job: CoderImportJob) async -> Bool {
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<1_500 where job.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        return !job.isRunning
    }

    @MainActor private static func makeModel(root: URL, environment: [String: String]) async -> (ChatPageModel, ChatLiveEngine) {
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        return (ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library))), engine)
    }

    // MARK: - 合成的來源

    private final class Fixture {
        static let hiddenCodexIDs: Set<String> = ["x4", "x5", "x6", "x7", "x8", "x13"]
        let base: URL
        let codexHome: URL
        let roots: CoderImportCatalog.Roots
        let alphaRoot: URL, betaCoderDir: URL, gammaRoot: URL, chatsRoot: URL
        let deltaRoot: URL, echoRoot: URL, claudeAlphaDir: URL, otherAlphaDir: URL
        /// 指到 codexHome 的捷徑（這台的 ~/.codex 就是捷徑）。
        let codexLink: URL
        /// 1…11 對到 c1…c11。
        let claudeIDs: [Int: String]
        func cid(_ number: Int) -> String { claudeIDs[number] ?? "" }
        private var writer: OpaquePointer?
        private var watched: [URL] = []

        init(_ base: URL) throws {
            self.base = base
            let fm = FileManager.default
            codexHome = base.appendingPathComponent("codex")
            let work = base.appendingPathComponent("work")
            alphaRoot = work.appendingPathComponent("alpha")
            betaCoderDir = work.appendingPathComponent("beta-coder")
            gammaRoot = work.appendingPathComponent("gamma-folder")   // 故意不建：資料夾已不在
            chatsRoot = work.appendingPathComponent("codex-chats")     // Codex 放「沒有專案的對話」的資料夾
            deltaRoot = work.appendingPathComponent("delta")           // 故意不建
            echoRoot = work.appendingPathComponent("echo")
            claudeAlphaDir = work.appendingPathComponent("claude-alpha")
            otherAlphaDir = work.appendingPathComponent("other/claude-alpha")   // 最後一段跟上面同名、資料夾不同
            codexLink = base.appendingPathComponent("codex-link")
            for dir in [alphaRoot, alphaRoot.appendingPathComponent("sub"), betaCoderDir, work.appendingPathComponent("beta"),
                        work.appendingPathComponent("empty"), claudeAlphaDir, otherAlphaDir, echoRoot, codexHome, chatsRoot] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try fm.createSymbolicLink(at: codexLink, withDestinationURL: codexHome)
            let claudeProjects = base.appendingPathComponent("claude/projects")
            let desktop = base.appendingPathComponent("claude-desktop")
            roots = .init(codexHome: codexHome, claudeProjects: claudeProjects, claudeDesktopSessions: desktop, home: NSHomeDirectory())
            claudeIDs = Dictionary(uniqueKeysWithValues: (1...11).map { ($0, UUID().uuidString.lowercased()) })
            try buildCodex(work: work)
            try buildClaude(projects: claudeProjects, desktop: desktop, alphaDir: claudeAlphaDir)
        }

        /// 同一份 Codex 資料，但經過捷徑讀（跟這台的 ~/.codex 一樣）。
        var linkedRoots: CoderImportCatalog.Roots {
            .init(codexHome: codexLink, claudeProjects: roots.claudeProjects, claudeDesktopSessions: roots.claudeDesktopSessions, home: roots.home)
        }

        func fingerprints() -> [String] {
            watched.map { url in
                let data = (try? Data(contentsOf: url)) ?? Data()
                let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                return url.lastPathComponent + "=" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "@\(date.timeIntervalSince1970)"
            }
        }

        /// 「Codex 正開著」：寫入的連線一直開到清單讀完才關。關掉後把 -wal／-shm 拿掉（這是自測自己合成的檔），
        /// 模擬 Codex 沒開、只剩主檔的情況。
        func closeWriter() {
            if let writer { sqlite3_close(writer) }
            writer = nil
            let db = codexHome.appendingPathComponent("state_5.sqlite")
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
            watched = watched.filter { !$0.lastPathComponent.hasPrefix("state_5.sqlite") } + [db]
        }

        func sidecarsExist() -> Bool {
            let db = codexHome.appendingPathComponent("state_5.sqlite").path
            return ["-wal", "-shm"].contains { FileManager.default.fileExists(atPath: db + $0) }
        }

        private func line(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }

        private func write(_ lines: [String], to url: URL, age: TimeInterval) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            let date = Date().addingTimeInterval(-age)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            watched.append(url)
        }

        private func exec(_ db: OpaquePointer?, _ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw BotLibraryError.invalid("fixture sql: " + String(cString: sqlite3_errmsg(db)))
            }
        }

        private static func quote(_ value: String?) -> String {
            value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
        }

        private func buildCodex(work: URL) throws {
            // 舊版資料庫：號碼小，不該被讀。
            var old: OpaquePointer?
            sqlite3_open_v2(codexHome.appendingPathComponent("state_2.sqlite").path, &old, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            try exec(old, "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT '{}', position INTEGER NOT NULL); INSERT INTO projects VALUES ('old','舊版專案','{}',0);")
            sqlite3_close(old)
            watched.append(codexHome.appendingPathComponent("state_2.sqlite"))

            sqlite3_open_v2(codexHome.appendingPathComponent("state_5.sqlite").path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            try exec(writer, """
                PRAGMA journal_mode=WAL;
                CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT '{}', position INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL DEFAULT 0, updated_at_ms INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY (project_id, position));
                CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                    source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
                    first_user_message TEXT NOT NULL DEFAULT '', agent_nickname TEXT, agent_role TEXT, updated_at_ms INTEGER, thread_source TEXT,
                    preview TEXT NOT NULL DEFAULT '', recency_at_ms INTEGER NOT NULL DEFAULT 0, name TEXT, is_pinned INTEGER NOT NULL DEFAULT 0,
                    project_id TEXT, originator TEXT);
                CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
                """)
            let projects: [(id: String, name: String, root: URL, position: Int)] = [
                ("A1", "Alpha 專案", alphaRoot, 0), ("A2", "Beta 專案", work.appendingPathComponent("beta"), 1),
                ("A3", "Gamma 名稱不同", gammaRoot, 2), ("A4", "空的專案", work.appendingPathComponent("empty"), 3),
                ("A5", "Echo 專案", echoRoot, 4),
            ]
            for project in projects {
                try exec(writer, "INSERT INTO projects (id, name, position) VALUES (\(Self.quote(project.id)), \(Self.quote(project.name)), \(project.position));"
                         + "INSERT INTO project_roots VALUES (\(Self.quote(project.id)), 0, \(Self.quote(project.root.path)));")
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let sessions = codexHome.appendingPathComponent("sessions/2026/09/20")
            func thread(_ id: String, cwd: URL, title: String, name: String? = nil, first: String = "", source: String = "vscode",
                        threadSource: String? = "user", archived: Int = 0, nickname: String? = nil, project: String? = nil,
                        originator: String? = nil, age: Int64, file: Bool = true, viaLink: Bool = false) throws {
                let rollout = sessions.appendingPathComponent("rollout-2026-09-20T01-00-00-\(id).jsonl")
                // 這台的 Codex 資料庫記的是 ~/.codex/…（捷徑），不是解開後的路徑。
                let stored = viaLink ? codexLink.appendingPathComponent("sessions/2026/09/20/" + rollout.lastPathComponent) : rollout
                if file {
                    try write([line(["type": "session_meta", "payload": ["id": id, "cwd": cwd.path, "source": "cli"]]),
                               line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "問 \(id)"]]]]),
                               line(["type": "response_item", "payload": ["type": "function_call_output", "output": "TOOL-OUTPUT-MARKER"]]),
                               line(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "答 \(id)"]]]])],
                              to: rollout, age: 7_200)
                }
                let recency = now - age
                try exec(writer, """
                    INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, archived, first_user_message, agent_nickname,
                        updated_at_ms, thread_source, recency_at_ms, name, project_id, originator)
                    VALUES (\(Self.quote(id)), \(Self.quote(stored.path)), \(recency / 1000), \(recency / 1000), \(Self.quote(source)), \(Self.quote(cwd.path)),
                        \(Self.quote(title)), \(archived), \(Self.quote(first)), \(Self.quote(nickname)), \(recency), \(Self.quote(threadSource)), \(recency),
                        \(Self.quote(name)), \(Self.quote(project)), \(Self.quote(originator)));
                    """)
            }
            try thread("x1", cwd: alphaRoot, title: "alpha 的第一句", name: "Alpha 正式名稱", age: 1_000)
            try thread("x2", cwd: alphaRoot.appendingPathComponent("sub"), title: "Alpha 第二則的標題", source: "cli", originator: "codex-tui", age: 2_000)
            try thread("x10", cwd: alphaRoot, title: "Alpha 原檔不在", age: 3_000, file: false)
            try thread("x3", cwd: work.appendingPathComponent("beta"), title: "", name: "", first: "Beta 第一句話", project: "A2", age: 1_500)
            try thread("x4", cwd: alphaRoot, title: "exec 房間", source: "exec", threadSource: nil, age: 100)
            try thread("x5", cwd: alphaRoot, title: "子代理", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"x1","depth":1}}}"#,
                       threadSource: "subagent", nickname: "Helper", age: 100)
            try thread("x6", cwd: alphaRoot, title: "封存的", archived: 1, age: 100)
            try thread("x7", cwd: alphaRoot, title: "被生出來的", age: 100)
            try thread("x8", cwd: alphaRoot, title: "codex exec", originator: "codex_exec", age: 100)
            try thread("x9", cwd: alphaRoot, title: "沒有專案的那則", age: 4_000)
            try thread("x12", cwd: chatsRoot.appendingPathComponent("2026-09-20/new-chat"), title: "另一則沒有專案的", age: 4_500)
            try thread("x13", cwd: alphaRoot, title: "", name: nil, first: "", age: 50)   // 開了沒說話：Codex 左邊欄也不列
            try thread("x11", cwd: deltaRoot, title: "Delta 的對話", age: 5_000)
            try thread("x15", cwd: echoRoot, title: "Echo 的對話", project: "A5", age: 6_000, viaLink: true)
            for index in 1...32 {
                try thread("g\(index)", cwd: gammaRoot, title: "Gamma 第 \(index) 則", age: Int64(100_000 - index * 1_000))
            }
            try exec(writer, "INSERT INTO thread_spawn_edges VALUES ('x1', 'x7', 'closed');")

            var assignments: [String: Any] = [:]
            for id in ["x1", "x4", "x5", "x6", "x7", "x8", "x10"] { assignments[id] = ["projectKind": "local", "projectId": "L1"] }
            for index in 1...32 { assignments["g\(index)"] = ["projectKind": "local", "projectId": "L3"] }
            assignments["x11"] = ["projectKind": "local", "projectId": "L5"]
            let state: [String: Any] = [
                "local-projects": [
                    "L1": ["id": "L1", "name": "Alpha 專案", "rootPaths": [alphaRoot.path]],
                    "L3": ["id": "L3", "name": "Gamma 名稱不同", "rootPaths": [gammaRoot.path]],
                    "L5": ["id": "L5", "name": "Delta 專案", "rootPaths": [deltaRoot.path]],
                ],
                "app-server-project-id-by-legacy-project-id-by-host": ["local:" + codexHome.path: ["L1": "A1", "L2": "A2", "L3": "A3", "L4": "A4"]],
                "project-order": ["L2", "R1", "L1", "L5", "L4"],
                "pinned-project-ids": ["L3"],
                "remote-projects": [["id": "R1", "hostId": "remote-ssh-discovered:primary-one", "remotePath": "/remote/x", "label": "遠端專案"]],
                "thread-project-assignments": assignments,
                "projectless-thread-ids": ["x9", "x12"],
                "thread-workspace-root-hints": ["x2": alphaRoot.appendingPathComponent("sub").path, "x9": chatsRoot.path, "x12": chatsRoot.path],
            ]
            let stateURL = codexHome.appendingPathComponent(".codex-global-state.json")
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL)
            watched.append(stateURL)
            let db = codexHome.appendingPathComponent("state_5.sqlite")
            watched += [db, URL(fileURLWithPath: db.path + "-wal")].filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        private func buildClaude(projects: URL, desktop: URL, alphaDir: URL) throws {
            let alpha = projects.appendingPathComponent("-fx-alpha"), home = projects.appendingPathComponent("-fx-home")
            let rooms = projects.appendingPathComponent("-fx-rooms")
            func session(_ number: Int, in folder: URL, cwd: String, entry: String = "cli", sidechain: Bool = false,
                         body: [[String: Any]], tail: [[String: Any]] = [], padding: Int = 0, age: TimeInterval) throws {
                let id = claudeIDs[number] ?? "c\(number)"
                var lines = [line(["type": "user", "cwd": cwd, "entrypoint": entry, "sessionId": id, "isSidechain": sidechain,
                                   "message": ["role": "user", "content": "<command-name>/clear</command-name>\n<command-message>clear</command-message>"]])]
                lines += body.map(line)
                for index in 0..<padding {
                    lines.append(line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "填充 \(index) " + String(repeating: "x", count: 2_000)]]]]))
                }
                lines += tail.map(line)
                try write(lines, to: folder.appendingPathComponent("\(id).jsonl"), age: age)
            }
            func user(_ text: String, meta: Bool = false) -> [String: Any] {
                ["type": "user", "isMeta": meta, "message": ["role": "user", "content": text]]
            }
            let answer: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "好"]]]]
            let cwd = alphaDir.path
            try session(1, in: alpha, cwd: cwd, body: [user("真正的第一句 c1"), answer, ["type": "ai-title", "aiTitle": "AI 標題 c1"],
                                                        ["type": "summary", "summary": "摘要 c1"], ["type": "custom-title", "customTitle": "自訂標題 c1"],
                                                        ["type": "agent-name", "agentName": "代理名稱 c1"]], age: 600)
            try session(2, in: alpha, cwd: cwd, body: [user("c2 第一句"), answer, ["type": "ai-title", "aiTitle": "AI 標題 c2"]],
                        tail: [["type": "summary", "summary": "摘要 c2"], answer, ["type": "custom-title", "customTitle": "自訂標題 c2"]],
                        padding: 400, age: 700)
            try session(3, in: alpha, cwd: cwd, body: [user("c3 第一句"), ["type": "summary", "summary": "摘要 c3"], ["type": "ai-title", "aiTitle": "AI 標題 c3"]], age: 800)
            try session(4, in: alpha, cwd: cwd, body: [user("c4 第一句"), ["type": "summary", "summary": "摘要 c4"]], age: 900)
            try session(5, in: alpha, cwd: cwd, body: [user("不該當標題", meta: true), user("<local-command-stdout>輸出</local-command-stdout>"),
                                                        user("c5 的第一句"), answer], age: 1_000)
            try session(6, in: alpha, cwd: cwd, sidechain: true, body: [user("子代理")], age: 1_100)
            try session(7, in: alpha, cwd: cwd, entry: "sdk-cli", body: [user("claude -p 跑的")], age: 1_200)
            try session(8, in: alpha, cwd: cwd, entry: "sdk-ts", body: [user("桌面 App 裡開的")], age: 1_300)
            try session(9, in: alpha, cwd: cwd, body: [user("封存的桌面對話")], age: 1_400)
            try write([line(["type": "user", "cwd": cwd, "isSidechain": true, "message": ["role": "user", "content": "subagent"]])],
                      to: alpha.appendingPathComponent("\(claudeIDs[1] ?? "c1")/subagents/agent-1.jsonl"), age: 50)
            try session(10, in: home, cwd: NSHomeDirectory(), body: [user("家目錄裡問的"), answer, ["type": "ai-title", "aiTitle": "家目錄的對話"]], age: 100)
            try session(11, in: projects.appendingPathComponent("-fx-other-alpha"), cwd: otherAlphaDir.path,
                        body: [user("另一個資料夾問的"), answer, ["type": "ai-title", "aiTitle": "另一個 claude-alpha 的對話"]], age: 2_000)
            let roomID = UUID().uuidString.lowercased()
            try write([line(["type": "user", "cwd": "/tmp/room", "entrypoint": "sdk-cli", "sessionId": roomID, "message": ["role": "user", "content": "施工"]])],
                      to: rooms.appendingPathComponent("\(roomID).jsonl"), age: 10)
            let appDir = desktop.appendingPathComponent("account/org")
            for (number, title, archived, prefix) in [(8, "桌面標題 c8", false, "local_"), (9, "封存的桌面標題", true, "")] {
                let id = claudeIDs[number] ?? ""
                let object: [String: Any] = ["sessionId": prefix + id, "title": title, "isArchived": archived, "cwd": cwd]
                let url = appDir.appendingPathComponent("local_\(id).json")
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: object).write(to: url)
                watched.append(url)
            }
        }
    }
}
#endif
