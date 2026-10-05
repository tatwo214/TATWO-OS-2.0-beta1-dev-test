#if DEBUG
import AppKit
import Darwin
import Foundation
import TatwoCEFBridge

/// `TATWO2_SELFTEST=w183connect`：「一個開關」的連線意圖、Pod 自動建連接器、配對頁在私訊框（W183 R6b）。
/// 只在完整隔離的 staging 跑；不開通道、不啟動關口、不碰網路與真的鑰匙圈。
/// - 真的 HandsAuth／HandsService／HandsConnectHost／HandsConnectFlow；ChatGPT（OpenAI 那端）用假的：照關口會轉進來的樣子叫
///   hands_auth（register_client、authorize_begin、authorize_submit、token）與 hands_tools。
/// - Pod 與私訊框用可替換的宿主（假的：腳本化的外掛頁結果、原生導頁事件）。真的 ChatGPT 外掛頁 DOM 另在
///   tests/w183-connect.test.mjs 用本機假頁面跑真的 Pod 腳本；真 CEF 在這裡起不來就記 SKIP（不當通過）。
/// - 副設備走真的設備簽章（ssh-keygen 金鑰、驗章）：begin_connect、connect_status、cancel_connect；非擁有者要碼、狀態輪詢裡沒有碼。
enum HandsConnectAcceptance {
    final class Checker {
        var passed = 0, failed = 0, skipped = 0
        func callAsFunction(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W183CONNECT \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(600)))")
        }
        func skip(_ label: String) {
            skipped += 1
            print("W183CONNECT SKIP \(label)")
        }
    }

    static let hostID = "11111111-1111-4111-8111-111111111111"
    static let secondaryID = "22222222-2222-4222-8222-222222222222"
    static let publicHost = "os-for-chatgpt.example.com"
    static let account = "Fixture Account"
    static let identity = "u=user-fixture|w=ws-fixture|e=fixture-mail"

    // MARK: - 假的 ChatGPT（OpenAI 那端＋使用者瀏覽器上的關口頁）

    final class FakeChatGPT {
        let service: HandsService
        let redirect = HandsSettings.defaultCallbacks[0]
        let verifier = HandsAuth.random(bytes: 32)
        let state = "st-" + HandsAuth.random(bytes: 9)
        let binding = "sha256:" + HandsAuth.sha256Hex(Data(("csrf-" + UUID().uuidString).utf8))
        var clientID = ""
        var transaction: String?

        init(service: HandsService) { self.service = service }

        var challenge: String { HandsAuth.challenge(for: verifier) }

        @discardableResult
        func register() throws -> String {
            let result = try service.handle(method: "hands_auth", params: ["op": "register_client", "redirect_uris": [redirect], "client_name": "ChatGPT"])
            clientID = result["client_id"] as? String ?? ""
            return clientID
        }

        /// 使用者的瀏覽器打開配對頁（關口叫 authorize_begin）。回（交易編號或錯誤代碼, 頁面的 HTTP 狀態）。
        func begin() -> (String?, Int) {
            do {
                let result = try service.handle(method: "hands_auth", params: [
                    "op": "authorize_begin", "client_id": clientID, "redirect_uri": redirect, "code_challenge": challenge,
                    "code_challenge_method": "S256", "state": state, "resource": "https://\(HandsConnectAcceptance.publicHost)/mcp", "scope": "tatwo.hands"])
                transaction = result["transaction_id"] as? String
                return (transaction, 200)
            } catch let error as HandsWireError {
                return (error.code, error == .pairingBusy ? 409 : 403)
            } catch { return (nil, 503) }
        }

        var authorizeURL: URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = HandsConnectAcceptance.publicHost
            components.path = "/authorize"
            let items: [(String, String)] = [("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect), ("state", state),
                                             ("code_challenge", challenge), ("code_challenge_method", "S256"),
                                             ("resource", "https://\(HandsConnectAcceptance.publicHost)/mcp"), ("scope", "tatwo.hands")]
            components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
            return components.url!
        }

        func submit(_ code: String) throws -> String {
            let result = try service.handle(method: "hands_auth", params: ["op": "authorize_submit", "transaction_id": transaction ?? "",
                                                                           "pairing_code": code, "browser_binding_hash": binding])
            return result["authorization_code"] as? String ?? ""
        }

        func token(_ code: String) throws -> String {
            let result = try service.handle(method: "hands_auth", params: ["op": "token", "grant_type": "authorization_code", "code": code,
                                                                           "code_verifier": verifier, "client_id": clientID, "redirect_uri": redirect])
            return result["access_token"] as? String ?? ""
        }

        func tools(_ access: String) throws {
            _ = try service.handle(method: "hands_tools", params: ["access_token": access])
        }
    }

    // MARK: - 可替換的 Pod 與私訊框

    @MainActor
    final class FakePod: HandsConnectPodDriving {
        var onFrame: ((HandsPodFrame) -> Void)?
        var onLost: ((String) -> Void)?
        /// W183 R10 第二輪：送出「按」之前的錨點（跟正式的 Pod 驅動一樣：按下去的結果（pressed、unknown）才有，而且在 ChatGPT 開始 OAuth 之前）。
        var onPressDispatch: ((HandsPressAnchor) -> Void)?
        var onUserPressNeeded: (() -> Void)?   // W183 R12
        /// W183 R10 第二輪：建立指令一開始（按之前、準備期間）要做的事（自測：這時候就冒出配對頁）。
        var onCreateStart: (() -> Void)?
        /// 錨點記下的時間（自測核對「配對頁在錨點之後」）。
        private(set) var anchors: [HandsPressAnchor] = []
        /// W183 R10 第三輪：流程這一次按的操作編號（跟正式的 Pod 驅動一樣：指令一開始記下，錨點帶著它）。
        var pressOperation: String?
        /// W183 R10 第四輪：原生一開窗就通知（跟正式的 Pod 驅動一樣：第一次看到一個 popup 就先通知，再送它的畫面）。
        var onPopupOpened: ((Int, Date, Bool) -> Void)?
        /// 原生開了一個 popup（只開、還沒載入任何東西）。
        func openPopup(_ key: Int, openerIsMain: Bool = true) {
            guard generations[key] == nil else { return }
            generations[key] = 0
            onPopupOpened?(key, Date(), openerIsMain)
        }
        var readiness: HandsPodReadiness = .ready(account: HandsConnectAcceptance.account)
        var identityValue: String? = HandsConnectAcceptance.identity
        /// 讀帳號身分要等多久（自測：讓「取消晚了一步」有時間發生）。
        var identityDelay: UInt64 = 0
        /// W183 R11 最後一輪（GPT-6 R11c 審查 3）：true＝回發出那一刻的帳號（晚到的舊結果）；false＝回回來那一刻的。
        var identityAtCall = false
        var identityReads = 0
        var identityWaiting: ((Int) async -> Void)?
        var scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true, matches: [])
        var rescanResult: HandsConnectorScan?
        var createResult: HandsConnectorAction = .pressed
        /// 先依序回這些（用完了回 createResult）。
        var createQueue: [HandsConnectorAction] = []
        var reconnectResult: HandsConnectorAction = .pressed
        var authorization: HandsConnectorAuthorization = .unknown
        var inspections = 0
        var resolvedConnector: HandsConnectorScan.Match?
        var deletedConnectors: [String] = []
        var beforeDelete: (() -> Bool)?
        var deleteWaiting: (() async -> Void)?
        func inspect(_ connector: HandsConnectorScan.Match, url: String) async -> HandsConnectorAuthorization {
            inspections += 1
            resolvedConnector = connector
            return authorization
        }
        func deleteConnector(_ connector: HandsConnectorScan.Match, keeping: String, url: String) async -> Bool {
            guard let id = connector.id, id != keeping, connector.serverURL == url, beforeDelete?() != false else { return false }
            if let deleteWaiting { await deleteWaiting(); guard held else { return false } }
            deletedConnectors.append(id)
            scanResult.matches.removeAll { $0.id == id }
            return true
        }
        var devMode: Bool? = true
        var exclusive = true
        var calls: [String] = []
        var acks: [HandsConnectorAck?] = []
        var popupsClosed = 0
        /// 按下建立（或重新連線、手動標出）時：假 ChatGPT 開始 OAuth。
        var onAction: (() -> Void)?
        var windowOpenAt: [String: Bool] = [:]
        let window: () -> Bool
        var held = false
        var reloads = 0
        private var generations: [Int: UInt64] = [:]
        static let plugins = URL(string: "https://chatgpt.com/plugins")!

        init(window: @escaping () -> Bool) { self.window = window }

        func prepare() async -> HandsPodReadiness { calls.append("prepare"); return readiness }
        func account() async -> String? { if case .ready(let account) = readiness { return account }; return nil }
        func identity() async -> String? {
            identityReads += 1
            if let identityWaiting { await identityWaiting(identityReads) }
            let askedValue: String? = { if case .ready = readiness { return identityValue }; return nil }()
            if identityDelay > 0 { try? await Task.sleep(nanoseconds: identityDelay) }
            if identityAtCall { return askedValue }
            if case .ready = readiness { return identityValue }
            return nil
        }
        func acquireExclusive(timeout: TimeInterval) async -> Bool { calls.append("exclusive"); held = exclusive; return exclusive }
        func releaseExclusive() { if held { calls.append("release") }; held = false }
        func scan(url: String) async -> HandsConnectorScan {
            calls.append("scan")
            windowOpenAt["scan"] = window()
            if let rescanResult, calls.filter({ $0 == "scan" }).count > 1 { return rescanResult }
            return scanResult
        }
        func devModeNow() async -> Bool? { devMode }
        func create(url: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
            calls.append(acknowledged == nil ? "create" : "create-resume")
            acks.append(acknowledged)
            windowOpenAt["create"] = window()
            let operation = pressOperation ?? ""
            onCreateStart?()
            if userPressDelay > 0 { onUserPressNeeded?(); try? await Task.sleep(nanoseconds: userPressDelay) }
            let result = createQueue.isEmpty ? createResult : createQueue.removeFirst()
            pressed(result, operation: operation)
            return result
        }
        func reconnect(url: String, connectorID: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
            calls.append("reconnect:" + connectorID)
            acks.append(acknowledged)
            windowOpenAt["reconnect"] = window()
            pressed(reconnectResult, operation: pressOperation ?? "")
            return reconnectResult
        }
        func pressedForTest(operation: String) { pressed(.pressed, operation: operation) }
        /// 真的按下去（或可能按了）才有錨點、ChatGPT 才開始 OAuth（跟實機一樣：要使用者看、要勾的那幾種不會開始）。錨點在前、OAuth 在後。
        private func pressed(_ result: HandsConnectorAction, operation: String) {
            guard result == .pressed || result == .unknown else { return }
            let anchor = HandsPressAnchor(at: Date(), mainGeneration: generations[-1] ?? 0, mainURL: Self.plugins,
                                          popups: Set(generations.keys.filter { $0 != -1 }), operation: operation)
            anchors.append(anchor)
            onPressDispatch?(anchor)
            onAction?()
        }
        func highlight(url: String, name: String?) async -> Bool {
            calls.append("highlight")
            windowOpenAt["highlight"] = window()
            onAction?()
            return true
        }
        func reload(_ url: URL, popupKey: Int?) { reloads += 1 }
        func showDeveloperSettings() async { calls.append("settings") }
        func closePopups() { popupsClosed += 1 }

        // W183 R10：代勾、代填（預設＝勾不了、填不了：流程照舊交給使用者、退回顯示碼；R10 的自測自己打開）。
        /// 代勾：nil／false＝點不下去。
        var tickResult: Bool?
        /// W183 R10 第三輪：代勾的結果另外指定（例如派送前核到同意內容變了＝consentChanged）；nil＝照 tickResult。
        var tickOutcome: HandsTickOutcome?
        var ticks: [HandsTickTarget] = []
        /// 代勾的那一下（自測：ChatGPT 在 Create 之前就開配對頁之類）。
        var onTick: (() -> Void)?
        func tick(_ target: HandsTickTarget) async -> HandsTickOutcome {
            calls.append("tick")
            ticks.append(target)
            windowOpenAt["tick"] = window()
            onTick?()
            return tickOutcome ?? (tickResult == true ? .clicked : .notClicked)
        }
        /// 代填：nil＝填不了（退回顯示碼）。拿到的是碼、綁住的那一頁、它的證據；自測拿碼替「頁面」送出，不記碼。
        var fillBehavior: ((String, HandsPodFrame, String) -> HandsCodeFill)?
        var fills: [(frame: HandsPodFrame, evidence: String)] = []
        func fillPairingCode(_ code: String, frame: HandsPodFrame, evidence: String, publicHost: String) async -> HandsCodeFill {
            calls.append("fill")
            fills.append((frame, evidence))
            return fillBehavior?(code, frame, evidence) ?? .failed("unsupported")
        }

        // W183 R12（主導 2）：指路（預設＝指不了：卡片照舊那一句；R12 的自測自己打開）。不記進 calls（舊的檢查照舊比對整串）。
        var gestureResult = false
        private(set) var gesturePoints = 0
        private(set) var gestureClears = 0
        /// W183 R12（.035 實機）：ChatGPT 的對話框停在等待（等它自己的授權視窗）。
        var gestureWaiting = false
        /// W183 R12（.037 實機）：亮起來那一顆的字、TATWO 自己按了 Continue。
        var gestureLabel = ""
        var gestureClickedLabel: String?
        /// W183 R12（.036 實機）：ChatGPT 在對話框裡講了錯（沒建成）。
        var gestureRejected: String?
        /// W183 R12（.036 實機）：Create 量不到＝亮起來請使用者自己按（按了才回結果）。
        var userPressDelay: UInt64 = 0
        /// Only actual Create calls are recorded; reconnect cannot add another connector.
        private(set) var createdNames: [String] = []
        /// W183 R12（.037 實機）：用名字找那個建好、還沒授權的。
        var byNameResult: HandsConnectorAction = .notFound("by_name")
        var byNameQueue: [HandsConnectorAction] = []
        private(set) var byNameCalls: [String] = []
        private(set) var byNameAcks: [HandsConnectorAck?] = []
        func reconnectByName(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
            byNameCalls.append(name)
            byNameAcks.append(acknowledged)
            calls.append("reconnect-by-name")
            let result = byNameQueue.isEmpty ? byNameResult : byNameQueue.removeFirst()
            if result == .pressed { pressedForTest(operation: pressOperation ?? "") }
            return result
        }

        func create(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
            createdNames.append(name)
            return await create(url: url, acknowledged: acknowledged)
        }
        func pointAtGesture(url: String, name: String) async -> HandsGesturePoint {
            gesturePoints += 1
            if let gestureRejected { return .rejected(gestureRejected) }
            if let gestureClickedLabel { return .clicked(gestureClickedLabel) }
            return gestureWaiting ? .waiting : gestureResult ? .shown(gestureLabel) : .none
        }
        func clearGesture() { gestureClears += 1 }

        private func next(_ surface: Int) -> UInt64 {
            let value = (generations[surface] ?? 0) + 1
            generations[surface] = value
            return value
        }

        /// 原生瀏覽器回報一頁載入完成（預設：從外掛頁來、popup 是剛剛才開的）。
        func emit(_ url: URL, status: Int = 200, popup: Int? = nil, source: URL? = FakePod.plugins, openedAt: Date? = nil, openerIsMain: Bool = true) {
            if let popup, generations[popup] == nil { openPopup(popup, openerIsMain: openerIsMain) }
            let surface = popup ?? -1
            onFrame?(HandsPodFrame(url: url, generation: next(surface), loading: false, httpStatus: status, popup: popup != nil, popupKey: popup,
                                   source: source, openedAt: popup != nil ? (openedAt ?? Date()) : nil, openerIsMain: openerIsMain))
        }

        /// 那個畫面開始載入下一份。
        func emitLoading(popup: Int? = nil) {
            let surface = popup ?? -1
            if let popup, generations[popup] == nil { openPopup(popup) }
            onFrame?(HandsPodFrame(url: nil, generation: (generations[surface] ?? 0), loading: true, httpStatus: 0, popup: popup != nil,
                                   popupKey: popup, source: FakePod.plugins, openedAt: popup != nil ? Date() : nil, openerIsMain: true))
        }

        func emitClosed(popup: Int) {
            onFrame?(HandsPodFrame(url: nil, generation: 0, loading: false, httpStatus: 0, popup: true, popupKey: popup, closed: true, openerIsMain: true))
        }
    }

    @MainActor
    final class FakePresenter: HandsConnectPresenting {
        var isAvailable = true
        var shown = false
        var podVisible = false
        var codeVisible = false
        var popups: [Int] = []
        var codeEverVisible = false
        func show() { shown = true }
        func hide() { shown = false }
        func setPodVisible(_ visible: Bool) { podVisible = visible }
        func placePopup(key: Int) { popups.append(key) }
        func setCodeVisible(_ visible: Bool) { codeVisible = visible; if visible { codeEverVisible = true } }
        /// W183 R8b 審查：私訊框 Browser 現在看得到的 Pod 畫面（nil＝不限：R6b 的檢查照舊；自測設了＝只有那一個）。
        var visibleSurface: Int?
        func showsSurface(_ surface: Int) -> Bool { visibleSurface.map { $0 == surface } ?? true }
        /// W183 R12（主導 1）：私訊框看得到連線的網頁（false＝收起來了：等的時間不倒數）。
        var webShown = true
        var webOnScreen: Bool { webShown }
    }

    /// 一個主機世界：自己的手腳資料夾、設定（開著、主機是這台、公開主機名）、HandsConnectHost、假 Pod、假私訊框、流程。
    @MainActor
    final class World {
        let service: HandsService
        let host: HandsConnectHost
        let epoch: HandsLocked<String>
        let pod: FakePod
        let presenter: FakePresenter
        var copied: [String] = []
        var flow: HandsConnectFlow!

        /// configure（W183 R7a）：主機上的專案、入口位置（HandsScopeAcceptance.swift 的 ScopeFixture）。
        /// disconnect（W183 R11）：已連線卡的［斷線］（自測：撤銷這個世界的主機；nil＝流程的預設，不假裝斷了）。W183 R11 第二輪：逐台的結果
        ///（HandsDisconnectOutcome）；正式的三條撤銷路（本機、主設備 RPC、信箱）在 w183build 的 HandsBuildR11Acceptance 用正式的 controller 驗。
        /// accounts（W183 R11 第二輪，GPT-6 R11 審查 4）：這台按［連線］連上的紀錄（nil＝不記）。
        init(_ base: URL, _ name: String, owner: String = HandsConnectAcceptance.hostID, link: ((HandsConnectHost) -> any HandsConnectLink)? = nil,
             configure: ((HandsService) -> Void)? = nil,
             disconnect: (@MainActor (HandsService, [String]) async -> [String: HandsDisconnectOutcome])? = nil,
             accounts: HandsConnectAccounts? = nil, loginGeneration: (@MainActor () -> Int)? = nil,
             consentApprovals: HandsConnectDigestBook? = nil, pendingCreateBook: HandsConnectDigestBook? = nil,
             connectLog: HandsConnectLog? = nil, connectors: HandsConnectorRegistry? = nil,
             hostAuthorization: (@MainActor (String, String) -> Bool?)? = nil,
             linkFor: (@MainActor (String) -> (link: (any HandsConnectLink)?, problem: String?))? = nil) throws {
            let root = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let real = URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path)
            let service = HandsService(paths: HandsPaths(root: real.appendingPathComponent("hands", isDirectory: true)))
            service.deviceIDOverride = HandsConnectAcceptance.hostID
            configure?(service)
            _ = try service.updateSettings {
                $0.enabled = true; $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = HandsConnectAcceptance.publicHost; $0.level = 1
            }
            let epoch = HandsLocked("epoch-1")
            let host = HandsConnectHost(service: service, epoch: { epoch.get() }, localDeviceID: { HandsConnectAcceptance.hostID },
                                        hostName: { "Primary One" }, serviceRunning: { true })
            host.attach()
            let pod = FakePod(window: { service.auth.windowExpiresAt != nil })
            let presenter = FakePresenter()
            let chosen: any HandsConnectLink = link?(host) ?? HandsConnectLocalLink(host: host, ownerID: owner)
            self.service = service
            self.host = host
            self.epoch = epoch
            self.pod = pod
            self.presenter = presenter
            var timeouts = HandsConnectFlow.Timeouts()
            timeouts.exclusive = 1; timeouts.authorizeAppears = 3; timeouts.redeem = 3; timeouts.firstMCP = 3; timeouts.gestureHint = 1
            timeouts.tickSettle = 0.05; timeouts.fillSettle = 1   // W183 R10
            timeouts.gesturePoint = 0.2; timeouts.gestureRetry = 0.3   // W183 R12（主導 2）
            timeouts.popupWaitNotice = 0.6   // W183 R12（.035 實機）
            var dependencies = HandsConnectFlow.Dependencies(
                link: { (chosen, nil) }, pod: { pod }, presenter: { presenter }, localDeviceID: { owner },
                copy: { [weak self] text in self?.copied.append(text) }, pollInterval: 0.05, timeouts: timeouts)
            if let disconnect { dependencies.disconnect = { hosts in await disconnect(service, hosts) } }
            dependencies.accounts = accounts
            if let loginGeneration { dependencies.loginGeneration = loginGeneration }   // W183 R11 最後一輪（GPT-6 R11c 審查 3）
            dependencies.consentApprovals = consentApprovals   // W183 R12（主導 3）
            dependencies.pendingCreateBook = pendingCreateBook   // W183 R12（主導 5）
            dependencies.connectors = connectors
            if let hostAuthorization { dependencies.hostAuthorization = hostAuthorization }
            dependencies.linkFor = linkFor
            dependencies.connectLog = connectLog   // W183 R12（.033 實機）：正式版的連線紀錄
            flow = HandsConnectFlow(dependencies: dependencies)
        }

        /// 假 ChatGPT 在 Pod 按下建立後開始 OAuth：註冊、打開配對頁（Pod 同頁跳轉或另開視窗）。
        func chatgptStarts(_ chatgpt: FakeChatGPT, popup: Int? = nil, before: (() -> Void)? = nil) {
            pod.onAction = { [weak self] in
                guard let self else { return }
                _ = try? chatgpt.register()
                before?()
                let (_, status) = chatgpt.begin()
                let url = chatgpt.authorizeURL
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self.pod.emit(url, status: status, popup: popup)
                }
            }
        }

        var pairing: HandsConnectPairingView? { if case .pairing(let view)? = flow.card { return view }; return nil }
        var attemptID: String? { host.currentAttemptID }
    }

    @MainActor static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    static func isConfirm(_ card: HandsConnectCard?) -> Bool { if case .confirm? = card { return true }; return false }

    /// W183 R8c：擁有者送給主機的配對頁證據（第二版：四個 OAuth 參數再綁 target、issuer／resource、attempt、世代）。
    static func evidence(_ chatgpt: FakeChatGPT, attempt: String, epoch: String, target: String = hostID) -> String {
        HandsAuth.boundEvidence(HandsAuth.evidenceHash(clientID: chatgpt.clientID, redirectURI: chatgpt.redirect, state: chatgpt.state,
                                                       challenge: chatgpt.challenge),
                                target: target, issuer: "https://" + publicHost, resource: "https://\(publicHost)/mcp", attempt: attempt,
                                setupEpoch: epoch)
    }

    // MARK: - 進入點

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let stagingPath = environment["TATWO_STAGING_ROOT"], let staging = HandsPath.realpath(stagingPath) else {
            throw BotLibraryError.invalid("w183connect needs a fully isolated staging environment")
        }
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w183connect-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let check = Checker()
        await pairingClipboardChecks(check)
        try await happyPath(check, base)
        try await popupPath(check, base)
        try await wrongCodeAndCancel(check, base)
        try await raceCancelToken(check, base)
        try await developerMode(check, base)
        try await existingConnector(check, base)
        try await capabilityFailures(check, base)
        try await attackerFirst(check, base)
        try await answerLink(check, base)
        try hostRules(check, base)
        try await invalidation(check, base)
        try manualWindowCodes(check, base)
        try await remote(check, base)
        try await warningAck(check, base)
        try await leftPairingPage(check, base)
        try await provenance(check, base)
        try await accountAtConfirm(check, base)
        try await cancelAdoptsHost(check, base)
        try await staleCommitPoints(check, base)
        try restartRevokesUnfinished(check, base)
        try await lateBegin(check, base)
        try await pendingCreate(check, base)
        try await scopeCard(check, base)   // W183 R7a：［連線］卡上選等級與專案（HandsScopeAcceptance.swift）
        try await r9Checks(check, base)   // W183 R9：ChatGPT 改版（新增 ▾ → 建立 MCP 應用程式）、手動步驟、專案說法一致（HandsConnectR9Acceptance.swift）
        try await r10Checks(check, base)   // W183 R10：按一下就好——代勾、代填與它們的退路（HandsConnectR10Acceptance.swift）
        try await r11Checks(check, base)   // W183 R11：快速接通與斷線——預設 Codex＋記憶、入口、沒登入自動接著、斷線重接（HandsConnectR11Acceptance.swift）
        try await r12Checks(check, base)   // W183 R12：說明改了的卡（同意並繼續、記住這一版）、重連不多建連接器、收起私訊框不倒數（HandsConnectR12Acceptance.swift）
        await podLease(check)
        realCEF(check)
        print("W183CONNECT SUMMARY failures=\(check.failed) passed=\(check.passed) skipped=\(check.skipped)")
        return check.failed == 0
    }

    // MARK: - 1. 成功：這個 attempt 的交易 → grant → 這個 grant 的第一次 /mcp

    @MainActor static func happyPath(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "happy")
        let service = world.service
        // 先有一筆別的（手動配對的）grant：它的 /mcp 不能算這次成功。
        let other = FakeChatGPT(service: service)
        try other.register()
        try service.startPairing()
        _ = other.begin()
        let otherCode = service.auth.pendingCard?.pairingCode ?? ""
        let otherAccess = try other.token(try other.submit(otherCode))
        check(!otherAccess.isEmpty && service.auth.pendingCard == nil, "準備：一筆手動配對的舊 grant")
        // HandsState：綁 attempt 的卡不上設定頁與 Island。
        let state = HandsState(service: service)

        let chatgpt = FakeChatGPT(service: service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        let confirmed = await waitUntil(5) { isConfirm(world.flow.card) }
        if case .confirm(let offer, let account)? = world.flow.card {
            check(confirmed && account == Self.account && offer.publicHost == publicHost && offer.hostName == "Primary One"
                  && offer.scope.level == 1 && offer.scope.projects.isEmpty && offer.callbackHosts == ["chatgpt.com"]
                  && offer.mcpURL == "https://\(publicHost)/mcp" && world.flow.phase == .waitingTap && world.presenter.shown,
                  "［連線］卡：Pod 目前帳號、主機、服務網址、L1、專案（沒有）、回到的網域；phase＝等你按", "\(offer)")
        } else {
            check(false, "［連線］卡出現", "\(String(describing: world.flow.card))")
        }
        check(service.auth.windowExpiresAt == nil && world.host.currentAttemptID == nil, "卡片出來之前不開配對窗口（T15：按［連線］才開）")
        world.flow.connect()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let attempt = world.attemptID ?? ""
        let tx = service.auth.attemptTransaction(attempt)
        check(paired && world.pod.windowOpenAt["scan"] == false && world.pod.windowOpenAt["create"] == true,
              "順序：讀清單時窗口關著；按建立之前主機才開窗口", "\(world.pod.windowOpenAt) \(world.pod.calls)")
        check(tx != nil && world.pairing?.pairingCode == tx?.pairingCode && world.pairing?.displayCode == tx?.displayCode
              && world.flow.phase == .waitingPairing && world.presenter.codeVisible && world.presenter.podVisible,
              "配對頁在私訊框（同頁）：卡片上方顯示交易碼、剩餘時間、8 碼（跟主機這一筆一樣）；碼在畫面上＝敏感")
        check(tx?.scope.level == 1 && tx?.scope.projects.isEmpty == true, "authorize_begin 用按下時的範圍快照")
        check(state.pendingPairing == nil && service.auth.pendingCard?.attemptID == attempt,
              "綁 attempt 的確認卡不上設定頁與 Island（HandsState 不收）")
        let remoteStatus = HandsRemote.status(HandsRemote.Host(service: service, phase: { .running(url: "https://\(publicHost)/mcp") },
                                                               setup: { nil }, localDeviceID: { hostID }))
        let statusJSON = String(decoding: try JSONSerialization.data(withJSONObject: remoteStatus), as: UTF8.self)
        check(remoteStatus["card"] == nil && !statusJSON.contains(tx?.pairingCode ?? "NOPE"),
              "所有設備輪詢的 remote_hands_status 裡沒有配對碼")
        let code = try chatgpt.submit(tx?.pairingCode ?? "")
        check(!code.isEmpty, "使用者照卡片打 8 碼：換到一次性授權碼")
        let authorized = await waitUntil(3) { world.flow.phase == .verifying && !world.presenter.codeVisible }
        let access = try chatgpt.token(code)
        let grants = service.auth.attemptGrantIDs(attempt)
        let granted = await waitUntil(3) { if case .verifying(let text)? = world.flow.card { return text.contains("授權完成") }; return false }
        check(authorized && granted && grants.count == 1 && world.flow.phase == .verifying,
              "授權完成（verifying）跟工具連上分開：grant 有了但還沒 /mcp＝不是已連線", "\(String(describing: world.flow.card))")
        // W183 R6b 審查：擁有者確認之前 grant 是暫時的：能拿工具清單、不能呼叫工具。
        var callBlocked = false
        let toolName = "hands_status"
        do { _ = try service.handle(method: "hands_call", params: ["access_token": access, "name": toolName]) }
        catch let error as HandsWireError { callBlocked = error == .rateLimited }
        check(service.auth.grant(forAccess: access)?.provisional == true && callBlocked,
              "擁有者確認之前：這個 attempt 的 grant 是暫時的，不能呼叫工具（只能拿工具清單）")
        // W183 R8a 審查（GPT-6）：暫時的 grant 在畫面上不算「已連線」——HandsState.confirmedGrants 不含它、
        // 副設備看的 remote_hands_status 也標 provisional（ChatGPT build 的節點與那一行狀態只看確認過的）。
        state.refresh()
        let attemptGrant = grants.first ?? ""
        let hostView = HandsRemoteStatus(HandsRemote.status(HandsRemote.Host(service: service, phase: { .running(url: "https://\(publicHost)/mcp") },
                                                                             setup: { nil }, localDeviceID: { hostID })))
        check(!attemptGrant.isEmpty && state.activeGrants.contains { $0.id == attemptGrant && $0.provisional }
              && !state.confirmedGrants.contains { $0.id == attemptGrant }
              && hostView?.grants.first { $0.id == attemptGrant }?.provisional == true,
              "W183 R8a 審查 暫時的 grant：畫面不算已連線（HandsState.confirmedGrants 不含、remote_hands_status 標 provisional）")
        try other.tools(otherAccess)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(world.flow.phase == .verifying, "別的 grant 的 /mcp 不算這次成功（不是「任何有效 grant」）")
        try chatgpt.tools(access)
        let connected = await waitUntil(3) { world.flow.phase == .connected }
        let record = grants.first.flatMap { service.auth.grantRecord($0) }
        check(connected && record?.isActive == true && record?.level == 1 && world.host.currentAttemptID == nil
              && service.auth.grant(forAccess: access)?.provisional == false && world.pod.identityReads >= 3,
              "這個 attempt 的 grant 第一次 /mcp 成功、擁有者再核對一次 Pod 帳號並確認＝已連線（終態；grant 轉正）")
        state.refresh()
        check(state.confirmedGrants.contains { $0.id == attemptGrant },
              "W183 R8a 審查 grant 轉正之後才算已連線（HandsState.confirmedGrants 含它）")
        let reopened = HandsAuth(url: service.auth.url)
        check(reopened.grant(forAccess: access) != nil, "確認過的 grant：App 重開照樣有效")
        let log = world.flow.debugLog.joined(separator: "\n") + (world.flow.problem ?? "")
        check(!log.contains(tx?.pairingCode ?? "NOPE") && !log.contains(chatgpt.state) && !log.contains(chatgpt.clientID),
              "流程紀錄與錯誤文字沒有配對碼、state、client_id")
        // 成功之後取消：只有一個終態（不撤銷已連上的）。
        let after = try world.host.cancel(attemptID: attempt, sender: hostID, reason: "late")
        check(after.state == .connected && service.auth.grantRecord(grants.first ?? "")?.isActive == true, "成功之後的取消不改終態")
    }

    // MARK: - 2. ChatGPT 另開視窗（popup）

    @MainActor static func popupPath(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "popup")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, popup: 77)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        check(paired && world.presenter.popups == [77] && world.pairing?.popup == true && !world.presenter.podVisible,
              "配對頁在另開的視窗：那個視窗放到私訊框的位置、卡片照樣顯示碼", "\(world.presenter.popups)")
        world.flow.cancel(reason: "test_done")
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil }
        check(closed && world.flow.phase == .idle && !world.presenter.shown, "R6a 的 cancel(reason:)：窗口關掉、卡片收回、phase 回 idle")
    }

    // MARK: - 3. 錯碼、取消、取消後舊授權碼兌換

    @MainActor static func wrongCodeAndCancel(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "wrong")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let right = world.pairing?.pairingCode ?? ""
        let wrong = right == "22222222" ? "33333333" : "22222222"
        var wrongRefused = false
        do { _ = try chatgpt.submit(wrong) } catch let error as HandsWireError { wrongRefused = error.code == "invalid_pairing_code" }
        let updated = await waitUntil(3) { world.pairing?.attemptsLeft == 4 }
        check(wrongRefused && updated && world.flow.phase == .waitingPairing, "錯碼：還可以錯 4 次（卡片跟著變）")
        // 對的碼送出、授權碼還沒兌換時取消：授權碼作廢。
        let authCode = try chatgpt.submit(right)
        let attempt = world.attemptID ?? ""
        check(world.service.auth.attemptHasPendingCode(attempt), "對的碼：授權碼等 ChatGPT 來換")
        world.flow.dismiss()
        let cancelled = await waitUntil(3) { !world.service.auth.attemptHasPendingCode(attempt) }
        var tokenRefused = false
        do { _ = try chatgpt.token(authCode) } catch let error as HandsWireError { tokenRefused = error.code == "invalid_grant" }
        check(cancelled && tokenRefused && world.service.auth.attemptGrantIDs(attempt).isEmpty && world.flow.phase == .waitingTap,
              "取消＝窗口、交易、還沒兌換的授權碼作廢；取消後舊授權碼換不到 grant；卡片收起、回到等你按")
    }

    // MARK: - 4. 取消與 /token 同時：只有一個終態

    static func raceCancelToken(_ check: Checker, _ base: URL) async throws {
        let root = base.appendingPathComponent("race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let host = HandsConnectHost(service: service, epoch: { "e" }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        let offer = try host.offer()
        // 在背景跑（主機核對範圍要回主執行緒讀專案名稱：主執行緒不能卡在 group.wait）。
        let (consistent, evidence) = try await HandsConnectOffMain.run { () -> (Bool, [String]) in
        var consistent = true, evidence: [String] = []
        for round in 0..<6 {
            let chatgpt = FakeChatGPT(service: service)
            try chatgpt.register()
            let id = UUID().uuidString
            _ = try host.begin(HandsConnectRequest(attemptID: id, setupEpoch: "e", ownerDeviceID: hostID, scopeDigest: offer.digest, mcpURL: offer.mcpURL),
                               sender: hostID)
            _ = chatgpt.begin()
            let hash = HandsConnectAcceptance.evidence(chatgpt, attempt: id, epoch: "e")   // W183 R8c：第二版證據
            let code = (try? host.status(attemptID: id, sender: hostID, evidence: hash))?.transaction?.pairingCode ?? ""
            let authCode = (try? chatgpt.submit(code)) ?? ""
            let group = DispatchGroup()
            let tokenResult = HandsLocked<String?>(nil)
            group.enter()
            DispatchQueue.global().async { tokenResult.set(try? chatgpt.token(authCode)); group.leave() }
            group.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(round % 3)) {
                _ = try? host.cancel(attemptID: id, sender: hostID, reason: "race"); group.leave()
            }
            group.wait()
            let final = try host.status(attemptID: id, sender: hostID, evidence: nil)
            let live = service.auth.attemptGrantIDs(id)
            // 終態一定是取消（第一次 /mcp 還沒來）；grant 不能還有效；token 就算先拿到也已經被撤銷（每次呼叫都重查）。
            let tokenStillWorks = tokenResult.get().flatMap { service.auth.grant(forAccess: $0) } != nil
            if final.state != .cancelled || !live.isEmpty || tokenStillWorks { consistent = false }
            evidence.append("\(final.state.rawValue)/\(live.count)/\(tokenResult.get() == nil ? "refused" : "issued")")
        }
        return (consistent, evidence)
        }
        check(consistent, "取消與 /token 同時：只有一個終態（取消），token 先到也被撤銷，沒有留下有效 grant", evidence.joined(separator: " "))
    }

    // MARK: - 5. 開發者模式沒開：不代按、窗口關著，打開後接著做

    @MainActor static func developerMode(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "devmode")
        world.pod.scanResult.devMode = false
        world.pod.devMode = false
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let waiting = await waitUntil(5) { world.flow.phase == .waitingUser }
        check(waiting && world.service.auth.windowExpiresAt == nil && !world.pod.calls.contains("create") && world.presenter.podVisible,
              "開發者模式沒開：不代按、私訊框顯示 Pod 那一頁、等的時候配對窗口關著", "\(world.pod.calls)")
        world.pod.scanResult.devMode = true
        world.pod.devMode = true
        let resumed = await waitUntil(5) { world.pod.calls.contains { $0.hasPrefix("create") } }
        check(resumed && world.pod.windowOpenAt["create"] == true, "使用者自己打開之後：重建意圖（新 attempt）、窗口開好才按建立", "\(world.pod.calls)")
        let beforeCreate = world.pod.calls.prefix { !$0.hasPrefix("create") }
        check(world.pod.calls.contains("settings") && !beforeCreate.contains("release") && world.pod.acks.first == .some(nil)
              && world.pod.calls.contains("create") && !world.pod.calls.contains("create-resume"),
              "開發者模式：拿著 Pod 換到設定頁等（聊天不會把頁面換走）；自動接著做時不帶「看過警語」（新的表單照樣交給使用者）",
              "\(world.pod.calls)")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: - 6. 已有同網址的連接器

    @MainActor static func existingConnector(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "existing")
        world.pod.scanResult.matches = [.init(id: "conn_1", name: "fixture", auth: "oauth")]
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        check(paired && world.pod.calls.contains("reconnect:conn_1") && !world.pod.calls.contains("create"),
              "已有指向同網址（OAuth）的：不重建、只重新連線清單認出的那一個 id（以網址＋OAuth 辨識，不看名字）", "\(world.pod.calls)")
        world.flow.cancel(reason: "test_done")

        let noAuth = try World(base, "existing-noauth")
        noAuth.pod.scanResult.matches = [.init(id: "conn_2", name: "fixture", auth: "none")]
        noAuth.flow.offer()
        _ = await waitUntil(5) { isConfirm(noAuth.flow.card) }
        noAuth.flow.connect()
        let manual = await waitUntil(5) { noAuth.flow.phase == .needsManual }
        check(manual && noAuth.service.auth.windowExpiresAt == nil && !noAuth.pod.calls.contains("create"),
              "同網址但不是 OAuth：不重用、不降成免驗證、不開窗口（需要手動）")

        let unknown = try World(base, "existing-unknownlist")
        unknown.pod.scanResult.listKnown = false
        unknown.flow.offer()
        _ = await waitUntil(5) { isConfirm(unknown.flow.card) }
        unknown.flow.connect()
        let blind = await waitUntil(5) { unknown.flow.phase == .needsManual }
        check(blind && !unknown.pod.calls.contains("create"), "讀不到外掛清單＝不知道有沒有建過：不按建立")
    }

    // MARK: - 7. 能力不足、明確不符、結果未知

    @MainActor static func capabilityFailures(_ check: Checker, _ base: URL) async throws {
        let ambiguous = try World(base, "ambiguous")
        ambiguous.pod.createResult = .ambiguous("form")
        ambiguous.flow.offer()
        _ = await waitUntil(5) { isConfirm(ambiguous.flow.card) }
        ambiguous.flow.connect()
        let manual = await waitUntil(5) { ambiguous.flow.phase == .needsManual }
        let closed = await waitUntil(3) { ambiguous.service.auth.windowExpiresAt == nil }
        check(manual && closed, "表單不只一個（或找不到）：不猜、這次取消（窗口關掉）、給「再連一次」或「手動」")
        // 手動＝同一套意圖（從可信入口重開）：開窗口、網址已複製、標出要按哪裡；碼照樣只在核對過的配對頁。
        let chatgpt = FakeChatGPT(service: ambiguous.service)
        ambiguous.chatgptStarts(chatgpt)
        ambiguous.flow.retry(manual: true)
        let guided = await waitUntil(5) { if case .manual? = ambiguous.flow.card { return true }; return false }
        let paired = await waitUntil(8) { ambiguous.pairing?.pairingCode != nil }
        check(guided && paired && ambiguous.copied == ["https://\(publicHost)/mcp"] && ambiguous.pod.calls.contains("highlight")
              && ambiguous.pod.windowOpenAt["highlight"] == true,
              "手動：網址已複製、Pod 標出要按哪裡、窗口開著；配對頁出來後照樣顯示碼", "\(ambiguous.pod.calls)")
        ambiguous.flow.cancel(reason: "test_done")

        let tampered = try World(base, "tampered")
        tampered.pod.createResult = .refused("url_mismatch")
        tampered.flow.offer()
        _ = await waitUntil(5) { isConfirm(tampered.flow.card) }
        tampered.flow.connect()
        let refused = await waitUntil(5) { tampered.flow.phase == .refused }
        let tamperClosed = await waitUntil(3) { tampered.service.auth.windowExpiresAt == nil }
        check(refused && tamperClosed && !tampered.presenter.codeEverVisible, "表單網址被改：明確不符＝終止、窗口關掉、沒有顯示碼")

        let unknown = try World(base, "unknown")
        unknown.pod.createResult = .unknown
        unknown.pod.rescanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true, matches: [])
        unknown.flow.offer()
        _ = await waitUntil(5) { isConfirm(unknown.flow.card) }
        unknown.flow.connect()
        let stopped = await waitUntil(5) { unknown.flow.phase == .needsManual }
        check(stopped && unknown.pod.calls.filter({ $0.hasPrefix("create") }).count == 1 && unknown.pod.calls.filter({ $0 == "scan" }).count == 2,
              "按了建立、結果未知：先讀清單，不再按建立", "\(unknown.pod.calls)")

        let noShow = try World(base, "noshow")
        noShow.flow.offer()
        _ = await waitUntil(5) { isConfirm(noShow.flow.card) }
        noShow.flow.connect()
        let hinted = await waitUntil(2.5) { if case .working(let text)? = noShow.flow.card { return text.contains("點一下") }; return false }
        let gaveUp = await waitUntil(5) { noShow.flow.phase == .needsManual }
        let noShowClosed = await waitUntil(3) { noShow.service.auth.windowExpiresAt == nil }
        check(hinted && gaveUp && noShowClosed, "授權頁沒出現：先提示在頁面上點一下（popup 手勢保護不放寬），時限到＝取消、要手動")

        let foreign = try World(base, "foreign")
        foreign.pod.onAction = { [weak foreign] in
            Task { @MainActor in foreign?.pod.emit(URL(string: "https://evil.example.net/authorize?client_id=x&code_challenge=y")!) }
        }
        foreign.flow.offer()
        _ = await waitUntil(5) { isConfirm(foreign.flow.card) }
        foreign.flow.connect()
        let wrongDomain = await waitUntil(5) { foreign.flow.phase == .refused }
        check(wrongDomain && !foreign.presenter.codeEverVisible, "授權頁在別的網域：明確不符＝終止、沒有碼")
    }

    // MARK: - 8. 攻擊者先占交易

    @MainActor static func attackerFirst(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "attacker")
        let attacker = FakeChatGPT(service: world.service)
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, before: {
            _ = try? attacker.register()
            _ = attacker.begin()   // 攻擊者的 ChatGPT 搶在前面開了這個窗口的交易
        })
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let refused = await waitUntil(8) { world.flow.phase == .refused }
        let attempt = world.flow.debugLog.contains { $0.contains("authorize observed") }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil && world.service.auth.pendingCard == nil }
        var attackerDead = false
        do { _ = try attacker.submit("22222222") } catch let error as HandsWireError { attackerDead = error.code == "pairing_window_closed" || error.code == "pairing_expired" }
        check(refused && attempt && closed && attackerDead && !world.presenter.codeEverVisible && world.service.auth.activeGrantIDs.isEmpty,
              "攻擊者先占交易：Pod 看到的配對頁對不上＝終止、不顯示碼、那一筆作廢、沒有新 grant", "\(world.flow.debugLog.suffix(4))")
    }

    // MARK: - 9. ChatGPT 回答裡的授權連結、配對中途另一組授權頁

    @MainActor static func answerLink(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "answer")
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        // 還沒按［連線］：對話裡的授權連結（就算網域對）一律不算。
        let link = FakeChatGPT(service: world.service)
        try link.register()
        world.pod.emit(link.authorizeURL)
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(world.flow.debugLog.contains { $0.contains("ignored") } && world.flow.phase == .waitingTap && world.service.auth.windowExpiresAt == nil,
              "回答裡的授權連結（沒按［連線］、不是這一輪的建立之後）：不算、不開窗口、沒有碼")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let second = FakeChatGPT(service: world.service)
        try second.register()
        world.pod.emit(second.authorizeURL)
        let refused = await waitUntil(5) { world.flow.phase == .refused }
        check(refused && !world.presenter.codeVisible, "配對中途 Pod 出現另一組授權參數的配對頁：明確不符＝終止、碼收起來")
    }

    // MARK: - 10. 主機規則：一次一個 attempt、世代、範圍、非擁有者

    static func hostRules(_ check: Checker, _ base: URL) throws {
        let root = base.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let epoch = HandsLocked("e1")
        let host = HandsConnectHost(service: service, epoch: { epoch.get() }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        let offer = try host.offer()
        func request(_ id: String, epoch: String = "e1", owner: String = hostID, digest: String? = nil) -> HandsConnectRequest {
            HandsConnectRequest(attemptID: id, setupEpoch: epoch, ownerDeviceID: owner, scopeDigest: digest ?? offer.digest, mcpURL: offer.mcpURL)
        }
        func refusal(_ body: () throws -> Void) -> HandsConnectRefusal? {
            do { try body(); return nil } catch let error as HandsConnectRefusal { return error } catch { return .invalid }
        }
        let a = UUID().uuidString, b = UUID().uuidString
        let first = try host.begin(request(a), sender: hostID)
        let again = try host.begin(request(a), sender: hostID)
        let busy = refusal { _ = try host.begin(request(b), sender: hostID) }
        check(first.state == .open && again.state == .open && busy == .busy && host.currentAttemptID == a,
              "一次只接受一個 attempt：同 ID 冪等、不同 ID 回忙碌（兩台設備、兩次點擊並行）")
        let notOwner = refusal { _ = try host.status(attemptID: a, sender: secondaryID, evidence: nil) }
        let notOwnerCancel = refusal { _ = try host.cancel(attemptID: a, sender: secondaryID, reason: "x") }
        check(notOwner == .notOwner && notOwnerCancel == .notOwner && host.currentAttemptID == a, "非擁有者要狀態、要碼、要取消：一律拒絕")
        // 範圍在 attempt 進行中改了：authorize_begin 前核對＝取消（這一筆開不了）。
        _ = try service.updateSettings { $0.level = 2 }
        let chatgpt = FakeChatGPT(service: service)
        try chatgpt.register()
        let (began, _) = chatgpt.begin()
        let after = try host.status(attemptID: a, sender: hostID, evidence: nil)
        check(began == "pairing_window_closed" && after.state == .cancelled && after.reason == "scope_changed",
              "範圍在按下之後改了：這個 attempt 取消，authorize_begin 不用新的範圍", "\(String(describing: began)) \(after)")
        _ = try service.updateSettings { $0.level = 1 }
        let stale = refusal { _ = try host.begin(request(UUID().uuidString, epoch: "e0"), sender: hostID) }
        let wrongScope = refusal { _ = try host.begin(request(UUID().uuidString, digest: "sha256:00"), sender: hostID) }
        let fakeOwner = refusal { _ = try host.begin(request(UUID().uuidString, owner: secondaryID), sender: hostID) }
        check(stale == .staleEpoch && wrongScope == .scopeChanged && fakeOwner == .invalid,
              "舊世代晚到、範圍快照對不上、替別台申請：一律不收")
        let c = UUID().uuidString
        _ = try host.begin(request(c), sender: hostID)
        epoch.set("e2")   // 主機的設定流程取消或重開：世代換了
        let moved = try host.status(attemptID: c, sender: hostID, evidence: nil)
        check(moved.state == .cancelled && moved.reason == "epoch_changed" && service.auth.windowExpiresAt == nil,
              "attempt 進行中世代換了：取消、窗口關掉")
        let done = refusal { _ = try host.begin(request(a, epoch: "e2", digest: try host.offer().digest), sender: hostID) }
        let finished = try host.begin(HandsConnectRequest(attemptID: a, setupEpoch: "e2", ownerDeviceID: hostID,
                                                          scopeDigest: try host.offer().digest, mcpURL: offer.mcpURL), sender: hostID)
        check(done == nil && finished.state == .cancelled && service.auth.windowExpiresAt == nil, "結束了的 attempt 同 ID 再送：回原來的終態、不重開")
    }

    // MARK: - 11. 作廢：鎖螢幕、帳號切換

    @MainActor static func invalidation(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "invalidate")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        world.flow.invalidate("screen_locked")
        let back = await waitUntil(5) { isConfirm(world.flow.card) && world.flow.phase == .waitingTap }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil }
        check(back && closed && !world.presenter.codeVisible && world.flow.problem?.contains("螢幕") == true,
              "鎖螢幕：這個 attempt 取消（窗口關掉）、碼收起來、回到等你按（卡片再出來）")

        let switched = try World(base, "account")
        switched.flow.offer()
        _ = await waitUntil(5) { isConfirm(switched.flow.card) }
        switched.pod.readiness = .ready(account: "Other Account")
        switched.flow.connect()
        let reshown = await waitUntil(5) {
            if case .confirm(_, let account)? = switched.flow.card { return account == "Other Account" }
            return false
        }
        check(reshown && !switched.pod.calls.contains("exclusive") && switched.service.auth.windowExpiresAt == nil,
              "按下時 Pod 帳號跟卡片上的不一樣：不開窗口，卡片換成新帳號讓你再看一次")

        let login = try World(base, "login")
        login.pod.readiness = .needsLogin
        login.flow.offer()
        _ = await waitUntil(5) { isConfirm(login.flow.card) }
        login.flow.connect()
        let waiting = await waitUntil(5) { login.flow.phase == .waitingUser && login.presenter.podVisible }
        let closedWhileLogin = login.service.auth.windowExpiresAt == nil && !login.pod.calls.contains("exclusive")
        login.pod.readiness = .ready(account: Self.account)
        // W183 R11（主導 B；取代「登入後回到確認卡」）：按了［連線］＝同意了；登入是他自己在框裡做的——登入好＝自動接著連（不回到確認卡、
        // 不用再按一次）。守的照舊：等登入的時候窗口一直關著、不拿獨占；接著連的那一輪照同一張卡的範圍，帳號＝他剛登入的那一個。
        let continued = await waitUntil(8) { login.pod.calls.contains("exclusive") && login.pod.calls.contains("create") }
        check(waiting && closedWhileLogin && continued && !isConfirm(login.flow.card),
              "Pod 沒登入：私訊框顯示 Pod 讓你登入（不換別的瀏覽器；等的時候窗口關著）；W183 R11 登入好自動接著連（不回到確認卡、不用再按一次）",
              "calls=\(login.pod.calls) card=\(String(describing: login.flow.card))")
        login.flow.cancel(reason: "test_done")
    }

    // MARK: - 12. 關窗口也清掉還沒兌換的授權碼（手動模式）

    static func manualWindowCodes(_ check: Checker, _ base: URL) throws {
        let root = base.appendingPathComponent("manual", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let chatgpt = FakeChatGPT(service: service)
        try chatgpt.register()
        try service.startPairing()
        _ = chatgpt.begin()
        let authCode = try chatgpt.submit(service.auth.pendingCard?.pairingCode ?? "")
        service.auth.closeWindow()
        var refused = false
        do { _ = try chatgpt.token(authCode) } catch let error as HandsWireError { refused = error.code == "invalid_grant" }
        check(refused && service.auth.activeGrantIDs.isEmpty, "關配對窗口（收掉配對、關開關）：還沒兌換的授權碼一起作廢")
    }

    // MARK: - 13. 副設備：真的設備簽章

    struct RemoteHarness {
        let secondary: DeviceDispatch
        let host: HandsLocked<HandsRemote.Host?>
        /// W183 R7a：主設備那端（驗章用）、驗過章送進來的 remote_hands_action 內容（看 begin_connect 帶了什麼）。
        var primary: DeviceDispatch? = nil
        var actions = HandsLocked<[[String: Any]]>([])
    }

    static func remoteHarness(_ root: URL) throws -> RemoteHarness? {
        let fm = FileManager.default
        let pRoot = root.appendingPathComponent("primary"), sRoot = root.appendingPathComponent("secondary")
        for dir in [pRoot.appendingPathComponent("entry"), sRoot.appendingPathComponent("entry"), pRoot.appendingPathComponent("live"),
                    sRoot.appendingPathComponent("live")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": pRoot.appendingPathComponent("entry").path], preference: nil)
        let sEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": sRoot.appendingPathComponent("entry").path], preference: nil)
        try DeviceIdentity(deviceID: hostID, name: "Primary One", hardwareModel: "Fixture", role: .primary, epoch: 1,
                           primaryDeviceID: hostID, updatedAt: Date()).encoded().write(to: pEntry.deviceJSON)
        try DeviceIdentity(deviceID: secondaryID, name: "Fixture", hardwareModel: "Fixture", role: .secondary, epoch: 1,
                           primaryDeviceID: hostID, updatedAt: Date()).encoded().write(to: sEntry.deviceJSON)
        let key = root.appendingPathComponent("paired-key"), hostKey = root.appendingPathComponent("host-key")
        for path in [key, hostKey] {
            let (status, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path])
            guard status == 0 else { return nil }
        }
        let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let publicHostKey = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
        let pRegistry = DeviceRegistry(root: pRoot.appendingPathComponent("live"), authorizedKeysURL: pRoot.appendingPathComponent("authorized_keys"))
        let sRegistry = DeviceRegistry(root: sRoot.appendingPathComponent("live"), authorizedKeysURL: sRoot.appendingPathComponent("authorized_keys"))
        let fingerprint = try pRegistry.authorize(publicKey: publicKey, deviceID: secondaryID)
        _ = try pRegistry.add(DeviceRecord(id: secondaryID, name: "Fixture", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                           publicKeyFingerprint: fingerprint, addedAt: Date(), lastSeenAt: Date(), workdirMap: [:],
                                           role: .secondary, epoch: 1))
        _ = try sRegistry.add(DeviceRecord(id: hostID, name: "Primary One", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                           publicKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: publicHostKey),
                                           addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .primary, epoch: 1))
        let primary = DeviceDispatch(entry: pEntry, registry: pRegistry, retireBackup: { _ in })
        let hostBox = HandsLocked<HandsRemote.Host?>(nil)
        let actions = HandsLocked<[[String: Any]]>([])
        let secondary = DeviceDispatch(entry: sEntry, registry: sRegistry, environment: ["TATWO2_SSH_KEY_PATH": key.path],
                                       retireBackup: { _ in }, rpc: { _, method, proof in
            do {
                let (sender, payload) = try primary.authenticate(method: method, proof: proof)
                if method == "remote_hands_action" { actions.update { $0.append(payload) } }   // W183 R7a
                guard HandsRemote.methods.contains(method), let host = hostBox.get() else { throw HandsRemote.Failure.invalid("method") }
                return try HandsRemote.handle(method: method, payload: payload, sender: sender, host: host)
            } catch { throw RemoteHostLinkError.remoteError(String(describing: error)) }
        })
        return RemoteHarness(secondary: secondary, host: hostBox, primary: primary, actions: actions)
    }

    @MainActor static func remote(_ check: Checker, _ base: URL) async throws {
        let root = base.appendingPathComponent("remote", isDirectory: true)
        guard let harness = try remoteHarness(root) else { return check(false, "副設備：產生測試金鑰") }
        let secondary = harness.secondary
        // 擁有者＝副設備（它的流程、它的 Pod、它的私訊框）；主機＝主設備（HandsConnectHost）。
        let world = try World(base, "remote-host", owner: secondaryID, link: { _ in HandsConnectRemoteLink(dispatch: secondary) })
        let service = world.service
        harness.host.set(HandsRemote.Host(service: service, phase: { .running(url: "https://\(publicHost)/mcp") }, setup: { nil },
                                          localDeviceID: { hostID }, devices: { [hostID: "Primary One", secondaryID: "Fixture"] }))
        // 舊的裸 start_pairing：副設備停用。
        var retired = false
        do { try await HandsConnectOffMain.run { _ = try secondary.callPrimary(method: "remote_hands_action", payload: ["op": "start_pairing"]) } }
        catch { retired = String(describing: error).contains(HandsConnectRemote.startPairingRetired) }
        check(retired && service.auth.windowExpiresAt == nil, "副設備的裸 start_pairing 停用（不開不綁人的窗口）")
        var missing = false
        do { try await HandsConnectOffMain.run { _ = try secondary.callPrimary(method: "remote_hands_action", payload: ["op": "connect_offer"]) } }
        catch { missing = String(describing: error).contains(HandsRemote.expiredReason) }
        check(missing, "connect_* 沒帶簽章涵蓋的 expires_at：不收")

        let chatgpt = FakeChatGPT(service: service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        let confirmed = await waitUntil(8) { isConfirm(world.flow.card) }
        check(confirmed && world.flow.offerShown?.publicHost == publicHost, "副設備：卡片內容經設備簽章 RPC 從主機拿（connect_offer）")
        world.flow.connect()
        let paired = await waitUntil(10) { world.pairing?.pairingCode != nil }
        let attempt = world.attemptID ?? ""
        let tx = service.auth.attemptTransaction(attempt)
        check(paired && world.pairing?.pairingCode == tx?.pairingCode, "副設備：begin_connect／connect_status 走簽章；碼只給按的那台（擁有者）")
        // W183 R6b 審查：舊的 stop_pairing 不能關別台按［連線］開的窗口、清它的授權碼（要擁有者 cancel_connect）。
        var stopRefused = false
        do { try await HandsConnectOffMain.run { _ = try secondary.callPrimary(method: "remote_hands_action", payload: ["op": "stop_pairing"]) } }
        catch { stopRefused = String(describing: error).contains(HandsConnectRemote.stopPairingAttempt) }
        check(stopRefused && service.auth.attemptTransaction(attempt) != nil && world.host.currentAttemptID == attempt,
              "舊的 stop_pairing 碰到綁連線意圖的窗口：拒絕，窗口與交易照舊")
        // 主機自己（非擁有者）與輪詢狀態：沒有碼。
        var hostRefused = false
        do { _ = try world.host.status(attemptID: attempt, sender: hostID, evidence: tx?.evidenceHash) } catch let error as HandsConnectRefusal { hostRefused = error == .notOwner }
        let polled = try await HandsConnectOffMain.run { HandsConnectPayload(try secondary.callPrimary(method: "remote_hands_status", payload: [:])) }.value
        let polledJSON = String(decoding: try JSONSerialization.data(withJSONObject: polled), as: UTF8.self)
        check(hostRefused && polled["card"] == nil && !polledJSON.contains(tx?.pairingCode ?? "NOPE"),
              "非擁有者（主機本機）要碼被拒；remote_hands_status 裡沒有碼")
        // 簽章涵蓋的內容不能替別台申請；取消是擁有者的。
        let expires = Int(Date().timeIntervalSince1970 + 60)
        var forged = false
        do {
            try await HandsConnectOffMain.run {
                _ = try secondary.callPrimary(method: "remote_hands_action", payload: [
                    "op": "begin_connect", "expires_at": expires, "attempt_id": UUID().uuidString, "setup_epoch": "epoch-1",
                    "owner_device_id": hostID, "scope_digest": "sha256:00", "mcp_url": "https://\(publicHost)/mcp"])
            }
        } catch { forged = String(describing: error).contains(HandsConnectRefusal.notOwner.rawValue) }
        check(forged, "begin_connect 的擁有設備要是驗章得到的那台（payload 不能替別台申請）")
        let code = try chatgpt.submit(tx?.pairingCode ?? "")
        let access = try chatgpt.token(code)
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { world.flow.phase == .connected }
        check(connected, "副設備：這個 attempt 的 grant 第一次 /mcp＝已連線")
    }

    // MARK: - 15. W183 R6b 審查：警語綁那一張表單與那一段文字

    @MainActor static func warningAck(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "warning-ack")
        let seen = HandsConnectorAck(form: "fabc123456", warning: "0123abcd-40")
        world.pod.createQueue = [.needsUser("表單上有警語", seen)]
        let chatgpt = FakeChatGPT(service: world.service)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let waiting = await waitUntil(5) { world.flow.phase == .waitingUser }
        let windowClosed = world.service.auth.windowExpiresAt == nil
        world.chatgptStarts(chatgpt)
        world.flow.continueAfterUser()
        let paired = await waitUntil(8) { world.pairing?.pairingCode != nil }
        check(waiting && windowClosed && paired && world.pod.acks.count == 2 && world.pod.acks[0] == nil && world.pod.acks[1] == seen
              && !world.pod.calls.contains("release"),
              "警語：等的時候窗口關著、拿著 Pod（表單不被關掉）；按「繼續」才帶回他看過的那一張表單與那段警語的指紋", "\(world.pod.calls)")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: - 16. W183 R6b 審查：綁住的配對頁載入別的、關掉、被帶去外站

    @MainActor static func leftPairingPage(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "left")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt, popup: 41)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        world.pod.emitLoading(popup: 41)
        let hiddenOnLoad = world.pairing?.pairingCode == nil && !world.presenter.codeVisible
        world.pod.emit(chatgpt.authorizeURL, popup: 41)
        let back = await waitUntil(3) { world.pairing?.pairingCode != nil }
        world.pod.emitClosed(popup: 41)
        let hiddenOnClose = world.pairing?.pairingCode == nil && !world.presenter.codeVisible
        check(hiddenOnLoad && back && hiddenOnClose, "綁住的配對頁一開始載入、或視窗關掉：碼當下收起來（不等下一圈）；回到同一頁才再顯示")
        world.flow.cancel(reason: "test_done")

        let foreign = try World(base, "left-foreign")
        let other = FakeChatGPT(service: foreign.service)
        foreign.chatgptStarts(other)
        foreign.flow.offer()
        _ = await waitUntil(5) { isConfirm(foreign.flow.card) }
        foreign.flow.connect()
        _ = await waitUntil(8) { foreign.pairing?.pairingCode != nil }
        let before = foreign.pod.popupsClosed
        foreign.pod.emit(URL(string: "https://evil.example.net/authorize?client_id=x&code_challenge=y")!)
        let refusedNow = foreign.flow.phase == .refused
        let closed = await waitUntil(3) { foreign.service.auth.windowExpiresAt == nil && foreign.service.auth.pendingCard == nil }
        check(refusedNow && !foreign.presenter.codeVisible && closed && foreign.pod.popupsClosed > before,
              "配對中途被帶到外站的授權頁：當下終止（不等下一圈）、碼收起來、交易作廢、配對頁視窗關掉")

        let away = try World(base, "left-away")
        let third = FakeChatGPT(service: away.service)
        away.chatgptStarts(third)
        away.flow.offer()
        _ = await waitUntil(5) { isConfirm(away.flow.card) }
        away.flow.connect()
        _ = await waitUntil(8) { away.pairing?.pairingCode != nil }
        away.pod.emit(URL(string: "https://elsewhere.example.net/landing")!)
        check(away.flow.phase == .refused && !away.presenter.codeVisible, "配對頁被帶到別的網站（不是這台主機、不是 ChatGPT）：當下終止")
    }

    // MARK: - 17. W183 R6b 審查：配對頁的來源（對話裡的連結、按下之前開的視窗）

    @MainActor static func provenance(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "provenance-chat")
        let link = FakeChatGPT(service: world.service)
        world.pod.onAction = { [weak world] in
            guard let world else { return }
            _ = try? link.register()
            _ = link.begin()
            let url = link.authorizeURL
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                world.pod.emit(url, source: URL(string: "https://chatgpt.com/c/abc-123")!)
            }
        }
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let refused = await waitUntil(5) { world.flow.phase == .refused }
        let closed = await waitUntil(3) { world.service.auth.windowExpiresAt == nil && world.service.auth.pendingCard == nil }
        check(refused && closed && !world.presenter.codeEverVisible && world.service.auth.activeGrantIDs.isEmpty,
              "等授權頁時，從對話頁打開的授權連結（網域、參數都對）：不算、終止、不顯示碼、交易作廢", "\(world.flow.debugLog.suffix(3))")

        let early = try World(base, "provenance-early")
        let chatgpt = FakeChatGPT(service: early.service)
        early.pod.onAction = { [weak early] in
            guard let early else { return }
            _ = try? chatgpt.register()
            _ = chatgpt.begin()
            let url = chatgpt.authorizeURL
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                early.pod.emit(url, popup: 9, openedAt: Date().addingTimeInterval(-60))   // 按下之前就開著的視窗延遲導頁
            }
        }
        early.flow.offer()
        _ = await waitUntil(5) { isConfirm(early.flow.card) }
        early.flow.connect()
        let earlyRefused = await waitUntil(5) { early.flow.phase == .refused }
        check(earlyRefused && !early.presenter.codeEverVisible, "按下建立之前就開著的視窗延遲導到配對頁：不算、終止、不顯示碼")
    }

    // MARK: - 18. W183 R6b 審查：最後確認前再核帳號；讀不到不算通過

    @MainActor static func accountAtConfirm(_ check: Checker, _ base: URL) async throws {
        for (name, value) in [("switched", Optional("u=someone-else|w=ws-fixture|e=other-mail")), ("unreadable", nil)] {
            let world = try World(base, "confirm-" + name)
            let service = world.service
            let chatgpt = FakeChatGPT(service: service)
            world.chatgptStarts(chatgpt)
            world.flow.offer()
            _ = await waitUntil(5) { isConfirm(world.flow.card) }
            world.flow.connect()
            _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
            let attempt = world.attemptID ?? ""
            let access = try chatgpt.token(try chatgpt.submit(world.pairing?.pairingCode ?? ""))
            world.pod.identityValue = value   // /token 之後、第一次 /mcp 之前換帳號（或讀不到）
            try chatgpt.tools(access)
            let refused = await waitUntil(5) { world.flow.phase == .refused }
            let revoked = await waitUntil(3) { service.auth.grant(forAccess: access) == nil && service.auth.activeGrantIDs.isEmpty }
            let final = try? world.host.status(attemptID: attempt, sender: hostID, evidence: nil)
            check(refused && revoked && final != nil && final?.state != .connected,
                  name == "switched" ? "第一次 /mcp 之後 Pod 帳號變了：不確認、撤銷這次的 grant（主機不會自己變成已連線）"
                                     : "第一次 /mcp 之後讀不到 Pod 帳號：不當成通過、撤銷", "\(String(describing: final))")
        }
    }

    // MARK: - 19. W183 R6b 審查：取消採用主機的回覆（成功先到、結果不確定）；取消與撤銷同一刻

    /// 包一層主機連線：可以讓 begin 晚到、讓取消與查詢「結果未知」。
    final class FlakyLink: HandsConnectLink, @unchecked Sendable {
        let inner: any HandsConnectLink
        let beginDelay: UInt64
        let failCancel: Bool
        init(_ inner: any HandsConnectLink, beginDelay: UInt64 = 0, failCancel: Bool = false) {
            self.inner = inner; self.beginDelay = beginDelay; self.failCancel = failCancel
        }
        var isRemote: Bool { inner.isRemote }
        func offer() async throws -> HandsConnectOffer { try await inner.offer() }
        func begin(_ request: HandsConnectRequest) async throws -> HandsConnectStatus {
            if beginDelay > 0 { try? await Task.sleep(nanoseconds: beginDelay) }
            return try await inner.begin(request)
        }
        func status(attemptID: String, evidence: String?) async throws -> HandsConnectStatus {
            if failCancel, evidence == nil { throw HandsConnectLinkError.unknown("fixture") }
            return try await inner.status(attemptID: attemptID, evidence: evidence)
        }
        func cancel(attemptID: String, reason: String) async throws -> HandsConnectStatus {
            if failCancel { throw HandsConnectLinkError.unknown("fixture") }
            return try await inner.cancel(attemptID: attemptID, reason: reason)
        }
        func confirm(attemptID: String) async throws -> HandsConnectStatus { try await inner.confirm(attemptID: attemptID) }
    }

    @MainActor static func cancelAdoptsHost(_ check: Checker, _ base: URL) async throws {
        // 成功先到：擁有者的確認已經送到主機、畫面還沒更新時按取消 → 主機回「已連線」，畫面照實顯示已連線。
        let world = try World(base, "cancel-late")
        let service = world.service
        let chatgpt = FakeChatGPT(service: service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let attempt = world.attemptID ?? ""
        let access = try chatgpt.token(try chatgpt.submit(world.pairing?.pairingCode ?? ""))
        world.pod.identityDelay = 600_000_000
        try chatgpt.tools(access)
        _ = await waitUntil(3) { if case .verifying(let text)? = world.flow.card { return text.contains("核對") }; return false }
        _ = try world.host.confirm(attemptID: attempt, sender: hostID)   // 確認先到了主機
        world.flow.dismiss()
        let late = await waitUntil(5) { world.flow.phase == .connected }
        if case .connected(let text)? = world.flow.card {
            check(late && text.contains("晚了一步") && service.auth.grant(forAccess: access) != nil, "取消晚了一步（主機已連上）：畫面照實顯示已連線，不假裝取消了")
        } else {
            check(false, "取消晚了一步：顯示已連線", "\(String(describing: world.flow.card))")
        }

        // 取消結果不確定：不假裝取消了。
        let unknown = try World(base, "cancel-unknown", link: { host in FlakyLink(HandsConnectLocalLink(host: host, ownerID: hostID), failCancel: true) })
        let other = FakeChatGPT(service: unknown.service)
        unknown.chatgptStarts(other)
        unknown.flow.offer()
        _ = await waitUntil(5) { isConfirm(unknown.flow.card) }
        unknown.flow.connect()
        _ = await waitUntil(8) { unknown.pairing?.pairingCode != nil }
        unknown.flow.dismiss()
        let failed = await waitUntil(8) { unknown.flow.phase == .failed }
        check(failed && unknown.flow.problem == HandsConnectFlow.cancelUnknownText && !unknown.flow.cancelling,
              "取消送不到主機（結果不確定）：明講不確定，不收成「已取消」", "\(String(describing: unknown.flow.card))")

        // 取消與撤銷同一刻：取消一回來，這個 attempt 換到的 token 就已經不能用。
        let root = base.appendingPathComponent("cancel-atomic", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bare = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        bare.deviceIDOverride = hostID
        _ = try bare.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let host = HandsConnectHost(service: bare, epoch: { "e" }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        let offer = try host.offer()
        let id = UUID().uuidString
        _ = try host.begin(HandsConnectRequest(attemptID: id, setupEpoch: "e", ownerDeviceID: hostID, scopeDigest: offer.digest, mcpURL: offer.mcpURL), sender: hostID)
        let fake = FakeChatGPT(service: bare)
        try fake.register()
        _ = fake.begin()
        let hash = HandsConnectAcceptance.evidence(fake, attempt: id, epoch: "e")   // W183 R8c：第二版證據
        let code = (try host.status(attemptID: id, sender: hostID, evidence: hash)).transaction?.pairingCode ?? ""
        let token = try fake.token(try fake.submit(code))
        let beforeCancel = bare.auth.grant(forAccess: token) != nil
        let status = try host.cancel(attemptID: id, sender: hostID, reason: "test")
        check(beforeCancel && status.state == .cancelled && bare.auth.grant(forAccess: token) == nil,
              "取消一回來（公布「已取消」的同時），這個 attempt 換到的 token 就已經撤銷")
    }

    // MARK: - 20. W183 R6b 審查：送碼、換 token、第一次 /mcp 都重核世代、範圍、期限

    @MainActor static func staleCommitPoints(_ check: Checker, _ base: URL) async throws {
        // 送了對的碼之後主機世代換了：ChatGPT 來換 token 時這個 attempt 先取消，換不到 grant。
        let world = try World(base, "stale-token")
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(8) { world.pairing?.pairingCode != nil }
        let code = try chatgpt.submit(world.pairing?.pairingCode ?? "")
        world.epoch.set("epoch-2")
        var tokenRefused = false
        do { _ = try chatgpt.token(code) } catch let error as HandsWireError { tokenRefused = error.code == "invalid_grant" }
        check(tokenRefused && world.service.auth.activeGrantIDs.isEmpty, "送了對的碼之後主機世代換了：換 token 前就取消，換不到 grant")
        world.flow.cancel(reason: "test_done")

        // 換到 token（暫時的 grant）之後範圍改了：第一次 /mcp 前重核＝取消、撤銷，這一次不給工具。
        let scoped = try World(base, "stale-mcp")
        let second = FakeChatGPT(service: scoped.service)
        scoped.chatgptStarts(second)
        scoped.flow.offer()
        _ = await waitUntil(5) { isConfirm(scoped.flow.card) }
        scoped.flow.connect()
        _ = await waitUntil(8) { scoped.pairing?.pairingCode != nil }
        let access = try second.token(try second.submit(scoped.pairing?.pairingCode ?? ""))
        scoped.epoch.set("epoch-3")
        var toolsRefused = false
        do { try second.tools(access) } catch let error as HandsWireError { toolsRefused = error == .unauthorized }
        check(toolsRefused && scoped.service.auth.grant(forAccess: access) == nil, "有了暫時的 grant 之後世代換了：第一次 /mcp 前重核＝撤銷，不給工具")
        scoped.flow.cancel(reason: "test_done")

        // 期限：有 grant 的 attempt 過了最後期限，一樣到期、撤銷。
        let late = try World(base, "stale-expired")
        let third = FakeChatGPT(service: late.service)
        late.chatgptStarts(third)
        late.flow.offer()
        _ = await waitUntil(5) { isConfirm(late.flow.card) }
        late.flow.connect()
        _ = await waitUntil(8) { late.pairing?.pairingCode != nil }
        let lateAccess = try third.token(try third.submit(late.pairing?.pairingCode ?? ""))
        late.host.now = { Date().addingTimeInterval(HandsAuth.windowLifetime + HandsConnectHost.completionGrace + 5) }
        var expiredRefused = false
        do { try third.tools(lateAccess) } catch let error as HandsWireError { expiredRefused = error == .unauthorized }
        check(expiredRefused && late.service.auth.grant(forAccess: lateAccess) == nil, "有 grant 的 attempt 過了最後期限：一樣到期、撤銷（不因為有 grant 就不收）")
        late.flow.cancel(reason: "test_done")

        // 設定一改就核一次（不等擁有者下一次輪詢）。
        let changed = try World(base, "stale-settings")
        let fourth = FakeChatGPT(service: changed.service)
        changed.chatgptStarts(fourth)
        changed.flow.offer()
        _ = await waitUntil(5) { isConfirm(changed.flow.card) }
        changed.flow.connect()
        _ = await waitUntil(8) { changed.pairing?.pairingCode != nil }
        let attempt = changed.attemptID ?? ""
        _ = try changed.service.updateSettings { $0.level = 2 }
        let voided = await waitUntil(3) { changed.service.auth.attemptTransaction(attempt) == nil && changed.service.auth.attemptWindowExpiry(attempt) == nil }
        check(voided, "設定（範圍）一改：進行中的 attempt 當下作廢（窗口、交易），不等輪詢")
        changed.flow.cancel(reason: "test_done")
    }

    // MARK: - 21. W183 R6b 審查：App 重開時還沒確認的 grant 撤銷

    static func restartRevokesUnfinished(_ check: Checker, _ base: URL) throws {
        let root = base.appendingPathComponent("restart", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let host = HandsConnectHost(service: service, epoch: { "e" }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        let offer = try host.offer()
        let id = UUID().uuidString
        _ = try host.begin(HandsConnectRequest(attemptID: id, setupEpoch: "e", ownerDeviceID: hostID, scopeDigest: offer.digest, mcpURL: offer.mcpURL), sender: hostID)
        let chatgpt = FakeChatGPT(service: service)
        try chatgpt.register()
        _ = chatgpt.begin()
        let hash = HandsConnectAcceptance.evidence(chatgpt, attempt: id, epoch: "e")   // W183 R8c：第二版證據
        let code = (try host.status(attemptID: id, sender: hostID, evidence: hash)).transaction?.pairingCode ?? ""
        let access = try chatgpt.token(try chatgpt.submit(code))
        let grant = service.auth.grant(forAccess: access)
        // App 當掉（/token 完成、第一次 /mcp 之前）：重開讀同一個授權檔。
        let reopened = HandsAuth(url: service.auth.url)
        check(grant?.provisional == true && reopened.grant(forAccess: access) == nil
              && reopened.grantRecord(grant?.grantID ?? "")?.revokeReason == "connect_unfinished",
              "App 重開時還沒確認的連線 grant：一律撤銷，不自動恢復")
    }

    // MARK: - 22. W183 R6b 審查：begin 還沒回就取消（晚到的 begin 不開窗口）

    @MainActor static func lateBegin(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "late-begin", link: { host in FlakyLink(HandsConnectLocalLink(host: host, ownerID: hostID), beginDelay: 500_000_000) })
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(3) { if case .working(let text)? = world.flow.card { return text.contains("配對窗口") }; return false }
        world.flow.dismiss()
        try? await Task.sleep(nanoseconds: 900_000_000)
        check(world.service.auth.windowExpiresAt == nil && world.host.currentAttemptID == nil && world.flow.phase == .waitingTap,
              "begin 還沒回就取消：取消先記成墓碑，晚到的 begin 不開窗口")
        let root = base.appendingPathComponent("tombstone", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = HandsService(paths: HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands")))
        service.deviceIDOverride = hostID
        _ = try service.updateSettings { $0.enabled = true; $0.hostDeviceID = hostID; $0.publicHost = publicHost }
        let host = HandsConnectHost(service: service, epoch: { "e" }, localDeviceID: { hostID }, hostName: { "Primary One" }, serviceRunning: { true })
        host.attach()
        let offer = try host.offer()
        let id = UUID().uuidString
        let early = try host.cancel(attemptID: id, sender: hostID, reason: "lock")
        let begun = try host.begin(HandsConnectRequest(attemptID: id, setupEpoch: "e", ownerDeviceID: hostID, scopeDigest: offer.digest, mcpURL: offer.mcpURL), sender: hostID)
        check(early.state == .cancelled && begun.state == .cancelled && service.auth.windowExpiresAt == nil,
              "主機：取消比 begin 先到＝墓碑；之後同 ID 的 begin 回「已取消」、不開窗口")
    }

    // MARK: - 23. W183 R6b 審查：按過建立、結果沒查清楚：清單找不到它之前不再按建立

    @MainActor static func pendingCreate(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "pending-create")
        world.pod.createResult = .unknown
        world.pod.rescanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true, matches: [])
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        _ = await waitUntil(5) { world.flow.phase == .needsManual }
        world.flow.retry()
        // W183 R12（主導 5）：那一句改成講清楚上次建的那一個還沒出現在清單、到 ChatGPT 看一下（原本「上次按了『建立』但結果不確定」）；守的一樣：不再按建立。
        let stopped = await waitUntil(5) { world.flow.phase == .needsManual && world.flow.problem?.contains("還沒出現在外掛清單") == true }
        check(stopped && world.pod.calls.filter({ $0.hasPrefix("create") }).count == 1,
              "按了建立、結果不確定、清單又找不到它：再連一次也不再按建立（改手動）", "\(world.pod.calls)")
    }

    // MARK: - 24. W183 R6b 審查：Pod 的獨占（帶回首頁才放行聊天、會換頁的指令與語音、取消時不空轉）

    /// 記憶體裡的 Pod 傳輸：記下送出的指令；在 chatgpt.com 上時照指令回覆（網頁腳本在外站不執行＝不回）。
    @MainActor final class LeaseTransport: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        var onChatGPT = true
        private(set) var commands: [String] = []
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func run(_ script: String) {
            guard let open = script.range(of: ".command("), script.hasSuffix(")"),
                  let data = String(script[open.upperBound..<script.index(before: script.endIndex)]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = payload["cmd"] as? String, let id = payload["id"] as? String else { return }
            commands.append(cmd)
            guard onChatGPT, cmd != "send", cmd != "stop" else { return }
            let reply: [String: Any]
            switch cmd {
            case "voice": reply = ["live": payload["stop"] as? Bool != true]
            case "voiceState": reply = ["live": false]
            default: reply = ["ok": true]
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true, "data": reply]) else { return }
            let json = String(decoding: body, as: UTF8.self)
            Task { @MainActor [weak self] in self?.onEvent?(json) }
        }
        func hello() { onEvent?(#"{"type":"hello","loggedIn":true}"#) }
    }

    @MainActor final class LeaseSurface: ChatGPTPodSurface {
        var onMainFrame: ((String?, UInt64, Bool, Int) -> Void)?
        var onPopup: ((TatwoCEFBrowserView) -> Void)?
        private(set) var loads: [URL] = []
        private var generation: UInt64 = 0
        func loadMain(_ url: URL) { loads.append(url) }
        func commit(_ url: String) { generation += 1; onMainFrame?(url, generation, false, 200) }
    }

    @MainActor static func podLease(_ check: Checker) async {
        let transport = LeaseTransport()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let surface = LeaseSurface()
        let pod = ChatGPTConnectorPod(tap: tap, surface: { surface })
        pod.restoreTimeout = 3
        pod.attach()
        surface.commit("https://chatgpt.com/plugins")
        let acquired = await pod.acquireExclusive(timeout: 1)
        // 拿著獨占：會換頁的指令與語音一律拒絕；連接器指令沒帶獨占也拒絕。
        var voiceBlocked = false
        do { _ = try await tap.voice(start: nil) } catch { voiceBlocked = String(describing: error).contains("連接 TATWO") || tap.connectorHold != nil }
        var noHold = false
        do { _ = try await tap.connectorRequest("connectorHome", [:], hold: nil, timeout: .seconds(1)) } catch { noHold = true }
        var wrongHold = false
        do { _ = try await tap.connectorRequest("connectorHome", [:], hold: UUID(), timeout: .seconds(1)) } catch { wrongHold = true }
        check(acquired && voiceBlocked && !transport.commands.contains("voice") && noHold && wrongHold,
              "獨占期間：語音、會換頁的指令不送；連接器指令要帶著目前的獨占才送", "\(transport.commands)")
        // 主框架停在外站（同頁配對頁）時放掉獨占：原生載回首頁、等新的網頁報到，才放行排隊的聊天。
        surface.commit("https://\(publicHost)/authorize?client_id=x")
        transport.onChatGPT = false
        let queued = tap.send(requestID: UUID().uuidString, text: "hello", conversationID: nil)
        pod.releaseExclusive()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let heldBack = !transport.commands.contains("send") && surface.loads == [ChatGPTTap.homeURL]
        surface.commit("https://chatgpt.com/")
        transport.onChatGPT = true
        transport.hello()
        let sent = await waitUntil(3) { transport.commands.contains("send") }
        check(heldBack && sent && tap.connectorHold == nil,
              "放掉獨占時 Pod 停在外站：原生載回 chatgpt.com、等網頁報到才送排隊的那一則（不會送進不執行指令的頁面）", "\(transport.commands) \(surface.loads)")
        withExtendedLifetime(queued) {}
        // 語音開著：拿不到獨占；結束語音才拿得到。
        let tap2 = ChatGPTTap(transport: LeaseTransport(), connection: .ready)
        _ = try? await tap2.voice(start: nil)
        let blockedByVoice = tap2.beginConnectorHold() == nil
        try? await tap2.voiceStop()
        let afterVoice = tap2.beginConnectorHold()
        check(blockedByVoice && afterVoice != nil, "語音開著時連接器拿不到獨占（不會被換頁切斷）；結束語音之後才拿得到")
        if let afterVoice { tap2.endConnectorHold(afterVoice) }
        // 等獨占的時候流程取消：馬上停（不在主執行緒空轉）。
        let tap3 = ChatGPTTap(transport: LeaseTransport(), connection: .ready)
        let other = tap3.beginConnectorHold()
        let pod3 = ChatGPTConnectorPod(tap: tap3, surface: { LeaseSurface() })
        let started = Date()
        let waiting = Task { @MainActor in await pod3.acquireExclusive(timeout: 10) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        waiting.cancel()
        let result = await waiting.value
        check(!result && Date().timeIntervalSince(started) < 2, "等獨占時流程取消：馬上回 false（不空轉到逾時）")
        if let other { tap3.endConnectorHold(other) }
    }

    // MARK: - 14. 真的 CEF（起不來＝SKIP，不當通過）

    @MainActor static func realCEF(_ check: Checker) {
        guard EmbeddedBrowserEnginePolicy.current == .chromiumCEF else {
            return check.skip("真 CEF 的 Pod／popup／配對頁檢查：這個建置沒有 Chromium（自測環境起不來）；主導實機驗")
        }
        check.skip("真 CEF 的 Pod／popup／配對頁檢查：自測不連 chatgpt.com、不啟動關口；主導實機驗（真的外掛頁 DOM、OAuth 同頁或 popup）")
    }
}
#endif
