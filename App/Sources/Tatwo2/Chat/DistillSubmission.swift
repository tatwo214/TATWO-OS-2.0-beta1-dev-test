import Foundation

/// W180 E4：/蒸餾 要把這條 session 整理成哪一種可重用的東西。預設技能；GBrain 只是選項之一。
/// （使用者 09-26：「/蒸餾 是 session 完工後寫成 skill 或其他用途的快捷鍵，不是寫死蒸餾進 GBrain」。
/// 通用記憶是 E1 的事，這裡不收「記憶」類型。）只依賴 Foundation：tests/w29b 會單獨編譯本檔。
enum DistillOutputKind: String, Codable, CaseIterable, Sendable {
    case skill, checklist, sop, gbrain

    var label: String {
        switch self {
        case .skill: "技能"
        case .checklist: "清單"
        case .sop: "SOP"
        case .gbrain: "GBrain"
        }
    }
}

/// 一個寫入目標：主設備上的絕對路徑（GBrain 是 `gbrain:<slug>`）、新建或取代、預定內容與原檔的 sha256。
struct DistillTarget: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case create, replace }
    let path: String
    let action: Action
    let newSHA: String
    /// 取代時原檔的 sha256；新建是 nil（寫入前再比一次，對不上就不寫）。
    let baseSHA: String?
}

/// 按「預覽寫入」得到的計畫：寫到哪、會不會先封存同名舊檔。確認寫入時主設備重算一次，對不上就不寫。
struct DistillWritePlan: Codable, Equatable, Sendable {
    let output: DistillOutputKind
    /// 技能資料夾名、筆記檔名（不含 .md）或 GBrain slug。
    let name: String
    let title: String
    let targets: [DistillTarget]
    /// 預覽時畫布全文的 sha256；畫布一改，預覽就失效。
    let contentSHA: String
}

/// The snapshot is persisted BEFORE either write. A reopened/failed submission is
/// never automatically retried: the user must first check the reported destinations.
struct DistillSubmission: Codable, Equatable, Sendable {
    var id = UUID()
    let threadID: UUID
    let content: String
    let title: String
    let slug: String
    let gbrain: Bool
    let skillet: Bool
    var message = "送出已開始；若中斷，請先查目的地，不會自動重送。"
    // W180 E4：以下都是可選欄位，舊畫布（只有 gbrain／skillet）照樣讀得回來。
    var output: DistillOutputKind?
    var targets: [DistillTarget]?
    /// 這次寫入的封存資料夾（manifest.json、還原.md、舊版原檔）。
    var archivePath: String?
    var receiptLines: [String]?
    var restoredAt: Date?
    /// writing（寫入前先存下的界線）｜done｜unconfirmed｜restored。nil＝W81 舊版送出。
    var status: String?
    /// 寫入時那張畫布的編號（封存紀錄也記這個；畫布換新之後，還原照樣只認這一次寫入）。
    var planID: UUID?
}
