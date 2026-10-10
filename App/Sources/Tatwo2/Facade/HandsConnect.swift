import AppKit
import Combine
import Foundation

// W183 R6 接口（主導）：「一個開關」兩房共用的名字；規格 docs/specs/183-chatgpt-hands/one-switch.md。
// - R6a（流程與畫面）：設定流程走到「等使用者按［連線］」時叫 `HandsConnectFlow.shared.offer()`；TAP 那一列的一行狀態看 `phase`；
//   不自己判斷配對、不碰連線意圖的內容。
// - R6b（連線安全與 Pod）：實作這裡的每個方法——私訊框的［連線］原生卡、一次性連線意圖（attempt）與範圍快照、主機端 begin／cancel、
//   Pod 自動建連接器、配對頁放進私訊框、成功證據（這個 attempt 的交易 → grant → 第一次 /mcp）、取消作廢未兌換的授權碼。
//
// W183 R6b 實作（擁有者這一端：按［連線］的那一台）：
// - offer()：向主機拿卡片內容（主機、服務網址、範圍、callback、世代；HandsConnectOffer），Pod 目前帳號；私訊框出現原生的［連線］卡。
//   卡片與配對碼是原生畫面：不進聊天草稿（輸入列拿掉）、模型輸入、通知預覽（不發 Island）、診斷（problem 只有白話）、截圖（敏感頁閘門＋視窗不給擷取）。
// - 按［連線］＝建立一次性的 HandsConnectIntent（只在記憶體）。順序：Pod 準備（登入、開發者模式、讀既有連接器；這時窗口關著）→
//   主機 begin（開綁這個 attempt 的 10 分鐘窗口）→ Pod 建（或重新連線）連接器 → 等 ChatGPT 開出 TATWO 配對頁（同頁或另開視窗）→
//   把 Pod 看到的授權參數（evidence）交給主機核對，對上了主機才給這台配對碼 → TATWO 在那一頁代填 8 碼並送出（W183 R10；填不成才照卡片自己打）
//   → 主機回報 grant（授權完成）→
//   這個 grant 的第一次 /mcp（工具連上）→ 再核對一次 Pod 帳號 → 送確認（已連線）。
// - 失敗分流：明確不符（網域、交易、帳號、世代）＝refused，終止、不顯示碼；能力不足（改版、找不到、看不到授權頁）＝needsManual，
//   這次取消，讓使用者選「再連一次」或「手動」；送出結果未知＝先查、不重送（連接器：先讀清單，不再按建立）。
// - 作廢：鎖螢幕、Pod 關掉或登出、帳號切換、主機或範圍改變＝取消這個 attempt，回到「等你在私訊框按一下」（重新顯示卡片）。
// - 不自動：開窗口、建或重連連接器、送配對碼一律要這台有人按了［連線］（或同一段流程裡的「繼續」「再連一次」「手動」）；重開 App 不沿用。
// - （已取代）首版不自動填配對碼。W183 R10（使用者 09-29 裁決：「I understand」與 8 碼由 TATWO 代做，只限 TATWO 自己開的那一頁）：
//   只在綁住的那一頁代填（contract §3b）；綁不上＝不填、不給碼、那一筆作廢；填不成＝卡片顯示碼讓使用者自己打。
// W183 R6b 審查（GPT-6、Claude）：
// - 成功要擁有者最後確認：第一次 /mcp 之後（主機 tools_ready，grant 還是暫時的、不能呼叫工具）再讀一次 Pod 帳號身分（登入編號、工作區、信箱）；
//   跟按［連線］時一樣才送 confirm；讀不到或不一樣＝refused（撤銷）。主機不會自己跳到「已連線」。
// - 取消採用主機的回覆：成功先到＝照實顯示「已連線」；取消結果不確定＝明講不確定；取消了才收卡片。begin 送出前就記成「主機可能收了」，
//   取消一定會送（主機收到晚到的 begin 不開窗口）。
// - 配對頁：只收這一輪按下之後、從 chatgpt.com 的非對話頁打開的第一個（主框架看上一個網址；popup 看打開它的那一刻與那時的網址）；
//   從對話、按下之前開的 popup、外站打開的＝refused。綁住的那個畫面一開始載入別的、關掉、晚到的舊世代＝碼馬上收；
//   配對中途出現外站授權頁、別組參數、被帶到別的網站＝馬上 refused（不等下一圈）。授權完成之後頁面的變化只收碼。
// - 警語：使用者按「繼續」帶回他看過的那一張表單與那段警語的指紋；開發者模式自動接著做時不帶（新的表單照樣交給他看）。
// - 等使用者處理開發者模式或警語時一直拿著 Pod（他就在那一頁按；聊天先排隊），最多 5 分鐘。
// - 按過建立、結果沒查清楚的（帳號＋網址）記著：清單裡找不到它之前不再按建立（改手動）。
// W183 R7a（卡上選範圍；HandsConnectScope.swift）：［連線］卡上選等級（L0／L1／L2）與專案（預設沿用主機目前的設定）；
//   按［連線］時選的就是這個 attempt 的範圍快照（begin 帶給主機；主機驗過、寫進設定、照新設定拍快照、核對 digest）。
//   「再連一次」「繼續」照同一個選擇重拍，跟上次確認的一樣才直接開始。選擇只在記憶體、只有卡片上的按鈕改得到。
// W183 R7a 審查（Claude）：選擇記著「在哪一台主機、主機設定是哪一份（digest）的時候做的」（choiceBasis）。主機的設定在這段時間被別的地方
//   改過（「詳細」、另一台）＝不沿用舊選擇（卡片從主機現在的設定開始；「再連一次」「繼續」也不直接開始），免得一按就把主機改回舊的。
//   從外面叫 offer()（TAP、設定流程）、連上之後自動收起、已連線時按取消，都清掉選擇。
// W183 R10（使用者 09-29：「連線根本連不上 而且也根本不自動」「就要給他用了還要多一個勾選 chatgpt是日常最親的ai 沒有那麼多權限需要隔離」；
//   裁決：ChatGPT 的「I understand」框和 8 碼由 TATWO 代做，只限 TATWO 自己開的那一頁；按［連線］那一下就算同意）：
// - 卡片不再選範圍（範圍＝中央設定的等級＋這台全部專案）；［連線］旁一行小字講明「按連線＝同意 ChatGPT 開發者模式的風險說明，TATWO 會替你勾選」。
// - 代勾：Pod 回 .tickable（表單上只有「I understand and want to continue」那一格、警語是認得的）＝App 用原生滑鼠事件點那一格
//  （網頁看到的是 isTrusted；R9 的真人證據鏈原封不動，只是按的人換成 TATWO），再帶同一張表單的記號按 Create。沒勾到、多了沒見過的
//   勾選框、警語大改＝照舊交給使用者（卡片一句話說原因）。代勾的那一段 Create 還沒按：出現配對頁＝當場終止（Create 之前的不算）。
// - 代填：配對碼只在主機核對過「Create 之後擁有者 Pod 看到的第一個配對頁」才給（§3b 的綁定不變）；拿到了就由 Pod 在**那一頁**
//  （同一個畫面、同一份文件、同一組參數）用原生點擊＋按鍵填好送出，碼不上卡片。填不成（找不到欄位、頁面改版、碼沒被收下）＝退回顯示碼。
//   手動模式（Create 是使用者自己按的）不代填。
// W183 R8c（多設備；GPT-6 必改 5）：
// - offer(target:preset:)：連指定的那台（這台＝本機；主設備＝設備簽章 RPC；別台副設備＝經主設備的信箱，碼只回到這台）；preset＝ChatGPT build
//   面板上選的等級與專案（卡片一開始就是它；主機那端照樣核對、而且不能超過 build 給那台的上限）。
// - Pod 建的連接器名稱「TATWO（<那台的名稱>）」；同一個 Pod 一次只建一個（這個流程只有一個 attempt；「連全部」由 HandsBuildController 逐台排）。
// - 送給主機的配對頁證據是第二版（HandsAuth.boundEvidence：再綁 target、issuer／resource、attempt、setupEpoch）。

/// 連線這一段的狀態（R6a 把它換成 TAP 那一列的一行字）。
enum HandsConnectionPhase: String, Sendable, Equatable {
    /// 還沒走到連線（或已關閉）。
    case idle
    /// 私訊框的［連線］卡已經出來，等使用者按。
    case waitingTap = "waiting_tap"
    /// 等使用者在私訊框處理 ChatGPT 的登入、MFA 或開發者模式警語（App 不代按；W183 R10 起「I understand」那一格由 TATWO 原生代勾，代勾不成才等使用者）。
    case waitingUser = "waiting_user"
    /// App 正在 Pod 裡建（或找回）連接器。
    case creatingConnector = "creating_connector"
    /// ChatGPT 開出的 TATWO 配對頁在私訊框裡：TATWO 代填 8 碼（W183 R10；填不成＝使用者照卡片打）。
    case waitingPairing = "waiting_pairing"
    /// 授權完成、等這個 grant 的第一次 /mcp 與擁有者確認。
    case verifying
    /// 這個 attempt 的 grant 已經有第一次 /mcp 成功、擁有者確認過。
    case connected
    /// 自動做不到（改版、看不到授權頁）：這次已取消，等使用者選「再連一次」或「手動」。
    case needsManual = "needs_manual"
    /// 明確不符（網域、交易、帳號、世代）：已終止、沒有顯示碼、沒有新 grant。
    case refused
    /// 出錯（一句話在 `problem`）。
    case failed
}

/// W183 R11（使用者 09-30：「接上要明確讓chatgpt能獲得codex能力 以及os記憶讀取」「ui要簡單好懂而不是砸文字做解釋」）：
/// 接上之後 ChatGPT 能做的（照等級）。L2＝Codex（沙盒工作區：讀、改檔、跑測試，交件後由你合併；這就是「如 Codex 的工程能力」）＋記憶
/// （讀、遮敏感；寫只進 ChatGPT 收件匣）；L1＝記憶＋提案；L0＝只看。卡片只畫圖示＋這幾個字（說明在滑過的提示裡）。
/// 兩條底線照舊（HandsFloors.swift）：金鑰類檔案讀不到、交易實盤類專案最多 L0。
enum HandsConnectAbility: String, CaseIterable, Sendable {
    case codex, memory, proposals, view

    var word: String {
        switch self {
        case .codex: "Codex"
        case .memory: "記憶"
        case .proposals: "提案"
        case .view: "只看"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .memory: "brain"
        case .proposals: "lightbulb"
        case .view: "eye"
        }
    }

    static func of(level: Int) -> [HandsConnectAbility] {
        switch min(max(level, 0), HandsSettings.maxLevel) {
        case 2: [.codex, .memory]
        case 1: [.memory, .proposals]
        default: [.view]
        }
    }

    static func words(level: Int) -> String { of(level: level).map(\.word).joined(separator: "、") }

    /// W183 R12（使用者 09-30 裁決：拿掉等級選擇——「他連上就是全部都能看 唯讀記憶是有他專屬的區塊」；連上＝全開＝L2）：連上之後能做的，
    /// 一行白話（確認卡、設定 › Plugin › TAP 的 ChatGPT Dev 面板同一句；不寫等級、不畫等級膠囊）。L2＝主導指定的那一句；
    /// L1、L0 只剩舊版主機（一律不調高）或還沒升上來的那一下（照實寫它現在能做的）。
    static func line(level: Int) -> String {
        switch min(max(level, 0), HandsSettings.maxLevel) {
        case 2: "連上後：看全部專案・可用 Codex・記憶只讀＋收件匣"
        case 1: "連上後：看全部專案・記憶只讀＋收件匣・寫提案"
        default: "連上後：只看全部專案（不碰記憶）"
        }
    }
}

/// 一次性的連線意圖（只在記憶體）。使用者按［連線］時建立；重開、鎖屏、Pod 關掉、帳號切換、主機或範圍改變＝作廢。
struct HandsConnectIntent: Sendable, Equatable {
    let attemptID: UUID
    /// 主機設定流程的世代（HandsSetup.setupEpoch）。
    let setupEpoch: String
    /// 按［連線］的那一台（配對碼只給它）。
    let ownerDeviceID: String
    let hostDeviceID: String
    /// `https://<公開主機名>/mcp`（主機的可信設定，不從網頁讀）。
    let mcpURL: String
    /// 授權範圍快照（authorize_begin 用這個，不讀按下之後才改的設定）。
    let scope: HandsGrantScope
    /// Pod 目前登入的帳號（觀測值，不是已驗證的身分）。
    let podAccount: String?
    let expiresAt: Date
    /// W183 R6b 審查：Pod 帳號的比對身分（登入編號、工作區、信箱；卡片出來時讀的）。最後確認前要一樣。
    let podIdentity: String?
}

// MARK: - Pod 與私訊框（正式＝ChatGPT Space 的 Pod 與私訊框；自測＝假的）

/// Pod 主框架（或 Pod 另開的視窗）實際載入的一頁（原生瀏覽器回報，不是網頁腳本說的）。
struct HandsPodFrame: Equatable, Sendable {
    var url: URL?
    var generation: UInt64
    var loading: Bool
    var httpStatus: Int
    /// 是 Pod 另開的視窗（CEF popup）；popupKey 認得是哪一個。
    var popup: Bool = false
    var popupKey: Int? = nil
    /// W183 R6b 審查：從哪裡來（主框架＝上一個網址；popup＝打開它時主框架的網址）。
    var source: URL? = nil
    /// W183 R6b 審查：popup 打開的時間。
    var openedAt: Date? = nil
    /// W183 R6b 審查：這個 popup 關掉了（url＝nil）。
    var closed: Bool = false
    /// W183 R10 第三輪（GPT-6 發現 1）：popup 是 Pod 主框架開的；不是＝不代填。
    /// W183 R10 第四輪：預設 false——正式 Pod 照 CEF 開窗那一刻的 frame->IsMain() 帶真的證據（ChatGPTConnectorPod.registerPopup）。
    var openerIsMain: Bool = false

    /// 哪一個畫面（主框架＝-1；popup＝它的 key）。
    var surface: Int { popup ? (popupKey ?? -2) : -1 }
}

enum HandsPodReadiness: Equatable, Sendable {
    case ready(account: String?)
    case needsLogin
    case unavailable(String)
}

/// Pod 讀到的 ChatGPT 外掛狀態（以「完整 MCP 網址＋OAuth」辨識，不以名字）。
struct HandsConnectorScan: Equatable, Sendable {
    struct Match: Codable, Equatable, Sendable {
        var id: String?
        var name: String
        /// "oauth"｜"none"｜"unknown"
        var auth: String
        var serverURL: String? = nil
        var detailPath: String? = nil
        var connected: Bool? = nil
        var needsReconnect: Bool? = nil
    }
    var loggedIn = true
    /// 讀得到完整的外掛清單（讀不到或看不懂＝不知道有沒有建過：不建，改手動）。
    var listKnown = false
    /// 開發者模式（nil＝看不出來）。
    var devMode: Bool?
    var matches: [Match] = []
    var conflictingNames: [String] = []
    /// 指令本身失敗（逾時、網頁改版）。
    var failure: String?
}

/// W183 R6b 審查：使用者看過的那一張表單（網頁上的記號）與那一段警語的指紋。按「繼續」帶回去；表單換了或警語變了＝沒看過。
struct HandsConnectorAck: Equatable, Sendable {
    let form: String
    let warning: String
    /// W183 R12（主導 3：「ChatGPT 改了說明文字：卡片直接顯示讀到的新說明全文，配一顆［同意並繼續］」）：網頁腳本讀到、跟 TATWO 認得的版本
    /// 對不上的那一份同意內容（純文字＋連結的字與網域）；讀不到或不能代勾（太長、連結不在 OpenAI 的網域）＝nil（照舊請使用者自己勾）。
    var consent: HandsConsentOffer? = nil
    /// W183 R12：使用者同意過的那一份（HandsConsentOffer.print 原樣）：帶回去給網頁腳本——整份一字不差才當成認得的版本代勾。
    var approved: String? = nil

    init(form: String, warning: String, consent: HandsConsentOffer? = nil, approved: String? = nil) {
        self.form = form
        self.warning = warning
        self.consent = consent
        self.approved = approved
    }

    /// 帶著使用者同意的那一份再走一次。
    func approving(_ print: String) -> HandsConnectorAck { HandsConnectorAck(form: form, warning: warning, consent: consent, approved: print) }
}

/// W183 R12（主導 3）：ChatGPT 的同意內容改了、TATWO 不認得的那一份（網頁腳本只收文字節點＝已經是純文字；外來文字只顯示、不執行）。
/// print＝綁住這一版的整份（版本標記＋照順序的文字＋每一個連結的字與網域）：使用者按［同意並繼續］＝記下它的 SHA-256（只在這台），
/// 下次同一份就自動代勾（網頁腳本那端照舊整份一字不差才算）。
struct HandsConsentOffer: Equatable, Sendable {
    struct Link: Equatable, Sendable {
        let text: String
        let origin: String
    }
    let text: String
    let links: [Link]
    let print: String

    static let textLimit = 4000
    static let printLimit = 12_000

    /// 只收網頁腳本給的樣子：文字、連結有上限；控制字元拿掉（顯示用）；print 要是「user」開頭的那一份。
    init?(wire raw: Any?) {
        guard let object = raw as? [String: Any], let text = object["text"] as? String, let print = object["print"] as? String,
              !text.isEmpty, text.count <= Self.textLimit, print.count <= Self.printLimit, print.hasPrefix("user\n"),
              let rawLinks = object["links"] as? [Any], rawLinks.count <= 16 else { return nil }
        var links: [Link] = []
        for item in rawLinks {
            guard let link = item as? [String: Any], let label = link["text"] as? String, let origin = link["origin"] as? String,
                  label.count <= 200, origin.count <= 200, origin.hasPrefix("https://") else { return nil }
            links.append(Link(text: Self.clean(label), origin: origin))
        }
        self.text = Self.clean(text)
        self.links = links
        self.print = print
    }

    init(text: String, links: [Link], print: String) {
        self.text = text
        self.links = links
        self.print = print
    }

    /// 同意過的記這個（只在這台）。
    var digest: String { HandsAuth.sha256Hex(Data(("tatwo-connect-consent|" + print).utf8)) }

    /// 顯示用：控制字元（換行、tab 以外）拿掉。
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }))
    }
}

/// W183 R10：「I understand and want to continue」那一格在 Pod 畫面上的位置（網頁腳本量的：CSS px、相對於畫面左上；也帶當時的畫面大小）。
/// App 只拿它決定原生滑鼠點哪裡；那一下有沒有落在那一格，仍由網頁腳本的真人證據鏈判（沒落在上面＝沒有證據、不按 Create）。
struct HandsTickTarget: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let viewportWidth: Double
    let viewportHeight: Double
    /// W183 R10 第二輪（GPT-6 2）：量的那一份文件（Pod 主框架收到這個結果那一刻的導頁世代）。點之前世代變了＝不點。
    var generation: UInt64 = 0
    /// W183 R10 第三輪：這一格屬於哪一張表單的記號（派送前請網頁腳本核同意內容用；Pod 驅動填）。
    var form: String = ""
    /// W183 R10 第三輪（GPT-6 發現 2）：量完當下 CEF 認的那一個節點（DevTools backendNodeId；Pod 驅動填）。派送前只驗這一個節點
    ///（不再依座標重新認領）；nil＝拿不到可信的節點身分，不代勾。
    var node: HandsTickNode? = nil

    /// 只收有限、寬至少 8、高預設 8（Create 可見區域為 4）、整格在畫面裡、畫面大小合理的。
    init?(wire raw: Any?, generation: UInt64 = 0, minimumHeight: Double = 8) {
        guard let object = raw as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard Set(object.keys).isSubset(of: ["x", "y", "w", "h", "vw", "vh"]), let x = number("x"), let y = number("y"),
              let width = number("w"), let height = number("h"), let vw = number("vw"), let vh = number("vh"),
              width >= 8, height >= minimumHeight, vw >= 1, vh >= 1, vw <= 10_000, vh <= 10_000,
              x >= 0, y >= 0, x + width <= vw, y + height <= vh else { return nil }
        self.init(x: x, y: y, width: width, height: height, viewportWidth: vw, viewportHeight: vh, generation: generation)
    }

    init(x: Double, y: Double, width: Double, height: Double, viewportWidth: Double, viewportHeight: Double, generation: UInt64 = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.generation = generation
    }

    /// 原生點擊的點：格子中間取整數（CEF 只收整數，而且一定還在格子裡）。
    var point: (x: Double, y: Double) { ((x + width / 2).rounded(.down), (y + height / 2).rounded(.down)) }
}

/// W183 R10 第三輪：CEF 畫面快照裡那一格的節點（elementID＝cef-<backendNodeId>，瀏覽器那端給的、網頁偽造不了）與它當時的位置。
struct HandsTickNode: Equatable, Sendable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// W183 R10 第三輪：代勾的結果。clicked＝原生點擊送出了（有沒有算數由網頁腳本的證據鏈判）；consentChanged＝派送前網頁腳本核到同意內容
///（版本、順序文字、連結字與網域）跟量的時候不一樣：不點、交給使用者。
enum HandsTickOutcome: Equatable, Sendable {
    case clicked
    case notClicked
    case consentChanged
}

/// W183 R10 第二輪（GPT-6 1；主導裁決「記下 Create 送出的那一刻與當時的文件／導頁世代」）：App 送出「按 Create（或重新連線）」之前記下的錨點。
/// 之後出現的第一個配對頁要在這之後、從這個流程導過來：主框架＝比這個世代新、一路都在 chatgpt.com；popup＝這一刻之後才開的。
/// 沒有錨點（整個準備期間）出現的配對頁＝一律拒絕、交易作廢。
struct HandsPressAnchor: Equatable, Sendable {
    let at: Date
    /// Pod 主框架那時的導頁世代與網址（連接器對話框那一頁）。
    let mainGeneration: UInt64
    let mainURL: URL?
    /// 那時已經開著的 popup（之後在它們裡面出現的配對頁不算）。
    let popups: Set<Int>
    /// W183 R10 第三輪（GPT-6 發現 7）：這一次按屬於流程的哪一次操作（流程在叫 create／reconnect 之前發的；錨點回呼只收現在這一次的）。
    var operation: String = ""
}

/// W183 R10：Pod 在綁住的配對頁填 8 碼的結果。
enum HandsCodeFill: Equatable, Sendable {
    /// 填好、按了送出（有沒有被收下看主機的狀態）。
    case filled
    /// 填不成（不是綁住的那一頁、找不到欄位、頁面改版、原生輸入送不出去）：退回顯示碼。原因只記在自測紀錄，沒有碼。
    case failed(String)
}

enum HandsConnectorAction: Equatable, Sendable {
    /// 按了建立（或重新連線）。
    case pressed
    /// W183 R10：表單上只剩「I understand and want to continue」那一格要勾（Pod 認得的那一格、警語也認得）：TATWO 代勾。
    /// 帶著這一張表單的記號與警語指紋（勾完照 R9 帶回去按 Create）與那一格在畫面上的位置。
    case tickable(HandsConnectorAck, HandsTickTarget)
    /// 要使用者自己看、自己按（警語、要打勾、開發者模式）：App 不代按。帶著他要看的那一張表單與警語。
    /// （W183 R10：只剩「I understand」那一格時是 .tickable，由 App 原生代勾；這裡是代勾不成、或別的情況。）
    case needsUser(String, HandsConnectorAck?)
    /// 找不到要按的東西（改版）。
    case notFound(String)
    /// 符合的不只一個（不猜）。
    case ambiguous(String)
    /// 讀回來不對（網址被改、不是 OAuth）：停。
    case refused(String)
    /// 送出去了、不知道結果（逾時）：先讀清單，不再按建立。
    case unknown
}

/// W183 R12：找「Connect」那一顆的結果。waiting＝ChatGPT 的外掛對話框整張停在等待（按了 Create 之後在等它自己的授權視窗；那時候沒有 Connect 是正常的）。
enum HandsGesturePoint: Equatable, Sendable {
    /// shown＝亮框畫上了（那一顆的字）；clicked＝TATWO 自己真的點擊按了那一顆（Continue to …）。
    case shown(String), clicked(String), waiting, none
    /// W183 R12（.036 實機）：對話框裡 ChatGPT 講了錯（例：「An app with this name already exists」）＝沒建成（那一句原文，最多 80 字）。
    case rejected(String)
}

@MainActor
protocol HandsConnectPodDriving: AnyObject {
    /// Pod 主框架或它另開的視窗載入了一頁（或 popup 關了）。
    var onFrame: ((HandsPodFrame) -> Void)? { get set }
    /// W183 R10 第二輪：Create（或重新連線）真的送出之前那一刻（Pod 驅動在送 connectorPress 之前叫；流程記成來源證據的錨點）。
    var onPressDispatch: ((HandsPressAnchor) -> Void)? { get set }
    /// W183 R10 第三輪（GPT-6 發現 7）：流程在叫 create／reconnect 之前設的操作編號；Pod 驅動在指令一開始記下，錨點帶著它（晚到的舊操作流程不收）。
    var pressOperation: String? { get set }
    /// W183 R10 第四輪（GPT-6 發現 1）：原生一開窗就通知（popup 的 key、開的時間、是不是 Pod 主框架開的）——不等載入完成、不管之後關不關。
    var onPopupOpened: ((Int, Date, Bool) -> Void)? { get set }
    /// Pod 關了、登出了（nil＝還在）。
    var onLost: ((String) -> Void)? { get set }
    /// W183 R12（.036 實機）：Create 量不到、點不中＝亮起來請使用者自己按（流程換卡片那一句）。
    var onUserPressNeeded: (() -> Void)? { get set }
    func prepare() async -> HandsPodReadiness
    /// 卡片上顯示的帳號（信箱或名字）。
    func account() async -> String?
    /// W183 R6b 審查：比對用的帳號身分（登入編號、工作區、信箱）。讀不到＝nil（不能當成通過）。
    func identity() async -> String?
    /// 獨占 Pod（聊天、語音中不硬換頁、等空檔）；等不到或流程取消回 false。
    func acquireExclusive(timeout: TimeInterval) async -> Bool
    /// 放掉獨占：先停掉還在跑的連接器指令、把 Pod 帶回 chatgpt.com 首頁，回到了才放行排隊的聊天。
    func releaseExclusive()
    func probe(connectorName: String) async -> String
    func scan(url: String) async -> HandsConnectorScan
    /// 只看現在這一頁（不換頁）開發者模式開了沒：使用者自己按的時候不打擾他。
    func devModeNow() async -> Bool?
    /// 建連接器；acknowledged＝使用者按「繼續」時帶回他看過的表單與警語（nil＝全新的，警語一律交給使用者）。
    func create(url: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction
    /// W183 R8c：建連接器、名稱「TATWO（<設備名稱>）」（多台時在 ChatGPT 裡分得出來；辨識既有的仍以帳號＋完整網址＋OAuth，不以名字）。
    func create(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction
    /// 重新連線：只認清單用完整網址認出來的那一個（connectorID）。
    func reconnect(url: String, connectorID: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction
    /// 引導模式：到外掛頁、把要按的地方標出來（不按）。
    func highlight(url: String, name: String?) async -> Bool
    /// 開發者模式沒開：把 Pod 換到 ChatGPT 的設定（開關在那裡；使用者自己按）。
    func showDeveloperSettings() async
    /// 授權頁載入時窗口剛好沒開（403）：同一頁重新載入一次。
    func reload(_ url: URL, popupKey: Int?)
    /// W183 R6b 審查：關掉這次連線開的視窗（配對頁 popup）：流程結束、取消、被拒一律關。
    func closePopups()
    /// W183 R10：替使用者勾「I understand and want to continue」：在 Pod 主框架那一格上送一次原生滑鼠點擊（網頁看到的是 isTrusted）。
    /// W183 R10 第三輪：只點量完當下記下的那一個節點；派送前請網頁腳本再核一次同意內容（變了＝consentChanged）。
    func tick(_ target: HandsTickTarget) async -> HandsTickOutcome
    /// W183 R10：在綁住的配對頁（frame＝那一個畫面、那一份文件；evidence＝那一頁的授權參數）填 8 碼並送出。只在那一頁；碼不進任何紀錄。
    func fillPairingCode(_ code: String, frame: HandsPodFrame, evidence: String, publicHost: String) async -> HandsCodeFill
    /// W183 R12（主導 2：要真人點的那一步指給他看）：在 Pod 頁上找 ChatGPT 要真人按的那一顆（Connect／連接／授權：放著這個網址的那一區
    /// 剛好一顆），捲到看得見；CEF 的節點驗證（畫面快照同一個位置剛好一顆沒停用的按鈕）過了才畫亮框＋箭頭（跟著捲動、點得穿過去）。
    /// 不按（ChatGPT 要真人的手勢）。true＝畫上了；找不到、對不上＝false（卡片照舊那一句）。
    func pointAtGesture(url: String, name: String) async -> HandsGesturePoint
    /// W183 R12：拿掉指路的亮框（配對頁出來了、這一段結束）。
    func clearGesture()
    /// W183 R12（.037 實機）：清單讀不到的那一個（建好、還沒授權）：用本機記下的名字在外掛頁找、核完整網址與 OAuth 才按它的 Connect。
    func reconnectByName(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction
    func inspect(_ connector: HandsConnectorScan.Match, url: String) async -> HandsConnectorAuthorization
    var resolvedConnector: HandsConnectorScan.Match? { get }
    func deleteConnector(_ connector: HandsConnectorScan.Match, keeping: String, url: String) async -> Bool
}

enum HandsConnectorAuthorization { case connected, needsReconnect, unknown }

extension HandsConnectPodDriving {
    func probe(connectorName: String) async -> String { "failed:unsupported" }
    /// 預設（自測的假 Pod）：名字不帶給網頁，照舊。
    func create(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction {
        await create(url: url, acknowledged: acknowledged)
    }
    /// W183 R10 預設（自測的假 Pod 沒接）：勾不了＝照舊交給使用者。
    func tick(_ target: HandsTickTarget) async -> HandsTickOutcome { .notClicked }
    /// W183 R10 預設（自測的假 Pod 沒接）：填不了＝退回顯示碼。
    func fillPairingCode(_ code: String, frame: HandsPodFrame, evidence: String, publicHost: String) async -> HandsCodeFill { .failed("unsupported") }
    /// W183 R12 預設（自測的假 Pod 沒接）：指不了＝卡片照舊那一句。
    func pointAtGesture(url: String, name: String) async -> HandsGesturePoint { .none }
    func reconnectByName(url: String, name: String, acknowledged: HandsConnectorAck?) async -> HandsConnectorAction { .notFound("unsupported") }
    func clearGesture() {}
    func inspect(_ connector: HandsConnectorScan.Match, url: String) async -> HandsConnectorAuthorization { .unknown }
    var resolvedConnector: HandsConnectorScan.Match? { nil }
    func deleteConnector(_ connector: HandsConnectorScan.Match, keeping: String, url: String) async -> Bool { false }
}

@MainActor
protocol HandsConnectPresenting: AnyObject {
    /// 私訊框能用（私訊鈕總開關開著）。
    var isAvailable: Bool { get }
    /// 私訊框自動打開、卡片滑出（冪等）。卡片在畫面上＝敏感（Computer Use 不准以 TATWO 為目標、視窗不給擷取）。
    func show()
    /// 卡片收回、私訊框回原狀（Pod 交回原處）。
    func hide()
    /// 卡片下面顯示 Pod 的那一頁（手機的內嵌頁）。
    func setPodVisible(_ visible: Bool)
    /// Pod 另開的視窗（配對頁）放到私訊框的位置。
    func placePopup(key: Int)
    /// 配對碼在畫面上。
    func setCodeVisible(_ visible: Bool)
    /// W183 R8b：連線完成＝私訊框 Browser 的連線分頁標「完成」（不關；使用者自己關）。
    func markDone()
    /// W183 R8b 審查（GPT-6）：這個 Pod 畫面（主框架＝-1、popup＝它的編號）現在真的在畫面上（配對碼只在綁住的那一頁看得到時給）。
    func showsSurface(_ surface: Int) -> Bool
    /// W183 R12（主導 1：「收起再打開要回到原來的步驟」）：私訊框看得到、連線的網頁在畫面上。等使用者的那幾段只算這段時間（收起來不倒數）。
    var webOnScreen: Bool { get }
}

@MainActor
extension HandsConnectPresenting {
    func markDone() {}
    /// 預設（自測的假呈現沒接）：一直算在畫面上（照舊倒數）。
    var webOnScreen: Bool { true }
}

/// 私訊框卡片的內容（原生畫面；HandsConnectDMLayer 畫）。
struct HandsConnectPairingView: Equatable, Sendable {
    let displayCode: String
    let expiresAt: Date
    let attemptsLeft: Int
    let callbackHost: String
    /// 只在這台、只在這張卡；Pod 看到的配對頁對上了才有。
    let pairingCode: String?
    let popup: Bool
    /// W183 R6b 審查：手動模式（ChatGPT 的建立是使用者自己按的：TATWO 無法確認配對頁的來源，卡片明講）。
    var manual: Bool = false
    /// W183 R8b 審查（GPT-6）：碼綁住的那一頁（HandsPodFrame.surface：主框架＝-1、popup＝它的編號）；畫面只在它看得到時顯示碼。
    var surface: Int = -1
    /// W183 R10：TATWO 代填沒成（找不到欄位、頁面改版、碼沒被收下）：退回讓使用者照卡片打（卡片說一句原因）。
    var autoFillFailed: Bool = false
    /// W183 R10 第二輪：送了 Create、回覆沒回來＝來源證明不了，TATWO 沒有代填（卡片說一句原因）。
    var autoFillUnproven: Bool = false

    var spacedCode: String? { pairingCode.map { String($0.prefix(4)) + " " + String($0.dropFirst(4)) } }
}

enum HandsConnectCard: Equatable, Sendable {
    case loading(String)
    case confirm(HandsConnectOffer, account: String?)
    case working(String)
    case waitingUser(String, continuable: Bool)
    case manual(url: String, steps: [String])
    case pairing(HandsConnectPairingView)
    case verifying(String)
    case connected(String)
    case needsManual(String)
    case refused(String)
    case failed(String)
    /// W183 R11：按了［斷線］、撤銷好了（卡片上一顆［連線］可以重接）。
    case disconnected(String)
    /// W183 R11 第二輪（GPT-6 R11b 審查 4）：已連線卡上的那幾台核對不了了（剛連上的期限過了、回報太舊）：不再說已連線、不宣稱能力；
    /// ［斷線］照樣可以按。新的回報核對得到＝回到已連線卡。
    case unconfirmed(String)
    /// W183 R12（主導 3）：ChatGPT 的說明改了、TATWO 不認得：卡片上顯示讀到的全文（可捲）＋［同意並繼續］（按了＝他看過、同意這一版：
    /// TATWO 代勾、記下這一版）。讀不到全文的照舊是 waitingUser（請他自己勾）。
    case consent(HandsConsentOffer)
}

extension HandsConnectCard {
    /// 只剩結果的卡（已連線、狀態未確認）：卡上有［斷線］。
    var isConnectedResult: Bool {
        switch self {
        case .connected, .unconfirmed: true
        default: false
        }
    }
}

/// W183 R11 最後一輪（GPT-6 R11c 審查 3）：流程讀到的 Pod 帳號身分（雜湊；nil＝流程看到登出了）與讀的那一刻 Pod 的登入世代
///（HandsPodLogin.generation）。入口只收現在這一代的；別一代的（晚到）只當成「請重新查一次」。
struct HandsConnectIdentityStamp: Equatable, Sendable {
    let tag: String?
    let generation: Int
}

/// R6a 與 R6b 之間唯一的入口。
@MainActor
final class HandsConnectFlow: ObservableObject {
    static let shared = HandsConnectFlow()

    @Published private(set) var phase: HandsConnectionPhase = .idle {
        didSet { if phase != oldValue { log("phase \(phase.rawValue)") } }   // W183 R12：正式版的連線紀錄
    }
    /// 出錯或需要手動時的一句話（給 TAP 那一列與私訊框）。沒有碼、沒有網址參數。
    @Published private(set) var problem: String?
    /// 私訊框卡片（R6b 的原生畫面讀）。
    @Published private(set) var card: HandsConnectCard? {
        didSet {
            if card != oldValue {
                pairingClipboard.clear()
                log("card " + (card.map(Self.cardLogLine) ?? "none"))
            }
        }   // 卡片換掉即清除本次複製的碼；紀錄不寫碼或帳號。
    }
    private let pairingClipboard = HandsPairingClipboard()

    /// 點擊時再核對目前卡片、綁住的頁面及期限，不能拿舊卡片複製。
    func copyPairingCode(_ shown: HandsConnectPairingView) -> Bool {
        guard phase == .waitingPairing, !cancelling, case .pairing(let current)? = card else { return false }
        return pairingClipboard.copy(shown, current: current,
                                     visible: presenter.showsSurface(shown.surface), now: dependencies.now())
    }
    /// 卡片上方那一行（主機、服務網址；按［連線］之後的每一步都顯示）。
    @Published private(set) var offerShown: HandsConnectOffer?
    /// 卡片下面要不要顯示 Pod 的那一頁。
    @Published private(set) var podVisible = false
    /// W183 R6b 審查：正在等主機回「取消」的結果（卡片的取消鈕先不收）。
    @Published private(set) var cancelling = false
    /// W183 R7a：［連線］卡上選的等級與專案。W183 R10：卡上不再選（只剩舊版主機的相容：照主機給的那一份）。
    @Published private(set) var choice: HandsScopeChoice?
    /// W183 R11（使用者 09-30「ui要簡單好懂而不是砸文字做解釋」；主導：「中間的步驟用進度點表示」）：按了［連線］之後走到第幾格
    ///（0 準備：Pod、帳號、讀外掛清單 → 1 建外掛：主機開窗口、建或重連、代勾 → 2 配對：等配對頁、代填 → 3 確認：授權、工具連上、核對帳號）。
    /// 卡片只畫點；card 裡的那一句留給滑過的提示與無障礙。
    @Published private(set) var progressStep = 0 {
        didSet { if progressStep != oldValue { log("step \(progressStep + 1)/\(Self.progressSteps)") } }   // W183 R12
    }
    /// W183 R11：進度點下面那一句——只在要你做一件事的時候才有（等 ChatGPT 空下來、在頁面上點一下）；其他時候 nil。
    @Published private(set) var progressHint: String?
    /// W183 R11：正在斷線（等主機回撤銷的結果）。
    @Published private(set) var disconnecting = false
    /// W183 R11（GPT-6 R11 審查 4）：流程最後一次讀到的 Pod 帳號身分的雜湊（HandsConnectAccounts.identityTag；沒登入＝nil）。
    /// 入口照它核對「目前這個帳號的那一條」；只在這台、不含原文。W183 R11 最後一輪（GPT-6 R11c 審查 3）：帶讀的那一刻的登入世代。
    @Published private(set) var podIdentity: HandsConnectIdentityStamp?
    /// W183 R11 最後一輪：這一次連線開始時 Pod 的登入世代（連上那一刻發布的帳號照這個）。
    private var attemptGeneration = 0
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：從新的回報推斷斷了（在別處撤銷、那台停了）的那幾台與它們原本的等級：之後新的回報證明
    /// 還連著＝「已斷線」卡回到已連線（推斷錯了救得回來）。使用者收起卡片、重接、斷線、開始新的一次就不再看。
    private var inferredEnd: (hosts: [String], level: Int?)?
    /// W183 R11（GPT-6 R11 審查 2）：這一次連線用的 Pod 帳號（進度卡上顯示：沒登入時按下、登入之後自動接著連的，就是登入的那一個）。
    @Published private(set) var attemptAccount: String?
    /// W183 R11：已連線卡的［斷線］要撤銷的主機（這次連上的那台；私訊框小膠囊打開的＝目前帳號已連上的那幾台）與它的等級（nil＝能力未確認）。
    private var connectedHosts: [String] = []
    private var connectedLevel: Int? = HandsBuildConfig.defaultLevel
    /// W183 R11：剛斷線的那幾台（「已斷線」卡上的［連線］重接它）。
    private var disconnectedHosts: [String] = []
    /// W183 R11（GPT-6 R11 審查 2）：按下［連線］的那一刻本來就沒登入 ChatGPT（卡上沒有帳號）＝登入之後可以自動接著連；
    /// 按的時候有帳號的，中途登出、換帳號＝回到確認卡（不能靠中途出現的「要登入」拿到自動接續）。
    private var loginContinueAllowed = false
    /// W183 R11 最後一輪：入口要核對的那幾台——已連線（或狀態未確認）卡上的；推斷斷了的「已斷線」卡上的（看它回不回得來）。
    var watchedHostIDs: [String] {
        if card?.isConnectedResult == true { return connectedHosts }
        if let inferredEnd, case .disconnected? = card { return inferredEnd.hosts }
        return []
    }
    /// W183 R11：入口（HandsConnectEntry）看的：這次連上的那幾台與它們的等級、剛斷線的那幾台（只讀）。
    var connectedHostIDs: [String] { connectedHosts }
    var connectedLevelValue: Int? { connectedLevel }
    var lastDisconnectedHosts: [String] { disconnectedHosts }

    struct Timeouts {
        var prepare: TimeInterval = 25
        var exclusive: TimeInterval = 120
        /// W183 R12（.034 實機：第 3 步 60 秒就放棄，ChatGPT 其實在等使用者按它頁面上的 Connect）：跟配對窗口一樣長（10 分鐘）。
        var authorizeAppears: TimeInterval = HandsAuth.windowLifetime
        var redeem: TimeInterval = 60
        var firstMCP: TimeInterval = 120
        /// 找不到授權頁多久之後提示「在頁面上點一下」（popup 被手勢保護擋了）。
        var gestureHint: TimeInterval = 3   // W183 R12：早一點講清楚要按哪裡
        /// W183 R12（主導 2）：網頁在畫面上等了多久開始找要真人點的那一顆（ChatGPT 自己開得出配對頁的就不打擾）、之後多久看一次它還在不在。
        var gesturePoint: TimeInterval = 2
        var gestureRetry: TimeInterval = 3
        /// W183 R12（.035 實機）：ChatGPT 的對話框停在等待多久之後，卡片說「ChatGPT 在等它的授權視窗」。
        var popupWaitNotice: TimeInterval = 20
        /// W183 R6b 審查：等使用者在 Pod 裡處理開發者模式或警語最多多久（拿著 Pod：ChatGPT Space 的送出先排隊）。
        var waitUser: TimeInterval = 300
        /// W183 R10：代勾之後等網頁把那一下處理完（真人證據在事件整段跑完之後才給）再帶記號按 Create。
        var tickSettle: TimeInterval = 0.5
        /// W183 R10：代填送出之後，主機多久還沒收下（授權完成）就退回顯示碼。
        var fillSettle: TimeInterval = 15
    }

    /// W183 R6b 審查：主機對「取消」的回覆。
    enum CancelOutcome: Equatable, Sendable { case cancelled, connected, unknown }

    struct Dependencies {
        var link: @MainActor () -> (link: (any HandsConnectLink)?, problem: String?)
        /// W183 R8c：連指定的那台（nil＝照舊的 link）。
        var linkFor: (@MainActor (String) -> (link: (any HandsConnectLink)?, problem: String?))? = nil
        var pod: @MainActor () -> any HandsConnectPodDriving
        var presenter: @MainActor () -> any HandsConnectPresenting
        var localDeviceID: () -> String?
        var copy: @MainActor (String) -> Void
        var now: () -> Date = Date.init
        var pollInterval: TimeInterval = 1
        var timeouts = Timeouts()
        /// 鎖螢幕、登出（正式＝NSWorkspace／系統通知；自測自己叫 invalidate）。
        var watchSession: @MainActor (@escaping @MainActor (String) -> Void) -> Void = { _ in }
        /// W183 R11：［斷線］＝撤銷這幾台主機上全部的 ChatGPT 授權（正式＝HandsBuildController.disconnect：這台本機、主設備簽章 RPC、
        /// 別台經主設備的信箱）。W183 R11（GPT-6 R11 審查 6）：逐台的結果。預設（自測沒接）＝每台都沒做成（不假裝斷了）。
        var disconnect: @MainActor ([String]) async -> [String: HandsDisconnectOutcome] = { hosts in
            Dictionary(hosts.map { ($0.lowercased(), HandsDisconnectOutcome.failed(HandsConnectFlow.disconnectUnavailable)) }, uniquingKeysWith: { a, _ in a })
        }
        /// W183 R11（GPT-6 R11 審查 4）：這台按［連線］連上的紀錄（哪個帳號連上哪台的哪一筆；只在這台）。nil＝不記（自測預設）。
        var accounts: HandsConnectAccounts? = nil
        /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：這台的單調時鐘（連上那一刻記下；「剛連上」照它算）。
        var uptime: () -> TimeInterval = { HandsMonotonic.now() }
        /// W183 R11 最後一輪（GPT-6 R11c 審查 3）：Pod 現在的登入世代（讀帳號身分之前先記下；正式＝HandsPodLogin.shared）。
        var loginGeneration: @MainActor () -> Int = { 0 }
        /// W183 R12（主導 3）：使用者同意過的同意內容（只記雜湊）；nil＝不記（自測預設：每次都問）。
        var consentApprovals: HandsConnectDigestBook? = nil
        /// W183 R12（主導 5）：按過建立、還沒在清單裡找到的（跨重開 App）；nil＝只記在記憶體（自測預設）。
        var pendingCreateBook: HandsConnectDigestBook? = nil
        /// W183 R12（.033 實機）：正式版的連線紀錄（connect-log.txt）；nil＝不寫（自測預設；R12 的自測自己給一份）。
        var connectLog: HandsConnectLog? = nil
        var connectors: HandsConnectorRegistry? = nil
        var hostAuthorization: @MainActor (String, String) -> Bool? = { _, _ in nil }
        var deviceName: @MainActor (String) -> String = { _ in "未確認設備" }
        var loginChanges: AnyPublisher<TapConnection, Never>? = nil

        static func live() -> Dependencies {
            Dependencies(
                link: { HandsConnectLinkResolver.live() },
                linkFor: { HandsConnectLinkResolver.live(target: $0) },
                pod: { ChatGPTConnectorPod.shared },
                presenter: { HandsConnectPresenter.shared },
                localDeviceID: { (try? DeviceIdentityStore.readLocal())?.deviceID },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                watchSession: { invalidate in HandsConnectSessionWatch.shared.start(invalidate) },
                disconnect: { hosts in await HandsBuildController.shared.disconnect(deviceIDs: hosts) },
                accounts: .shared,
                loginGeneration: { HandsPodLogin.shared.generation },
                consentApprovals: HandsConsentApprovals.shared,
                pendingCreateBook: HandsPendingCreates.shared,
                connectLog: .shared, connectors: .shared,
                hostAuthorization: { host, identity in HandsConnectFlow.hostAuthorization(host: host, identityTag: HandsConnectAccounts.identityTag(identity), evidence: HandsBuildController.shared.connectEvidence(host), records: HandsConnectAccounts.shared.records()) }, deviceName: { host in HandsBuildController.shared.devices.first { HandsHostAuthority.same($0.id, host) }?.name ?? "未確認設備" }, loginChanges: HandsPodLogin.shared.changes.eraseToAnyPublisher())
        }
    }

    private typealias PendingCancel = (id: String, link: any HandsConnectLink)

    private let dependencies: Dependencies
    private lazy var pod: any HandsConnectPodDriving = dependencies.pod()
    private lazy var presenter: any HandsConnectPresenting = dependencies.presenter()
    /// 每次重來 +1：舊的流程在每個 await 之後核對，對不上就不再動任何東西。
    private var runID = 0
    /// W183 R12：這張確認卡之後的第幾次嘗試（紀錄的「重試第幾次」）。
    private var attemptSerial = 0
    private var task: Task<Void, Never>?
    private var link: (any HandsConnectLink)?
    private var offerValue: HandsConnectOffer?
    /// W183 R7a：按［連線］時照卡上選的範圍重拍的那一份（這個 attempt 的範圍快照；「再連一次」核對用）。
    private var chosenOffer: HandsConnectOffer?
    /// W183 R7a 審查（Claude）：這個選擇是在哪一台主機、主機設定是哪一份（offer 的 digest）的時候做的。
    private var choiceBasis: (host: String, digest: String)?
    private var accountValue: String?
    private var identityValue: String?
    private var intent: HandsConnectIntent?
    /// 這個 attempt 可能已經送到主機（送 begin 之前就設：之後的取消一定會送）。
    private var begun = false
    private var holdsPod = false
    /// 這一輪 Pod 按下建立（或重新連線、開始手動）的時間：之後第一個 TATWO 配對頁才算（對話裡的連結、之前的頁都不算）。
    private var awaitingSince: Date?
    /// 這一輪是手動（建立是使用者自己按的）。
    private var manualAttempt = false
    /// Pod 看到的配對頁（evidence、哪一個框、第幾份文件）。
    private var observed: (evidence: String, frame: HandsPodFrame)?
    /// 現在看得到的那一頁還是綁住的配對頁（離開了、開始載入別的、關了＝碼先收起來）。
    private var onAuthorizePage = false
    /// 每個畫面看過的最新導頁世代（晚到的舊事件不算）。
    private var surfaceGenerations: [Int: UInt64] = [:]
    /// 配對頁載入時窗口剛好沒開（403）：同一頁重新載入過一次沒有。
    private var reloadedOnce = false
    /// 這個 attempt 已經換到 grant（之後頁面的變化只收碼、不再判不符）。
    private var granted = false
    /// 使用者要看的那一張表單與警語（按「繼續」帶回去）。
    private var pendingAck: HandsConnectorAck?
    /// W183 R10 第二輪（GPT-6 1）：Create（或重新連線）真的送出的那一刻（錨點）。nil＝還沒送出：整個準備期間出現的配對頁一律拒絕、作廢。
    private var pressAnchor: HandsPressAnchor?
    /// 送了「按」、但回覆沒回來（不知道網頁收了沒）：之後出現的配對頁不代填（來源證明不了），只能顯示碼讓使用者自己打。
    private var pressUnproven = false
    /// 錨點之後主框架離開過 chatgpt.com（配對頁不是一路從這個流程導過來的）。
    private var mainLeftChatGPT = false
    /// W183 R10 第三輪（GPT-6 發現 7）：現在這一次按的操作編號（叫 create／reconnect 之前發；錨點帶的不是它＝晚到的舊操作，不收）。
    private var pressOperation: String?
    /// W183 R10 第三輪（GPT-6 發現 1；主導裁決）：錨點之後、配對頁出來之前新開的 popup。只准「剛好一個」（配對頁就在它裡面），
    /// 或配對頁在主框架而且沒有新開任何 popup；多了、或 popup 不是 Pod 主框架開的＝不代填、顯示碼（crowdedSinceAnchor）。
    private var popupsSinceAnchor: Set<Int> = []
    private var crowdedSinceAnchor = false
    /// W183 R10 第四輪：錨點之後有 popup 不是 Pod 主框架開的（子框架、iframe 開的）＝這一輪不代填。
    private var nonMainOpenerSinceAnchor = false
    /// W183 R10：這個 attempt 的代填做到哪（一次；綁住的那一頁才做）。
    private enum AutoFill: Equatable { case notTried, filled(Date, attemptsLeft: Int), failed }
    private var autoFill: AutoFill = .notTried
    /// 按過建立、結果還沒查清楚的（帳號身分＋網址）：清單裡找到它之前不再按建立。W183 R12（主導 5）：也記進這台的檔（跨重開 App；只記雜湊）。
    private var pendingCreates: Set<String> = []
    private func hasPendingCreate(_ key: String) -> Bool {
        pendingCreates.contains(key) || dependencies.pendingCreateBook?.contains(HandsPendingCreates.digest(key)) == true
    }
    private func notePendingCreate(_ key: String) {
        pendingCreates.insert(key)
        dependencies.pendingCreateBook?.insert(HandsPendingCreates.digest(key))
    }
    private func forgetPendingCreate(_ key: String) {
        pendingCreates.remove(key)
        dependencies.pendingCreateBook?.remove(HandsPendingCreates.digest(key))
    }
    /// 找不到入口不等於不存在：只記本輪提示，不刪持久名稱／pending，也不是重建授權。
    private struct MissingCreateRecovery: Equatable {
        let key: String
        let generation: Int
    }
    @Published private var missingCreateRecovery: MissingCreateRecovery?
    /// 只有 needsManual 上明確按 retry 才給一次；同意卡續接可攜帶，送出建立或離開本輪即作廢。
    private var allowCreateAfterMissing: MissingCreateRecovery?
    /// 與重建授權分開：同一張 byName 重連表單的續接路由，絕不能因帶 ack 就變成 create。
    private struct NamedReconnectResume {
        let scope: MissingCreateRecovery
        let name: String
        let ack: HandsConnectorAck?

        func accepts(_ next: HandsConnectorAck?) -> Bool {
            guard let ack, let next, !next.form.isEmpty, !next.warning.isEmpty else { return false }
            return next.form == ack.form && next.warning == ack.warning && next.consent == ack.consent
                && (next.approved == ack.approved || next.approved == ack.consent?.print)
        }
    }
    private var namedReconnectResume: NamedReconnectResume?
    var retryWillRebuild: Bool {
        guard phase == .needsManual, let recovery = missingCreateRecovery,
              let offer = chosenOffer ?? offerValue else { return false }
        return recoveryMatches(recovery, identity: identityValue, url: offer.mcpURL)
    }
    private func recoveryMatches(_ recovery: MissingCreateRecovery, identity: String?, url: String) -> Bool {
        guard let identity else { return false }
        return recovery.key == identity + "|" + url && recovery.generation == dependencies.loginGeneration()
    }
    private var watching = false
    /// W183 R8c：這一輪要連哪一台（nil＝照舊：這台或主設備）、ChatGPT build 面板上選的範圍（卡片一開始用它）。
    private(set) var targetDeviceID: String?
    private var presetChoice: HandsScopeChoice?
    /// W183 R8 整合審查（GPT-6 中／Claude 高）：使用者在卡片上按「取消」、卡片收起來（這一輪結束；phase 回到「等你按」，不是 idle）的次數。
    /// ChatGPT build 的逐台［連線］看這個知道「這一台這一輪結束了」（不然會一直佔著「正在連」）。
    @Published private(set) var closedByUser = 0
    #if DEBUG
    /// 自測：每一步的紀錄（沒有碼）。
    private(set) var debugLog: [String] = []
    /// W183 R11 自測畫面證據：把進度點停在某一格（不跑流程）。
    func debugShowProgress(step: Int, phase: HandsConnectionPhase = .creatingConnector) {
        progressStep = step
        self.phase = phase
    }
    #endif

    private var loginWatch: AnyCancellable?
    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live()
        loginWatch = self.dependencies.loginChanges?.sink { [weak self] state in
            // Connect flows already react to Pod identity changes; this only stops an in-flight cleanup.
            if !HandsConnectEntry.signedIn(state), self?.cleaningConnectors == true { self?.invalidate("pod_logged_out") }
        }
    }

    static func hostAuthorization(host: String, identityTag: String, evidence: HandsConnectHostEvidence?, records: [HandsConnectAccountRecord]) -> Bool? {
        guard let evidence, evidence.fresh, evidence.serving, !evidence.clockSuspect else { return nil }
        if HandsConnectVerdict.proves(host: host, evidence: evidence, identityTag: identityTag, records: records) { return true }
        if let sampled = evidence.grantsVersion, let confirmed = records.last(where: { $0.host.lowercased() == host.lowercased() && $0.identityTag == identityTag })?.grantVersion,
           sampled < confirmed { return nil }
        return evidence.grantLevels != nil || evidence.confirmedGrants == 0 ? false : nil
    }
    func requireConnectorAuthorization(host: String, identityTags: [String]) {
        do { try dependencies.connectors?.requireAuthorization(device: host, identityTags: identityTags) }
        catch { log("connector authorization persistence failed") }
    }

    // MARK: - R6a 的入口

    /// R6a：設定流程走到「等使用者按［連線］」時叫（冪等；已經在連線中就不重來）。R6b：顯示私訊框的［連線］卡。
    func offer() {
        switch phase {
        case .waitingTap where card != nil, .waitingUser, .creatingConnector, .waitingPairing, .verifying:
            presenter.show()   // 已經在連線中：只把私訊框叫出來
            return
        default:
            break
        }
        guard !cancelling else { presenter.show(); return }
        // W183 R8 整合審查（Claude 中）：這個入口（設定流程、助理）連的是這台或主設備——清掉 ChatGPT build 上一輪指定的那台與面板上選的範圍。
        targetDeviceID = nil
        presetChoice = nil
        clearChoice()   // W183 R7a 審查：從外面開的新卡片從主機目前的設定開始
        startOffer(note: nil)
    }

    /// W183 R7a 審查：清掉卡上的選擇（下一張卡片從主機目前的設定開始）。
    private func clearChoice() {
        choice = nil
        chosenOffer = nil
        choiceBasis = nil
    }

    /// W183 R7a 審查：主機的設定還是做這個選擇時的那一份，或就是這次選的已經寫進去了（別的地方沒改過）。舊版主機（不收卡上選）＝不管。
    private func hostUnchanged(_ offer: HandsConnectOffer, confirmed: HandsConnectOffer?) -> Bool {
        guard offer.supportsChoice else { return true }
        guard let basis = choiceBasis, basis.host == offer.hostDeviceID else { return false }
        return offer.digest == basis.digest || offer.digest == confirmed?.digest
    }

    /// W183 R8c：ChatGPT build 的［連線］——連指定的那台（這台、主設備、或別台副設備：經主設備的信箱，碼只回到這台）。
    /// preset＝面板上選的等級與專案（卡片一開始就是它）。正在連別台（還沒結束）＝不換、只把私訊框叫出來（同一個 Pod 一次一個連接器）。
    /// W183 R8 整合審查（Claude 高）：回 true＝這一輪真的開始了；false＝沒開始（別的連線還在跑、正在取消）——叫的那邊不能當成在連這台。
    @discardableResult
    func offer(target: String?, preset: HandsScopeChoice? = nil) -> Bool {
        switch phase {
        case .waitingUser, .creatingConnector, .waitingPairing, .verifying:
            presenter.show()
            return false
        default:
            break
        }
        guard !cancelling else { presenter.show(); return false }
        clearChoice()   // W183 R8 整合：從外面開的新卡片照 R7a 審查清掉舊選擇（面板上選的走 preset，不沿用上一張卡）
        targetDeviceID = target?.lowercased()
        presetChoice = preset
        startOffer(note: nil)
        return true
    }

    /// 使用者或流程取消這次連線（關開關、換主機、Pod 帳號改變…）。R6b：清掉窗口、待確認交易、未兌換的授權碼，撤銷這個 attempt 的 grant。
    /// W183 R6b 審查：採用主機的回覆——成功先到＝phase 照實是「已連線」；取消結果不確定＝failed＋一句話。
    func cancel(reason: String) {
        let pending = takeAttempt()
        stop(reason: reason)
        card = nil
        offerShown = nil
        clearChoice()   // W183 R7a：下一次的卡片從主機目前的設定開始
        podVisible = false
        presenter.setCodeVisible(false)
        presenter.hide()
        phase = .idle
        problem = nil
        guard let pending else { return }
        let my = runID
        Task { @MainActor [weak self] in
            let outcome = await HandsConnectFlow.cancelOnHost(pending, reason: reason)
            guard let self else { return }
            self.log("cancel \(reason) -> \(outcome)")
            guard my == self.runID else { return }
            switch outcome {
            case .cancelled: break
            case .connected: self.phase = .connected; self.problem = nil
            case .unknown: self.phase = .failed; self.problem = HandsConnectFlow.cancelUnknownText
            }
        }
    }

    // MARK: - 私訊框卡片上的按鈕（只有畫面叫；AI 工具、遠端都叫不到）

    /// ［連線］：建立一次性的連線意圖，照順序做。manual＝手動（不代按 ChatGPT，App 只開窗口、複製網址、標出要按哪裡）。
    func connect(manual: Bool = false) {
        guard !cancelling else { return }
        guard let offer = offerValue else { return startOffer(note: nil) }
        guard case .confirm? = card else { return }   // 其他狀態走「再連一次」「手動」「繼續」（會先重新核對範圍）
        // W183 R7a：卡上選的範圍就是這個 attempt 的範圍快照（主機不收卡上選的範圍＝舊版，照主機目前的設定）。
        guard let chosen = Self.chosen(offer, choice) else {
            problem = "選的專案主機上已經沒有了；再選一次"
            return startOffer(note: problem)
        }
        startAttempt(offer: chosen, account: accountValue, identity: identityValue, manual: manual, ack: nil, keepPod: false)
    }

    // W183 R10：卡上選等級、專案（R7a 的 chooseLevel／toggleProject）拿掉——範圍照 ChatGPT build 的中央設定＋這台全部專案。
    // 下面的 choice／chosen 只剩相容：舊版主機（還給卡上選的清單）照它自己給的那一份送回去，新主機 supportsChoice＝false，這些都不作用。

    /// 照卡上選的範圍重拍（主機不收卡上選的範圍＝原樣）；選了清單外的＝nil。
    nonisolated static func chosen(_ offer: HandsConnectOffer, _ choice: HandsScopeChoice?) -> HandsConnectOffer? {
        guard offer.supportsChoice else { return offer }
        return offer.choosing(choice ?? offer.defaultChoice)
    }

    /// 卡片上的「取消」：這次不連（主機上的 attempt 取消，等主機回覆），卡片收回；TAP 那一列留在「等你在私訊框按一下」。
    func dismiss() {
        guard !cancelling, !disconnecting, !cleaningConnectors else { return }
        cleanupPreview = nil
        if phase == .connected {   // 已連線的卡：只收起來
            card = nil
            clearChoice()   // W183 R7a 審查
            presenter.hide()
            return
        }
        if case .disconnected? = card {   // W183 R11：「已斷線」卡：只收起來（沒有在跑的連線）
            card = nil
            problem = nil
            inferredEnd = nil   // W183 R11 最後一輪：收起來了＝不再看它回不回得來
            presenter.hide()
            return
        }
        let pending = takeAttempt()
        stop(reason: "user_cancelled")
        podVisible = false
        presenter.setCodeVisible(false)
        problem = nil
        guard let pending else { return closeAfterDismiss() }
        cancelling = true
        card = .working("正在取消這次連線…")
        let my = runID
        Task { @MainActor [weak self] in
            let outcome = await HandsConnectFlow.cancelOnHost(pending, reason: "user_cancelled")
            guard let self else { return }
            self.cancelling = false
            self.log("cancel user_cancelled -> \(outcome)")
            guard my == self.runID else { return }
            switch outcome {
            case .cancelled: self.closeAfterDismiss()
            case .connected: self.showLateSuccess()
            case .unknown:
                self.phase = .failed
                self.problem = HandsConnectFlow.cancelUnknownText
                self.card = .failed(HandsConnectFlow.cancelUnknownText)
            }
        }
    }

    // MARK: - W183 R11：斷線、重接、已連線卡

    /// W183 R11（使用者 09-30「測試接上跟取消」；主導：「一顆按鈕就斷乾淨（撤銷授權、ChatGPT 那邊再叫就被拒）；斷線後可以再按［連線］重接」）：
    /// 已連線卡上的［斷線］（只有畫面叫得到；AI 工具、遠端都叫不到）。撤銷那台主機上全部的 ChatGPT 授權（token、授權碼、窗口一起作廢，
    /// 跑著的沙盒工作停下）——ChatGPT 之後再叫＝被拒。斷好＝「已斷線」卡＋［連線］（重接走同一張確認卡）；沒斷成＝已連線卡上一句話，
    /// ［斷線］照樣可以再按（不假裝斷了）。
    func disconnect() {
        guard !cancelling, !disconnecting, !cleaningConnectors, card?.isConnectedResult == true else { return }
        cleanupPreview = nil
        let hosts = connectedHosts
        guard !hosts.isEmpty else {
            problem = Self.disconnectUnavailable
            return
        }
        endRun()   // 沒有在跑的連線；舊的等待一律不再動卡片
        let my = runID
        let level = connectedLevel
        let previous = card   // 沒斷成＝放回按之前那一張（已連線、或狀態未確認：不因為沒斷成就又說已連線）
        disconnecting = true
        problem = nil
        card = .working(Self.disconnectingText)
        log("disconnect hosts=\(hosts.count)")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcomes = await self.dependencies.disconnect(hosts)
            self.disconnecting = false
            guard my == self.runID else { return }
            self.adoptDisconnect(hosts: hosts, outcomes: outcomes, level: level, previous: previous)
        }
    }

    /// W183 R11（GPT-6 R11 審查 6）：逐台採用［斷線］的結果——斷了的（撤銷了；存沒存成另外說）馬上不算連著（紀錄拿掉、入口跟著改）；
    /// 沒做成、不知道的留著（卡片照實說哪一台怎樣），再按［斷線］只重試這幾台。
    private func adoptDisconnect(hosts: [String], outcomes: [String: HandsDisconnectOutcome], level: Int?, previous: HandsConnectCard?) {
        let cut = hosts.filter { outcomes[$0.lowercased()]?.cut == true }
        let remaining = hosts.filter { outcomes[$0.lowercased()]?.cut != true }
        var connectorNote: String?
        if let registry = dependencies.connectors {
            for host in cut {
                var tags = dependencies.accounts?.records().filter { HandsHostAuthority.same($0.host, host) }.map(\.identityTag) ?? []
                if let identity = identityValue ?? intent?.podIdentity { tags.append(HandsConnectAccounts.identityTag(identity)) }
                do { try registry.requireAuthorization(device: host, identityTags: tags) }
                catch { connectorNote = "已斷線，但連接器的重接紀錄無法保存；再連時請確認原本那一份。" }
            }
        }
        dependencies.accounts?.forget(hosts: cut)
        var notes = hosts.compactMap { outcomes[$0.lowercased()]?.text ?? (outcomes[$0.lowercased()] == nil ? Self.disconnectUnavailable : nil) }
        if let connectorNote { notes.append(connectorNote) }
        log("disconnect cut=\(cut.count) remaining=\(remaining.count)")
        if remaining.isEmpty {
            connectedHosts = []
            disconnectedHosts = hosts
            phase = .idle
            problem = notes.isEmpty ? nil : notes.joined(separator: "；")   // 撤銷了但沒存成：照實說（之後要重新配對）
            card = .disconnected(Self.disconnectedText)
            presenter.show()
            return
        }
        connectedHosts = remaining
        if !cut.isEmpty { disconnectedHosts = cut }
        phase = .connected
        problem = notes.joined(separator: "；")
        if cut.isEmpty, let previous, previous.isConnectedResult {
            card = previous
        } else {
            card = .connected(cut.isEmpty ? Self.connectedText(levelOrNil: level) : Self.partialDisconnectText(cut: cut.count, left: remaining.count))
        }
    }

    @Published private(set) var cleanupPreview: HandsConnectorCleanup.Preview?
    @Published private(set) var cleaningConnectors = false

    /// Explicit user action; looking at duplicates cannot delete anything.
    func prepareConnectorCleanup() {
        guard !cleaningConnectors, !cancelling, !disconnecting, card?.isConnectedResult == true,
              let registry = dependencies.connectors, !connectedHosts.isEmpty else { return }
        let hosts = connectedHosts, my = runID
        cleaningConnectors = true
        cleanupPreview = nil; problem = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if my == self.runID { self.cleaningConnectors = false } }
            let generation = self.dependencies.loginGeneration()
            guard let identity = await self.pod.identity(), await self.pod.acquireExclusive(timeout: self.dependencies.timeouts.exclusive) else {
                if my == self.runID { self.problem = "目前無法查看原連接器；等 ChatGPT 空下來再整理。" }; return
            }
            guard my == self.runID else { if !self.holdsPod { self.pod.releaseExclusive() }; return }; self.holdsPod = true; self.startWatching()
            defer { if my == self.runID { self.releasePod(); self.stopWatching() } }
            var previews: [HandsConnectorCleanup.Preview] = [], notes: [String] = []
            for host in hosts {
                let resolved = self.dependencies.linkFor?(host) ?? self.dependencies.link()
                guard let offer = try? await resolved.link?.offer(), HandsHostAuthority.same(offer.hostDeviceID, host) else {
                    notes.append(self.dependencies.deviceName(host) + "：" + (resolved.problem ?? "主機或網址未確認") + "，未整理。"); continue
                }
                let scan = await self.pod.scan(url: offer.mcpURL)
                for match in scan.matches where match.connected == nil { self.log("cleanup skip \(match.name): 帳號區／Connect 按鈕未確認") }
                self.log("cleanup scan listKnown=\(scan.listKnown) step=\(scan.failure ?? (scan.listKnown ? "完整清單已讀取" : "Pod 未回報卡點"))")
                guard !Task.isCancelled, generation == self.dependencies.loginGeneration(), await self.pod.identity() == identity, my == self.runID else {
                    if my == self.runID { self.problem = "ChatGPT 帳號已改變；整理已停止。" }; return
                }
                let key = HandsConnectorRegistry.key(device: host, identity: identity, mcpURL: offer.mcpURL)
                if registry.record(key) == nil {
                    let active = scan.matches.filter { $0.connected == true && $0.auth == "oauth" && $0.id != nil && $0.serverURL == offer.mcpURL
                        && HandsConnectorRegistry.isDeviceName($0.name, base: HandsBuildConfig.connectorName(offer.hostName)) }
                    guard scan.listKnown, active.count == 1 else { notes.append(offer.hostName + "：無法唯一確認目前連著的那份，未整理。"); continue }
                    do { try registry.remember(active[0], key: key) }
                    catch { notes.append(offer.hostName + "：編號無法保存，未整理。"); continue }
                }
                guard let preview = HandsConnectorCleanup(registry: registry).preview(scan: scan, key: key, identity: identity,
                    generation: generation, base: HandsBuildConfig.connectorName(offer.hostName), url: offer.mcpURL) else {
                    notes.append(offer.hostName + "：清單或原編號未確認，未整理。"); continue
                }
                if preview.removing.isEmpty { continue }
                let connected = scan.matches.first { $0.id == preview.keeping.id }?.connected == true ? true : await self.pod.inspect(preview.keeping, url: offer.mcpURL) == .connected
                if connected { previews.append(preview) } else { notes.append(offer.hostName + "：目前授權未確認，未整理。") }
            }
            guard !Task.isCancelled, generation == self.dependencies.loginGeneration(), await self.pod.identity() == identity, my == self.runID else { return }
            if var first = previews.first { first.devices = Array(previews.dropFirst()); self.cleanupPreview = first }
            self.problem = notes.isEmpty ? (previews.isEmpty ? "沒有可整理的同網址重複外掛。" : nil) : notes.joined(separator: "；")
        }
    }
    func cancelConnectorCleanup() { cleanupPreview = nil }
    func confirmConnectorCleanup() {
        guard !cleaningConnectors, !disconnecting, !cancelling, let preview = cleanupPreview, let registry = dependencies.connectors else { return }
        let previews = [preview] + preview.devices, notes = problem, my = runID
        cleanupPreview = nil // a confirmation can only be consumed once
        cleaningConnectors = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if my == self.runID { self.cleaningConnectors = false } }
            guard await self.pod.acquireExclusive(timeout: self.dependencies.timeouts.exclusive) else { if my == self.runID { self.problem = "ChatGPT 忙碌；沒有刪除。" }; return }
            guard my == self.runID else { if !self.holdsPod { self.pod.releaseExclusive() }; return }; self.holdsPod = true; self.startWatching()
            defer { if my == self.runID { self.releasePod(); self.stopWatching() } }
            guard let identity = await self.pod.identity(), my == self.runID else { if my == self.runID { self.problem = "ChatGPT 帳號未確認；沒有刪除。" }; return }
            do {
                var count = 0
                for item in previews { count += try await HandsConnectorCleanup(registry: registry).execute(item, pod: self.pod,
                    identity: identity, generation: self.dependencies.loginGeneration(), currentGeneration: self.dependencies.loginGeneration) }; guard my == self.runID else { return }
                self.problem = "已整理 \(count)／\(previews.reduce(0) { $0 + $1.removing.count }) 份重複外掛；每台保留目前連著的那一份。" + (notes.map { "；" + $0 } ?? "")
            } catch { if my == self.runID { self.problem = "無法保存還原紀錄，或帳號／連線已改變；整理已停止。" } }
        }
    }

    /// W183 R11：「已斷線」卡上的［連線］：重接剛斷的那台（同一張確認卡：按連線＝同意那一行照樣在）。
    func reconnect() {
        guard !cancelling, !disconnecting, case .disconnected? = card else { return }
        let hosts = disconnectedHosts
        card = nil
        if hosts.count == 1, let only = hosts.first {
            _ = offer(target: only)
        } else {
            offer()
        }
    }

    /// W183 R11：私訊框 ChatGPT 上方的「已連線」小膠囊按了＝拿出已連線卡（有［斷線］）。正在連、正在取消或斷線＝只把私訊框叫出來。
    /// hosts＝目前這個帳號已連上的那幾台（入口核對過的）；level＝ChatGPT 實際拿到的（nil＝能力未確認）。
    func showConnected(hosts: [String], level: Int?) {
        switch phase {
        case .waitingUser, .creatingConnector, .waitingPairing, .verifying:
            presenter.show()
            return
        default:
            break
        }
        guard !cancelling, !disconnecting, !hosts.isEmpty else { return }
        inferredEnd = nil   // W183 R11 最後一輪
        connectedHosts = hosts.map { $0.lowercased() }
        connectedLevel = level.map { min(max($0, 0), HandsSettings.maxLevel) }
        phase = .connected
        problem = nil
        card = .connected(Self.connectedText(levelOrNil: connectedLevel))
        presenter.show()
    }

    /// W183 R11（GPT-6 R11 審查 3，中：「『剛連上』沒有期限，會永久蓋過撤銷與離線回報」）：入口從新的回報看出已連線卡上的那幾台不在了
    ///（在別處撤銷、那台停了或暫停）：已連線卡跟著改——全部不在＝「已斷線」卡（照實說原因）；還有別台＝留著那幾台。
    /// 等級變了（中央收窄）＝卡上的字跟著改。只動已連線卡（連線中、斷線中、別的卡片不動）。
    /// W183 R11 第二輪（GPT-6 R11b 審查 4，中：「90 秒到期後，結果卡還是寫已連線：Codex、記憶」）：unconfirmed＝卡上那幾台裡核對不了的
    ///（剛連上的期限過了、回報太舊）——有一台核對不了＝卡片改成「連線狀態未確認」、拿掉能力；［斷線］留著。之後核對得到＝回到已連線卡。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：connected＝這次核對得到的那幾台。推斷「斷了」之後，新的回報證明卡上的那幾台都還連著＝
    /// 「已斷線」卡回到已連線。
    func connectionChanged(ended: [String], ending: HandsConnectVerdict.Ending?, level: Int?, unconfirmed: [String] = [], connected: [String] = []) {
        guard !cancelling, !disconnecting else { return }
        if ending == .revoked, let identity = identityValue {
            for host in ended where dependencies.hostAuthorization(host, identity) == false { requireConnectorAuthorization(host: host, identityTags: [HandsConnectAccounts.identityTag(identity)]) }
        }
        if let inferred = inferredEnd, phase == .idle, case .disconnected(let text)? = card,
           text == Self.endedElsewhereText || text == Self.hostStoppedText {
            let back = inferred.hosts.allSatisfy { host in connected.contains { HandsHostAuthority.same($0, host) } }
            guard back else { return }
            log("connection recovered")
            inferredEnd = nil
            connectedHosts = inferred.hosts
            disconnectedHosts = []
            connectedLevel = level ?? inferred.level
            phase = .connected
            card = .connected(Self.connectedText(levelOrNil: connectedLevel))
            return
        }
        guard phase == .connected, card?.isConnectedResult == true, !connectedHosts.isEmpty else { return }
        let gone = connectedHosts.filter { host in ended.contains { HandsHostAuthority.same($0, host) } }
        if gone.count == connectedHosts.count {
            log("connection ended \(ending?.rawValue ?? "")")
            // 紀錄不在這裡拿掉（只有［斷線］撤銷好了才拿）：判定錯了也救得回來；真的不在了，之後的回報照樣沒有它。
            inferredEnd = (gone, connectedLevel)
            disconnectedHosts = gone
            connectedHosts = []
            phase = .idle
            problem = nil
            card = .disconnected(ending == .stopped ? Self.hostStoppedText : Self.endedElsewhereText)
            return
        }
        if !gone.isEmpty { connectedHosts.removeAll { host in gone.contains(host) } }
        let unsure = connectedHosts.contains { host in unconfirmed.contains { HandsHostAuthority.same($0, host) } }
        if unsure {
            let next = HandsConnectCard.unconfirmed(Self.unconfirmedStatusText)
            if card != next { log("connection unconfirmed"); card = next }
            return
        }
        let next = HandsConnectCard.connected(Self.connectedText(levelOrNil: level))
        guard next != card || level != connectedLevel else { return }
        connectedLevel = level
        card = next
    }

    /// 「再連一次」：重新拿卡片內容；跟使用者上次確認的一樣就直接開始（這一下就是他按的），不一樣就讓他再看一次卡片。
    func retry(manual: Bool = false) {
        guard !cancelling, !cleaningConnectors else { return }
        let confirmed = chosenOffer ?? offerValue, account = accountValue, identity = identityValue, picked = choice
        let rebuild = !manual && retryWillRebuild ? missingCreateRecovery : nil
        stop(reason: "retry")
        let my = runID
        phase = .creatingConnector
        problem = nil
        card = .loading("重新確認主機與範圍…")
        task = Task { [weak self] in
            guard let self else { return }
            guard let loaded = await self.loadOffer(my) else { return }
            // W183 R7a：照上次卡上選的範圍重拍，跟上次確認的一樣才直接開始。
            // W183 R7a 審查：主機的設定被別的地方改過＝不直接開始（不把主機改回舊的），讓他再看一次卡片。
            if let confirmed, let again = Self.chosen(loaded.offer, picked), again.digest == confirmed.digest,
               again.setupEpoch == confirmed.setupEpoch, self.hostUnchanged(loaded.offer, confirmed: confirmed),
               loaded.account == account, identity != nil, loaded.identity == identity {
                self.startAttempt(offer: again, account: loaded.account, identity: loaded.identity, manual: manual, ack: nil, keepPod: false, rebuild: rebuild)
            } else {
                self.showConfirm(loaded.offer, account: loaded.account, note: "主機的設定或 Pod 帳號變了；再看一次再按")
            }
        }
    }

    /// 「繼續」：使用者在 Pod 那一頁處理完警語（或開發者模式）。這一下＝重建意圖（新的 attempt，範圍與帳號要跟卡片一樣）；
    /// 帶回他看過的那一張表單與警語（換了就再交給他看）。
    func continueAfterUser() { continueAfterUser(ack: pendingAck) }

    private func continueAfterUser(ack: HandsConnectorAck?) {
        // W183 R12：「說明改了」的卡（同意並繼續）也從這裡接著做。
        let waiting: Bool = { switch card { case .waitingUser?, .consent?: return true; default: return false } }()
        guard waiting, let confirmed = chosenOffer ?? offerValue else { return }
        let account = accountValue, identity = identityValue, picked = choice
        let rebuild = allowCreateAfterMissing
        let named = namedReconnectResume
        runID += 1
        task?.cancel()
        let my = runID
        card = .working("重新確認主機與範圍…")
        task = Task { [weak self] in
            guard let self else { return }
            guard let loaded = await self.loadOffer(my) else { return }
            guard let again = Self.chosen(loaded.offer, picked), again.digest == confirmed.digest, again.setupEpoch == confirmed.setupEpoch,
                  self.hostUnchanged(loaded.offer, confirmed: confirmed),   // W183 R7a 審查
                  loaded.account == account, identity != nil, loaded.identity == identity else {
                return self.showConfirm(loaded.offer, account: loaded.account, note: "主機的設定或 Pod 帳號變了；再看一次再按")
            }
            // 使用者就在 Pod 那一頁處理完：不放掉 Pod（放掉會把表單關掉），直接用新的 attempt 接著做。
            self.startAttempt(offer: again, account: loaded.account, identity: loaded.identity, manual: false, ack: ack, keepPod: true,
                              rebuild: rebuild, named: named)
        }
    }

    /// 作廢（鎖螢幕、Pod 關掉或登出、帳號切換、主機或範圍改變）：取消這個 attempt，回到「等你在私訊框按一下」。
    func invalidate(_ reason: String) {
        missingCreateRecovery = nil
        allowCreateAfterMissing = nil
        namedReconnectResume = nil
        if cleaningConnectors {
            endRun(); stopWatching()
            problem = "ChatGPT 帳號或登入狀態已改變；整理已停止。"
            return
        }
        guard intent != nil || [.waitingPairing, .creatingConnector, .verifying, .waitingUser].contains(phase) else { return }
        log("invalidate \(reason)")
        let pending = takeAttempt()
        stop(reason: reason)
        podVisible = false
        presenter.setCodeVisible(false)
        let note = Self.invalidationText(reason)
        guard let pending else { return startOffer(note: note) }
        cancelling = true
        card = .working(note + "（正在通知主機…）")
        let my = runID
        Task { @MainActor [weak self] in
            let outcome = await HandsConnectFlow.cancelOnHost(pending, reason: reason)
            guard let self else { return }
            self.cancelling = false
            self.log("cancel \(reason) -> \(outcome)")
            guard my == self.runID else { return }
            switch outcome {
            case .cancelled: self.startOffer(note: note)
            case .connected: self.showLateSuccess()
            case .unknown:
                self.phase = .failed
                self.problem = HandsConnectFlow.cancelUnknownText
                self.card = .failed(note + "。" + HandsConnectFlow.cancelUnknownText)
            }
        }
    }

    // MARK: - 流程

    private func startOffer(note: String?) {
        stop(reason: "reoffer")
        let my = runID
        phase = .waitingTap
        problem = nil
        podVisible = false
        card = .loading("讀取主機與 ChatGPT…")
        guard presenter.isAvailable else {
            phase = .failed
            problem = "私訊鈕關著：到設定打開私訊鈕，再回來按「連線」"
            card = nil
            return
        }
        presenter.show()
        task = Task { [weak self] in
            guard let self else { return }
            guard let loaded = await self.loadOffer(my) else { return }
            self.showConfirm(loaded.offer, account: loaded.account, note: note)
        }
    }

    /// 拿主機的卡片內容、Pod 目前帳號與它的比對身分。失敗就把卡片換成錯誤（回 nil）。
    private func loadOffer(_ my: Int) async -> (offer: HandsConnectOffer, account: String?, identity: String?)? {
        let generation = dependencies.loginGeneration()   // W183 R11 最後一輪：讀帳號之前的登入世代（晚到的結果帶著它）
        let resolved = targetDeviceID.flatMap { target in dependencies.linkFor?(target) } ?? dependencies.link()   // W183 R8c
        guard let link = resolved.link else { fail(resolved.problem ?? "找不到主機", my: my); return nil }
        self.link = link
        let offer: HandsConnectOffer
        do { offer = try await link.offer() } catch {
            guard my == runID else { return nil }
            fail((error as? HandsConnectLinkError)?.plain ?? "連不到主機", my: my)
            return nil
        }
        guard my == runID else { return nil }
        attachPod()
        let readiness = await pod.prepare()
        guard my == runID else { return nil }
        let account: String?
        switch readiness {
        case .ready(let observed): account = observed
        case .needsLogin: account = nil
        case .unavailable(let reason): fail("ChatGPT 的 Pod 起不來（\(reason)）", my: my); return nil
        }
        let identity = account == nil ? nil : await pod.identity()
        guard my == runID else { return nil }
        offerValue = offer
        accountValue = account
        identityValue = identity
        // W183 R11（GPT-6 R11 審查 4）：入口照這個核對目前帳號；W183 R11 最後一輪：帶讀之前記下的登入世代。
        podIdentity = HandsConnectIdentityStamp(tag: identity.map { HandsConnectAccounts.identityTag($0) }, generation: generation)
        return (offer, account, identity)
    }

    private func showConfirm(_ offer: HandsConnectOffer, account: String?, note: String?) {
        missingCreateRecovery = nil
        allowCreateAfterMissing = nil
        namedReconnectResume = nil
        cancelAttemptOnHost(reason: "reconfirm")   // 還沒送到主機的意圖：丟掉
        releasePod()
        // W183 R7a：卡上的選擇留著（同一台主機、主機的設定沒被別的地方改過、選的專案還在清單裡）；否則從主機目前的設定開始。
        // W183 R7a 審查（Claude）：比的是做選擇時記下的主機與 digest（choiceBasis），不是 offerValue（loadOffer 已經換成新的了）。
        // W183 R8c：ChatGPT build 面板上選的（preset）優先（只留主機清單裡的；主機那端照樣核對上限）。
        // W183 R8 整合：preset 也是「對著主機這一份設定做的選擇」——記下 choiceBasis（R7a 審查的「主機被別處改過就不沿用」照樣管它）。
        if offer.supportsChoice {
            let selectable = Set(offer.projectChoices.map(\.id))
            let preset = presetChoice.map { HandsScopeChoice(level: $0.level, projectIDs: $0.projectIDs.intersection(selectable)) }
            presetChoice = nil
            var kept: HandsScopeChoice?
            if hostUnchanged(offer, confirmed: chosenOffer), let current = choice {
                kept = HandsScopeChoice(level: current.level, projectIDs: current.projectIDs.intersection(selectable))
            }
            if let preset {
                choice = preset
                chosenOffer = nil
                choiceBasis = (offer.hostDeviceID, offer.digest)
            } else if let kept {
                choice = kept
            } else {
                choice = offer.defaultChoice
                chosenOffer = nil
                choiceBasis = (offer.hostDeviceID, offer.digest)
            }
        } else {
            choice = nil
            choiceBasis = nil
            presetChoice = nil   // W183 R8 整合：舊版主機不收卡上選——面板的 preset 也不留到下一張
        }
        offerValue = offer
        accountValue = account
        offerShown = offer
        phase = .waitingTap
        problem = note
        podVisible = false
        attemptSerial = 0   // W183 R12：新的一張確認卡＝重試次數從頭算
        card = .confirm(offer, account: account)
        presenter.show()
    }

    private func startAttempt(offer: HandsConnectOffer, account: String?, identity: String?, manual: Bool, ack: HandsConnectorAck?, keepPod: Bool,
                              rebuild: MissingCreateRecovery? = nil, named: NamedReconnectResume? = nil) {
        stop(reason: "restart", keepPod: keepPod)
        if let named {
            guard !manual, keepPod, rebuild == nil, named.accepts(ack),
                  recoveryMatches(named.scope, identity: identity, url: offer.mcpURL) else {
                return showConfirm(offer, account: account, note: "重連的表單或登入狀態已改變；請重新確認，不建立新的外掛")
            }
            namedReconnectResume = named
        }
        if !manual, let rebuild {
            guard recoveryMatches(rebuild, identity: identity, url: offer.mcpURL) else {
                return showConfirm(offer, account: account, note: "ChatGPT 的登入狀態或網址已改變；請重新確認外掛是否存在")
            }
            allowCreateAfterMissing = rebuild
        }
        let my = runID
        guard let owner = dependencies.localDeviceID(), !owner.isEmpty else { return fail("這台還沒有設備身分", my: my) }
        let created = HandsConnectIntent(attemptID: UUID(), setupEpoch: offer.setupEpoch, ownerDeviceID: owner, hostDeviceID: offer.hostDeviceID,
                                         mcpURL: offer.mcpURL, scope: offer.scope, podAccount: account,
                                         expiresAt: dependencies.now().addingTimeInterval(HandsAuth.windowLifetime), podIdentity: identity)
        intent = created
        attemptSerial += 1
        dependencies.connectLog?.begin(attempt: created.attemptID)   // W183 R12：紀錄的每一行帶這次嘗試的代號
        offerShown = offer
        chosenOffer = offer   // W183 R7a：這個 attempt 的範圍快照（卡上選的）
        // W183 R11（GPT-6 R11 審查 2）：按下去的那一刻卡上沒有帳號（本來就沒登入）＝登入之後才可以自動接著連；進度卡顯示這次用的帳號。
        loginContinueAllowed = account == nil
        attemptAccount = account
        attemptGeneration = dependencies.loginGeneration()   // W183 R11 最後一輪
        inferredEnd = nil
        phase = .creatingConnector
        problem = nil
        progressStep = 0   // W183 R11：進度點從第一格開始
        progressHint = nil
        card = .working(manual ? "準備手動連線…" : "在 ChatGPT 裡準備連接器…")
        podVisible = true
        presenter.setPodVisible(true)
        presenter.show()
        startWatching()
        log("attempt #\(attemptSerial) manual=\(manual) ack=\(ack != nil) consent_approved=\(ack?.approved != nil)")
        task = Task { [weak self] in await self?.run(created, offer: offer, manual: manual, ack: ack, my: my) }
    }

    private func run(_ intent: HandsConnectIntent, offer: HandsConnectOffer, manual: Bool, ack: HandsConnectorAck?, my: Int) async {
        guard let link else { return fail("找不到主機", my: my) }
        // 1. Pod：登入、帳號（看得到的與比對身分）跟卡片上的一樣。
        let readiness = await pod.prepare()
        guard my == runID else { return }
        switch readiness {
        case .needsLogin:
            // W183 R11（GPT-6 R11 審查 2，高）：卡上有帳號（A）的，中途登出＝回到確認卡（登入之後要再看一次是哪個帳號）。
            guard loginContinueAllowed else { return loggedOut(offer, my: my) }
            return waitForLogin(my)
        case .unavailable(let reason):
            return fail("ChatGPT 的 Pod 起不來（\(reason)）", my: my)
        case .ready(let account):
            if account != intent.podAccount {
                return showConfirm(offer, account: account, note: "Pod 目前的 ChatGPT 帳號跟卡片上的不一樣；看一下再按")
            }
        }
        let identityNow = await pod.identity()
        guard my == runID else { return }
        guard let identityNow else { return fail("讀不到 Pod 的 ChatGPT 帳號（網頁沒有回）；按「再連一次」", my: my) }
        guard identityNow == intent.podIdentity else {
            identityValue = identityNow
            return showConfirm(offer, account: accountValue, note: "Pod 目前的 ChatGPT 帳號跟卡片上的不一樣；看一下再按")
        }
        // 2. 獨占 Pod（聊天、語音中不硬換頁，等空檔）。
        // W183 R9 審查（GPT-6 #9）：原生外掛頁「新增 ▾」的對話框開著也要等（雙向）。
        card = .working("等 ChatGPT 空下來（回完這一則、結束語音，或關掉 ChatGPT Dev 分頁的「新增」對話框）再開始…")
        progressHint = Self.busyHint   // W183 R11：進度點下面只留這一句（要你讓 ChatGPT 空下來）
        guard await pod.acquireExclusive(timeout: dependencies.timeouts.exclusive) else {
            guard my == runID else { return }
            return fail("ChatGPT 尚未能準備好外掛頁（仍在回答、語音、開著「新增」對話框、ChatGPT Space 正在用這一頁，或頁面載入失敗）；等它結束、收起 Space 或載入完成，再按「再連一次」", my: my)
        }
        guard my == runID else {
            if !holdsPod { pod.releaseExclusive() }   // 已經停了、也沒有新的一輪接手：放掉（帶回首頁）
            return
        }
        holdsPod = true
        progressHint = nil
        let createKey = identityNow + "|" + intent.mcpURL
        if let rebuild = allowCreateAfterMissing, !recoveryMatches(rebuild, identity: identityNow, url: intent.mcpURL) {
            return showConfirm(offer, account: accountValue, note: "ChatGPT 的登入狀態已改變；請重新確認外掛是否存在")
        }
        attemptCreateKey = createKey
        reconnectByName = namedReconnectResume != nil
        nameInUse = namedReconnectResume?.name
        selectedConnector = nil
        let registryKey = HandsConnectorRegistry.key(device: offer.hostDeviceID, identity: identityNow, mcpURL: intent.mcpURL)
        let remembered = dependencies.connectors?.record(registryKey)
        let hostAuthorized = dependencies.hostAuthorization(offer.hostDeviceID, identityNow)
        if hostAuthorized == false { requireConnectorAuthorization(host: offer.hostDeviceID, identityTags: [HandsConnectAccounts.identityTag(identityNow)]) }
        // 3. 先讀既有連接器（這時窗口還關著）。
        var existing: HandsConnectorScan.Match?
        if let remembered {
            existing = remembered.connector
            selectedConnector = remembered.connector
            nameInUse = remembered.connector.name
            // Never read a list or create when this installation already knows the ID.
            let inspected = await pod.inspect(remembered.connector, url: intent.mcpURL)
            let authorization = remembered.needsAuthorization || hostAuthorized == false ? HandsConnectorAuthorization.needsReconnect : inspected
            guard my == runID else { return }
            if authorization == .connected {
                intentAlreadyAuthorized(offer)
                return
            }
            guard authorization == .needsReconnect else {
                return needsManual("ChatGPT 原本的「\(remembered.connector.name)」授權狀態未確認；等關口恢復，或到設定 › Apps › 自己建立的查看這一份。不建立第二份。", my: my)
            }
        } else if !manual {
            card = .working("讀 ChatGPT 的外掛清單…")
            var scan = await pod.scan(url: intent.mcpURL)
            guard my == runID else { return }
            log("scan listKnown=\(scan.listKnown) devMode=\(String(describing: scan.devMode)) matches=\(scan.matches.count) step=\(scan.failure ?? (scan.listKnown ? "完整清單已讀取" : "Pod 未回報卡點"))")
            if !scan.loggedIn { return loginContinueAllowed ? waitForLogin(my) : loggedOut(offer, my: my) }   // W183 R11（GPT-6 R11 審查 2）
            if scan.devMode == false { return waitForDeveloperMode(my) }
            if let failure = scan.failure { return needsManual("讀不到 ChatGPT 的外掛清單（\(failure)）", my: my) }
            guard scan.listKnown else { return needsManual("讀不到完整的 ChatGPT 外掛清單，不確定有沒有建過；改用手動比較安全", my: my) }
            if scan.conflictingNames.contains(connectorNameInUse(offer)) {
                _ = await pod.highlight(url: intent.mcpURL, name: connectorNameInUse(offer))
                guard my == runID else { return }
                return needsManual("ChatGPT 的同名「\(connectorNameInUse(offer))」指向不同伺服器；到設定 › Apps › 自己建立的查看，不刪除、不另建。", my: my)
            }
            let active = scan.matches.filter { ($0.connected == true || $0.needsReconnect == true) && $0.auth == "oauth" && HandsConnectorRegistry.isDeviceName($0.name, base: connectorNameInUse(offer)) }
            if scan.matches.count > 1 && active.count == 1 { scan.matches = active }
            if scan.matches.count > 1 { return needsManual("ChatGPT 裡指向這個網址的外掛不只一個；先刪到剩一個，或改用手動", my: my) }
            if let match = scan.matches.first {
                guard match.auth == "oauth" else {
                    return needsManual("ChatGPT 裡已經有同網址、但不是 OAuth 的外掛；先刪掉它再連（不改成免驗證）", my: my)
                }
                guard match.id != nil else { return needsManual("ChatGPT 裡已經有指向這個網址的外掛，但認不出它的編號；改用手動比較安全", my: my) }
                existing = match
                selectedConnector = match
                nameInUse = match.name
                allowCreateAfterMissing = nil   // 清單找到同網址永遠先沿用，不能把重建授權帶去下一輪。
                forgetPendingCreate(createKey)
            } else if ack == nil, allowCreateAfterMissing == nil, hasPendingCreate(createKey) || nameInUse != nil {   // 同意續接或本輪明確重建不回 byName
                // W183 R12（主導 5）：重開 App 之後也記得上次按過建立——清單裡找不到它：
                // W183 R12（.037 實機：建成、還沒授權的「TATWO（Mac mini）2」清單讀不到）：先用本機記下的名字在外掛頁找它、打開、核完整網址
                // 與 OAuth 才按它的 Connect（byName）；找不到入口只提示，使用者確認不存在、明確重試才給本輪一次重建。
                reconnectByName = true
            }
            // 開窗口之前再看一次帳號（讀清單的時候可能換過）。
            let again = await pod.identity()
            guard my == runID else { return }
            guard let again else { return fail("讀不到 Pod 的 ChatGPT 帳號（網頁沒有回）；按「再連一次」", my: my) }
            guard again == intent.podIdentity else { return refuse("Pod 的 ChatGPT 帳號在連線中途換了；已停止", my: my) }
        }
        if remembered == nil, let existing, existing.connected == true, existing.auth == "oauth", existing.serverURL == intent.mcpURL,
           HandsConnectorRegistry.isDeviceName(existing.name, base: HandsBuildConfig.connectorName(offer.hostName)), hostAuthorized == true,
           attemptGeneration == dependencies.loginGeneration(), let registry = dependencies.connectors {
            do { try registry.remember(existing, key: registryKey) }
            catch { return needsManual("原連接器編號無法保存；沒有另建外掛。", my: my) }
            intentAlreadyAuthorized(offer)
            return
        }
        // 4. 主機開窗口（綁這個 attempt、範圍用卡片上的快照）。送出前就記成「主機可能收了」：這時停下來一定會送取消，晚到的 begin 主機不開窗口。
        card = .working("請主機開 10 分鐘的配對窗口…")
        progressStep = 1   // W183 R11：第二格（建外掛）
        let request = HandsConnectRequest(intent: intent, scopeDigest: offer.digest, choice: offer.scopeChoice)   // W183 R7a：卡上選的範圍
        begun = true
        do {
            let status = try await link.begin(request)
            guard my == runID else { return }   // 已經停了：stop() 送過取消
            guard !status.state.isTerminal else { return await finishTerminal(status, my: my) }
        } catch let error as HandsConnectLinkError {
            guard my == runID else { return }
            switch error {
            case .refused(.staleEpoch), .refused(.scopeChanged), .refused(.scopeInvalid):   // W183 R7a：選的專案主機不收＝回到卡片
                begun = false
                return startOffer(note: error.plain)
            case .unknown:
                // 送出結果未知：先查，不重送。
                guard let status = try? await link.status(attemptID: request.attemptID, evidence: nil) else {
                    guard my == runID else { return }
                    return fail("連不到主機，不確定窗口開了沒；已停止（主機 10 分鐘後自己關）", my: my)
                }
                guard my == runID else { return }
                guard !status.state.isTerminal else { return await finishTerminal(status, my: my) }
            default:
                begun = false
                return fail(error.plain, my: my)
            }
        } catch {
            guard my == runID else { return }
            return fail("連不到主機", my: my)
        }
        // 5. Pod 建（或重新連線）連接器；手動＝網址已複製、標出要按哪裡。
        if manual {
            manualAttempt = true
            dependencies.copy(intent.mcpURL)
            awaitingSince = dependencies.now()
            _ = await pod.highlight(url: intent.mcpURL, name: selectedConnector != nil || hasPendingCreate(createKey) ? connectorNameInUse(offer) : nil)
            guard my == runID else { return }
            phase = .creatingConnector
            let scan = selectedConnector != nil || hasPendingCreate(createKey) ? nil : await pod.scan(url: intent.mcpURL)
            guard my == runID else { return }
            card = .manual(url: intent.mcpURL, steps: Self.manualSteps(intent.mcpURL, name: connectorNameInUse(offer), existing: selectedConnector != nil || hasPendingCreate(createKey), scan: scan))
            return await awaitAuthorize(intent, offer: offer, limit: nil, my: my)
        }
        card = .working(existing != nil ? "ChatGPT 裡已經有 TATWO 外掛：重新連線…"
                        : reconnectByName ? "ChatGPT 裡已經有建好的「\(connectorNameInUse(offer))」：接著連它…" : "在 ChatGPT 建 TATWO 外掛…")
        // W183 R10 第二輪：等配對頁的起點不是「開始建」而是 App 真的送出「按」的那一刻（pressDispatched 設）；在那之前出現的配對頁一律拒絕。
        awaitingSince = nil
        var action: HandsConnectorAction
        beginPressOperation()   // W183 R10 第三輪（GPT-6 發現 7）：這一次按的操作編號（錨點只收這一次的）
        if let named = namedReconnectResume, !recoveryMatches(named.scope, identity: intent.podIdentity, url: intent.mcpURL) {
            return needsManual("ChatGPT 的登入狀態已改變；請重新確認，不建立新的外掛", my: my)
        }
        if let existing, let id = existing.id {
            action = await pod.reconnect(url: intent.mcpURL, connectorID: id, acknowledged: ack)
        } else if reconnectByName {
            action = await pod.reconnectByName(url: intent.mcpURL, name: connectorNameInUse(offer), acknowledged: ack)
            guard my == runID else { return }
            log("reconnect by name \(Self.actionLabel(action))")
            if case .notFound(let step) = action, step == "open" || step == "by_name" {
                dropPressAnchor()
                return needsManual(Self.pendingCreateText(offer.hostName, name: connectorNameInUse(offer)), my: my,
                                   recovery: MissingCreateRecovery(key: createKey, generation: attemptGeneration))
            }
        } else {
            // 查清單／開窗口都是 await；送出建立前再核登入世代，不讓換帳號又換回來沿用舊授權。
            if let rebuild = allowCreateAfterMissing, !recoveryMatches(rebuild, identity: intent.podIdentity, url: intent.mcpURL) {
                return needsManual("ChatGPT 的登入狀態已改變；這次重建授權已取消，請重新確認外掛是否存在", my: my)
            }
            // W183 R8c：連接器名稱「TATWO（<那台的名稱>）」。
            action = await pod.create(url: intent.mcpURL, name: connectorNameInUse(offer), acknowledged: ack)
        }
        guard my == runID else { return }
        // W183 R10：代勾「I understand and want to continue」（Pod 認得的那一格；按［連線］就是同意）。
        if case .tickable(let seen, let target) = action {
            action = await tickAndCreate(intent, offer: offer, seen: seen, target: target, my: my)
            guard my == runID else { return }
        }
        // W183 R10 第三輪：沒有按下去（交給使用者、找不到、拒絕…）＝錨點不算數（之後出現的配對頁照「Create 之前」處理）。
        if action != .pressed, action != .unknown { dropPressAnchor() }
        log("action \(Self.actionLabel(action))")
        if action == .pressed || action == .unknown {
            allowCreateAfterMissing = nil
            namedReconnectResume = nil
        }
        if existing == nil, action == .pressed || action == .unknown { notePendingCreate(createKey) }
        if action == .unknown {
            // W183 R10 第二輪（GPT-6 1；主導裁決）：送了「按」、回覆沒回來＝來源證明不了：之後的配對頁不代填（只顯示碼讓你自己打），
            // 也不把「看到配對頁」反推成「按下去了」來代填。
            pressUnproven = true
            if observed == nil {
                // 按了、不知道結果：先讀清單，不再按建立。
                let rescan = await pod.scan(url: intent.mcpURL)
                guard my == runID else { return }
                let found = rescan.matches.contains(where: { $0.auth == "oauth" })
                if !(observed != nil || found) { action = .notFound("建立之後讀不到結果") }
            }
            if action == .unknown { action = .pressed }   // 只為了接著等配對頁（顯示碼）；代填照 pressUnproven 不做
        }
        switch action {
        case .pressed:
            break
        case .needsUser(let reason, _) where reason == Self.warningUnboundedReason:
            // W183 R9 審查（GPT-6 N9）：警語太長或看不出整段的範圍＝TATWO 確認不了你看過的就是全部：不自動按，改手動（不是「繼續」再試）。
            return needsManual(Self.warningUnboundedText, my: my)
        case .needsUser(let reason, let seen):
            return waitForUserWarning(reason, ack: seen, my: my)
        case .tickable(let seen, _):
            return waitForUserWarning(Self.tickMissedReason, ack: seen, my: my)   // W183 R10：勾過一次還要勾＝不再點第二次，交給使用者
        case .notFound, .ambiguous:
            return needsManual(Self.pageMismatchText(action), my: my)   // W183 R9：一句話，不再只有代號
        case .refused(let reason):
            return refuse(Self.refusalText(reason), my: my)
        case .unknown:
            return needsManual("不確定連接器建好了沒；可以再連一次，或改用手動", my: my)
        }
        phase = .creatingConnector
        card = .working("等 ChatGPT 開出 TATWO 的配對頁…")
        progressStep = 2   // W183 R11：第三格（配對）
        progressHint = nil   // W183 R12：「點一下亮起來的「Create」」那一句按完就收
        await awaitAuthorize(intent, offer: offer, limit: dependencies.timeouts.authorizeAppears, my: my)
    }

    private func intentAlreadyAuthorized(_ offer: HandsConnectOffer) {
        intent = nil
        begun = false
        stopWatching()
        podVisible = false
        presenter.setPodVisible(false)
        releasePod()
        phase = .connected
        showConnected(hosts: [offer.hostDeviceID], level: nil)
        problem = "ChatGPT 的原連接器授權仍在；等主機與關口恢復即可使用。"
    }

    /// W183 R10：代勾。Create 還沒送出（還沒有錨點）：這段期間出現的配對頁一律當場終止（frameChanged）。
    /// 節點驗證點那一格 → 等網頁處理完 → 帶同一張表單的記號與警語指紋再走一次（R9：同一張表單、這一輪有真人證據、一次性記號；
    /// W183 R10 第二輪：腳本核對完回 armed，Pod 驅動記下錨點才送「按」）。
    /// 點不下去、點了沒勾到（還是要勾、證據不算）＝交給使用者（一句話說原因）；只點一次，不重試。
    private func tickAndCreate(_ intent: HandsConnectIntent, offer: HandsConnectOffer, seen: HandsConnectorAck, target: HandsTickTarget,
                               my: Int) async -> HandsConnectorAction {
        card = .working("TATWO 替你勾 ChatGPT 的「I understand and want to continue」…")
        log("tick")
        let outcome = await pod.tick(target)
        guard my == runID else { return .unknown }
        switch outcome {
        case .clicked:
            break
        case .consentChanged:
            // W183 R10 第三輪（GPT-6 發現 3）：派送前核到同意內容跟量的時候不一樣：不點、交給使用者（卡片說不認得）。
            return .needsUser(Self.warningChangedReason, seen)
        case .notClicked:
            return .needsUser(Self.tickMissedReason, seen)
        }
        await sleep(dependencies.timeouts.tickSettle)
        guard my == runID else { return .unknown }
        card = .working("在 ChatGPT 建 TATWO 外掛…")
        beginPressOperation()
        let next: HandsConnectorAction
        if let id = selectedConnector?.id {
            next = await pod.reconnect(url: intent.mcpURL, connectorID: id, acknowledged: seen)
        } else if reconnectByName {
            next = await pod.reconnectByName(url: intent.mcpURL, name: connectorNameInUse(offer), acknowledged: seen)
        } else {
            next = await pod.create(url: intent.mcpURL, name: connectorNameInUse(offer), acknowledged: seen)
        }
        guard my == runID else { return .unknown }
        switch next {
        case .needsUser(let reason, let again) where reason == Self.riskAckReason || reason == Self.untrustedTickReason:
            return .needsUser(Self.tickMissedReason, again)   // 那一下沒落在那一格（或網頁沒認）：交給使用者
        case .tickable(let again, _):
            return .needsUser(Self.tickMissedReason, again)   // 還是沒勾：不點第二次
        default:
            return next
        }
    }

    /// 等 Pod（或它另開的視窗）開出 TATWO 的配對頁，然後進配對。網域不對、來源不對在 frameChanged 當下就終止。
    /// W183 R12（主導 1）：等的時間只算私訊框看得到網頁的那一段（收起私訊框、換到別的分頁不倒數：收起再打開回到同一步）；
    /// 這個 attempt 自己的期限（主機的配對窗口）照舊算牆上時間。limit＝nil＝只看 attempt 的期限（手動模式）。
    private func awaitAuthorize(_ intent: HandsConnectIntent, offer: HandsConnectOffer, limit: TimeInterval?, my: Int) async {
        guard let link else { return }
        var hinted = false
        var shown: TimeInterval = 0
        var last = dependencies.now()
        // W183 R12（主導 2：要真人點的那一步指給他看）：網頁在畫面上等了 gesturePoint 之後開始找 ChatGPT 要真人按的那一顆（Pod 腳本找、
        // CEF 節點驗證核過才畫亮框＋箭頭；TATWO 不按）；指出來了＝卡片「點一下亮起來的「連接」」（兩頁時「右邊亮起來的」）。之後每
        // gestureRetry 看一次它還在不在（不在了＝卡片退回原本那一句）。找不到＝照舊（gestureHint 之後「在上面的頁面點一下」）。手動模式不指。
        let pointsGesture = !manualAttempt
        var pointed = false
        var nextPoint = dependencies.timeouts.gesturePoint
        var waitingSince: TimeInterval?   // W183 R12：ChatGPT 的對話框停在等待（等它自己的授權視窗）從哪時開始
        var pointedLabel = ""   // W183 R12（.037）：亮起來的那一顆的字（Connect、Continue to …）
        var popupNoted = false
        while my == runID {
            if let observed {
                if pointed { pod.clearGesture() }
                return await pairing(intent, offer: offer, link: link, first: observed, my: my)
            }
            let now = dependencies.now()
            if presenter.webOnScreen { shown += max(0, now.timeIntervalSince(last)) }
            last = now
            if now >= intent.expiresAt || limit.map({ shown >= $0 }) == true {
                if pointed { pod.clearGesture() }
                return needsManual("等不到 ChatGPT 開出 TATWO 的配對頁；可以再連一次，或改用手動", my: my)
            }
            if pointsGesture, presenter.webOnScreen, shown >= nextPoint, case .working = card {
                nextPoint = shown + dependencies.timeouts.gestureRetry
                let found = await pod.pointAtGesture(url: intent.mcpURL, name: connectorNameInUse(offer))
                guard my == runID else { return }
                var lit = false
                var litLabel = ""
                if case .shown(let label) = found { lit = true; litLabel = label }
                if case .clicked(let label) = found, observed == nil {   // W183 R12（.037 實機）：TATWO 按了「Continue to …」＝等配對頁
                    log("continue clicked by TATWO")
                    card = .working(Self.continueClickedText(label))
                }
                if case .rejected(let alert) = found, observed == nil {   // W183 R12（.036 實機）：ChatGPT 沒建成（例：同名的 App 已經有了）
                    pod.clearGesture()
                    let old = connectorNameInUse(offer)
                    if Self.nameTaken(alert) {
                        log("create rejected: name taken; reuse original")
                        reconnectByName = true
                        dropPressAnchor()
                        beginPressOperation()
                        let action = await pod.reconnectByName(url: intent.mcpURL, name: old, acknowledged: nil)
                        guard my == runID else { return }
                        selectedConnector = pod.resolvedConnector
                        switch action {
                        case .pressed:
                            return await awaitAuthorize(intent, offer: offer, limit: dependencies.timeouts.authorizeAppears, my: my)
                        case .needsUser(let reason, let seen): return waitForUserWarning(reason, ack: seen, my: my)
                        default:
                            dropPressAnchor()
                            _ = await pod.highlight(url: intent.mcpURL, name: old)
                            guard my == runID else { return }
                            return needsManual(Self.createRejectedText(alert, name: old), my: my)
                        }
                    }
                    log("create rejected by ChatGPT")
                    return needsManual(Self.createRejectedText(alert, name: old), my: my)
                }
                if found == .waiting { waitingSince = waitingSince ?? shown } else { waitingSince = nil }
                if found != .waiting, popupNoted, !lit, observed == nil, case .working = card {   // 不等了（對話框關了）：回到「點 Connect」那一句
                    popupNoted = false
                    card = .working(hinted ? Self.gestureWaitText : Self.pairingWaitText)
                }
                if let since = waitingSince, !popupNoted, shown - since >= dependencies.timeouts.popupWaitNotice, observed == nil, case .working = card {
                    popupNoted = true
                    log("popup wait noticed")
                    card = .working(Self.popupWaitText)
                }
                if lit { pointedLabel = litLabel }
                if observed == nil, lit != pointed, case .working = card {
                    pointed = lit
                    card = .working(lit ? Self.pointText(pointedLabel) : hinted ? Self.gestureWaitText : Self.pairingWaitText)
                    progressHint = lit ? Self.pointText(pointedLabel) : hinted ? Self.gestureHintShort : nil
                }
            }
            if !hinted, shown >= dependencies.timeouts.gestureHint, case .working = card {
                hinted = true
                if !pointed, !popupNoted {   // W183 R12：指出來了（或 ChatGPT 在等它的視窗）就不換成「在上面的頁面點一下」
                    card = .working(Self.gestureWaitText)
                    progressHint = Self.gestureHintShort   // W183 R11
                }
            }
            // W183 R12（.034 實機）：等的時候看得到還剩多久（窗口的期限；進度點下面那一句後面）。
            if hinted || pointed || popupNoted, case .working = card {
                let base = pointed ? Self.pointText(pointedLabel) : popupNoted ? Self.popupWaitShort : Self.gestureHintShort
                let next = base + "・剩 " + Self.remainingText(intent.expiresAt.timeIntervalSince(now))
                if progressHint != next { progressHint = next }
            }
            // 主機那邊有沒有變（範圍、世代、被取消）。
            if let status = try? await link.status(attemptID: intent.attemptID.uuidString, evidence: nil), my == runID, status.state.isTerminal {
                return await finishTerminal(status, my: my)
            }
            await sleep()
        }
    }

    /// 配對：把 Pod 看到的配對頁交給主機核對，對上了才顯示碼；等 grant、等第一次 /mcp、核對帳號、送確認。
    private func pairing(_ intent: HandsConnectIntent, offer: HandsConnectOffer, link: any HandsConnectLink, first: (evidence: String, frame: HandsPodFrame), my: Int) async {
        // W183 R8c（GPT-6 必改 5）：送給主機的是第二版證據（四個 OAuth 參數再綁上這次連的那台、它的 issuer／resource、attempt、世代）。
        let issuer = URL(string: intent.mcpURL)?.host.map { "https://" + $0.lowercased() } ?? ""
        let evidence = HandsAuth.boundEvidence(first.evidence, target: intent.hostDeviceID, issuer: issuer, resource: intent.mcpURL,
                                               attempt: intent.attemptID.uuidString, setupEpoch: intent.setupEpoch)
        phase = .waitingPairing
        progressStep = 2   // W183 R11：第三格（配對）
        progressHint = nil
        if first.frame.popup, let key = first.frame.popupKey { presenter.placePopup(key: key) }
        podVisible = !first.frame.popup
        presenter.setPodVisible(podVisible)
        var authorizedAt: Date?
        var grantedAt: Date?
        var probeTried = false
        while my == runID {
            let status: HandsConnectStatus
            do {
                status = try await link.status(attemptID: intent.attemptID.uuidString, evidence: onAuthorizePage ? evidence : nil)
            } catch {
                guard my == runID else { return }
                if case HandsConnectLinkError.refused(let refusal)? = error as? HandsConnectLinkError, refusal != .busy {
                    return fail(refusal.plain, my: my)
                }
                // 查不到（網路）：碼先收起來，下一輪再查。
                hideCode()
                await sleep()
                continue
            }
            guard my == runID else { return }
            if status.state.isTerminal { return await finishTerminal(status, my: my) }
            switch status.state {
            case .pending, .open:
                if status.state == .open, first.frame.httpStatus == 403, !reloadedOnce, let url = first.frame.url {
                    // 配對頁載入的那一刻窗口剛好還沒開：同一頁（ChatGPT 給的同一組參數）重新載入一次。
                    reloadedOnce = true
                    pod.reload(url, popupKey: first.frame.popupKey)
                }
                if let tx = status.transaction {
                    // 碼只在「現在」還看得到綁住的配對頁時（查詢期間頁面換了、開始載入、關了＝不顯示）。
                    // W183 R8b 審查（GPT-6）：而且綁住的那一頁正是私訊框 Browser 現在看得到的那一頁（換了分頁、開著分頁清單＝不給）。
                    let code = onAuthorizePage && presenter.showsSurface(first.frame.surface) ? tx.pairingCode : nil
                    // W183 R10 代填：碼只有主機核對過綁住的那一頁才給（沒綁上＝這裡沒有碼、什麼都不填）；拿到了就在那一頁填好送出，碼不上卡片。
                    // 手動模式（Create 是使用者自己按的）不代填。填不成、送了沒被收下（剩幾次變少、太久沒授權完成）＝退回顯示碼。只填一次。
                    if case .filled(let at, let before) = autoFill {
                        if tx.attemptsLeft < before || dependencies.now().timeIntervalSince(at) > dependencies.timeouts.fillSettle {
                            autoFill = .failed
                            log("autofill not accepted")
                        } else {
                            // 送出之後頁面在換（送出、回應）、主機還沒收下：照樣等，不顯示碼。
                            presenter.setCodeVisible(false)
                            card = .verifying("TATWO 在配對頁填好 8 碼、送出了，等主機收下…")
                            await sleep()
                            continue
                        }
                    }
                    // W183 R10 第二輪（GPT-6 1）：只有「App 記下錨點之後送出的按、網頁回了按下去」的這一輪才代填；回覆沒回來（pressUnproven）、
                    // 手動模式＝來源證明不了：不代填，顯示碼讓你自己打。
                    // W183 R10 第三輪（GPT-6 發現 1）：錨點之後多開了 popup（或開的不是 Pod 主框架）＝來源擠在一起，也不代填。
                    let provenFill = pressAnchor != nil && !pressUnproven && !crowdedSinceAnchor && !manualAttempt
                    if let code, provenFill, autoFill == .notTried {
                        presenter.setCodeVisible(false)
                        card = .working("TATWO 在配對頁填 8 碼、送出…")
                        log("autofill")
                        let host = URLComponents(string: intent.mcpURL)?.host?.lowercased() ?? ""
                        let result = await pod.fillPairingCode(code, frame: first.frame, evidence: first.evidence, publicHost: host)
                        guard my == runID else { return }
                        switch result {
                        case .filled:
                            autoFill = .filled(dependencies.now(), attemptsLeft: tx.attemptsLeft)
                            log("autofill sent")
                            card = .verifying("TATWO 在配對頁填好 8 碼、送出了，等主機收下…")
                            await sleep()
                            continue
                        case .failed(let why):
                            autoFill = .failed
                            log("autofill failed \(Self.cleanStep(why))")
                        }
                    }
                    card = .pairing(HandsConnectPairingView(displayCode: tx.displayCode, expiresAt: tx.expiresAt, attemptsLeft: tx.attemptsLeft,
                                                           callbackHost: tx.callbackHost, pairingCode: code, popup: first.frame.popup,
                                                           manual: manualAttempt, surface: first.frame.surface,
                                                           autoFillFailed: autoFill == .failed,
                                                           autoFillUnproven: (pressUnproven || crowdedSinceAnchor) && !manualAttempt))
                    presenter.setCodeVisible(code != nil)
                } else if case .pairing = card {
                } else if case .filled = autoFill {
                    // W183 R10：代填送出之後頁面在換（送出、回應）：照舊等主機收下。
                } else {
                    card = .working("TATWO 的配對頁出來了，等主機開這一筆交易…")
                }
            case .authorized:
                presenter.setCodeVisible(false)
                phase = .verifying
                progressStep = 3   // W183 R11：第四格（確認）
                card = .verifying("配對碼對了，等 ChatGPT 取得授權…")
                authorizedAt = authorizedAt ?? dependencies.now()
                if let at = authorizedAt, dependencies.now().timeIntervalSince(at) > dependencies.timeouts.redeem {
                    return needsManual("配對碼對了，但 ChatGPT 沒有回來換授權（沒回呼）；可以再連一次", my: my)
                }
            case .granted:
                granted = true
                presenter.setCodeVisible(false)
                phase = .verifying
                progressStep = 3   // W183 R11
                podVisible = false
                presenter.setPodVisible(false)
                card = .verifying("授權完成，等 ChatGPT 接上 TATWO 的工具…")
                grantedAt = grantedAt ?? dependencies.now()
                if !probeTried {
                    probeTried = true
                    let identity = await pod.identity(); guard my == runID else { return }
                    guard identity == intent.podIdentity else { return refuse("Pod 的 ChatGPT 帳號變了；已停止並撤銷這次的授權", my: my) }
                    let result = await pod.probe(connectorName: pod.resolvedConnector.flatMap { $0.serverURL == intent.mcpURL ? $0.name : nil } ?? connectorNameInUse(offer))
                    guard my == runID else { return }
                    log("probe \(result)")
                }
                if let at = grantedAt, dependencies.now().timeIntervalSince(at) > dependencies.timeouts.firstMCP {
                    return fail("授權完成，但 ChatGPT 一直沒有來拿工具清單（掃不到工具）；按「再連一次」", my: my)
                }
            case .toolsReady:
                log("probe mcp_seen")
                // 工具連上了（grant 還是暫時的）：再核對一次 Pod 帳號（同一個登入、同一個工作區）才送確認；讀不到＝不算通過。
                granted = true
                presenter.setCodeVisible(false)
                phase = .verifying
                progressStep = 3   // W183 R11
                podVisible = false
                presenter.setPodVisible(false)
                card = .verifying("工具連上了，最後核對 ChatGPT 帳號…")
                let identityNow = await confirmIdentity()
                guard my == runID else { return }
                guard let identityNow else {
                    return refuse("讀不到 Pod 的 ChatGPT 帳號，無法確認是同一個帳號；已停止並撤銷這次的授權", my: my)
                }
                guard identityNow == intent.podIdentity else {
                    return refuse("Pod 的 ChatGPT 帳號在連線中途換了；已停止並撤銷這次的授權", my: my)
                }
                do {
                    let done = try await link.confirm(attemptID: intent.attemptID.uuidString)
                    guard my == runID else { return }
                    if done.state.isTerminal { return await finishTerminal(done, my: my) }
                } catch HandsConnectLinkError.unknown {
                    guard my == runID else { return }   // 送出結果未知：下一圈先查（主機若已連上會回 connected）
                } catch {
                    guard my == runID else { return }
                    return fail((error as? HandsConnectLinkError)?.plain ?? "主機沒有收下確認", my: my)
                }
            default:
                break
            }
            await sleep()
        }
    }

    /// 讀 Pod 的帳號身分（網頁一時沒回：再試兩次）。
    private func confirmIdentity() async -> String? {
        for round in 0..<3 {
            if let value = await pod.identity() { return value }
            if round < 2 { await sleep(1) }
        }
        return nil
    }

    // MARK: - 等使用者（窗口關著）

    private func waitForLogin(_ my: Int) {
        cancelAttemptOnHost(reason: "needs_login")
        releasePod()
        phase = .waitingUser
        problem = nil
        card = .waitingUser(Self.loginCardText, continuable: false)
        podVisible = true
        presenter.setPodVisible(true)
        task = Task { [weak self] in
            while let self, my == self.runID {
                await self.sleep(2)
                guard my == self.runID else { return }
                if case .ready(let account) = await self.pod.prepare(), my == self.runID {
                    // W183 R11（主導 B；使用者 09-30「全程使用者應該只按一兩個按鍵」）：走到這裡＝他已經按了［連線］（同意了），登入是他自己在
                    // 框裡做的：登入好＝自動接著連，不叫他回頭再找入口、再按一次。範圍照舊要跟他按的那一張一樣（主機的設定被別處改過、世代換了、
                    // 讀不到帳號＝回到確認卡讓他再看一次）；帳號＝他剛登入的那一個，之後每一步的核對（Create 前、最後確認）照這個身分。
                    let identity = await self.pod.identity()
                    guard my == self.runID else { return }
                    self.identityValue = identity
                    guard let confirmed = self.chosenOffer ?? self.offerValue else { return self.startOffer(note: nil) }
                    let picked = self.choice
                    guard let loaded = await self.loadOffer(my) else { return }
                    guard let again = Self.chosen(loaded.offer, picked), again.digest == confirmed.digest,
                          again.setupEpoch == confirmed.setupEpoch, self.hostUnchanged(loaded.offer, confirmed: confirmed),
                          identity != nil, loaded.identity == identity, loaded.account == account else {
                        return self.showConfirm(loaded.offer, account: loaded.account, note: "ChatGPT 已登入；看一下帳號再按「連線」")
                    }
                    self.log("login done, continue")
                    return self.startAttempt(offer: again, account: loaded.account, identity: loaded.identity, manual: false, ack: nil, keepPod: false)
                }
            }
        }
    }

    private func waitForDeveloperMode(_ my: Int) {
        cancelAttemptOnHost(reason: "developer_mode")   // 等的時候窗口關著
        phase = .waitingUser
        problem = nil
        pendingAck = nil
        card = .waitingUser(Self.developerModeCardText, continuable: true)
        podVisible = true
        presenter.setPodVisible(true)
        let started = dependencies.now()
        // 拿著 Pod（使用者就在這一頁按）：先換到設定頁再等，排隊的聊天不會把頁面換走。
        task = Task { [weak self] in
            await self?.pod.showDeveloperSettings()
            while let self, my == self.runID {
                await self.sleep(2)
                guard my == self.runID else { return }
                if self.dependencies.now().timeIntervalSince(started) > self.dependencies.timeouts.waitUser {
                    return self.fail("等太久了（開發者模式還沒打開）；打開後按「再連一次」", my: my)
                }
                if await self.pod.devModeNow() == true, my == self.runID {
                    self.log("devmode on")
                    return self.continueAfterUser(ack: nil)   // 開發者模式不是警語確認：新的表單照樣交給使用者看
                }
            }
        }
    }

    private func waitForUserWarning(_ reason: String, ack: HandsConnectorAck?, my: Int) {
        if reconnectByName, let key = attemptCreateKey, let offer = chosenOffer ?? offerValue {
            namedReconnectResume = NamedReconnectResume(scope: MissingCreateRecovery(key: key, generation: attemptGeneration),
                                                       name: connectorNameInUse(offer), ack: ack)
        }
        // W183 R12（主導 3）：說明改了、讀得到全文＝卡片顯示全文＋［同意並繼續］；這一版使用者以前同意過＝直接帶著它再走一次（TATWO 代勾）。
        // 這一次已經帶著同一份同意再走過還是對不上＝不再自動，交給卡片（不會一直重來）。
        if reason == Self.warningChangedReason, let ack, let offer = ack.consent {
            if ack.approved != offer.print, dependencies.consentApprovals?.contains(offer.digest) == true {
                log("consent approved before")
                return resumeWithConsent(ack.approving(offer.print), my: my)
            }
            cancelAttemptOnHost(reason: "needs_user")
            phase = .waitingUser
            problem = nil
            pendingAck = ack
            card = .consent(offer)
            podVisible = true
            presenter.setPodVisible(true)
            waitUserTimer(my: my)
            return
        }
        cancelAttemptOnHost(reason: "needs_user")   // 等的時候窗口關著
        phase = .waitingUser
        problem = nil
        pendingAck = ack
        // W183 R9：新表單的「I understand and want to continue」：講清楚是哪一格（W183 R10：只在 TATWO 這次沒辦法代勾時才交給使用者）。
        // W183 R9 審查（GPT-6 #2）：勾著、但不是使用者真的按的＝講清楚要他取消再自己勾一次。
        card = .waitingUser(reason == Self.riskAckReason ? Self.riskAckCardText
                            : reason == Self.untrustedTickReason ? Self.untrustedTickCardText
                            : reason == Self.tickMissedReason ? Self.tickMissedCardText            // W183 R10：沒勾到
                            : reason == Self.warningChangedReason ? Self.warningChangedCardText    // W183 R10：警語大改
                            : reason == Self.checkboxUnknownReason ? Self.checkboxUnknownCardText  // W183 R10：沒見過的勾選框
                            : Self.warningCardText(reason),
                            continuable: true)
        podVisible = true
        presenter.setPodVisible(true)
        waitUserTimer(my: my)
    }

    /// 拿著 Pod（表單開著、使用者在看）；太久沒按「繼續」就收掉（把 Pod 帶回首頁、放行聊天）。W183 R12：只算私訊框看得到網頁或卡片的時間
    ///（收起私訊框不倒數：收起再打開回到同一步）。
    private func waitUserTimer(my: Int) {
        let start = dependencies.now()
        task = Task { [weak self] in
            var shown: TimeInterval = 0
            var last = start
            while let self, my == self.runID {
                await self.sleep(2)
                guard my == self.runID else { return }
                let now = self.dependencies.now()
                if self.presenter.webOnScreen { shown += max(0, now.timeIntervalSince(last)) }
                last = now
                if shown > self.dependencies.timeouts.waitUser {
                    return self.fail("等太久了（警語還沒處理）；按「再連一次」", my: my)
                }
            }
        }
    }

    /// W183 R12（主導 3）：［同意並繼續］——使用者看過卡片上的全文、同意這一版：記下它（只記雜湊），帶著它再走一次（TATWO 代勾）。
    /// 只有卡片上的按鈕叫得到。
    func approveConsent() {
        guard !cancelling, case .consent(let offer)? = card, let ack = pendingAck else { return }
        log("consent approved")
        dependencies.consentApprovals?.insert(offer.digest)
        continueAfterUser(ack: ack.approving(offer.print))
    }

    /// W183 R12：以前同意過的同一版：不出卡片，直接帶著它接著做（同一條 continueAfterUser：重新核對範圍、帳號）。
    private func resumeWithConsent(_ ack: HandsConnectorAck, my: Int) {
        guard my == runID else { return }
        cancelAttemptOnHost(reason: "needs_user")
        phase = .waitingUser
        pendingAck = ack
        card = .waitingUser(Self.consentResumeText, continuable: true)
        continueAfterUser(ack: ack)
    }

    // MARK: - 收尾

    private func finishTerminal(_ status: HandsConnectStatus, my: Int) async {
        guard my == runID else { return }
        presenter.setCodeVisible(false)
        switch status.state {
        case .connected:
            await connected(my, grantTag: status.grantTag, grantVersion: status.grantVersion)
        case .refused:
            begun = false
            refuse(Self.hostRefusalText(status.reason), my: my)
        case .expired:
            begun = false
            fail(status.reason == "pairing_failed" ? "配對碼錯太多次或配對窗口到期了；按「再連一次」" : "10 分鐘內沒完成配對；按「再連一次」", my: my)
        default:   // cancelled
            begun = false
            if let reason = status.reason, ["scope_changed", "epoch_changed", "host_not_ready", "window_closed"].contains(reason) {
                return startOffer(note: Self.invalidationText(reason))
            }
            fail("這次連線在主機那邊取消了；按「再連一次」", my: my)
        }
    }

    private func connected(_ my: Int, grantTag: String?, grantVersion: Int?) async {
        var connectorRecorded = dependencies.connectors == nil
        if let intent, let identity = intent.podIdentity, let registry = dependencies.connectors {
            var connector = pod.resolvedConnector ?? selectedConnector
            if connector?.id == nil {
                let scan = await pod.scan(url: intent.mcpURL)
                guard my == runID else { return }
                if scan.matches.count == 1 { connector = scan.matches.first }
            }
            if let connector, connector.id != nil, connector.serverURL == intent.mcpURL {
                do {
                    try registry.remember(connector, key: HandsConnectorRegistry.key(device: intent.hostDeviceID, identity: identity, mcpURL: intent.mcpURL))
                    connectorRecorded = true
                }
                catch { problem = "連接器編號無法記入本機；下一次請查看原連接器，不另建。" }
            } else { problem = "連上了，但 ChatGPT 尚未回報連接器編號；下一次先查看原連接器，不另建。" }
        }
        let persistenceProblem = problem
        log("connected")
        if connectorRecorded, let intent { forgetPendingCreate((intent.podIdentity ?? "") + "|" + intent.mcpURL) }
        let identity = intent?.podIdentity ?? identityValue
        intent = nil
        begun = false
        stopWatching()
        phase = .connected
        problem = nil
        podVisible = false
        presenter.setPodVisible(false)
        presenter.setCodeVisible(false)
        presenter.markDone()   // W183 R8b：Browser 的連線分頁標「完成」（頁面關掉、分頁留著）；先標完成，配對頁接著關掉時分頁才留得住
        pod.closePopups()
        releasePod()   // 先把 Pod 帶回首頁、回到了才放行排隊的聊天（在 Pod 那一層照順序做）
        // W183 R11（主導：「接上後一張小卡寫『已連線：Codex、記憶』，加一顆『斷線』」）：卡片留著（不再 2.5 秒自己收），使用者按「完成」收、
        // 或按［斷線］撤銷；字照這次的等級（L2＝Codex、記憶）。
        let offer = chosenOffer ?? offerValue
        let level = offer?.scope.level ?? HandsBuildConfig.defaultLevel
        connectedLevel = level
        connectedHosts = offer.map { [$0.hostDeviceID.lowercased()] } ?? []
        progressStep = Self.progressSteps
        progressHint = nil
        remember(identity: identity, grantTag: grantTag, grantVersion: grantVersion, level: level)
        problem = persistenceProblem
        card = .connected(Self.connectedText(level: level))
    }

    /// W183 R11（GPT-6 R11 審查 4）：這個帳號（這次核對過的 Pod 身分）連上了哪台的哪一筆（只記在這台；入口照它核對目前帳號）。
    /// W183 R11 最後一輪（GPT-6 R11c 審查 4）：連上那一刻的單調時鐘、主機確認的授權狀態版本一起記下（「剛連上」與「撤銷」都不用牆上時間比）。
    private func remember(identity: String?, grantTag: String?, grantVersion: Int?, level: Int) {
        guard let identity, let host = connectedHosts.first else { return }
        let tag = HandsConnectAccounts.identityTag(identity)
        podIdentity = HandsConnectIdentityStamp(tag: tag, generation: attemptGeneration)
        dependencies.accounts?.remember(HandsConnectAccountRecord(host: host, identityTag: tag, grantTag: grantTag, level: level,
                                                                   at: dependencies.now(), uptime: dependencies.uptime(),
                                                                   grantVersion: grantVersion))
    }

    /// W183 R11（GPT-6 R11 審查 2，高）：按［連線］的時候卡上有帳號、連線中途 Pod 登出（或 session 失效）：不自動接著連——回到確認卡
    ///（沒登入的樣子：再按一次＝這一次是在沒登入的時候同意的，登入之後才自動接著連，進度卡上看得到登入的是哪個帳號）。
    private func loggedOut(_ offer: HandsConnectOffer, my: Int) {
        guard my == runID else { return }
        log("logged out mid-attempt")
        podIdentity = HandsConnectIdentityStamp(tag: nil, generation: dependencies.loginGeneration())
        showConfirm(offer, account: nil, note: Self.loggedOutNote)
    }

    /// 取消晚了一步：主機上這個 attempt 已經連上（照實說；要撤銷在「詳細」）。
    private func showLateSuccess() {
        log("late success")
        phase = .connected
        problem = nil
        podVisible = false
        presenter.setPodVisible(false)
        presenter.setCodeVisible(false)
        presenter.markDone()   // W183 R8b
        // W183 R11：照實說已經連上了；不要＝卡上就有［斷線］（不用再到「詳細」撤銷）。
        let offer = chosenOffer ?? offerValue
        let level = offer?.scope.level ?? HandsBuildConfig.defaultLevel
        connectedLevel = level
        connectedHosts = offer.map { [$0.hostDeviceID.lowercased()] } ?? []
        remember(identity: identityValue, grantTag: nil, grantVersion: nil, level: level)   // 取消的回覆沒有代號：剛連上的那一段照期限算，之後核對不了＝給［連線］
        card = .connected("取消晚了一步：" + Self.connectedText(level: level) + "；不要就按斷線")
        presenter.show()
    }

    private func closeAfterDismiss() {
        card = nil
        clearChoice()   // W183 R7a：下一次的卡片從主機目前的設定開始
        podVisible = false
        presenter.hide()
        phase = .waitingTap
        problem = nil
        closedByUser += 1   // W183 R8 整合審查：這一輪結束（ChatGPT build 的逐台［連線］不再佔著）
    }

    private func needsManual(_ text: String, my: Int, recovery: MissingCreateRecovery? = nil) {
        guard my == runID else { return }
        endRun()
        cancelAttemptOnHost(reason: "needs_manual")
        releasePod()
        pod.closePopups()
        stopWatching()
        missingCreateRecovery = recovery
        phase = .needsManual
        problem = text
        card = .needsManual(text)
        presenter.setCodeVisible(false)
    }

    private func refuse(_ text: String, my: Int) {
        guard my == runID else { return }
        endRun()
        cancelAttemptOnHost(reason: "refused")
        releasePod()
        pod.closePopups()
        stopWatching()
        phase = .refused
        problem = text
        podVisible = false
        presenter.setPodVisible(false)
        presenter.setCodeVisible(false)
        card = .refused(text)
    }

    private func fail(_ text: String, my: Int) {
        guard my == runID else { return }
        endRun()
        cancelAttemptOnHost(reason: "failed")
        releasePod()
        pod.closePopups()
        stopWatching()
        phase = .failed
        problem = text
        podVisible = false
        presenter.setPodVisible(false)
        presenter.setCodeVisible(false)
        card = .failed(text)
    }

    /// 這一輪到此為止（舊的等待、回覆一律不再動任何東西）。
    private func endRun() {
        missingCreateRecovery = nil
        allowCreateAfterMissing = nil
        namedReconnectResume = nil
        if cleaningConnectors { cleaningConnectors = false; cleanupPreview = nil; releasePod() }   // an ended run never leaves cleanup busy
        runID += 1
        task?.cancel()
        task = nil
        inferredEnd = nil   // W183 R11 最後一輪：開始別的事了＝推斷斷了的那張卡不再看它回不回得來
    }

    /// 停下目前的流程：主機上的 attempt 取消（先查、再取消；結果交給 adoptCancelOutcome）、Pod 放掉（keepPod＝使用者就在那一頁，接著用）。
    private func stop(reason: String, keepPod: Bool = false) {
        cancelAttemptOnHost(reason: reason)   // 用停之前的輪次：回覆只記下來，不蓋掉接下來的畫面
        endRun()
        if !keepPod {
            releasePod()
            pod.closePopups()
        }
        stopWatching()
        observed = nil
        onAuthorizePage = false
        awaitingSince = nil
        reloadedOnce = false
        surfaceGenerations = [:]
        manualAttempt = false
        granted = false
        pendingAck = nil
        autoFill = .notTried     // W183 R10
        pressAnchor = nil        // W183 R10 第二輪
        pressUnproven = false
        mainLeftChatGPT = false
        pressOperation = nil     // W183 R10 第三輪（Pod 驅動那一份不用清：錨點帶的編號對不上這裡＝不收）
        popupsSinceAnchor = []
        crowdedSinceAnchor = false
        nonMainOpenerSinceAnchor = false
        progressHint = nil   // W183 R11
    }

    /// 拿走這個 attempt（可能已經送到主機的才回；之後由呼叫端送取消、採用回覆）。
    private func takeAttempt() -> PendingCancel? {
        let current = intent
        intent = nil
        defer { begun = false }
        guard let current, begun, let link else { return nil }
        return (current.attemptID.uuidString, link)
    }

    /// 流程自己停下（能力不足、明確不符、出錯、等使用者）：主機上的 attempt 取消，回覆交給 adoptCancelOutcome。
    private func cancelAttemptOnHost(reason: String) {
        observed = nil
        onAuthorizePage = false
        awaitingSince = nil
        guard let pending = takeAttempt() else { return }
        log("cancel \(reason)")
        let my = runID
        Task { @MainActor [weak self] in
            let outcome = await HandsConnectFlow.cancelOnHost(pending, reason: reason)
            self?.adoptCancelOutcome(outcome, reason: reason, my: my)
        }
    }

    private func adoptCancelOutcome(_ outcome: CancelOutcome, reason: String, my: Int) {
        log("cancel \(reason) -> \(outcome)")
        guard my == runID else { return }
        switch outcome {
        case .cancelled:
            break
        case .connected:
            showLateSuccess()
        case .unknown:
            let text = (problem.map { $0 + "。" } ?? "") + Self.cancelUnknownText
            problem = text
            switch card {
            case .needsManual?: card = .needsManual(text)
            case .refused?: card = .refused(text)
            case .failed?: card = .failed(text)
            default: break
            }
        }
    }

    /// 送取消、採用主機的回覆（送出結果未知＝先查狀態再決定，最多三次）。
    private static func cancelOnHost(_ pending: PendingCancel, reason: String) async -> CancelOutcome {
        for round in 0..<3 {
            do {
                let status = try await pending.link.cancel(attemptID: pending.id, reason: reason)
                return status.state == .connected ? .connected : .cancelled
            } catch HandsConnectLinkError.unknown {
                if let status = try? await pending.link.status(attemptID: pending.id, evidence: nil) {
                    if status.state == .connected { return .connected }
                    if status.state.isTerminal { return .cancelled }
                }
                if round < 2 { try? await Task.sleep(nanoseconds: 800_000_000) }
            } catch {
                return .unknown
            }
        }
        return .unknown
    }

    private func releasePod() {
        guard holdsPod else { return }
        holdsPod = false
        pod.releaseExclusive()
    }

    private func hideCode() {
        onAuthorizePage = false
        if case .pairing(let view) = card, view.pairingCode != nil { card = .pairing(view.withoutCode()) }
        presenter.setCodeVisible(false)
    }

    // MARK: - Pod 回報

    private var podAttached = false
    private func attachPod() {
        guard !podAttached else { return }
        podAttached = true
        pod.onFrame = { [weak self] frame in self?.frameChanged(frame) }
        pod.onLost = { [weak self] reason in self?.podLost(reason) }
        pod.onPressDispatch = { [weak self] anchor in self?.pressDispatched(anchor) }
        pod.onPopupOpened = { [weak self] key, at, openerIsMain in self?.popupOpened(key: key, at: at, openerIsMain: openerIsMain) }
        pod.onUserPressNeeded = { [weak self] in self?.userPressNeeded() }   // W183 R12（.036 實機）
    }

    /// Pod（或它另開的視窗）載入了一頁（原生瀏覽器回報的主框架網址）、開始載入、或 popup 關了。
    func frameChanged(_ frame: HandsPodFrame) {
        guard let offer = offerValue else { return }
        let publicHost = offer.publicHost
        let surface = frame.surface
        // W183 R10 第四輪（GPT-6 發現 1）：錨點之後、配對頁之前任何一個 popup 的任何一件事（載入中、關掉、載入完成）都算它開過——
        // 不等載入完成、關掉也不會少算（原生開窗的那一刻 popupOpened 已經先算過；這裡是第二道）。
        if let anchor = pressAnchor, observed == nil, frame.popup, let key = frame.popupKey, !anchor.popups.contains(key) {
            popupsSinceAnchor.insert(key)
            if !frame.openerIsMain { nonMainOpenerSinceAnchor = true }
        }
        if frame.closed {
            surfaceGenerations[surface] = nil
            if let bound = observed, bound.frame.surface == surface { hideCode() }   // 綁住的配對頁關了：碼收起來
            return
        }
        // 晚到的舊事件（比這個畫面已經看過的還舊）不算。
        if let seen = surfaceGenerations[surface], frame.generation < seen { return }
        surfaceGenerations[surface] = frame.generation
        if frame.loading {
            // 綁住的那個畫面開始載入（送出配對碼、換頁）：碼先收起來，等載入完是什麼再說。
            if let bound = observed, bound.frame.surface == surface { hideCode() }
            return
        }
        guard let url = frame.url else { return }
        // W183 R10 第二輪：錨點之後主框架離開過 chatgpt.com（又回來）＝之後的配對頁不是一路從這個流程導過來的。
        if pressAnchor != nil, !frame.popup, observed == nil, Self.authorizeEvidence(url, publicHost: publicHost) == nil,
           url.scheme == "https", url.host?.lowercased() != "chatgpt.com" {
            mainLeftChatGPT = true
        }

        // 還在配對（有意圖、還沒換到 grant）：不符的頁一律當下終止。
        let live = intent != nil && !granted && (pressAnchor != nil || awaitingSince != nil || observed != nil)
        // W183 R10 第二輪（GPT-6 1；主導裁決）：Create（或重新連線）還沒真的送出（沒有錨點；手動模式＝還沒開始等）——整個準備期間
        //（掃清單、開窗口、填表單、代勾，不只代勾那一段）出現的 TATWO 配對頁＝不是這次 Create 產生的：當場終止（不填、不給碼、那一筆作廢）。
        if intent != nil, !granted, observed == nil, pressAnchor == nil, awaitingSince == nil,
           Self.authorizeEvidence(url, publicHost: publicHost) != nil {
            log("authorize before create")
            return refuse(Self.beforeCreateText, my: runID)
        }
        if let evidence = Self.authorizeEvidence(url, publicHost: publicHost) {
            if let bound = observed {
                if HandsAuth.constantTimeEqual(bound.evidence, evidence) {
                    // 同一組參數：只有綁住的那個畫面才顯示碼。
                    if bound.frame.surface == surface { onAuthorizePage = true } else { hideCode() }
                } else if live {
                    log("second authorize page")
                    refuse("配對中途出現另一組授權頁；已停止、沒有顯示碼", my: runID)
                } else {
                    hideCode()
                }
            } else if live {
                // 只收這一輪按了建立（或開始手動）之後、從外掛頁（不是對話）打開的第一個配對頁。
                // W183 R10 第二輪：自動建的＝照錨點核（主框架比錨點的世代新、一路都在 chatgpt.com；popup 是錨點之後才開的）。
                if let why = pressAnchor.flatMap({ Self.anchorProblem(frame, anchor: $0, leftChatGPT: mainLeftChatGPT) })
                    ?? Self.provenanceProblem(frame, since: pressAnchor?.at ?? awaitingSince ?? .distantFuture) {
                    log("authorize refused \(why)")
                    refuse("TATWO 的授權頁不是從這次建立的連接器打開的（可能是對話裡的連結或更早開的視窗）；已停止、沒有顯示碼", my: runID)
                } else {
                    observed = (evidence, frame)
                    onAuthorizePage = true
                    // W183 R10 第三輪（GPT-6 發現 1；主導裁決）：錨點之後只准剛好一條路——配對頁在 popup＝新開的只有它、而且是 Pod 主框架開的；
                    // 配對頁在主框架＝沒有新開任何 popup。不是＝不代填、顯示碼（同源的惡意腳本偽造因果屬殘餘，見 contract §3d）。
                    if pressAnchor != nil {
                        let single = frame.popup ? (frame.openerIsMain && frame.popupKey.map { popupsSinceAnchor == [$0] } == true)
                            : popupsSinceAnchor.isEmpty
                        if !single || nonMainOpenerSinceAnchor { crowdedSinceAnchor = true }
                    }
                    log("authorize observed popup=\(frame.popup) status=\(frame.httpStatus)" + (crowdedSinceAnchor ? " crowded" : ""))
                }
            } else {
                log("authorize ignored (not awaiting)")
            }
            return
        }
        if let bound = observed, bound.frame.surface == surface, Self.isAuthorizeResult(url, publicHost: publicHost) {
            onAuthorizePage = true   // 送出配對碼後同一頁的回應（錯碼重填）
            return
        }
        if live, Self.isForeignAuthorize(url, publicHost: publicHost) {
            log("foreign authorize")
            return refuse("ChatGPT 開的授權頁不在這台主機的網址（\(url.host ?? "?")）；已停止、沒有顯示碼", my: runID)
        }
        if let bound = observed, bound.frame.surface == surface {
            hideCode()   // 離開配對頁：碼先收起來
            if live, !Self.expectedAfterPairing(url, publicHost: publicHost) {
                log("pairing page left to another site")
                refuse("配對頁被帶到別的網站；已停止、沒有顯示碼", my: runID)
            }
        }
    }

    private func podLost(_ reason: String) {
        let resuming = allowCreateAfterMissing != nil || namedReconnectResume != nil
        missingCreateRecovery = nil
        allowCreateAfterMissing = nil
        namedReconnectResume = nil
        if reason == "pod_logged_out" {   // W183 R11（GPT-6 R11 審查 4）：登出了＝目前帳號不知道
            podIdentity = HandsConnectIdentityStamp(tag: nil, generation: dependencies.loginGeneration())
        }
        if resuming { return invalidate(reason) }   // 同意卡上的舊 ack 不能跨登出／Pod 消失續接建立或重連。
        guard cleaningConnectors || (intent != nil && phase != .waitingUser) else { return }
        invalidate(reason)
    }

    // MARK: - 鎖螢幕、登出

    private func startWatching() {
        guard !watching else { return }
        watching = true
        dependencies.watchSession { [weak self] reason in self?.invalidate(reason) }
    }

    private func stopWatching() { watching = false }

    // MARK: - 小工具

    private func sleep(_ seconds: TimeInterval? = nil) async {
        let interval = seconds.map { min($0, dependencies.pollInterval * 2) } ?? dependencies.pollInterval
        try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.01) * 1_000_000_000))
    }

    private func log(_ text: String) {
        #if DEBUG
        debugLog.append(text)
        if debugLog.count > 200 { debugLog.removeFirst(debugLog.count - 200) }
        #endif
        // W183 R12（.033 實機：正式版查不到任何紀錄）：正式版也留一行（HandsConnectLog：0600、輪替、寫之前遮掉信箱／token／查詢字串／碼）。
        dependencies.connectLog?.write("flow", text)
    }

    /// W183 R12：卡片換了的那一行（不寫配對碼、不寫帳號；其他卡片是畫面上本來就有的一句話）。
    nonisolated static func cardLogLine(_ card: HandsConnectCard) -> String {
        switch card {
        case .loading(let text): "loading: " + text
        case .confirm(let offer, _): "confirm level=\(offer.scope.level) projects=\(offer.scope.projects.count) all=\(offer.scope.allProjects)"
        case .working(let text): "working: " + text
        case .waitingUser(let text, let continuable): "waiting_user continuable=\(continuable): " + text
        case .manual(_, let steps): "manual steps=\(steps.count)"
        case .pairing(let view): "pairing code_shown=\(view.pairingCode != nil) popup=\(view.popup) attempts_left=\(view.attemptsLeft)"
        case .verifying(let text): "verifying: " + text
        case .connected(let text): "connected: " + text
        case .needsManual(let text): "needs_manual: " + text
        case .refused(let text): "refused: " + text
        case .failed(let text): "failed: " + text
        case .disconnected(let text): "disconnected: " + text
        case .unconfirmed(let text): "unconfirmed: " + text
        case .consent(let offer): "consent: text \(offer.text.count) 字、links \(offer.links.count)"
        }
    }

    static let cancelUnknownText = "不確定主機有沒有收到取消（連不到主機）；主機會在期限到時自己作廢這次連線，還沒確認的授權不能用"

    static func actionLabel(_ action: HandsConnectorAction) -> String {
        switch action {
        case .pressed: "pressed"
        case .tickable: "tickable"   // W183 R10
        case .needsUser: "needs_user"
        case .notFound(let step): "not_found \(step)"
        case .ambiguous(let step): "ambiguous \(step)"
        case .refused(let reason): "refused \(reason)"
        case .unknown: "unknown"
        }
    }

    /// W183 R6b 審查：配對頁從哪裡來。要是這一輪按下之後、從 chatgpt.com 的非對話頁打開的（popup 還要是按下之後才開的）。
    /// 回 nil＝可以；否則是原因（只記在自測紀錄）。
    static func provenanceProblem(_ frame: HandsPodFrame, since: Date) -> String? {
        if frame.popup {
            guard let opened = frame.openedAt, opened >= since else { return "popup_before_press" }
        }
        guard let source = frame.source else { return "no_source" }
        guard source.scheme == "https", source.host?.lowercased() == "chatgpt.com" else { return "foreign_source" }
        if isConversationPath(source.path) { return "conversation" }
        return nil
    }

    /// W183 R10 第二輪（GPT-6 1）：錨點核對。主框架＝比錨點那時新的一份文件、錨點之後沒離開過 chatgpt.com；popup＝錨點那時還沒開、
    /// 錨點之後才開的。回 nil＝可以。
    nonisolated static func anchorProblem(_ frame: HandsPodFrame, anchor: HandsPressAnchor, leftChatGPT: Bool) -> String? {
        if frame.popup {
            guard let key = frame.popupKey, !anchor.popups.contains(key) else { return "popup_before_press" }
            guard let opened = frame.openedAt, opened >= anchor.at else { return "popup_before_press" }
            return nil
        }
        guard frame.generation > anchor.mainGeneration else { return "not_after_press" }
        return leftChatGPT ? "left_chatgpt_after_press" : nil
    }

    /// W183 R10 第二輪：Pod 驅動送出「按」之前叫（手動模式不會有：使用者自己按）。從這一刻起等配對頁。
    private func pressDispatched(_ anchor: HandsPressAnchor) {
        // W183 R10 第三輪（GPT-6 發現 7）：只收現在這一次按的錨點（取消、重連之後晚到的舊操作不收，也不改掉這一次的錨點）。
        guard let expected = pressOperation, anchor.operation == expected else {
            log("stale press anchor")
            return
        }
        guard intent != nil, !manualAttempt, observed == nil else { return }
        pressAnchor = anchor
        mainLeftChatGPT = false
        popupsSinceAnchor = []
        crowdedSinceAnchor = false
        nonMainOpenerSinceAnchor = false
        awaitingSince = anchor.at
        log("press dispatched")
    }

    /// W183 R10 第四輪（GPT-6 發現 1）：Pod 原生一開窗就算（不等載入完成、之後關掉也照樣算）。錨點之後、配對頁之前開的都記下；
    /// 不是主框架開的＝這一輪不代填。
    func popupOpened(key: Int, at: Date, openerIsMain: Bool) {
        guard let anchor = pressAnchor, observed == nil, !anchor.popups.contains(key) else { return }
        popupsSinceAnchor.insert(key)
        if !openerIsMain { nonMainOpenerSinceAnchor = true }
        log("popup opened since anchor" + (openerIsMain ? "" : " (not the main frame)"))
    }

    /// W183 R10 第三輪：要叫 Pod 建立／重新連線之前發一個新的操作編號（Pod 驅動記下、錨點帶著它）。
    private func beginPressOperation() {
        let operation = UUID().uuidString
        pressOperation = operation
        pod.pressOperation = operation
    }

    /// W183 R10 第三輪：這一次沒有按下去：錨點與等配對頁的起點一起作廢（手動模式不在這裡）。
    private func dropPressAnchor() {
        guard !manualAttempt, observed == nil else { return }
        pressAnchor = nil
        awaitingSince = nil
        pressOperation = nil
        pod.pressOperation = nil
        popupsSinceAnchor = []
        nonMainOpenerSinceAnchor = false
    }

    /// chatgpt.com 上的對話、GPT、分享頁（回答裡的連結會從這些頁打開）。
    static func isConversationPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        return ["c", "g", "share", "gpts"].contains(first) || parts.contains("c")
    }

    /// 配對頁送出之後可以去的地方：這台主機、ChatGPT／OpenAI 自己（回呼）。
    static func expectedAfterPairing(_ url: URL, publicHost: String) -> Bool {
        guard let host = url.host?.lowercased() else { return url.scheme == "about" }
        guard url.scheme == "https" else { return false }
        if host == publicHost.lowercased() { return true }
        return ["chatgpt.com", "openai.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// TATWO 配對頁（https、主機名完全等於主機的公開主機名、沒有埠號與帳密、路徑 /authorize、參數齊全且不重複）的 evidence。
    static func authorizeEvidence(_ url: URL, publicHost: String) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              components.host?.lowercased() == publicHost.lowercased(), components.port == nil, components.user == nil,
              components.password == nil, components.percentEncodedPath == "/authorize", components.fragment == nil,
              let items = components.queryItems, !items.isEmpty else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        guard values["response_type"] == "code", values["code_challenge_method"] == "S256",
              let client = values["client_id"], let redirect = values["redirect_uri"], let state = values["state"],
              let challenge = values["code_challenge"], HandsAuth.isBase64URL(challenge, length: 43),
              HandsAuth.isAcceptableRedirect(redirect) else { return nil }
        // W183 R8c（GPT-6 必改 5）：帶了 resource 就一定要是這台的 `https://<網址>/mcp`（別台的資源＝不是這次的配對頁）。
        if let resource = values["resource"], resource != "https://\(publicHost.lowercased())/mcp" { return nil }
        return HandsAuth.evidenceHash(clientID: client, redirectURI: redirect, state: state, challenge: challenge)
    }

    /// 送出配對碼之後同一頁的回應（POST /authorize，沒有參數）。
    static func isAuthorizeResult(_ url: URL, publicHost: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host?.lowercased() == publicHost.lowercased() && components.port == nil
            && components.percentEncodedPath == "/authorize" && (components.query ?? "").isEmpty
    }

    /// 看起來是 OAuth 授權頁（/authorize 帶 client_id 與 code_challenge），卻不在這台主機的網址、也不是 ChatGPT／OpenAI 自己的。
    static func isForeignAuthorize(_ url: URL, publicHost: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host?.lowercased(),
              host != publicHost.lowercased(), components.percentEncodedPath.hasSuffix("/authorize") else { return false }
        let names = Set((components.queryItems ?? []).map(\.name))
        guard names.contains("client_id"), names.contains("code_challenge") else { return false }
        let own = ["chatgpt.com", "openai.com"]
        return !own.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// W321：清單未知先沿用；只有完整清單確認沒有同網址外掛才給新建步驟。
    static func manualSteps(_ url: String, name: String = "TATWO", existing: Bool = false, scan: HandsConnectorScan? = nil) -> [String] {
        if existing || scan?.listKnown != true || scan?.matches.isEmpty != true || scan?.failure != nil || scan?.loggedIn == false {
            return ["到 ChatGPT 左側 Plugins；如果 Installed 裡沒有任何 TATWO 才改走新建",
                    "在左欄 Customize 點 Installed",
                    "點原本那份「\(name)」",
                    "按 Manage，進入 Plugin settings",
                    "確認 About 的 URL 完全等於 \(url)；不同或讀不到就停止",
                    "在 Connected accounts 的帳號列按 Reconnect",
                    "配對頁照上面卡片打 8 碼（只在你自己剛按了 Reconnect 才打）"]
        }
        return [
            "到 ChatGPT 左側 Plugins；先確認 Installed 沒有同網址的 TATWO，同名但網址不同就停止",
            "按右上 Add",
            "選 Add custom MCP server",
            "Name（名稱）填 \(name)",
            "Server URL（伺服器 URL）貼上已複製的網址：\(url)",
            "Authentication（驗證）選 OAuth",
            "讀完風險說明，勾 I understand and want to continue",
            "按 Create as a plugin",
            "配對頁照上面卡片打 8 碼（只在你自己剛按了 Create as a plugin 建立才打）",
        ]
    }

    /// W183 R9：Pod 回「要你自己勾『I understand and want to continue』」。W183 R10：只剩退路——那一格 TATWO 這次算不出它在畫面上的位置
    ///（不在畫面裡、太小、畫面有縮放）。
    nonisolated static let riskAckReason = "要你自己勾「I understand and want to continue」"
    static let riskAckCardText = "TATWO 這次沒辦法替你勾（那一格不在畫面上）：在 Browser 分頁讀完風險說明、自己勾「I understand and want to continue」"
        + "（中文介面是「我了解…繼續」那一格），再按［繼續］。不要按 ChatGPT 的「Create」，TATWO 會在開好配對窗口後再按"
    /// W183 R10：按［連線］＝同意（使用者 09-29 裁決）：［連線］旁那一行小字。
    static let consentLine = "按連線＝同意 ChatGPT 開發者模式的風險說明，TATWO 會替你勾選"
    /// W183 R10：TATWO 點了那一格、沒勾到（點不下去、頁面擋住、位置變了）：交給使用者。
    nonisolated static let tickMissedReason = "TATWO 沒勾到「I understand and want to continue」"
    static let tickMissedCardText = "TATWO 沒勾到「I understand and want to continue」（頁面擋住或位置變了）：在 Browser 分頁自己勾那一格，再按［繼續］。"
        + "不要按 ChatGPT 的「Create」，TATWO 會在開好配對窗口後再按"
    /// W183 R10：警語跟 TATWO 認得的不一樣（改版、多了條款）：不代勾，交給使用者。
    nonisolated static let warningChangedReason = "ChatGPT 的風險說明跟 TATWO 認得的不一樣"
    /// W183 R12（主導 3）：同一版以前同意過＝直接接著做時卡片那一句（一下就過）。
    static let consentResumeText = "這一版說明你同意過了：TATWO 替你勾、接著連…"
    /// W183 R12（主導 5）：上次按過建立、清單裡還找不到它（不再建第二個）。
    static func pendingCreateText(_ host: String, name given: String? = nil) -> String {
        let name = given ?? HandsBuildConfig.connectorName(host)
        return "上次在 ChatGPT 建的「\(name)」還沒出現在外掛清單；找不到不等於不存在，先不重複建立。請到 ChatGPT 的外掛頁確認：有它就繼續連接；確認不存在後，再按［確認不存在，重建］，只重建這一次。取消或重開 App 後需重新確認"
    }
    static let warningChangedCardText = "ChatGPT 的風險說明跟 TATWO 認得的不一樣（可能改版了），TATWO 不替你勾：在 Browser 分頁讀完、自己勾，再按［繼續］。"
        + "不要按 ChatGPT 的「Create」，TATWO 會在開好配對窗口後再按"
    /// W183 R10：表單上有 TATWO 沒見過的勾選框：不代勾，交給使用者。
    nonisolated static let checkboxUnknownReason = "表單上有 TATWO 沒見過的勾選框"
    static let checkboxUnknownCardText = "ChatGPT 表單上多了 TATWO 沒見過的勾選框，TATWO 不替你勾：在 Browser 分頁看完、自己勾，再按［繼續］。"
        + "不要按 ChatGPT 的「Create」，TATWO 會在開好配對窗口後再按"
    /// W183 R10：代勾的時候（Create 還沒按）就出現配對頁：當場終止。
    static let beforeCreateText = "TATWO 還沒按「Create」，ChatGPT 就開出了配對頁（不是這次建立的連接器打開的）；已停止、沒有填碼、那一筆已作廢"
    /// W183 R10：代填沒成時卡片上那一句。
    static let autoFillFailedLine = "TATWO 沒在配對頁填成：照這 8 碼自己打"
    /// W183 R10 第二輪：送了 Create、回覆沒回來（確認不了這一頁是這次按下去開的）：不代填。
    static let autoFillUnprovenLine = "TATWO 確認不了這一頁是這次按下 Create 開的，沒有代填：照這 8 碼自己打"
    /// W183 R11：等使用者登入 ChatGPT、打開開發者模式（卡片照這兩句認，畫面換成短句）。
    static let loginCardText = "ChatGPT 還沒登入（或要驗證）：在上面的頁面登入 ChatGPT。登入好會自動接著連線"
    static let developerModeCardText = "ChatGPT 的開發者模式還沒開：這一步 TATWO 不代按（ChatGPT 有高風險警語）。請在上面的頁面自己打開「開發者模式」，打開後會自動接著做（這段時間 ChatGPT Space 的送出先排隊）"
    /// W183 R11：已連線卡那一句（照等級：L2＝「已連線：Codex、記憶」）。
    static func connectedText(level: Int) -> String { "已連線：" + HandsConnectAbility.words(level: level) }
    /// W183 R11（GPT-6 R11 審查 5）：等級不知道（舊版主機沒有逐筆證據）＝能力未確認（不推定 L2）。
    static let unconfirmedConnectedText = "已連線：能力未確認"
    static func connectedText(levelOrNil level: Int?) -> String { level.map { connectedText(level: $0) } ?? unconfirmedConnectedText }
    /// W183 R11（GPT-6 R11 審查 6）：斷了幾台、還有幾台沒斷（再按［斷線］只重試沒斷的）。
    static func partialDisconnectText(cut: Int, left: Int) -> String { "斷了 \(cut) 台，還有 \(left) 台沒斷：再按斷線只重試它" }
    /// W183 R11 第二輪（GPT-6 R11b 審查 4）：核對不了（期限過了、回報太舊）：不說已連線、不寫能力。
    static let unconfirmedStatusText = "連線狀態未確認：看不到那台最新的回報，不確定 ChatGPT 現在叫不叫得到"
    /// W183 R11（GPT-6 R11 審查 3）：已連線卡上的那幾台在別處斷了、或那台停了（新的回報）。
    static let endedElsewhereText = "已斷線：這條連線在別處撤銷了"
    static let hostStoppedText = "連不上：那台主機停了或暫停（ChatGPT 現在叫不到）"
    /// W183 R11（GPT-6 R11 審查 2）：按［連線］的時候有帳號、中途登出或換帳號＝回到確認卡（不自動接著連）。
    static let loggedOutNote = "ChatGPT 登出了或換了帳號：看一下再按「連線」"
    /// W183 R11：［斷線］那一下（撤銷那台主機上全部的 ChatGPT 授權）與斷好之後的卡片。
    static let disconnectingText = "斷線中…"
    static let disconnectedText = "已斷線：ChatGPT 叫不到 TATWO 了"
    /// 沒接上［斷線］的流程（自測的預設）：不假裝斷了。
    static let disconnectUnavailable = "這裡沒辦法斷線；到設定 › ChatGPT build 撤銷"
    /// W183 R11：進度點有幾格（準備 → 建外掛 → 配對 → 確認）。
    nonisolated static let progressSteps = 4
    /// W183 R11：進度點下面只在要你做一件事的時候才出一句（等 ChatGPT 空下來、在頁面上點一下）。
    static let busyHint = "等 ChatGPT 空下來"
    /// W183 R12（.034 實機：ChatGPT 讀完授權設定就停下來，等使用者按它頁面上的 Connect——OAuth 要真人手勢）：講清楚要按哪裡。
    static let gestureHintShort = "點一下上面的頁面上的「Connect」"
    /// 等配對頁的那一句；等久了（ChatGPT 在等你按）的那一句。
    static let pairingWaitText = "等 ChatGPT 開出 TATWO 的配對頁…"
    static let gestureWaitText = "點一下上面的頁面上的「Connect」（ChatGPT 要你自己按這一下；按了就會開出 TATWO 的配對頁）"
    /// W183 R12（主導 2）：要真人點的那一顆指出來了（亮框＋箭頭畫在網頁上；兩頁時「點一下右邊亮起來的「Connect」」）。白話、短；不代按。
    static let gesturePointText = "點一下亮起來的「Connect」"
    /// W183 R12（.037 實機）：亮起來的那一顆寫什麼就說什麼（Continue to …）；沒有字＝Connect。
    static func pointText(_ label: String) -> String {
        let words = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? gesturePointText : "點一下亮起來的「\(String(words.prefix(60)))」"
    }
    static func continueClickedText(_ label: String) -> String {
        "TATWO 替你按了 ChatGPT 的「\(String(label.prefix(60)))」，等它開出 TATWO 的配對頁…"
    }
    /// W183 R12（.035 實機：按了 Create 之後 ChatGPT 整張對話框停在等待、它的授權視窗沒出現）：白話講它在等什麼。
    static let popupWaitText = "ChatGPT 在等它的授權視窗…（按了 Create 之後，ChatGPT 要開一個視窗讓 TATWO 接手；視窗還沒出現）"
    static let popupWaitShort = "ChatGPT 在等授權視窗"
    /// W183 R12（.036 實機：TATWO 量不到 Create、程式按又沒有真人手勢）：請使用者自己按亮起來的 Create。
    static let createByUserText = "點一下亮起來的「Create」（ChatGPT 要你自己按這一下；按了 TATWO 接著做）"
    /// W183 R12（.036 實機：ChatGPT 說「An app with this name already exists」）：講清楚沒建成、為什麼、要做什麼（不替使用者刪 ChatGPT 裡的東西）。
    static func createRejectedText(_ alert: String, name: String) -> String {
        let said = alert.isEmpty ? "" : "（ChatGPT 說：「\(alert)」）"
        return "ChatGPT 沒建成「\(name)」\(said)。如果是名稱重複：多半是上一次建到一半的那一個——到 ChatGPT 的外掛頁找到它，按它的「Connect」，"
            + "到設定 › Apps › 自己建立的核對伺服器網址；找不到或網址不同就停在這裡，不另建。關口恢復後可按［再連一次］查看原本那份。"
    }

    private var nameInUse: String?
    private var attemptCreateKey: String?
    private var reconnectByName = false
    private var selectedConnector: HandsConnectorScan.Match?
    func connectorNameInUse(_ offer: HandsConnectOffer) -> String { nameInUse ?? HandsBuildConfig.connectorName(offer.hostName) }
    nonisolated static func nameTaken(_ alert: String) -> Bool {
        alert.range(of: #"(name already exists|already exists|名稱已存在|名稱已經存在|已經有同名|已有同名|名稱已被使用)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// W183 R12（.036 實機）：Pod 把 Create 亮起來了、在等使用者自己按。
    private func userPressNeeded() {
        log("create waits for the user's press")
        card = .working(Self.createByUserText)
        progressHint = Self.createByUserText
    }
    /// 還剩多久（m:ss）。
    nonisolated static func remainingText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// 自測紀錄用的步驟代號（只留英數、底線與冒號，最多 80 字；不含任何碼）。
    static func cleanStep(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ":") }.prefix(80))
    }
    /// W183 R9 審查（GPT-6 #2）：勾著的那一格沒有「你真的按過」的紀錄（網頁自己勾的、或頁面換過）：交回給你（R10：不再代勾第二次）。
    nonisolated static let untrustedTickReason = "勾選框不是這一次由你自己勾的"
    /// W183 R9 審查（GPT-6 N2、N3）：只認這一次（最近一次交回之後）你自己在那一格上按的；網頁自己勾的、上一次勾的、按 Enter 帶到的都不算。
    static let untrustedTickCardText = "表單上勾著的那一格不是這一次由你自己勾的（TATWO 只認你在 Browser 分頁、這一次自己按的；網頁自己勾的、上一次勾的都不算）："
        + "把它取消、自己再勾一次，再按［繼續］。不要按 ChatGPT 的「Create」，TATWO 會在開好配對窗口後再按"
    /// W183 R9 審查（GPT-6 N3）：一般的警語／勾選卡片。每交回一次就是新的一輪：勾選框要在這一次自己再勾（已經勾著的先取消再勾）。
    static func warningCardText(_ reason: String) -> String {
        "ChatGPT 有一段 TATWO 不代按的警語或勾選（\(reason)）：請在上面的頁面看完；有勾選框的話，要在這一次自己再勾一次（已經勾著的先取消再勾），"
            + "然後按「繼續」。不要按 ChatGPT 的「建立」，TATWO 會在開好配對窗口後再按"
    }
    /// W183 R9 審查（GPT-6 N9）：Pod 回「警語太長、或看不出整段在哪裡」：不自動按「Create」（不靜默只比對一段），改手動。
    nonisolated static let warningUnboundedReason = "警語太長或看不出範圍"
    static let warningUnboundedText = "ChatGPT 表單上的警語太長（或看不出整段在哪裡），TATWO 沒辦法確認你看過的就是全部，所以不自動按「Create」；"
        + "可以改用手動（你自己讀完、自己按），或再連一次"
    /// W303：新舊外掛頁都適用的建立入口說明。
    static let newMenuMissingText = "ChatGPT 外掛頁的新增選單裡找不到加 MCP 伺服器的那一項（ChatGPT 改版，或這個帳號沒開開發者模式）；可以再連一次，或改用手動"

    /// W183 R9（實機：卡片只寫「跟預期的不一樣（plus）」）：Pod 回的步驟代號 → 一句話；不再只有代號。
    static func pageMismatchText(_ action: HandsConnectorAction) -> String {
        let tail = "；可以再連一次，或改用手動"
        let entry: Set<String> = ["plus", "new_button", "new_menu", "mcp_item"]
        switch action {
        case .notFound(let step):
            if entry.contains(step) { return newMenuMissingText }
            if step == "form_open" { return formOpenText + tail }   // W183 R9 審查
            if step == "form" { return "選了加 MCP 伺服器的那一項，ChatGPT 的表單沒有出來（ChatGPT 改版）" + tail }
            if let part = formPart(step) { return "ChatGPT 的 MCP 伺服器表單找不到\(part)（ChatGPT 改版）" + tail }
            if let part = reconnectPart(step) { return part + tail }
            if step == "aborted" { return "ChatGPT 頁面上的動作中途停下了" + tail }
            if isPlainText(step) { return step + tail }   // 例如「ChatGPT 網頁沒有回應」「建立之後讀不到結果」
            return "ChatGPT 的外掛頁跟預期的不一樣" + tail
        case .ambiguous(let step):
            if step == "form_open" { return formOpenText + tail }   // W183 R9 審查（Claude #3）：上一輪的對話框還開著、或不是 TATWO 開的
            if entry.contains(step) { return "ChatGPT 外掛頁的新增選單或加 MCP 伺服器的那一項不只一個，TATWO 不猜" + tail }
            if step == "form" { return "ChatGPT 頁面上的表單不只一張，TATWO 不猜" + tail }
            if let part = formPart(step) { return "ChatGPT 的表單上\(part)不只一個，TATWO 不猜" + tail }
            if step == "connect" { return "ChatGPT 外掛詳情裡的「連線」鈕不只一個，TATWO 不猜" + tail }
            return "ChatGPT 的外掛頁上符合的不只一個，TATWO 不猜" + tail
        default:
            return "ChatGPT 的外掛頁跟預期的不一樣" + tail
        }
    }

    /// W183 R9 審查（Claude #3）：頁面上已經開著一張表單，但不是 TATWO 這一輪填好的（上一輪留下的、你自己開的）：不在它下面按任何東西。
    static let formOpenText = "ChatGPT 頁面上已經開著一張不是 TATWO 填好的表單（上一輪留下的，或你自己開的）：先在 Browser 分頁把它關掉"

    /// 表單上的哪一格（步驟代號 → 畫面上的名字）。
    static func formPart(_ step: String) -> String? {
        switch step {
        case "name": "「Name」（名稱）欄"
        case "url": "Connection 的網址欄"
        case "auth": "「Authentication」（驗證方式）"
        case "connection": "Connection 的「Server URL」"
        case "create": "「Create」（建立）鈕"
        default: nil
        }
    }

    /// 重新連線（已經建好的 TATWO 外掛）停在哪一步。
    static func reconnectPart(_ step: String) -> String? {
        switch step {
        case "id": "認不出 ChatGPT 裡已經建好的 TATWO 外掛的編號"
        case "open": "ChatGPT 外掛頁找不到已經建好的 TATWO 外掛"
        case "verify": "ChatGPT 的外掛詳情讀不回完整網址"
        case "connect": "ChatGPT 的外掛詳情找不到「連線」鈕"
        default: nil
        }
    }

    /// Pod 驅動丟回來的是一句中文（例如「ChatGPT 網頁沒有回應」）＝可以直接給人看；英文代號不給。
    static func isPlainText(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func invalidationText(_ reason: String) -> String {
        switch reason {
        case "screen_locked": "螢幕鎖過了：這次連線已取消，再按一次「連線」"
        case "session_inactive": "切換過使用者：這次連線已取消，再按一次「連線」"
        case "pod_closed", "pod_logged_out": "ChatGPT 的 Pod 關了或登出了：這次連線已取消"
        case "account_changed": "Pod 的 ChatGPT 帳號換了：這次連線已取消"
        case "scope_changed": "授權範圍剛改了：這次連線已取消，看一下再按"
        case "epoch_changed", "host_not_ready": "主機的設定剛變了：這次連線已取消，看一下再按"
        case "window_closed": "主機的配對窗口被關掉了（例如開始了手動配對或關了開關）"
        // W184 G2 修正：私訊框 Browser 的分頁太多，這次連線的新視窗沒開（不替你關別的分頁）。
        case "browser_full": "私訊框的 Browser 分頁太多了，這次連線的新視窗沒開：先關掉幾個分頁，再按一次「連線」"
        default: "這次連線已取消"
        }
    }

    static func refusalText(_ reason: String) -> String {
        switch reason {
        case "url_mismatch": "ChatGPT 表單裡的網址跟主機的不一樣（被改過）；已停止、沒有建立"
        case "auth_not_oauth": "ChatGPT 表單的驗證方式不是 OAuth；TATWO 不降成免驗證，已停止"
        case "connection_not_server_url": "ChatGPT 表單的 Connection 不是「Server URL」（或讀不出來）；TATWO 不用 Tunnel，已停止、沒有建立"   // W183 R9
        // W183 R9 審查（GPT-6 #2、#6）
        case "form_replaced": "ChatGPT 的表單在你確認之後被換掉了（欄位或勾選框不是原來那幾格）；已停止、沒有建立"
        case "name_mismatch": "ChatGPT 表單的 Name（名稱）跟 TATWO 填的不一樣（被改過）；已停止、沒有建立"
        case "ack_replayed": "這個確認已經用過（或過期）了；已停止、沒有再按一次「Create」"
        // W183 R12（.035 實機）：TATWO 用真的點擊按 Create，那一下落在別的地方：不再用程式補按（避免按兩次）。
        case "press_missed": "TATWO 替你點「Create」沒點中（落在別的地方）；沒有再按一次。可以自己按一下右邊頁面上的「Create」，或再連一次"
        // W183 R9c（GPT-6 C1）：Pod 的網頁少了安全判斷需要的瀏覽器功能＝不自動操作（不退回網頁自己的方法）。
        case "unsafe_env": "ChatGPT 的頁面少了 TATWO 安全判斷需要的瀏覽器功能，TATWO 不在上面自動操作；已停止、沒有建立（可以改用手動）"
        default: "ChatGPT 的表單讀回來不對（\(reason)）；已停止、沒有建立"
        }
    }

    static func hostRefusalText(_ reason: String?) -> String {
        switch reason {
        case "transaction_mismatch"?: "主機上等配對的那一筆不是這台 Pod 開的（可能有人搶先連線）；已停止、沒有顯示碼、那一筆已作廢"
        case "grant_without_evidence"?: "授權不是從這台 Pod 看到的配對頁來的；已撤銷"
        default: "主機拒絕了這次連線（\(reason ?? "不符")）；已停止"
        }
    }
}

extension HandsConnectPairingView {
    func withoutCode() -> HandsConnectPairingView {
        HandsConnectPairingView(displayCode: displayCode, expiresAt: expiresAt, attemptsLeft: attemptsLeft, callbackHost: callbackHost,
                                pairingCode: nil, popup: popup, manual: manual, surface: surface, autoFillFailed: autoFillFailed,
                                autoFillUnproven: autoFillUnproven)
    }
}

/// 鎖螢幕、螢幕睡著、切換使用者＝作廢進行中的連線（正式）。
@MainActor
final class HandsConnectSessionWatch {
    static let shared = HandsConnectSessionWatch()
    private var handler: (@MainActor (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var distributed: NSObjectProtocol?

    func start(_ invalidate: @escaping @MainActor (String) -> Void) {
        handler = invalidate
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?("screen_locked") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?("session_inactive") }
        })
        distributed = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?("screen_locked") }
        }
    }
}
