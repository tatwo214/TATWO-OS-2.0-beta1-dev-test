#if DEBUG
import AppKit
import Combine

enum BrowserCloseAllAcceptance {
    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let staging = environment["TATWO_STAGING_ROOT"] else { throw CocoaError(.fileReadNoPermission) }
        var passed = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures += 1 }
            print("W206CLOSEALL \(condition ? "PASS" : "FAIL") \(label)")
        }
        let registry = BrowserTabRegistry(storageURL: URL(fileURLWithPath: staging).appendingPathComponent("w206.json"))
        let store = BrowserWorkSpaceStore(registry: registry)
        let space = registry.spaces.first { !$0.isSessionSpace }!, folder = space.folders[0].id
        let owner = BrowserTabOwner.workSpace(spaceID: space.id)
        let ordinary = (0..<14).map { registry.openTab(owner: owner, title: "tab-\($0)", folderID: folder) }
        registry.setPinned(ordinary[0].id, true)
        let bookmark = registry.addBookmark(folderID: folder, url: URL(string: "https://example.org/bookmark")!, title: "bookmark")!
        let bookmarkTab = registry.openBookmark(bookmark.id, folderID: folder, owner: owner)!
        let favorite = registry.addFavorite(url: URL(string: "https://example.org/favorite")!, title: "favorite")
        let favoriteTab = registry.openFavorite(favorite.id, owner: owner)!
        let sensitive = registry.openTab(owner: owner, url: URL(string: "https://example.org/one-time")!, sensitive: true)
        let agent = registry.openTab(owner: owner, title: "agent", isAgentTab: true)
        let controlled = registry.openTab(owner: owner, title: "controlled"), nativeAgent = registry.openTab(owner: owner, title: "native-agent")
        let toolTab = registry.openTab(owner: owner, title: "WebMCP")
        let other = registry.openTab(owner: .workSpace(spaceID: registry.addSpace(name: "fixture").id), title: "other")
        let tools = TatwoWebMCPRuntime(confirm: { _, _ in true }, audit: { _ in }, log: { _ in })
        var completion: ((String?, String?) -> Void)?
        tools.attach(tabID: toolTab.id.uuidString) { _, _, _, done in completion = done }
        tools.update(tabID: toolTab.id.uuidString, snapshotJSONString: #"{"schema":"TatwoCEFWebMCPToolsSnapshotV1","origin":"https://example.org","navigationGeneration":1,"tools":[{"name":"fixture","description":"Read note","inputSchemaJSON":"{}","origin":"https://example.org","navigationGeneration":1}]}"#)
        let invocation = Task { try await tools.invoke(tabID: toolTab.id.uuidString, tool: "fixture", argumentsJSON: "{}") }
        for _ in 0..<100 where completion == nil { await Task.yield() }
        check(completion != nil && tools.tabsInUse == [toolTab.id.uuidString], "WebMCP protects an actual pending call")
        registry.workSpaceTabUsage = { id in (id == controlled.id, id != nativeAgent.id, tools.tabsInUse.contains(id.uuidString)) }
        store.select(registryID: ordinary[4].id)
        let oldSpaces = registry.spaces, oldFavorites = registry.favorites
        let expected = ordinary.map(\.title) + [bookmarkTab.title, favoriteTab.title]
        let oldHost = IslandNotice.shared.hostAvailable
        IslandNotice.shared.hostAvailable = true
        defer { IslandNotice.shared.hostAvailable = oldHost; tools.detach(tabID: toolTab.id.uuidString) }
        check(store.closeAllTabsTitle == "關閉全部分頁（17）", "close count includes sleeping, pinned, bookmark, favorite and sensitive tabs")
        var notifications = 0, tabPublications = 0
        let noticeWatch = registry.changes.sink { notifications += 1 }
        let tabWatch = registry.$tabs.dropFirst().sink { _ in tabPublications += 1 }
        defer { noticeWatch.cancel(); tabWatch.cancel() }
        store.closeAllTabs()
        check(notifications == 1 && tabPublications == 1, "W207 batch close publishes tabs once and notifies once")
        check(registry.tabs(ownedBy: owner).map(\.id) == [agent.id, controlled.id, nativeAgent.id, toolTab.id], "agent marker, native control/actor and pending WebMCP remain")
        check(registry.spaces == oldSpaces && registry.favorites == oldFavorites && registry.tabs.contains(other), "saved data and another space remain unchanged")
        check(IslandNotice.shared.current?.title == "已關閉 17 個分頁" && IslandNotice.shared.current?.detail == "右鍵可全部復原・4 個 AI 正在用的分頁保留", "Island displays closed count, undo and retained AI count")
        check(store.reopenClosedBatchTitle == "重新開啟剛關閉的 16 個分頁" && registry.recentlyClosed.count == 10, "batch undo is independent of the ten-entry history")
        notifications = 0; tabPublications = 0
        store.reopenClosedBatch()
        check(notifications == 1 && tabPublications == 1, "W207 batch undo publishes tabs once and notifies once")
        check(registry.tabs(ownedBy: owner).filter { ![agent.id, controlled.id, nativeAgent.id, toolTab.id].contains($0.id) }.map(\.title) == expected && store.selectedTab.title == ordinary[4].title, "batch restores original order and selection")
        check(registry.tabs(ownedBy: owner).first { $0.title == ordinary[0].title }?.isPinned == true && store.closedBatchCount == 0 && !store.canReopenClosedTab, "pinned state restored; batch and single history consumed")
        check(!registry.tabs.contains { $0.url == sensitive.url } && registry.recentlyClosed.allSatisfy { $0.url != sensitive.url }, "one-time authorization URL never restores")
        completion?("{}", nil)
        _ = try await invocation.value
        check(tools.tabsInUse.isEmpty, "WebMCP protection ends when the call completes")
        store.closeAllTabs()
        let manualBookmark = registry.openBookmark(bookmark.id, folderID: folder, owner: owner)!
        let manualFavorite = registry.openFavorite(favorite.id, owner: owner)!
        store.reopenClosedBatch()
        check(registry.tabs.filter { $0.bookmarkID == bookmark.id }.map(\.id) == [manualBookmark.id] && registry.tabs.filter { $0.favoriteID == favorite.id }.map(\.id) == [manualFavorite.id], "manually reopened bookmark/favorite are reused once")
        store.closeAllTabs()
        registry.reopenClosedTab(record: registry.recentlyClosed.first { $0.title == ordinary[13].title })
        store.reopenClosedBatch()
        check(registry.tabs.filter { $0.title == ordinary[13].title }.count == 1, "a tab reopened singly is not restored again by batch undo")
        while let notice = IslandNotice.shared.current { IslandNotice.shared.resolve(.cancel, id: notice.id) }
        let quiet = BrowserWorkSpaceStore(registry: BrowserTabRegistry())
        quiet.addTab()
        quiet.closeAllTabs()
        check(IslandNotice.shared.current?.title == "已關閉 1 個分頁" && IslandNotice.shared.current?.detail == "右鍵可全部復原", "no retained-AI message when none remain")
        if let notice = IslandNotice.shared.current { IslandNotice.shared.resolve(.cancel, id: notice.id) }
        registry.closeSensitiveTabs()
        try registry.flush()
        check(!(try String(contentsOf: URL(fileURLWithPath: staging).appendingPathComponent("w206.json"), encoding: .utf8)).contains("one-time"), "authorization URL stays out of persistence")
        print("W206CLOSEALL SUMMARY passed=\(passed) failures=\(failures)")
        return failures == 0
    }
}
#endif
