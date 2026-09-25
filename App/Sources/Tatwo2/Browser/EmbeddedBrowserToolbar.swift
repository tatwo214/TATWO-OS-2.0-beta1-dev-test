// 源自 Apps/TatwoUltraworkMac 的同名檔；W67 僅重構共用網址列，保留原註解／書籤模型與儲存行為。
import AppKit
import SwiftUI
import WebKit
import Darwin

// MARK: - Annotation model + store（#30：app 內瀏覽器註解）

struct EmbeddedBrowserAnnotation: Identifiable, Codable, Equatable {
    let id: UUID
    let profileKey: UUID
    let url: String
    let title: String
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        profileKey: UUID,
        url: String,
        title: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileKey = profileKey
        self.url = url
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

enum EmbeddedBrowserAnnotationPolicy {
    static let maximumTextCharacters = 4_096
    static let maximumURLCharacters = 4_096
    static let maximumTitleCharacters = 512
    static let maximumAnnotationsPerProfile = 500
    static let maximumPersistedBytes = 1_048_576
    static let maximumAddsPerRateWindow = 12
    static let rateWindowSeconds: TimeInterval = 60

    static func candidate(
        isMainFrame: Bool,
        text: String?,
        committedURLString: String?,
        currentNativeURLString: String?,
        nativeTitle: String?,
        profileKey: UUID,
        createdAt: Date = Date()
    ) -> EmbeddedBrowserAnnotation? {
        guard isMainFrame,
              let committedURLString,
              committedURLString == currentNativeURLString,
              committedURLString.count <= maximumURLCharacters,
              let text = text?.trimmingCharacters(
                in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count <= maximumTextCharacters
        else {
            return nil
        }
        let title = String(
            (nativeTitle ?? "").prefix(maximumTitleCharacters))
        return EmbeddedBrowserAnnotation(
            profileKey: profileKey,
            url: committedURLString,
            title: title,
            text: text,
            createdAt: createdAt)
    }

    static func permitsAppend(
        _ candidate: EmbeddedBrowserAnnotation,
        to annotations: [EmbeddedBrowserAnnotation],
        recentAcceptedAt: [Date],
        now: Date,
        encodedByteCount: Int
    ) -> Bool {
        guard candidate.text.count <= maximumTextCharacters,
              candidate.url.count <= maximumURLCharacters,
              candidate.title.count <= maximumTitleCharacters,
              annotations.lazy.filter({
                  $0.profileKey == candidate.profileKey
              }).count < maximumAnnotationsPerProfile,
              encodedByteCount <= maximumPersistedBytes
        else {
            return false
        }
        let windowStart = now.addingTimeInterval(-rateWindowSeconds)
        return recentAcceptedAt.lazy.filter { $0 >= windowStart }.count
            < maximumAddsPerRateWindow
    }
}

/// 持久化的瀏覽器註解庫。每筆資料綁定 native profile key，查詢與容量
/// 均以 profile 分區；app 內閉環，外部瀏覽器右鍵整合為後續授權項目。
/// `@unchecked Sendable` is required because serialized GCD I/O closures capture the store before UI mutation returns to the main queue.
final class EmbeddedBrowserAnnotationStore:
    ObservableObject,
    @unchecked Sendable
{
    // 全部 mutation 經 DispatchQueue.main / SwiftUI 主執行緒；nonisolated(unsafe) 靜默 Swift6 併發診斷。
    nonisolated(unsafe) static let shared = EmbeddedBrowserAnnotationStore()

    @Published private(set) var annotations: [EmbeddedBrowserAnnotation] = []

    private let fileURL: URL
    private var acceptedAtByProfile: [UUID: [Date]] = [:]
    private let ioQueue = DispatchQueue(
        label: "tatwo.browser-annotations.io",
        qos: .utility)

    init() {
        let dir = TatwoRuntimeLayout.applicationSupportRoot()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser-annotations-v2.json")
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func annotations(
        forURL url: String,
        profileKey: UUID
    ) -> [EmbeddedBrowserAnnotation] {
        annotations.filter {
            $0.profileKey == profileKey && $0.url == url
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(
        _ annotation: EmbeddedBrowserAnnotation,
        now: Date = Date()
    ) -> Bool {
        let candidateAnnotations = annotations + [annotation]
        guard let data = try? JSONEncoder().encode(candidateAnnotations),
              EmbeddedBrowserAnnotationPolicy.permitsAppend(
                annotation,
                to: annotations,
                recentAcceptedAt:
                    acceptedAtByProfile[annotation.profileKey] ?? [],
                now: now,
                encodedByteCount: data.count)
        else {
            return false
        }
        annotations = candidateAnnotations
        let windowStart = now.addingTimeInterval(
            -EmbeddedBrowserAnnotationPolicy.rateWindowSeconds)
        acceptedAtByProfile[annotation.profileKey] =
            (acceptedAtByProfile[annotation.profileKey] ?? [])
            .filter { $0 >= windowStart } + [now]
        save()
        return true
    }

    func remove(_ annotation: EmbeddedBrowserAnnotation) {
        annotations.removeAll { $0.id == annotation.id }
        save()
    }

    // 讀取也走背景 ioQueue，避免啟動時主執行緒同步磁碟 I/O。
    private func load() {
        let url = fileURL
        ioQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  data.count
                    <= EmbeddedBrowserAnnotationPolicy.maximumPersistedBytes,
                  let decoded = try? JSONDecoder().decode([EmbeddedBrowserAnnotation].self, from: data),
                  !decoded.isEmpty,
                  decoded.allSatisfy({
                      $0.text.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumTextCharacters
                          && $0.url.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumURLCharacters
                          && $0.title.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumTitleCharacters
                  }),
                  Dictionary(grouping: decoded, by: \.profileKey)
                    .values.allSatisfy({
                        $0.count
                            <= EmbeddedBrowserAnnotationPolicy
                            .maximumAnnotationsPerProfile
                    })
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.annotations = decoded
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(annotations) else { return }
        let url = fileURL
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Bookmark model + store

struct EmbeddedBrowserBookmark: Identifiable, Codable, Equatable {
    let id: UUID
    let profileKey: UUID
    let url: String
    let title: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        profileKey: UUID,
        url: String,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileKey = profileKey
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }

    var resolvedURL: URL? {
        URL(string: url)
    }

    var host: String {
        guard let host = resolvedURL?.host, !host.isEmpty else {
            return url
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var initial: String {
        String(displayTitle.prefix(1)).uppercased()
    }

    var tooltip: String {
        displayTitle == host ? host : "\(displayTitle)\n\(host)"
    }

    var faviconURL: URL? {
        guard let source = resolvedURL,
              let scheme = source.scheme,
              let host = source.host
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = source.port
        components.path = "/favicon.ico"
        return components.url
    }
}

enum EmbeddedBrowserBookmarkPolicy {
    static let maximumURLCharacters = 4_096
    static let maximumTitleCharacters = 512
    static let maximumBookmarksPerProfile = 100
    static let maximumPersistedBytes = 524_288

    static func candidate(
        urlString: String,
        title: String,
        profileKey: UUID,
        createdAt: Date = Date()
    ) -> EmbeddedBrowserBookmark? {
        let trimmedURL = urlString.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmedURL.count <= maximumURLCharacters,
              trimmedTitle.count <= maximumTitleCharacters,
              let url = URL(string: trimmedURL),
              EmbeddedBrowserNavigationPolicy.decision(for: url) == .allow
        else {
            return nil
        }
        return EmbeddedBrowserBookmark(
            profileKey: profileKey,
            url: url.absoluteString,
            title: trimmedTitle,
            createdAt: createdAt)
    }

    static func permitsAppend(
        _ candidate: EmbeddedBrowserBookmark,
        to bookmarks: [EmbeddedBrowserBookmark],
        encodedByteCount: Int
    ) -> Bool {
        candidate.url.count <= maximumURLCharacters
            && candidate.title.count <= maximumTitleCharacters
            && bookmarks.lazy.filter({
                $0.profileKey == candidate.profileKey
            }).count < maximumBookmarksPerProfile
            && !bookmarks.contains(where: {
                $0.profileKey == candidate.profileKey
                    && $0.url == candidate.url
            })
            && encodedByteCount <= maximumPersistedBytes
    }

    static func isValidPersistedCollection(
        _ bookmarks: [EmbeddedBrowserBookmark],
        encodedByteCount: Int
    ) -> Bool {
        encodedByteCount <= maximumPersistedBytes
            && bookmarks.allSatisfy {
                $0.url.count <= maximumURLCharacters
                    && $0.title.count <= maximumTitleCharacters
                    && $0.resolvedURL != nil
            }
            && Dictionary(grouping: bookmarks, by: \.profileKey)
                .values.allSatisfy {
                    $0.count <= maximumBookmarksPerProfile
                }
    }
}

struct EmbeddedBrowserBookmarkUndoState: Equatable {
    private(set) var bookmarks: [EmbeddedBrowserBookmark]
    private(set) var lastRemoved: EmbeddedBrowserBookmark?
    private var lastRemovedIndex: Int?

    init(bookmarks: [EmbeddedBrowserBookmark]) {
        self.bookmarks = bookmarks
    }

    @discardableResult
    mutating func remove(id: UUID) -> EmbeddedBrowserBookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = bookmarks.remove(at: index)
        lastRemoved = removed
        lastRemovedIndex = index
        return removed
    }

    @discardableResult
    mutating func undo() -> EmbeddedBrowserBookmark? {
        guard let bookmark = lastRemoved else { return nil }
        let index = min(lastRemovedIndex ?? bookmarks.endIndex, bookmarks.endIndex)
        bookmarks.insert(bookmark, at: index)
        lastRemoved = nil
        lastRemovedIndex = nil
        return bookmark
    }
}

/// Profile-partitioned JSON store. Its live location, background I/O, and
/// bounded decode/write behavior intentionally mirror the annotation store.
final class EmbeddedBrowserBookmarkStore:
    ObservableObject,
    @unchecked Sendable
{
    nonisolated(unsafe) static let shared = EmbeddedBrowserBookmarkStore()

    @Published private(set) var bookmarks: [EmbeddedBrowserBookmark]

    private let fileURL: URL?
    private let ioQueue = DispatchQueue(
        label: "tatwo.browser-bookmarks.io",
        qos: .utility)

    init() {
        let dir = TatwoRuntimeLayout.applicationSupportRoot()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser-bookmarks-v1.json")
        bookmarks = []
        load()
    }

    init(
        fileURL: URL?,
        seedBookmarks: [EmbeddedBrowserBookmark] = []
    ) {
        self.fileURL = fileURL
        bookmarks = seedBookmarks
        if fileURL != nil {
            load()
        }
    }

    func bookmarks(profileKey: UUID) -> [EmbeddedBrowserBookmark] {
        bookmarks.filter { $0.profileKey == profileKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(_ bookmark: EmbeddedBrowserBookmark) -> Bool {
        let candidateBookmarks = bookmarks + [bookmark]
        guard let data = try? JSONEncoder().encode(candidateBookmarks),
              EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: bookmarks,
                encodedByteCount: data.count)
        else {
            return false
        }
        bookmarks = candidateBookmarks
        save()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> EmbeddedBrowserBookmark? {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return nil
        }
        bookmarks.removeAll { $0.id == id }
        save()
        return bookmark
    }

    @discardableResult
    func restore(_ bookmark: EmbeddedBrowserBookmark) -> Bool {
        add(bookmark)
    }

    private func load() {
        guard let fileURL else { return }
        ioQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(
                    [EmbeddedBrowserBookmark].self,
                    from: data),
                  EmbeddedBrowserBookmarkPolicy.isValidPersistedCollection(
                    decoded,
                    encodedByteCount: data.count)
            else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.bookmarks = decoded
            }
        }
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(bookmarks),
              data.count
                <= EmbeddedBrowserBookmarkPolicy.maximumPersistedBytes
        else {
            return
        }
        ioQueue.async {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Shared compact address controls. Bookmark management lives in Browser work space.
struct EmbeddedBrowserToolbar: View {
    /// 使用者實際綁定的「聚焦網址列」快捷鍵；沒綁就回 nil，提示不顯示任何按鍵。
    static func focusAddressHint(
        map: BrowserShortcutMap = BrowserGeneralSettings.load().shortcuts
    ) -> String? {
        map.combos(for: .focusAddressBar).first?.display
    }

    @Binding var addressText: String
    var addressFieldFocused: FocusState<Bool>.Binding
    let state: EmbeddedBrowserNavigationState
    let enabled: Bool
    let onSubmit: () -> Void
    let onCommand: (EmbeddedBrowserCommand.Action) -> Void

    var openTabs: [BrowserAddressSuggestion] = []
    var onSelectTab: (String) -> Void = { _ in }
    // FocusState cannot request focus while its TextField is unmounted.
    // Consume an explicit request from the existing browser shortcut action.
    var expansionRequest: Binding<Bool> = .constant(false)
    /// W115（使用者 09-20）：⌘T 不離開現在看的頁面，直接叫出這個搜尋面板，而且欄位是空的（不是現在這頁的網址）；
    /// 送出時開成新分頁。Esc／失焦就取消這個意圖。
    var newTabIntent: Binding<Bool> = .constant(false)
    var showsAddress = true
    /// W148：網址位置改顯示這段文字（擴充管理頁開著時是「擴充功能」，不是底下分頁的網域）。
    var labelOverride: String? = nil
    var compactChrome = false
    /// 聊天旁（compact）：編輯網址時直接在頂列展開成一個輸入欄，不再用浮在網頁上方的面板。
    /// 浮動面板在聊天旁拿不到鍵盤焦點（.014 自測：焦點落到左側欄搜尋、送出不換頁）；
    /// 外層用這個值把分頁列讓出來。
    var isEditing: Binding<Bool> = .constant(false)
    // 提示只能顯示使用者實際綁定的快捷鍵。⌘L 是系統保留鍵且不在 defaults 裡，
    // 寫死「⌘L 編輯」等於向使用者宣告一個按下去沒反應的功能。
    @State private var addressShortcutHint: String? = EmbeddedBrowserToolbar.focusAddressHint()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var copied = false
    @State private var history: [BrowserHistoryEntry] = []
    @State private var searchSettings = BrowserGeneralSettings()
    @State private var selection = -1
    private struct Choice: Identifiable {
        let id: String
        let section: String
        let title: String
        let url: String?
        let tabID: String?
    }
    private var editHint: String {
        addressShortcutHint.map { "\($0) 編輯 · Esc 還原" } ?? "Esc 還原"
    }
    private var choices: [Choice] {
        let query = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isExpanded, !query.isEmpty else { return [] }
        let tabs = openTabs.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
            .prefix(6).map { Choice(id: "tab-" + $0.id, section: "開啟中的分頁", title: $0.title, url: nil, tabID: $0.id) }
        let visits = BrowserHistoryStore.suggestions(history, matching: query).map {
            Choice(id: $0.url.absoluteString, section: "歷史", title: $0.title, url: $0.url.absoluteString, tabID: nil)
        }
        return [Choice(id: "search", section: "用 \(searchSettings.searchEngine.title) 搜尋", title: query,
            url: searchSettings.searchEngine.queryURL(query).absoluteString, tabID: nil)] + tabs + visits
    }
    private func choose(_ choice: Choice) {
        isExpanded = BrowserOmniboxPresentation.isExpanded(after: .submit)
        if let id = choice.tabID { onSelectTab(id); addressFieldFocused.wrappedValue = false }
        else if let url = choice.url { addressText = url; onSubmit(); addressFieldFocused.wrappedValue = false }
        selection = -1
    }

    var body: some View {
        HStack(spacing: BrowserOmniboxMetrics.controlGap) {
            control("chevron.left", "上一頁", enabled && state.canGoBack, .goBack)
            control("chevron.right", "下一頁", enabled && state.canGoForward, .goForward)
            control(state.isLoading ? "xmark" : "arrow.clockwise", state.isLoading ? "停止載入" : "重新載入", enabled && showsAddress, state.isLoading ? .stopLoading : .reload)
            if showsAddress && compactChrome && isExpanded {
                addressField
                    .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset)
                    .background(BrowserOmniboxDismissMonitor { dismissEditor(.focusLost) })
            } else if showsAddress && compactChrome {
                // 使用者 09-19：聊天旁不要一長串網址，改成一顆連結鈕，點了複製這個分頁的網址；要改網址走右鍵或快捷鍵。
                Button(action: copyAddress) {
                    Image(systemName: copied ? "checkmark" : "link").font(.system(size: BrowserOmniboxMetrics.iconSize))
                        .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!enabled || (state.urlString ?? "").isEmpty)
                .help("複製此分頁網址；右鍵可編輯網址")
                .accessibilityLabel(copied ? "已複製網址" : "複製網址").accessibilityIdentifier("browser.omnibox.copy")
                .contextMenu {
                    Button("複製網址", action: copyAddress)
                    Button("編輯網址…", action: expandEditor)
                }
            } else if showsAddress {
                Button(action: expandEditor) {
                    HStack(spacing: BrowserOmniboxMetrics.controlGap) {
                        // 獨立 Browser：顯示網域（不放放大鏡）；聊天旁走上面的連結鈕。
                        Text(labelOverride ?? BrowserOmniboxPresentation.domain(for: state.urlString))
                            .font(.system(size: BrowserOmniboxMetrics.domainFontSize))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, minHeight: BrowserOmniboxMetrics.collapsedHeight, alignment: .leading)
                    .padding(.leading, BrowserOmniboxMetrics.horizontalInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!enabled)
                .help(editHint)
                .accessibilityLabel("網址").accessibilityIdentifier("browser.omnibox")
                .accessibilityHidden(isExpanded)
            } else {
                Spacer(minLength: BrowserOmniboxMetrics.zero)
            }
        }
        .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
        .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset)
        .frame(height: BrowserOmniboxMetrics.collapsedHeight)
        // 命中層本身不吃事件（mouse-down 沿 responder chain 回到 SwiftUI），但它讓
        // AppKit 知道這塊不是拖視窗區。聊天旁的 chrome 由外層浮動工具列統一登記，
        // 這裡只負責獨立 Browser 自己那條導覽列。
        .background(BrowserChromeHitLayer())
        .accessibilityIdentifier("browser-navigation-bar")
        .overlay(alignment: compactChrome ? .topLeading : .top) {
            if showsAddress && isExpanded && !compactChrome {
                editorPanel
                    .background(BrowserChromeHitLayer())
                    .frame(width: compactChrome ? 280 : nil)
                    .offset(y: BrowserOmniboxMetrics.collapsedHeight + BrowserOmniboxMetrics.panelGap)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: BrowserOmniboxMetrics.expansionDuration), value: isExpanded)
        // W115：獨立 Browser 也要回報「搜尋面板開著」——頂列平時隱形，面板開著時不能因為滑鼠不在頂端就把它收掉（自測 .013）。
        .onChange(of: isExpanded) { _, expanded in isEditing.wrappedValue = expanded }
        .onChange(of: expansionRequest.wrappedValue, initial: true) { _, requested in
            guard requested else { return }
            expansionRequest.wrappedValue = false
            expandEditor()
        }
        // W115d（.018 自測：第二次 ⌘T 只讓欄位失焦，面板還掛著）：取消不再靠「焦點變了」間接推導，
        // newTabIntent 由 true 變 false 而面板還開著＝使用者取消，直接收。送出那條路徑面板已經先收了，不會進來。
        .onChange(of: newTabIntent.wrappedValue) { was, now in
            if was, !now, isExpanded { dismissEditor(.escape) }
        }
        .onChange(of: addressFieldFocused.wrappedValue) { _, focused in
            if focused && showsAddress {
                isExpanded = BrowserOmniboxPresentation.isExpanded(after: .focusRequested)
            } else if isExpanded {
                dismissEditor(.focusLost)
            }
        }
        .onChange(of: showsAddress) { _, visible in
            guard !visible else { return }
            isExpanded = false
            addressFieldFocused.wrappedValue = false
            expansionRequest.wrappedValue = false
            selection = -1
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserShortcutMap.changed)) { _ in
            addressShortcutHint = EmbeddedBrowserToolbar.focusAddressHint()
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            do { try await Task.sleep(for: BrowserOmniboxMetrics.historyDebounce) }
            catch { return }
            history = (try? await BrowserHistoryStore.shared.entries()) ?? []
        }
    }

    private var addressField: some View {
        TextField("搜尋或輸入網址", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: BrowserOmniboxMetrics.editorFontSize, design: .monospaced))
            .focused(addressFieldFocused)
            .frame(height: BrowserOmniboxMetrics.expandedFieldHeight)
            .onSubmit {
                if choices.indices.contains(selection) { choose(choices[selection]) }
                else {
                    isExpanded = BrowserOmniboxPresentation.isExpanded(after: .submit)
                    onSubmit()
                    addressFieldFocused.wrappedValue = false
                }
            }
            .onMoveCommand { direction in
                guard !choices.isEmpty, !compactChrome else { return } // 聊天旁的行內輸入欄沒有建議清單
                if direction == .down { selection = min(selection + 1, choices.count - 1) }
                if direction == .up { selection = max(0, selection - 1) }
            }
            .onChange(of: addressText) { _, _ in selection = -1 }
            .onExitCommand {
                addressText = state.urlString ?? ""
                dismissEditor(.escape)
            }
            .accessibilityLabel("網址").accessibilityIdentifier("browser.omnibox")
            .disabled(!enabled)
            // 欄位剛掛上去的那一輪還不在視窗的 key-view 迴圈裡，同步要焦點會無聲失敗（焦點留在原處）。
            .onAppear { DispatchQueue.main.async { addressFieldFocused.wrappedValue = true } }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: BrowserOmniboxMetrics.panelGap) {
            addressField
            Text(editHint)
                .font(.system(size: BrowserOmniboxMetrics.hintFontSize))
                .foregroundStyle(LiquidGlassTokens.browserOmniboxMutedInk)
                .allowsHitTesting(false)
            if !choices.isEmpty {
                ScrollView {
                    VStack(spacing: BrowserOmniboxMetrics.zero) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            Button { choose(choice) } label: {
                                HStack(spacing: BrowserOmniboxMetrics.controlGap) {
                                    Text(choice.section).font(.caption)
                                        .foregroundStyle(LiquidGlassTokens.browserOmniboxMutedInk)
                                    Text(choice.title).lineLimit(1)
                                    Spacer(minLength: BrowserOmniboxMetrics.zero)
                                }
                                .padding(BrowserOmniboxMetrics.panelPadding)
                                .frame(height: BrowserOmniboxMetrics.suggestionRowHeight)
                                .contentShape(Rectangle())
                                .background(index == selection
                                    ? Color.accentColor.opacity(LiquidGlassTokens.browserOmniboxSelectionOpacity) : .clear)
                            }.buttonStyle(.plain).focusable(false)
                        }
                    }
                }
                .frame(height: min(CGFloat(choices.count) * BrowserOmniboxMetrics.suggestionRowHeight,
                    BrowserOmniboxMetrics.suggestionMaximumHeight))
                .accessibilityLabel("網址建議")
            }
        }
        .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
        .padding(BrowserOmniboxMetrics.panelPadding)
        .frame(maxWidth: BrowserOmniboxMetrics.panelMaximumWidth, minHeight: BrowserOmniboxMetrics.panelMinimumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(BrowserOmniboxGlass(cornerRadius: BrowserOmniboxMetrics.panelRadius))
        .background(BrowserOmniboxDismissMonitor { dismissEditor(.focusLost) })
    }

    private func copyAddress() {
        guard let url = state.urlString, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func expandEditor() {
        guard enabled && showsAddress else { return }
        guard !isExpanded else { if newTabIntent.wrappedValue { addressText = "" }; addressFieldFocused.wrappedValue = true; return }
        searchSettings = BrowserGeneralSettings.load()
        addressText = newTabIntent.wrappedValue ? "" : (state.urlString ?? "")
        selection = -1
        isExpanded = BrowserOmniboxPresentation.isExpanded(after: .click)
    }

    private func dismissEditor(_ event: BrowserOmniboxPresentation.Event) {
        guard isExpanded else { return }
        isExpanded = BrowserOmniboxPresentation.isExpanded(after: event)
        addressText = state.urlString ?? ""
        newTabIntent.wrappedValue = false
        addressFieldFocused.wrappedValue = false
        selection = -1
    }

    private func control(_ symbol: String, _ label: String, _ enabled: Bool,
                         _ action: EmbeddedBrowserCommand.Action) -> some View {
        Button {
            dismissEditor(.focusLost)
            onCommand(action)
        } label: {
            Image(systemName: symbol).font(.system(size: BrowserOmniboxMetrics.iconSize))
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}
