// W183 R8a：ChatGPT build 的工程細節（節點面板右上「…」打開才看得到）＋主機與副設備共用的小元件。
// 使用者 09-28：「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」「整個流程不要弄得非常多文字」→ 舊的 R6a「一列＋詳細」畫面
// （ChatGPTHandsSection）拿掉：開關、狀態、節點流程與面板在 New/ChatGPTBuildSection.swift；等級、專案、設備、網域、子網域在節點面板。
// 這裡留下收進「…」的：步驟、帳號與網域、已連線與撤銷（含配對窗口）、沒用到的通道、診斷——程式照 R3／R3b／R6a 審查過的版本搬來：
// - 設定頁不直接開舊的沒有連線意圖的配對窗口、不顯示配對碼（只在私訊框的［連線］卡）。
// - 清沒用到的通道：只列符合條件的、卡片內確認、刪之前再查一次、只刪勾的。
// 按鈕一律玻璃 chip；確認用卡片內確認列（不跳系統框）。
// W183 R8a 審查（GPT-6「…」操作繞過 adapter）：這裡的寫入一律經 HandsBuildModel.detail(_:shown:)——畫面畫出來那一刻看到的（shown：主設備、
// 這台的流程世代）帶著走，送出那一刻再核一次，變了就不送。
// W183 R8 整合（R8c 多設備）：每台都是自己的主機——「…」一律是這台自己的（步驟、帳號與網域、已連線與撤銷、沒用到的通道、診斷）；
// 「改用這台當主機」與副設備看主機的那兩塊（ChatGPTHandsRemoteView／ChatGPTHandsRemoteGrants）拿掉（claim_host 退役、公共狀態沒有授權網址）；
// 別台的連線在「已連線與撤銷」的「其他設備」撤銷（經主設備的信箱，只作用在按的時候看到的那一組）。R7a 的「副設備看得到主機的等級與專案」
// 在多設備是 ChatGPT Dev 面板（每台勾選的設備的等級與專案都在中央設定，哪一台都看得到、改得到）。
import SwiftUI
import AppKit

struct ChatGPTBuildDetails: View {
    let kind: HandsBuildMore
    @ObservedObject private var build = HandsBuildModel.shared
    @ObservedObject private var hands = HandsState.shared
    @ObservedObject private var service = ChatGPTHandsService.shared
    @ObservedObject private var setup = HandsSetup.shared
    @ObservedObject private var accounts = CloudflareAccountsStore.shared
    @ObservedObject private var connect = HandsConnectFlow.shared
    @State private var confirming: Confirm?
    @State private var callbackField = ""
    /// W183 R3b：「取消並重新授權」做不了的原因。
    @State private var reauthorizeProblem: String?
    /// W183 R6a：沒用到的 TATWO 通道——勾了哪幾條、確認列、上次清的結果。
    @State private var tunnelSelection: Set<String> = []
    @State private var confirmingTunnelDelete = false
    @State private var tunnelDeleteResult: String?

    private enum Confirm: Equatable { case revoke(String), revokeAll, revokeDevice(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = build.build.localAvailabilityText {
                Text(text).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(build.devices.filter { $0.selected && $0.connection != .done }) { device in
                let text = "\(device.name)：\(build.build.connectionReason(device.id))"
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(text)
            }
            switch kind {
            case .steps:
                setupProgress
            case .account:
                accountBlock
                urlRow
            case .grants:
                grantsBlock
                pairingWindowRow
                otherDevicesBlock
            case .tunnels:
                unusedTunnelsBlock
            case .diagnostics:
                diagnostics
            }
        }
        .onAppear {
            if kind == .tunnels, setup.state.step(.authorize).status == .done { setup.checkUnusedTunnels() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.build.details.\(kind.rawValue)")
    }

    // MARK: 開關與取消勾選的確認列（ChatGPTBuildSection 叫；字留在這裡，主卡片上只有短字）

    /// W183 R8 整合：總開關關掉＝勾選的每一台都關（每台的連線作廢、關口停下；撤銷世代變大）。
    static func offConfirmCopy(devices: Int) -> (question: String, detail: String, confirm: String) {
        ("關掉 ChatGPT build？",
         (devices > 1 ? "勾選的 \(devices) 台都會關掉：" : "") + "所有 ChatGPT 連線（授權）立刻作廢、沙盒裡還在跑的全部收掉、工作區鎖住（保留不刪）。之後重新打開要重新連線。",
         "關掉")
    }

    /// W183 R8 整合（多設備「每台關掉」）：取消勾一台還在跑、有連線的設備。
    static func deselectCopy(name: String) -> (question: String, detail: String, confirm: String) {
        ("關掉「\(name)」的 ChatGPT build？",
         "那台的 ChatGPT 連線（授權）立刻作廢、關口停下、工作區鎖住（保留不刪）；別台不受影響。那台沒開的話，連上主設備時才會停。",
         "關掉")
    }

    /// W183 R8a 審查（Claude）：已經有網址之後換網域的確認列。
    static func zoneChangeCopy(domain: String, connected: Bool) -> (question: String, detail: String, confirm: String) {
        ("改用網域「\(domain)」？",
         (connected ? "現在的 ChatGPT 連線會失效（要重新連線）；" : "") + "現在的網址不能用了，要按「套用」照新網域重建網址。Cloudflare 上舊的通道與 DNS 紀錄不會被刪。",
         "換網域")
    }

    // MARK: 標準設定流程的進度（步驟）

    private var setupProgress: some View {
        let shown = build.seen
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("步驟").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if setup.busy {
                    ProgressView().controlSize(.small)
                    // 取消＝這次連線一起作廢（HandsBuildModel.detail(.cancelSetup)：setup.cancel()＋connectFlow.cancel(reason: "cancelled")）。
                    OSChipButton(title: "取消") { _ = build.detail(.cancelSetup, shown: shown) }
                        .accessibilityIdentifier("tap.chatgpt.hands.cancel")
                }
            }
            if let problem = setup.problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tap.chatgpt.hands.setupProblem")
            }
            ForEach(HandsSetupStep.allCases) { step in
                stepRow(step, shown: shown)
            }
            if let url = setup.loginURL {
                // W183 R5b／R8b：授權頁在這台的私訊框 Browser 開（不關設定、不跳頁）；自動跳出的沒看到，就在這裡打開。
                OSChipButton(title: "在這台打開授權頁", systemImage: "safari") { _ = build.detail(.openLogin(url), shown: shown) }
                    .accessibilityIdentifier("tap.chatgpt.hands.openLogin")
            }
        }
        .accessibilityIdentifier("tap.chatgpt.hands.steps")
    }

    private func stepRow(_ step: HandsSetupStep, shown: HandsBuildSeen) -> some View {
        let entry = step == .start ? HandsSetup.liveStartStep(setup.state.step(step), phase: service.phase) : setup.state.step(step)
        let canRerun = entry.status == .failed && !setup.busy && step != .pairing
        let rerun: (() -> Void)? = canRerun ? { _ = build.detail(.rerun(step), shown: shown) } : nil
        return ChatGPTHandsStepRow(number: step.number, title: step.title, status: entry.status, statusLabel: entry.status.label,
                                   message: entry.message, rerun: rerun, rerunTitle: ChatGPTHandsStepRow.rerunLabel(for: step))
    }

    static let reauthorizeDetail = "會先停下 ChatGPT build、清掉剛才這次登入拿到的 Cloudflare 授權（鑰匙圈），再開一次授權頁讓你選對的帳號與網域；授權完照常接著做。Cloudflare 上已經建的通道與 DNS 紀錄不會被刪（要刪請到 Cloudflare 後台）。"

    /// W183 R3b：第 3 步之後「已授權：Cloudflare 帳號〈名稱〉、網域〈網域〉」；拿到授權後先「請確認」（是這個，繼續／取消並重新授權），
    /// 確認前不建通道、不開網址；上次取消沒清完＝「再清一次」。W183 R8c：登入只是登入，建網址要在 Cloudflare 面板選網域、按「套用」。
    @ViewBuilder private func authorizedBlock(_ summary: HandsAuthorizationSummary) -> some View {
        let shown = build.seen
        HandsAuthorizationRow(summary: summary, canReauthorize: hands.activeGrants.isEmpty, busy: setup.busy, problem: reauthorizeProblem,
                              onConfirm: { domain in
                                  reauthorizeProblem = build.detail(.confirmAuthorization(token: summary.confirmToken ?? "", domain: domain), shown: shown)
                              },
                              onReauthorize: {
                                  // 私訊鈕關掉時授權頁退回 OS 瀏覽器（設定浮層先關）；授權完帶回這頁（HandsBuildModel.detail(.reauthorize)）。
                                  reauthorizeProblem = build.detail(.reauthorize, shown: shown)
                              })
    }

    // MARK: 帳號與網域、網址

    /// 帳號與網域：已授權的那一列（含「取消並重新授權」）、換帳號到環境登入。
    /// W183 R8a 審查（Claude）：選網域只在 Cloudflare 面板的網域選單（網址建好之後換要卡片內確認）；這裡不再放第二個直接換的選單。
    @ViewBuilder private var accountBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = setup.authorizedSummary() { authorizedBlock(summary) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OSChipButton(title: "環境登入 › Cloudflare", systemImage: "arrow.right.circle") { EnvironmentLoginTab.open(.cloudflare) }
                    .accessibilityIdentifier("tap.chatgpt.hands.goCloudflare")
            }
        }
    }

    /// 網址（關口起來後的 MCP 網址）＋固定子網域的標籤（W183 R6a：`<標籤>.<網域>`）。
    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .running(let url) = service.phase {
                row("網址") {
                    Text(url).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    OSChipButton(title: "複製", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .accessibilityIdentifier("tap.chatgpt.hands.copyURL")
                }
            }
            if let problem = service.rangesProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: 配對窗口

    /// W183 R6a 審查（GPT-6「手動配對仍直接開啟舊式無 attempt 窗口」）：這裡不再有「手動配對」（不從設定頁開沒有連線意圖的配對窗口；
    /// 手動退路由 R6b 在使用者按［連線］、建立連線意圖之後提供），也不顯示配對碼（只在私訊框的［連線］卡上）。
    /// 別的路徑開著的窗口：只顯示還剩多久與「收掉配對」。
    @ViewBuilder private var pairingWindowRow: some View {
        if let expires = hands.pairingWindowExpiresAt {
            let shown = build.seen
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(expires.timeIntervalSince(context.date)))
                    Text("配對窗口開著：還有 \(left / 60) 分 \(left % 60) 秒").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                OSChipButton(title: "收掉配對") { _ = build.detail(.stopPairing, shown: shown) }
                    .accessibilityIdentifier("tap.chatgpt.hands.stopPairing")
            }
        }
    }

    // MARK: 已連線與撤銷

    @ViewBuilder private var grantsBlock: some View {
        let active = hands.activeGrants
        let shown = build.seen
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已連線（\(active.count)）").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !active.isEmpty {
                    OSChipButton(title: "全部撤銷", role: .destructive) { confirming = .revokeAll }
                        .accessibilityIdentifier("tap.chatgpt.hands.revokeAll")
                }
            }
            if confirming == .revokeAll {
                confirmRow(question: "撤銷全部 ChatGPT 連線？", detail: "所有授權與 token 立刻作廢、沙盒裡還在跑的全部收掉、工作區鎖住（保留不刪）。ChatGPT 要再用得重新連線。",
                           confirmTitle: "全部撤銷") { _ = build.detail(.revokeAll, shown: shown) }
            }
            ForEach(active) { grant in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        // W183 R8a 審查（GPT-6）：暫時的 grant（還沒確認）標「確認中」，不當已連線。
                        Text(grant.clientName + (grant.provisional ? "（確認中）" : "")).font(.callout)
                        Text("\(HandsState.levelLabel(grant.level))・\(grant.projectIDs.count) 個專案・連線於 \(grant.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    OSChipButton(title: "撤銷", role: .destructive) { confirming = .revoke(grant.id) }
                }
                if confirming == .revoke(grant.id) {
                    confirmRow(question: "撤銷「\(grant.clientName)」這筆連線？", detail: "它的 token 立刻作廢、工作收掉、工作區鎖住（保留不刪）。",
                               confirmTitle: "撤銷") { _ = build.detail(.revoke(grant.id), shown: shown) }
                }
            }
            if let error = hands.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("tap.chatgpt.hands.error")
            }
        }
        .accessibilityIdentifier("tap.chatgpt.hands.grants")
    }

    /// W183 R8 整合（多設備）：別台的連線（那台回報的數字）＋「全部撤銷」（卡片內確認；經主設備的信箱交給那台，只作用在按的時候
    /// 看到的那一組：之後才建的連線不會被晚到的撤銷清掉）。
    @ViewBuilder private var otherDevicesBlock: some View {
        let frame = build.frame
        let others = frame.snapshot.devices.filter { !$0.isThisDevice && (frame.input.anyGrants[$0.id.lowercased()] ?? 0) > 0 }
        if !others.isEmpty {
            let shown = build.seen
            VStack(alignment: .leading, spacing: 6) {
                Text("其他設備").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(others) { device in
                    let count = frame.input.anyGrants[device.id.lowercased()] ?? 0
                    HStack(spacing: 8) {
                        Text("\(device.name)・\(count) 個連線").font(.callout)
                        Spacer()
                        OSChipButton(title: "全部撤銷", role: .destructive) { confirming = .revokeDevice(device.id) }
                            .accessibilityIdentifier("tap.chatgpt.hands.revokeDevice")
                    }
                    if confirming == .revokeDevice(device.id) {
                        confirmRow(question: "撤銷「\(device.name)」的全部 ChatGPT 連線？",
                                   detail: "那台的授權與 token 立刻作廢、沙盒裡還在跑的全部收掉、工作區鎖住（保留不刪）。只撤銷現在看到的這些；那台沒開的話，連上主設備時才會做。",
                                   confirmTitle: "全部撤銷") { _ = build.detail(.revokeDevice(device.id), shown: shown) }
                    }
                }
            }
            .accessibilityIdentifier("tap.chatgpt.hands.otherDevices")
        }
    }

    // MARK: 沒用到的 TATWO 通道（W183 R6a：12:35 那次多建的 tatwo-hands-…）

    /// 只列：名字 tatwo-hands- 開頭、沒有連線、不是現在用的（HandsCloudflared.unusedTatwoTunnels）；沒有就寫「沒有」。
    /// 勾起來按「清掉」→ 卡片內確認 → 刪之前 HandsSetup 再查一次，只刪還符合條件而且勾了的。
    @ViewBuilder private var unusedTunnelsBlock: some View {
        if let tunnels = setup.unusedTunnels, !tunnels.isEmpty {
            let shown = build.seen
            VStack(alignment: .leading, spacing: 6) {
                Text("沒用到的 TATWO 通道（\(tunnels.count)）").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("名字 tatwo-hands- 開頭、沒有連線、不是現在用的那條、沒被這個網域的 DNS 指到。勾起來按「清掉」只刪勾的這些。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if setup.unusedTunnelsUnverified {
                    // W183 R6a 審查（Claude）：查不到 DNS＝分不出是不是另一台設備的通道（那台沒開時也沒有連線）。
                    Text("查不到這個網域的 DNS 紀錄：列出的可能是另一台設備的通道（那台沒開時也沒有連線），確定不用了再勾。")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tap.chatgpt.hands.unusedTunnelsUnverified")
                }
                ForEach(tunnels) { tunnel in
                    Toggle(isOn: Binding(get: { tunnelSelection.contains(tunnel.id) }, set: { on in
                        if on { tunnelSelection.insert(tunnel.id) } else { tunnelSelection.remove(tunnel.id) }
                        confirmingTunnelDelete = false
                    })) {
                        Text(tunnel.name + (tunnel.createdAt.map { "・建於 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                            .font(.caption.monospaced())
                    }
                    .toggleStyle(.checkbox)
                }
                if confirmingTunnelDelete {
                    ChatGPTHandsConfirmRow(question: "清掉勾的 \(tunnelSelection.count) 條通道？",
                                           detail: "只刪勾的這些（沒有連線、名字 tatwo-hands- 開頭、不是現在用的、沒被 DNS 指到）；每一條刪之前都會再查一次，不符合的不刪。可能是另一台設備沒開時的通道：刪了，那台再當主機時要重新授權建一條。Cloudflare 上刪了就沒有了。",
                                           confirmTitle: "清掉",
                                           onCancel: { confirmingTunnelDelete = false },
                                           onConfirm: {
                                               confirmingTunnelDelete = false
                                               let chosen = tunnelSelection
                                               tunnelDeleteResult = nil
                                               let refusal = build.deleteUnusedTunnels(chosen, shown: shown) { deleted, failed in
                                                   tunnelSelection = []
                                                   tunnelDeleteResult = failed == 0 ? "清掉 \(deleted) 條" : "清掉 \(deleted) 條；\(failed) 條沒刪成（稍後再試）"
                                               }
                                               if let refusal { tunnelDeleteResult = refusal }
                                           })
                } else {
                    HStack {
                        if setup.checkingTunnels { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        OSChipButton(title: "清掉", systemImage: "trash", role: .destructive) { confirmingTunnelDelete = true }
                            .disabled(tunnelSelection.isEmpty || setup.busy || setup.checkingTunnels)
                            .accessibilityIdentifier("tap.chatgpt.hands.clearTunnels")
                    }
                }
                if let tunnelDeleteResult {
                    Text(tunnelDeleteResult).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("tap.chatgpt.hands.unusedTunnels")
        } else if setup.checkingTunnels {
            ProgressView().controlSize(.small)
        } else {
            Text(tunnelDeleteResult ?? "沒有").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 診斷：錯誤、ChatGPT 的回呼網址

    @ViewBuilder private var diagnostics: some View {
        let shown = build.seen
        VStack(alignment: .leading, spacing: 6) {
            if let error = hands.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Text("ChatGPT 建外掛時如果顯示了自己的回呼網址（chatgpt.com 開頭），加在這裡；沒顯示就不用管。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hands.settings.effectiveCallbacks, id: \.self) { url in
                HStack {
                    Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    if hands.settings.chatgptCallbacks.contains(url) {
                        OSChipButton(title: "移除") { _ = build.detail(.setCallbacks(hands.settings.chatgptCallbacks.filter { $0 != url }), shown: shown) }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("https://chatgpt.com/…", text: $callbackField).textFieldStyle(.roundedBorder).font(.caption)
                OSChipButton(title: "加入") {
                    let value = callbackField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard HandsAuth.isAcceptableRedirect(value) else { return }
                    let base = hands.settings.chatgptCallbacks.isEmpty ? HandsSettings.defaultCallbacks : hands.settings.chatgptCallbacks
                    if build.detail(.setCallbacks(base + [value]), shown: shown) == nil { callbackField = "" }
                }
                .disabled(!HandsAuth.isAcceptableRedirect(callbackField.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .accessibilityIdentifier("tap.chatgpt.hands.diagnostics")
    }

    // MARK: 共用

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    /// 卡片內確認列（不跳系統框；跟副設備那塊共用 ChatGPTHandsConfirmRow）。
    private func confirmRow(question: String, detail: String, confirmTitle: String, onConfirm: @escaping () -> Void) -> some View {
        ChatGPTHandsConfirmRow(question: question, detail: detail, confirmTitle: confirmTitle,
                               onCancel: { confirming = nil },
                               onConfirm: {
                                   confirming = nil
                                   onConfirm()
                               })
    }

    /// 狀態小鈕的顏色（ChatGPT Space 頂端；跟 R6a 同一套）。
    static func color(_ tone: HandsOneSwitchStatus.Tone) -> Color {
        switch tone {
        case .idle: .secondary
        case .busy: .orange
        case .waiting: LiquidGlassTokens.brandAccent
        case .good: .green
        case .bad: .red
        }
    }

    /// 打開 ChatGPT build 的紀錄（施工房的根對話）：切到 Coder、選那條、關掉設定。還沒有就開到 Coder。
    @MainActor static func openActivity() {
        guard let model = CLISessionsTermination.model else { return }
        let root = model.localLiveForBridge?.doc.threads.first {
            $0.engine == ChatLiveEngine.handsEngine && $0.parentThreadID == nil && !$0.isArchived && $0.deviceID == nil
        }
        model.mode = .chat
        if let root { model.selectLocalThread(root.id) }
        NotificationCenter.default.post(name: .tatwoCloseSettingsPage, object: nil)
    }
}

/// 確認卡（本機與副設備共用）：callback 網域、等級、專案與記憶範圍、交易編號、配對碼。
/// 文案只說「授權這筆連線」，不宣稱驗證了是誰的 ChatGPT（接口 v2 §3、v3 V15）。
struct ChatGPTHandsPairingCard: View {
    let transaction: String
    let pairingCode: String
    let callbackHost: String
    let level: Int
    let projects: [String]
    let memory: String
    let attemptsLeft: Int
    let onMismatch: () -> Void
    var sandbox = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("授權這筆連線？").font(.system(size: 13, weight: .semibold))
            Text(sandbox ? "確認沙盒版剛建立的交易與回呼網域，再在沙盒版輸入配對碼。對不上就按「對不上，作廢」。" : "確認 ChatGPT 跳出的 TATWO 頁面上的交易編號跟這裡一樣，再在那個頁面輸入下面的配對碼。對不上就按「對不上，作廢」。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { label("交易編號"); Text(transaction).font(.system(size: 15, weight: .semibold, design: .monospaced)) }
                GridRow { label("回到"); Text(callbackHost).font(.callout) }
                if sandbox {
                    GridRow { label("權限"); Text("只能領工、交件、回報心跳").font(.callout) }
                } else {
                    GridRow { label("等級"); Text(HandsState.levelLabel(level)).font(.callout) }
                    GridRow { label("專案"); Text(projects.isEmpty ? "（沒有勾任何專案）" : projects.joined(separator: "、")).font(.callout) }
                    GridRow { label("記憶"); Text(memory).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text(pairingCode)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("tap.chatgpt.hands.pairingCode")
                Text("還能試 \(attemptsLeft) 次").font(.caption).foregroundStyle(.secondary)
                Spacer()
                OSChipButton(title: "對不上，作廢", role: .destructive, action: onMismatch)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatLiquidSection(cornerRadius: 12, accentOpacity: 0.12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.hands.pairingCard")
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// W183 R3b 審查：授權後的那一列（主機、副設備、環境登入共用）。
/// - 還沒確認：「請確認：Cloudflare 帳號〈名稱〉、網域〈網域〉是你要的嗎？」＋「是這個，繼續」（網域名稱還不知道＝「再查一次網域名稱」）
///   ＋「取消並重新授權」。確認前主機不建通道、不改 DNS、不啟動。
/// - 已確認：「已授權：…」＋「取消並重新授權」（還沒配對才有）。上次取消沒清完：「再清一次」。
struct HandsAuthorizationRow: View {
    let summary: HandsAuthorizationSummary
    let canReauthorize: Bool
    let busy: Bool
    let problem: String?
    var remote = false
    /// 帶畫面上看到的網域（空字串＝網域名稱還不知道，請主機再查一次）。
    let onConfirm: (String) -> Void
    let onReauthorize: () -> Void
    @State private var confirmingReauthorize = false

    private var text: String {
        if summary.cleanupPending { return "上次取消授權沒清完：Cloudflare 帳號〈\(summary.account)〉、網域〈\(summary.domain ?? "（不明）")〉" }
        if summary.needsConfirm { return HandsSetup.confirmText(account: summary.account, domain: summary.domain) }
        return HandsSetup.authorizedText(account: summary.account, domain: summary.domain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: summary.needsConfirm || summary.cleanupPending ? "questionmark.circle" : "checkmark.seal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(summary.needsConfirm || summary.cleanupPending ? Color.orange : Color.green).frame(width: 14)
                Text(text)
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(remote ? "tap.chatgpt.hands.remoteAuthorized" : "tap.chatgpt.hands.authorized")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if summary.cleanupPending {
                    OSChipButton(title: "再清一次（取消並重新授權）", systemImage: "arrow.clockwise") { onReauthorize() }
                        .disabled(busy)
                        .accessibilityIdentifier(remote ? "tap.chatgpt.hands.remoteCleanup" : "tap.chatgpt.hands.cleanup")
                } else {
                    if summary.needsConfirm {
                        if let domain = summary.domain {
                            OSChipButton(title: "是這個，繼續", systemImage: "checkmark", isPrimary: true) { onConfirm(domain) }
                                .disabled(busy || summary.confirmToken == nil)
                                .accessibilityIdentifier(remote ? "tap.chatgpt.hands.remoteConfirm" : "tap.chatgpt.hands.confirmAuthorization")
                        } else {
                            OSChipButton(title: "再查一次網域名稱", systemImage: "magnifyingglass") { onConfirm("") }
                                .disabled(busy || summary.confirmToken == nil)
                        }
                    }
                    if canReauthorize || summary.needsConfirm {
                        OSChipButton(title: "取消並重新授權", systemImage: "arrow.uturn.backward") { confirmingReauthorize = true }
                            .disabled(busy || confirmingReauthorize)
                            .accessibilityIdentifier(remote ? "tap.chatgpt.hands.remoteReauthorize" : "tap.chatgpt.hands.reauthorize")
                    }
                }
            }
            if confirmingReauthorize {
                ChatGPTHandsConfirmRow(question: "取消這個授權、重新登入 Cloudflare？",
                                       detail: remote ? "會請主機先停下 ChatGPT build、清掉剛才這次登入拿到的 Cloudflare 授權（主機的鑰匙圈），再開一次授權頁；授權頁一樣可以在這台按。Cloudflare 上已經建的通道與 DNS 紀錄不會被刪（要刪請到 Cloudflare 後台）。"
                                                      : ChatGPTBuildDetails.reauthorizeDetail,
                                       confirmTitle: "重新授權",
                                       onCancel: { confirmingReauthorize = false },
                                       onConfirm: {
                                           confirmingReauthorize = false
                                           onReauthorize()
                                       })
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.hands.authorizationRow")
    }
}

/// 設定步驟的一列（主機與副設備共用；W183 R3b）：圖示、「N. 標題」、中文狀態（等待中／進行中／等你按／完成／失敗）、訊息、失敗時「重試」（授權那一步「重新授權」；W183 R7a）。
struct ChatGPTHandsStepRow: View {
    let number: Int
    let title: String
    /// nil＝副設備收到不認得的狀態代碼（字寫「未知」）。
    let status: HandsSetupStatus?
    let statusLabel: String
    let message: String
    let rerun: (() -> Void)?
    /// W183 R7a：失敗時那顆鈕的名字跟步驟訊息、那一列的鈕一致（授權那一步＝「重新授權」，其他＝「重試」）。
    var rerunTitle = HandsOneSwitchStatus.Action.retry.title

    static func rerunLabel(for step: HandsSetupStep) -> String {
        (step == .authorize ? HandsOneSwitchStatus.Action.reauthorize : .retry).title
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.icon(status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.color(status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(number). \(title)").font(.system(size: 12, weight: .medium))
                    Text(statusLabel).font(.caption2.weight(.semibold)).foregroundStyle(Self.color(status))
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(status == .failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let rerun {
                OSChipButton(title: rerunTitle, action: rerun)
            }
        }
    }

    static func icon(_ status: HandsSetupStatus?) -> String {
        switch status {
        case .pending?: "circle"
        case .running?: "arrow.triangle.2.circlepath"
        case .waitingUser?: "hand.point.up.left"
        case .done?: "checkmark.circle.fill"
        case .failed?: "exclamationmark.triangle.fill"
        case nil: "questionmark.circle"
        }
    }

    static func color(_ status: HandsSetupStatus?) -> Color {
        switch status {
        case .pending?, nil: .secondary
        case .running?: .orange
        case .waitingUser?: LiquidGlassTokens.brandAccent
        case .done?: .green
        case .failed?: .red
        }
    }
}

/// 卡片內確認列（不跳系統框；主機與副設備共用）。
struct ChatGPTHandsConfirmRow: View {
    let question: String
    let detail: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OSChipButton(title: "取消", action: onCancel)
                OSChipButton(title: confirmTitle, role: .destructive, action: onConfirm)
                    .accessibilityIdentifier("tap.chatgpt.hands.confirm")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatLiquidSection(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.hands.confirmRow")
    }
}

/// 小藥丸狀態（圓點＋短字）。
struct ChatGPTHandsStatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .chatGlassChip()
        .help(text)
        .accessibilityLabel(text)
        .accessibilityIdentifier("tap.chatgpt.hands.statusPill")
    }
}

/// W199：ChatGPT Space 頂端保留設定圖示；只有需要動手才有提示點，help 與 AX 不報健康狀態。
struct ChatGPTHandsStatusButton: View {
    @ObservedObject private var entry = HandsConnectEntry.shared
    @ObservedObject private var build = HandsBuildController.shared
    @ObservedObject private var hands = HandsState.shared
    @ObservedObject private var remote = HandsRemoteClient.shared
    let open: () -> Void

    /// 副設備：主機是主設備、而且開著，才顯示主設備的狀態。
    private var remoteStatus: HandsRemoteStatus? {
        guard !hands.settings.enabled, let status = remote.status, status.primaryIsHost else { return nil }
        return status
    }

    private var visible: Bool {
        if build.config != nil { return build.enabled || hands.settings.enabled }
        return hands.settings.enabled || remoteStatus?.enabled == true
    }

    /// ChatGPT Space 頂端列掛這個（ChatGPTTopBarControls 的 .task，一定存在的那一列）：副設備每 30 秒問一次主設備；
    /// 去重與連不上的退避在 HandsRemoteClient。這台自己開著手腳就不問。Space 看不到＝task 被取消。
    @MainActor static func pollRemoteStatus() async {
        let remote = HandsRemoteClient.shared
        guard remote.isSecondary else { return }
        while !Task.isCancelled {
            if !HandsState.shared.settings.enabled { remote.fetch() }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    var body: some View {
        // 輪詢不掛在這裡（小鈕沒出現時 Group 是空的、task 不會跑）：掛在 ChatGPTTopBarControls 那一列（pollRemoteStatus）。
        Group { if visible { button } }
    }

    private var button: some View {
            Button(action: open) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                    if entry.noticeText != nil {
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -4, y: 5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("設定 › Plugin › TAP › ChatGPT build")
            .accessibilityLabel("ChatGPT build 設定")
            .accessibilityIdentifier("chatgpt.hands.status")
    }
}
