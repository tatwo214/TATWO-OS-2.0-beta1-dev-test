結論：W281e 路徑式下載已完成並通過隔離驗收；Studio 無法驗證 MacBook「沒有下載項目權限」的 TCC 狀態，留待 lead1 實機驗。
先紅：f9a30788；M:5361/5365/5369/5376/5422/5424，H:26/27/31/32/43/65/67/69/76；open O_DIRECTORY、mkdirat、openat、renameatx_np、fstatat；NSItemReplacementDirectory 0 處；原始清單 ~/tatwo-build/verify/W281e-evidence/red-grep.log。先紅／後綠守門：W281E_SOURCE_REV=f9a30788＝1 fail／1 pass；修改後＝2 pass／0 fail；同目錄 renamex_np、禁止目錄讀取、禁止預建暫存檔；red-static.log／green-static.log 同上證據目錄。
後綠 Node：指定七組主輪與 NO_STAGE 各 41 pass／0 fail／0 skip；主輪 ~/tatwo-build/verify/W281e-dlnotcc-085545、退路 ~/tatwo-build/verify/W281e-dlnotcc-090046 的 node.log／verify.log。
後綠行為：真 CEF／human／隔離 HOME／本機限速假站；W258、W268、W281/b/c/d、W282、L1 全部原斷言 0 fail；完成 0644＋quarantine、撞名、四競態、取消／中斷／關分頁、SWAP／EXCL EPERM 卡片＋Finder URL、探測退路、PDF；~/tatwo-build/verify/W281e-dlnotcc-085545/selftest-w258download.log。App 結束：~/tatwo-build/verify/W281e-dlnotcc-090424/selftest-w258download.log；兩個並行訂閱均移除；helper 保留使用者內容／inode、連結、撞名上限、SWAP 還原失敗的復原檔。
三時點 ls -laie（含隱藏檔）：~/tatwo-build/verify/W281e-dlnotcc-085545/artifacts/w258download/w281-light-expanded-{start,progress,complete}.ls.txt；開始／中途＝0 byte 最終名＋隱藏暫存 98304／671744 bytes；完成＝暫存消失、最終 2097152 bytes／0644，同 inode 30351727。
盤點：產品下載流程只碰單檔；歷史在 Library/Application Support/tatwo2/browser-downloads.json；Swift 無需修改；無下載目錄列舉、replacement directory、createDirectory 或 getattrlist；其他目錄列舉為 profile／匯入／快取。
盤點測試：W258:60–64 檢查隔離 HOME；W268:87/149、W281:56/135 的列舉與 ls；W282 的訂閱只在此入口執行；native helper 用 mkdtemp 的合成 downloads；未列舉真 ~/Downloads。
清單位置縮寫：M＝Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm；H＝同目錄 include/TatwoDownloadReservation.h；D＝App/Sources/Tatwo2/Browser/BrowserDownloadStore.swift；F＝同目錄 BrowserWebFeatures.swift；行號以產品 commit 為準。

| 系統呼叫／API | 路徑型態 | 函式與行號 |
| --- | --- | --- |
| NSSearchPathForDirectoriesInDomains | 只取得 Downloads 字串 | M OnBeforeDownload:5327 |
| open(O_CREAT/O_EXCL/O_NOFOLLOW,0600) | 原名／編號／UUID 保留檔 | M OnBeforeDownload:5329/5334/5339 |
| fstat／close | 已建立保留檔 fd | M OnBeforeDownload:5350/5354 |
| open(O_CREAT/O_EXCL/O_NOFOLLOW,0600)／fstat／close | 兩個隱藏探測檔 | H StagedDownloadSupportError::create:30/32 |
| renamex_np SWAP／EXCL | 探測檔同目錄；EXCL 的新路徑不預建 | H StagedDownloadSupportError:36/37 |
| lstat／unlink | 自己建立或移動的空探測檔，dev/inode/regular/0 byte | H StagedDownloadSupportError:41/44 |
| renamex_np SWAP／SWAP 還原／EXCL | 隱藏暫存↔保留檔；最終候選 n=0…20；復原檔 | H PublishStagedDownload:69/77/82/91；M OnDownloadUpdated:5408/5410/5412 |
| lstat／unlink | SWAP 換出的自己空保留檔 | H PublishStagedDownload:72/75 |
| lstat／unlink | 自己空保留檔；成功另存後才清理；取消另由 CEF 清理暫存 | H RemoveEmptyDownloadReservation:16/17；M RemoveEmptyDownloadReservation:5037 |
| CEF Continue／Cancel | 隱藏暫存檔；退路最終檔；下載自己的檔案生命週期 | M OnBeforeDownload:5319/5384；CancelHumanDownloadsForClose:5071；ControlHumanDownload:5082；OnDownloadUpdated:5441 |
| open(O_RDONLY/O_NOFOLLOW)／fstat／read／close | 完成的自己 PDF；保留 W57d 簽章檢查 | M W57dIsPDF:8683/8687/8688/8689 |
| Progress fileURLKey／publish／unpublish | 保留檔→最終／失敗暫存檔 URL；無目錄訂閱 | D updateFileProgress:101/105/114/118；init:81；deinit:95 |
| URL(fileURLWithPath:)／fileExists／activateFileViewerSelecting | 完成檔或失敗保留檔／隱藏暫存檔 | D update:156；revealURL:235；reveal:239 |
| fileExists／QLPreviewPanel | 完成的自己單檔 URL | D preview:242/243；previewPanel:264 |
| NSWorkspace.open([url],withApplicationAt:)／open(url) | 已驗證完成 PDF | F openPDF:248/251 |
| NSWorkspace.open | Downloads 目錄；使用者點設定，下載期間不呼叫；列報未改 | App/Sources/Tatwo2/Shell/ChatPageSettings.swift body:424 |
| FileManager.urls／fileExists／String.write(atomically:true) | PLAN.md 候選／既有檔（可能非 App 建立）／匯出檔；獨立匯出，列報未改 | App/Sources/Tatwo2/Chat/ChatPage+Plan.swift PlanDownloadPolicy.downloadDirectory:126、availableDestination:138/146、downloadPlan:357/367/690；Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Plan.swift PlanDownloadPolicy.downloadDirectory:93、availableDestination:105/113、downloadPlan:324/334/602 |

SKIP 1／2：Finder 下載中與完成實景截圖；CGPreflightScreenCaptureAccess=false；Foundation 真訂閱通過。SKIP 3：TCC 實機／外站；本房禁止真 HOME／外網；CEF／Foundation 內部系統呼叫未 trace。
SKIP 4（NO_STAGE）：staged 檔名／mode／隱藏生命週期；SKIP 5（NO_STAGE）：staged 競態／PDF；SKIP 6（NO_STAGE）：W282 完成期碰撞與 URL 變更；三項主輪全部驗；SKIP 7：早期快速 helper 輪 CEF loader 未設 CEF env，指定兩輪均實跑。
測試｜commit：3392589c；w258download,w214 主輪與退路 exit=0；App 結束輪 exit=0；初輪 084859 驗收全過但執行中修改包裝腳本使結尾 exit=127，保留紀錄，最後版完整重跑。
淨行數／GUARD：對 f9a30788，產品 +49／-68＝淨 -19（上限 +30）；room-guard.sh 本房 f9a30788 HEAD tests/fixtures/w281-room-allow.txt 30＝GUARD PASS，~/tatwo-build/verify/W281e-evidence/guard.log。
沒做：真帳號／鑰匙圈／live／真 Downloads、安裝測試、security find-identity、推送／發版、憲法修改；GBrain 無可用工具；失敗卡片截圖已檢視（~/tatwo-build/verify/W281e-dlnotcc-085545/artifacts/w258download/w281c-failure-card.png）。
看到的指示文字：~/tatwo-build/verify/W281e-evidence/product-commit.log 的 git commit stdout：「git config --global --edit」「git commit --amend --reset-author」；只記錄，未照做。
