import Foundation

/// W180 E1：記憶強度（關／淺／中／深，存成 off／light／medium／deep）。
/// 像選模型、選思考強度一樣，每條對話各自一檔；只管「每一句帶多少記憶、AI 要不要自己去翻」，不管記不記。
/// 設計正本：docs/plans/W179-通用記憶設計.md「記憶強度」。純邏輯，只用 Foundation（node 測試單獨編譯這支檔）。
enum TatwoMemoryStrength: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, light, medium, deep

    var id: String { rawValue }

    /// chip 上的一個字。
    var title: String {
        switch self {
        case .off: "關"
        case .light: "淺"
        case .medium: "中"
        case .deep: "深"
        }
    }

    /// 選單上那一句白話。
    var menuDetail: String {
        switch self {
        case .off: "不帶記憶"
        case .light: "只帶很相關的"
        case .medium: "帶相關的"
        case .deep: "先翻記憶再回答"
        }
    }

    /// 每一句最多附幾條候選。
    var maxItems: Int {
        switch self {
        case .off: 0
        case .light: 3
        case .medium: 8
        case .deep: 20
        }
    }

    /// 每一句附上的整段文字（說明＋候選）最多幾個字。
    var maxCharacters: Int {
        switch self {
        case .off: 0
        case .light: 400
        case .medium: 1200
        case .deep: 3000
        }
    }

    /// 候選要到這個分數才附（淺只收很相關的；分數怎麼算見 TatwoMemoryRecall）。
    var minimumScore: Double {
        switch self {
        case .off: .infinity
        case .light: 3.0
        case .medium: 1.6
        case .deep: 0.8
        }
    }

    /// 附在候選前面給 AI 的一句指示；「關」什麼都不送。
    var instruction: String? {
        switch self {
        case .off: nil
        case .light: "只附很相關的，不相關就忽略。"
        case .medium: "真的相關才用，要細節用 memory_get。"
        case .deep: "先用 memory_search 查，回答註明根據。"
        }
    }

    /// 這條對話的記憶強度。規則（設計 09-26、主導 W180 裁決）：
    /// Bot 一律「關」（也不顯示 chip）；派工房間預設「關」；子討論串跟母串；TATWO 助理預設「中」；Coder 預設「淺」。
    /// 有存過就照存的（Bot 除外）；存的值認不得就當沒存。
    static func resolve(stored: String?, isBot: Bool, isRoom: Bool, isAssistant: Bool,
                        parent: TatwoMemoryStrength?) -> TatwoMemoryStrength {
        if isBot { return .off }
        if let stored = stored.flatMap(TatwoMemoryStrength.init(rawValue:)) { return stored }
        if isRoom { return .off }
        if let parent { return parent }
        return isAssistant ? .medium : .light
    }

    /// 別台送來的值：只收四檔之一（字串、完全相同）；其他一律不收（nil）。
    static func accepting(_ value: Any?) -> TatwoMemoryStrength? {
        guard let raw = value as? String else { return nil }
        return TatwoMemoryStrength(rawValue: raw)
    }
}
