# W255b Keychain audit
Scope: tests/, module-wide Security shims in CloudflareAccounts.swift, App SelfTest.swift and *Acceptance.swift, App/Tests, Apps/*/Tests, Packages/*/Tests, Tools/*selftest* and scripts/*selftest*.
Command inventory: rg 'security |SecItem|SecKeychain', plus quoted security executable names and indirect Keychain constructor/capability calls. Raw inventories retained in the external room evidence directory.
| Caller | Existing isolation | Required repair |
|---|---|---|
| tests/tatwo-staging-reuse-in-place-contract.test.mjs signingIdentity (20 tests) | Only safe with W255 preload | Import refusal launcher in the test; keep the 20 baseline FAIL outcomes, no signing substitute |
| tests/runtime-determinism.test.mjs real certificate/CMS (2 tests) | Only safe with W255 preload | Import refusal launcher; do not query identities or introduce skips |
| tests/update-channels.test.mjs private adapter | Exported in-memory security function | Rename the compiler-input command and fake to w255bFixtureSecurity; assert no native security symbol remains; preserve installer assertions |
| tests/w255-hardening.test.mjs | All four SecItem names rewritten to stateful fakes before compiling | Existing migration/data-preservation checks retained |
| tests/browser-import.test.mjs + browser-import-checks.swift | BrowserSafeStorage.Query injected as ImportKeychainProbe; vault uses InMemorySecretStore | Add compiler-input refusal stubs as a second boundary |
| tests/browser-password-vault.test.mjs + browser-password-vault-checks.swift | InMemorySecretStore / fixture failing stores | Add compiler-input refusal stubs |
| tests/browser-password-fill.test.mjs + browser-password-fill-checks.swift | InMemorySecretStore | Add compiler-input refusal stubs |
| tests/agent-accounts.test.mjs + agent-accounts-checks.swift | Password, TOTP and pending stores are injected | Add compiler-input refusal stubs |
| tests/browser-ai-vault.test.mjs + browser-ai-vault-checks.swift | Password injected; TOTP/pending defaults still native | Inject both missing stores; add compiler-input refusal stubs; product behavior unchanged |
| tests/w106-claude-quota.test.mjs | Every credential load receives a synthetic Reader | Add refusal stubs for SecItemCopyMatching and SecKeychain interaction APIs |
| SelfTest.runGitHubTest/runGitHubMCPTest | memory credential fixture; cleanup and credential helper refused before security | Keep existing BLOCKED reporting; cover all selftest native entry points with synthetic refusal |
| HandsBuildAcceptance / HandsUIAcceptance | CloudflareMemorySecrets injected | Keep fixture injection; selftest API refusal covers accidental defaults |
| W255HardeningAcceptance | No Keychain API; SecCode signature checks only | No Keychain change |
| generic SelfTest=1 | Launches a genuine engine | Refuse before engine launch; retain explicit failure |
| Swift TatwoProductionInstallAnchorKeychainStoreTests | Injected readers or pure query construction | No change |
| Swift TatwoPLGEventChainTests, TatwoDeviceTrustTests, RemoteLoopProductionRunnerTests | Pure query/configuration/source assertions or synthetic operations | No change |
| Swift TatwoTestEnvironmentCapabilitiesTests | Injected create/cleanup probes | No change |
| Swift ClaudeOAuthUsageClientTests | FakeClaudeKeychainCommandRunner | No change |
| Swift TatwoFleetSchedulerTests two native high-water tests | Live capability probe uses the host default keychain, despite unique service names | Replace capability entry with hard refusal before probing; retain assertions; no new skip |
All other grep hits are imports, status constants, comments, source strings or security-policy labels; none invokes a Keychain API.
Outer Seatbelt profile refuses /usr/bin/security, host Keychain paths and securityd lookup; blocks outbound network except private loopback/Unix fixtures. It is kept as defense beyond the audited fakes.

Module-wide selftest Security shims live alongside the existing Cloudflare Keychain backend; SelfTest.swift retains only the engine-entry refusal. W230's existing 900-line backend-budget assertion is unchanged.

F1 and the full post-change Node run used the outer Seatbelt profile. Final verify.sh runs use the audited fakes/refusal launchers and each test's own sandbox: macOS refuses nested sandbox initialization, which otherwise prevents the original positive fixture probes from running. All HOME/live/engine/OS roots remain synthetic; no host Keychain or signing identity backend is enabled.
