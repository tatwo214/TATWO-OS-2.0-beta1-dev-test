#if DEBUG
import AppKit
import Foundation
import Combine
import SwiftUI

@MainActor enum W258DownloadAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              TatwoCEFRuntime.compiled, let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"],
              let scratch = env["TMPDIR"], let home = env["HOME"], home == env["CFFIXED_USER_HOME"] else {
            throw TapError.remote("isolated real CEF environment required")
        }
        let folder = URL(fileURLWithPath: artifacts)
        if Bundle.main.bundleIdentifier == nil {
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let receipt = folder.appendingPathComponent("cef-app.json")
            let stage = Process()
            stage.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            stage.arguments = ["node", checkout.appendingPathComponent("tests/fixtures/w258-stage.mjs").path]
            stage.currentDirectoryURL = checkout
            var stageEnv = env
            stageEnv["TATWO2_TEST_BINARY"] = Bundle.main.executableURL!.path
            stageEnv["TATWO2_W258_CEF_RECEIPT"] = receipt.path
            stage.environment = stageEnv
            try stage.run()
            guard await BrowserRuntimeAcceptance.waitUntil({ !stage.isRunning }), stage.terminationStatus == 0,
                  let item = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: String],
                  let binary = item["binary"], let appRoot = item["scratch"],
                  appRoot.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path + "/"),
                  binary.hasPrefix(appRoot + "/W258.app/") else { throw TapError.remote("CEF staging failed") }
            if env["TATWO2_SELFTEST"] == "w270dlfly" {
                let prototype = checkout.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("briefs/W270-prototype.html")
                try Data(contentsOf: prototype).write(to: folder.appendingPathComponent("prototype.html"))
            }
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = [checkout.appendingPathComponent("tests/fixtures/w258-server.py").path, folder.path]
            try server.run()
            defer { if server.isRunning { server.terminate() } }
            let portFile = folder.appendingPathComponent("port")
            guard await BrowserRuntimeAcceptance.waitUntil({ FileManager.default.fileExists(atPath: portFile.path) }) else {
                throw TapError.remote("local server failed")
            }
            let port = try String(contentsOf: portFile).trimmingCharacters(in: .whitespacesAndNewlines)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: binary)
            child.arguments = ["--use-mock-keychain"]
            var isolated = env
            isolated.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
            isolated["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] = "1"
            isolated["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = port
            if env["TATWO2_SELFTEST"] == "w270dlfly" { isolated["TATWO2_SELFTEST"] = "w258download"; isolated["TATWO_W270_DLFLY"] = "1" }
            child.environment = isolated
            return try await withCheckedThrowingContinuation { continuation in
                child.terminationHandler = { process in
                    if env["TATWO2_SELFTEST"] == "w270dlfly" { print("W270 CHILD exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)") }
                    continuation.resume(returning: process.terminationStatus == 0)
                }
                do { try child.run() } catch { continuation.resume(throwing: error) }
            }
        }
        guard Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2.staging.w258", NSApp is TatwoCEFApplication,
              CommandLine.arguments.contains("--use-mock-keychain"),
              let port = env["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] else { throw TapError.remote("fixture app required") }
        let downloads = URL(fileURLWithPath: home).appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        guard FileManager.default.homeDirectoryForCurrentUser.path == home,
              NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first == downloads.path else {
            throw TapError.remote("Downloads escaped isolated HOME")
        }
        var passed = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            print("W258 \(value ? "PASS" : "FAIL") \(label)")
            if value { passed += 1 } else { failures += 1 }
        }
        let registry = BrowserTabRegistry.shared
        let store = BrowserWorkSpaceStore(registry: registry)
        let runtime = BrowserWorkSpaceRuntime.shared
        let origin = "http://127.0.0.1:\(port)"
        print("W258 HOST engine=\(EmbeddedBrowserEnginePolicy.current) fixture=\(EmbeddedBrowserEnginePolicy.isDownloadFixture(Bundle.main.bundleIdentifier))")
        guard let rootCache = TatwoCEFProfileLocationResolver.rootCacheURL() else { throw TapError.remote("fixture cache root unavailable") }
        try FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootCache.deletingLastPathComponent().appendingPathComponent("cef-logs"), withIntermediateDirectories: true)
        await runtime.authorize()
        print("W258 HOST access=\(runtime.access)")
        store.addTab(url: URL(string: origin + "/page/A")!)
        let openerID = store.selectedRegistryID!
        let feedbackScene = W268DownloadAcceptance.SceneState()
        let rig = TatwoComposerModeAcceptance.ClickRig(
            W268DownloadAcceptance.Scene(store: store, runtime: runtime, state: feedbackScene), size: CGSize(width: 1100, height: 740))
        defer { rig.close() }
        check(rig.moveOnScreen(), "Browser space window on screen")
        await rig.settle()
        func visibleBrowser(_ view: NSView) -> TatwoCEFBrowserView? {
            if let browser = view as? TatwoCEFBrowserView, !browser.isHiddenOrHasHiddenAncestor { return browser }
            return view.subviews.lazy.compactMap { visibleBrowser($0) }.first
        }
        func pageReady(_ path: String) async -> TatwoCEFBrowserView? {
            _ = await BrowserRuntimeAcceptance.waitUntil {
                visibleBrowser(rig.host)?.currentURLString == origin + path && !runtime.navigationState.isLoading
            }
            return visibleBrowser(rig.host)
        }
        guard let browser = await pageReady("/page/A") else {
            print("W258 HOST selected=\(store.selectedTab.url) start=\(store.showsStartPage) error=\(runtime.error ?? "none") access=\(runtime.access)")
            if let shot = rig.capture(), let png = shot.bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("startup.png"))
            }
            throw TapError.remote("Browser space never mounted CEF")
        }
        if env["TATWO_W291_TRANSLATE"] == "1" { return try await W291TranslationAcceptance.run(store: store, runtime: runtime, browser: browser, rig: rig, origin: origin, folder: folder) }
        if env["TATWO_W270_DLFLY"] == "1" { return try await W270DownloadAcceptance.run(store: store, runtime: runtime, browser: browser, rig: rig, scene: feedbackScene, origin: origin, folder: folder) }
        check(browser.browserActor == .human && !browser.agentControlled, "real human tab in Browser space")
        // Explicit consent for the second local host; retain all production policy checks.
        browser.onPrivateNetworkRequested = { host, reply in reply(host == "localhost") }
        var events: [[String: Any]] = []
        var lastStates: [String: BrowserDownloadStore.State] = [:]
        let observation = BrowserDownloadStore.shared.$downloads.sink { items in
            for item in items where lastStates[item.id] != item.state {
                lastStates[item.id] = item.state
                events.append(["filename": item.filename, "state": item.state.rawValue])
                print("W258 EVENT \(item.state.rawValue) \(item.filename)")
            }
        }
        defer { observation.cancel() }
        func click(_ view: TatwoCEFBrowserView, label: String) async throws -> Bool {
            let snapshot = try await BrowserRuntimeAcceptance.snapshot(view)
            guard let element = BrowserAgentBridge.uniqueElement(BrowserAgentBridge.clickElements(snapshot), selector: nil, label: label),
                  let rect = element["rect"] as? [String: Any], let viewport = snapshot["viewport"] as? [String: Any],
                  let point = BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: view.bounds.size) else {
                throw TapError.remote("fixture click target missing: " + label)
            }
            return view.sendClick(at: point, navigationGeneration: view.navigationGeneration)
        }
        if env["TATWO_W282_TERMINATION_ONLY"] == "1" {
            return try await W282DownloadAcceptance.termination(browser: browser, rig: rig, runtime: runtime, origin: origin)
        }
        if env["TATWO_W281F_RED_ONLY"] != "1" {
            check(try await W281DownloadAcceptance.unsupportedExtension(browser: browser, rig: rig, runtime: runtime, origin: origin, folder: folder), "W281f impossible extension rejects empty paths")
        }
        check(try await W281DownloadAcceptance.longNames(browser: browser, rig: rig, runtime: runtime, origin: origin, folder: folder), "W281f long filenames")
        if env["TATWO_W281F_RED_ONLY"] == "1" { return failures == 0 }
        for name in ["A", "B", "C", "D", "E"] {
            print("W258 CASE \(name)")
            store.select(registryID: openerID)
            _ = await BrowserRuntimeAcceptance.waitUntil { visibleBrowser(rig.host) === browser }
            browser.loadURLString(origin + "/page/" + name)
            check(await BrowserRuntimeAcceptance.waitUntil {
                browser.currentURLString == origin + "/page/" + name && !runtime.navigationState.isLoading
            }, name + " page ready")
            await rig.settle()
            let start = events.count
            check(try await click(browser, label: "Download " + name), name + " native click accepted")
            let completed = await BrowserRuntimeAcceptance.waitUntil {
                BrowserDownloadStore.shared.downloads.contains { $0.filename == name + ".bin" && $0.done }
            }
            let states = events.dropFirst(start).filter { $0["filename"] as? String == name + ".bin" }
                .compactMap { $0["state"] as? String }
            check(completed && states.contains("starting") && states.contains("completed"), name + " starting to completed")
            let file = downloads.appendingPathComponent(name + ".bin")
            check((try? Data(contentsOf: file)) == Data(String(repeating: "W258 fixture " + name + "\n", count: 4096).utf8),
                  name + " correct filename and bytes in isolated Downloads")
            print("W258 RESULT \(name) completed=\(completed) states=\(states)")
        }
        check(try await W281DownloadAcceptance.collisions(browser: browser, rig: rig, runtime: runtime, origin: origin, folder: folder), "W281b numbered collision names")
        if env["TATWO_W281B_RED_ONLY"] == "1" { return failures == 0 }
        check(try await W282DownloadAcceptance.run(browser: browser, rig: rig, runtime: runtime, origin: origin, folder: folder), "W282 Finder file progress")
        check(try await W268DownloadAcceptance.run(store: store, runtime: runtime, browser: browser, rig: rig, scene: feedbackScene, origin: origin, folder: folder), "W268 visible download feedback")
        if env["TATWO2_W258_REAL_SITE"] == "1", failures == 0 {
            let marker = URL(fileURLWithPath: scratch).appendingPathComponent("notchy-attempted")
            guard !FileManager.default.fileExists(atPath: marker.path) else { throw TapError.remote("D4 already attempted") }
            try Data("one public CEF attempt\n".utf8).write(to: marker, options: .withoutOverwriting)
            print("W258 D4 begin")
            browser.loadURLString("https://notchy.dev/download/")
            let ready = await BrowserRuntimeAcceptance.waitUntil {
                browser.currentURLString == "https://notchy.dev/download/" && !runtime.navigationState.isLoading
            }
            if ready {
                await rig.settle()
                let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
                let links = BrowserAgentBridge.clickElements(snapshot)
                if let element = links.first(where: { ($0["destinationOrigin"] as? String) == "https://notchy.dev" && ($0["destinationPath"] as? String) == "/Notchy.dmg" }),
                   let rect = element["rect"] as? [String: Any], let viewport = snapshot["viewport"] as? [String: Any],
                   let point = BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: browser.bounds.size) {
                    let baselineIDs = Set(BrowserDownloadStore.shared.downloads.map(\.id))
                    print("W258 D4 click=\(browser.sendClick(at: point, navigationGeneration: browser.navigationGeneration))")
                    var started: BrowserDownloadStore.Item?
                    let writing = await BrowserRuntimeAcceptance.waitUntil {
                        started = BrowserDownloadStore.shared.downloads.first { !baselineIDs.contains($0.id) }
                        return (started?.received ?? 0) > 0
                    }
                    if let item = started {
                        print("W258 D4 writing=\(writing) bytes=\(item.received) cancel=\(browser.cancelDownload(item.id))")
                        _ = await BrowserRuntimeAcceptance.waitUntil {
                            BrowserDownloadStore.shared.downloads.first { $0.id == item.id }?.state.isTerminal == true
                        }
                        guard item.fileURL.deletingLastPathComponent().standardizedFileURL.path == downloads.standardizedFileURL.path else {
                            throw TapError.remote("D4 file escaped isolated Downloads")
                        }
                        if FileManager.default.fileExists(atPath: item.fileURL.path) { try FileManager.default.removeItem(at: item.fileURL) }
                        let partial = item.fileURL.appendingPathExtension("crdownload")
                        if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
                        print("W258 D4 cancelled and scratch file removed")
                    } else { print("W258 D4 no file write; phase=\(runtime.navigationState.phase) error=\(runtime.navigationState.structuredError?.code ?? 0)") }
                } else { print("W258 D4 download link unavailable; no click") }
            } else { print("W258 D4 public page unavailable; no click") }
        }
        // Use a fresh ephemeral agent context; neither human cookies nor download permission is inherited.
        let agent = try TatwoCEFBrowserView(frame: browser.frame, persistentProfile: nil, initialURL: origin + "/page/agent", actor: .agent)
        browser.superview!.addSubview(agent)
        var blocked = false, agentEvents = 0
        agent.stateHandler = { _, _, _, _, _, phase, _, _, _, _ in if phase == .blockedBySecurity { blocked = true } }
        agent.onDownloadEvent = { _ in agentEvents += 1 }
        defer { agent.closeBrowser(); agent.removeFromSuperview() }
        check(await BrowserRuntimeAcceptance.waitUntil { agent.currentURLString == origin + "/page/agent" && agent.navigationGeneration > 0 }, "agent local page ready")
        await rig.settle()
        check(try await click(agent, label: "Download agent"), "agent native click dispatched")
        check(await BrowserRuntimeAcceptance.waitUntil { blocked }, "agent attachment blocked by CEF")
        check(agentEvents == 0 && !FileManager.default.fileExists(atPath: downloads.appendingPathComponent("agent.bin").path), "agent emitted no download or file")
        await rig.settle()
        if let cached = rig.capture(), let shot = GlobalDMChatAcceptance.captureOwnWindow(cached),
           let png = shot.bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent("browser-space.png"))
        }
        await agent.closeBrowser(); agent.removeFromSuperview()
        if env["TATWO_W281_LEGACY_ACCEPTANCE"] == "1" { print("W281 SKIP staged races/PDF in forced legacy run; exercised in the main run") }
        else { check(try await W281DownloadAcceptance.run(browser: browser, rig: rig, runtime: runtime, origin: origin, folder: folder), "W281 staged download races") }
        print("W258 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
