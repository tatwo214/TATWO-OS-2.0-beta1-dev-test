# W276d — 外部系統驗收

- Studio / macOS 27.0.1；正式 App pid 72148 保持執行。
- `initializer-before.txt`：b6673b7c 啟動器在 payload constructor 中查不到自己的 LaunchServices 身分。
- `initializer-after.txt`：相同 constructor 在修正版中讀到 staging 身分及 bundle path；尚未呼叫 payload main。
- 修正版在隔離 HOME/CFFIXED_USER_HOME 後呼叫系統 `GetCurrentProcess`，再 dlopen Swift/CEF；不預建 NSApplication，保留 CEF 的應用程式子類別。
- 這證明原啟動器沒有先報到。Studio 舊版也能開視窗，未重現 MacBook 的 AlertNotificationService 覆寫；造成該身分的精確呼叫者仍未定位。
- `acceptance.txt`：open -g 與 Finder 的開啟處理都回傳 0；兩次均由外部 CGWindowListCopyWindowInfo 讀到可見、layer 0、寬高 > 400 的 staging 主視窗。
- Finder 由 `open -a Finder <App>` 接收檔案開啟動作。未模擬實體滑鼠雙擊。Finder AppleScript 路徑先前逾時，原始失敗保留在本機 system.log。
- `before.json` 與兩次 during/after JSON：正式 App 的同一個主視窗 id、bounds 保持不變。
- 每次 AppleScript quit 回傳 0；候選程序、helper、NSRunningApplication 殘留均為 0。
- `*-lsappinfo-full.txt` 保留完整系統報到資料。`-only` 輸出的 NULL/!cgsConnection 屬未選欄位，不能解讀為系統沒有視窗。
- `verify.txt`：原 offline fixture + verify.sh；Node 27/27、w216 60/60，0 fail。
- Release+CEF 已建置，TATWO2_STAGING_ADHOC=1 跳過鑰匙圈查詢，deep/strict 簽章通過。
- 此處僅有外部系統文字／JSON，沒有 App 自己的截圖。檔案內使用者路徑已換成 /Users/fixture。
- 重跑：`bash tests/fixtures/w276-launchservices-verify.sh '<staging.app>' '<evidence-dir>'`。
- 本機原始輸出：~/tatwo-build/tmp/W276d/；未推送、未簽正式憑證、未改正式 App／真帳號／真 live。
