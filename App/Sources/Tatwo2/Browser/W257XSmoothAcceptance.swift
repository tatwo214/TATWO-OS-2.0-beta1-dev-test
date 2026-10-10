#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor enum W257XSmoothAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let artifacts = env["TATWO2_SELFTEST_ARTIFACTS"], let scratch = env["TMPDIR"],
              TatwoCEFRuntime.compiled else { throw TapError.remote("isolated real CEF fixture required") }
        let folder = URL(fileURLWithPath: artifacts)
        if Bundle.main.bundleIdentifier == nil {
            guard let receipt = env["TATWO2_W257_CEF_RECEIPT"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: receipt)),
                  let item = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let binary = item["binary"], let root = item["scratch"],
                  root.hasPrefix(URL(fileURLWithPath: scratch).standardizedFileURL.path + "/"),
                  binary.hasPrefix(root + "/W257.app/") else { throw TapError.remote("scratch CEF App receipt required") }
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = [root + "/W257.app/Contents/Resources/w257-timeline.py", artifacts]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.standardError
            try server.run()
            defer { if server.isRunning { server.terminate() } }
            let portFile = folder.appendingPathComponent("port")
            guard await BrowserRuntimeAcceptance.waitUntil({ FileManager.default.fileExists(atPath: portFile.path) }) else {
                throw TapError.remote("loopback server failed")
            }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            var childEnv = env
            childEnv.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
            childEnv["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] = "1"
            childEnv["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = port
            for run in 1...3 {
                childEnv["TATWO2_W257_RUN"] = String(run)
                let child = Process()
                child.executableURL = URL(fileURLWithPath: binary)
                child.arguments = ["--use-mock-keychain"]
                child.environment = childEnv
                child.standardOutput = FileHandle.standardOutput
                child.standardError = FileHandle.standardError
                let ok: Bool = try await withCheckedThrowingContinuation { continuation in
                    child.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
                    do { try child.run() } catch { continuation.resume(throwing: error) }
                }
                guard ok else { return false }
            }
            let samples = try (1...3).map { run in
                try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run-\(run).json"))) as! [String: Any]
            }
            var medians: [String: Double] = [:]
            for key in ["p50", "p95", "longFrames", "longtaskMs"] {
                medians[key] = samples.map { ($0[key] as! NSNumber).doubleValue }.sorted()[1]
            }
            try JSONSerialization.data(withJSONObject: medians, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("median.json"))
            print("W257 MEDIAN \(medians)")
            print("W257 SUMMARY failures=0 three fresh processes, 1000x700, local images, 10 seconds")
            return true
        }
        guard Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2.staging.w257", NSApp is TatwoCEFApplication,
              let port = env["TATWO_STAGING_BROWSER_LOOPBACK_PORT"],
              CommandLine.arguments.contains("--use-mock-keychain"),
              let helper = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) else {
            throw TapError.remote("fixture application and mock keychain required")
        }
        func check(_ ok: Bool, _ label: String) throws {
            print("W257 \(ok ? "PASS" : "FAIL") \(label)")
            guard ok else { throw TapError.remote(label) }
        }
        let run = env["TATWO2_W257_RUN"] ?? "1"
        let cache = folder.appendingPathComponent("cache-\(run)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try TatwoCEFRuntime.initialize(withRootCachePath: cache.path, helperExecutablePath: helper.path,
            logFilePath: folder.appendingPathComponent("cef-\(run).log").path,
            bundledDenyListPath: BrowserBundledHostDenyList.verifiedResourceURL().path)
        let view = try TatwoCEFBrowserView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700),
            persistentProfile: nil, initialURL: "http://127.0.0.1:\(port)/timeline")
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { view.closeBrowser(); window.close() }
        let resultFile = folder.appendingPathComponent("result.json")
        // Results are archived instead of deleted; each process has a fresh cache.
        if FileManager.default.fileExists(atPath: resultFile.path) {
            try FileManager.default.moveItem(at: resultFile, to: folder.appendingPathComponent("previous-\(run).json"))
        }
        try check(await BrowserRuntimeAcceptance.waitUntil { FileManager.default.fileExists(atPath: resultFile.path) }, "10-second page sample received")
        let data = try Data(contentsOf: resultFile)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check((result["cards"] as! Int) >= 600 && (result["scrollY"] as! Double) >= 180000,
                  "600+ cards loaded in batches of 20 and scrolled")
        try check(result["longtaskSupported"] as? Bool == true && (result["width"] as! Int) == 1000
                  && (result["height"] as! Int) == 700, "longtask observer and fixed viewport")
        try data.write(to: folder.appendingPathComponent("run-\(run).json"))
        print("W257 SAMPLE run=\(run) p50=\(result["p50"]!) p95=\(result["p95"]!) longFrames=\(result["longFrames"]!) longtaskMs=\(result["longtaskMs"]!) cards=\(result["cards"]!)")
        func strings(_ node: NSObject, depth: Int = 0) -> [String] {
            guard depth < 40 else { return [] }
            func attribute(_ modern: String, _ legacy: String) -> Any? {
                let selector = NSSelectorFromString(modern)
                if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue(),
                   (value as? [Any])?.isEmpty != true { return value }
                let getter = NSSelectorFromString("accessibilityAttributeValue:")
                return node.responds(to: getter) ? node.perform(getter, with: legacy)?.takeUnretainedValue() : nil
            }
            var text: [String] = []
            for (modern, legacy) in [("accessibilityLabel", "AXDescription"), ("accessibilityTitle", "AXTitle"),
                                     ("accessibilityValue", "AXValue"), ("accessibilityRole", "AXRole")] {
                if let value = attribute(modern, legacy) as? String { text.append(value) }
            }
            var children = attribute("accessibilityChildren", "AXChildren") as? [NSObject] ?? []
            if children.isEmpty { children = (node as? NSView)?.subviews ?? [] }
            for child in children { text += strings(child, depth: depth + 1) }
            return text
        }
        let before = strings(view).contains { $0.contains("W257 AX requested content") }
        print("W257 AX beforeManual=\(before) voiceOver=\(NSWorkspace.shared.isVoiceOverEnabled) diagnostics=\(BrowserAccessibilityTreeState.stateText)")
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        print("W257 AX immediate request state=\(BrowserAccessibilityTreeState.stateText)")
        let readable = await BrowserRuntimeAcceptance.waitUntil {
            strings(view).contains { $0.contains("W257 AX requested content") }
        }
        print("W257 AX afterManual=\(readable) diagnostics=\(BrowserAccessibilityTreeState.stateText)")
        try JSONSerialization.data(withJSONObject: strings(view)).write(to: folder.appendingPathComponent("ax-\(run).json"))
        if env["TATWO2_W257_BASELINE"] != "1" {
            try check(!before && !NSWorkspace.shared.isVoiceOverEnabled, "default does not expose web AX content")
            try check(readable && strings(view).contains("AXButton"), "AXManualAccessibility exposes real web node text and AXButton")
            try check(BrowserAccessibilityTreeState.stateText.contains("開（原因：輔助工具"), "diagnostics reports native request reason")
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXManualAccessibility"))
            try check(await BrowserRuntimeAcceptance.waitUntil {
                !strings(view).contains { $0.contains("W257 AX requested content") }
            }, "releasing manual request closes tree")
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            try check(await BrowserRuntimeAcceptance.waitUntil {
                strings(view).contains { $0.contains("W257 AX requested content") }
            }, "AXEnhancedUserInterface uses the same demand path")
            view.isHidden = true
            try await Task.sleep(for: .milliseconds(150))
            view.isHidden = false
            try check(await BrowserRuntimeAcceptance.waitUntil {
                strings(view).contains { $0.contains("W257 AX requested content") }
            }, "requested tree survives hiding and revealing native tab")
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXManualAccessibility"))
            view.loadURLString("http://127.0.0.1:\(port)/cuax")
            try await Task.sleep(for: .milliseconds(500))
            setenv("TATWO2_CU_AX_SECONDS", "2", 1)
            defer { unsetenv("TATWO2_CU_AX_SECONDS") }
            func observe(_ tree: Bool = true) throws -> ComputerUseNative.State {
                try ComputerUseNative.readState(.current, deadline: ProcessInfo.processInfo.systemUptime + 8,
                    includeTree: tree)
            }
            func webContent() -> Bool { strings(view).contains { $0.contains("W257 AX requested content") } }
            func enhanced() -> Bool { NSApp.accessibilityAttributeValue(.init(rawValue: "AXEnhancedUserInterface")) as? Bool == true }
            func screenshot(_ name: String) async throws {
                let host = NSHostingView(rootView: BrowserDiagnosticsView())
                let diagnostics = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 760),
                    styleMask: [.titled], backing: .buffered, defer: false)
                diagnostics.isReleasedWhenClosed = false
                diagnostics.contentView = host
                diagnostics.orderFrontRegardless()
                defer { diagnostics.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TapError.remote("diagnostics screenshot unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("diagnostics PNG unavailable") }
                try png.write(to: folder.appendingPathComponent("cuax-\(name)-\(run).png"))
            }
            try check(!enhanced() && !webContent(), "CU lease starts with no native demand or web nodes")
            _ = try observe(false)
            try check(!enhanced(), "image-only CU read does not request a tree")
            _ = try observe()
            try check(BrowserAccessibilityTreeState.stateText.contains("無障礙樹：開"), "CU_READ_ON diagnostics opens on self read")
            try check(await BrowserRuntimeAcceptance.waitUntil { webContent() }, "CU web content arrives asynchronously")
            let second = try observe()
            try check(webContent() && strings(view).contains("AXButton"), "CU_READ_ON second read exposes real web node and AXButton via W257 native AX traversal")
            if AXIsProcessTrusted() {
                try check(second.nodes.contains { $0.title.contains("W257 AX requested content") }, "CU second observation returns web node")
            } else {
                print("W257 SKIP CU second observation node list: fixture has no AX permission; native CEF subtree verified directly")
            }
            try await screenshot("on")
            let renewedFrom = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(1100))
            _ = try observe()
            try await Task.sleep(for: .milliseconds(1100))
            try check(ProcessInfo.processInfo.systemUptime > renewedFrom + 2 && enhanced()
                      && webContent() && BrowserAccessibilityTreeState.stateText.contains("無障礙樹：開"),
                      "CU_RENEW stays open beyond original deadline")
            try await Task.sleep(for: .milliseconds(1100))
            try check(await BrowserRuntimeAcceptance.waitUntil { !webContent() }, "CU_EXPIRE actual web subtree disappears")
            try check(!enhanced() && BrowserAccessibilityTreeState.stateText.contains("無障礙樹：關"),
                      "CU_EXPIRE diagnostics off and AXEnhancedUserInterface false")
            try await screenshot("off")
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
            _ = try observe()
            try await Task.sleep(for: .milliseconds(2300))
            try check(enhanced() && webContent() && BrowserAccessibilityTreeState.stateText.contains("無障礙樹：開"),
                      "CU_PREEXISTING preserves another accessibility client's request after expiry")
            NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXManualAccessibility"))
        }
        return true
    }
}
#endif
