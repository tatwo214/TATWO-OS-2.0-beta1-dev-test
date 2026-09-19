// 公開 PR #4（作者 saiguigu1068021-cell）整合後的契約：聊天旁瀏覽器與獨立 Browser
// work space 各自一套分頁與 CEF，浮動 chrome 不吃網頁點擊，AI 導覽先過既有政策。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));

const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const registry = read('Browser/BrowserTabRegistry.swift');
const host = read('Chat/ChatPage.swift');
const layout = read('Chat/ChatRightPanelLayoutPolicy.swift');
const design = read('Browser/BrowserWorkSpaceDesignView.swift');
const chrome = read('Browser/BrowserWorkSpaceEmbeddedChrome.swift');
const glass = read('Browser/BrowserToolbarGlass.swift');
const divider = read('Chat/ChatBrowserDivider.swift');

test('PR4 聊天旁瀏覽器有自己的分頁檔與 runtime，不動獨立 Browser 的 registry', () => {
  // PR4b：兩邊各存各的，而且 Chat 這邊從空的開始，完全不抄來源 registry。
  assert.match(registry, /chatInspectorURL = defaultURL.deletingLastPathComponent\(\)\s*\.appendingPathComponent\("chat-tabs.json"\)/);
  assert.match(registry, /chatInspectorMigrationURL/);
  const make = registry.slice(registry.indexOf('static func makeChatInspectorRegistry'),
    registry.indexOf('static func discardMigratedChatInspectorStoreIfNeeded'));
  assert.ok(make.indexOf('return registry') > 0);
  // 不遷移：不讀 source 的任何分頁／書籤，也不寫回 source。
  assert.doesNotMatch(make, /source\.(?:tabs|spaces|favorites)\b/);
  assert.doesNotMatch(make, /source\.(?:openTab|close|update|setPinned|addSpace|addFolder|addBookmark|renameSpace)\(/);
  assert.doesNotMatch(make, /registry\.(?:openTab|addSpace|addFolder|addBookmark|renameSpace|setPinned)\(/);
  // 清理舊遷移：偵測到 PR #4 的標記就把抄來的檔備份成 .pre-pr4b，只做一次。
  const cleanup = registry.slice(registry.indexOf('static func discardMigratedChatInspectorStoreIfNeeded'),
    registry.indexOf('func tabs(ownedBy owner: BrowserTabOwner)'));
  assert.match(cleanup, /guard !fileManager.fileExists\(atPath: cleaned.path\) else \{ return \}/);
  assert.match(cleanup, /fileManager.fileExists\(atPath: migrated.path\)/);
  assert.match(cleanup, /let backup = store.appendingPathExtension\("pre-pr4b"\)/);
  assert.match(cleanup, /moveItem\(at: store, to: backup\)/);
  // 獨立 Browser 的 tabs.json 不在清理範圍內。
  assert.doesNotMatch(cleanup, /defaultURL|tabs\.json/);
  assert.match(make, /discardMigratedChatInspectorStoreIfNeeded\(store: store\)/);
  assert.match(host, /_browserWorkSpaceStore = StateObject\(wrappedValue: BrowserWorkSpaceStore\(registry: model.browserTabRegistry\)\)/);
  assert.match(host, /let chatRegistry = BrowserTabRegistry.chatInspectorRegistry\(source: model.browserTabRegistry\)/);
  // ChatPage 每次重建都重跑 init；registry 必須是同一個，否則 store 和 runtime 會分家。
  assert.match(registry, /static func chatInspectorRegistry\(source: BrowserTabRegistry\) -> BrowserTabRegistry \{[\s\S]*?if let existing = chatInspectorRegistries\[key\] \{ return existing \}/);
  assert.doesNotMatch(host, /BrowserTabRegistry.makeChatInspectorRegistry\(/);
  assert.match(host, /chatBrowserRuntime = BrowserWorkSpaceRuntime.forChat\("chat-browser-inspector", registry: chatRegistry,/);
  assert.match(host, /BrowserWorkSpaceDesignView\(store: chatBrowserWorkSpaceStore,\s*onClose: \{ browserInspectorPresented = false \}, runtime: chatBrowserRuntime\)/);
});

test('PR4 靠邊停的瀏覽器要留下側欄與聊天寬度，窄視窗改上下排而不是擠壓', () => {
  assert.match(layout, /let workspaceReserve = WorkspaceSidebarMetrics.width \+ WorkspaceSidebarMetrics.contentGap \+ minimumChatWidth/);
  assert.match(layout, /let maximum = min\(960, available\)/);
  assert.match(layout, /let canDock = maximum >= 320/);
  assert.match(layout, /min\(420, max\(0, windowHeight\) \* 0.42\)/);
  // 舊的 .inspector 掛法會直接吃掉左列寬度，已移除。
  assert.doesNotMatch(host, /\.inspector\(isPresented: \$browserInspectorPresented\)/);
  assert.doesNotMatch(host, /inspectorColumnWidth\(min: 420, ideal: 640, max: 960\)/);
  assert.match(host, /if visible && layout.canDock \{\s*ChatBrowserDivider\(/);
  assert.match(host, /if visible && !layout.canDock \{\s*Divider\(\)/);
  assert.match(host, /layout.clampedWidth\(CGFloat\(sharedBrowserPanelWidth\)\)/);
  // 切到 Browser work space 時收起聊天旁的面板，避免同一顆 CEF 被兩邊搶。
  assert.match(host, /\.onChange\(of: model.mode\) \{ _, mode in\s*if mode == \.browser \{\s*browserInspectorPresented = false/);
  assert.match(divider, /setAccessibilityRole\(\.splitter\)/);
  assert.match(divider, /addCursorRect\(bounds, cursor: \.resizeLeftRight\)/);
  assert.match(divider, /override var mouseDownCanMoveWindow: Bool \{ false \}/);
});

test('PR4c 聊天旁頂列固定在網頁上方（不浮在 CEF 上），chrome 一律擁有點擊', () => {
  // 使用者 09-18 實機：浮動＋hover 才出現的頂列按鈕「一直有問題」。改成跟獨立 Browser 同一種
  // 疊放：VStack（工具列在上、網頁在下），命中路徑與獨立 Browser 相同，不再靠 CEF 容器讓位。
  assert.match(design, /if onClose != nil \{[\s\S]*?VStack\(spacing: BrowserOmniboxMetrics.zero\) \{\s*workspaceToolbar[\s\S]*?browserPageContent\s*\}/);
  assert.doesNotMatch(design, /browserPageContent\s*\.overlay\(alignment: \.top\)/);
  assert.doesNotMatch(design, /\.allowsHitTesting\(embeddedToolbarVisible\)/);
  assert.match(design, /private var chromeOwnsHits: Bool \{ true \}/);
  assert.match(design, /\.background\(BrowserChromeHitLayer\(isActive: chromeOwnsHits\)\)/);
  // 命中層與容器讓位仍在（獨立 Browser 也靠它擋標題列帶拖視窗）。
  assert.match(glass, /final class BrowserChromeAwareContainerView: NSView/);
  assert.match(glass, /override var mouseDownCanMoveWindow: Bool \{ false \}/);
  assert.doesNotMatch(design, /NonWindowDraggingView\(\)\.allowsHitTesting\(false\)/);
  // 聊天旁網址列不再是放大鏡，跟獨立 Browser 一樣顯示網域；命中層兩種 chrome 都開。
  const toolbar = read('Browser/EmbeddedBrowserToolbar.swift');
  assert.doesNotMatch(toolbar, /if compactChrome \{\s*Image\(systemName: "magnifyingglass"\)/);
  assert.doesNotMatch(toolbar, /BrowserChromeHitLayer\(isActive: !compactChrome\)/);
});

test('PR4 兩種 chrome 共用同一份瀏覽器動作，AI 導覽先過既有政策', () => {
  // 獨立 Browser 仍有可見的「瀏覽器功能」選單；聊天旁改掛在新增分頁的右鍵。
  assert.match(chrome, /var browserActionsButton: some View \{\s*Menu \{ browserActionsMenu \}/);
  assert.match(chrome, /\.contextMenu \{ browserActionsMenu \}/);
  assert.match(design, /if onClose == nil \{ browserActionsButton \}/);
  assert.match(design, /if onClose == nil \{ auxiliaryBrowserControls \} else \{ embeddedToolsExpander \}/);
  // PR4b：展開的工具是獨立圓鈕、垂直一列、中心線對齊 ⌃，沒有底板。
  assert.match(chrome, /func embeddedToolChip\(_ systemImage: String\) -> some View \{[\s\S]*?\.clipShape\(Circle\(\)\)[\s\S]*?\.shadow\(/);
  assert.match(chrome, /embeddedToolChip\(embeddedToolsPinned \? "chevron.up" : "chevron.down"\)/);
  const expander = chrome.slice(chrome.indexOf('var embeddedToolsExpander'));
  // PR4e：圓鈕列畫在無邊框子視窗（永遠在 CEF 之上），不 overlay、不推開網頁；⌃ 與子視窗各自回報 hover。
  assert.doesNotMatch(expander, /\.overlay\(alignment: \.top\)/);
  assert.match(expander, /\.onHover \{ embeddedToolsHovered = \$0 \}/);
  assert.match(chrome, /BrowserFloatingToolsAnchor\(isOpen: embeddedToolsOpen,\s*onHoverPanel: \{ embeddedToolsPanelHovered = \$0 \}\)/);
  assert.match(chrome, /VStack\(spacing: BrowserChatChromeMetrics.toolsGap\) \{ embeddedToolsColumn \}\s*\.frame\(width: BrowserChatChromeMetrics.expanderSize\)/);
  assert.doesNotMatch(design, /embeddedToolsRow/);
  const panel = read('Browser/BrowserFloatingToolsPanel.swift');
  assert.match(panel, /styleMask: \[\.borderless, \.nonactivatingPanel\]/);
  assert.match(panel, /window\.addChildWindow\(panel, ordered: \.above\)/);
  assert.match(panel, /backgroundColor = \.clear/);
  // 關最後一個分頁＝收合；啟動預設不開面板。
  assert.match(chrome, /let last = store\.tabs\.count <= 1\s*store\.close\(tab\.id\)\s*if last \{ onClose\?\(\) \}/);
  assert.match(host, /@State var browserInspectorOpenThreads: Set<UUID> = \[\]/);
  assert.doesNotMatch(host, /@AppStorage\("chat\.sharedBrowserPanelOpen"\)/);
  // 底板（圓角材質方塊）與內距都不能再出現在展開的那一列。
  assert.doesNotMatch(expander, /RoundedRectangle|toolsPadding|toolsCornerRadius/);
  assert.doesNotMatch(expander, /alignment: \.topTrailing/);
  assert.match(chrome, /static let toolsColumnWidth = expanderSize \+ toolsGap/);
  // 政策阻擋要回可辨識的原因，而不是讓 Swift 橋接等到導向逾時。
  const request = read('New/BrowserAgentRequest.swift');
  assert.match(request, /static func validateDestination\(_ url: URL\) throws \{[\s\S]*?EmbeddedBrowserNavigationPolicy.decision\(for: url, actor: \.strict\)/);
  assert.match(request, /case \.askOncePerHost:\s*throw BrowserAgentRequestError\("browser_navigation_blocked_by_policy"\)/);
  assert.match(read('Facade/BrowserAgentBridge.swift'), /try BrowserAgentNavigation.validateDestination\(url\)\s*self\.model\?\.queueBrowserAgentNavigation\(navigation\)/);
  // 關閉確認可能從 CEF 的 main-queue 區塊發起，必須用 run-loop source 才排得進去。
  assert.match(read('Shell/TatwoTerminationCoordinator.swift'),
    /RunLoop.main.perform\(inModes: \[\.common, \.modalPanel, \.eventTracking\], block: action\)\s*CFRunLoopWakeUp\(CFRunLoopGetMain\(\)\)/);
});

// PR4b fixture：跑的是真的 BrowserTabRegistry，儲存路徑注入到暫存目錄，
// 一個位元組都不碰使用者的 ~/Library/Application Support/TATWO OS/Browser。
test('PR4b fixture：Chat registry 不抄來源分頁，舊遷移檔備份後清空且只清一次', {
  timeout: 120_000, skip: process.platform !== 'darwin',
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'pr4b-chat-registry-'));
  const checks = join(dir, 'Checks.swift');
  writeFileSync(checks, String.raw`
import Foundation
import AppKit

@main struct Pr4bChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let browser = root.appendingPathComponent("Browser")
        try fm.createDirectory(at: browser, withIntermediateDirectories: true)
        let source = BrowserTabRegistry(storageURL: browser.appendingPathComponent("tabs.json"))
        let space = source.spaces.first { !$0.isSessionSpace }!
        source.openTab(owner: .workSpace(spaceID: space.id), url: URL(string: "https://x.com/home"), title: "X")
        source.openTab(owner: .workSpace(spaceID: space.id), url: URL(string: "https://openai.com"), title: "OpenAI")
        try source.flush()
        let sourceTabs = source.tabs

        // 上一版遷移出來的樣子：抄好的 chat-tabs.json ＋ PR #4 的遷移標記。
        let store = browser.appendingPathComponent("chat-tabs.json")
        let migrated = Data("{\"migrated\":true}".utf8)
        try migrated.write(to: store)
        try Data("v1\n".utf8).write(to: browser.appendingPathComponent("chat-tabs.migrated-v1"))

        let chat = BrowserTabRegistry.makeChatInspectorRegistry(source: source, store: store)
        precondition(chat.tabs.isEmpty, "chat registry must not copy the standalone Browser tabs")
        precondition(source.tabs == sourceTabs, "source registry must stay untouched")
        precondition(!fm.fileExists(atPath: browser.appendingPathComponent("chat-tabs.migrated-v1").path))
        let backup = try Data(contentsOf: store.appendingPathExtension("pre-pr4b"))
        precondition(backup == migrated, "the migrated file must be kept as chat-tabs.json.pre-pr4b")
        precondition(fm.fileExists(atPath: browser.appendingPathComponent("chat-tabs.cleaned-pr4b").path))
        let standalone = try Data(contentsOf: browser.appendingPathComponent("tabs.json"))
        precondition(!standalone.isEmpty, "the standalone Browser store must stay intact")

        // 清理只做一次：之後使用者自己在 Chat 瀏覽器開的分頁要留著。
        let kept = BrowserTabRegistry.makeChatInspectorRegistry(source: source, store: store)
        kept.openTab(owner: .workSpace(spaceID: kept.spaces.first { !$0.isSessionSpace }!.id),
                     url: URL(string: "https://example.com"), title: "mine")
        try kept.flush()
        BrowserTabRegistry.discardMigratedChatInspectorStoreIfNeeded(store: store)
        precondition(BrowserTabRegistry(storageURL: store).tabs.count == 1, "second run must not wipe user tabs")
        print("PR4B CHAT REGISTRY FIXTURE PASS")
    }
}
`);
  const binary = join(dir, 'checks');
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    'App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift',
    'App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift',
    checks, '-o', binary], { cwd: repo, encoding: 'utf8', timeout: 110_000 });
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PR4B CHAT REGISTRY FIXTURE PASS/);
});

test('/goal 101: chat panel renders with its own runtime and never touches standalone Browser state', () => {
  const host = read('Chat/ChatPage.swift');
  assert.match(host, /forChat\("chat-browser-inspector", registry: chatRegistry,\s*adoptsWorkSpaceTabs: true\)/);
  assert.doesNotMatch(host, /BrowserWorkSpaceLifecycleModifier\(store: chatBrowserWorkSpaceStore/);
  const design = read('Browser/BrowserWorkSpaceDesignView.swift');
  // The page surface must use the view's runtime; the default is the standalone Browser's shared one.
  assert.match(design, /BrowserWorkSpaceCEFSurface\(tabID: tabID, spaceID: spaceID,[^\n]*\n[^\n]*runtime: runtime\)/);
  assert.match(design, /searchFocusRequest > store\.consumedSearchFocusRequest/);
  const surface = read('Browser/BrowserWorkSpaceCEFSurface.swift');
  assert.match(surface, /if let owner, !adoptsWorkSpaceTabs \{ return registry\.tabs\(ownedBy: owner\) \}/);
});

test('/goal 101: real mouse clicks reach the chat strip and the panel toolbar while the panel is docked', () => {
  // Measured with ui_probe on .016: hits landing on the PR hit layer were dead, and the window drag view
  // covered both the chat strip (moved left by the panel) and the panel toolbar.
  const glass = read('Browser/BrowserToolbarGlass.swift');
  const layer = glass.slice(glass.indexOf('final class LayerView'), glass.indexOf('/// The CEF child must yield'));
  assert.match(layer, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \}/);
  assert.match(layer, /static func ownsChromePoint/);
  const shell = read('Shell/AppShell.swift');
  assert.match(shell, /@AppStorage\("tatwo\.chat\.dockedBrowserWidth"\)/);
  assert.match(shell, /if dockedBrowserWidth > 0 \{\s*Color\.clear\.frame\(width: CGFloat\(dockedBrowserWidth\)\)\.allowsHitTesting\(false\)/);
  const host = read('Chat/ChatPage.swift');
  assert.match(host, /\.onChange\(of: visible && layout\.canDock \? Double\(width \+ ChatBrowserInspectorLayout\.dividerWidth\) : 0, initial: true\)/);
});

test('/goal 101 (user 09-19): truly floating chips, instant retract, fading glass, copy-link button, hover toolbox', () => {
  const panel = read('Browser/BrowserFloatingToolsPanel.swift');
  assert.match(panel, /static let inset: CGFloat = 12/);              // shadows are not clipped into a plate
  assert.match(panel, /blendingMode = \.behindWindow/);               // a clear child window has nothing to blur within
  assert.doesNotMatch(panel, /asyncAfter/);                            // retract is decided by pointer position, no timer
  assert.match(panel, /guard panel != nil, !wantsOpen, !mouseInside\(\) else \{ return \}/);
  const design = read('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /workspaceToolbar\s*\.background \{ BrowserFloatingToolbarBackdrop\(\) \}/);
  const toolbar = read('Browser/EmbeddedBrowserToolbar.swift');
  assert.match(toolbar, /else if showsAddress && compactChrome \{[\s\S]*?Button\(action: copyAddress\)/);
  assert.match(toolbar, /Button\("編輯網址…", action: expandEditor\)/);
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.doesNotMatch(panels, /Label\("變更收據 \(diff\)"/);
  assert.doesNotMatch(panels, /Label\("瀏覽器", systemImage: "globe"\)/);
  assert.match(panels, /BrowserFloatingToolsAnchor\(isOpen: toolboxHovered \|\| toolboxPanelHovered \|\| toolboxPinned/);
  assert.match(read('Chat/ChatPage.swift'), /layoutWidth \+ CGFloat\(dockedBrowserWidthSignal\) >= 760/);
});

test('/goal 102 G1/G2: chat-side tabs and open state follow the thread; docked panel leaves room for the composer', () => {
  const design = read('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /func selectThreadSpace\(_ threadID: UUID\) \{\s*let name = "thread:" \+ threadID\.uuidString/);
  assert.match(design, /if !store\.threadScoped \{ spaceControls \}/);
  const host = read('Chat/ChatPage.swift');
  assert.match(host, /@State var browserInspectorOpenThreads: Set<UUID> = \[\]/);
  assert.match(host, /\.onChange\(of: model\.selectedThreadID\) \{ _, _ in syncChatBrowserToThread\(\) \}\s*\.id\(chatBrowserThreadKey\)/);
  const policy = read('Chat/ChatRightPanelLayoutPolicy.swift');
  assert.match(policy, /static let minimumChatWidth: CGFloat = 420/);
  assert.match(policy, /WorkspaceSidebarMetrics\.contentGap \+ minimumChatWidth/);
  const avatar = read('Chat/ChatPageLeafViews+MessageDerived.swift');
  const body = avatar.slice(avatar.indexOf('struct ChatModelAvatar'));
  assert.match(body, /\.renderingMode\(\.template\)/);
  assert.doesNotMatch(body.slice(0, 1400), /liquidGlassSurface|LinearGradient|\.shadow\(/);
});

