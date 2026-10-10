W270 已實作並提交；尚未通過完整驗收：W268 深色收起淡出斷言修正兩次後仍失敗，已依施工單停止修補。

- 1. 做到：8 組 recent click origin error=0 pt；5 秒到期與鍵盤 lower-center fallback=0 pt；只記座標、視窗與時間。
- 2. 做到：two ripples 110ms apart and eight sparks，8 組通過；A2 palette；見 light-expanded-150.png。
- 3. 做到：300ms 彈出、抬高34pt、120ms停留、760ms二次弧線、縮至0.38／−16°；exactly one file in flight，8 組通過；見 *-400.png／*-800.png。
- 4／Browser. 做到：展開側欄錨點、收起34pt浮出鈕；浮出與完成後消失皆通過；light/dark-expanded/collapsed 全部真 CEF。
- 4／GPT Space. 做到：production GPT mounts CEF、頁面左下浮出鈕／卡片；gpt-{0,400,1200,complete}.png。
- 4／私訊框. 做到：production DM mounts same human page／DM Dots mounted；卡片界線皆在網頁內；dm-*.png／dots-*.png。
- 4／Coder. 做到：Coder mounts real CEF、飛到工具列既有下載鈕、卡片在網頁左下；coder-*.png。
- 4／備援. 做到：無錨點只顯示卡片、不飛；fallback card bounds=(14,368,280,68)pt；fallback-card.png。無宿主時可用目前視窗最後登記錨點。
- 5. 做到：下載圖示1→1.25→1、34pt光環擴至2.6倍／560ms、箭頭下沉；共用漸層#9b7cf0→#5b3cc4與260ms卡片過場；見 *-1200.png。
- 6. 部分做到：rendered checkmark／completion particles=6／未讀保留均通過，W270 4秒收起誤差最大0.016s；W268 dark-collapsed card faded after 4s and arrow restored 仍 FAIL（timeout=4.176s），見 w270-known-failure.txt。
- 7. 做到：系統 accessibilityReduceMotion 與 W268 override 共用判定；reduced no file or particles／completion particles=0 通過；reduced-*.png。未更動實機系統偏好。
- 8. 做到：3 筆真下載，queue maximum simultaneous file count=1；第二筆保留原點排隊，第三筆直接落地，all three real downloads complete。
- 9. 做到：Core Animation／SwiftUI，沒有逐格計時器；animation overlay passes clicks 與 input receives click and typing during animation，8 組通過。

截圖根：tests/fixtures/w270-shots/；Browser {light,dark}-{expanded,collapsed}-{0,150,400,800,1200,complete,complete-plus-5s}.png 共28張；{gpt,dm,coder}-{0,400,1200,complete}.png 共12張。
補充：同目錄 dots/reduced 各4張、fallback-card.png；tests/fixtures/w270-prototype-A2-400.png；失敗原圖 tests/fixtures/w270-w268-dark-collapsed-faded.png。
量測：tests/fixtures/w270-measurements.json；終點最大誤差1.14e-13pt；完成圖取事件後180ms，完成+5s圖取4秒dismiss後約1秒，JSON註明各參考時鐘。
測試｜verify/W270-dlfly-190653：CEF建置0、Node34/0、w270dlfly190/0；verify/W270-dlfly-185557：w258download 1 fail（W268168/1）、w24875/0、w265141/0、w26960/0。
限制：w269 browserMounted=false，其 Browser 比較未驗證，不列通過；Browser 動畫另有 W270 真 CEF 證據。
安全｜verify/W270-dlfly-191153：不帶CEF建置0、W178安全＋隱私19/0；otool無CEF連結。
commit｜產品、自測、截圖與失敗紀錄：40ebf705；本報告為後續文件提交；分支w270/dlfly，未推送。
淨行數｜對dc6a2c27：產品+294 −30＝+264（上限300）；GUARD PASS；所有改檔與理由見tests/fixtures/w270-room-allow.txt。
沒做｜未達指定回歸0 fail；未跑MacBook實機、未安裝／發布、未改TatwoCEFBridge.mm或下載保留／暫存邏輯。
邊界紀錄｜曾列真家目錄Library/Logs/DiagnosticReports檔名，未讀診斷內容；自測使用隔離home、本機假站與fixture憑證。
看到指示｜BrowserDownloadFeedback.swift:80「已下載 · 點此在 Finder 顯示」；未依文字開Finder。
看到指示｜W270-prototype.html:99「你選了 A，這版把點擊效果加強了。照 TATWO OS 的 Browser 真實擺法做：左欄 250 寬、左下是下載鈕。按畫面裡的「Download Notchy」看按下去那一刻的動畫；可以切到「A 原版」比較。」只依施工單測A2，未採額外指示。
看到指示｜git commit輸出「git config --global --edit」「git commit --amend --reset-author」；未執行。
