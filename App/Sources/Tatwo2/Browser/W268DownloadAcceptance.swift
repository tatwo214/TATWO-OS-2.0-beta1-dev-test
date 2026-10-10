#if DEBUG
import AppKit
import SwiftUI
import Combine
import Darwin

@MainActor enum W268DownloadAcceptance {
    final class SceneState: ObservableObject {
        @Published var dark = false
        @Published var reduced = false
        @Published var sidebarGeneration = 0
    }
    struct Scene: View {
        @ObservedObject var store: BrowserWorkSpaceStore
        @ObservedObject var runtime: BrowserWorkSpaceRuntime
        @ObservedObject var state: SceneState
        var body: some View {
            HStack(spacing: 0) {
                if !store.focusMode {
                    BrowserWorkSpaceSidebarList(store: store).id(state.sidebarGeneration).padding(12).frame(width: 250)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                BrowserWorkSpaceDesignView(store: store, runtime: runtime)
            }
            .environment(\.colorScheme, state.dark ? .dark : .light)
            .environment(\.browserDownloadReducedMotion, state.reduced ? true : nil)
        }
    }
    final class Marker: NSView {
        var kind = "", motion = "", phase = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    struct Probe: NSViewRepresentable {
        let kind: String
        var motion = "", phase = ""
        func makeNSView(context: Context) -> Marker { Marker() }
        func updateNSView(_ view: Marker, context: Context) { view.kind = kind; view.motion = motion; view.phase = phase }
    }
    static func marker(_ kind: String, in rig: TatwoComposerModeAcceptance.ClickRig) -> Marker? {
        func visit(_ view: NSView) -> Marker? {
            if let marker = view as? Marker, marker.kind == kind, marker.window != nil,
               !marker.isHiddenOrHasHiddenAncestor, marker.bounds.width > 0, marker.bounds.height > 0 { return marker }
            return view.subviews.lazy.compactMap { visit($0) }.first
        }
        rig.host.layoutSubtreeIfNeeded(); rig.window.displayIfNeeded()
        return visit(rig.host)
    }
    static func mouse(_ point: NSPoint, in rig: TatwoComposerModeAcceptance.ClickRig) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { rig.window.sendEvent(event) }
        }
    }
    static func nativeClick(_ browser: TatwoCEFBrowserView, in rig: TatwoComposerModeAcceptance.ClickRig) async throws -> Bool {
        let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
        guard let element = BrowserAgentBridge.uniqueElement(BrowserAgentBridge.clickElements(snapshot), selector: nil, label: "Download slow"),
              let rect = element["rect"] as? [String: Any], let viewport = snapshot["viewport"] as? [String: Any],
              let point = BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: browser.bounds.size) else { return false }
        mouse(browser.convert(NSPoint(x: point.x, y: browser.isFlipped ? point.y : browser.bounds.height - point.y), to: nil), in: rig)
        return true
    }
    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    static func run(store: BrowserWorkSpaceStore, runtime: BrowserWorkSpaceRuntime, browser: TatwoCEFBrowserView,
                    rig: TatwoComposerModeAcceptance.ClickRig, scene: SceneState, origin: String, folder: URL) async throws -> Bool {
        let downloads = BrowserDownloadStore.shared
        let originalPointer = NSEvent.mouseLocation
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        defer { CGWarpMouseCursorPosition(CGPoint(x: originalPointer.x, y: screenTop - originalPointer.y)) }
        var failures = 0, passed = 0
        func check(_ result: Bool, _ label: String) {
            print("W268 \(result ? "PASS" : "FAIL") \(label)")
            if result { passed += 1 } else { failures += 1 }
        }
        var diskEvidence: [[String: Any]] = []
        let mask = umask(0); umask(mask)
        let stagedAssertions = ProcessInfo.processInfo.environment["TATWO_W281_LEGACY_ACCEPTANCE"] != "1"
        if !stagedAssertions { print("W281 SKIP staged filename/mode assertions in forced legacy run; original W258/W268 checks remain enabled") }
        func disk(_ stage: String) throws {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let prefix = stage.replacingOccurrences(of: "-start", with: "").replacingOccurrences(of: "-progress", with: "").replacingOccurrences(of: "-complete", with: "")
            let name = "slow-" + prefix + ".bin"
            let matching = files.filter { $0.lastPathComponent.hasPrefix("slow-" + prefix) }
            if stagedAssertions { check(matching.count == 1 && matching.first?.lastPathComponent == name, "W281 " + stage + " Finder only final filename") }
            if stagedAssertions {
                let hidden = files.filter { $0.lastPathComponent.hasSuffix(".tatwo-download") }
                check(stage.hasSuffix("-complete") ? hidden.isEmpty : hidden.count == 1, "W281c " + stage + " hidden temporary file lifecycle")
                if !stage.hasSuffix("-complete") {
                    let reserved = root.appendingPathComponent(name)
                    check((try? FileManager.default.attributesOfItem(atPath: reserved.path)[.size] as? NSNumber)?.intValue == 0, "W281c visible reservation remains zero bytes")
                    if let file = hidden.first {
                        let info = try FileManager.default.attributesOfItem(atPath: file.path)
                        check(info[.type] as? FileAttributeType == .typeRegular && (info[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()), "W281e staging is an owned regular file")
                    }
                }
            }
            let listing = Process(); listing.executableURL = URL(fileURLWithPath: "/bin/ls")
            listing.arguments = ["-laie", root.path]; let output = Pipe(); listing.standardOutput = output
            try listing.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); listing.waitUntilExit()
            try data.write(to: folder.appendingPathComponent("w281-" + stage + ".ls.txt"))
            for file in files {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                if stage.hasSuffix("-complete") && file.lastPathComponent == name {
                    if stagedAssertions { check((attributes[.posixPermissions] as? NSNumber)?.uint16Value == UInt16(0o666 & ~mask), "W281 completed mode 0666 minus umask actual=\(String(format: "%o", (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)) expected=\(String(format: "%o", 0o666 & ~mask))") }
                    check((try? Data(contentsOf: file)) == Data(repeating: 120, count: 2 * 1024 * 1024), "W281 completed bytes")
                    let quarantine = file.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
                    check(quarantine, "W281 quarantine survives publication (present on 2bed1f1f baseline)")
                    print("W281 QUARANTINE \(file.lastPathComponent) present=\(quarantine)")
                }
                diskEvidence.append(["stage": stage, "name": file.lastPathComponent, "bytes": attributes[.size] ?? 0,
                    "inode": attributes[.systemFileNumber] ?? 0, "mode": attributes[.posixPermissions] ?? 0])
            }
        }
        func shot(_ name: String) async throws {
            await rig.settle(2)
            guard let cached = rig.capture(), let captured = GlobalDMChatAcceptance.captureOwnWindow(cached),
                  let png = captured.bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("W268 screenshot unavailable") }
            try png.write(to: folder.appendingPathComponent(name + ".png"))
            check(true, "screenshot " + name)
        }
        for dark in [false, true] {
            scene.dark = dark
            rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for collapsed in [false, true] {
                store.focusMode = collapsed
                downloads.clearDownloads(); downloads.markDownloadsSeen()
                if let id = downloads.feedbackID { downloads.dismissFeedback(id) }
                let prefix = "\(dark ? "dark" : "light")-\(collapsed ? "collapsed" : "expanded")"
                let page = origin + "/page/slow-" + prefix
                browser.loadURLString(page)
                check(await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == page && !runtime.navigationState.isLoading }, "slow human page ready")
                await rig.settle()
                rig.window.makeKeyAndOrderFront(nil)
                let parked = rig.window.convertPoint(toScreen: NSPoint(x: rig.size.width - 40, y: rig.size.height / 2))
                check(CGWarpMouseCursorPosition(CGPoint(x: parked.x, y: screenTop - parked.y)) == .success, prefix + " pointer parked in own webpage away from card")
                var progress: [Int64] = [], progressTimes: [Double] = []
                var finderSingle = true, diskSamples = 0
                var actualCompletionTime: Double?
                let observation = downloads.$downloads.sink { items in
                    if items.first?.filename == "slow-" + prefix + ".bin" {
                        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("slow-" + prefix) }) ?? []
                        finderSingle = finderSingle && names == ["slow-" + prefix + ".bin"]
                        diskSamples += 1
                    }
                    if let item = items.first, item.filename.hasPrefix("slow-"), item.done, actualCompletionTime == nil { actualCompletionTime = ProcessInfo.processInfo.systemUptime }
                    if let item = items.first, item.filename.hasPrefix("slow-"), item.state == .downloading {
                        progress.append(item.received); progressTimes.append(ProcessInfo.processInfo.systemUptime)
                    }
                }
                let start = ProcessInfo.processInfo.systemUptime
                check(try await nativeClick(browser, in: rig), prefix + " native download click")
                let visible = await wait(0.3) {
                    downloads.feedback?.filename == "slow-" + prefix + ".bin" && (marker("indicator", in: rig)?.phase == "active" || BrowserDownloadFlight.shared.overlay?.superview != nil)
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                check(visible && milliseconds <= 300, prefix + " visible within 300ms measured=\(String(format: "%.1f", milliseconds))ms")
                check(downloads.completionID == nil, prefix + " start clears previous completion pulse")
                if !collapsed {
                    _ = await wait(1.5) { marker("indicator", in: rig)?.motion.hasPrefix("true:") == true }
                    check(marker("indicator", in: rig)?.motion.hasPrefix("true:") == true, prefix + " landing arrow drops")
                }
                try await shot(prefix + "-start")
                try disk(prefix + "-start")
                if !collapsed {
                    try await Task.sleep(for: .seconds(max(0, start + 1.65 - ProcessInfo.processInfo.systemUptime)))
                    check(marker("indicator", in: rig)?.motion.hasPrefix("false:") == true, prefix + " arrow returns after landing")
                }
                let responder = rig.window.firstResponder
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: rig.window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) { rig.window.sendEvent(event) }
                try await Task.sleep(for: .milliseconds(40))
                let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
                let snapshotText = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8) ?? ""
                check(snapshotText.contains("Focus:INPUT Typed:x") && rig.window.firstResponder === responder, prefix + " input focus retained while card appeared")
                try await Task.sleep(for: .seconds(2))
                try await shot(prefix + "-progress")
                try disk(prefix + "-progress")
                check(downloads.aggregateProgress.map { $0 > 0 && $0 < 1 } == true, prefix + " live aggregate fraction")
                check(await wait(12) { downloads.feedback?.done == true }, prefix + " real CEF completed")
                check(downloads.completionID != nil, prefix + " completion checkmark 1.2s")
                if !collapsed { check(await wait(0.3) { marker("indicator", in: rig)?.phase == "completed" }, prefix + " rendered indicator shows checkmark") }
                try await shot(prefix + "-complete")
                try disk(prefix + "-complete")
                check(progress.count >= 3 && zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 } && progress.last! > progress.first!, prefix + " progress monotonic")
                check(zip(progressTimes, progressTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.095 }, prefix + " progress publications at most 10Hz")
                if stagedAssertions { check(finderSingle && diskSamples >= 3, "W281 continuous event samples only final filename samples=\(diskSamples)") }
                observation.cancel()
                check(!downloads.unreadCompletions.isEmpty, prefix + " completion unread badge")
                let completedTime = actualCompletionTime ?? ProcessInfo.processInfo.systemUptime
                var fadedAt: Double?
                let fadeObservation = downloads.$feedbackID.sink { id in if id == nil { fadedAt = ProcessInfo.processInfo.systemUptime } }
                try await Task.sleep(for: .seconds(max(0, completedTime + 1 - ProcessInfo.processInfo.systemUptime)))
                check(downloads.completionID != nil, prefix + " checkmark held at 1s")
                try await Task.sleep(for: .seconds(max(0, completedTime + 1.3 - ProcessInfo.processInfo.systemUptime)))
                check(downloads.completionID == nil, prefix + " arrow restored by 1.3s")
                try await Task.sleep(for: .seconds(max(0, completedTime + 4.35 - ProcessInfo.processInfo.systemUptime)))
                // W270: the deadline is armed when the flight layer sees the completion; main-thread animation work adds up to ~0.3 s.
                check(fadedAt.map { $0 - completedTime >= 3.9 && $0 - completedTime <= 4.4 } == true, prefix + " card timeout measured=\(String(format: "%.3f", (fadedAt ?? completedTime) - completedTime))s")
                fadeObservation.cancel()
                // W270: the card now fades out over 260 ms after its 4 s deadline.
                try await Task.sleep(for: .seconds(max(0, completedTime + 4.7 - ProcessInfo.processInfo.systemUptime)))
                check(marker("card", in: rig) == nil && downloads.completionID == nil, prefix + " card faded after 4s and arrow restored")
                if !collapsed { check(await wait(0.3) { marker("indicator", in: rig)?.phase == "idle" }, prefix + " rendered indicator restores arrow") }
                try await shot(prefix + "-faded")
                store.focusMode = false
                await rig.settle()
                if let indicator = marker("indicator", in: rig) {
                    let frame = indicator.convert(indicator.bounds, to: nil)
                    mouse(NSPoint(x: frame.midX, y: frame.midY), in: rig)
                    await rig.settle()
                    check(store.sidebarInteractionActive, prefix + " open full list")
                    check(downloads.unreadCompletions.isEmpty, prefix + " unread cleared by list")
                    // Remount this fixture's sidebar between cases so no transient popover survives into the next screenshot.
                    scene.sidebarGeneration += 1
                    await rig.settle()
                    check(!store.sidebarInteractionActive, prefix + " full list closed before next case")
                } else { check(false, prefix + " indicator mounted") }
            }
        }
        for reduced in [true, false] {
            scene.reduced = reduced; store.focusMode = false
            if let id = downloads.feedbackID { downloads.dismissFeedback(id) }
            let page = origin + "/page/unknown-" + (reduced ? "reduced" : "animated")
            browser.loadURLString(page)
            _ = await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == page && !runtime.navigationState.isLoading }
            await rig.settle()
            check(try await nativeClick(browser, in: rig), "unknown total real CEF click")
            _ = await wait(0.3) { marker("card", in: rig) != nil }
            var motions: [String] = []
            for _ in 0..<20 {
                if let indicator = marker("indicator", in: rig) { motions.append(indicator.motion) }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(downloads.aggregateProgress == nil && !downloads.active.isEmpty, "real CEF indeterminate total")
            check(!motions.isEmpty && (reduced ? motions.allSatisfy { $0 == "false:false" } : motions.contains("true:true") || motions.contains("false:true")), reduced ? "reduce motion no arrow drop or arc rotation" : "unknown total rotating arc enabled")
            check(await wait(12) { downloads.feedback?.done == true }, "unknown size completion visible")
        }
        browser.loadURLString(origin + "/page/broken")
        _ = await BrowserRuntimeAcceptance.waitUntil { browser.currentURLString == origin + "/page/broken" && !runtime.navigationState.isLoading }
        await rig.settle()
        check(try await nativeClick(browser, in: rig), "failure fixture native click")
        check(await wait(25) { downloads.feedback?.state == .failed }, "CEF interruption shows failure")
        if let failed = downloads.feedback, failed.state == .failed {
            check(failed.failure?.isEmpty == false && downloads.canRetry(failed), "failure reason and retry remain available")
            try await Task.sleep(for: .milliseconds(4200))
            check(marker("card", in: rig) != nil && downloads.feedbackID == failed.id, "failure card persists beyond 4s")
            if let card = marker("card", in: rig) {
                let frame = card.convert(card.bounds, to: nil)
                mouse(NSPoint(x: frame.minX + 24, y: frame.minY + 20), in: rig)
                check(await wait(5) { downloads.feedbackID != failed.id && downloads.feedback != nil }, "native retry button starts a new CEF transfer")
                _ = await wait(25) { downloads.feedback?.state == .failed }
            }
        }
        try JSONSerialization.data(withJSONObject: diskEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("w268-d5-lifecycle.json"))
        print("W268 SUMMARY failures=\(failures) passed=\(passed)")
        return failures == 0
    }
}
#endif
