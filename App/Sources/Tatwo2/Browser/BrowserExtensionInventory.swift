import Foundation

/// W121（使用者 2026-09-21：「我要的是正常的擴充功能體驗」）：讀出這台機器上真的裝了哪些擴充。
/// 只讀 profile 裡的 manifest（名稱、版本），不執行任何擴充的程式碼，也不碰它的儲存資料。
enum BrowserExtensionInventory {
    struct Item: Identifiable, Equatable {
        let id: String        // 擴充 ID（資料夾名）
        let name: String
        let version: String
        /// manifest 裡最大的那張圖示；沒有就 nil，畫面用拼圖符號代替。
        let iconPath: String?
        /// 點這個擴充時要開的頁面（popup 或 options）；沒有就開它的管理頁。
        let actionURL: String
    }

    /// W122：釘選在工具列的擴充（使用者 2026-09-21：「點擊可釘選在工具列」）。
    enum Pins {
        static let key = "tatwo.browser.extensions.pinned"
        static func ids() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        static func toggle(_ id: String) {
            var list = ids()
            if let index = list.firstIndex(of: id) { list.remove(at: index) } else { list.append(id) }
            UserDefaults.standard.set(list, forKey: key)
        }
        static func contains(_ id: String) -> Bool { ids().contains(id) }
    }

    static var profilesRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("tatwo2/chromium/cef-root", isDirectory: true)
    }

    /// W132：工具列與選單共用同一份清單；掃描有 I/O，不要每次重畫都跑。
    @MainActor private static var cache: [Item]?
    @MainActor static func cached(reload: Bool = false) -> [Item] {
        if reload || cache == nil { cache = installed() }
        return cache ?? []
    }

    /// 掃 cef-root 下每個 profile 的 `Extensions/<id>/<版本>/manifest.json`；同一個擴充只留版本最大的一份。
    static func installed(root: URL? = nil) -> [Item] {
        let manager = FileManager.default
        let base = root ?? profilesRoot
        guard let profiles = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var best: [String: Item] = [:]
        for profile in profiles {
            let extensions = profile.appendingPathComponent("Extensions", isDirectory: true)
            guard let ids = try? manager.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil) else { continue }
            for idURL in ids {
                let id = idURL.lastPathComponent
                guard id.count == 32, !id.hasPrefix(".") else { continue }
                guard let versions = try? manager.contentsOfDirectory(at: idURL, includingPropertiesForKeys: nil) else { continue }
                for versionURL in versions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard let item = read(id: id, at: versionURL) else { continue }
                    best[id] = item   // 目錄已排序，最後留下的就是版本最大的
                }
            }
        }
        return best.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func read(id: String, at folder: URL) -> Item? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let version = (object["version"] as? String) ?? folder.lastPathComponent
        // 圖示：action/browser_action 的 default_icon 優先，其次 manifest 的 icons；都取尺寸最大的那張。
        func largest(_ any: Any?) -> String? {
            if let path = any as? String { return path }
            guard let map = any as? [String: Any] else { return nil }
            return map.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.last.flatMap { map[$0] as? String }
        }
        let action = (object["action"] ?? object["browser_action"]) as? [String: Any]
        let icon = largest(action?["default_icon"]) ?? largest(object["icons"])
        let iconPath = icon.map { folder.appendingPathComponent($0).path }
        let popup = (action?["default_popup"] as? String) ?? (object["options_page"] as? String)
            ?? ((object["options_ui"] as? [String: Any])?["page"] as? String)
        let actionURL = popup.map { "chrome-extension://\(id)/\($0)" } ?? "chrome://extensions/?id=\(id)"
        var name = (object["name"] as? String) ?? id
        if name.hasPrefix("__MSG_") {   // 名稱在語言檔裡
            let key = String(name.dropFirst(6).dropLast(2))
            let locale = (object["default_locale"] as? String) ?? "en"
            for candidate in [locale, "en", "en_US"] {
                let messages = folder.appendingPathComponent("_locales/\(candidate)/messages.json")
                if let data = try? Data(contentsOf: messages),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let entry = object[key] as? [String: Any], let message = entry["message"] as? String {
                    name = message; break
                }
            }
            if name.hasPrefix("__MSG_") { name = id }
        }
        return Item(id: id, name: name, version: version, iconPath: iconPath, actionURL: actionURL)
    }
}
