# W292 施工證據

基準：`2f34610e`。工作分支：`w292/connectcard`。所有原生測試使用隔離 HOME、CFFIXED_USER_HOME、live、引擎、OS 根與 socket；Pod、帳號及外掛都是既有 W208 假世界的資料。沒有登入真帳號或刪除真外掛。

重跑：先做離線 Debug 建置，再執行：

```sh
TATWO2_TEST_BINARY="$PWD/.build/debug/Tatwo2" node --test tests/w292-connectcard.test.mjs
node --test tests/public-privacy.test.mjs
```

建置沿用本機已下載的 Package.resolved 相依快取，使用 `--disable-automatic-resolution --skip-update`，SDK 巨集路徑見 `build.log`。沒有 fetch、push 或安裝 App。

| 驗收 | 原始回條 |
| --- | --- |
| 設定入口 AXPress → 原地共用卡 → 整理預覽與刪除確認 → 取消；設定卡斷線保留原 ID | `w292.log` |
| 設定內 Pod／配對 popup 使用既有容器，不發私訊開框請求；離開保留頁面釋放卡片路由 | `w292.log` |
| W199：健康與等待安靜，初次未連與可處理的撤銷有入口；原生頂列 AXPress | `w292.log` |
| 設定開／關與 Space 切換 ×3；保留且透明的舊設定仍開著時釋放遮罩；面板回到可見視窗清單 | `w292.log` |
| 斷線、重連、二十輪原外掛 ID、不重建、整理封存與取消等既有斷言 | `w208tap.log` |
| TAP 回歸、連線與敏感畫面回歸、W199 安靜規則 | `w185tap.log`、`w183connect.log`、`w199quiet.log` |
| 隱私掃描測試、65 項相關原始碼／假 Pod 檢查、3 項入口與卡片契約 | `public-privacy.log`、`source-checks.log`、`source-entry-checks.log` |

私訊鈕根因：`Shell/AppShell.swift:3142` 以 opacity 保留舊頁面，並於 3143 傳遞 `tatwoWorkspaceVisible`；舊 `DM/GlobalDMLayering.swift:124` 只監看遮罩 active，沒有監看頁面是否可見，且切頁不會觸發 onDisappear。修正位於 `GlobalDMLayering.swift:126`。自測維持同一個保留 View、讓 settings 仍為 true，只切換可見性，重現並驗證這條路徑。

截圖都是原生元件、假資料：`settings-card-light.png`、`settings-card-dark.png`；預覽與確認為 `settings-preview-light.png`、`settings-preview-dark.png`。`dm-web-entry-light.png` 使用真正的 `ChatGPTWebSpaceHeader`，網頁區是明示的假頁面，沒有開 chatgpt.com。

`w183connect` 明列跳過 1 項真 CEF Pod／popup／配對頁檢查，因本次 Debug 建置未啟用 Chromium；交主導在實機驗，沒有把它算成通過。真帳號、真鑰匙圈、真 live、部署、推送都未執行。

額外舊 `w183-quick-connect.test.mjs` 有兩項既存失敗：R11 default 的英文 instructions 文案，以及 R11c 1 的舊 revision regex。直接用 `git archive 2f34610e` 重跑同兩項也失敗；見 `baseline-known-failures.log`。沒有修改這兩項或它們的產品實作。

最後版本的 w292、w208tap（521）、w185tap（438）、w183connect（402／CEF skip 1）均 0 failures。W199 在整批末輪曾記到 hidden=1（75 pass／1 fail），同版、無改程式下單獨重跑為 76 pass／0 fail；保留 `w199quiet-hidden-request-failure.log`、`native-current-first.log` 與 `w199-rerun.log`，不把首輪失敗抹掉。喚醒測試本輪不能穩定重現該次失敗；本房沒有修改 TAP 喚醒或放寬斷言。隱私測試 13／0 fail；相關 source 檢查 65／0 fail，入口契約 3／0 fail。
