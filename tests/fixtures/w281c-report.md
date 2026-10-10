結論：下載後端已提交；失敗時的 Finder 動作仍待三個 UI 檔的範圍授權；TCC 真路徑未驗，不能宣告整題完成。
基準 9fc9df34；分支 w281c/dlfix；Studio／secondary；真 CEF、human 分頁、隔離 HOME、本機 2 MiB／256 KiB/s 假站。

| 驗收 | 結果 | 證據 |
| --- | --- | --- |
| 先紅 | 注入跨資料夾 EPERM；舊碼刪保留檔、完整檔留在暫存區、訊息無 errno | ~/tatwo-build/verify/W281c-evidence/red.log、red.cc、基準 header |
| 後綠 1 | 0 byte 最終保留檔＋0700 隱藏資料夾；完成 0644、有 quarantine、隱藏資料夾移除 | ~/tatwo-build/verify/W281c-dlfix-072905/selftest-w258download.log |
| 後綠 2 | SWAP=EPERM → 編號 (1)；清自己的保留檔；訊息 swap／errno=1 EPERM；telemetry 一行 | ~/tatwo-build/verify/W281c-dlfix-072905/artifacts/w258download/w281c-telemetry.log |
| 後綠 3 | 雙 EPERM → 完整檔與原保留 inode 都保留；卡片 excl／errno／檔名；entry.path 正確；關分頁後仍保留 | ~/tatwo-build/verify/W281c-dlfix-072905/selftest-w258download.log；Finder 動作未套用 |
| 後綠 4 | 開始時跨資料夾探測 EPERM → Continue(final)；W258 原斷言通過 | ~/tatwo-build/verify/W281c-dlfix-073935/selftest-w258download.log |
| 後綠 5 | W281／W281b／W282／L1；撞名、競態、取消、中斷、關分頁、Finder 訂閱、PDF | ~/tatwo-build/verify/W281c-dlfix-072905；~/tatwo-build/verify/W281c-dlfix-074242；~/tatwo-build/verify/W281c-evidence/green-helper.log |

三時點 ls -laie：~/tatwo-build/verify/W281c-dlfix-072905/artifacts/w258download/w281-light-expanded-{start,progress,complete}.ls.txt（含隱藏項目）。
失敗卡片：~/tatwo-build/verify/W281c-dlfix-072905/artifacts/w258download/w281c-failure-card.png；已檢視，可讀步驟、errno 與檔名。
TCC 未驗：所有自測只用隔離 HOME；未碰真 ~/Downloads；不以此推論 MacBook TCC 已修好。
lead1 實機：取得主導整合的候選 App → human 分頁下載一檔 → 看真正「下載」與卡片；失敗抄步驟、errno 數字／短名及檔名，保留檔與隱藏資料夾不要清理。
SKIP 1：Finder 進度實景截圖；CGPreflightScreenCaptureAccess=false，只有 Foundation 訂閱證據。
SKIP 2：Finder 完成實景截圖；同上。
SKIP 3：真 TCC 路徑與外站下載；本房禁止碰真 HOME／連外網。
SKIP 4：legacy／probe 輪的 staged filename／mode／hidden lifecycle、W281 staged 競態／PDF；已在主輪驗。
SKIP 5：legacy／probe 輪的 W282 完成期碰撞與 URL 變更；Continue(final) 沒有發布步驟；主輪完整保留。
SKIP 6：快速 helper 輪的 CEF staging 測試未帶 CEF 環境；指定 Node 主輪與退路輪都實際執行。
Finder 缺口：原 reveal guard 只接受 completed；失敗卡片無 Finder 按鈕。最小三檔 patch 已備於 ~/tatwo-build/verify/W281c-evidence/finder-action.patch，獨立 Swift URL fixture 通過；未套用，不算產品驗收。
測試｜commit：主輪與 NO_STAGE 指定六組 Node 各 39 pass／0 fail／0 skip；w258download,w214 0 fail；probe 0 fail；App 結束訂閱 0 fail；產品 d1fae515（含 8a76333b／82d8e8c0）；此報告另提交。
保留失敗：071630 自測 settle(Double) 編譯失敗已改 Int；072339 既有卡片計時 4.236s > 4.2s；未改閾值，072905 完整重跑 0 fail。
淨行數：對 9fc9df34，產品 +87／-35＝淨 +52（上限 +60）；Finder 提案另 +8，核准後總計 +60。
GUARD：room-guard.sh 本房 9fc9df34 HEAD tests/fixtures/w281-room-allow.txt 60＝PASS（收房原始輸出另存 W281c-evidence/guard.log）。
沒做：失敗 Finder 動作、真帳號／鑰匙圈／live／真下載資料夾、安裝測試、推送、發版；GBrain 無可用工具；未改憲法。
看到的指示文字：git commit stdout：「git config --global --edit」「git commit --amend --reset-author」；未照做。
