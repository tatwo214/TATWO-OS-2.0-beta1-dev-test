#if DEBUG
import AppKit
import Foundation
import Darwin

@MainActor enum W281DownloadAcceptance {
    static func unsupportedExtension(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                                     runtime: BrowserWorkSpaceRuntime, origin: String, folder: URL) async throws -> Bool {
        let fm = FileManager.default, downloads = BrowserDownloadStore.shared
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let held = folder.appendingPathComponent("w281f-held-downloads"), name = "c." + String(repeating: "z", count: 253)
        let path = root.appendingPathComponent(name)
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("W281f \(value ? "PASS" : "FAIL") extension \(label)"); if !value { failures += 1 }
        }
        defer { if fm.fileExists(atPath: held.path) { try? fm.moveItem(at: held, to: root) } }
        let page = origin + "/page/slow-long-extension"
        browser.loadURLString(page)
        check(await W268DownloadAcceptance.wait(10) { browser.currentURLString == page && !runtime.navigationState.isLoading }, "page ready")
        await rig.settle()
        var savedInode: NSNumber?
        let legacy = getenv("TATWO_W281_NO_STAGE") != nil
        if legacy {
            print("W281f SKIP initial 255-byte ASCII extension download in NO_STAGE: unchanged CEF Continue(final) interrupts at 255 ASCII bytes; staged run covers it")
            try Data(repeating: 120, count: 2 * 1024 * 1024).write(to: path, options: .withoutOverwriting)
            savedInode = try fm.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
        }
        for kind in (legacy ? ["collision", "missing-root"] : ["initial", "collision", "missing-root"]) {
            if kind == "missing-root" { try fm.moveItem(at: root, to: held) }
            let ids = Set(downloads.downloads.map(\.id))
            check(try await W268DownloadAcceptance.nativeClick(browser, in: rig), kind + " human click")
            check(await W268DownloadAcceptance.wait(15) { downloads.downloads.contains { !ids.contains($0.id) && $0.state.isTerminal } }, kind + " terminal event")
            let final = downloads.downloads.first { !ids.contains($0.id) && $0.state.isTerminal }
            if kind == "initial" {
                check(final?.done == true && final?.filename == name && name.utf8.count == 255, "255-byte extension filename downloads without collision")
                savedInode = try fm.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
            } else {
                check(final?.state == .failed && final?.filename == name, kind + " no legal candidate fails with original filename")
            }
            let preserved = kind == "missing-root" ? held.appendingPathComponent(name) : path
            check((try? Data(contentsOf: preserved)) == Data(repeating: 120, count: 2 * 1024 * 1024) && (try? fm.attributesOfItem(atPath: preserved.path)[.systemFileNumber] as? NSNumber) == savedInode, kind + " existing bytes and inode unchanged")
            if kind == "missing-root" { check(!fm.fileExists(atPath: root.path), "missing Downloads is never created as a file") }
        }
        print("W281f extension SUMMARY failures=\(failures)")
        return failures == 0
    }
    static func longNames(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                          runtime: BrowserWorkSpaceRuntime, origin: String, folder: URL) async throws -> Bool {
        let fm = FileManager.default, downloads = BrowserDownloadStore.shared
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let record = folder.appendingPathComponent("w281f-stage.txt")
        let legacy = getenv("TATWO_W281_NO_STAGE") != nil
        let red = getenv("TATWO_W281F_RED_ONLY") != nil
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("W281f \(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        setenv("TATWO_W281_STAGE_RECORD", record.path, 1)
        defer { unsetenv("TATWO_W281_STAGE_RECORD"); unsetenv("TATWO_W281_SWAP_FAIL") }
        if legacy { print("W281f SKIP 255-byte ASCII CEF original/collision/EXCL/UUID cases in NO_STAGE: unchanged CEF Continue(final) interrupts at 255 ASCII bytes; helper and staged run cover them") }
        for kind in (red ? ["zh", "ascii240"] : legacy ? ["zh", "zh-edge", "zh-collision", "ascii240"] : ["zh", "zh-edge", "zh-collision", "ascii240", "ascii", "collision", "excl", "uuid"]) {
            let stem = kind == "zh" ? String(repeating: "報告", count: 40) : kind.hasPrefix("zh-") ? String(repeating: "報", count: 83) : String(repeating: kind == "excl" ? "b" : "a", count: kind == "ascii240" ? 240 : 251)
            let name = stem + ".bin"
            let expected = kind == "collision" ? String(repeating: "a", count: 247) + " (1).bin" : kind == "zh-collision" ? String(repeating: "報", count: 82) + " (1).bin" : kind == "excl" && !legacy ? String(repeating: "b", count: 247) + " (1).bin" : name
            let original = root.appendingPathComponent(name)
            if kind == "uuid" {
                // Exhaust all 99 reservations; each file is owned by this isolated fixture.
                for i in 1...99 {
                    let path = root.appendingPathComponent(String(repeating: "a", count: 251 - " (\(i))".utf8.count) + " (\(i)).bin")
                    if !fm.fileExists(atPath: path.path) { try Data("user".utf8).write(to: path, options: .withoutOverwriting) }
                }
            }
            if kind == "excl" && !legacy { setenv("TATWO_W281_SWAP_FAIL", "1", 1) }
            try? fm.removeItem(at: record)
            let page = origin + "/page/slow-long-" + kind
            browser.loadURLString(page)
            check(await W268DownloadAcceptance.wait(10) { browser.currentURLString == page && !runtime.navigationState.isLoading }, kind + " page ready")
            await rig.settle()
            let ids = Set(downloads.downloads.map(\.id))
            let originalBytes = try? Data(contentsOf: original)
            let originalInode = try? fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
            check(try await W268DownloadAcceptance.nativeClick(browser, in: rig), kind + " human click")
            check(await W268DownloadAcceptance.wait(10) { downloads.downloads.contains { !ids.contains($0.id) && ($0.received > 0 || $0.state.isTerminal) } }, kind + " writing or interrupted")
            let activeStage = (try? String(contentsOf: record)).map { URL(fileURLWithPath: $0) }
            if !legacy {
                let actual = try fm.contentsOfDirectory(atPath: root.path).first { $0 == activeStage?.lastPathComponent }
                print("W281f DISK kind=\(kind) actualHiddenBytes=\(actual?.utf8.count ?? 0)")
                check(actual.map { $0.utf8.count <= 153 } == true, kind + " actual hidden file exists and <=153 bytes")
            }
            check(await W268DownloadAcceptance.wait(15) { downloads.downloads.contains { !ids.contains($0.id) && $0.state.isTerminal } }, kind + " terminal event")
            guard let final = downloads.downloads.first(where: { !ids.contains($0.id) && $0.state.isTerminal }) else { continue }
            let stage = (try? String(contentsOf: record)).map { URL(fileURLWithPath: $0) }
            print("W281f ACTUAL kind=\(kind) inputBytes=\(name.utf8.count) stageBytes=\(stage?.lastPathComponent.utf8.count ?? 0) finalBytes=\(final.filename.utf8.count) state=\(final.state.rawValue) error=\(final.failure ?? "none")")
            check(final.done, kind + " download completed")
            check(final.filename.utf8.count <= 255, kind + " final <=255 bytes")
            if kind == "uuid" {
                let prefix = String(final.filename.prefix(36))
                check(UUID(uuidString: prefix) != nil && final.filename.dropFirst(36).hasPrefix("-") && final.filename.hasSuffix(".bin") && final.filename.utf8.count == 255, "UUID fallback bounded with extension")
            } else { check(final.filename == expected, kind + " exact final filename") }
            check((try? Data(contentsOf: final.fileURL)) == Data(repeating: 120, count: 2 * 1024 * 1024), kind + " correct downloaded bytes")
            let expectedMode = legacy ? 0o600 : 0o644
            check((try? fm.attributesOfItem(atPath: final.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == expectedMode, kind + " mode " + String(format: "%04o", expectedMode))
            if legacy { check(stage == nil, kind + " legacy has no hidden staging") }
            else { check(stage.map { $0.lastPathComponent.utf8.count <= 153 && $0.lastPathComponent.hasSuffix(".tatwo-download") && !fm.fileExists(atPath: $0.path) } == true, kind + " actual hidden stage <=153 bytes and removed") }
            if let originalBytes { check((try? Data(contentsOf: original)) == originalBytes && (try? fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber) == originalInode, kind + " original bytes and inode unchanged") }
            unsetenv("TATWO_W281_SWAP_FAIL")
        }
        print("W281f SUMMARY failures=\(failures)")
        return failures == 0
    }
    static func collisions(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                           runtime: BrowserWorkSpaceRuntime, origin: String, folder: URL) async throws -> Bool {
        let fm = FileManager.default, downloads = BrowserDownloadStore.shared
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let original = root.appendingPathComponent("slow.bin")
        try Data("original user bytes".utf8).write(to: original, options: .withoutOverwriting)
        let originalInode = try fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("W281b \(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        func listing(_ phase: String) throws {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ls")
            process.arguments = ["-laie", root.path]; process.standardOutput = pipe
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            try data.write(to: folder.appendingPathComponent("w281b-" + phase + ".ls.txt"))
        }
        func shot(_ phase: String) async throws {
            await rig.settle(1)
            guard let cached = rig.capture(), let capture = GlobalDMChatAcceptance.captureOwnWindow(cached),
                  let png = capture.bitmap.representation(using: .png, properties: [:]) else { throw TapError.remote("collision screenshot unavailable") }
            try png.write(to: folder.appendingPathComponent("w281b-" + phase + ".png"))
        }
        browser.loadURLString(origin + "/page/slow")
        check(await W268DownloadAcceptance.wait(10) { browser.currentURLString == origin + "/page/slow" && !runtime.navigationState.isLoading }, "collision page ready")
        await rig.settle()
        var firstBytes: Data?, firstInode: NSNumber?
        for number in 1...2 {
            let expected = "slow (\(number)).bin"
            let ids = Set(downloads.downloads.map(\.id))
            check(try await W268DownloadAcceptance.nativeClick(browser, in: rig), "collision human click \(number)")
            var item: BrowserDownloadStore.Item?
            check(await W268DownloadAcceptance.wait(10) {
                item = downloads.downloads.first { !ids.contains($0.id) }
                return item != nil
            }, "collision event received")
            guard let item else { continue }
            print("W281b ACTUAL filename=\(item.filename) expected=\(expected)")
            check(item.filename == expected, "collision final filename \(expected)")
            if number == 1 { try listing("start") }
            check(await W268DownloadAcceptance.wait(10) { (downloads.downloads.first { $0.id == item.id }?.received ?? 0) > 0 }, "collision transfer writing")
            if number == 1 { try listing("progress"); try await shot("progress") }
            check(await W268DownloadAcceptance.wait(20) { downloads.downloads.first { $0.id == item.id }?.state.isTerminal == true }, "collision terminal event")
            let final = downloads.downloads.first { $0.id == item.id }
            check(final?.done == true && final?.filename == expected && downloads.feedback?.filename == expected,
                  "collision completed event and card \(expected)")
            if number == 1 { try listing("complete"); try await shot("complete") }
            let actualNames = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("slow") || $0.hasSuffix("-slow.bin") }.sorted()
            check(actualNames == (["slow.bin"] + (1...number).map { "slow (\($0)).bin" }).sorted(), "collision only original plus numbered downloads actual=\(actualNames)")
            check((try? Data(contentsOf: original)) == Data("original user bytes".utf8) &&
                  (try? fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber) == originalInode, "collision original bytes and inode unchanged")
            let first = root.appendingPathComponent("slow (1).bin")
            if number == 1 { firstBytes = try? Data(contentsOf: first); firstInode = try? fm.attributesOfItem(atPath: first.path)[.systemFileNumber] as? NSNumber }
            else { check(firstBytes == (try? Data(contentsOf: first)) && firstInode == (try? fm.attributesOfItem(atPath: first.path)[.systemFileNumber] as? NSNumber), "collision (1) bytes and inode unchanged") }
            check((try? Data(contentsOf: root.appendingPathComponent(expected))) == Data(repeating: 120, count: 2 * 1024 * 1024), "collision downloaded bytes")
        }
        print("W281b SUMMARY failures=\(failures)")
        return failures == 0
    }
    static func run(browser: TatwoCEFBrowserView, rig: TatwoComposerModeAcceptance.ClickRig,
                    runtime: BrowserWorkSpaceRuntime, origin: String, folder: URL) async throws -> Bool {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let downloads = BrowserDownloadStore.shared
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("W281 \(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        func inode(_ url: URL) -> UInt64? {
            (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        let record = folder.appendingPathComponent("w281-stage.txt")
        setenv("TATWO_W281_STAGE_RECORD", record.path, 1)
        defer { unsetenv("TATWO_W281_STAGE_RECORD"); unsetenv("TATWO_W281_NO_STAGE"); unsetenv("TATWO_W281_PUBLISH_FAIL"); unsetenv("TATWO_W281_SWAP_FAIL"); unsetenv("TATWO_W281_PROBE_FAIL") }
        browser.loadURLString(origin + "/document.pdf")
        check(await W268DownloadAcceptance.wait(15) { browser.currentURLString == origin + "/document.pdf" && browser.currentDocumentIsPDF && runtime.navigationState.phase == .finished && !runtime.navigationState.isLoading }, "local PDF document ready")
        await rig.settle()
        var pdfReplied = false, pdfPath: String?
        browser.downloadCurrentPDF { path in pdfPath = path; pdfReplied = true }
        check(await W268DownloadAcceptance.wait(15) { pdfReplied }, "W57d completion received")
        let pdfItem = downloads.downloads.first { $0.filename == "document.pdf" }
        print("W281 PDF completion=\(pdfPath ?? "nil") event=\(pdfItem?.fileURL.path ?? "none") state=\(pdfItem?.state.rawValue ?? "none") phase=\(runtime.navigationState.phase)")
        check(pdfPath == pdfItem?.fileURL.path && pdfItem?.done == true && pdfPath?.hasPrefix(root.path + "/") == true,
              "W57d completion gets published final path; W57dIsPDF accepted it")
        for kind in ["user", "link-existing", "link-missing", "deleted", "cancel", "broken", "swap-failure", "publish-failure", "probe-failure", "fallback", "close"] {
            let name = kind == "broken" ? "broken-w281" : "slow-w281-" + kind
            let path = root.appendingPathComponent(name + ".bin")
            let retained = folder.appendingPathComponent(name + "-reservation")
            let victim = folder.appendingPathComponent(name + "-victim")
            if kind == "swap-failure" { setenv("TATWO_W281_SWAP_FAIL", "1", 1) }
            if kind == "probe-failure" { setenv("TATWO_W281_PROBE_FAIL", "1", 1) }
            if kind == "publish-failure" { setenv("TATWO_W281_PUBLISH_FAIL", "1", 1) }
            if kind == "fallback" { setenv("TATWO_W281_NO_STAGE", "1", 1) }
            try? fm.removeItem(at: record)
            let page = origin + "/page/" + name
            browser.loadURLString(page)
            check(await W268DownloadAcceptance.wait(10) { browser.currentURLString == page && !runtime.navigationState.isLoading }, kind + " page ready")
            await rig.settle()
            check(try await W268DownloadAcceptance.nativeClick(browser, in: rig), kind + " human download click")
            var transfer: BrowserDownloadStore.Item?
            check(await W268DownloadAcceptance.wait(10) {
                transfer = downloads.downloads.first { $0.filename == name + ".bin" }
                return (transfer?.received ?? 0) > 0
            }, kind + " transfer writing")
            guard let transfer else { continue }
            let stage = (try? String(contentsOf: record))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reservationInode = inode(path)
            var preservedInode: UInt64?, victimInode: UInt64?
            if ["user", "link-existing", "link-missing", "deleted"].contains(kind) {
                // DEBUG mid-transfer hook: retain the original inode so it cannot be reused.
                try fm.moveItem(at: path, to: retained)
                if kind == "user" { try Data("user bytes".utf8).write(to: path, options: .withoutOverwriting) }
                if kind == "link-existing" { try Data("victim bytes".utf8).write(to: victim); victimInode = inode(victim) }
                if kind.hasPrefix("link-") { try fm.createSymbolicLink(atPath: path.path, withDestinationPath: victim.path) }
                preservedInode = inode(path)
            }
            if kind == "cancel" { check(browser.cancelDownload(transfer.id), "cancel accepted") }
            if kind == "close" { await browser.closeBrowser() }
            check(await W268DownloadAcceptance.wait(kind == "broken" ? 40 : 20) {
                downloads.downloads.first { $0.id == transfer.id }?.state.isTerminal == true
            }, kind + " terminal event")
            let final = downloads.downloads.first { $0.id == transfer.id }
            print("W281 DISK \(kind) final=\(final?.fileURL.lastPathComponent ?? "none") beforeInode=\(preservedInode ?? 0) afterInode=\(inode(path) ?? 0) victimExists=\(fm.fileExists(atPath: victim.path)) victimBytes=\((try? Data(contentsOf: victim).count) ?? -1)")
            if ["cancel", "broken", "close"].contains(kind) {
                check(final?.state != .completed && !fm.fileExists(atPath: path.path), kind + " no Downloads residue")
                check((try? fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(name) }.isEmpty) == true, kind + " no partial file residue")
                check(await W268DownloadAcceptance.wait(5) { stage.map { !fm.fileExists(atPath: $0) } == true }, kind + " hidden temporary file removed")
                if kind == "broken", let final {
                    check(final.state == .failed && downloads.revealURL(final) == nil, "W281d network interruption without file has no Finder action")
                }
            } else if kind == "publish-failure" {
                let stagedFile = stage.map { URL(fileURLWithPath: $0) }
                check(final?.state == .failed && inode(path) == reservationInode && (try? Data(contentsOf: path)) == Data(), "W281c failed publication keeps original empty reservation")
                check(stagedFile.flatMap { try? Data(contentsOf: $0) } == Data(repeating: 120, count: 2 * 1024 * 1024), "S2 downloaded bytes retained in private staging")
                check(stagedFile.map { final?.fileURL == $0 && final?.failure?.contains($0.path) == false } == true, "W281c failure event gives retained file URL without path in message")
                check(final?.failure?.contains("excl") == true && final?.failure?.contains("errno=1 EPERM") == true && stagedFile.map { final?.failure?.contains($0.lastPathComponent) == true } == true, "W281c failure card step errno filename")
                check(stage.map { URL(fileURLWithPath: $0).deletingLastPathComponent() == root && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("." + name + ".bin.") && URL(fileURLWithPath: $0).lastPathComponent.hasSuffix(".tatwo-download") } == true, "W281c failed bytes retained inside Downloads hidden file")
                check(final.map { downloads.revealURL($0) == stagedFile && downloads.feedback == $0 } == true, "W281d failure card and list revealURL selects actual hidden retained file")
                await rig.settle(1)
                if let cached = rig.capture(), let capture = GlobalDMChatAcceptance.captureOwnWindow(cached), let png = capture.bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: folder.appendingPathComponent("w281c-failure-card.png"))
                } else { check(false, "W281c failure card screenshot") }
                print("W281b S2 error=\(final?.failure ?? "none")")
                unsetenv("TATWO_W281_PUBLISH_FAIL")
            } else if kind == "swap-failure" {
                let numbered = root.appendingPathComponent(name + " (1).bin")
                check(final?.done == true && final?.fileURL == numbered && (try? Data(contentsOf: numbered)) == Data(repeating: 120, count: 2 * 1024 * 1024), "W281c SWAP EPERM publishes numbered file")
                check(!fm.fileExists(atPath: path.path) && stage.map { !fm.fileExists(atPath: $0) } == true, "W281c SWAP fallback cleans own empty reservation and temporary file")
                check(final?.failure?.contains("swap") == true && final?.failure?.contains("errno=1 EPERM") == true && final?.failure?.contains(root.path) == false, "W281c SWAP fallback message step errno without path")
                unsetenv("TATWO_W281_SWAP_FAIL")
            } else if kind == "fallback" || kind == "probe-failure" {
                check(stage == nil && final?.done == true && (try? Data(contentsOf: path)) == Data(repeating: 120, count: 2 * 1024 * 1024), "forced staging failure uses legacy completion")
                unsetenv("TATWO_W281_NO_STAGE"); unsetenv("TATWO_W281_PROBE_FAIL")
            } else {
                let expected = kind == "deleted" ? path : root.appendingPathComponent(name + " (1).bin")
                check(final?.done == true && final?.fileURL == expected && (try? Data(contentsOf: expected)) == Data(repeating: 120, count: 2 * 1024 * 1024), kind + " download published without overwrite")
                if kind == "deleted" {
                    check(final?.failure == nil && downloads.feedback?.id == final?.id && downloads.feedback?.failure == nil,
                          "W281d deleted reservation completes at original filename with no card error")
                }
                if kind == "user" { check(inode(path) == preservedInode && (try? Data(contentsOf: path)) == Data("user bytes".utf8), "user content and inode unchanged") }
                if kind.hasPrefix("link-") {
                    check(inode(path) == preservedInode && (try? fm.destinationOfSymbolicLink(atPath: path.path)) == victim.path, kind + " symlink unchanged")
                    check(kind == "link-existing" ? inode(victim) == victimInode && (try? Data(contentsOf: victim)) == Data("victim bytes".utf8) : !fm.fileExists(atPath: victim.path), kind + " victim unchanged / missing target absent")
                }
                check(stage.map { !fm.fileExists(atPath: $0) } == true, kind + " hidden temporary file removed")
            }
            if kind == "close" {
                // The closed mount is replaced through the existing workspace runtime.
                break
            }
        }
        let failedFile = downloads.downloads.first { $0.state == .failed && $0.filename.hasPrefix(".slow-w281-publish-failure.bin.") }
        check((try? Data(contentsOf: root.appendingPathComponent("slow-w281-publish-failure.bin"))) == Data() &&
              failedFile.flatMap { try? Data(contentsOf: $0.fileURL) } == Data(repeating: 120, count: 2 * 1024 * 1024), "W281c failed reservation and bytes survive tab close and late callbacks")
        if let telemetryPath = ProcessInfo.processInfo.environment["TATWO_CEF_EMBEDDING_TELEMETRY_PATH"], let telemetry = try? String(contentsOfFile: telemetryPath) {
            let lines = telemetry.components(separatedBy: .newlines).filter { $0.contains("phase=download_publish") || $0.contains("phase=download_stage") }
            try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("w281c-telemetry.log"), atomically: true, encoding: .utf8)
            check(lines.filter { $0.contains("phase=download_publish step=swap errno=1") && $0.contains("slow-w281-swap-failure") }.count == 1, "W281c SWAP telemetry exactly one line")
            check(lines.filter { $0.contains("phase=download_publish step=excl errno=1") && $0.contains("slow-w281-publish-failure") }.count == 1, "W281c EXCL telemetry exactly one line")
            check(lines.contains { $0.contains("phase=download_stage errno=1") && $0.contains("slow-w281-probe-failure") }, "W281c failed same-directory probe telemetry")
            check(lines.allSatisfy { !$0.contains(root.path) }, "W281c telemetry has no full path")
        } else { check(false, "W281c telemetry available") }
        print("W281 SUMMARY failures=\(failures)")
        return failures == 0
    }
}
#endif
