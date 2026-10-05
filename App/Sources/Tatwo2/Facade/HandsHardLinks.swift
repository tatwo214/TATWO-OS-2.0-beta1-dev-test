import Darwin
import Foundation

// W183 R6c 審查（GPT-6）：工作區裡「另一個名字在工作區外」的硬連結。
// Seatbelt 只看路徑：主機上的某個程式（不是沙盒裡的指令，它建不了）把入口的檔（同一顆碟）硬連結進工作區，沙盒裡的任意指令
// 就能用工作區裡的那個名字讀寫它（09-28 本機實測：規則允許的資料夾裡的硬連結，讀得到它在外面的那個檔）。
// 檔案小幫手本來就拒絕連結數 > 1 的檔；任意指令（run_command、job_start）、git diff、交件在開始前用這裡掃一次整個工作區資料夾
//（repo＋scratch）：一般檔的連結數比「在工作區裡找到的名字數」多＝至少有一個名字在外面 → 不跑、不交件。
// 工作區裡自己互相連結的（兩個名字都在裡面）照常。在沙盒外逐層 openat（O_NOFOLLOW）、不跟隨捷徑、不跑任何程式。
enum HandsHardLinks {
    struct Key: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// Darwin returns variable-length records, not a full Swift `dirent` value.
    /// Copy only the validated name bytes; materializing d_name can overread the
    /// final record in readdir's buffer and crash the host before a job starts.
    static func entryName(_ entry: UnsafePointer<dirent>) throws -> [CChar] {
        let offset = MemoryLayout<dirent>.offset(of: \.d_name)!
        let recordLength = Int(entry.pointee.d_reclen)
        let length = Int(entry.pointee.d_namlen)
        guard length > 0, length < Int(PATH_MAX), offset + length < recordLength else {
            throw HandsToolError.invalid("workspace_invalid_directory_entry")
        }
        let bytes = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self)
        guard bytes[length] == 0 else {
            throw HandsToolError.invalid("workspace_invalid_directory_entry")
        }
        let name = Array(UnsafeBufferPointer(start: bytes, count: length))
        guard !name.contains(0), !name.contains(47) else {
            throw HandsToolError.invalid("workspace_invalid_directory_entry")
        }
        return name
    }

    /// 回第一個有外部名字的一般檔（相對 root 的路徑）；nil＝沒有。讀不了、項目太多、太深＝丟錯（呼叫端當作不安全、不跑）。
    static func outsideLink(under root: String, limit: Int = 1_000_000, maxDepth: Int = 256) throws -> String? {
        let rootFD = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw HandsToolError.invalid("workspace_unreadable") }
        defer { close(rootFD) }
        var links: [Key: (expected: Int, found: Int, path: String)] = [:]
        var seen = 0

        func walk(_ fd: Int32, _ relative: String, depth: Int) throws {
            guard depth <= maxDepth else { throw HandsToolError.invalid("workspace_too_deep_to_verify") }
            let listFD = dup(fd)
            guard listFD >= 0 else { throw HandsToolError.invalid("workspace_unreadable:\(relative)") }
            guard let directory = fdopendir(listFD) else {
                close(listFD)
                throw HandsToolError.invalid("workspace_unreadable:\(relative)")
            }
            var subdirectories: [(name: [CChar], path: String)] = []
            do {
                defer { closedir(directory) }
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else {
                        guard errno == 0 else { throw HandsToolError.invalid("workspace_unreadable:\(relative)") }
                        break
                    }
                    var name = try entryName(UnsafePointer(entry))
                    let display = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if display == "." || display == ".." { continue }
                    name.append(0)
                    seen += 1
                    guard seen <= limit else { throw HandsToolError.invalid("workspace_too_large_to_verify") }
                    let child = relative.isEmpty ? display : relative + "/" + display
                    let type = Int32(entry.pointee.d_type)
                    if type == DT_LNK { continue }
                    if type == DT_DIR { subdirectories.append((name, child)); continue }
                    var info = stat()
                    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw HandsToolError.invalid("workspace_unreadable:\(child)") }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        subdirectories.append((name, child))
                    case S_IFREG where info.st_nlink > 1:
                        let key = Key(device: info.st_dev, inode: info.st_ino)
                        if var known = links[key] {
                            known.found += 1
                            links[key] = known
                        } else {
                            links[key] = (Int(info.st_nlink), 1, child)
                        }
                    default:
                        break
                    }
                }
            }
            for (name, path) in subdirectories {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw HandsToolError.invalid("workspace_unreadable:\(path)") }
                defer { close(child) }
                try walk(child, path, depth: depth + 1)
            }
        }

        try walk(rootFD, "", depth: 0)
        return links.values.filter { $0.found < $0.expected }.map { $0.path }.min()
    }
}

extension HandsService {
    /// 跑指令、看 diff、交件之前：工作區資料夾（repo＋scratch）裡沒有「另一個名字在外面」的硬連結。有就不做（不鎖工作區：
    /// 那是主機這邊的東西，拿掉之後重試就好）。
    func requireNoOutsideLinks(_ workspace: HandsWorkspace) throws {
        if let path = try HandsHardLinks.outsideLink(under: workspace.dir) {
            throw HandsToolError.invalid("hardlink_to_outside_refused: \(path) is a hard link to a file outside this workspace; "
                                         + "nothing was run — ask the user to remove it on the Mac, then retry")
        }
    }
}
