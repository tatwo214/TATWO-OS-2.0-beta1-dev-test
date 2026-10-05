#if DEBUG
import Darwin
import Foundation

/// W180 E1b 自測：`TATWO2_SELFTEST=w180memsync`。
/// 兩個暫存入口（主設備、副設備）各有自己的 memory/ git 倉、設備身分、配對名單與真的 SSH 簽章；
/// RPC 在同一個行程裡注入（照 W78 DeviceDispatch 的 rpc／push 注入法），fetch／push 是本機路徑的 git。
/// 注入的 RPC 跟真的一樣：主設備的錯誤用 String(describing:) 變成字串、包成 remote_error；離線丟的是傳輸錯誤。
/// 不是實機兩台的 SSH 端到端；全部在假 HOME 底下（真 HOME 直接拒跑），不碰真的入口與記憶。
enum TatwoMemorySyncAcceptance {
    final class Checker: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failures = 0
        func callAsFunction(_ condition: Bool, _ label: String) {
            lock.lock(); defer { lock.unlock() }
            if condition { print("W180MEMSYNC PASS \(label)") } else { failures += 1; print("W180MEMSYNC FAIL \(label)") }
        }
    }

    /// 自測開關：主設備在不在線、外接卷有沒有掛上、fetch 之後要不要讓主設備再改一筆。
    final class Switches: @unchecked Sendable {
        var online = true
        var primaryMounted = true
        var afterFetch: (() -> Void)?
        /// 簽完章、送到主設備之前等多久（模擬兩條 SSH 連線到達順序顛倒）。
        var rpcDelay: (() -> TimeInterval)?
        /// 主設備還是舊版 App：不認得 memory_sync_*（SSH 轉進來的呼叫回 caller_not_trusted）。
        var legacyPrimary = false
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value - 1
        }
    }

    struct World {
        let base: URL
        let pPaths: EngineMemoryPaths
        let sPaths: EngineMemoryPaths
        let unmounted: EngineMemoryPaths
        let pID: String
        let sID: String
        let primaryDispatch: DeviceDispatch
        let secondaryDispatch: DeviceDispatch
        let primaryEngine: TatwoMemorySyncEngine
        let secondaryEngine: TatwoMemorySyncEngine
        let switches: Switches
        let primaryFirst: String
        let secondaryFirst: String
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let check = Checker()
        let environment = ProcessInfo.processInfo.environment
        guard let fakeHome = environment["HOME"], !fakeHome.isEmpty, let account = getpwuid(getuid()),
              let realHome = account.pointee.pw_dir,
              URL(fileURLWithPath: fakeHome).standardizedFileURL.path != URL(fileURLWithPath: String(cString: realHome)).standardizedFileURL.path
        else {
            print("W180MEMSYNC FAIL isolated HOME required")
            print("W180MEMSYNC SUMMARY failures=1")
            return 1
        }
        let base = URL(fileURLWithPath: fakeHome).appendingPathComponent("w180memsync-" + UUID().uuidString.prefix(8))
        let done = DispatchSemaphore(value: 0)
        let holder = Box<World?>(nil)
        // git 一律不在主執行緒：準備也在背景。
        DispatchQueue.global(qos: .userInitiated).async {
            do { holder.value = try setUp(base) } catch { check(false, "setup: \(error.localizedDescription)") }
            done.signal()
        }
        done.wait()
        guard let world = holder.value else {
            print("W180MEMSYNC SUMMARY failures=\(max(check.failures, 1))")
            return 1
        }

        // 主執行緒：runOnce 直接擋下（不跑 git）；trigger 立刻回來，同步在背景佇列做。
        let refusedBefore = TatwoMemorySyncEngine.runsRefusedOnMainThread
        let gitBefore = TatwoMemorySyncEngine.gitAttemptsOnMainThread
        _ = world.secondaryEngine.runOnce()
        check(TatwoMemorySyncEngine.runsRefusedOnMainThread == refusedBefore + 1
              && TatwoMemorySyncEngine.gitAttemptsOnMainThread == gitBefore, "main thread: runOnce refused, no git on main")
        let started = Date()
        world.secondaryEngine.trigger(.manual)
        let elapsed = Date().timeIntervalSince(started)
        check(elapsed < 0.2, "main thread: trigger returns at once (\(Int(elapsed * 1000)) ms), sync runs in the background")

        DispatchQueue.global(qos: .userInitiated).async {
            world.secondaryEngine.queue.sync {}
            do {
                try scenarios(world, check)
            } catch {
                check(false, "unexpected error: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        check(TatwoMemorySyncEngine.gitAttemptsOnMainThread == 0, "no git on the main thread during any sync")
        try? FileManager.default.removeItem(at: base)
        print("W180MEMSYNC SUMMARY failures=\(check.failures)")
        return check.failures == 0 ? 0 : 1
    }

    // MARK: 準備：兩個入口、身分、配對、簽章金鑰、兩段互不相關的記憶歷史

    static func setUp(_ base: URL) throws -> World {
        let fm = FileManager.default
        let pRoot = base.appendingPathComponent("primary"), sRoot = base.appendingPathComponent("secondary")
        let pEntryRoot = pRoot.appendingPathComponent("entry"), sEntryRoot = sRoot.appendingPathComponent("entry")
        for dir in [pEntryRoot, sEntryRoot, pRoot.appendingPathComponent("live"), sRoot.appendingPathComponent("live"),
                    pRoot.appendingPathComponent("home"), sRoot.appendingPathComponent("home")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": pEntryRoot.path], preference: nil)
        let sEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": sEntryRoot.path], preference: nil)
        let pID = "11111111-1111-4111-8111-111111111111", sID = "22222222-2222-4222-8222-222222222222"
        try DeviceIdentity(deviceID: pID, name: "Primary One", hardwareModel: "Fixture", role: .primary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: pEntry.deviceJSON)
        try DeviceIdentity(deviceID: sID, name: "Fixture", hardwareModel: "Fixture", role: .secondary, epoch: 1,
                           primaryDeviceID: pID, updatedAt: Date()).encoded().write(to: sEntry.deviceJSON)
        let key = base.appendingPathComponent("paired-key"), hostKey = base.appendingPathComponent("host-key")
        for path in [key, hostKey] {
            let (status, _) = try DeviceDispatch.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path])
            guard status == 0 else { throw TatwoMemorySyncEngine.Failure(reason: "ssh-keygen failed") }
        }
        let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let publicHost = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
        let pRegistry = DeviceRegistry(root: pRoot.appendingPathComponent("live"),
                                       authorizedKeysURL: pRoot.appendingPathComponent("authorized_keys"))
        let sRegistry = DeviceRegistry(root: sRoot.appendingPathComponent("live"),
                                       authorizedKeysURL: sRoot.appendingPathComponent("authorized_keys"))
        let fingerprint = try pRegistry.authorize(publicKey: publicKey, deviceID: sID)
        let pPeer = DeviceRecord(id: pID, name: "Primary One", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                 publicKeyFingerprint: try DeviceRegistry.fingerprint(publicKey: publicHost),
                                 addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .primary, epoch: 1)
        let sPeer = DeviceRecord(id: sID, name: "Fixture", host: "127.0.0.1", user: "fixture", sshPort: 1,
                                 publicKeyFingerprint: fingerprint, addedAt: Date(), lastSeenAt: Date(),
                                 workdirMap: [:], role: .secondary, epoch: 1)
        _ = try pRegistry.add(sPeer)
        _ = try sRegistry.add(pPeer)

        let pPaths = EngineMemoryPaths(home: pRoot.appendingPathComponent("home").path, entryRoot: pEntryRoot)
        let sPaths = EngineMemoryPaths(home: sRoot.appendingPathComponent("home").path, entryRoot: sEntryRoot)
        let unmounted = EngineMemoryPaths(home: pRoot.appendingPathComponent("home").path,
                                          entryRoot: base.appendingPathComponent("unmounted/entry"))
        // 主設備的記憶：自己一段歷史。
        try EngineMemoryLinks.createMemoryFolder(pPaths.memory)
        try note(pPaths.memory, "primary-first.md", title: "主設備先有", body: "主設備原本就記著的一條。")
        try appendIndex(pPaths.memory, "- [主設備先有](primary-first.md) — 主設備原本就記著的一條")
        _ = EngineMemoryLinks.commit(pPaths.memory, message: "fixture：主設備原本的記憶")
        // 副設備在「等主設備同步」時自己建的：另一段互不相關的歷史。
        try EngineMemoryLinks.createMemoryFolder(sPaths.memory)
        try Data("20260927".utf8).write(to: sPaths.memory.appendingPathComponent(".git/" + EngineMemoryLinks.awaitingPrimaryMarker))
        try note(sPaths.memory, "secondary-first.md", title: "副設備先有", body: "副設備離線時記的一條。")
        try appendIndex(sPaths.memory, "- [副設備先有](secondary-first.md) — 副設備離線時記的一條")
        _ = EngineMemoryLinks.commit(sPaths.memory, message: "fixture：副設備自己建的記憶")
        guard let primaryFirst = head(pPaths.memory), let secondaryFirst = head(sPaths.memory) else {
            throw TatwoMemorySyncEngine.Failure(reason: "fixture memory not committed")
        }

        let switches = Switches()
        let primaryDispatch = DeviceDispatch(entry: pEntry, registry: pRegistry, retireBackup: { _ in })
        let primaryEngine = TatwoMemorySyncEngine(paths: { switches.primaryMounted ? pPaths : unmounted },
                                                  dispatch: primaryDispatch)
        let secondaryDispatch = DeviceDispatch(entry: sEntry, registry: sRegistry,
            environment: ["TATWO2_SSH_KEY_PATH": key.path], retireBackup: { _ in },
            rpc: { _, method, proof in
                guard switches.online else { throw RemoteHostLinkError.tunnelUnavailable }
                if let delay = switches.rpcDelay?() { Thread.sleep(forTimeInterval: delay) }
                if switches.legacyPrimary, method.hasPrefix("memory_sync_") {
                    throw RemoteHostLinkError.remoteError("caller_not_trusted")
                }
                do {
                    let (sender, payload) = try primaryDispatch.authenticate(method: method, proof: proof)
                    switch method {
                    case "memory_sync_target", "memory_sync_receive":
                        return try primaryEngine.handle(method: method, payload: payload, sender: sender)
                    default:
                        throw TatwoMemorySyncEngine.Failure(reason: "unexpected_fixture_rpc")
                    }
                } catch {
                    // 跟 OSAgentBridge 一樣：錯誤用 String(describing:) 回傳，RemoteHostLink 包成 remote_error。
                    throw RemoteHostLinkError.remoteError(String(describing: error))
                }
            })
        let secondaryEngine = TatwoMemorySyncEngine(paths: { sPaths }, dispatch: secondaryDispatch,
            fetch: { paths, repository in
                guard switches.online else { throw RemoteHostLinkError.tunnelUnavailable }
                let fetched = TatwoMemorySyncEngine.runGit(["fetch", "-q", "--no-tags", "--", repository,
                                                            "+HEAD:" + TatwoMemorySyncEngine.primaryRef], in: paths.memory)
                guard fetched.status == 0 else { throw TatwoMemorySyncEngine.Failure(reason: "fixture_fetch_failed") }
                if let hook = switches.afterFetch { switches.afterFetch = nil; hook() }
            },
            push: { paths, repository, commit, ref in
                guard switches.online else { throw RemoteHostLinkError.tunnelUnavailable }
                let pushed = TatwoMemorySyncEngine.runGit(["push", "-q", "--", repository, "\(commit):\(ref)"], in: paths.memory)
                guard pushed.status == 0 else { throw TatwoMemorySyncEngine.Failure(reason: "fixture_push_failed") }
            })
        return World(base: base, pPaths: pPaths, sPaths: sPaths, unmounted: unmounted, pID: pID, sID: sID,
                     primaryDispatch: primaryDispatch, secondaryDispatch: secondaryDispatch,
                     primaryEngine: primaryEngine, secondaryEngine: secondaryEngine, switches: switches,
                     primaryFirst: primaryFirst, secondaryFirst: secondaryFirst)
    }

    // MARK: 情境

    static func scenarios(_ w: World, _ check: Checker) throws {
        let p = w.pPaths.memory, s = w.sPaths.memory
        let fm = FileManager.default

        // 0. 第一次同步、兩段歷史不相關（主執行緒 trigger 的那一輪）：兩邊的檔都留下。
        let index = { (memory: URL) in text(memory.appendingPathComponent("MEMORY.md")) ?? "" }
        check(fm.fileExists(atPath: p.appendingPathComponent("secondary-first.md").path)
              && fm.fileExists(atPath: s.appendingPathComponent("primary-first.md").path)
              && fm.fileExists(atPath: p.appendingPathComponent("primary-first.md").path)
              && fm.fileExists(atPath: s.appendingPathComponent("secondary-first.md").path),
              "unrelated histories: both sides keep their files")
        check([p, s].allSatisfy { index($0).contains("(primary-first.md)") && index($0).contains("(secondary-first.md)") }
              && index(p).components(separatedBy: "# 記憶索引").count == 2,
              "unrelated histories: MEMORY.md keeps both sides' lines, header once")
        check(copies(p).isEmpty && copies(s).isEmpty, "unrelated histories: index and README merged by lines, no copies")
        check([p, s].allSatisfy { isAncestor($0, w.primaryFirst) && isAncestor($0, w.secondaryFirst) },
              "unrelated histories: both histories kept on both sides")
        check(!fm.fileExists(atPath: s.appendingPathComponent(".git/" + EngineMemoryLinks.awaitingPrimaryMarker).path),
              "first sync clears the awaiting-primary marker")
        check(treeID(p) == treeID(s) && w.secondaryEngine.status.state == .synced && w.secondaryEngine.status.pending == 0,
              "after first sync both sides identical, nothing pending")

        // 1. 副設備新增（像 Claude 寫的，沒 commit）→ 主設備收得到。
        try note(s, "from-secondary.md", title: "副設備記的", body: "在副設備記下的一條。")
        try note(s, "shared.md", title: "兩邊都會改", body: "原本的內容。")
        try note(s, "other.md", title: "另一條", body: "原本的另一條。")
        var status = w.secondaryEngine.runOnce(.change)
        check(text(p.appendingPathComponent("from-secondary.md")) == text(s.appendingPathComponent("from-secondary.md"))
              && tracked(p, "from-secondary.md") && status.state == .synced && status.pending == 0,
              "secondary add reaches the primary")
        check(clean(p) && gitText(p, ["log", "-1", "--format=%an <%ae>"]) == "TATWO OS <tatwo-os@localhost>",
              "primary working tree clean, commits authored by TATWO OS")
        check(gitText(p, ["for-each-ref", "refs/heads/inbox/"]).isEmpty, "primary clears the inbox branch after merging")

        // 2. 主設備新增（主設備定時 commit）→ 副設備拉得到；狀態寫「主設備・已記下」。
        try note(p, "from-primary.md", title: "主設備記的", body: "在主設備記下的一條。")
        let primaryStatus = w.primaryEngine.runOnce(.change)
        check(primaryStatus.isPrimary == true && primaryStatus.state == .synced && primaryStatus.line.hasPrefix("主設備・已記下")
              && tracked(p, "from-primary.md"), "primary commits on its own tick")
        status = w.secondaryEngine.runOnce(.timer)
        check(text(s.appendingPathComponent("from-primary.md")) == text(p.appendingPathComponent("from-primary.md"))
              && status.state == .synced, "primary add reaches the secondary")

        // 2b. 主設備收件時先 commit 本機（Claude 剛寫、還沒 commit 的不會被蓋掉）。
        try note(p, "claude-wrote.md", title: "Claude 剛寫", body: "主設備上 Claude 剛寫、還沒 commit。")
        try note(s, "second-round.md", title: "第二輪", body: "副設備第二輪記的。")
        _ = w.secondaryEngine.runOnce(.change)
        check(tracked(p, "claude-wrote.md") && tracked(p, "second-round.md") && clean(p),
              "primary receive commits what was written locally first; nothing lost")
        _ = w.secondaryEngine.runOnce(.timer)
        check(fm.fileExists(atPath: s.appendingPathComponent("claude-wrote.md").path) && treeID(p) == treeID(s),
              "next round brings it to the secondary")

        // 3. 同一檔兩邊都改（副設備合併時遇到）：主設備版留原名，這台的另存一份並標 conflict。
        try note(p, "shared.md", title: "兩邊都會改", body: "主設備改的內容。")
        _ = w.primaryEngine.runOnce(.change)
        try note(s, "shared.md", title: "兩邊都會改", body: "副設備改的內容。")
        status = w.secondaryEngine.runOnce(.change)
        let sharedCopiesS = copies(s, stem: "shared"), sharedCopiesP = copies(p, stem: "shared")
        let sharedCopy = sharedCopiesS.first.flatMap { text(s.appendingPathComponent($0)) } ?? ""
        check([p, s].allSatisfy { (text($0.appendingPathComponent("shared.md")) ?? "").contains("主設備改的內容") }
              && sharedCopiesS.count == 1 && sharedCopiesP == sharedCopiesS
              && sharedCopiesS[0].hasPrefix("shared--Fixture-") && sharedCopy.contains("副設備改的內容")
              && sharedCopy.contains("conflict: \"shared.md\""),
              "both edited: primary version keeps the name, this device's version saved as <name>--<device>-<date>.md with conflict")
        check(status.conflicts == 1 && status.line.contains("兩版並存 1 條"), "status counts the kept-both copy")

        // 4. 主設備收件時才遇到（fetch 之後主設備又改）：同一套規則，主設備版留原名、副設備版另存一份。
        try note(s, "other.md", title: "另一條", body: "副設備改的另一條。")
        w.switches.afterFetch = {
            try? note(p, "other.md", title: "另一條", body: "主設備後來改的另一條。")
            _ = EngineMemoryLinks.commit(p, message: "fixture：主設備在 fetch 之後又改")
        }
        _ = w.secondaryEngine.runOnce(.change)
        let otherCopiesP = copies(p, stem: "other")
        check((text(p.appendingPathComponent("other.md")) ?? "").contains("主設備後來改的另一條")
              && otherCopiesP.count == 1 && otherCopiesP[0].hasPrefix("other--Fixture-")
              && (text(p.appendingPathComponent(otherCopiesP.first ?? "-")) ?? "").contains("副設備改的另一條"),
              "primary-side merge: same rule, primary version keeps the name, one copy")
        _ = w.secondaryEngine.runOnce(.timer)
        check(copies(s, stem: "other") == otherCopiesP && treeID(p) == treeID(s), "secondary converges to the same tree")

        // 5. 再跑幾輪：不重複產生副本，兩邊一致。
        _ = w.secondaryEngine.runOnce(.timer)
        _ = w.primaryEngine.runOnce(.timer)
        _ = w.secondaryEngine.runOnce(.timer)
        check(copies(p, stem: "shared").count == 1 && copies(p, stem: "other").count == 1
              && copies(s, stem: "shared").count == 1 && copies(s, stem: "other").count == 1 && treeID(p) == treeID(s),
              "repeated rounds: no duplicate copies, both sides identical")
        try sameVersionNotCopiedTwice(w, check)

        // 6. 離線：先留在這台，連上再送。
        w.switches.online = false
        try note(s, "offline.md", title: "離線記的", body: "離線時記下的一條。")
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .offline && status.pending >= 1 && status.line.contains("先留在這台")
              && !fm.fileExists(atPath: p.appendingPathComponent("offline.md").path),
              "offline: queued in the local git")
        w.switches.online = true
        status = w.secondaryEngine.runOnce(.timer)
        check(tracked(p, "offline.md") && status.state == .synced && status.pending == 0, "back online: queued change sent")

        // 7. 主設備外接卷沒掛上：主設備安靜略過；副設備留在本機、不報錯。
        w.switches.primaryMounted = false
        let unmountedStatus = w.primaryEngine.runOnce(.timer)
        check(unmountedStatus.state == .folderMissing && unmountedStatus.line == "記憶資料夾沒接上" && unmountedStatus.error == nil,
              "primary volume not mounted: quiet status, no error")
        try note(s, "while-unmounted.md", title: "外接卷沒掛時", body: "主設備外接卷沒掛上時記的。")
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .primaryFolderMissing && status.pending >= 1 && status.line.hasPrefix("主設備的記憶資料夾沒接上"),
              "secondary: primary folder missing, change kept locally")
        w.switches.primaryMounted = true
        _ = w.secondaryEngine.runOnce(.timer)
        check(tracked(p, "while-unmounted.md"), "volume back: change delivered")

        // 8. 不安全的樹：連結檔、memory/ 以外的路徑、.git、子模組、git 設定檔一律拒收，主設備不動。
        try unsafeTrees(w, check)

        // 8b. 審查修正：簽章呼叫排成一列、舊版主設備、錯誤的角度、擋住的檔、大小寫、金鑰、一次刪太多。
        try reviewFixes(w, check)

        // 9. 一把鎖：有人拿著鎖時，commit 會等。
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            TatwoMemoryLock.run { holding.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        holding.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { release.signal() }
        let waited = Date()
        _ = EngineMemoryLinks.commit(s, message: "fixture：鎖")
        check(Date().timeIntervalSince(waited) >= 0.5, "commit waits for the shared memory lock")

        // 10. 沒有任何使用者的檔在同步中不見。
        let expected = ["primary-first.md", "secondary-first.md", "from-secondary.md", "from-primary.md", "claude-wrote.md",
                        "second-round.md", "shared.md", "other.md", "offline.md", "while-unmounted.md"]
        check([p, s].allSatisfy { memory in expected.allSatisfy { fm.fileExists(atPath: memory.appendingPathComponent($0).path) } },
              "no user file lost on either side")

        // 11. 檔案監看：memory/ 一有變動，10 秒內送到主設備（定時那一輪要 60 秒後才會到）。
        w.secondaryEngine.start()
        Thread.sleep(forTimeInterval: 1.5)
        w.secondaryEngine.queue.sync {}
        let written = Date()
        try note(s, "watched.md", title: "監看", body: "檔案監看觸發的一條。")
        var arrived = false
        while Date().timeIntervalSince(written) < 10 {
            if tracked(p, "watched.md") { arrived = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let seconds = Date().timeIntervalSince(written)
        w.secondaryEngine.stop()
        check(arrived, "memory/ change reaches the primary within 10 seconds via the file watcher (\(String(format: "%.1f", seconds)) s)")
    }

    /// W180 E1b 審查修正的情境（每一段結束時兩邊都回到一致）。
    static func reviewFixes(_ w: World, _ check: Checker) throws {
        let p = w.pPaths.memory, s = w.sPaths.memory
        let fm = FileManager.default
        let secret = "api" + "_key = " + String(repeating: "Q", count: 20)

        // a. 好幾條對主設備的簽章呼叫同時跑（像記憶同步、派發、提案），傳輸上先簽的晚到：一個都不能被當成重送拒收。
        let order = Counter()
        w.switches.rpcDelay = { max(0, 0.3 - Double(order.next()) * 0.06) }
        let failures = Box<[String]>([]), failuresLock = NSLock()
        let group = DispatchGroup()
        for _ in 0..<6 {
            DispatchQueue.global().async(group: group) {
                do { _ = try w.secondaryDispatch.callPrimary(method: "memory_sync_target", payload: [:]) } catch {
                    failuresLock.lock(); failures.value.append(String(describing: error)); failuresLock.unlock()
                }
            }
        }
        group.wait()
        w.switches.rpcDelay = nil
        check(failures.value.isEmpty, "concurrent signed calls to the primary are serialized: none rejected as replayed")

        // b. 主設備的 App 還沒更新（不認得記憶同步）：照實說，不說成連不上。
        w.switches.legacyPrimary = true
        try note(s, "legacy.md", title: "舊版主設備", body: "主設備還沒更新時記的。")
        var status = w.secondaryEngine.runOnce(.change)
        check(status.state == .failed && status.error == "主設備的 App 還沒更新，不認得記憶同步" && !status.line.contains("連不上"),
              "primary app not updated yet: says so, not offline")
        w.switches.legacyPrimary = false
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .synced && tracked(p, "legacy.md"), "after the primary updates, the change is sent")

        // c. 主設備那邊有檔擋住（含金鑰、只留在主設備）：錯誤經過 RPC 字串化，副設備看到的是主設備角度的白話、寫出檔名。
        try write("---\nname: 撞名\n---\n\n" + secret + "\n", p.appendingPathComponent("clash.md"))
        _ = w.primaryEngine.runOnce(.timer)
        try note(s, "clash.md", title: "撞名", body: "副設備記的一般內容。")
        status = w.secondaryEngine.runOnce(.change)
        let primarySide = status.error ?? ""
        check(status.state == .failed && primarySide.contains("主設備的 clash.md") && !primarySide.contains("這台")
              && !status.line.contains("Failure(") && status.line.range(of: "[a-z]+_[a-z_]+", options: .regularExpression) == nil,
              "primary-side failure shown on the secondary in plain Chinese, from the primary's side, naming the file")
        check(!tracked(p, "clash.md") && (text(p.appendingPathComponent("clash.md")) ?? "").contains(secret),
              "primary's held-back file untouched")
        try fm.removeItem(at: p.appendingPathComponent("clash.md"))
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .synced && tracked(p, "clash.md") && treeID(p) == treeID(s), "once the primary's file is gone, sync resumes")

        // d. 這台有檔擋住合併：狀態寫出檔名；這台新記的照樣送到主設備（上傳不停）。
        try write("---\nname: 這台撞名\n---\n\n" + secret + "\n", s.appendingPathComponent("s-clash.md"))
        try note(p, "s-clash.md", title: "這台撞名", body: "主設備記的一般內容。")
        _ = w.primaryEngine.runOnce(.timer)
        try note(s, "upload.md", title: "照樣上傳", body: "這台合併卡住時照樣送到主設備。")
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .failed && (status.error ?? "").contains("這台的 s-clash.md") && tracked(p, "upload.md")
              && (text(s.appendingPathComponent("s-clash.md")) ?? "").contains(secret),
              "a held-back file blocks this device's merge: status names it, uploads still reach the primary")
        try fm.removeItem(at: s.appendingPathComponent("s-clash.md"))
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .synced && tracked(s, "s-clash.md") && treeID(p) == treeID(s), "once it is gone, this device catches up")

        // e. 檔名只差大小寫（macOS 當成同一個檔）：兩版都留，主設備那版留原名。
        try note(p, "Case.md", title: "大小寫", body: "主設備的大寫版。")
        _ = w.primaryEngine.runOnce(.timer)
        try note(s, "case.md", title: "大小寫", body: "副設備的小寫版。")
        status = w.secondaryEngine.runOnce(.change)
        func caseKept(_ memory: URL) -> Bool {
            let files = gitText(memory, ["ls-files"]).components(separatedBy: "\n")
            let copy = files.filter { $0.hasPrefix("case--Fixture-") }
            guard files.contains("Case.md"), !files.contains("case.md"), copy.count == 1 else { return false }
            let upper = gitText(memory, ["show", "HEAD:Case.md"]), lower = gitText(memory, ["show", "HEAD:" + copy[0]])
            return upper.contains("主設備的大寫版") && lower.contains("副設備的小寫版") && clean(memory)
        }
        check(status.state == .synced && treeID(p) == treeID(s) && caseKept(p) && caseKept(s),
              "names differing only in case (macOS): both versions kept, primary's keeps the name")

        // f. 同名的檔和資料夾：這輪不合併、說清楚，哪一邊都不丟；改名後照常同步。
        try write("主設備的一個檔\n", p.appendingPathComponent("layout"))
        _ = w.primaryEngine.runOnce(.timer)
        try note(s, "layout/x.md", title: "資料夾", body: "副設備在同名資料夾裡記的。")
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .failed && (status.error ?? "").contains("同名的檔和資料夾") && (status.error ?? "").contains("layout")
              && tracked(p, "layout") && !tracked(p, "layout/x.md") && tracked(s, "layout/x.md"),
              "a file and a folder with the same name: stops and says so, nothing dropped")
        try fm.removeItem(at: s.appendingPathComponent("layout"))
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .synced && tracked(s, "layout") && treeID(p) == treeID(s), "after the rename, sync resumes")

        // g. 手動 git commit 繞過金鑰檢查：不送到主設備；最新版拿掉、歷史裡還有也不送（推送會帶上整段歷史）。
        guard let beforeSecret = head(s) else { throw TatwoMemorySyncEngine.Failure(reason: "fixture head") }
        try write("---\nname: 手動\n---\n\n" + secret + "\n", s.appendingPathComponent("manual-secret.md"))
        TatwoMemorySyncEngine.runGit(["add", "--", "manual-secret.md"], in: s)
        TatwoMemorySyncEngine.runGit(["commit", "-q", "-m", "fixture：手動 commit"], in: s)
        let secretBlob = gitText(s, ["rev-parse", "HEAD:manual-secret.md"])
        let primaryHasBlob = { TatwoMemorySyncEngine.runGit(["cat-file", "-e", secretBlob], in: p).status == 0 }
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .failed && (status.error ?? "").contains("金鑰") && (status.error ?? "").contains("manual-secret.md")
              && !tracked(p, "manual-secret.md") && !primaryHasBlob(),
              "a secret-looking file committed by hand is not sent to the primary")
        TatwoMemorySyncEngine.runGit(["rm", "-q", "--", "manual-secret.md"], in: s)
        TatwoMemorySyncEngine.runGit(["commit", "-q", "-m", "fixture：手動拿掉"], in: s)
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .failed && (status.error ?? "").contains("manual-secret.md") && !primaryHasBlob(),
              "removed in the latest version but still in history: still not sent")
        TatwoMemorySyncEngine.runGit(["reset", "-q", "--hard", beforeSecret], in: s) // 暫存的自測倉：把那兩個手動 commit 拿掉
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .synced && treeID(p) == treeID(s), "history without the secret: sync resumes")

        // h. 這台一次刪掉很多條：先不送，狀態列確認後主設備先封存（附還原說明）再刪；主設備自己也擋沒確認的。
        let bulk = (1...11).map { "bulk-\($0).md" }
        for name in bulk { try note(s, name, title: name, body: "一次清掉的其中一條。") }
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .synced && bulk.allSatisfy { tracked(p, $0) }, "bulk notes reach the primary")
        for name in bulk { try fm.removeItem(at: s.appendingPathComponent(name)) }
        status = w.secondaryEngine.runOnce(.change)
        check(status.state == .held && status.heldOutgoing && status.held == 11 && status.line.contains("這台刪了 11 條")
              && bulk.allSatisfy { fm.fileExists(atPath: p.appendingPathComponent($0).path) },
              "this device deleted many notes: not sent until confirmed, the primary keeps them")
        let ref = TatwoMemorySyncEngine.inboxRef(w.sID)
        guard let wiped = head(s) else { throw TatwoMemorySyncEngine.Failure(reason: "fixture head") }
        TatwoMemorySyncEngine.runGit(["push", "-q", "--", p.path, "\(wiped):\(ref)"], in: s)
        var refused = ""
        do { _ = try w.secondaryDispatch.callPrimary(method: "memory_sync_receive", payload: ["ref": ref, "commit": wiped]) }
        catch { refused = TatwoMemorySyncEngine.short(error) }
        check(refused.contains("先不套用") && bulk.allSatisfy { tracked(p, $0) }, "the primary refuses an unconfirmed mass deletion by itself")
        TatwoMemorySyncEngine.runGit(["update-ref", "-d", ref], in: p)
        w.secondaryEngine.approveHeld()
        status = w.secondaryEngine.runOnce(.timer)
        let day = EngineMemoryLinks.dayStamp(Date())
        let pArchive = w.pPaths.entryRoot.appendingPathComponent("archive/memory-sync-deleted-" + day)
        check(status.state == .synced && bulk.allSatisfy { !fm.fileExists(atPath: p.appendingPathComponent($0).path) }
              && bulk.allSatisfy { fm.fileExists(atPath: pArchive.appendingPathComponent($0).path) }
              && (text(pArchive.appendingPathComponent("還原.md")) ?? "").contains("bulk-1.md") && treeID(p) == treeID(s),
              "after confirming: the primary archives them with a restore note, then removes them")

        // i. 另一台（主設備）一次刪掉很多條：先不套用到這台；確認後這台先封存再刪。
        let wide = (1...11).map { "wide-\($0).md" }
        for name in wide { try note(p, name, title: name, body: "主設備一次清掉的其中一條。") }
        _ = w.primaryEngine.runOnce(.timer)
        _ = w.secondaryEngine.runOnce(.timer)
        check(wide.allSatisfy { tracked(s, $0) }, "primary bulk notes reach the secondary")
        for name in wide { try fm.removeItem(at: p.appendingPathComponent(name)) }
        _ = w.primaryEngine.runOnce(.timer)
        status = w.secondaryEngine.runOnce(.timer)
        check(status.state == .held && !status.heldOutgoing && status.held == 11 && status.line.contains("另一台刪了 11 條")
              && wide.allSatisfy { fm.fileExists(atPath: s.appendingPathComponent($0).path) },
              "the other device deleted many notes: not applied here until confirmed")
        w.secondaryEngine.approveHeld()
        status = w.secondaryEngine.runOnce(.timer)
        let sArchive = w.sPaths.entryRoot.appendingPathComponent("archive/memory-sync-deleted-" + day)
        check(status.state == .synced && wide.allSatisfy { !fm.fileExists(atPath: s.appendingPathComponent($0).path) }
              && wide.allSatisfy { fm.fileExists(atPath: sArchive.appendingPathComponent($0).path) } && treeID(p) == treeID(s),
              "after confirming here: archived first, then removed")
    }

    /// 同一對版本已經另存過（別天存的也算），再遇到一次不再產生第二份。
    static func sameVersionNotCopiedTwice(_ w: World, _ check: Checker) throws {
        let repo = w.base.appendingPathComponent("dedupe")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func must(_ arguments: [String]) throws {
            guard TatwoMemorySyncEngine.runGit(arguments, in: repo).status == 0 else {
                throw TatwoMemorySyncEngine.Failure(reason: "fixture git failed: \(arguments.first ?? "")")
            }
        }
        try must(["-c", "init.defaultBranch=main", "init", "-q"])
        try write("base\n", repo.appendingPathComponent("x.md"))
        try must(["add", "-A"]); try must(["commit", "-q", "-m", "base"])
        try must(["checkout", "-q", "-b", "primary"])
        try write("primary\n", repo.appendingPathComponent("x.md"))
        try must(["commit", "-q", "-am", "primary"])
        try must(["checkout", "-q", "main"])
        try write("secondary\n", repo.appendingPathComponent("x.md"))
        let earlier = TatwoMemorySyncMerge.markConflict(Data("secondary\n".utf8), path: "x.md")
        try earlier.write(to: repo.appendingPathComponent("x--Fixture-20260101.md"))
        try must(["add", "-A"]); try must(["commit", "-q", "-m", "secondary"])
        guard let primaryTip = head(repo, "primary") else { throw TatwoMemorySyncEngine.Failure(reason: "fixture branch") }
        let outcome = try w.secondaryEngine.merge(memory: repo, other: primaryTip, otherIsPrimary: true, label: "Fixture", day: "20260927")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []).filter { $0.hasPrefix("x--") }
        check(outcome.kind == "merged" && outcome.copies == 0 && names == ["x--Fixture-20260101.md"]
              && text(repo.appendingPathComponent("x.md")) == "primary\n",
              "same pair of versions never copied twice (even on another day)")
    }

    static func unsafeTrees(_ w: World, _ check: Checker) throws {
        let s = w.sPaths.memory, p = w.pPaths.memory
        let fm = FileManager.default
        let ref = TatwoMemorySyncEngine.inboxRef(w.sID)
        let before = head(p)
        func mustText(_ arguments: [String], input: Data? = nil, environment: [String: String] = [:]) throws -> String {
            let result = TatwoMemorySyncEngine.runGit(arguments, in: s, input: input, environment: environment)
            guard result.status == 0 else { throw TatwoMemorySyncEngine.Failure(reason: "fixture git failed: \(arguments.first ?? "")") }
            return result.text
        }
        guard let base = head(s) else { throw TatwoMemorySyncEngine.Failure(reason: "fixture head") }
        let blob = try mustText(["hash-object", "-w", "--stdin"], input: Data("/etc/hosts".utf8))
        func withEntry(_ mode: String, _ id: String, _ path: String) throws -> String {
            let index = w.base.appendingPathComponent("idx-" + UUID().uuidString).path
            let env = ["GIT_INDEX_FILE": index]
            _ = try mustText(["read-tree", base], environment: env)
            _ = try mustText(["update-index", "--add", "--cacheinfo", "\(mode),\(id),\(path)"], environment: env)
            return try mustText(["write-tree"], environment: env)
        }
        func withRootTree(_ name: String) throws -> String {
            let inner = try mustText(["mktree"], input: Data("100644 blob \(blob)\tconfig\n".utf8))
            let root = try mustText(["ls-tree", base])
            return try mustText(["mktree"], input: Data((root + "\n040000 tree \(inner)\t\(name)\n").utf8))
        }
        func commit(_ tree: String) throws -> String { try mustText(["commit-tree", tree, "-p", base, "-m", "fixture：不安全"]) }
        func rejected(_ commit: String, _ label: String, expect: String) {
            let pushed = TatwoMemorySyncEngine.runGit(["push", "-q", "-f", "--", p.path, "\(commit):\(ref)"], in: s)
            var message = ""
            do {
                _ = try w.secondaryDispatch.callPrimary(method: "memory_sync_receive", payload: ["ref": ref, "commit": commit])
            } catch { message = error.localizedDescription }
            check(pushed.status == 0 && message.contains(expect) && head(p) == before, label)
        }
        rejected(try commit(try withEntry("120000", blob, "evil-link.md")), "symlink in the tree rejected", expect: "連結檔")
        rejected(try commit(try withRootTree("..")), "path outside memory/ (..) rejected", expect: "以外的路徑")
        rejected(try commit(try withRootTree(".GIT")), ".git folder (any case) rejected", expect: "以外的路徑")
        rejected(try commit(try withEntry("160000", base, "sub")), "submodule rejected", expect: "子模組")
        rejected(try commit(try withEntry("100644", blob, ".gitattributes")), "git settings file that differs rejected", expect: "git 設定檔")
        // 檔案系統不分大小寫：`.GIT` 就是 `.git`，所以看的是 .git/config 有沒有被換成送來的內容。
        check(!fm.fileExists(atPath: p.appendingPathComponent("evil-link.md").path)
              && !fm.fileExists(atPath: p.deletingLastPathComponent().appendingPathComponent("config").path)
              && text(p.appendingPathComponent(".git/config"))?.contains("/etc/hosts") == false && clean(p),
              "rejected trees leave the primary working tree untouched")
        TatwoMemorySyncEngine.runGit(["update-ref", "-d", ref], in: p)

        // 收件分支只准 refs/heads/inbox/<送件的設備>/memory。
        var wrongRef = false, otherDevice = false
        do { _ = try w.secondaryDispatch.callPrimary(method: "memory_sync_receive", payload: ["ref": "refs/heads/main", "commit": base]) }
        catch { wrongRef = error.localizedDescription.contains("invalid_memory_sync_receipt") }
        do {
            _ = try w.secondaryDispatch.callPrimary(method: "memory_sync_receive",
                                                    payload: ["ref": TatwoMemorySyncEngine.inboxRef(w.pID), "commit": base])
        } catch { otherDevice = error.localizedDescription.contains("invalid_memory_sync_receipt") }
        check(wrongRef && otherDevice, "receive only accepts the sender's own inbox ref")

        // 沒簽章、簽章被改：驗章擋下；兩個新方法在「要設備簽章」那一組，不在 SSH 遙控與 staging 唯讀清單。
        var proof = try w.secondaryDispatch.signed(method: "memory_sync_receive", payload: ["ref": ref, "commit": base])
        proof["signature"] = Data("not a signature".utf8).base64EncodedString()
        var tampered = false
        do { _ = try w.primaryDispatch.authenticate(method: "memory_sync_receive", proof: proof) } catch { tampered = true }
        check(tampered, "tampered device signature rejected")
        check(["memory_sync_target", "memory_sync_receive"].allSatisfy {
            OSAgentBridge.untrustedCallerMethods.contains($0) && !OSAgentBridge.sshForwardMethods.contains($0)
                && !OSAgentBridge.stagingReadOnlyMethods.contains($0)
        }, "trust tables: signed-device group only, not SSH remote control or staging read-only")

        // 這台自己有連結檔：不送，說清楚；主設備不動。改回一般檔後照常同步。
        let link = s.appendingPathComponent("link.md")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        let status = w.secondaryEngine.runOnce(.change)
        check(status.state == .failed && (status.error ?? "").contains("連結檔") && !fm.fileExists(atPath: p.appendingPathComponent("link.md").path),
              "this device's symlink is not sent, status says why")
        try fm.removeItem(at: link)
        let after = w.secondaryEngine.runOnce(.change)
        check(after.state == .synced && treeID(p) == treeID(s), "after the symlink is gone, sync resumes")
    }

    // MARK: 小工具（都在背景執行緒）

    static func note(_ memory: URL, _ name: String, title: String, body: String) throws {
        let text = "---\nname: \(title)\ndescription: \(body)\nmetadata:\n  type: project\n---\n\n\(body)\n"
        try write(text, memory.appendingPathComponent(name))
    }

    static func appendIndex(_ memory: URL, _ line: String) throws {
        let url = memory.appendingPathComponent("MEMORY.md")
        let old = text(url) ?? ""
        try write(old + (old.hasSuffix("\n") || old.isEmpty ? "" : "\n") + line + "\n", url)
    }

    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func gitText(_ memory: URL, _ arguments: [String]) -> String {
        TatwoMemorySyncEngine.runGit(arguments, in: memory).text
    }

    static func head(_ memory: URL, _ name: String = "HEAD") -> String? {
        let result = TatwoMemorySyncEngine.runGit(["rev-parse", "--verify", "-q", name + "^{commit}"], in: memory)
        return result.status == 0 ? result.text : nil
    }

    static func treeID(_ memory: URL) -> String { gitText(memory, ["rev-parse", "HEAD^{tree}"]) }

    static func tracked(_ memory: URL, _ path: String) -> Bool {
        TatwoMemorySyncEngine.runGit(["cat-file", "-e", "HEAD:" + path], in: memory).status == 0
    }

    static func clean(_ memory: URL) -> Bool { gitText(memory, ["status", "--porcelain"]).isEmpty }

    static func isAncestor(_ memory: URL, _ commit: String) -> Bool {
        TatwoMemorySyncEngine.runGit(["merge-base", "--is-ancestor", commit, "HEAD"], in: memory).status == 0
    }

    static func copies(_ memory: URL, stem: String? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? [])
            .filter { file in TatwoMemorySyncMerge.isConflictCopy(file) && (stem.map { file.hasPrefix($0 + "--") } ?? true) }
            .sorted()
    }
}
#endif
