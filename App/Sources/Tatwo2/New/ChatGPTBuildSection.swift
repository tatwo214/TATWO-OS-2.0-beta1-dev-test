// W183 R8a：設定 › Plugin › TAP › ChatGPT 卡片裡的「ChatGPT build」（照 09-28 對照稿；規格 docs/specs/183-chatgpt-hands/chatgpt-build.md）。
// 使用者 09-28：「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」「整個流程不要弄得非常多文字 我還寧願你做得像n8n那種icon流程可視化，
// 也不要對一個沒有說明書的開發者塞一堆文字說明」「可以 多設備就這樣 照對照稿開工」。
// - 一列：「ChatGPT build」＋ⓘ（說明只在這裡）＋狀態 pill＋開關；下面節點流程（New/ChatGPTBuildFlow.swift），再下面一次一個節點面板。
// - 面板：GPT（Pod 帳號、開發者模式）；設備（每台一張勾選卡）；Cloudflare（沒帳號＝登入一顆；有＝帳號＋網域＋子網域＋套用）；
//   ChatGPT Dev（連上後能做的那一行、專案、［連線］；W183 R12 拿掉 L0／L1／L2 那一排）。工程細節（步驟、帳號與網域、已連線與撤銷、沒用到的通道、換主機、診斷）收進右上「…」。
// - 畫面只讀 HandsBuildModel（接口 HandsBuildModeling＋幾個接口外的確認列）、只叫它的動作（按鈕一律經 HandsBuildUIIntent）。
// W183 R8 整合（接到 R8c 的多設備後端）：設備可以多選（取消勾有連線、在跑的那台先在卡片內確認）；Cloudflare 每台一個子網域欄位、
// 每台自己的授權（沒有的那台一顆「替它登入」：授權頁開在這台私訊框的 Browser、授權存那台）；「套用」帶看到的那一版與每台的草稿；
// ［連線］逐台排（多台時每台還有一顆）；那台安全停機＝設備面板一顆「解除安全鎖」（使用者對那台按）。換主機確認、交回主設備拿掉。
// - 按鈕一律玻璃 chip 或對照稿的圓角塊；確認用卡片內確認列（不跳系統框）；開關用品牌色。字都放在 HandsBuildCopy（自測檢查都短）。
import SwiftUI

struct ChatGPTBuildSection: View {
    @ObservedObject private var model = HandsBuildModel.shared
    var showsFlow = false
    #if DEBUG
    var testFrame: HandsBuildModel.Frame? = nil
    #endif
    /// Pod 的啟用動作。登入統一在 TAP 卡頭。
    var onEnableChatGPT: () -> Void = {}
    /// 使用者點過的節點（nil＝跟著「要你處理的」那一個）。
    @State private var chosen: HandsBuildPanel?
    /// 右上「…」打開的工程細節（nil＝節點面板）。
    @State private var more: HandsBuildMore?
    @State private var confirmingOff = false
    /// W183 R8 整合：每台的子網域草稿（設備 id → 還沒存的字）。
    @State private var subdomainDrafts: [String: String] = [:]
    /// W183 R8 整合：取消勾一台還在跑、有連線的設備＝卡片內確認列。
    @State private var confirmingDeselect: String?
    /// W183 R8a 審查（GPT-6）：這張卡在畫面上＝Computer Use 不准以 TATWO 為目標（HandsBuildScreenGate）。
    @State private var screenToken = UUID()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        #if DEBUG
        let frame = testFrame ?? model.frame
        #else
        let frame = model.frame
        #endif
        let panel = HandsBuildPanel.resolve(chosen: chosen, attention: frame.snapshot.attention)
        VStack(alignment: .leading, spacing: 14) {
            buildRow(frame)
            if confirmingOff { offConfirm(frame.input) }
            if showsFlow {
            ChatGPTBuildFlow(graph: frame.graph, selected: more == nil ? panel : nil, dimmed: !frame.input.enabled) { picked in
                chosen = picked
                self.more = nil
                confirmingDeselect = nil
                model.clearNotice()
            }
            }
            panelBox(panel, frame, more: more)
        }
        // 畫面開著：對這台的現況、後端一陣子內同步快一點（HandsBuildController.viewDidAppear）。
         .task {
            #if DEBUG
            if testFrame != nil { return }
            #endif
            await model.watch()
        }
        // 要你處理的節點換了：面板跟過去（使用者點過的也放掉）。
        .onChange(of: frame.snapshot.attention) { _, _ in chosen = nil }
        // W183 R8a 審查（GPT-6）：主設備（主權）一變＝不適用的面板、草稿、待確認的操作全部收掉。
        .onChange(of: frame.input.roleKey) { _, _ in resetForRoleChange() }
        // W183 R8 整合審查（Claude 中「子網域存不成＝停下、草稿留著」）：存檔是背景 CAS——送出當下不清草稿；等設定回來、那台的子網域
        // 已經是草稿那個字才清（存不成、版本衝突＝草稿留著，使用者打的字不會不見）。
        .onChange(of: frame.input.configRevision) { _, _ in pruneSavedDrafts(model.snapshot.devices) }
        .onAppear { HandsBuildScreenGate.appeared(screenToken) }
        .onDisappear { HandsBuildScreenGate.disappeared(screenToken) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.build")
    }

    private func resetForRoleChange() {
        more = nil
        chosen = nil
        subdomainDrafts = [:]
        confirmingOff = false
        confirmingDeselect = nil
        model.resetForRoleChange()
    }

    // MARK: 那一列：ChatGPT build ⓘ｜狀態｜開關

    private func buildRow(_ frame: HandsBuildModel.Frame) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ChatGPTBuildPalette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(HandsBuildCopy.title).font(.system(size: 16, weight: .semibold))
            OSInfoButton(title: HandsBuildCopy.infoTitle, paragraphs: [HandsBuildCopy.infoParagraph], accessibilityID: "tap.chatgpt.build.info")
            ChatGPTHandsStatusPill(text: frame.snapshot.statusText, color: ChatGPTBuildPalette.color(frame.snapshot.statusState))
                .help(frame.snapshot.statusText)
            Spacer(minLength: 8)
            Toggle(HandsBuildCopy.title, isOn: Binding(get: { model.enabled }, set: { on in
                if on {
                    confirmingOff = false
                    HandsBuildUIIntent.toggle(true).send(to: model)
                } else {
                    confirmingOff = true   // 關掉先在卡片內確認
                }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(LiquidGlassTokens.brandAccent)
            .disabled(!model.canToggle || confirmingOff)
            .accessibilityIdentifier("tap.chatgpt.build.enabled")
        }
    }

    private func offConfirm(_ input: HandsBuildInput) -> some View {
        let copy = ChatGPTBuildDetails.offConfirmCopy(devices: input.selected.count)
        return ChatGPTHandsConfirmRow(question: copy.question, detail: copy.detail, confirmTitle: copy.confirm,
                                      onCancel: { confirmingOff = false },
                                      onConfirm: {
                                          confirmingOff = false
                                          HandsBuildUIIntent.toggle(false).send(to: model)
                                      })
    }

    // MARK: 節點面板（一次一個）

    private func panelBox(_ panel: HandsBuildPanel, _ frame: HandsBuildModel.Frame, more: HandsBuildMore?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let more {
                    Button { self.more = nil; model.clearNotice() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(HandsBuildCopy.back)
                    .accessibilityLabel(HandsBuildCopy.back)
                    .accessibilityIdentifier("tap.chatgpt.build.back")
                    Text(more.title).font(.system(size: 14, weight: .semibold))
                } else {
                    Text(panel.title).font(.system(size: 14, weight: .semibold))
                }
                Spacer(minLength: 0)
                moreMenu
            }
            if let more {
                ChatGPTBuildDetails(kind: more)
            } else {
                if frame.snapshot.problemPanel == panel, let problem = frame.snapshot.problem {
                    problemLine(problem, fix: frame.snapshot.fix)
                }
                switch panel {
                case .gpt: gptPanel(frame)
                case .devices: devicesPanel(frame)
                case .cloudflare: cloudflarePanel(frame)
                case .dev: devPanel(frame)
                }
            }
            if let notice = model.notice ?? frame.snapshot.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(ChatGPTBuildPalette.waiting)
                    .accessibilityIdentifier("tap.chatgpt.build.notice")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(ChatGPTBuildPalette.canvas(scheme), in: shape)
        .overlay(shape.strokeBorder(ChatGPTBuildPalette.border(scheme), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tap.chatgpt.build.panel.\(more.map { "more." + $0.rawValue } ?? panel.rawValue)")
    }

    /// 出錯：一句話＋那一顆鈕（重試／重新登入／解除安全鎖／再連一次），只在出錯的那個節點的面板。
    private func problemLine(_ problem: String, fix: HandsBuildFix?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(problem)
                .font(.caption)
                .foregroundStyle(ChatGPTBuildPalette.failed)
                .lineLimit(2)
                .textSelection(.enabled)
                .accessibilityIdentifier("tap.chatgpt.build.problem")
            Spacer(minLength: 0)
            if let fix {
                OSChipButton(title: fix.title, systemImage: "arrow.clockwise", isPrimary: true) { model.fix() }
                    .accessibilityIdentifier("tap.chatgpt.build.fix")
            }
        }
    }

    /// 右上「…」：這台的工程細節（不佔版面，按了才打開；每台都是自己的主機）。
    private var moreMenu: some View {
        Menu {
            ForEach(HandsBuildMore.items, id: \.self) { item in
                Button(item.title) { more = item; model.clearNotice() }
            }
            Button(HandsBuildCopy.activity) { ChatGPTBuildDetails.openActivity() }
            Divider()
            Button(HandsBuildCopy.envLogin) { EnvironmentLoginTab.open(.cloudflare) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(HandsBuildCopy.more)
        .accessibilityLabel(HandsBuildCopy.more)
        .accessibilityIdentifier("tap.chatgpt.build.more")
    }

    // MARK: GPT

    private func gptPanel(_ frame: HandsBuildModel.Frame) -> some View {
        let input = frame.input
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(ChatGPTBuildPalette.color(frame.snapshot.gpt)).frame(width: 8, height: 8)
                Text(gptLine(input))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("tap.chatgpt.build.pod")
            }
            if case .disabled = input.pod {
                OSChipButton(title: HandsBuildCopy.enableChatGPT, systemImage: "power", isPrimary: true) { onEnableChatGPT() }
                    .accessibilityIdentifier("tap.chatgpt.build.enableChatGPT")
            }
        }
    }

    /// W183 R8a 審查（GPT-6）：寫明是「Pod」目前的帳號（觀測值），不是既有連線（grant）的帳號身分。
    private func gptLine(_ input: HandsBuildInput) -> String {
        let who: String
        switch input.pod {
        case .ready: who = input.podAccount.map { HandsBuildCopy.pod + "：" + $0 } ?? HandsBuildCopy.pod
        case .sleeping: who = input.podAccount.map { HandsBuildCopy.pod + "：" + $0 } ?? HandsBuildCopy.podAsleep
        case .starting: who = HandsBuildCopy.podStarting
        case .needsLogin: who = HandsBuildCopy.notLoggedIn
        case .disabled: who = HandsBuildCopy.off
        case .failed(let message): who = HandsOneSwitchStatus.short(message)
        }
        return who + "・" + model.devModeText
    }

    // MARK: 設備（多選）

    private func devicesPanel(_ frame: HandsBuildModel.Frame) -> some View {
        let input = frame.input
        let locked = frame.snapshot.devices.filter { input.safetyLocked.contains($0.id.lowercased()) }
        return VStack(alignment: .leading, spacing: 12) {
            ChatGPTBuildWrap(spacing: 10) {
                ForEach(frame.snapshot.devices) { device in deviceCard(device, input) }
            }
            // 取消勾一台還在跑、有連線的＝先在卡片內確認（那台的連線作廢、關口停下；別台不受影響）。
            if let id = confirmingDeselect, let device = frame.snapshot.devices.first(where: { $0.id == id }) { deselectRow(device) }
            // 那台安全停機：使用者對那台明確解除（重新勾選、重開、同步都不會解除）。
            ForEach(locked) { device in
                HStack(spacing: 8) {
                    Text(device.name).font(.caption).foregroundStyle(ChatGPTBuildPalette.failed).lineLimit(1)
                    Spacer(minLength: 0)
                    OSChipButton(title: HandsBuildCopy.unlock, systemImage: "lock.open") {
                        HandsBuildUIIntent.unlockSafety(device.id).send(to: model)
                    }
                    .accessibilityIdentifier("tap.chatgpt.build.unlock")
                }
            }
        }
    }

    private func deviceCard(_ device: HandsBuildDevice, _ input: HandsBuildInput) -> some View {
        let accent = ChatGPTBuildPalette.accent
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let box = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let role = (device.isPrimary ? HandsBuildCopy.primaryRole : HandsBuildCopy.secondaryRole)
            + (device.isThisDevice ? "・" + HandsBuildCopy.thisDevice : "")
        let id = device.id.lowercased()
        // 還在跑、有連線（含確認中的）：取消勾要先確認。
        let live = device.state != .off || (input.anyGrants[id] ?? 0) > 0
        return Button {
            if device.selected, live {
                confirmingDeselect = device.id
            } else {
                confirmingDeselect = nil
                HandsBuildUIIntent.pickDevice(device.id, !device.selected).send(to: model)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    box.fill(device.selected ? accent : ChatGPTBuildPalette.nodeFill(scheme))
                    box.strokeBorder(device.selected ? accent : ChatGPTBuildPalette.fieldBorder(scheme), lineWidth: 1.5)
                    if device.selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(role).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Circle().fill(ChatGPTBuildPalette.color(device.state)).frame(width: 7, height: 7)
                    .help(HandsBuildCopy.word(device.state))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(device.selected ? accent.opacity(0.08) : ChatGPTBuildPalette.nodeFill(scheme), in: shape)
            .overlay(shape.strokeBorder(device.selected ? accent : ChatGPTBuildPalette.nodeBorder(scheme), lineWidth: device.selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!input.configKnown)
        .accessibilityLabel("\(device.name)（\(role)）")
        .accessibilityValue((device.selected ? "已勾選" : "未勾選") + "・" + HandsBuildCopy.word(device.state))
        .accessibilityIdentifier("tap.chatgpt.build.device.\(id)")
    }

    private func deselectRow(_ device: HandsBuildDevice) -> some View {
        let copy = ChatGPTBuildDetails.deselectCopy(name: device.name)
        return ChatGPTHandsConfirmRow(question: copy.question, detail: copy.detail, confirmTitle: copy.confirm,
                                      onCancel: { confirmingDeselect = nil },
                                      onConfirm: {
                                          confirmingDeselect = nil
                                          HandsBuildUIIntent.pickDevice(device.id, false).send(to: model)
                                      })
    }

    // MARK: Cloudflare（每台一個子網域、每台自己的授權）

    private func cloudflarePanel(_ frame: HandsBuildModel.Frame) -> some View {
        let input = frame.input
        let hosts = frame.snapshot.devices.filter(\.selected)
        let state = frame.snapshot.cloudflare
        // 按鈕帶著畫出來那一刻看到的（設定版本、網域、勾選、世代）；送出前比對（W183 R8a 審查）。
        let seen = HandsBuildSeen.of(input)
        let drafts = currentDrafts(hosts)
        return VStack(alignment: .leading, spacing: 12) {
            if !input.hasCloudflareAccount || input.loginOpenHere != nil {
                // 沒有任何帳號：這台先登入（跟環境登入同一份）；勾了別台＝也可以替那台登入（授權存那台）。
                ChatGPTBuildWrap(spacing: 10) {
                    loginChip
                    ForEach(hosts.filter { !$0.isThisDevice }) { device in loginForChip(device, input) }
                    if input.loginOpenHere != nil { ProgressView().controlSize(.small) }
                }
            }
            if input.hasCloudflareAccount {
                HStack(spacing: 8) {
                    Circle().fill(state == .done ? ChatGPTBuildPalette.done : ChatGPTBuildPalette.waiting).frame(width: 8, height: 8)
                    Text(accountName(input))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("tap.chatgpt.build.cloudflareAccount")
                    zoneMenu(input)
                }
                // W183 R8a 審查（Claude）：已經有網址之後換網域＝卡片內確認列（現有網址與連線會失效），不一鍵換。
                if let zone = model.pendingZone { zoneChangeRow(zone, input) }
                ForEach(hosts) { device in
                    subdomainRow(device, input, labeled: frame.snapshot.devices.count > 1)
                }
                if !hosts.isEmpty {
                    HStack(spacing: 10) {
                        if state != .done || !drafts.isEmpty {
                            OSChipButton(title: HandsBuildCopy.apply, systemImage: "checkmark", isPrimary: true) { apply(hosts, seen: seen) }
                                .disabled(!input.enabled || input.selectedZoneID == nil || !input.applyBusy.isEmpty)
                                .accessibilityIdentifier("tap.chatgpt.build.apply")
                        }
                        // 已建好也能只重套本機，修復時不用再碰多設備入口。
                        OSChipButton(title: "只套用這台", systemImage: "laptopcomputer") {
                            HandsBuildUIIntent.applyHere(seen: seen, drafts: currentDrafts(hosts)).send(to: model)
                        }
                        .disabled(!input.enabled || input.selectedZoneID == nil || input.busyHere || !input.applyBusy.isEmpty
                                  || !hosts.contains { HandsHostAuthority.same($0.id, input.localDeviceID) })
                        .accessibilityIdentifier("tap.chatgpt.build.applyHere")
                        if !input.applyBusy.isEmpty { ProgressView().controlSize(.small) }
                    }
                }
            }
        }
    }

    private func accountName(_ input: HandsBuildInput) -> String {
        (input.zones.first { $0.id == input.selectedZoneID } ?? input.zones.first)?.accountName ?? ""
    }

    private func zoneChangeRow(_ zone: String, _ input: HandsBuildInput) -> some View {
        let seen = HandsBuildSeen.of(input)
        let name = input.zones.first { $0.id == zone }?.name ?? HandsBuildCopy.domainUnknown
        let copy = ChatGPTBuildDetails.zoneChangeCopy(domain: name, connected: input.totalGrants > 0)
        return ChatGPTHandsConfirmRow(question: copy.question, detail: copy.detail, confirmTitle: copy.confirm,
                                      onCancel: { model.dismissZoneChange() },
                                      onConfirm: { model.confirmZoneChange(seen: seen) })
    }

    private var loginChip: some View {
        Button { HandsBuildUIIntent.loginCloudflare.send(to: model) } label: {
            HStack(spacing: 8) {
                Image(systemName: "cloud").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatGPTBuildPalette.cloud)
                Text(HandsBuildCopy.loginCloudflare).font(.system(size: 13)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .chatGlassChip()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tap.chatgpt.build.loginCloudflare")
    }

    /// 替那台登入（人在這台；那台跑自己的 cloudflared、授權存那台；授權頁開在這台私訊框的 Browser）。那台在等＝轉圈。
    @ViewBuilder private func loginForChip(_ device: HandsBuildDevice, _ input: HandsBuildInput) -> some View {
        if input.loginBusy.contains(device.id.lowercased()) {
            ProgressView().controlSize(.small).help(device.name)
        } else {
            OSChipButton(title: device.isThisDevice ? HandsBuildCopy.loginCloudflare : HandsBuildCopy.loginFor(device.name), systemImage: "cloud") {
                HandsBuildUIIntent.loginCloudflareFor(device.id).send(to: model)
            }
            .disabled(!input.configKnown)
            .accessibilityIdentifier("tap.chatgpt.build.loginFor.\(device.id.lowercased())")
        }
    }

    /// 網域（每台回報的帳號裡的；R8c：不自動選）：玻璃 chip 選單，不用系統的彈出按鈕。
    private func zoneMenu(_ input: HandsBuildInput) -> some View {
        let multipleAccounts = Set(input.zones.map(\.accountName)).count > 1
        let label: (HandsBuildZone) -> String = { zone in
            (zone.name.isEmpty ? HandsBuildCopy.domainUnknown : zone.name) + (multipleAccounts ? "（\(zone.accountName)）" : "")
        }
        let current = input.zones.first { $0.id == input.selectedZoneID }
        return Menu {
            ForEach(input.zones) { zone in
                Button(label(zone)) { HandsBuildUIIntent.chooseZone(zone.id).send(to: model) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map(label) ?? HandsBuildCopy.pickDomain).font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .chatGlassChip()
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!input.configKnown || model.pendingZone != nil)
        .accessibilityIdentifier("tap.chatgpt.build.zone")
    }

    /// 每台一列：`<子網域>` ＋ `.<網域>`（對照稿的兩段式欄位）＋那台的授權與網址狀態（沒授權＝替它登入；網址好了＝綠勾）。
    private func subdomainRow(_ device: HandsBuildDevice, _ input: HandsBuildInput, labeled: Bool) -> some View {
        let left = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
        let right = UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous)
        let id = device.id.lowercased()
        return HStack(spacing: 8) {
            if labeled {
                Text(device.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
            }
            HStack(spacing: 0) {
                Group {
                    if input.configKnown {
                        TextField(HandsSettings.defaultSubdomainLabel, text: Binding(get: { subdomainDrafts[device.id] ?? device.subdomain },
                                                                                     set: { subdomainDrafts[device.id] = $0 }))
                            .textFieldStyle(.plain)
                            .onSubmit { commitSubdomain(device) }
                            .frame(width: 150)
                    } else {
                        Text(device.subdomain).textSelection(.enabled)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ChatGPTBuildPalette.nodeFill(scheme), in: left)
                .overlay(left.strokeBorder(ChatGPTBuildPalette.fieldBorder(scheme), lineWidth: 1))
                .accessibilityIdentifier("tap.chatgpt.build.subdomain")
                Text("." + (input.domain ?? HandsBuildCopy.domainUnknown))
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(ChatGPTBuildPalette.suffixFill(scheme), in: right)
                    .overlay(right.strokeBorder(ChatGPTBuildPalette.fieldBorder(scheme), lineWidth: 1))
                    .offset(x: -1)
                    .accessibilityIdentifier("tap.chatgpt.build.domain")
            }
            if input.selectedZoneID != nil, !input.authorized.contains(id) {
                loginForChip(device, input)
            } else if input.urlReady.contains(id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(ChatGPTBuildPalette.done)
                    .help(HandsBuildCopy.word(.done))
            } else if input.applyBusy.contains(id) {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// 還沒存的子網域草稿（跟現在的不一樣的才算）。
    private func currentDrafts(_ hosts: [HandsBuildDevice]) -> [HandsBuildDraft] {
        hosts.compactMap { device in
            guard let label = subdomainDrafts[device.id], label != device.subdomain else { return nil }
            return HandsBuildDraft(label: label, device: device.id)
        }
    }

    private func commitSubdomain(_ device: HandsBuildDevice) {
        guard let draft = subdomainDrafts[device.id], draft != device.subdomain else { subdomainDrafts[device.id] = nil; return }
        HandsBuildUIIntent.subdomain(draft, device: device.id).send(to: model)
        // W183 R8 整合審查（Claude 中）：不在送出當下清（存檔在背景）；存好之後 pruneSavedDrafts 清。
    }

    /// 設定回來了：那台的子網域已經是草稿那個字（照同一套規則正規化）＝存好了，草稿清掉；其他的（存不成、還沒回來）留著。
    private func pruneSavedDrafts(_ devices: [HandsBuildDevice]) {
        for (id, draft) in subdomainDrafts {
            guard let device = devices.first(where: { $0.id == id }) else { continue }
            if draft == device.subdomain || HandsSettings.validLabel(draft) == device.subdomain { subdomainDrafts[id] = nil }
        }
    }

    /// 「套用」：改了子網域先存（不合格或沒存成就停在這裡、草稿留著），再請勾選的每台照選好的網域與子網域建通道與 DNS。
    /// W183 R8a 審查（GPT-6）：整串交給 adapter（HandsBuildModel.plan(.applyURLs(seen:drafts:))）——看到的變了不送、任何一步沒成功就停。
    private func apply(_ hosts: [HandsBuildDevice], seen: HandsBuildSeen) {
        HandsBuildUIIntent.apply(seen: seen, drafts: currentDrafts(hosts)).send(to: model)
        // W183 R8 整合審查（Claude 中）：草稿不在這裡清——存檔是背景 CAS，存不成（版本衝突、主設備沒存成）草稿要留著；存好之後 pruneSavedDrafts 清。
    }

    // MARK: ChatGPT Dev

    private func devPanel(_ frame: HandsBuildModel.Frame) -> some View {
        let input = frame.input
        let hosts = frame.snapshot.devices.filter(\.selected)
        return VStack(alignment: .leading, spacing: 12) {
            // W183 R12（使用者 09-30：「這個環節我非常不理解」「他連上就是全部都能看 唯讀記憶是有他專屬的區塊」；裁決：拿掉等級選擇）：
            // L0／L1／L2 那一排拿掉，換成一行白話（連上＝全開；跟確認卡同一句）。
            Text(HandsBuildCopy.capabilities)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tap.chatgpt.build.capabilities")
            HStack(spacing: 10) {
                connectButton(frame)
                // 多台：每台自己一顆（同一個 Pod 一次一個連接器；大的那顆＝逐台排）。
                if hosts.count > 1 {
                    ForEach(hosts.filter { $0.connection != .done }) { device in
                        OSChipButton(title: HandsBuildCopy.connectOne(device.name), systemImage: "link") {
                            HandsBuildUIIntent.connect(device.id).send(to: model)
                        }
                        .disabled(!input.enabled || frame.snapshot.dev == .working)
                        .accessibilityIdentifier("tap.chatgpt.build.connect.\(device.id.lowercased())")
                    }
                }
            }
        }
    }

    /// ［連線］＝私訊框的原生［連線］卡（一次性連線意圖只在那張卡按下才建立；W183 R10：那一下就算同意，勾選與 8 碼由 TATWO 代做）；
    /// 多台＝逐台排。已連線＝白底品牌色字，不能再按。
    private func connectButton(_ frame: HandsBuildModel.Frame) -> some View {
        let input = frame.input
        let dev = frame.snapshot.dev
        let connected = dev == .done
        let usable = input.enabled && (dev == .waiting || dev == .failed)
        let filled = usable && !connected
        let accent = ChatGPTBuildPalette.accent
        return Button { HandsBuildUIIntent.connect(nil).send(to: model) } label: {
            HStack(spacing: 6) {
                if dev == .working { ProgressView().controlSize(.mini) }
                Text(connected ? HandsBuildCopy.connectedShort : HandsBuildCopy.connect)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(filled ? accent : ChatGPTBuildPalette.nodeFill(scheme), in: Capsule())
            .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable || connected ? 1 : 0.55)
        .accessibilityIdentifier("tap.chatgpt.build.connect")
    }
}

/// 一列放不下就換行（設備卡、專案 chip）。
struct ChatGPTBuildWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let widths: [CGFloat] = rows.map { row in
            let content: CGFloat = row.map(\.width).reduce(CGFloat.zero, +)
            let gaps = spacing * CGFloat(max(row.count - 1, 0))
            return content + gaps
        }
        let heights: [CGFloat] = rows.map { $0.map(\.height).max() ?? CGFloat.zero }
        let width: CGFloat = widths.max() ?? 0
        let height = heights.reduce(CGFloat.zero, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].isEmpty ? size.width : used + spacing + size.width
            if !rows[rows.count - 1].isEmpty, needed > width {
                rows.append([size])
                used = size.width
            } else {
                rows[rows.count - 1].append(size)
                used = needed
            }
        }
        return rows.filter { !$0.isEmpty }
    }
}
