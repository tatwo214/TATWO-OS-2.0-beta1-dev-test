import AppKit

/// 一般貼上保留儲存格與簡報文字；檔案網址、拖曳與明確的貼圖操作沿用附件路徑。
enum ComposerPastePolicy {
    static func prefersText(from pasteboard: NSPasteboard, fileURLs: [URL], preferText: Bool) -> Bool {
        guard preferText, pasteboard.name != .drag, fileURLs.isEmpty,
              let text = pasteboard.string(forType: .string) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
