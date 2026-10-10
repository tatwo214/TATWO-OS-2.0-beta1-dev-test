import Combine
import Foundation
import Security

// W183 R3：設定 › 環境登入 › Cloudflare（多帳號；使用者 09-27「設定/環境登入/github|cloudflare 全部都走多號可登入」）。
//
// - 帳號從哪來：標準設定流程的「授權」步驟（HandsSetup：獨立 HOME 跑 `cloudflared tunnel login`，使用者在 OS 瀏覽器按一下）。
//   授權完就記在這裡，TAP › ChatGPT 只「選用」，不另外登入（spec「這裡是帳號的唯一存放處」）。
// - 清單檔 `<tatwo2>/cloudflare/accounts.json`（0600、原子寫入）只放：帳號 id、名稱、網域（名稱＋zone id）、選用的網域、通道 id。
//   不放任何憑證、token；不放在入口（那裡是 git、會備份到 GitHub）。
// - 秘密只在鑰匙圈（CloudflareKeychain）：不同步、不自訂存取清單（只有 TATWO OS 自己讀得到，其他 App 讀要使用者同意）。
//   **不照抄** GitHubAccounts.keychainAccess() 那種「所有 App 都能讀」的寫法。
//   ThisDeviceOnly（W183 R3 審查）：macOS 只有 data-protection 鑰匙圈會照 kSecAttrAccessible 做；舊式的登入鑰匙圈會忽略它。
//   所以照 BrowserPasswordVault 的做法：先寫 data-protection 鑰匙圈（WhenUnlockedThisDeviceOnly）；App 的簽章沒有 keychain-access-groups
//   權限時系統回 -34018，才退回登入鑰匙圈（每個使用者一份、App 預設存取清單；**這時 ThisDeviceOnly 沒有保障**：
//   移轉輔助程式搬整個登入鑰匙圈到新 Mac 時會一起搬——寫在報告的殘餘）。每次寫都「先刪再加」：屬性與存取清單一定是我們這次給的，
//   不會把秘密寫進別的程式預先建好、存取清單比較寬的同名項目。讀、刪兩邊都看。
//   服務名：`tatwo2-cloudflare`（帳號欄 `cert:<zone id>`＝授權得到的憑證）、`tatwo2-cloudflare-tunnel`（帳號欄 `tunnel`＝通道 token，R2 照這個讀）。
// - 資料層是 `.shared`：環境登入與 TAP 兩頁看同一份，登入一次兩邊都看得到。

struct CloudflareDomain: Codable, Equatable, Hashable, Sendable {
    /// 網域名稱（例 example.com）；授權後還讀不到時是空字串，建通道時會補上。
    var name: String
    var zoneID: String

    enum CodingKeys: String, CodingKey { case name, zoneID = "zone_id" }
}

struct CloudflareAccount: Codable, Equatable, Identifiable, Sendable {
    /// Cloudflare 的 account id（32 位十六進位）。
    var id: String
    var name: String
    var domains: [CloudflareDomain]
    /// ChatGPT 手腳選用的網域（zone id）。
    var selectedDomain: String?
    /// ChatGPT 手腳在這個帳號建的通道（只有 id，不是 token）。
    var tunnelID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, domains
        case selectedDomain = "selected_domain"
        case tunnelID = "tunnel_id"
    }

    /// W183 R8c（GPT-6 必改 4）：只有**明確選過**的才算（不再退回第一個網域：登入不等於選了網址）。
    var selected: CloudflareDomain? {
        domains.first { $0.zoneID == selectedDomain }
    }

    var displayName: String { name.isEmpty ? "Cloudflare 帳號 \(id.prefix(6))" : name }
}

// MARK: - 鑰匙圈

protocol CloudflareSecretStore: AnyObject, Sendable {
    func read(service: String, account: String) throws -> String?
    /// 只問有沒有（不讀內容、不跳授權框）。
    func contains(service: String, account: String) -> Bool
    func save(_ value: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

enum CloudflareSecretError: Error, CustomStringConvertible, Equatable {
    case invalid, locked, keychain(OSStatus)
    var description: String {
        switch self {
        case .invalid: "cloudflare_secret_invalid"
        case .locked: "cloudflare_keychain_locked"
        case .keychain(let status): "cloudflare_keychain_\(status)"
        }
    }
}

/// generic password：先 data-protection 鑰匙圈（WhenUnlockedThisDeviceOnly），沒有權限（-34018）才退回登入鑰匙圈；不同步、
/// 用 App 預設的存取清單（只有建立它的 TATWO OS 讀得到）。讀一律不跳授權框（kSecUseAuthenticationUIFail）：讀不到就回 locked，由畫面說明。
final class CloudflareKeychain: CloudflareSecretStore, @unchecked Sendable {
    static let certService = "tatwo2-cloudflare"
    static let tunnelService = HandsTunnelKeychain.service   // R2 照這個名稱讀（account "tunnel"；兩種鑰匙圈都看）
    static let tunnelAccount = "tunnel"
    static let missingEntitlement: OSStatus = -34018

    enum Backend: CaseIterable { case dataProtection, login }

    private func query(_ service: String, _ account: String, _ backend: Backend) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        if backend == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    func read(service: String, account: String) throws -> String? {
        for backend in Backend.allCases {
            var q = query(service, account, backend)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound || status == Self.missingEntitlement { continue }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw CloudflareSecretError.locked }
            guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CloudflareSecretError.keychain(status)
            }
            DeviceOnlyKeychain.harden(query(service, account, backend))
            return value
        }
        return nil
    }

    func contains(service: String, account: String) -> Bool {
        Backend.allCases.contains { backend in
            var q = query(service, account, backend)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemCopyMatching(q as CFDictionary, nil)
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }
    }

    /// 先刪再加（兩種鑰匙圈的舊項目都刪）：新項目的屬性與存取清單一定是這次給的。
    func save(_ value: String, service: String, account: String) throws {
        guard !value.isEmpty, value.utf8.count <= 64 * 1024, !value.contains("\0") else { throw CloudflareSecretError.invalid }
        try remove(service: service, account: account)
        var last: OSStatus = errSecSuccess
        for backend in Backend.allCases {
            var insert = query(service, account, backend)
            insert[kSecValueData as String] = Data(value.utf8)
            // ThisDeviceOnly：不進備份還原到別台、不同步（data-protection 鑰匙圈才會照做）。不給 kSecAttrAccess（不改存取清單）＝只有 TATWO OS 自己。
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insert[kSecAttrLabel as String] = service == Self.certService ? "TATWO OS Cloudflare 授權" : "TATWO OS ChatGPT 手腳通道"
            last = SecItemAdd(insert as CFDictionary, nil)
            if last == errSecSuccess { return }
            if last != Self.missingEntitlement { break }
        }
        throw CloudflareSecretError.keychain(last)
    }

    func remove(service: String, account: String) throws {
        for backend in Backend.allCases {
            var q = query(service, account, backend)
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement else {
                throw CloudflareSecretError.keychain(status)
            }
        }
    }
}

/// 隔離環境（staging／自測／source test）的秘密庫：不碰真的鑰匙圈（W183 R3 審查：設定的入口也要擋，不能只靠 fixture 環境變數）。
final class CloudflareRefusingSecrets: CloudflareSecretStore, @unchecked Sendable {
    func read(service: String, account: String) throws -> String? { throw CloudflareSecretError.invalid }
    func contains(service: String, account: String) -> Bool { false }
    func save(_ value: String, service: String, account: String) throws { throw CloudflareSecretError.invalid }
    func remove(service: String, account: String) throws {}
}

#if DEBUG
/// 自測與畫面預覽用的記憶體假鑰匙圈（只在 DEBUG 編譯存在；不落檔、不跨行程）。
/// 真鑰匙圈在假 HOME 下會跳授權框卡住三輪驗收（照 GitHubAccounts 的 fixture 做法）。
final class CloudflareMemorySecrets: CloudflareSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    init() {}
    private func key(_ service: String, _ account: String) -> String { service + "\u{1}" + account }
    func read(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key(service, account)]
    }
    func contains(service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[key(service, account)] != nil
    }
    func save(_ value: String, service: String, account: String) throws {
        guard !value.isEmpty, !value.contains("\0") else { throw CloudflareSecretError.invalid }
        lock.lock(); values[key(service, account)] = value; lock.unlock()
    }
    func remove(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemoves { throw CloudflareSecretError.locked }   // W183 R3b：自測模擬鑰匙圈鎖著、刪不掉
        values[key(service, account)] = nil
    }
    private var failRemoves = false
    /// 自測：模擬刪不掉（鑰匙圈鎖著）。
    var failRemovesForTesting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failRemoves }
        set { lock.lock(); failRemoves = newValue; lock.unlock() }
    }
    /// 自測：目前存了幾筆（證明秘密在鑰匙圈、不在檔案）。
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func allValues() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(values.values) }
}
#endif

// MARK: - 帳號清單

/// 兩頁共用的帳號清單。可以從任何執行緒呼叫（鎖保護），畫面的 @Published 在主執行緒更新。
final class CloudflareAccountsStore: ObservableObject, @unchecked Sendable {
    static let shared = CloudflareAccountsStore()

    @Published private(set) var accounts: [CloudflareAccount] = []

    let fileURL: URL
    let secrets: CloudflareSecretStore
    private let lock = NSRecursiveLock()
    private var current: [CloudflareAccount] = []

    struct Document: Codable, Equatable {
        var version = 1
        var accounts: [CloudflareAccount] = []
    }

    init(fileURL: URL = CloudflareAccountsStore.defaultURL(), secrets: CloudflareSecretStore = CloudflareAccountsStore.defaultSecrets()) {
        self.fileURL = fileURL
        self.secrets = secrets
        current = Self.load(fileURL)
        accounts = current
    }

    /// `<tatwo2>/cloudflare/accounts.json`（跟 GitHub 的 accounts.json 同一層；TATWO2_LIVE_ROOT 會把它帶到 staging）。
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let live = environment["TATWO2_LIVE_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        return live.deletingLastPathComponent().appendingPathComponent("cloudflare", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    /// 正式：鑰匙圈。DEBUG 且 `TATWO2_CLOUDFLARE_CREDENTIAL_FIXTURE=memory`：記憶體假資料（匯出畫面、自測用；release 沒有這條路）。
    /// staging／自測／source test 沒有明確要記憶體假資料：一律拒絕（不碰正式鑰匙圈；W183 R3 審查）。
    static func defaultSecrets(environment: [String: String] = ProcessInfo.processInfo.environment) -> CloudflareSecretStore {
        #if DEBUG
        if environment["TATWO2_CLOUDFLARE_CREDENTIAL_FIXTURE"] == "memory" { return CloudflareMemorySecrets() }
        #endif
        if HandsSetup.isolated(environment) { return CloudflareRefusingSecrets() }
        return CloudflareKeychain()
    }

    private static func load(_ url: URL) -> [CloudflareAccount] {
        guard let data = HandsFiles.readSecure(url, limit: 1024 * 1024),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return document.accounts.filter { Self.validID($0.id) }.map(Self.sanitized)
    }

    static func validID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    private static func sanitized(_ account: CloudflareAccount) -> CloudflareAccount {
        var copy = account
        copy.name = String(account.name.filter { !$0.isNewline }.prefix(80))
        copy.domains = account.domains.filter { validID($0.zoneID) }
            .map { CloudflareDomain(name: HandsGatewayLaunch.validHost($0.name) ?? "", zoneID: $0.zoneID) }
        if let selected = copy.selectedDomain, !copy.domains.contains(where: { $0.zoneID == selected }) { copy.selectedDomain = nil }
        if let tunnel = copy.tunnelID, UUID(uuidString: tunnel) == nil { copy.tunnelID = nil }
        return copy
    }

    var snapshot: [CloudflareAccount] { lock.lock(); defer { lock.unlock() }; return current }

    func reload() {
        lock.lock(); current = Self.load(fileURL); let value = current; lock.unlock()
        publish(value)
    }

    private func publish(_ value: [CloudflareAccount]) {
        if Thread.isMainThread { accounts = value } else { DispatchQueue.main.async { [weak self] in self?.accounts = value } }
    }

    private func save(_ list: [CloudflareAccount]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(Document(accounts: list)), to: fileURL)
    }

    private func mutate(_ change: (inout [CloudflareAccount]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var list = current
        try change(&list)
        list = list.map(Self.sanitized)
        try save(list)
        current = list
        publish(list)
    }

    static func certAccount(_ zoneID: String) -> String { "cert:" + zoneID }

    func account(_ id: String) -> CloudflareAccount? { snapshot.first { $0.id == id } }

    /// 這個網域有沒有存授權（只問有沒有，不讀內容）。
    func hasCert(zoneID: String) -> Bool {
        secrets.contains(service: CloudflareKeychain.certService, account: Self.certAccount(zoneID))
    }

    /// 用授權時才讀（寫成 0600 暫存檔給 cloudflared，用完就刪）。
    func cert(zoneID: String) throws -> String? {
        try secrets.read(service: CloudflareKeychain.certService, account: Self.certAccount(zoneID))
    }

    /// 授權完成：先把憑證收進鑰匙圈，再更新清單；清單寫不進去就把剛存的憑證拿掉（不留下沒有帳號的秘密）。
    /// W183 R8c（GPT-6 必改 4）：只記帳號與網域，**不自動選網域**（selectedDomain 只由使用者的選擇與「套用」寫）。
    func upsert(accountID: String, name: String?, domain: CloudflareDomain, cert: String) throws {
        guard Self.validID(accountID), Self.validID(domain.zoneID) else { throw CloudflareSecretError.invalid }
        let hadCert = hasCert(zoneID: domain.zoneID)
        try secrets.save(cert, service: CloudflareKeychain.certService, account: Self.certAccount(domain.zoneID))
        do {
            try mutate { list in
                if let index = list.firstIndex(where: { $0.id == accountID }) {
                    if let name, !name.isEmpty { list[index].name = name }
                    if let existing = list[index].domains.firstIndex(where: { $0.zoneID == domain.zoneID }) {
                        if !domain.name.isEmpty { list[index].domains[existing].name = domain.name }
                    } else {
                        list[index].domains.append(domain)
                    }
                } else {
                    list.append(CloudflareAccount(id: accountID, name: name ?? "", domains: [domain], selectedDomain: nil, tunnelID: nil))
                }
            }
        } catch {
            if !hadCert { try? secrets.remove(service: CloudflareKeychain.certService, account: Self.certAccount(domain.zoneID)) }
            throw error
        }
    }

    /// 建通道時才知道網域名稱（授權後讀不到的情況）：補上。
    func setDomainName(zoneID: String, name: String) throws {
        guard let host = HandsGatewayLaunch.validHost(name) else { throw CloudflareSecretError.invalid }
        try mutate { list in
            for index in list.indices {
                for d in list[index].domains.indices where list[index].domains[d].zoneID == zoneID { list[index].domains[d].name = host }
            }
        }
    }

    /// ChatGPT 手腳選用哪個帳號的哪個網域（TAP › ChatGPT 的選單、標準流程）。
    func select(accountID: String, zoneID: String) throws {
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.id == accountID }),
                  list[index].domains.contains(where: { $0.zoneID == zoneID }) else { throw CloudflareSecretError.invalid }
            list[index].selectedDomain = zoneID
        }
    }

    func setTunnel(accountID: String, tunnelID: String?) throws {
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.id == accountID }) else { throw CloudflareSecretError.invalid }
            list[index].tunnelID = tunnelID
        }
    }

    /// 移除帳號：刪掉這台存的授權（每個網域一份）；removeTunnelToken＝通道 token 是它的通道的（由 HandsSetup.removeAccount 判斷，
    /// 而且在那之前已經先停掉手腳），先刪 token，再刪授權、最後改清單——前面失敗就丟錯，不會留下「清單沒了、秘密還在」。
    /// Cloudflare 上的通道與 DNS 紀錄不動（不碰使用者帳號裡的東西；要刪請到 Cloudflare 後台）。
    func remove(accountID: String, removeTunnelToken: Bool) throws {
        guard let account = account(accountID) else { return }
        if removeTunnelToken {
            try secrets.remove(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
        }
        for domain in account.domains {
            try secrets.remove(service: CloudflareKeychain.certService, account: Self.certAccount(domain.zoneID))
        }
        try mutate { $0.removeAll { $0.id == accountID } }
    }

    /// W183 R3b「取消並重新授權」：只刪這個網域的授權（這次登入拿到的）；帳號沒有別的網域就整個移除（同 remove）。
    /// 先刪秘密、再改清單。回傳帳號是不是整個移除了。
    @discardableResult
    func removeDomain(accountID: String, zoneID: String, removeTunnelToken: Bool) throws -> Bool {
        guard let account = account(accountID) else { return false }
        if account.domains.allSatisfy({ $0.zoneID == zoneID }) {
            try remove(accountID: accountID, removeTunnelToken: removeTunnelToken)
            return true
        }
        try secrets.remove(service: CloudflareKeychain.certService, account: Self.certAccount(zoneID))
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.id == accountID }) else { return }
            list[index].domains.removeAll { $0.zoneID == zoneID }
            if list[index].selectedDomain == zoneID { list[index].selectedDomain = nil }
        }
        return false
    }

    // MARK: 通道 token（R2 的 HandsTunnelKeychain 讀同一個位置）

    func hasTunnelToken() -> Bool {
        secrets.contains(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
    }

    /// W183 R3b 審查：只刪通道 token（「取消並重新授權」清這一輪的 token；帳號、其他網域的授權留著）。
    func removeTunnelToken() throws {
        try secrets.remove(service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
    }

    func saveTunnelToken(_ token: String) throws {
        guard HandsGatewayLaunch.validToken(token) else { throw CloudflareSecretError.invalid }
        try secrets.save(token, service: CloudflareKeychain.tunnelService, account: CloudflareKeychain.tunnelAccount)
    }
}
