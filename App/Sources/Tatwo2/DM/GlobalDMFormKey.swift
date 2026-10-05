import Foundation

// W184 F45（使用者 09-29 晚：「切換型態從command option tab改成command s」→ 改口「我看快捷改讓人自定義好了 不要讓ai費工了」）：
// 換形態的鍵＝⌥⌘＋一個鍵，使用者在私訊框的直達鍵頁（GlobalDMDirectKeyPage 的「換形態」那一列）自己設；預設 Tab（沒改過的人照舊 ⌥⌘Tab）。
// 同一套規則、同一套錄鍵：只收英文字母或數字（外加回到預設的 Tab）、系統保留鍵不能選、不能跟任何直達鍵同一顆（兩個方向都擋：
// 直達鍵那一邊在 GlobalDMDirectKeyRules.verdict 照目前換形態的鍵擋）。註冊照舊只在私訊框看得到時（GlobalDMHotKeys.refresh）。

/// 換形態的鍵怎麼存、怎麼讀、能不能選（純邏輯，好測）。
enum GlobalDMFormKeyBook {
    /// UserDefaults 裡只存鍵名（例如 "S"）；沒存＝預設 Tab。
    static let storageKey = "tatwo2.globalDM.formKey"
    /// 預設＝Tab（⌥⌘Tab）。
    static let standard: GlobalDMDirectKey = .tab

    /// 讀：沒存過、壞值、系統保留鍵（擋鍵清單）、不是英文字母或數字＝預設 Tab。
    static func load(from defaults: UserDefaults) -> GlobalDMDirectKey {
        guard let raw = defaults.string(forKey: storageKey), let key = GlobalDMDirectKey(rawValue: raw), key != standard,
              GlobalDMDirectKeyRules.blocked[key.rawValue] == nil, key.isAssignable else { return standard }
        return key
    }

    /// 這台現在的換形態鍵（直達鍵的規則拿它當預設；沒改過＝Tab）。
    static func current() -> GlobalDMDirectKey { load(from: .standard) }

    /// 存：回到預設（Tab）＝拿掉記錄（跟沒改過一模一樣）。
    static func save(_ key: GlobalDMDirectKey, to defaults: UserDefaults) {
        if key == standard { defaults.removeObject(forKey: storageKey) } else { defaults.set(key.rawValue, forKey: storageKey) }
    }

    /// 換形態那一列能不能選這個鍵：Tab（預設）可以；其他照直達鍵的擋鍵清單、只收英文字母或數字；已經是某個直達鍵＝不行（說出是哪一個）。
    static func verdict(_ key: GlobalDMDirectKey, directKeys: [GlobalDMTarget: GlobalDMDirectKey]) -> GlobalDMDirectKeyVerdict {
        if key == standard { return .ok }
        if let reason = GlobalDMDirectKeyRules.blocked[key.rawValue] { return .blocked(key, reason: reason) }
        guard key.isAssignable else { return .unsupported }
        let owners = directKeys.filter { $0.value == key }.keys.sorted { $0.storageValue < $1.storageValue }
        if let owner = owners.first { return .taken(key, by: owner) }
        return .ok
    }
}
