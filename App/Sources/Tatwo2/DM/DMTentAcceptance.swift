#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184tent`：W184 E 倒放＝Browser 影片子畫面（第一階段）＋有事時蓋上來的三種卡。
/// 無頭建置沒有 CEF：影片來源換成假的（每個分頁一個色塊 NSView，放在自己的「分頁容器」裡；借＝搬進倒放的容器、還＝搬回來），
/// 其餘都是正式的 DMTentVideo、DMTentPick、BrowserTentPolicy、DMTentCard。主機（TatwoCEFTabHostView）的借出／還回由 node 原始碼測試守、
/// 主導實機驗。只在完整隔離的 staging 跑。
/// 畫面證據（PNG）寫到 TATWO2_SELFTEST_ARTIFACTS：有影片（色塊代替）、滑鼠移入的控制、空狀態（兩句）、三種卡、主視窗那一格的佔位卡。
enum DMTentAcceptance {
    @MainActor final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: @autoclosure () -> String = "") {
            if condition { passed += 1 } else { failed += 1 }
            let detail = condition ? "" : evidence()
            print("W184TENT \(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(400)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W184TENT SKIP \(label)")
        }
    }

    // MARK: - 假的影片來源

    @MainActor final class FakeSource: DMTentVideoSource {
        var tabList: [BrowserLendableTab] = []
        private(set) var pages: [String: NSView] = [:]
        private(set) var homes: [String: NSView] = [:]
        private(set) var lent: [String] = []
        private(set) var givenBack: [(id: String, focus: Bool)] = []
        private(set) var opened: [String?] = []
        let startSubject = PassthroughSubject<String, Never>()
        let changeSubject = PassthroughSubject<Void, Never>()
        let returnSubject = PassthroughSubject<(tabID: String, reason: BrowserTabReturnReason), Never>()

        /// 加一個分頁：一個色塊（代替影片）放在它自己的「分頁容器」裡。
        func add(_ tab: BrowserLendableTab, color: NSColor = .systemIndigo) {
            tabList.append(tab)
            let home = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            let page = DMTentAcceptance.videoBlock(color: color)
            page.frame = home.bounds
            home.addSubview(page)
            homes[tab.id] = home
            pages[tab.id] = page
        }

        func tabs() -> [BrowserLendableTab] { tabList }

        func lend(_ id: String, into container: NSView) -> Bool {
            guard let tab = tabList.first(where: { $0.id == id }), BrowserTentPolicy.lendable(tab), let page = pages[id] else { return false }
            if page.superview !== container {
                page.frame = container.bounds
                page.autoresizingMask = [.width, .height]
                container.addSubview(page)
            }
            page.isHidden = false
            lent.append(id)
            return true
        }

        func giveBack(_ id: String, focus: Bool) {
            putHome(id)
            givenBack.append((id: id, focus: focus))
        }

        func openBrowser(_ id: String?) { opened.append(id) }

        var starts: AnyPublisher<String, Never> { startSubject.eraseToAnyPublisher() }
        var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }
        var returns: AnyPublisher<(tabID: String, reason: BrowserTabReturnReason), Never> { returnSubject.eraseToAnyPublisher() }

        func update(_ id: String, _ change: (inout BrowserLendableTab) -> Void) {
            guard let index = tabList.firstIndex(where: { $0.id == id }) else { return }
            change(&tabList[index])
        }

        /// 這個分頁開始播影片（時間記好才送，同 BrowserVideoTabs）。
        func start(_ id: String, at date: Date) {
            update(id) { $0.videoStartedAt = date }
            startSubject.send(id)
        }

        /// 主機自己還回（分頁要關、主視窗下指令、拿回來、要全螢幕）：先放回原分頁容器，再通知。
        func hostReturn(_ id: String, _ reason: BrowserTabReturnReason) {
            putHome(id)
            returnSubject.send((tabID: id, reason: reason))
        }

        func isHome(_ id: String) -> Bool { pages[id]?.superview === homes[id] }

        private func putHome(_ id: String) {
            guard let page = pages[id], let home = homes[id] else { return }
            if page.superview !== home {
                page.frame = home.bounds
                home.addSubview(page)
            }
            page.isHidden = false
        }
    }

    /// 轉換動畫進行中（假的）。
    @MainActor final class Flag { var value = false }

    /// 畫面外的測試視窗：occlusion（有沒有被整個蓋住）由測試決定——畫面外的視窗系統一律算「看不到」，
    /// 而倒放只把影片放在看得到的框裡（DMTentVideo.isVisibleHolder 正式的判斷照樣看 isVisible／縮到 Dock／occlusion／祖先隱藏）。
    final class RigWindow: NSWindow {
        var occluded = false
        override var occlusionState: NSWindow.OcclusionState { occluded ? [] : .visible }
    }

    /// 一組測試用的倒放：假的來源、自己的形態設定、自己的轉換旗標、兩個視窗（停靠框、浮動框的替身）。
    @MainActor final class Rig {
        let source: FakeSource
        let settings: GlobalDMDeskSettings
        let animating: Flag
        let transitions: CurrentValueSubject<Bool, Never>
        let box: PassthroughSubject<Void, Never>
        let video: DMTentVideo
        let docked: RigWindow
        let floating: RigWindow

        init(defaults: UserDefaults, holderGrace: TimeInterval = 0.06, recheck: TimeInterval = 0.05) {
            let source = FakeSource(), animating = Flag()
            let transitions = CurrentValueSubject<Bool, Never>(false), box = PassthroughSubject<Void, Never>()
            let settings = GlobalDMDeskSettings(defaults: defaults)
            settings.form = .outerPortrait
            self.source = source
            self.animating = animating
            self.transitions = transitions
            self.box = box
            self.settings = settings
            video = DMTentVideo(source: { source }, settings: settings, transitions: transitions.eraseToAnyPublisher(),
                                isTransitioning: { animating.value }, boxChanges: box.eraseToAnyPublisher(),
                                holderGrace: holderGrace, recheckInterval: recheck)
            docked = Self.window()
            floating = Self.window()
        }

        static func window() -> RigWindow {
            let window = RigWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 678, height: 466), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 678, height: 466))
            window.orderFrontRegardless()
            return window
        }

        /// SwiftUI 的 makeNSView：框掛上視窗、claim。
        func mount(_ window: NSWindow) -> DMTentVideoContainer {
            let container = DMTentVideoContainer(frame: window.contentView?.bounds ?? .zero)
            container.video = video
            window.contentView?.addSubview(container)
            video.claim(container)
            return container
        }

        /// SwiftUI 的 dismantleNSView：框拿掉、release。
        func unmount(_ container: DMTentVideoContainer) {
            container.removeFromSuperview()
            video.release(container)
        }

        func close() {
            docked.orderOut(nil)
            floating.orderOut(nil)
        }
    }

    @MainActor static func settle(_ seconds: Double = 0.03) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await Task.yield()
    }

    /// 代替影片的色塊（自己畫底色：cacheDisplay 畫得出來）。
    final class VideoBlock: NSView {
        var color: NSColor = .black
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }

    /// 代替影片的色塊（深色底＋一行字）。
    @MainActor static func videoBlock(color: NSColor) -> NSView {
        let view = VideoBlock(frame: NSRect(x: 0, y: 0, width: 678, height: 466))
        view.color = color
        let label = NSTextField(labelWithString: "〔Browser 分頁正在播的影片〕")
        label.textColor = .white
        label.font = .systemFont(ofSize: DMPhone.TextSize.footnote, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        return view
    }

    // MARK: - 入口

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"], let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w184tent needs a fully isolated staging environment")
        }
        let root = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        let check = Checker()
        var suites: [String] = []
        func freshDefaults(_ name: String) -> UserDefaults {
            let suite = "ai.tatwo.selftest.w184tent.\(name).\(UUID().uuidString)"
            suites.append(suite)
            return UserDefaults(suiteName: suite) ?? .standard
        }
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }

        policyChecks(check)
        pickChecks(check)
        await lendingChecks(check, freshDefaults)
        await hiddenHolderChecks(check, freshDefaults)
        restoreRuleChecks(check)
        await takeoverChecks(check, freshDefaults)
        sleepChecks(check)
        keyChecks(check)
        cardChecks(check)
        try await evidence(check, root: root, freshDefaults)
        check.skip("真的 CEF：YouTube 播放中切到倒放不重新載入、聲音不斷；全螢幕、⌘W、主視窗佔位卡的點擊——這個建置沒有 Chromium，主導實機驗")

        print("W184TENT SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - A 候選篩選（施工單第 5 條）

    @MainActor static func policyChecks(_ check: Checker) {
        let now = Date()
        let base = BrowserLendableTab(id: "base", host: "video.example", title: "影片", videoStartedAt: now)
        check(BrowserTentPolicy.lendable(base), "A0 a playing human Browser work space tab can be lent")
        typealias N = BrowserLendableTab.Native
        let refused: [(String, BrowserLendableTab)] = [
            ("私訊框 Browser 的授權頁", BrowserLendableTab(id: "auth", videoStartedAt: now, ownedByWorkSpace: false, native: N(sensitivePage: true))),
            ("Pod（ChatGPT）", BrowserLendableTab(id: "pod", videoStartedAt: now, ownedByWorkSpace: false, native: N(isPod: true))),
            ("配對頁 popup", BrowserLendableTab(id: "pair", videoStartedAt: now, ownedByWorkSpace: false, native: N(sensitivePage: true))),
            ("登入 popup", BrowserLendableTab(id: "login", videoStartedAt: now, ownedByWorkSpace: false, native: N(sensitivePage: true))),
            ("AI 分頁", BrowserLendableTab(id: "ai", videoStartedAt: now, isAgentTab: true)),
            ("AI 控制中", BrowserLendableTab(id: "ctl", videoStartedAt: now, native: N(agentControlled: true))),
            ("敏感頁（登記簿標的授權分頁）", BrowserLendableTab(id: "sens", videoStartedAt: now, isSensitive: true)),
            ("敏感頁（只准 https 的授權頁旗標）", BrowserLendableTab(id: "sp", videoStartedAt: now, native: N(sensitivePage: true))),
            ("受保護的呈現（只准 https）", BrowserLendableTab(id: "https", videoStartedAt: now, native: N(httpsOnly: true))),
            ("非使用者本人操作的頁", BrowserLendableTab(id: "agent", videoStartedAt: now, native: N(isHuman: false))),
            ("睡著的分頁", BrowserLendableTab(id: "sleep", videoStartedAt: now, isSleeping: true)),
            ("聊天 session 的分頁", BrowserLendableTab(id: "chat", videoStartedAt: now, ownedByWorkSpace: false)),
            ("原生頁面還沒建好", BrowserLendableTab(id: "none", videoStartedAt: now, native: nil)),
        ]
        for (label, tab) in refused {
            check(!BrowserTentPolicy.lendable(tab) && DMTentPick.candidates([tab], dismissed: nil).isEmpty,
                  "A1 never lent: \(label)")
        }
        check(DMTentPick.candidates([BrowserLendableTab(id: "quiet")], dismissed: nil).isEmpty,
              "A2 a tab that is not playing a video is not a candidate")
        // 登記簿的分頁→旗標：擁有者、AI 分頁、睡著照登記簿；網域去掉 www.、只收 http／https。
        let url = URL(string: "https://www.youtube.com/watch?v=W184")
        func tab(_ owner: BrowserTabOwner, agent: Bool = false, sleeping: Bool = false) -> BrowserTab {
            BrowserTab(id: UUID(), owner: owner, url: url, title: "W184", faviconPNG: nil, isPinned: false, isSleeping: sleeping,
                       lastActiveAt: now, createdAt: now, isAgentTab: agent ? true : nil)
        }
        let space = UUID()
        let work = BrowserLendableTab(tab: tab(.workSpace(spaceID: space)), isSensitive: false, videoStartedAt: now, isSelected: true, native: N())
        let chat = BrowserLendableTab(tab: tab(.chatSession(sessionID: "s")), isSensitive: false, videoStartedAt: now, isSelected: false, native: N())
        let bot = BrowserLendableTab(tab: tab(.bot(botID: "b")), isSensitive: false, videoStartedAt: now, isSelected: false, native: N())
        let asleep = BrowserLendableTab(tab: tab(.workSpace(spaceID: space), sleeping: true), isSensitive: false, videoStartedAt: now,
                                        isSelected: false, native: N())
        let flagged = BrowserLendableTab(tab: tab(.workSpace(spaceID: space), agent: true), isSensitive: false, videoStartedAt: now,
                                         isSelected: false, native: N())
        let workOK = work.ownedByWorkSpace && work.host == "youtube.com" && BrowserTentPolicy.lendable(work)
        let othersRefused = !chat.ownedByWorkSpace && !bot.ownedByWorkSpace && !BrowserTentPolicy.lendable(chat)
            && !BrowserTentPolicy.lendable(bot)
        let stateRefused = !BrowserTentPolicy.lendable(asleep) && !BrowserTentPolicy.lendable(flagged)
        check(workOK && othersRefused && stateRefused,
              "A3 from the registry: only awake, human work space tabs; chat session and bot tabs, AI tabs and sleeping tabs are refused")
        check(BrowserLendableTab.displayHost(URL(string: "file:///tmp/a.mp4")) == nil
              && BrowserLendableTab.displayHost(URL(string: "http://video.example:8080/x?y=1")) == "video.example",
              "A4 the label shows only an http/https host (no path, no query)")
    }

    // MARK: - B 挑分頁（施工單第 4 條，純計算）

    @MainActor static func pickChecks(_ check: Checker) {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20),
            t3 = t0.addingTimeInterval(30)
        let a = BrowserLendableTab(id: "A", lastActiveAt: t0, videoStartedAt: t0, isSelected: true, native: .init(isOnScreen: true))
        let b = BrowserLendableTab(id: "B", lastActiveAt: t1, videoStartedAt: t2)
        let c = BrowserLendableTab(id: "C", lastActiveAt: t2)
        check(DMTentPick.onEnter([a, b, c], dismissed: nil) == "A",
              "B1 entering the tent takes the selected tab that is playing (even when the main window shows it)")
        var quiet = a
        quiet.videoStartedAt = nil
        check(DMTentPick.onEnter([quiet, b, BrowserLendableTab(id: "D", lastActiveAt: t0, videoStartedAt: t1)], dismissed: nil) == "B",
              "B2 otherwise the most recently started video")
        let tieOld = BrowserLendableTab(id: "E", lastActiveAt: t0, videoStartedAt: t1)
        let tieNew = BrowserLendableTab(id: "F", lastActiveAt: t2, videoStartedAt: t1)
        check(DMTentPick.onEnter([tieOld, tieNew], dismissed: nil) == "F", "B3 same start time: the one used last")
        let dismissed = DMTentPick.Dismissed(id: "A", startedAt: t0)
        check(DMTentPick.onEnter([a, b], dismissed: dismissed) == "B",
              "B4 a dismissed tab is skipped until it starts playing again")
        var restarted = a
        restarted.videoStartedAt = t3
        check(DMTentPick.onEnter([restarted, b], dismissed: dismissed) == "A", "B5 once it starts again it can be taken")
        let fresh = BrowserLendableTab(id: "G", lastActiveAt: t3, videoStartedAt: t3)
        var watched = fresh
        watched.native = .init(isOnScreen: true)
        check(DMTentPick.collectsStart("G", in: [fresh], dismissed: nil)
              && !DMTentPick.collectsStart("G", in: [watched], dismissed: nil)
              && !DMTentPick.collectsStart("G", in: [fresh], dismissed: DMTentPick.Dismissed(id: "G", startedAt: t3))
              && !DMTentPick.collectsStart("H", in: [BrowserLendableTab(id: "H", videoStartedAt: t3, isAgentTab: true)], dismissed: nil),
              "B6 an empty tent collects a newly started video, but not one the main window is showing, a dismissed one, or an AI tab")
        check(DMTentPick.playingElsewhere([b]) && !DMTentPick.playingElsewhere([c])
              && !DMTentPick.playingElsewhere([BrowserLendableTab(id: "I", videoStartedAt: t0, isSensitive: true)]),
              "B7 the empty sentence knows whether a lendable Browser video is still playing")
    }

    // MARK: - C 借出與還回（施工單第 4、6 條；假的來源＋正式的 DMTentVideo）

    @MainActor static func lendingChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let rig = Rig(defaults: freshDefaults("lend"))
        defer { rig.close() }
        let source = rig.source, video = rig.video
        let t0 = Date(timeIntervalSince1970: 2_000)
        source.add(BrowserLendableTab(id: "A", host: "video.example", title: "A", lastActiveAt: t0, videoStartedAt: t0.addingTimeInterval(1),
                                      isSelected: true))
        source.add(BrowserLendableTab(id: "B", host: "b.example", title: "B", lastActiveAt: t0, videoStartedAt: t0.addingTimeInterval(2)),
                   color: .systemTeal)
        source.add(BrowserLendableTab(id: "C", host: "c.example", title: "C", lastActiveAt: t0), color: .systemPink)

        // C1 進倒放：轉換動畫走完才掛上（同 setForm：先改形態、再播動畫；倒放的畫面下一輪才掛上）。動畫期間只放黑底，不閃空狀態那句。
        rig.settings.form = .tent
        rig.animating.value = true
        rig.transitions.send(true)
        let enteringAtStart = video.entering
        var container = rig.mount(rig.docked)
        await settle()
        check(video.lentTabID == nil && source.isHome("A") && enteringAtStart && video.entering,
              "C1 while the tent transition is still animating nothing is attached (a black backdrop, not the empty sentence)")
        rig.animating.value = false
        rig.transitions.send(false)
        await settle()
        check(video.lentTabID == "A" && source.pages["A"]?.superview === container && video.shown?.host == "video.example"
              && !video.entering,
              "C1 when the transition ends the selected playing tab's page moves into the tent (the same view, not reloaded)",
              "lent=\(String(describing: video.lentTabID))")
        check(WindowCaptureShield.shared.holders(of: rig.docked) == 0 && rig.docked.sharingType != .none,
              "C1 the tent does not hold WindowCaptureShield (a normal web page, no sensitive content)")

        // C2 已在倒放時不自動換台。
        source.start("C", at: t0.addingTimeInterval(5))
        await settle()
        check(video.lentTabID == "A" && source.isHome("C"), "C2 a video that starts elsewhere does not replace the one in the tent")

        // C3 切形態：離開倒放在動畫開始前（同一個呼叫裡、同步）先還回；動畫的「藏原生畫面」碰不到它。
        rig.settings.form = .outerPortrait
        let returnedAtOnce = video.lentTabID == nil && source.isHome("A") && source.givenBack.last?.id == "A"
        let covers = GlobalDMNativePageCover.cover(in: rig.docked.contentView)
        let untouched = source.pages["A"]?.isHidden == false && covers.allSatisfy { $0.hidden.isEmpty }
        for cover in covers { cover.uncover() }
        check(returnedAtOnce && untouched,
              "C3 leaving the tent gives the page back synchronously, before the form animation hides native pages")
        rig.unmount(container)
        await settle()

        // C4 收起私訊框（框被拆掉）：沒有看得到的框＝換手寬限期內不還，過了才還回。
        rig.settings.form = .tent
        container = rig.mount(rig.docked)
        await settle()
        let relent = video.lentTabID == "A"
        let backs = source.givenBack.count
        rig.unmount(container)
        let heldForAMoment = video.lentTabID == "A" && source.givenBack.count == backs
        try? await Task.sleep(nanoseconds: 150_000_000)
        await settle()
        check(relent && heldForAMoment && video.lentTabID == nil && source.isHome("A") && source.givenBack.count == backs + 1,
              "C4 closing the box: after the hand-off grace with nobody taking over, the page goes back to its tab")

        // C5 停靠↔浮動換手：新的框在換手寬限期內接手，影片不彈回主視窗。
        container = rig.mount(rig.docked)
        await settle()
        let beforeHandoff = source.givenBack.count
        let other = rig.mount(rig.floating)
        rig.unmount(container)
        await settle()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await settle()
        check(video.lentTabID == "A" && source.pages["A"]?.superview === other && source.givenBack.count == beforeHandoff,
              "C5 docked ↔ floating hand-off moves the page to the new box without bouncing back to the main window")
        container = other

        // C6 分頁被關（主機先還回再通知）：變成空狀態；已經在播的不收，新開始播的才收。
        source.hostReturn("A", .closing)
        await settle()
        let emptied = video.lentTabID == nil && video.shown == nil && source.isHome("A")
        source.update("A") { $0.videoStartedAt = nil }
        source.changeSubject.send()
        await settle()
        let stayedEmpty = video.lentTabID == nil
        source.start("C", at: t0.addingTimeInterval(8))
        await settle()
        check(emptied && stayedEmpty && video.lentTabID == "C" && source.pages["C"]?.superview === container,
              "C6 a closed tab leaves the tent empty; an empty tent only collects a newly started video")

        // C7 主視窗下指令、主視窗「拿回來」：先拿回來（主機），倒放變空狀態；正在主視窗看的新播放不搶。
        source.hostReturn("C", .command)
        await settle()
        let command = video.lentTabID == nil
        source.start("B", at: t0.addingTimeInterval(9))
        await settle()
        let tookB = video.lentTabID == "B"
        source.hostReturn("B", .takenBack)
        await settle()
        let takenBack = video.lentTabID == nil
        source.update("B") { $0.native = .init(isOnScreen: true); $0.videoStartedAt = nil }
        source.start("B", at: t0.addingTimeInterval(10))
        await settle()
        check(command && tookB && takenBack && video.lentTabID == nil,
              "C7 a main-window command or 拿回來 returns it first; a video started in the visible main window is not pulled in")

        // C8 要全螢幕：主機先還回；主視窗沒在顯示這個分頁（全螢幕沒開）＝回到 Browser。
        source.update("B") { $0.native = .init() }
        source.start("B", at: t0.addingTimeInterval(11))
        await settle()
        let lentForFullscreen = video.lentTabID == "B"
        source.hostReturn("B", .fullscreen(started: false))
        await settle()
        let opensBrowser = source.opened.last == .some("B")
        source.start("B", at: t0.addingTimeInterval(12))
        await settle()
        let openedCount = source.opened.count
        source.hostReturn("B", .fullscreen(started: true))
        await settle()
        check(lentForFullscreen && opensBrowser && video.lentTabID == nil && source.opened.count == openedCount,
              "C8 fullscreen returns the page first; when the main window could not show it, 回到 Browser opens it there")

        // C9 AI 控制、要睡：每次變動都重看，不能借了就馬上還回。
        source.start("B", at: t0.addingTimeInterval(13))
        await settle()
        let lentBeforeAgent = video.lentTabID == "B"
        source.update("B") { $0.native?.agentControlled = true }
        source.changeSubject.send()
        await settle()
        let agentReturned = video.lentTabID == nil && source.isHome("B")
        source.update("B") { $0.native?.agentControlled = false }
        source.start("B", at: t0.addingTimeInterval(14))
        await settle()
        let lentBeforeSleep = video.lentTabID == "B"
        source.update("B") { $0.isSleeping = true }
        source.changeSubject.send()
        await settle()
        check(lentBeforeAgent && agentReturned && lentBeforeSleep && video.lentTabID == nil && source.isHome("B"),
              "C9 AI control or a tab about to sleep gives the page back at once")
        source.update("B") { $0.isSleeping = false }

        // C10 「關掉子畫面」：還回、記住；它重新開始播才再收；再進倒放也不挑它。
        source.start("B", at: t0.addingTimeInterval(15))
        await settle()
        let lentBeforeDismiss = video.lentTabID == "B"
        video.dismiss()
        let dismissedNow = video.lentTabID == nil && source.isHome("B") && video.dismissed?.id == "B"
        rig.settings.form = .outerPortrait
        rig.unmount(container)
        source.update("A") { $0.videoStartedAt = nil; $0.isSelected = false }
        source.update("C") { $0.videoStartedAt = nil }
        source.update("B") { $0.isSelected = true }
        rig.settings.form = .tent
        container = rig.mount(rig.docked)
        await settle()
        let skippedOnEnter = video.lentTabID == nil
        source.start("B", at: t0.addingTimeInterval(16))   // 「重新開始播」要先停過：這裡直接給新的開始時間
        await settle()
        check(lentBeforeDismiss && dismissedNow && skippedOnEnter && video.lentTabID == "B" && video.dismissed == nil,
              "C10 關掉子畫面 remembers the tab (not taken again, not even on re-entry) until it starts playing again")

        // C11 「回到 Browser」：還回、鍵盤給頁面、主視窗切到 Browser 選那個分頁。
        video.backToBrowser()
        check(video.lentTabID == nil && source.givenBack.last.map { $0.id == "B" && $0.focus } == true
              && source.opened.last == .some("B"),
              "C11 回到 Browser gives the page back with keyboard focus and opens that tab in the main window")

        // C12 有卡蓋著：影片藏在下面（聲音照播：同一個頁面、沒有還回）；卡拿掉就回來。
        source.start("B", at: t0.addingTimeInterval(17))
        await settle()
        container.covered = true
        let hidden = video.lentTabID == "B" && source.pages["B"]?.isHidden == true
        container.covered = false
        check(hidden && source.pages["B"]?.isHidden == false && video.lentTabID == "B",
              "C12 a card covering the tent hides the video under it (still lent, keeps playing) and shows it again after")
        rig.settings.form = .outerPortrait
        rig.unmount(container)
        await settle()
    }

    // MARK: - C13 看不到的框（GPT-6 審查發現 5、6）：停靠框只被 orderOut、框沒拆掉

    @MainActor static func hiddenHolderChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let rig = Rig(defaults: freshDefaults("hidden"), holderGrace: 0.4, recheck: 0.05)
        defer { rig.close() }
        let source = rig.source, video = rig.video
        let t0 = Date(timeIntervalSince1970: 3_000)
        source.add(BrowserLendableTab(id: "A", host: "video.example", title: "A", lastActiveAt: t0, videoStartedAt: t0, isSelected: true))
        rig.settings.form = .tent
        let docked = rig.mount(rig.docked)
        await settle()
        let lent = video.lentTabID == "A" && source.pages["A"]?.superview === docked
        let backs = source.givenBack.count

        // 主視窗縮到 Dock／被 sheet 蓋住：控制器只把停靠框 orderOut，框的內容還掛著（沒拆、沒 release、也不發通知）。
        rig.docked.orderOut(nil)
        await settle(0.15)
        let heldDuringGrace = video.lentTabID == "A" && video.isAwaitingHolder && source.pages["A"]?.superview === docked
            && source.givenBack.count == backs
        await settle(0.5)
        check(lent && heldDuringGrace && video.lentTabID == nil && source.isHome("A") && source.givenBack.count == backs + 1
              && !video.isAwaitingHolder,
              "C13 docked box only ordered out (content still mounted): kept during the hand-off grace, returned to its tab after it")

        // 框再出現（停靠框掛回來）：寬限期後還回去的那一支收回來（恢復原樣）。
        rig.docked.orderFrontRegardless()
        rig.box.send(())
        await settle()
        check(video.lentTabID == "A" && source.pages["A"]?.superview === docked,
              "C13 when the hidden box is shown again the video it returned comes back")

        // 寬限期內框又出現：不還。
        let beforeFlicker = source.givenBack.count
        rig.docked.orderOut(nil)
        await settle(0.15)
        let noticed = video.isAwaitingHolder
        rig.docked.orderFrontRegardless()
        rig.box.send(())
        await settle(0.55)
        check(noticed && video.lentTabID == "A" && source.pages["A"]?.superview === docked && source.givenBack.count == beforeFlicker
              && !video.isAwaitingHolder,
              "C13 hidden then shown again within the grace (a sheet flicker): never returned, same box")

        // 寬限期內浮動框接手：搬過去、不彈回主視窗。
        rig.docked.orderOut(nil)
        let floating = rig.mount(rig.floating)
        await settle(0.6)
        check(video.lentTabID == "A" && source.pages["A"]?.superview === floating && source.givenBack.count == beforeFlicker,
              "C13 docked hidden, floating box takes over within the grace: moved there, no bounce to the main window")

        // 視窗被整個蓋住（occlusion）一樣算看不到：過了寬限期還回；露出來（occlusion 通知）＝收回來。
        rig.floating.occluded = true
        await settle(0.15)
        let occludedHeld = video.lentTabID == "A"
        await settle(0.5)
        let occludedReturned = video.lentTabID == nil && source.isHome("A")
        rig.floating.occluded = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.floating)
        await settle()
        check(occludedHeld && occludedReturned && video.lentTabID == "A" && source.pages["A"]?.superview === floating,
              "C13 a fully covered (occluded) box counts as not visible: returned after the grace; uncovered = taken back in")

        // 框只是被收起又出現不算「進倒放那一刻」：倒放空著時，不把主視窗正在看的影片吸進來。
        video.dismiss()
        source.add(BrowserLendableTab(id: "B", host: "b.example", title: "B", lastActiveAt: t0, videoStartedAt: t0.addingTimeInterval(5),
                                      isSelected: true, native: .init(isOnScreen: true)), color: .systemTeal)
        source.update("A") { $0.isSelected = false }
        rig.floating.orderOut(nil)
        await settle(0.1)
        rig.floating.orderFrontRegardless()
        rig.box.send(())
        await settle()
        check(video.lentTabID == nil && source.isHome("B") && source.isHome("A"),
              "C13 an empty tent that is hidden and shown again is not an entry: the video the main window shows is not pulled in")

        rig.settings.form = .outerPortrait
        rig.unmount(docked)
        rig.unmount(floating)
        await settle()
    }

    // MARK: - C14 框再出現就收回來的資格（GPT-6 審查新發現 4，純計算）

    @MainActor static func restoreRuleChecks(_ check: Checker) {
        let t0 = Date(timeIntervalSince1970: 4_000), t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20)
        typealias N = BrowserLendableTab.Native
        let url = "https://video.example/watch?v=W184"
        let base = BrowserLendableTab(id: "A", host: "video.example", title: "A", lastActiveAt: t0, videoStartedAt: t1,
                                      native: N(navigationGeneration: 7, pageURL: url))
        guard let ticket = DMTentRestore.Ticket(base) else {
            check(false, "C14 a returned, still-playing tab that the main window does not show gets a restore ticket")
            return
        }
        check(DMTentRestore.stillValid(ticket, base), "C14 nothing happened since the return: it can come back")
        func changed(_ label: String, _ change: (inout BrowserLendableTab) -> Void) -> (String, BrowserLendableTab) {
            var tab = base
            change(&tab)
            return (label, tab)
        }
        let takeovers: [(String, BrowserLendableTab)] = [
            changed("主視窗正在呈現它") { $0.native?.isOnScreen = true },
            changed("主視窗選過或離開過它（最後使用時間變了）") { $0.lastActiveAt = t2 },
            changed("導頁、重新整理、上一頁（頁面世代變了）") { $0.native?.navigationGeneration = 8 },
            changed("同一份文件裡換網址（單頁 App 換影片）") { $0.native?.pageURL = url + "&t=2" },
            changed("導到非影片頁、停了（沒在播影片）") { $0.videoStartedAt = nil },
            changed("暫停後又播（不同的一段播放）") { $0.videoStartedAt = t2 },
            changed("AI 控制（不能借了）") { $0.native?.agentControlled = true },
            changed("睡著、原生頁面沒了") { $0.native = nil },
        ]
        for (label, tab) in takeovers {
            check(!DMTentRestore.stillValid(ticket, tab), "C14 the main window took over, the ticket is void: \(label)")
        }
        check(!DMTentRestore.stillValid(ticket, nil), "C14 the tab is gone: the ticket is void")
        var shown = base
        shown.native?.isOnScreen = true
        var stopped = base
        stopped.videoStartedAt = nil
        check(DMTentRestore.Ticket(shown) == nil && DMTentRestore.Ticket(stopped) == nil,
              "C14 no ticket when the main window already shows it at the return, or it is not playing a video")
    }

    // MARK: - C14 框收起期間主視窗接手（GPT-6 審查新發現 4，正式的 DMTentVideo）

    @MainActor static func takeoverChecks(_ check: Checker, _ freshDefaults: (String) -> UserDefaults) async {
        let rig = Rig(defaults: freshDefaults("takeover"), holderGrace: 0.3, recheck: 0.05)
        defer { rig.close() }
        let source = rig.source, video = rig.video
        let t0 = Date(timeIntervalSince1970: 5_000)
        var start = t0
        source.add(BrowserLendableTab(id: "A", host: "video.example", title: "A", lastActiveAt: t0, videoStartedAt: start, isSelected: true,
                                      native: .init(navigationGeneration: 1, pageURL: "https://video.example/watch?v=1")))
        rig.settings.form = .tent
        var container = rig.mount(rig.docked)
        await settle()

        /// 倒放重新收 A（換出倒放再換回來＝進倒放那一刻）。
        func relend() async -> Bool {
            rig.settings.form = .outerPortrait
            rig.unmount(container)
            rig.docked.orderFrontRegardless()
            rig.settings.form = .tent
            container = rig.mount(rig.docked)
            await settle()
            return video.lentTabID == "A" && source.pages["A"]?.superview === container
        }
        /// 停靠框只被 orderOut 超過寬限期：A 還回原分頁、留下「框再出現就收回來」的資格。
        func hideAndReturn() async -> Bool {
            rig.docked.orderOut(nil)
            await settle(0.55)
            return video.lentTabID == nil && source.isHome("A") && video.hasRestoreTicket
        }
        /// 停靠框掛回來。
        func showAgain() async {
            rig.docked.orderFrontRegardless()
            rig.box.send(())
            await settle()
        }

        // 對照組：框收起期間什麼都沒發生＝框再出現就收回來。
        let lentFirst = video.lentTabID == "A"
        let returned = await hideAndReturn()
        await showAgain()
        check(lentFirst && returned && video.lentTabID == "A" && source.pages["A"]?.superview === container,
              "C14 control: hidden past the grace, nothing happened meanwhile, shown again = the video comes back")

        // 資格還在時主視窗接手：在主視窗看它（呈現）→ 作廢；主視窗換走以後框再出現也不收回來。
        let hidden1 = await hideAndReturn()
        source.update("A") { $0.native?.isOnScreen = true }
        source.changeSubject.send()
        await settle()
        let voidedOnScreen = !video.hasRestoreTicket
        source.update("A") { $0.native?.isOnScreen = false }
        await showAgain()
        check(hidden1 && voidedOnScreen && video.lentTabID == nil && source.isHome("A"),
              "C14 while the ticket exists the main window shows the tab: the ticket is void, the box coming back does not pull it in")

        // 主視窗選了它又離開（最後使用時間變了、現在不在畫面上）：一樣作廢。
        let lent2 = await relend()
        let hidden2 = await hideAndReturn()
        source.update("A") { $0.lastActiveAt = t0.addingTimeInterval(60) }
        source.changeSubject.send()
        await showAgain()
        check(lent2 && hidden2 && video.lentTabID == nil && source.isHome("A"),
              "C14 the main window selected the tab and left it again: not pulled back into the tent")

        // 導頁（頁面世代變了）：作廢。
        let lent3 = await relend()
        let hidden3 = await hideAndReturn()
        source.update("A") { $0.native?.navigationGeneration = 2 }
        source.changeSubject.send()
        await showAgain()
        check(lent3 && hidden3 && video.lentTabID == nil && source.isHome("A"),
              "C14 the tab navigated in the main window (new page generation): not pulled back")

        // 單頁 App 換網址（世代沒變、網址變了）：作廢。
        let lent4 = await relend()
        let hidden4 = await hideAndReturn()
        source.update("A") { $0.native?.pageURL = "https://video.example/watch?v=2" }
        source.changeSubject.send()
        await showAgain()
        check(lent4 && hidden4 && video.lentTabID == nil && source.isHome("A"),
              "C14 the tab changed URL inside the same document: not pulled back")

        // 導到非影片頁（沒在播影片）：作廢；之後就算又開始播，也要照「空狀態收新開始播的」規則（這裡框看得到、不在主視窗，就收）。
        let lent5 = await relend()
        let hidden5 = await hideAndReturn()
        source.update("A") { $0.videoStartedAt = nil }
        source.changeSubject.send()
        await showAgain()
        let notPulled = video.lentTabID == nil && source.isHome("A") && !video.hasRestoreTicket
        start = t0.addingTimeInterval(120)
        source.start("A", at: start)
        await settle()
        check(lent5 && hidden5 && notPulled && video.lentTabID == "A",
              "C14 the tab went to a non-video page: not pulled back; a video started later is collected by the normal empty-tent rule")

        // 還回當下主視窗已經在呈現它：根本不給資格。
        source.update("A") { $0.native?.isOnScreen = true }
        rig.docked.orderOut(nil)
        await settle(0.55)
        let noTicket = video.lentTabID == nil && source.isHome("A") && !video.hasRestoreTicket
        source.update("A") { $0.native?.isOnScreen = false }
        await showAgain()
        check(noTicket && video.lentTabID == nil,
              "C14 the main window already shows the tab when it is returned: no ticket, the box coming back does not pull it in")

        rig.settings.form = .outerPortrait
        rig.unmount(container)
        await settle()
    }

    // MARK: - D 借出不被睡（施工單第 7 條）

    @MainActor static func sleepChecks(_ check: Checker) {
        let now = Date()
        let lent = UUID(), idle = UUID(), selected = UUID()
        let tabs = [lent, idle, selected].map {
            BrowserMemoryPolicy.Tab(id: $0, lastActiveAt: now.addingTimeInterval(-3_600), isSleeping: false)
        }
        // 主機的睡眠保護名單＝原生頁面擋睡的＋借給倒放的（TatwoCEFTabHostView.protectedTabIDs；node 測試守原始碼）。
        let victims = BrowserMemoryPolicy.sleepCandidates(tabs: tabs, selected: [selected], limit: 1, protected: [lent], pressure: .critical)
        check(!victims.contains(lent) && victims.contains(idle) && !victims.contains(selected),
              "D1 a tab lent to the tent is in the sleep protection list, even under critical memory pressure", "\(victims)")
    }

    // MARK: - E 倒放框裡的鍵盤（施工單第 9 條）

    @MainActor static func keyChecks(_ check: Checker) {
        let command: NSEvent.ModifierFlags = [.command]
        let blocked = ["w", "t", "n", "l", "r", "f", "p", "1", "[", ","].allSatisfy { BrowserLentKeys.claims(characters: $0, modifiers: command) }
        let editing = ["c", "v", "x", "a", "z", "Z", "q", "h"].allSatisfy { !BrowserLentKeys.claims(characters: $0, modifiers: command) }
        let plain = !BrowserLentKeys.claims(characters: "w", modifiers: []) && !BrowserLentKeys.claims(characters: " ", modifiers: [])
            && !BrowserLentKeys.claims(characters: "f", modifiers: [.shift])
        check(blocked && editing && plain,
              "E1 in the tent ⌘W and other menu shortcuts are swallowed (nothing in the main window closes); editing keys, typing and space still reach the page")
    }

    // MARK: - F 有事時蓋上來的三種卡（施工單第 11 條）

    @MainActor static func cardChecks(_ check: Checker) {
        let now = Date()
        let expires = now.addingTimeInterval(271.2)
        func resolve(approval: Bool = false, snoozed: Bool = false, pairing: Date? = nil, running: Bool = false) -> DMTentCard? {
            DMTentCard.resolve(approval: approval, approvalSnoozed: snoozed, pairingExpiresAt: pairing, running: running,
                               target: "TATWO 助理", preview: "主設備上現在有兩件事在跑", now: now)
        }
        // 剩幾秒是浮點數（到期時間減現在），只比形狀與「剩 m:ss」。
        func isPairing(_ card: DMTentCard?) -> Bool {
            if case .pairing? = card { return true }
            return false
        }
        let first: DMTentCard? = resolve(approval: true, pairing: expires, running: true)
        let snoozed: DMTentCard? = resolve(approval: true, snoozed: true, pairing: expires, running: true)
        let expired: DMTentCard? = resolve(pairing: now.addingTimeInterval(-1), running: true)
        let idle: DMTentCard? = resolve()
        let expectReply = DMTentCard.reply(target: "TATWO 助理", preview: "主設備上現在有兩件事在跑")
        check(first == DMTentCard.approval(target: "TATWO 助理") && isPairing(snoozed) && expired == expectReply && idle == nil,
              "F1 priority: 等你核准 > 配對進行中 > 回覆中; nothing happening = back to the video")
        let approval = DMTentCard.approval(target: "TATWO 助理")
        check(approval.header == "等你核准" && approval.body == "TATWO 助理 有一個動作要你核准" && approval.footnote == "核准只在 Island"
              && approval.actions.map(\.title) == ["到 Island 核准", "稍後"],
              "F2 等你核准: one sentence + 到 Island 核准 / 稍後 (approving stays on the Island)")
        let reply = DMTentCard.reply(target: "TATWO 助理", preview: "主設備上現在有兩件事在跑")
        check(reply.header == "TATWO 助理・回覆中" && reply.body == "主設備上現在有兩件事在跑" && reply.actions.map(\.title) == ["停止", "打開私訊框"],
              "F3 回覆中: <對象>・回覆中 + the latest reply + 停止 / 打開私訊框")
        let code = "7K2P9QXM"
        let flow = HandsConnectCard.pairing(HandsConnectPairingView(displayCode: "7K2P 9QXM", expiresAt: expires, attemptsLeft: 3,
                                                                    callbackHost: "primary-one.example", pairingCode: code, popup: true))
        let pairing = resolve(pairing: DMTentCard.pairingExpiry(flow))
        let words = pairing?.allText.joined(separator: " ") ?? ""
        let pairingShape = isPairing(pairing) && pairing?.header == "配對進行中・剩 4:32"
            && pairing?.actions.map(\.title) == ["打開配對頁"]
        let noCode = !words.contains("7K2P") && !words.contains("9QXM") && !words.contains("primary-one")
        check(pairingShape && noCode,
              "F4 配對進行中・剩 m:ss + 打開配對頁, reading only the expiry: the pairing code is never on the tent", words)
        check(DMTentCard.pairingExpiry(.working("W184")) == nil && DMTentCard.pairingExpiry(nil) == nil,
              "F5 no pairing card when the connection flow is not pairing")
        let long = String(repeating: "很長的回覆 ", count: 60) + "\n最後一句"
        let preview = DMTentCard.preview(long)
        check(preview.hasPrefix("…") && preview.hasSuffix("最後一句") && !preview.contains("\n")
              && preview.count <= DMTentLayout.previewCharacters + 1,
              "F6 the reply preview is the latest part of the reply, flattened to fit two or three lines")
        check(DMTentEmpty.text(playingElsewhere: false) == "Browser 沒有在播影片" && DMTentEmpty.buttonTitle == "打開 Browser"
              && DMTentEmpty.text(playingElsewhere: true) == "影片在 Browser 分頁播放",
              "G1 no video: one sentence + 打開 Browser (a video playing elsewhere is said as it is)")
        check(DMTentControlsText.source(host: "youtube.com") == "youtube.com・Browser 分頁" && DMTentControlsText.back == "回到 Browser"
              && DMTentControlsText.dismiss == "關掉子畫面",
              "G2 hover controls: <網域>・Browser 分頁 / 回到 Browser / 關掉子畫面")
        check(BrowserTentPlaceholder.text == "這支影片在私訊框倒放播放" && BrowserTentPlaceholder.takeBackTitle == "拿回來",
              "G3 the main window's tab says 這支影片在私訊框倒放播放 with 拿回來")
    }

    // MARK: - H 畫面證據（PNG）

    @MainActor static func evidence(_ check: Checker, root: URL, _ freshDefaults: (String) -> UserDefaults) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"], !folder.isEmpty else {
            check.skip("H 畫面證據：沒有 TATWO2_SELFTEST_ARTIFACTS（不是 lead-verify 跑的）")
            return
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { engine.shutdownAll() }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(library: library)))
        let store = GlobalDMStore(defaults: freshDefaults("shot"), chatGPTAllowed: { true })
        store.attach(model)
        store.select(.assistant)
        let size = GlobalDMForm.tent.size
        let margin = GlobalDMLayout.margin

        func shoot(_ name: String, _ content: some View, wait: Double = 0.5) async -> Bool {
            let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
            let view = content
                .frame(width: size.width, height: size.height)
                .environment(\.globalDMScreenRadius, DMPhone.screenRadius)
                .modifier(GlobalDMBoxChrome(cornerRadius: DMPhone.screenRadius))
                .padding(margin)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: canvas)
            let window = RigWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: canvas.width, height: canvas.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            let url = out.appendingPathComponent(name)
            do { try png.write(to: url) } catch { return false }
            print("W184TENT NOTE evidence \(url.path)")
            return bitmap.pixelsWide >= Int(canvas.width) && bitmap.pixelsHigh >= Int(canvas.height)
        }

        // 有影片：色塊代替 CEF 畫面，照正式的流程借進倒放框（倒放、沒在轉換、框掛在看得到的視窗上）。
        let playing = Rig(defaults: freshDefaults("shotVideo"), holderGrace: 0)
        defer { playing.close() }
        playing.source.add(BrowserLendableTab(id: "shot", host: "youtube.com", title: "影片", lastActiveAt: Date(),
                                              videoStartedAt: Date(), isSelected: true), color: NSColor(white: 0.08, alpha: 1))
        playing.settings.form = .tent
        let video = await shoot("tent-video.png", GlobalDMTentPane(store: store, model: model, video: playing.video))
        check(video && playing.source.lent.contains("shot"), "H1 tent with a video (a colour block stands in for the CEF page) rendered to PNG")
        playing.settings.form = .outerPortrait
        playing.settings.form = .tent
        let hover = await shoot("tent-video-hover-controls.png",
                                GlobalDMTentPane(store: store, model: model, video: playing.video, forceControls: true))
        check(hover, "H2 tent with the hover controls (<網域>・Browser 分頁, 回到 Browser, 關掉子畫面) rendered to PNG")
        playing.settings.form = .outerPortrait

        // 空狀態（兩句）。
        let empty = Rig(defaults: freshDefaults("shotEmpty"), holderGrace: 0)
        defer { empty.close() }
        empty.settings.form = .tent
        let nothing = await shoot("tent-empty.png", GlobalDMTentPane(store: store, model: model, video: empty.video))
        check(nothing, "H3 empty tent (Browser 沒有在播影片 + 打開 Browser) rendered to PNG")
        empty.settings.form = .outerPortrait
        let elsewhere = await shoot("tent-empty-playing-elsewhere.png", DMTentEmptyView(playingElsewhere: true) {})
        check(elsewhere, "H4 empty tent while a Browser video plays elsewhere rendered to PNG")

        // 三種卡（配對卡的字裡沒有碼）。
        let cards: [(String, DMTentCard)] = [
            ("tent-card-approval.png", .approval(target: "TATWO 助理")),
            ("tent-card-pairing.png", .pairing(remaining: 272)),
            ("tent-card-reply.png", .reply(target: "TATWO 助理", preview: "主設備上現在有兩件事在跑：ChatGPT build 的關口，和剛裝好的新版…")),
        ]
        var shots: [String] = []
        for (name, card) in cards {
            if await shoot(name, DMTentCardView(card: card) { _ in }) { shots.append(name) }
        }
        check(shots.count == cards.count, "H5 the three cards (等你核准, 配對進行中, 回覆中) rendered to PNG", "\(shots)")
        let placeholder = await shoot("main-window-placeholder.png", BrowserTentPlaceholder {})
        check(placeholder, "H6 the main window's placeholder (這支影片在私訊框倒放播放 + 拿回來) rendered to PNG")
    }
}
#endif
