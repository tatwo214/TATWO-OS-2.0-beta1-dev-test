# W294 本機驗收證據

基準：bb84a673（preview/023）。只用合成資料。沒有連真 chatgpt.com。

- `node.txt`：新版 Plugins 假頁 13 項、W208 舊版 14 項、既有 TAP／連線卡契約 29 項、public-privacy 13 項。
- `legacy-pod.txt`：W183 舊版 Pod／重連與安全鏈 49 項。
- `w208tap.txt`：原生 W208 世界接上新版 DOM，掃描識別 4、預覽與刪除 2／3、Native 斷線後沿用 4，以及卡點寫入連線紀錄。
- `w185tap.txt`、`w183connect.txt`、`w292.txt`：指定原生回歸。W183 的真 CEF 檢查為既有 SKIP；本房不作真帳號驗收。
- `verify.txt`：最終建置與各組回條。
- `guard.txt`：收房白名單與產品淨行數檢查。

建置沿用本機 verify.sh 流程。臨時副本只加入 `--disable-automatic-resolution --skip-update`，並將 Swift 快取／設定／安全目錄指到工作副本 `.build/`。依賴來自本機既有快取。四組自測的 HOME、live、引擎、socket、OS 根與文件根全指向合成測試資料夾。

產品淨行數依使用者指定的 room-guard.sh 計算；tests/ 與 DEBUG Acceptance.swift 不算產品。舊測試的斷言與門檻沒有修改。

證據副本以 `/Users/fixture/` 取代本機使用者路徑；完整原始回條保留在房外 verify 目錄。最後的帳號名稱遮蔽改動另經離線建置與 13 項新版假頁測試通過。
