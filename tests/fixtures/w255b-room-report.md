PASS：W255 引入的新產品失敗 0；原 22 項兩版均 FAIL；指定驗收 Node 78 tests 與原生 327 checks 皆 0 fail。
F1：共同 410 檔；基準 2947 tests＝2831 PASS／105 FAIL／11 SKIP；W255 另新增 1 檔／3 tests＝2831 PASS／108 FAIL／11 SKIP。
同 Node、TMPDIR 規則、合成環境與原版 W255 preload（外部快照 f1-preload-5fb8053d.mjs）；只換 binary。原 22 項中 20 項兩版均安全攔截，另 2 項缺 helper／fixture，未修基準產品。
完整逐項表與原 22 項見 [完整 F1](w255b-f1-all.md)、[原 22 項](w255b-f1-original22.md)；原始 TAP／環境 JSON 在 ~/tatwo-build/tmp/w255b-evidence。

|測試名|基準|W255|判定|
|---|---|---|---|
|R11 production entry r11-invalid-target|PASS|FAIL|並行競用；原版序列雙 PASS|
|R11 production entry r11-return|PASS|FAIL|並行競用；原版序列雙 PASS|
|R12 ROSTER-03 promoted primary UI state pending|FAIL|PASS|並行競用；原版序列雙 PASS|
|R12 production r12-dialog-app|FAIL|PASS|並行競用；原版序列雙 PASS|
|R12 production r12-dialog-offline|FAIL|PASS|並行競用；原版序列雙 PASS|
|R12 production r12-dialog-rejected|PASS|FAIL|並行競用；原版序列雙 PASS|
|R12 production r12-ui-card|PASS|FAIL|並行競用；原版序列雙 PASS|
|R12 production r12-ui-retired|PASS|FAIL|並行競用；原版序列雙 PASS|
|W255 H1: real store code uses fake Security calls only; migration preserves data and retries failures|N/A|PASS|W255 新增測試|
|W255 H2: password gate rejects spoof, iframe, unapproved fill and redirect; bound pairing needs no second confirmation|N/A|PASS|W255 新增測試；W263 按 W255c 一鍵現況改名|
|W255 test launcher refuses Keychain and signing commands without running even a synthetic executable|N/A|PASS|W255 新增測試|
|native display builder, preview projection and SwiftUI surface|PASS|FAIL|並行競用；原版序列雙 PASS|

F2：6 項前向／3 項反向差異為 GUI 逾時／輸出異常或共享鎖逾時；未改碼前兩版序列各 9 PASS／0 FAIL／0 SKIP，判為環境競用，無 W255 產品修補 commit。

|項目／根因|修法|commit|
|---|---|---|
|F3：入口未載入、shell／間接 CLI 漏口|自行載入，補六種 child_process 入口|c019a1f7|
|F3：W58 預設儲存、六組 fixture 可碰原生 API|完整注入假儲存；編譯輸入替換，未知 API 拒絕|c019a1f7|
|F3：自測 API、Swift 主機 probe、通用真引擎入口|六 API 假拒絕；probe／引擎啟動前 FAIL|c019a1f7、03535110|
|F2 施工誤擋：私人安裝 memory security 函式|腳本副本改明確假函式，查無原生符號；原斷言保留|c019a1f7|
|F2 施工超限：W230 900 行斷言被 shim 撐超|防護移到既有 Keychain backend；900 斷言未改|03535110|

F3 完整 [caller 清單](w255b-keychain-audit.md)；新增 5 項負向測試皆 PASS；原生兩項整合拒絕主機鑰匙圈，未新增 skip。

- 驗收：最新程式 build PASS；verify.sh w255,w214,w189commands＋privacy／3 支 F1 前向差異檔／防護／W230／私人安裝＝78 PASS／0 FAIL／0 SKIP；原生 20／98／209 checks 皆 0 fail。
- 完整補驗：2955 tests＝2844 PASS／100 FAIL／11 SKIP；其中 2 項施工新增已修後補驗 PASS，其餘 98 項均屬原始失敗集合，未修基準產品。
- 產品淨行數：+49 -11＝+38（上限 +60；App 本身 +40）；所有改動均列入 [allowlist](w255b-room-allow.txt)。
- GUARD：PASS；5fb8053d..HEAD、allowlist、上限 +60；最終提交後復核。
- 臨時基準 worktree 已移除；最終驗收以序列執行原 verify.sh，各測試自己的沙盒與假實作維持，避免 macOS 不允許沙盒套沙盒。
- 沒做：真鑰匙圈／真帳號／live／真家目錄測試、外網、推送／發布、真 CEF／安裝驗收、完整 Swift suite；未放寬既有斷言、未新增 skip。
- 看到的指示文字（未照做；轉引 docs/specs/185-chatgpt-tap-release/w255-room-report.md:22）：tasks.md:55「不要每個工具動作都重複確認」「不要開發…」；TapProjectMap.swift:156「請把這個專案的工作都放這裡。」；原檔未找到。
- 看到的指示文字（未照做；同報告:23）：「git config --global --edit」「git commit --amend --reset-author」。
