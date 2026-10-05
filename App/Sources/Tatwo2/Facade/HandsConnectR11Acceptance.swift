#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI

// W183 R11 自測（w183connect；完整隔離的 staging，不開通道、不啟動關口、不上網）：快速接通與斷線。
// 使用者 09-30：「接上要明確讓chatgpt能獲得codex能力 以及os記憶讀取」「全程使用者應該只按一兩個按鍵 不勾選、不研究，就是一個很簡單的串接，
// 關鍵是 ui要簡單好懂而不是砸文字做解釋」「測試接上跟取消」；主導 09-30（實測 .031 之後）A 入口、B 沒登入就先在框裡登入再自動接著連、
// C 主副設備、D 狀態膠囊與 hands_setup_status、E 自測。
// - 預設：新的一份 ChatGPT build 預設 L2（Codex＝沙盒工作區＋記憶讀取）；舊的一份（R11 之前）還是舊預設 L1 的那幾台照一次升到 L2、L0 不動。
// - 按一下［連線］（確認卡）之後：進度點、已連線卡「已連線：Codex、記憶」＋［斷線］（留著，不再 2.5 秒自己收）；［斷線］＝撤銷，ChatGPT 再叫＝被拒；
//   斷線後按［連線］重接（ChatGPT 裡已經有的連接器照 R6b 的「重新連線」）。
// - 沒登入 ChatGPT：按［連線］＝框裡是 ChatGPT 登入頁；登入好自動接著連（不回到確認卡、不用再按）。
// - 入口：私訊框 ChatGPT 對象上方的小膠囊、＋ › 外掛程式那一頁的第一列（規則純資料驗；畫面證據 PNG）。
// - 只剩結果的卡片（已連線、已斷線）不擋 Computer Use（沒有碼、沒有同意）；連線過程的卡片照舊擋。

extension HandsConnectAcceptance {
    @MainActor static func r11Checks(_ check: Checker, _ base: URL) async throws {
        try r11Defaults(check, base)
        r11Faces(check)
        r11EntryRules(check)
        try await r11ConnectDisconnect(check, base)
        try await r11LoginContinues(check, base)
        try await r11bChecks(check, base)   // W183 R11 第二輪：GPT-6 R11 審查的反例（HandsConnectR11bAcceptance.swift）
        await r11Evidence(check)
    }

    // MARK: 預設：Codex＋記憶（L2）

    @MainActor static func r11Defaults(_ check: Checker, _ base: URL) throws {
        let empty = HandsBuildConfig.empty(primaryID: hostID, epoch: 1)
        check(HandsBuildConfig.defaultLevel == 2 && empty.levelDefault == 2 && HandsBuildConfig.upgradedDefaults(empty) == nil
              && HandsConnectAbility.of(level: HandsBuildConfig.defaultLevel) == [.codex, .memory],
              "W183 R11 新的一份 ChatGPT build：預設 L2＝Codex（沙盒工作區）＋記憶（讀、遮敏感），不用再選範圍")
        func entry(_ id: String, level: Int, revision: Int) -> HandsBuildDeviceEntry {
            HandsBuildDeviceEntry(deviceID: id, name: "Primary One", isPrimary: id == hostID, selected: true,
                                  subdomain: id == hostID ? "os-for-chatgpt" : "os-for-chatgpt-b", level: level, projectIDs: [],
                                  deviceRevision: revision, revocationGeneration: 0)
        }
        let old = HandsBuildConfig(primaryID: hostID, authorityEpoch: 1, configRevision: 5, enabled: true, accountID: nil, zoneID: nil, domain: nil,
                                   devices: [entry(hostID, level: 1, revision: 3), entry(secondaryID, level: 0, revision: 2)], migratedFromLegacy: nil)
        let upgraded = HandsBuildConfig.upgradedDefaults(old)
        // W183 R11 第二輪（GPT-6 R11 審查 1，高）：遷移不直接升（那台現有的連線可能是收窄過的舊 L2 grant）——記成待升，
        // 等那台的回報說它會先封頂（level_guard）或沒有連線才升（HandsBuildConfig.raisingPending）。原本「遷移就升、版本 +1」的守法改寫成這樣。
        check(upgraded?.entry(hostID)?.level == 1 && upgraded?.entry(hostID)?.deviceRevision == 3 && upgraded?.levelDefaultPending == [hostID]
              && upgraded?.entry(secondaryID)?.level == 0 && upgraded?.entry(secondaryID)?.deviceRevision == 2
              && upgraded?.configRevision == 6 && upgraded?.levelDefault == 2 && upgraded.flatMap(HandsBuildConfig.upgradedDefaults) == nil,
              "W183 R11 舊的一份（沒有 level_default）照一次：舊預設 L1 的記成待升 L2（還不升：現有連線不能因為遷移就放大）；刻意收窄的 L0 不動、不列；照過就不再照",
              "\(String(describing: upgraded))")
        // 升不升看那台的回報：舊版主機（沒有 level_guard）＝不升；會先封頂的（R11 起）＝升（那台的版本 +1、整份 +1）。
        // W183 R11 最後一輪（GPT-6 R11c 審查 1）：舊版主機沒有連線也不升；會先封頂的要回報夠新、已經套用到現在這一版。
        let at = Date()
        var oldHost = HandsBuildDeviceReport(deviceID: hostID)
        oldHost.grants = 1
        oldHost.receivedAt = at
        oldHost.appliedConfigRevision = 6   // 已經套用到遷移之後的這一版
        var guarded = oldHost
        guarded.levelGuard = true
        var idle = HandsBuildDeviceReport(deviceID: hostID)   // 舊版、沒有連線
        idle.receivedAt = at
        idle.appliedConfigRevision = 6
        let kept = upgraded.flatMap { HandsBuildConfig.raisingPending($0, device: hostID, report: oldHost, now: at) }
        let raised = upgraded.flatMap { HandsBuildConfig.raisingPending($0, device: hostID, report: guarded, now: at) }
        let raisedIdle = upgraded.flatMap { HandsBuildConfig.raisingPending($0, device: hostID, report: idle, now: at) }
        let other = upgraded.flatMap { HandsBuildConfig.raisingPending($0, device: secondaryID, report: guarded, now: at) }
        check(kept == nil && raised?.entry(hostID)?.level == 2 && raised?.entry(hostID)?.deviceRevision == 4 && raised?.levelDefaultPending == nil
              && raised?.configRevision == 7 && raisedIdle == nil && other == nil
              && raised.flatMap { HandsBuildConfig.raisingPending($0, device: hostID, report: guarded, now: at) } == nil,
              "W183 R11 第二輪 待升的那台：舊版主機（回報沒有 level_guard）＝不升（W183 R11 最後一輪：沒有連線也不升）；回報說會先封頂＝升到 L2（版本 +1）；不在待升清單的不動",
              "kept=\(kept == nil) raised=\(String(describing: raised?.entry(hostID)?.level)) idle=\(String(describing: raisedIdle?.entry(hostID)?.level))")
        // W183 R11 最後一輪（GPT-6 R11c 審查 1 反例：過舊的「零 grant」回報）：同一道 raiseCheck——舊版主機零連線（新的、舊的都一樣）＝請它先更新；
        // 會先封頂的主機：回報太舊（主設備收到超過 raiseReportWindow）、時間在未來（鐘跳過）、還沒套用到這一版＝先等它回報；都對＝可以調高。
        let current = upgraded ?? old
        var staleIdle = idle
        staleIdle.receivedAt = at.addingTimeInterval(-3600)
        var guardedStale = guarded
        guardedStale.receivedAt = at.addingTimeInterval(-(HandsBuildConfig.raiseReportWindow + 5))
        var guardedFuture = guarded
        guardedFuture.receivedAt = at.addingTimeInterval(HandsBuildConfig.raiseReportWindow + 5)
        var guardedBehind = guarded
        guardedBehind.appliedConfigRevision = 5
        typealias R = HandsBuildConfig
        check(R.raiseCheck(idle, config: current, now: at) == .needsUpdate && R.raiseCheck(staleIdle, config: current, now: at) == .needsUpdate
              && R.raiseCheck(oldHost, config: current, now: at) == .needsUpdate && R.raiseCheck(nil, config: current, now: at) == .unknown
              && R.raiseCheck(guardedStale, config: current, now: at) == .unknown && R.raiseCheck(guardedFuture, config: current, now: at) == .unknown
              && R.raiseCheck(guardedBehind, config: current, now: at) == .unknown && R.raiseCheck(guarded, config: current, now: at) == .allowed
              && upgraded.flatMap { R.raisingPending($0, device: hostID, report: guardedBehind, now: at) } == nil
              && upgraded.flatMap { R.raisingPending($0, device: hostID, report: guardedStale, now: at) } == nil,
              "W183 R11 最後一輪（GPT-6 R11c 審查 1 反例）舊版主機零連線的回報（剛收到的、一小時前的）＝不調高、請它先更新；會先封頂的主機回報太舊、時間在未來、還沒套用到這一版＝先等它回報；新的、套用到這一版＝可以")
        // 讀檔那一條：舊檔第一次讀＝升級並存起來；再讀（新的一份）不再升、版本不再動。
        let root = base.appendingPathComponent("r11-defaults", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = HandsPaths(root: URL(fileURLWithPath: HandsPath.realpath(root.path) ?? root.path).appendingPathComponent("hands", isDirectory: true))
        let dependencies = HandsBuildConfigStore.Dependencies(role: { .authority(local: hostID, epoch: 1) }, devices: { [] }, legacy: { nil })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(old), to: HandsBuildConfigStore(paths: paths, dependencies: dependencies).url)
        let first = HandsBuildConfigStore(paths: paths, dependencies: dependencies).load()
        let second = HandsBuildConfigStore(paths: paths, dependencies: dependencies).load()
        let raw = (try? Data(contentsOf: HandsBuildConfigStore(paths: paths, dependencies: dependencies).url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // W183 R12（使用者 09-30 裁決：拿掉等級選擇；所有設備一律 L2）：讀檔那一條多照一次 unifiedLevels——刻意收窄過的 L0（secondaryID）
        // 也記成待升（還是 L0、不直接升），整份再 +1（＝7）。R11 守的照舊：還是 L1、待升清單記下、第二次讀是存下來的那一份。
        check(first?.entry(hostID)?.level == 1 && first?.entry(secondaryID)?.level == 0 && first?.levelDefaultPending == [hostID, secondaryID]
              && first?.configRevision == 7 && first?.levelUnified == true && second == first
              && raw.contains("\"level_default\"") && raw.contains("\"level_default_pending\"") && raw.contains("\"level_unified\""),
              "W183 R11 主設備讀到舊的設定檔：照一次並存回去（level_default、待升清單記下；還是 L1），第二次讀是存下來的那一份；W183 R12：L0 也記成待升（還是 L0）",
              "first=\(String(describing: first?.configRevision)) second=\(String(describing: second?.configRevision)) pending=\(String(describing: first?.levelDefaultPending))")
        // 那台來回報（主設備 record → applyPendingDefault）：舊版＝不升；會先封頂（回報新、套用到這一版）＝升並存起來。
        // W183 R12：存下來的那一份是 7（多照了一次 unifiedLevels）：那台要套用到 7 才升。
        var guardedNow = guarded
        guardedNow.appliedConfigRevision = 7
        let store = HandsBuildConfigStore(paths: paths, dependencies: dependencies)
        let notYet = store.applyPendingDefault(device: hostID, report: oldHost)
        let now = store.applyPendingDefault(device: hostID, report: guardedNow)
        let reread = HandsBuildConfigStore(paths: paths, dependencies: dependencies).load()
        check(notYet == nil && now?.entry(hostID)?.level == 2 && reread?.entry(hostID)?.level == 2 && reread?.levelDefaultPending == [secondaryID],
              "W183 R11 第二輪 主設備收到那台的回報：舊版有連線＝還是 L1；回報說會先封頂＝升到 L2 並存起來（重讀也是）",
              "reread=\(String(describing: reread?.entry(hostID)?.level))")
    }

    // MARK: 卡片：圖示＋一句、進度點、短的退路、已連線／已斷線

    @MainActor static func r11Faces(_ check: Checker) {
        typealias F = HandsConnectCardFace
        check(HandsConnectAbility.words(level: 2) == "Codex、記憶" && HandsConnectAbility.words(level: 1) == "記憶、提案"
              && HandsConnectAbility.words(level: 0) == "只看" && HandsConnectFlow.connectedText(level: 2) == "已連線：Codex、記憶"
              && HandsConnectFlow.connectedText(levelOrNil: nil) == "已連線：能力未確認",   // W183 R11 第二輪（GPT-6 R11 審查 5）
              "W183 R11 接上之後拿到什麼（照等級）：L2＝「已連線：Codex、記憶」；L1＝記憶、提案；L0＝只看")
        let fallbacks: [(String, String)] = [(HandsConnectFlow.riskAckCardText, F.ackLine), (HandsConnectFlow.tickMissedCardText, F.tickMissedLine),
                                             (HandsConnectFlow.warningChangedCardText, F.changedLine), (HandsConnectFlow.checkboxUnknownCardText, F.unknownBoxLine),
                                             (HandsConnectFlow.untrustedTickCardText, F.untrustedLine), (HandsConnectFlow.loginCardText, F.loginLine),
                                             (HandsConnectFlow.developerModeCardText, F.developerLine),
                                             (HandsConnectFlow.warningCardText("x"), F.warningLine)]
        let shortened = fallbacks.allSatisfy { full, short in
            let face = F.make(.waitingUser(full, continuable: true), phase: .waitingUser)
            return face.line == short && face.detail == full && short.count <= 40 && full.count > short.count
        }
        let manual = F.make(.manual(url: "https://example.com/mcp", steps: HandsConnectFlow.manualSteps("https://example.com/mcp")), phase: .needsManual)
        check(shortened && manual.line == F.manualLine && F.manualLine.count <= 60,
              "W183 R11 退路卡（沒勾到、要你勾、登入、開發者模式、手動）都只留一句短話；整句留在提示與無障礙（不刪、不改流程的字）",
              fallbacks.map { F.make(.waitingUser($0.0, continuable: true), phase: .waitingUser).line }.joined(separator: "｜"))
        var working = HandsConnectCardContext(phase: .creatingConnector)
        let dots = working.showsDots
        working.cancelling = true
        let cancelling = !working.showsDots
        let loading = !HandsConnectCardContext(phase: .waitingTap).showsDots
        let disconnecting = !HandsConnectCardContext(phase: .connected, disconnecting: true).showsDots
        check(dots && cancelling && loading && disconnecting && HandsConnectFlow.progressSteps == 4
              && [HandsConnectionPhase.creatingConnector, .waitingPairing, .verifying].allSatisfy { HandsConnectCardContext(phase: $0).showsDots },
              "W183 R11 連線中＝進度點（準備→建外掛→配對→確認，四格）；讀取中、取消中、斷線中照舊一句＋轉圈")
        let connected = F.make(.connected(HandsConnectFlow.connectedText(level: 2)), phase: .connected)
        let disconnected = F.make(.disconnected(HandsConnectFlow.disconnectedText), phase: .idle)
        check(connected.kind == .connected && connected.actions == [.disconnect] && connected.dismissTitle == "完成"
              && disconnected.kind == .disconnected && disconnected.actions == [.reconnect] && disconnected.dismissTitle == "完成",
              "W183 R11 已連線卡：「已連線：Codex、記憶」＋［斷線］＋完成；已斷線卡：一句＋［連線］＋完成")
        // 只剩結果的卡片不算連線過程（不擋 Computer Use）；過程的每一種照舊算。
        let offer = HandsConnectOffer(hostDeviceID: hostID, hostName: "Primary One", publicHost: publicHost,
                                      scope: HandsGrantScope(level: 2, projects: [], memory: HandsGrantScope.memoryText(level: 2)),
                                      callbackHosts: ["chatgpt.com"], setupEpoch: "epoch-1")
        let process: [HandsConnectCard?] = [nil, .loading("x"), .confirm(offer, account: nil), .working("x"), .waitingUser("x", continuable: true),
                                            .pairing(HandsConnectPairingView(displayCode: "AB12", expiresAt: Date(), attemptsLeft: 5, callbackHost: "chatgpt.com",
                                                                             pairingCode: nil, popup: false)),
                                            .verifying("x"), .needsManual("x"), .refused("x"), .failed("x"), .manual(url: "u", steps: [])]
        check(process.allSatisfy { HandsConnectPresenter.inProcess($0) }
              && !HandsConnectPresenter.inProcess(.connected("x")) && !HandsConnectPresenter.inProcess(.disconnected("x")),
              "W183 R11 Computer Use 閘門：確認、登入、警語、配對、確認中、出錯（再連＝重新同意）照舊擋；只剩結果的已連線／已斷線卡不擋（連上之後在閘門外看得到狀態）")
        // 確認卡那一行照等級；網址、全部專案、授權後回到哪收成一行小字（T15 那幾項照樣都在卡上）。
        let line = HandsConnectConfirmContent.line(offer)
        let facts = HandsConnectConfirmContent.facts(offer)
        // W183 R12（使用者 09-30 裁決：拿掉等級選擇；主導：確認卡不顯示等級膠囊，直接寫能力）：那一句改成連上後能做的（主機名在上面那一條路）。
        check(line == "連上後：看全部專案・可用 Codex・記憶只讀＋收件匣" && facts.contains(publicHost) && facts.contains("chatgpt.com")
              && facts.contains(HandsConnectConfirmContent.projectsText(offer)),
              "W183 R11 確認卡：一句能力（W183 R12：「連上後：看全部專案・可用 Codex・記憶只讀＋收件匣」，不畫等級膠囊）；網址、專案、授權後回到哪一行小字", "\(line)｜\(facts)")
    }

    // MARK: 入口的規則（三個地方同一份）

    @MainActor static func r11EntryRules(_ check: Checker) {
        typealias S = HandsConnectEntryState
        func device(_ id: String, selected: Bool = true, connection: HandsBuildNodeState) -> HandsBuildDevice {
            HandsBuildDevice(id: id, name: "Primary One", isPrimary: id == hostID, isThisDevice: id == hostID, selected: selected, state: .done,
                             subdomain: "os-for-chatgpt", url: nil, connection: connection)
        }
        // W183 R11 第二輪（GPT-6 R11 審查 3、4）：每台的判定改成「目前這個帳號的那一條在不在」（HandsConnectVerdict）；原本的
        //「回報已連線／剛連上／剛斷線」三個輸入收成一個判定（剛連上的樂觀、剛斷線的紀錄都在判定裡：HandsConnectR11bAcceptance 驗）。守的一樣。
        func resolve(enabled: Bool = true, _ devices: [HandsBuildDevice], cloudflare: HandsBuildNodeState = .done,
                     phase: HandsConnectionPhase = .idle, verdict: HandsConnectVerdict = .open) -> S {
            S.resolve(enabled: enabled, devices: devices, cloudflare: cloudflare, phase: phase, verdict: { _ in verdict })
        }
        let off = resolve(enabled: false, [device(hostID, connection: .waiting)])
        let none = resolve([device(hostID, selected: false, connection: .off)])
        let setup = resolve([device(hostID, connection: .waiting)], cloudflare: .waiting)
        let ready = resolve([device(hostID, connection: .waiting)])
        let running = resolve([device(hostID, connection: .waiting)], phase: .waitingPairing)
        let done = resolve([device(hostID, connection: .done)], verdict: .connected(level: 2))
        let otherAccount = resolve([device(hostID, connection: .done)], verdict: .open)
        let ended = resolve([device(hostID, connection: .done)], verdict: .ended(.revoked))
        let unconfirmed = resolve([device(hostID, connection: .done)], verdict: .connected(level: nil))
        check(off == .hidden && none == .hidden && setup == .setup && ready == .connect && running == .connecting
              && done == .connected(hosts: [hostID], level: 2) && otherAccount == .connect && ended == .connect
              && unconfirmed == .connected(hosts: [hostID], level: nil) && unconfirmed.word == "已連線・能力未確認",
              "W183 R11 入口的狀態：ChatGPT build 沒開＝不出來；網址還沒好＝到設定；好了＝「連線」；連線中；目前這個帳號連上＝「已連線・Codex、記憶」；主機上只有別的帳號（或核對不了）、那一條不在了＝「連線」；能力沒有證據＝「已連線・能力未確認」",
              "\(off) \(none) \(setup) \(ready) \(running) \(done) \(otherAccount) \(ended) \(unconfirmed)")
        check(S.connect.word == "連線" && S.setup.word == "連線" && S.connected(hosts: [], level: 2).word == "已連線・Codex、記憶"
              && S.connect.symbol == "link" && HandsConnectEntry.status(.connected(hosts: [hostID], level: 2))
                == HandsConnectEntryStatus(state: "connected", text: "已連線・Codex、記憶", abilities: ["codex", "memory"], level: 2, capability: "confirmed")
              && HandsConnectEntry.status(.connected(hosts: [hostID], level: nil)).capability == "unconfirmed"
              && HandsConnectEntry.status(.connected(hosts: [hostID], level: nil)).abilities.isEmpty
              && HandsConnectEntry.status(.connect, hostAuthorized: true).hostAuthorized
              && HandsConnectEntry.status(.connect).state == "not_connected" && HandsConnectEntry.status(.setup).state == "setup_needed",
              "W183 R11 膠囊的字：圖示＋「連線」兩個字；連上＝「已連線・Codex、記憶」；hands_setup_status 的 connection 同一份（connected、codex、memory、L2）")
        // ＋ › 外掛程式：第一列是 TATWO 的「連線」（沒開 ChatGPT build＝不列，ChatGPT 的清單照舊）。
        let row = ChatGPTQuickMenuRow(id: HandsConnectEntry.menuRowID, symbol: "link", title: "連線", detail: "讓 ChatGPT 用這台的 Codex 和記憶")
        let with = ChatGPTQuickMenu.plusSections(tools: [], recentApps: [], selectedToolID: nil, thinking: nil, showingPlugins: true, tatwo: row)
        let without = ChatGPTQuickMenu.plusSections(tools: [], recentApps: [], selectedToolID: nil, thinking: nil, showingPlugins: true)
        let main = ChatGPTQuickMenu.plusSections(tools: [], recentApps: [], selectedToolID: nil, thinking: nil, showingPlugins: false, tatwo: row)
        check(with.map(\.id) == ["back", "tatwo", "none"] && with[1].rows.first?.id == HandsConnectEntry.menuRowID
              && without.map(\.id) == ["back", "none"] && !main.flatMap(\.rows).contains { $0.id == HandsConnectEntry.menuRowID },
              "W183 R11 ＋ › 外掛程式那一頁：返回下面第一列就是「連線」（ChatGPT 的工具清單照舊在下面）；沒開＝不列；第一頁不多東西",
              "with=\(with.map(\.id)) without=\(without.map(\.id))")
        // 私訊框：對象是 ChatGPT、對話看得到、沒有別的東西浮在上面才出來。
        let store = GlobalDMStore(defaults: UserDefaults(suiteName: "w183r11.entry.\(UUID().uuidString)") ?? .standard,
                                  chatGPTAllowed: { true }, directKeys: true)
        store.select(.chatGPT)
        let shown = HandsConnectEntryPill.shows(store: store, cardShown: false)
        let hiddenByCard = !HandsConnectEntryPill.shows(store: store, cardShown: true)
        var offNotice = HandsConnectionNotice()
        offNotice.update(.hidden, devices: [], uptime: 0) { _ in }
        let hiddenOff = offNotice.text == nil
        store.isChatGPTDrawerOpen = true
        let hiddenByDrawer = !HandsConnectEntryPill.shows(store: store, cardShown: false)
        store.isChatGPTDrawerOpen = false
        store.select(.assistant)
        let otherTarget = !HandsConnectEntryPill.shows(store: store, cardShown: false)
        check(shown && hiddenByCard && hiddenOff && hiddenByDrawer && otherTarget,
              "W183 R11 私訊框的膠囊：ChatGPT 對象的主畫面才出來（卡片、抽屜在上面、別的對象、ChatGPT build 沒開＝不出來）",
              "shown=\(shown) card=\(hiddenByCard) off=\(hiddenOff) drawer=\(hiddenByDrawer) other=\(otherTarget)")
    }

    // MARK: 按一下就接上（L2）→ 已連線卡留著 → ［斷線］＝ChatGPT 被拒 → 再按［連線］重接

    @MainActor static func r11ConnectDisconnect(_ check: Checker, _ base: URL) async throws {
        // 卡片這一段（按［斷線］之後卡片怎麼變）：這個世界的撤銷＝這台主機的 revokeEverything（逐台結果）。正式的 controller 三條撤銷路
        //（本機、主設備 RPC、信箱）另外在 w183build 用正式的 HandsBuildController 驗（HandsBuildR11Acceptance：GPT-6 R11 審查 7）。
        let world = try World(base, "r11-connect", disconnect: { service, hosts in
            let outcome: HandsDisconnectOutcome = service.revokeEverything() == nil ? .revoked : .revokedUnsaved("x")
            return Dictionary(hosts.map { ($0.lowercased(), outcome) }, uniquingKeysWith: { a, _ in a })
        })
        let service = world.service
        _ = try service.updateSettings { $0.level = 2 }   // 這個世界沒接 ChatGPT build：本機設定＝上限（中央的預設是 L2）
        let seen = HandsConnectorAck(form: "fr11tick001", warning: "0123abcd-97")
        world.pod.createQueue = [.tickable(seen, tickTarget)]
        world.pod.tickResult = true
        var chatgpt = FakeChatGPT(service: service)
        world.pod.onTick = { world.chatgptStarts(chatgpt) }
        var authCode: String?
        world.pod.fillBehavior = { code, _, _ in
            authCode = try? chatgpt.submit(code)
            return .filled
        }
        var steps: [Int] = []
        let watch = world.flow.$progressStep.sink { steps.append($0) }
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        let confirmLevel: Int? = { if case .confirm(let offer, _)? = world.flow.card { return offer.scope.level }; return nil }()
        world.flow.connect()   // 使用者唯一按的一下
        let authorized = await waitUntil(8) { authCode?.isEmpty == false }
        let access = try chatgpt.token(authCode ?? "")
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { world.flow.phase == .connected }
        let tools = (try? service.handle(method: "hands_tools", params: ["access_token": access]))?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        let codex = ["open_workspace", "read_file", "write_file", "run_command", "submit_workspace"].allSatisfy(names.contains)
        let memory = ["memory_search", "memory_get", "memory_inbox_save"].allSatisfy(names.contains)
        check(confirmLevel == 2 && authorized && connected && codex && memory,
              "W183 R11 按一下［連線］就接上：範圍 L2，ChatGPT 拿到的工具有 Codex（開工作區、讀寫檔、跑指令、交件）與記憶（搜尋、讀、寫收件匣）",
              "level=\(String(describing: confirmLevel)) tools=\(names.sorted())")
        let text: String? = { if case .connected(let value)? = world.flow.card { return value }; return nil }()
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // 以前 2.5 秒自己收：現在留著
        let stays: Bool = { if case .connected? = world.flow.card { return true }; return false }()
        let ordered = steps == steps.sorted() && [0, 1, 2, 3].allSatisfy(steps.contains)
        check(text == "已連線：Codex、記憶" && stays && world.presenter.shown && ordered,
              "W183 R11 已連線卡：「已連線：Codex、記憶」留著（按完成才收、上面有［斷線］）；中間走過的四格進度點照順序",
              "text=\(String(describing: text)) steps=\(steps)")
        watch.cancel()
        // ［斷線］：撤銷＝ChatGPT 再叫就被拒；卡片換成「已斷線」＋［連線］。
        world.flow.disconnect()
        let gone = await waitUntil(5) { if case .disconnected? = world.flow.card { return true }; return false }
        var rejected = false
        do { _ = try service.handle(method: "hands_tools", params: ["access_token": access]) } catch { rejected = true }
        check(gone && rejected && world.flow.phase == .idle && service.auth.activeGrantIDs.isEmpty && world.presenter.shown,
              "W183 R11 ［斷線］一下就斷乾淨：授權撤銷（ChatGPT 再叫 hands_tools＝被拒）、卡片「已斷線」＋［連線］",
              "card=\(String(describing: world.flow.card)) grants=\(service.auth.activeGrantIDs.count)")
        // 沒接上撤銷的流程（預設）：不假裝斷了。
        let unwired = try World(base, "r11-unwired")
        unwired.flow.showConnected(hosts: [hostID], level: 2)
        unwired.flow.disconnect()
        let honest = await waitUntil(3) {
            if case .connected? = unwired.flow.card { return unwired.flow.problem == HandsConnectFlow.disconnectUnavailable }
            return false
        }
        check(honest, "W183 R11 撤銷沒成（這裡沒接上）：照實說沒斷成、已連線卡照舊（［斷線］可以再按），不假裝斷了",
              "card=\(String(describing: unwired.flow.card)) problem=\(String(describing: unwired.flow.problem))")
        // 再按［連線］：ChatGPT 裡已經有那個連接器＝照 R6b 的「重新連線」，新的授權能用、舊的照舊被拒。
        chatgpt = FakeChatGPT(service: service)
        authCode = nil
        world.pod.scanResult = HandsConnectorScan(loggedIn: true, listKnown: true, devMode: true,
                                                  matches: [.init(id: "conn-r11", name: "TATWO（Primary One）", auth: "oauth")])
        world.chatgptStarts(chatgpt)
        world.flow.reconnect()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        world.flow.connect()
        let again = await waitUntil(8) { authCode?.isEmpty == false }
        let access2 = try chatgpt.token(authCode ?? "")
        try chatgpt.tools(access2)
        let reconnected = await waitUntil(5) { world.flow.phase == .connected }
        check(again && reconnected && world.pod.calls.contains("reconnect:conn-r11") && service.auth.grant(forAccess: access2) != nil
              && service.auth.grant(forAccess: access) == nil,
              "W183 R11 斷線之後再按［連線］重接：ChatGPT 裡的 TATWO 連接器照舊，重新連線拿到新的授權；斷掉的那一組照舊被拒",
              "calls=\(world.pod.calls.suffix(8))")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 沒登入 ChatGPT：按一次［連線］→ 框裡登入 → 自動接著連

    @MainActor static func r11LoginContinues(_ check: Checker, _ base: URL) async throws {
        let world = try World(base, "r11-login")
        world.pod.readiness = .needsLogin
        let chatgpt = FakeChatGPT(service: world.service)
        world.chatgptStarts(chatgpt)
        var authCode: String?
        world.pod.fillBehavior = { code, _, _ in
            authCode = try? chatgpt.submit(code)
            return .filled
        }
        world.flow.offer()
        _ = await waitUntil(5) { isConfirm(world.flow.card) }
        let noAccount: Bool = { if case .confirm(_, let account)? = world.flow.card { return account == nil }; return false }()
        world.flow.connect()   // 唯一按的一下
        let loginStep = await waitUntil(5) {
            if case .waitingUser(let text, continuable: false)? = world.flow.card { return text == HandsConnectFlow.loginCardText }
            return false
        }
        let inBox = world.presenter.podVisible && world.presenter.shown && world.service.auth.windowExpiresAt == nil
        world.pod.readiness = .ready(account: Self.account)   // 使用者在框裡登入好了
        let authorized = await waitUntil(10) { authCode?.isEmpty == false }
        let access = try chatgpt.token(authCode ?? "")
        try chatgpt.tools(access)
        let connected = await waitUntil(5) { world.flow.phase == .connected }
        check(noAccount && loginStep && inBox && authorized && connected,
              "W183 R11（B）沒登入 ChatGPT：同一顆［連線］＝框裡顯示 ChatGPT 登入頁（卡片一句「登入好自動接著連」、這時窗口關著）；登入好自動接著建外掛、代填、連上（不用再按、不回頭找入口）",
              "calls=\(world.pod.calls) card=\(String(describing: world.flow.card))")
        world.flow.cancel(reason: "test_done")
    }

    // MARK: 畫面證據（PNG）：入口、確認卡、登入、進行中、已連線、已斷線、外掛程式那一頁

    @MainActor static func r11Evidence(_ check: Checker) async {
        guard let folder = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"], !folder.isEmpty else {
            return check.skip("W183 R11 畫面證據：沒有 TATWO2_SELFTEST_ARTIFACTS（不是 lead-verify 跑的）")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let size = CGSize(width: GlobalDMForm.outerPortrait.size.width + GlobalDMLayout.margin * 2,
                          height: GlobalDMForm.outerPortrait.size.height + GlobalDMLayout.margin * 2)
        var written: [String] = []
        func shoot(_ name: String, _ view: some View) {
            guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: size) else { return }
            if let png = rendered.bitmap.representation(using: .png, properties: [:]), (try? png.write(to: out.appendingPathComponent(name))) != nil {
                written.append(name)
                print("W183CONNECT NOTE evidence \(out.appendingPathComponent(name).path)")
            }
            rendered.close()
        }
        typealias P = DMBrowserPhoneAcceptance
        let offer = HandsConnectOffer(hostDeviceID: hostID, hostName: "Primary One", publicHost: publicHost,
                                      scope: HandsGrantScope(level: 2, projects: [HandsProjectRef(id: UUID().uuidString, name: "Primary One 專案"),
                                                                                  HandsProjectRef(id: UUID().uuidString, name: "示範專案")],
                                                             memory: HandsGrantScope.memoryText(level: 2), allProjects: true, readOnlyProjectIDs: []),
                                      callbackHosts: ["chatgpt.com"], setupEpoch: "epoch-1")

        // 1. 入口：私訊框 ChatGPT 對象，頂列下面一顆「連線」（連上＝「已連線・Codex、記憶」）。
        let chat = P.Phone("r11-chat")
        chat.store.select(.chatGPT)
        shoot("r11-1-entry.png", P.phoneShot(chat.store, entryScreen(.connect)))
        // 2. 按了＝［連線］卡（圖示＋一行字；只有取消｜連線）；沒登入多一行。
        shoot("r11-2-confirm.png", confirmSheet(chat.store, offer: offer, account: "Primary One"))
        shoot("r11-2b-confirm-not-logged-in.png", confirmSheet(chat.store, offer: offer, account: nil))

        // 3. 沒登入：框裡是 ChatGPT 的登入頁（Pod），卡片一句「登入好自動接著連」。
        let login = evidencePhone(page: "ChatGPT 登入（假頁面）：Email、用 Google 繼續")
        login.store.showBrowser()
        _ = login.browser.openPod(purpose: .chatgptDeveloper)
        login.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/auth/login"), generation: 1, loading: false, httpStatus: 200))
        login.box.card = .waitingUser(HandsConnectFlow.loginCardText, continuable: false)
        login.presenter.show()
        shoot("r11-3-login.png", P.phoneShot(login.store, login.pane()))
        login.presenter.hide()

        // 4. 進行中：浮在 ChatGPT 分頁上的進度點（第三格：配對）。
        let busy = evidencePhone(page: "ChatGPT Dev・New Plugin（假頁面）")
        busy.store.showBrowser()
        _ = busy.browser.openPod(purpose: .chatgptDeveloper)
        busy.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        busy.flow.debugShowProgress(step: 2, phase: .waitingPairing)
        busy.box.card = .working("等 ChatGPT 開出 TATWO 的配對頁…")
        busy.presenter.show()
        shoot("r11-4-progress.png", P.phoneShot(busy.store, busy.pane()))

        // 5. 已連線：小卡「已連線：Codex、記憶」＋［斷線］；私訊框 ChatGPT 對象上方的膠囊也是「已連線・Codex、記憶」。
        busy.flow.debugShowProgress(step: HandsConnectFlow.progressSteps, phase: .connected)
        busy.box.card = .connected(HandsConnectFlow.connectedText(level: 2))
        shoot("r11-5-connected.png", P.phoneShot(busy.store, busy.pane()))
        shoot("r11-5b-entry-connected.png", P.phoneShot(chat.store, entryScreen(.connected(hosts: [hostID], level: 2))))

        // 6. 斷線之後：一句＋［連線］；膠囊回到「連線」。
        busy.flow.debugShowProgress(step: 0, phase: .idle)
        busy.box.card = .disconnected(HandsConnectFlow.disconnectedText)
        shoot("r11-6-disconnected.png", P.phoneShot(busy.store, busy.pane()))
        busy.presenter.hide()

        // 7. ＋ › 外掛程式那一頁：第一列「連線」。
        let row = ChatGPTQuickMenuRow(id: HandsConnectEntry.menuRowID, symbol: "link", title: "連線", detail: "讓 ChatGPT 用這台的 Codex 和記憶")
        let menu = ChatGPTQuickMenu(sections: ChatGPTQuickMenu.plusSections(tools: [], recentApps: [], selectedToolID: nil, thinking: nil,
                                                                           showingPlugins: true, tatwo: row),
                                    metrics: .dmPhone, identifier: "tatwo.dm.plusMenu") { _ in }
        shoot("r11-7-plugins.png", P.phoneShot(chat.store, VStack { Spacer(minLength: 0); menu.padding(16) }))

        let expected = ["r11-1-entry.png", "r11-2-confirm.png", "r11-2b-confirm-not-logged-in.png", "r11-3-login.png", "r11-4-progress.png",
                        "r11-5-connected.png", "r11-5b-entry-connected.png", "r11-6-disconnected.png", "r11-7-plugins.png"]
        if written.isEmpty {
            check.skip("W183 R11 畫面證據：這個環境畫不出來（沒有畫面環境）")
        } else {
            check(written == expected, "W183 R11 畫面證據 PNG：入口、確認卡（有登入／沒登入）、登入、進行中、已連線（卡與膠囊）、已斷線、外掛程式那一頁", "\(written)")
        }
    }

    /// 私訊框 ChatGPT 對象的主畫面（頂列下面的膠囊、中間一句、輸入框的位置）：跟 HandsConnectDMLayer 同一個位置。
    @MainActor static func entryScreen(_ state: HandsConnectEntryState) -> some View {
        ZStack(alignment: .top) {
            Color.clear
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("問 ChatGPT 任何事；用你自己的 ChatGPT 帳號。")
                    .font(.system(size: DMPhone.TextSize.secondary))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Capsule().fill(Color.primary.opacity(0.06)).frame(height: 44).padding(.horizontal, 16).padding(.bottom, 16)
            }
            if state == .connect || state == .setup {
                HandsConnectEntryPill(text: "連線", help: state.help) {}
                    .padding(.top, HandsConnectEntryPill.gap)
            }
        }
    }

    /// 確認卡（同 HandsConnectDMLayer：遮罩蓋住整支手機，sheet 從下滑出到離頂 96）。
    @MainActor static func confirmSheet(_ store: GlobalDMStore, offer: HandsConnectOffer, account: String?) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                GlobalDMTopBar(store: store, form: .outerPortrait)
                Spacer(minLength: 0)
            }
            Color.black.opacity(GlobalDMWebSheetLayout.dimOpacity)
            HandsConnectSheetView(card: .confirm(offer, account: account), context: HandsConnectCardContext(phase: .waitingTap, offer: offer),
                                  actions: HandsConnectCardActions())
                .padding(.top, GlobalDMWebSheetLayout.topInset)
        }
        .frame(width: GlobalDMForm.outerPortrait.size.width, height: GlobalDMForm.outerPortrait.size.height)
        .modifier(GlobalDMBoxChrome())
        .padding(GlobalDMLayout.margin)
    }

    /// 一支自測的手機（Browser 的 Pod 頁照給的字畫）；跟 DMBrowserPhoneAcceptance.Phone 一樣都是自己的、不碰正式的。
    @MainActor final class EvidencePhone {
        let store: GlobalDMStore
        let browser: DMBrowser
        let box: DMBrowserPhoneAcceptance.CardBox
        let flow: HandsConnectFlow
        let presenter: HandsConnectPresenter
        let shelf: DMBrowserPhoneAcceptance.Shelf
        private let transitions: CurrentValueSubject<Bool, Never>

        init(page: String) {
            let defaults = UserDefaults(suiteName: "w183r11.\(UUID().uuidString)") ?? .standard
            let store = GlobalDMStore(defaults: defaults, chatGPTAllowed: { true }, directKeys: true)
            let transitions = CurrentValueSubject<Bool, Never>(false)
            let browser = DMBrowser(store: store, openBox: {}, pageHost: DMBrowserPhoneAcceptance.EvidenceWebHost(),
                                    podPage: { DMBrowserPhoneAcceptance.EvidencePage(page) }, windowShown: { $0.isVisible },
                                    transitions: { transitions.eraseToAnyPublisher() })
            let box = DMBrowserPhoneAcceptance.CardBox()
            self.store = store
            self.browser = browser
            self.box = box
            self.transitions = transitions
            flow = DMBrowserPhoneAcceptance.inertFlow()
            shelf = DMBrowserPhoneAcceptance.Shelf()
            presenter = HandsConnectPresenter(store: store, openBox: {}, browser: browser, hookPod: { _ in }, podURL: { nil },
                                              cancelFlow: {}, card: { box.card })
        }

        func pane() -> some View {
            // 整合（W184 G2d 拿掉 dmBrowserBarPinned，改成 dmBrowserChromeShown，預設＝照滑鼠、不固定展開）：不設＝原本的 false。
            DMBrowserPane(store: store, browser: browser, flow: flow, connect: presenter, spaces: shelf.spaces)
        }
    }

    @MainActor static func evidencePhone(page: String) -> EvidencePhone { EvidencePhone(page: page) }
}
#endif
