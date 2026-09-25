import Foundation

/// W160：憲法「## 引擎摘要」→ 入口 agents.md 的純文字轉換。不碰檔案、不依賴其他型別，
/// 讓 tests/w160-agents-render.test.mjs 可以單獨編譯驗證「組回來逐位元一致」。
enum AgentsRender {
    static let summaryHeading = "## 引擎摘要"
    static let header = """
    # agents.md：在這位使用者設備上工作的所有 AI

    由 TATWO OS 依 `os.md` 產生，唯讀，每台一樣。開工先讀 `~/AI/TATWO OS/user.md`（使用者是誰）與 `~/AI/TATWO OS/device.json`（這台是誰）；衝突以 `~/AI/TATWO OS/os.md` 為準。


    """

    /// 憲法裡「## 引擎摘要」一節的全文（含標題），到下一個二級標題為止；沒有這一節回 nil。
    static func summary(in constitution: String) -> String? {
        let text = constitution.hasPrefix("\u{FEFF}") ? String(constitution.dropFirst()) : constitution
        let heading = summaryHeading + "\n"
        guard let start = text.range(of: heading) else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return heading + String(rest[..<end])
    }

    /// 摘要裡的三級小節升成 agents.md 的二級小節；小節之前的說明段不帶進去。
    static func render(constitution: String) -> String? {
        guard let summary = summary(in: constitution),
              let first = summary.range(of: "\n### ") else { return nil }
        let body = summary[summary.index(after: first.lowerBound)...]
            .components(separatedBy: "\n")
            .map { $0.hasPrefix("### ") ? "## " + $0.dropFirst(4) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return header + body + "\n"
    }

}
