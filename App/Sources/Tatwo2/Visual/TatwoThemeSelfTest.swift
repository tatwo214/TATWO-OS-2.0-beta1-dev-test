#if DEBUG
import Foundation
import AppKit
import SwiftUI

/// W184 H4 修正第四輪：自測暫時換主題（只給自測用，產品的 TatwoThemeStore 不動）。
///
/// 為什麼要有這個：`TatwoThemeStore.select()` 會把主題寫進 `UserDefaults.standard` 的 `tatwo.activeThemeID`，而自測程式
/// （build-cache 的 Tatwo2）的偏好設定網域是整台共用的——lead-verify 換了 HOME／CFFIXED_USER_HOME 也隔不到它
/// （跑自測那台的 ~/Library/Preferences/Tatwo2.plist）。別的房間同時開的自測一開起來就讀那一格：以前 w184mode 量到一半切到 aurora，
/// 同一時間開起來的 w184chat 就整個用 aurora 畫（G3c drawn 那條照 fable5 調的門檻就差太少）。
///
/// 用法：換之前先建一個（記下原本的主題與存檔），`use(_:)` 換畫面用的主題、存檔那一格馬上寫回原本的值；
/// `restore()`（放在 defer，中途 continue／return／失敗都會還原）換回原本的主題、存檔照舊。
@MainActor
struct TatwoThemeSelfTestScope {
    static var forceDark: Bool { ProcessInfo.processInfo.environment["TATWO2_SELFTEST_DARK"] == "1" }

    /// 真正的 darkAqua＋玻璃主題；紙主題本來固定淺色，不能當深色證據。
    static func withDarkAppearance<T>(_ make: () throws -> T) rethrows -> T {
        let app = NSApplication.shared
        let scope = TatwoThemeSelfTestScope()
        let appearance = app.appearance
        scope.use(.aurora)
        app.appearance = NSAppearance(named: .darkAqua)
        defer { scope.restore(); app.appearance = appearance }
        return try make()
    }

    static func withDarkAppearance<T>(_ make: () async throws -> T) async rethrows -> T {
        let app = NSApplication.shared
        let scope = TatwoThemeSelfTestScope()
        let appearance = app.appearance
        scope.use(.aurora)
        app.appearance = NSAppearance(named: .darkAqua)
        defer { scope.restore(); app.appearance = appearance }
        return try await make()
    }

    static func saveDarkEvidence<V: View>(_ name: String, size: CGSize, to folder: URL?, @ViewBuilder content: () -> V) -> Bool {
        withDarkAppearance {
            guard let shot = GlobalDMChatAcceptance.renderSync(content(), size: size, scheme: .dark) else { return false }
            defer { shot.close() }
            guard shot.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                  hasReadableDarkPixels(shot.bitmap), let folder else { return false }
            GlobalDMChatAcceptance.save(shot, name, to: folder)
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    /// 反例：只有設定 dark 旗標、卻畫出淺色底或全黑空圖都不能算證據。
    static func hasReadableDarkPixels(_ bitmap: NSBitmapImageRep) -> Bool {
        var dark = 0, light = 0, count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
                if luminance < 0.35 { dark += 1 }
                if luminance > 0.65 { light += 1 }
            }
        }
        return count > 0 && Double(dark) / Double(count) > 0.25 && light > 20
    }

    /// 跟 TatwoThemeStore 的存檔鍵同一個字串（那邊是 private；node 測試核對兩邊一致）。
    static let storedKey = "tatwo.activeThemeID"
    /// 量像素的自測：門檻照跑自測那台平常存的 fable5（紙底）調的，程序一開始就把畫面定在 fable5（見 SelfTest.runIfRequested）。
    static let pixelSelfTests: Set<String> = ["w184chat", "w184forms", "w184button", "w184tent", "w184browser", "w184mode"]

    private let original: TatwoThemeID
    private let stored: Any?

    init() {
        let themes = TatwoThemeStore.shared   // 先建好（第一次建會照它的規則存一次），再記存檔
        original = themes.activeThemeID
        stored = UserDefaults.standard.object(forKey: Self.storedKey)
    }

    /// 這個程序畫的樣子換成 theme；共用的存檔不變。
    func use(_ theme: TatwoThemeID) {
        TatwoThemeStore.shared.select(theme)
        keepStored()
    }

    /// 換回建的時候那個主題；共用的存檔不變。
    func restore() {
        TatwoThemeStore.shared.select(original)
        keepStored()
    }

    private func keepStored() {
        if let stored {
            UserDefaults.standard.set(stored, forKey: Self.storedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storedKey)
        }
    }
}
#endif
