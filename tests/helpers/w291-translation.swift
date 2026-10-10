import AppKit
import WebKit
import SwiftUI
import Translation

// Only this disposable harness substitutes the Browser transport. The controller and translator are production source.
@MainActor final class BrowserWorkSpaceRuntime: ObservableObject {
    let web: WKWebView
    var navigationTabID: UUID?
    struct Navigation { var urlString: String?; var isLoading = false }
    var navigationState = Navigation()
    var holdRestore = false, heldRestores: [CheckedContinuation<Void, Never>] = []
    var heldRestore: CheckedContinuation<Void, Never>? { heldRestores.first }
    func releaseRestores() { holdRestore = false; let values = heldRestores; heldRestores = []; values.forEach { $0.resume() } }
    var holdSample = false, heldSample: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    init() { let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); web = WKWebView(frame: NSRect(x: 0,y: 0,width: 1050,height: 720), configuration: config) }
    func js(_ script: String) async throws -> Any? { try await web.evaluateJavaScript(script) }
    func translate(tabID: UUID, operation: String, payload: String? = nil, limit: Int = 0) async -> String? {
        calls.append(operation)
        if operation == "restore", holdRestore { await withCheckedContinuation { heldRestores.append($0) } }
        if operation == "sample", holdSample { await withCheckedContinuation { heldSample = $0 } }
        let arg: String
        if operation == "apply" { arg = String(data: try! JSONSerialization.data(withJSONObject: payload!, options: .fragmentsAllowed), encoding: .utf8)! }
        else { arg = operation == "collect" ? String(limit) : "" }
        return try? await js("fixtureController.\(operation)(\(arg))") as? String
    }
    func load(_ url: URL, script: String) async throws {
        web.load(URLRequest(url: url))
        try await wait { !self.web.isLoading && self.web.url == url }
        _ = try await js("window.fixtureController = (\(script))()")
    }
}
enum FixtureError: Error { case timeout, provider }
@MainActor func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<600 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
    throw FixtureError.timeout
}
@MainActor final class FakeProvider {
    struct Response { var clientIdentifier: String?; var targetText: String }
    var batches = 0, hold = false, entered = false, released: CheckedContinuation<Void, Never>?
    var throwNext = false, prefix = "中文譯文"
    func prepareTranslation() async throws {}
    func translations(from requests: [TranslationSession.Request]) async throws -> [Response] {
        batches += 1; entered = true
        if hold { await withCheckedContinuation { released = $0 } }
        if throwNext { throwNext = false; throw FixtureError.provider }
        return requests.map { Response(clientIdentifier: $0.clientIdentifier, targetText: "\(prefix)：圖書館每天早晨開放。讀者可以借書，並在安靜的地方閱讀與學習。") }
    }
}
@main struct W291Fixture {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["zh-Hant"], BrowserPageTranslator.autoKey: false], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do { try await run(); exit(0) } catch { print("W291 FAIL \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        let origin = args[1], script = try String(contentsOfFile: args[2]), shots = args[3], baseline = args[4] == "baseline"
        let runtime = BrowserWorkSpaceRuntime(), translator = BrowserPageTranslator(), provider = FakeProvider()
        let tab = UUID()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1050,height:720), styleMask:[.titled], backing:.buffered, defer:false)
        window.appearance = NSAppearance(named:.aqua); window.contentView = runtime.web; window.orderFront(nil)
        var passed = 0
        func check(_ result: Bool, _ label: String) throws {
            print("W291 \(result ? "PASS" : "FAIL") \(label)"); if !result { throw FixtureError.provider }; passed += 1
        }
        func page(_ path: String, id: UUID? = nil) async throws {
            translator.pageChanged(runtime:runtime, tabID:id ?? tab, url:origin+path, isLoading:true)
            try await runtime.load(URL(string:origin+path)!, script:script)
            translator.pageChanged(runtime:runtime, tabID:id ?? tab, url:origin+path, isLoading:false)
            try await wait { if case .offer = translator.phase { return true }; return false }
        }
        func translated() async throws -> Bool {
            let json = try await runtime.js("JSON.stringify([...document.querySelectorAll('#article p')].map(p=>p.textContent))") as! String
            let texts = try JSONSerialization.jsonObject(with:Data(json.utf8)) as! [String]
            return texts.count >= 260 && texts.allSatisfy { $0.hasPrefix(provider.prefix) }
        }
        func complete() async throws {
            try await wait { provider.batches >= 3 }
            for _ in 0..<300 { if try await translated() { return }; try await Task.sleep(nanoseconds:20_000_000) }
            throw FixtureError.timeout
        }
        func start() -> Task<Void, Never> { provider.batches = 0; translator.startManually(); return launch(translator, provider) }
        func shot(_ filename: String) async throws {
            try await Task.sleep(nanoseconds:150_000_000)
            let image = try await runtime.web.takeSnapshot(configuration:nil)
            let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
            try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:shots).appendingPathComponent(filename))
        }
        try await page("/long")
        if baseline {
            translator.toggleAuto()
            let task = launch(translator, provider); try await complete(); task.cancel()
            let sample = await runtime.translate(tabID:tab,operation:"sample")!
            try check(BrowserPageTranslator.detect(sample) == nil, "BASELINE reproduced: translated DOM detected as target language")
            translator.toggleAuto(); translator.toggleAuto() // restore and re-enable before the async restore returns
            try await wait { if case .offer = translator.phase { return true }; return false }
            try check(translator.autoEnabled && translator.configurationBox == nil, "BASELINE reproduced: rapid off/on leaves original text, auto enabled, no translation task")
            translator.startManually()
            let first = translator.configurationBox as! TranslationSession.Configuration
            translator.restore(); try await wait { if case .offer = translator.phase { return true }; return false }
            translator.startManually()
            try check(first == translator.configurationBox as! TranslationSession.Configuration, "BASELINE reproduced: same-language restart configuration is equal")
            runtime.holdRestore = true; translator.restore(); try await wait { runtime.heldRestore != nil }
            translator.pageChanged(runtime:runtime,tabID:UUID(),url:origin+"/next",isLoading:true)
            runtime.releaseRestores()
            try await Task.sleep(nanoseconds:50_000_000)
            try check(translator.phase != .idle, "BASELINE reproduced: stale restore overwrites next page phase")
            print("W291 BASELINE SUMMARY \(passed) reproduced 0 unexpected failures"); return
        }
        try await shot("before.png")
        var previous: TranslationSession.Configuration?
        for round in 1...3 {
            let task = start(); let config = translator.configurationBox as! TranslationSession.Configuration
            if let previous { try check(previous != config, "repeat \(round) invalidates same-language session") }; previous = config
            try await complete(); try check(try await translated(), "continuous translation \(round): all 260 nodes")
            if round == 1 {
                let sample = await runtime.translate(tabID:tab, operation:"sample")!
                try check(BrowserPageTranslator.detect(sample) == "en", "translated DOM still samples original source language")
            }
            if round <= 2 { try await shot(round == 1 ? "first.png" : "second.png") }
            task.cancel(); await task.value
        }
        provider.batches = 0
        translator.toggleAuto(); translator.toggleAuto(); translator.toggleAuto()
        taskForRapid: do {
            let rapid = launch(translator, provider)
            try await complete()
            let rapidComplete = try await translated()
            try check(translator.autoEnabled && rapidComplete, "rapid off/on retranslation completes")
            rapid.cancel(); await rapid.value; translator.toggleAuto()
        }
        for round in 1...3 {
            translator.restore(); try await wait { translator.phase == .offer(source:"en") }
            try await Task.sleep(nanoseconds:100_000_000)
            try check((try await runtime.js("document.querySelector('#article p').textContent") as! String).hasPrefix("Article"), "restore \(round) original text")
            let task = start(); try await complete(); try check(try await translated(), "translate-original-translate \(round)"); task.cancel(); await task.value
        }
        // Same run keeps watching newly inserted DOM; a manual restart also translates it.
        var task = start(); try await complete(); _ = try await runtime.js("appendContent()")
        try await Task.sleep(nanoseconds:3_200_000_000)
        try check((try await runtime.js("document.getElementById('dynamic').textContent") as! String).hasPrefix(provider.prefix), "dynamic content background translation")
        task.cancel(); await task.value; _ = try await runtime.js("appendContent()")
        task = start(); try await complete(); try check(try await translated(), "dynamic content manual retranslation"); task.cancel(); await task.value
        try await page("/next"); task = start(); try await complete(); try check(try await translated(), "translate after navigation"); task.cancel(); await task.value
        // Retry after provider error must recollect the IDs marked by the failed attempt.
        translator.restore(); provider.throwNext = true; task = start()
        try await wait { if case .failed = translator.phase { return true }; return false }; await task.value
        task = start(); try await complete(); try check(try await translated(), "retry after provider failure recollects all nodes"); task.cancel(); await task.value
        translator.restore(); provider.hold = true; provider.entered = false; task = start()
        try await wait { provider.entered }; translator.startManually()
        try check(provider.batches == 1, "manual press during translation ignored")
        // Toggle semantics: second click turns auto off and restores, late provider result cannot apply.
        if !translator.autoEnabled { translator.toggleAuto() }; translator.toggleAuto()
        provider.hold = false; provider.released?.resume(); provider.released = nil; await task.value
        try await Task.sleep(nanoseconds:100_000_000)
        let restoredText = try await runtime.js("document.querySelector('#article p').textContent") as! String
        try check(!translator.autoEnabled && restoredText.hasPrefix("Article"), "toggle during translation cancels and shows original")
        provider.hold = true; provider.entered = false; task = start(); try await wait { provider.entered }
        let applies = runtime.calls.filter { $0 == "apply" }.count
        // Reload same URL: isLoading transition must cancel even when pageKey is unchanged.
        translator.pageChanged(runtime:runtime,tabID:tab,url:origin+"/next",isLoading:true)
        provider.hold = false; provider.released?.resume(); provider.released = nil; await task.value
        try check(translator.phase == .idle && runtime.calls.filter { $0 == "apply" }.count == applies, "same URL reload cancels old batch")
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["ja"], BrowserPageTranslator.autoKey: false], forName: UserDefaults.argumentDomain)
        try await page("/language"); provider.prefix = "日本語訳"
        task = start(); try await complete(); try check(try await translated(), "change provider target then retranslate"); task.cancel(); await task.value
        try check((translator.configurationBox as! TranslationSession.Configuration).target?.minimalIdentifier == "ja", "Apple configuration follows changed target language")
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["zh-Hant"], BrowserPageTranslator.autoKey: false], forName: UserDefaults.argumentDomain)
        translator.restore(); translator.startManually()
        try check((translator.configurationBox as! TranslationSession.Configuration).target == BrowserPageTranslator.targetLanguage, "restart uses current target language")
        runtime.holdRestore = true; translator.restore(); try await wait { runtime.heldRestore != nil }
        translator.pageChanged(runtime:runtime,tabID:UUID(),url:origin+"/held",isLoading:true)
        runtime.releaseRestores()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(translator.phase == .idle, "stale restore cannot overwrite navigation phase")
        try await page("/sample"); translator.restore(); try await Task.sleep(nanoseconds:100_000_000)
        // Force idle so manual sampling can be held over navigation.
        translator.pageChanged(runtime:runtime,tabID:tab,url:origin+"/pending",isLoading:true)
        runtime.holdSample = true; translator.startManually(); try await wait { runtime.heldSample != nil }
        translator.pageChanged(runtime:runtime,tabID:UUID(),url:origin+"/pending-next",isLoading:true)
        runtime.holdSample = false; runtime.heldSample?.resume(); runtime.heldSample = nil
        try await Task.sleep(nanoseconds:100_000_000)
        try check(translator.phase == .idle, "stale manual sample cannot change next page")
        let source = Locale.Language(identifier:"en"), target = Locale.Language(identifier:"zh-Hant")
        if #available(macOS 26.0, *), await LanguageAvailability().status(from:source,to:target) == .installed {
            let session = TranslationSession(installedSource:source,target:target)
            let result = try await session.translate("The library opens every morning.")
            try check(!result.targetText.isEmpty && result.targetText != result.sourceText, "APPLE installed-language smoke")
        } else { print("W291 SKIP APPLE installed-language smoke: en -> zh-Hant language pack unavailable (no download)") }
        print("W291 SUMMARY \(passed) pass 0 fail"); window.close()
    }
}
