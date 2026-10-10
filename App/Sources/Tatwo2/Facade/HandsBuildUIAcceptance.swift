#if DEBUG
import CoreGraphics
import Foundation

/// W183 R8a（ChatGPT build 的畫面；docs/specs/183-chatgpt-hands/chatgpt-build.md）的自測，掛在 `TATWO2_SELFTEST=w183ui` 底下（HandsUIAcceptance.run 叫）。
/// W183 R8 整合：畫面接到 R8c 的多設備後端（HandsBuildController）之後，舊的單主機形狀改成多設備形狀——每一條原本守的東西寫在旁邊。
/// 全是純判斷（不碰鑰匙圈、網路、真的設定流程；不用任何 .shared）：
/// - 節點標記對應：Pod、設備、Cloudflare、ChatGPT Dev 在各種狀態下的完成／等你／進行中／沒選／出錯，與那一行短字、出錯鈕；
/// - 面板切換：點的＞要你處理的＞ChatGPT Dev；要你處理的節點會跟著流程往下走；
/// - 單設備只畫「主」、多設備每台一個節點、連線條數與實線／虛線；節點位置不重疊、不超出；
/// - 按鈕叫對 model 動作（HandsBuildUIIntent → HandsBuildModeling，用記錄的假 model）；adapter 把每個動作對到多設備後端（HandsBuildModel.plan）；
/// - 主卡片上沒有長段說明文字（HandsBuildCopy 每一句都短；說明只在 ⓘ 那一句）。
/// 以上是純邏輯（判斷與「算出要做的事」）；W183 R8a 審查另補操作級的反例（buildReviewChecks）；後端那一半（CAS、存不成就停、授權頁開在
/// Browser 分頁、確認過的連線才算）在 w183build 的整合檢查（HandsBuildIntegrationAcceptance.swift）用真的控制器與信箱驗。
extension HandsUIAcceptance {
    /// 記錄叫了什麼的假 model（驗「按鈕叫對 model 動作」）。
    @MainActor final class RecordingBuildModel: HandsBuildModeling, HandsBuildSeenApplying {
        var calls: [String] = []
        var enabled = false
        var statusText = HandsBuildCopy.off
        var statusState: HandsBuildNodeState = .off
        var problem: String?
        var gptState: HandsBuildNodeState = .off
        var podAccount: String?
        var devices: [HandsBuildDevice] = []
        var cloudflareState: HandsBuildNodeState = .off
        var zones: [HandsBuildZone] = []
        var selectedZoneID: String?
        var devState: HandsBuildNodeState = .off
        var level = 1
        var projects: [HandsBuildProject] = []

        func setEnabled(_ on: Bool) { calls.append("setEnabled(\(on))") }
        func setDevice(_ id: String, selected: Bool) { calls.append("setDevice(\(id),\(selected))") }
        func loginCloudflare() { calls.append("loginCloudflare") }
        func loginCloudflare(for deviceID: String) { calls.append("loginCloudflare(\(deviceID))") }
        func chooseZone(_ id: String) { calls.append("chooseZone(\(id))") }
        func setSubdomain(_ label: String, for deviceID: String) { calls.append("setSubdomain(\(label),\(deviceID))") }
        func applyURLs() { calls.append("applyURLs") }
        func applyURLs(seen: HandsBuildSeen, drafts: [HandsBuildDraft]) { calls.append("applyURLs(seen,\(drafts.map(\.label).joined(separator: "+")))") }
        func setLevel(_ level: Int) { calls.append("setLevel(\(level))") }
        func setProject(_ id: String, selected: Bool) { calls.append("setProject(\(id),\(selected))") }
        func connect(deviceID: String?) { calls.append("connect(\(deviceID ?? "all"))") }
        func unlockSafety(for deviceID: String) { calls.append("unlockSafety(\(deviceID))") }
    }

    @MainActor static func buildUIChecks(_ check: Checker) {
        let p = "11111111-1111-4111-8111-111111111111", s = "22222222-2222-4222-8222-222222222222", s2 = "33333333-3333-4333-8333-333333333333"
        let domain1 = "example.com", domain2 = "example.org"
        let zone = HandsBuildZone(id: "zone-1", name: domain1, accountName: "Primary One's Account")
        let zone2 = HandsBuildZone(id: "zone-2", name: domain2, accountName: "Primary One's Account")
        let loginURL = URL(string: "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2Fexample")!
        func device(_ id: String, _ name: String, primary: Bool = false, here: Bool = false, selected: Bool = false,
                    state: HandsBuildNodeState = .off, url: String? = nil, connection: HandsBuildNodeState = .off) -> HandsBuildDevice {
            HandsBuildDevice(id: id, name: name, isPrimary: primary, isThisDevice: here, selected: selected, state: state,
                             subdomain: primary ? "os-for-chatgpt" : "os-for-chatgpt-" + name.lowercased().filter(\.isLetter), url: url,
                             connection: connection)
        }
        let primaryOff = device(p, "Primary One", primary: true, here: true)
        let primaryOn = device(p, "Primary One", primary: true, here: true, selected: true, state: .working)
        let secondaryOff = device(s, "Secondary Two")
        let thirdOff = device(s2, "Other One")
        /// 開著、勾了主設備、設定拿到了（第 3 版）。
        func input(_ change: (inout HandsBuildInput) -> Void = { _ in }) -> HandsBuildInput {
            var i = HandsBuildInput()
            i.configKnown = true
            i.configRevision = 3
            i.authority = p + "#1"
            i.localDeviceID = p
            i.devices = [primaryOff]
            i.pod = .ready
            i.podAccount = "Primary One"
            i.epochHere = "e1"
            change(&i)
            return i
        }
        func connectedInput(_ change: (inout HandsBuildInput) -> Void = { _ in }) -> HandsBuildInput {
            input { i in
                i.enabled = true; i.zones = [zone]; i.selectedZoneID = zone.id; i.domain = zone.name
                i.devices = [device(p, "Primary One", primary: true, here: true, selected: true, state: .done,
                                    url: "https://os-for-chatgpt.example.com/mcp", connection: .done)]
                i.cloudflare = .done; i.dev = .done; i.statusText = HandsBuildCopy.connected(2); i.statusState = .done; i.level = 2
                i.authorized = [p]; i.urlReady = [p]; i.urlBuilt = [p]; i.grants = [p: 1]; i.anyGrants = [p: 1]
                change(&i)
            }
        }
        func problem(_ kind: HandsBuildProblem.Kind, _ device: String?, step: HandsSetupStep? = nil) -> HandsBuildProblem {
            HandsBuildProblem(kind: kind, device: device, text: "那台：出了一點事", step: step)
        }

        // W183 R8 整合審查：「…」步驟那一列的鈕名（授權＝重新授權、其他＝重試），出錯鈕要跟它一致。
        let authorizeLabel = ChatGPTHandsStepRow.rerunLabel(for: .authorize), cloudflaredLabel = ChatGPTHandsStepRow.rerunLabel(for: .cloudflared)

        // MARK: 節點標記對應與那一行短字
        struct Case { let label: String; let input: HandsBuildInput; let expect: (HandsBuildSnapshot) -> Bool }
        let cases: [Case] = [
            Case(label: "關著、沒 Cloudflare 帳號：已關閉；GPT 完成、主設備沒勾、Cloudflare 等你（關著也能登入）、Dev 沒開",
                 input: input { i in i.statusText = HandsBuildCopy.off },
                 expect: { $0.statusText == HandsBuildCopy.off && $0.statusState == .off && $0.gpt == .done
                     && $0.devices.map(\.state) == [.off] && $0.cloudflare == .waiting && $0.dev == .off && $0.attention == .cloudflare }),
            Case(label: "這台的授權頁開在私訊框：Cloudflare 等你、字「等你在私訊框授權」",
                 input: input { i in i.enabled = true; i.devices = [primaryOn]; i.loginOpenHere = loginURL; i.cloudflare = .working; i.statusText = "準備中…" },
                 expect: { $0.cloudflare == .waiting && $0.statusText == HandsBuildCopy.waitAuthorize && $0.attention == .cloudflare }),
            Case(label: "還沒從主設備拿到設定：字「準備中…」、Cloudflare 與 Dev 不亮「!」（不猜）",
                 input: input { i in i.configKnown = false; i.configRevision = nil; i.enabled = false },
                 expect: { $0.statusText == HandsBuildCopy.preparing && $0.statusState == .working && $0.cloudflare == .off && $0.dev == .off
                     && $0.attention != .cloudflare }),
            Case(label: "替那台登入沒成：Cloudflare 出錯（紅）、一句話＋「重新登入」（那台）",
                 input: input { i in i.enabled = true; i.problem = problem(.login, s) },
                 expect: { $0.cloudflare == .failed && $0.problemPanel == .cloudflare && $0.fix == .login(s) && $0.attention == .cloudflare
                     && $0.statusState == .failed && $0.statusText.hasPrefix("出錯：") }),
            Case(label: "套用沒成（撞名、建通道失敗）：Cloudflare 出錯、那一顆是「重試」（再套用一次）",
                 input: input { i in i.enabled = true; i.problem = problem(.apply, p) },
                 expect: { $0.cloudflare == .failed && $0.fix == .retryApply && $0.problemPanel == .cloudflare }),
            Case(label: "那台自己回報關口那一步有問題：亮在 ChatGPT Dev、那一顆是「重試」",
                 input: input { i in i.enabled = true; i.problem = problem(.step, s, step: .start) },
                 expect: { $0.dev == .failed && $0.problemPanel == .dev && $0.fix == .retryApply }),
            // W183 R8 整合審查（Claude 中，守 R7a「失敗那顆鈕的名字要跟步驟訊息一致」）：授權那一步＝「重新授權」（替那台登入），不是「重試」（再套用）。
            Case(label: "那台回報授權那一步出錯：Cloudflare 出錯、那一顆是「重新授權」（替那台登入；跟步驟訊息、「…」那一列同一個名字）",
                 input: input { i in i.enabled = true; i.problem = problem(.step, s, step: .authorize) },
                 expect: { $0.cloudflare == .failed && $0.problemPanel == .cloudflare && $0.fix == .reauthorize(s, .authorize)
                     && $0.fix?.title == HandsOneSwitchStatus.Action.reauthorize.title
                     && $0.fix?.title == authorizeLabel }),
            Case(label: "那台回報 cloudflared 那一步出錯：一樣是替那台登入、名字跟那一列一致（「重試」）",
                 input: input { i in i.enabled = true; i.problem = problem(.step, s, step: .cloudflared) },
                 expect: { $0.fix == .reauthorize(s, .cloudflared) && $0.fix?.title == cloudflaredLabel }),
            Case(label: "套用沒成是因為那台還沒登入那個 Cloudflare 帳號：那一顆是「重新登入」（替那台登入；再套用只會被拒絕）",
                 input: input { i in i.enabled = true; i.problem = problem(.apply, s, step: .authorize) },
                 expect: { $0.cloudflare == .failed && $0.fix == .login(s) }),
            Case(label: "那台安全停機：設備那一格紅、那一顆是「解除安全鎖」（使用者對那台按）",
                 input: input { i in i.enabled = true; i.devices = [primaryOff, device(s, "Secondary Two", selected: true, state: .waiting)]
                     i.problem = problem(.safety, s) },
                 expect: { $0.problemPanel == .devices && $0.fix == .unlock(s) && $0.devices.first { $0.id == s }?.state == .failed
                     && $0.attention == .devices }),
            Case(label: "那台太久連不到主設備（暫停）：設備出錯、沒有鈕（連上就恢復；連線沒有撤銷）",
                 input: input { i in i.enabled = true; i.problem = problem(.paused, p) },
                 expect: { $0.problemPanel == .devices && $0.fix == nil && $0.devices.first?.state == .failed }),
            Case(label: "按了做不了（設定剛被改過）：只是一句提示，不算節點出錯",
                 input: input { i in i.enabled = true; i.problem = problem(.action, nil); i.statusText = "等你選設備" },
                 expect: { $0.problem == nil && $0.problemPanel == nil && $0.notice == "那台：出了一點事" && $0.statusText == "等你選設備" }),
            Case(label: "開著、一台都沒勾：要你處理的是設備",
                 input: input { i in i.enabled = true; i.statusText = "等你選設備"; i.statusState = .waiting },
                 expect: { $0.attention == .devices && $0.statusText == "等你選設備" }),
            Case(label: "網址好了、等［連線］：Cloudflare 完成、Dev 等你（後端的字）",
                 input: connectedInput { i in i.dev = .waiting; i.statusText = "等你按連線"; i.statusState = .waiting; i.grants = [:]; i.anyGrants = [:]
                     i.devices[0].connection = .waiting },
                 expect: { $0.cloudflare == .done && $0.dev == .waiting && $0.statusText == "等你按連線" && $0.attention == .dev }),
            Case(label: "連線出錯：Dev 出錯、那一顆是「再連一次」（上一次沒成的那台）",
                 input: connectedInput { i in i.problem = problem(.connect, p) },
                 expect: { $0.dev == .failed && $0.problemPanel == .dev && $0.fix == .reconnect(p) }),
            // W183 R12（使用者 09-30 裁決：拿掉等級選擇）：字改成寫能力（「已連線・Codex、記憶」），不寫 L2。
            Case(label: "已連線：全部完成、字「已連線・Codex、記憶」、沒有要你處理的",
                 input: connectedInput(),
                 expect: { $0.gpt == .done && $0.cloudflare == .done && $0.dev == .done && $0.statusText == "已連線・Codex、記憶" && $0.attention == nil
                     && $0.devices.first?.url == "https://os-for-chatgpt.example.com/mcp" && $0.devices.first?.connection == .done }),
            Case(label: "Pod 沒登入：GPT 等你（要你處理的是 GPT）",
                 input: connectedInput { i in i.pod = .needsLogin },
                 expect: { $0.gpt == .waiting && $0.attention == .gpt }),
            Case(label: "ChatGPT 分頁關著：GPT 等你；Pod 啟動中＝轉圈；Pod 出錯＝紅",
                 input: connectedInput { i in i.pod = .disabled },
                 expect: { $0.gpt == .waiting
                     && HandsBuildSnapshot.derive(connectedInput { i in i.pod = .starting }).gpt == .working
                     && HandsBuildSnapshot.derive(connectedInput { i in i.pod = .failed("x") }).gpt == .failed
                     && HandsBuildSnapshot.derive(connectedInput { i in i.pod = .sleeping(everReady: true) }).gpt == .done }),
        ]
        let wrong = cases.filter { !$0.expect(HandsBuildSnapshot.derive($0.input)) }
            .map { "\($0.label)：\(HandsBuildSnapshot.derive($0.input))" }
        check(wrong.isEmpty, "W183 R8a 節點狀態對應：完成綠勾／等你橘「!」／進行中轉圈／沒選灰／出錯紅，與那一行短字、出錯鈕（\(cases.count) 種；W183 R8 整合：多設備的出錯種類）", "\(wrong)")

        // MARK: 單設備只畫主、多設備畫多個、連線
        func graph(_ i: HandsBuildInput) -> HandsBuildGraph { HandsBuildModel.frame(i).graph }
        let one = graph(connectedInput())
        let two = graph(connectedInput { i in i.devices.append(secondaryOff) })
        let three = graph(connectedInput { i in i.devices += [secondaryOff, thirdOff] })
        let unknown = graph(input { i in i.devices = [] })
        let kinds = one.nodes.map(\.kind)
        check(kinds == [.gpt, .device, .cloudflare, .dev] && one.deviceCount == 1 && one.nodes[1].label == "主" && one.nodes[1].sub == "Primary One"
              && one.edges.count == 3 && one.edges.allSatisfy(\.done),
              "W183 R8a 只有一台設備：只畫一個「主」節點（GPT → 主 → Cloudflare → ChatGPT Dev），已連線＝三條都是實線",
              "\(one.nodes.map { "\($0.label)/\($0.sub)" }) \(one.edges)")
        let twoLabels = two.nodes.filter { $0.kind == .device }.map(\.label)
        let secondaryEdges = two.edges.filter { $0.from == HandsBuildGraph.deviceNodeID(s) || $0.to == HandsBuildGraph.deviceNodeID(s) }
        check(two.deviceCount == 2 && twoLabels == ["主", "副"] && two.edges.count == 5 && secondaryEdges.count == 2 && secondaryEdges.allSatisfy { !$0.done }
              && three.deviceCount == 3 && three.edges.count == 7,
              "W183 R8a 多台設備：每台一個節點（主／副），沒勾的那台兩條都是灰虛線；三台＝三個設備節點", "\(two.edges)")
        let twoSelected = graph(connectedInput { i in
            i.devices.append(device(s, "Secondary Two", selected: true, state: .done, url: "https://os-for-chatgpt-secondarytwo.example.com/mcp", connection: .done))
        })
        check(twoSelected.deviceCount == 2 && twoSelected.edges.allSatisfy(\.done),
              "W183 R8 整合 多台都勾：每台一個節點、各自一條到 Cloudflare 的實線（每台各自一個網址、一條連線）", "\(twoSelected.edges)")
        check(unknown.deviceCount == 1 && unknown.nodes[1].sub == HandsBuildCopy.thisDevice,
              "W183 R8a 讀不到設備身分：只畫一台「主・這台」")
        let waitingGraph = graph(connectedInput { i in i.dev = .waiting; i.grants = [:]; i.statusText = "等你按連線" })
        check(waitingGraph.edges.last == HandsBuildGraph.Edge(from: HandsBuildGraph.cloudflareID, to: HandsBuildGraph.devID, done: false)
              && waitingGraph.edges.first?.done == true,
              "W183 R8a 連線跟著變色：完成＝實線、還沒＝虛線（Cloudflare → Dev 在連上之前是虛線）")
        check(one.nodes[1].accessibilityLabel == "主 Primary One：完成" && waitingGraph.nodes.last?.accessibilityLabel == "ChatGPT Dev：等你"
              && one.nodes.map(\.panel) == [.gpt, .devices, .cloudflare, .dev],
              "W183 R8a VoiceOver 念名稱與狀態；每個節點打開自己的面板（設備節點都開「設備」）",
              "\(one.nodes.map(\.accessibilityLabel))")
        var layoutProblems: [String] = []
        for width in [CGFloat(440), 520, 640, 820] {
            for count in 1...4 {
                let list = Array([primaryOff, secondaryOff, thirdOff, device("44444444-4444-4444-8444-444444444444", "Fourth One")].prefix(count))
                let g = graph(connectedInput { i in i.devices = list })
                let layout = HandsBuildLayout(width: width, devices: g.deviceCount)
                let frames = Array(layout.frames(g).values)
                let inside = frames.allSatisfy { $0.minX >= 0 && $0.maxX + 8 <= layout.width && $0.minY - 8 >= 0 && $0.maxY <= layout.height }
                let apart = frames.enumerated().allSatisfy { a in frames.enumerated().allSatisfy { b in a.offset == b.offset || !a.element.insetBy(dx: -8, dy: -8).intersects(b.element) } }
                if !inside || !apart || frames.count != g.nodes.count { layoutProblems.append("w=\(width) n=\(count)") }
            }
        }
        check(layoutProblems.isEmpty && HandsBuildLayout.height(devices: 1) == 250 && HandsBuildLayout.height(devices: 3) > 250,
              "W183 R8a 節點位置（照對照稿四欄、設備直向排）：各種寬度與 1–4 台都不重疊、標記不超出", "\(layoutProblems)")

        // MARK: 面板切換
        // W183 R8 整合審查：照名字找那兩個情境（中間加了出錯鈕的情境，位置會變）。
        let loginCase = cases.first { $0.label.hasPrefix("這台的授權頁開在私訊框") } ?? cases[1]
        let connectCase = cases.first { $0.label.hasPrefix("網址好了、等［連線］") } ?? cases[10]
        let loginSnap = HandsBuildSnapshot.derive(loginCase.input), connectSnap = HandsBuildSnapshot.derive(connectCase.input)
        check(HandsBuildPanel.resolve(chosen: nil, attention: .cloudflare) == .cloudflare && HandsBuildPanel.resolve(chosen: .gpt, attention: .cloudflare) == .gpt
              && HandsBuildPanel.resolve(chosen: nil, attention: nil) == .dev
              && loginSnap.attention == .cloudflare && connectSnap.attention == .dev,
              "W183 R8a 面板切換：點了哪個節點就開哪個（一次一個）；沒點＝要你處理的那個（套用完跟著換到 ChatGPT Dev）；都好了＝ChatGPT Dev")
        check(HandsSetupStep.allCases.map(HandsBuildPanel.of) == [.devices, .cloudflare, .cloudflare, .cloudflare, .dev, .dev, .dev, .dev],
              "W183 R8a 步驟歸到節點：選主機＝設備；cloudflared、授權、通道＝Cloudflare；關口、網址、連線＝ChatGPT Dev")

        // MARK: 按鈕叫對 model 動作
        let recorder = RecordingBuildModel()
        let seenNow = HandsBuildSeen.of(input())
        let intents: [(HandsBuildUIIntent, String)] = [
            (.toggle(true), "setEnabled(true)"), (.toggle(false), "setEnabled(false)"), (.pickDevice(s, true), "setDevice(\(s),true)"),
            (.loginCloudflare, "loginCloudflare"), (.loginCloudflareFor(s), "loginCloudflare(\(s))"), (.chooseZone("zone-2"), "chooseZone(zone-2)"),
            (.subdomain("my-os", device: p), "setSubdomain(my-os,\(p))"), (.apply(seen: nil, drafts: []), "applyURLs"),
            (.apply(seen: seenNow, drafts: [HandsBuildDraft(label: "my-os", device: p), HandsBuildDraft(label: "my-os-b", device: s)]), "applyURLs(seen,my-os+my-os-b)"),
            (.level(2), "setLevel(2)"), (.project("proj", false), "setProject(proj,false)"), (.connect(nil), "connect(all)"), (.connect(s), "connect(\(s))"),
            (.unlockSafety(s), "unlockSafety(\(s))"),
        ]
        for (intent, _) in intents { intent.send(to: recorder) }
        check(recorder.calls == intents.map(\.1), "W183 R8a 按鈕叫對 model 動作（純邏輯：開關、設備、登入（這台／替那台）、網域、子網域、套用（帶看到的那一份與每台的草稿）、等級、專案、連線（全部／一台）、解除安全鎖）", "\(recorder.calls)")

        // MARK: adapter：每個動作對到多設備後端（HandsBuildController）
        typealias E = HandsBuildEffect
        let two2 = input { i in i.devices = [primaryOff, secondaryOff] }
        let open = input { i in i.enabled = true; i.devices = [device(p, "Primary One", primary: true, here: true, selected: true), secondaryOff]
            i.zones = [zone, zone2]; i.selectedZoneID = zone.id; i.domain = zone.name }
        let unknownConfig = input { i in i.configKnown = false; i.configRevision = nil }
        let draft = HandsBuildDraft(label: "my-os", device: p)
        let plans: [(String, [E], [E])] = [
            ("打開（中央設定；一台都沒勾＝勾主設備）", HandsBuildModel.plan(.setEnabled(true), input()), [.setEnabled(true)]),
            ("關掉（確認列之後）", HandsBuildModel.plan(.setEnabled(false), open), [.setEnabled(false)]),
            ("還沒拿到設定＝開關不送（R8c：沒有不比對版本的改法）", HandsBuildModel.plan(.setEnabled(true), unknownConfig), [.notice(HandsBuildCopy.notReady)]),
            ("勾另一台＝多選（不再是換主機）", HandsBuildModel.plan(.setDevice(s, true), two2), [.select(s, true)]),
            ("取消勾那台＝那台關掉（每台關掉）", HandsBuildModel.plan(.setDevice(p, false), open), [.select(p, false)]),
            ("已經勾了＝不送", HandsBuildModel.plan(.setDevice(p, true), open), []),
            ("不認得的設備＝不送", HandsBuildModel.plan(.setDevice("99999999-9999-4999-8999-999999999999", true), two2), []),
            ("登入 Cloudflare（這台）＝只是登入", HandsBuildModel.plan(.loginCloudflare(nil), input()), [.login(p)]),
            ("這台的授權頁在等＝在這台再打開", HandsBuildModel.plan(.loginCloudflare(nil), input { i in i.loginOpenHere = loginURL }), [.openLogin(loginURL)]),
            ("這台的設定流程在跑＝不送", HandsBuildModel.plan(.loginCloudflare(nil), input { i in i.busyHere = true }), [.notice(HandsBuildCopy.busy)]),
            ("這台的登入不用等設定（登入只是登入）", HandsBuildModel.plan(.loginCloudflare(nil), unknownConfig), [.login(p)]),
            ("替別台登入（授權存那台）", HandsBuildModel.plan(.loginCloudflare(s), two2), [.login(s)]),
            ("替別台登入：已經在等那台＝不重送", HandsBuildModel.plan(.loginCloudflare(s), input { i in i.devices = [primaryOff, secondaryOff]; i.loginBusy = [s] }), []),
            ("替別台登入：還沒拿到設定＝不送", HandsBuildModel.plan(.loginCloudflare(s), input { i in i.devices = [primaryOff, secondaryOff]; i.configKnown = false }),
             [.notice(HandsBuildCopy.notReady)]),
            ("選網域（還沒有網址）＝直接選", HandsBuildModel.plan(.chooseZone("zone-2"), open), [.chooseZone("zone-2")]),
            ("改子網域（那一台）", HandsBuildModel.plan(.setSubdomain("My-OS", s), open), [.setSubdomain("my-os", s)]),
            ("子網域不合格", HandsBuildModel.plan(.setSubdomain("bad_label!", p), open), [.notice(HandsBuildCopy.badLabel)]),
            ("子網域一樣＝不送", HandsBuildModel.plan(.setSubdomain("os-for-chatgpt", p), open), []),
            ("套用（照看到的那一版）", HandsBuildModel.plan(.applyURLs(seen: HandsBuildSeen.of(open), drafts: []), open), [.apply(expected: 3, drafts: [])]),
            ("套用帶子網域草稿（先存再套用，同一件）", HandsBuildModel.plan(.applyURLs(seen: HandsBuildSeen.of(open), drafts: [draft]), open),
             [.apply(expected: 3, drafts: [draft])]),
            ("套用（關著）＝先打開", HandsBuildModel.plan(.applyURLs(seen: nil, drafts: []), input()), [.notice(HandsBuildCopy.turnOnFirst)]),
            ("套用（沒選網域）＝先選網域（R8c：不自動選）", HandsBuildModel.plan(.applyURLs(seen: nil, drafts: []), input { i in i.enabled = true; i.devices = open.devices }),
             [.notice(HandsBuildCopy.pickDomain)]),
            ("套用（一台都沒勾）", HandsBuildModel.plan(.applyURLs(seen: nil, drafts: []), input { i in i.enabled = true; i.selectedZoneID = zone.id }),
             [.notice(HandsBuildCopy.pickDevice)]),
            ("等級", HandsBuildModel.plan(.setLevel(2), open), [.setLevel(2)]),
            ("等級沒有 L3", HandsBuildModel.plan(.setLevel(3), open), [.setLevel(2)]),
            ("等級一樣＝不送", HandsBuildModel.plan(.setLevel(1), open), []),
            ("等級（沒勾設備）＝先勾", HandsBuildModel.plan(.setLevel(2), input()), [.notice(HandsBuildCopy.pickDevice)]),
            // W183 R10：專案不再勾（全部可見、面板只顯示）：勾專案的動作什麼都不送（在清單裡的也一樣）。
            ("勾專案（那台的）＝不送（W183 R10 全部可見）", HandsBuildModel.plan(.setProject("\(p)/a", true), input { i in
                i.projects = [HandsBuildProject(id: "\(p)/a", name: "Project A", selected: false, deviceID: p)] }), []),
            ("不在清單的專案不收", HandsBuildModel.plan(.setProject("zz", true), input { i in i.projects = [HandsBuildProject(id: "a", name: "Project A", selected: true)] }), []),
            ("［連線］全部＝私訊框的［連線］卡、逐台排", HandsBuildModel.plan(.connect(nil), open), [.connect(nil)]),
            ("［連線］一台", HandsBuildModel.plan(.connect(p), open), [.connect(p)]),
            ("［連線］沒勾的那台＝不送", HandsBuildModel.plan(.connect(s), open), []),
            ("關著不連線", HandsBuildModel.plan(.connect(nil), input()), [.notice(HandsBuildCopy.turnOnFirst)]),
            ("解除安全鎖（那台鎖著）", HandsBuildModel.plan(.unlock(s), input { i in i.safetyLocked = [s] }), [.unlock(s)]),
            ("解除安全鎖（那台沒鎖）＝不送", HandsBuildModel.plan(.unlock(s), input()), []),
            ("出錯鈕：解除安全鎖", HandsBuildModel.plan(.fix, input { i in i.safetyLocked = [s]; i.problem = problem(.safety, s) }), [.unlock(s)]),
            ("出錯鈕：再套用一次", HandsBuildModel.plan(.fix, input { i in i.enabled = true; i.devices = open.devices; i.selectedZoneID = zone.id
                i.problem = problem(.apply, p) }), [.apply(expected: 3, drafts: [])]),
            ("出錯鈕：替那台重新登入", HandsBuildModel.plan(.fix, input { i in i.devices = [primaryOff, secondaryOff]; i.problem = problem(.login, s) }), [.login(s)]),
            ("出錯鈕：授權那一步出錯＝替那台登入（重新授權）", HandsBuildModel.plan(.fix, input { i in i.devices = [primaryOff, secondaryOff]
                i.problem = problem(.step, s, step: .authorize) }), [.login(s)]),
            ("出錯鈕：套用沒成因為那台還沒登入＝替那台登入", HandsBuildModel.plan(.fix, input { i in i.enabled = true; i.devices = [primaryOff, secondaryOff]
                i.problem = problem(.apply, s, step: .authorize) }), [.login(s)]),
            ("出錯鈕：再連一次", HandsBuildModel.plan(.fix, input { i in i.enabled = true; i.devices = open.devices; i.problem = problem(.connect, p) }), [.connect(p)]),
            ("出錯鈕：暫停、連不到＝沒有鈕", HandsBuildModel.plan(.fix, input { i in i.problem = problem(.paused, p) }), []),
        ]
        let planWrong = plans.filter { $0.1 != $0.2 }.map { "\($0.0)：\($0.1)" }
        check(planWrong.isEmpty, "W183 R8a adapter 把每個動作對到多設備後端（純邏輯，\(plans.count) 條；W183 R8 整合：開關、多選設備、登入只是登入（這台／替那台）、套用帶看到的那一版、等級與專案、［連線］逐台、解除安全鎖、出錯鈕）",
              "\(planWrong)")
        let unlockOnlyWhenAsked = plans.allSatisfy { row in
            !row.1.contains { if case .unlock = $0 { return true }; return false } || row.0.contains("解除安全鎖")
        }
        check(plans.allSatisfy { !$0.1.contains(.setEnabled(true)) || $0.0.hasPrefix("打開") } && unlockOnlyWhenAsked,
              "W183 R8a 畫面的按鈕不會繞過確認（結構檢查：只有開關打開才送 setEnabled(true)；解除安全鎖只由使用者按那台）——安全流程的操作級反例在 W183 R8a 審查那幾條")

        // MARK: 沒有長段說明文字
        W224Acceptance.compactBuild { value, label in check(value, label, "native current card") }
        check(HandsBuildMore.allCases.allSatisfy { $0.title.count <= 8 }, "W183 工程細節選單的字維持 8 字以內")
        let conforming: any HandsBuildModeling.Type = HandsBuildModel.self   // 編譯得過＝實作了接口
        let backend: any HandsBuildModeling.Type = HandsBuildController.self
        check(String(describing: conforming) == "HandsBuildModel" && String(describing: backend) == "HandsBuildController",
              "W183 R8a HandsBuildModel 實作接口 HandsBuildModeling（名字與語意不改）；W183 R8 整合：它接的後端是 R8c 的 HandsBuildController")

        buildReviewChecks(check, input: input, connectedInput: connectedInput, device: device, zone: zone, zone2: zone2, p: p, s: s)
    }

    // MARK: - W183 R8a 審查（GPT-6／Claude）：操作級的反例

    @MainActor static func buildReviewChecks(_ check: Checker, input: ((inout HandsBuildInput) -> Void) -> HandsBuildInput,
                                             connectedInput: ((inout HandsBuildInput) -> Void) -> HandsBuildInput,
                                             device: (String, String, Bool, Bool, Bool, HandsBuildNodeState, String?, HandsBuildNodeState) -> HandsBuildDevice,
                                             zone: HandsBuildZone, zone2: HandsBuildZone, p: String, s: String) {
        typealias E = HandsBuildEffect
        // 先做好要用的設備（傳給非逃逸的 input 閉包時不能抓非逃逸的參數：Swift 不准重入修改）。
        let pWorking = device(p, "Primary One", true, true, true, .working, nil, .off)
        let sWorking = device(s, "Secondary Two", false, false, true, .working, nil, .off)
        let pDone = device(p, "Primary One", true, true, true, .done, nil, .off)
        let sDone = device(s, "Secondary Two", false, false, true, .done, nil, .off)

        // 1. Computer Use：卡片在畫面上＝以 TATWO 自己為目標一律拒絕（跟私訊框授權頁同一道閘門；截圖、讀 AX、每個輸入前都看）。
        let own = ProcessInfo.processInfo.processIdentifier
        let before = BrowserSensitivePageGate.isActive
        let token = UUID()
        HandsBuildScreenGate.appeared(token)
        HandsBuildScreenGate.appeared(token)   // 重畫再出現一次：不重複算
        let gateOpen: Bool = HandsBuildScreenGate.isShown && HandsConnectPresenter.anySensitive && BrowserSensitivePageGate.isActive
        let sensitive: Bool = BrowserSensitivePageGate.isActive
        let selfRefused: Bool = ComputerUseController.refusesSelf(pid: own, lane: .externalApplication, sensitivePageOpen: sensitive)
        let otherAppOK: Bool = !ComputerUseController.refusesSelf(pid: own &+ 1, lane: .externalApplication, sensitivePageOpen: sensitive)
        let builtInOK: Bool = !ComputerUseController.refusesSelf(pid: own, lane: .builtInBrowser, sensitivePageOpen: sensitive)
        let everyInput: Bool = ComputerUseController.preDispatchCodes.contains(ComputerUseController.sensitivePageCode)
        let noSelfGrant: Bool = !ComputerUseController.shared.isOperatingSelf()
        let blocked: Bool = gateOpen && selfRefused && otherAppOK && builtInOK && everyInput && noSelfGrant
        HandsBuildScreenGate.disappeared(token)
        let released = !HandsBuildScreenGate.isShown && BrowserSensitivePageGate.isActive == before
        check(blocked && released,
              "W183 R8a 審查 Computer Use：ChatGPT build 的安全設定卡在畫面上時，全權 AI 也不能以 TATWO 為目標代按（閘門層：出現就撤銷以 TATWO 為目標的授權、每個輸入前再看；別的 App 與內建瀏覽器不受影響；卡片收起就恢復）",
              "before=\(before) blocked=\(blocked) released=\(released)")
        check.skip("Computer Use 真的拿到以 TATWO 為目標的授權後被這張卡撤銷：無頭自測拿不到螢幕錄影與輔助使用權限，只驗到閘門與拒絕判斷；主導實機驗")

        // 2. 換了主設備之後的舊面板：「…」裡的寫入不送；會放寬的動作這台的流程世代也要一樣；roleKey 一變畫面就收面板與草稿。
        //    W183 R8 整合：R8c 沒有「一次一台主機」——原本的「模式或主機變了」改成「主設備（主權）變了」；每台都看這台自己的「…」。
        let shown = HandsBuildSeen.of(input { _ in })
        let nowOtherAuthority = HandsBuildSeen.of(input { i in i.authority = s + "#2" })
        let nowNewEpoch = HandsBuildSeen.of(input { i in i.epochHere = "e2" })
        let writes: [HandsBuildDetail] = [.setCallbacks(["https://chatgpt.com/aip/x/oauth/callback"]), .deleteTunnels(["t1"]),
                                          .confirmAuthorization(token: "tok", domain: "example.com"), .reauthorize, .rerun(.tunnel),
                                          .openLogin(URL(string: "https://dash.cloudflare.com/argotunnel")!), .revoke("g1"), .revokeAll, .cancelSetup,
                                          .stopPairing, .revokeDevice(s)]
        func refusal(_ action: HandsBuildDetail, _ shown: HandsBuildSeen, _ now: HandsBuildSeen) -> String? {
            HandsBuildModel.detailRefusal(action, shown: shown, now: now)
        }
        var staleRefused = true
        for write in writes {
            let moved: String? = refusal(write, shown, nowOtherAuthority)
            let same: String? = refusal(write, shown, shown)
            if moved != HandsBuildCopy.changed || same != nil { staleRefused = false }
        }
        let confirmNewEpoch: Bool = refusal(.confirmAuthorization(token: "tok", domain: "example.com"), shown, nowNewEpoch) != nil
        let callbacksNewEpoch: Bool = refusal(.setCallbacks([]), shown, nowNewEpoch) != nil
        let revokeNewEpoch: Bool = refusal(.revoke("g1"), shown, nowNewEpoch) == nil
        let revokeDeviceNewEpoch: Bool = refusal(.revokeDevice(s), shown, nowNewEpoch) == nil
        let cancelNewEpoch: Bool = refusal(.cancelSetup, shown, nowNewEpoch) == nil
        let epochRule: Bool = confirmNewEpoch && callbacksNewEpoch && revokeNewEpoch && revokeDeviceNewEpoch && cancelNewEpoch
        let panels: Bool = HandsBuildMore.items == HandsBuildMore.allCases && !HandsBuildMore.allCases.map(\.rawValue).contains("host")
        let roleKey: String = input { _ in }.roleKey
        let otherKey: String = input { i in i.authority = s + "#2" }.roleKey
        let sameRoleKey: String = input { i in i.enabled = true; i.level = 2; i.configRevision = 9 }.roleKey
        let keyMoves: Bool = roleKey != otherKey && roleKey == sameRoleKey
        check(staleRefused && epochRule && panels && keyMoves,
              "W183 R8a 審查 角色切換後的舊面板（W183 R8 整合：換了主設備）：「…」裡的加入／移除回呼網址、確認授權、重跑、清通道、撤銷都不送；會放寬的動作這台的流程世代也要一樣；「…」只有這台自己的五項（沒有「改用這台當主機」）",
              "stale=\(staleRefused) epoch=\(epochRule) panels=\(panels) key=\(keyMoves)")

        // 3. 等確認帳號與網域時拒絕這個授權（R3b／R8a）。W183 R8 整合（R8c 必改 4：登入只是登入）：登入不綁任何網域、不建網址——
        //    登入的結果只有在使用者自己選網域、按「套用」之後才會被用上；所以「不是要的授權」根本用不上（選別的網域、或替那台再登入一次）。
        //    這台的「…」›「帳號與網域」照舊有「是這個，繼續／取消並重新授權」（HandsAuthorizationRow）。
        let afterLogin = input { i in i.enabled = true; i.devices = [pWorking]
            i.zones = [zone, zone2] }   // 登入完：帳號裡有網域，但還沒選
        let loginOnly: [E] = HandsBuildModel.plan(.loginCloudflare(nil), afterLogin)
        let applyNeedsChoice: [E] = HandsBuildModel.plan(.applyURLs(seen: HandsBuildSeen.of(afterLogin), drafts: []), afterLogin)
        let loginIsLogin: Bool = loginOnly == [E.login(p)]
            && !loginOnly.contains { if case .apply = $0 { return true }; if case .chooseZone = $0 { return true }; return false }
        check(loginIsLogin && applyNeedsChoice == [E.notice(HandsBuildCopy.pickDomain)],
              "W183 R8a 審查 等確認時拒絕授權（W183 R8 整合：登入只是登入）：登入不選網域、不建網址；沒選網域按「套用」＝先選網域——不是要的授權不會被用上")

        // 4. 「套用」確認的是看到的那一份：背景換了（設定版本、網域、勾選變了）＝不送；一樣＝帶看到的那一版（後端再照這一版做 CAS）。
        let seenOpen = input { i in i.enabled = true; i.devices = [pWorking]
            i.zones = [zone, zone2]; i.selectedZoneID = zone.id; i.domain = zone.name }
        let seenA = HandsBuildSeen.of(seenOpen)
        var swapped = seenOpen; swapped.configRevision = 4; swapped.selectedZoneID = zone2.id; swapped.domain = zone2.name
        var reselected = seenOpen; reselected.configRevision = 4
        reselected.devices.append(sWorking)
        let swappedPlan: [E] = HandsBuildModel.plan(.applyURLs(seen: seenA, drafts: []), swapped)
        let reselectedPlan: [E] = HandsBuildModel.plan(.applyURLs(seen: seenA, drafts: []), reselected)
        let samePlan: [E] = HandsBuildModel.plan(.applyURLs(seen: seenA, drafts: []), seenOpen)
        let applySeen: Bool = swappedPlan == [E.notice(HandsBuildCopy.changed)] && reselectedPlan == [E.notice(HandsBuildCopy.changed)]
            && samePlan == [E.apply(expected: 3, drafts: [])]
        check(applySeen, "W183 R8a 審查 「套用」確認的是畫面上看到的那一份（設定版本、網域、勾選、世代）：背景換了就不送，請你再看一次；一樣＝帶看到的那一版（後端照這一版 CAS）")

        // 5. 子網域存檔失敗＝不往下建網址（W183 R8 整合：存與套用是同一件交給後端——後端照看到的版本先存、存不成就停；真的存檔失敗的操作級
        //    驗收在 w183build「套用帶子網域草稿：存不成」）。這裡驗：不合格的草稿一開始就停；照順序做、第一步沒成功就停（runEffects）。
        let draft = HandsBuildDraft(label: "my-os", device: p)
        let effects: [E] = HandsBuildModel.plan(.applyURLs(seen: seenA, drafts: [draft]), seenOpen)
        let badDraft: [E] = HandsBuildModel.plan(.applyURLs(seen: seenA, drafts: [HandsBuildDraft(label: "bad_label!", device: p)]), seenOpen)
        var ran: [E] = []
        let stop = E.notice("存不成")
        let result = HandsBuildModel.runEffects([stop, E.connect(nil)]) { effect in ran.append(effect); return !effect.isNotice }
        let ordered: Bool = effects == [E.apply(expected: 3, drafts: [draft])] && badDraft == [E.notice(HandsBuildCopy.badLabel)]
        let stoppedAtSave: Bool = result.stopped == stop && result.done == 0 && ran == [stop]
        check(ordered && stoppedAtSave && HandsBuildCopy.saveFailed("x").hasPrefix("沒存成"),
              "W183 R8a 審查 子網域存檔失敗＝停在那裡（草稿跟套用是同一件、後端先存；不合格一開始就停；照順序做、第一步沒成功後面不做）",
              "effects=\(effects) ran=\(ran)")

        // 6. 暫時的 grant 不算完成：主機這台與副設備的狀態字（HandsOneSwitchStatus：ChatGPT Space 的狀態小鈕還在用）照舊；
        //    W183 R8 整合：每台回報確認過的連線數（confirmed_grants），後端只把確認過的當「已連線」（w183build 驗）——這裡驗畫面照後端的。
        func localStatus(confirmed: Int, provisional: Int) -> HandsOneSwitchStatus {
            var setup = HandsSetupState()
            for step in HandsSetupStep.allCases where step != .pairing { setup.steps[step.rawValue] = HandsSetupStepState(status: .done, message: "", updatedAt: Date()) }
            return HandsOneSwitchStatus.forLocal(.init(enabled: true, level: 2, busy: false, setup: setup, loginOpen: false, blocked: nil,
                                                       phase: .running(url: "https://os-for-chatgpt.example.com/mcp"), activeGrants: confirmed,
                                                       connect: .idle, connectProblem: nil, handback: nil, provisionalGrants: provisional))
        }
        let provisionalGrant: [String: Any] = ["id": "g1", "client_name": "ChatGPT", "level": 2, "provisional": true]
        let grantsObject: [String: Any] = ["enabled": true, "phase": ["state": "running", "text": "running", "url": "https://os-for-chatgpt.example.com/mcp"],
                                           "grants": [provisionalGrant]]
        let remoteGrants = HandsRemoteStatus(grantsObject)
        let remoteOne = remoteGrants.map { HandsOneSwitchStatus.forRemote(.init(status: $0, pendingEnabled: nil, stale: false, problem: nil, connect: .idle, connectProblem: nil)) }
        let onlyProvisional: HandsOneSwitchStatus = localStatus(confirmed: 0, provisional: 1)
        let localRule: Bool = onlyProvisional == HandsOneSwitchStatus.connecting
            && localStatus(confirmed: 1, provisional: 0) == HandsOneSwitchStatus.connected(level: 2)
            && localStatus(confirmed: 0, provisional: 0) == HandsOneSwitchStatus.waiting(.connect)
        let remoteRule: Bool = remoteOne == HandsOneSwitchStatus.connecting && (remoteGrants?.grants.first?.provisional ?? false)
        let pending = connectedInput { i in i.dev = .working; i.statusText = HandsOneSwitchStatus.connecting.text; i.statusState = .working
            i.grants = [p: 0]; i.anyGrants = [p: 1]; i.devices[0].connection = .working }
        let pendingSnap = HandsBuildSnapshot.derive(pending)
        let devNode: Bool = pendingSnap.dev == HandsBuildNodeState.working && pendingSnap.devices.first?.connection == HandsBuildNodeState.working
            && pendingSnap.statusText == HandsOneSwitchStatus.connecting.text && pending.totalGrants == 0
        check(localRule && remoteRule && devNode,
              "W183 R8a 審查 暫時的 grant（還沒確認、不能呼叫工具）不算已連線：主機與副設備都顯示「連線中…」、ChatGPT Dev 轉圈不打勾、有效連線數不算它",
              "\(localStatus(confirmed: 0, provisional: 1)) remote=\(String(describing: remoteOne))")

        // 7. 還不知道（W183 R8 整合：還沒從主設備拿到設定；原本是「副設備還在問主機」）：不亮「等你登入 Cloudflare」、不跳 Cloudflare 面板、
        //    改設定的按鈕不送（後端也拒：沒有預期版本）。
        let asking = input { i in i.configKnown = false; i.configRevision = nil; i.enabled = false; i.statusText = HandsBuildCopy.off }
        let a = HandsBuildSnapshot.derive(asking)
        let askingOK: Bool = a.statusText == HandsBuildCopy.preparing && a.cloudflare == HandsBuildNodeState.off && a.dev == HandsBuildNodeState.off
            && a.attention != HandsBuildPanel.cloudflare
        let askingRefused: Bool = [HandsBuildModel.Action.setEnabled(true), .setDevice(p, true), .chooseZone(zone.id), .setLevel(2), .connect(nil),
                                   .applyURLs(seen: nil, drafts: [])].allSatisfy { HandsBuildModel.plan($0, asking) == [E.notice(HandsBuildCopy.notReady)] }
        check(askingOK && askingRefused,
              "W183 R8a 審查 還不知道（還沒從主設備拿到設定）：字是「準備中…」、Cloudflare 不亮「!」；開關、勾設備、選網域、等級、連線、套用都不送",
              "asking=\(a.statusText)/\(a.cloudflare)")

        // 8. 已經有網址（或已連線）之後換網域：先出卡片內確認列（不一鍵換）；確認時看到的變了＝不送。
        let built = connectedInput { i in i.zones = [zone, zone2] }
        let fresh = input { i in i.zones = [zone, zone2]; i.selectedZoneID = zone.id }
        var builtMoved = built; builtMoved.configRevision = 9
        let askFirst: Bool = HandsBuildModel.plan(.chooseZone("zone-2"), built) == [E.askZoneChange("zone-2")]
        let confirmed: Bool = HandsBuildModel.plan(.confirmZone("zone-2", seen: HandsBuildSeen.of(built)), built) == [E.chooseZone("zone-2")]
        let movedRefused: Bool = HandsBuildModel.plan(.confirmZone("zone-2", seen: HandsBuildSeen.of(built)), builtMoved) == [E.notice(HandsBuildCopy.changed)]
        let freshDirect: Bool = HandsBuildModel.plan(.chooseZone("zone-2"), fresh) == [E.chooseZone("zone-2")]
        check(askFirst && confirmed && movedRefused && freshDirect,
              "W183 R8a 審查 網址建好（或已連線）之後換網域：先在卡片內確認（現有網址與連線會失效），不一鍵換；網址還沒建＝直接換")

        // 9. 範圍摘要常駐：等級白話、記憶讀寫、有效連線；W183 R8 整合：每台勾選的設備的專案帶著那台（(deviceID, projectID)），哪一台都看得到、改得到。
        // W183 R12（拿掉等級選擇）：等級白話（levelWords）拿掉，換成一行能力（跟確認卡同一句）；還沒全開寫現在能做的。
        let wordsMatch: Bool = HandsBuildCopy.capabilities == "連上後：看全部專案・可用 Codex・記憶只讀＋收件匣"
            && HandsBuildCopy.capabilities == HandsConnectAbility.line(level: HandsBuildConfig.defaultLevel)
        let perDevice = input { i in i.enabled = true; i.devices = [pDone, sDone]
            i.projects = [HandsBuildProject(id: "\(s)/b", name: "Project B", selected: false, deviceID: s)] }
        // W183 R10：專案全部可見——面板上勾不了（哪一台都一樣：動作什麼都不送）；中央設定只剩等級。
        let fromHere: Bool = HandsBuildModel.plan(.setProject("\(s)/b", true), perDevice).isEmpty
        check(wordsMatch && fromHere, "W224-5 現在的卡片只留能力；專案勾選仍不送（畫面契約由原生 AX 檢查）")
    }
}
extension HandsBuildAcceptance {
    @MainActor static func statusTruthChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("w185-status"), keys: keys)
        let observer = try fleet.add(aID, name: "fixture")
        let config = try fleet.update([.select(device: pID, selected: true), .select(device: bID, selected: true),
                                       .setEnabled(true), .zone(accountID: accountID, zoneID: zoneID, domain: domain)])
        let ctl = HandsBuildController(dependencies: .init(
            sync: observer.sync, flow: HandsConnectFlow(), localID: { aID }, pairedDevices: { known },
            loginHere: {}, unlockHere: { _, _, _ in nil },
            revocation: .standard(service: observer.service, callPrimary: fleetPrimaryCall(fleet, sender: aID)),
            role: { observer.role }, openLogin: { _, _ in }, closeLogin: { _ in },
            background: { $0() }, now: { fleet.clock.now() }, uptime: { fleet.clock.uptime() }))
        observer.sync.syncNow()
        _ = await waitUntil(3) { ctl.config != nil }
        check(ctl.connectionReason(bID) == "沒收到這台的回報" && !ctl.statusText.contains("登入 Cloudflare"),
              "W311 沒收到副設備回報：不要求 Cloudflare 登入", ctl.statusText)
        for detail in ["Connection reset by peer", "Connection closed by remote host", "ssh_remote_login_unresponsive"] {
            check(HandsRemoteClient.plain(RemoteHostLinkError.sshHomeLookupFailed(detail)) == "主設備的遠端登入沒有回應",
                  "W311 SSH 拒絕與主設備没開分開：" + detail)
        }
        func report(_ id: String, running: Bool, grants: Int) -> HandsBuildDeviceReport {
            var r = HandsBuildDeviceReport(deviceID: id)
            r.appliedConfigRevision = config.configRevision
            r.permit = "active"
            r.phase = running ? "running" : "stopped"
            r.phaseText = running ? "運作中" : "測試：通道暫停"
            r.publicHost = config.hostname(id)
            r.grants = grants; r.confirmedGrants = grants
            return r
        }
        var unauthorized = report(bID, running: false, grants: 0)
        unauthorized.accounts = [.init(id: accountID, name: "fixture", zones: [.init(zoneID: zoneID, name: domain, authorized: false)])]
        fleet.authority.record(report(pID, running: false, grants: 0), from: pID)
        fleet.authority.record(unauthorized, from: bID)
        observer.sync.syncNow()
        _ = await waitUntil(3) { ctl.hasFreshReport(bID) }
        check(ctl.statusText.contains("登入 Cloudflare"), "W311 明確回報沒有通道憑證：才要求登入", ctl.statusText)
        let primary = report(pID, running: true, grants: 1)
        let stopped = report(bID, running: false, grants: 0)
        fleet.authority.record(primary, from: pID)
        fleet.authority.record(stopped, from: bID)
        observer.sync.syncNow()
        _ = await waitUntil(3) { ctl.devices.first(where: { $0.id == pID })?.connection == .done }
        let primaryName = known.first(where: { $0.id == pID })!.name
        check(ctl.statusText.contains("已連線：\(primaryName)") && ctl.statusText != "等你按連線" && ctl.statusState == .working,
              "W185 兩台勾選只有一台確認連上：控制器顯示已連線設備與部分狀態", ctl.statusText)
        check(ctl.connectionReason(bID) == "關口沒在跑：測試：通道暫停"
              && ctl.devices.first(where: { $0.id == bID })?.connection == .waiting,
              "W185 新鮮回報但關口停下：設備等待，原因保留那台 phaseText")
        func input() -> HandsBuildInput {
            var i = HandsBuildInput()
            i.configKnown = true; i.enabled = true; i.devices = ctl.devices
            i.statusText = ctl.statusText; i.statusState = ctl.statusState
            i.deviceReasons[bID] = ctl.connectionReason(bID)
            i.problem = HandsBuildProblem(kind: .step, device: bID, text: "副設備失敗")
            return i
        }
        var frame = HandsBuildModel.frame(input())
        check(frame.snapshot.statusText == ctl.statusText && frame.snapshot.statusState == .working
              && frame.graph.nodes.first(where: { $0.id == HandsBuildGraph.deviceNodeID(bID) })?.accessibilityLabel.contains("關口沒在跑") == true,
              "W185 畫面 adapter 不以單台錯誤蓋掉部分連線；節點與 AX 有關口原因")
        fleet.clock.advance(60)
        fleet.authority.record(primary, from: pID)
        observer.sync.syncNow()
        _ = await waitUntil(3) { ctl.connectionReason(bID).contains("最後回報") }
        frame = HandsBuildModel.frame(input())
        check(ctl.statusText.contains("已連線：\(primaryName)") && ctl.connectionReason(bID).contains("那台的 App 沒開或連不到（最後回報 ")
              && frame.graph.nodes.first(where: { $0.id == HandsBuildGraph.deviceNodeID(bID) })?.accessibilityLabel.contains("最後回報") == true,
              "W185 回報過期：仍標出可用設備；另一台節點與 AX 帶最後回報時間", ctl.statusText)
        let partial = HandsConnectEntryState.resolve(enabled: true, devices: ctl.devices, cloudflare: .waiting, phase: .idle,
                                                     reason: { ctl.connectionReason($0) },
                                                     verdict: { $0 == pID ? .connected(level: 1) : .open })
        check(partial.word.contains("已連線：\(primaryName)") && partial.code == "partially_connected"
              && HandsConnectEntry.status(partial).level == 1,
              "W185 私訊膠囊：部分帳號連線可見，能力沿用已證實等級、不提高上限")
        let unproven = HandsConnectEntryState.resolve(enabled: true, devices: ctl.devices, cloudflare: .done, phase: .idle,
                                                      verdict: { _ in .open })
        check(unproven == .connect, "W185 私訊膠囊：別的帳號的 grant 不冒充目前帳號已連線")
        let now = fleet.clock.now(), expires = fleet.clock.now().addingTimeInterval(300)
        let active: HandsBuildPermit.State = .active(config.slice(for: bID), expiresAt: expires)
        let warning = HandsBuildController.memberAvailability(permit: active, primary: "Mac mini", lastSync: now.addingTimeInterval(-60), now: now)
        check(warning == "主設備（Mac mini）沒開或連不到；你這台的 ChatGPT 手腳會在 \(ChatGPTHandsService.clockText(expires)) 暫停"
              && HandsBuildController.memberAvailability(permit: active, primary: "Mac mini", lastSync: now, now: expires) == "已暫停：主設備沒開"
              && HandsBuildController.memberAvailability(permit: .paused("expired"), primary: "Mac mini", lastSync: now, now: now) == "已暫停：主設備沒開",
              "W185 副設備：失聯提示信封到期時間，到期後明說已暫停")
        check(HandsBuildController.memberAvailability(permit: active, primary: "Mac mini", lastSync: now, now: now) == nil
              && HandsBuildController.memberAvailability(permit: .inactive(nil), primary: "Mac mini", lastSync: nil, now: now) == nil,
              "W185 主設備恢復或未啟用：不誤報失聯暫停")
        let refusal = HandsLocked(false)
        let refused = try fleet.add(bID, name: "fixture", callPrimary: { payload in
            if refusal.get() { throw RemoteHostLinkError.sshHomeLookupFailed("Connection reset by peer") }
            return try Fleet.wire(try HandsBuildRemote.handle(payload: try Fleet.wire(payload), sender: bID, authority: fleet.authority))
        })
        let refusedCard = HandsBuildController(dependencies: .init(
            sync: refused.sync, flow: HandsConnectFlow(), localID: { bID }, pairedDevices: { known },
            loginHere: {}, unlockHere: { _, _, _ in nil },
            revocation: .standard(service: refused.service, callPrimary: fleetPrimaryCall(fleet, sender: bID)),
            role: { refused.role }, openLogin: { _, _ in }, closeLogin: { _ in },
            background: { $0() }, now: { fleet.clock.now() }, uptime: { fleet.clock.uptime() }))
        refused.sync.syncNow()
        _ = await waitUntil(3) { refused.sync.lastSync != nil }
        refusal.set(true); fleet.clock.advance(HandsBuildEnvelopes.lifetime + 1)
        refused.sync.syncNow()
        _ = await waitUntil(3) { refusedCard.localAvailabilityText == "已暫停：主設備的遠端登入沒有回應" }
        check(refusedCard.localAvailabilityText == "已暫停：主設備的遠端登入沒有回應"
              && refused.sync.problem == "連不到主設備（主設備的遠端登入沒有回應）",
              "W311 副設備信封到期且 SSH 被拒：卡片不誤報主設備沒開", refusedCard.statusText)
        let old = HandsSetupStepState(status: .done, message: "運作中（舊資料）", updatedAt: now)
        let live = HandsSetup.liveStartStep(old, phase: .failed("暫時讀不到；12:34 自動重試"))
        check(live.status == .failed && live.message == "沒在跑：暫時讀不到；12:34 自動重試"
              && HandsSetup.liveStartStep(live, phase: .stopped) == live
              && HandsSetup.liveStartStep(old, phase: .running(url: "https://example.com/mcp")).message == "運作中",
              "W185 setup start 顯示採關口即時狀態，不沿用舊運作中")
    }
}
#endif
