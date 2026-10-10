#if DEBUG
import AppKit
import SwiftUI
import Translation

/// W291: real human CEF transport, isolated W258 app/profile and loopback fixture. No language downloads.
@MainActor enum W291TranslationAcceptance {
    static func run(store: BrowserWorkSpaceStore, runtime: BrowserWorkSpaceRuntime, browser: TatwoCEFBrowserView,
                    rig: TatwoComposerModeAcceptance.ClickRig, origin: String, folder: URL) async throws -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        var arguments = previous
        arguments["AppleLanguages"] = ["zh-Hant"]; arguments[BrowserPageTranslator.autoKey] = false
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let translator = BrowserPageTranslator(), tab = store.selectedRegistryID!
        var passed = 0
        func check(_ ok: Bool, _ label: String) throws {
            print("W291CEF \(ok ? "PASS" : "FAIL") \(label)")
            guard ok else { throw TapError.remote(label) }; passed += 1
        }
        func text() async throws -> String {
            let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
            return BrowserAgentBridge.readSnapshot(snapshot, url: browser.currentURLString ?? "", maxChars: 60000)["text"] as? String ?? ""
        }
        func navigate(_ path: String) async throws {
            let url = origin + path
            translator.pageChanged(runtime: runtime, tabID: tab, url: url, isLoading: true)
            browser.loadURLString(url)
            try check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == url && !runtime.navigationState.isLoading }, "load local long page \(path)")
            translator.pageChanged(runtime: runtime, tabID: tab, url: url, isLoading: false)
            try check(await BrowserRuntimeAcceptance.waitUntil { if case .offer = translator.phase { return true }; return false }, "offer English source \(path)")
        }
        func translate() async throws -> Task<Void, Never> {
            translator.startManually()
            var batches = 0
            let task = Task {
                await translator.run(prepare: {}, translate: { items in
                    batches += 1
                    return items.map { [$0[0], "中文譯文：圖書館每天早晨開放。讀者可以借書，並在安靜的地方閱讀與學習。"] as [Any] }
                })
            }
            var complete = false
            for _ in 0..<200 {
                let body = try await text()
                if batches >= 3, body.contains("中文譯文"), !body.contains("Article ") { complete = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(complete, "all long-page batches translated by fixture provider")
            return task
        }
        func shot(_ filename: String) async throws {
            await rig.settle()
            guard let cached = rig.capture(), let captured = GlobalDMChatAcceptance.captureOwnWindow(cached),
                  let png = captured.bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("CEF screenshot missing") }
            try png.write(to: folder.appendingPathComponent(filename))
        }
        try await navigate("/w291/long")
        rig.window.appearance = NSAppearance(named: .aqua)
        try await shot("before.png")
        for round in 1...3 {
            let task = try await translate()
            if round <= 2 { try await shot(round == 1 ? "first.png" : "second.png") }
            try check(translator.phase == .translated(source: "en"), "repeat \(round) settles state")
            task.cancel(); await task.value
        }
        for round in 1...3 {
            translator.restore()
            var original = false
            for _ in 0..<100 {
                if try await text().contains("Article 1:"), !(try await text().contains("中文譯文")) { original = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(original, "restore original \(round)")
            let task = try await translate(); task.cancel(); await task.value
        }
        try await navigate("/w291/next")
        let task = try await translate(); task.cancel(); await task.value
        let source = Locale.Language(identifier: "en"), target = BrowserPageTranslator.targetLanguage
        if #available(macOS 26.0, *), await LanguageAvailability().status(from: source, to: target) == .installed {
            let session = TranslationSession(installedSource: source, target: target)
            let result = try await session.translate("The library opens every morning.")
            try check(!result.targetText.isEmpty && result.targetText != result.sourceText, "installed Apple language smoke")
        } else { print("W291CEF SKIP installed Apple language smoke: language pack unavailable; no download") }
        translator.restore()
        print("W291CEF SUMMARY \(passed) pass 0 fail")
        return true
    }
}
#endif
