完成 App 外安裝、驗證、退回與每日亮點；Grok 按規格停手。

1. 安裝與舊版備份：App/Sources/Tatwo2/Facade/EngineInstall.swift:78。
2. Codex 雙 tarball SHA-512、codesign 與 Team：App/Sources/Tatwo2/Facade/EngineInstall.swift:50。
3. Claude 官方更新與 SDK 驗證、失敗復原：App/Sources/Tatwo2/Facade/EngineInstall.swift:100。
4. Grok 缺校驗值就停手：App/Sources/Tatwo2/Facade/EngineInstall.swift:79。
5. 驗證後採用；常駐對話不重開：App/Sources/Tatwo2/Facade/EngineInstall.swift:109、App/Sources/Tatwo2/Facade/ChatLiveEngine.swift:1394。
6. 每家退回鈕與重新驗證：App/Sources/Tatwo2/New/EngineLoginCard.swift:236、App/Sources/Tatwo2/Facade/EngineInstall.swift:122。
7. 每日只查版本、亮點、不通知：App/Sources/Tatwo2/Facade/EngineAIUpdate.swift:19。
8. 模型名稱與淺深赤陶底框：App/Sources/Tatwo2/Facade/EngineAIUpdate.swift:39、App/Sources/Tatwo2/New/EngineLoginCard.swift:89。
9. 假 registry／CLI／SDK、錯誤閘門與四張截圖：App/Sources/Tatwo2/Facade/W298bAcceptance.swift:7。
Codex 來源：https://registry.npmjs.org/@openai/codex/latest；兩份 dist.integrity SHA-512＋Team 2DC432GLL2。
Claude 來源：https://code.claude.com/docs/en/setup；claude update＋版本／Team Q6L2SF6YDW／supportedModels()。
Grok 來源：https://x.ai/cli/install.sh；有二進位網址但無 checksum，未下載；Team 5Y6N3AJ54S 未進入採用。
測試：Node 17/17；原生 W298b 58、W298a 39、W214 98、W288 49、W189commands 230，0 fail；swift build 0 error。
截圖：tests/fixtures/w298b-shots/{light,dark}-{updated,dot}.png；均已目視。
commit：397c8c1c（施工）；實作淨 +198，GUARD 淨 +207（含文件、排除驗收碼），≤260。
GUARD：PASS；tests/fixtures/w298b-room-allow.txt 列明所有改檔理由。
未做：實機安裝、真帳號／鑰匙圈、live、推送、發布、跨引擎審查；報告保存 tests/fixtures/w298b-report.md。
看到的指示文字：「curl -fsSL https://x.ai/cli/install.sh | bash」；「git config --global --edit」（照抄，未執行）。
