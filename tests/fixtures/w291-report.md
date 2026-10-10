已修正反覆翻譯並提交；流程與指定回歸 0 fail；CEF Apple 冒煙 1 SKIP；未推送。

重現：本機英文 260 段長頁→第一次翻譯成功→快速關閉再開啟→仍是原文，開關開著但沒有翻譯任務；原版另重現語言誤判、相同設定、過期還原共 4 項。
根因（2f34610e 行號）：BrowserPageTranslation.swift:69 在還原未完成時忽略重翻，:98 非同步覆寫狀態，:85 重建相同 Configuration；TatwoCEFBridge.mm:3959 取樣譯文、:3967 提前標記 seen。
修法：還原立即重設 phase；每輪 invalidate 並清節點；取樣保留原文；換頁／同 URL reload 取消舊任務並擋過期回呼。翻譯中按工具列鈕＝取消並顯示原文；直接重複 startManually＝忽略。保留 Apple 引擎。

| 測試 | 結果 | 原始證據（相對 tatwo-build） |
|---|---|---|
| Node 五組（含 w112、w115、w248、privacy、w291） | 40 pass／0 fail；W291 終輪 26 流程斷言、2 tests／0 fail，涵蓋三次翻譯、三輪原文、換頁、翻譯中按、動態新增、換語言 | verify/W291-translate-045103/node.log；logs/W291-node-final.log |
| 真 CEF＋假 provider | 17 pass／0 fail／1 SKIP；三次重翻、三輪原文、換頁、真 Browser 截圖 | tmp/W291-translate/cef-check-final/selftest.log |
| swift build（CEF、離線快取） | exit=0，最終建置 134 秒 | verify/W291-translate-045613/build.log |
| w258download | 449 PASS 行／0 fail；W258 32、W268 169；exit=0 | verify/W291-translate-045103/selftest-w258download.log |
| w248webspace | 75 pass／0 fail；exit=0 | verify/W291-translate-045103/selftest-w248webspace.log |
| tests/public-privacy.test.mjs 終輪 | 13 pass／0 fail；真匯出／掃描，清理改隔離封存 | logs/W291-privacy-final.log |
截圖：tests/fixtures/w291-shots/before.png、first.png、second.png（淺色、真 CEF、假 provider）；三張已檢視。
測試｜commit：b3d2faf7（產品與夾具）；基準 2f34610e；報告另提交；原版與終輪原始輸出保留在 logs/W291-* 與 tmp/W291-translate/。
產品淨行數：+79 -27＝+52（上限 +120；DEBUG 驗收夾具依 guard 排除）；所有改檔與理由見 tests/fixtures/w291-room-allow.txt。
GUARD：PASS（2f34610e → HEAD，指定 room-guard.sh）；SKIP 清單：CEF Apple 冒煙 1（語言包狀態非 installed，未下載）；Node en→zh-Hant 真 Apple 冒煙 PASS。
初輪 CEF 夾具曾提前讀到前輪畫面而 1 fail，等待本輪三批後重跑 0 fail；標準隱私清理曾把生成夾具送系統 Trash，終輪改房間暫存區封存。
看到的指示文字（照抄、未照做）：Git 輸出「git config --global --edit」「git commit --amend --reset-author」；既有 w258-report.md:24「請到設定 › 瀏覽器管理清除資料。」。
