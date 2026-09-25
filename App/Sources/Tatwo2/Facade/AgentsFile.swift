import Foundation
import Darwin

/// W160：入口的 `agents.md` 由 OS 從憲法「## 引擎摘要」產生（憲法 v4.1 §0 ④）。
/// 各引擎的全域規則檔是連到它的連結，所以只寫這一份；只在主設備寫，副設備靠 W78 派發收到同一份。
/// 純文字轉換可單獨測試；寫入前先比對，內容相同不碰檔案。
enum AgentsFile {
    static let fileName = "agents.md"

    enum Outcome: Equatable { case unchanged, written, skippedNotPrimary, skippedNoSummary }

    /// 主設備才寫。寫法：同目錄暫存檔 → rename 取代（不經由既有檔的權限）→ 0444。
    /// 目標若是連結或不是一般檔就不動，交給使用者處理。
    @discardableResult
    static func refresh(entry: TatwoEntry = TatwoEntry(), role: DeviceRole?) throws -> Outcome {
        guard role == .primary else { return .skippedNotPrimary }
        let constitution = try OSUpstreamBinding.readText(entry.constitution.path)
        guard let content = AgentsRender.render(constitution: constitution) else { return .skippedNoSummary }
        let target = entry.root.appendingPathComponent(fileName)
        var info = stat()
        if lstat(target.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw OSUpstreamBinding.failure("入口的 agents.md 不是一般檔，不覆寫")
            }
            if (try? Data(contentsOf: target)) == Data(content.utf8) { return .unchanged }
        }
        let temp = entry.root.appendingPathComponent(".agents.md.\(UUID().uuidString).tmp")
        try Data(content.utf8).write(to: temp)
        guard chmod(temp.path, 0o444) == 0, rename(temp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw OSUpstreamBinding.failure("寫入 agents.md 失敗")
        }
        // 入口有記版本就只提交這一個檔，之後照使用者的設定推到 GitHub 備份。
        if EntryBackup.isRepository(entry) {
            _ = EntryBackup.gitOutput(["add", "--", fileName], in: entry.root, allowEmpty: true)
            if EntryBackup.gitOutput(["-c", "commit.gpgsign=false", "commit", "--only", "-q", "-m",
                                      "agents.md：依 os.md 重新產生", "--", fileName], in: entry.root, allowEmpty: true) != nil {
                OSDocuments.afterCommit?()
            }
        }
        return .written
    }

    /// 內建三家引擎的注入文字要帶上使用者偏好；它們的家目錄是隔離的，不能指望它們自己去讀。
    static func userPreferences(entry: TatwoEntry = TatwoEntry()) -> String? {
        guard let text = try? OSUpstreamBinding.readText(entry.root.appendingPathComponent("user.md").path) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
