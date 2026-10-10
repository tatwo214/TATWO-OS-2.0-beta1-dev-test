未量到滑動改善；基準已預設關閉 AX。按 W257 指示停止效能調整，保留需求路徑修正與量測證據。

| 三次中位數 | 改前 c901ffff | 改後 | 差異 |
|---|---:|---:|---:|
| p50 格時間 ms | 6.9 | 6.9 | 0 |
| p95 格時間 ms | 8.5 | 8.6 | +0.1（約 +1.2%） |
| >50 ms 長格數 | 0 | 0 | 0 |
| longtask 總時長 ms | 0 | 0 | 0 |

方法：同一台 Mac Studio（Mac17,14），VoiceOver 關、TATWO_CEF_FORCE_AX 未設；真 CEF 154.0.28 / Chromium 154.0.8037.58，1000×700 viewport；每輪新程序、新空快取、mock keychain。頁內 rAF 以 19200 px/s 捲動 10 秒；每批 20 則，共 34 批／680 則。PNG 由 canvas 生成，HTTP 只綁 127.0.0.1；nearest-rank p50/p95，longtask 依捲動起迄裁切，再各取三輪中位數。
改前各輪 p95：8.5／8.5／8.6 ms；改後：8.6／8.6／8.6 ms。六輪 p50 都是 6.9 ms，長格與 longtask 都是 0。
原始改前：tatwo-build/verify/W257-xsmooth-003407/artifacts/w257xsmooth/{run-1,run-2,run-3,median}.json（含每格時間）。
原始改後：tatwo-build/verify/W257-xsmooth-005740/artifacts/w257xsmooth/{run-1,run-2,run-3,median,ax-1,ax-2,ax-3}.json。
P1 的頁內量測在修改產品前完成；原來的 AX 遍歷只用舊 API，之後補齊新舊 API；頁內量測程式與參數前後相同。
P2：CEF 的 TatwoCEFApplication 繼承 NSApplication，未繼承 Chromium 的 BrowserCrApplication 需求處理；接 AXEnhancedUserInterface／AXManualAccessibility 事件至 CEF SetAccessibilityState。既有與新分頁共用需求判斷，預設沿用 STATE_DEFAULT；沒有偵測輪詢。完整樹 process scope 只給 TATWO_CEF_FORCE_AX=1 除錯。
Computer Use 只在已驗過目標、要求 includeTree、目標為 OS 時設定 AXManualAccessibility；browser agent 原本走 DOM，無需啟用 AX。
原生證據（三輪各通過）：beforeManual=false；afterManual=true，讀到「W257 AX requested content」與 AXButton；取消要求關樹；Enhanced 要求同路徑；隱藏再顯示仍可讀。viewDidUnhide 事件後重套仍有效的需求，處理 Chromium 揭頁時重算暫時 AX 模式。
P4：既有診斷列顯示關／開與原因，native log 驗證要求前後的文字；更正舊文案「其他工具需強制旗標」。未另做診斷 UI 截圖。
指定 verify：tatwo-build/verify/W257-xsmooth-005740/verify.log；Node 47 pass／0 fail／1 原有 skip；w257xsmooth 27、w209spotify 78、w214 98、w250picker 180 個 PASS，四套 exit=0。w97 兩個檔案皆存在並執行。
browser*.test.mjs 與指定相關檔共 66 檔：396 tests／391 pass／1 fail／4 原有 skip；逐檔結果 browser-final-results.json。唯一失敗 W54 裸 padding 在 c901ffff 重現，證據 base-visual-tokens.txt；該產品檔未改。
Node 的 SwiftUI fixture 使用環境底稿既有的 macro frontend；只有六個需要它的 Node 檔使用。verify.sh 的 swift build 全部未設定 SWIFT_DRIVER_SWIFT_FRONTEND_EXEC。首次廣掃有外掛／鎖／receipt 失敗，原始日誌 all-browser-node.txt 保留。
keyword 廣掃共 885 tests／849 pass／32 fail／4 skip：28 安裝測試缺可信 Node 或固定簽章身分；socket 已正常 frontend 重跑通過；W54 基準既有失敗；W85 fixture 缺 HandsComputerUse；W86 要求另一種 TMPDIR 形狀。日誌 all-browser-node-2.txt 保留，未修改那些程式。
重現：先用 verify.sh 建置，執行 python3 tests/fixtures/w257-pack.py "$TMPDIR"；export TATWO2_W257_CEF_RECEIPT="$TMPDIR/fixture-app.json"；再跑本房指定 verify 命令（另含 tests/w257-xsmooth.test.mjs）。打包器只從已驗證本機 W248 bundle 複製 CEF，不下載或重編；保留 W248 helper 名稱並建立裸執行檔 loader 連結。
產品淨行數 +50（上限 +60）；收房 GUARD 結果以最終 room-guard 輸出為準。檔案與理由列於 w257-room-allow.txt。
未做：真 X 帳號、切换系統 VoiceOver、PGO／CEF 重編、其他效能旗標、推送／發版、另一家引擎副審。GBrain 無可用工具，未查詢。
看到的舊指示：docs/specs/097-browser-perf/spec.md:30「下次啟動：分支 `dev/macbook/w97b-pgo`（配方 `CEF_PGO=1`），mini 樹在 `/Volumes/cefvol/cef-build/work-2384915`。」未照做；本房明定不做 PGO。
越界紀錄：keyword 廣掃誤納入 tatwo-staging-reuse-in-place-contract.test.mjs；signingIdentity() 呼叫 security find-identity -v -p codesigning，列出真鑰匙圈的簽章身分，違反本房不碰真鑰匙圈的要求。測試因沒有固定簽章身分失敗；該命令不讀密碼／私鑰、不寫入鑰匙圈。已停止額外測試並保留日誌；未將任何簽章身分值寫進本報告。
