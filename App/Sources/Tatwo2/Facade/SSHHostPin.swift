import Darwin
import Foundation

enum SSHHostPinError: Error, CustomStringConvertible {
    /// 配對紀錄查無這台，或這台沒有 host 指紋（分流後只剩客戶端金鑰）。
    case hostKeyNotPaired(String)
    case pinFileUnwritable(String)

    var description: String {
        switch self {
        case .hostKeyNotPaired(let name):
            return "「\(name)」這台設備缺隧道識別（主機金鑰指紋），請重新配對"
        case .pinFileUnwritable(let detail):
            return "主機金鑰 pin 檔寫不出來：\(detail)"
        }
    }
}

/// W91c：一次性 ssh／rsync（派工遠端 worktree、Engines 同步、對機更新）共用的主機金鑰 pin。
///
/// 規則與 `RemoteHostLink.prepareHostPin` 逐條相同：只認配對紀錄裡的 **host** 指紋，
/// 從 known_hosts 撈出「指紋相符的那一把」重新標成固定別名寫進專屬檔，ssh 只讀那一檔；
/// 沒有 host 指紋＝拒絕，不退回 TOFU，也不提供任何放寬旋鈕。
/// （`RemoteHostLink` 保留它自己那份：隧道要帶 endpoint／演算法狀態，且既有測試單獨編譯那一檔。）
final class SSHHostPin {
    /// 寫進 pin 檔的別名；ssh 要用 `HostKeyAlias` 才查得到這一行（比對金鑰本體，不比對主機名）。
    static let alias = "tatwo-paired-host"

    let fingerprint: String
    let algorithms: String
    let knownHostsFile: URL

    private init(fingerprint: String, algorithms: String, knownHostsFile: URL) {
        self.fingerprint = fingerprint
        self.algorithms = algorithms
        self.knownHostsFile = knownHostsFile
    }

    deinit { try? FileManager.default.removeItem(at: knownHostsFile) }

    static func make(_ device: DeviceRecord,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SSHHostPin {
        guard let pinned = device.pinnedHostKeyFingerprint, pinned.hasPrefix("SHA256:") else {
            throw SSHHostPinError.hostKeyNotPaired(device.name)
        }
        let known = environment["TATWO2_SSH_KNOWN_HOSTS"] ?? environment["TATWO2_KNOWN_HOSTS"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path
        let lines = (try? String(contentsOfFile: known, encoding: .utf8))?.split(separator: "\n") ?? []
        var match: (key: String, type: String)?
        for line in lines where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }
            let key = "\(parts[1]) \(parts[2])"
            if (try? DeviceRegistry.fingerprint(publicKey: key)) == pinned {
                match = (key, String(parts[1])); break
            }
        }
        guard let match else { throw SSHHostPinError.hostKeyNotPaired(device.name) }
        let file = pinDirectory().appendingPathComponent("w91c-host-" + UUID().uuidString)
        do {
            try Data((alias + " " + match.key + "\n").utf8).write(to: file, options: .atomic)
        } catch {
            throw SSHHostPinError.pinFileUnwritable(error.localizedDescription)
        }
        _ = chmod(file.path, 0o600)
        return SSHHostPin(fingerprint: pinned,
                          algorithms: match.type == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : match.type,
                          knownHostsFile: file)
    }

    /// `RemoteDeviceRef` 只帶 id：回同一份配對紀錄找這台的 host 指紋，查不到就是缺。
    static func make(deviceID: String, name: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SSHHostPin {
        guard let record = DeviceStatusReader.registry(environment: environment).first(where: { $0.id == deviceID }) else {
            throw SSHHostPinError.hostKeyNotPaired(name)
        }
        return try make(record, environment: environment)
    }

    /// rsync 的 `-e` 字串是照空白切的（不解引號），所以 pin 檔要落在沒有空白的目錄。
    private static func pinDirectory() -> URL {
        let temporary = NSTemporaryDirectory()
        let usable = !temporary.isEmpty
            && !temporary.contains(where: { $0.isWhitespace })
            && !temporary.contains("\"")
        return URL(fileURLWithPath: usable ? temporary : "/tmp", isDirectory: true)
    }

    /// 主機金鑰相關＋BatchMode 的固定選項；逾時／連線那類選項由各呼叫點自己接。
    var options: [String] {
        // -o 的值照 ssh_config 語法解析，路徑一律加引號（核可的 staging 卷帶空白）。
        let quoted = knownHostsFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(quoted)\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=\(algorithms)", "-o", "UpdateHostKeys=no",
            "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
            "-o", "HostKeyAlias=\(Self.alias)", "-o", "CheckHostIP=no",
        ]
    }

    /// 手上沒有 pin 時的固定形狀（只有 fixture 擷取會走到）：known_hosts 是空的，ssh 必定拒絕。
    /// 這比 pin 更嚴，不是放寬旋鈕；真的要連線的路徑一律先 `make` 出 pin，缺指紋就 throw。
    static let denied: [String] = [
        "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "UpdateHostKeys=no", "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
        "-o", "HostKeyAlias=tatwo-paired-host", "-o", "CheckHostIP=no",
    ]

    static func options(_ pin: SSHHostPin?) -> [String] { pin?.options ?? denied }
}
