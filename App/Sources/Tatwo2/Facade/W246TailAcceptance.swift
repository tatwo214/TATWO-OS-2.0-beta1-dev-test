#if DEBUG
import Foundation
import SwiftUI
import AppKit

@MainActor enum W246TailAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let staging = env["TATWO_STAGING_ROOT"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: staging).appendingPathComponent("w246"), work = root.appendingPathComponent("work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("hello.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Task.detached { try HandsGit.checked(["init", "-q"], cwd: work.path) }.value
        let patch = "diff --git a/hello.txt b/hello.txt\n--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-before\n+after\n"
        var failures = 0
        func check(_ ok: Bool, _ label: String) { print("W246 \(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures += 1 } }
        for text in ["\u{061C}", "\u{2060}", "\u{2064}", "\u{180E}", "\u{FEFF}", "👩‍💻"] {
            do { _ = try ChangeProposalStore.check(patch.replacingOccurrences(of: "+after", with: "+after" + text), cwd: work.path); check(false, "E1 format character rejected") }
            catch { check(String(describing: error).contains("請改用一般文字"), "E1 format character rejected") }
        }
        check(try await Task.detached { try ChangeProposalStore.check(patch.replacingOccurrences(of: "+after", with: "+after😀"), cwd: work.path).count == 1 }.value, "E1 ordinary emoji accepted")
        let registry = OSMCPRegistry(environment: env), source = registry.paths.userHome.appendingPathComponent(".claude.json")
        func publish(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: ["mcpServers": object], options: [.sortedKeys]).write(to: source) }
        func candidate(_ name: String) -> OSMCPRegistry.Item { registry.scan().items.first { $0.sourceName == name }! }
        func until(_ condition: () -> Bool) async throws { try await W241PetsAcceptance.until { condition() } }
        let helper = "fixture-helper --mode read", definition: [String: Any] = ["url": "https://fixture.invalid/mcp", "headersHelper": helper, "startupCommand": "unshown-fixture", "oauth": ["clientId": "fixture", "command": "unshown-fixture"]]
        try publish(["helper": definition])
        let item = candidate("helper")
        check(item.commandLine.contains("會執行：" + helper), "E2 index text lists headersHelper")
        let artifacts = URL(fileURLWithPath: env["TATWO2_SELFTEST_ARTIFACTS"]!)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let page = PluginsPage(entries: [], environment: [], skillsDirectoryCatalog: .init(rootURL: artifacts), skilletRepositoryStore: .init(rootURL: artifacts), onRegister: { _, _, _, _ in }, onRemove: { _ in })
        let notice = IslandNotice.shared, oldHost = notice.hostAvailable
        notice.hostAvailable = true; defer { notice.hostAvailable = oldHost }
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }; theme.use(.aurora)
        guard let indexShot = GlobalDMChatAcceptance.renderSync(page.mcpAcceptanceView(scan: registry.scan(), imported: [], updates: [:], interactive: true).padding(24), size: CGSize(width: 1200, height: 720), scheme: .light) else { throw TapError.notReady }
        defer { indexShot.close() }
        await W214Acceptance.settle(indexShot)
        func press(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered) -> Bool { DMBrowserAcceptance.axCollect(shot.host, [id])[id].map(DMBrowserAcceptance.axPress) ?? false }
        check(press("mcp-index-helper", indexShot), "E2 select helper index row")
        await W214Acceptance.settle(indexShot)
        check(press("mcp-import", indexShot), "E2 press actual import chip")
        try await until { notice.current != nil }
        check(notice.current?.detail.contains("會執行：" + helper) == true, "E2 import confirmation lists helper")
        check(registry.servers().isEmpty, "E2 before consent no engine receives helper")
        if let request = notice.current { notice.resolve(.cancel, id: request.id) }
        try? await Task.sleep(for: .milliseconds(80))
        check(registry.servers().isEmpty, "E2 cancel withholds helper")
        try registry.bringIn([item])
        let payload = PluginsSource.sidecarMCPConfig(engine: .claude, stored: [item.name], environment: env) ?? ""
        check(payload.contains(helper) && !payload.contains("unshown-fixture"), "E2 forwards displayed helper and excludes undisplayed execution fields")
        var opaque = definition; opaque["headersHelper"] = ["command": "unshown-fixture"]
        try publish(["helper": opaque]); try registry.bringIn([candidate("helper")])
        check(!(PluginsSource.sidecarMCPConfig(engine: .claude, stored: [item.name], environment: env) ?? "").contains("unshown-fixture"), "E2 unsupported helper cannot execute without display")
        try publish(["helper": definition]); try registry.bringIn([candidate("helper")])
        var masked = item; masked.headersHelper = "helper --token=" + ["sk", "w246-fake"].joined(separator: "-")
        check(masked.commandLine.contains("會執行：••••") && !masked.commandLine.contains("w246-fake") && masked.blocked, "E2 helper credentials masked and blocked")
        var keyword = item; keyword.headersHelper = "gcloud auth print-access-token"
        check(keyword.commandLine.contains("會執行：gcloud auth print-access-token") && !keyword.blocked, "lead: helper keywords alone stay visible and allowed")
        var bare = item; bare.headersHelper = "helper --token " + String(repeating: "q", count: 20)
        check(bare.blocked && bare.commandLine.contains("會執行：••••"), "lead: helper flag-separated credential is blocked")
        var quoted = item; quoted.headersHelper = "helper \"--token\" \"" + String(repeating: "q", count: 20) + "\""
        check(quoted.blocked, "lead: quoted helper flag credential is blocked")
        var accept = item; accept.headersHelper = "curl --header \"Accept: application/json\" https://example.com"
        check(!accept.blocked && accept.commandLine.contains("Accept: application/json"), "lead: non-credential header stays visible and allowed")
        var auth = item; auth.headersHelper = "curl --header \"Authorization: Bearer " + String(repeating: "z", count: 16) + "\""
        check(auth.blocked, "lead: authorization header value is blocked")
        var escapedQuote = item; escapedQuote.headersHelper = "curl --header \"X-Custom: \\\"" + ["sk", "w246-escaped"].joined(separator: "-") + "\\\"\""
        check(escapedQuote.blocked && !escapedQuote.commandLine.contains("w246-escaped"), "lead: escaped quote inside a header value does not hide a credential")
        var literalBackslash = item; literalBackslash.headersHelper = "curl --header \"X-Custom: s\\k-demo\""
        check(!literalBackslash.blocked, "lead: a backslash the shell keeps inside double quotes is not removed")
        var continued = item; continued.headersHelper = "curl --header \"X-Custom: s\\\nk-w246-cont\""
        var continuedBare = item; continuedBare.headersHelper = "helper s\\\nk-w246-cont"
        check(continued.blocked && continuedBare.blocked, "lead: backslash-newline continuation does not split a credential")
        var combining = item; combining.headersHelper = "helper \"x\"\u{301} --token " + String(repeating: "q", count: 20)
        var combiningEquals = item; combiningEquals.headersHelper = "helper --token=\u{301}" + String(repeating: "q", count: 20)
        check(combining.blocked && combiningEquals.blocked, "lead: a combining mark after a quote or equals sign does not hide a credential")
        var changed = definition; changed["headersHelper"] = "fixture-helper --mode changed"; changed["args"] = ["new"]
        changed["env"] = ["PATH": "/fixture/path"]
        try publish(["helper": changed])
        let saved = try registry.load()[0], reason = registry.changeNotice(saved) ?? ""
        check(reason.contains("來源設定變了：args、env.PATH、headersHelper") && !reason.contains("/fixture/path"), "E3 names changed fields without values")
        check(registry.servers().isEmpty, "E3 changed source withheld")
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light, cards = PluginsSource.osMCPEntries(environment: env)
            guard let shot = GlobalDMChatAcceptance.renderSync(page.mcpAcceptanceView(scan: nil, imported: cards, updates: [:], interactive: true).padding(24), size: CGSize(width: 1200, height: 720), scheme: scheme) else { throw TapError.notReady }
            await W214Acceptance.settle(shot)
            let text = W214Acceptance.text(shot)
            check(text.contains("來源設定變了：args、env.PATH、headersHelper") && !text.contains("這版改了同意方式"), "E3 real changes have card explanation without upgrade notice")
            check(!press("mcp-reimport-all", shot), "E3 changed source excluded from batch")
            GlobalDMChatAcceptance.save(shot, "w246-changed-\(dark ? "dark" : "light").png", to: artifacts)
            check(press("mcp-reimport-os-mcp:" + saved.id, shot), "E3 individual reimport chip")
            try await until { notice.current != nil }
            guard let request = notice.current else { throw TapError.notReady }
            check(request.detail.contains("會執行：fixture-helper --mode changed") && request.detail.contains("來源設定變了：args、env.PATH、headersHelper"), "E2/E3 renewal confirmation lists helper and changed fields")
            let alert = IslandNotice.fullTextAlert(request)
            alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            alert.layout()
            guard let view = alert.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TapError.notReady }
            view.wantsLayer = true
            alert.window.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            alert.window.displayIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("w246-confirm-\(dark ? "dark" : "light").png"))
            check(!dark || TatwoThemeSelfTestScope.hasReadableDarkPixels(bitmap), "E2 confirmation dark text readable")
            notice.resolve(.cancel, id: request.id)
            try? await Task.sleep(for: .milliseconds(80)); shot.close()
        }
        var misleading = changed; misleading["這版改了同意方式"] = "fixture"
        try publish(["helper": misleading])
        guard let misleadingShot = GlobalDMChatAcceptance.renderSync(page.mcpAcceptanceView(scan: nil, imported: PluginsSource.osMCPEntries(environment: env), updates: [:], interactive: true).padding(24), size: CGSize(width: 1200, height: 720)) else { throw TapError.notReady }
        await W214Acceptance.settle(misleadingShot)
        check(!press("mcp-reimport-all", misleadingShot), "E3 source field names cannot masquerade as legacy consent")
        misleadingShot.close(); try publish(["helper": changed])
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
        legacy[0]["consent"] = ["fingerprint": saved.consent!.fingerprint!]
        try JSONSerialization.data(withJSONObject: legacy).write(to: registry.url)
        check(registry.changeNotice(try registry.load()[0])?.contains("這版改了同意方式") == true && registry.servers().isEmpty, "E3 old fingerprint needs upgrade consent")
        try registry.bringIn([candidate("helper")])
        check(registry.failureReason(try registry.load()[0]) == nil, "E3 renewed source is available")
        let live = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: W185FakeConversationTap())
        defer { live.shutdownAll() }
        let project = live.newProject(name: "Fixture", workdir: work.path), parent = live.newThread(in: project)
        let files = try await Task.detached { try ChangeProposalStore.check(patch, cwd: work.path) }.value
        let proposal = ChangeProposalStore.Proposal(title: "測試", summary: "一行", projectID: project, cwd: work.path, files: files, digest: HandsAuth.sha256Hex(Data(patch.utf8)))
        for compress in [true, false] {
            let child = live.createDiscussion(parentThreadID: parent)!
            try live.groupBridge.proposals.save(proposal, patch: patch, thread: child, sequence: 1)
            let folder = live.groupBridge.proposals.root.appendingPathComponent("proposals/\(child)")
            let result = compress ? live.compressDiscussion(child) : live.mergeDiscussionIntoParent(child)
            check(result == parent && live.threadRecord(child)?.isArchived == true && !fm.fileExists(atPath: folder.path), "E4 both child archive routes remove proposal folder")
        }
        let script = root.appendingPathComponent("coder.mjs")
        try #"""
        import readline from 'node:readline';
        const emit=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line);
          if(c.op==='close')process.exit(0);
          if(c.op==='send') {
            emit({type:'system',subtype:'init',session_id:'w246-fixture',model:'gpt-6.1-sol'});
            emit({type:'system',subtype:'turn_accepted',client_turn_id:c.uuid});
          }
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous; overrides["tatwo2.sidecarPath.codex"] = script.path; overrides[GroupCoderBridge.flag] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        check(live.composerSend(threadID: parent, text: "@@ChatGPT fixture", model: "gpt-6.1-sol", engine: .codex), "E5 fake group created")
        try await until { live.groupBridge.sessions[parent] != nil }
        let group = live.groupBridge.sessions[parent]!
        _ = live.groupBridge.stop(parent); live.stop(threadID: parent)
        try await until { !live.isRunning(parent) }
        let sequence = group.record(speaker: "ChatGPT", text: proposal.eventText, kind: "proposal")
        let store = live.groupBridge.proposals
        try store.save(proposal, patch: patch, thread: parent, sequence: sequence)
        let patchFile = store.root.appendingPathComponent("proposals/\(parent)/\(sequence).patch")
        try fm.setAttributes([.immutable: true], ofItemAtPath: patchFile.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: patchFile.path) }
        try await live.groupBridge.applyProposal(parent, sequence: sequence, confirmed: true)
        let applied = store.proposal(parent, sequence)!, event = group.events.first { $0.sequence == sequence }!
        check(try fm.fileExists(atPath: patchFile.path) && applied.applied == true && event.kind == "proposal-applied" && String(contentsOf: file, encoding: .utf8) == "after\n", "E5 deletion failure keeps successful apply state")
        let card = ChangeProposalCard(proposal: applied, event: event, primary: "Codex", viewPatch: { "" }, review: { false }, apply: {}, reject: {})
        guard let cardShot = GlobalDMChatAcceptance.renderSync(card.padding(24), size: CGSize(width: 820, height: 380)) else { throw TapError.notReady }
        check(W214Acceptance.text(cardShot).contains("已套用") && W214Acceptance.text(cardShot).contains("補丁未能刪除，請稍後清理。") && !press("proposal-apply", cardShot), "E5 card says applied with one cleanup prompt and no apply button")
        cardShot.close()
        do { try await live.groupBridge.applyProposal(parent, sequence: sequence, confirmed: true); check(false, "E5 bridge refuses second apply") }
        catch { check(true, "E5 bridge refuses second apply") }
        try await Task.detached { try store.apply(parent, sequence) }.value
        check(try String(contentsOf: file, encoding: .utf8) == "after\n", "E5 durable marker prevents reapplication")
        let planThread = live.newThread(in: project), plan = TatwoPlanArtifactV1(threadID: planThread, objective: "保留原計畫")
        try live.savePlanArtifact(plan)
        live.commandSelfTestSetRunning(planThread, true)
        let external = "```tatwo-plan\n## 目標\nChatGPT 的計畫\n## 範圍\n外部內容\n```"
        check(TatwoPlanArtifactV1.parseSections(fromReply: external) != nil, "E6 external fixture would update an eligible plan")
        live.groupWrite(planThread, .init(sequence: 1, turn: 1, speaker: "ChatGPT", text: external, kind: "message"), status: "done", source: .system)
        live.handleSDK(planThread, ["type": "result", "subtype": "success", "is_error": false])
        let retained = try live.loadPlanArtifact(planThread)!
        check(retained.sourceAssistantMessageID == nil && retained.sections == plan.sections && retained.objective == plan.objective, "E6 only TAP reply leaves plan unchanged")
        let fake = ["ghp", "W246_FAKE"].joined(separator: "_"), atSign = String(UnicodeScalar(64)!)
        let cases: [[Any]]
        if let path = env["W246_URL_CASES"] {
            guard NativeStagingIsolation.allowsRead(URL(fileURLWithPath: path), within: URL(fileURLWithPath: staging)) else { throw TapError.notReady }
            cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[Any]]
        } else {
            cases = [["https://fixture.invalid/mcp%2Fapi_key=\(fake)", true], ["https://fixture.invalid/mcp?x=a%26token=\(fake)", true], ["https://[broken", true], ["not a URL", true], ["https://person%2Fnote\(atSign)fixture.invalid/mcp", true], ["https://fixture.invalid/mcp?mode=read", false]]
        }
        for row in cases {
            let url = row[0] as! String, expected = row[1] as! Bool
            check(OSMCPRegistry.Item.hasSecret(url, urlOnly: true) == expected, "E7 shared URL corpus")
            var remote = item; remote.remoteURL = url
            check(remote.blocked == expected && (expected ? remote.commandLine.hasPrefix("••••") : remote.commandLine.hasPrefix(url)), "E7 remote URL masked and blocked consistently")
        }
        check(OSMCPRegistry.Item.hasSecret(fake + "%GG") && !OSMCPRegistry.Item.hasSecret("100%"), "E7 decoding failure preserves existing argument credential checks")
        let midToken = "helper " + "gh" + "p_" + String(repeating: "x", count: 24)
        check(OSMCPRegistry.Item.hasSecret(midToken) && !OSMCPRegistry.Item.hasSecret("helper --mask-thing"), "lead: credential in the middle of a helper command is detected")
        print("W246 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
