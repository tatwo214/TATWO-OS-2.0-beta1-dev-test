#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI

/// W199：隔離 root、假 Pod；實際 Space／私訊框元件與正式載入路徑。
@MainActor
enum W199QuietAcceptance {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil else { throw TapError.notReady }
        let root = URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!).appendingPathComponent("w199-entry-" + UUID().uuidString)
        let entry = try await HandsBuildAcceptance.w199EntryChecks(check, root)
        let devices = [device("one", "Laptop Fixture"), device("two", "Studio Fixture"), device("off", "未勾選", selected: false)]
        let connected = HandsConnectEntryState.connected(hosts: ["one", "two"], level: 2)
        let partial = HandsConnectEntryState.partial(hosts: ["one"], level: 2, text: "fixture")
        var notice = HandsConnectionNotice(), checks: [[String]] = []
        notice.update(.connecting, devices: devices, uptime: 0) { checks.append($0) }
        notice.update(.connecting, devices: devices, uptime: 14.99) { checks.append($0) }
        check(notice.text == nil, "W199 automatic connecting under 15 seconds stays silent")
        notice.update(.connecting, devices: devices, uptime: 15) { checks.append($0) }
        notice.update(.connecting, devices: devices, uptime: 300) { checks.append($0) }
        check(notice.text == nil, "W203 automatic connecting at 15 seconds and five minutes stays silent")
        notice.update(connected, devices: devices, uptime: 16) { checks.append($0) }
        notice.userInitiated = true
        notice.update(.connecting, devices: devices, uptime: 17) { checks.append($0) }
        check(notice.text == nil, "W205-2 explicit connection stays quiet while confirmation needs no user action")
        notice.update(partial, devices: devices, uptime: 18) { checks.append($0) }
        check(notice.text == nil && notice.checkAt == 23 && checks == [["two"]], "W199 partial rechecks only the unconfirmed selected host in background")
        notice.update(connected, devices: devices, uptime: 20) { checks.append($0) }
        check(notice.text == nil && notice.checkAt == nil, "W199 healthy state cancels the notice wakeup")
        for tick in [21.0, 26, 31] { notice.update(partial, devices: devices, uptime: tick, actionableHosts: ["two"]) { checks.append($0) } }
        check(notice.text == nil, "W199 first three partial checks never report status")
        notice.update(partial, devices: devices, uptime: 36, actionableHosts: ["two"]) { checks.append($0) }
        check(notice.text == "Studio Fixture 的連線被撤銷了：按一下重新連線", "W199 repeated failure names the host and offers one action")
        notice.dismiss()
        notice.update(partial, devices: devices, uptime: 37, actionableHosts: ["two"]) { checks.append($0) }
        check(notice.text == nil, "W205-2 same host same revoked reason stays dismissed")
        notice.update(partial, devices: devices, uptime: 38, actionableHosts: []) { checks.append($0) }
        notice.update(partial, devices: devices, uptime: 39, actionableHosts: ["two"]) { checks.append($0) }
        check(notice.text == nil, "W205-2 stale evidence then same reason never resurrects dismissal")
        notice.update(partial, devices: devices, uptime: 40, actionableHosts: ["two"], reasonKeys: ["two": "different-grant"]) { checks.append($0) }
        check(notice.text != nil, "W205-2 changed account grant state permits a new prompt")
        notice.dismiss()
        var reopenedNotice = HandsConnectionNotice(dismissed: notice.dismissed)
        for tick in [0.0, 5, 10, 15] { reopenedNotice.update(partial, devices: devices, uptime: tick, actionableHosts: ["two"], reasonKeys: ["two": "different-grant"]) { _ in } }
        check(reopenedNotice.text == nil, "W205-2 persisted dismissal survives recreating notice")
        reopenedNotice.update(connected, devices: devices, uptime: 16) { _ in }
        for tick in [17.0, 22, 27, 32] { reopenedNotice.update(partial, devices: devices, uptime: tick, actionableHosts: ["two"], reasonKeys: ["two": "different-grant"]) { _ in } }
        check(reopenedNotice.text != nil, "W205-2 confirmed recovery followed by revocation prompts again")
        var allQuiet = true
        for tick in stride(from: 37.0, through: 337, by: 5) {
            notice.update(partial, devices: devices, uptime: tick) { checks.append($0) }
            allQuiet = allQuiet && notice.text == nil
        }
        check(allQuiet, "W203-1 offline for five minutes keeps Space and DM entry silent")
        notice.update(connected, devices: devices, uptime: 338) { checks.append($0) }
        check(notice.text == nil, "W199 recovery automatically removes the failure prompt")

        var hostEvidence = HandsConnectHostEvidence(fresh: true, serving: true, confirmedGrants: 0, grantLevels: [:],
            receivedAt: Date(), actualLevel: 2, grantsVersion: 1)
        check(!HandsConnectionNotice.actionable(evidence: hostEvidence, verdict: .open, hasAccountRecord: false),
              "W205-2 local missing record cannot prove another host needs action")
        check(HandsConnectionNotice.actionable(evidence: hostEvidence, verdict: .ended(.revoked), hasAccountRecord: true),
              "W203-1 online revoked account is actionable")
        hostEvidence.fresh = false
        check(!HandsConnectionNotice.actionable(evidence: hostEvidence, verdict: .ended(.revoked), hasAccountRecord: true),
              "W203-1 sleeping host is not actionable even with old revocation")
        hostEvidence.fresh = true; hostEvidence.grantLevels = nil
        check(!HandsConnectionNotice.actionable(evidence: hostEvidence, verdict: .open, hasAccountRecord: false),
              "W203-1 old host without account evidence remains quiet")
        notice.update(.connect, devices: devices, uptime: 339) { checks.append($0) }
        check(notice.text == nil, "W203-1 all hosts offline remains quiet with no connected host")

        let pod = Pod(), tap = ChatGPTTap(transport: pod, connection: .sleeping)
        let model = ChatGPTSpaceModel(testTap: tap)
        defer { tap.sleep() }
        pod.holdProjects = true
        model.toggleProject("g-p-fixture")
        check(model.projectLoadStates["g-p-fixture"] == .loading && model.projectConversations["g-p-fixture"] == nil,
              "W199 expand synchronously enters loading")
        // .056 閘門：mini 滿載時 3 秒不一定等得到喚醒＋報到；拆成四條，失敗時看得出是哪一條。
        let requested = try await until(seconds: 10) { !pod.pendingProjects.isEmpty }
        check(requested, "W199 sleeping web wakes and waits for hidden-sensitive hello before requesting the project")
        check(pod.starts == 1, "W199 sleeping web starts exactly once for the project load (starts=\(pod.starts))")
        check(pod.hiddenRequests == 0, "W199 no page request is sent while the web is hidden (hidden=\(pod.hiddenRequests))")
        check(tap.connection == .ready, "W199 project request waits for ready (connection=\(tap.connection))")
        pod.holdProjects = false; pod.flushProjects()
        let loaded = try await until { model.projectLoadStates["g-p-fixture"] == .loaded }
        check(loaded && model.projectConversations["g-p-fixture"]?.first?.title == "Fixture conversation 1",
              "W199 loading becomes a visible conversation")
        pod.holdProjects = true
        model.retryProject("g-p-fixture")
        check(model.projectConversations["g-p-fixture"]?.count == 1 && model.projectLoadStates["g-p-fixture"] == .loading,
              "W199 reload preserves the previous list until the replacement arrives")
        _ = try await until { !pod.pendingProjects.isEmpty }
        pod.failProjects = true; pod.flushProjects()
        let failed = try await until { model.projectLoadStates["g-p-fixture"] == .failed("讀不到這個專案的對話") }
        check(failed && model.projectConversations["g-p-fixture"]?.count == 1,
              "W199 project failure shows retry and keeps old conversations")
        pod.failProjects = false; pod.holdProjects = false; pod.revision = 2
        model.retryProject("g-p-fixture")
        _ = try await until { model.projectConversations["g-p-fixture"]?.first?.title == "Fixture conversation 2" }
        check(model.projectLoadStates["g-p-fixture"] == .loaded, "W199 explicit retry succeeds and clears the error")
        pod.revision = 3; pod.emit(["type":"auth"])
        let renewed = try await until { model.projectConversations["g-p-fixture"]?.first?.title == "Fixture conversation 3" }
        check(renewed, "W199 renewed ready web automatically rereads expanded projects even without a state transition")
        tap.sleep(); pod.revision = 4
        let wake = tap.acquireLease(backgroundWork: true); tap.start()
        let recovered = try await until { model.projectConversations["g-p-fixture"]?.first?.title == "Fixture conversation 4" }
        tap.releaseLease(wake)
        check(recovered, "W199 connection recovery automatically rereads expanded projects")
        pod.holdProjects = true; model.retryProject("g-p-fixture")
        _ = try await until { !pod.pendingProjects.isEmpty }
        model.toggleProject("g-p-fixture")
        pod.flushProjects()
        try await Task.sleep(for: .milliseconds(50))
        check(!model.expandedProjects.contains("g-p-fixture") && model.projectLoadStates["g-p-fixture"] == .idle,
              "W199 collapse cancels an in-flight result and does not leave loading stuck")
        pod.holdProjects = false; pod.emptyProjects = true; model.toggleProject("g-p-fixture")
        _ = try await until { model.projectLoadStates["g-p-fixture"] == .loaded }
        check(model.projectConversations["g-p-fixture"] == [], "W199 successful empty project is distinguishable from loading and failure")
        pod.emptyProjects = false; pod.malformed = true; model.retryProject("g-p-fixture")
        _ = try await until { model.projectLoadStates["g-p-fixture"] == .failed("讀不到這個專案的對話") }
        check(model.projectLoadStates["g-p-fixture"] == .failed("讀不到這個專案的對話"), "W199 malformed API response cannot masquerade as an empty project")
        await model.reloadConversationList()
        check(model.listFailure != nil, "W199 main list malformed response offers retry")
        pod.malformed = false; await model.reloadConversationList()
        check(model.listFailure == nil && !model.conversations.isEmpty, "W199 main list retry recovers")
        pod.failList = true; await model.reloadConversationList()
        check(model.listFailure != nil && !model.conversations.isEmpty, "W199 main list failure preserves loaded rows")
        pod.failList = false; await model.reloadConversationList()
        pod.failSearch = true; model.search = "Fixture"
        _ = try await until { model.searchLoadState == .failed("讀不到搜尋結果") }
        check(model.searchLoadState == .failed("讀不到搜尋結果"), "W199 server search failure is explicit")
        pod.failSearch = false; model.retrySearch()
        _ = try await until { model.searchLoadState == .loaded }
        check(model.searchResults?.count == 1, "W199 search retry succeeds")
        pod.failSearch = true; model.retrySearch()
        check(model.searchResults?.count == 1 && model.searchLoadState == .loading, "W199 same-query reread keeps previous search results")
        _ = try await until { model.searchLoadState == .failed("讀不到搜尋結果") }
        check(model.searchResults?.count == 1, "W199 failed search reread keeps previous results")
        pod.failSearch = false; model.search = ""; model.retryProject("g-p-fixture")
        _ = try await until { model.projectLoadStates["g-p-fixture"] == .loaded }
        pod.holdCatalog = true; model.retryProjects()
        check(model.projectsLoadState == .loaded, "W224-3 cached root projects refresh without loading row")
        _ = try await until { !pod.pendingCatalog.isEmpty }
        model.retryProject("g-p-fixture")
        _ = try await until { model.projectLoadStates["g-p-fixture"] == .loaded }
        check(model.projectsLoadState == .loaded && model.projectLoadStates["g-p-fixture"] == .loaded,
              "W207 held catalog read does not block an independent conversation directory read")
        func catalogFinished(after replies: Int) async throws -> Bool {
            try await until { pod.catalogReplies > replies && !pod.workActive }
        }
        let cachedProjects = model.projects, failedReplies = pod.catalogReplies
        pod.failCatalog = true; pod.flushCatalog()
        let failureFinished = try await catalogFinished(after: failedReplies)
        check(failureFinished && model.projectsLoadState == .loaded && !model.projects.isEmpty
              && model.projects == cachedProjects,
              "W224-3 cached root failure keeps rows without error row")
        try await evidence(check, model: model, tap: tap, partial: partial, entry: entry)
        let retryReplies = pod.catalogReplies
        pod.failCatalog = false; pod.revision = 5; model.retryProjects()
        let retryRequested = try await until { !pod.pendingCatalog.isEmpty }
        check(retryRequested && pod.workActive && model.projects == cachedProjects,
              "W227 root retry remains pending with the cached list until a response")
        pod.holdCatalog = false; pod.flushCatalog()
        let retryFinished = try await catalogFinished(after: retryReplies)
        check(retryFinished && model.projectsLoadState == .loaded && model.projects.count == 1
              && model.projects.first?.title == "Fixture project 5" && model.projects != cachedProjects,
              "W203-5 root projects retry recovers")
        let recoveredProjects = model.projects, malformedReplies = pod.catalogReplies
        pod.malformed = true; pod.holdCatalog = true; model.retryProjects()
        let malformedRequested = try await until { !pod.pendingCatalog.isEmpty }
        check(malformedRequested && pod.workActive && model.projects == recoveredProjects,
              "W227 malformed root read stays pending before its response")
        pod.holdCatalog = false; pod.flushCatalog()
        let malformedFinished = try await catalogFinished(after: malformedReplies)
        check(malformedFinished && model.projectsLoadState == .loaded && !model.projects.isEmpty
              && model.projects == recoveredProjects, "W224-3 malformed root catalog keeps prior success")
        let fresh = ChatGPTSpaceModel(testTap: tap)
        fresh.retryProjects()
        _ = try await until { fresh.projectsLoadState == .failed("讀不到專案清單") }
        check(fresh.projectsLoadState == .failed("讀不到專案清單") && fresh.projects.isEmpty,
              "W203-5 malformed first root catalog is still an explicit failure")
    }

    private static func device(_ id: String, _ name: String, selected: Bool = true) -> HandsBuildDevice {
        HandsBuildDevice(id: id, name: name, isPrimary: id == "two", isThisDevice: id == "one", selected: selected,
                         state: .done, subdomain: "fixture", url: nil, connection: .done)
    }
    private static func until(seconds: Int = 3, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(seconds))
        while !predicate(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }

    private static func evidence(_ check: (Bool, String) -> Void, model: ChatGPTSpaceModel, tap: ChatGPTTap,
                                 partial: HandsConnectEntryState, entry: HandsConnectEntry) async throws {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let out = URL(fileURLWithPath: path)
        let defaults = UserDefaults(suiteName: "w199-" + UUID().uuidString)!
        let session = ChatGPTConversationSession(tap: tap)
        let store = GlobalDMStore(defaults: defaults, chatGPT: { session }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(ChatGPTModelCatalog(models: [], defaultModelID: nil, defaultEffortID: nil)).eraseToAnyPublisher() },
                                  directKeys: false, recentApps: defaults)
        // 紙主題固定淺色，不能拿它套深色旗標當證據；只換這個程序的取色快取，偏好設定不寫入。
        _ = TatwoThemeStore.shared
        let palette = TatwoActivePalette.current, appearance = NSApp.appearance
        TatwoActivePalette.current = TatwoTheme.aurora.palette
        defer { TatwoActivePalette.current = palette; NSApp.appearance = appearance }
        var onlineNotice = HandsConnectionNotice()
        for tick in [0.0, 5, 10, 15] {
            onlineNotice.update(partial, devices: [device("one", "Fixture One"), device("two", "Studio Fixture")],
                                uptime: tick, actionableHosts: ["two"]) { _ in }
        }
        for scheme in [ColorScheme.light, .dark] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let word = scheme == .light ? "light" : "dark"
            let space = HStack(spacing: 0) {
                ChatGPTSpaceSidebarList(model: model).frame(width: 250)
                Divider()
                ChatGPTSpaceMainPane(model: model, showsHeader: false, connectionEntry: entry)
            }
            let dm = VStack(spacing: 0) {
                Text("ChatGPT").font(.headline).padding(16)
                HandsConnectEntryButton(entry: entry)
                GlobalDMChatGPTPane(store: store, session: session, isAvailable: true, directory: model)
            }
            for (surface, view, size) in [("space", AnyView(space), CGSize(width: 1080, height: 720)),
                                           ("dm", AnyView(dm), CGSize(width: 390, height: 650))] {
                let name = "w199-" + surface + "-" + word + ".png"
                guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: size, scheme: scheme),
                      let png = rendered.bitmap.representation(using: .png, properties: [:]) else {
                    check(false, "W199 screenshot " + name); continue
                }
                defer { rendered.close() }
                let ids = GlobalDMChatAcceptance.identifiers(in: rendered)
                if scheme == .dark {
                    check(rendered.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                          && TatwoThemeSelfTestScope.hasReadableDarkPixels(rendered.bitmap),
                          "W199 " + surface + " dark screenshot has native dark appearance and readable pixels")
                }
                check(!ids.contains("tatwo.dm.handsConnect.entry") && !ids.contains("chatgpt.handsConnect.entry"),
                      "W199 quiet " + surface + " " + word + " has no connection entry in native accessibility tree")
                try png.write(to: out.appendingPathComponent(name))
                check(true, "W199 screenshot " + out.appendingPathComponent(name).path)
            }
            var pressed = 0, dismissed = 0
            let actionable = TatwoComposerModeAcceptance.ClickRig(
                HandsConnectEntryPill(text: onlineNotice.text!, help: partial.help, dismiss: { dismissed += 1 }) { pressed += 1 }
                    .environment(\.colorScheme, scheme)
                    .padding(12).frame(width: 500, height: 80), size: CGSize(width: 500, height: 80))
            actionable.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            await actionable.settle(8)
            await actionable.click(NSPoint(x: 250, y: 40))
            check(pressed == 1, "W203-1 online revoked account shows one actually clickable prompt " + word)
            await actionable.click(NSPoint(x: 417, y: 40))
            check(dismissed == 1 && pressed == 1, "W205-2 先不用 is a separate clickable chip without triggering reconnection " + word)
            if let rendered = actionable.capture() {
                GlobalDMChatAcceptance.save(rendered, "w203-online-unlinked-" + word + ".png", to: out)
            } else { check(false, "W203-1 online prompt screenshot") }
            actionable.close()
            var disabledPressed = 0
            let disabled = TatwoComposerModeAcceptance.ClickRig(
                OSChipButton(title: "停止", role: .destructive) { disabledPressed += 1 }
                    .disabled(true).environment(\.colorScheme, scheme)
                    .frame(width: 500, height: 80), size: CGSize(width: 500, height: 80))
            await disabled.settle(8)
            await disabled.click(NSPoint(x: 250, y: 40))
            check(disabledPressed == 0, "W205-1 readable disabled chip still rejects native mouse action " + word)
            disabled.close()
        }
    }

    final class Pod: FakeTapPod {
        var hiddenRequests = 0, revision = 1
        var holdProjects = false, failProjects = false, emptyProjects = false, malformed = false, failList = false, failSearch = false
        var pendingProjects: [String] = []
        var holdCatalog = false, failCatalog = false
        var pendingCatalog: [String] = []
        var catalogReplies = 0

        override func start() throws {
            isRunning = true; starts += 1
            Task { @MainActor in
                while hidden && isRunning { try? await Task.sleep(for: .milliseconds(10)) }
                guard isRunning else { return }
                try? await Task.sleep(for: .milliseconds(100))
                emit(["type":"hello", "loggedIn":true])
            }
        }

        override func respond(_ command: [String: Any], id: String, cmd: String) {

            if hidden { hiddenRequests += 1 }
            if cmd == "projects", holdCatalog { pendingCatalog.append(id); return }
            if cmd == "projectConversations", holdProjects { pendingProjects.append(id); return }
            respond(id, cmd: cmd)
        }
        func flushCatalog() {
            let ids = pendingCatalog; pendingCatalog = []
            for id in ids { respond(id, cmd: "projects") }
        }
        func flushProjects() {
            let ids = pendingProjects; pendingProjects = []
            for id in ids { respond(id, cmd: "projectConversations") }
        }
        private func respond(_ id: String, cmd: String) {
            if cmd == "projects" { catalogReplies += 1 }
            if (cmd == "projects" && failCatalog) || (cmd == "projectConversations" && failProjects) || (cmd == "list" && failList) || (cmd == "search" && failSearch) {
                emit(["type":"result", "id":id, "ok":false, "message":"fixture failure"]); return
            }
            let row: [String: Any] = ["id":"fixture-conversation", "title":"Fixture conversation \(revision)", "update_time":Date().timeIntervalSince1970]
            var result: [String: Any] = ["items":[]]
            switch cmd {
            case "projectConversations": result = malformed ? [:] : ["items":emptyProjects ? [] : [row]]
            case "list", "search": result = malformed ? [:] : ["items":[row], "total":1]
            case "projects": result = malformed ? [:] : ["items":[["id":"g-p-fixture", "title":"Fixture project \(revision)", "kind":"project"]]]
            case "models": result = ["models":[]]
            default: break
            }
            emit(["type":"result", "id":id, "ok":true, "data":result])
        }

    }
}
/// 入口也對著真正的簽章回報跑：假同步傳輸、假連接器 Pod、暫存授權資料，不接實機。
extension HandsBuildAcceptance {
    @MainActor static func w199EntryChecks(_ check: (Bool, String) -> Void, _ root: URL) async throws -> HandsConnectEntry {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let keys = try makeKeys(root) else { throw TapError.notReady }
        let fleet = try Fleet(root.appendingPathComponent("fleet"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One"), b = try fleet.add(bID, name: "Studio B")
        try fixtureAccount(p); try fixtureAccount(b)
        _ = try fleet.update([.select(device: pID, selected: true), .select(device: bID, selected: true), .setEnabled(true),
                              .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let hosts = [(p, "os-for-chatgpt.example.com"), (b, "os-for-chatgpt-studiob.example.com")]
        for (device, host) in hosts {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
            var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = "/mcp"
            device.phase.set(.running(url: url.string!))
        }
        fleet.syncAll(); fleet.syncAll()
        let accounts = HandsConnectAccounts(url: root.appendingPathComponent("accounts.json"))
        let identity = "u=fixture|w=fixture|e=fixture", tag = HandsConnectAccounts.identityTag(identity)
        for (device, host) in hosts {
            let grant = try r11Pair(device.service, host: host)
            accounts.remember(HandsConnectAccountRecord(host: device.id, identityTag: tag,
                                                        grantTag: HandsBuildDeviceReport.grantTag(grant.grant), level: 2,
                                                        at: fleet.clock.now(for: pID).addingTimeInterval(-300), uptime: fleet.clock.uptime() - 300,
                                                        grantVersion: device.service.auth.stateVersion))
        }
        fleet.syncAll()
        let flow = r11InertFlow(owner: pID)
        let controller = reviewController(fleet, p, flow: flow)
        _ = await r11CaughtUp(controller, [p, b])
        let states = CurrentValueSubject<TapConnection, Never>(.ready)
        let login = HandsPodLogin(state: states.eraseToAnyPublisher())
        let entry = HandsConnectEntry(build: { controller }, flow: flow, now: { fleet.clock.now(for: pID) }, uptime: { fleet.clock.uptime() },
                                      openSetup: {}, accounts: accounts, probeIdentity: { identity }, login: login)
        _ = await waitUntil(3) { entry.identityTag == tag }
        entry.refresh()
        check(entry.state == .connected(hosts: [pID, bID], level: 2) && entry.noticeText == nil,
              "W199 actual entry with signed confirmed grants remains silent")
        states.send(.failed("fixture temporary restart")); entry.refresh()
        check(entry.identityTag == nil && entry.noticeText == nil && entry.state != .connected(hosts: [pID, bID], level: 2),
              "W199 transient web failure waits quietly without asserting an unverified account is connected")
        states.send(.ready)
        _ = await waitUntil(3) { entry.identityTag == tag }
        entry.refresh()
        check(entry.noticeText == nil && entry.state == .connected(hosts: [pID, bID], level: 2),
              "W199 restored web identity quietly confirms the same account again")
        fleet.offline.set([bID]); fleet.clock.advance(46)
        p.sync.syncNow()
        try await Task.sleep(for: .milliseconds(100))
        entry.refresh()
        let partial: Bool = { if case .partial = entry.state { return true }; return false }()
        check(partial && entry.noticeText == nil && controller.connecting == nil,
              "W199 actual partial entry rechecks existing background sync without opening a connect flow")
        for _ in 0..<3 {
            // 等這輪假的同步完畢才推進兩個時鐘，避免模擬出「RPC 中途牆鐘跳過」的另一個案例。
            p.sync.syncNow()
            fleet.clock.advance(5)
            entry.refresh()
        }
        check(entry.noticeText == nil && controller.connecting == nil,
              "W203-1 offline signed host never produces an actionable line")
        for _ in 0..<5 {
            p.sync.syncNow()
            fleet.clock.advance(60)
            entry.refresh()
        }
        check(entry.noticeText == nil && !p.sync.debugHot()
              && HandsBuildSync.interval(role: .authority(local: pID, epoch: 1), hot: p.sync.debugHot(), permitActive: true, permitKnown: true,
                                         failures: 0, membersHot: false, intervals: .init()) == 30,
              "W203-1 offline five minutes releases heat and returns primary sync to 30 seconds")
        // 失敗後的背景核對沿用 60 秒退避；資料內容没變，仍須發布這次的新鮮時間戳。
        p.sync.syncNow()
        fleet.clock.advance(60)
        fleet.offline.set([])
        b.sync.syncNow()
        entry.refresh()
        let recovered = await waitUntil(3) {
            entry.refresh()
            if case .connected = entry.state { return true }
            return false
        }
        check(recovered && entry.noticeText == nil && controller.connecting == nil && flow.card == nil,
              "W199 actual background recovery clears the line without a card, new connector or permission change state=\(entry.state) suspect=\(controller.connectEvidence(bID)?.clockSuspect ?? true)")
        for (device, _) in hosts { check(device.service.auth.revokeAll(reason: "fixture") == nil, "W207 expiry fixture revokes its synthetic grant") }
        fleet.syncAll(); fleet.syncAll()
        let revoked = await waitUntil(3) { entry.refresh(); return entry.noticeText != nil }
        check(revoked, "W207 fresh revoked evidence produces an actionable notice")
        if let synced = p.sync.lastSync {
            fleet.clock.advance(max(0, HandsBuildController.freshWindow - fleet.clock.now(for: pID).timeIntervalSince(synced) - 0.15))
            entry.refresh()
            check(entry.noticeText != nil, "W207 notice remains until evidence actually expires")
            try await Task.sleep(for: .milliseconds(400))
            check(entry.noticeText == nil, "W207 evidence expiry clears the notice without a repeating timer or another refresh event")
        } else { check(false, "W207 expiry fixture has a synchronization timestamp") }
        return entry
    }
}
#endif
