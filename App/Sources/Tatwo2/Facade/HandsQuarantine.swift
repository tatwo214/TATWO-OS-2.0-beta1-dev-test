import Darwin
import Foundation

// W183 R10 第三輪（GPT-6 發現 4、5、8；主導裁決）：工作區裡的隔離搬移。
// - 從固定、驗證過的資料夾 descriptor 出發，逐層 openat(O_NOFOLLOW | O_DIRECTORY)（任何一層是捷徑、不是資料夾＝失敗，不會走到工作區外面），
//   用 descriptor 相對的 renameat 搬，搬之前、搬之後核對身分（裝置＋inode）。
// - 還原說明（RESTORE.txt）在搬任何東西之前先寫；寫不成＝整次隔離失敗（呼叫端鎖住工作區）。
// - 同一個工作區的掃描與搬移一次只有一個（withWorkspaceMutex；雙掃描＝第二個等第一個做完再看版本）。
// 掃描本身只列候選（名字）；安全靠的是搬移那一步不跟捷徑、只在驗證過的資料夾 descriptor 底下動。

enum HandsQuarantine {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: 工作區專用互斥

    private static let mutexTableLock = NSLock()
    private static var mutexes: [UUID: NSLock] = [:]

    /// 同一個工作區的遷移、執行前隔離一次只做一個（別的工作區不受影響）。會等（不是試一次就放棄）。
    static func withWorkspaceMutex<T>(_ id: UUID, _ body: () throws -> T) rethrows -> T {
        mutexTableLock.lock()
        let mutex: NSLock
        if let existing = mutexes[id] { mutex = existing } else { mutex = NSLock(); mutexes[id] = mutex }
        mutexTableLock.unlock()
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    #if DEBUG
    /// 自測用：掃描完、搬之前停一下（第一個參數是工作區 id；自測在這時候把中間的資料夾換成捷徑、或讓第二個掃描排隊）。
    nonisolated(unsafe) static var beforeMoveGate: ((UUID) -> Void)?
    #endif

    // MARK: descriptor

    /// 開一個資料夾（最後一段不跟捷徑），核對開到的就是 lstat 看到的那一個。
    static func openDirectory(_ path: String) throws -> Int32 {
        var before = stat()
        guard lstat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR else { throw Failure("not_a_directory") }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("open_failed") }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
            close(fd)
            throw Failure("identity_changed")
        }
        return fd
    }

    static func components(_ relative: String) throws -> [String] {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw Failure("bad_path") }
        return parts
    }

    /// root 底下 relative 的上一層資料夾：逐層不跟捷徑。回（那一層的 fd、最後一段名字）；呼叫端 close。
    static func openParent(_ root: Int32, _ relative: String) throws -> (Int32, String) {
        let parts = try components(relative)
        var fd = dup(root)
        guard fd >= 0 else { throw Failure("dup_failed") }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Failure("not_a_plain_directory") }
            fd = next
        }
        return (fd, parts[parts.count - 1])
    }

    /// dest 底下建出 relative 的上一層資料夾（每一層 mkdirat；已經有的要是資料夾、不是捷徑）。回（那一層的 fd、最後一段名字）。
    static func makeParents(_ dest: Int32, _ relative: String) throws -> (Int32, String) {
        let parts = try components(relative)
        var fd = dup(dest)
        guard fd >= 0 else { throw Failure("dup_failed") }
        for part in parts.dropLast() {
            if mkdirat(fd, part, 0o700) != 0, errno != EEXIST { close(fd); throw Failure("mkdir_failed") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw Failure("quarantine_path_not_a_directory") }
            fd = next
        }
        return (fd, parts[parts.count - 1])
    }

    /// 把 root 底下的 relative 搬到 dest 底下（toRelative；nil＝同一個相對位置）。不跟捷徑（最後一段是捷徑就搬捷徑本身），
    /// 搬之前、之後核對身分。
    static func move(_ relative: String, from root: Int32, to dest: Int32, as toRelative: String? = nil) throws {
        let (source, name) = try openParent(root, relative)
        defer { close(source) }
        var before = stat()
        guard fstatat(source, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("missing") }
        let (target, targetName) = try makeParents(dest, toRelative ?? relative)
        defer { close(target) }
        guard renameat(source, name, target, targetName) == 0 else { throw Failure("rename_failed") }
        var after = stat()
        guard fstatat(target, targetName, &after, AT_SYMLINK_NOFOLLOW) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
            throw Failure("identity_changed")
        }
    }

    /// 在 dir 底下寫一個新檔（已經有、是捷徑＝失敗；寫不完整、存不進磁碟＝失敗）。
    static func writeNew(_ dir: Int32, _ name: String, _ data: Data) throws {
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("restore_note_create_failed") }
        defer { close(fd) }
        var written = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            while written < raw.count {
                let count = write(fd, base + written, raw.count - written)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard ok, fsync(fd) == 0 else { throw Failure("restore_note_write_failed") }
    }

    /// 在 dir（工作區資料夾）底下開一個新的隔離資料夾 quarantine-<時間>[-n]（mkdirat；不重用舊的），回（fd、名字）。
    static func makeQuarantine(_ dir: Int32) throws -> (Int32, String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for attempt in 0..<20 {
            let name = "quarantine-" + stamp + (attempt == 0 ? "" : "-\(attempt)")
            if mkdirat(dir, name, 0o700) != 0 {
                if errno == EEXIST { continue }
                throw Failure("quarantine_mkdir_failed")
            }
            let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure("quarantine_open_failed") }
            return (fd, name)
        }
        throw Failure("quarantine_name_taken")
    }

    // MARK: 掃描（只列候選；搬的時候才是安全那一步）

    /// root（工作區的 repo）底下要隔離的項目（相對路徑，照找到的順序）：
    /// - 金鑰類名字的檔或資料夾（整個算一個，不往裡面看；捷徑本身名字是金鑰類也算，不跟進去）；
    /// - nestedGit＝true：根以外的 .git（別人的 Git 物件庫；整個算一個）。
    /// 根的 .git 不看。看到超過 limit 個項目＝失敗（看不完不能說乾淨）。
    static func scan(_ root: Int32, nestedGit: Bool, limit: Int = 500_000) throws -> [String] {
        var out: [String] = []
        var pending: [String] = [""]
        var seen = 0
        while let relative = pending.popLast() {
            let fd: Int32
            if relative.isEmpty {
                fd = dup(root)
            } else {
                guard let (parent, name) = try? openParent(root, relative) else { continue }
                fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                close(parent)
            }
            guard fd >= 0 else { continue }   // 列的時候不見了、換成捷徑：不走進去（搬的那一步會再核）
            defer { close(fd) }
            let listFD = dup(fd)
            guard listFD >= 0 else { throw Failure("scan_open_failed") }
            guard let directory = fdopendir(listFD) else { close(listFD); throw Failure("scan_open_failed") }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                // readdir 的最後一筆可能只剩實際名稱長度；不能複製整個 d_name tuple。
                let bytes = try HandsHardLinks.entryName(UnsafePointer(entry)).map { UInt8(bitPattern: $0) }
                guard let name = String(bytes: bytes, encoding: .utf8) else { throw Failure("scan_name_not_utf8") }
                if name == "." || name == ".." { continue }
                seen += 1
                guard seen <= limit else { throw Failure("scan_too_large") }
                let child = relative.isEmpty ? name : relative + "/" + name
                if relative.isEmpty, name == ".git" { continue }
                if HandsSecretFiles.isSecret(name: name) || (nestedGit && name.lowercased() == ".git") {
                    out.append(child)
                    continue
                }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR { pending.append(child) }
            }
        }
        return out
    }

    /// root 底下這一個相對路徑存在（不跟捷徑；中間任何一層是捷徑＝當作不存在）。回它的類型（S_IFDIR…）或 nil。
    static func entryType(_ root: Int32, _ relative: String) -> mode_t? {
        guard let (parent, name) = try? openParent(root, relative) else { return nil }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// W183 R10 第四輪（GPT-6 發現 2）：根 .git 的指紋——.git 與 objects 的身分（裝置＋inode）、有沒有 alternates、pack 檔的名字、
    /// 散的物件有幾個。還原（整個換掉 .git、搬回舊的物件）就對不上。.git 不是資料夾、讀不到＝nil。
    static func gitFingerprint(repo: String) -> String? {
        var gitInfo = stat(), objectsInfo = stat()
        guard lstat(repo + "/.git", &gitInfo) == 0, (gitInfo.st_mode & S_IFMT) == S_IFDIR,
              lstat(repo + "/.git/objects", &objectsInfo) == 0, (objectsInfo.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let fm = FileManager.default
        var alternatesInfo = stat()
        let alternates = lstat(repo + "/.git/objects/info/alternates", &alternatesInfo) == 0
        let packs = ((try? fm.contentsOfDirectory(atPath: repo + "/.git/objects/pack")) ?? []).filter { $0.hasSuffix(".pack") }.sorted()
        var loose = 0
        for folder in (try? fm.contentsOfDirectory(atPath: repo + "/.git/objects")) ?? [] where folder.count == 2 && folder.allSatisfy(\.isHexDigit) {
            loose += ((try? fm.contentsOfDirectory(atPath: repo + "/.git/objects/" + folder)) ?? []).count
        }
        return "\(gitInfo.st_dev):\(gitInfo.st_ino)|\(objectsInfo.st_dev):\(objectsInfo.st_ino)|alt=\(alternates)|\(packs.joined(separator: ","))|\(loose)"
    }

    // MARK: 一次隔離

    /// 把 items（repo 底下的相對路徑）搬到工作區資料夾裡新的 quarantine-<時間>/files/。先寫還原說明（寫不成＝整次失敗、什麼都沒搬）；
    /// rootGit＝true 時另外把整個 repo/.git 搬到 quarantine-<時間>/git-archive（呼叫端用它重建乾淨的副本）。回隔離資料夾的絕對路徑。
    static func quarantine(workspaceID: UUID, dir: String, repo: String, items: [String], rootGit: Bool, reason: String) throws -> String {
        let dirFD = try openDirectory(dir)
        defer { close(dirFD) }
        let repoFD = try openDirectory(repo)
        defer { close(repoFD) }
        // repo 要是 dir 底下那一個 repo（不是別處的資料夾）。
        var repoInfo = stat(), childInfo = stat()
        guard fstat(repoFD, &repoInfo) == 0, fstatat(dirFD, "repo", &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
              repoInfo.st_dev == childInfo.st_dev, repoInfo.st_ino == childInfo.st_ino else { throw Failure("repo_not_in_workspace") }
        #if DEBUG
        beforeMoveGate?(workspaceID)
        #endif
        let (quarantineFD, name) = try makeQuarantine(dirFD)
        defer { close(quarantineFD) }
        // W183 R10 第四輪（GPT-6 發現 2、4）：照實寫——還原之後 TATWO 會重新整理（不宣稱還原之後 ChatGPT 仍讀不到）；還原 .git 之前先封存
        // 目前的新 .git（不要蓋掉整理之後的新工作）。
        var note = "TATWO 把這個 ChatGPT 工作區裡的東西搬到這裡隔離（W183 R10；\(reason)；沒有刪）。\n\n"
        note += "還原（給你自己看、自己用）：\n"
        if rootGit {
            note += "1. 先把目前的 repo/.git 搬進這個資料夾（例如改名成 git-current）——那是整理之後的新工作，不要直接蓋掉。\n"
            note += "2. 再把 git-archive（原本的 repo/.git）搬回 repo/.git；files/ 底下的東西搬回 repo/ 同一個位置。\n"
        } else {
            note += "1. 把 files/ 底下的東西搬回 repo/ 同一個位置。\n"
        }
        note += "還原之後，TATWO 下一次替 ChatGPT 用這個工作區之前會發現、先鎖住、重新整理一次（金鑰類的檔、別人的 Git 物件庫、舊的 "
        note += ".build/repositories 會再搬來隔離，工作區自己的 .git 會再重建）；在那之前 ChatGPT 不會用它。不要把還原當成要讓 ChatGPT 讀。\n\n"
        note += items.map { "- files/" + $0 }.joined(separator: "\n") + (items.isEmpty ? "" : "\n")
        note += rootGit ? "- git-archive（原本的 repo/.git）\n" : ""
        try writeNew(quarantineFD, "RESTORE.txt", Data(note.utf8))
        if !items.isEmpty {
            guard mkdirat(quarantineFD, "files", 0o700) == 0 else { throw Failure("quarantine_mkdir_failed") }
            let filesFD = openat(quarantineFD, "files", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard filesFD >= 0 else { throw Failure("quarantine_open_failed") }
            defer { close(filesFD) }
            for item in items { try move(item, from: repoFD, to: filesFD) }
        }
        if rootGit {
            guard entryType(repoFD, ".git") == S_IFDIR else { throw Failure("root_git_not_a_directory") }
            try move(".git", from: repoFD, to: quarantineFD, as: "git-archive")
        }
        return dir + "/" + name
    }
}
