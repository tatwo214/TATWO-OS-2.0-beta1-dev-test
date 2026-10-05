import Foundation

/// W180 E1：回答下面那一列「用了 N 條記憶」存在對話裡的文字（system 訊息，status `info|記憶`）。純邏輯，node 測試單獨編譯。
/// N＝這輪 OS 帶給 AI 的候選，加上這輪 AI 用 memory_get／memory_search 讀過的（去重；主導 W180 裁決 a）。
/// 文字本身就看得懂（舊版或別的畫面照原文顯示也不怪）；新畫面讀回來畫成可展開的一列。逐字稿會同步到副設備，副設備只顯示。
struct TatwoMemoryUsageNote: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    static let tag = "記憶"
    static let status = "info|記憶"
    /// 展開後第一行小字：這些是「帶給 AI 參考的」，不代表 AI 一定用上。
    static let detailCaption = "這輪帶給 AI 參考的記憶"
    private static let queryPrefix = "〔這句〕"

    var items: [Item]
    /// 這輪使用者那句話（截短）；按「不相關」時拿來記「哪一句不相關」。
    var query: String

    var count: Int { items.count }
    var headline: String { "用了 \(items.count) 條記憶" }

    /// 去重（照先後）、丟掉 id 有換行或〔〕的（寫不回來）；標題壓成一行、不超過 80 字（寫出去再讀回來會一模一樣）。
    init(items: [Item], query: String) {
        var seen = Set<String>()
        self.items = items.compactMap { item in
            guard !item.id.isEmpty, !item.id.contains(where: { "\n\r〔〕".contains($0) }),
                  seen.insert(item.id).inserted else { return nil }
            let title = Self.flat(item.title, limit: 80)
                .replacingOccurrences(of: "〔", with: "［").replacingOccurrences(of: "〕", with: "］")
            return Item(id: item.id, title: title.isEmpty ? item.id : title)
        }
        self.query = Self.flat(query, limit: 80)
    }

    func encoded() -> String {
        var lines = [headline]
        for item in items { lines.append("- " + item.title + "〔" + item.id + "〕") }
        if !query.isEmpty { lines.append(Self.queryPrefix + query) }
        return lines.joined(separator: "\n")
    }

    static func decode(_ text: String) -> TatwoMemoryUsageNote? {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("用了 "), first.hasSuffix(" 條記憶") else { return nil }
        var items: [Item] = []
        var query = ""
        for line in lines.dropFirst() {
            if line.hasPrefix(queryPrefix) {
                query = String(line.dropFirst(queryPrefix.count))
                continue
            }
            guard line.hasPrefix("- "), line.hasSuffix("〕"), let open = line.range(of: "〔", options: .backwards) else { continue }
            let id = String(line[open.upperBound..<line.index(before: line.endIndex)])
            let title = String(line[line.index(line.startIndex, offsetBy: 2)..<open.lowerBound])
            guard !id.isEmpty else { continue }
            items.append(Item(id: id, title: title))
        }
        guard !items.isEmpty else { return nil }
        return TatwoMemoryUsageNote(items: items, query: query)
    }

    static func flat(_ text: String, limit: Int) -> String {
        let one = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.count > limit ? String(one.prefix(limit)) : one
    }
}
