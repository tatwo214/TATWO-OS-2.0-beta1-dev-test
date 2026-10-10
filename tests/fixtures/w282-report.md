結論：程式、訂閱與取消驗收完成；Finder 實景未驗收，缺下載中／完成兩張截圖。
做了：每個 human 下載 ID 一個檔案 Progress，starting 有 path 才 publish；更新位元組；未知大小 indeterminate；終態與 App 結束 unpublish；Finder 無暫停。
訂閱：真 CEF／human／隔離 HOME／本機 2 MiB、256 KiB/s；同行程 Foundation addSubscriber(forFileURL:) 收到檔案進度代理。
fractionCompleted：19 個不同值，0 → 0.0625 → 0.234375 → 0.515625 → 0.796875 → 0.96875 → 1；單調增加；published=1、removed=1。
撞名：slow-w282-collision (1).bin 訂閱成功，原檔無發布；完成才撞名時，舊 URL 移除、新 (1) URL 發布後移除。
取消：訂閱代理 cancel() → cancellationHandler → BrowserDownloadStore.cancel(current) → 原 Controls.cancel → 原 human CEF cancelDownload；狀態 cancelled、progress 移除。
訂閱證據：tests/fixtures/w282-subscriptions.json；原始回呼／失敗／並行／未知大小見 ~/tatwo-build/verify/W282-dlprogress-062208/selftest-w258download.log。

| 驗收 | 結果 | 證據（~/tatwo-build/verify/ 下） |
| --- | --- | --- |
| 指定四組 Node | 30 pass／0 fail／0 skip | W282-dlprogress-062208/node.log |
| w258download,w214 | W258 30、W268 141、W214 98 pass；W281／W281b／W282 0 fail；兩個行程 exit=0 | W282-dlprogress-062208/verify.log |
| App 結束 | 獨立真 CEF 行程同時兩個下載；結束通知後兩個訂閱都移除；exit=0 | W282-dlprogress-062534/selftest-w258download.log |

Finder 截圖路徑：無檔；下載中／完成兩張均未取得；不宣稱 Finder 已畫出進度條，也未判定隔離 HOME 不支援。
SKIP 1：Finder 下載中；SKIP 2：Finder 完成；App 回報 CGPreflightScreenCaptureAccess=false；AppleScript 開窗兩次未返回後停止，未更動系統權限。
SKIP 3：外站 Notchy 未啟用，依本房禁外網；CEF 版本與 wrapper 沿 W248b environment.txt；未用 stub。
首輪失敗保留：W282-dlprogress-061734 的結束通知關閉 CEF，影響後續 W268；已拆獨立行程；062310 的切頁時序失敗已補等 starting／publish，062534 通過。
測試｜commit：99e7b977（產品、驗收與原始訂閱資料）；本報告另提交；最後僅新增報告與原始 JSON，再跑 public-privacy。
淨行數：對 4492f29c，產品 +32／-0＝淨 +32（上限 +40）；逐檔理由見 tests/fixtures/w282-room-allow.txt。
GUARD：room-guard.sh 本房 4492f29c HEAD tests/fixtures/w282-room-allow.txt 40＝PASS；TatwoCEFBridge.mm 未改。
沒做：Finder 實景驗收、真帳號／鑰匙圈／live／真下載目錄、安裝測試、推送／發布；GBrain 無可用工具；未更改入口憲法。
看到的指示文字：git commit stdout：「git config --global --edit」「git commit --amend --reset-author」；只記錄，未照做。
