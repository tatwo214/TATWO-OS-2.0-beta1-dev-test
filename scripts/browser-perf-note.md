# W97 瀏覽器效能量測筆記（給主導與使用者照做，不是程式）

改動：無障礙樹從「每個分頁無條件開完整樹」改成「偵測到 VoiceOver 或 `TATWO_CEF_FORCE_AX=1` 才開」。
這份筆記只管**怎麼量**。沒有填完表格之前，不要說這次改動變快了，也不要據此決定要不要重編 PGO。

## 一、前提（不守就別量）

- 同一台機器（MacBook）、同一個網路、同一顆電源模式，量測期間不要跑打包、建置、下載或 VM。
- 每輪開始前把瀏覽器快取清掉（瀏覽器設定 → 清除資料），並關掉其他分頁只留一個。
- VoiceOver **關閉**（系統設定 → 輔助使用 → VoiceOver）。這是一般使用者的狀態，也是這次要省的成本。
- 兩個版本都要是打包過的 App，不是 debug build：
  - **.002 ＝ 改前**（現行安裝版，無障礙樹永遠開）
  - **.003 ＝ 改後**（本列車建置的候選版）
- Safari 只當「這台機器今天大概多快」的參考背景值，不列入前後對照的結論。

## 二、同一台上省時的對照法（可選，但建議）

不想裝兩個版本時，可以只用 .003 跑兩組：

- 「等同改前」：`TATWO_CEF_FORCE_AX=1` 啟動 App（無障礙樹強制開）。
- 「改後」：不設環境變數，或 `TATWO_CEF_FORCE_AX=0`（強制關）。

從終端機啟動已安裝的 App：

    TATWO_CEF_FORCE_AX=1 "/Applications/TATWO OS.app/Contents/MacOS/tatwo2"

每次切換要完全結束 App 再重開（環境變數只在啟動時讀）。
開完後到「瀏覽器診斷 → 引擎」確認那一列寫的是你要的狀態與原因，不要靠記憶。
這組數字只證明「AX 樹的成本」，不證明 .002 與 .003 之間其他差異，兩種對照都做最好。

## 三、指標與跑法

每個組態跑 **3 次**，取**中位數**（不是平均，單次卡頓不該拉走結論）。

1. **Speedometer 3.1**（https://browserbench.org/Speedometer3.1/）
   在 OS 瀏覽器開啟，按 Start Test，等跑完記 **Score**（越高越好）。
   每次之間重新整理頁面；三次中間不要切到別的 App。
2. **同一頁的導覽計時**：Speedometer 跑完後，在同一個分頁開啟診斷／主控台執行：

       const t = performance.getEntriesByType('navigation')[0];
       console.log(Math.round(t.domContentLoadedEventEnd), Math.round(t.loadEventEnd));

   記 **DCL**（domContentLoadedEventEnd）與 **load**（loadEventEnd），單位 ms（越低越好）。
   這兩個值量的是頁面本身的載入，Speedometer 分數量的是跑起來之後的互動速度，兩個都要看。

## 四、填表（量完把數字填進來，並複製一份到 converge.md）

環境：日期＿＿＿ / macOS ＿＿＿ / 機型 MacBook / 網路＿＿＿ / VoiceOver 關

| 組態 | Speedometer 3.1（3 次） | 中位數 | DCL ms（3 次） | 中位數 | load ms（3 次） | 中位數 |
|---|---|---|---|---|---|---|
| .002 改前 | ／／ |  | ／／ |  | ／／ |  |
| .003 改後 | ／／ |  | ／／ |  | ／／ |  |
| .003 `TATWO_CEF_FORCE_AX=1` | ／／ |  | ／／ |  | ／／ |  |
| Safari（參考） | ／／ |  | ／／ |  | ／／ |  |

差異：Speedometer ＿＿%（改後 ÷ 改前 − 1）；DCL ＿＿%；load ＿＿%
判讀：三次之間的散布比前後差還大時，這次量測不算數，重量一輪。

## 五、順手要做的兩個確認（不是效能，是沒弄壞）

- VoiceOver **打開**後**新開一個分頁**，網頁的連結／標題唸得出來 → 按需啟用沒有關掉真正需要的人。
  （既有分頁不會即時跟上，要重開分頁或讓它睡眠後喚醒；診斷頁那一列已寫明。）
- VoiceOver 關閉時，診斷頁那一列顯示「無障礙樹：關（原因：未偵測到輔助工具）」。

## 六、量完之後

把表格填好貼進 `docs/specs/097-browser-perf/converge.md`，再由主導判斷要不要走 spec 第 3 項（mini 上 `chrome_pgo_phase=2` 重編 CEF，數小時）。差距不明顯就不要重編。
