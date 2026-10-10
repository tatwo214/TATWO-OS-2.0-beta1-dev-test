結論：D1–D4 已實作，真 CEF／human 分頁驗收全過、16 張原始截圖逐張自檢；D5 查明後保留現狀，交主導決定，未宣稱已發行或實機安裝驗收。
D1 做到：加權合計進度環、未知大小轉弧、箭頭 0.34 秒落回；`start arrow drops`、`arrow returns within 0.4s`、`progress monotonic`、`aggregate weights bytes across downloads` 通過。
D1 完成：滿環／勾號約 1.2 秒；自測確認 1 秒仍有勾、1.3 秒還原，並檢查原生視圖 rendered completed／idle；見 expanded-complete／faded 圖。
D2 做到：卡片在側欄按鈕上方或收起時網頁左下角；檔名／類型／位元組／細進度、最新下載＋其餘數量、完成 Finder 揭示入口、失敗原因與重試。
D2 `visible within 300ms`：light-expanded 40.0 ms、light-collapsed 19.6 ms、dark-expanded 24.4 ms、dark-collapsed 20.4 ms（原生點擊至卡片／可見側欄進度環）。
D2 `card timeout measured`：依上列順序 4.006／4.002／4.092／4.053 秒；`input focus retained while card appeared` 通過，原生按鍵 x 仍進入網頁輸入框。
D2 `failure card persists beyond 4s`、`native retry button starts a new CEF transfer` 通過；完成點卡片沿用 reveal，未實際開啟 Finder。
D3 做到：`completion unread badge`、`unread cleared by list` 通過；實際按下載鈕開清單即清除，還原舊歷史與重複完成不會點亮。
D4 做到：`progress publications at most 10Hz`、`reduce motion no arrow drop or arc rotation`、`unknown total rotating arc enabled` 通過；固定尺寸 overlay，側欄不跳動。
D4 驗收以隔離環境 override 開啟減少動態；產品同時讀系統 accessibilityReduceMotion（系統 true 優先），沒有改真系統偏好。
D5 未改：bridge 以 O_EXCL／O_NOFOLLOW、0600 獨佔保留最終路徑，再把既有路徑傳給 CEF Continue；介面接受路徑，不能傳保留的 descriptor。
D5 實測根因：原檔 inode 28220211／0 byte／0600；Chromium 寫 (1) 檔 inode 28220210／0644；完成最終檔 inode 28220210／2097152 byte／0600，(1) 消失，顯示引擎搬回且沿用保留權限；bridge 無合併／chmod 程式。
D5 決定：不能安全地先移除獨佔保留；完成 inode 已更換，按路徑 chmod 可能碰到使用者替換檔。建議另案以私有暫存位置＋descriptor 所有權完成搬移，補競態／符號連結驗收；此房不放寬 W258 保護。
D5 證據：tests/fixtures/w268-d5-lifecycle.json；僅把原始 JSON 欄名 name 改為 filename 以符合公開隱私掃描，數值未改；原件在下列收據 artifacts/w258download/。
測試：swift build exit=0（未遇巨集外掛失敗）；Node 56 pass／0 fail／0 skip；W268 113／0、W258 27／0、w209spotify 78／0、w214 98／0、w250picker 180／0。
收據：verify/W268-dlanim-044648/verify.log、selftest-w258download.log；環境沿 W248b，SWIFT_DRIVER_SWIFT_FRONTEND_EXEC 已移除；下載全在隔離 HOME、本機 2 MiB／256 KiB/s 假站。
截圖：tests/fixtures/w268-shots/light-expanded-start.png；tests/fixtures/w268-shots/light-expanded-progress.png；tests/fixtures/w268-shots/light-expanded-complete.png；tests/fixtures/w268-shots/light-expanded-faded.png。
截圖：tests/fixtures/w268-shots/light-collapsed-start.png；tests/fixtures/w268-shots/light-collapsed-progress.png；tests/fixtures/w268-shots/light-collapsed-complete.png；tests/fixtures/w268-shots/light-collapsed-faded.png。
截圖：tests/fixtures/w268-shots/dark-expanded-start.png；tests/fixtures/w268-shots/dark-expanded-progress.png；tests/fixtures/w268-shots/dark-expanded-complete.png；tests/fixtures/w268-shots/dark-expanded-faded.png。
截圖：tests/fixtures/w268-shots/dark-collapsed-start.png；tests/fixtures/w268-shots/dark-collapsed-progress.png；tests/fixtures/w268-shots/dark-collapsed-complete.png；tests/fixtures/w268-shots/dark-collapsed-faded.png。
commit：產品與驗收程式 9a087c9b；截圖、D5 量測及本報告另提交在本分支 HEAD；沒有 push。
淨行數：對 4d2977f7，產品 +161／-12＝淨 +149（上限 +180）；逐檔理由見 tests/fixtures/w268-room-allow.txt。
GUARD：room-guard.sh 工作副本 4d2977f7 HEAD tests/fixtures/w268-room-allow.txt 180＝PASS；四個 W267 禁改檔未動。
沒做：D5 引擎／權限改動、外站 Notchy 重試、真帳號／鑰匙圈／live、安裝／推送／發行；GBrain 工具不可用，未登錄 GBrain；主導仍須逐圖驗收。
看到的指示文字（照抄、未照做）：BrowserDownloadFeedback.swift:69 完成卡片「已下載 · 點此在 Finder 顯示」；本機假站下載連結「Download slow」，焦點回顯「Focus:INPUT Typed:x」；無外站指示。
