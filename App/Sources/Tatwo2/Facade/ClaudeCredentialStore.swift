// W106：Claude 額度一直讀不到、還叫人重新登入，但聊天明明能用。
// 根因是同一台機器上有兩份 Claude 憑證 namespace：登入子程序寫一份、聊天 sidecar 讀另一份，
// 額度讀的是登入那份（登入當下寫完就沒人更新），於是永遠拿到過期 token。
// 這裡把「額度要讀哪一份憑證」收斂成唯一來源，並且把「沒登入／讀不到／過期」分開講清楚。
import Foundation
import CryptoKit
import Security

enum ClaudeCredentialStore {
    /// Claude Code 共用的 Keychain 服務名（securestorage namespace 為空時就是它）。
    static let baseService = "Claude Code-credentials"

    struct Credential: Equatable {
        let service: String
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?

        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    /// 讀不到憑證時的三種情況；措辭不可互相冒充，尤其「過期」不等於「要重新登入」。
    static let accessDeniedReason = "Claude 已登入、聊天正常，不是沒登入；額度要另外讀鑰匙圈裡的憑證，macOS 需要你允許一次"

    enum Failure: Error, Equatable {
        case noCredential
        case accessDenied
        case expired(Date?)

        var reason: String {
            switch self {
            case .noCredential:
                return "Keychain 裡沒有 Anthropic 登入憑證；要在這裡登入一次"
            case .accessDenied:
                return ClaudeCredentialStore.accessDeniedReason
            case .expired(let date):
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let when = date.map { formatter.string(from: $0) } ?? "時間不明"
                return "存起來的 Anthropic 憑證已過期（\(when)）；Claude 還能聊天代表引擎已經換過新的，換到 Keychain 後這裡就會顯示"
            }
        }
    }

    /// Claude Code 的規則：namespace 空＝共用服務名，非空＝服務名加上 sha256(namespace) 前 8 碼。
    static func service(namespace: String) -> String {
        let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseService }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "\(baseService)-\(digest)"
    }

    /// 第一順位一定是聊天 sidecar 用的 namespace：額度要跟能不能聊天講同一件事。
    /// 第二順位才是舊版登入子程序可能留下的獨立 namespace，當備援用，不搶先。
    static func candidateServices(
        paths: EnginePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let chat = service(namespace: NativeStagingIsolation.sidecarClaudeNamespace(
            environment: environment,
            configDirectory: paths.claudeConfigDirectory.path))
        let isolated = service(namespace: paths.claudeConfigDirectory.path)
        return chat == isolated ? [chat] : [chat, isolated]
    }

    /// 回傳 Keychain 讀取結果；測試可以注入 reader，不碰真的 Keychain。
    typealias Reader = @Sendable (String) -> (status: OSStatus, data: Data?)

    static func load(
        paths: EnginePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        reader: Reader = ClaudeCredentialStore.keychainReader
    ) -> Result<Credential, Failure> {
        var denied = false
        var bestExpired: Credential?
        for service in candidateServices(paths: paths, environment: environment) {
            let outcome = reader(service)
            if outcome.status == errSecItemNotFound { continue }
            guard outcome.status == errSecSuccess,
                  let data = outcome.data,
                  let credential = decode(service: service, data: data)
            else {
                denied = true
                continue
            }
            // 沒過期就直接用；過期的先留著，全部都過期時才拿最新的一份報告日期。
            if !credential.isExpired(now: now) { return .success(credential) }
            if (credential.expiresAt ?? .distantPast) > (bestExpired?.expiresAt ?? .distantPast) {
                bestExpired = credential
            }
        }
        // 有一份讀不到（通常就是聊天在用、持續更新的那份）時，先講「需要你允許」：那才是使用者能處理的事；
        // 另一份過期只是舊登入留下的殘骸。
        if denied { return .failure(.accessDenied) }
        if let bestExpired { return .failure(.expired(bestExpired.expiresAt)) }
        return .failure(.noCredential)
    }

    static func decode(service: String, data: Data) -> Credential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return Credential(
            service: service,
            accessToken: token,
            expiresAt: expiry(oauth["expiresAt"]),
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    /// Claude Code 存的是毫秒；舊版有存秒的，兩種都吃。
    static func expiry(_ raw: Any?) -> Date? {
        var number: Double?
        if let value = raw as? NSNumber { number = value.doubleValue }
        else if let text = raw as? String { number = Double(text) }
        guard let number, number > 0 else { return nil }
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    /// 自動讀取一律「不准跳系統視窗」。共用那份憑證是 Claude Code CLI 建的，鑰匙圈只信任 CLI 自己；
    /// 別的程式一讀，macOS 就會跳「要不要允許」的密碼視窗，而且 securityd 一次只處理一個請求——
    /// 主執行緒剛好也在讀鑰匙圈（GitHub token）就整個 App 卡死（.021 sample 實證）。
    /// 所以背景更新讀不到就回 accessDenied；要授權只能由使用者自己按按鈕觸發（authorizeInteractively）。
    static let keychainReader: Reader = { service in read(service: service, interactive: false) }

    private static let interactionLock = NSLock()

    private static func read(service: String, interactive: Bool) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // 實測（2026-09-19，獨立小程式）：kSecUseAuthenticationUIFail 對這種舊式（檔案型）鑰匙圈的 ACL 視窗無效，照跳；
        // 只有行程層級的 SecKeychainSetUserInteractionAllowed(false) 擋得住（0.03 秒回 errSecAuthFailed、不跳視窗）。
        // 它是全行程開關，所以用鎖包住、讀完立刻還原；互動式讀取也排同一把鎖，不會在關閉期間被誤擋。
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous: DarwinBoolean = true
        if !interactive {
            SecKeychainGetUserInteractionAllowed(&previous)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    /// 使用者在模型登入頁按「允許讀取額度」時才呼叫：這一次允許 macOS 跳授權視窗（選「永遠允許」之後就不會再問）。
    /// 一定在背景執行緒跑；回傳是否讀到。
    static func authorizeInteractively(paths: EnginePaths,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        let service = candidateServices(paths: paths, environment: environment)[0]
        return await Task.detached(priority: .userInitiated) {
            read(service: service, interactive: true).status == errSecSuccess
        }.value
    }
}
