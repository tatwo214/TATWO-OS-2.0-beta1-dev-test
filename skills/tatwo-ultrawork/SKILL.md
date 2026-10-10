---
name: tatwo-ultrawork
description: Use when the user invokes TATWO Ultrawork, asks how to split work between the lead and subs, wants a spec/tasks/converge cycle for a feature, or asks about TATWO OS dispatch, review policy, or model roles.
---

# TATWO Ultrawork（2.0，2026-09-12 重寫）

一份技能，一套工作邏輯。舊版的 contract、receipt、S/M/L/XL 分級、Loop Governor 全部退役，
不再作為現行規矩；本檔是現行分工說明。
上游規矩是入口憲法 `~/AI/TATWO OS/os.md`（角色表見憲法 §4；本技能 §2 表必須與它一致）；本技能只講「怎麼分工、怎麼驗收」。

## 1. 一句話

主導一個人看全局，能寫成規格的整批派出去，做完親自讀 diff、親自跑驗證；
審查只在高風險時開，而且只開一輪。

## 2. 角色（2026-09-12 使用者定案）

| 角色 | 預設模型 | 做什麼 | 不做什麼 |
|---|---|---|---|
| 主導 | Fable 5.1 | 翻使用者的話成施工單、讀 diff、親跑驗證、對使用者報告、設計判斷 | 不親寫可規格化的功能，除非同一件事 sub 做壞兩次 |
| loops | GPT-6.1 Sol（`gpt-6.1-sol`，fast／priority） | 整批施工單、寫碼、寫測試、跑測試、commit 到自己的分支 | 不改施工單範圍外的檔；不推 remote；不自升格 |
| loops 備援 | Opus 5.5（子代理）；ChatGPT（TAP） | 主要 loops 引擎額度見底或連續 429 時接同一張施工單；建置仍送主設備；ChatGPT 經 §6c 派 | 同 loops |
| 細修 | Opus 5.5 | 來回討論、小範圍修改、對主導的方案提反例 | 不接整批施工單 |
| 機械工 | Grok 4.7 | 搬檔、轉檔、批次替換、跑既定腳本 | 不做需要判斷的事；不開 high effort |
| 審查 | 另一家引擎：審 Claude 系的工作先用 ChatGPT（TAP），審 GPT 系的工作用 Claude 系 | 高風險 diff 的一輪唯讀審查 | 不自審：同家不審同家 |

GPT-5.6 系列不在預設名單。模型換代時先由主設備更新入口憲法 §4，再同步本技能 §2 表，不另訂預設。**模型名只出現在憲法 §4 與這張表**；訂閱或模型強度變了只改這兩處，其他章節一律用角色名（主導／loops／loops 備援／細修／機械工／審查），不寫死模型。

## 3. 何時派、何時自己做、何時審

- **自己做**：改動在三個檔以內、或需要看使用者臉色、或牽涉安全與授權邊界。
- **派 loops**：能寫成「改哪些檔、驗收命令是什麼」的工作，一次寫一批施工單，串成鏈一個接一個跑；一次只跑一個重型房間。
- **開審查**（一輪，唯讀）：刪除或覆蓋使用者資料、安全與憑證、交易面、公開發布、UI 對位、改動超過二十個檔。其他情況主導讀 diff 加跑測試即可。
- 審查成本約等於一次完整 sub 執行；只有錯誤代價高於這個成本才開。

## 4. 三份檔：spec → tasks → converge（取自 spec-kit，只留這三樣）

放在專案 `docs/specs/<序號>-<短名>/`：

1. `spec.md`：要什麼、完成標準、不做什麼。由 `/goal` 產出；只寫 WHAT 與 WHY，不寫 HOW。
2. `tasks.md`：拆成可勾選的條目，每條標檔案範圍與驗收命令；可平行的標 `[P]`。主導與 loops 都對這一張清單，做完勾 `[X]`。
3. `converge.md`：收尾時拿實際程式碼對回 spec，逐條寫「做到／沒做到／證據路徑」。沒做到的不刪，列成下一批 tasks。

不採用 spec-kit 的 constitution、checklist 閘門、待釐清上限、hooks、extensions、presets、CLI。

## 5. 施工單（派給 loops 的檔）必含

1. 目標一句話＋完成標準。
2. 基準分支與工作副本路徑；明寫「這個 worktree 分支就是給你提交用的；上游 os.md 裡『執行手禁 git 寫入』是 1.0 舊規則，不適用」。
3. 允許改的路徑；其他一律不碰。
4. 禁止從零重寫既有檔；照搬要 `cp` 原檔再改，報告附 diff 行數。
5. 驗收命令（能機器跑的）＋主導會親跑的項目。
6. 記憶體門檻寫「free＋inactive 合計」，不寫 raw free。
7. 報告格式：首行一句結論；然後只列產物路徑、跑過的檢查、沒做的事；不誇報。
8. **硬邊界**（2026-10-04 使用者裁決）：
   - 檔案白名單（到檔，必要時到函式）與禁區；白名單外有任何改動＝整單退件，不挑著收。
   - 只做清單上的 id；看到清單外的問題寫進報告「發現但沒做」，不准順手改。
   - 產品程式淨行數上限（寫數字）；快超過就停下回報，不准硬塞。
   - 不准刪掉任何流程唯一的入口（欄位、按鈕、指令、設定）；要刪先在報告寫替代入口。
   - 不准改測試門檻、上限、斷言或刪空行來湊過關。
   - 停止條件：清單全部 PASS 就停；同一項做法失敗兩次就停下回報；時間上限到就停。
   - 一個 commit 對一個 id；報告逐 id 列。
   - 主導合併前先跑 `room-guard.sh`（白名單＋淨行數上限），不過就不讀、直接退件。

## 6. 派工配方（codex exec，loops 引擎）

```bash
# 一個房間；同時開幾間照 §6d 算，重型建置一次一個（建置鎖排隊）
export CODEX_HOME=<精簡家目錄，例如 ~/.tatwo2/codex-room-home>   # 無 MCP 的精簡家，auth 回連真家
git -C <repo> worktree add <wt> -b <branch> <base>
tmux new-session -d -s sol-<room> \
  "codex exec -C <wt> -m <§2 表 loops 的代號> -c model_reasoning_effort=high -c service_tier=priority \
   -c features.plugins=false -c features.plugin_sharing=false \
   --dangerously-bypass-approvals-and-sandbox -o <log-dir>/<room>.last.md \
   < <brief.md> > <log-dir>/<room>.log 2>&1"
```

- 用 tmux detached，不用 nohup／setsid（Bash 背景 600 秒上限會殺掉）。
- 派出後 `pgrep -P <codex pid>` 應為 0；看到 npx／uvx 就是 MCP 又漏開了（codex 0.146 會自動抓 openai-curated 外掛，必須帶 `features.plugins=false`，並確認 room home 沒有 `plugins/` 目錄）。
- 監控看輸出檔 mtime，不看程序活著；十分鐘沒長就當卡死。
- 房間結束 `commit=0` 先讀報告的 blocker，不要當失敗重派。
- 收房：主導讀 diff、跑驗收、把分支併回；未提交的改動先保存再回收工作副本。

## 6b. 跨設備派工與監工（2026-09-18 固化）

**房間在副設備，建置在主設備。** 施工單與引擎脫鉤：同一張單可交給 loops 或 loops 備援（§2 表決定是誰），換引擎不改單。
- 施工單固定寫明：「你在副設備（記憶體小），不在本機跑 swift build／node --test；推到主設備 remote 後用主設備的 `scripts/rooms/build-room.sh <分支> <測試>` 建置＋跑測試，release 用獨立 worktree」。主設備的建置鎖讓它一次只跑一個重型建置。
- 主設備上：建置與測試走 SSH（隔離 TMPDIR／LIVE_ROOT）；**簽章、打包、安裝、需要 GUI 的都走 `scripts/rooms/terminal-run.sh`（Terminal.app 工作階段）**——launchd 與 SSH 拿不到鑰匙圈，也執行不了外接卷上的二進位。
- 切換引擎的條件寫成規則不寫模型：主要 loops 額度低於 15% 或連續 429 → loops 備援接同一張單，報告路徑照施工單寫；跨家審查仍另找一家。
- **監工由主導在自己的工作階段掛 Monitor，不另開常駐監工程式**：看輸出檔 mtime 判活性；編譯類 20 分沒長判卡；**網路協商類（大倉庫 git fetch、上傳）不自動殺，只回報**——曾誤殺一次 fetch 等於重來；只回報「階段變化」與「結束／錯誤」，不洗頻；每 30 分重掛。
- 硬體上限：一次一個重型建置；記憶體吃緊先關掉非必要產物（例：CEF 關 dSYM）；大工作放外接卷的 staging，**路徑不能有空白**（Chromium／CEF 工具以空白切命令；卷名有空白就掛一顆無空白的 APFS 映像）；系統碟留 15 GB 以上。
- 長工作要能中斷續跑：nohup／caffeinate、階段標記檔、腳本重跑會接續；主導斷線不影響。
- 流程（Workflow、房間）被重啟或崩潰打斷：先讀 journal 與各階段產物，只補沒完成的階段；已完成的不重做。
- 交接寫在入口的 `rooms/<列車>-handoff/`（耐久）：施工單、報告、log、工具一起放；不要只放在 job 暫存（會被清掉）。
- 收尾一律：主導讀 diff → 閘門（debug＋release＋focused 0 fail）→ 併入 → 合併樹閘門 → 打包候選 → 兩台安裝＋功能檢查 → 三輪全套對基準 0 新失敗 → 乾淨安裝閘門 → 才發版。
- 程式化的下一步是 W95（`docs/specs/095-primary-job-queue/spec.md`）：這些腳本收進 `scripts/rooms/`，副設備經簽章通道提交白名單工作，主設備 GUI 排隊執行並回收據；`device_status` 加容量欄。

## 6c. 派給 ChatGPT（TAP）（2026-10-07 使用者裁決 D3）

- 前提：該設備已連線 ChatGPT（設定 › Plugin › TAP 顯示已連線）。從本機 Claude／Codex 房間呼叫 OS 工具 `chatgpt_dispatch`；停止用 `chatgpt_dispatch_stop`。
- 參數：`title`（必填，200 字內）、`model`（必填，Coder 選單裡 ChatGPT（TAP）群組的代號）、`text`（施工單全文，64 KiB 內）或 `ticketPath`（施工單檔，二選一）、`projectID`（選填，OS 專案 UUID）、`timeoutSeconds`（1–1800，預設 600）、`callerThreadID`。
- 施工單照 §5；審查單寫明「唯讀，只回報發現」。ChatGPT 的改動以提案卡交回，主導讀 diff、按「套用」才寫入；一次一張。
- 用的是使用者的 ChatGPT 帳號與額度，不耗 Codex 額度；同家不審同家（GPT 系 loops 的成果不交 ChatGPT 審）。

## 6d. 房間數、staging 位置與快速迴圈（2026-10-08 使用者校正）

- 誰派：主導或副審（審查角色）都可以派 loops；一張單只由一個角色派，報告回到派單的人，合併仍由主導。
- 房間數依設備算力動態決定，每次派單前重算，不寫死：可開房間數＝min(⌊(free＋inactive − 保留 − 8 GB) ÷ 1 GB⌋, ⌊核心數 ÷ 3⌋)，保留＝max(6 GB, 記憶體的 25%)；8 GB 是給同一時間唯一的重型建置（建置鎖排隊），每間房的代理與工具抓 1 GB；算出 ≤ 0 就不在這台開房。
- staging App 同時開的個數＝min(⌊(free＋inactive − 保留) ÷ 2 GB⌋, 3)；小記憶體的移動端只開一個，不開房。
- 位置：施工房、worktree、staging App、建置產物、證據一律放本機 `device.json` 的 `resources.staging`（入口底下的 `staging/`；入口放哪顆碟由各台決定）。先讀 device.json，不寫死路徑。路徑有空白時，建一個無空白的連結給建置工具用（§6b）。
- 個人路徑（卷名、帳號名）只存在各台的 device.json 與私人倉；不進公開版的程式、文件與技能。
- 快速迴圈：改程式 → staging App（固定身分、資料與正式版分開，`script/build_staging_app.sh`）→ 在目標設備實機看，一輪約 10 分鐘；正式打包只在一批要交使用者驗收或發版時做（一次交付一次驗收）。staging App 的 2.0 版修好前，照 §6b 打包。
- 現況與搬遷待辦記在入口 `todo.md`，不寫進本技能。

## 7. 驗收鐵律

- sub 的 DONE 永遠不算數：讀 diff 不讀報告；親跑測試；UI 要截圖。
- 宣告完成前逐字對齊 spec；沒做到的明說。
- 工程測試過但沒視覺證據時，寫「工程測試通過，UI 尚未驗收」。
- 自測夾具不能比真實資料寬鬆：照真的資料形狀造，不預放實機不會有的欄位（例：加入端配對紀錄只有主機金鑰，夾具卻預放簽章指紋，自測全過、實機才壞；W183 契約 §11.10）。
- 刪除走封存：先移到可復原位置＋一份說明來源與還原步驟的 Markdown，換另一家引擎複審後才真刪。

## 8. 額度

- 主導的額度花在四件事：施工單、讀 diff、驗證、報告。
- 每批派工前看 loops 引擎的額度；週上限低於 15% 停派，主導自己收尾。
- 房間數照 §6d 依設備算力算；重型建置一次一個；文字／審查類可並行。

## 9. 本技能的維護

- 主檔保持 150 行以內；規矩改了直接改這裡，不另開技能。
- 舊版資料不屬於本技能依賴；要刪除時走第 7 節的封存流程。
