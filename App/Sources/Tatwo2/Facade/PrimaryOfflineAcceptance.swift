#if DEBUG
import Foundation
import SwiftUI
import AppKit
import Combine

/// `TATWO2_SELFTEST=w182assistoffline`：主設備斷線時助理在這台接著聊、連回補回同一條；要主設備才能做的事先排隊、
/// 連回依序送出；W201：自動處理安靜，拒收才提示。無頭驗收，只在完整隔離的 staging 環境跑（引擎要未登入，不燒額度）。
/// 兩個 live root：主設備（ChatPageModel＋真的 OSAgentBridge，照 socket 上同一套認人、處理、錯誤轉字串）與副設備
/// （ChatPageModel，主設備用記憶體替身接到主設備那台的真引擎資料，已配對設備呼叫直接交給主設備的 bridge；不連 SSH）。
/// 本機助理的回覆不跑引擎：送出換成記錄替身，回覆的列直接接在本機那條（就像引擎回完）。
enum PrimaryOfflineAcceptance {
    final class CallLog {
        var calls: [(method: String, params: [String: Any])] = []
        var methods: [String] { calls.map(\.method) }
        /// 記憶提案核准替身接下來要回的結果（每條提案一串；空了就回成功）。
        var memoryReplies: [String: [PrimaryCallFailure?]] = [:]
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w182assistoffline needs a fully isolated staging environment")
        }
        let staging = URL(fileURLWithPath: stagingPath).standardizedFileURL.resolvingSymlinksInPath()
        let live = URL(fileURLWithPath: livePath).standardizedFileURL.resolvingSymlinksInPath()
        guard live.path.hasPrefix(staging.path + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: live.appendingPathComponent("document.json").path) else {
            throw BotLibraryError.invalid("w182assistoffline requires a fresh live root")
        }
        let login = EngineLogin(environment: environment)
        guard [ClaudeSidecar.Kind.claude, .codex, .grok].allSatisfy({ !login.status(for: $0).isLoggedIn }) else {
            throw BotLibraryError.invalid("isolated engine homes must be logged out; refusing to send")
        }
        let disableKey = "tatwo2.disabledEngines"
        let disableBefore = UserDefaults.standard.stringArray(forKey: disableKey)
        let pollBefore = DistillWire.pollInterval
        DistillWire.pollInterval = 0.02
        defer { DistillWire.pollInterval = pollBefore }

        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W182ASSISTOFFLINE \(condition ? "PASS" : "FAIL") \(label)")
        }

        let base = staging.appendingPathComponent("w182-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let primaryRoots = DistillWriterRoots(skills: base.appendingPathComponent("primary/skills", isDirectory: true),
                                              entry: base.appendingPathComponent("primary/entry", isDirectory: true))
        try fm.createDirectory(at: primaryRoots.entry, withIntermediateDirectories: true)
        let work = base.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // ---------- 主設備：真引擎資料＋真 bridge ----------
        let primaryLive = live.appendingPathComponent("primary", isDirectory: true)
        try fm.createDirectory(at: primaryLive, withIntermediateDirectories: true)
        let primary = ChatLiveEngine(store: ChatLiveStore(root: primaryLive), environment: environment)
        defer { primary.shutdownAll() }
        let classifyA = primary.newProject(name: "Offline alpha", workdir: work.path)
        let classifyB = primary.newProject(name: "Offline beta", workdir: work.path)
        let movable = primary.newThread(in: classifyA, title: "要搬的串")
        let coderThread = primary.newThread(in: classifyA, title: "主設備的 Coder 串")
        guard let primaryAssistant = primary.doc.assistantThreadID else { throw BotLibraryError.invalid("primary assistant missing") }
        let primaryBots = BotLibrary(root: primaryLive, skillsRoot: base.appendingPathComponent("primary-bot-skills", isDirectory: true))
        await primaryBots.ready()
        let primaryModel = ChatPageModel(environment: environment, botCoreFixture: (primary, BotStore(library: primaryBots)))
        primaryModel.distillState.testRoots = primaryRoots
        primaryModel.disabledEngines = []   // 只改這個 model 的記憶體
        let bridge = OSAgentBridge.distillTestBridge(model: primaryModel)
        // 主設備那條原本聊到這裡（前情）。
        primary.appendOfflineRows(threadID: primaryAssistant, rows: [
            ChatMessage(id: "fixture-p1", role: .user, text: "主設備的問題一：週末要不要備份"),
            ChatMessage(id: "fixture-p2", role: .assistant, text: "主設備的回答一：週六早上備份", status: "done"),
        ])

        let log = CallLog()
        func respond(_ caller: OSSocketCaller, _ method: String, _ params: [String: Any]) async -> Result<[String: Any], Error> {
            guard let request = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else {
                return .failure(RemoteHostLinkError.invalidResponse)
            }
            let data = await Task.detached { bridge.respondForSelfTest(caller: caller, request: request) }.value
            // 跟 RemoteHostLink.callLocked 一樣：ok＝false 原樣變成 remoteError(字串)。
            guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ok = response["ok"] as? Bool else { return .failure(RemoteHostLinkError.invalidResponse) }
            guard ok else { return .failure(RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown")) }
            return .success(response["result"] as? [String: Any] ?? [:])
        }
        let transport: PrimaryCallTransport = { method, params, completion in
            log.calls.append((method, params))
            guard let request = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else {
                return completion(.failure(RemoteHostLinkError.invalidResponse))
            }
            Task.detached {
                let data = bridge.respondForSelfTest(caller: .ssh, request: request)
                await MainActor.run {
                    guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let ok = response["ok"] as? Bool else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
                    guard ok else { return completion(.failure(RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown"))) }
                    let result = response["result"] as? [String: Any] ?? [:]
                    completion(.success((try? JSONSerialization.data(withJSONObject: result)) ?? Data()))
                }
            }
        }
        let distillTransport: DistillTransport = { method, params, completion in
            log.calls.append((method, params))
            guard let request = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else {
                return completion(.failure(RemoteHostLinkError.invalidResponse))
            }
            Task.detached {
                let data = bridge.respondForSelfTest(caller: .ssh, request: request)
                await MainActor.run {
                    guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let ok = response["ok"] as? Bool else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
                    guard ok else { return completion(.failure(RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown"))) }
                    guard let result = response["result"] as? [String: Any] else { return completion(.failure(RemoteHostLinkError.invalidResponse)) }
                    completion(.success(result))
                }
            }
        }
        func call(_ method: String, _ params: [String: Any], via chosen: PrimaryCallTransport? = nil) async -> Result<[String: Any], Error> {
            let outcome = await awaitPrimaryCall(chosen ?? transport, method, params)
            return outcome.flatMap { data in Result { (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] } }
        }
        func errorCode(_ outcome: Result<[String: Any], Error>) -> String? {
            if case .failure(RemoteHostLinkError.remoteError(let code)) = outcome { return code }
            return nil
        }

        // ---------- 副設備：本機引擎＋主設備替身 ----------
        let secondaryLive = live.appendingPathComponent("secondary", isDirectory: true)
        try fm.createDirectory(at: secondaryLive, withIntermediateDirectories: true)
        let secondary = ChatLiveEngine(store: ChatLiveStore(root: secondaryLive), environment: environment)
        defer { secondary.shutdownAll() }
        let localProject = secondary.newProject(name: "Local project", workdir: work.path)
        let localThread = secondary.newThread(in: localProject, title: "副設備本機串")
        guard let localAssistant = secondary.doc.assistantThreadID else { throw BotLibraryError.invalid("local assistant missing") }
        let secondaryBots = BotLibrary(root: secondaryLive, skillsRoot: base.appendingPathComponent("secondary-bot-skills", isDirectory: true))
        await secondaryBots.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (secondary, BotStore(library: secondaryBots)))
        model.disabledEngines = []   // 這台有送得出去的模型（W181 R3 起會退回本機）；只改記憶體

        // (1) 主設備與單機行為不變：沒有主設備時什麼都不做。
        check(primaryModel.primaryLinkState() == nil && primaryModel.primaryOfflineBanner == nil
              && primaryModel.assistantOfflineLine == nil && primaryModel.assistantOfflineBeginTurn() == nil
              && primaryModel.distillCanvasActions.queuedOn == nil && !primaryModel.assistantOfflineHandoffActive,
              "(1) primary: no link, no banner, no top line, no offline turn, distill writes locally")
        primaryModel.primaryOfflineTick()
        check(model.primaryLinkState() == nil && model.primaryOfflineBanner == nil && model.assistantOfflineLine == nil
              && !model.assistantPlacement.isPrimary && model.assistantPlacementNote == nil,
              "(1) standalone (no primary paired): unchanged")

        let primaryDevice = AssistantPrimaryDevice(id: "primary-one", displayName: "Primary One")
        let remote = PrimaryOfflineAcceptanceRemote(engine: primary)
        var reachable = true
        var connecting = false
        model.assistantPrimaryTestDouble = (device: primaryDevice,
                                            engine: { () -> (any AssistantRemoteEngine)? in reachable ? remote : nil },
                                            connecting: { connecting })
        model.distillState.testPrimary = (id: primaryDevice.id, name: "Primary One",
                                          transport: { reachable ? distillTransport : nil })
        guard let sync = model.primaryOfflineSync, let outbox = model.primaryOutbox, let store = model.assistantOfflineStore else {
            throw BotLibraryError.invalid("secondary offline stores missing")
        }
        await outbox.ready()
        await store.ready()
        sync.testPrimaryCall = transport
        sync.testDeviceName = "Secondary One"
        sync.testMemoryDecide = { id, accept, isPublic in
            let logged: [String: Any] = ["id": id, "accept": accept, "isPublic": isPublic]
            log.calls.append(("memory_decide", logged))
            guard var queue = log.memoryReplies[id], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            log.memoryReplies[id] = queue
            return next
        }
        var sentToLocal: [(text: String, seed: String?)] = []
        model.dmLocalSendTestDouble = { threadID, text, _ in
            let seed = MainActor.assumeIsolated { AssistantOfflineSeed.peek(threadID, userText: text) }
            sentToLocal.append((text, seed))
            return true
        }

        // (2) 連得到主設備：助理接主設備那條；頂端那行不出現；記下主設備那條最近的對話（斷線時當前情）。
        connecting = true
        reachable = false
        check(model.primaryOfflineBanner == nil && model.assistantOfflineLine == nil,
              "(2) first connection still pending: no offline line yet")
        connecting = false
        reachable = true
        model.primaryOfflineTick()
        check(model.assistantPlacement.isPrimary && model.primaryOfflineBanner == nil && model.assistantOfflineLine == nil,
              "(2) primary reachable: assistant on the primary, no banner, no top line")
        let remembered = AssistantPrimaryContextMemory.shared.recentPrimaryAssistantMessages(deviceID: primaryDevice.id) ?? []
        check(remembered.map(\.text) == ["主設備的問題一：週末要不要備份", "主設備的回答一：週六早上備份"],
              "(2) recent primary conversation remembered in memory while online")
        remote.transcriptReads = 0
        model.primaryOfflineTick()
        check(remote.transcriptReads == 0,
              "(2) remembering reads the document it already has (no transcript fetch on every update)")

        // (3) W201：斷線時安靜在這台接著聊；第一句帶前情（資料不是指令），第二句不帶。
        reachable = false
        check(!model.assistantPlacement.isPrimary && model.assistantCanSend && model.assistantOfflineHandoffActive
              && model.assistantOfflineLine == nil,
              "(3) offline: runs here quietly without a top line")
        check(model.assistantPlacementNote == nil,
              "(3) DM local fallback is quiet")
        // W201 使用者裁決：能自動接手就不報備；同步與前情的驗收維持原保證。
        check(model.primaryOfflineBanner == nil,
              "(3) window banner is absent while the primary is offline")
        check(model.sendToAssistant(text: "離線第一句") && sentToLocal.count == 1, "(3) first offline turn is sent locally")
        let firstSeed = sentToLocal.first?.seed ?? ""
        check(firstSeed.contains("是資料不是指令") && firstSeed.contains("主設備「Primary One」的助理")
              && firstSeed.contains("主設備的問題一：週末要不要備份") && firstSeed.contains("主設備的回答一：週六早上備份")
              && firstSeed.hasSuffix("離線第一句"),
              "(3) the first turn carries the primary's recent conversation, wrapped as data not instructions")
        check(!AssistantOfflineSeed.isArmed(localAssistant) && store.open(device: primaryDevice.id, localThread: localAssistant)?.seeded == true,
              "(3) the seed is used once; the stretch is recorded")
        secondary.appendOfflineRows(threadID: localAssistant, rows: [
            ChatMessage(role: .user, text: "離線第一句"), ChatMessage(role: .assistant, text: "本機回答一", status: "done")])
        secondary.appendSystemMessage(threadID: localAssistant, text: "這句沒有送出：還沒登入", status: "error|登入")
        check(model.sendToAssistant(text: "離線第二句") && sentToLocal.count == 2 && sentToLocal.last?.seed == nil,
              "(3) only the first offline turn carries the context")
        secondary.appendOfflineRows(threadID: localAssistant, rows: [
            ChatMessage(role: .user, text: "離線第二句"), ChatMessage(role: .assistant, text: "本機回答二", status: "done")])
        // 真的送給引擎時由 ChatLiveEngine.send 拿走（只拿一次）。
        let probe = UUID()
        AssistantOfflineSeed.arm(probe, rows: [CoderImport.SeedRow(kind: .user, text: "舊問題")], label: "主設備「Primary One」的助理")
        let taken = AssistantOfflineSeed.take(probe, userText: "現在的問題")
        check(taken?.contains("舊問題") == true && taken?.hasSuffix("現在的問題") == true
              && AssistantOfflineSeed.take(probe, userText: "再一次") == nil, "(3) engine-side take wraps once, then nothing")

        // (4) 斷線時三種動作放進佇列（畫面照樣可以按）；只收三種；可以取消。
        // 記憶提案核准：記憶提案畫面離線時就是呼叫這個。
        check(outbox.enqueueMemoryDecide(id: "memory-1", accept: true, isPublic: false, text: "記得喝水") != nil,
              "(4) memory approval queued offline")
        // 分類決定：主設備的建議（先在主設備建一則）。
        let suggestItem: [String: Any] = ["threadIDs": [movable.uuidString], "reason": "同一個資料夾",
                                          "targetProjectID": classifyB.uuidString]
        let suggestion = await respond(.app, "project_suggest", ["items": [suggestItem], "callerThreadID": primaryAssistant.uuidString])
        guard case .success(let suggested) = suggestion,
              let proposalID = (suggested["proposalID"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw BotLibraryError.invalid("classification proposal not created: \(suggestion)")
        }
        let board = ProjectClassificationBoard.shared
        board.decideRemote(model: model, deviceID: primaryDevice.id, name: "Primary One", id: proposalID, action: .approve,
                           summary: "1 條 → Offline beta")
        check(board.message == nil
              && outbox.item(.classifyDecide, key: "id", value: proposalID.uuidString)?.state == .queued,
              "(4) classification decision queued offline quietly")
        // /蒸餾 寫入：畫布在這台，按確認寫入先排隊。
        func skill(_ name: String, _ marker: String) -> String {
            "---\nname: \(name)\ndescription: 要打包發版時照這份檢查（\(marker)）\n---\n# 發版檢查\n## 何時用\n要打包發版時。\n"
                + "## 步驟\n1. 跑三輪測試\n## 驗收\n- 三輪一致\n## 不要做\n- 不推公開倉\n"
        }
        func reply(_ text: String) -> ChatMessage {
            ChatMessage(role: .assistant, text: "整理好了：\n```tatwo-distill\n\(text)\n```\n要改再說。")
        }
        func preview(_ id: UUID) async -> Result<DistillWritePlan, Error> {
            await withCheckedContinuation { continuation in model.previewDistill(id) { continuation.resume(returning: $0) } }
        }
        func write(_ id: UUID, _ plan: DistillWritePlan) async -> DistillWriteResult {
            await withCheckedContinuation { continuation in model.writeDistill(id, plan) { continuation.resume(returning: $0) } }
        }
        model.selectedThreadID = localThread
        model.prompt = "/蒸餾"
        model.send()
        let skillText = skill("w182-offline", "離線排隊")
        secondary.updatePlanFromReply(localThread, reply: reply(skillText))
        guard let planID = model.activePlanArtifact?.planID else { throw BotLibraryError.invalid("distill canvas missing") }
        let actions = model.distillCanvasActions
        check(actions.queuedOn == "Primary One" && actions.blocked == nil && actions.executesOn == nil,
              "(4) distill canvas says it will queue for the primary")
        let callsBeforeDistill = log.calls.count
        guard case .success(let offlinePreview) = await preview(planID) else { throw BotLibraryError.invalid("offline preview failed") }
        check(offlinePreview.targets.isEmpty && offlinePreview.name == "w182-offline"
              && offlinePreview.contentSHA == DistillCanvas.sha256(skillText) && log.calls.count == callsBeforeDistill,
              "(4) offline preview checks here, contacts nobody")
        let queuedWrite = await write(planID, offlinePreview)
        let queuedSubmission = model.activePlanArtifact?.distillSubmission
        check(queuedWrite.status == "queued" && !queuedWrite.failed && queuedSubmission?.status == "queued"
              && queuedSubmission?.message.contains("連回主設備「Primary One」後會自動送") == true
              && outbox.item(.distillWrite, key: "planID", value: planID.uuidString)?.state == .queued
              && log.calls.count == callsBeforeDistill,
              "(4) confirm-write queues: canvas marked queued, nothing sent")
        // 取消（頂端那行展開的清單上按「取消」）：佇列拿掉、畫布一起解鎖；再排一次給下面連回用。
        if let queuedItem = outbox.item(.distillWrite, key: "planID", value: planID.uuidString) {
            model.cancelPrimaryOutboxItem(queuedItem)
        }
        check(queuedSubmission != nil && model.activePlanArtifact?.distillSubmission == nil
              && outbox.item(.distillWrite, key: "planID", value: planID.uuidString) == nil,
              "(4) a queued distill write can be cancelled from the top line (canvas unlocked too)")
        let requeued = await write(planID, offlinePreview)
        check(requeued.status == "queued", "(4) distill write queued again")
        // 取消記憶提案那筆。
        if let extra = outbox.enqueueMemoryDecide(id: "memory-cancel", accept: false, isPublic: false, text: "不要這條") {
            outbox.cancel(extra.id)
        }
        check(outbox.item(.memoryDecide, key: "id", value: "memory-cancel") == nil, "(4) a queued memory approval can be cancelled")
        // 只收三種動作、參數照種類。
        check(outbox.enqueue(.memoryDecide, params: ["id": "x", "accept": "true", "isPublic": "false", "method": "send_message"],
                             title: "多一個欄位") == nil
              && outbox.enqueue(.classifyDecide, params: ["deviceID": "p", "id": "not-a-uuid", "action": "approve"], title: "壞 id") == nil
              && outbox.enqueue(.distillWrite, params: [:], title: "空的") == nil
              && PrimaryOutboxItem.Kind.allCases.map(\.rawValue).sorted() == ["distill_write", "memory_decide", "project_proposal_decide"],
              "(4) the queue only takes the three actions with their own parameters")
        // W201：原本約 310 行釘舊橫條的斷言改驗設定清單；排隊三件與助理段落數仍逐一驗。
        check(model.primaryOfflineBanner == nil && model.primaryOfflineDetails?.waiting.count == 3
              && model.primaryOfflineDetails?.assistantStretches == 1,
              "(4) settings list counts what waits to be sent; no banner")
        // 原子寫入、重開 App 讀得回來；不認得的種類、壞檔不影響。
        await outbox.flushWrites()
        let reopened = PrimaryOutbox(root: secondaryLive)
        await reopened.ready()
        check(fm.fileExists(atPath: secondaryLive.appendingPathComponent(PrimaryOutbox.fileName).path)
              && reopened.items.map(\.id) == outbox.items.map(\.id) && reopened.items.allSatisfy { $0.state == .queued },
              "(4) queue file is written and reads back after a restart")
        let crafted = base.appendingPathComponent("crafted", isDirectory: true)
        try fm.createDirectory(at: crafted, withIntermediateDirectories: true)
        let good = PrimaryOutboxItem(id: UUID(), kind: .memoryDecide, params: ["id": "ok", "accept": "true", "isPublic": "false"],
                                     createdAt: Date(), state: .queued, title: "ok", attempts: 0)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var rows = [try JSONSerialization.jsonObject(with: encoder.encode(good))]
        let unknownKind: [String: Any] = ["id": UUID().uuidString, "kind": "send_message", "params": ["threadID": "x", "text": "hi"],
                                          "createdAt": "2026-09-27T00:00:00Z", "state": "queued", "title": "不該收", "attempts": 0]
        rows.append(unknownKind)
        try JSONSerialization.data(withJSONObject: rows).write(to: crafted.appendingPathComponent(PrimaryOutbox.fileName))
        let craftedBox = PrimaryOutbox(root: crafted)
        await craftedBox.ready()
        check(craftedBox.items.map(\.id) == [good.id], "(4) an unknown kind in the file is dropped, the rest reads")
        let corrupt = base.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: corrupt.appendingPathComponent(PrimaryOutbox.fileName))
        let corruptBox = PrimaryOutbox(root: corrupt)
        await corruptBox.ready()
        let kept = (try? fm.contentsOfDirectory(atPath: corrupt.path)) ?? []
        check(corruptBox.items.isEmpty && kept.contains { $0.hasPrefix(PrimaryOutbox.fileName + ".unreadable-") },
              "(4) a broken queue file counts as empty and is kept aside")

        let legacyRoot = base.appendingPathComponent("legacy-terminal")
        let reasons: [(String, Bool)] = [
            ("memory_not_pending", false), ("這條記憶提案在「Primary One」上已經處理過或不在了", false),
            ("caller_not_trusted", true), ("unknown fixture refusal", true), ("proposal_not_found", true)]
        let legacyItems = reasons.map { reason, _ in
            PrimaryOutboxItem(id: UUID(), kind: .memoryDecide,
                params: ["id": "legacy-fixture", "accept": "true", "isPublic": "false"], createdAt: Date(),
                state: .failed, title: "Legacy fixture", reason: reason, refused: true, attempts: 1)
        } + PrimaryOutboxItem.classificationTerminalReasonCodes.sorted().map { code in
            PrimaryOutboxItem(id: UUID(), kind: .classifyDecide,
                params: ["deviceID": "fixture", "id": UUID().uuidString, "action": "approve"], createdAt: Date(),
                state: .failed, title: "Legacy classification", reason: ProjectClassification.userMessage(code: code), refused: true, attempts: 1)
        }
        let explicitRetry = PrimaryOutboxItem(id: UUID(), kind: .memoryDecide,
            params: ["id": "legacy-explicit", "accept": "true", "isPublic": "false"], createdAt: Date(),
            state: .failed, title: "Explicit retry", reason: "memory_not_pending", refused: true, terminal: false, attempts: 1)
        let legacyFile = PrimaryOfflineJSONFile<[PrimaryOutboxEntry]>(url: legacyRoot.appendingPathComponent(PrimaryOutbox.fileName))
        legacyFile.save((legacyItems + [explicitRetry]).map(PrimaryOutboxEntry.init)); await legacyFile.flush()
        let migrated = PrimaryOutbox(root: legacyRoot); await migrated.ready(); await migrated.file.flush()
        let reread = PrimaryOutbox(root: legacyRoot); await reread.ready()
        check(migrated.items.map(\.canRetry) == reasons.map { $0.1 } + Array(repeating: false, count: 4) + [true]
              && reread.items == migrated.items && migrated.items.allSatisfy { $0.terminal != nil },
              "W207 legacy terminal refusals migrate durably; unknown and pairing reasons remain retryable")

        // (5) 主設備那一側：新方法只給已配對設備、只寫助理那條、不觸發引擎。
        let appendRows: [AssistantOfflineRow] = [AssistantOfflineRow(role: "user", text: "探測", createdAt: Date())]
        let unpaired = await call(AssistantOfflineWire.method, AssistantOfflineWire.params(
            requestID: UUID(), threadID: primaryAssistant, device: "Secondary One", rows: appendRows))
        check(errorCode(unpaired)?.hasPrefix("remote_access_disabled") == true, "(5) unpaired primary refuses the append")
        let registry = DeviceRegistry(root: live, authorizedKeysURL: base.appendingPathComponent("unused-authorized-keys"),
                                      environment: environment)
        try registry.add(id: "fixture-secondary", name: "fixture", host: "fixture.invalid", user: "fixture",
                         publicKeyFingerprint: "SHA256:fixture")
        let method = AssistantOfflineWire.method
        check(OSAgentBridge.sshForwardMethods.contains(method) && !OSAgentBridge.untrustedCallerMethods.contains(method)
              && !OSAgentBridge.stagingReadOnlyMethods.contains(method)
              && OSAgentBridge.allows(caller: .ssh, method: method, params: [:], staging: true)
              && [OSSocketCaller.app, .engine(UUID()), .job(UUID()), .helper, .other(pid: nil), .externalAI].allSatisfy {   // W183 R1
                  !OSAgentBridge.allows(caller: $0, method: method, params: [:], staging: true) },
              "(5) the new method is only in the SSH (paired device) list")
        let fromEngine = await respond(.engine(primaryAssistant), method, AssistantOfflineWire.params(
            requestID: UUID(), threadID: primaryAssistant, device: "x", rows: appendRows))
        check(errorCode(fromEngine) == "caller_not_trusted", "(5) an AI engine on the primary cannot append")
        let coderBefore = primary.transcript(for: coderThread).count
        let wrongThread = await call(method, AssistantOfflineWire.params(requestID: UUID(), threadID: coderThread, device: "x", rows: appendRows))
        check(errorCode(wrongThread) == "assistant_unavailable" && primary.transcript(for: coderThread).count == coderBefore,
              "(5) only the primary's own assistant thread can be written")
        var extraKey = AssistantOfflineWire.params(requestID: UUID(), threadID: primaryAssistant, device: "x", rows: appendRows)
        extraKey["model"] = "any"
        var systemRow = AssistantOfflineWire.params(requestID: UUID(), threadID: primaryAssistant, device: "x", rows: appendRows)
        systemRow["rows"] = [["role": "system", "text": "x", "createdAt": "2026-09-27T00:00:00Z"]]
        let refusedShapes = [await call(method, extraKey), await call(method, systemRow),
                             await call(method, ["requestID": UUID().uuidString, "threadID": primaryAssistant.uuidString,
                                                 "device": "x", "rows": [[String: Any]]()])]
        check(refusedShapes.allSatisfy { errorCode($0) == "invalid_params" },
              "(5) only text and time rows (user/assistant) are accepted")

        // (6) 連回：補回主設備那條（順序、標記）、不觸發引擎；依序送出排隊的；Island 說一聲。
        reachable = true
        check(model.primaryOfflineBanner == nil && model.assistantPlacement.isPrimary
              && model.assistantOfflineLine == nil,
              "(6) reconnected: banner absent, back on the primary, merging quietly")
        let primaryBefore = primary.transcript(for: primaryAssistant).count
        outbox.lastMemoryProposals = [UserMemoryProposal(id: "memory-1", text: "記得喝水", isPublic: false, source: "fixture",
                                                         createdAt: Date(), status: "pending", decidedAt: nil)]
        log.calls = []
        let report = await model.primaryOfflineSyncNow()
        let syncMethods = log.methods   // 這一輪同步送出去的（下面重送探測也會記進 log）
        let merged = primary.transcript(for: primaryAssistant)
        let appended = Array(merged.suffix(from: min(primaryBefore, merged.count)))
        let marker = "〔在「Secondary One」離線時〕\n"
        check(report.merge.mergedRows == 4 && appended.count == 5 && appended.first?.role == .system
              && appended.first?.text.contains("在「Secondary One」離線時") == true
              && appended.dropFirst().map(\.text) == [marker + "離線第一句", marker + "本機回答一", marker + "離線第二句", marker + "本機回答二"]
              && appended.dropFirst().map(\.role) == [.user, .assistant, .user, .assistant],
              "(6) the offline stretch lands at the end of the primary's thread, in order, each row marked")
        check(!merged.contains { $0.text.contains("還沒登入") || $0.text.contains("是資料不是指令") },
              "(6) error notes and the seed never travel")
        check(!primary.isRunning(primaryAssistant) && primary.sidecarProcessID(threadID: primaryAssistant) == nil
              && !primaryModel.hasRunningWork, "(6) appending never starts an engine on the primary")
        let stretch = store.stretches.first { $0.localThreadID == localAssistant }
        check(stretch?.state == .merged && secondary.transcript(for: localAssistant).last?.text.contains("已補回「Primary One」") == true
              && secondary.transcript(for: localAssistant).contains { $0.text == "本機回答二" },
              "(6) the local thread keeps its rows and is marked merged")
        check(model.assistantMessages.suffix(4).map(\.text) == [marker + "離線第一句", marker + "本機回答一", marker + "離線第二句", marker + "本機回答二"]
              && model.assistantOfflineLine == nil,
              "(6) the secondary sees that stretch in the primary's thread")
        if let rows = stretch?.rows, let stretchID = stretch?.id {
            let again = await call(method, AssistantOfflineWire.params(requestID: stretchID, threadID: primaryAssistant,
                                                                       device: "Secondary One", rows: rows))
            check((try? again.get())?["duplicate"] as? Bool == true && primary.transcript(for: primaryAssistant).count == merged.count,
                  "(6) resending the same request adds nothing")
        } else {
            check(false, "(6) resending the same request adds nothing")
        }
        // 主設備的引擎：下一句帶上剛補回的那段（資料不是指令），只帶一次；不是助理那條不帶。
        let catchUp = primary.offlineCatchUpSeed(threadID: primaryAssistant, currentTurn: "probe-turn", userText: "剛才說的那件事呢") ?? ""
        let firstRow: String = marker + "離線第一句", lastRow: String = marker + "本機回答二"
        let catchUpCarries = catchUp.contains("是資料不是指令") && catchUp.contains(firstRow) && catchUp.contains(lastRow)
        let catchUpOnlyNew = !catchUp.contains("主設備的回答一") && catchUp.hasSuffix("剛才說的那件事呢")
        let coderNotSeeded = primary.offlineCatchUpSeed(threadID: coderThread, currentTurn: "t", userText: "x") == nil
        check(catchUpCarries && catchUpOnlyNew && coderNotSeeded,
              "(6) the primary's engine gets the merged stretch with its next turn, as data not instructions")
        primary.appendOfflineRows(threadID: primaryAssistant, rows: [
            ChatMessage(id: "fixture-p3", role: .user, text: "主設備接著問"),
            ChatMessage(id: "fixture-p4", role: .assistant, text: "主設備接著答", status: "done")])
        check(primary.offlineCatchUpSeed(threadID: primaryAssistant, currentTurn: "next", userText: "x") == nil,
              "(6) once the primary has answered a turn after it, the stretch is not sent to the engine again")
        check(outbox.lastMemoryProposals.first?.status == "accepted",
              "(6) a sent memory approval marks the proposal decided (the proposals card re-reads)")
        let order = syncMethods.filter { $0 != "distill_write" }
        check(order == [method, "memory_decide", "project_proposal_decide"]
              && syncMethods.filter { $0 == "distill_write" }.count >= 2,
              "(6) queued actions go out in order after the merge")
        check(outbox.items.isEmpty && report.outbox.sent.count == 3 && primary.threadRecord(movable)?.projectID == classifyB,
              "(6) every queued action was sent and removed; the primary moved the thread itself")
        let skillFile = primaryRoots.skills.appendingPathComponent("w182-offline/SKILL.md")
        check((try? Data(contentsOf: skillFile)) == Data(skillText.utf8) && model.activePlanArtifact?.distillSubmission?.status == "done",
              "(6) the queued distill write was previewed and written on the primary; the canvas shows done")

        // (7) 失敗：連線類留著、寫原因、隔一段再送，同一種的後面幾筆照順序等；別種的照送；主設備說不能做的標失敗、不重試。
        reachable = false
        outbox.enqueueMemoryDecide(id: "memory-2", accept: true, isPublic: false, text: "第二條")
        outbox.enqueueMemoryDecide(id: "memory-3", accept: false, isPublic: false, text: "第三條")
        board.decideRemote(model: model, deviceID: primaryDevice.id, name: "Primary One", id: proposalID, action: .approve,
                           summary: "已經搬過的那則")
        log.memoryReplies["memory-2"] = [PrimaryCallFailure(code: "ssh_tunnel_unavailable", remote: false)]
        reachable = true
        log.calls = []
        _ = await model.primaryOfflineSyncNow()
        let waitingItem = outbox.item(.memoryDecide, key: "id", value: "memory-2")
        let refusedItem = outbox.item(.classifyDecide, key: "id", value: proposalID.uuidString)
        let roundOne: [String] = ["memory_decide", "project_proposal_decide"]
        let waitingKept = waitingItem?.state == .queued && waitingItem?.reason == "連線不穩"
        let waitingDelayed = (waitingItem?.retryAfter ?? .distantPast) > Date()
        let laterWaited = outbox.item(.memoryDecide, key: "id", value: "memory-3")?.attempts == 0
        check(log.methods == roundOne && waitingKept && waitingDelayed && laterWaited,
              "(7) a transient failure stays queued with a reason; later items of that kind wait their turn")
        check(refusedItem?.refused == true && refusedItem?.state == .failed && refusedItem?.reason == "這則建議已經處理過了。"
              && refusedItem?.canRetry == false,
              "(7) another kind is not held up; a 'cannot do' is marked failed with a plain reason and no resend")
        log.calls = []
        _ = await model.primaryOfflineSyncNow()
        check(log.calls.isEmpty && outbox.items.count == 3, "(7) a failed item waits out its retry delay (no call every 10 seconds)")
        log.calls = []
        _ = await model.primaryOfflineSyncNow(reconnected: true)
        check(log.methods == ["memory_decide", "memory_decide"] && outbox.items.count == 1,
              "(7) next round sends in order (coming back skips the delay)")
        log.calls = []
        _ = await model.primaryOfflineSyncNow(reconnected: true)
        check(log.calls.isEmpty && outbox.items.count == 1, "(7) a refused action is not retried")
        if let refusedItem { outbox.cancel(refusedItem.id) }
        check(outbox.items.isEmpty, "(7) a failed item can be removed")
        // 記憶提案：主設備回「不能做」這類、這台還沒跟主設備配好的，標失敗寫原因、不重試，也不卡住後面的。
        reachable = false
        outbox.enqueueMemoryDecide(id: "memory-4", accept: true, isPublic: false, text: "第四條")
        outbox.enqueueMemoryDecide(id: "memory-5", accept: true, isPublic: false, text: "第五條")
        outbox.enqueueMemoryDecide(id: "memory-6", accept: true, isPublic: false, text: "第六條")
        log.memoryReplies["memory-4"] = [PrimaryCallFailure(code: "untrusted_rpc_sender", remote: true)]
        log.memoryReplies["memory-5"] = [PrimaryCallFailure(code: "primary_not_paired", remote: false)]
        reachable = true
        log.calls = []
        _ = await model.primaryOfflineSyncNow()
        let rejectedMemory = outbox.item(.memoryDecide, key: "id", value: "memory-4")
        let unpairedMemory = outbox.item(.memoryDecide, key: "id", value: "memory-5")
        let threeDecides: [String] = ["memory_decide", "memory_decide", "memory_decide"]
        let rejectedOK = rejectedMemory?.refused == true && rejectedMemory?.reason?.contains("untrusted_rpc_sender") == true
        let unpairedOK = unpairedMemory?.refused == true && unpairedMemory?.reason?.contains("重新配對") == true
            && rejectedMemory?.canRetry == true && unpairedMemory?.canRetry == true
        let restSent = outbox.item(.memoryDecide, key: "id", value: "memory-6") == nil
        check(log.methods == threeDecides && rejectedOK && unpairedOK && restSent,
              "(7) a memory decision the primary refuses, or this device is not paired for, fails with a reason and does not block the rest")
        log.calls = []
        _ = await model.primaryOfflineSyncNow(reconnected: true)
        check(log.calls.isEmpty, "(7) refused memory decisions are not retried")
        for item in outbox.items { outbox.cancel(item.id) }
        let setupNotQueued = !PrimaryCallFailure(code: "primary_not_paired", remote: false).isRetryable
        let refusedNotQueued = !PrimaryCallFailure(code: "memory_not_pending", remote: true).isRetryable
        let linkQueued = PrimaryCallFailure(RemoteHostLinkError.tunnelUnavailable).isRetryable
        let busyQueued = PrimaryCallFailure(RemoteHostLinkError.remoteError("os_bridge_busy")).isRetryable
        check(outbox.items.isEmpty && setupNotQueued && refusedNotQueued && linkQueued && busyQueued,
              "(7) only connection-type failures are queued from the online path")

        // /蒸餾：排隊時看不到主設備那邊；那邊已經有同名的就不寫、畫布解鎖並說明。
        model.prompt = "/蒸餾"
        model.send()
        secondary.updatePlanFromReply(localThread, reply: reply(skill("w182-offline", "第二版")))
        guard let secondPlan = model.activePlanArtifact?.planID, secondPlan != planID else {
            throw BotLibraryError.invalid("second distill canvas missing")
        }
        reachable = false
        guard case .success(let secondPreview) = await preview(secondPlan) else { throw BotLibraryError.invalid("second preview failed") }
        _ = await write(secondPlan, secondPreview)
        let fileBefore = try? Data(contentsOf: skillFile)
        reachable = true
        _ = await model.primaryOfflineSyncNow()
        let sameName = model.queuedDistillFailure(secondPlan)
        check(sameName?.reason?.contains("同名") == true && model.activePlanArtifact?.distillSubmission == nil
              && (try? Data(contentsOf: skillFile)) == fileBefore
              && model.distillCanvasActions.queueFailure(secondPlan)?.contains("同名") == true,
              "(7) a same-name file on the primary is not overwritten; the canvas unlocks and says why")
        if let sameName {
            reachable = false
            let retryError = model.retryPrimaryOutboxItem(sameName)
            check(retryError == nil && model.activePlanArtifact?.distillSubmission?.status == "queued"
                  && model.activePlanArtifact?.distillSubmission?.id.uuidString == sameName.params["submissionID"]
                  && outbox.waiting.count == 1,
                  "W201 distill retry restores the original canvas boundary before requeueing")
            reachable = true
            _ = await model.primaryOfflineSyncNow(reconnected: true)
            check(model.queuedDistillFailure(secondPlan)?.reason?.contains("同名") == true
                  && model.activePlanArtifact?.distillSubmission == nil && (try? Data(contentsOf: skillFile)) == fileBefore,
                  "W201 distill retry cannot overwrite a same-name primary file and unlocks the canvas")
            if let rejected = model.queuedDistillFailure(secondPlan) {
                let edited = model.saveEditedPlanCanvasText(skill("changed-after-refusal", "changed"))
                check(edited && model.retryPrimaryOutboxItem(rejected) != nil && outbox.waiting.isEmpty
                      && model.queuedDistillFailure(secondPlan)?.id == rejected.id && model.activePlanArtifact?.distillSubmission == nil
                      && (try? Data(contentsOf: skillFile)) == fileBefore,
                      "W201 changed distill canvas refuses retry without queueing or changing the primary")
            } else { check(false, "W201 retried distill refusal stays available for handling") }
        } else { check(false, "W201 refused distill item available for retry") }
        model.distillCanvasActions.dismissQueueFailure(secondPlan)
        check(model.queuedDistillFailure(secondPlan) == nil && outbox.items.isEmpty, "(7) the distill failure line can be dismissed")

        // (8) 舊主設備（不認得補回）：寫一行、先留在這台；主設備更新後補得回去。
        model.primaryOfflineTick()   // 連著：前情換成主設備最新的
        reachable = false
        sentToLocal = []
        check(model.sendToAssistant(text: "第二段離線") && sentToLocal.first?.seed?.contains("本機回答二") == true,
              "(8) a new offline stretch seeds again with the primary's latest (including the merged part)")
        secondary.appendOfflineRows(threadID: localAssistant, rows: [
            ChatMessage(role: .user, text: "第二段離線"), ChatMessage(role: .assistant, text: "本機回答三", status: "done")])
        let oldPrimary: PrimaryCallTransport = { method, params, completion in
            if method == AssistantOfflineWire.method {
                log.calls.append((method, params))
                return completion(.failure(RemoteHostLinkError.remoteError("caller_not_trusted")))
            }
            transport(method, params, completion)
        }
        sync.testPrimaryCall = oldPrimary
        reachable = true
        let primaryCount = primary.transcript(for: primaryAssistant).count
        _ = await model.primaryOfflineSyncNow()
        check(store.stretches.contains { $0.state == .legacy } && primary.transcript(for: primaryAssistant).count == primaryCount
              && model.assistantOfflineLine == nil
              && secondary.transcript(for: localAssistant).last?.text.contains("還沒更新，這段先留在這台") == true,
              "(8) an older primary: quiet retry, the stretch stays here")
        _ = await model.primaryOfflineSyncNow(reconnected: true)
        check(store.stretches.contains { $0.state == .legacy }
              && log.methods.filter { $0 == method }.count >= 2,
              "(8) retrying an older primary does not pop the notice again")
        sync.testPrimaryCall = transport
        _ = await model.primaryOfflineSyncNow(reconnected: true)
        check(!store.stretches.contains { $0.state == .legacy } && primary.transcript(for: primaryAssistant).last?.text == marker + "本機回答三"
              && model.assistantOfflineLine == nil,
              "(8) once the primary is updated the stretch merges")

        // (9) 補失敗（連線類）：留著下次再補，不丟資料。
        reachable = false
        _ = model.sendToAssistant(text: "第三段離線")
        secondary.appendOfflineRows(threadID: localAssistant, rows: [ChatMessage(role: .user, text: "第三段離線")])
        let flaky: PrimaryCallTransport = { method, params, completion in
            if method == AssistantOfflineWire.method { return completion(.failure(RemoteHostLinkError.tunnelUnavailable)) }
            transport(method, params, completion)
        }
        sync.testPrimaryCall = flaky
        reachable = true
        remote.delivered = []
        var draftCleared = false
        // 連回後馬上送新的一句：先等剛才離線那段補回（送出中、不能再送），補不成就不送、草稿留著。
        check(model.assistantPlacement.isPrimary && model.sendToAssistant(text: "連回後第一句", onDelivered: { draftCleared = true })
              && model.assistantOfflineHolding && !model.assistantCanSend && model.assistantIsDelivering,
              "(9) a new turn right after reconnecting waits for the offline stretch to merge first")
        await sync.assistantHold?.value
        let pending = store.stretches.last { $0.localThreadID == localAssistant }
        let pendingRows: [String] = pending?.rows?.map(\.text) ?? []
        let pendingKept = pending?.state == .pending && pendingRows == ["第三段離線"]
        let heldBack = remote.delivered.isEmpty && !draftCleared
        let holdLine = model.assistantOfflineLine ?? ""
        check(pendingKept && heldBack && holdLine.contains("還沒補回") && holdLine.contains("草稿留著"),
              "(9) a failed merge stays pending with its rows; the new turn is not sent and the draft stays")
        sync.testPrimaryCall = transport
        check(model.sendToAssistant(text: "連回後第一句", onDelivered: { draftCleared = true }), "(9) sending again waits for the merge")
        await sync.assistantHold?.value
        let thirdRow: String = marker + "第三段離線"
        let thirdMerged = store.stretches.last { $0.localThreadID == localAssistant }?.state == .merged
            && primary.transcript(for: primaryAssistant).last?.text == thirdRow
        let deliveredTexts: [String] = remote.delivered.map(\.text)
        let deliveredAfter = deliveredTexts == ["連回後第一句"] && remote.delivered.first?.primaryLast == thirdRow
        check(thirdMerged && deliveredAfter && draftCleared && !model.assistantOfflineHolding,
              "(9) the next round merges it, then the new turn goes to the primary after that stretch")
        await store.flushWrites()
        let storeFile = secondaryLive.appendingPathComponent(AssistantOfflineStore.fileName)
        check(fm.fileExists(atPath: storeFile.path), "(9) the stretch record is on disk")

        // (11) 很長的一段：分成幾次送（則數、總字數都在主設備收得下的範圍內），一則都不丟；切法與請求 id 每次都一樣。
        let roles = ["user", "assistant"]
        let manyRows = (0..<450).map { AssistantOfflineRow(role: roles[$0 % 2], text: "長段第 \($0) 則", createdAt: Date()) }
        let bigText = String(repeating: "字", count: 20_000)
        let bigRows = (0..<40).map { AssistantOfflineRow(role: "user", text: bigText + "\($0)", createdAt: Date()) }
        let byCount = AssistantOfflineWire.chunks(manyRows), bySize = AssistantOfflineWire.chunks(bigRows)
        let probeStretch = UUID()
        let countCuts: [Int] = byCount.map(\.count)
        let cutByCount = countCuts == [400, 50] && Array(byCount.joined()) == manyRows
        let partBytes: [Int] = bySize.map { part in part.reduce(0) { total, row in total + row.text.utf8.count } }
        let cutBySize = bySize.count == 2 && Array(bySize.joined()) == bigRows
            && partBytes.allSatisfy { $0 <= AssistantOfflineWire.maxTotalBytes }
        let idFirst = AssistantOfflineWire.requestID(probeStretch, chunk: 0)
        let idSecond = AssistantOfflineWire.requestID(probeStretch, chunk: 1)
        let idThird = AssistantOfflineWire.requestID(probeStretch, chunk: 2)
        let idsStable = idFirst == probeStretch && idSecond == AssistantOfflineWire.requestID(probeStretch, chunk: 1)
            && idSecond != idThird && idSecond != probeStretch
        check(cutByCount && cutBySize && idsStable,
              "(11) a long stretch is cut into parts the primary accepts, same cut and ids every time")
        reachable = false
        _ = model.sendToAssistant(text: "長段 0")
        let longMessages: [ChatMessage] = (0..<450).map { index in
            index % 2 == 0 ? ChatMessage(role: .user, text: "長段 \(index)")
                : ChatMessage(role: .assistant, text: "長段 \(index)", status: "done")
        }
        secondary.appendOfflineRows(threadID: localAssistant, rows: longMessages)
        reachable = true
        let beforeLong = primary.transcript(for: primaryAssistant).count
        log.calls = []
        let longReport = await model.primaryOfflineSyncNow()
        let longMerged = primary.transcript(for: primaryAssistant)
        let longRows = longMerged.suffix(from: min(beforeLong, longMerged.count)).filter { $0.role != .system }.map(\.text)
        let longStretch = store.stretches.last { $0.localThreadID == localAssistant }
        let expectedLong: [String] = (0..<450).map { index in marker + "長段 \(index)" }
        let twoRequests: [String] = [method, method]
        let longLanded = longReport.merge.mergedRows == 450 && log.methods == twoRequests && longRows == expectedLong
        let longNoted = longStretch?.state == .merged && secondary.transcript(for: localAssistant).last?.text.contains("450 則") == true
        check(longLanded && longNoted, "(11) a stretch over 400 rows lands whole and in order, in two requests")
        if let longStretch, let rows = longStretch.rows, AssistantOfflineWire.chunks(rows).count == 2 {
            let again = await call(method, AssistantOfflineWire.params(requestID: AssistantOfflineWire.requestID(longStretch.id, chunk: 1),
                                                                       threadID: primaryAssistant, device: "Secondary One",
                                                                       rows: AssistantOfflineWire.chunks(rows)[1]))
            check((try? again.get())?["duplicate"] as? Bool == true && primary.transcript(for: primaryAssistant).count == longMerged.count,
                  "(11) resending a part adds nothing")
        } else {
            check(false, "(11) resending a part adds nothing")
        }

        // (10) 停用設定一個字都沒寫。
        check(UserDefaults.standard.stringArray(forKey: disableKey) == disableBefore, "(10) engine-disable settings untouched")

        try await quietDevicesChecks(environment: environment, root: base.appendingPathComponent("quiet-live"), check: check)

        print("W182ASSISTOFFLINE SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
    /// W201：正式 View 的隔離點擊驗收，只有暫存根目錄與假設備，沒有 SSH／引擎送出。
    @MainActor static func quietDevicesChecks(environment: [String: String], root: URL,
                                              check: (Bool, String) -> Void) async throws {
        guard let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw BotLibraryError.invalid("W201 requires a screenshot artifacts directory")
        }
        let themeScope = TatwoThemeSelfTestScope()
        let originalAppearance = NSApp.appearance
        defer { themeScope.restore(); NSApp.appearance = originalAppearance }
        let folder = URL(fileURLWithPath: artifacts).appendingPathComponent("w201-quiet-devices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        defer { local.shutdownAll() }
        let library = BotLibrary(root: root, skillsRoot: root.appendingPathComponent("skills"))
        await library.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (local, BotStore(library: library)))
        model.disabledEngines = []
        let device = DeviceRecord(id: "00000001-4444-4444-8444-444444444444", name: "Primary One", host: "192.0.2.10", user: "example", sshPort: 22,
                                  publicKeyFingerprint: "SHA256:quietfixture", addedAt: Date(),
                                  lastSeenAt: Date(), workdirMap: [:])
        // W221b: the device row must come from a verified roster, including in offline UI fixtures.
        let fleetEntry = TatwoEntry(environment: environment)
        let fleetStore = DeviceFleetStore(registry: DeviceRegistry(environment: environment), environment: environment)
        let originalFleet = try fleetStore.read()
        let originalIdentity = try? Data(contentsOf: fleetEntry.deviceJSON)
        defer {
            try? fleetStore.save(originalFleet)
            if let originalIdentity { try? originalIdentity.write(to: fleetEntry.deviceJSON) }
            else { try? FileManager.default.removeItem(at: fleetEntry.deviceJSON) }
        }
        let fixtureKey = root.appendingPathComponent("quiet-roster-key").path
        guard try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", fixtureKey]).0 == 0 else {
            throw DeviceFleetError.missingKey
        }
        let publicKey = try String(contentsOfFile: fixtureKey + ".pub", encoding: .utf8)
        let fingerprint = try DeviceRegistry.fingerprint(publicKey: publicKey)
        var signingEnvironment = environment; signingEnvironment["TATWO2_SSH_KEY_PATH"] = fixtureKey
        signingEnvironment.removeValue(forKey: "SSH_AUTH_SOCK")
        try FileManager.default.createDirectory(at: fleetEntry.root, withIntermediateDirectories: true)
        try DeviceIdentity(deviceID: device.id, name: "fixture", hardwareModel: "fixture", role: .primary,
                           epoch: 1, primaryDeviceID: device.id, updatedAt: Date()).encoded().write(to: fleetEntry.deviceJSON)
        let member = DeviceFleetMember(id: device.id, name: device.name, factionID: "main", role: .primary,
            clientKeyFingerprint: fingerprint, hostKeyFingerprint: nil, clientPublicKey: publicKey, hostPublicKey: nil,
            endpoints: [.init(kind: .lan, host: device.host)], user: device.user, legacy: true)
        let group = DeviceFleetGroup(id: "main", name: "fixture", type: .main, primaryDeviceID: device.id, managerDisplayName: "fixture")
        let roster = DeviceFleetRoster(version: 1, primaryID: device.id, epoch: 1, groups: [group], devices: [member], edges: [])
        var signedState = originalFleet
        signedState.trust = DeviceFleetTrust(localID: device.id, primaryID: device.id, epoch: 1, pinnedPrimaryKey: fingerprint, kind: .owner)
        signedState.envelope = try DeviceFleetEnvelope.issue(.init(roster: roster), environment: signingEnvironment)
        try fleetStore.save(signedState)
        check(try fleetStore.readGraph()?.roster?.devices.contains { $0.id == device.id } == true,
              "W221b offline device row belongs to the verified roster")
        let session = RemoteDeviceSession(device: device, link: RemoteHostLink(environment: environment), environment: environment)
        defer { session.shutdown() }
        model.devices = [device]
        model.w182AdoptRemoteSessionsForTest([session])
        var reachable = false
        model.assistantPrimaryTestDouble = (device: AssistantPrimaryDevice(id: device.id, displayName: device.name),
                                           engine: { reachable ? session.engine : nil }, connecting: { false })
        guard let outbox = model.primaryOutbox, let sync = model.primaryOfflineSync else {
            throw BotLibraryError.invalid("quiet fixture stores missing")
        }
        await outbox.ready()
        let island = IslandNotice.shared
        let islandWasAvailable = island.hostAvailable
        island.hostAvailable = true
        var islandNotices = 0
        let islandObservation = island.$current.compactMap { $0 }.sink { _ in islandNotices += 1 }
        defer { islandObservation.cancel(); island.hostAvailable = islandWasAvailable }
        sync.testMemoryDecide = { _, _, _ in nil }
        let coderProject = local.newProject(name: "Remote project", workdir: root.path)
        let coder = local.newThread(in: coderProject, title: "Remote Coder")
        var doc = local.doc
        if let index = doc.threads.firstIndex(where: { $0.id == coder }) {
            doc.threads[index].messages = [LiveMessageRecord(ChatMessage(role: .user, text: "暫存的 Coder 對話"))]
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let initial: [String: Any] = ["document": try JSONSerialization.jsonObject(with: encoder.encode(doc)),
                                      "revision": NSNumber(value: 1), "runningThreadIDs": [String]()]
        session.w182TestConnect(initial: initial)
        session.engine?.onTranscriptFetched?(coder, doc.threads.first { $0.id == coder }?.messages ?? [])
        await session.w201WaitForCache()
        session.w182TestDisconnect()
        var hints: [String] = []
        session.onHint = { hints.append($0) }
        session.w203ConnectionProblemForTest(RemoteHostLinkError.tunnelStartFailed("Permission denied (publickey) /Users/fixture/private.txt"))
        check(session.connectionProblem == "認證失敗，請檢查設備登入與配對" && hints.isEmpty
              && model.deviceConnectionProblem(device.id) == session.connectionProblem,
              "W203 device authentication failure is fixed Settings-only text without a hint")
        check(RemoteDeviceSession.actionableConnectionProblem(RemoteHostLinkError.tunnelStartFailed("REMOTE HOST IDENTIFICATION HAS CHANGED"))
              == "主機金鑰不符，請重新確認設備配對", "W203 host key mismatch is actionable Settings-only category")
        check(RemoteDeviceSession.actionableConnectionProblem(RemoteHostLinkError.tunnelUnavailable) == nil,
              "W203 ordinary offline has no connection problem or notice")

        func shot(_ rig: TatwoComposerModeAcceptance.ClickRig, _ name: String) throws {
            guard let png = rig.capture()?.bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                throw BotLibraryError.invalid("quiet devices render failed: " + name)
            }
            let target = folder.appendingPathComponent(name + ".png")
            try png.write(to: target)
            print("W201 PNG \(target.path)")
        }
        func point(_ rect: CGRect, height: CGFloat) -> NSPoint {
            NSPoint(x: rect.midX, y: height - rect.midY)
        }
        func tapPopover(_ anchor: (NSWindow, CGRect)?, screenshot: String) async throws -> Bool {
            guard let (window, rect) = anchor, let content = window.contentView else { return false }
            let host = content.superview ?? content
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let target = folder.appendingPathComponent(screenshot + ".png")
                    try png.write(to: target)
                    print("W201 PNG \(target.path)")
                }
            }
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
            return true
        }
        for dark in [false, true] {
            themeScope.use(dark ? .aurora : .fable5)
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            let probe = PrimaryOutboxViewProbe()
            for index in 1...3 { outbox.enqueueMemoryDecide(id: "quiet-\(suffix)-\(index)", accept: true, isPublic: false, text: "測試提案 \(index)") }
            let top = TatwoComposerModeAcceptance.ClickRig(
                VStack(spacing: 0) {
                    PrimaryOfflineBannerHost(model: model, testProbe: probe)
                    Spacer()
                }.frame(width: 1200, height: 220)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                size: CGSize(width: 1200, height: 220))
            top.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await top.settle(12)
            check(model.primaryOfflineBanner == nil && !probe.bannerVisible && probe.bannerFrame == nil,
                  "W201 \(suffix) queued-only: actual banner view absent")
            check(model.assistantCanSend && model.assistantPlacementNote == nil && model.assistantOfflineLine == nil,
                  "W201 \(suffix) local assistant fallback has no connection announcement")
            try shot(top, "window-top-queued-" + suffix)
            let settingsProbe = PrimaryOutboxViewProbe()
            let settings = TatwoComposerModeAcceptance.ClickRig(
                DevicesCard(model: model, testProbe: settingsProbe)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                size: CGSize(width: 850, height: 1100))
            settings.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await settings.settle(12)
            check(model.primaryOfflineDetails?.waiting.count == 3 && !settingsProbe.detailsVisible,
                  "W201 \(suffix) settings device row counts 3; list starts collapsed")
            try shot(settings, "settings-devices-collapsed-" + suffix)
            if let frame = settingsProbe.deviceFrame {
                await settings.click(point(frame, height: settings.size.height))
                await settings.settle(12)
                check(settingsProbe.detailsVisible && settingsProbe.cancelFrames.count == 3,
                      "W201 \(suffix) clicking actual settings device row opens the shared cancellable list")
                try shot(settings, "settings-devices-expanded-" + suffix)
                if let item = outbox.waiting.first, let cancel = settingsProbe.cancelFrames[item.id] {
                    await settings.click(point(cancel, height: settings.size.height))
                    check(!outbox.items.contains { $0.id == item.id } && model.primaryOfflineDetails?.waiting.count == 2,
                          "W201 \(suffix) actual settings cancel updates the count")
                } else { check(false, "W201 settings cancel button geometry") }
            } else { check(false, "W201 settings device row geometry") }
            settings.close()
            for item in outbox.items { model.cancelPrimaryOutboxItem(item) }
            guard outbox.enqueueMemoryDecide(id: "quiet-refused-" + suffix, accept: true, isPublic: false, text: "沒送到的提案") != nil,
                  let refused = outbox.waiting.last else { throw BotLibraryError.invalid("quiet refused fixture") }
            // W203: obsolete proposals are remove-only. This retry fixture is a recoverable refusal.
            sync.testMemoryDecide = { _, _, _ in PrimaryCallFailure(code: "synthetic_refusal", remote: true) }
            session.w182TestConnect(initial: initial); reachable = true
            _ = await model.primaryOfflineSyncNow(reconnected: true)
            await top.settle(12)
            check(probe.bannerVisible && model.primaryOfflineDetails?.failed.count == 1 && outbox.waiting.isEmpty,
                  "W201 \(suffix) real sync refusal after reconnect creates prompt while online")
            try shot(top, "window-top-failed-online-" + suffix)
            session.w182TestDisconnect(); reachable = false
            sync.testMemoryDecide = { _, _, _ in nil }
            await top.settle(12)
            check(probe.bannerVisible && model.primaryOfflineBanner?.line == "有 1 件沒送到「Primary One」：按一下處理",
                  "W201 \(suffix) failed: one clickable handling prompt while offline")
            try shot(top, "window-top-failed-" + suffix)
            probe.retryFrames = [:]; probe.cancelFrames = [:]
            probe.retryNative = [:]; probe.cancelNative = [:]
            if let frame = probe.bannerFrame {
                await top.click(point(frame, height: top.size.height))
                await top.settle(12)
                check(probe.detailsVisible && probe.retryFrames[refused.id] != nil && probe.cancelFrames[refused.id] != nil,
                      "W201 \(suffix) clicking actual prompt opens retry and cancel list")
                let pressed = try await tapPopover(probe.retryNative[refused.id], screenshot: "failed-list-retry-" + suffix)
                await top.settle(12)
                check(pressed && model.primaryOfflineBanner == nil && !probe.bannerVisible && outbox.waiting.count == 1,
                      "W201 \(suffix) actual retry requeues and handling prompt disappears")
            } else { check(false, "W201 failed banner button geometry") }
            for item in outbox.items { model.cancelPrimaryOutboxItem(item) }
            // 第二次拒收走同一個 popover 的取消鈕。
            _ = outbox.enqueueMemoryDecide(id: "quiet-cancel-" + suffix, accept: false, isPublic: false, text: "取消未送到的提案")
            if let item = outbox.waiting.last {
                outbox.mark(item.id, state: .failed, reason: "假主設備拒收", refused: true)
                await top.settle(12)
                if let frame = probe.bannerFrame {
                    probe.cancelFrames = [:]; probe.cancelNative = [:]
                    await top.click(point(frame, height: top.size.height)); await top.settle(12)
                    let pressed = try await tapPopover(probe.cancelNative[item.id], screenshot: "failed-list-cancel-" + suffix)
                    await top.settle(12)
                    check(pressed && outbox.items.isEmpty && model.primaryOfflineBanner == nil && !probe.bannerVisible,
                          "W201 \(suffix) actual failed-item cancel removes prompt automatically")
                } else { check(false, "W201 second failed banner geometry") }
            }
            _ = outbox.enqueueMemoryDecide(id: "quiet-obsolete-" + suffix, accept: false, isPublic: false, text: "合成已處理提案")
            if let obsolete = outbox.waiting.last {
                outbox.mark(obsolete.id, state: .failed, reason: "這條記憶提案已經處理過或不在了", refused: true, terminal: true)
                let obsoleteProbe = PrimaryOutboxViewProbe()
                let obsoleteRig = TatwoComposerModeAcceptance.ClickRig(
                    PrimaryOfflineOutboxList(model: model, outbox: outbox, testProbe: obsoleteProbe)
                        .padding(14).environment(\.colorScheme, scheme), size: CGSize(width: 500, height: 180))
                obsoleteRig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                await obsoleteRig.settle(12)
                let item = outbox.items.first { $0.id == obsolete.id }!
                check(!item.canRetry && obsoleteProbe.retryFrames[item.id] == nil
                      && obsoleteProbe.cancelNative[item.id] != nil && model.retryPrimaryOutboxItem(item) != nil,
                      "W203 obsolete refusal has only Remove and refuses retry before queueing")
                try shot(obsoleteRig, "obsolete-remove-only-" + suffix)
                let removed = try await tapPopover(obsoleteProbe.cancelNative[item.id], screenshot: "obsolete-remove-click-" + suffix)
                check(removed && outbox.items.isEmpty, "W203 actual Remove removes obsolete refusal")
                obsoleteRig.close()
            }
            top.close()
            for item in outbox.items { model.cancelPrimaryOutboxItem(item) }
        }

        // 實際 session 的 connect/disconnect 路徑跑十輪（各輪取消排程，不連網）；同步也各跑一輪。
        var allQuiet = true
        for _ in 0..<10 {
            session.w182TestConnect(initial: initial); reachable = true
            model.primaryOfflineTick(); await model.primaryOfflineSyncSettled()
            _ = await model.primaryOfflineSyncNow(reconnected: true)
            session.w182TestDisconnect(); reachable = false
            model.primaryOfflineTick()
            allQuiet = allQuiet && model.primaryOfflineBanner == nil && model.assistantPlacementNote == nil && model.assistantOfflineLine == nil
        }
        check(allQuiet && hints.isEmpty && islandNotices == 0,
              "W201 ten disconnect/reconnect cycles: zero hints and zero Island notices")
        let noteID = UUID().uuidString.lowercased()
        let automatic = [ChatMessage(id: "offline:\(noteID):head", role: .system, text: "補回說明", status: "info|離線補回"),
                         ChatMessage(id: "offline:\(noteID):legacy", role: .system, text: "舊版重試", status: "info|離線補回"),
                         ChatMessage(id: "offline:\(noteID):merged", role: .system, text: "已補回", status: "done|已補回")]
        let kept = [ChatMessage(role: .user, text: "〔在「Example」離線時〕使用者的原話"),
                    ChatMessage(role: .system, text: "權限已允許", status: "info|權限"),
                    ChatMessage(id: "offline:\(noteID):merged", role: .system, text: "送不到的錯誤", status: "error|送出")]
        check(ChatTranscriptDisplayBuilder.build(automatic + kept).count == kept.count
              && GlobalDMBubble.rows(automatic + kept).count == kept.count,
              "W201 Coder/assistant/DM hide automatic system rows; user text, permission and errors stay")
        check(model.selectRemote(deviceID: device.id, threadID: coder) && model.remoteOfflineReadOnly != nil,
              "W201 selecting offline remote Coder opens the action-local read-only explanation")
        if let state = model.remoteOfflineReadOnly {
            for dark in [false, true] {
                themeScope.use(dark ? .aurora : .fable5)
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let rig = TatwoComposerModeAcceptance.ClickRig(
                    RemoteOfflineComposerBar(model: model, state: state).padding(20)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light),
                    size: CGSize(width: 850, height: 160))
                rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                await rig.settle(12)
                try shot(rig, "remote-coder-offline-" + (dark ? "dark" : "light"))
                rig.close()
            }
        }
        session.w182TestConnect(initial: initial); reachable = true
        _ = outbox.enqueueMemoryDecide(id: "quiet-send", accept: true, isPublic: false, text: "重送仍走原路徑")
        if let item = outbox.waiting.last {
            outbox.mark(item.id, state: .failed, reason: "之前拒收", refused: true)
            model.retryPrimaryOutboxItem(item)
            await model.primaryOfflineSyncSettled()
            _ = await model.primaryOfflineSyncNow()
            check(outbox.items.isEmpty && model.primaryOfflineBanner == nil,
                  "W201 online user retry uses original send path and disappears after delivery")
        }
        await outbox.flushWrites()
    }

}

/// 主設備那台的真引擎資料，包成副設備看得到的遠端引擎（不連 SSH、不送出）。
@MainActor
final class PrimaryOfflineAcceptanceRemote: AssistantRemoteEngine {
    let engine: ChatLiveEngine
    /// 送到主設備的句子，和那一刻主設備那條最後一則（看順序用）。
    var delivered: [(text: String, primaryLast: String?)] = []
    /// 逐字稿讀了幾次（正式版每次讀快取是空的就會經 SSH 重拉一次）。
    var transcriptReads = 0
    init(engine: ChatLiveEngine) { self.engine = engine }
    var doc: LiveDocumentRecord { engine.doc }
    func transcript(for threadID: UUID?) -> [ChatMessage] {
        transcriptReads += 1
        return engine.transcript(for: threadID)
    }
    func isTranscriptLoading(_ threadID: UUID?) -> Bool { false }
    func isRunning(_ threadID: UUID?) -> Bool { engine.isRunning(threadID) }
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? { engine.threadRecord(threadID) }
    func deliver(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind?, assistantRoute: String?,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        delivered.append((text, self.engine.transcript(for: threadID).last?.text))   // 參數 engine 是引擎種類，要讀主設備資料用 self.engine
        completion(.success(()))
    }
    func stop(threadID: UUID) {}
}
#endif
