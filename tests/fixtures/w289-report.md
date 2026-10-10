未完成：工具已施工；關窗夾具兩次修正仍失敗，依邊界停止。GPU 欄位未取得。

1. 開關：做到。使用環境變數 `TATWO_X_DIAG=1`，預設關；關閉 135 秒，`x_diag` 0 行、CDP 回覆 0 次。
2. 取樣：部分做到。每 5 秒、可見 X 頂層、純數字、跨文件重設基準；短測有 2 行。GPU PID=0、footprint/CPU=null；開啟兩分鐘未驗收。
3. A/B：程式與單測做到。`TATWO_X_DIAG_NO_INJECT=1` 跳過 X 活動腳本，頁內欄位預設 null；真 CEF A/B 未驗收。
4. 整理：做到。`python3 scripts/x-diag-summary.py <遙測檔>` 輸出每分鐘表；計數／時長／heap 與 Nodes 增量加總，絕對值平均，延遲及壓力最大值取 max。

假站兩分鐘表：未取得。以下為 15 秒短測的每分鐘摘要；只有 1 列，不能補成 3 列。中位數欄為區間中位數的平均。

| run | browser | generation | minute | samples | JSHeapUsedSize | JSHeapTotalSize | Nodes | JSHeapUsedSizeDelta | JSHeapTotalSizeDelta | NodesDelta | LayoutCount | LayoutDuration | RecalcStyleCount | RecalcStyleDuration | ScriptDuration | TaskDuration | documents | nodes | jsEventListeners | loafCount | loafMs | imageCount | imageMedianMs | imageMaxMs | videoWaiting | videoStalled | rendererPID | rendererFootprintBytes | rendererCPUSeconds | gpuPID | gpuFootprintBytes | gpuCPUSeconds | swapBytes | memoryPressure | sampleSeconds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 1 | 1 | 2 | 870746.000 | 2359296.000 | 2164.500 | -345100.000 | -1048576.000 | -999.000 | 29.000 | 0.001 | 29.000 | 0.001 | 0.100 | 0.232 | 1.000 | 2164.500 | 107.000 | 2.000 | 141.700 | 24.000 | 0.100 | 95.200 | 1852.000 | 1.000 | 10339.000 | 77686320.000 | 0.012 | 0.000 | - | - | 0.000 | 1.000 | 5.000 |

額外負擔：未驗收。關閉 135 秒主程序 CPU=3.259%；開啟 15 秒=4.752%；兩段長度不同，不能宣告增加 <2%。
測試｜commit：產品 `96a8c6ed`；CEF 最終建置 exit=0、Node 56/0/0，最終增補 10/0/0、新檔納入後隱私 13/0/0；w258download 449 PASS／0 fail、w248webspace 75/0，兩輪 exit=0。
證據：`~/tatwo-build/verify/W289-xdiag-{045319,045728,050212}/`；`~/tatwo-build/tmp/W289-xdiag/{native-2,smoke,smoke-2}-run.log`；原始短測 `tests/fixtures/w289-short-samples.txt`。
淨行數：對 2f34610e，產品 +197（不含 tests/ 與整理腳本）；GUARD 計入整理腳本後 +240，均 ≤250；所有改檔與理由在 w289-room-allow.txt。
GUARD：PASS（收房指令與輸出已核對）；分支 w289/xdiag，未推送。
沒做：X 效能修正、真 X／帳號／鑰匙圈／live／真家目錄的執行測試、MacBook 實測、發布；GBrain 無可用工具。下載／TAP／ChatGPT Space 產品邏輯無改動。
阻礙：本機 CEF GPU 使用一般 Helper 名稱，現有名稱比對找不到；原生夾具關窗兩次修正仍 exit=3，停止該驗收，沒有放寬檢查。
看到指示文字：舊收據「請到設定 › 瀏覽器管理清除資料。」；Git 輸出「git config --global --edit」「git commit --amend --reset-author」。均未照做。
