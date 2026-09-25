import Darwin
import Foundation

/// W178：本機 socket（os.sock、browser.sock）是誰在連。
///
/// 同一個使用者底下的任何程式都打得開 0600 的 socket。會讀對話、送訊息、操作電腦或瀏覽器的方法，
/// 只給這幾種呼叫者：TATWO OS 自己；App 登記過的程序根（AI 引擎 sidecar、App 代跑的背景指令、測試探針）
/// 與它們開出來的程式；系統 sshd 轉進來的連線（已配對設備用 ssh -L 連進來，SSH 金鑰已驗過身分）。
/// 「系統 sshd」：對方是 sshd 程式，而且上一層是 root 身分的 sshd（使用者自己跑的 sshd 做不出 root 父程序）。
/// App 開的其他子程序（瀏覽器核心的輔助程序等）、經 SSH 跑起來的程式、使用者自己的終端機
/// （含 CLI 分頁：tmux 伺服器已脫離 App）與其他 App 一律不算自己人。
/// 認人在接到連線的當下做一次；引擎與背景指令同時綁定是哪條對話，之後不能自稱別條。
enum OSSocketCaller: Equatable {
    case app
    case engine(UUID)
    case job(UUID)
    case helper
    case ssh
    case other(pid: pid_t?)

    /// App 在行程內登記的程序根。
    enum Root: Equatable {
        case engine(UUID)
        case job(UUID)
        case helper
    }

    /// 程序根連同登記當下的啟動時間：pid 被別的程序重用、或 App 重開後舊工作已不是它的子程序，都對不上。
    struct RootEntry: Equatable {
        let root: Root
        let startTime: UInt64
    }

    var isTrusted: Bool {
        if case .other = self { return false }
        return true
    }

    /// App 自己或它登記的程序根（不含 SSH 轉進來的）。
    var isLocalApp: Bool {
        switch self {
        case .app, .engine, .job, .helper: return true
        case .ssh, .other: return false
        }
    }

    /// 引擎與背景指令只能以自己那條對話的身分呼叫。
    var boundThread: UUID? {
        switch self {
        case .engine(let thread), .job(let thread): return thread
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .app: "app"
        case .engine(let thread): "engine(\(thread.uuidString.prefix(8)))"
        case .job(let thread): "job(\(thread.uuidString.prefix(8)))"
        case .helper: "helper"
        case .ssh: "ssh"
        case let .other(pid): "other(\(pid.map(String.init) ?? "?"))"
        }
    }

    static let sshExecutables: Set<String> = ["/usr/libexec/sshd-session", "/usr/sbin/sshd"]

    /// 目前登記的 sidecar／背景工作（由 OSAgentBridge 提供；沒有 model 的無頭情境是 nil）。
    static var rootsProvider: (() -> [pid_t: RootEntry])?
    private static let helperLock = NSLock()
    private static var helpers: [pid_t: UInt64] = [:]

    /// App 自己開、需要連本機 socket 的輔助程序（例如自測探針）。只有行程內的程式碼能登記；登記時記下啟動時間。
    @discardableResult
    static func registerHelper(_ pid: pid_t) -> Bool {
        guard let startTime = processStartTime(pid) else { return false }
        helperLock.lock(); helpers[pid] = startTime; helperLock.unlock()
        return true
    }

    static func unregisterHelper(_ pid: pid_t) {
        helperLock.lock(); helpers[pid] = nil; helperLock.unlock()
    }

    static func currentRoots() -> [pid_t: RootEntry] {
        var roots = rootsProvider?() ?? [:]
        helperLock.lock()
        for (pid, startTime) in helpers { roots[pid] = RootEntry(root: .helper, startTime: startTime) }
        helperLock.unlock()
        return roots
    }

    static func classify(fd: Int32, appPID: pid_t = getpid()) -> OSSocketCaller {
        guard let pid = peerPID(fd) else { return .other(pid: nil) }
        return classify(pid: pid, appPID: appPID, roots: currentRoots())
    }

    /// 對方本身是系統 sshd（父程序是 root 的 sshd）就是 ssh -L 轉進來的；否則從對方往上找父程序，
    /// 先遇到登記過的程序根（而且那個根的父程序就是 App、啟動時間跟登記時一樣）才算自己人；
    /// 一路找到 App 本身都沒遇到，就是 App 開的其他程式，不算。
    static func classify(pid: pid_t, appPID: pid_t = getpid(), roots: [pid_t: RootEntry]) -> OSSocketCaller {
        if pid == appPID { return .app }
        if let path = executablePath(pid), sshExecutables.contains(path),
           let parent = parentPID(of: pid), parent > 1,
           let parentPath = executablePath(parent), sshExecutables.contains(parentPath),
           processUIDs(parent).map({ $0.real == 0 && $0.effective == 0 }) == true {
            return .ssh
        }
        var current = pid
        for _ in 0..<64 {
            if let entry = roots[current] {
                guard parentPID(of: current) == appPID, processStartTime(current) == entry.startTime else { break }
                switch entry.root {
                case .engine(let thread): return .engine(thread)
                case .job(let thread): return .job(thread)
                case .helper: return .helper
                }
            }
            guard current > 1, let parent = parentPID(of: current), parent != current, parent != appPID else { break }
            current = parent
        }
        return .other(pid: pid)
    }

    /// <sys/un.h>：SOL_LOCAL = 0、LOCAL_PEERPID = 0x002（連線當下對方的 pid）。
    static func peerPID(_ fd: Int32) -> pid_t? {
        let solLocal: Int32 = 0, localPeerPID: Int32 = 0x002
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func processUIDs(_ pid: pid_t) -> (real: uid_t, effective: uid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return (info.kp_eproc.e_pcred.p_ruid, info.kp_eproc.e_ucred.cr_uid)
    }

    /// 程序的啟動時間（微秒）；pid 重用時會不一樣。
    static func processStartTime(_ pid: pid_t) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
