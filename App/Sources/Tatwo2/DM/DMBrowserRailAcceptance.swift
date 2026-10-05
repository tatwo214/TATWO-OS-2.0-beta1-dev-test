#if DEBUG
import AppKit
import Combine
import SwiftUI

/// W184 G2（使用者 09-29：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」）＋
/// W184 G2c（09-29 17:50：「瀏覽器右側目前用起來不好 改成跟browser space一樣滑鼠指到左列」）＋W184 G2d（09-30：側欄、頂列、搜尋框
/// 改用主視窗 Browser space 的元件）：`TATWO2_SELFTEST=w184browser` 的側欄與新分頁段——左緣才滑出、卡片不被蓋、真的滑鼠按側欄每一格、
/// 新分頁（側欄＋、總覽＋、⌘⌥T）；書籤、珍藏一律開新分頁、不動 Pod／配對／授權分頁；切換空間後書籤跟著換（跟主視窗同一個 store）；
/// 打網址或搜尋只開 https；分頁滿了；一般分頁不算敏感。
/// 完整隔離的 staging；不用任何 shared 單例（Browser、Browser space 的分頁清單與 store 都是自測自己建的、只在記憶體）。
extension DMBrowserPhoneAcceptance {
    /// 自測自己的 Browser space（只在記憶體的分頁清單，不碰正式的 tabs.json）：
    /// 「Primary One」（綠，兩個資料夾：文件、筆記）、「工作」（紫，一個資料夾）、Session space；珍藏三個（一個跟 Pod 同網址、一個 http）。
    @MainActor final class Shelf {
        let registry: BrowserTabRegistry
        let store: BrowserWorkSpaceStore
        let spaces: DMBrowserSpaces
        let primary: UUID
        let work: UUID
        let docs: BrowserBookmark
        let plain: BrowserBookmark
        let script: BrowserBookmark
        let board: BrowserBookmark
        let favorite: BrowserFavorite
        let podFavorite: BrowserFavorite
        let httpFavorite: BrowserFavorite

        init() {
            let registry = BrowserTabRegistry(storageURL: nil)
            self.registry = registry
            let first = registry.spaces.first { !$0.isSessionSpace }?.id ?? registry.addSpace(name: "Primary One").id
            registry.renameSpace(first, to: "Primary One")
            registry.setSpaceColor(first, "green")
            primary = first
            let folder = registry.spaces.first { $0.id == first }?.folders.first?.id ?? registry.addFolder(spaceID: first)!.id
            registry.renameFolder(folder, to: "文件")
            docs = registry.addBookmark(folderID: folder, url: URL(string: "https://example.com/docs")!, title: "Primary One 文件")!
            plain = registry.addBookmark(folderID: folder, url: URL(string: "http://example.org/plain")!, title: "舊網站（http）")!
            let notes = registry.addFolder(spaceID: first, name: "筆記")!.id
            script = registry.addBookmark(folderID: notes, url: URL(string: "javascript:void(0)")!, title: "小工具（javascript）")!
            let second = registry.addSpace(name: "工作").id
            registry.setSpaceColor(second, "purple")
            work = second
            let boards = registry.addFolder(spaceID: second, name: "看板")!.id
            board = registry.addBookmark(folderID: boards, url: URL(string: "https://example.net/board")!, title: "示範看板")!
            favorite = registry.addFavorite(url: URL(string: "https://example.com/docs")!, title: "文件")
            podFavorite = registry.addFavorite(url: URL(string: "https://chatgpt.com/plugins")!, title: "ChatGPT")
            httpFavorite = registry.addFavorite(url: URL(string: "http://example.org/news")!, title: "新聞")
            store = BrowserWorkSpaceStore(registry: registry)
            spaces = DMBrowserSpaces(registry: registry, store: store)
        }

        func projected(_ id: UUID) -> BrowserWorkSpaceStore.Bookmark? {
            store.folders.flatMap(\.bookmarks).first { $0.id == id }
        }

        /// W184 G2d：主視窗在「Primary One」釘選一個分頁（側欄「📌 Pinned」底下那一列）；回傳它在分頁清單裡的 id。
        @discardableResult
        func addPinned(_ url: URL, title: String) -> UUID {
            let tab = registry.openTab(owner: .workSpace(spaceID: primary), url: url, title: title)
            registry.setPinned(tab.id, true)
            return tab.id
        }

        /// 那個釘選分頁在主視窗 store 裡的樣子（Pinned 底下那一列用的）。
        func pinnedTab(_ id: UUID) -> BrowserWorkSpaceStore.Tab? {
            store.pinnedTabs.first { $0.registryID == id }
        }
    }

    /// 畫面證據用的假網頁宿主：一般分頁、授權頁的頁面畫出網域（正式是 CEF 的網頁；這個建置沒有 Chromium）。
    @MainActor final class EvidenceWebHost: GlobalDMWebPageHosting {
        /// W184 G2d：每一次開的網址（量頂列的重新載入、打網址開了哪一頁）。
        private(set) var opened: [URL] = []
        /// W184 G2d（GPT-6 審查 G2d #1）：開出來的每一張假網頁（量重新載入不換瀏覽器、紀錄還在）。
        private(set) var pages: [EvidenceWebPage] = []
        func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage {
            opened.append(url)
            let page = EvidenceWebPage("\(url.host ?? "")\(url.path)（假網頁）", url: url)
            page.report = onState
            pages.append(page)
            onState(GlobalDMWebPageState(loading: false, error: nil, committedURL: url, stacked: 0))
            return page
        }
    }

    /// 畫面證據用的假網頁。W184 G2d（GPT-6 審查 G2d #1）：帶一段假的瀏覽紀錄——頁內走到別頁（navigate）、上一頁、下一頁、原生重新載入
    /// （同一張頁、紀錄不變、回報一次載入）；關掉＝從畫面拿掉。
    @MainActor final class EvidenceWebPage: GlobalDMWebPage {
        let canvas = EvidencePage.Canvas(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        var report: (@MainActor (GlobalDMWebPageState) -> Void)?
        private(set) var history: [URL] = []
        private(set) var index = 0
        private(set) var reloads = 0
        private(set) var closes = 0
        init(_ title: String, url: URL? = nil) {
            canvas.title = title
            if let url { history = [url] }
        }
        var view: NSView { canvas }
        var isHumanActor: Bool { true }
        var current: URL? { history.isEmpty ? nil : history[index] }
        func back() { goBack() }
        /// 頁內點了連結、走到別頁（瀏覽紀錄多一頁，往前的紀錄清掉）。
        func navigate(to url: URL) {
            history = Array(history.prefix(index + 1)) + [url]
            index = history.count - 1
            publish()
        }
        func goBack() {
            guard index > 0 else { return }
            index -= 1
            publish()
        }
        func goForward() {
            guard index + 1 < history.count else { return }
            index += 1
            publish()
        }
        func reload() {
            reloads += 1
            publish(loading: true)
            publish()
        }
        func close() { closes += 1; canvas.removeFromSuperview() }
        private func publish(loading: Bool = false) {
            guard let current else { return }
            canvas.title = "\(current.host ?? "")\(current.path)（假網頁）"
            canvas.needsDisplay = true
            report?(GlobalDMWebPageState(loading: loading, error: nil, committedURL: current, stacked: 0,
                                         canGoBack: index > 0, canGoForward: index + 1 < history.count))
        }
    }

    static func openedID(_ result: DMBrowserBrowseResult) -> UUID? {
        if case .opened(let id) = result { return id }
        return nil
    }

    static func switchedID(_ result: DMBrowserBrowseResult) -> UUID? {
        if case .switched(let id) = result { return id }
        return nil
    }

    // MARK: - 書籤、珍藏、打網址：一律新分頁，不動流程分頁；切換空間；分頁滿了；一般分頁不算敏感

    @MainActor static func shelfChecks(_ check: Checker) async {
        let shelf = Shelf()
        let h = Harness("w184g2")
        let (window, holder) = DMBrowserAcceptance.windowed("w184g2")
        h.browser.release(h.surface)
        h.browser.claim(holder)
        // 流程的分頁：Pod（ChatGPT Dev）＋配對頁（popup），配對頁在最前面。
        _ = h.browser.openPod(purpose: .chatgptDeveloper)
        h.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        let pairingPage = FakePage()
        var pairingCancelled = 0
        h.browser.adoptPopup(pairingPage, key: 90, purpose: .chatgptPairing, expectedHost: nil, onCancel: { pairingCancelled += 1 })
        let podTab = h.browser.tabs.first { $0.kind == .pod }
        let podPage = h.podPages.get().first
        let flowIDs = Set(h.browser.tabs.map(\.id))

        // 1. 書籤：開新分頁（一般分頁）、在最前面；Pod、配對頁的分頁與頁面都不動。
        guard let docs = shelf.projected(shelf.docs.id) else { return check(false, "G1 fixture bookmark projected") }
        let opened = DMBrowserShelf.open(bookmark: docs, in: h.browser)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 1 && h.browser.activeTab?.pageURL != nil }
        let newTab = h.browser.activeTab
        let tabsKept: Bool = flowIDs.isSubset(of: Set(h.browser.tabs.map(\.id)))
        let pagesKept: Bool = (podPage?.closes ?? 1) == 0 && pairingPage.closes == 0 && pairingCancelled == 0
        let podURLKept: Bool = h.browser.tabs.first(where: { $0.kind == .pod })?.pageURL == podTab?.pageURL
        let flowsKept = tabsKept && pagesKept && podURLKept
        let openedNew: Bool = openedID(opened) != nil && openedID(opened) == newTab?.id
        let isBrowse: Bool = newTab?.purpose == .browse && newTab?.kind == .web
        let startOK: Bool = newTab?.startURL?.absoluteString == "https://example.com/docs" && newTab?.title == "Primary One 文件"
        let countOK: Bool = h.host.pages.count == 1 && h.browser.tabs.count == 3
        check(openedNew && isBrowse && startOK && countOK && flowsKept,
              "G1 a bookmark opens a NEW general tab in the DM Browser (in front); the Pod tab and the pairing tab, their pages and their flows are untouched",
              "result=\(opened) tab=\(String(describing: newTab)) pages=\(h.host.pages.count) flowsKept=\(flowsKept)")
        // 2. 同一個書籤再按＝切過去（不再開）；別的書籤、http 書籤＝新分頁（http 改 https）；javascript: 書籤＝不開。
        if let pairing = h.browser.tabs.first(where: { $0.purpose == .chatgptPairing }) { h.browser.select(pairing.id) }
        let again = DMBrowserShelf.open(bookmark: docs, in: h.browser)
        let switched = switchedID(again) != nil && switchedID(again) == newTab?.id && h.browser.activeID == newTab?.id
        let plain = shelf.projected(shelf.plain.id).map { DMBrowserShelf.open(bookmark: $0, in: h.browser) }
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 2 }
        let upgraded = h.browser.activeTab?.startURL?.absoluteString == "https://example.org/plain"
        let countBefore = h.browser.tabs.count
        let script = shelf.projected(shelf.script.id).map { DMBrowserShelf.open(bookmark: $0, in: h.browser) }
        let scriptRefused: Bool = script == .refused(.notSecure)
        let nothingOpened: Bool = h.browser.tabs.count == countBefore && h.host.pages.count == 2
        check(switched && upgraded && scriptRefused && nothingOpened,
              "G2 the same bookmark again switches to its tab; an http bookmark opens as https in a new tab; a javascript: bookmark is refused (one sentence), nothing opened",
              "again=\(again) plain=\(String(describing: plain)) script=\(String(describing: script))")
        // 3. 珍藏（W184 G2 第三輪，同主視窗 openFavorite）：書籤開的分頁屬於那個書籤（同網址也不拿來比）＝開這個珍藏自己的新分頁；
        //    再按同一個珍藏＝切回它自己的分頁；跟 Pod 同網址的珍藏＝開新的一般分頁（不切到 Pod、不在 Pod 裡導航）。
        let favoriteResult = DMBrowserShelf.open(favorite: shelf.favorite, in: h.browser)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 3 }
        let favoriteTab = openedID(favoriteResult)
        let favoriteOwn: Bool = favoriteTab != nil && favoriteTab != newTab?.id
        let favoriteAgain = DMBrowserShelf.open(favorite: shelf.favorite, in: h.browser)
        let favoriteSwitched: Bool = favoriteTab != nil && switchedID(favoriteAgain) == favoriteTab
        if let favoriteTab { h.browser.userClose(favoriteTab) }   // 一般分頁最多 4 個：先收掉
        let podBefore = h.browser.tabs.first { $0.kind == .pod }
        let podFavorite = DMBrowserShelf.open(favorite: shelf.podFavorite, in: h.browser)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 4 }
        let podFavoriteTab = h.browser.activeTab
        let podUntouched = h.browser.tabs.first(where: { $0.kind == .pod }) == podBefore && (podPage?.closes ?? 1) == 0
        let podFavoriteNew: Bool = openedID(podFavorite) != nil && openedID(podFavorite) == podFavoriteTab?.id
        let podFavoriteBrowse: Bool = podFavoriteTab?.purpose == .browse && podFavoriteTab?.kind == .web
        check(favoriteOwn && favoriteSwitched && podFavoriteNew && podFavoriteBrowse && podUntouched,
              "G3 (W184 G2 third round) a favorite opens its own tab (a tab opened from a bookmark belongs to that bookmark, same as the main window) and switches back to it next time; a favorite with the Pod's own address opens a NEW general tab — never the Pod tab",
              "favorite=\(favoriteResult) again=\(favoriteAgain) podFavorite=\(podFavorite) active=\(String(describing: podFavoriteTab))")
        // 3b（W184 G2 修正，GPT-6 6）：手打網址 A 開頁、在頁內導到 B，再點珍藏 A＝開新的（不切到已經離開 A 的那一頁）；
        //     還停在 A 的一般分頁＝切過去。
        let pageA = URL(string: "https://example.com/a")!, pageB = URL(string: "https://example.com/b")!
        if let plainTab = plain.flatMap(openedID) { h.browser.userClose(plainTab) }   // 一般分頁最多 4 個：先收掉用不到的那一個
        let typedA = h.browser.openBrowse(url: pageA, title: "A", origin: .typed)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 5 }
        let typedTab = openedID(typedA)
        h.host.pages.last?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: pageB, stacked: 0))
        let movedToB = h.browser.tabs.first(where: { $0.id == typedTab })?.pageURL == pageB
        let favoriteA = BrowserFavorite(id: UUID(), url: pageA, title: "A", faviconPNG: nil, order: 0)
        let afterMove = DMBrowserShelf.open(favorite: favoriteA, in: h.browser)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 6 }
        let freshA = openedID(afterMove)
        let againA = DMBrowserShelf.open(favorite: favoriteA, in: h.browser)
        let newTabForA: Bool = freshA != nil && freshA != typedTab
        let switchedToA: Bool = switchedID(againA) != nil && switchedID(againA) == freshA
        check(movedToB && newTabForA && switchedToA,
              "G3b (W184 G2 fix, GPT-6 6) typed A then navigated to B, favorite A opens a NEW tab (the one now on B no longer counts); a general tab still on A switches",
              "moved=\(movedToB) afterMove=\(afterMove) again=\(againA)")
        for id in [typedTab, freshA].compactMap({ $0 }) { h.browser.userClose(id) }
        // 3c（W184 G2 第三輪，查證 #5）：打網址開的（沒綁定的）一般分頁現在停在珍藏的網址＝切過去；珍藏自己開的分頁載入時轉址
        //     （加 www、加 query）之後，再按同一個珍藏＝還是切回那一頁（不再多開一個）。
        let pageC = URL(string: "https://example.com/c")!
        let typedC = h.browser.openBrowse(url: pageC, title: "C", origin: .typed)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 7 }
        let favoriteC = BrowserFavorite(id: UUID(), url: pageC, title: "C", faviconPNG: nil, order: 0)
        let toTyped = DMBrowserShelf.open(favorite: favoriteC, in: h.browser)
        let typedSwitch: Bool = openedID(typedC) != nil && switchedID(toTyped) == openedID(typedC)
        if let id = openedID(typedC) { h.browser.userClose(id) }
        let redirectFavorite = BrowserFavorite(id: UUID(), url: URL(string: "https://example.com/docs/edit")!, title: "Docs", faviconPNG: nil, order: 0)
        let firstTap = DMBrowserShelf.open(favorite: redirectFavorite, in: h.browser)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == 8 }
        let landed = URL(string: "https://www.example.com/docs/edit?tab=t.0")!
        h.host.pages.last?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: landed, stacked: 0))
        let redirected: Bool = openedID(firstTap).flatMap { id in h.browser.tabs.first { $0.id == id }?.pageURL } == landed
        let secondTap = DMBrowserShelf.open(favorite: redirectFavorite, in: h.browser)
        let boundSwitch: Bool = openedID(firstTap) != nil && switchedID(secondTap) == openedID(firstTap) && h.host.pages.count == 8
        check(typedSwitch && redirected && boundSwitch,
              "G3c (W184 G2 third round) a typed (unbound) general tab now on the favorite's address switches; a favorite's own tab that redirected while loading (added www and a query) is still its tab — the next tap switches back, no duplicate",
              "typed=\(toTyped) redirected=\(redirected) second=\(secondTap) pages=\(h.host.pages.count)")
        if let id = openedID(firstTap) { h.browser.userClose(id) }
        // 4. 一般分頁不是授權頁：不算敏感、不擋截圖；流程的分頁照舊（Pod、配對頁開著＝敏感；選中流程分頁＝擋截圖）。
        let browseOnScreen = h.browser.activeTab?.purpose == .browse && !h.browser.needsCaptureProtection
        let flowStillSensitive = h.browser.isSensitive
        if let pairing = h.browser.tabs.first(where: { $0.purpose == .chatgptPairing }) { h.browser.select(pairing.id) }
        let pairingShields = h.browser.needsCaptureProtection
        let browseNotSensitive: Bool = h.browser.tabs.filter { $0.purpose == .browse }.allSatisfy { !$0.isSensitive }
        let flowSensitive: Bool = h.browser.tabs.filter { $0.purpose.isFlow }.allSatisfy { $0.isSensitive }
        check(browseOnScreen && flowStillSensitive && pairingShields && browseNotSensitive && flowSensitive,
              "G4 general tabs are not authorisation pages: not sensitive, no capture block while one is in front — the flow tabs keep every protection (still sensitive; the pairing tab in front blocks capture)",
              "browse=\(browseOnScreen) sensitive=\(flowStillSensitive) pairing=\(pairingShields)")
        // 5. 流程不能用 open 開一般網頁；一般分頁不會被當成流程的授權頁接手（以起點認的只找流程分頁）。
        let flowOpen = h.browser.open(url: URL(string: "https://example.com/docs")!, purpose: .browse)
        let notByStart: Bool = h.browser.tab(start: URL(string: "https://example.com/docs")!) == nil
        let notValidated: Bool = DMBrowser.validatedStart(URL(string: "https://example.com")!, .browse) == nil
        let kinds: Bool = !DMBrowserPurpose.browse.isConnect && !DMBrowserPurpose.browse.isFlow && DMBrowserPurpose.chatgptLogin.isConnect
            && !DMBrowserPurpose.cloudflareLogin.isConnect
        check(!flowOpen && notByStart && notValidated && kinds,
              "G5 a flow cannot open a general page through open(url:purpose:); tab(start:) only finds flow tabs; general tabs are neither connect nor flow tabs")
        // 6. 分頁數的規則在 capacityChecks（W184 G2 修正 1：不自動關使用者的頁、不替使用者取消別的流程）。
        // 7. 網址卡在打字：頁面開好、換分頁都不把鍵盤搶回頁面；打完（keepsKeyboard＝false）換分頁＝鍵盤給頁面。
        let fieldStand = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        holder.addSubview(fieldStand)
        window.makeFirstResponder(fieldStand)
        let typing = window.firstResponder
        h.browser.keepsKeyboard = true
        if let pod = h.browser.tabs.first(where: { $0.kind == .pod }) { h.browser.select(pod.id) }
        let kept = window.firstResponder === typing
        h.browser.keepsKeyboard = false
        if let pairing = h.browser.tabs.first(where: { $0.purpose == .chatgptPairing }) { h.browser.select(pairing.id) }
        let pageTook = (window.firstResponder as? NSView).map { $0 === pairingPage.view || $0.isDescendant(of: pairingPage.view) } ?? false
        fieldStand.removeFromSuperview()
        check(kept && pageTook, "G7 while the address field is being typed in, switching tabs does not steal the keyboard; afterwards the page gets it again",
              "kept=\(kept) pageTook=\(pageTook)")
        h.browser.closeAll()
        window.contentView = nil

        // 8. 打網址或搜尋：網址（沒寫協定＝https、http 改 https）或搜尋；javascript:、file:、帶帳密＝不開。
        let R = DMBrowserBrowseInput.self
        let search = R.resolve("hello world", engine: .google)
        var credentials = URLComponents(string: "https://example.com")!
        credentials.user = "user"
        credentials.password = "pw"
        let withCredentials = credentials.string ?? ""
        let bare: Bool = R.resolve("example.com", engine: .google)?.absoluteString == "https://example.com"
        let upgradedHTTP: Bool = R.resolve("http://example.com/a?b=1", engine: .google)?.absoluteString == "https://example.com/a?b=1"
        let dangerous: Bool = R.resolve("javascript:alert(1)", engine: .google) == nil && R.resolve("file:///etc/hosts", engine: .google) == nil
        let refusedOthers: Bool = R.resolve(withCredentials, engine: .google) == nil && R.resolve("   ", engine: .google) == nil
        let searchOK: Bool = search?.scheme == "https" && search?.host == "www.google.com"
        let searchTitle: String? = search.map { R.title(for: "hello world", url: $0, engine: .google) }
        let hostTitle: String = R.title(for: "example.com", url: URL(string: "https://example.com")!, engine: .google)
        let strictStart: Bool = DMBrowser.browseStart(URL(string: "http://example.com")!) == nil
        check(bare && upgradedHTTP && dangerous && refusedOthers && searchOK && searchTitle == "搜尋：hello world" && hostTitle == "example.com" && strictStart,
              "G8 typing: an address (no scheme = https, http upgraded) or a search with the Browser's engine; javascript:, file: and user:password addresses never open",
              "search=\(String(describing: search))")

        // 9. 切換空間＝主視窗那一份 store 的 selectSpace（跟在側欄點圓點一樣）：書籤跟著換；珍藏是同一排（主視窗每個空間也是同一排）。
        let before = shelf.store.folders.map(\.name)
        let favoritesBefore = shelf.registry.favorites.map(\.id)
        let toWork = shelf.spaces.select(registryID: shelf.work)
        let after = shelf.store.folders.map(\.name)
        let afterMarks = shelf.store.folders.flatMap(\.bookmarks).map(\.id)
        let sameStore = shelf.spaces.store === shelf.store && shelf.spaces.isAdopted
        let favoritesAfter = shelf.registry.favorites.map(\.id)
        let toPrimary = shelf.spaces.select(registryID: shelf.primary)
        let back = shelf.store.folders.map(\.name)
        let foldersFollow: Bool = before == ["文件", "筆記"] && after == ["看板"] && afterMarks == [shelf.board.id] && back == before
        let backOnPrimary: Bool = shelf.store.selectedSpace.registryID == shelf.primary
        let favoritesSame: Bool = favoritesBefore == favoritesAfter && favoritesAfter.count == 3
        check(toWork && toPrimary && foldersFollow && sameStore && backOnPrimary && favoritesSame,
              "G9 switching space in the DM Browser switches the main window's own store (same object, same selectSpace as clicking the sidebar dot): the bookmarks follow; favorites are the one shared row (same as the main window, not per space)",
              "before=\(before) after=\(after) back=\(back) same=\(sameStore)")
        // 10. 主視窗還沒打開：私訊框自己留一份、照樣能切；主視窗的 store 交過來時照私訊框選的空間切一次，之後以主視窗為準。
        let alone = DMBrowserSpaces(registry: shelf.registry)
        let aloneStore = alone.store
        alone.select(registryID: shelf.work)
        let aloneSwitched = !alone.isAdopted && aloneStore.selectedSpace.registryID == shelf.work
        let mainStore = BrowserWorkSpaceStore(registry: shelf.registry)
        let mainStarted = mainStore.selectedSpace.registryID
        alone.adopt(mainStore)
        let chat = BrowserWorkSpaceStore(registry: BrowserTabRegistry(storageURL: nil))
        alone.adopt(chat)   // 別份分頁清單（聊天旁瀏覽器）不收
        let adoptedMain: Bool = alone.isAdopted && alone.store === mainStore
        let followed: Bool = mainStarted == shelf.primary && mainStore.selectedSpace.registryID == shelf.work
        check(aloneSwitched && adoptedMain && followed,
              "G10 before the main window exists the DM keeps its own store; when the main window's store arrives it follows the space chosen in the DM once, then the main window leads; a store over another tab list is never adopted",
              "alone=\(aloneSwitched) adopted=\(alone.isAdopted) main=\(String(describing: mainStore.selectedSpace.registryID))")
        // 10b（W184 G2 修正，GPT-6 5）：store 的整數 ID 是各自視窗的別名。GPT-6 的步驟：私訊框先用自己的 store 畫出選單（「工作」那一列）；
        //      期間刪掉一個空間、新增一個；主視窗的 store（新建，別名重排）接管——舊選單那一列的整數在新 store 指到別的空間。
        //      切換用那一列的 UUID 在當下的 store 找：切到的是「工作」，不是那個整數現在指的空間；已刪的空間＝不切、回 false。
        let other = Shelf()
        let oldSpaces = DMBrowserSpaces(registry: other.registry)
        let oldRow = oldSpaces.store.spaces.first { $0.registryID == other.work }
        other.registry.removeSpace(other.primary, closingTabs: true)
        let added = other.registry.addSpace(name: "新空間").id
        let newStore = BrowserWorkSpaceStore(registry: other.registry)
        if let fresh = newStore.spaces.first(where: { $0.registryID == added }) { newStore.selectSpace(fresh.id) }
        let newAlias = newStore.spaces.first { $0.registryID == other.work }?.id
        let oldAliasElsewhere = oldRow.flatMap { row in newStore.spaces.first { $0.id == row.id }?.registryID }
        oldSpaces.adopt(newStore)
        let onFresh = newStore.selectedSpace.registryID == added
        let pickedWork = oldRow?.registryID.map { oldSpaces.select(registryID: $0) } ?? false
        let movedToWork = newStore.selectedSpace.registryID == other.work
        let selectedBefore = newStore.selectedSpace.registryID
        let deletedRefused = !oldSpaces.select(registryID: other.primary) && newStore.selectedSpace.registryID == selectedBefore
        let aliasesDiffer: Bool = oldRow != nil && newAlias != nil && oldRow?.id != newAlias && oldAliasElsewhere != nil && oldAliasElsewhere != other.work
        check(aliasesDiffer && onFresh && pickedWork && movedToWork && deletedRefused,
              "G10b (W184 G2 fix, GPT-6 5) a space row drawn before the main window's store took over is switched by its UUID in the current store: after a space was deleted and another added, the row's old integer points to a different space in the new store, yet 工作 is picked; a deleted space is refused and nothing changes",
              "oldRow=\(String(describing: oldRow?.id)) new=\(String(describing: newAlias)) elsewhere=\(oldAliasElsewhere == added) picked=\(pickedWork) moved=\(movedToWork) deleted=\(deletedRefused)")
    }

    // MARK: - W184 G2 修正 1（第三輪）：分頁數——不自動關使用者的頁、不替使用者取消別的流程、流程分頁永遠有位子；載入失敗再按＝重新載入

    @MainActor final class Counter { var value = 0 }

    /// 第一次開頁失敗（像 CEF 還在啟動、等太久），之後照常開（假頁面）；記下每一次要開的網址（量重試開的是哪一頁）。
    @MainActor final class FlakyHost: GlobalDMWebPageHosting {
        var failNext = false
        var pages: [DMBrowserAcceptance.FakeWebPage] = []
        var requested: [URL] = []
        func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage {
            requested.append(url)
            if failNext {
                failNext = false
                throw BrowserSensitivePageError.busy
            }
            let page = DMBrowserAcceptance.FakeWebPage()
            page.report = onState
            pages.append(page)
            onState(GlobalDMWebPageState(loading: false, error: nil, committedURL: url, stacked: 0))
            return page
        }
    }

    @MainActor static func capacityChecks(_ check: Checker) async {
        // A. 滿載含一般頁：Pod＋配對頁＋一般頁。一般頁最多 maxBrowseTabs 個（第 5 個＝一句話）；滿了之後流程要開授權頁、又沒有已完成的
        //    ＝暫時多開一格（W184 G2 第三輪：不退到 OS 瀏覽器），一般頁一個都不關、流程一個都不取消。
        let h = Harness("w184g2cap")
        let (window, holder) = DMBrowserAcceptance.windowed("w184g2cap")
        h.browser.release(h.surface)
        h.browser.claim(holder)
        let cancels = Counter()
        _ = h.browser.openPod(purpose: .chatgptDeveloper, onCancel: { cancels.value += 1 })
        let pairing = FakePage()
        h.browser.adoptPopup(pairing, key: 60, purpose: .chatgptPairing, expectedHost: nil, onCancel: { cancels.value += 1 })
        var browseIDs: [UUID] = []
        var fifth: DMBrowserBrowseResult?
        for n in 1...5 {
            let result = h.browser.openBrowse(url: URL(string: "https://example.com/cap\(n)")!, title: "頁 \(n)")
            if let id = openedID(result) { browseIDs.append(id) } else { fifth = result }
        }
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == DMBrowser.maxBrowseTabs }
        let capped: Bool = browseIDs.count == DMBrowser.maxBrowseTabs && fifth == .refused(.browseFull) && h.browser.tabs.count == DMBrowser.maxTabs
        // 授權頁從 HandsSetup 的正式入口開（同正式的呼叫端）：開在私訊框（多開一格），退路（OS 瀏覽器）一次都沒走。
        let login1 = DMBrowserAcceptance.loginURL("W184G2CAP1")
        let fellBack = Counter()
        let inBox = HandsSetup.openLoginPage(login1, onCancel: { cancels.value += 1 }, browser: h.browser, fallback: { _, _ in fellBack.value += 1 })
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == DMBrowser.maxBrowseTabs + 1 }
        let overflowOpened: Bool = inBox && fellBack.value == 0 && h.browser.tab(start: login1) != nil && h.browser.tabs.count == DMBrowser.maxTabs + 1
        let browseAlive: Bool = browseIDs.allSatisfy { id in h.browser.tabs.contains { $0.id == id } } && h.host.pages.allSatisfy { $0.closes == 0 }
        let flowsAlive: Bool = cancels.value == 0 && pairing.closes == 0 && h.browser.tabs.filter(\.purpose.isFlow).count == 3
        check(capped && overflowOpened && browseAlive && flowsAlive,
              "G6 (W184 G2 fix, third round) full with general tabs: general tabs stop at \(DMBrowser.maxBrowseTabs) (the 5th gets one sentence); an authorisation page still opens in the DM box (one tab over the limit for the short flow) — never the OS browser fallback — no general page closed, no flow cancelled",
              "capped=\(capped) fifth=\(String(describing: fifth)) inBox=\(inBox) fellBack=\(fellBack.value) tabs=\(h.browser.tabs.count) browse=\(browseAlive) flows=\(flowsAlive)")
        // 完成的配對頁（不在最前面）先收（頁面早就關了）：下一張授權頁照開、總數不再往上長，一般頁照樣不動。
        h.browser.markDone(purpose: .chatgptPairing)
        if let first = browseIDs.first { h.browser.select(first) }
        let login2 = DMBrowserAcceptance.loginURL("W184G2CAP2")
        let opened = h.browser.open(url: login2, purpose: .cloudflareLogin)
        _ = await DMBrowserAcceptance.waitUntil(5) { h.host.pages.count == DMBrowser.maxBrowseTabs + 2 }
        let doneGone: Bool = !h.browser.tabs.contains { $0.kind == .popup(60) } && h.browser.tabs.count == DMBrowser.maxTabs + 1
        let browseKept: Bool = browseIDs.allSatisfy { id in h.browser.tabs.contains { $0.id == id } }
            && h.host.pages.prefix(DMBrowser.maxBrowseTabs).allSatisfy { $0.closes == 0 }
        // 絕不收目前在看的分頁：授權頁標完成、正在看它（最前面）；又有流程要開＝不收它，新的照樣多開。
        h.browser.loginPage(login1, .done)
        if let tab = h.browser.tab(start: login1) { h.browser.select(tab.id) }
        let activeDone = h.browser.activeTab?.done == true
        let login3 = DMBrowserAcceptance.loginURL("W184G2CAP3")
        let openedBeside = h.browser.open(url: login3, purpose: .cloudflareLogin) && h.browser.tab(start: login1) != nil
            && h.browser.tab(start: login3) != nil
        check(opened && doneGone && browseKept && activeDone && openedBeside && cancels.value == 0,
              "G6a a finished tab that is not in front makes room first (its page was already closed) and the general pages stay; the finished tab being looked at is never closed — the next flow page opens beside it",
              "opened=\(opened) doneGone=\(doneGone) kept=\(browseKept) activeDone=\(activeDone) beside=\(openedBeside) tabs=\(h.browser.tabs.count)")
        h.browser.closeAll()
        window.contentView = nil

        // B. 滿載全是流程：五張授權頁＋Pod。Pod 再開配對頁 popup＝照樣收進分頁（多開），不替使用者取消別的流程；網頁一直開新視窗，
        //    到了硬上限（maxTabs＋popupOverflow）才不開：這一頁關掉、Browser 上一句話、呼叫端收到 onFull（連線中＝卡片說一句）。
        let f = Harness("w184g2flows")
        let flowCancels = Counter(), full = Counter()
        for k in 1...5 { f.browser.open(url: DMBrowserAcceptance.loginURL("W184G2F\(k)"), purpose: .cloudflareLogin, onCancel: { flowCancels.value += 1 }) }
        _ = f.browser.openPod(purpose: .chatgptDeveloper, onCancel: { flowCancels.value += 1 })
        _ = await DMBrowserAcceptance.waitUntil(5) { f.host.pages.count == 5 }
        var popups: [FakePage] = []
        for key in 61...64 {
            let popup = FakePage()
            popups.append(popup)
            f.browser.adoptPopup(popup, key: key, purpose: .chatgptPairing, expectedHost: nil, onCancel: { flowCancels.value += 1 }, onFull: { full.value += 1 })
        }
        let popupsAdopted: Bool = popups.allSatisfy { $0.closes == 0 } && full.value == 0
            && f.browser.tabs.count == DMBrowser.maxTabs + DMBrowser.popupOverflow && f.browser.notice == nil
        let extra = FakePage()
        f.browser.adoptPopup(extra, key: 65, purpose: .chatgptLogin, expectedHost: nil, onFull: { full.value += 1 })
        let capRefused: Bool = extra.closes == 1 && full.value == 1 && !f.browser.tabs.contains { $0.kind == .popup(65) }
            && f.browser.notice == DMBrowser.popupRefusedText
        let othersIntact: Bool = flowCancels.value == 0 && f.host.pages.allSatisfy { $0.closes == 0 } && popups.allSatisfy { $0.closes == 0 }
        f.browser.clearNotice()
        // Pod：全是流程分頁也照樣開（先確認 Pod 的頁建得起來）；［連線］的新視窗到了硬上限＝卡片那一句話的文字（「先關掉幾個分頁」）。
        f.browser.close(purpose: .chatgptDeveloper)
        let podsBefore = f.podPages.get().count
        let podOpened: Bool = f.browser.openPod(purpose: .chatgptDeveloper) && f.podPages.get().count == podsBefore + 1
        let cardLine: Bool = HandsConnectFlow.invalidationText("browser_full").contains("先關掉幾個分頁")
        check(popupsAdopted && capRefused && othersIntact && podOpened && cardLine && f.browser.notice == nil,
              "G6b (W184 G2 fix, third round) full with flow tabs only: new pairing popups are still taken in (the flow gets its tab), no other flow cancelled; only past the hard limit (\(DMBrowser.maxTabs + DMBrowser.popupOverflow) tabs, a page opening window after window) a popup is closed — the Browser says one sentence and the caller gets onFull (the connect card's line); the Pod tab opens even when every tab is a flow",
              "adopted=\(popupsAdopted) refused=\(capRefused) others=\(othersIntact) pod=\(podOpened) card=\(cardLine) cancels=\(flowCancels.value) tabs=\(f.browser.tabs.count)")
        f.browser.closeAll()

        // G13（查證 #6、第三輪 #7）：書籤的分頁上次沒開成（CEF 還在忙丟錯、或載入失敗）＝再按一次就重新載入（舊頁面關掉、錯誤清掉），
        //      開的是這個分頁自己失敗的那個網址。
        let flaky = FlakyHost()
        let store = GlobalDMStore(defaults: UserDefaults(suiteName: "w184g2.reload.\(UUID().uuidString)") ?? .standard,
                                  chatGPTAllowed: { true }, directKeys: true)
        let browser = DMBrowser(store: store, openBox: {}, pageHost: flaky, podPage: { FakePage() }, windowShown: { $0.isVisible })
        let docs = URL(string: "https://example.com/docs")!
        let bookmark = BrowserWorkSpaceStore.Bookmark(id: UUID(), title: "文件", url: docs.absoluteString)
        flaky.failNext = true
        let first = DMBrowserShelf.open(bookmark: bookmark, in: browser)
        _ = await DMBrowserAcceptance.waitUntil(3) { browser.activeTab?.problem != nil }
        let tabID = openedID(first)
        let failed: Bool = tabID != nil && browser.activeTab?.problem != nil && tabID.map { browser.page(for: $0) == nil } == true
        let second = DMBrowserShelf.open(bookmark: bookmark, in: browser)
        _ = await DMBrowserAcceptance.waitUntil(3) { tabID.map { browser.page(for: $0) != nil } == true }
        let retried: Bool = tabID != nil && second == .reloaded(tabID!) && browser.activeTab?.problem == nil && browser.tabs.count == 1 && flaky.pages.count == 1
        flaky.pages.last?.report?(GlobalDMWebPageState(loading: false, error: "連不上", committedURL: nil, stacked: 0))
        let errored = browser.activeTab?.problem != nil
        let third = DMBrowserShelf.open(bookmark: bookmark, in: browser)
        _ = await DMBrowserAcceptance.waitUntil(3) { flaky.pages.count == 2 && browser.activeTab?.problem == nil }
        let reopened: Bool = tabID != nil && third == .reloaded(tabID!) && flaky.pages.first?.closes == 1 && flaky.pages.count == 2 && browser.tabs.count == 1
        let fine = DMBrowserShelf.open(bookmark: bookmark, in: browser)
        let startRetries: Bool = flaky.requested == [docs, docs, docs]
        check(failed && retried && errored && reopened && tabID != nil && fine == .switched(tabID!) && startRetries,
              "G13 (W184 G2 fix, 查證 #6) a bookmark tab that failed (page never built, or load error before it ever landed) is reloaded at its start when tapped again — the old page closed, the error cleared, one tab; a healthy one just switches",
              "first=\(first) second=\(second) third=\(third) fine=\(fine) requested=\(flaky.requested.map { $0.path })")
        // 第三輪（查證 #7）：分頁在頁內走到別的網址之後壞掉（渲染程序結束：錯誤＋最後停在的網址）＝再按書籤，重試開的是它自己壞掉的
        // 那一頁（/status），不是它的起點；剛好是那個網址的珍藏＝那個分頁是書籤的，不拿來比（開珍藏自己的新分頁，不把書籤的分頁重新載入成別頁）。
        let status = URL(string: "https://example.com/status")!
        flaky.pages.last?.report?(GlobalDMWebPageState(loading: false, error: nil, committedURL: status, stacked: 0))
        flaky.pages.last?.report?(GlobalDMWebPageState(loading: false, error: "渲染程序結束", committedURL: status, stacked: 0))
        let crashed: Bool = browser.activeTab?.problem != nil && browser.activeTab?.pageURL == status
        let statusFavorite = BrowserFavorite(id: UUID(), url: status, title: "Status", faviconPNG: nil, order: 0)
        let viaFavorite = DMBrowserShelf.open(favorite: statusFavorite, in: browser)
        _ = await DMBrowserAcceptance.waitUntil(3) { flaky.requested.count == 4 }
        let favoriteOwnTab: Bool = openedID(viaFavorite) != nil && openedID(viaFavorite) != tabID && flaky.requested.last == status
        if let fresh = openedID(viaFavorite) { browser.userClose(fresh) }
        if let tabID { browser.select(tabID) }
        let retry = DMBrowserShelf.open(bookmark: bookmark, in: browser)
        _ = await DMBrowserAcceptance.waitUntil(3) { flaky.requested.count == 5 }
        let ownURL: Bool = tabID != nil && retry == .reloaded(tabID!) && flaky.requested.last == status && browser.activeTab?.pageURL == status
        check(crashed && favoriteOwnTab && ownURL,
              "G13b (W184 G2 third round, 查證 #7) a tab that went to another page and then broke retries its own failed page (not its start, not another tab's address); a favorite with that address does not grab the bookmark's tab — it opens its own",
              "crashed=\(crashed) favorite=\(viaFavorite) retry=\(retry) requested=\(flaky.requested.map { $0.path })")
        browser.closeAll()
    }

    // MARK: - W184 G2 修正 2、8、9；G2c／G2d：真的滑鼠——卡片的按鈕按得到、不被側欄蓋；網頁左邊不叫出側欄；側欄每一格真的做它的事

    /// 按得到的畫面：無邊框視窗放在螢幕外、排在畫面上（不透明、接滑鼠），自測送真的滑鼠事件（window.sendEvent，跟使用者點的同一條路）。
    @MainActor final class Clickable {
        let window: NSWindow
        let host: NSView

        /// keyable＝用私訊框自己的面板（GlobalDMPanel，不啟動 App 也能成為 key 視窗）：量「私訊框是 key 視窗」時的按鍵。
        init<V: View>(_ view: V, size: CGSize, keyable: Bool = false) {
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light)))
            host.frame = NSRect(origin: .zero, size: size)
            let rect = NSRect(x: -20_000, y: -19_000, width: size.width, height: size.height)
            let window: NSWindow = keyable
                ? GlobalDMPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            if keyable { window.makeKey() }
            self.window = window
            self.host = host
        }

        func settle(_ rounds: Int = 6) async {
            for _ in 0..<rounds {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }

        /// 真的按一下：按下交給視窗；放開先排進 App 的事件佇列（同使用者點的路）——按到的東西若自己開追蹤迴圈從佇列等放開
        /// （例如捲軸 NSScroller.trackKnob），放開已經在那裡，不會卡住自測；沒被拿走＝App 的事件迴圈照常送到視窗。
        func click(_ point: NSPoint) async {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            // 沒被追蹤迴圈拿走＝當下收回來、照舊 50ms 之後直接交給視窗（整合分支上看到：放開經 App 的事件迴圈送、跟按下擠在同一輪，
            // SwiftUI 的「點一下」偶爾沒成立——R8 分頁列、S6 珍藏沒反應）。
            let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date.distantPast, inMode: .default, dequeue: true)
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let pending { window.sendEvent(pending) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await settle(3)
        }

        func frame(_ key: String) -> CGRect? {
            DMBrowserPhoneAcceptance.views(DMFrameProbeView.self, in: host).first { $0.key == key }.map { $0.convert($0.bounds, to: nil) }
        }

        func center(_ key: String) -> NSPoint? { frame(key).map { NSPoint(x: $0.midX, y: $0.midY) } }

        var reveal: DMBrowserBarReveal? { DMBrowserPhoneAcceptance.views(DMBrowserBarAnchorView.self, in: host).first?.reveal }
        /// 畫面現在是不是在打字（讀 Esc 錨拿到的最新值；錨一直在，nil＝沒在打）：address＝頂列網址欄、search＝置中搜尋框。
        var panelState: DMBrowserPanel? { DMBrowserPhoneAcceptance.views(DMBrowserPanelEscapeAnchor.AnchorView.self, in: host).first?.panel }
        /// 側欄的命中區（滑出、固定著＝登記著、網頁讓位）：貼左緣、寬＝側欄寬的那一層。
        var sidebarActive: Bool {
            let width = DMBrowserPhone.sidebarWidth(for: host.bounds.width)
            return DMBrowserPhoneAcceptance.views(BrowserChromeHitLayer.LayerView.self, in: host).contains { layer in
                guard layer.isActive, abs(layer.frame.width - width) < 1 else { return false }
                return layer.convert(layer.bounds, to: nil).minX < 1
            }
        }
        /// 頂列畫出來了沒（量尺開著時）。
        var toolbarDrawn: Bool { frame("bar.panel.tools") != nil || frame("bar.panel.folded") != nil }
        var hasEscapeAnchor: Bool { !DMBrowserPhoneAcceptance.views(DMBrowserPanelEscapeAnchor.AnchorView.self, in: host).isEmpty }
        var container: DMBrowserPageContainer? { DMBrowserPhoneAcceptance.views(DMBrowserPageContainer.self, in: host).first }

        /// 頁面容器在這一點給不給網頁（nil＝讓位給浮在上面的東西）。
        func pageTakes(_ point: NSPoint) -> Bool {
            guard let container, let superview = container.superview else { return false }
            return container.hitTest(superview.convert(point, from: nil)) != nil
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    @MainActor final class TapBox { var dismiss = 0, continued = 0 }

    /// 珍藏那一排第 index 格的正中間（BrowserFavoritesStrip：左右各 8、五格一排、格距 6；量尺是整排）。
    @MainActor static func favoriteTile(_ screen: Clickable, index: Int) -> NSPoint? {
        guard let strip = screen.frame("side.favorites") else { return nil }
        let inset = BrowserSidebarMetrics.rowHorizontalPadding
        let gap = BrowserFavoritesStrip.tileGap
        let count = CGFloat(BrowserFavoritesStrip.visibleCount)
        let tile = max(24, (strip.width - 2 * inset - (count - 1) * gap) / count)
        return NSPoint(x: strip.minX + inset + CGFloat(index) * (tile + gap) + tile / 2, y: strip.midY)
    }

    @MainActor static func pointerChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        // C1（GPT-6 3；查證 #1、#2、#7）：配對碼卡片、側欄收著：指標從收著的狀態移到右上「取消」正中間——側欄不滑出、卡片與鈕不動；
        //    按下去真的叫到 tatwo.dm.handsConnect.cancel（取消）。
        let phone = Phone("pointer")
        phone.browser.adoptPopup(EvidencePage("連上 TATWO（假配對頁）"), key: 95, purpose: .chatgptPairing, expectedHost: nil)
        phone.box.card = .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date().addingTimeInterval(272), attemptsLeft: 5,
                                                          callbackHost: "chatgpt.com", pairingCode: "73215946", popup: true, surface: 95))
        phone.presenter.show()
        let taps = TapBox()
        let actions = HandsConnectCardActions(dismiss: { taps.dismiss += 1 }, continueAfterUser: { taps.continued += 1 })
        let cancelScreen = Clickable(phone.pane(probes: true).environment(\.dmConnectCardActions, actions), size: size)
        await cancelScreen.settle()
        if let chip = cancelScreen.frame("card.dismiss"), let reveal = cancelScreen.reveal {
            let point = NSPoint(x: chip.midX, y: chip.midY)
            reveal.evaluate(windowPoint: point)
            await cancelScreen.settle()
            let still: Bool = !reveal.isRevealed && !cancelScreen.sidebarActive
                && cancelScreen.frame("card.dismiss").map { abs($0.midX - chip.midX) < 1 && abs($0.midY - chip.midY) < 1 } == true
            await cancelScreen.click(point)
            check(still && taps.dismiss == 1,
                  "C1 (W184 G2 fix) pointer from the hidden-sidebar state onto the centre of the card's top-right 取消: the sidebar stays hidden, the chip does not move, and pressing it really fires tatwo.dm.handsConnect.cancel",
                  "chip=\(chip) still=\(still) taps=\(taps.dismiss)")
        } else {
            check(false, "C1 the card's 取消 chip and the Browser's reveal anchor are drawn")
        }
        cancelScreen.close()
        // C2（W184 G2c／G2d）：「輪到你」卡：從左緣叫出側欄、指標往右移到卡片左邊的「取消」——側欄滑出了但停在卡片上面，
        //    按「取消」、「繼續」右半邊都真的按到卡片（沒被側欄擋住、卡片不動）。
        phone.box.card = .waitingUser(HandsConnectFlow.riskAckCardText, continuable: true)
        let turnScreen = Clickable(phone.pane(probes: true).environment(\.dmConnectCardActions, actions), size: size)
        await turnScreen.settle()
        if let cancel = turnScreen.frame("card.turnCancel"), let button = turnScreen.frame("card.continue"), let reveal = turnScreen.reveal {
            reveal.evaluate(windowPoint: NSPoint(x: 10, y: cancel.midY))
            let out = reveal.isRevealed
            let point = NSPoint(x: cancel.midX, y: cancel.midY)
            reveal.evaluate(windowPoint: point)
            await turnScreen.settle()
            let sidebarOut: Bool = out && turnScreen.sidebarActive && turnScreen.frame("side.panel").map { !$0.contains(point) } == true
            let still: Bool = turnScreen.frame("card.turnCancel").map { abs($0.midX - cancel.midX) < 1 } == true
            await turnScreen.click(point)
            await turnScreen.click(NSPoint(x: button.maxX - 8, y: button.midY))
            check(sidebarOut && still && taps.dismiss == 2 && taps.continued == 1,
                  "C2 (W184 G2d) the 「輪到你」 card with the full-height sidebar out: the sidebar stops above the card, so the pointer on the card's left 取消 is not on the sidebar; pressing 取消 and the right half of 繼續 both really reach the card",
                  "out=\(sidebarOut) still=\(still) dismiss=\(taps.dismiss) continued=\(taps.continued)")
        } else {
            check(false, "C2 the 「輪到你」 card's 取消、繼續 and the reveal anchor are drawn")
        }
        turnScreen.close()
        phone.presenter.hide()

        // R7（W184 G2d）：網頁左邊的內容（左緣 18 以外）不會叫出側欄——點下去照樣給網頁；左緣叫出來之後側欄上是側欄的；
        //    往右回到網頁（離開側欄右緣再 30）就收、那一點又給網頁。
        let edge = Phone("edge")
        _ = edge.browser.openPod(purpose: .chatgptDeveloper)
        let pageScreen = Clickable(edge.pane(), size: size)
        await pageScreen.settle()
        if let reveal = pageScreen.reveal, pageScreen.container != nil {
            reveal.closeDelay = 0   // 延遲在 B2 量過；這裡量位置
            let content = NSPoint(x: 40, y: 305)
            let onSidebar = NSPoint(x: 150, y: 305)
            reveal.evaluate(windowPoint: content)
            await pageScreen.settle()
            let quiet = !reveal.isRevealed && pageScreen.pageTakes(content) && pageScreen.pageTakes(onSidebar)
            reveal.evaluate(windowPoint: NSPoint(x: 10, y: 305))
            await pageScreen.settle()
            let fromEdge = reveal.isRevealed
            reveal.evaluate(windowPoint: onSidebar)
            await pageScreen.settle()
            let sidebarOwns = reveal.isRevealed && !pageScreen.pageTakes(onSidebar)
            reveal.evaluate(windowPoint: NSPoint(x: 330, y: 305))
            await pageScreen.settle()
            let back = !reveal.isRevealed && pageScreen.pageTakes(onSidebar)
            check(quiet && fromEdge && sidebarOwns && back,
                  "R7 (W184 G2d) the page's left part never brings the sidebar out — clicks there go to the page; only the left 18pt does (no handle drawn), the sidebar then owns its area until the pointer goes back over the page",
                  "quiet=\(quiet) edge=\(fromEdge) sidebar=\(sidebarOwns) back=\(back)")
        } else {
            check(false, "R7 the Browser's reveal anchor and page container are drawn")
        }
        pageScreen.close()
        edge.browser.closeAll()

        // R8（W184 G2d）：用真的滑鼠按側欄的每一格（主視窗 Browser space 的元件）：珍藏＝開這個珍藏自己的新分頁、資料夾＝展開、書籤＝開這個書籤的
        //    新分頁（Pod／登入視窗都不動）、新分頁＝空白分頁＋置中搜尋框拿到游標、分頁列＝換到那一頁、×＝關掉那一頁、空間圓點＝切到那個空間（書籤跟著換）。
        let pressPhone = Phone("press")
        let page = EvidencePage("ChatGPT 登入（假頁面）")
        pressPhone.browser.adoptPopup(page, key: 96, purpose: .chatgptLogin, expectedHost: nil)
        let loginID = pressPhone.browser.activeTab?.id
        let press = Clickable(pressPhone.pane(.sidebar, probes: true), size: size, keyable: true)
        await press.settle()
        var did: [String] = []
        let flowsBefore = pressPhone.browser.tabs.filter(\.purpose.isFlow).map(\.id)
        if let tile = favoriteTile(press, index: 0) {
            await press.click(tile)
            let tab = pressPhone.browser.activeTab
            did.append("favorite=\(tab?.purpose == .browse && tab?.origin == .favorite(pressPhone.shelf.favorite.id) ? "new" : "none")")
        }
        await press.settle(3)
        if let folder = pressPhone.shelf.store.folders.first, let row = press.center("side.folder.\(folder.id.uuidString)") {
            let before = press.frame("side.bookmark.\(pressPhone.shelf.docs.id.uuidString)") != nil
            await press.click(row)
            let after = press.frame("side.bookmark.\(pressPhone.shelf.docs.id.uuidString)") != nil
            did.append("folder=\(before != after)")
        }
        if let bookmark = press.center("side.bookmark.\(pressPhone.shelf.docs.id.uuidString)") {
            await press.click(bookmark)
            let tab = pressPhone.browser.activeTab
            did.append("bookmark=\(tab?.purpose == .browse && tab?.origin == .bookmark(pressPhone.shelf.docs.id) ? "new" : "none")")
        }
        await press.settle(3)
        let flowsKept: Bool = pressPhone.browser.tabs.filter(\.purpose.isFlow).map(\.id) == flowsBefore && page.closes == 0
        if let loginID, let row = press.center("side.tab.\(loginID.uuidString)") {
            await press.click(row)
            did.append("row=\(pressPhone.browser.activeID == loginID)")
        }
        if let plus = press.center("side.newTab") {
            let before = pressPhone.browser.tabs.count
            await press.click(plus)
            _ = await DMBrowserAcceptance.waitUntil(2) { press.panelState == .search }
            let blank = pressPhone.browser.activeTab?.isBlank == true && pressPhone.browser.tabs.count == before + 1
            did.append("newTab=\(blank ? "blank" : "none")/\(press.panelState?.rawValue ?? "nil")")
            _ = DMBrowserPanelEscape.closePanel(in: press.window)
            await press.settle(3)
            if let blankID = pressPhone.browser.activeID, blank, let close = press.center("side.close.\(blankID.uuidString)") {
                let count = pressPhone.browser.tabs.count
                await press.click(close)
                did.append("close=\(pressPhone.browser.tabs.count == count - 1 && !pressPhone.browser.tabs.contains { $0.id == blankID })")
            }
        }
        await press.settle(3)
        let foldersBefore = pressPhone.shelf.store.folders.map(\.name)
        if let work = press.center("side.space.\(pressPhone.shelf.work.uuidString)") {
            await press.click(work)
            let switched = pressPhone.shelf.store.selectedSpace.registryID == pressPhone.shelf.work
            did.append("space=\(switched && pressPhone.shelf.store.folders.map(\.name) == ["看板"] && foldersBefore == ["文件", "筆記"])")
        }
        check(did == ["favorite=new", "folder=true", "bookmark=new", "row=true", "newTab=blank/search", "close=true", "space=true"] && flowsKept,
              "R8 (W184 G2d) pressing each part of the Browser space sidebar with a real mouse: a favorite and a bookmark (after opening its folder) each open their own NEW general tab (the login tab untouched), a tab row switches to it, 新分頁 opens a blank tab with the caret in the centered search box, its × closes it, a space dot switches the space (the bookmarks follow)",
              "\(did.joined(separator: " ")) flowsKept=\(flowsKept)")
        press.close()
        pressPhone.browser.closeAll()

        // R12（W184 G2d）：頂列的網址欄在打字＝頂列不收（指標移到網頁上也一樣）；收起輸入的當下照滑鼠位置重算：
        //      指標在網頁上＝頂列收起；指標在頂列上＝頂列還在。
        let hover = Phone("hover")
        _ = hover.browser.openPod(purpose: .chatgptDeveloper)
        hover.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        let hoverScreen = Clickable(hover.pane(probes: true), size: size, keyable: true)
        await hoverScreen.settle()
        if let reveal = hoverScreen.reveal {
            var typing = false, stays = false, hides = false, keeps = false
            reveal.evaluate(windowPoint: NSPoint(x: 300, y: size.height - 6))
            await hoverScreen.settle(3)
            if let nav = hoverScreen.frame("bar.nav") {
                await hoverScreen.click(NSPoint(x: nav.minX + 8 + 108 + 40, y: nav.midY))
                typing = hoverScreen.panelState == .address && reveal.holds
                reveal.evaluate(windowPoint: NSPoint(x: 330, y: 305))   // 指標移到網頁上
                await hoverScreen.settle(3)
                stays = hoverScreen.panelState == .address && hoverScreen.toolbarDrawn
                _ = DMBrowserPanelEscape.closePanel(in: hoverScreen.window)   // 收起輸入（指標在網頁上）
                await hoverScreen.settle(10)   // 頂列淡出 0.12 秒之後才從畫面拿掉
                hides = hoverScreen.panelState == nil && !reveal.toolbarRevealed && !hoverScreen.toolbarDrawn
            }
            reveal.evaluate(windowPoint: NSPoint(x: 300, y: size.height - 6))
            await hoverScreen.settle(3)
            if let nav = hoverScreen.frame("bar.nav") {
                await hoverScreen.click(NSPoint(x: nav.minX + 8 + 108 + 40, y: nav.midY))
                reveal.evaluate(windowPoint: NSPoint(x: 300, y: size.height - 30))   // 指標在頂列上
                _ = DMBrowserPanelEscape.closePanel(in: hoverScreen.window)
                await hoverScreen.settle(10)
                keeps = hoverScreen.panelState == nil && reveal.toolbarRevealed && hoverScreen.toolbarDrawn
            }
            check(typing && stays && hides && keeps,
                  "R12 (W184 G2d) while typing in the toolbar's address the toolbar stays even with the pointer over the page; when typing ends it follows the pointer: over the page = the toolbar goes away, on the toolbar = it stays",
                  "typing=\(typing) stays=\(stays) hides=\(hides) keeps=\(keeps)")
        } else {
            check(false, "R12 the Browser's reveal anchor is drawn")
        }
        hoverScreen.close()
        hover.browser.closeAll()
    }

    // MARK: - W184 G2 修正 3、4；G2c：流程叫到前面收起輸入、Esc 只收網址輸入

    @MainActor static func pressEscape(in window: NSWindow) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// 這個視窗收到幾個 Esc（證明事件真的走到路由，不是沒送到）、其中幾個被放行（交給網頁或輸入法；沒放行＝路由自己用掉）。
    @MainActor final class EscTally { var seen = 0, passed = 0 }

    /// 自測的「私訊框 Esc」：照 GlobalDMPanelController 的本機 keyDown 監聽，只看這個視窗、走同一條 routeEscape。
    @MainActor static func escapeRoute(for window: NSWindow, store: GlobalDMStore, form: GlobalDMForm, tally: EscTally) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 路由回傳的不是同一個事件就是 nil：在 MainActor 上只算「放不放行」（NSEvent 不是 Sendable，不從 assumeIsolated 傳出來）。
            let passes = MainActor.assumeIsolated { () -> Bool in
                guard event.window === window else { return true }
                let routed = GlobalDMPanelController.routeEscape(event, window: window, floating: nil, store: store, form: form)
                if event.keyCode == 53 {
                    tally.seen += 1
                    if routed != nil { tally.passed += 1 }
                }
                return routed != nil
            }
            return passes ? event : nil
        }
    }

    /// 一個 Esc 場景：框開著（單欄＝Browser 那一頁、內橫＝右欄），沒有分頁＝置中的搜尋框在打字（W184 G2d）；真的按 presses 次 Esc，每按一次記
    /// 「輸入、框開著沒、放行／收到」。before＝按之前對畫面做的事（例如輸入法正在組字），between＝第一下之後做的事。
    /// 框是私訊框自己的面板（能拿鍵盤：搜尋框的游標要進得去）。
    @MainActor static func escapeScene(_ name: String, form: GlobalDMForm, beside: Bool, panel: DMBrowserPanel, presses: Int,
                                       before: ((Clickable) -> Void)? = nil, between: ((Clickable) -> Void)? = nil) async -> [String] {
        let phone = Phone(name)
        phone.store.isOpen = true
        if beside {
            phone.store.browsesBeside = true
            phone.store.isBrowsingBeside = true
        } else {
            phone.store.showBrowser()
        }
        let screen = Clickable(phone.pane(.sidebar, panel: panel), size: CGSize(width: 466, height: 610), keyable: true)
        await screen.settle()
        _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState != nil }
        before?(screen)
        await screen.settle(3)
        let tally = EscTally()
        let monitor = escapeRoute(for: screen.window, store: phone.store, form: form, tally: tally)
        var steps = ["open=\(screen.panelState?.rawValue ?? "nil")"]
        for press in 0..<presses {
            if press == 1 { between?(screen) }
            await pressEscape(in: screen.window)
            await screen.settle(3)
            steps.append("panel=\(screen.panelState?.rawValue ?? "nil") box=\(phone.store.isOpen) passed=\(tally.passed)/\(tally.seen)")
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        screen.close()
        return steps
    }

    @MainActor static func panelChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        // G11（查證 #4；W184 G2d）：在打字（沒分頁＝置中的搜尋框；有網頁＝頂列的網址欄）、輸入拿著鍵盤；流程把授權頁叫到前面＝輸入收起來、鍵盤放掉。
        var raised: [String] = []
        for (name, panel) in [("raise-search", DMBrowserPanel.search), ("raise-address", DMBrowserPanel.address)] {
            let raise = Phone(name)
            if panel == .address {
                _ = raise.browser.openPod(purpose: .chatgptDeveloper)
                raise.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
            }
            let screen = Clickable(raise.pane(panel: panel), size: size, keyable: true)
            await screen.settle()
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == panel }
            let typing = DMBrowserPanelEscape.openPanel(in: screen.window) == panel && screen.panelState == panel && raise.browser.keepsKeyboard
            let login = DMBrowserAcceptance.loginURL("W184G2D" + name.uppercased().replacingOccurrences(of: "-", with: ""))
            _ = raise.browser.open(url: login, purpose: .cloudflareLogin)
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == nil }
            let closed: Bool = screen.panelState == nil && DMBrowserPanelEscape.openPanel(in: screen.window) == nil && !raise.browser.keepsKeyboard
                && raise.browser.activeTab?.startURL == login
            raised.append("\(panel.rawValue)=\(typing && closed)")
            screen.close()
            raise.browser.closeAll()
        }
        check(raised == ["search=true", "address=true"],
              "G11 (W184 G2 fix, 查證 #4; G2d) a flow bringing its authorisation / pairing page to the front ends typing — in the centered search box and in the toolbar's address — and lets go of the keyboard it held",
              raised.joined(separator: " "))

        // G12（GPT-6 4；查證 #5、#8；G2c／G2d）：真的 Esc 事件（排進 App 的事件佇列，走私訊框同一條 Esc 路由）：在打字的時候
        //   第一下只收輸入（框還開著、事件用掉）；第二下（沒在打）＝照原本的路：內橫＝收框；單欄＝放行給網頁。
        let duoSearch = await escapeScene("esc-duo-search", form: .innerLandscape, beside: true, panel: .search, presses: 2)
        let singleSearch = await escapeScene("esc-single-search", form: .outerPortrait, beside: false, panel: .search, presses: 2)
        let duoOK: Bool = duoSearch == ["open=search", "panel=nil box=true passed=0/1", "panel=nil box=false passed=0/2"]
        let singleOK: Bool = singleSearch == ["open=search", "panel=nil box=true passed=0/1", "panel=nil box=true passed=1/2"]
        check(duoOK && singleOK,
              "G12 (W184 G2 fix, G2c, G2d) a real Esc key event through the DM box's Esc route while typing in the Browser, inner landscape and single column: the first Esc ends typing only (box open, event used); the second goes the old way (inner landscape closes the box, single column passes it to the page and the box stays)",
              "duo=\(duoSearch) single=\(singleSearch)")
        // G14（第三輪 #4）：順序用行為量，不只看原始碼——
        //   輸入法正在組字（搜尋框的字還沒選完）＝Esc 交給輸入法，輸入不收；字選完（沒在組字）再按＝收輸入。
        //   倒放＝最先判斷：在打字也是收框（輸入不動）。
        let ime = await escapeScene("esc-ime", form: .outerPortrait, beside: false, panel: .search, presses: 2,
                                    before: { screen in
                                        // 搜尋框裡先有一個字，再用輸入法組下一個（字還沒選完）。
                                        let editor = screen.window.firstResponder as? NSTextView
                                        editor?.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                                        editor?.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0),
                                                              replacementRange: NSRange(location: NSNotFound, length: 0))
                                    },
                                    between: { screen in (screen.window.firstResponder as? NSTextView)?.unmarkText() })
        // W184 G2c 第二輪（GPT-6 #2）：組字的不是 NSTextView（網頁輸入框那一類 NSTextInputClient）也一樣交給輸入法
        //（它拿走了鍵盤，搜尋框就不在打字了；組字中的 Esc 照樣放行給它，選完之後單欄照舊放行給網頁）。
        let client = ComposingClient(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let imeClient = await escapeScene("esc-ime-client", form: .outerPortrait, beside: false, panel: .search, presses: 2,
                                          before: { screen in
                                              screen.host.addSubview(client)
                                              screen.window.makeFirstResponder(client)
                                              client.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0),
                                                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                                          },
                                          between: { _ in client.unmarkText() })
        let tent = await escapeScene("esc-tent", form: .tent, beside: false, panel: .search, presses: 1)
        let imeOK: Bool = ime == ["open=search", "panel=search box=true passed=1/1", "panel=nil box=true passed=1/2"]
        let clientOK: Bool = imeClient == ["open=nil", "panel=nil box=true passed=1/1", "panel=nil box=true passed=2/2"]
        let tentOK: Bool = tent == ["open=search", "panel=search box=false passed=0/1"]
        check(imeOK && clientOK && tentOK,
              "G14 (W184 G2 third round; second round adds a non-NSTextView input; G2d) the Esc order, measured: while an input method is composing in the search box, Esc goes to the input method and typing goes on; once composing ends the next Esc ends typing; a composing text input that is not an NSTextView (NSTextInputClient, like a web page's field) also gets the Esc; in the tent the box closes first (typing is left alone)",
              "ime=\(ime) client=\(imeClient) tent=\(tent)")
    }

    // MARK: - W184 G2c：新分頁（左列＋、分頁總覽的＋、⌘⌥T、滿了一句話）

    /// 真的按一下鍵（排進 App 的事件佇列，走跟真的鍵盤一樣的派送：本機事件監聽 → NSApp.sendEvent → key 視窗）。
    @MainActor static func pressKey(_ keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags, in window: NSWindow) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// 自測的「私訊框 ⌘⌥T」：照 GlobalDMPanelController 的本機 keyDown 監聽（handleNewTab），只看這個視窗、走同一條 routeNewTab。
    @MainActor static func newTabRoute(for window: NSWindow, store: GlobalDMStore, form: @escaping @MainActor () -> GlobalDMForm,
                                       browser: DMBrowser, tally: EscTally) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let passes = MainActor.assumeIsolated { () -> Bool in
                guard event.window === window else { return true }
                let routed = GlobalDMPanelController.routeNewTab(event, window: window, store: store, form: form(), browser: browser,
                                                                 hasSecondary: true)
                if event.keyCode == DMBrowserNewTabKey.keyCode {
                    tally.seen += 1
                    if routed != nil { tally.passed += 1 }
                }
                return routed != nil
            }
            return passes ? event : nil
        }
    }

    @MainActor static func newTabChecks(_ check: Checker) async {
        let size = CGSize(width: 466, height: 610)
        // N1：側欄的「新分頁」（真的滑鼠）＝空白的一般分頁在最前面、置中的搜尋框拿到游標；已經在空白的新分頁上再按＝不再多開；
        //     W184 G2c 第二輪（GPT-6 測試缺口）：真的在搜尋框打字、按 Return＝開在這個空白分頁上（同一個分頁；不是直接叫 openBrowse）。
        let phone = Phone("newtab")
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        let screen = Clickable(phone.pane(.sidebar, probes: true), size: size, keyable: true)
        await screen.settle()
        var sidebarPlus = false, again = false, filled = false
        if let plus = screen.center("side.newTab") {
            let before = phone.browser.tabs.count
            await screen.click(plus)
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
            let tab = phone.browser.activeTab
            let blankID = tab?.id
            sidebarPlus = tab?.isBlank == true && tab?.purpose == .browse && tab?.isSensitive == false && tab?.title == DMBrowser.blankTitle
                && phone.browser.tabs.count == before + 1 && screen.panelState == .search && phone.browser.newTabAsk?.refusal == nil
                && screen.frame("search.panel") != nil
            let serial = phone.browser.newTabAsk?.serial ?? 0
            // 側欄多了一列（空白的新分頁）：「新分頁」位置不變（在分頁上面），再按一次。
            if let moved = screen.center("side.newTab") { await screen.click(moved) }
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
            again = phone.browser.tabs.count == before + 1 && phone.browser.newTabAsk?.serial == serial + 1 && screen.panelState == .search
            let typed = await screen.type("example.com/new")
            await pressKey(36, characters: "\r", flags: [], in: screen.window)
            _ = await DMBrowserAcceptance.waitUntil(2) { phone.browser.activeTab?.isBlank == false }
            filled = typed && blankID != nil && phone.browser.activeID == blankID && phone.browser.tabs.count == before + 1
                && phone.browser.activeTab?.startURL?.absoluteString == "https://example.com/new" && phone.browser.activeTab?.isBlank == false
                && screen.panelState == nil
        }
        check(sidebarPlus && again && filled,
              "N1 (W184 G2c; G2d) the sidebar's 新分頁 (a real click) opens a blank general tab in front (not an authorisation page) showing the centered search box with the caret in it; pressing it again on that blank tab opens nothing more; really typing an address and pressing Return fills that same tab",
              "plus=\(sidebarPlus) again=\(again) filled=\(filled) tabs=\(phone.browser.tabs.map { $0.title })")
        // N2：分頁總覽最後一格「＋」＝一樣開空白的新分頁、收起總覽、置中的搜尋框拿到游標。
        phone.browser.isShowingTabList = true
        await screen.settle()
        var overviewPlus = false
        if let cell = screen.center("tabList.newTab") {
            let before = phone.browser.tabs.count
            await screen.click(cell)
            _ = await DMBrowserAcceptance.waitUntil(2) { screen.panelState == .search }
            overviewPlus = !phone.browser.isShowingTabList && phone.browser.activeTab?.isBlank == true && phone.browser.tabs.count == before + 1
                && screen.panelState == .search
        }
        check(overviewPlus, "N2 (W184 G2c; G2d) the tab overview's last cell ＋ opens a blank new tab too, closes the overview and puts the caret in the centered search box")
        // N3：一般分頁滿了（4 個）＝新分頁不開、頁面頂上那一句話（G2 的規則；「所有分頁」那一顆在同一句話旁）。
        _ = phone.browser.openBrowse(url: URL(string: "https://example.com/n2")!, title: "n2", origin: .typed,
                                     typedInto: phone.browser.activeID)   // 開在剛才那個空白分頁上（在它上面開始打的字）
        _ = phone.browser.openBrowse(url: URL(string: "https://example.com/n3")!, title: "n3", origin: .typed)
        _ = phone.browser.openBrowse(url: URL(string: "https://example.com/n4")!, title: "n4", origin: .typed)
        await screen.settle(3)
        let browseCount = phone.browser.tabs.filter { $0.purpose == .browse }.count
        var full = false
        if let plus = screen.center("side.newTab") {
            let before = phone.browser.tabs.count
            await screen.click(plus)
            await screen.settle(3)
            full = browseCount == DMBrowser.maxBrowseTabs && phone.browser.tabs.count == before && phone.browser.newTabAsk?.refusal == .browseFull
                && screen.frame("note") != nil && DMBrowserBrowseRefusal.browseFull.line.contains("最多 \(DMBrowser.maxBrowseTabs) 個")
        }
        check(full, "N3 (W184 G2c; G2d) with 4 general tabs 新分頁 opens nothing and the Browser says the one sentence at the top of the page (一般網頁最多 4 個…先關掉一個)",
              "browse=\(browseCount) ask=\(String(describing: phone.browser.newTabAsk)) note=\(screen.frame("note") != nil)")
        screen.close()
        phone.browser.closeAll()

        // N4：⌘⌥T（真的鍵盤事件，走私訊框同一條路）：私訊框是 key 視窗、看得到 Browser＝新分頁、置中的搜尋框拿到游標；
        //     ⌘T（沒有 ⌥）、看對話、倒放＝不收（放行，主視窗的 ⌘T 照舊）；內橫右欄的 Browser 也收。
        let keyPhone = Phone("newtab-key")
        keyPhone.store.isOpen = true
        keyPhone.store.showBrowser()
        _ = keyPhone.browser.openPod(purpose: .chatgptDeveloper)
        let keyScreen = Clickable(keyPhone.pane(.sidebar), size: size, keyable: true)
        await keyScreen.settle()
        let isKey = keyScreen.window.isKeyWindow || NSApp.keyWindow === keyScreen.window
        let tally = EscTally()
        var form: GlobalDMForm = .outerPortrait
        let monitor = newTabRoute(for: keyScreen.window, store: keyPhone.store, form: { form }, browser: keyPhone.browser, tally: tally)
        let before = keyPhone.browser.tabs.count
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command, .option], in: keyScreen.window)
        _ = await DMBrowserAcceptance.waitUntil(2) { keyScreen.panelState == .search }
        await keyScreen.settle()
        let opened: Bool = keyPhone.browser.activeTab?.isBlank == true && keyPhone.browser.tabs.count == before + 1
            && keyScreen.panelState == .search && tally.seen == 1 && tally.passed == 0
        let caret = await DMBrowserAcceptance.waitUntil(2) { keyScreen.window.firstResponder is NSTextView }
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command], in: keyScreen.window)
        let plainCommandT: Bool = tally.seen == 2 && tally.passed == 1 && keyPhone.browser.tabs.count == before + 1
        keyPhone.store.isBrowsing = false
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command, .option], in: keyScreen.window)
        let conversation: Bool = tally.passed == 2 && keyPhone.browser.tabs.count == before + 1
        keyPhone.store.showBrowser()
        form = .tent
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command, .option], in: keyScreen.window)
        let tent: Bool = tally.passed == 3 && keyPhone.browser.tabs.count == before + 1
        form = .innerLandscape
        _ = keyPhone.browser.openBrowse(url: URL(string: "https://example.com/k")!, title: "k", origin: .typed,
                                        typedInto: keyPhone.browser.activeID)   // 空白的那一頁先開成網頁
        // W184 G2c 第二輪（GPT-6 #1）：內橫、選了左欄的對話對象＝兩個旗標都 false；右欄因為還有分頁照樣是 Browser，⌘⌥T 照樣收。
        keyPhone.store.isBrowsing = false
        keyPhone.store.browsesBeside = true
        keyPhone.store.isBrowsingBeside = false
        let beforeDuo = keyPhone.browser.tabs.count
        await pressKey(DMBrowserNewTabKey.keyCode, characters: "t", flags: [.command, .option], in: keyScreen.window)
        let duo: Bool = tally.passed == 3 && keyPhone.browser.tabs.count == beforeDuo + 1 && keyPhone.browser.activeTab?.isBlank == true
        if let monitor { NSEvent.removeMonitor(monitor) }
        keyScreen.close()
        keyPhone.browser.closeAll()
        check(isKey && opened && caret && plainCommandT && conversation && tent && duo,
              "N4 (W184 G2c; G2d) ⌘⌥T as a real key event through the DM box's own key route: with the box key and the Browser on screen it opens a blank new tab with the caret in the centered search box; ⌘T without ⌥, the conversation, the tent pass it on (nothing opened); the inner-landscape right column takes it too — also with both Browser flags off while tabs keep it on screen (second round)",
              "key=\(isKey) opened=\(opened) caret=\(caret) cmdT=\(plainCommandT) chat=\(conversation) tent=\(tent) duo=\(duo) seen=\(tally.seen) passed=\(tally.passed)")
    }

}
#endif
