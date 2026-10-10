W288：8 處修正與隔離原生自驗完成；指定檢查全部 0 failures，10 張淺深色截圖已自檢。

| 項 | 結果與證據（checks / failures） |
|---|---|
| 1 | 做到。w288 #1＝3/0；NSEvent keyDown 經 NSWindow.sendEvent，沒有直接設文字。修前 3/2：w288-before-keys.log。 |
| 2 | 做到。w288 #2＝24/0；Codex／Claude 真滑鼠事件停止、草稿保留、停止位置不動。w288-shots/2-{gpt-6.1-sol,opus-5.5}-draft-{light,dark}.png。 |
| 3 | 做到。w288 #3＝10/0、w217voice＝94/0；同一套語音元件、期限與停止。w288-shots/3-tap-voice-{light,dark}.png 含模型名及完整輸入框。 |
| 4 | 做到。w288 #4＝8/0；同一次模型點擊關閉 Thread 並打開模型面板，反向也互斥。w288-shots/4-model-panel-{light,dark}.png。 |
| 5 | 做到。w288-coderfix Node #5＝1/0；計畫空狀態與同類英文提示／無障礙標籤已中文化，指定字串 grep 0。 |
| 6 | 做到。w288 #6＝4/0；玻璃樣式放在原生 Menu 外層，淺深色均有玻璃 chip 邊緣，沒有藍色系統按鈕。w288-shots/6-archived-chip-{light,dark}.png。 |
| 7 | 做到。w288-coderfix Node #7＝1/0，實際 Swift 分類＝8/0；只略過記憶 worker 日誌，使用者工具錯誤及正式 error 事件保留。 |
| 8 | 做到。w288-coderfix Node #8＝1/0；建議明寫「貢獻到 TATWO OS 公開倉（只在公開倉或其 fork 使用）」。 |

測試｜commit：build exit 0；Node 49/0（含 public-privacy 13/0）；w288 49/0、w189commands 230/0、w189send 87/0、w217voice 94/0；程式驗證 commit＝0a4a2ce3。
證據：本目錄 w288-verify.log、w288-node.log、w288-selftest-*.log；截圖在 w288-shots/；副本只替換本機證據路徑，原始輸出保留在隔離 verify 目錄。
淨行數：對 2f34610e，只排除 tests/＝+206（含原生自測）；room-guard 的產品分類＝+51；兩者均 ≤ +220。
GUARD：PASS；到檔白名單與理由在 w288-room-allow.txt，結果在 w288-guard.log。
沒做的事：未連外、推送、安裝或發版；測試用隔離 HOME、引擎／Pod 替身，未用真帳號、真鑰匙圈、正式 live 或真麥克風。GBrain 工具不可用，未查過往決策。
看到的指示文字：docs/specs/189-coder-health/user-check.md:3「用已有登入的 App；先記版本，逐項勾對／不對／無法測。」；依本房硬邊界未照做。git commit 輸出「git config --global --edit」；未照做。

可重跑（repo 根、bash）：
```bash
source tests/fixtures/w276-offline-verify-env.sh
export -f swift
~/tatwo-build/verify.sh "$PWD" w288,w189commands,w189send,w217voice tests/w288-coderfix.test.mjs tests/w189-commands.test.mjs tests/w189-send.test.mjs tests/w189-engine-errors.test.mjs tests/w189-claude-controls.test.mjs tests/w189-model-routing.test.mjs tests/public-privacy.test.mjs
~/tatwo-build/room-guard.sh "$PWD" 2f34610e HEAD tests/fixtures/w288-room-allow.txt 220
```
