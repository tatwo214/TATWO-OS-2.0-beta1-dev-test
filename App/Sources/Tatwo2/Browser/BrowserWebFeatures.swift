import AppKit
import TatwoCEFBridge
import UniformTypeIdentifiers

/// Native UI belongs to one mounted human browser, never to the app's key tab implicitly.
@MainActor
final class BrowserWebFeatures {
    private weak var browser: TatwoCEFBrowserView?
    private weak var container: NSView?
    private var panel: NSSavePanel?
    private var panelCompletion: TatwoCEFFileDialogCompletion?
    private final class FullscreenCover: NSView {
        weak var owner: NSView?
    }
    /// W118：全螢幕專用的無邊框視窗（蓋滿分頁所在的那個螢幕）。borderless 預設不能當 key，鍵盤會進不來。
    private final class FullscreenWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private var overlay: FullscreenCover?
    private var fullscreenWindow: FullscreenWindow?
    private weak var fullscreenHost: NSWindow?
    private var presentationBeforeFullscreen: NSApplication.PresentationOptions?
    private var fullscreenKeys: Any?
    private var presentationSerial: UInt64 = 0

    /// Explicit user-approved handoff; no CEF cookies or session data are exported.
    static func openInSystemBrowser(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func focusOwner(for view: NSView) -> NSView {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let cover = current as? FullscreenCover, let owner = cover.owner { return owner }
            ancestor = current.superview
        }
        return view
    }

    init(browser: TatwoCEFBrowserView, container: NSView) {
        self.browser = browser
        self.container = container
        browser.onFileDialog = { [weak self] mode, title, defaultPath, filters, multiple, completion in
            guard let self else { completion(nil); return }
            self.showFileDialog(mode: mode, title: title, defaultPath: defaultPath,
                                acceptFilters: filters, multiple: multiple, completion: completion)
        }
        browser.onFullscreenModeChange = { [weak self] full in self?.setFullscreen(full) }
        browser.onWebFeaturesInvalidated = { [weak self] in self?.invalidate() }
    }

    private var canPresent: Bool {
        guard let browser, let container else { return false }
        return browser.browserActor == .human && !browser.agentControlled &&
            browser.window != nil && !container.isHiddenOrHasHiddenAncestor && container.window != nil
    }

    private func showFileDialog(mode: Int, title: String, defaultPath: String,
                                acceptFilters: [String], multiple: Bool,
                                completion: @escaping TatwoCEFFileDialogCompletion) {
        guard canPresent, panel == nil, let window = browser?.window, window.attachedSheet == nil,
              (0...3).contains(mode) else { completion(nil); return }
        let picker: NSSavePanel
        if mode == 3 {
            picker = NSSavePanel()
        } else {
            let open = NSOpenPanel()
            open.canChooseDirectories = mode == 2
            open.canChooseFiles = mode != 2
            open.allowsMultipleSelection = mode == 1 && multiple
            open.canCreateDirectories = false
            picker = open
        }
        if !title.isEmpty { picker.title = BrowserHumanInteraction.oneLine(title) }
        picker.message = "網站：\(URL(string: browser?.currentURLString ?? "")?.host ?? "")"
        if !defaultPath.isEmpty {
            let url = URL(fileURLWithPath: defaultPath)
            // The page can suggest a name, not silently select or read a local file.
            if (defaultPath as NSString).isAbsolutePath {
                picker.directoryURL = mode == 2 ? url : url.deletingLastPathComponent()
            }
            if mode == 3 { picker.nameFieldStringValue = url.lastPathComponent }
        }
        let types = Self.contentTypes(acceptFilters)
        if mode != 2, !types.isEmpty { picker.allowedContentTypes = types }
        picker.allowsOtherFileTypes = types.isEmpty
        panel = picker
        panelCompletion = completion
        picker.beginSheetModal(for: window) { [weak self, weak picker] response in
            guard let self, let picker, self.panel === picker else { return }
            let reply = self.panelCompletion
            self.panel = nil
            self.panelCompletion = nil
            guard response == .OK, self.canPresent else { reply?(nil); return }
            let urls = (picker as? NSOpenPanel)?.urls ?? picker.url.map { [$0] } ?? []
            reply?(urls.filter(\.isFileURL).map(\.path))
        }
    }

    static func contentTypes(_ filters: [String]) -> [UTType] {
        var result: [UTType] = []
        for filter in filters {
            let value = filter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "*/*" || value == "*" { return [] }
            let type: UTType?
            switch value {
            case "image/*": type = .image
            case "audio/*": type = .audio
            case "video/*": type = .movie
            case "text/*": type = .text
            default:
                type = value.hasPrefix(".") ? UTType(filenameExtension: String(value.dropFirst())) :
                    UTType(mimeType: value)
            }
            if let type, !result.contains(type) { result.append(type) }
        }
        return result
    }

    /// W118（使用者 2026-09-20：「全螢幕應該是整個電腦」「無法顯示進度條等全螢幕滑鼠交互功能」）：
    /// W57d 把瀏覽器疊在同一個視窗的 SwiftUI 內容上，所以只滿版 App 視窗，滑鼠事件也要先過 NSHostingView。
    /// 現在改成在分頁所在的螢幕開一個專用無邊框視窗：整個螢幕、選單列與 Dock 自動隱藏、滑鼠直接進網頁。
    /// 不用原生全螢幕 Space（不換桌面、沒有轉場動畫），不換任何視窗的 delegate；Esc／⌘ 快捷鍵與退出時還原照舊。
    private func setFullscreen(_ full: Bool) {
        if full {
            guard overlay == nil, canPresent, let browser, let host = browser.window else {
                if overlay == nil { browser?.exitContentFullscreen() }
                return
            }
            let screen = host.screen ?? NSScreen.main
            let frame = screen?.frame ?? host.frame
            let stage = FullscreenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            stage.isReleasedWhenClosed = false
            stage.backgroundColor = .black
            stage.hasShadow = false
            stage.animationBehavior = .none
            stage.collectionBehavior = [.fullScreenAuxiliary]   // 主視窗本身在原生全螢幕 Space 時也要疊得上去
            let cover = FullscreenCover(frame: NSRect(origin: .zero, size: frame.size))
            cover.owner = container
            cover.autoresizingMask = [.width, .height]
            cover.wantsLayer = true
            cover.layer?.backgroundColor = NSColor.black.cgColor
            stage.contentView = cover
            overlay = cover
            fullscreenWindow = stage
            fullscreenHost = host
            let responder = host.firstResponder
            // 有瀏海的螢幕：影片排在瀏海下面（跟系統播放器一樣），上面那條留黑。
            let notch = screen?.safeAreaInsets.top ?? 0
            cover.addSubview(browser)
            browser.frame = NSRect(x: 0, y: 0, width: cover.bounds.width, height: max(0, cover.bounds.height - notch))
            browser.autoresizingMask = [.width, .height]
            // 主視窗已在原生全螢幕時，選單列與 Dock 由系統管；不在時才自己要求自動隱藏（離開時還原）。
            if !host.styleMask.contains(.fullScreen) {
                presentationBeforeFullscreen = NSApp.presentationOptions
                NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            }
            stage.setFrame(frame, display: true)
            stage.makeKeyAndOrderFront(nil)
            if let view = responder as? NSView, view.isDescendant(of: browser) { stage.makeFirstResponder(view) }
            else { stage.makeFirstResponder(browser) }
            // Exists only while this overlay exists, and only intercepts its own window.
            // Esc must also work after focus moves from the renderer into host chrome.
            fullscreenKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.overlay != nil, let browser = self.browser,
                      event.window === browser.window else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 53, modifiers.isEmpty {
                    browser.exitContentFullscreen()
                    return nil
                }
                if modifiers.contains(.command),
                   ["l", "t", "w", "r", "f", "p", "[", "]", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
                    .contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                    browser.exitContentFullscreen()
                }
                return event
            }
        } else {
            guard let cover = overlay else { return }
            overlay = nil
            if let fullscreenKeys { NSEvent.removeMonitor(fullscreenKeys) }
            fullscreenKeys = nil
            let stage = fullscreenWindow
            fullscreenWindow = nil
            if let browser, let container {
                let responder = stage?.firstResponder
                container.addSubview(browser)
                browser.frame = container.bounds
                browser.autoresizingMask = [.width, .height]
                container.needsLayout = true
                if let view = responder as? NSView, view.isDescendant(of: browser) { browser.window?.makeFirstResponder(view) }
            }
            if let options = presentationBeforeFullscreen { NSApp.presentationOptions = options }
            presentationBeforeFullscreen = nil
            cover.removeFromSuperview()
            stage?.contentView = nil
            stage?.orderOut(nil)
            stage?.close()
            if let host = fullscreenHost, host.isVisible { host.makeKeyAndOrderFront(nil) }
            fullscreenHost = nil
        }
    }

    func invalidate() {
        presentationSerial &+= 1
        // Consume first: cancel() may synchronously invoke the panel completion.
        let picker = panel
        let reply = panelCompletion
        panel = nil
        panelCompletion = nil
        picker?.cancel(nil)
        reply?(nil)
        setFullscreen(false)
    }

    func requestPDF(download: Bool = false) {
        guard canPresent, let browser else { return }
        let generation = browser.navigationGeneration
        let serial = presentationSerial
        let completion: (String?) -> Void = { [weak self, weak browser] path in
            guard let self, self.presentationSerial == serial, self.canPresent,
                  let browser, browser.browserActor == .human, !browser.agentControlled,
                  browser.navigationGeneration == generation, browser.window != nil,
                  !browser.isHiddenOrHasHiddenAncestor else { return }
            Self.openPDF(path, window: browser.window)
        }
        if download { browser.downloadCurrentPDF(completion: completion) }
        else { browser.printToPDF(completion: completion) }
    }

    private static func openPDF(_ path: String?, window: NSWindow?) {
        guard let path else {
            let alert = NSAlert()
            alert.messageText = "無法開啟 PDF"
            alert.informativeText = "列印或下載未完成，或分頁已切換。請回到原分頁重試。"
            if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
            return
        }
        // The bridge only returns completed, signature-checked .pdf files for a current human tab.
        let url = URL(fileURLWithPath: path)
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
