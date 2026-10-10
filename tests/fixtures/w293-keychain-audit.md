Staging 的已知原生帳密路徑已停用；CEF 與 TAP 使用隔離假鑰匙圈，平台憑證鑰匙圈讀取回空。正式版保留原行為。
| 路徑（repo 相對檔名:行號） | staging 邊界與證據 |
| --- | --- |
| Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm:362,367,4659,4750；Package.swift:91；script/tatwo2-staging-launcher.c:68 | 主程序與所有 Helper 明列 use-mock-keychain，deny list 未改；launcher 重啟讓 OS argv 可驗證。外部探針發現平台憑證掃描仍讀 SecItemCopyMatching，故 staging dyld 邊界回 errSecItemNotFound/nil；正式版轉原 API，替身原 API 的真 dyld 測試通過，不關閉 TLS 驗證。 |
| App/Sources/Tatwo2/Facade/TestKeychainBoundary.swift:10,18 | 固定 staging bundle 或非空白 scratch HOME 一律啟用六個拒絕入口；回 errSecInteractionNotAllowed，資料 nil，未進 Security.*。release -O 編譯測試覆蓋。 |
| App/Sources/Tatwo2/Browser/BrowserPasswordVault.swift:48,154,222；App/Sources/Tatwo2/Browser/Import/ChromiumImporter.swift:105 | SecretStore 與 Chromium 匯入的 SecItem 呼叫由上述邊界拒絕；LocalAuthenticator 在建立 LAContext 前拒絕；不寫真密碼、不跳系統驗證。 |
| App/Sources/Tatwo2/TAP/TapWebPod.swift:159,176；App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift:1932 | TAP 沿用同一 CEF runtime 和 staging profile root；沒有另外的 native Keychain 入口。 |
| App/Sources/Tatwo2/Facade/GitHubAccounts.swift:554,574,594,660 | 三個 SecItem 呼叫拒絕；ghIsAvailable 在 staging 回 false，auth login/status/token 子程序不啟動。 |
| App/Sources/Tatwo2/Facade/CloudflareAccounts.swift:100,117,133,144；App/Sources/Tatwo2/Facade/HandsGatewayLaunch.swift:511；App/Sources/Tatwo2/Facade/ChatGPTHandsService.swift:169 | Hands 憑證全部經六個拒絕入口；既有自動啟動也排除 staging。SecRandom/TLS 信任驗證不是憑證存取。 |
| App/Sources/Tatwo2/Facade/GBrainService.swift:42,58,89；App/Sources/Tatwo2/Facade/GBrainKeychain.swift:26,34,45,50,55 | 既有 staging 禁止 adapter/service 啟動；原生存取也由拒絕入口攔截，不啟動含 security 的 Node adapter。 |
| App/Sources/Tatwo2/Facade/EngineLogin.swift:98,294,476；App/Sources/Tatwo2/Engine/ClaudeSidecar.swift:118；App/Sources/Tatwo2/Facade/ClaudeCredentialStore.swift:152 | 既有 staging 不跑 security 探針；停用真 Claude CLI auth/status 與 SDK sidecar，因子程序不受 Swift wrapper 保護；原生 store 經六個拒絕入口。明列假 CLI 注入仍可測試。 |
| App/Sources/Tatwo2/Facade/PrimaryTransfer.swift:474；App/Sources/Tatwo2/New/IPadUseController.swift:873 | staging 在 security find-identity 前退出，不讀真簽署身份。 |
| tests/w293-mockkeychain.test.mjs:13,47 | 2f34610e 的正式 CEF callbacks／deny list 對照通過；正常／空白 marker 的 Keychain activation 與基準相同，僅觀察 activation，不執行真鑰匙圈呼叫。 |
任意使用者 shell 指令不屬 App 憑證功能；未替使用者執行 security、真登入、跨設備或 live 操作。系統 ps／安全日誌與加密 cookie 證據留在本房外部 verify 目錄。
