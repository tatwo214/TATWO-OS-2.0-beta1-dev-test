結論：W281f 主路完成；指定主輪／退路皆 0 fail；退路 255 位元組 ASCII 仍中斷，明列 SKIP，不算通過。
先紅（92e37c2c）：中文 80 字＝244 bytes，實際隱藏檔名 297 bytes，完成而非中斷；英文主檔名 240 bytes＋.bin＝244 bytes，中斷錯誤 1；helper 252→256 bytes，errno=63 ENAMETOOLONG。
後綠真 CEF：80 中文字原名 244 bytes／隱藏 152 bytes；240 bytes 英文主檔名＋.bin＝244 bytes／隱藏 153 bytes；255 bytes ASCII 原名也完成；全部 0644、2 MiB 正確、隱藏檔完成後移除。
後綠撞名：中文 253→254 bytes、ASCII 255→255 bytes，截主檔名＋「 (1).bin」，原內容／inode 不變；EXCL 編號與 UUID 保底皆 255 bytes／隱藏 153 bytes／0644。
helper 32 組：短 9→13/14、250→254/255、252/255→255、中文 253→254/255、家庭 emoji 254→233/234、組合字元 253→254/255、旗幟 252→248/249 bytes；UUID 46–255 bytes；UTF-8、完整組合字元與副檔名全部通過。
極端副檔名：255 bytes 首次主路下載成功；編號／UUID 加完整副檔名自身超限時拒絕空候選；保留使用者 bytes／inode；不存在的 Downloads 不會被誤建為檔案；helper 保持 ENAMETOOLONG。
測試｜產品 commit 82922930（前件 420ab2b2）：主輪 Node 41／W258 32／W268 169／W214 98 pass；退路 Node 41／W258 31／W268 121／W214 98 pass；兩輪 0 fail、Node 0 skip；W281/b/c/d/e、W282、L1 原斷言通過；App 結束兩個並行訂閱均移除、exit=0。
證據：~/tatwo-build/verify/W281f-dllong-093121（主）、-093801（退）、-094322（App 結束）、-091719（基準 CEF）；W281f-evidence/{red-helper,green-helper,red-extension-helper,green-static}.log；隔離 HOME／本機假站／mock keychain。
SKIP 1：Finder progress 截圖，主輪／退路均 window unavailable；Foundation 訂閱與進度斷言有實跑。
SKIP 2：Finder completed 截圖，主輪／退路均 window unavailable。
SKIP 3：W258 D4 公開真站，使用者禁止連外網；沒有嘗試。
SKIP 4：GBrain 查詢，沒有可用工具。
SKIP 5：NO_STAGE 的 255 bytes ASCII 原名／撞名／EXCL／UUID 真 CEF 案例；首輪 -092629 有 14 個失敗斷言，實際中斷錯誤 1；舊 Continue(final) 保留，主輪與 helper 完整驗過這些案例。
SKIP 6：NO_STAGE 的首次 255 bytes ASCII 長副檔名下載；主輪已驗；退路以合成原檔驗撞名／資料夾不存在兩個保護案例。
SKIP 7：NO_STAGE 既有 staged 檔名／mode／隱藏生命週期斷言；主輪完整驗；新增退路長檔名 244、253、254、244 bytes 完成且維持 0600。
SKIP 8：NO_STAGE 既有 staged 競態／PDF completion；沒有發布步驟；主輪完整驗。
SKIP 9：NO_STAGE W282 完成期碰撞／URL 變更；Continue(final) 沒有發布步驟；主輪完整驗。
淨行數／GUARD：對 92e37c2c，產品 +30／-7＝+23（上限 +25）；room-guard.sh 本房 92e37c2c HEAD tests/fixtures/w281-room-allow.txt 25＝GUARD PASS；最終輸出 W281f-evidence/guard.log。
看到的指示文字：~/tatwo-build/verify/W281f-evidence/edge-commit.log:9「git config --global --edit」；:13「git commit --amend --reset-author」；只記錄，未照做。
診斷更正：舊退路日誌的「.crdownload suffix」是未查證的推斷；只確認 Continue(final) 在 255 ASCII bytes 中斷；測試 SKIP 文字已更正，原始失敗日誌保留；沒有更改退路或放寬 W258。
