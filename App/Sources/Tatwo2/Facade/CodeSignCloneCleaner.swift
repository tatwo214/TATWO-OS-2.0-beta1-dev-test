// W180 B3：清掉舊的簽章副本。
// App 內建的 Chromium 每次啟動會在 `$(getconf DARWIN_USER_TEMP_DIR)/../X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX/`
// 放一份整個 App 的複本（主執行檔是硬連結、其他檔是 APFS clone），正常結束時自己收；
// App 被換掉或強制結束時收不到，舊版本那份就一直佔著（約 1.2 GB，舊檔換掉後才真的佔空間）。
// install.sh（W151）在 App 沒開著時會先清；安裝當下 App 還開著、或不是用 install.sh 裝的，就會留下來——這裡補上。
// 做法：新版本第一次啟動、跑穩一段時間之後清一次。只動上面那個資料夾裡 `code_sign_clone.` 開頭的資料夾；
// 保留最新一份、目前這個進程在用的那份（主執行檔是同一個檔）、十分鐘內剛建的；其餘刪。
// 認不出自己在用哪份就整批不動。失敗不影響啟動，結果寫一行到 App 自己的紀錄
//（Application Support/tatwo2/logs/code-sign-clone.log）。不改 install.sh。
import Darwin
import Foundation

enum CodeSignCloneCleaner {
    static let bundleID = "ai.tatwo.tatwo2"
    static let folderName = bundleID + ".code_sign_clone"
    static let clonePrefix = "code_sign_clone."
    /// 新版本啟動後等多久才清（先確認自己正常跑起來）。
    static let launchDelay: TimeInterval = 120
    /// 太新的副本不動（可能是另一份正在啟動）。
    static let recentGuard: TimeInterval = 600
    static let cleanedKey = "tatwo.codeSignClone.cleaned"

    /// 檔案身分（同一個檔＝同一個 device＋inode；硬連結也一樣）。
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        static func of(_ path: String) -> FileIdentity? {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        }
    }

    struct Candidate: Equatable, Sendable {
        let url: URL
        let modified: Date
        /// 副本裡的主執行檔（`*/Contents/MacOS/<執行檔名>`）；讀不到就是空的。
        let executables: [FileIdentity]
    }

    struct Plan: Equatable, Sendable {
        var keep: [Candidate] = []
        var remove: [Candidate] = []
    }

    struct Outcome: Equatable, Sendable {
        var removed: [String] = []
        var kept: [String] = []
        var failed: [String] = []
        var skipped: String?

        var logLine: String {
            if let skipped { return "沒有清：\(skipped)" }
            var line = "清舊簽章副本：刪 \(removed.count) 份、留 \(kept.count) 份"
            if !failed.isEmpty { line += "、刪不掉 \(failed.count) 份（\(failed.joined(separator: "、"))）" }
            if !removed.isEmpty { line += "；刪的是 " + removed.joined(separator: "、") }
            return line
        }
    }

    // MARK: 挑選（純邏輯）

    /// 保留：最新一份、目前進程在用的那份、太新的；其餘刪。認不出目前在用哪份（running＝nil）就全部保留。
    static func plan(_ candidates: [Candidate], running: FileIdentity?, now: Date,
                     recentGuard: TimeInterval = CodeSignCloneCleaner.recentGuard) -> Plan {
        var plan = Plan()
        let ordered = candidates.sorted { $0.modified > $1.modified }
        guard let running else {
            plan.keep = ordered
            return plan
        }
        for (index, candidate) in ordered.enumerated() {
            let isNewest = index == 0
            let inUse = candidate.executables.contains(running)
            let isRecent = now.timeIntervalSince(candidate.modified) < recentGuard
            if isNewest || inUse || isRecent { plan.keep.append(candidate) } else { plan.remove.append(candidate) }
        }
        return plan
    }

    // MARK: 找資料夾、掃副本、刪

    /// `…/T/` 的上一層的 `X/ai.tatwo.tatwo2.code_sign_clone`。
    static func folder(userTempDirectory: String) -> URL {
        URL(fileURLWithPath: userTempDirectory, isDirectory: true).standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("X", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// 同 `getconf DARWIN_USER_TEMP_DIR`（不看 TMPDIR，它可能被改過）。
    static func userTempDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
        return path.isEmpty ? nil : path
    }

    /// 只列 `code_sign_clone.` 開頭、本身是資料夾（不是捷徑）的項目。
    static func scan(folder: URL, executableName: String) -> [Candidate] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasPrefix(clonePrefix) }.sorted().compactMap { name -> Candidate? in
            let url = folder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            let bundles = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let executables = bundles.sorted().compactMap { bundle in
                FileIdentity.of(url.appendingPathComponent(bundle)
                    .appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent(executableName).path)
            }
            return Candidate(url: url, modified: modified, executables: executables)
        }
    }

    static func clean(folder: URL, executableName: String, running: FileIdentity?, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        guard FileManager.default.fileExists(atPath: folder.path) else {
            outcome.skipped = "沒有副本資料夾"
            return outcome
        }
        guard running != nil else {
            outcome.skipped = "認不出目前在用哪一份，這次不動"
            return outcome
        }
        let selection = Self.plan(scan(folder: folder, executableName: executableName), running: running, now: now)
        outcome.kept = selection.keep.map(\.url.lastPathComponent)
        let base = folder.standardizedFileURL.path + "/"
        for candidate in selection.remove {
            let name = candidate.url.lastPathComponent
            let path = candidate.url.standardizedFileURL.path
            // 再確認一次：就在這個資料夾底下一層、名字對、仍是資料夾不是捷徑。
            var info = stat()
            guard path.hasPrefix(base), !path.dropFirst(base.count).contains("/"), name.hasPrefix(clonePrefix),
                  lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                outcome.failed.append(name)
                continue
            }
            do {
                try FileManager.default.removeItem(at: candidate.url)
                outcome.removed.append(name)
            } catch {
                outcome.failed.append(name)
            }
        }
        return outcome
    }

    // MARK: 紀錄

    static var logsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tatwo2/logs", isDirectory: true)
    }

    static func appendLog(_ message: String, in directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("code-sign-clone.log")
        let line = "\(ISO8601DateFormatter().string(from: now)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: 啟動後排一次

    @MainActor private static var scheduled = false

    /// 主視窗第一個畫面出來後呼叫。只有正式安裝的 App（bundle id 對）、這個版本這個執行檔還沒清過才排；
    /// 等 `launchDelay` 秒（確認跑得起來）再在背景清。自測、匯出畫面時不做。
    @MainActor static func scheduleAfterLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !scheduled else { return }
        scheduled = true
        guard environment["TATWO2_SELFTEST"] == nil,
              !environment.keys.contains(where: { $0.hasPrefix("TATWO_ULTRAWORK_EXPORT_") }),
              Bundle.main.bundleIdentifier == bundleID,
              let executable = Bundle.main.executableURL,
              let temp = userTempDirectory()
        else { return }
        // 啟動當下就記住自己的主執行檔：之後 App 若被換掉，同一個路徑會指到新檔。
        let running = FileIdentity.of(executable.path)
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let stamp = "\(build):\(running.map { String($0.inode) } ?? "?")"
        guard UserDefaults.standard.string(forKey: cleanedKey) != stamp else { return }
        let name = executable.lastPathComponent
        let target = folder(userTempDirectory: temp)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + launchDelay) {
            let outcome = Self.clean(folder: target, executableName: name, running: running)
            UserDefaults.standard.set(stamp, forKey: Self.cleanedKey)
            if let logs = Self.logsDirectory { Self.appendLog("build \(build) " + outcome.logLine, in: logs) }
        }
    }
}
