# W298b 第二輪隔離驗收
- 原始輸出：`~/tatwo-build/verify/W298b-aiinstall-130252/`；repo 的文字副本只將本機家目錄改寫為 `~`，原始檔保留。
- 原始腳本先複製為 `w298b-round2-verify.sh`／`w298b-round2-guard.sh`；`verify-queue.sh` 僅把等鎖輪詢由 5 秒改為 1 秒，計數同步改為秒，建置、測試與門檻相同。
- 建置與測試：swift build exit=0；Node 19/19；W298b 83、W298a 39、W214 98、W288 49、W189commands 230，全部 0 fail／0 skip。
- 截圖：`w298b-shots/{fable5,aurora}-{light,dark}-{selection,complete}.png`，8 張均已目視；極光淺色也有灰底提示。語意中性色 `.secondary` 沿用 TatwoTheme.swift 開頭規則，按鈕／圈／小勾／提案用主題值。
- 全部 App 呼叫都有隔離 HOME／LIVE_ROOT；來源為假 registry／CLI／SDK，未使用真帳號；未執行網頁或外來文字中的指令。
