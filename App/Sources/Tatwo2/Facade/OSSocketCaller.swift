import Darwin
import Foundation
import Security

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
    /// W183 R1／R1b：ChatGPT 手腳的關口（App 在 Seatbelt 裡直接啟動的關口本人）。不綁對話（接口 v2 §1：授權一律看 grant）；
    /// 只准 `HandsContract.externalAIMethods`；它開的子行程不沿用這個身分（一律 `.other`）。
    case externalAI
    case other(pid: pid_t?)

    /// App 在行程內登記的程序根。
    enum Root: Equatable {
        case engine(UUID)
        case job(UUID)
        case helper
        case externalAI   // W183 R1／R1b：不綁對話
    }

    /// 程序根連同登記當下的啟動時間：pid 被別的程序重用、或 App 重開後舊工作已不是它的子程序，都對不上。
    struct RootEntry: Equatable {
        let root: Root
        let startTime: UInt64
        /// W183 R1：子孫是否沿用這個身分。外部 AI 的關口不沿用——只有登記的那個 pid 本人算，它開的程式一律 `.other`。
        var inheritable: Bool {
            if case .externalAI = root { return false }
            return true
        }
    }

    /// 自己人＝App、它登記的引擎／背景工作／探針、系統 sshd 轉進來的已配對設備。外部 AI 與其他程式都不算。
    var isTrusted: Bool {
        switch self {
        case .app, .engine, .job, .helper, .ssh: return true
        case .externalAI, .other: return false   // W183 R1：外部 AI 明確不算自己人
        }
    }

    /// App 自己或它登記的程序根（不含 SSH 轉進來的、不含外部 AI）。
    var isLocalApp: Bool {
        switch self {
        case .app, .engine, .job, .helper: return true
        case .ssh, .externalAI, .other: return false
        }
    }

    /// 引擎、背景指令只能以自己那條對話的身分呼叫。外部 AI 不綁對話（W183 R1b：授權看 grant，thread 參數一律忽略）。
    var boundThread: UUID? {
        switch self {
        case .engine(let thread), .job(let thread): return thread
        case .app, .helper, .ssh, .externalAI, .other: return nil
        }
    }

    var label: String {
        switch self {
        case .app: "app"
        case .engine(let thread): "engine(\(thread.uuidString.prefix(8)))"
        case .job(let thread): "job(\(thread.uuidString.prefix(8)))"
        case .helper: "helper"
        case .ssh: "ssh"
        case .externalAI: "externalAI"
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
        // W183 R1：ChatGPT 手腳的關口（HandsContract.swift 登記；一次只有一個）。
        for (pid, entry) in externalAIRoots() { roots[pid] = entry }
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
        let registry = DeviceRegistry()
        if executablePath(pid) == DeviceFleetGate.path(registry: registry).path
            || DeviceFleetRevocation.processArguments(pid)?.args.contains(DeviceFleetGate.path(registry: registry).path) == true {
            return DeviceFleetGate.identity(pid: pid, registry: registry) == nil ? .other(pid: pid) : .ssh
        }
        if let path = executablePath(pid), sshExecutables.contains(path),
           systemSSHSignature(pid: pid, path: path),
           let parent = parentPID(of: pid), parent > 1,
           let parentPath = executablePath(parent), sshExecutables.contains(parentPath),
           systemSSHSignature(pid: parent, path: parentPath),
           processUIDs(parent).map({ $0.real == 0 && $0.effective == 0 }) == true {
            // ExposeAuthInfo=yes 時 sshd 提供 SSH_USER_AUTH；不採信 RPC 的自報指紋。
            // macOS 對 sshd 的環境可能不可讀，純 -L 也可能沒有該檔；nil 時主防線仍是名單收斂 authorized_keys。
            if let fingerprint = sshAuthenticatedFingerprint(pid: pid)
                ?? DeviceFleetRevocation.childAuthenticatedFingerprint(sshPID: pid),
               !sshFingerprintAllowed(fingerprint) { return .other(pid: pid) }
            return .ssh
        }
        var current = pid
        for _ in 0..<64 {
            if let entry = roots[current] {
                guard parentPID(of: current) == appPID, processStartTime(current) == entry.startTime else { break }
                // W183 R1：不沿用的根（外部 AI 關口）只認本人；找到它時對方若是它的子孫，一律不算。
                guard entry.inheritable || current == pid else { break }
                switch entry.root {
                case .engine(let thread): return .engine(thread)
                case .job(let thread): return .job(thread)
                case .helper: return .helper
                case .externalAI: return .externalAI
                }
            }
            guard current > 1, let parent = parentPID(of: current), parent != current, parent != appPID else { break }
            current = parent
        }
        return .other(pid: pid)
    }

    /// Kernel PID plus Apple's exact system sshd identity; no request-supplied identity.
    static func systemSSHSignature(pid: pid_t, path: String) -> Bool {
        guard sshExecutables.contains(path) else { return false }
        var code: SecCode?, requirement: SecRequirement?
        let identity = path == "/usr/sbin/sshd" ? "com.apple.sshd" : "com.apple.sshd-session"
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary,
            [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString("anchor apple and identifier \"\(identity)\"" as CFString,
            [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    static func sshFingerprintAllowed(_ fingerprint: String, registry: DeviceRegistry = DeviceRegistry()) -> Bool {
        let fleet = DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment)
        do {
            guard let trust = try fleet.trust() else { return true } // 未升級設備維持 W178 原檢查。
            _ = trust
            let allowed = try fleet.capabilities(for: fingerprint) != nil
                && registry.fleetHasAuthorizedFingerprint(fingerprint)
            if !allowed { fleet.audit("fleet_ssh_untrusted_controller_refused") }
            return allowed
        } catch { fleet.audit("fleet_ssh_roster_unreadable"); return false }
    }

    /// Capture after system-sshd classification, before reading untrusted request bytes.
    static func sshFingerprint(fd: Int32, caller: OSSocketCaller) -> String? {
        guard caller == .ssh, let pid = peerPID(fd) else { return nil }
        if let gate = DeviceFleetGate.identity(pid: pid, registry: DeviceRegistry()) { return gate.fingerprint }
        return sshAuthenticatedFingerprint(pid: pid)
            ?? DeviceFleetRevocation.childAuthenticatedFingerprint(sshPID: pid)
    }

    /// Every SSH request needs an authenticated key, including unrestricted MAIN owners.
    /// Gate callers supply a kernel-verified identity; missing sshd authinfo fails closed.
    static func sshMethodAllowed(fingerprint: String?, method: String,
                                 registry: DeviceRegistry = DeviceRegistry()) -> Bool {
        guard let fingerprint else { return false }
        let fleet = DeviceFleetStore(registry: registry, environment: registry.fleetEnvironment)
        do {
            guard try fleet.trust() != nil else { return true }
            guard registry.fleetHasAuthorizedFingerprint(fingerprint),
                  try fleet.methodAllowed(fingerprint: fingerprint, method: method) else {
                fleet.audit("fleet_ssh_capability_refused"); return false
            }
            return true
        } catch { fleet.audit("fleet_ssh_roster_unreadable"); return false }
    }

    /// 只從已驗證的 sshd PID 讀這一個環境欄位；不把其他環境（可能含秘密）寫入任何日誌。
    static func sshAuthenticatedFingerprint(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // 跳過 argc、executable 及 argc 個 argv，再讀 environ；argv 自報不算 ExposeAuthInfo。
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var position = 4
        while position < size, buffer[position] != 0 { position += 1 }
        while position < size, buffer[position] == 0 { position += 1 }
        for _ in 0..<argc {
            while position < size, buffer[position] != 0 { position += 1 }; position += 1
        }
        while position < size {
            let start = position
            while position < size, buffer[position] != 0 { position += 1 }
            let value = String(decoding: buffer[start..<min(position, size)], as: UTF8.self)
            position += 1
            guard value.hasPrefix("SSH_USER_AUTH=") else { continue }
            let path = String(value.dropFirst("SSH_USER_AUTH=".count))
            guard path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 8192,
                  info.st_uid == geteuid() || info.st_uid == 0, info.st_mode & 0o022 == 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
            let keys = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 3, fields[0] == "publickey" else { return nil }
                return try? DeviceRegistry.fingerprint(publicKey: "\(fields[1]) \(fields[2])")
            }
            return keys.count == 1 ? keys.first : nil
        }
        return nil
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
