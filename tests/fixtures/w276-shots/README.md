# W276c — Studio 實機證據

- 基準 c5f1e015；工作副本 w276/staging。正式版 PID 72148 全程維持執行，未修改正式 App、憑證或登入帳號。
- 舊 ad-hoc 複本：`open -g` 在 2 秒檢查前退出，stdout/stderr 皆空；直接跑啟動器能開。
- 根因：`legacy-instance-trace.txt` 記錄真正的舊 App 在單一實例查詢時只取得 PID -1。執行檔由 Tatwo2Staging exec 成 Tatwo2，與 Info.plist 的啟動身分失配；guard 將 -1 判成其他同 ID 實例，主程式返回。
- `guard-probe.swift` 是不含 CEF、AppIntents 或產品單一實例程式碼的最小 AppKit 重現。相同 guard 判斷在 exec 時 records=[-1]、early_return；dlopen 時 records=[自身 PID]、normal_exit（見 exec-guard.txt、dlopen-guard.txt）。
- 修法：C 主執行檔只連 libSystem；隔離完成後才 dlopen 同包的 Tatwo2 動態程式並呼叫 main。測試在 Objective-C +load 讀取 Foundation HOME，確認已隔離且執行檔仍是 Tatwo2Staging。
- `parallel-summary.json`：open -g 31.593 秒仍在；AppleScript quit 回傳 0，0.447 秒後殘留 0；正式版同 PID 存活；SecurityAgent 未出現。
- `windows.txt`：Staging 只有正常主視窗，沒有 layer 27 Island；正式版保留唯一 layer 27 Island。Staging 也不建立 NSStatusItem，既有全域熱鍵隔離保留。
- `sockets.txt`：os.sock、browser.sock 都位於 tatwo2-staging。
- `light.png`：真實啟動後用既有 UIProbe 擷取 App 自身視窗；不是離線 fixture render。CLI/Terminal 缺少螢幕錄製與 AX 權限。`--staging-snapshot` 只在 Staging 有效，沿用 UIProbe 的敏感窗保護與固定暫存輸出。
- 圖中側欄用一次性的 NSArgumentDomain `-tatwo.sidebar.pinned YES -AppleInterfaceStyle Light` 展開；未修改正式版或持久偏好。Browser 在 Staging Info.plist 預設啟用，圖中六個 Space 選鈕可見。
- 閒置 Staging 直接正常退出；執行中的聊天或 loops 仍經原確認流程；正式版結束判定不變。
- `verify.log`：指定三份 Node 測試 26/26、w216 60/60、0 fail；Release+CEF 建置成功；ad-hoc 複本 deep/strict 簽章通過。
- 未測正式版關閉情境：使用者要求不碰正式 App，且它正在執行；未取得停止授權。Finder 以 AppleScript open 驗證同一 LaunchServices 路徑，沒有模擬實體雙擊。
- 本機原始輸出與 ad-hoc App：~/tatwo-build/tmp/W276c/。未推送、未同步、未使用真鑰匙圈、未登入真帳號。GBrain 查詢回傳 Internal error。

Repo 文字證據把本機使用者路徑換成 /Users/fixture；原始輸出保留在上述本機暫存房。未修改公開掃描白名單。
