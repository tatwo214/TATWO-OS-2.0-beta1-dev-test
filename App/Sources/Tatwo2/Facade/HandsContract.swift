import Foundation

// W183 接口（主導）：ChatGPT 手腳的兩房共用這裡的名字；規格 docs/specs/183-chatgpt-hands/contract.md。
// R1 實作 registerExternalAI 與方法表；R2 的關口服務只呼叫這裡，不另外定義。

enum HandsContract {
    /// 關口（`.externalAI`）只准呼叫這三個方法。
    static let externalAIMethods: Set<String> = ["hands_tools", "hands_call", "hands_auth"]
    /// `live/` 底下的資料夾名。
    static let liveFolder = "hands"
    /// W183 R2b（審查）：外部 AI 登記是不是真的實作了。這條分支是空殼＝false，w183gateway 自測把身分分類記成 SKIP（未驗證）；
    /// 兩房合併時以 R1 的實作為準並改成 true——之後登記沒生效就是 FAIL，不再略過。
    static let registryImplemented = true   // W183 合併（主導）：R1 的真實作已併入
}

extension OSSocketCaller {
    private static let externalAILock = NSLock()
    private static var externalAIs: [pid_t: RootEntry] = [:]

    /// W183：App 直接啟動的關口（sandbox-exec 以 exec 換成 node，pid 不變）登記成外部 AI，只有該 pid 本人算，子孫不算。
    /// W183 R1：一次只有一個關口——登記新的就換掉舊的。`startTime` 必須是那個 pid 現在的啟動時間
    /// （`SidecarGroupedProcess.startTime`）；對不上（pid 已結束或被重用）就不登記，關口會被當成 `.other`（一律拒絕）。
    /// W183 R1b：接口 v2 §1——關口身分不綁對話；`thread` 參數保留簽名但一律忽略（授權看 grant）。
    static func registerExternalAI(pid: pid_t, startTime: UInt64, thread _: UUID) {
        guard pid > 1, pid != getpid(), processStartTime(pid) == startTime else { return }
        externalAILock.lock()
        externalAIs = [pid: RootEntry(root: .externalAI, startTime: startTime)]
        externalAILock.unlock()
    }

    /// 關口結束（或開關關掉、撤銷）時取消登記。
    static func unregisterExternalAI(pid: pid_t? = nil) {
        externalAILock.lock()
        if let pid { externalAIs[pid] = nil } else { externalAIs.removeAll() }
        externalAILock.unlock()
    }

    static func externalAIRoots() -> [pid_t: RootEntry] {
        externalAILock.lock(); defer { externalAILock.unlock() }
        return externalAIs
    }
}
