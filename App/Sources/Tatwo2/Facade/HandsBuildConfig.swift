import CryptoKit
import Foundation

// W183 R8c：ChatGPT build 的多設備設定（docs/specs/183-chatgpt-hands/chatgpt-build.md；GPT-6 設計審查 W183-R8「開工前必改」六條）。
//
// 使用者 09-28：「我人不在主設備 我根本按不了授權 可是這些都是我的設備」「登入完選擇網址跟設備……沒有副設備的人一率主設備，
// 有多設備的人在選擇可選擇單一設備或多設備綁定」「可以 多設備就這樣 照對照稿開工」（每台各自一個網址、一條連線）。
//
// - 設定的正本在主設備（沒配對任何設備的單機＝它自己就是正本）：勾了哪些設備、Cloudflare 帳號與網域、每台的子網域、每台的等級上限與專案
//   （專案是那台自己的 id：(deviceID, projectID)）。**不含任何金鑰、token、憑證**。
// - 世代分開（GPT-6 必改 1）：主權 epoch（device.json）／設定版本 configRevision（整份，每改一次 +1）／每台的設定版本 deviceRevision
//   （那一台的內容變了才 +1）／每台的撤銷世代 revocationGeneration（明確關掉那一台才 +1）／每台自己的 setupEpoch（HandsSetup，不在這裡）。
//   關 B 只動 B 的 deviceRevision、revocationGeneration；A 的內容沒變＝A 的服務不動。
// - 改設定一律「預期版本比對」（CAS）：延遲送達的舊請求（舊的啟用／關閉）版本對不上＝不收。
// - 同一個主機名（子網域＋網域）不能分給兩台；已經有別台建立證據的主機名也不能分（HandsBuildOwnership）。
// - 舊資料遷移（必改 8）：第一次讀、還沒有 build-config.json＝照舊的單主機設定（HandsSettings＋HandsSetupState）遷成「勾選那一台」的一份；
//   不複製任何 OAuth 狀態（auth.json 一律留在各台、不同步）。

/// 一台設備在 ChatGPT build 裡的設定（主設備存）。
struct HandsBuildDeviceEntry: Codable, Equatable, Sendable {
    var deviceID: String
    var name: String
    var isPrimary: Bool
    var selected: Bool
    /// 這台的子網域標籤（主設備預設 os-for-chatgpt，其他 os-for-chatgpt-<簡稱>；可改）。
    var subdomain: String
    /// 等級上限（0…2）。那台實際的等級＝它自己核准的（［連線］卡上選的）∩ 這個上限：這裡只會替那台收窄，不會替它放大。
    var level: Int
    /// 允許的專案（那台自己的專案 id；那台自己解析，不存在的一律不算）。
    var projectIDs: [String]
    /// 這台的內容每改一次 +1。
    var deviceRevision: Int
    /// 明確關掉這台（取消勾選、整個關掉）一次 +1：那台看到比自己套用過的大＝撤銷它全部的 ChatGPT 連線。
    var revocationGeneration: Int

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", name, isPrimary = "is_primary", selected, subdomain, level
        case projectIDs = "project_ids", deviceRevision = "device_revision", revocationGeneration = "revocation_generation"
    }
}

/// 給一台設備的那一份（信封裡簽的內容；只有那台需要的，不含別台的任何東西）。
struct HandsBuildDeviceSlice: Codable, Equatable, Sendable {
    var deviceID: String
    var name: String
    /// 開關開著、而且勾了這台。
    var active: Bool
    var subdomain: String
    /// `<子網域>.<網域>`（網域還沒選＝nil）。
    var hostname: String?
    var accountID: String?
    var zoneID: String?
    var domain: String?
    var level: Int
    var projectIDs: [String]
    var deviceRevision: Int
    var revocationGeneration: Int
    /// ChatGPT 裡的連接器名稱「TATWO（<設備名稱>）」。
    var connectorName: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", name, active, subdomain, hostname, accountID = "account_id", zoneID = "zone_id", domain, level
        case projectIDs = "project_ids", deviceRevision = "device_revision", revocationGeneration = "revocation_generation"
        case connectorName = "connector_name"
    }

    /// 簽章涵蓋的內容雜湊（兩邊用同一個編碼：排序鍵的 JSON）。
    var contentHash: String { "sha256:" + HandsAuth.sha256Hex(HandsBuildCanonical.encode(self)) }

    /// 比較「內容變了沒」用（不看兩個版本號）。
    var contentKey: HandsBuildDeviceSlice {
        var copy = self
        copy.deviceRevision = 0
        copy.revocationGeneration = 0
        return copy
    }
}

/// 排序鍵、不跳脫斜線的 JSON（簽章與雜湊的正規形；兩端同一個編碼器）。
enum HandsBuildCanonical {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func object(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func hash(_ value: Any) -> String { "sha256:" + HandsAuth.sha256Hex(object(value)) }
}

struct HandsBuildConfig: Codable, Equatable, Sendable {
    static let schemaName = "tatwo.hands-build.v1"
    var schema: String = HandsBuildConfig.schemaName
    var primaryID: String
    var authorityEpoch: Int
    var configRevision: Int
    /// ChatGPT build 的總開關。
    var enabled: Bool
    var accountID: String?
    var zoneID: String?
    var domain: String?
    var devices: [HandsBuildDeviceEntry]
    /// 從舊的單主機設定遷過來的（只記一次，畫面與報告看）。
    var migratedFromLegacy: Bool?
    /// W183 R11：這一份的預設等級是照哪一版的規則（nil＝R11 之前：舊預設 L1；2＝R11 起預設 L2）。舊的一份第一次讀到時照一次（upgradedDefaults）。
    var levelDefault: Int?
    /// W183 R11（GPT-6 R11 審查 1，高：「遷移不能提高任何既有連線的有效上限」）：舊的一份裡還是舊預設 L1、還沒升到 L2 的那幾台。
    /// 升不升看那台自己的回報：回報會先封頂現有連線（level_guard，R11 起的主機）或根本沒有連線（grants＝0）才升；舊版主機有連線＝先不升
    ///（舊版收到調高就會讓收窄過的舊 L2 grant 恢復），等它更新或斷線。面板上改那台的等級＝使用者自己決定了，拿掉。
    var levelDefaultPending: [String]?
    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇；「他連上就是全部都能看」＝連上＝全開＝L2）：這一份照過「所有設備一律 L2」沒
    ///（nil＝還沒照；true＝照過）。照一次＝低於 L2 的每一台（L0 也算：面板已經沒有等級可選）記進待升清單；升不升照 R11 同一道（unifiedLevels）。
    var levelUnified: Bool?

    enum CodingKeys: String, CodingKey {
        case schema, primaryID = "primary_id", authorityEpoch = "authority_epoch", configRevision = "config_revision", enabled
        case accountID = "account_id", zoneID = "zone_id", domain, devices, migratedFromLegacy = "migrated_from_legacy"
        case levelDefault = "level_default", levelDefaultPending = "level_default_pending"
        case levelUnified = "level_unified"   // W183 R12
    }

    static let maxDevices = 16
    static let maxProjects = 64
    /// W183 R11（使用者 09-30：「接上要明確讓chatgpt能獲得codex能力 以及os記憶讀取」；主導：「如果現在預設不是這樣，改成一按［連線］就是這樣，
    /// 不要再多一步選範圍」）：新加進來的設備預設 L2＝Codex（沙盒工作區：讀、改檔、跑測試，交件後你合併）＋記憶（讀、遮敏感；寫只進 ChatGPT 收件匣）。
    /// 兩條底線照舊在主機擋（HandsFloors.swift）：金鑰類檔案讀不到、交易實盤類專案最多 L0。面板上照樣可以改成 L1、L0。
    static let defaultLevel = 2

    static func empty(primaryID: String, epoch: Int) -> HandsBuildConfig {
        HandsBuildConfig(primaryID: primaryID.lowercased(), authorityEpoch: epoch, configRevision: 0, enabled: false,
                         accountID: nil, zoneID: nil, domain: nil, devices: [], migratedFromLegacy: nil, levelDefault: defaultLevel,
                         levelUnified: true)   // W183 R12：新的一份一開始就是「一律 L2」（新加的設備預設 L2）
    }

    /// W183 R11：R11 之前的那一份（沒有 level_default）第一次讀到時照一次新的預設：還是舊預設 L1 的那幾台記成「待升到 L2」（L0 是使用者
    /// 刻意收窄的，不動；之後在面板改的照改）。W183 R11（GPT-6 R11 審查 1，高）：這裡不直接升——那台現有的連線（可能是收窄過的舊 L2 grant）
    /// 不能因為遷移就拿回 L2：等那台的回報說它會先封頂（level_guard）或沒有連線，才升（raisingPending）。已經照過（有 level_default）＝nil。
    static func upgradedDefaults(_ config: HandsBuildConfig) -> HandsBuildConfig? {
        guard config.levelDefault == nil else { return nil }
        var next = config
        next.levelDefault = defaultLevel
        let pending = next.devices.filter { $0.level == 1 }.map(\.deviceID)
        next.levelDefaultPending = pending.isEmpty ? nil : pending
        next.configRevision = config.configRevision + 1
        return next
    }

    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇，連上＝全開；主導：中央設定所有設備一律 L2，但 R11 的安全規則照守）：還沒照過的那一份
    /// 照一次——低於 L2 的每一台（L1、L0 都算：L0 以前當成刻意收窄、不動；現在面板沒有等級可選了）記進待升清單（已經在的不重複）。
    /// 這裡不直接升：那台現有的連線不因此放大（升的時候那台的主機先封頂：HandsService.levelGuard；要新能力得重新按［連線］）；升不升照 R11
    /// 同一道（raisingPending → raiseCheck：會先封頂的主機、回報夠新、已經套用到這一版才升；舊版主機一律不升）。照過（level_unified）＝nil。
    static func unifiedLevels(_ config: HandsBuildConfig) -> HandsBuildConfig? {
        guard config.levelUnified != true else { return nil }
        var next = config
        next.levelDefault = defaultLevel
        next.levelUnified = true
        var pending = config.levelDefaultPending ?? []
        for entry in config.devices where entry.level < defaultLevel && !pending.contains(where: { HandsHostAuthority.same($0, entry.deviceID) }) {
            pending.append(entry.deviceID.lowercased())
        }
        next.levelDefaultPending = pending.isEmpty ? nil : pending
        next.configRevision = config.configRevision + 1
        return next
    }

    /// W183 R11（GPT-6 R11 審查 1）：那台來回報了——待升的那台，回報說它會先封頂現有連線（R11 起的主機）或沒有連線，才升到預設（那台的版本 +1、
    /// 整份 +1，收到信封就生效；那台的主機在新等級生效之前先把現有的 grant 封頂：HandsService.levelGuard）。等級已經不是 1（面板改過）＝只拿掉。
    /// W183 R12：低於 L2 的都升（L0 也算：unifiedLevels 記進來的）；已經是 L2＝只拿掉。
    /// 還不能升（舊版主機、有連線）＝nil（留著，下一次回報再看）。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 1）：跟面板調高同一道 raiseCheck——舊版主機一律不升（沒有連線也一樣）；會先封頂的主機要這一份
    /// 回報夠新、已經套用到現在這一版（report 帶主設備收到的時間）。
    static func raisingPending(_ config: HandsBuildConfig, device: String, report: HandsBuildDeviceReport, now: Date) -> HandsBuildConfig? {
        guard let pending = config.levelDefaultPending, pending.contains(where: { HandsHostAuthority.same($0, device) }),
              let index = config.index(device) else { return nil }
        var next = config
        if next.devices[index].level < defaultLevel {   // W183 R12：L0 也升（所有設備一律 L2）；檢查照舊
            guard raiseCheck(report, config: config, now: now) == .allowed else { return nil }   // W183 R11 第二輪：跟面板調高同一道檢查
            next.devices[index].level = defaultLevel
            if config.slice(for: device).contentKey != next.slice(for: device).contentKey { next.devices[index].deviceRevision += 1 }
        }
        let rest = pending.filter { !HandsHostAuthority.same($0, device) }
        next.levelDefaultPending = rest.isEmpty ? nil : rest
        next.configRevision = config.configRevision + 1
        return next
    }

    /// W183 R11 第二輪（GPT-6 R11b 審查 1，高：「面板調高也會放大舊版主機的既有 grant」）：那台能不能調高等級——預設升級（raisingPending）、
    /// 面板調高、舊畫面寫穿（HandsBuildConfigStore.update）都用這一道。還沒有回報＝不知道（先不調高）。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 1，高：「過舊的『零 grant』回報放行舊主機調高」）：
    /// - 舊版主機（回報沒有 level_guard）＝一律不調高（面板請它先更新）。它收到較高的等級不會先封頂；「沒有連線」的快照也不算——
    ///   取樣之後、收窄之前它可能就有了新的 grant，回報停了主設備也不知道。
    /// - 會先封頂的主機（level_guard）：這一份回報要夠新（主設備收到它到現在不超過 raiseReportWindow；時間倒退的也不算），而且那台已經
    ///   套用到現在這一版設定（applied_config_revision：上一次收窄已經在那台生效、封頂過了）才調高；不然＝先等它回報。
    ///   有沒有連線（grants＝0）不再單獨放行任何一台。
    static let raiseReportWindow: TimeInterval = 45
    static func raiseCheck(_ report: HandsBuildDeviceReport?, config: HandsBuildConfig, now: Date) -> HandsBuildRaise {
        guard let report else { return .unknown }
        guard report.levelGuard else { return .needsUpdate }
        guard let received = report.receivedAt, abs(now.timeIntervalSince(received)) <= raiseReportWindow,
              report.appliedConfigRevision >= config.configRevision else { return .unknown }
        return .allowed
    }

    func entry(_ id: String) -> HandsBuildDeviceEntry? { devices.first { HandsHostAuthority.same($0.deviceID, id) } }
    func index(_ id: String) -> Int? { devices.firstIndex { HandsHostAuthority.same($0.deviceID, id) } }

    /// 總開關開著、而且勾了這台。
    func isActive(_ id: String) -> Bool { enabled && (entry(id)?.selected ?? false) }

    func hostname(_ id: String) -> String? {
        guard let entry = entry(id), let domain else { return nil }
        return HandsGatewayLaunch.validHost(entry.subdomain + "." + domain)
    }

    var selectedIDs: [String] { devices.filter(\.selected).map(\.deviceID) }

    /// 給那台的那一份（不在設定裡＝沒勾、關著、版本 0）。
    /// W183 R8c 審查：不在設定裡的那一份是固定的（不帶帳號與網域）：版本 0 的內容永遠一樣，副設備的「同版異內容」檢查不會誤判。
    func slice(for id: String) -> HandsBuildDeviceSlice {
        let entry = self.entry(id)
        let name = entry?.name ?? ""
        return HandsBuildDeviceSlice(deviceID: id.lowercased(), name: name, active: isActive(id),
                                     subdomain: entry?.subdomain ?? HandsSettings.defaultSubdomainLabel,
                                     hostname: hostname(id), accountID: entry == nil ? nil : accountID, zoneID: entry == nil ? nil : zoneID,
                                     domain: entry == nil ? nil : domain,
                                     level: entry?.level ?? 1, projectIDs: (entry?.projectIDs ?? []).sorted(),
                                     deviceRevision: entry?.deviceRevision ?? 0, revocationGeneration: entry?.revocationGeneration ?? 0,
                                     connectorName: Self.connectorName(name))
    }

    /// ChatGPT 裡看到的連接器名稱「TATWO（<設備名稱>）」（使用者 09-28：每台一個連接器、分得出來；名稱是設備自己的名稱，不寫死）。
    static func connectorName(_ deviceName: String) -> String {
        let cleaned = String(deviceName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "（" && $0 != "）" })
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        return cleaned.isEmpty ? "TATWO" : "TATWO（\(cleaned)）"
    }

    /// 主設備預設 os-for-chatgpt；其他 os-for-chatgpt-<簡稱>（名字的英數；沒有就用 id 前 6 碼）；撞到已經用的名字就加 -2、-3…
    static func defaultSubdomain(name: String, deviceID: String, isPrimary: Bool, taken: Set<String>) -> String {
        let base = HandsSettings.defaultSubdomainLabel
        let candidate: String
        if isPrimary {
            candidate = base
        } else {
            let short = String(name.lowercased().unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }.map(Character.init).prefix(12))
            let tail = short.isEmpty ? String(deviceID.lowercased().filter { $0.isHexDigit }.prefix(6)) : short
            candidate = base + "-" + tail
        }
        var label = HandsSettings.validLabel(candidate) ?? base + "-" + String(deviceID.lowercased().filter { $0.isHexDigit }.prefix(6))
        var counter = 2
        while taken.contains(label) {
            label = HandsSettings.validLabel(candidate + "-\(counter)") ?? candidate + "\(counter)"
            counter += 1
        }
        return label
    }

    /// 正規化＋核對（寫進磁碟之前、讀出來之後都做）。不合格丟 HandsBuildConfigError。
    func validated() throws -> HandsBuildConfig {
        guard schema == Self.schemaName, UUID(uuidString: primaryID) != nil, authorityEpoch >= 0, configRevision >= 0,
              devices.count <= Self.maxDevices else { throw HandsBuildConfigError.invalid("config") }
        var copy = self
        copy.primaryID = primaryID.lowercased()
        if let account = accountID, !CloudflareAccountsStore.validID(account) { throw HandsBuildConfigError.invalid("account") }
        if let zone = zoneID, !CloudflareAccountsStore.validID(zone) { throw HandsBuildConfigError.invalid("zone") }
        if let domain {
            guard let host = HandsGatewayLaunch.validHost(domain) else { throw HandsBuildConfigError.invalid("domain") }
            copy.domain = host
        }
        guard (copy.zoneID == nil) == (copy.domain == nil), (copy.zoneID == nil) == (copy.accountID == nil) else {
            throw HandsBuildConfigError.invalid("zone")
        }
        var seen = Set<String>()
        var labels = Set<String>()
        for index in copy.devices.indices {
            var entry = copy.devices[index]
            guard UUID(uuidString: entry.deviceID) != nil else { throw HandsBuildConfigError.invalid("device") }
            entry.deviceID = entry.deviceID.lowercased()
            guard seen.insert(entry.deviceID).inserted else { throw HandsBuildConfigError.invalid("duplicate_device") }
            entry.name = String(entry.name.filter { !$0.isNewline }.prefix(60))
            guard let label = HandsSettings.validLabel(entry.subdomain) else { throw HandsBuildConfigError.invalid("subdomain") }
            entry.subdomain = label
            // 同一個主機名不能分給兩台（每台的網址＝子網域＋同一個網域）。
            guard labels.insert(label).inserted else { throw HandsBuildConfigError.hostnameTaken(label) }
            guard (0...HandsSettings.maxLevel).contains(entry.level) else { throw HandsBuildConfigError.invalid("level") }
            guard entry.projectIDs.count <= Self.maxProjects else { throw HandsBuildConfigError.invalid("projects") }
            let projects = entry.projectIDs.compactMap { UUID(uuidString: $0)?.uuidString }
            guard projects.count == entry.projectIDs.count else { throw HandsBuildConfigError.invalid("projects") }
            entry.projectIDs = Array(Set(projects)).sorted()
            guard entry.deviceRevision >= 0, entry.revocationGeneration >= 0 else { throw HandsBuildConfigError.invalid("revision") }
            copy.devices[index] = entry
        }
        // W183 R11：待升的只留設定裡有的設備（id 小寫、不重複）；空的＝nil。
        if let pending = copy.levelDefaultPending {
            var kept: [String] = []
            for id in pending.prefix(Self.maxDevices) where UUID(uuidString: id) != nil && seen.contains(id.lowercased()) && !kept.contains(id.lowercased()) {
                kept.append(id.lowercased())
            }
            copy.levelDefaultPending = kept.isEmpty ? nil : kept
        }
        return copy
    }

    /// 畫面與副設備看的（不是秘密；跟磁碟上一樣的欄位）。
    var wire: [String: Any] {
        (try? JSONSerialization.jsonObject(with: HandsBuildCanonical.encode(self)) as? [String: Any]) ?? [:]
    }

    init(primaryID: String, authorityEpoch: Int, configRevision: Int, enabled: Bool, accountID: String?, zoneID: String?, domain: String?,
         devices: [HandsBuildDeviceEntry], migratedFromLegacy: Bool?, levelDefault: Int? = nil, levelDefaultPending: [String]? = nil,
         levelUnified: Bool? = nil) {
        self.primaryID = primaryID
        self.authorityEpoch = authorityEpoch
        self.configRevision = configRevision
        self.enabled = enabled
        self.accountID = accountID
        self.zoneID = zoneID
        self.domain = domain
        self.devices = devices
        self.migratedFromLegacy = migratedFromLegacy
        self.levelDefault = levelDefault
        self.levelDefaultPending = levelDefaultPending
        self.levelUnified = levelUnified
    }

    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(HandsBuildConfig.self, from: data), let valid = try? decoded.validated() else { return nil }
        self = valid
    }
}

/// W183 R11 第二輪（GPT-6 R11b 審查 1）：調高等級的檢查結果（HandsBuildConfig.raiseCheck）。
enum HandsBuildRaise: Equatable, Sendable {
    case allowed
    /// 舊版主機（回報沒有 level_guard）：先更新那台（W183 R11 最後一輪：有沒有連線都一樣）。
    case needsUpdate
    /// 那台還沒回報、回報太舊、還沒套用到現在這一版（主設備剛重開、那台沒開、剛改過設定）：先不調高。
    case unknown
}

enum HandsBuildConfigError: Error, Equatable, CustomStringConvertible {
    /// 改設定時帶的預期版本跟主設備現在的不一樣（別台剛改過、或這是延遲送達的舊請求）。帶主設備現在的版本。
    case revisionConflict(Int)
    case hostnameTaken(String)
    /// 這個主機名已經有別台的建立證據（通道與 DNS 是那台建的）：不分給這台。
    case hostnameOwned(String)
    case unknownDevice
    case notAuthority
    case notSaved
    case invalid(String)
    /// W183 R8c 審查（GPT-6 中）：主設備的所有權表讀不到（壞了、權限）＝不知道誰有哪個網址：不分配網址（關掉照樣可以）。
    case ownershipUnknown
    /// W183 R11 第二輪（GPT-6 R11b 審查 1，高）：那台是舊版：不發布較高的等級（帶那台的名字）。W183 R11 最後一輪：有沒有連線都一樣。
    case raiseNeedsUpdate(String)
    /// W183 R11 第二輪：那台還沒回報（不知道會不會先封頂）：先不調高（帶那台的名字）。W183 R11 最後一輪：回報太舊、還沒套用到這一版也是。
    case raiseUnknown(String)

    var description: String {
        switch self {
        case .revisionConflict(let current): "hands_build_revision_conflict:\(current)"
        case .hostnameTaken(let label): "hands_build_hostname_taken:\(label)"
        case .hostnameOwned(let host): "hands_build_hostname_owned:\(host)"
        case .unknownDevice: "hands_build_unknown_device"
        case .notAuthority: "hands_build_not_authority"
        case .notSaved: "hands_build_not_saved"
        case .invalid(let what): "hands_build_invalid:\(what)"
        case .ownershipUnknown: "hands_build_ownership_unknown"
        case .raiseNeedsUpdate(let name): "hands_build_raise_needs_update:\(name)"
        case .raiseUnknown(let name): "hands_build_raise_unknown:\(name)"
        }
    }

    /// 白話（畫面）。
    var plain: String {
        switch self {
        case .revisionConflict: "設定剛被改過（可能是另一台）；看一下畫面再按一次"
        case .hostnameTaken(let label): "\(label) 已經給了另一台設備；每台要用不同的子網域"
        case .hostnameOwned(let host): "\(host) 是另一台設備建的網址；換一個子網域"
        case .unknownDevice: "主設備不認得這台設備（先在設定 › 設備配對）"
        case .notAuthority: "這台不是主設備；ChatGPT build 的設定在主設備"
        case .notSaved: "主設備的設定存不進去（磁碟滿？）"
        case .invalid: "設定的內容不對"
        case .ownershipUnknown: "主設備的網址所有權紀錄讀不到（檔案壞了？）：先不分配網址；關掉、取消勾選照樣可以"
        case .raiseNeedsUpdate(let name): "\(name)：先更新 TATWO OS 才能調高"   // W183 R11 最後一輪：舊版主機斷線再連也不行了（不寫那條路）
        case .raiseUnknown(let name): "\(name) 還沒回報最新狀態：等它連上、套用好再調高"
        }
    }

    static func from(_ error: Error) -> HandsBuildConfigError? {
        if let known = error as? HandsBuildConfigError { return known }
        let text = String(describing: error)
        if let range = text.range(of: "hands_build_revision_conflict:") {
            return .revisionConflict(Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0)
        }
        if let range = text.range(of: "hands_build_hostname_taken:") { return .hostnameTaken(String(text[range.upperBound...].prefix(63))) }
        if let range = text.range(of: "hands_build_hostname_owned:") { return .hostnameOwned(String(text[range.upperBound...].prefix(253))) }
        if text.contains("hands_build_unknown_device") { return .unknownDevice }
        if text.contains("hands_build_not_authority") { return .notAuthority }
        if text.contains("hands_build_not_saved") { return .notSaved }
        if text.contains("hands_build_invalid") { return .invalid("remote") }
        if text.contains("hands_build_ownership_unknown") { return .ownershipUnknown }
        if let range = text.range(of: "hands_build_raise_needs_update:") { return .raiseNeedsUpdate(String(text[range.upperBound...].prefix(60))) }
        if let range = text.range(of: "hands_build_raise_unknown:") { return .raiseUnknown(String(text[range.upperBound...].prefix(60))) }
        return nil
    }
}

/// 畫面按的改動（主設備在同一把鎖裡照預期版本一次套完；副設備經設備簽章 RPC 送 wire）。AI 工具一律走不到這裡。
enum HandsBuildConfigOp: Equatable, Sendable {
    case setEnabled(Bool)
    case select(device: String, selected: Bool)
    case subdomain(device: String, label: String)
    case zone(accountID: String, zoneID: String, domain: String)
    case level(device: String, level: Int)
    case project(device: String, projectID: String, selected: Bool)

    var wire: [String: Any] {
        switch self {
        case .setEnabled(let on): ["type": "enabled", "value": on]
        case .select(let device, let selected): ["type": "select", "device": device, "value": selected]
        case .subdomain(let device, let label): ["type": "subdomain", "device": device, "label": label]
        case .zone(let account, let zone, let domain): ["type": "zone", "account": account, "zone": zone, "domain": domain]
        case .level(let device, let level): ["type": "level", "device": device, "value": level]
        case .project(let device, let project, let selected): ["type": "project", "device": device, "project": project, "value": selected]
        }
    }

    init?(wire raw: Any) {
        guard let object = raw as? [String: Any], let type = object["type"] as? String else { return nil }
        let device = (object["device"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
        func bool(_ key: String) -> Bool? {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        switch type {
        case "enabled":
            guard let value = bool("value"), object.count == 2 else { return nil }
            self = .setEnabled(value)
        case "select":
            guard let device, let value = bool("value"), object.count == 3 else { return nil }
            self = .select(device: device, selected: value)
        case "subdomain":
            guard let device, let label = object["label"] as? String, label.utf8.count <= 63, object.count == 3 else { return nil }
            self = .subdomain(device: device, label: label)
        case "zone":
            guard let account = object["account"] as? String, let zone = object["zone"] as? String, let domain = object["domain"] as? String,
                  CloudflareAccountsStore.validID(account), CloudflareAccountsStore.validID(zone), HandsGatewayLaunch.validHost(domain) != nil,
                  object.count == 4 else { return nil }
            self = .zone(accountID: account, zoneID: zone, domain: domain)
        case "level":
            guard let device, let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Double(number.intValue) == number.doubleValue, object.count == 3 else { return nil }
            self = .level(device: device, level: number.intValue)
        case "project":
            guard let device, let project = (object["project"] as? String).flatMap({ UUID(uuidString: $0)?.uuidString }),
                  let value = bool("value"), object.count == 4 else { return nil }
            self = .project(device: device, projectID: project, selected: value)
        default:
            return nil
        }
    }
}

/// 設備 → 主機名／通道的所有權（不是秘密）：每台回報自己**有建立證據**的資源（通道 id、主機名、網域）；主設備記著。
/// 「沒有連線不等於沒有主人」：別台的清理只看這張表＋自己的建立證據，離線那台的通道照樣是它的。
struct HandsBuildOwnership: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var hostname: String
        var deviceID: String
        var tunnelID: String?
        var zoneID: String?
        /// 從哪來：created（那台建的）／legacy_host（舊的單主機設定遷過來）。
        var evidence: String
        var recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case hostname, deviceID = "device_id", tunnelID = "tunnel_id", zoneID = "zone_id", evidence, recordedAt = "recorded_at"
        }
    }
    var records: [Record] = []
    /// W183 R8c 審查（GPT-6 中）：讀不到所有權表（不是「沒有檔案」）＝不知道（不是可信的空表）：不分配、不清任何東西。不存檔、不上線路。
    var unknown = false
    /// 上限：滿了＝新的不收（回衝突），**不**把還有效的舊紀錄擠掉。
    static let maxRecords = 128

    enum CodingKeys: String, CodingKey { case records }

    func owner(of hostname: String) -> String? {
        records.first { $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame }?.deviceID
    }

    /// 別台（不是 deviceID）擁有的通道 id。
    func foreignTunnels(excluding deviceID: String) -> Set<String> {
        Set(records.filter { !HandsHostAuthority.same($0.deviceID, deviceID) }.compactMap { $0.tunnelID?.lowercased() })
    }

    /// 那台回報它現在持有的資源（加進它的名下；已經是別台的主機名＝不收，衝突回傳）＋它**確定已經釋放**的主機名（刪掉了、查過確定不在）。
    /// W183 R8c 審查（GPT-6 中「回報替換會無證據地遺忘舊資源」）：那台這一次沒回報的**不**拿掉——只憑 released（釋放證據）拿掉那一筆；
    /// 表滿了＝新的不收，不擠掉還有效的舊紀錄。W183 R8c 審查（Claude 中）：內容一樣的紀錄不動（連時間也不改），沒變就不用重寫檔案。
    mutating func replace(device: String, with reported: [Record], released: [String] = [], now: Date) -> [String] {
        let id = device.lowercased()
        var conflicts: [String] = []
        let reportedHosts = Set(reported.compactMap { HandsGatewayLaunch.validHost($0.hostname)?.lowercased() })
        let releasedHosts = Set(released.prefix(16).compactMap { HandsGatewayLaunch.validHost($0)?.lowercased() }).subtracting(reportedHosts)
        records.removeAll { HandsHostAuthority.same($0.deviceID, id) && releasedHosts.contains($0.hostname.lowercased()) }
        for var record in reported.prefix(8) {
            guard let host = HandsGatewayLaunch.validHost(record.hostname) else { continue }
            if let owner = owner(of: host), !HandsHostAuthority.same(owner, id) { conflicts.append(host); continue }
            record.hostname = host
            record.deviceID = id
            record.tunnelID = record.tunnelID.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
            record.zoneID = record.zoneID.flatMap { CloudflareAccountsStore.validID($0) ? $0 : nil }
            record.evidence = "created"
            if let index = records.firstIndex(where: { $0.hostname.caseInsensitiveCompare(host) == .orderedSame }) {
                let existing = records[index]
                if existing.sameResource(as: record) { continue }   // 一樣＝不動
                // 同一台、同一個主機名、內容換了（例如通道換過；遷移紀錄變成建立證據）：原地更新。
                record.recordedAt = now
                records[index] = record
                continue
            }
            guard records.count < Self.maxRecords else { conflicts.append(host); continue }
            record.recordedAt = now
            records.append(record)
        }
        return conflicts
    }

    var wire: [[String: Any]] {
        records.map { record in
            var out: [String: Any] = ["hostname": record.hostname, "device_id": record.deviceID, "evidence": record.evidence]
            if let tunnel = record.tunnelID { out["tunnel_id"] = tunnel }
            if let zone = record.zoneID { out["zone_id"] = zone }
            return out
        }
    }

    init() {}

    init(unknown: Bool) { self.unknown = unknown }

    init(wire raw: Any?) {
        records = (raw as? [[String: Any]] ?? []).prefix(Self.maxRecords).compactMap { object in
            guard let host = HandsGatewayLaunch.validHost(object["hostname"] as? String),
                  let device = (object["device_id"] as? String).flatMap({ UUID(uuidString: $0) != nil ? $0.lowercased() : nil }) else { return nil }
            return Record(hostname: host, deviceID: device,
                          tunnelID: (object["tunnel_id"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil },
                          zoneID: (object["zone_id"] as? String).flatMap { CloudflareAccountsStore.validID($0) ? $0 : nil },
                          evidence: (object["evidence"] as? String) == "legacy_host" ? "legacy_host" : "created", recordedAt: Date())
        }
    }
}

extension HandsBuildOwnership.Record {
    /// 同一筆資源（不看紀錄時間）：主機名、設備、通道、網域、證據都一樣。
    func sameResource(as other: HandsBuildOwnership.Record) -> Bool {
        hostname.caseInsensitiveCompare(other.hostname) == .orderedSame && HandsHostAuthority.same(deviceID, other.deviceID)
            && tunnelID?.lowercased() == other.tunnelID?.lowercased() && zoneID == other.zoneID && evidence == other.evidence
    }
}

/// 這台在 ChatGPT build 裡是什麼身分（device.json）。
enum HandsBuildRole: Equatable, Sendable {
    /// 設定的正本在這台（主設備；或還沒配對任何設備的單機＝epoch 0）。
    case authority(local: String, epoch: Int)
    /// 副設備：設定在主設備，這台只信已配對的那一台主設備簽的信封。
    case member(local: String, primary: String, epoch: Int)
    /// 沒有設備身分（或看不懂）：一律不跑。
    case unknown

    static func from(_ identity: DeviceIdentity?) -> HandsBuildRole {
        guard let identity else { return .unknown }
        let local = identity.deviceID.lowercased()
        if identity.role == .primary, let epoch = identity.epoch { return .authority(local: local, epoch: epoch) }
        if identity.role == .secondary, let primary = identity.primaryDeviceID, let epoch = identity.epoch {
            return .member(local: local, primary: primary.lowercased(), epoch: epoch)
        }
        if identity.epoch == nil, identity.primaryDeviceID == nil { return .authority(local: local, epoch: 0) }   // 還沒配對：這台就是正本
        return .unknown
    }

    static func current(entry: TatwoEntry = TatwoEntry()) -> HandsBuildRole {
        from(try? DeviceIdentityStore.readLocal(entry: entry))
    }

    var localID: String? {
        switch self {
        case .authority(let local, _), .member(let local, _, _): local
        case .unknown: nil
        }
    }

    var isAuthority: Bool { if case .authority = self { return true }; return false }
}

/// 主設備這端：設定正本（app/build-config.json）與所有權（app/build-ownership.json），都 0600、原子寫入、沒有秘密。
final class HandsBuildConfigStore: @unchecked Sendable {
    struct Dependencies {
        var role: () -> HandsBuildRole
        /// 已配對的設備（含這台）：名稱與主／副以這台自己的登記為準，不信請求帶的。
        var devices: () -> [HandsSetupDevice]
        /// 舊的單主機設定（遷移用；只在還沒有 build-config.json 時讀一次）。
        var legacy: () -> (settings: HandsSettings, setup: HandsSetupState)?
        var now: () -> Date = Date.init
    }

    static let shared = HandsBuildConfigStore(paths: .default, dependencies: .init(
        role: { HandsBuildRole.current() },
        devices: { HandsSetup.pairedDevices() },
        legacy: {
            let settings = HandsService.shared.settings.load()
            guard let data = HandsFiles.readSecure(HandsPaths.default.appDir.appendingPathComponent("setup.json"), limit: 256 * 1024) else {
                return (settings, HandsSetupState())
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (settings, (try? decoder.decode(HandsSetupState.self, from: data)) ?? HandsSetupState())
        }))

    let url: URL
    let ownershipURL: URL
    let dependencies: Dependencies
    private let lock = NSRecursiveLock()
    private var cached: HandsBuildConfig?
    #if DEBUG
    /// 自測：模擬存不進去。
    var failSavesForTesting = false

    /// 自測（W183 R11 第二輪）：丟掉記憶體裡的那一份（模擬重開 App：下一次 load 從檔案讀、照遷移規則走）。
    func reloadForTesting() {
        lock.lock(); cached = nil; lock.unlock()
    }
    #endif

    init(paths: HandsPaths, dependencies: Dependencies) {
        url = paths.appDir.appendingPathComponent("build-config.json")
        ownershipURL = paths.appDir.appendingPathComponent("build-ownership.json")
        self.dependencies = dependencies
    }

    /// 這台是正本：現在的設定（第一次讀、還沒有檔案＝照舊設定遷移並存起來）。不是正本＝nil。
    func load() -> HandsBuildConfig? {
        lock.lock(); defer { lock.unlock() }
        guard case .authority(let local, let epoch) = dependencies.role() else { return nil }
        if let cached, HandsHostAuthority.same(cached.primaryID, local), cached.authorityEpoch == epoch { return cached }
        if let data = HandsFiles.readSecure(url, limit: 512 * 1024),
           let decoded = try? JSONDecoder().decode(HandsBuildConfig.self, from: data), var valid = try? decoded.validated(),
           HandsHostAuthority.same(valid.primaryID, local) {
            if valid.authorityEpoch != epoch { valid.authorityEpoch = epoch }   // 主權換過（同一台又當回正本）：沿用設定、改新的主權
            // W183 R11：R11 之前的那一份照一次新的預設（舊預設 L1 的那幾台記成待升；那台回報說會先封頂或沒有連線才升：applyPendingDefault）；
            // 存不進去＝不照（下次再試），不讓記憶體跟磁碟不一樣。
            if let upgraded = HandsBuildConfig.upgradedDefaults(valid), (try? save(upgraded)) != nil { valid = upgraded }
            // W183 R12：所有設備一律 L2——照一次（低於 L2 的記成待升；升不升照 R11 同一道）；存不進去＝不照（下次再試）。
            if let unified = HandsBuildConfig.unifiedLevels(valid), (try? save(unified)) != nil { valid = unified }
            cached = valid
            return valid
        }
        // 檔案壞了（不是沒有）＝不自己重建：當成全部關著（fail closed），等使用者在畫面重新設定。
        if FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return HandsBuildConfig.empty(primaryID: local, epoch: epoch)
        }
        let migrated = Self.migrated(local: local, epoch: epoch, legacy: dependencies.legacy(), devices: dependencies.devices())
        if (try? save(migrated.config)) != nil {
            if !migrated.ownership.records.isEmpty { try? saveOwnership(migrated.ownership) }
            cached = migrated.config
        }
        return migrated.config
    }

    /// 所有權表。W183 R8c 審查（GPT-6 中）：沒有檔案＝可信的空表；檔案在、卻讀不到或看不懂（壞了、權限）＝unknown（不是空表）。
    func ownership() -> HandsBuildOwnership {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        if lstat(ownershipURL.path, &info) != 0 { return errno == ENOENT ? HandsBuildOwnership() : HandsBuildOwnership(unknown: true) }
        guard let data = HandsFiles.readSecure(ownershipURL, limit: 256 * 1024) else { return HandsBuildOwnership(unknown: true) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HandsBuildOwnership.self, from: data)) ?? HandsBuildOwnership(unknown: true)
    }

    /// 最近一次存所有權表失敗的原因（畫面看；nil＝沒事）。
    private(set) var ownershipProblem: String?

    /// 那台回報的資源（它自己有建立證據的）＋它確定釋放的主機名。回傳衝突的主機名（別台的、或表滿了）。
    /// 所有權表讀不到（unknown）＝什麼都不改（不覆蓋、不清）。只有真的變了才存。
    @discardableResult
    func recordResources(device: String, _ reported: [HandsBuildOwnership.Record], released: [String] = []) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var table = ownership()
        guard !table.unknown else { ownershipProblem = HandsBuildConfigError.ownershipUnknown.plain; return [] }
        let before = table
        let conflicts = table.replace(device: device, with: reported, released: released, now: dependencies.now())
        if table != before {
            do { try saveOwnership(table); ownershipProblem = nil } catch { ownershipProblem = "主設備的網址所有權紀錄存不進去（磁碟滿？）" }
        }
        return conflicts
    }

    /// 照預期版本一次套完（CAS）；版本對不上＝不改（revisionConflict）。只有真的變了才 +1、才存。
    /// W183 R8c 審查（GPT-6 中「CAS 是選填」）：預期版本**一定要帶**（沒有「nil＝跳過比對」）；還沒拿到設定的畫面不能改。
    /// W183 R11 第二輪（GPT-6 R11b 審查 1，高）：raise＝那台能不能調高（主設備照那台最後的回報：HandsBuildConfig.raiseCheck）。
    /// W183 R11 最後一輪：raise 拿到改之前的這一份（那台要已經套用到這一版）。
    @discardableResult
    func update(expectedRevision: Int, ops: [HandsBuildConfigOp], raise: (String, HandsBuildConfig) -> HandsBuildRaise) throws -> HandsBuildConfig {
        lock.lock(); defer { lock.unlock() }
        guard let current = load() else { throw HandsBuildConfigError.notAuthority }
        guard expectedRevision == current.configRevision else { throw HandsBuildConfigError.revisionConflict(current.configRevision) }
        guard ops.count <= 32 else { throw HandsBuildConfigError.invalid("too_many_changes") }
        let known = dependencies.devices()
        var config = current
        for op in ops { try Self.apply(op, to: &config, known: known) }
        config = try config.validated()
        // W183 R11 第二輪（GPT-6 R11b 審查 1，高）：調高已經在設定裡的那台（面板、舊畫面寫穿）跟預設升級同一道檢查——舊版主機有連線、
        // 或還沒回報＝不發布較高的等級（面板調高不是對既有連線的重新同意）；整次改動都不收，畫面照這一句說。
        for entry in config.devices {
            guard let old = current.entry(entry.deviceID), entry.level > old.level else { continue }
            let name = entry.name.isEmpty ? "那台" : entry.name
            switch raise(entry.deviceID, current) {
            case .allowed: continue
            case .needsUpdate: throw HandsBuildConfigError.raiseNeedsUpdate(name)
            case .unknown: throw HandsBuildConfigError.raiseUnknown(name)
            }
        }
        // 主機名的所有權：別台有建立證據的不分給這台。所有權表讀不到＝不知道：不分配新的網址（關掉、取消勾選照樣可以）。
        let table = ownership()
        if let domain = config.domain {
            for entry in config.devices where entry.selected {
                let host = entry.subdomain + "." + domain
                if table.unknown, config.isActive(entry.deviceID),
                   !current.isActive(entry.deviceID) || config.hostname(entry.deviceID) != current.hostname(entry.deviceID) {
                    throw HandsBuildConfigError.ownershipUnknown
                }
                if let owner = table.owner(of: host), !HandsHostAuthority.same(owner, entry.deviceID) { throw HandsBuildConfigError.hostnameOwned(host) }
            }
        }
        // 每台的版本：內容變了 deviceRevision +1；原本在跑、這次被關掉＝revocationGeneration +1（那台撤銷全部連線）。
        for index in config.devices.indices {
            let id = config.devices[index].deviceID
            let old = current.entry(id)
            if current.slice(for: id).contentKey != config.slice(for: id).contentKey {
                config.devices[index].deviceRevision = (old?.deviceRevision ?? 0) + 1
            }
            if current.isActive(id), !config.isActive(id) {
                config.devices[index].revocationGeneration = (old?.revocationGeneration ?? 0) + 1
            }
        }
        guard config != current else { return current }
        config.configRevision = current.configRevision + 1
        try save(config)
        cached = config
        return config
    }

    /// W183 R11（GPT-6 R11 審查 1，高）：那台來回報了（HandsBuildAuthority.record）：待升到預設 L2 的那台，回報說它會先封頂現有連線或沒有連線
    /// ＝升（存得進去才算；存不進去＝下一次回報再試）。回升了之後的設定（沒動＝nil）。
    @discardableResult
    func applyPendingDefault(device: String, report: HandsBuildDeviceReport) -> HandsBuildConfig? {
        lock.lock(); defer { lock.unlock() }
        guard let current = load(), let next = HandsBuildConfig.raisingPending(current, device: device, report: report, now: dependencies.now()),
              let valid = try? next.validated(), (try? save(valid)) != nil else { return nil }
        cached = valid
        return valid
    }

    static func apply(_ op: HandsBuildConfigOp, to config: inout HandsBuildConfig, known: [HandsSetupDevice]) throws {
        func ensure(_ device: String) throws -> Int {
            if let index = config.index(device) {
                if let info = known.first(where: { HandsHostAuthority.same($0.id, device) }) {
                    config.devices[index].name = String(info.name.prefix(60))
                    config.devices[index].isPrimary = info.isPrimary
                }
                return index
            }
            guard let info = known.first(where: { HandsHostAuthority.same($0.id, device) }), config.devices.count < HandsBuildConfig.maxDevices else {
                throw HandsBuildConfigError.unknownDevice
            }
            let taken = Set(config.devices.map(\.subdomain))
            config.devices.append(HandsBuildDeviceEntry(
                deviceID: info.id.lowercased(), name: String(info.name.prefix(60)), isPrimary: info.isPrimary, selected: false,
                subdomain: HandsBuildConfig.defaultSubdomain(name: info.name, deviceID: info.id, isPrimary: info.isPrimary, taken: taken),
                level: HandsBuildConfig.defaultLevel, projectIDs: [], deviceRevision: 0, revocationGeneration: 0))   // W183 R11：預設 L2
            return config.devices.count - 1
        }
        switch op {
        case .setEnabled(let on):
            config.enabled = on
            // 使用者 09-28：「沒有副設備的人一率主設備」：打開時一台都沒勾＝勾主設備（正本這台）。
            if on, config.devices.allSatisfy({ !$0.selected }) {
                let primary = known.first(where: \.isPrimary)?.id ?? config.primaryID
                let index = try ensure(primary)
                config.devices[index].selected = true
            }
        case .select(let device, let selected):
            let index = try ensure(device)
            config.devices[index].selected = selected
        case .subdomain(let device, let label):
            guard let valid = HandsSettings.validLabel(label) else { throw HandsBuildConfigError.invalid("subdomain") }
            let index = try ensure(device)
            config.devices[index].subdomain = valid
        case .zone(let account, let zone, let domain):
            config.accountID = account
            config.zoneID = zone
            config.domain = HandsGatewayLaunch.validHost(domain)
        case .level(let device, let level):
            guard (0...HandsSettings.maxLevel).contains(level) else { throw HandsBuildConfigError.invalid("level") }
            let index = try ensure(device)
            config.devices[index].level = level
            // W183 R11：面板上改了那台的等級＝使用者自己決定了（不再等預設升級）。
            if let pending = config.levelDefaultPending {
                let rest = pending.filter { !HandsHostAuthority.same($0, device) }
                config.levelDefaultPending = rest.isEmpty ? nil : rest
            }
        case .project(let device, let project, let selected):
            let index = try ensure(device)
            var set = Set(config.devices[index].projectIDs)
            if selected { set.insert(project) } else { set.remove(project) }
            config.devices[index].projectIDs = Array(set).sorted()
        }
    }

    private func save(_ config: HandsBuildConfig) throws {
        #if DEBUG
        if failSavesForTesting { throw HandsBuildConfigError.notSaved }
        #endif
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try HandsFiles.writeAtomically(try encoder.encode(config), to: url) } catch { throw HandsBuildConfigError.notSaved }
    }

    private func saveOwnership(_ table: HandsBuildOwnership) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try HandsFiles.writeAtomically(try encoder.encode(table), to: ownershipURL)
    }

    /// 舊的單主機 → 一份設定（必改 8）。主機是這台：帶上等級、專案、網域（第 3 步確認過的）與它的網址所有權；主機是別台：只勾那台、
    /// 所有權記它的網址（那台的專案與網域它自己回報）。不碰任何 OAuth 狀態。
    static func migrated(local: String, epoch: Int, legacy: (settings: HandsSettings, setup: HandsSetupState)?,
                         devices: [HandsSetupDevice]) -> (config: HandsBuildConfig, ownership: HandsBuildOwnership) {
        var config = HandsBuildConfig.empty(primaryID: local, epoch: epoch)
        var ownership = HandsBuildOwnership()
        guard let legacy else { return (config, ownership) }
        let settings = legacy.settings, setup = legacy.setup
        let host = (settings.hostDeviceID ?? (settings.enabled ? local : nil))?.lowercased()
        guard let host else { return (config, ownership) }
        let info = devices.first { HandsHostAuthority.same($0.id, host) }
        let hostIsLocal = HandsHostAuthority.same(host, local)
        guard hostIsLocal || info != nil else { return (config, ownership) }   // 舊主機已經不在配對清單＝不遷（使用者重新選）
        let isPrimary = info?.isPrimary ?? hostIsLocal
        config.devices = [HandsBuildDeviceEntry(
            deviceID: host, name: String((info?.name ?? "").prefix(60)), isPrimary: isPrimary, selected: true,
            subdomain: settings.effectiveSubdomainLabel, level: settings.level,
            projectIDs: hostIsLocal ? settings.allowedProjectIDs : [], deviceRevision: 1, revocationGeneration: 0)]
        // W183 R11：舊預設 L1＝待升到 L2（GPT-6 R11 審查 1：等那台的回報說它會先封頂現有連線、或沒有連線才升；raisingPending）。
        // W183 R12：所有設備一律 L2——L0 也記成待升（升不升照同一道 raiseCheck）。
        if settings.level < HandsBuildConfig.defaultLevel { config.levelDefaultPending = [host] }
        config.enabled = settings.enabled
        if hostIsLocal, let account = setup.accountID, let zone = setup.zoneID, let domain = setup.domain.flatMap(HandsGatewayLaunch.validHost),
           setup.step(.authorize).status == .done, !setup.isUnconfirmed(zone), setup.discard == nil {
            config.accountID = account; config.zoneID = zone; config.domain = domain
        }
        config.configRevision = 1
        config.migratedFromLegacy = true
        if let validated = try? config.validated() { config = validated } else { config = .empty(primaryID: local, epoch: epoch) }
        let publicHost = HandsGatewayLaunch.validHost(hostIsLocal ? (setup.publicHost ?? settings.publicHost) : settings.publicHost)
        if let publicHost {
            ownership.records = [HandsBuildOwnership.Record(hostname: publicHost, deviceID: host, tunnelID: hostIsLocal ? setup.tunnelID : nil,
                                                            zoneID: hostIsLocal ? setup.zoneID : nil, evidence: "legacy_host", recordedAt: Date())]
        }
        return (config, ownership)
    }
}
