#if DEBUG
import AppKit

@MainActor enum W282DownloadAcceptance {
    final class Subscription {
        var progress: Progress?
        var fractions: [Double] = []
        var published = 0, removed = 0
        var token: Any?
        init(_ url: URL) {
            token = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                MainActor.assumeIsolated {
                    self?.progress = progress; self?.published += 1
                    print("W282 SUBSCRIBE \(url.lastPathComponent) kind=\(String(describing: progress.kind))")
                }
                return { [weak self] in
                    MainActor.assumeIsolated {
                        self?.sample(); self?.removed += 1; self?.progress = nil
                        print("W282 REMOVE \(url.lastPathComponent)")
                    }
                }
            }
        }
        func sample() {
            if let progress, fractions.last != progress.fractionCompleted { fractions.append(progress.fractionCompleted) }
        }
        func close() { if let token { Progress.removeSubscriber(token); self.token = nil } }
    }
    static func run(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                    runtime: BrowserWorkSpaceRuntime, origin: String, folder: URL) async throws -> Bool {
        let fm = FileManager.default, store = BrowserDownloadStore.shared
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var failures = 0, evidence: [[String: Any]] = []
        func check(_ result: Bool, _ label: String) {
            print("W282 \(result ? "PASS" : "FAIL") \(label)"); if !result { failures += 1 }
        }
        func start(_ name: String) async throws -> BrowserDownloadStore.Item? {
            let ids = Set(store.downloads.map(\.id)), page = origin + "/page/" + name
            browser.loadURLString(page)
            check(await W268DownloadAcceptance.wait(10) { browser.currentURLString == page && !runtime.navigationState.isLoading }, name + " page ready")
            await rig.settle()
            check(try await W268DownloadAcceptance.nativeClick(browser, in: rig), name + " human native click")
            _ = await W268DownloadAcceptance.wait(10) { store.downloads.contains { !ids.contains($0.id) } }
            return store.downloads.first { !ids.contains($0.id) }
        }
        func finish(_ item: BrowserDownloadStore.Item, _ sub: Subscription) async -> BrowserDownloadStore.Item? {
            _ = await W268DownloadAcceptance.wait(25) {
                sub.sample(); return store.downloads.first { $0.id == item.id }?.state.isTerminal == true
            }
            check(await W268DownloadAcceptance.wait(5) { sub.removed > 0 && sub.progress == nil }, item.filename + " unpublished")
            let final = store.downloads.first { $0.id == item.id }
            evidence.append(["filename": item.filename, "published": sub.published, "removed": sub.removed,
                             "fractions": sub.fractions, "state": final?.state.rawValue ?? "missing"])
            print("W282 FRACTIONS \(item.filename) \(sub.fractions)")
            return final
        }
        // Only this isolated folder's Finder window is created, configured and captured.
        func appleScript(_ source: String, arguments: [String] = []) async throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source] + arguments; process.standardOutput = output; process.standardError = output
            try process.run()
            guard await W268DownloadAcceptance.wait(5, { !process.isRunning }) else {
                process.terminate(); throw TapError.remote("Finder AppleScript timeout; automation access unconfirmed")
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw TapError.remote(result) }; return result
        }
        var finderID: String?
        do {
            guard CGPreflightScreenCaptureAccess() else { throw TapError.remote("screen capture access absent (CGPreflightScreenCaptureAccess=false)") }
            finderID = try await appleScript("""
                on run argv
                    tell application "Finder"
                        set w to make new Finder window to (POSIX file (item 1 of argv))
                        set current view of w to icon view
                        set bounds of w to {120, 100, 900, 600}
                        set icon size of icon view options of w to 96
                        activate
                        return id of w
                    end tell
                end run
                """, arguments: [root.path])
        } catch { print("W282 FINDER unavailable: \(error)") }
        func finderShot(_ phase: String) async throws {
            guard let finderID else { print("W282 SKIP Finder \(phase): window unavailable"); return }
            _ = try await appleScript("tell application \"Finder\"\nset index of Finder window id " + finderID + " to 1\nactivate\nend tell")
            try await Task.sleep(for: .milliseconds(450))
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard let window = windows.first(where: {
                ($0[kCGWindowOwnerName as String] as? String) == "Finder" &&
                (($0[kCGWindowBounds as String] as? [String: Any])?["X"] as? NSNumber)?.intValue == 120
            }), let number = window[kCGWindowNumber as String] as? NSNumber else {
                print("W282 SKIP Finder \(phase): own window absent from screen capture list"); return
            }
            let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-l", number.stringValue, folder.appendingPathComponent("w282-finder-" + phase + ".png").path]
            try shot.run(); shot.waitUntilExit()
            check(shot.terminationStatus == 0, "Finder " + phase + " screenshot")
        }
        let normalURL = root.appendingPathComponent("slow-w282-finder.bin")
        let normal = Subscription(normalURL); defer { normal.close() }
        guard let item = try await start("slow-w282-finder") else { throw TapError.remote("W282 download absent") }
        check(await W268DownloadAcceptance.wait(5) { normal.sample(); return (normal.progress?.fractionCompleted ?? 0) > 0.15 }, "subscriber discovers final reservation and receives bytes")
        check((try? fm.attributesOfItem(atPath: normalURL.path)[.size] as? NSNumber)?.intValue == 0, "Finder reservation remains zero bytes during progress")
        check(normal.progress?.kind == .file && normal.progress?.userInfo[.fileURLKey] as? URL == normalURL &&
              normal.progress?.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind == .downloading && normal.progress?.isPausable == false,
              "file URL, downloading kind and no pause on subscribed proxy")
        try await finderShot("progress")
        let final = await finish(item, normal)
        check(final?.done == true && (try? Data(contentsOf: normalURL)) == Data(repeating: 120, count: 2 * 1024 * 1024), "completed full file replaces reservation")
        check(normal.fractions.count > 3 && zip(normal.fractions, normal.fractions.dropFirst()).allSatisfy { $0 <= $1 } &&
              (normal.fractions.last ?? 0) > 0.9, "fractionCompleted monotonically increases")
        try await finderShot("completed")

        let collisionURL = root.appendingPathComponent("slow-w282-collision.bin")
        try Data("existing user file".utf8).write(to: collisionURL, options: .withoutOverwriting)
        let numberedURL = root.appendingPathComponent("slow-w282-collision (1).bin")
        let collision = Subscription(numberedURL); defer { collision.close() }
        let original = Subscription(collisionURL); defer { original.close() }
        guard let numbered = try await start("slow-w282-collision") else { throw TapError.remote("collision download absent") }
        check(await W268DownloadAcceptance.wait(5) { collision.progress != nil }, "collision subscribed at final numbered name")
        check(numbered.fileURL == numberedURL && original.published == 0, "collision publishes only final numbered name")
        check(await finish(numbered, collision)?.done == true, "collision completed")

        let unknown = Subscription(root.appendingPathComponent("unknown-w282.bin")); defer { unknown.close() }
        guard let unknownItem = try await start("unknown-w282") else { throw TapError.remote("unknown download absent") }
        check(await W268DownloadAcceptance.wait(5) { unknown.progress?.isIndeterminate == true }, "unknown size indeterminate")
        let cancel = Subscription(root.appendingPathComponent("slow-w282-cancel.bin")); defer { cancel.close() }
        guard let cancelItem = try await start("slow-w282-cancel") else { throw TapError.remote("cancel download absent") }
        check(await W268DownloadAcceptance.wait(5) { cancel.progress != nil }, "cancel subscriber receives progress")
        check(unknown.progress != nil && cancel.progress != nil && unknown.progress !== cancel.progress, "simultaneous downloads have independent progress")
        cancel.progress?.cancel()
        check(await finish(cancelItem, cancel)?.state == .cancelled, "Finder proxy cancel reaches existing CEF cancel path")
        check(await finish(unknownItem, unknown)?.done == true, "unknown download completed and removed")

        let broken = Subscription(root.appendingPathComponent("broken-w282.bin")); defer { broken.close() }
        guard let brokenItem = try await start("broken-w282") else { throw TapError.remote("broken download absent") }
        check(await finish(brokenItem, broken)?.state == .failed, "failed progress removed")

        if ProcessInfo.processInfo.environment["TATWO_W281_LEGACY_ACCEPTANCE"] == "1" {
            print("W282 SKIP late publication collision and changed URL: legacy Continue(final) has no publication step; asserted in main staged run")
        } else {
            // A real late publication collision changes the completed path.
            let changedURL = root.appendingPathComponent("slow-w282-changed.bin")
            let changed = Subscription(changedURL); defer { changed.close() }
            let renamedURL = root.appendingPathComponent("slow-w282-changed (1).bin")
            let renamed = Subscription(renamedURL); defer { renamed.close() }
            guard let changedItem = try await start("slow-w282-changed") else { throw TapError.remote("late collision absent") }
            check(await W268DownloadAcceptance.wait(5) { changed.progress != nil }, "late collision original subscription")
            try fm.moveItem(at: changedURL, to: folder.appendingPathComponent("w282-retained-reservation"))
            try Data("replacement user bytes".utf8).write(to: changedURL, options: .withoutOverwriting)
            let changedFinal = await finish(changedItem, changed)
            check(changedFinal?.done == true && changedFinal?.fileURL == renamedURL &&
                  (try? Data(contentsOf: renamedURL)) == Data(repeating: 120, count: 2 * 1024 * 1024), "completion uses late final numbered path")
            _ = await W268DownloadAcceptance.wait(2) { renamed.published > 0 && renamed.removed > 0 }
            check(renamed.published > 0 && renamed.removed > 0, "changed final URL republished then removed")
        }

        if let finderID { _ = try? await appleScript("tell application \"Finder\" to close Finder window id " + finderID) }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("w282-subscriptions.json"))
        print("W282 SUMMARY failures=\(failures)")
        return failures == 0
    }

    // Termination also closes CEF; run this in a separate fixture process.
    static func termination(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                            runtime: BrowserWorkSpaceRuntime, origin: String) async throws -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let subscriptions = ["slow-w282-termination-a", "slow-w282-termination-b"].map { Subscription(root.appendingPathComponent($0 + ".bin")) }
        defer { subscriptions.forEach { $0.close() } }
        for (index, name) in ["slow-w282-termination-a", "slow-w282-termination-b"].enumerated() {
            let page = origin + "/page/" + name
            browser.loadURLString(page)
            guard await W268DownloadAcceptance.wait(10, { browser.currentURLString == page && !runtime.navigationState.isLoading }) else { return false }
            await rig.settle()
            guard try await W268DownloadAcceptance.nativeClick(browser, in: rig) else { return false }
            guard await W268DownloadAcceptance.wait(5, { subscriptions[index].progress != nil }) else { return false }
            print("W282 PASS termination download \(index + 1) published")
        }
        guard await W268DownloadAcceptance.wait(5, { subscriptions.allSatisfy { $0.progress != nil } }) else { return false }
        print("W282 PASS two real CEF downloads published before App termination")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        let removed = await W268DownloadAcceptance.wait(5) { subscriptions.allSatisfy { $0.removed == 1 && $0.progress == nil } }
        print("W282 \(removed ? "PASS" : "FAIL") App termination unpublishes all concurrent downloads")
        return removed
    }
}
#endif
