import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// W112（使用者 2026-09-20：翻譯「不然先用apple的吧」）：就地翻譯。頁面文字只在使用者按了翻譯之後才取出，
/// 交給 Apple 的裝置端翻譯（不出這台設備），翻完寫回原本的文字節點，版面不動；可一鍵還原。
@MainActor
final class BrowserPageTranslator: ObservableObject {
    enum Phase: Equatable { case idle, offer(source: String), translating(source: String), translated(source: String), failed(String) }
    @Published private(set) var phase: Phase = .idle
    /// `.translationTask` 靠這個值的變動啟動；型別放 Any 是因為 Translation 只在 macOS 15 以上有。
    @Published var configurationBox: Any?
    private var generation = 0
    private weak var runtime: BrowserWorkSpaceRuntime?
    private var tabID: UUID?
    private var pageKey = ""

    static let alwaysKey = "tatwo.browser.translate.alwaysHosts"
    static var alwaysHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: alwaysKey) }
    }
    /// W119（使用者 2026-09-20 晚：「把翻譯鍵改成我點下去就開啟自動翻譯 再點才取消」「點進其中一篇新聞連結 進去後應繼續自動翻譯」）：
    /// 翻譯鈕是一個開關。開著的時候，任何分頁載入到外語頁面都自動翻；關掉就把目前這頁還原。跨重開保留。
    static let autoKey = "tatwo.browser.translate.auto"
    @Published private(set) var autoEnabled = UserDefaults.standard.bool(forKey: BrowserPageTranslator.autoKey)
    func toggleAuto() {
        autoEnabled.toggle()
        UserDefaults.standard.set(autoEnabled, forKey: Self.autoKey)
        if autoEnabled { startManually() } else { restore() }
    }

    static var targetLanguage: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "zh-Hant") }

    /// 每次分頁、網址或載入狀態變動都叫一次；載入完成後才偵測語言。
    func pageChanged(runtime: BrowserWorkSpaceRuntime, tabID: UUID?, url: String?, isLoading: Bool) {
        let key = "\(tabID?.uuidString ?? "-")|\(url ?? "-")"
        self.runtime = runtime
        guard key != pageKey || (phase == .idle && !isLoading) else { return }
        if key != pageKey { pageKey = key; self.tabID = tabID; generation += 1; phase = .idle; configurationBox = nil }
        guard !isLoading, let tabID, let url, url.hasPrefix("http") else { return }
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)   // 等頁面把第一屏文字放進 DOM
            guard let self, current == self.generation,
                  let json = await runtime.translate(tabID: tabID, operation: "sample"),
                  let source = Self.detect(json), current == self.generation else { return }
            self.phase = .offer(source: source)
            if self.autoEnabled || URL(string: url)?.host.map(Self.alwaysHosts.contains) == true { self.start() }
        }
    }

    /// 來源語言與使用者語言同一種就不提供翻譯。先信頁面自己宣告的 lang，再用文字判斷。
    static func detect(_ json: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let text = object["text"] as? String, text.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let declared = (object["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let source = recognizer.dominantLanguage?.rawValue ?? declared else { return nil }
        let base: (String) -> String = { String($0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
        return base(source) == base(targetLanguage.minimalIdentifier) ? nil : source
    }

    /// 工具列的翻譯鈕：隨時可以手動按。還沒偵測過就先取樣判斷來源語言；同語言也照使用者的意思說明，不默默不動。
    func startManually() {
        if case .offer = phase { start(); return }
        guard phase == .idle || { if case .failed = phase { return true }; return false }(), let tabID, let runtime else { return }
        let current = generation
        Task { [weak self] in
            guard let self, let json = await runtime.translate(tabID: tabID, operation: "sample"), current == self.generation else {
                self?.phase = .failed("這一頁現在沒辦法翻譯（頁面還沒準備好）"); return
            }
            guard let source = Self.detect(json) else { self.phase = .failed("這一頁看起來已經是你的語言，或文字太少"); return }
            self.phase = .offer(source: source); self.start()
        }
    }

    func start() {
        guard case .offer(let source) = phase else { return }
        phase = .translating(source: source)
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            configurationBox = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Self.targetLanguage)
            return
        }
        #endif
        phase = .failed("這個 macOS 版本沒有內建翻譯")
    }

    func restore() {
        guard let tabID, let runtime else { return }
        // W119：關掉開關時不管目前狀態都請頁面還原（切回一個先前翻過的分頁時 phase 是 idle，但 DOM 還是譯文）。
        var source: String?
        switch phase { case .translated(let s), .translating(let s), .offer(let s): source = s; default: break }
        generation += 1; configurationBox = nil
        Task { _ = await runtime.translate(tabID: tabID, operation: "restore"); self.phase = source.map { .offer(source: $0) } ?? .idle }
    }

    #if canImport(Translation)
    /// 由 `.translationTask` 呼叫：一批一批取文字、翻、寫回；翻完後每 3 秒補翻新冒出來的內容（無限捲動）。
    @available(macOS 15.0, *)
    func run(_ session: TranslationSession) async {
        guard case .translating(let source) = phase, let tabID, let runtime else { return }
        let current = generation
        do {
            try await session.prepareTranslation()   // 語言包沒裝時，系統會自己問要不要下載
            var idle = 0, misses = 0, applied = 0
            // W119（使用者：「翻譯卡住了」）：取文字那一步偶爾逾時（頁面正忙、正在換頁），以前直接 break，
            // 「翻譯中」的轉圈就沒人收。現在重試幾次；不管怎麼離開迴圈，最後一定把狀態收掉。
            defer {
                if current == generation, phase == .translating(source: source) {
                    phase = applied > 0 ? .translated(source: source) : .failed("這一頁現在沒辦法翻譯（頁面沒有回應）")
                }
            }
            while current == generation, idle < 200 {
                guard let json = await runtime.translate(tabID: tabID, operation: "collect", limit: 120),
                      let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                      let items = object["items"] as? [[Any]] else {
                    misses += 1
                    if misses >= 4 { break }
                    try await Task.sleep(nanoseconds: 1_500_000_000); continue
                }
                misses = 0
                let requests = items.compactMap { item -> TranslationSession.Request? in
                    guard item.count == 2, let id = item[0] as? Int, let text = item[1] as? String else { return nil }
                    return .init(sourceText: text, clientIdentifier: String(id))
                }
                if !requests.isEmpty {
                    let responses = try await session.translations(from: requests)
                    let pairs: [[Any]] = responses.compactMap { r in r.clientIdentifier.flatMap { Int($0) }.map { [$0, r.targetText] as [Any] } }
                    if let data = try? JSONSerialization.data(withJSONObject: pairs), current == generation {
                        _ = await runtime.translate(tabID: tabID, operation: "apply", payload: String(decoding: data, as: UTF8.self))
                        applied += pairs.count
                        // W119b（.022 自測：頁面早就是中文了，鈕還轉圈一分多鐘，看起來像卡住）：長頁面要翻很多批，
                        // 第一批譯文一寫回頁面就把「翻譯中」收掉；後面的批次照樣在背景繼續翻（迴圈只看 generation）。
                        if current == generation, phase == .translating(source: source) { phase = .translated(source: source) }
                    }
                }
                if current == generation, phase == .translating(source: source), object["more"] as? Bool != true { phase = .translated(source: source) }
                if object["more"] as? Bool == true { continue }
                idle = requests.isEmpty ? idle + 1 : 0
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        } catch is CancellationError {
        } catch {
            if current == generation { phase = .failed("翻譯失敗：\(error.localizedDescription)") }
        }
    }
    #endif
}

/// 掛在網頁上：負責偵測語言與跑 `.translationTask`；按鈕在工具列（使用者 2026-09-20：「翻譯鈕擺到工具列 可手動點擊」）。
struct BrowserTranslationHost: ViewModifier {
    @ObservedObject var runtime: BrowserWorkSpaceRuntime
    @ObservedObject var translator: BrowserPageTranslator
    let tabID: UUID?

    private var url: String? { runtime.navigationTabID == tabID ? runtime.navigationState.urlString : nil }
    private var isLoading: Bool { runtime.navigationTabID == tabID ? runtime.navigationState.isLoading : true }

    func body(content: Content) -> some View {
        translationTask(content)
            .onChange(of: "\(tabID?.uuidString ?? "")|\(url ?? "")|\(isLoading)", initial: true) { _, _ in
                translator.pageChanged(runtime: runtime, tabID: tabID, url: url, isLoading: isLoading)
            }
    }

    @ViewBuilder private func translationTask(_ view: some View) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            view.translationTask(translator.configurationBox as? TranslationSession.Configuration) { session in
                await translator.run(session)
            }
        } else { view }
        #else
        view
        #endif
    }
}

/// 工具列上的翻譯鈕＝自動翻譯的開關（W119）。開著＝強調色；這一頁翻不了就變暗（不跳警示）；翻第一輪時轉圈。
struct BrowserTranslateButton: View {
    @ObservedObject var translator: BrowserPageTranslator
    let host: String?
    let size: CGFloat

    var body: some View {
        Button(action: translator.toggleAuto) {
            Group {
                if case .translating = translator.phase { ProgressView().controlSize(.mini) }
                else { Image(systemName: "translate").foregroundStyle(tint).opacity(unavailable ? 0.3 : 1) }
            }
            .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityIdentifier("browser.translate")
        .accessibilityValue(translator.autoEnabled ? "開" : "關")
    }

    // 使用者 09-20：「不要按了顯示警示 按下不能翻譯就符號顯示變暗」——不能翻就只是變暗，不跳警示符號。
    private var unavailable: Bool { if case .failed = translator.phase { return true }; return false }
    private var tint: Color { translator.autoEnabled ? Color.accentColor : LiquidGlassTokens.browserOmniboxInk }
    private var label: String {
        if !translator.autoEnabled {
            if case .offer = translator.phase { return "這一頁是外語；點一下開啟自動翻譯" }
            return "開啟自動翻譯（由 Apple 裝置端翻譯，內容不離開這台設備）"
        }
        switch translator.phase {
        case .translating: return "自動翻譯開著：翻譯中…（第一次要等系統下載語言，可能幾分鐘）；再點一次關閉並顯示原文"
        case .failed(let reason): return "自動翻譯開著；\(reason)。再點一次關閉"
        default: return "自動翻譯開著；再點一次關閉並顯示原文"
        }
    }
}
