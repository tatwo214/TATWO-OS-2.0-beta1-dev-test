import Foundation

// W183 R7a：［連線］卡上直接選權限與專案（副設備也能選）。
// 09-28 實測：MacBook（副設備）走到私訊框的［連線］卡，卡上寫「L1…」「專案：沒有」，但副設備沒有任何地方能改等級與專案
// （遠端的「詳細」沒有、AI 工具也刻意不能改）；mini 沒接螢幕。使用者裁決：這次要「L2 沙盒動手」＋只開一個專案，
// 而且連線當下範圍就固定（範圍快照），所以要在按［連線］之前、就在卡片上選。
//
// - 主機把「可以選的專案」（id、名稱、資料夾最後一段；不帶完整路徑）放進 connect_offer 與 remote_hands_status；
//   資料夾不見的、不能當專案的（入口本身、入口的 chatgpt/、家目錄、秘密資料夾、網路磁碟…：HandsRuntime.folderProblem）不列。
// - 卡上選等級（L0／L1／L2；L3 不存在）與專案（預設沿用主機目前的設定）。按［連線］＝這個 attempt 的範圍快照：
//   本機直接叫 HandsConnectHost.begin；副設備 begin_connect 多帶 level、project_ids（設備簽章涵蓋）。
// - 主機驗：等級 0…2、每個專案 id 都在上面那份清單裡（不在的、入口、chatgpt/ 一律拒，connect_scope_invalid）；
//   驗過、而且沒有別的 attempt 在跑，才把主機設定的等級上限與允許專案改成卡上選的（寫進設定、「詳細」看得到），
//   再照新設定拍範圍快照、核對擁有者看到的 digest，才開窗口。
// - 這條路只有原生卡片的按鈕（本機）與設備簽章的 begin_connect（副設備）：AI 的工具介面——os-mcp 的工具、助理（hands_setup_step）、
//   外部 AI（關口的三個方法）——都沒有改等級與專案的方法。
//   殘餘（W183 R7a 審查，GPT-6；不宣稱「AI 一律改不了」）：同一個 macOS 使用者身分、能跑任意指令的程式（例如「完整存取權」下的 AI 背景指令、
//   引擎自己的 shell）本來就能直接改 app/settings.json，或用這台的配對 SSH 金鑰簽 begin_connect——那把金鑰本身就能 SSH 登入主設備。
//   這不是 App 裡的權限檢查擋得住的（要獨立 UID 的服務或硬體綁定的使用者確認），寫在 threat-model T17，首版不做。
// - 已連線的 grant 照舊用自己的快照（grant 記的等級、專案不變；有效範圍＝grant ∩ 設定）：選得比較大不會讓它們變大。
// W183 R7a 審查（Claude、GPT-6）：
// - 主機目前允許、但這一刻用不了的專案（資料夾暫時不見、磁碟讀不到）照樣列出（帶 problem、卡上灰的、預設勾著）：不會因為外接碟沒掛上、
//   使用者什麼都沒動就按［連線］而被拿掉（拿掉會收工作、鎖工作區）。主機只拒絕真的不能當專案的（入口、chatgpt/、受保護的資料夾），
//   以及「現在沒允許、又用不了」的。
// - 清單不截斷：可列舉的上限（listLimit）跟最多選幾個（selectionLimit）分開；超過上限、有看不懂的列＝主機不給／副設備不收卡上選
//   （卡片照舊只顯示，按［連線］照主機目前的設定），不拿不完整的清單重建授權。
// W183 R10（使用者 09-29「就要給他用了還要多一個勾選」）：卡上選範圍整個拿掉——範圍＝中央設定的等級＋這台全部專案（全部可見）。
//   主機的 offer 不再給 project_choices（supportsChoice＝false）、begin 帶了範圍一律拒絕（HandsConnectHost）。這裡留下的是資料結構與
//   舊版主機的相容（舊主機給了清單，新擁有者照樣只顯示、送回主機自己給的那一份），以及「這台所有能當專案的」清單（面板、有效範圍）。

/// 主機上可以選的一個專案（給卡片；不帶完整路徑）。
struct HandsProjectChoice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// 資料夾最後一段（讓同名的專案分得出來）。
    let folder: String
    /// W183 R7a 審查（Claude）：主機目前允許、但這一刻用不了（folder_missing、storage_unreadable）。nil＝可以選。
    var problem: String? = nil

    /// 只有這兩種「暫時」的問題會列出來（其他的是政策上不能當專案，不列）。
    static let temporaryProblems: Set<String> = ["folder_missing", "storage_unreadable"]
    /// 可列舉的上限（跟 HandsScopeChoice.selectionLimit 分開）。超過＝不給卡上選，不截斷。
    static let listLimit = 1000

    init(id: String, name: String, folder: String, problem: String? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.problem = problem
    }

    var wire: [String: Any] {
        var out: [String: Any] = ["id": id, "name": name, "folder": folder]
        if let problem { out["problem"] = problem }
        return out
    }

    /// 副設備收到的（id 只收 UUID；名稱與資料夾只收一行、有長度上限；problem 只收那兩種；多的欄位不收）。
    init?(wire raw: [String: Any]) {
        guard Set(raw.keys).isSubset(of: ["id", "name", "folder", "problem"]),
              let id = (raw["id"] as? String).flatMap({ UUID(uuidString: $0)?.uuidString }) else { return nil }
        let problem = raw["problem"] as? String
        guard raw["problem"] == nil || problem.map({ Self.temporaryProblems.contains($0) }) == true else { return nil }
        self.init(id: id, name: String((raw["name"] as? String ?? "").filter { !$0.isNewline }.prefix(80)),
                  folder: String((raw["folder"] as? String ?? "").filter { !$0.isNewline && $0 != "/" }.prefix(80)), problem: problem)
    }

    /// 副設備收到的整份清單。不完整（不是陣列、超過上限、有看不懂的列、id 重複）＝nil：卡片不讓選（照舊只顯示）。
    static func list(_ raw: Any?) -> [HandsProjectChoice]? {
        guard let rows = raw as? [Any], rows.count <= listLimit else { return nil }
        let decoded = rows.compactMap { ($0 as? [String: Any]).flatMap(HandsProjectChoice.init(wire:)) }
        guard decoded.count == rows.count, Set(decoded.map(\.id)).count == decoded.count else { return nil }
        return decoded
    }
}

/// 卡上選的範圍（等級、專案 id）。
struct HandsScopeChoice: Equatable, Sendable {
    var level: Int
    /// 大寫 UUID 字串。
    var projectIDs: Set<String>

    /// 最多選幾個（跟清單上限 HandsProjectChoice.listLimit 分開寫；主機目前允許的都要放得進來）。
    static let selectionLimit = HandsProjectChoice.listLimit

    /// begin_connect 帶的（等級只收整數，不收 true／1.5；專案 id 只收字串、最多 selectionLimit 個）。nil＝這個請求沒有帶範圍（舊版擁有者）。
    static func fromWire(_ payload: [String: Any]) throws -> HandsScopeChoice? {
        guard payload["level"] != nil || payload["project_ids"] != nil else { return nil }
        guard let number = payload["level"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              Double(number.intValue) == number.doubleValue,
              let raw = payload["project_ids"] as? [String], raw.count <= selectionLimit, raw.allSatisfy({ $0.utf8.count <= 64 }) else {
            throw HandsConnectRefusal.scopeInvalid
        }
        return HandsScopeChoice(level: number.intValue, projectIDs: Set(raw))
    }

    var wireFields: [String: Any] { ["level": level, "project_ids": projectIDs.sorted()] }
}

extension HandsConnectOffer {
    /// 卡片一開始的選擇：主機目前的等級上限與允許專案（清單裡有的；暫時不見的也在清單裡、照樣勾著）。
    /// 清單裡沒有的＝政策上不能當專案（入口、chatgpt/、受保護的資料夾），卡上明講會拿掉（droppedProjects）。
    var defaultChoice: HandsScopeChoice {
        let selectable = Set(projectChoices.map(\.id))
        return HandsScopeChoice(level: scope.level, projectIDs: Set(scope.projects.map(\.id).filter(selectable.contains)))
    }

    /// 這個等級的記憶說明（主機給的；舊版主機沒給就用這台的規則）。記憶照現有規則，不在卡上改。
    func memoryText(level: Int) -> String {
        levelMemory.indices.contains(level) ? levelMemory[level] : HandsGrantScope.memoryText(level: level)
    }

    /// 照卡上選的範圍重拍的卡片內容（digest＝主機改完設定後拍的那一份，對得上才開窗口）。
    /// 主機不收卡上選的範圍（舊版）、等級不在 0…2、選了清單外的專案＝nil。
    func choosing(_ choice: HandsScopeChoice) -> HandsConnectOffer? {
        guard supportsChoice, (0...HandsSettings.maxLevel).contains(choice.level) else { return nil }
        let picked = projectChoices.filter { choice.projectIDs.contains($0.id) }
        guard picked.count == choice.projectIDs.count else { return nil }
        let projects = picked.map { HandsProjectRef(id: $0.id, name: $0.name) }.sorted { $0.name < $1.name }
        return HandsConnectOffer(hostDeviceID: hostDeviceID, hostName: hostName, publicHost: publicHost,
                                       scope: HandsGrantScope(level: choice.level, projects: projects, memory: memoryText(level: choice.level)),
                                       callbackHosts: callbackHosts, setupEpoch: setupEpoch, projectChoices: projectChoices,
                                       levelMemory: levelMemory, supportsChoice: true, connectedCount: connectedCount)
    }

    /// 這份卡片內容的範圍（begin 帶給主機的；主機不收卡上選的範圍＝nil）。
    var scopeChoice: HandsScopeChoice? {
        supportsChoice ? HandsScopeChoice(level: scope.level, projectIDs: Set(scope.projects.map(\.id))) : nil
    }

    /// 選得比主機現在的設定小（等級降、或拿掉了現在允許的專案）：已經連上的也會跟著少掉這些（有效範圍＝grant ∩ 設定）。
    func narrows(_ choice: HandsScopeChoice) -> Bool {
        choice.level < scope.level || !Set(scope.projects.map(\.id)).isSubset(of: choice.projectIDs)
    }

    /// W183 R7a 審查：主機目前允許、但不能當專案（清單裡沒有）的：按［連線］會從允許清單拿掉（卡上明講，不默默拿掉）。
    var droppedProjects: [HandsProjectRef] {
        let listed = Set(projectChoices.map(\.id))
        return scope.projects.filter { !listed.contains($0.id) }
    }
}

extension HandsService {
    /// 主機上的所有專案（Coder 的專案，不含助理那個）：id、名稱、資料夾。會回主執行緒讀專案清單：不要在鎖裡叫。
    /// W183 R10 底線 B：順便更新交易實盤類的分類（鎖裡的最後一道檢查看這一份；HandsService.noteProjectRecords）。
    /// W183 R10 第二輪（GPT-6 5；主導裁決）：專案根目錄本身（或它上面某一層）是金鑰類資料夾（.aws、credentials-backup…；設定路徑或
    /// 真實路徑任一個）＝整個專案不納入範圍（哪裡都不列、讀不到、開不了工作區）。
    /// W183 R10 第三輪（GPT-6 6）：讀清單的那一刻發序號（跟主執行緒看到清單變了是同一個序列）；分類照序號發布，晚到的舊計算不發布。
    func allProjectRecords() -> [(UUID, String, String)] {
        #if DEBUG
        if let projectsOverride {
            let (raw, seq) = readOverride(projectsOverride)
            let records = Self.withoutSecretRoots(raw, home: runtime.home)
            noteProjectRecords(records, seq: seq, digest: Self.projectListDigest(raw))
            return records
        }
        #endif
        let (raw, seq): ([(UUID, String, String)], UInt64) = onMain { [weak self] in
            guard let self, let engine = self.engine else { return ([], 0) }
            let list = engine.doc.projects.filter { $0.id != engine.doc.assistantProjectID }.map { ($0.id, $0.name, $0.workdir) }
            return (list, self.noteListRead(Self.projectListDigest(list)))
        }
        let records = Self.withoutSecretRoots(raw, home: runtime.home)
        if seq > 0 { noteProjectRecords(records, seq: seq, digest: Self.projectListDigest(raw)) }
        return records
    }

    /// W183 R10 第二輪：拿掉根目錄是金鑰類資料夾的專案（設定的路徑、真實路徑都看）。
    static func withoutSecretRoots(_ records: [(UUID, String, String)], home: String) -> [(UUID, String, String)] {
        records.filter { _, _, workdir in
            !HandsSecretFiles.isSecretRoot(workdir, home: home)
                && !(HandsPath.realpath(workdir).map { HandsSecretFiles.isSecretRoot($0, home: home) } ?? false)
        }
    }

    /// W183 R10：「全部可見」的有效範圍＝能當專案的＋這一刻暫時用不了的（資料夾不見、磁碟讀不到：之後回來照樣可見，它的工作區不會被鎖）；
    /// 政策上不能當專案的（入口本身、入口的 chatgpt/、家目錄、秘密資料夾、網路磁碟…：HandsRuntime.folderProblem）不算。
    func visibleProjectRecords() -> [(UUID, String, String)] {
        allProjectRecords().filter { _, _, workdir in
            guard let real = HandsPath.realpath(workdir) else { return true }   // folder_missing（暫時）
            guard let problem = runtime.folderProblem(real) else { return true }
            return HandsProjectChoice.temporaryProblems.contains(problem)
        }
    }

    /// W183 R10：這台所有能當專案的（資料夾在、HandsRuntime.folderProblem 過得了）：面板、卡片的清單都是這一份。
    func buildProjectRecords() -> [(UUID, String, String)] {
        allProjectRecords().compactMap { id, name, workdir -> (UUID, String, String)? in
            guard let real = HandsPath.realpath(workdir), runtime.folderProblem(real) == nil else { return nil }
            return (id, name, workdir)
        }
    }

    /// 主機上的專案清單（副設備的狀態 remote_hands_status 用；W183 R7a 起的格式）。不能當專案（HandsRuntime.folderProblem：入口本身、
    /// 入口的 chatgpt/、家目錄、秘密資料夾、網路磁碟、雲端同步資料夾…）的不列；只給 id、名稱、資料夾最後一段。
    /// W183 R7a 審查（Claude）：allowed 裡面、這一刻用不了的（資料夾暫時不見、磁碟讀不到）照樣列出、帶 problem。
    /// W183 R10：不再照 ChatGPT build 的專案上限收窄（專案全部可見；中央設定只剩等級）。
    func connectProjectChoices(allowed: Set<String>) -> [HandsProjectChoice] {
        allConnectProjectChoices(allowed: allowed)
    }

    /// W183 R8c：這台所有能當專案的（ChatGPT build 的設備面板列的；W183 R10：就是有效範圍的全部專案）。只列這一刻就能用的（不帶 problem）。
    func buildProjectChoices() -> [HandsProjectChoice] {
        buildProjectRecords().compactMap { id, name, workdir -> HandsProjectChoice? in
            guard let real = HandsPath.realpath(workdir) else { return nil }
            return HandsProjectChoice(id: id.uuidString, name: String(name.filter { !$0.isNewline }.prefix(80)),
                                      folder: String(URL(fileURLWithPath: real).lastPathComponent.prefix(80)))
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// W183 R7a 審查：主機上的清單（含 allowed 裡暫時用不了的）。
    private func allConnectProjectChoices(allowed: Set<String>) -> [HandsProjectChoice] {
        allProjectRecords().compactMap { id, name, workdir -> HandsProjectChoice? in
            let cleanName = String(name.filter { !$0.isNewline }.prefix(80))
            guard let real = HandsPath.realpath(workdir) else {
                guard allowed.contains(id.uuidString) else { return nil }
                return HandsProjectChoice(id: id.uuidString, name: cleanName, folder: String(URL(fileURLWithPath: workdir).lastPathComponent.prefix(80)),
                                          problem: "folder_missing")
            }
            let folder = String(URL(fileURLWithPath: real).lastPathComponent.prefix(80))
            switch runtime.folderProblem(real) {
            case nil:
                return HandsProjectChoice(id: id.uuidString, name: cleanName, folder: folder)
            case let problem? where HandsProjectChoice.temporaryProblems.contains(problem) && allowed.contains(id.uuidString):
                return HandsProjectChoice(id: id.uuidString, name: cleanName, folder: folder, problem: problem)
            default:
                return nil
            }
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

}
