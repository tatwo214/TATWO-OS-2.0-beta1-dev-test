import Foundation

/// W171（使用者 2026-09-22）：不再用一串問題擋住第一次打開。
/// 「先讓使用者進入 app 再從設定分頁裡面引導…不要讓使用者在還沒進入狀況的時候做決定」。
/// 第一次打開只做安全的預設：建入口、寫這台的名字與身分（第一台），不碰任何引擎的規則檔、不開 GitHub 備份。
/// 這些預設會在 設定 › 開始使用 與 設定 › 設備 標成「預設」，使用者確認或改掉。
enum FirstRunDefaults {
    private static let key = "tatwo2.setup.firstRunDefaults"

    struct Record: Codable, Equatable {
        var appliedAt: Date?
        /// 使用者在設備頁按過「這樣就好」或改過名字／改成加入既有那台。
        var confirmed = false
        /// 預設沒套上時的原因（例如入口已有別的檔）；App 照樣打開，開始使用頁會顯示。
        var failure: String?
    }

    static var record: Record? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func save(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 這台的名字與身分還是自動給的、使用者還沒看過。
    static var awaitsDeviceConfirmation: Bool { record.map { $0.appliedAt != nil && !$0.confirmed } ?? false }

    /// 第一次打開時呼叫：入口還沒有這台的身分才做。不選任何引擎，所以不會改到別人的規則檔。
    @discardableResult
    static func applyIfNeeded(entry: TatwoEntry = TatwoEntry(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard OSOnboarding.needsOnboarding(entry: entry) else { return false }
        var draft = OSOnboarding.defaultDraft(environment: environment)
        draft.engines = []
        do {
            try OSOnboarding.install(try OSOnboarding.preview(draft: draft, entry: entry))
            save(Record(appliedAt: Date(), confirmed: false, failure: nil))
            return true
        } catch {
            save(Record(appliedAt: nil, confirmed: false, failure: error.localizedDescription))
            return false
        }
    }

    static func confirm() {
        var current = record ?? Record()
        current.confirmed = true
        save(current)
    }

    /// 改這台的名字。只動 device.json 的 name 與 updatedAt，其他欄位（邊界、偏好）原樣保留。
    static func rename(_ raw: String, entry: TatwoEntry = TatwoEntry()) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw OSUpstreamBinding.failure("名字不能是空的") }
        let data = try Data(contentsOf: entry.deviceJSON)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OSUpstreamBinding.failure("這台的身分檔讀不懂，先不改")
        }
        object["name"] = String(name.prefix(80))
        object["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let next = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try DeviceIdentity.decode(next)
        try next.write(to: entry.deviceJSON, options: .atomic)
        confirm()
    }

    /// 「我已經有一台」：把第一次打開時自動寫的正本與身分封存起來，改成等著跟那台配對的身分。
    /// 只在身分還是自動預設、而且這台還沒跟任何設備配對時可以做；否則要走正式的主權移交。
    static func switchToExistingPrimary(entry: TatwoEntry = TatwoEntry(),
                                        environment: [String: String] = ProcessInfo.processInfo.environment,
                                        now: Date = Date()) throws {
        guard awaitsDeviceConfirmation else { throw OSUpstreamBinding.failure("這台的身分已經確認過；要改請用設備頁的主權移交") }
        guard DeviceStatusReader.registry(environment: environment).isEmpty else {
            throw OSUpstreamBinding.failure("這台已經跟其他設備配對過；要改請用設備頁的主權移交")
        }
        let identity = try DeviceIdentityStore.readLocal(entry: entry)
        let name = identity?.name
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: now)
        }()
        let archive = entry.root.appendingPathComponent("archive/first-run-default-\(stamp)")
        var moved: [String] = []
        for file in ["device.json", "os.md", "skillet.md", "os-upstream.md", "agents.md", "user.md"] {
            let source = entry.root.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: archive.appendingPathComponent(file))
            moved.append(file)
        }
        if !moved.isEmpty {
            let manifest = "# 第一次打開時自動建立的檔案\n\n使用者選「我已經有一台」，改成等著跟那台配對。以下檔案原樣搬到這裡：\n\n"
                + moved.map { "- \($0)（還原：搬回入口根目錄）" }.joined(separator: "\n") + "\n"
            try Data(manifest.utf8).write(to: archive.appendingPathComponent("MANIFEST.md"))
        }
        var draft = OSOnboarding.defaultDraft(environment: environment)
        draft.engines = []
        draft.role = .secondary
        if let name { draft.name = name }
        try OSOnboarding.install(try OSOnboarding.preview(draft: draft, entry: entry))
        confirm()
    }
}
