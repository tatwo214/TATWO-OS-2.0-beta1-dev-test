import Foundation

/// W177：外部 App 背景網頁（Pod）的瀏覽器快取，每次開 App、第一次啟動那個 Pod 之前清掉
/// （憲法 v4.2 第 7 條：對話內容不落地）。快取裡會有對話資料與圖片（跟一般瀏覽器一樣）；
/// 登入用的 Cookies 等放在 Application Support，不動（不用重登）。
/// Chromium 在 macOS 把 HTTP 快取放在 ~/Library/Caches 底下、跟設定檔在 Application Support 的相對路徑相同。
@MainActor
enum TapPodStorage {
    private static var purged: Set<UUID> = []

    static func purgeHTTPCacheOnce(profileID: UUID) {
        guard purged.insert(profileID).inserted else { return }
        guard let profile = try? TatwoCEFProfileStore.live?.profileURL(for: profileID),
              profile.lastPathComponent.contains(profileID.uuidString.lowercased()),
              let cache = cacheDirectory(forProfile: profile) else { return }
        try? FileManager.default.removeItem(at: cache)
    }

    /// 設定檔在 ~/Library/Application Support/X → HTTP 快取在 ~/Library/Caches/X/Cache。不在 Application Support 底下就不動。
    nonisolated static func cacheDirectory(forProfile profile: URL, fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let supportPath = support.standardizedFileURL.path + "/"
        let profilePath = profile.standardizedFileURL.path
        guard profilePath.hasPrefix(supportPath) else { return nil }
        let relative = String(profilePath.dropFirst(supportPath.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
        let cache = caches.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("Cache", isDirectory: true)
        // 路徑上（Caches 以下）不能有符號連結，解析後也要一模一樣：不會順著連結刪到別的設定檔（審查 #5）。
        var check = cache
        while check.path.count > caches.path.count {
            if (try? check.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
            check = check.deletingLastPathComponent()
        }
        guard cache.resolvingSymlinksInPath().path == cache.standardizedFileURL.path else { return nil }
        return cache
    }
}
