import SwiftUI

/// W184 H4（使用者 09-30：「輸入筐我認為要改成我們設計好的coder輸入筐 並且我想將全部同款的自研輸入筐優化 將記憶、模型、ultrawork、速度
/// 全部收進模式選擇裡，並在裡面可以個別挑選…最後套用在當前的所有自研輸入筐裡」）：一個輸入框的「模式選擇」。
/// chip 上一行摘要（ChatComposerChrome.swift 的 ChatComposerModeChip），點了開模式卡＝ULTRAWORK 卡擴充（TatwoComposerModeCard.swift）。
/// 這裡只描述「畫什麼、按了叫誰」：值照舊存在原本的地方（Coder＝ChatPageModel 與畫面的角色設定、私訊框＝GlobalDMStore／ChatPageModel、
/// Space 搭建＝SpaceSetupPreviewState.Domain）；每個按鈕叫的都是原本 chip／選單叫的那一個函式，所以送出時帶的模型、速度、推理強度、
/// 記憶、協作檔位跟改之前一樣（只換 UI）。
struct TatwoComposerMode {
    /// 一排檔位：S～XXL、速度、推理強度、記憶都用同一條填充式玻璃拉條（舊版 #24，TatwoComposerFilledTrack）。
    struct Steps {
        struct Option: Identifiable, Equatable {
            let id: String
            let title: String
        }

        let title: String
        let options: [Option]
        let selectedID: String?
        /// 標題右邊的一句白話（例：記憶「只帶很相關的」）。
        var detail: String? = nil
        var isEnabled = true
        /// 拉條下面的一行小字（例：在主設備上跑；選了跟下一句一起帶過去）。
        var note: String? = nil
        let identifier: String
        let choose: @MainActor (String) -> Void

        var selectedIndex: Int? { options.firstIndex { $0.id == selectedID } }
        var selectedTitle: String? { options.first { $0.id == selectedID }?.title }
        // Ultra 只能從清單明確選取，不能在滑鼠或鍵盤拉條上意外啟用。
        var sliderOptions: [Option] { options.filter { $0.id != TatwoCodexReasoningEffort.ultra.rawValue } }
        var sliderSelectedIndex: Int? { sliderOptions.firstIndex { $0.id == selectedID } }
        var hasUltra: Bool { options.contains { $0.id == TatwoCodexReasoningEffort.ultra.rawValue } }
    }

    /// ultrawork（協作）：S～XXL 拉條＋電源（關＝單模型 thread）。
    struct Collaboration {
        let level: ChatCollaborationLevel
        var isEnabled = true
        /// 拉條下面的一行小字（W184 H4 修正 #1：私訊框的 session「跟主視窗 Coder 同一個設定」、助理「不帶 ultrawork」、別台的照那台）。
        var note: String? = nil
        let setLevel: @MainActor (ChatCollaborationLevel) -> Void
    }

    /// 「身份與模型」的一列：單模型＝一列；ultrawork 開著＝主導、副審、sub 各一列。點了在卡裡換成那一列的模型清單。
    struct ModelRow: Identifiable {
        let id: String
        let role: String
        let tint: Color
        let title: String
        var detail: String? = nil
        let identifier: String
        var isEnabled = true
        let options: [ModelOption]
        let choose: @MainActor (String) -> Void
    }

    /// 模型清單的一列：照品牌分段；選中的打勾、下一輪才換的標時鐘、停用的引擎變淡不能選（同原本的選單）。
    struct ModelOption: Identifiable, Equatable {
        let id: String
        let title: String
        let brand: ChatRouteBrandGroup
        var isSelected = false
        var isDisabled = false
        var isPending = false
    }

    struct Badge: Equatable {
        let text: String
        var positive = false
    }

    struct Footnote: Equatable {
        let icon: String
        let text: String
    }

    /// chip 上的一段（模型・記憶・ultrawork）：每一段各自是一個可按的無障礙元素，沿用舊 chip 的識別碼；按哪一段都開同一張卡。
    struct Segment: Identifiable, Equatable {
        let id: String
        let text: String
        /// 窄的時候的字。W184 H4 修正（查核 #6）：窄的時候圖示照樣畫（看得出哪一段是 ultrawork）；空字串＝只剩圖示，沒有圖示才整段不畫。
        let short: String
        var icon: String? = nil
        let accessibilityLabel: String
        let identifier: String
        /// ultrawork 開著：強調色。
        var emphasized = false
        /// ultrawork 關著、記憶現在不能選：淡。
        var dimmed = false
    }

    var eyebrow: String
    var title: String
    var badge: Badge? = nil
    var collaboration: Collaboration? = nil
    var modelHeading = "身份與模型"
    var modelHint: String? = "點擊任一列更換"
    var models: [ModelRow]
    var modelNote: String? = nil
    var modelNoteAction: (@MainActor () -> Void)? = nil
    var speed: Steps? = nil
    var effort: Steps? = nil
    var memory: Steps? = nil
    var footnote: Footnote? = nil
    var segments: [Segment]
    var help = "模式選擇：模型、速度、記憶、ultrawork"

    static let identifier = "tatwo.composer.mode"
    static let cardIdentifier = "tatwo.composer.mode.card"
}

// MARK: - 共用的小規則

extension TatwoComposerMode {
    /// chip 上模型的短名：GPT 系列去掉「GPT-」（同 Coder 模型 chip：「6 fast」），其他照助理 chip 的短名（「Opus 5.5」「Fable 5.1」）。
    static func shortModelName(_ route: ChatRouteChoice) -> String {
        if route.runtimeAdapter == .chatgptTap { return route.commandLabel }
        if route.title.hasPrefix("GPT-") { return String(route.title.dropFirst("GPT-".count)) }
        return AssistantModelRouting.chipName(route)
    }

    /// 卡上的模型名：去掉「Claude 」品牌字，其他照友善名稱（「Opus 5.5」「GPT-6」「Fable 5.1」）。
    static func cardModelName(_ route: ChatRouteChoice) -> String {
        if route.runtimeAdapter == .chatgptTap { return route.title }
        var name = AssistantModelRouting.friendlyName(route)
        if name.hasPrefix("Claude ") { name.removeFirst("Claude ".count) }
        return name
    }

    /// 速度的字：fast 照舊、standard 寫「標準」（白話）。
    static func speedTitle(_ tier: TatwoModelSpeedTier) -> String {
        tier == .fast ? "fast" : "標準"
    }

    /// 所有路由照品牌分段（Coder 的模型清單：目前選的品牌排最前面，同原本的 Codex 式選單）。
    /// W184 H4 修正（審查 #9）：isDisabled＝這一輪實際在哪台跑、那台送不出這家（本機的照這台；別台上的不拿這台擋）：變淡、標「已停用」、不能選
    /// （同助理與私訊框的選單）。
    static func routeOptions(selectedID: String?, pendingID: String? = nil, deviceID: String = "local",
                             isDisabled: (ClaudeSidecar.Kind) -> Bool = { _ in false }) -> [ModelOption] {
        let selected = selectedID.map { ChatRouteChoice.resolve($0, deviceID: deviceID).id }
        return ChatRouteChoice.brandSections(selectedID: selectedID, deviceID: deviceID).flatMap { section in
            section.choices.map { choice in
                let disabled = AssistantModelRouting.engineKind(for: choice).map(isDisabled) ?? false
                let name = cardModelName(choice)
                return ModelOption(id: choice.id, title: disabled ? "\(name) · 已停用" : name, brand: section.brand,
                                   isSelected: choice.id == selected, isDisabled: disabled, isPending: choice.id == pendingID)
            }
        }
    }

    /// 助理與私訊框 session 的清單（同原本的系統選單：品牌照 pickerOrder、停用的引擎標「已停用」不能選）。
    static func assistantOptions(_ options: [AssistantModelOption]) -> [ModelOption] {
        ChatRouteBrandGroup.pickerOrder.flatMap { brand in
            options.filter { $0.route.brandGroup == brand }.map { option in
                ModelOption(id: option.route.id, title: option.title, brand: brand,
                            isSelected: option.isSelected, isDisabled: option.isDisabled)
            }
        }
    }

    static func speedSteps(route: ChatRouteChoice, selected: TatwoModelSpeedTier?,
                           isEnabled: Bool = true,
                           choose: @escaping @MainActor (TatwoModelSpeedTier) -> Void) -> Steps? {
        guard route.supportsNativeSpeedControl else { return nil }
        return Steps(title: "速度", options: route.allowedSpeedTiers.map { Steps.Option(id: $0.rawValue, title: speedTitle($0)) },
                     selectedID: selected?.rawValue, isEnabled: isEnabled, identifier: "tatwo.composer.mode.speed",
                     choose: { raw in if let tier = TatwoModelSpeedTier(rawValue: raw) { choose(tier) } })
    }

    /// W184 H4 修正（審查 #1）：推理強度真的會送到引擎嗎——只有 Codex 系的每一輪帶 effort（ChatPageModel.send、sendFromDM、
    /// ClaudeSidecar.sendCommand）；Claude、Grok 的 sidecar 還不收。卡上照「實際會送到那個引擎的能力」決定能不能調。
    static func forwardsEffort(_ route: ChatRouteChoice) -> Bool {
        AssistantModelRouting.engineKind(for: route) == .codex
            || (route.runtimeAdapter == .claudeCLI && route.profile.hasEngineCapabilityReport)
    }
    static let effortNotForwarded = "這個模型的引擎還不收推理強度，照它自己的預設"
    static let ultraWarning = "會自動分派子代理，較耗額度"

    static func collaborationEffort(_ level: ChatCollaborationLevel, route: ChatRouteChoice) -> TatwoCodexReasoningEffort? {
        guard forwardsEffort(route) else { return nil }
        let requested: TatwoCodexReasoningEffort
        switch level {
        case .off: return nil
        case .s: requested = .low
        case .m: requested = .medium
        case .l: requested = .high
        case .xl: requested = .xhigh
        case .xxl: requested = route.allowedEfforts.contains(.max) ? .max : .xhigh
        }
        return route.profile.nativeReasoningEffort(for: requested)
    }

    /// selected＝nil：這一台不知道（別台上跑的，照那台的設定）：拉條不亮。
    /// 引擎不收推理強度（非 Codex）：照樣列出、變淡、寫一句原因——不亮著卻不送。
    static func effortSteps(route: ChatRouteChoice, selected: TatwoCodexReasoningEffort?,
                            isEnabled: Bool = true,
                            choose: @escaping @MainActor (TatwoCodexReasoningEffort) -> Void) -> Steps? {
        guard route.supportsNativeReasoningControl else { return nil }
        let options = route.allowedEfforts.map { Steps.Option(id: $0.rawValue, title: $0.displayName) }
        guard forwardsEffort(route) else {
            return Steps(title: "推理強度", options: options, selectedID: nil, isEnabled: false, note: effortNotForwarded,
                         identifier: "tatwo.composer.mode.effort", choose: { _ in })
        }
        return Steps(title: "推理強度", options: options,
                     selectedID: route.profile.compatibleReasoningValue(selected?.rawValue), isEnabled: isEnabled,
                     note: route.profile.reasoningDowngradeNotice(for: selected?.rawValue),
                     identifier: "tatwo.composer.mode.effort",
                     choose: { raw in
                         if let effort = TatwoCodexReasoningEffort(rawValue: raw), route.allowedEfforts.contains(effort) { choose(effort) }
                     })
    }

    /// 記憶：關／淺／中／深（同原本的記憶選單）；別台上的那條說明「選了跟下一句一起帶過去」；接不到那台時變淡不能選。
    static func memorySteps(_ state: TatwoMemoryChipState,
                            choose: @escaping @MainActor (TatwoMemoryStrength) -> Void) -> Steps {
        Steps(title: "記憶", options: TatwoMemoryStrength.allCases.map { Steps.Option(id: $0.rawValue, title: $0.title) },
              selectedID: state.strength.rawValue, detail: state.strength.menuDetail, isEnabled: state.isEnabled,
              note: state.remotePlace == nil ? nil : state.headline, identifier: "tatwo.composer.mode.memory",
              choose: { raw in if let strength = TatwoMemoryStrength(rawValue: raw) { choose(strength) } })
    }

    /// W184 H4 修正（查核 #6）：窄的時候寫「記淺」「記中」（看得出是記憶，不是只剩一個「淺」）；關著照舊「記憶關」不縮
    /// （只寫「關」會讀成前面那一段關掉了）。
    static func memorySegment(_ state: TatwoMemoryChipState) -> Segment {
        Segment(id: "memory", text: "記憶\(state.strength.title)",
                short: memoryShort(state.strength),
                accessibilityLabel: "記憶強度：\(state.strength.title)", identifier: "tatwo-memory-strength",
                dimmed: !state.isEnabled)
    }

    static func memoryShort(_ strength: TatwoMemoryStrength) -> String {
        strength == .off ? "記憶\(strength.title)" : "記\(strength.title)"
    }

    /// 窄的時候：開著＝圖示＋檔位（「L」），關著＝只剩淡淡的圖示（圖示照樣畫，見 Segment.short）。
    static func collaborationSegment(_ level: ChatCollaborationLevel, identifier: String) -> Segment {
        let active = level != .off
        return Segment(id: "ultrawork", text: active ? "ultrawork \(level.title)" : "ultrawork",
                       short: active ? level.title : "",
                       icon: active ? "point.3.connected.trianglepath.dotted" : "target",
                       accessibilityLabel: active ? "ultrawork：\(level.title)" : "ultrawork：關",
                       identifier: identifier, emphasized: active, dimmed: !active)
    }

    static func collaborationTitle(_ level: ChatCollaborationLevel) -> String {
        level != .off ? "\(level.title) 協作編制" : "單模型模式"
    }

    /// 「模型」那一段：模型短名＋速度（模型有速度檔時），沒有速度就接推理強度（同原本 Coder 模型 chip 的第二個字）。
    /// label＝無障礙名稱的開頭（預設「模型」；TATWO 助理頁沿用原本模型 chip 的「助理的模型」）。
    static func modelSegment(title: String, suffix: String?, accessibilityTitle: String, identifier: String,
                             dimmed: Bool = false, label: String = "模型") -> Segment {
        let text = [title, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return Segment(id: "model", text: text, short: title, accessibilityLabel: "\(label)：\(accessibilityTitle)",
                       identifier: identifier, dimmed: dimmed)
    }
}

// MARK: - Coder（主視窗）

extension TatwoComposerMode {
    /// 換 Coder 的模型：同原本模型面板（selectRouteChoice）——換路由之後，推理強度、速度不在新模型允許的檔位裡就換成它的預設。
    @MainActor
    static func applyCoderRoute(_ choice: ChatRouteChoice, to model: ChatPageModel) {
        model.setSingleModel(choice.id, syncCollaborationLead: model.collaborationLevel != .off)
        if choice.supportsNativeReasoningControl, !choice.allowedEfforts.contains(model.selectedEffort) {
            if model.selectedEffort == .max || model.selectedEffort == .ultra {
                // 回覆中換模型會排到下一輪，selectedModel 此時仍是舊路由。
                if let notice = choice.profile.reasoningDowngradeNotice(for: model.selectedEffort.rawValue) { model.flashComposerHint(notice) }
                model.selectedEffort = choice.profile.nativeReasoningEffort(for: model.selectedEffort) ?? choice.defaultEffort
            } else {
                model.selectedEffort = choice.defaultEffort
            }
        }
        if choice.supportsNativeSpeedControl, !choice.allowedSpeedTiers.contains(model.selectedSpeedTier) {
            model.selectedSpeedTier = choice.defaultSpeedTier ?? choice.allowedSpeedTiers.first ?? .fast
        }
    }

    /// Coder 輸入框：ultrawork（S～XXL＋角色）、模型、速度、推理強度、記憶（只在 Coder 對話；CLI、Bot 串不顯示）。
    /// `ultraworkOnly`：Plan 畫布裡的 ULTRAWORK 卡只放協作那幾區（同原本那張卡）。
    /// W184 H4 修正（GPT-6 H4 審查）：
    /// - #3：檔位與角色＝Coder 開著的那一條自己記住的（ChatPageModel.ultraworkSettings(for:)；私訊框開同一條才一起變）。
    /// - #1：推理強度只有真的會送到的引擎（Codex 系）能調；其他引擎照樣列出、變淡、寫原因（effortSteps）。chip 也不再寫送不出去的推理強度。
    /// - #9：模型清單（含每一個角色的清單）照這一輪實際在哪台跑標停用（coderRouteBlocked：本機照這台；走主設備的不拿這台擋）。
    @MainActor
    static func coder(model: ChatPageModel,
                      roleModelID: @escaping @MainActor (UltraworkRoleSlot) -> String,
                      chooseRole: @escaping @MainActor (ChatRouteChoice, UltraworkRoleSlot) -> Void,
                      chooseModel: @escaping @MainActor (ChatRouteChoice) -> Void,
                      ultraworkOnly: Bool = false) -> TatwoComposerMode {
        let route = model.routeChoice
        let level = model.ultraworkSettings(for: model.selectedThreadID).collaborationLevel
        let planMode = model.isPlanModeEnabled
        var rows: [ModelRow] = []
        // 「模型」＝這條 thread 送出時真的用的模型（selectedModel；下面的速度、推理強度調的就是它）。
        // W184 H4 修正（查核 #8）：ultrawork 開著也列、排在角色前面——主導／副審／sub 只寫進這一輪的 ultrawork 設定，
        // 換它們不會換掉這一輪用的模型（同原本：ultrawork 開著時模型 chip 照樣在，按了走 selectRouteChoice）。
        // 查核 #10：Plan 畫布那張（ultraworkOnly）照原本那張卡，沒有這一列（計畫階段不在那裡換執行的模型）。
        if !ultraworkOnly {
            let pending = model.pendingRouteChoice.flatMap { $0.id == route.id ? nil : $0 }
            rows.append(ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent, title: cardModelName(route),
                                 detail: pending.map { "下一輪 \(cardModelName($0))" } ?? route.id,
                                 identifier: "tatwo.composer.mode.model",
                                 options: routeOptions(selectedID: model.selectedModel, pendingID: model.pendingModelID, deviceID: model.modelSelectionDeviceID,
                                                       isDisabled: { model.coderRouteBlocked($0) }),
                                 choose: { id in chooseModel(ChatRouteChoice.resolve(id, deviceID: model.modelSelectionDeviceID)) }))
        }
        if level != .off {
            rows += roleRows(level: level, roleModelID: roleModelID, chooseRole: chooseRole,
                             isDisabled: { model.coderRouteBlocked($0) })
        }
        var mode = TatwoComposerMode(eyebrow: "ULTRAWORK", title: collaborationTitle(level),
                                     badge: planMode ? Badge(text: "PLAN · 唯讀") : Badge(text: "確認後 · 可執行", positive: true),
                                     collaboration: Collaboration(level: level) {
                                         model.setCollaborationLevel($0)
                                         if let effort = collaborationEffort($0, route: model.routeChoice) { model.selectedEffort = effort }
                                     },
                                     models: rows,
                                     footnote: planMode
                                        ? Footnote(icon: "lock.fill", text: "Plan 階段不寫檔；確認 Goal 後才投影受控工作目錄。")
                                        : Footnote(icon: "checkmark.shield.fill", text: "執行權限綁定 Goal、角色與受控輸出根。"),
                                     segments: [])
        if let place = model.coderRemotePlace, !ultraworkOnly {
            mode.modelNote = "在\(place)上跑：模型能不能用照那台"
        }
        let memory = model.mode == .chat ? model.memoryChipState(.coder) : nil
        if !ultraworkOnly {
            mode.speed = speedSteps(route: route, selected: model.selectedSpeedTier) { model.selectedSpeedTier = $0 }
            mode.effort = effortSteps(route: route, selected: model.selectedEffort) { model.selectedEffort = $0 }
            if let memory {
                mode.memory = memorySteps(memory) { model.setMemoryStrength($0, for: .coder) }
            }
        }
        // chip 上模型後面接的字：有速度檔寫速度；沒有就寫推理強度——只有真的會送到的（Codex 系）才寫（審查 #1）。
        let suffix: String? = route.supportsNativeSpeedControl ? speedTitle(model.selectedSpeedTier)
            : (route.supportsNativeReasoningControl && forwardsEffort(route) ? model.selectedEffort.compactDisplayName : nil)
        var segments = [modelSegment(title: shortModelName(route), suffix: suffix,
                                     accessibilityTitle: [route.runtimeAdapter == .chatgptTap ? route.commandLabel : route.title, suffix].compactMap { $0 }.joined(separator: " "),
                                     identifier: "chat-composer-model")]
        if let memory { segments.append(memorySegment(memory)) }
        segments.append(collaborationSegment(level, identifier: "chat-composer-ultrawork"))
        mode.segments = segments
        mode.help = level != .off ? "模式選擇：Ultrawork 協作保持 \(level.title)；模型、速度、記憶也在這裡" : "模式選擇：模型、速度、記憶、Ultrawork"
        return mode
    }

    /// ultrawork 開著時「身份與模型」的角色列：主導、副審、每一個 sub（照檔位的人數；每一列點了換成那一列的模型清單）。
    /// Coder 與私訊框的 session 共用（W184 H4 修正：審查 #5——整份角色都列、都記、都送）。
    @MainActor
    static func roleRows(level: ChatCollaborationLevel,
                         roleModelID: @escaping @MainActor (UltraworkRoleSlot) -> String,
                         chooseRole: @escaping @MainActor (ChatRouteChoice, UltraworkRoleSlot) -> Void,
                         isDisabled: (ClaudeSidecar.Kind) -> Bool,
                         isEnabled: Bool = true) -> [ModelRow] {
        let slots: [UltraworkRoleSlot] = [.primary]
            + (0..<UltraworkRoleConfiguration.auxiliaryCount(for: level)).map { UltraworkRoleSlot.auxiliary($0) }
        return slots.map { slot in
            let modelID = roleModelID(slot)
            let chosen = ChatRouteChoice.resolve(modelID)
            let role: String, tint: Color
            switch slot {
            case .primary: role = "主導"; tint = LiquidGlassTokens.brandAccent
            case let .auxiliary(index): role = index == 0 ? "副審" : "sub"; tint = index == 0 ? .orange : .secondary
            }
            return ModelRow(id: "role-\(slot.label)", role: role, tint: tint, title: cardModelName(chosen),
                            detail: modelID,
                            identifier: slot == .primary ? "ultrawork-role-primary" : "ultrawork-role-\(slot.label)",
                            isEnabled: isEnabled,
                            options: routeOptions(selectedID: modelID, isDisabled: isDisabled),
                            choose: { id in chooseRole(ChatRouteChoice.resolve(id), slot) })
        }
    }
}

// MARK: - 私訊框（助理、Coder session；ChatGPT 對象的輸入框照 ChatGPT 原版，不在這裡）

extension TatwoComposerMode {
    /// 私訊框：模型（同原本的模型 chip：助理的選單、那條 session 的選單；回覆中、那台連不上時不能換）＋記憶（ChatGPT、Bot 串不顯示）。
    /// W184 H4 修正（查核 #1）：送出時真的帶的也收進來，照送出的那條路列或不列——
    /// - 速度、推理強度：本機那一條記住的偏好（助理 sendToLocalAssistant、session sendFromDM 讀 requestedSpeedTier／requestedEffort，
    ///   只有 Codex 系的模型帶）；改了寫回那一條（setModelPreferences，同 setAssistantModel／setDMSessionModel 那條路）。
    ///   引擎不收推理強度（非 Codex）：照樣列出、變淡、寫原因（GPT-6 審查 #1，跟 Coder 同一套）。
    /// - ultrawork（GPT-6 審查 #3、#5）：Coder session（本機或別台）送出時帶「那一條自己記住的」檔位與角色（sendFromDM／deliver 帶那條的），
    ///   所以卡上列、改的也是那一條的；私訊框與主視窗開的是同一條才一起變，不同條互不影響。角色（主導、副審、每一個 sub）也列、也改。
    ///   助理的送出不帶 ultrawork：拉條照樣看得到、變淡、寫原因；那台連不上時也變淡、寫原因。
    /// - 別台上跑的（接主設備的助理、別台的 session）：這一台送出只帶模型，速度、推理強度照那台的設定：照樣列出、變淡、寫明。
    @MainActor
    static func dm(store: GlobalDMStore) -> TatwoComposerMode? {
        let target = store.target
        guard target != .chatGPT else { return nil }
        let title = store.modelChipTitle
        let canChoose = store.canChooseModel
        let options = assistantOptions(store.modelOptions(for: target))
        let selected = options.first(where: \.isSelected)
        let row = ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent, title: title,
                           detail: selected?.id, identifier: "tatwo.composer.mode.model", isEnabled: canChoose,
                           options: options, choose: { [weak store] id in store?.chooseModel(id, for: target) })
        var sessionID: UUID?
        if case .thread(let id) = target { sessionID = id }
        let model = store.model
        let local = model.flatMap { TatwoComposerMode.dmLocalThread(model: $0, target: target) }
        let elsewhere = dmElsewhere(model: model, target: target)
        let reachable = sessionID.map { id in model?.canSetUltrawork(for: id) == true } ?? false
        let level: ChatCollaborationLevel = reachable
            ? (sessionID.flatMap { id in model?.ultraworkSettings(for: id).collaborationLevel } ?? .off) : .off
        var mode = TatwoComposerMode(eyebrow: "ULTRAWORK",
                                     title: sessionID == nil ? "TATWO 助理" : (reachable ? collaborationTitle(level) : "這條對話"),
                                     models: [row], segments: [])
        mode.modelHeading = "模型"
        mode.modelNote = canChoose ? store.modelHeadline(for: target) : store.modelChipHelp
        if let model, let id = sessionID, reachable {
            let sameAsCoder = model.selectedThreadID == id
            mode.collaboration = Collaboration(level: level,
                                               note: sameAsCoder ? "這條也開在主視窗 Coder：兩邊一起變" : "只改這一條對話") { [weak model] in
                model?.setUltraworkLevel($0, for: id)
                if let model, let local, let record = model.localLiveForBridge?.threadRecord(local) {
                    let route = ChatRouteChoice.resolve(record.requestedModel ?? record.model ?? "gpt-6.1-sol")
                    if let effort = collaborationEffort($0, route: route) {
                        dmSetPreferences(model: model, threadID: local, route: route, speed: nil, effort: effort)
                    }
                }
            }
            if level != .off {
                mode.modelHeading = "身份與模型"
                mode.models += roleRows(level: level,
                                        roleModelID: { [weak model] slot in model?.ultraworkRoleModelID(slot, for: id) ?? "" },
                                        chooseRole: { [weak model] choice, slot in
                                            model?.setUltraworkRole(choice.canonicalModelSlug, slot: slot, for: id)
                                        },
                                        isDisabled: { kind in local != nil && model.isEngineDisabled(kind) })
            }
        } else {
            mode.collaboration = Collaboration(level: .off, isEnabled: false,
                                               note: sessionID != nil ? "\(elsewhere)：那台連上後才能改 ultrawork" : "助理不使用 ultrawork",
                                               setLevel: { _ in })
        }
        var suffix: String? = nil
        if let route = store.modelOptions(for: target).first(where: \.isSelected)?.route {
            if AssistantModelRouting.engineKind(for: route) == .codex {
                // W184 H4b：這一段搬到 applyPreferenceSteps（TATWO 助理頁的 assistantSpace 共用，內容一字不變）。
                suffix = applyPreferenceSteps(to: &mode, model: model, local: local, route: route, canChoose: canChoose, elsewhere: elsewhere)
            } else {
                mode.effort = effortSteps(route: route, selected: nil) { _ in }   // 引擎不收：變淡、寫原因（審查 #1）
            }
        }
        var segments = [modelSegment(title: title, suffix: suffix,
                                     accessibilityTitle: [title, suffix].compactMap { $0 }.joined(separator: " "),
                                     identifier: "tatwo.dm.model", dimmed: !canChoose)]
        if let model, let memoryTarget = GlobalDMMemoryChip.target(target),
           let state = model.memoryChipState(memoryTarget) {
            mode.memory = memorySteps(state) { [weak model] in model?.setMemoryStrength($0, for: memoryTarget) }
            segments.append(memorySegment(state))
        }
        if reachable {
            segments.append(collaborationSegment(level, identifier: "tatwo.dm.ultrawork"))
        }
        mode.segments = segments
        mode.help = store.modelChipHelp
        return mode
    }

    /// 私訊框這個對象在這一台上的那一條（本機跑的助理、本機的 session）；別台上跑的（接主設備的助理、別台的 session）＝nil。
    @MainActor
    static func dmLocalThread(model: ChatPageModel, target: GlobalDMTarget) -> UUID? {
        guard let engine = model.localLiveForBridge else { return nil }
        switch target {
        case .assistant:
            guard case .local = model.assistantPlacement, let id = model.assistantThreadID,
                  engine.threadRecord(id) != nil else { return nil }
            return id
        case .thread(let id):
            return engine.threadRecord(id) != nil ? id : nil
        case .chatGPT:
            return nil
        }
    }

    /// 在哪一台上跑（「在主設備「Primary One」上跑」「在「Second Two」上跑」）；說不出是哪台＝「在別台上跑」。
    @MainActor
    static func dmElsewhere(model: ChatPageModel?, target: GlobalDMTarget) -> String {
        switch target {
        case .assistant:
            if let name = model?.assistantPrimaryName { return "在主設備「\(name)」上跑" }
        case .thread(let id):
            if let remote = model?.dmRemote(for: id) { return "在\(remote.place)上跑" }
        case .chatGPT:
            break
        }
        return "在別台上跑"
    }

    /// 私訊框改這一條的速度或推理強度：寫回那一條的偏好（setModelPreferences；模型照那一條記住的，沒記過就記下現在送出會用的那個）。
    /// 回覆中不改（同 setAssistantModel／setDMSessionModel）；那條正好是 Coder 開著的那條時，Coder 的輸入框跟著重讀（同 setDMSessionModel）。
    @MainActor
    static func dmSetPreferences(model: ChatPageModel, threadID: UUID, route: ChatRouteChoice,
                                 speed: TatwoModelSpeedTier?, effort: TatwoCodexReasoningEffort?) {
        guard let engine = model.localLiveForBridge, !engine.isRunning(threadID),
              let record = engine.threadRecord(threadID) else { return }
        let tier = speed ?? record.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:)) ?? route.defaultSpeedTier ?? .fast
        let reasoning = effort ?? record.requestedEffort.flatMap(TatwoCodexReasoningEffort.init(rawValue:)) ?? route.defaultEffort
        if let notice = route.profile.reasoningDowngradeNotice(for: reasoning.rawValue) { model.flashComposerHint(notice) }
        engine.setModelPreferences(threadID: threadID, model: record.requestedModel ?? route.id,
                                   effort: route.profile.compatibleReasoningValue(reasoning.codexRawValue) ?? route.defaultEffort.codexRawValue,
                                   speedTier: tier.rawValue)
        if model.selectedRemote == nil, model.selectedThreadID == threadID { model.restoreModelPreferences() }
        model.objectWillChange.send()
    }
}

// MARK: - TATWO 助理頁（Assistant/AssistantSpacePane.swift 的輸入框）

extension TatwoComposerMode {
    /// TATWO 助理頁的輸入框（W184 H4b，使用者 09-30：「將記憶、模型、ultrawork、速度全部收進模式選擇裡…套用在當前的所有自研輸入筐裡」）。
    /// 助理頁的助理跟私訊框的助理是同一條、同一條送出路徑（sendToAssistant），所以規則照 dm(store:) 的助理那一支，
    /// 只是直接讀 ChatPageModel（助理頁沒有 GlobalDMStore）；每個按鈕叫的都是原本助理頁 chip 叫的那一個函式（只換 UI）：
    /// - 模型：原本的模型 chip（AssistantModelMenu）——清單＝assistantModelOptions（本機跑時被停用的引擎標「已停用」不能選）、
    ///   選了走 setAssistantModel、回覆中（assistantIsRunning）不能換；接在主設備時卡上寫「在主設備「…」上跑」。
    /// - 速度、推理強度：助理那一條記住的偏好（送出時讀的欄位；只有 Codex 系的模型帶）；接主設備時照那台的設定：照樣列出、變淡、寫明。
    /// - 記憶：助理那一條（memoryChipState(.assistant)）；連不上主設備時變淡不能選。
    /// - ultrawork：助理不帶（拉條照樣看得到、變淡、寫原因）。
    /// 識別碼沿用助理頁原本的：模型那段 tatwo-assistant-model（無障礙名稱「助理的模型：…」）、記憶那段 tatwo-memory-strength。
    @MainActor
    static func assistantSpace(model: ChatPageModel) -> TatwoComposerMode {
        let canChoose = !model.assistantIsRunning
        let title = model.assistantModelChipTitle
        let options = assistantOptions(model.assistantModelOptions)
        let selected = options.first(where: \.isSelected)
        let row = ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent, title: title,
                           detail: selected?.id, identifier: "tatwo.composer.mode.model", isEnabled: canChoose,
                           options: options, choose: { [weak model] id in model?.setAssistantModel(id) })
        var mode = TatwoComposerMode(eyebrow: "ULTRAWORK", title: "TATWO 助理", models: [row], segments: [])
        mode.modelHeading = "模型"
        mode.modelNote = canChoose ? model.assistantPrimaryName.map { "在主設備「\($0)」上跑；沒選就照那邊的設定" } : "回覆中不換模型"
        mode.collaboration = Collaboration(level: .off, isEnabled: false,
                                           note: "助理不使用 ultrawork", setLevel: { _ in })
        var suffix: String? = nil
        if let route = model.assistantModelOptions.first(where: \.isSelected)?.route {
            if AssistantModelRouting.engineKind(for: route) == .codex {
                suffix = applyPreferenceSteps(to: &mode, model: model,
                                              local: dmLocalThread(model: model, target: .assistant),
                                              route: route, canChoose: canChoose,
                                              elsewhere: dmElsewhere(model: model, target: .assistant))
            } else {
                mode.effort = effortSteps(route: route, selected: nil) { _ in }   // 引擎不收：變淡、寫原因（審查 #1；同私訊框）
            }
        }
        var segments = [modelSegment(title: title, suffix: suffix,
                                     accessibilityTitle: [title, suffix].compactMap { $0 }.joined(separator: " "),
                                     identifier: "tatwo-assistant-model", dimmed: !canChoose, label: "助理的模型")]
        if let state = model.memoryChipState(.assistant) {
            mode.memory = memorySteps(state) { [weak model] in model?.setMemoryStrength($0, for: .assistant) }
            segments.append(memorySegment(state))
        }
        mode.segments = segments
        mode.help = canChoose ? "助理的模型，不更動 Coder" : "回覆中不換模型"
        return mode
    }

    /// 助理與私訊框 session 的「速度、推理強度」兩排（Codex 系的模型才有；送出時讀的是那一條記住的偏好）。
    /// 本機那一條：列出它記的值，改了寫回那一條（dmSetPreferences）；回覆中不能改（canChoose）。
    /// 別台上跑的（接主設備的助理、別台的 session）：這一台送出只帶模型，所以照樣列出、變淡、寫明「照那台的設定」。
    /// 回傳 chip 上模型後面接的字（有速度檔的模型寫速度，沒有就寫推理強度；別台上的不寫）。私訊框（dm）與助理頁（assistantSpace）共用。
    @MainActor
    fileprivate static func applyPreferenceSteps(to mode: inout TatwoComposerMode, model: ChatPageModel?, local: UUID?,
                                                 route: ChatRouteChoice, canChoose: Bool, elsewhere: String) -> String? {
        if let model, let local, let record = model.localLiveForBridge?.threadRecord(local) {
            let tier = record.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:)) ?? route.defaultSpeedTier ?? .fast
            let effort = record.requestedEffort.flatMap(TatwoCodexReasoningEffort.init(rawValue:)) ?? route.defaultEffort
            let write: @MainActor (TatwoModelSpeedTier?, TatwoCodexReasoningEffort?) -> Void = { [weak model] newTier, newEffort in
                guard let model else { return }
                TatwoComposerMode.dmSetPreferences(model: model, threadID: local, route: route, speed: newTier, effort: newEffort)
            }
            mode.speed = speedSteps(route: route, selected: tier, isEnabled: canChoose) { write($0, nil) }
            mode.effort = effortSteps(route: route, selected: effort, isEnabled: canChoose) { write(nil, $0) }
            return route.supportsNativeSpeedControl ? speedTitle(tier)
                : (route.supportsNativeReasoningControl ? effort.compactDisplayName : nil)
        }
        mode.speed = speedSteps(route: route, selected: nil, isEnabled: false) { _ in }
        mode.effort = effortSteps(route: route, selected: nil, isEnabled: false) { _ in }
        let note = "\(elsewhere)：速度、推理強度照那台的設定"
        if mode.effort != nil { mode.effort?.note = note } else { mode.speed?.note = note }
        return nil
    }
}

// MARK: - Space 搭建（UI 預覽＋正式搭建）

extension TatwoComposerMode {
    /// Space 搭建的輸入框：同原本兩顆選單——預覽時模型、推理強度、速度、協作都只改畫面上的選擇（不連模型、不啟動協作）；
    /// 正式搭建時協作不能選、推理強度與速度不列，選了 Bot 之後模型沿用 Bot（不能選）。記憶不在這裡（只在 Coder）。
    /// blocked：這台送不出的引擎（nil＝照這台的「不用 API 金鑰」設定算；自測直接給）。
    @MainActor
    static func spaceSetup(domain: SpaceSetupPreviewState.Domain, blocked: Set<ClaudeSidecar.Kind>? = nil) -> TatwoComposerMode {
        let route = domain.composerRoute
        let production = domain.isProduction
        let usesBot = production && !domain.chosenBotID.isEmpty
        // 正式搭建不帶協作：卡與 chip 都照「關」畫（預覽時選的檔位留著，回到預覽照舊）。
        let level: ChatCollaborationLevel = production ? .off : domain.composerCollaboration
        // W184 H4 修正（審查 #9）：正式搭建在這台跑（SpaceSubmission：本機、不接遠端），送不出的那家照這台標停用；預覽不連模型，不標。
        let blockedHere: Set<ClaudeSidecar.Kind> = !production ? []
            : blocked ?? Set(ClaudeSidecar.Kind.allCases.filter { EngineDisableStore.blocksSend($0, allowStale: true) })
        let row = ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent,
                           title: usesBot ? "Bot 設定" : cardModelName(route), detail: usesBot ? nil : route.id,
                           identifier: "tatwo.composer.mode.model", isEnabled: !usesBot,
                           options: routeOptions(selectedID: route.id, isDisabled: { blockedHere.contains($0) }),
                           choose: { [weak domain] id in domain?.selectComposerRoute(id) })
        // W184 H4 修正（審查 #1、#2）：正式搭建的送出不帶協作：拉條照樣看得到、變淡、寫一句原因（不亮著卻不送）。
        var mode = TatwoComposerMode(eyebrow: "ULTRAWORK", title: collaborationTitle(level),
                                     badge: production ? nil : Badge(text: "UI 預覽"),
                                     collaboration: Collaboration(level: level, isEnabled: !production,
                                                                  note: production ? "搭建需求不帶 ultrawork" : nil) { [weak domain] in
                                         domain?.composerCollaboration = $0
                                         if let effort = collaborationEffort($0, route: route) { domain?.composerEffort = effort }
                                     },
                                     models: [row], segments: [])
        if !production {
            mode.speed = speedSteps(route: route, selected: domain.composerSpeed) { [weak domain] in domain?.composerSpeed = $0 }
            mode.effort = effortSteps(route: route, selected: domain.composerEffort) { [weak domain] in domain?.composerEffort = $0 }
            mode.footnote = Footnote(icon: "eye", text: "UI 預覽：不連接模型、不啟動協作任務、不變更 Bot")
        } else if usesBot {
            mode.modelNote = "模型沿用選好的 Bot"
        }
        let modelTitle = usesBot ? "Bot 設定" : route.title.replacingOccurrences(of: "GPT-", with: "")
        let suffix: String?
        if production {
            suffix = nil
        } else if route.supportsNativeSpeedControl {
            suffix = domain.composerSpeed.map { speedTitle($0) }
        } else {
            // 審查 #1：推理強度只有真的會送到的引擎才寫在 chip 上（同 Coder）。
            suffix = route.supportsNativeReasoningControl && forwardsEffort(route) ? domain.composerEffort.compactDisplayName : nil
        }
        mode.segments = [modelSegment(title: modelTitle, suffix: suffix, accessibilityTitle: modelTitle,
                                      identifier: "space-composer-model"),
                         collaborationSegment(level, identifier: "space-composer-ultrawork")]
        mode.help = production ? "模式選擇：模型（搭建需求送出時用它）" : "模式選擇：UI 預覽，不連接模型或啟動協作"
        return mode
    }
}

// MARK: - Bot Studio（展示，未接入）

extension TatwoComposerMode {
    /// Bot Studio 的輸入框是展示（原本模型、派工方式兩顆按了都沒作用）：卡上照樣列出這隻用的模型與派工方式，一律不能改。
    /// 記憶不顯示（Bot 不帶使用者的記憶）；也沒有 S～XXL（Bot 的派工方式不是 ultrawork 檔位）。
    static func botStudio(modelLabel: String, modelTier: String, scopeLabel: String) -> TatwoComposerMode {
        let row = ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent, title: modelLabel,
                           detail: modelTier, identifier: "tatwo.composer.mode.model", isEnabled: false,
                           options: [], choose: { _ in })
        // W184 H4 修正（查核 #7）：派工方式只有展示的這一檔，畫成跟「模型」同款的停用列——不用只有一格的拉條
        // （一格＝整條填滿，看起來就是一顆方塊按鈕）；真的選項（自己做、找群一起…）接上之前不編出來。
        let scope = ModelRow(id: "scope", role: "派工", tint: Color.secondary, title: scopeLabel,
                             identifier: "tatwo.composer.mode.scope", isEnabled: false, options: [], choose: { _ in })
        var mode = TatwoComposerMode(eyebrow: "模式選擇", title: scopeLabel, badge: Badge(text: "展示"),
                                     models: [row, scope], segments: [])
        mode.modelHeading = "模型與派工方式"
        mode.modelHint = nil
        mode.modelNote = "展示・切換未生效"
        mode.footnote = Footnote(icon: "sparkles", text: "Gen-5 展示・未接入：送出不會真的派工")
        mode.segments = [modelSegment(title: modelLabel, suffix: modelTier, accessibilityTitle: "\(modelLabel) \(modelTier)",
                                      identifier: "bot-composer-model"),
                         Segment(id: "scope", text: scopeLabel, short: scopeLabel, icon: "circle.circle",
                                 accessibilityLabel: "派工方式：\(scopeLabel)", identifier: "bot-composer-scope")]
        mode.help = "這隻用哪個模型、自己做還是找群一起（展示・切換未生效）"
        return mode
    }
}
