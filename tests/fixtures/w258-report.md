Studio 未重現 MacBook 故障；A–E 與 notchy 真站均到下載回呼，原問題的根因與修復尚未完成。

| 案例 | 修前／交付後（未改下載行為） | 點擊後回呼 |
|---|---|---|
| A 同站附件 | 成功／成功 | Browse → Can → Before |
| B 跨站三次 302 | 成功／成功 | Browse → Redirect×3 → Can → Before |
| C target=_blank | 成功／成功 | Popup → 新 human 分頁 Browse → Can → Before |
| D location.href | 成功／成功 | Browse → Can → Before |
| E download 屬性 | 成功／成功 | Can → Before |
Browse=OnBeforeBrowse；Can=CanDownload；Before=OnBeforeDownload；Redirect=OnResourceRedirect；Popup=OnBeforePopup。
A–E 的 OnOpenURLFromTab 均未呼叫；各檔均 starting→completed，隔離 HOME/Downloads 的檔名與內容正確。
Agent：真 CEF 點附件到 CanDownload 後被擋；下載事件 0、agent.bin 不存在。
根因：未定位。TatwoCEFBridge.mm:5268 允許 human；:5281 的 OnBeforeDownload 確實收到附件，未見 Space 路由／about:blank 攔截證據。
改動：w258download、自動建立隔離 CEF bundle／假站、DEBUG fixture 入口、只記回呼名稱與主機的 trace；未改產品下載策略。
Commit：本提交，分支 w258/download，基準 c901ffff；全部 9 個檔案與理由見 w258-room-allow.txt。
D4：只點一次；release-assets 主機到 Can／Before，CEF 收到 82,973 bytes，cancel=true；取消後僅剩 A–E，沒有 Notchy 暫存檔。未保留磁碟 stat。
D4 腳本因目錄 URL 尾端斜線比對誤判而 exit=1；已改比較標準化 path，依一次限制未重跑真站。
驗收：build 0；Node 55/0、1 skip；啟用 TATWO_BROWSER_TABS_NATIVE=1 補跑 3/0、0 skip；w258download 26/0、w209spotify 78/0、w214 98/0、w250picker 180/0；無巨集失敗。
驗收證據：~/tatwo-build/verify/W258-download-004820/；原生補跑：~/tatwo-build/tmp/W258-download/native-tabs.log。
修前證據：~/tatwo-build/verify/W258-download-004154/；D4：~/tatwo-build/tmp/W258-download/run-real-FTTeiL/run.log。
產品淨行數：+33 −1＝+32（上限 +60）。
GUARD：PASS（room-guard.sh c901ffff HEAD，9 檔符合 allow，產品淨 +32／60）。
沒做：未定位／修復原 MacBook 故障；未核驗已裝 App、未碰真帳號／鑰匙圈／live／真家目錄資料、未安裝／推送／發版；GBrain 無可用本機工具。
看到的指示文字：W258-download-004020/artifacts/w258download/startup.png（源碼 EmbeddedBrowserProfile.swift:840）「請到設定 › 瀏覽器管理清除資料。」；未照提示清除資料，只建立隔離夾具目錄。
看到的指示文字：git commit 輸出「git config --global --edit」「git commit --amend --reset-author」；未修改全域設定或重設作者。
