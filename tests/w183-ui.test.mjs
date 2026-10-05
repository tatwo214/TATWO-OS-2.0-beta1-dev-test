import test from 'node:test';
import { nativeW214 } from './w214-native-fixture.mjs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// W183 R3：ChatGPT 手腳的畫面與標準設定流程——原始碼契約＋設定指令的 Seatbelt 規則實跑。
// 流程每一步的狀態機（假 cloudflared、假鑰匙圈）、OS 工具界線、副設備 RPC 驗章在 App 自測 TATWO2_SELFTEST=w183ui（lead-verify 在 mini 跑）。
const repo = fileURLToPath(new URL('..', import.meta.url));
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');
const swift = name => read(`App/Sources/Tatwo2/${name}`);
const setBody = (source, name) => source.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\]`))?.[1] ?? '';
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  return source.slice(from, to < 0 ? source.length : to);
};
const code = source => source.replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^\n"]*$/gm, '');

const settings = swift('Shell/ChatPageSettings.swift');
const envLogin = swift('New/EnvironmentLoginPage.swift');
const cfCard = swift('New/CloudflareAccountsCard.swift');
const cfStore = swift('Facade/CloudflareAccounts.swift');
const cloudflared = swift('Facade/HandsCloudflared.swift');
const setup = swift('Facade/HandsSetup.swift');
const remote = swift('Facade/HandsRemote.swift');
const section = swift('New/ChatGPTHandsSection.swift');
// W183 R8a：ChatGPT build（TAP 一張卡＋節點流程）：畫面、節點流程、adapter（接口 HandsBuild.swift）。
const build = swift('New/ChatGPTBuildSection.swift');
const flow = swift('New/ChatGPTBuildFlow.swift');
const buildModel = swift('Facade/HandsBuildModel.swift');
const info = swift('New/OSInfoButton.swift');
const banner = swift('New/HandsReviewBanner.swift');
const bridge = swift('Facade/OSAgentBridge.swift');
const server = read('Engines/os-mcp/server.mjs');
// W183 R6a：一個開關（判斷與動作）、它的自測。
const oneSwitch = swift('Facade/HandsOneSwitch.swift');
const service = swift('Facade/ChatGPTHandsService.swift');
const newUI = ['New/EnvironmentLoginPage.swift', 'New/CloudflareAccountsCard.swift', 'New/ChatGPTHandsSection.swift', 'New/OSInfoButton.swift', 'New/HandsReviewBanner.swift',
  'New/ChatGPTBuildSection.swift', 'New/ChatGPTBuildFlow.swift'];

test('W185 status truth: partial connection survives adapter errors; node reasons and live start reach visible/AX surfaces', () => {
  const controller = swift('Facade/HandsBuildController.swift');
  assert.match(controller, /connected\.map\(\\\.name\)\.joined/);
  assert.match(controller, /那台的 App 沒開或連不到（最後回報/);
  assert.match(controller, /關口沒在跑：/);
  assert.match(buildModel, /i\.deviceReasons\[device\.id\] = b\.connectionReason\(device\.id\)/);
  assert.match(buildModel, /sub: device\.name \+ \(s\.deviceReasons\[device\.id\]/);
  const summary = between(buildModel, '// 那一行狀態（短）。', 'return s');
  assert.ok(summary.indexOf('connection == .done') < summary.indexOf('if let problem'));
  assert.match(section, /HandsSetup\.liveStartStep\(setup\.state\.step\(step\), phase: service\.phase\)/);
  const entry = swift('New/HandsConnectEntry.swift');
  assert.match(entry, /case partial\(hosts: \[String\], level: Int\?, text: String\)/);
  assert.match(entry, /guard case \.connected\(let level\) = verdict\(device\.id\) else \{ continue \}/);
  assert.match(swift('New/HandsConnectDMView.swift'), /if let text = build\.localAvailabilityText \{ return text \}/);
  assert.match(swift('New/HandsConnectDMView.swift'), /availabilityText: availability/);
  assert.match(swift('Facade/HandsBuildUIAcceptance.swift'), /static func statusTruthChecks/);
  assert.match(swift('Facade/HandsBuildIntegrationAcceptance.swift'), /try await statusTruthChecks\(check, base, keys\)/);
});

test('W214 environment access uses logo circles and a collapsed section in Login', () => {
  assert.match(nativeW214(1), /W214 PASS N1.selection-persists.true/);
  assert.match(nativeW214(2), /W214 PASS N2.login-title-and-sidebar.true/);
  assert.match(nativeW214(2), /W214 PASS N2.environment-default-collapsed.true/);
  assert.match(nativeW214(2), /W214 PASS N2.no-environment-sidebar-entry.true/);
  assert.match(settings, /\n        case github\n/, 'rawValue github stays (sidebar update shortcut, 開始使用, export)');
  assert.match(envLogin, /static let storageKey = "tatwo\.settings\.envLogin\.tab"/);
  assert.equal((envLogin.match(/@AppStorage\(EnvironmentLoginTab\.storageKey\)/g) ?? []).length, 2);
  assert.match(envLogin, /UserDefaults\.standard\.set\(tab\.rawValue, forKey: storageKey\)\s*\n\s*EnvironmentLoginTarget\(rawValue: tab\.rawValue\)\?\.open\(\)/);
  assert.match(envLogin, /userInfo: \["environmentTarget": rawValue\]/);
  assert.match(envLogin, /CloudflareAccountsCard\(\)[\s\S]*GitHubAccountsCard\(model: model\)/);
  const shell = between(settings, 'struct TatwoSettingsPage: View {', '    @ViewBuilder\n    private var rightContent');
  assert.match(shell, /\.onReceive\(NotificationCenter\.default\.publisher\(for: \.tatwoCloseSettingsPage\)\) \{ _ in onClose\(\) \}/);
  assert.match(swift('Facade/EntryBackup.swift'), /設定 › 環境登入 › GitHub 登入/);
});

test('Cloudflare accounts: shared store, keychain ThisDeviceOnly without an all-apps ACL, list file holds only ids and names', () => {
  // W183 R3 審查：ThisDeviceOnly 只在 data-protection 鑰匙圈有效：先寫那裡，沒權限（-34018）才退回登入鑰匙圈；每次先刪再加；讀兩邊。
  const kc = between(cfStore, 'final class CloudflareKeychain', 'final class CloudflareRefusingSecrets');
  assert.match(kc, /if backend == \.dataProtection \{ query\[kSecUseDataProtectionKeychain as String\] = true \}/);
  assert.match(kc, /static let missingEntitlement: OSStatus = -34018/);
  assert.match(kc, /try remove\(service: service, account: account\)\n\s*var last: OSStatus = errSecSuccess\n\s*for backend in Backend\.allCases/, 'delete then add: our attributes and default ACL every time');
  assert.doesNotMatch(kc, /SecItemUpdate/, 'never writes into a pre-existing item');
  assert.match(swift('Facade/HandsGatewayLaunch.swift'), /for dataProtection in \[true, false\] \{[\s\S]*?if dataProtection \{ query\[kSecUseDataProtectionKeychain as String\] = true \}/, 'R2 reads both backends');
  // staging／自測：秘密庫與設定流程的每個副作用都拒絕（不靠 fixture 環境變數）。
  assert.match(cfStore, /if HandsSetup\.isolated\(environment\) \{ return CloudflareRefusingSecrets\(\) \}/);
  assert.match(setup, /if HandsSetup\.isolated\(environment\) \{[\s\S]*?runner: HandsRefusingRunner\(\)[\s\S]*?locateCloudflared: \{ nil \}[\s\S]*?installCloudflared: \{ done in done\(\.failure\(\.isolated\)\) \}[\s\S]*?updateSettings: \{ _ in throw HandsSetupError\.isolated \}/);
  assert.match(setup, /!ChatGPTHandsService\.allowedToRun\(environment: environment\)/);
  assert.match(cfStore, /static let shared = CloudflareAccountsStore\(\)/);
  assert.match(cfCard, /@ObservedObject private var store = CloudflareAccountsStore\.shared/);
  assert.match(section, /@ObservedObject private var accounts = CloudflareAccountsStore\.shared/);
  const keychain = between(cfStore, 'final class CloudflareKeychain', '#if DEBUG');
  assert.match(keychain, /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/);
  assert.match(keychain, /kSecAttrSynchronizable as String: false/);
  assert.match(keychain, /kSecUseAuthenticationUIFail/);
  assert.doesNotMatch(keychain, /SecAccessCreate|SecTrustedApplication|kSecAttrAccess as String|keychainAccess\(/, 'never the GitHub all-apps ACL');
  assert.match(cfStore, /static let certService = "tatwo2-cloudflare"/);
  assert.match(cfStore, /static let tunnelService = HandsTunnelKeychain\.service/);
  assert.match(cfStore, /static let tunnelAccount = "tunnel"/);
  assert.match(swift('Facade/HandsGatewayLaunch.swift'), /static let service = "tatwo2-cloudflare-tunnel"/);
  const account = between(cfStore, 'struct CloudflareAccount:', 'var selected:');
  assert.deepEqual([...account.matchAll(/^\s*var (\w+):/gm)].map(m => m[1]), ['id', 'name', 'domains', 'selectedDomain', 'tunnelID'],
    'only id, name, domains, the selected domain and the tunnel id');
  const domain = between(cfStore, 'struct CloudflareDomain:', 'struct CloudflareAccount:');
  assert.deepEqual([...domain.matchAll(/^\s*var (\w+):/gm)].map(m => m[1]), ['name', 'zoneID']);
  assert.match(cfStore, /appendingPathComponent\("cloudflare", isDirectory: true\)\s*\n\s*\.appendingPathComponent\("accounts\.json"\)/);
  assert.match(cfStore, /HandsFiles\.writeAtomically/);
  assert.doesNotMatch(code(cfStore), /\.write\(to:|NSLog\(|print\(/);
  // 移除：卡片內確認列、玻璃 chip，不跳系統框；只刪這台的授權，不碰 Cloudflare 上的通道與 DNS。
  assert.match(cfCard, /private func removalRow/);
  assert.match(cfCard, /Cloudflare 上的通道與 DNS 紀錄不會被刪/);
  assert.match(cfStore, /func remove\(accountID: String, removeTunnelToken: Bool\) throws \{[\s\S]*?if removeTunnelToken \{[\s\S]*?for domain in account\.domains[\s\S]*?try mutate/);
  // 移除正在用的帳號（W183 R3 審查）：忙碌時拒絕；依鑰匙圈裡 token 的通道認「正在用」；先關開關、關口停下，再刪。
  const removal = between(setup, 'private func performRemoval', 'private func enqueue');
  assert.match(removal, /let tokenIsTheirs = account\.tunnelID != nil && account\.tunnelID == state\.tokenTunnelID/);
  const order = ['updateSettings { $0.enabled = false }', 'dependencies.serviceChanged()', 'dependencies.accounts.remove(accountID: accountID, removeTunnelToken: removeToken)']
    .map(needle => removal.indexOf(needle));
  assert.ok(order.every(i => i >= 0) && order[0] < order[1] && order[1] < order[2], `stop first, then delete ${order}`);
  assert.match(setup, /func removeAccount\(_ accountID: String, completion: @escaping \(String\?\) -> Void\) \{\n\s*lock\.lock\(\)\n\s*guard !jobActive else/);
  assert.match(cfCard, /HandsSetup\.shared\.removeAccount\(account\.id\)/);
  assert.match(cfCard, /\.disabled\(setup\.busy \|\| removing\)/);
  assert.doesNotMatch(cfCard, /store\.remove\(/);
  // 換帳號、換網域都不清掉「鑰匙圈裡的 token 是哪條通道的」。
  assert.doesNotMatch(code(between(setup, 'func chooseDomain', 'func removeAccount')), /tokenTunnelID = nil/);
  // W183 R8c（GPT-6 必改 4）：登入只是登入——adopt()（登入後改手腳的帳號／網域／通道／網址）拿掉了。
  assert.doesNotMatch(setup, /private func adopt\(/);
});

test('New UI files: glass chips only, in-card confirm rows, no system dialogs, no blue bordered buttons', () => {
  for (const file of newUI) {
    const source = code(swift(file));
    assert.doesNotMatch(source, /\.borderedProminent|\.buttonStyle\(\.bordered|\.alert\(|\.confirmationDialog\(|NSAlert/, file);
    for (const tint of source.matchAll(/\.tint\(([^)]*)\)/g)) assert.equal(tint[1], 'LiquidGlassTokens.brandAccent', file);
  }
  const leftovers = read('tests/w180-leftovers.test.mjs');
  for (const file of ['New/CloudflareAccountsCard.swift', 'New/ChatGPTHandsSection.swift', 'New/ChatGPTBuildSection.swift', 'New/ChatGPTBuildFlow.swift']) {
    assert.ok(leftovers.includes(`'${file}'`), `${file} is in the D1 sweep`);
  }
});

test('TAP › ChatGPT: one card with ChatGPT build (switch, ⓘ with the one sentence, node flow); logic behind HandsBuildModel', () => {
  const tap = swift('TAP/TapSettingsView.swift');
  // W183 R8a（使用者 09-28「tap/chatgpt跟chatgpt手腳合併 手腳改名chatgpt build」）：ChatGPT 卡裡嵌 ChatGPT build，不再是另一塊。
  assert.equal((tap.match(/ChatGPTBuildSection\(/g) ?? []).length, 1);
  assert.doesNotMatch(code(tap), /ChatGPTHandsSection\(\)/);
  const tapCard = between(tap, 'private var chatGPTCard: some View {', 'private var moreMenu: some View {');
  assert.ok(tapCard.indexOf('Divider()') > 0 && tapCard.indexOf('Divider()') < tapCard.indexOf('ChatGPTBuildSection('), 'card head, divider, then ChatGPT build');
  assert.match(swift('Pages/PluginsPage.swift'), /else if selectedTab == "tap" \{\s*TapSettingsView\(\)/);
  assert.match(build, /Toggle\(HandsBuildCopy\.title, isOn: Binding\(get: \{ model\.enabled \}/);
  assert.match(build, /OSInfoButton\(title: HandsBuildCopy\.infoTitle, paragraphs: \[HandsBuildCopy\.infoParagraph\]/);
  // W183 R5（使用者 09-28「說明太長了」）：ⓘ 只放他給的那一句（W183 R8a 沿用，名字改 ChatGPT build）。
  assert.match(buildModel, /static let infoParagraph = "透過 Cloudflare 網域連結主、副設備，提供 ChatGPT 如 Codex 的工程能力，用以節省 Codex 額度。"/);
  assert.match(buildModel, /static let infoTitle = "ChatGPT build 是什麼"/);
  assert.match(info, /\.popover\(isPresented: \$shown, arrowEdge: \.bottom\)/, 'system popover: the settings overlay clips hand-made cards');
  assert.match(info, /\.frame\(width: 300, alignment: \.leading\)/);
  // W183 R6a（一個開關）：打開＝runAll(allowLogin: true)（沒登入 Cloudflare 就在私訊框開授權頁，不再停下來導去環境登入）；
  // 環境登入只剩「詳細」裡換帳號的那顆鈕。
  assert.match(section, /EnvironmentLoginTab\.open\(\.cloudflare\)/);
  assert.doesNotMatch(code(section), /allowLogin: false/);
  assert.match(between(oneSwitch, 'static func turnOn(', 'static func turnOff('), /setEnabled\(true\)\n\s*setup\.runAll\(trigger: \.user, allowLogin: true\)/);
  // W183 R8 整合：ChatGPT build 的開關接到 R8c 的中央設定（HandsBuildController.setEnabled：照看到的版本 CAS；一台都沒勾＝勾主設備）；
  // 被勾的那台由背景同步照做（只恢復已經套用的網址、不開授權頁、不叫 retry）——登入與建網址各自要使用者按。
  const toggle = between(buildModel, 'case .setEnabled(let on):\n            pendingEnabled', 'case .select(');
  assert.match(toggle, /build\.setEnabled\(on\)/);
  assert.match(swift('Facade/HandsBuildConfig.swift'), /if on, config\.devices\.allSatisfy\(\{ !\$0\.selected \}\) \{\n\s*let primary = known\.first\(where: \\\.isPrimary\)\?\.id \?\? config\.primaryID/);
  // W183 R8c（GPT-6 必改 4）：登入只是登入——「登入完接著做」（resumeIntent）、「重新授權確認後接著做」（continueAfterConfirm）都拿掉；
  // 登入完停在「選網域、按套用」，工作裡不再接著跑整條。（W183 R8 整合：R8a 那邊守「接著做的意圖綁世代」的斷言因此改成「沒有接著做」。）
  assert.doesNotMatch(code(setup), /resumeIntent|continueAfterConfirm/);
  assert.match(setup, /W183 R8c（GPT-6 必改 4）：登入完不再「同一個工作裡接著跑」/);
  assert.match(setup, /static let chooseDomainMessage = "已登入 Cloudflare：在 ChatGPT build 的 Cloudflare 節點選網域、按「套用」才會建網址（登入不會自己綁網址）"/);
  // 關掉＝中央設定關掉（那一台一台的撤銷世代變大＝各自撤銷連線、關口停下；HandsBuildReconciler）。
  assert.match(toggle, /build\.setEnabled\(on\)/);
  assert.match(between(oneSwitch, 'static func turnOff(', 'static func retry('), /setup\.turnedOff\(\)/);
  // 打開開關不直接叫關口（第 5 步才開）；W183 R6a：那一行狀態只有規格那幾種字，不再寫「第 N 步」。
  // W183 R8 整合：那一行字是 R8c 控制器的（照每台的回報；沒收到回執不寫已關）＋這台的「等你在私訊框授權」、出錯的一句話。
  assert.doesNotMatch(toggle, /settingsDidChange/);
  for (const source of [section, build, swift('Facade/HandsBuildController.swift')]) assert.doesNotMatch(code(source), /settingUpText|第 \\\(step\.number\) 步|設定中：第/);
  assert.match(buildModel, /i\.statusText = b\.statusText/);
  // W199 10-03：頂部小鈕不再報備健康狀態；設定頁的狀態來源與所有忙碌／授權保障照舊。
  assert.match(between(section, 'struct ChatGPTHandsStatusButton: View', undefined), /\.accessibilityLabel\("ChatGPT build 設定"\)/);
  // 忙碌時不准換網域、主機（選單停用；chooseDomain 丟錯；chooseHost 回 false 由畫面說明）。
  assert.match(setup, /func chooseDomain\(accountID: String, zoneID: String\) throws \{\n\s*lock\.lock\(\); defer \{ lock\.unlock\(\) \}\n\s*guard !jobActive, !maintaining else \{ throw HandsSetupError\.busy \}/);
  // W183 R8a 審查（Claude）：選網域只在 Cloudflare 面板的網域選單（「…」裡不再有第二個直接換的選單）；網址建好之後換要卡片內確認。
  assert.doesNotMatch(code(section), /setup\.chooseDomain\(|private var domainPicker/);
  // W183 R8 整合：網域選單在 Cloudflare 面板；還沒拿到設定、等換網域確認時停用（每台回報的帳號裡的網域；R8c：不自動選）。
  assert.match(build, /\.disabled\(!input\.configKnown \|\| model\.pendingZone != nil\)/, 'W183 R8a zone menu on the Cloudflare panel');
  assert.match(between(buildModel, 'case .chooseZone(let zone):', 'case .setSubdomain'), /guard i\.urlBuilt\.isEmpty, i\.totalGrants == 0 else \{ return \[\.askZoneChange\(zone\)\] \}/);
  // W183 R8 整合（R8c 必改 1：沒有「一次只有一台主機」）：「改用這台當主機」、換主機確認列、畫面模式（本機／副設備／主機是別台）都拿掉——
  // 每台被勾的設備自己當自己的主機；設備面板是多選（勾＝那台打開，取消勾＝那台關掉）。claim_host 退役（主設備那端一律拒）。
  assert.doesNotMatch(code(section) + code(build) + code(buildModel), /hostHereRow|hostChangeRow|confirmHostChange|chooseHost|enum Mode:/);
  assert.match(between(buildModel, 'case .setDevice(let id, let selected):', 'case .chooseZone('), /return device\.selected == selected \? \[\] : \[\.select\(device\.id\.lowercased\(\), selected\)\]/);
  assert.match(buildModel, /var roleKey: String \{ authority \+ "\|" \+ \(localDeviceID \?\? ""\)\.lowercased\(\) \}/);
  for (const piece of ['urlRow', 'pairingWindowRow', 'grantsBlock', 'accountBlock', 'setupProgress', 'unusedTunnelsBlock', 'otherDevicesBlock', 'diagnostics']) {
    assert.match(section, new RegExp(`private var ${piece}`), piece);
  }
  // W183 R8a：等級、專案在 ChatGPT Dev 面板；設備在設備面板（HandsState.levelLabel 的字當提示與 VoiceOver）。
  // W183 R12（使用者 09-30 裁決：拿掉等級選擇——「這個環節我非常不理解」）：L0／L1／L2 那一排（levelChip）拿掉，換成一行白話（連上後能做的）。
  for (const piece of ['deviceCard', 'connectButton', 'subdomainRow', 'loginChip']) assert.match(build, new RegExp(`private (func|var) ${piece}`), piece);
  assert.doesNotMatch(code(build), /levelChip|ForEach\(0\.\.\.HandsSettings\.maxLevel|HandsState\.levelLabel/);
  assert.match(build, /Text\(HandsBuildCopy\.capabilities\)[\s\S]{0,200}\.accessibilityIdentifier\("tap\.chatgpt\.build\.capabilities"\)/);
  // W183 R6a 審查（GPT-6「手動配對仍直接開啟舊式無 attempt 窗口」）：設定頁不再直接開舊的配對窗口、不顯示配對碼（只在私訊框的［連線］卡）。
  for (const source of [section, build, buildModel]) assert.doesNotMatch(code(source), /hands\.startPairing\(\)|ChatGPTHandsPairingCard\(|手動配對/);
  assert.match(between(section, '@ViewBuilder private var pairingWindowRow: some View {', 'private var isRunning'), /OSChipButton\(title: "收掉配對"\) \{ _ = build\.detail\(\.stopPairing, shown: shown\) \}/);
  assert.match(between(buildModel, 'func detail(_ action: HandsBuildDetail', 'func deleteUnusedTunnels('), /case \.stopPairing:\n\s*hands\.stopPairing\(\)/);
  const card = between(section, 'struct ChatGPTHandsPairingCard: View', '/// W183 R3b 審查：授權後的那一列');
  for (const words of ['交易編號', '回到', '等級', '專案', '記憶', '授權這筆連線']) assert.ok(card.includes(words), words);
  assert.doesNotMatch(card, /已驗證|verified/, 'never claims the ChatGPT account was verified (v2 §3)');
  assert.match(section, /confirmRow\(question: "撤銷全部 ChatGPT 連線？"/);
  assert.match(section, /\("關掉 ChatGPT build？",/);
  assert.match(section, /NotificationCenter\.default\.post\(name: \.tatwoCloseSettingsPage, object: nil\)/);
});

// W199 10-03：頂部仍可開設定；健康不報狀態，只有需要動手才有提示標記。尺寸與輪詢保障不改。
test('ChatGPT Space: settings icon stays accessible, healthy states are silent, actionable states alone show a marker', () => {
  const space = swift('TAP/ChatGPTSpace.swift');
  const controls = between(space, 'struct ChatGPTTopBarControls: View', 'struct ChatGPTProjectCreationView: View');
  const creation = between(space, 'struct ChatGPTProjectCreationView: View', 'struct ChatGPTSpaceMainPane: View');
  assert.match(creation, /Button \{ model\.showsProjectCreation = false \} label: \{\s*Image\(systemName: "xmark"\)\.frame\(width: 28, height: 28\)/);
  assert.match(creation, /\.accessibilityLabel\("關閉"\)\.accessibilityIdentifier\("chatgpt\.project\.cancel"\)/);
  const button = controls.indexOf('ChatGPTHandsStatusButton { model.openTapSettings() }');
  assert.ok(button > 0 && button < controls.indexOf('if model.page == nil, tap.connection != .needsLogin {'));
  assert.equal((controls.match(/\.frame\(width: (28|36), height: (28|36)\)/g) || []).length, 3, 'w177 width budget unchanged in this file');
  const status = between(section, 'struct ChatGPTHandsStatusButton: View', undefined);
  // 輪詢掛在一定存在的那一列（小鈕沒出現時空的 Group 上的 task 不會跑）。
  assert.match(controls, /\.task \{ await ChatGPTHandsStatusButton\.pollRemoteStatus\(\) \}/);
  assert.doesNotMatch(status, /Group \{ if visible \{ button \} \}\s*\.task/);
  assert.match(status, /guard !hands\.settings\.enabled, let status = remote\.status, status\.primaryIsHost else \{ return nil \}/);
  assert.match(status, /Image\(systemName: "hand\.raised"\)[\s\S]*\.frame\(width: 28, height: 28\)/);
  assert.match(status, /if entry\.noticeText != nil \{\s*Circle\(\)\.fill\(Color\.orange\)/);
  assert.match(status, /\.help\("設定 › Plugin › TAP › ChatGPT build"\)/);
  assert.match(status, /\.accessibilityLabel\("ChatGPT build 設定"\)/);
  assert.doesNotMatch(status, /Text\(summary/, 'no text button (would overflow the draggable reserve)');
});

test('Standard setup flow: eight steps, only authorize and pairing need the user, resumable state with no secrets', () => {
  const steps = between(setup, 'enum HandsSetupStep', 'enum HandsSetupStatus');
  assert.match(steps, /case host, cloudflared, authorize, tunnel, start, url, pairing, remember/);
  assert.match(steps, /var needsUser: Bool \{ self == \.authorize \|\| self == \.pairing \}/);
  const state = between(setup, 'struct HandsSetupState', 'struct HandsPendingTunnel');
  assert.deepEqual([...state.matchAll(/^\s*var (\w+): [^{\n]*$/gm)].map(m => m[1]),
    ['steps', 'hostDeviceID', 'accountID', 'zoneID', 'domain', 'tunnelID', 'tunnelName', 'publicHost', 'tokenTunnelID', 'cloudflaredSource', 'updatedAt', 'loginZoneID',
     'unconfirmedZoneIDs', 'confirmToken', 'discard', 'pendingTunnels', 'retiredHost', 'createdTunnels', 'releasedHosts'],
    'setup.json: step states and ids only, no secret');
  // W183 R5（實機＋GPT-6 審查）：建通道前記下的只有名字與時間；先確定寫進磁碟才建；找回要有「這一輪建的」證據。
  assert.deepEqual([...between(setup, 'struct HandsPendingTunnel', 'struct HandsRetiredHost').matchAll(/^\s*var (\w+):/gm)].map(m => m[1]), ['name', 'since']);
  // W183 R6a：遷移時要刪的那一筆舊紀錄也只有名稱與 id。
  assert.deepEqual([...between(setup, 'struct HandsRetiredHost', 'struct HandsSetupDiscard').matchAll(/^\s*var (\w+):/gm)].map(m => m[1]), ['host', 'zoneID', 'tunnelID', 'fixed']);
  const tunnelStep = between(setup, 'private func stepTunnel', '// 2. W183 R6a');
  assert.match(tunnelStep, /do \{ try mutateDurably \{ \$0\.pendingTunnels = [^\n]*\} \}\n\s*catch \{ return fail\(\.tunnel, [^\n]*\) \}\n\s*let credentials = /, 'pending name must be on disk before create');
  assert.match(tunnelStep, /case \.absent:\n\s*mutate \{ \$0\.pendingTunnels\?\[accountID\] = nil \}/);
  assert.match(tunnelStep, /case \.foreign:\n[^\n]*\n\s*recordError\("tunnel\.list", found\)\n\s*return fail\(\.tunnel, Self\.foreignMessage\(pending\.name\)\)/, 'foreign: stop, neither adopt nor recreate');
  assert.match(between(setup, 'private func mutate(_ change', 'private func set('), /writeAtomically\(data, to: stateURL\) \}\n\s*lock\.unlock\(\)/, 'mutate writes under the lock');
  assert.match(tunnelStep, /case \.ambiguous, \.malformed:\n\s*recordError\("tunnel\.list", found\)\n\s*return fail\(\.tunnel, Self\.lookupUnclearMessage\)/);
  assert.doesNotMatch(cloudflared, /func scrub|scrubbedErrors|func jsonValue/, 'no free-text error logging, no first-JSON-wins parsing');
  assert.match(setup, /private func recordError\(_ command: String, _ result: CommandResult\) \{[\s\S]*?category=\\\(HandsCloudflared\.errorCategory\(result\.lines\)\)"/);
  // W183 R3b 審查：「取消並重新授權」要清的那一筆也只有 id（冪等重按用）。
  assert.deepEqual([...between(setup, 'struct HandsSetupDiscard', 'struct HandsAuthorizationSummary').matchAll(/^\s*var (\w+):/gm)].map(m => m[1]),
    ['accountID', 'zoneID', 'fromLogin', 'tokenTunnelID']);
  assert.match(setup, /appendingPathComponent\("setup\.json"\)/);
  assert.match(setup, /HandsFiles\.writeAtomically\(data, to: stateURL\)/);
  assert.match(setup, /static let interruptedMessage = "上次中斷；開關開著會自動接著做"/);
  // 授權：獨立 HOME 跑 cloudflared tunnel login，網址只開 Cloudflare 的（W183 R5b：在這台的私訊框開；私訊鈕關掉才退回 OS 瀏覽器）；憑證收進鑰匙圈並刪檔。
  assert.match(setup, /arguments: \["tunnel", "--no-autoupdate", "--config", config\.path, "login"\]/);
  assert.match(setup, /HandsCloudflared\.loginURL\(in: line\)/);
  assert.match(setup, /if trigger != \.remote \{ self\.openIfCurrent\(url, round: round\) \}/);
  // W183 R5b 審查（GPT-6）：這一輪的識別碼——收尾先作廢再停指令；晚到的輸出、主執行緒上真的開頁之前都要核對；所有退出路徑最後一道收頁。
  const authorize = between(setup, 'private func stepAuthorize(', 'static func prepareMessage');
  assert.match(authorize, /let round = UUID\(\)\n\s*lock\.lock\(\); loginRound = \(round, false\); lock\.unlock\(\)\n\s*defer \{ endLoginRound\(round\); settleLoginPages\(round, done: false\) \}/);
  assert.match(authorize, /func stopAndClean\(\) -> Bool \{\n\s*endLoginRound\(round\)[^\n]*\n\s*command\.cancel\(\)/, 'invalidate before stopping');
  assert.match(authorize, /guard self\.publishRoundURL\(url, round: round,/);
  // W183 R8b 審查（GPT-6）：cloudflared 結束＝這一輪結束（先作廢）；正常結束＝授權頁先撤下（「確認中」），授權檔驗過、存好才標「完成」，其他照舊收。
  assert.match(authorize, /if let code = exitCode\.get\(\) \{\n(\s*\/\/[^\n]*\n)+\s*endLoginRound\(round, withdraw: code == 0\)\n\s*untrackRunner\(\)/);
  assert.match(authorize, /settleLoginPages\(round, done: true\)   \/\/ W183 R8b 審查/);
  assert.doesNotMatch(code(authorize), /publishLoginURL\(/, 'every exit goes through endLoginRound');
  const publish = between(setup, 'private func publishRoundURL(', 'private func isCurrentLogin(');
  assert.match(publish, /lock\.lock\(\); defer \{ lock\.unlock\(\) \}\n\s*guard let current = loginRound, current\.id == round, !current\.published else \{ return false \}/);
  assert.match(setup, /private func openIfCurrent\(_ url: URL, round: UUID\) \{\n\s*DispatchQueue\.main\.async \{ \[weak self\] in\n\s*guard let self, self\.isCurrentLogin\(url, round: round\) else \{ return \}\n\s*self\.dependencies\.openURL\(url\)/);
  const end = between(setup, 'private func endLoginRound(', '// MARK: -');
  assert.match(end, /guard mine else \{ return \}\n\s*if withdraw, let url \{ dependencies\.loginPagesWithdrawn\(url\) \} else \{ dependencies\.closeLoginPages\(url\) \}/, 'closes (or withdraws) even when no URL had been published');
  assert.match(end, /if done \{ dependencies\.loginPagesDone\(pending\.url\) \} else \{ dependencies\.closeLoginPages\(pending\.url\) \}/);
  assert.match(setup, /queue: BrowserExternalURLQueue = \.shared, present: Bool = true\)/);
  assert.match(setup, /_ = queue\.enqueue\(\[url\], sensitive: true\)/);
  assert.match(setup, /let read = Self\.readSmallFile\(certFile\)\n\s*certText = read\.text\n\s*unlink\(certFile\.path\)/);
  assert.match(setup, /guard \(info\.st_mode & 0o077\) == 0 else \{ return \(nil, true\) \}/, 'a cert readable by others is refused');
  assert.match(setup, /try dependencies\.accounts\.upsert\(accountID: cert\.accountID/);
  // 建通道：隨機名字；W183 R6a 固定網址 `<標籤>.<網域>`（不再隨機子網域、撞名不換名字）；不覆蓋既有 DNS、憑證只以 0600 暫存、用完刪；token 只進鑰匙圈。
  assert.match(setup, /let name = "tatwo-hands-" \+ dependencies\.random\(16\)/);
  assert.doesNotMatch(code(setup), /let label = "h" \+ dependencies\.random\(19\)/);
  assert.match(setup, /let label = dependencies\.loadSettings\(\)\.effectiveSubdomainLabel/);
  assert.match(setup, /base \+ \["route", "dns", tunnelID, requested\]/);
  assert.doesNotMatch(code(setup), /overwrite-dns/);
  assert.match(setup, /O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC, mode_t\(0o600\)/);
  assert.match(setup, /defer \{ unlink\(certFile\.path\) \}/);
  assert.match(setup, /unlink\(credentials\.path\)/);
  assert.match(setup, /try dependencies\.accounts\.saveTunnelToken\(token\)/);
  assert.match(setup, /SystemRandomNumberGenerator/);
  // 助理叫開、開關原本是關的：先在 Island 問。
  assert.match(setup, /if !dependencies\.loadSettings\(\)\.enabled, trigger == \.assistant \{/);
  assert.match(setup, /IslandNotice\.shared\.ask\(title: title, detail: detail, allowLabel: "允許"/);
  // W183 R8c：每台被勾選的設備自己當自己的主機；要用別台＝在 ChatGPT build 勾那台（那台自己跑自己的）。
  assert.match(setup, /static let otherDeviceRunsItselfMessage = "每台設備自己跑自己的：要用那台，在 ChatGPT build 勾那台/);
  assert.match(setup, /if !permit\.isActive, trigger == \.user \|\| trigger == \.remote, dependencies\.buildSelectDefault\(local\) \{/);
  // 「開始配對」只能由使用者在 App 按。
  assert.doesNotMatch(setup, /startPairing|openWindow/);
  // 退路（私訊鈕關掉）：授權頁在「設定」浮層底下打不開：先關設定再開 OS 瀏覽器；授權結束帶回原本那一頁（W183 R3 審查）。
  const browser = between(setup, '@MainActor static func openInOSBrowser', '@MainActor static func open(_ page');
  assert.ok(browser.indexOf('.tatwoCloseSettingsPage') > 0 && browser.indexOf('.tatwoCloseSettingsPage') < browser.indexOf('queue.enqueue([url], sensitive: true)'));
  assert.match(setup, /if reopen, let page \{ HandsSetup\.open\(page\) \}/);   // W183 R8c：登入完不接著做，帶回原本那一頁
  assert.match(cfCard, /HandsSetup\.returnAfterAuthorize = \.environmentLogin\n\s*HandsSetup\.shared\.login\(trigger: \.user\)/);
  assert.match(section, /OSChipButton\(title: "在這台打開授權頁", systemImage: "safari"\) \{ _ = build\.detail\(\.openLogin\(url\), shown: shown\) \}/);
  assert.match(cfCard, /HandsSetup\.openLoginPage\(url, returnTo: \.environmentLogin, onCancel: \{ HandsSetup\.shared\.cancel\(\) \}\)/);
  for (const source of [section, cfCard, build, buildModel]) assert.doesNotMatch(code(source), /openInOSBrowser/, 'W183 R5b: settings never jump to the Browser tab');
  assert.match(buildModel, /HandsSetup\.openLoginPage\(url, returnTo: \.tap, onCancel: \{ \[weak self\] in self\?\.setup\.cancel\(\) \}\)/);
  // 建通道：每一步發布前核對帳號與網域沒變。
  const tunnel = between(setup, 'private func stepTunnel', 'private func stepStart');
  assert.ok((tunnel.match(/guard unchanged\(\)/g) ?? []).length >= 4, 'unchanged() before every publish');
  // App 當掉／舊指令沒結束：重開先收掉上次那一組、清檔；取消要確認真的結束才清、才准重跑。
  assert.match(setup, /work\.async \{ \[weak self\] in self\?\.recoverAfterCrash\(\) \}/);
  assert.match(setup, /if HandsCloudflaredRunner\.isOurGuard\(pid: pgid, setupHome: home\) \{/);
  assert.match(setup, /guard command\.waitForExit\(timeout: dependencies\.exitWait\) else \{\n\s*lock\.lock\(\); lingering = command/);
  assert.match(setup, /if let reason = self\.unblock\(\) \{/);
  assert.match(setup, /guard Self\.removeLeftovers\(in: setupHome, dotDir: dotDir\) else \{/);
  // 給 AI 的狀態：沒有帳號名稱與 id。
  assert.match(setup, /"message": aiMessage\(step, entry\)/);
  assert.match(between(setup, 'private func aiMessage', 'enum HandsSetupTool'), /return redactedForAI\(entry\.message, keepHosts: step == \.url && entry\.status == \.done\)/);
  assert.doesNotMatch(code(between(setup, 'private func stepAuthorize', 'private struct CommandResult')), /displayName/);
  assert.doesNotMatch(code(between(setup, 'private func stepRemember', 'private func stepPairing')), /displayName/);
  // W183 R8c（GPT-6 必改 1）：沒有「一次只有一台主機」的交接了——主機那一步只看這台的啟用許可（主設備的設定正本；副設備看簽過的信封）。
  assert.match(setup, /var permit = dependencies\.buildPermit\(local\)/);
  assert.doesNotMatch(code(between(setup, 'private func stepHost', 'private func stepCloudflared')), /transferHost|confirmHostLease/);
});

test('cloudflared: only the pinned download verified by sha256 (archive and binary), never Homebrew, never auto-updated', () => {
  assert.match(cloudflared, /static let pinnedVersion = "2026\.9\.1"/);
  const hashes = [...cloudflared.matchAll(/SHA256: "([0-9a-f]+)"/g)].map(m => m[1]);
  assert.equal(hashes.length, 4);
  assert.ok(hashes.every(h => h.length === 64));
  assert.match(cloudflared, /releases\/download\/2026\.9\.1\/cloudflared-darwin-arm64\.tgz/);
  assert.match(cloudflared, /releases\/download\/2026\.9\.1\/cloudflared-darwin-amd64\.tgz/);
  // 壓縮檔讀進記憶體一次：驗雜湊與經 stdin 交給 tar 的是同一份位元組（W183 R3 審查 TOCTOU）。
  assert.match(cloudflared, /let data = try readArchive\(archive, expectedBytes: pin\.archiveBytes\)\n\s*guard sha256\(of: data\) == pin\.archiveSHA256 else \{ throw Failure\.hash \}/);
  assert.match(cloudflared, /process\.arguments = \["-xzf", "-", "-C", staging\.path, "--no-same-owner", "cloudflared"\]/);
  assert.match(cloudflared, /process\.standardInput = input/);
  // 只用下載的那份（Homebrew 路徑任何同使用者程式都改得到）；每個指令開之前重驗雜湊；殘餘明寫。
  assert.match(cloudflared, /static func locate\(root: URL\) -> Location\? \{\n\s*verifiedInstalled\(root: root\)\.map/);
  assert.doesNotMatch(code(cloudflared), /findCloudflared|\/opt\/homebrew|case homebrew/);
  assert.match(cloudflared, /殘餘（寫明、不宣稱已涵蓋）/);
  assert.match(setup, /guard let located = dependencies\.locateCloudflared\(\) else \{ return CommandResult\(code: nil, lines: \[\], problem: Self\.cloudflaredMissing\) \}/);
  assert.match(cloudflared, /guard sha256\(ofFile: extracted\) == pin\.binarySHA256 else \{ throw Failure\.binaryHash \}/);
  assert.match(cloudflared, /static let downloadHosts: Set<String> = \["github\.com", "objects\.githubusercontent\.com", "release-assets\.githubusercontent\.com"\]/);
  assert.match(cloudflared, /static func binDirectory\(root: URL\) -> URL \{ root\.appendingPathComponent\("bin", isDirectory: true\) \}/);
  // R2 的服務也找得到下載的那份；cloudflared 的沙盒只多開它自己這一個執行檔。
  assert.match(swift('Facade/ChatGPTHandsService.swift'), /var cloudflared: \(\) -> URL\? = \{ HandsCloudflared\.verifiedInstalled\(root: HandsGatewayLaunch\.Paths\.defaultRoot\(\)\) \}/);
  assert.match(read('Engines/chatgpt-hands/cloudflared.sb'), /\(allow file-read\* \(literal \(param "CF_BIN"\)\)\)/);
  // 設定指令：沙盒外殼、最小環境（PATH 指到空資料夾：cloudflared 開不了預設瀏覽器）、不繼承 fd、放棄責任行程。
  const runner = between(cloudflared, 'final class HandsCloudflaredRunner', undefined);
  // W183 R3 審查：先全拒寫、只准執行 cloudflared 本身、不准 fork、對外只開 443 與 DNS、不准連本機。
  for (const rule of ['(deny process-exec)\n', '(allow process-exec (literal (param "CF_BIN")))', '(deny process-fork)', '(deny file-write*)\n',
    '(deny file-read* (subpath (param "USER_HOME")) (subpath (param "HANDS_ROOT")) (subpath "/Volumes"))',
    '(allow file-read* file-write* (subpath (param "SETUP_HOME")))', '(deny network-outbound)\n', '(remote tcp "*:443")',
    '(deny network-outbound (remote ip "localhost:*"))', '(remote unix-socket (path-literal "/private/var/run/mDNSResponder"))']) {
    assert.ok(runner.includes(rule), rule);
  }
  assert.doesNotMatch(runner, /\(allow process-fork|\(allow network\*|\(allow file-write\* \(subpath "\//);
  // 看門程式：umask 077、App 的 stdin EOF 或訊號＝收掉 cloudflared、等它結束、清檔；正式一律包著。
  const guardScript = between(cloudflared, 'static let guardScript = """', '    """');
  for (const piece of ['umask 077', 'trap stop HUP INT TERM', 'exec 3<&0 </dev/null', 'wait "$child"', '/bin/rm -f -- "$home"/oc-* "$home"/cred-* "$home"/.cloudflared/*']) {
    assert.ok(guardScript.includes(piece), piece);
  }
  assert.match(runner, /let guarded = \["-c", Self\.guardScript, Self\.guardName, setupHome, HandsGatewayLaunch\.sandboxExec\] \+ sandbox \+ \[bin\] \+ programPrefix \+ arguments/);
  assert.match(runner, /posix_spawn_file_actions_adddup2\(&actions, stdinRead, STDIN_FILENO\)/);
  assert.match(runner, /_ = fcntl\(stdinWrite, F_SETNOSIGPIPE, 1\)/);
  assert.match(runner, /let environment = \["HOME": setupHome, "PATH": emptyBin\.path, "TMPDIR": tmp\.path \+ "\/", "LANG": "en_US\.UTF-8"\]/);
  assert.match(runner, /POSIX_SPAWN_CLOEXEC_DEFAULT/);
  assert.match(runner, /responsibility_spawnattrs_setdisclaim/);
  assert.match(runner, /init\(\) \{ disclaimResponsibility = true; programPrefix = \[\] \}\n\s*#if DEBUG\n\s*init\(disclaimResponsibilityForTesting: Bool, programPrefix: \[String\] = \[\]\)/, 'release always disclaims and runs cloudflared itself; only DEBUG self-tests may change either');
});

test('OS tools hands_setup_*: declared one per line, only the App and this device’s engines, never the external AI', () => {
  for (const name of ['hands_setup_status', 'hands_setup_step']) {
    assert.equal([...server.matchAll(new RegExp(`^  \\['${name}',.*\\],$`, 'gm'))].length, 1, `${name}: one tuple per line`);
  }
  assert.match(server, /\['hands_setup_step', [^\n]*enum: \['all', 'next', 'host', 'cloudflared', 'authorize', 'tunnel', 'start', 'url', 'pairing', 'remember'\]/);
  // 參數由 App 檢查（HandsSetupTool.handle：只認 step／action／hostDeviceID，對話身分欄位忽略、其他一律拒）。
  assert.match(setup, /guard keys\.isEmpty else \{ throw Failure\.invalid\("hands_setup_status takes no arguments"\) \}/);
  const allows = between(bridge, 'static func allows(caller:', '/// 只有隔離根在暫存目錄');
  assert.match(allows, /if HandsContract\.externalAIMethods\.contains\(method\) \{ return false \}\n\s*\/\/ W183 R3[^\n]*\n\s*if HandsSetupTool\.methods\.contains\(method\) \{ return HandsSetupTool\.allows\(caller\) \}/);
  const gate = between(setup, 'static func allows(_ caller: OSSocketCaller) -> Bool {', '    }\n');
  assert.match(gate, /case \.app, \.engine, \.helper: return true/);
  assert.match(gate, /case \.job, \.ssh, \.externalAI, \.other: return false/);
  for (const list of ['untrustedCallerMethods', 'stagingReadOnlyMethods', 'sshForwardMethods']) {
    assert.doesNotMatch(setBody(bridge, list), /hands_setup/, list);
  }
  assert.match(bridge, /case "hands_setup_status", "hands_setup_step":\n\s*return try HandsSetupTool\.handle\(method: method, params: params\)/);
  assert.match(setup, /throw Failure\.needsUser\("配對要使用者在私訊框按［連線］/);
  const manual = swift('Resources/tatwo-assistant.md');
  const flow = between(manual, '## ChatGPT build 標準流程', undefined);
  for (const words of ['`hands_setup_status`', '`hands_setup_step', 'Authorize', '［連線］', '8 碼配對碼', '同一步失敗兩次就停下來問使用者', '~/.cloudflared', 'os-for-chatgpt']) {
    assert.ok(flow.includes(words), words);
  }
  assert.match(read('docs/os-mcp-tools.md'), /\| hands_setup_status \|[\s\S]*\| hands_setup_step \|/);
});

test('Secondary device RPC: device-signed like memory_propose, whitelisted fields, never an AI tool', () => {
  for (const method of ['remote_hands_status', 'remote_hands_action']) {
    assert.ok(setBody(bridge, 'untrustedCallerMethods').includes(`"${method}"`), `${method}: needs a device signature`);
    assert.ok(!setBody(bridge, 'sshForwardMethods').includes(`"${method}"`));
    assert.ok(!setBody(bridge, 'stagingReadOnlyMethods').includes(`"${method}"`));
    assert.doesNotMatch(server, new RegExp(method), 'not an OS MCP tool');
  }
  assert.match(bridge, /case "remote_hands_status", "remote_hands_action":\n\s*let \(sender, payload\) = try DeviceDispatch\.shared\.authenticate\(method: method, proof: params\)\n\s*return try HandsRemote\.handle/);
  assert.match(remote, /static let actions: Set<String> = \["start_pairing", "stop_pairing", "revoke_grant", "revoke_all", "claim_host", "release_host",\s*"start_setup", "continue_setup", "cancel_setup", "turn_off", "reauthorize", "confirm_authorization",\s*"unlock_safety"\]/);
  // W183 R8c（GPT-6 必改 1）：單一主機的 claim_host／release_host 拿掉（每台被勾選的設備自己當自己的主機）。
  assert.match(remote, /case "claim_host", "release_host":\n[^\n]*\n\s*throw Failure\.invalid\(hostClaimRetired\)/);
  // 一次只有一台主機（W183 R3 審查）：主設備記著主機；原主機是別台而且還在配對清單＝拒絕；主設備是原主機＝關開關、等關口停下。
  const claim = between(remote, 'static func claim(sender: String', 'static func release(sender: String');
  assert.match(claim, /refusal\.set\(busyReason\)/);
  // W183 R6a 審查（GPT-6）：主設備是原主機＝關開關＋換主機在同一次寫設定裡；存不進去＝不宣稱交接成功；關口停了才確認。
  assert.match(claim, /if same\(current, local\) \{ settings\.enabled = false; handedOver\.set\(true\) \}/);
  assert.match(claim, /catch HandsSettingsFailure\.offButNotSaved \{[\s\S]*?host\.serviceChanged\(\)\n\s*throw HandsRemote\.Failure\.invalid\("settings_not_saved"\)/);
  assert.match(claim, /if handedOver\.get\(\) \{\n\s*host\.serviceChanged\(\)/);
  // W183 R6b：配對碼不再放進所有設備都輪詢的狀態（card 拿掉）；只有按［連線］那台用 connect_status 拿得到（tests/w183-connect.test.mjs）。
  assert.doesNotMatch(code(remote), /result\["card"\]|auth\.pendingCard/);
  // 副設備：斷線、到期不顯示舊配對碼；查詢去重、退避；按鈕走自己的佇列。
  assert.match(remote, /if inFlight \|\| \(!force && Date\(\) < nextAllowed\) \{ lock\.unlock\(\); return \}/);
  assert.match(remote, /static let backoff: \[TimeInterval\] = \[10, 30, 60\]/);
  assert.match(remote, /self\.status = self\.status\?\.withoutPairing\(\)/);
  assert.match(remote, /actionQueue\.async/);
  // W183 R8 整合：副設備看主機那一塊（ChatGPTHandsRemoteView）拿掉（每台自己當主機）；守的「斷線、太舊不顯示舊的」改在多設備的畫面：
  // 每台那一格只信夠新的回報（主設備收到的時間＋這台自己最近拿到全貌的時間，兩個都看）。
  assert.match(swift('Facade/HandsBuildController.swift'), /return server\.timeIntervalSince\(received\) <= Self\.freshWindow && dependencies\.now\(\)\.timeIntervalSince\(synced\) <= Self\.freshWindow/);
  assert.doesNotMatch(code(remote), /transcript|overview_snapshot|accessHash|refreshHash|tokens/);
  assert.match(remote, /dispatch\.callPrimary\(method: "remote_hands_status", payload: \[:\]\)/);
  // 副設備畫面：撤銷送到主機做。W183 R6a：「在主機開始配對」與配對卡拿掉（連線改成私訊框的［連線］卡，配對碼只給按的那台）。
  assert.doesNotMatch(code(section), /remote\.act\("start_pairing"\)/);
  // W183 R8 整合：別台的撤銷＝「已連線與撤銷」的「其他設備」（卡片內確認）→ 經主設備的信箱交給那台（只作用在按的時候看到的那一組）。
  assert.match(section, /confirmTitle: "全部撤銷"\) \{ _ = build\.detail\(\.revokeDevice\(device\.id\), shown: shown\) \}/);
  assert.match(buildModel, /case \.revokeDevice\(let id\):\n\s*build\.revokeAll\(for: id\)/);
});

test('Review card (v3 V6): candidate SHA, main-line advanced notice, executable files flagged, no copy-merge-command; no orange dot for hands rooms', () => {
  const card = swift('New/DispatchCard.swift');
  assert.match(card, /if let handsReview \{ HandsReviewBanner\(summary: handsReview\); Divider\(\) \}/);
  // diff 與審查卡同一次、同一個候選 SHA 算（重新載入也一起換；途中重新交件＝丟錯不顯示混合版本；W183 R3 審查）。
  assert.equal((card.match(/model\.loadDispatchReview\(/g) ?? []).length, 2);
  assert.doesNotMatch(card, /loadDispatchDiff|handsReviewSummary/);
  const review = between(banner, 'func loadDispatchReview', undefined);
  assert.match(review, /let context = try dispatchGitContext\(id\)[\s\S]*?DispatchGit\.diff\(context\)[\s\S]*?handsReviewSummary\(context\)[\s\S]*?guard again\?\.handsCandidate == candidate, review\?\.candidate == candidate else[\s\S]*?handsMarkReviewed\(context, truncated: diff\.truncated\)/);
  assert.match(card, /\.fill\(room\.isHands \? handsColor\(room\.liveness\) : room\.needsAttention \? \.orange : livenessColor\(room\.liveness\)\)/);
  assert.match(card, /\} else if room\.isRunning, !room\.isHands \{/);
  assert.match(card, /Text\(room\.isHands \? "ChatGPT 手腳（外部資料）" : room\.engineLabel\)/);
  const colors = between(card, 'private func handsColor', 'private func livenessColor');
  assert.doesNotMatch(colors, /orange/);
  for (const words of ['候選版本', '主線已前進', '會被執行的檔', '外部資料', '沒有「複製合併指令」']) assert.ok(banner.includes(words), words);
  assert.match(banner, /try service\.validateCandidate\(workdir: workdir, base: base, candidate: candidate\)/);
  assert.match(banner, /DispatchGit\.background/);
  assert.doesNotMatch(banner, /Button\("複製合併指令"\)|copyDispatchMergeCommand/);
});

test('Self-test w183ui is registered and never touches the real keychain or network', () => {
  const selftest = swift('SelfTest.swift');
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w183ui"[\s\S]{0,200}HandsUIAcceptance\.run\(\)/);
  const acceptance = swift('Facade/HandsUIAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /CloudflareMemorySecrets\(\)/);
  assert.doesNotMatch(acceptance, /CloudflareKeychain\(\)|CloudflareAccountsStore\.shared|HandsSetup\.shared|URLSession/);
  assert.match(acceptance, /installCloudflared: \{ done in done\(\.failure\(\.download\)\) \}/);
});

// 設定指令的 Seatbelt 規則實跑：用 Node 扮演 cloudflared（同一份規則），證明使用者的 ~/.cloudflared、手腳的 App 設定讀不到、
// 預設瀏覽器與任何其他程式開不了、沙盒外（/tmp、假 Homebrew bin、App 資料）寫不進去、本機服務與其他 unix socket 連不到，
// 只有設定流程的家目錄寫得進去。家目錄用暫存資料夾假扮，不碰真的家目錄。
test('setup command Seatbelt profile: deny-by-default writes, exec, fork, local services and sockets; only the setup home writable', { skip: process.platform !== 'darwin' }, async () => {
  const marker = 'static let profile = """\n';
  const profile = between(cloudflared, marker, '    """').slice(marker.length).split('\n').map(line => line.replace(/^ {4}/, '')).join('\n');
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183ui-sb-')));
  try {
    const home = path.join(root, 'home'), hands = path.join(root, 'hands'), setupHome = path.join(hands, 'cf-setup');
    fs.mkdirSync(path.join(home, '.cloudflared'), { recursive: true });
    fs.mkdirSync(path.join(hands, 'app'), { recursive: true });
    fs.mkdirSync(setupHome, { recursive: true });
    fs.writeFileSync(path.join(home, '.cloudflared', 'cert.pem'), 'W183UI-CANARY-home\n');
    fs.writeFileSync(path.join(hands, 'app', 'settings.json'), '{"canary":"W183UI-CANARY-app"}\n');
    const probe = path.join(setupHome, 'probe.cjs');
    const brew = path.join(root, 'brew', 'bin');
    fs.mkdirSync(brew, { recursive: true });
    fs.writeFileSync(path.join(brew, 'cloudflared'), '#!/bin/sh\n');
    // 本機服務（TCP）與一個 unix socket：沙盒裡的程式都不該連得到。
    const net = await import('node:net');
    const tcp = net.createServer(socket => socket.end()); await new Promise(done => tcp.listen(0, '127.0.0.1', done));
    const sockPath = path.join(root, 's.sock');
    const unix = net.createServer(socket => socket.end()); await new Promise(done => unix.listen(sockPath, done));
    fs.writeFileSync(probe, `const fs=require('fs'),cp=require('child_process'),net=require('net');const out={};
const r=(k,f)=>{try{fs.readFileSync(f);out[k]='READ'}catch(e){out[k]=e.code}};
const w=(k,f)=>{try{fs.writeFileSync(f,'x');out[k]='WROTE'}catch(e){out[k]=e.code}};
r('userCert',process.argv[2]);r('appSettings',process.argv[3]);
w('setupWrite',process.argv[4]+'/written.txt');w('appWrite',process.argv[5]+'/app/evil.txt');
w('tmpWrite','/private/tmp/w183ui-sb-'+process.pid);w('brewWrite',process.argv[6]+'/cloudflared');
const o=cp.spawnSync('/usr/bin/open',['-h']);out.open=o.error?o.error.code:'RAN';
const s=cp.spawnSync('/bin/sh',['-c','true']);out.exec=s.error?s.error.code:'RAN';
const c=(k,opts)=>new Promise(done=>{const x=net.connect(opts);x.on('connect',()=>{out[k]='CONNECTED';x.destroy();done()});x.on('error',e=>{out[k]=e.code;done()})});
Promise.all([c('localTCP',{host:'127.0.0.1',port:+process.argv[7]}),c('unixSocket',{path:process.argv[8]})]).then(()=>console.log(JSON.stringify(out)));`);
    const node = fs.realpathSync(process.execPath);
    // 跟 HandsCloudflaredRunner.fullProfile 一樣：上層資料夾只開 stat（24 格，沒用到填 "/"）。
    const ancestors = [...new Set([path.join(setupHome, 'x'), node].flatMap(p => {
      const out = []; for (let d = path.dirname(p); d !== '/'; d = path.dirname(d)) out.push(d); return out;
    }))].sort();
    assert.ok(ancestors.length <= 24);
    const slots = Array.from({ length: 24 }, (_, i) => ['-D', `ANC_${i}=${ancestors[i] ?? '/'}`]).flat();
    const full = profile + '\n' + Array.from({ length: 24 }, (_, i) => `(allow file-read-metadata (literal (param "ANC_${i}")))`).join('\n') + '\n';
    assert.match(cloudflared, /static let ancestorSlots = 24/);
    assert.match(cloudflared, /\(allow file-read-metadata \(literal \(param \\"ANC_\\\(\$0\)\\"\)\)\)/);
    const args = ['-p', full, '-D', `USER_HOME=${home}`, '-D', `HANDS_ROOT=${hands}`, '-D', `SETUP_HOME=${setupHome}`, '-D', `CF_BIN=${node}`, ...slots,
      node, probe, path.join(home, '.cloudflared', 'cert.pem'), path.join(hands, 'app', 'settings.json'), setupHome, hands, brew,
      String(tcp.address().port), sockPath];
    const { spawn } = await import('node:child_process');
    const run = await new Promise(done => {
      const child = spawn('/usr/bin/sandbox-exec', args, { env: { HOME: setupHome, PATH: path.join(setupHome, 'nobin') } });
      let stdout = '', stderr = '';
      child.stdout.on('data', d => { stdout += d; }); child.stderr.on('data', d => { stderr += d; });
      const timer = setTimeout(() => child.kill('SIGKILL'), 30_000);
      child.on('close', status => { clearTimeout(timer); done({ status, stdout, stderr }); });
    });
    tcp.close(); unix.close();
    assert.equal(run.status, 0, run.stderr);
    const out = JSON.parse(run.stdout.trim().split('\n').at(-1));
    assert.deepEqual(out, { userCert: 'EPERM', appSettings: 'EPERM', setupWrite: 'WROTE', appWrite: 'EPERM', tmpWrite: 'EPERM', brewWrite: 'EPERM',
      open: 'EPERM', exec: 'EPERM', localTCP: 'EPERM', unixSocket: 'EPERM' }, run.stderr);
    assert.ok(!fs.existsSync(path.join(hands, 'app', 'evil.txt')));
    assert.equal(fs.readFileSync(path.join(brew, 'cloudflared'), 'utf8'), '#!/bin/sh\n', 'the fake Homebrew binary is untouched');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// 看門程式實跑（W183 R3 審查：App 當掉時設定指令與明文要有人收）：App 的 stdin EOF 或 SIGTERM＝收掉子行程、等它結束、刪暫存憑證與授權檔；
// 子行程自己正常結束＝照它的結束碼、不刪（App 還要讀授權檔）；umask 077。
test('setup guard: stdin EOF or SIGTERM kills the child and deletes leftovers; a normal exit keeps them and passes the code', { skip: process.platform !== 'darwin' }, async () => {
  const marker = 'static let guardScript = """\n';
  const script = between(cloudflared, marker, '    """').slice(marker.length).split('\n').map(line => line.replace(/^ {4}/, '')).join('\n');
  const guardName = cloudflared.match(/static let guardName = "([^"]+)"/)[1];
  const { spawn } = await import('node:child_process');
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'w183ui-guard-')));
  const plant = home => {
    fs.mkdirSync(path.join(home, '.cloudflared'), { recursive: true });
    for (const file of ['oc-x.pem', 'cred-x.json', '.cloudflared/cert.pem', 'keep.txt']) fs.writeFileSync(path.join(home, file), 'W183UI-CANARY');
  };
  const left = home => ['oc-x.pem', 'cred-x.json', '.cloudflared/cert.pem'].filter(file => fs.existsSync(path.join(home, file)));
  const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
  const run = (home, command, finish) => new Promise(done => {
    const child = spawn('/bin/sh', ['-c', script, guardName, home, ...command], { stdio: ['pipe', 'pipe', 'pipe'], detached: true });
    let out = '';
    child.stdout.on('data', d => { out += d; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 20_000);
    child.on('close', code => { clearTimeout(timer); done({ code, out }); });
    finish(child);
  });
  try {
    for (const how of ['eof', 'term']) {
      const home = path.join(root, how); fs.mkdirSync(home); plant(home);
      const pidFile = path.join(home, 'child.pid');
      const result = await run(home, ['/bin/sh', '-c', `echo $$ > '${pidFile}'; exec /bin/sleep 30`], child => {
        const wait = setInterval(() => {
          if (!fs.existsSync(pidFile)) return;
          clearInterval(wait);
          if (how === 'eof') child.stdin.end(); else process.kill(-child.pid, 'SIGTERM');
        }, 50);
      });
      const pid = Number(fs.readFileSync(pidFile, 'utf8'));
      assert.equal(result.code, 143, how);
      assert.deepEqual(left(home), [], `${how}: leftovers deleted`);
      assert.ok(fs.existsSync(path.join(home, 'keep.txt')), `${how}: only the named leftovers`);
      assert.ok(!alive(pid), `${how}: the child is gone`);
    }
    const home = path.join(root, 'normal'); fs.mkdirSync(home); plant(home);
    const result = await run(home, ['/bin/sh', '-c', `umask; echo x > '${home}/.cloudflared/new.pem'; exit 7`], () => {});
    assert.equal(result.code, 7);
    assert.equal(result.out.trim(), '0077', 'umask 077 for everything cloudflared writes');
    assert.equal((fs.statSync(path.join(home, '.cloudflared/new.pem')).mode & 0o777).toString(8), '600');
    assert.deepEqual(left(home), ['oc-x.pem', 'cred-x.json', '.cloudflared/cert.pem'], 'a normal exit keeps the cert for the App to read');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// W183 R3b：副設備也能把設定流程跑完（主導實機：副設備只有遠端檢視、沒有開關、授權網址只在主機、步驟狀態是英文）。
test('R3b secondary switch: device-signed start/continue/cancel/turn_off/reauthorize run the host\'s standard flow; host switch follows', () => {
  const action = between(remote, 'static func setupAction(_ op: String, payload: [String: Any] = [:], host: Host', 'static let revokeNotSavedReason');
  // 開始：主機的開關跟著開、照原本的流程跑（主機＝主設備自己；授權頁直接開）。主機是別台＝不做。
  assert.match(action, /if let current = settings\.hostDeviceID, !current\.isEmpty, !same\(current, local\) \{ throw Failure\.invalid\(HandsHostAuthority\.busyReason\) \}/);
  // W183 R5b：副設備按的＝trigger .remote（主機不在自己的畫面開授權頁）。
  assert.match(action, /case "start_setup":[\s\S]*?host\.service\.updateSettings \{ \$0\.enabled = true \}[\s\S]*?host\.refreshUI\(\)[\s\S]*?flow\.runAll\(trigger: \.remote, allowLogin: true, hostOverride: local, requester: sender\)/);
  assert.match(action, /case "continue_setup":[\s\S]*?flow\.runAll\(trigger: \.remote, allowLogin: true, hostOverride: local, requester: sender\)/);
  // W183 R5b 審查（GPT-6）：按的那台＝驗章得到的 sender（payload 不能指定）；每個設定工作一個編號。
  assert.match(remote, /var result = try setupAction\(op, payload: payload, host: host, sender: sender\)/);
  assert.match(remote, /case "remote_hands_status":\n\s*guard payload\.isEmpty else \{ throw Failure\.invalid\("status takes no fields"\) \}\n\s*return status\(host, sender: sender\)/);
  assert.match(setup, /currentRun = \(Self\.randomLabel\(16\), trigger == \.remote \? requester : nil\)/);
  assert.doesNotMatch(action, /trigger: \.user/);
  assert.match(action, /case "continue_setup":\s*guard settings\.enabled else \{ throw Failure\.invalid\(notEnabledReason\) \}/);
  // 關掉＝跟主機畫面的「關掉」一樣（關開關＝撤銷全部 grant、取消進行中的設定、叫關口停）。
  assert.match(action, /case "turn_off":[\s\S]*?updateSettings \{ \$0\.enabled = false \}[\s\S]*?flow\.turnedOff\(\)\n\s*host\.serviceChanged\(\)/);
  // W183 R3b 審查：先取消（世代換掉）再關；存不進去＝主機已在記憶體強制關閉，回報照實說（不是「撤銷沒存」）。
  assert.match(action, /case "turn_off":\s*(\/\/[^\n]*\n\s*)*flow\.cancel\(\)\n\s*var failure: String\?\n\s*do \{ _ = try host\.service\.updateSettings \{ \$0\.enabled = false \} \}\n\s*catch HandsSettingsFailure\.offButNotSaved \{ failure = offNotSavedReason \}/);
  assert.match(action, /case "cancel_setup":\s*flow\.cancel\(\)/);
  assert.match(action, /if let refusal = flow\.reauthorize\(trigger: \.remote, requester: sender\) \{ throw Failure\.invalid\(refusal\.rawValue\) \}/);
  assert.match(remote, /case "start_setup", "continue_setup", "cancel_setup", "turn_off", "reauthorize", "confirm_authorization", "unlock_safety":\n\s*guard payload\["grant_id"\] == nil else/);
  // W183 R3b 審查：設定動作要簽章涵蓋的有效期限；往前走的還要主機給的流程世代（舊的、過期的一律不收）。
  assert.match(action, /guard let expires = \(payload\["expires_at"\] as\? NSNumber\)\?\.doubleValue,\s*expires > now\.timeIntervalSince1970, expires <= now\.timeIntervalSince1970 \+ maxAhead else \{\s*throw Failure\.invalid\(expiredReason\)/);
  assert.match(action, /if epochOps\.contains\(op\) \{\s*guard let epoch = payload\["setup_epoch"\] as\? String, epoch\.utf8\.count <= 64, epoch == flow\.setupEpoch else \{\s*throw Failure\.invalid\(staleEpochReason\)/);
  // W183 R8c 審查（GPT-6 高）：解除安全鎖也要帶主機給的流程世代（晚到的舊解除不收）。
  assert.match(remote, /static let epochOps: Set<String> = \["start_setup", "continue_setup", "reauthorize", "confirm_authorization", "unlock_safety"\]/);
  assert.match(remote, /payload\["expires_at"\] = Int\(Date\(\)\.timeIntervalSince1970 \+ HandsRemote\.requestLifetime\)/);
  assert.match(setup, /var setupEpoch: String \{ lock\.lock\(\); defer \{ lock\.unlock\(\) \}; return "\\\(bootNonce\)\.\\\(generation\)" \}/);
  // W183 R3b 審查（Claude）：主機的設定流程在跑時不交出主機；第 5 步寫「打開」前在設定鎖裡再核取消與主機。
  assert.match(between(remote, 'static func claim(sender: String', 'static func release(sender: String'), /if host\.flow\?\.isBusy == true \{ throw HandsRemote\.Failure\.invalid\(setupBusyReason\) \}/);
  const start = between(setup, 'private func stepStart', 'private func stepURL');
  assert.match(start, /dependencies\.checkpoint\("start\.beforeWrite"\)[\s\S]*?try dependencies\.updateSettings \{ settings in\s*if self\.cancelled \{ refusal\.set\("cancelled"\); return \}\s*if let current = settings\.hostDeviceID, !current\.isEmpty, current\.caseInsensitiveCompare\(hostDevice\) != \.orderedSame \{/);
  assert.match(between(oneSwitch, 'static func turnOff(', 'static func retry('), /setup\.cancel\(\)\n\s*setEnabled\(false\)\n\s*setup\.turnedOff\(\)/, 'local switch: cancel first, then off');
  assert.match(remote, /default:\n\s*throw Failure\.invalid\("op"\)/, 'unknown ops are refused, not treated as revoke_all');
  assert.match(remote, /flow: HandsSetup\.shared,\n\s*refreshUI: \{ DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ HandsState\.shared\.refresh\(\) \} \} \}/);
  // 副設備畫面：開關（主機的開關）、先選主機（預設主設備）、關掉先在卡片內確認；繼續、取消。
  // W183 R5（使用者「點開啟時卡很久」＋GPT-6 審查）：按下去先照按的樣子顯示；那一次動作成功或失敗時由 client 自己清掉。
  // W183 R8a：副設備的開關＝主機的開關（HandsBuildModel 的 remote 模式）；按下去先照按的樣子顯示、還在問主機／斷線／上一個還沒回來＝停用。
  // W183 R8 整合：開關＝中央設定的總開關（在哪一台按都一樣，照看到的版本 CAS）；按下去先照按的樣子顯示（設定版本還是按的那一版、
  // 後端沒說做不了才算），還沒從主設備拿到設定、上一個還沒回來＝停用。下面 HandsRemoteClient 的 act 照舊驗（［連線］到主設備還在用）。
  assert.match(buildModel, /var enabled: Bool \{ pendingSwitch \?\? input\.enabled \}/);
  assert.match(buildModel, /guard let pending = pendingEnabled, pending\.revision == build\.config\?\.configRevision, build\.actionProblem == nil else \{ return nil \}/);
  assert.match(buildModel, /var canToggle: Bool \{ input\.configKnown && pendingSwitch == nil \}/);
  assert.match(build, /\.disabled\(!model\.canToggle \|\| confirmingOff\)/);
  const act = between(remote, 'func act(_ op: String', 'private func epochForRequest');
  assert.equal((act.match(/if self\.pendingToken == token \{ self\.pendingEnabled = nil; self\.pendingToken = nil \}/g) ?? []).length, 2, 'cleared on both success and failure, only by its own request');
  assert.match(between(buildModel, 'case .setEnabled(let on):\n            return', 'case .setDevice('), /return on == i\.enabled \? \[\] : \[\.setEnabled\(on\)\]/);
  assert.match(section, /\(devices > 1 \? "勾選的 \\\(devices\) 台都會關掉：" : ""\)/);
  assert.match(build, /\} else \{\n\s*confirmingOff = true   \/\/ 關掉先在卡片內確認/);
  // W183 R6a：副設備不選主機（預設主設備；在副設備按也一樣，送到主設備做）；「改用這台當主機」在「詳細」、先確認。
  assert.doesNotMatch(code(section), /"（主設備・預設）"|remoteHostChoice/);
  // W183 R8 整合：畫面不再送單主機的遠端設定動作（start_setup、continue_setup、cancel_setup、reauthorize…）——多設備的設定一律經 R8c 的
  // 控制器（中央設定 CAS、信箱）；主設備那端照舊驗章、帶期限與世代（上面），給舊版副設備用。
  assert.doesNotMatch(code(buildModel) + code(between(section, 'struct ChatGPTBuildDetails: View {', 'struct ChatGPTHandsPairingCard: View')) + code(build),
    /remote\.act\(|HandsRemoteClient/);
  // 不是 AI 工具（os-mcp 沒有）、外部 AI 不能叫。
  for (const op of ['start_setup', 'continue_setup', 'turn_off', 'reauthorize']) assert.doesNotMatch(server, new RegExp(op), op);
});

test('R3b login URL: only on the device-signed channel while waiting; never in hands_setup_status, step messages or files', () => {
  // 主機：只在第 3 步等使用者按、這台是主機時才帶；網址不寫進步驟訊息（訊息會給 AI、會存檔）。
  assert.match(setup, /var pendingLoginURL: URL\? \{\n\s*lock\.lock\(\); defer \{ lock\.unlock\(\) \}\n\s*guard let url = loginURLValue, current\.step\(\.authorize\)\.status == \.waitingUser else \{ return nil \}/);
  assert.match(setup, /message: trigger == \.remote \? Self\.authorizeWaitingRemoteMessage : Self\.authorizeWaitingMessage\)/);
  assert.match(between(setup, 'private func publishRoundURL(', 'private func isCurrentLogin('), /set\(\.authorize, \.waitingUser, message\)/);
  for (const name of ['authorizeWaitingMessage', 'authorizeWaitingRemoteMessage']) {
    const waitingMessage = setup.match(new RegExp(`static let ${name} = "([^"]*)"`))?.[1] ?? '';
    assert.ok(waitingMessage.includes('在這台打開授權頁') && waitingMessage.includes('私訊框') && !/\\\(|https?:/.test(waitingMessage), waitingMessage);
  }
  assert.match(setup, /static let aiAuthorizeWaiting = "等使用者在瀏覽器按授權"/);
  const payload = between(setup, 'func statusPayload()', 'enum HandsSetupTool');
  assert.doesNotMatch(payload, /login_url|loginURL\b|absoluteString/, 'hands_setup_status never carries the URL');
  assert.match(payload, /"message": aiMessage\(step, entry\)/);
  assert.match(payload, /payload\["user_action"\] = aiMessage\(pending, state\.step\(pending\)\)/);
  assert.match(payload, /return Self\.aiAuthorizeWaiting/);
  // W183 R8c（GPT-6 必改 3）：公共狀態（所有設備都輪詢得到的 remote_hands_status）不再帶登入網址與確認 token；網址只經信箱給按的那台。
  const status = between(remote, 'static func status(_ host: Host', 'static func same(');
  assert.match(status, /let loginOpen = isHost && host\.flow\?\.pendingLoginURL != nil/);
  assert.doesNotMatch(code(status), /result\["login_url"\]|confirm_token|absoluteString/);
  // 副設備：只收 Cloudflare 授權頁、太舊或斷線就拿掉；W183 R5b：在這台的私訊框開（私訊鈕關掉才退回 OS 瀏覽器分頁）。
  assert.match(remote, /loginURL = \(object\["login_url"\] as\? String\)\.flatMap \{ \$0\.utf8\.count <= 4096 \? HandsCloudflared\.loginURL\(in: \$0\) : nil \}/);
  assert.match(remote, /if !fresh \{ copy\.loginURL = nil \}/);
  assert.match(between(remote, 'func withoutPairing()', 'var settingUpStep'), /copy\.loginURL = nil/);
  const open = between(remote, '@MainActor func openLoginHere', '@MainActor private func settleAwaiting');
  assert.match(open, /openLoginPage\?\(url\)\s*\?\? HandsSetup\.openLoginPage\(url, onCancel: \{ \[weak self\] in self\?\.cancelFromPage\(\) \}\)/);
  // W183 R5b 審查（Claude）：頁面的「取消」＝這台馬上不等了（不等輪詢），再請主機取消。
  assert.match(remote, /@MainActor func cancelFromPage\(\) \{\n\s*disarmAutoOpen\(\)\n\s*openedLoginURL = nil[^\n]*\n\s*endAwaiting\(closePage: false\)\n\s*act\("cancel_setup"\)/);
  assert.match(open, /guard HandsCloudflared\.loginURL\(in: url\.absoluteString\) == url else \{ return \}/);
  assert.match(setup, /_ = queue\.enqueue\(\[url\], sensitive: true\)/);
  // W183 R8 整合（R8c 必改 3）：副設備不再從公共狀態拿主機的網址（「在這台打開主機的授權頁」那一塊拿掉）；替別台登入的網址只經信箱到
  // 按的那台，由控制器開在這台的私訊框 Browser（HandsSetup.openLoginPage：只收 Cloudflare 授權網址）；這台自己的授權頁在「…」›「步驟」可以再打開。
  assert.match(swift('Facade/HandsBuildController.swift'), /openLogin: \{ url, cancel in _ = HandsSetup\.openLoginPage\(url, onCancel: cancel\) \}/);
  assert.match(swift('Facade/HandsBuildController.swift'), /if !result\.final, state == "login_url", let raw = object\["url"\] as\? String, let url = HandsCloudflared\.loginURL\(in: raw\) \{/);
  assert.match(section, /OSChipButton\(title: "在這台打開授權頁", systemImage: "safari"\) \{ _ = build\.detail\(\.openLogin\(url\), shown: shown\) \}/);
  assert.match(buildModel, /case \.openLogin\(let url\):\n\s*HandsSetup\.openLoginPage\(url, returnTo: \.tap, onCancel: \{ \[weak self\] in self\?\.setup\.cancel\(\) \}\)/);
  // 沒有任何地方把網址寫進日誌或檔案。
  for (const source of [setup, remote]) assert.doesNotMatch(code(source), /NSLog\(|print\(|Logger\(/);
  assert.match(swift('Facade/HandsUIAcceptance.swift'), /授權網址（canary）不在 hands_setup_status／step、步驟訊息、這個世界的任何檔案/);
  assert.match(read('docs/os-mcp-tools.md'), /等使用者在瀏覽器按授權/);
});

test('R3b after authorization: both screens show the account and domain; cancel-and-reauthorize clears only this login and stops first', () => {
  assert.match(setup, /return "已授權：Cloudflare 帳號〈\\\(account\)〉、網域〈\\\(name\)〉"/);
  assert.match(section, /HandsSetup\.authorizedText\(account: summary\.account, domain: summary\.domain\)/);
  assert.equal((section.match(/title: "取消並重新授權"/g) ?? []).length, 1, 'one shared row for host, secondary and environment login');
  // W183 R8 整合：副設備看主機那一塊拿掉（每台自己當主機：每台在自己的「…」›「帳號與網域」確認、重新授權自己的登入）；共用的那一列只剩這台與環境登入。
  assert.equal((section.match(/HandsAuthorizationRow\(summary:/g) ?? []).length, 1, 'this device uses the shared row (environment login uses it too)');
  assert.match(cfCard, /HandsAuthorizationRow\(summary: summary/);
  assert.match(section, /HandsAuthorizationRow\(summary: summary, canReauthorize: hands\.activeGrants\.isEmpty/);
  assert.match(remote, /result\["authorized"\] = \["account_name": summary\.account, "domain": summary\.domain \?\? "",\s*"needs_confirm": summary\.needsConfirm, "cleanup_pending": summary\.cleanupPending\] as \[String: Any\]/);
  assert.match(remote, /result\["can_reauthorize"\] = !flow\.isBusy && !flow\.dependencies\.hasActiveGrant\(\)/);
  const reauth = between(setup, 'func reauthorize(trigger: HandsSetupTrigger', 'func authorizedSummary()');
  assert.match(reauth, /guard !dependencies\.hasActiveGrant\(\) else \{ return \.paired \}/);
  assert.match(reauth, /forceOnly: \[\.authorize\], requester: requester, prelude:/);
  const discard = between(setup, 'private func discardAuthorization()', '@discardableResult\n    private func enqueue');
  const order = ['mutate { $0.discard = record }', 'updateSettings { $0.enabled = false }', 'dependencies.serviceChanged()',
    'removeDomain(accountID: record.accountID, zoneID: record.zoneID, removeTunnelToken: false)', 'dependencies.accounts.removeTunnelToken()', 'value.discard = nil']
    .map(n => discard.indexOf(n));
  assert.ok(order.every(i => i >= 0) && order.every((v, i) => i === 0 || order[i - 1] < v), `record, stop, clear, then drop the record ${order}`);
  // W183 R6a 審查：只看 loginZoneID（換用環境登入原本就有的帳號時也要確認，但那不是這次登入拿到的，不刪）。
  assert.match(discard, /fromLogin: state\.loginZoneID == zoneID,/, 'only the credential this login obtained');
  assert.match(discard, /if record\.fromLogin \{/);
  // W183 R3b 審查：這一輪的通道 token 不看帳號有沒有整個移除都刪；清到一半失敗可以重按（discard 留著）。
  assert.match(discard, /if let tunnel = record\.tokenTunnelID, snapshot\.tokenTunnelID == tunnel \{/);
  assert.match(cfStore, /func removeTunnelToken\(\) throws \{/);
  assert.match(between(setup, 'func reauthorize(trigger: HandsSetupTrigger', 'func authorizedSummary()'), /if state\.discard == nil \{/);
  assert.match(setup, /\$0\.loginZoneID = cert\.zoneID/);
  assert.match(cfStore, /func removeDomain\(accountID: String, zoneID: String, removeTunnelToken: Bool\) throws -> Bool \{/);
  // 取消並重新授權：不刪 Cloudflare 上的通道與 DNS（不跑任何刪除指令）。W183 R6a：刪除指令只在「詳細」清沒用到的通道（使用者確認後）。
  assert.doesNotMatch(code(between(setup, 'func reauthorize(trigger: HandsSetupTrigger', 'private func enqueue')), /"delete"|"cleanup"|deleteDNSRecord/);
  assert.equal((code(setup).match(/"delete"/g) ?? []).length, 1, 'only deleteUnusedTunnels runs tunnel delete');
  assert.match(between(setup, 'func deleteUnusedTunnels(', 'private func maintenance('), /base \+ \["delete", tunnel\.id\]/);
  assert.doesNotMatch(code(setup), /"cleanup"|"-f"|"--force"|overwrite-dns/);
});

test('R3b Chinese step status on both devices', () => {
  const labels = between(setup, 'var label: String {', 'static func label(forCode');
  for (const [code, text] of [['pending', '等待中'], ['running', '進行中'], ['waitingUser', '等你按'], ['done', '完成'], ['failed', '失敗']]) {
    assert.match(labels, new RegExp(`case \\.${code}: "${text}"`), code);
  }
  assert.match(setup, /HandsSetupStatus\(rawValue: code\)\?\.label \?\? "未知"/);
  assert.match(remote, /var statusLabel: String \{ HandsSetupStatus\.label\(forCode: status\) \}/);
  // W183 R8 整合：副設備看主機步驟的那一塊拿掉（每台自己當主機、在自己的「…」›「步驟」看自己的，中文狀態同一套）；
  // 別台的狀態在設備節點上只是一個標記＋那台回報的一句話（HandsBuildController；沒有英文狀態碼）。
  assert.doesNotMatch(section, /struct ChatGPTHandsRemoteView/);
  assert.match(swift('Facade/HandsBuildController.swift'), /func phaseText\(_ id: String\) -> String \{ fresh\(report\(id\)\) \? report\(id\)\?\.phaseText \?\? "" : "" \}/);
  assert.match(section, /statusLabel: entry\.status\.label/);
  assert.match(swift('Facade/HandsUIAcceptance.swift'), /try await remoteSetupChecks\(check, fixture\)/);
});

test('R3b review: authorization is a confirmation gate bound to this round (no tunnel, DNS or start before the user confirms)', () => {
  const authorize = between(setup, 'private func stepAuthorize', 'private struct CommandResult');
  // W183 R8c（GPT-6 必改 4）：登入只是登入——收進鑰匙圈、更新帳號清單就停；不採用、不標「待確認」、不接著建通道。等確認的舊狀態照舊擋（不跳過）。
  assert.doesNotMatch(authorize, /adopt\(|unconfirmedZoneIDs = \(value/);
  assert.match(authorize, /mutate \{ \$0\.loginZoneID = cert\.zoneID \}/);
  assert.match(authorize, /return waitUser\(\.authorize, Self\.chooseDomainMessage\)/);
  assert.match(authorize, /if !force, snapshot\.awaitingConfirmation, let zone = snapshot\.zoneID/);
  assert.match(authorize, /if snapshot\.discard != nil \{ return fail\(\.authorize, Self\.cleanupPendingMessage\) \}/);
  // 晚到的取消：等名稱時看取消；收進鑰匙圈之後才取消＝回滾這一輪新增的。
  assert.match(authorize, /while looked\.wait\(timeout: \.now\(\) \+ dependencies\.pollInterval\) == \.timedOut \{\s*if cancelled \|\| Date\(\) > lookupDeadline \{ break \}\s*\}\s*if cancelled \{ return \.stopped \}/);
  assert.match(authorize, /dependencies\.checkpoint\("authorize\.afterUpsert"\)\n\s*if cancelled \{[\s\S]*?if !domainExisted \{ _ = try\? dependencies\.accounts\.removeDomain/);
  // 第 4 步以後都先過確認這關。
  for (const [fn, step] of [['private func stepTunnel', 'tunnel'], ['private func stepStart', 'start'], ['private func stepRemember', 'remember']]) {
    assert.match(between(setup, fn, 'private func'), new RegExp(`if let gate = authorizationGate\\(\\) \\{ return fail\\(\\.${step}, gate\\) \\}`), fn);
  }
  // W183 R8c：不再自動挑帳號與網域（chosenAccountDomain 拿掉）；只用明確選好的那一組。
  assert.doesNotMatch(setup, /func chosenAccountDomain/);
  assert.match(authorize, /if case let \(_, domain\)\? = recordedAccountDomain\(\) \{/);
  // 確認：確認碼（定長比對）＋畫面上看到的網域；名稱不知道＝只再查一次、不確認；開關關著＝只記成完成。
  const confirm = between(setup, 'func confirmAuthorization(token: String, domain shown: String, trigger: HandsSetupTrigger = .user, requester: String? = nil) throws -> Bool', 'private func domainName');
  assert.match(confirm, /HandsAuth\.constantTimeEqual\(expected, token\) else \{ throw HandsConfirmRefusal\.stale \}/);
  assert.match(confirm, /guard let known else \{[\s\S]*?self\?\.lookupNames\(zoneID: zone\); return false/);
  assert.match(confirm, /guard shown == known else \{ throw HandsConfirmRefusal\.changed \}/);
  assert.match(between(setup, 'private func commitConfirmation', 'private func lookupNames'), /return false   \/\/ W183 R8c：不接著做/);
  // AI：確認不是工具動作；給 AI 的只說「等使用者在畫面確認」，沒有網域、主機名。
  assert.doesNotMatch(between(setup, 'enum HandsSetupTool', undefined), /confirmAuthorization/);
  const payload = between(setup, 'func statusPayload()', 'enum HandsSetupTool');
  assert.doesNotMatch(payload, /"domain":|"public_host":/);
  assert.match(payload, /return Self\.aiConfirmWaiting/);
  assert.match(setup, /static let aiConfirmWaiting = "等使用者在畫面確認授權的 Cloudflare 帳號與網域（你看不到帳號與網域，也不能替他按）"/);
  assert.match(between(setup, 'func redactedForAI', 'func statusPayload'), /\(\$0, "（你的網域）"\)/);
  assert.match(read('docs/os-mcp-tools.md'), /唯一的例外是 `url`/);
  // 副設備：確認碼與網域經設備簽章 RPC 來回；代碼換成這台該怎麼做。
  assert.doesNotMatch(code(between(remote, 'static func status(_ host: Host', 'static func same(')), /confirm_token/, 'W183 R8c: the public status never carries the confirm token');
  assert.match(remote, /case "authorize\.needs_login"\?: return "那台還沒登入 Cloudflare（或還沒選網域）：在 ChatGPT build 的 Cloudflare 節點替那台按「登入 Cloudflare」/);
  // W183 R8 整合：副設備顯示主機步驟的那一塊拿掉；代碼換成白話（displayMessage）照舊在 HandsRemote（舊版副設備還會讀）。
  assert.match(remote, /var displayMessage: String/);
  for (const words of ['是這個，繼續', '再查一次網域名稱', '再清一次']) assert.ok(section.includes(words), words);
  const acceptance = swift('Facade/HandsUIAcceptance.swift');
  for (const fn of ['confirmGateChecks', 'lateCancelChecks', 'multiDomainChecks', 'cleanupRetryChecks', 'settingsFailureChecks', 'raceChecks', 'browserPathChecks']) {
    assert.match(acceptance, new RegExp(`try await ${fn}\\(check, (world, fixture, authorized: authorized|fixture)\\)`), fn);
  }
});

test('R3b review: switching off survives a failed settings write (in-memory forced off, grants revoked first)', () => {
  const settingsSource = swift('Facade/HandsSettings.swift');
  const service = swift('Facade/HandsService.swift');
  assert.match(settingsSource, /final class HandsForcedOff: @unchecked Sendable/);
  assert.match(settingsSource, /if HandsForcedOff\.shared\.contains\(settingsURL\) \{ settings\.enabled = false \}/);
  assert.match(swift('Facade/HandsGatewayLaunch.swift'), /enabled: object\["enabled"\] as\? Bool == true && !HandsForcedOff\.shared\.contains\(url\)/);
  const update = between(service, 'func updateSettings(', 'func setEnabled(');
  const order = ['revocationProblem = auth.revokeAll(reason: "switched_off")', 'HandsForcedOff.shared.set(settings.settingsURL, true)',
    'HandsSandbox.terminateAll()', 'try settings.save(new)', 'if turningOff { throw HandsSettingsFailure.offButNotSaved }',
    'HandsForcedOff.shared.set(settings.settingsURL, false)'].map(n => update.indexOf(n));
  assert.ok(order.every(i => i >= 0) && order.every((v, i) => i === 0 || order[i - 1] < v), `revoke and force off before saving ${order}`);
});

test('R3b review: the login page is a memory-only browser tab (not in tabs.json, recently closed, archives or history) and closes when the flow ends', () => {
  const browser = 'App/Sources/Tatwo2/Browser/';
  const queue = read(browser + 'BrowserExternalURLQueue.swift');
  const registry = read(browser + 'BrowserTabRegistry.swift');
  const lifecycle = read(browser + 'BrowserWorkSpaceLifecycle.swift');
  const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
  const history = read(browser + 'Import/BrowserHistoryStore.swift');
  assert.match(queue, /func enqueue\(_ urls: \[URL\], sensitive: Bool\) -> Bool/);
  assert.match(queue, /func consume\(whenMounted mounted: Bool, open: \(\[URL\]\) -> Void\) \{\s*consumeItems/);
  assert.match(lifecycle, /store\.openExternal\(spaceID: target\.id, url: item\.url, sensitive: item\.sensitive\)/);
  assert.match(design, /registry\.openTab\(owner: \.workSpace\(spaceID: spaceID\), url: url, sensitive: sensitive\)/);
  assert.match(registry, /if sensitive \{ sensitiveTabIDs\.insert\(tab\.id\) \}/);
  assert.match(registry, /let stored = tabs\.filter \{ !sensitiveTabIDs\.contains\(\$0\.id\) \}\.map/);
  // Single and batch close/undo privacy is executed in the swiftc fixture below.
  assert.match(registry, /tabs\(ownedBy: \.workSpace\(spaceID: id\)\)\.filter \{ !sensitiveTabIDs\.contains\(\$0\.id\) \}/);
  assert.match(registry, /static let closeSensitiveTabsNotification = Notification\.Name\("tatwo\.browser\.closeSensitiveTabs"\)/);
  assert.match(history, /guard !Self\.isExcluded\(url\) else \{ return \}/);
  assert.match(setup, /if let marker = loginMarker\(url\) \{ BrowserHistoryStore\.excludeVisits\(containing: marker\) \}/);
  assert.match(setup, /if url == nil, let had \{ dependencies\.closeLoginPages\(had\) \}/);
  assert.match(remote, /if let hook = closeLoginPages \{ hook\(url\) \} else \{ HandsSetup\.postCloseLoginPages\(only: url\) \}/);
});

// 真的把瀏覽器的佇列、生命週期、分頁登記、瀏覽紀錄編在一起跑（跟 browser-default-browser 同一組檔案）：敏感分頁不落檔、流程結束關掉。
test('R3b review swiftc: sensitive login tab through the real queue, lifecycle and registry never reaches disk', { skip: process.platform !== 'darwin' }, () => {
  const browser = path.join(repo, 'App/Sources/Tatwo2/Browser/');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'w183r3b-browser-'));
  try {
    const design = fs.readFileSync(browser + 'BrowserWorkSpaceDesignView.swift', 'utf8');
    const store = design.slice(design.indexOf('@MainActor'), design.indexOf('// MARK: - End local fixture model'));
    const source = path.join(dir, 'fixture.swift'), binary = path.join(dir, 'fixture');
    fs.writeFileSync(source, `import SwiftUI
import Combine
${store}
// 只替身匯入器的相依（跟 browser-daily-nav 一樣）；瀏覽紀錄、佇列、生命週期、分頁登記都是正式程式碼。
enum BrowserImportError: Error { case tooLarge, invalidData }
enum BrowserImportSnapshot { static let maximumJSONBytes = 16 * 1024 * 1024 }
enum ChromiumImporter {
  static func navigationURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), ["https", "http"].contains(url.scheme) else { return nil }
    return url
  }
}
@main struct Fixture {
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let registryURL = root.appendingPathComponent("tabs.json")
    let registry = BrowserTabRegistry(storageURL: registryURL)
    let store = BrowserWorkSpaceStore(registry: registry)
    let queue = BrowserExternalURLQueue(notifications: NotificationCenter())
    let lifecycle = BrowserWorkSpaceLifecycle(store: store, registry: registry, queue: queue, settingsURL: root.appendingPathComponent("settings.json"))
    let canary = "W183R3BCANARY0123456789"
    let login = URL(string: "https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.example.org%2F" + canary)!
    let normal = URL(string: "https://example.com/normal")!
    BrowserHistoryStore.excludeVisits(containing: canary)
    precondition(queue.enqueue([login], sensitive: true) && queue.enqueue([normal]))
    try lifecycle.consumePendingURLs()
    let tab = registry.tabs.first { $0.url == login }!
    precondition(registry.isSensitive(tab.id) && !registry.isSensitive(registry.tabs.first { $0.url == normal }!.id))
    registry.update(tab.id, url: URL(string: "https://dash.cloudflare.com/login?redirect_uri=" + login.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!, title: "x", favicon: nil)
    try registry.flush()
    let history = BrowserHistoryStore(storageURL: root.appendingPathComponent("history.json"))
    try await history.recordVisit(url: registry.tabs.first { $0.id == tab.id }!.url!, title: "x")
    try await history.recordVisit(url: normal, title: "n")
    registry.close(tab.id)
    precondition(registry.recentlyClosed.allSatisfy { !($0.url?.absoluteString.contains(canary) ?? false) })
    precondition(queue.enqueue([login], sensitive: true)); try lifecycle.consumePendingURLs()
    let batchLogin = registry.tabs.first { $0.url == login }!
    if case let .workSpace(spaceID) = batchLogin.owner { _ = registry.closeWorkSpaceTabs(spaceID: spaceID, selectedID: batchLogin.id) }
    precondition(registry.recentlyClosed.allSatisfy { !($0.url?.absoluteString.contains(canary) ?? false) })
    if case let .workSpace(spaceID) = batchLogin.owner { _ = registry.reopenWorkSpaceBatch(spaceID: spaceID) }
    precondition(!registry.tabs.contains { $0.url?.absoluteString.contains(canary) == true })
    precondition(queue.enqueue([login], sensitive: true)); try lifecycle.consumePendingURLs()
    NotificationCenter.default.post(name: BrowserTabRegistry.closeSensitiveTabsNotification, object: nil)
    for _ in 0..<50 where registry.tabs.contains(where: { $0.url == login }) { try await Task.sleep(nanoseconds: 20_000_000) }
    precondition(!registry.tabs.contains { $0.url == login })
    try registry.flush()
    var disk = ""
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
      disk += (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    precondition(!disk.contains(canary) && disk.contains("example.com") && disk.contains("normal"), disk)   // JSON 會把 / 寫成 \\/
    print("W183R3B browser fixture passed")
  }
}
`);
    const files = ['TatwoBrowserLaneCore.swift', 'BrowserTabRegistry.swift', 'BrowserGeneralSettings.swift', 'BrowserShortcuts.swift',
      'BrowserDailyNavigationPolicy.swift', 'BrowserExternalURLQueue.swift', 'BrowserWorkSpaceLifecycle.swift', 'Import/BrowserHistoryStore.swift'].map(f => browser + f);
    const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2', ...files, source, '-o', binary], { encoding: 'utf8', timeout: 240000 });
    assert.equal(compile.status, 0, compile.stderr);
    // 資料放在自己的資料夾（掃「磁碟上有沒有授權網址」時不要掃到這份測試原始碼本身）。
    const data = path.join(dir, 'data');
    fs.mkdirSync(data);
    const run = spawnSync(binary, [data], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.match(run.stdout, /W183R3B browser fixture passed/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});


test('W183 R5b／R8b: Cloudflare authorization opens as a tab in the DM box Browser (phone in-app browser), not an OS Browser tab', () => {
  const sheet = swift('DM/GlobalDMWebSheet.swift');
  const dmBrowser = swift('DM/DMBrowser.swift');
  const pane = swift('DM/DMBrowserView.swift');
  const page = swift('Browser/BrowserSensitivePage.swift');
  const backend = swift('Browser/ChromiumCEFBackend.swift');
  // 起點只收驗過的 Cloudflare 授權網址；起點只能從這個工廠建；Browser 只照用途驗過的起點開（Pod、配對頁不能用網址開）。
  assert.match(sheet, /guard HandsCloudflared\.loginURL\(in: url\.absoluteString\) == url, let host = url\.host\?\.lowercased\(\) else \{ return nil \}/);
  assert.match(sheet, /private init\(url: URL, title: String, host: String, source: Source\)/);
  assert.match(dmBrowser, /case \.cloudflareLogin: return GlobalDMWebSheet\.cloudflareAuthorization\(url\)\?\.url\n\s*case \.chatgptDeveloper, \.chatgptPairing, \.chatgptLogin: return nil/);
  assert.match(dmBrowser, /guard store\.isEnabled, let start = Self\.validatedStart\(url, purpose\) else \{ return false \}/);
  // 網址 pill：照看得到的那一頁實際載入的網址（W183 R8b 審查：還沒有＝「尚未確認來源」，不拿起點頂替）；不是 https、網域對不上＝標出來。
  // 流程的頁沒有網址列可以改、不另開視窗（W184 G2：打網址或搜尋的框在直欄「網址」卡 DMBrowserRail.swift，只開新的一般分頁，w183-browser 守）。
  assert.match(dmBrowser, /var sourceKnown: Bool \{ !pageClosed && pageURL != nil \}/);
  assert.match(dmBrowser, /return !\(host == expected \|\| host\.hasSuffix\("\." \+ expected\)\)/);
  assert.match(dmBrowser, /case \.cloudflareLogin: return HandsCloudflared\.loginHost\.split\(separator: "\."\)\.suffix\(2\)\.joined\(separator: "\."\)/);
  assert.match(pane, /return warn \? "exclamationmark\.triangle\.fill" : "lock\.fill"/);
  assert.doesNotMatch(code(pane) + code(dmBrowser), /TextField|NSWindow\(|NSPanel\(|WKWebView|BrowserTabRegistry\.shared|tabs\.json/);
  // 自動打開私訊框、切到 Browser、這個分頁在最前面；分頁全部收掉＝私訊框回原狀（使用者沒動過才改回）。
  const reveal = between(dmBrowser, 'private func reveal(_ id: UUID) {', 'private func restoreBox() {');
  // W184 AB（GPT-6 複核 新發現 1）：開框是一個請求（先記原本的樣子），框真的開好之後才切到 Browser、分頁在最前面。
  assert.match(reveal, /if prior == nil \{ prior = BoxState\(docked: store\.isOpen, floating: store\.isFloatingOpen, browsing: store\.isBrowsing\) \}\s*pendingOpens\.removeValue\(forKey: id\)\?\.cancel\(\)\s*let request = GlobalDMOpenRequest\(/);
  assert.match(reveal, /store\.showBrowser\(\)\s*activeID = id/);
  assert.match(dmBrowser, /BoxState\(docked: store\.isOpen, floating: store\.isFloatingOpen, browsing: store\.isBrowsing\) == applied \{\s*store\.isOpen = prior\.docked\s*store\.isFloatingOpen = prior\.floating/);
  // 分頁不會自己消失：框收起來＝頁面拿下來（不銷毀、沒有時限）；流程完成＝標「完成」；流程結束（取消、失敗、逾時）＝關；總開關關掉＝全關。
  const place = between(dmBrowser, 'private func place(focus: Bool = false) {', 'private func focusActive() {');
  assert.match(place, /if tab\.id == activeID, let target \{ page\.attach\(to: target\) \} else \{ page\.detach\(\) \}/);
  assert.doesNotMatch(dmBrowser, /handoff|asyncAfter|Task\.sleep/);
  assert.match(dmBrowser, /forName: Self\.loginPagesNotification[\s\S]{0,500}self\?\.loginPage\(url, end\)/);
  const ends = between(dmBrowser, 'func loginPage(_ url: URL, _ end: LoginPageEnd) {', '// MARK: - 頁面放在哪個框');
  assert.match(ends, /case \.done: retire\(tab\.id, done: true, note: nil\)/);
  assert.match(ends, /case \.withdrawn: if !tab\.done \{ retire\(tab\.id, done: false,/);
  assert.match(ends, /case \.closed: if !tab\.done \{ removeTab\(tab\.id\) \}/);
  assert.match(dmBrowser, /\.sink \{ \[weak self\] enabled in MainActor\.assumeIsolated \{ if !enabled \{ self\?\.closeAll\(cancelling: true\) \} \} \}/);
  // 使用者關掉還沒完成的分頁＝取消那個流程（例如這一輪授權）；完成的只關。
  assert.match(dmBrowser, /let cancel = tab\.done \? nil : cancelActions\[id\]\s*removeTab\(id\)\s*cancel\?\(\)/);
  // HandsSetup：cloudflared 正常結束＝頁面先撤下；授權檔驗過、存好才標「完成」（W183 R8b 審查）；其他＝關。都照舊關 OS 瀏覽器退路的敏感分頁。
  assert.match(setup, /endLoginRound\(round, withdraw: code == 0\)/);
  const done = between(setup, 'private static func postLoginPages(', '/// W183 R5b 審查（GPT-6）：這一輪還有效');
  assert.match(done, /closeSensitiveTabsNotification, object: url\)\n\s*guard let url else \{ return \}\n\s*NotificationCenter\.default\.post\(name: DMBrowser\.loginPagesNotification, object: url, userInfo: \["state": end\.rawValue\]\)/);
  // 副設備：連不上＝馬上收；網址換了、換了一輪＝收；網址撤回、同一輪還在收尾＝頁面先撤下（分頁寫「確認中」）；
  // 主機的第 3 步完成（或在等你確認）而且是這一頁那一輪才標「完成」。
  const settle = between(remote, '@MainActor private func settleAwaiting', '/// W183 R8b：主機的第 3 步做完了');
  assert.match(settle, /guard let status else \{\n\s*endAwaiting\(closePage: true\)/);
  assert.match(settle, /if status\.loginURL != nil \|\| otherRun \{\n\s*closeOpenedPage\(\)/);
  assert.match(settle, /openedPageWithdrawn = true\n\s*if let hook = loginPageWithdrawn \{ hook\(url\) \} else \{ HandsSetup\.postLoginPagesWithdrawn\(only: url\) \}/);
  assert.ok(settle.indexOf('guard timedOut || settled else { return }') < settle.indexOf('Self.authorizationFinished(status)'));
  // 鍵盤：分頁出現、頁面開好都把鍵盤給頁面；對象清單、錄鍵頁收起；Browser 開著時不送出、Esc 給網頁。
  assert.match(swift('DM/GlobalDMStore.swift'), /func showBrowser\(\) \{\s*isPickerOpen = false\s*isEditingDirectKeys = false/);
  assert.match(place, /if focus, target != nil \{ focusActive\(\) \}/);
  assert.match(swift('DM/GlobalDMStore.swift'), /func send\(\) -> Bool \{\n\s*guard !isBrowsing else \{ return false \}/);
  // W183 R5b 審查（GPT-6）：Computer Use 以 TATWO 自己為目標——Browser 有敏感分頁時撤銷並拒絕（截圖、讀 AX、每個輸入、回傳前）。
  const cu = read('App/Sources/Tatwo2/New/ComputerUseController.swift');
  assert.match(dmBrowser, /BrowserSensitivePageGate\.pageAppeared\(\)   \/\/ 敏感頁出現/);
  assert.match(dmBrowser, /BrowserSensitivePageGate\.register\(self\)/);
  assert.match(between(cu, 'private func checkContext(', 'func perform('), /try refuseSelfWhileSensitive\(grant\)/);
  const observe = between(cu, 'private func observe(_ grant', '/// A sheet abort');
  assert.ok(observe.indexOf('try refuseSelfWhileSensitive(grant)') < observe.indexOf('ComputerUseNative.read('), 'checked before the AX read');
  assert.ok(observe.lastIndexOf('try refuseSelfWhileSensitive(grant)') > observe.indexOf('SCScreenshotManager.captureImage'), 'checked after capture, before returning');
  assert.match(cu, /sensitivePageOpen && lane == \.externalApplication && pid == ownPID/);
  assert.match(page, /browsers\.contains \{ \$0\.value\?\.isSensitive == true \} \|\| !BrowserTabRegistry\.withSensitiveTabs\.isEmpty/);
  // 授權時不給擷取：授權頁正在畫面上＝框所在的視窗 sharingType .none（W183 R8b 審查：以視窗計數）；完成、關掉、框換了就放手。
  // W184 D（契約 §3b 已同步）：「在畫面上」＝選中的是還開著的敏感分頁、分頁總覽沒開、Browser 在框裡看得到；敏感分頁開著但在看對話、
  // 收起來、倒放、選中別的分頁＝可以截圖。Computer Use 閘門照舊看 isSensitive（上面那條，有敏感分頁就擋）。
  assert.match(dmBrowser, /WindowCaptureShield\.shared\.hold\(self, window: needsCaptureProtection \? window : nil\)/);
  assert.match(dmBrowser, /Self\.capturesBlocked\(activeSensitive: activeTab\?\.isSensitive == true, tabList: isShowingTabList, onScreen: shownWindow != nil\)/);
  assert.match(dmBrowser, /window\.sharingType = \.none/);
  // W183 R5b 審查（GPT-6）：敏感頁的新視窗一律不開原生視窗（CEF 建立前攔截，疊在同一張頁面）；只准 https。
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const popup = between(bridge, 'bool TatwoClient::OnBeforePopup(', 'void TatwoClient::OnBeforePopupAborted(');
  const contained = popup.indexOf('if (opener.sensitivePage) {');
  assert.ok(contained > 0 && contained < popup.indexOf('#pragma mark - W112 link-to-tab') && contained < popup.indexOf('[[NSWindow alloc]'),
    'sensitive branch runs before link-to-tab and before any NSWindow');
  const branch = between(popup, 'if (opener.sensitivePage) {', '#pragma mark - W183 R5b sensitive popups end');
  assert.doesNotMatch(branch, /NSWindow|makeKeyAndOrderFront|onPopupCreated/);
  assert.match(branch, /if \(!policy\.human \|\| contain == nil \|\| opener\.window == nil \|\| stage == nil\) \{\n\s*LogBrowserLifecycle\(@"popup_blocked_sensitive"\);\n\s*return true;/);
  assert.match(branch, /contained\.sensitivePage = YES;[\s\S]*contain\(contained\);[\s\S]*window_info\.SetAsChild/);
  assert.match(bridge, /if \(policy\.https_only\) return \[scheme isEqualToString:@"https"\] && CanonicalHost\(url\)\.length > 0;/);
  assert.match(bridge, /policy\.https_only = owner && \(owner\.sensitivePage \|\| owner\.httpsOnly\);/);
  assert.match(bridge, /_sensitivePage = opener\.sensitivePage;/);
  assert.match(backend, /browser\.sensitivePage = true\n[\s\S]{0,400}browser\.onPopupCreated = nil/);
  // W183 R8b：上一頁＝最上面那一頁退一頁；它沒有上一頁而且是頁內開的新視窗＝收掉那一層。
  assert.match(page, /if top\.canGoBack \{ top\.goBack\(\) \} else \{ popTop\(\) \}/);
  // HandsSetup：流程拿到網址＝這台私訊框的 Browser（不關設定、不切 OS 的 Browser 工作區、不開 OS 瀏覽器分頁）；私訊鈕關掉才退回舊路。
  const open = between(setup, 'static func openLoginPage(', '/// 在 OS 的瀏覽器打開');
  assert.doesNotMatch(open, /tatwoCloseSettingsPage|tatwoOpenWorkOSWindow|NSApp\.activate|queue\.enqueue/);
  assert.match(open, /guard let sheet = GlobalDMWebSheet\.cloudflareAuthorization\(url\) else \{ return false \}/);
  assert.match(open, /if browser\.open\(url: sheet\.url, purpose: \.cloudflareLogin, onCancel: onCancel, fallback: \{ elsewhere\(\$0, back\) \}\) \{\s*returnAfterAuthorize = nil/);
  assert.match(setup, /HandsSetup\.openLoginPage\(url, onCancel: \{ HandsSetup\.shared\.cancel\(\) \}\)/);
  assert.match(setup, /enum HandsSetupTrigger: String, Sendable \{ case user, assistant, remote, resume \}/);
  // 真的頁面：Browser 後端給的 human 頁面（共用 context；後端沒啟動走同一套啟動、用 host 的租約），不進分頁清單、AI 橋、WebMCP、瀏覽紀錄。
  const sensitive = between(backend, 'func openSensitivePage(', 'private func closeTab(');
  assert.match(sensitive, /sharingContextWith: source, initialURL: "about:blank", actor: \.human/);
  assert.match(sensitive, /persistentProfile: location\.persistentProfilePath,\s*initialURL: "about:blank", actor: \.human/);
  assert.match(sensitive, /if profileLease == nil \{ profileLease = try TatwoCEFProfileLocationResolver\.prepareForRuntime\(location\) \}/);
  assert.doesNotMatch(sensitive, /actor: \.agent|BrowserAgentBridge|TatwoWebMCPRuntime|BrowserHistoryStore|pageMetadataHandler|entries\[/);
  assert.match(sensitive, /TatwoCEFContainerTeardownContract\.detachFromHostWindow\(browser\)/);
  assert.match(page, /await runtime\.authorize\(\)[\s\S]*EmbeddedBrowserRuntimeMountPolicy\.allowsMount[\s\S]*runtime\.mount\(\)/);
  assert.doesNotMatch(code(page), /TatwoCEFProfileLeaseRegistry|prepareForRuntime|TatwoCEFBrowserView\(|WKWebView/, 'no own profile lease or browser');
  // 副設備：按的那台自動開、授權結束標完成或收回、不跳頁；主機不開（trigger .remote）。
  assert.match(remote, /static let autoOpenOps: Set<String> = \["start_setup", "continue_setup", "reauthorize"\]/);
  assert.match(remote, /let run = Self\.autoOpenOps\.contains\(op\) && response\["started"\] as\? Bool == true && decoded\?\.setupRunMine == true\n\s*\? decoded\?\.setupRun : nil/);
  assert.match(remote, /guard Date\(\) <= until, let status, status\.setupRun == run, status\.setupRunMine else \{\n\s*disarmAutoOpen\(\)/);
  assert.match(remote, /if let url = status\.loginURL \{\s*disarmAutoOpen\(\)\s*openLoginHere\(url\)/);
  assert.match(remote, /guard authorized, !timedOut, openedInTab else \{ return \}/);
  assert.match(remote, /DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ awaitLimit, execute: item\)/);
  assert.match(remote, /MainActor\.assumeIsolated \{ self\?\.checkFreshness\(\) \}/);
  // 文案：副設備那一塊的長說明縮成一句，「在這台打開授權頁」留著當備援。
  // W183 R8 整合：副設備看主機授權頁的那一塊拿掉（R8c：公共狀態沒有授權網址；替別台登入的網址經信箱只到按的那台、開在它的 Browser 分頁，
  // w183build「W183 R8 整合 替別台登入」）；「在這台打開授權頁」留在這台的「…」›「步驟」當備援（也是開在私訊框的 Browser）。
  assert.doesNotMatch(section, /private func loginBlock\(|static func authorizationRow\(/);
  assert.match(between(section, '    private var setupProgress: some View {', '    private func stepRow('),
    /OSChipButton\(title: "在這台打開授權頁", systemImage: "safari"\) \{ _ = build\.detail\(\.openLogin\(url\), shown: shown\) \}/);
  const integration = swift('Facade/HandsBuildIntegrationAcceptance.swift');
  for (const label of ['W183 R8 整合 替別台登入：授權頁開在這台私訊框的 Browser 分頁', 'W183 R8 整合 替別台登入完成：這台的授權分頁標「完成」',
    'W183 R8 整合 替別台登入時還沒完成就關掉授權分頁＝請那台取消這一輪']) assert.ok(integration.includes(label), label);
  assert.match(integration, /openLogin: \{ url, cancel in _ = dm\.open\(url, onCancel: cancel\) \}/, 'the same HandsSetup.openLoginPage path, only the DM box swapped');
  // 自測：主機本機觸發／遠端觸發／完成＝標完成、還沒完成就關＝取消、逾時、打不開／只收驗過的網址／磁碟上沒有網址；真 CEF 起不來記 SKIP（不當通過）。
  const acceptance = swift('Facade/HandsUIAcceptance.swift');
  // W183 R8 整合：副設備按開關那一段照 R8c（登入走信箱、公共狀態沒有授權網址）改寫——R8b 那一版「副設備自動在 Browser 開」的標籤換成 R8c 的
  // 「遠端觸發（改走信箱）」；R8b 守的「授權分頁在按的那台的 Browser、完成標完成、還沒完成就關＝取消」搬到信箱那條路（w183build 的整合檢查，見下面）。
  for (const label of ['W183 R8b 主機本機觸發', 'W183 R5b 遠端觸發（W183 R8c 改走信箱）', 'W183 R8b 授權完成：Browser 的授權分頁標「完成」、不自己消失',
    'W183 R8b 使用者關掉完成的分頁', 'W183 R8b 還沒完成時關掉授權分頁＝取消這一輪', 'W183 R8b 逾時：流程結束時由流程關掉授權分頁', '頁面打不開',
    '只收 HandsCloudflared.loginURL 驗過的 Cloudflare 授權網址當起點', '敏感：授權網址不進瀏覽紀錄',
    'W183 R8b 分頁不會自己消失', 'W183 R8b 關框、主視窗收起來、切到對話', 'W183 R8b 鍵盤', 'W183 R8b 網址 pill', 'W183 R8b Computer Use',
    'W183 R8b 授權時不給擷取', 'W183 R5b 審查 設定浮層開著', 'W183 R5b 審查 逾時收尾之後才讀到的授權網址', 'W183 R5b 審查 副設備自動開頁',
    'W183 R5b 審查 副設備已開的授權頁', 'W183 R8b 副設備：授權完成（或在等你確認）', 'W183 R5b 審查 取消後馬上按「繼續」',
    'W183 R5b 審查 這一輪是哪台按的']) assert.ok(acceptance.includes(label), label);
  assert.match(acceptance, /check\.skip\("私訊框的真 CEF 頁面/);
  assert.match(acceptance, /check\.skip\("設定浮層開著時浮動框/);
  assert.match(acceptance, /Notification\.Name\.tatwoCloseSettingsPage, \.tatwoOpenWorkOSWindow, \.tatwoOpenSettingsSection/);
  assert.match(acceptance, /HandsSetup\.returnAfterAuthorize = \.environmentLogin\n\s*world\.setup\.login\(trigger: \.user\)/);
  // 起點：只收固定版本 cloudflared 印的那一種（callback 也驗），惡意輸入有自測。
  const cf = swift('Facade/HandsCloudflared.swift');
  assert.match(cf, /parts\.percentEncodedPath == loginPath/, 'URL.path drops a trailing slash; compare the raw path');
  assert.match(cf, /items\.count == 2, Set\(items\.map\(\\\.name\)\) == \["aud", "callback"\]/);
  assert.match(cf, /static let callbackHost = "login\.cloudflareaccess\.org"/);
  assert.match(cf, /parts\.percentEncodedPath\.range\(of: #"\^\/\[A-Za-z0-9_-\]\{43\}=\$"#/);
  assert.doesNotMatch(cf, /hasPrefix\("\/argotunnel"\)/);
  assert.match(acceptance, /W183UI SUMMARY passed=\\\(check\.passed\) failures=\\\(check\.failed\) skipped=\\\(check\.skipped\)/);
});

// W183 R6a：一個開關（docs/specs/183-chatgpt-hands/one-switch.md）——使用者 09-28「到目前為止的流程我非常不滿意 太複雜」→「先停，重做成一個開關」。
// W183 R8a：一列＋「詳細」拿掉，換成節點流程＋一次一個面板；工程細節收進面板右上「…」（chatgpt-build.md）。
test('W183 R8a one card: ChatGPT build row, node flow, one panel at a time; engineering details only behind 「…」', () => {
  const body = between(build, '    var body: some View {', '    // MARK: 那一列');
  assert.match(nativeW214(3), /W214 PASS N3.flow-default-absent.true/);
  assert.match(nativeW214(3), /W214 PASS N3.flow-visible-after-expand.true/);
  assert.match(body, /panelBox\(panel, frame, more: more\)/);
  // W183 R8a 審查（GPT-6）：模式一變，這個模式沒有的「…」面板立刻不畫；roleKey 一變就收面板、草稿、待確認的操作。
  // W183 R8 整合：每台都是自己的主機——「…」一律是這台自己的五項（沒有模式）；roleKey＝主設備（主權）＋這台，一變照舊全收。
  assert.match(body, /panelBox\(panel, frame, more: more\)/);
  assert.match(body, /\.onChange\(of: frame\.input\.roleKey\) \{ _, _ in resetForRoleChange\(\) \}/);
  assert.match(body, /let panel = HandsBuildPanel\.resolve\(chosen: chosen, attention: frame\.snapshot\.attention\)/);
  assert.match(body, /\.onChange\(of: frame\.snapshot\.attention\) \{ _, _ in chosen = nil \}/);
  assert.doesNotMatch(code(build), /DisclosureGroup|setupProgress|grantsBlock|unusedTunnelsBlock|hostHereRow/, 'no 詳細 on the main card');
  const panels = between(build, '    private func panelBox(', '    /// 出錯：一句話');
  assert.match(panels, /case \.gpt: gptPanel\(frame\)\n\s*case \.devices: devicesPanel\(frame\)\n\s*case \.cloudflare: cloudflarePanel\(frame\)\n\s*case \.dev: devPanel\(frame\)/);
  assert.match(panels, /if let more \{\n\s*ChatGPTBuildDetails\(kind: more\)/);
  const menu = between(build, '    private var moreMenu: some View {', '    // MARK: GPT');
  assert.match(menu, /ForEach\(HandsBuildMore\.items, id: \\\.self\) \{ item in\n\s*Button\(item\.title\) \{ more = item; model\.clearNotice\(\) \}/);
  assert.match(buildModel, /enum HandsBuildMore: String, Sendable, Equatable, CaseIterable \{\n\s*case steps, account, grants, tunnels, diagnostics\n/);
  assert.match(buildModel, /static let items: \[HandsBuildMore\] = allCases/);
  assert.match(menu, /ChatGPTBuildDetails\.openActivity\(\)/);
  assert.match(menu, /EnvironmentLoginTab\.open\(\.cloudflare\)/);
  assert.match(menu, /\.menuStyle\(\.button\)\n\s*\.buttonStyle\(\.plain\)/);
  const details = between(section, 'struct ChatGPTBuildDetails: View {', '    // MARK: 開關與取消勾選的確認列');
  for (const piece of ['setupProgress', 'accountBlock', 'urlRow', 'grantsBlock', 'pairingWindowRow', 'otherDevicesBlock', 'unusedTunnelsBlock', 'diagnostics']) assert.ok(details.includes(piece), piece);
  // W183 R8 整合：副設備看主機的兩塊（ChatGPTHandsRemoteView／ChatGPTHandsRemoteGrants）拿掉；別台的連線在「其他設備」撤銷（經信箱）。
  assert.match(details, /case \.grants:\n\s*grantsBlock\n\s*pairingWindowRow\n\s*otherDevicesBlock/);
  assert.doesNotMatch(code(section), /ChatGPTHandsRemoteView|ChatGPTHandsRemoteGrants/);
  for (const source of [section, build]) assert.doesNotMatch(code(source), /cloudflareGuide|先登入 Cloudflare|"開始配對"|在主機開始配對/);
  // 以前 R6a 的整塊畫面拿掉（靜態判斷搬到 HandsBuildModel，自測照用）。
  assert.doesNotMatch(section, /struct ChatGPTHandsSection: View/);
  // W183 R8 整合：R6a 的畫面模式與同步鍵（mode、syncKey）拿掉（多設備沒有「主機是別台」）；「交回主設備」的判斷搬到 HandsOneSwitch（舊的狀態字與自測還在用）。
  for (const name of ['static func mode(local:', 'static func syncKey(isSecondary:']) assert.ok(!buildModel.includes(name), name);
  assert.ok(oneSwitch.includes('static func handback(problem:'), 'handback moved to HandsOneSwitch');
  // 狀態只有規格那幾種字；出錯＝一句話＋一顆鈕（重試／重新授權／再連一次／交回主設備）。
  for (const words of ['"已關閉"', '"準備中…"', '"等你在私訊框按一下"', '"連線中…"', '"已連線・L', '"出錯：" + message']) assert.ok(oneSwitch.includes(words), words);
  assert.match(oneSwitch, /case \.retry: "重試"\n\s*case \.reauthorize: "重新授權"\n\s*case \.reconnect: "再連一次"\n\s*case \.handBack: "交回主設備"/);
  assert.doesNotMatch(code(oneSwitch), /第 \\\(|設定中/);
  assert.match(build, /OSChipButton\(title: fix\.title, systemImage: "arrow\.clockwise", isPrimary: true\) \{ model\.fix\(\) \}/);
  // 連線那一段看 HandsConnectFlow（R6b）；接口檔不改。
  assert.match(section, /@ObservedObject private var connect = HandsConnectFlow\.shared/);
  assert.match(oneSwitch, /case \.creatingConnector, \.verifying: return \.connecting/);
  // 合併後（主導）：HandsConnect.swift 由 R6b 實作；R6a 只靠接口名字（offer／cancel(reason:)／phase／problem）。
  const connectIface = swift('Facade/HandsConnect.swift');
  for (const name of [/func offer\(\)/, /func cancel\(reason: String\)/, /var phase: HandsConnectionPhase/, /var problem: String\?/]) assert.match(connectIface, name);
});

test('W183 R6a flow: switch → authorize in the DM box; pairing step → offer() (no pairing window); off / host change / cancel → cancel(reason:)', () => {
  const pairing = between(setup, 'private func stepPairing(trigger: HandsSetupTrigger)', '// MARK: - W183 R6a：固定子網域');
  assert.match(pairing, /let outcome = waitUser\(\.pairing, Self\.pairingWaitingMessage\)\n\s*if trigger == \.user \|\| trigger == \.assistant \{ dependencies\.offerConnect\(\) \}/);
  assert.doesNotMatch(code(pairing), /openWindow|startPairing/);
  assert.match(setup, /case \.pairing: return stepPairing\(trigger: trigger\)/);
  assert.match(setup, /deps\.offerConnect = \{ DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ HandsConnectFlow\.shared\.offer\(\) \} \} \}/);
  assert.match(setup, /deps\.cancelConnect = \{ reason in DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ HandsConnectFlow\.shared\.cancel\(reason: reason\) \} \} \}/);
  // 隔離環境（自測、staging）：預設什麼都不做（不叫 R6b、不上網）。
  const deps = between(setup, 'struct Dependencies {', 'static func live(');
  assert.match(deps, /var offerConnect: \(\) -> Void = \{\}/);
  assert.match(deps, /var cancelConnect: \(String\) -> Void = \{ _ in \}/);
  assert.match(deps, /done\(\.failure\("unavailable"\)\)/);
  assert.match(between(setup, 'func turnedOff()', 'private func releaseAfterOff()'), /cancel\(\)\n\s*dependencies\.cancelConnect\("switched_off"\)/);
  // W183 R6a 審查：換主機＝使用者按「確定」（confirmHostChange）才換；換了＝這次連線作廢。
  // W183 R8c：換成別台＝不換（每台自己跑自己的），這次連線不作廢；換回這台才作廢。
  assert.match(between(setup, 'func confirmHostChange(token: String)', 'func dismissHostChange()'), /if started, HandsHostAuthority\.same\(request\.to, dependencies\.localDeviceID\(\)\) \{ dependencies\.cancelConnect\("host_changed"\) \}/);
  // W183 R8a 審查：「…」裡的取消經 adapter（HandsBuildModel.detail）：取消＝這次連線一起作廢（主機與副設備）。
  assert.match(section, /OSChipButton\(title: "取消"\) \{ _ = build\.detail\(\.cancelSetup, shown: shown\) \}/);
  // W183 R8 整合：副設備取消主機設定的那一顆拿掉（每台自己當主機、取消自己的）；別台的登入在它的授權分頁關掉＝取消（信箱 login_cancel）。
  const detail = between(buildModel, 'func detail(_ action: HandsBuildDetail', 'func deleteUnusedTunnels(');
  assert.match(detail, /case \.cancelSetup:\n\s*setup\.cancel\(\)\n\s*connectFlow\.cancel\(reason: "cancelled"\)/);
  assert.doesNotMatch(detail, /remoteCancel|remote\.act/);
  assert.match(swift('Facade/HandsBuildController.swift'), /_ = try\? sync\.submit\(action: "login_cancel", target: entry\.device, payload: \["operation_id": operation\]\) \{ _ in \}/);
  // 副設備按的「是這個，繼續」＝.remote（主機不在自己的畫面出［連線］卡；按的那台 offer）。
  assert.match(remote, /flow\.confirmAuthorization\(token: token, domain: domain, trigger: \.remote, requester: sender\)/);
  // 那一列：走到「等［連線］」、這一段還沒開始＝自動叫一次；關了卡片給「再連一次」。
  // W183 R8a：畫面不再自己叫［連線］卡（先在 ChatGPT Dev 面板選等級與專案，再按［連線］）；按了＝私訊框的［連線］卡。
  assert.doesNotMatch(code(build), /autoOffered|shouldOffer/);
  // W183 R8 整合：［連線］經 R8c 的控制器——連指定的那台（多台＝逐台排；同一個 Pod 一次一個連接器）＝HandsConnectFlow.offer(target:preset:)（私訊框的原生卡）。
  assert.match(between(buildModel, 'case .connect(let device):\n            guard', 'case .unlock('), /return \[\.connect\(device\?\.lowercased\(\)\)\]/);
  assert.match(buildModel, /case \.connect\(let device\):\n\s*build\.connect\(deviceID: device\)/);
  // W183 R10（使用者 09-29「這邊要勾選也太怪」）：［連線］不再帶面板上的範圍（範圍＝中央等級＋那台全部專案）；照舊是私訊框的原生卡。
  assert.match(swift('Facade/HandsBuildController.swift'), /dependencies\.flow\.offer\(target: target, preset: nil\)/);
  // 助理規則與 docs：沒有「開始配對」、配對＝私訊框按［連線］。
  assert.match(between(setup, 'enum HandsSetupTool', undefined), /請使用者按［連線］/);
  assert.doesNotMatch(between(setup, 'enum HandsSetupTool', undefined), /按「開始配對」/);
  assert.match(read('docs/os-mcp-tools.md'), /私訊框跳出［連線］卡/);
});

test('W183 R6a auto-resume after the host App restarts: only tunnel, gateway and existing grants; never login, offer, pairing window or retry; safety stop survives', () => {
  const resume = between(setup, 'func resumeIfEnabled() -> Bool {', 'func reauthorize(trigger:');
  assert.match(resume, /guard settings\.enabled, let local = dependencies\.localDeviceID\(\), HandsHostAuthority\.same\(settings\.hostDeviceID, local\) else \{ return false \}/);
  assert.match(resume, /enqueue\(HandsSetupStep\.runOrder, trigger: \.resume, allowLogin: false, force: false, hostOverride: nil\)/);
  assert.match(setup, /enum HandsSetupTrigger: String, Sendable \{ case user, assistant, remote, resume \}/);
  assert.match(setup, /if trigger == \.resume \{ return waitUser\(\.authorize, Self\.resumeNeedsLoginMessage\) \}/);
  // 自動續跑只叫關口照設定判斷；助理叫的是保留安全鎖的重試（W183 R6a 審查 Claude：一般失敗救得回來）；使用者、遠端按的才是「重試」。
  assert.match(setup, /switch trigger \{\n\s*case \.resume: dependencies\.resumeService\(\)\n\s*case \.assistant: dependencies\.retryService\(\)\n\s*case \.user, \.remote: dependencies\.startService\(\)\n\s*\}/, 'neither auto-resume nor the AI lifts the manual retry lock');
  assert.match(setup, /deps\.resumeService = \{ ChatGPTHandsService\.shared\.settingsDidChange\(\) \}/);
  assert.match(setup, /deps\.retryService = \{ ChatGPTHandsService\.shared\.retryKeepingSafetyLock\(\) \}/);
  assert.doesNotMatch(between(service, 'func retryKeepingSafetyLock() {', 'func stop() {'), /clearSafetyStop|safetyLatched = false/);
  assert.match(setup, /message: Self\.interruptedMessage, updatedAt: value\.updatedAt/);
  assert.match(swift('Shell/AppShell.swift'), /ChatGPTHandsService\.shared\.startIfEnabled\(\) \}\n[^\n]*\n\s*DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 5\) \{ HandsSetup\.shared\.resumeIfEnabled\(\) \}/);
  // 安全停機（socket 被動過）：鎖寫進 app/（關口讀寫不到），重開 App、自動續跑（settingsDidChange）都不解除；只有「重試」解除。
  // W183 R6a 審查（GPT-6）：先鎖（改名預寫的那份 → 寫新的 → 預寫的改唯讀 → 行程記著）再停；讀不到＝當成鎖著；起關口前先預寫（寫不進去不起）。
  assert.match(service, /if tampered \{ safetyStop\(\) \}\n\s*terminateBoth\(disarm: !tampered\)/);
  assert.match(service, /if Darwin\.rename\(safetyArmedURL\(paths\)\.path, safetyStopURL\(paths\)\.path\) == 0 \{ return true \}/);
  assert.match(service, /return chmod\(safetyArmedURL\(paths\)\.path, 0o400\) == 0/);
  assert.match(service, /guard errno == ENOENT else \{ return \.unreadable \}/);
  assert.match(service, /let state: SafetyState = safetyLatched \? \.locked : Self\.safetyState\(paths\)/);
  const start = between(service, 'private func start(_ prepared: Prepared) {', 'private func gatewayOutput(');
  assert.ok(start.indexOf('guard Self.armSafety(paths) else') > 0 && start.indexOf('guard Self.armSafety(paths) else') < start.indexOf('HandsGatewayLaunch.spawnGateway('), 'arm before spawning');
  // 副設備當主機要主設備確認過的租約（重開後雙主機）。
  assert.match(service, /guard dependencies\.hostConfirmed\(local\) else \{/);
  assert.match(between(service, 'func retry() {', 'func stop() {'), /Self\.clearSafetyStop\(paths\)/);
  // W183 R8c 審查（GPT-6 高）：另一個呼叫是綁事故編號的 unlockSafety(incident:)（核對跟現在鎖著的是同一次才清）。
  assert.equal((code(service).match(/clearSafetyStop\(/g) ?? []).length, 3, 'defined once, called only from retry and the incident-bound unlock');
  assert.match(between(service, 'func unlockSafety(incident: String) -> Bool {', 'func currentSafetyIncident()'),
    /guard let current, HandsAuth\.constantTimeEqual\(current, incident\) else \{ return false \}\n\s*Self\.clearSafetyStop\(paths\)/);
  assert.match(service, /static func safetyStopURL\(_ paths: HandsGatewayLaunch\.Paths\) -> URL \{ safetyDir\(paths\)\.appendingPathComponent\("safety-stop\.json"\) \}/);
  assert.match(service, /URL\(fileURLWithPath: HandsGatewayLaunch\.realPath\(paths\.appDir\.path\) \?\? paths\.appDir\.path, isDirectory: true\)/, 'app/ (realpath; the gateway cannot write it)');
});

test('W183 R6a fixed subdomain os-for-chatgpt: taken name stops (no overwrite, no rename); random→fixed migration deletes only the recorded TATWO CNAME', () => {
  const settingsSource = swift('Facade/HandsSettings.swift');
  assert.match(settingsSource, /static let defaultSubdomainLabel = "os-for-chatgpt"/);
  assert.match(settingsSource, /case subdomainLabel = "subdomain_label"/);
  const dns = between(setup, '// 2. W183 R6a', '// 3. 通道 token');
  assert.match(dns, /if HandsCloudflared\.errorCategory\(result\.lines\)\.contains\("exists"\) \{\n\s*return abandon\(fail\(\.tunnel, domain == nil \? Self\.fixedHostTakenMessage/);
  // W183 R6a 審查（Claude）：撞到另一台的 TATWO 通道就照實說（不覆蓋、不換名字）；自動續跑不遷移；遷移時已經連上的連線作廢。
  assert.match(setup, /return Self\.fixedHostOtherDeviceMessage\(host\)/);
  // W183 R8c 審查（GPT-6／Claude 高）：自動續跑與助理一律照用已經套用的網址（不只以前的隨機網址）：不遷移、不 route dns。
  assert.match(dns, /if !isFixedHost\(snapshot\.publicHost, state: snapshot\), !keepsCurrentHost\(snapshot, trigger: trigger\) \{/);
  assert.match(setup, /guard state\.publicHost != nil, state\.tunnelID != nil else \{ return false \}\n\s*return trigger == \.resume \|\| trigger == \.assistant/);
  assert.match(dns, /if dependencies\.revokeGrants\("url_migrated"\) != nil/);
  assert.doesNotMatch(code(dns), /for attempt in|random\(|overwrite/, 'never retries with another name, never overwrites');
  // 遷移：先記下（寫進磁碟）→ 加新紀錄 → API 確認是指向這條通道的 CNAME → 才換網址。
  const order = ['try mutateDurably { $0.retiredHost = retiring }', 'base + ["route", "dns", tunnelID, requested]',
    'switch checkRecord(zoneID: zoneID, host: host, tunnelID: tunnelID)', 'mutate { $0.publicHost = host }'].map(n => dns.indexOf(n));
  assert.ok(order.every(i => i >= 0) && order.every((v, i) => i === 0 || order[i - 1] < v), `record, add, confirm, then switch ${order}`);
  assert.match(dns, /case \.notOurs, \.unknown: return abandon\(fail\(\.tunnel, Self\.fixedHostUnconfirmedMessage\)\)/);
  // 刪舊的：關口用新網址起來之後（第 6 步）、只刪記下的那個名稱、TATWO 的隨機格式、只有一筆、CNAME、指向記下的那條通道。
  assert.match(setup, /retireOldHost\(runningURL: url\)/);
  const retire = between(setup, 'private func retireOldHost(runningURL: String)', 'private func recordCategory(');
  assert.match(retire, /HandsHostAuthority\.same\(URL\(string: runningURL\)\?\.host, current\)/);
  assert.match(retire, /Self\.isTatwoRandomHost\(retired\.host, domain: domain\)/);
  assert.match(retire, /guard records\.count == 1, let record = records\.first, record\.type == "CNAME", record\.name == retired\.host\.lowercased\(\),\s*record\.content == HandsCloudflared\.tunnelTarget\(retired\.tunnelID\) else \{/);
  // W183 R6a 審查（GPT-6）：setup.json 只當提示——現在這條通道、Cloudflare 上是 TATWO 建的、新網址從外面確認、刪之前再查一次，照順序。
  const checks = ['guard state.tunnelID?.lowercased() == tunnel, state.tokenTunnelID?.lowercased() == tunnel', 'switch tunnelOwnership(tunnel)',
    'if let problem = probe(current)', 'let (lookup, stopped) = lookupRecord(zoneID: retired.zoneID, host: retired.host)',
    'let (again, stoppedAgain) = lookupRecord(zoneID: retired.zoneID, host: retired.host)', 'dependencies.deleteDNSRecord('].map(n => retire.indexOf(n));
  assert.ok(checks.every(i => i >= 0) && checks.every((v, i) => i === 0 || checks[i - 1] < v), `verify in order before deleting ${checks}`);
  assert.match(retire, /guard !stoppedAgain, !cancelled, sameGeneration, case \.records\(let latest\)\? = again, latest == \[record\] else \{/);
  assert.match(setup, /return tunnel\.active && tunnel\.name\.hasPrefix\(HandsCloudflared\.tatwoTunnelPrefix\) \? \.tatwo : \.notTatwo/);
  assert.match(setup, /&& records\[0\]\.content == HandsCloudflared\.tunnelTarget\(tunnelID\) && records\[0\]\.proxied/);
  assert.match(cloudflared, /if http\.statusCode == 403, type\.hasPrefix\("text\/plain"\), String\(data: body, encoding: \.utf8\) == "forbidden" \{ return nil \}/);
  assert.match(setup, /label\.range\(of: #"\^h\[a-z0-9\]\{19\}\$"#/);
  assert.match(setup, /case \.running\(let url\) where HandsHostAuthority\.same\(URL\(string: url\)\?\.host, host\):/);
  // Cloudflare API：照 lookupZone（ephemeral、不跟隨轉址、不帶 cookie、token 只在標頭）；錯誤只回分類。
  const api = between(cloudflared, '// MARK: - W183 R6a：DNS 紀錄', 'private final class NoRedirect');
  assert.match(api, /URLSession\(configuration: configuration, delegate: NoRedirect\(\), delegateQueue: nil\)/);
  assert.match(api, /URLSessionConfiguration\.ephemeral/);
  assert.match(api, /request\.httpShouldHandleCookies = false/);
  assert.match(api, /api\.cloudflare\.com\/client\/v4\/zones\/\\\(zoneID\)\/dns_records\/\\\(recordID\)/);
  assert.doesNotMatch(code(api), /print\(|NSLog|Logger\(|\.write\(to:/);
  assert.match(setup, /let safe = String\(category\.filter \{ \$0\.isASCII && \(\$0\.isLetter \|\| \$0\.isNumber \|\| \$0 == "_" \|\| \$0 == "\+"\) \}\.prefix\(40\)\)/);
});

test('W183 R6a secondary: resync when the host setting changes, force a fetch while there is no status, ≤10 s backoff while the page is visible, hand back', () => {
  // W183 R8 整合：ChatGPT build 接到 R8c 的多設備後端——畫面開著＝後端一陣子內同步快一點（HandsBuildSync.heatUp：有事 1.5 秒），
  // 不再是「副設備問主機的單主機狀態」（沒有模式、沒有同步鍵）。還沒拿到設定＝「準備中…」、按鈕不送（w183ui 自測）。
  const watchTask = between(build, '         .task {', '        // 要你處理的節點換了');
  assert.match(watchTask, /#if DEBUG\s+if testFrame != nil \{ return \}\s+#endif\s+await model\.watch\(\)/);
  assert.match(between(buildModel, '    func appear() {', '    /// Pod 目前帳號'), /build\.viewDidAppear\(\)[\s\S]*if tick % 20 == 0 \{ build\.viewDidAppear\(\) \}/);
  assert.match(swift('Facade/HandsBuildController.swift'), /func viewDidAppear\(\) \{\n\s*dependencies\.sync\.heatUp\(\)\n\s*dependencies\.sync\.syncSoon\(\)/);
  assert.doesNotMatch(buildModel, /syncWithHost|var syncKey/);
  for (const source of [section, build, buildModel]) assert.doesNotMatch(code(source), /watchingRemote|讀取主機狀態/);
  // W183 R6a 審查（GPT-6）：從「這一次開始問」起算最多 visibleMaxGap（10 秒），到期自己排一次，不等下一輪定時器。
  assert.match(remote, /var visibleMaxGap: TimeInterval = 10/);
  assert.match(remote, /self\.nextAllowed = started\.addingTimeInterval\(min\(delay, self\.visibleMaxGap\)\)/);
  assert.match(remote, /if let retryIn \{ DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ retryIn\) \{ \[weak self\] in self\?\.retryWhileVisible\(\) \} \}/);
  // 副設備按的開關：主機走到「等你按［連線］」＝這台的私訊框出［連線］卡（按的那台）。
  assert.match(remote, /static let offerOps: Set<String> = \["start_setup", "continue_setup", "confirm_authorization", "reauthorize"\]/);
  assert.match(remote, /if offer \{ MainActor\.assumeIsolated \{ self\.armOffer\(\) \} \}/);
  assert.match(remote, /self\.offerIfReady\(result\)/);
  // 交回主設備：關開關＝交回；不成功那一列給鈕（開關開沒開都可以）；重開後還登記是主機也給。
  assert.match(setup, /@Published private\(set\) var handbackProblem: String\?/);
  assert.match(between(setup, 'func handBack()', '/// TAP 選帳號與網域'), /dependencies\.cancelConnect\("host_changed"\)\n\s*work\.async \{ \[weak self\] in self\?\.releaseAfterOff\(\) \}/);
  // W183 R6a 審查（Claude）：只有交回真的沒成功（第 1 步記著失敗）才給「交回主設備」——剛認領、開關關著＝已關閉。
  // W183 R8 整合：這個判斷搬到 HandsOneSwitch（舊的狀態字與自測照用）；ChatGPT build 的卡片沒有「交回」（R8c：claim／release 退役，每台關掉＝取消勾那台）。
  assert.match(oneSwitch, /guard isSecondary, let local, HandsHostAuthority\.same\(settings\.hostDeviceID, local\), !settings\.enabled, !busy,\n\s*hostStep\.status == \.failed else \{ return nil \}/);
  // W183 R6a 審查（GPT-6）：交回之前「關」要存進磁碟、關口要停；副設備重開後先問主設備（租約）；交接請求帶期限、冪等 id、原主機／任期。
  assert.match(setup, /if dependencies\.hostNeedsRelease\(\), let problem = stopBeforeRelease\(\) \?\? dependencies\.releaseHost\(\) \{/);
  assert.match(between(setup, 'private func stopBeforeRelease() -> String? {', 'func handBack()'), /if notSaved \|\| !dependencies\.offPersisted\(\) \|\| dependencies\.loadSettings\(\)\.enabled \{ return Self\.handbackNotSavedMessage \}/);
  // W183 R8c：主機那一步只看這台的啟用許可（取代單主機租約）：暫停＝不起、沒勾＝不起；不認領、不交出。
  assert.match(setup, /case \.paused:\n\s*return fail\(\.host, Self\.leaseUnreachableMessage\)\n\s*case \.inactive, \.none:\n\s*return fail\(\.host, Self\.notSelectedMessage\)/);
  assert.match(remote, /guard same\(current, sender\) \|\| current\.lowercased\(\) == expected\.lowercased\(\) else \{ refusal\.set\(staleHostReason\); return \}/);
  assert.match(remote, /guard tenure == \(settings\.hostEpoch \?\? 0\) else \{ refusal\.set\(staleHostReason\); return \}/);
  assert.match(remote, /static let hostFields: Set<String> = \["expires_at", "expected_host", "host_epoch", "request_id"\]/);
  // 換主機：W183 R8 整合（R8c 必改 1）——畫面沒有「改用這台當主機」與換主機確認列了（每台被勾的設備自己當主機；設備面板多選，
  // 取消勾有連線的那台先在卡片內確認）。後端的一次性請求照舊（下面）：AI 工具只能提出、不能確認；畫面不確認＝請求到期作廢（fail closed）。
  assert.doesNotMatch(code(buildModel) + code(build) + code(section), /handBack|hostHere|confirmHostChange|hostChangeRow/);
  assert.match(build, /if let id = confirmingDeselect, let device = frame\.snapshot\.devices\.first\(where: \{ \$0\.id == id \}\) \{ deselectRow\(device\) \}/);
  const confirmHost = between(setup, 'func confirmHostChange(token: String)', 'func dismissHostChange()');
  assert.match(confirmHost, /guard Date\(\) < request\.expiresAt, request\.epoch == epochNow, configured\.lowercased\(\) == \(request\.from \?\? ""\)\.lowercased\(\) else \{ return false \}/);
  assert.match(setup, /if let requested, !requested\.isEmpty, requested\.caseInsensitiveCompare\(local\) != \.orderedSame \{\n\s*return fail\(\.host, Self\.otherDeviceRunsItselfMessage\)/);
  assert.match(between(setup, 'enum HandsSetupTool', undefined), /case \.needsConfirmation:\n\s*throw Failure\.needsUser/);
});

test('W183 R6a unused TATWO tunnels: only tatwo-hands-, no connections, not in use; confirm first; recheck before delete; same sandbox; category-only errors', () => {
  const parse = between(cloudflared, 'static func unusedTatwoTunnels(', 'struct UnusedTunnel:');
  assert.match(parse, /guard active, name\.hasPrefix\(tatwoTunnelPrefix\), name\.count <= 64, connections\.isEmpty,\s*!excluded\.contains\(id\), !excludingNames\.contains\(name\) else \{ continue \}/);
  assert.match(cloudflared, /static let tatwoTunnelPrefix = "tatwo-hands-"/);
  const del = between(setup, 'func deleteUnusedTunnels(', 'private func maintenance(');
  // W183 R6a 審查（GPT-6）：每一條刪之前都再查一次，而且本機的世代、帳號、網域沒換。
  assert.match(del, /for id in wanted\.sorted\(\) \{[\s\S]*?guard !self\.cancelled, sameGeneration, self\.snapshot\.zoneID == zone, self\.snapshot\.accountID == account else \{ failed \+= 1; continue \}\n\s*guard let fresh = self\.listUnused\(base: base, home: home\)\.tunnels else \{ failed \+= 1; continue \}\n\s*guard let tunnel = fresh\.first\(where: \{ \$0\.id == id \}\) else \{ continue \}/);
  assert.match(del, /self\.recordError\("tunnel\.delete", result\)/);
  // W183 R8c（GPT-6 必改 6）：只列自己有建立證據的；主設備所有權表記的別台通道不列（離線照樣）；所有權表或 DNS 查不到＝整份不列（禁止刪）。
  assert.match(setup, /guard let foreign = dependencies\.foreignTunnels\(\) else \{ recordCategory\("tunnel\.list", "ownership_unknown"\); return \(nil, false\) \}/);
  assert.match(setup, /guard let targets else \{ recordCategory\("tunnel\.list", "dns_unknown"\); return \(nil, false\) \}/);
  assert.match(setup, /return \(found\.filter \{ evidence\.contains\(\$0\.id\.lowercased\(\)\) && !foreign\.contains\(\$0\.id\.lowercased\(\)\) && !targets\.contains\(\$0\.id\) \}, false\)/);
  assert.match(section, /if setup\.unusedTunnelsUnverified \{/);
  assert.match(setup, /let ids = Set\(\[state\.tunnelID, state\.tokenTunnelID\]\.compactMap \{ \$0 \} \+ dependencies\.accounts\.snapshot\.compactMap\(\\\.tunnelID\)\)/);
  assert.match(between(setup, 'private func withAccount', 'func checkUnusedTunnels'), /defer \{ unlink\(certFile\.path\) \}/);
  const block = between(section, '@ViewBuilder private var unusedTunnelsBlock: some View {', '// MARK: 診斷');
  assert.match(block, /if let tunnels = setup\.unusedTunnels, !tunnels\.isEmpty \{/);
  assert.match(block, /ChatGPTHandsConfirmRow\(question: "清掉勾的 \\\(tunnelSelection\.count\) 條通道？"/);
  assert.match(block, /OSChipButton\(title: "清掉", systemImage: "trash", role: \.destructive\) \{ confirmingTunnelDelete = true \}/);
  // 維護不算設定流程的忙碌（那一行狀態不跳「準備中」），但跟流程不搶 cloudflared。
  assert.match(between(setup, 'private func maintenance(', '// MARK: - 小工具'), /guard !jobActive, !maintaining else \{ lock\.unlock\(\); return false \}/);
});

test('W183 R6a self-test covers the one-switch rules and never touches the real keychain or network', () => {
  const acceptance = swift('Facade/HandsOneSwitchAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.doesNotMatch(acceptance, /CloudflareKeychain\(\)|CloudflareAccountsStore\.shared|HandsSetup\.shared|URLSession|HandsConnectFlow\.shared/);
  const run = between(swift('Facade/HandsUIAcceptance.swift'), '@MainActor static func run()', '// MARK: - 設定分頁');
  for (const fn of ['oneSwitchFlowChecks', 'safetyLockChecks', 'fixedSubdomainChecks', 'handbackChecks', 'remoteSyncChecks', 'unusedTunnelChecks', 'resumeBoundaryChecks']) {
    assert.ok(run.includes(fn + '('), fn);
  }
  for (const label of ['W183 R6a 主設備開關＝runAll(allowLogin: true)', 'W183 R6a 走到配對：叫 HandsConnectFlow.offer', 'W183 R6a 重開續跑',
    'W183 R6a 安全停機', 'W183 R6a 關開關：叫 HandsConnectFlow.cancel', 'W183 R6a 換主機要確認', 'W183 R6a 隨機→固定', 'W183 R6a 固定子網域撞名',
    // W183 R8 整合：「主機設定或畫面模式一變就重新同步」那一條拿掉（多設備沒有畫面模式與同步鍵；畫面開著＝後端熱問，改設定一律 CAS）。
    'W183 R6a 關開關＝交回主設備', 'W183 R6a 設定頁看得到時連不上最多 10 秒', 'W183 R6a 清掉：刪之前再查一次',
    'W183 R6a 狀態字', 'W183 R8a 舊的一列＋「詳細」拿掉',
    // W183 R6a 審查（十七條）：每一條都有自測。
    'W183 R6a 審查 安全停機先鎖再停', 'W183 R6a 審查 鎖寫不進去', 'W183 R6a 審查 讀標記出錯', 'W183 R6a 審查 副設備沒有主設備確認過的租約',
    'W183 R6a 審查 交回之前「關」要存進磁碟', 'W183 R8c 每台許可', 'W183 R8c 每台啟用許可', 'W183 R6a 審查 交接請求',
    'W183 R6a 審查 交回：不是這一任的', 'W183 R6a 審查 換主機的請求綁原主機', 'W183 R6a 審查 setup.json 被改', 'W183 R6a 審查 刪之前再查一次',
    'W183 R6a 審查 刪舊紀錄之前從外面確認新網址', 'W183 R6a 審查 新紀錄要是經過 Cloudflare 代理的', 'W183 R6a 審查 自動續跑（與已連上時助理叫的）不遷移',
    'W183 R6a 審查 已經連上時遷移', 'W183 R6a 審查 自動續跑只接受原本確認過的帳號與網域', 'W183 R8c 使用者按的也一樣',
    'W183 R6a 審查 設定頁看得到時', 'W183 R6a 審查 沒用到的通道', 'W183 R6a 審查 換主機撞到固定的名字', 'W183 R6a 審查 「交回主設備」只在交回真的沒成功時出現',
    'W183 R6a 審查 助理的重試']) {
    assert.ok((acceptance + swift('Facade/HandsUIAcceptance.swift')).includes(label), label);
  }
});

// ---------- W183 R7a：步驟訊息與畫面一致、舊 DNS 紀錄的重試、外部確認的第二條路 ----------

test('W183 R7a step messages: no internal room codes; button names in messages match the screen (authorize = 重新授權, others = 重試); the one line has no step numbers', () => {
  // 使用者看得到的字不露內部代號（W183 R6a 之類）。
  const visible = [setup, oneSwitch, section, swift('Facade/HandsConnect.swift'), swift('New/HandsConnectDMView.swift'), remote]
    .map(source => [...code(source).matchAll(/"((?:[^"\\\n]|\\.)*)"/g)].map(m => m[1]).join('\n')).join('\n');
  assert.doesNotMatch(visible, /W1\d\d|R[0-9][a-c]?）/);
  assert.match(setup, /static func urlMessage\(_ url: String\) -> String \{\n\s*"\\\(url\)——ChatGPT 的連接器由 App 在 ChatGPT Space 自動建：使用者在私訊框按［連線］就好"/);
  // 授權那一步出錯時那一列的鈕是「重新授權」：那一步的訊息也寫「重新授權」；步驟清單的鈕照步驟叫（不再有「重跑這一步」）。
  assert.doesNotMatch(code(setup), /fail\(\.authorize, [^\n]*「重試」/);
  assert.match(setup, /step == HandsSetupStep\.authorize\.rawValue \? "已取消；按「重新授權」再做" : "已取消；按「重試」再做"/);
  assert.match(oneSwitch, /return \.failed\(short\(message\), step == \.authorize \? \.reauthorize : \.retry\)/);
  assert.match(section, /\(step == \.authorize \? HandsOneSwitchStatus\.Action\.reauthorize : \.retry\)\.title/);
  assert.match(section, /OSChipButton\(title: rerunTitle, action: rerun\)/);
  assert.doesNotMatch(section, /重跑這一步/);
  assert.match(setup, /按「登入 Cloudflare」（或到「設定 › 環境登入 › Cloudflare」）/);
  assert.match(cfCard, /OSChipButton\(title: "用瀏覽器登入 Cloudflare"/);
  assert.doesNotMatch(setup, /第 2 步的「重試」|先確認第 3 步/);
  // 那一行（出錯：一句話）不寫「第 N 步」；步驟清單照 allCases 編號（副設備照主機給的順序）。
  assert.match(oneSwitch, /replacingOccurrences\(of: #"第\\s\*\[0-9\]\+\\s\*步（\(\[\^）\]\*\)）"#, with: "「\$1」"/);
  assert.match(setup, /var number: Int \{ \(Self\.allCases\.firstIndex\(of: self\) \?\? 0\) \+ 1 \}/);
  assert.match(remote, /result\["setup"\] = HandsSetupStep\.allCases\.map/);
});

test('W183 R7a old DNS record: kept when the new URL cannot be confirmed, then retried automatically (no press); confirmation has a second path that avoids the system DNS cache', () => {
  // 第 6 步之後排重試；重試走維護（不算設定流程的忙碌）、照同一套核對；關了、不是主機就不試。
  assert.match(setup, /retireOldHost\(runningURL: url\)   \/\/ W183 R6a[^\n]*\n\s*scheduleRetireRetry\(\)/);
  const retry = between(setup, 'private func scheduleRetireRetry(', 'private enum TunnelOwnership');
  assert.match(retry, /guard current\.retiredHost != nil else \{ retireRetries = 0; lock\.unlock\(\); return \}/);
  assert.match(retry, /let delay = delays\[min\(retireRetries, delays\.count - 1\)\]/);
  assert.match(retry, /guard settings\.enabled, let local = dependencies\.localDeviceID\(\),/);
  assert.match(retry, /let started = maintenance\(publishes: false\) \{/);
  assert.match(retry, /if case \.running\(let url\) = self\.dependencies\.servicePhase\(\) \{ self\.retireOldHost\(runningURL: url\) \}/);
  assert.match(setup, /var retireRetryDelays: \[TimeInterval\] = \[60, 180, 600, 1800, 3600\]/);
  // 不放寬：確認不了照樣不刪（retireOldHost 的核對順序不動，見上面 R6a 那條）。
  assert.match(between(setup, 'private func retireOldHost(runningURL: String)', 'private func scheduleRetireRetry('), /if let problem = probe\(current\) \{ recordCategory\("dns\.probe", problem\); return \}/);
  // 第二條路：系統那條回 network 才走；公開 DNS 用 IP 連（不經系統解析）、只收公開位址；直連時 SNI 與憑證都用這個名字；判斷同一個 gatewayVerdict。
  assert.match(cloudflared, /guard verdict == "network" else \{ return completion\(verdict\) \}\n\s*probeViaPublicDNS\(host: name\) \{ second in completion\(second\.map \{ "network\+" \+ \$0 \}\) \}/);
  const publicProbe = swift('Facade/HandsPublicProbe.swift');
  assert.match(publicProbe, /static let publicResolvers = \["1\.1\.1\.1", "1\.0\.0\.1"\]/);
  assert.match(publicProbe, /URLComponents\(string: "https:\/\/\\\(resolver\)\/dns-query"\)/);
  assert.match(publicProbe, /sec_protocol_options_set_tls_server_name\(security, name\)/);
  assert.match(publicProbe, /SecTrustSetPolicies\(secTrust, SecPolicyCreateSSL\(true, name as CFString\)\)\n\s*verified\(SecTrustEvaluateWithError\(secTrust, nil\)\)/);
  assert.match(publicProbe, /guard isPublicAddress\(address\), let name = HandsGatewayLaunch\.validHost\(host\), let bytes = addressBytes\(address\) else \{\s*return completion\("doh_private"\)\s*\}/);
  assert.match(publicProbe, /case \.complete\(let parsed\): return \.some\(gatewayVerdict\(parsed\.response\(host: host\), data: parsed\.body, host: host\)\)/);
  // W183 R7a 審查（GPT-6）：「備援連得到」跟「可以刪」分開——每個解析器都乾淨、答案一致才直連；A 失敗不改問 AAAA。
  assert.match(publicProbe, /if !failures\.isEmpty \{\s*if sets\.isEmpty \{ return \(nil, Set\(failures\)\.count == 1 \? failures\[0\] : "failed"\) \}\s*return \(nil, "partial"\)\s*\}/);
  assert.match(publicProbe, /guard let first = sets\.first, sets\.allSatisfy\(\{ \$0 == first \}\) else \{ return \(nil, "inconsistent"\) \}/);
  assert.match(publicProbe, /if let failure = v4\.failure \{ return completion\("doh_" \+ failure\) \}\s*if let address = v4\.addresses\?\.first \{ return probe\(address, host, completion\) \}/);
  // 問題與答案要接得上這個名字；有一個不是公開位址就整份不收。
  assert.match(publicProbe, /\(questions\[0\]\["name"\] as\? String\)\.map\(dnsName\) == name, dnsInteger\(questions\[0\]\["type"\]\) == code else \{ return \.failure\("question"\) \}/);
  assert.match(publicProbe, /return \.failure\("unlinked"\)   \/\/ 跟這個名字接不上的列/);
  assert.match(publicProbe, /guard isPublicAddress\(value\) else \{ return \.failure\("private"\) \}/);
  // 位址照 inet_pton 的位元組判斷；IPv6 只收 2000::\/3；連線用位元組建的位址。
  assert.match(publicProbe, /guard b\.count == 16, b\[0\] & 0xE0 == 0x20 else \{ return false \}/);
  assert.match(publicProbe, /if bytes\.count == 4, let v4 = IPv4Address\(Data\(bytes\)\) \{\s*endpoint = \.ipv4\(v4\)/);
  assert.doesNotMatch(code(publicProbe), /hasPrefix\("fe8"\)|hasPrefix\("::ffff:"\)|NWEndpoint\.Host\(address\)/);
  // 接收出錯一律「連不上」；嚴格照框。
  assert.match(publicProbe, /if failed \{ return \.some\("network"\) \}/);
  assert.match(publicProbe, /case \(\.some, \.some\):\s*return \.malformed/);
  assert.match(publicProbe, /if \["content-length", "transfer-encoding", "content-type"\]\.contains\(key\), headers\[key\] != nil \{ return \.malformed \}/);
  assert.match(publicProbe, /if rest\.count > length \{ return \.malformed \}/);
  assert.match(publicProbe, /guard bytes\[chunkEnd\.\.<bytes\.index\(chunkEnd, offsetBy: 2\)\] == crlf else \{ return \.malformed \}/);
  assert.match(publicProbe, /if end\.lowerBound == cursor \{ return end\.upperBound == bytes\.endIndex \? \.complete\(body\) : \.malformed \}/);
  assert.doesNotMatch(code(publicProbe), /let ended = closed \|\| error != nil/);
  assert.doesNotMatch(code(publicProbe), /Authorization|Bearer|Cookie:|apiToken|print\(|NSLog|\.write\(to:/);
  assert.match(publicProbe, /request\.httpShouldHandleCookies = false/);
  // 自測：確認不了＝不刪、之後自己再試、確認得了才刪；公開 DNS 與直連回應的解析。
  const acceptance = swift('Facade/HandsScopeAcceptance.swift');
  for (const label of ['W183 R7a 舊紀錄：新網址從外面確認不了（network）＝不刪、記著；之後不用按，自己隔一段時間再試', 'W183 R7a 公開 DNS（DoH JSON，用 IP 連、不經系統解析）',
    'W183 R7a 直連的回應照同一個判斷', 'W183 R7a 步驟訊息裡點名的按鈕都是畫面上真的有的', 'W183 R7a 第 6 步（網址給 ChatGPT）的訊息不露內部代號',
    'W183 R7a 授權那一步出錯或取消', 'W183 R7a 那一行不寫「第 N 步」', 'W183 R7a 審查 刪除判定', 'W183 R7a 審查 公開位址照 inet_pton 的位元組判斷']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.match(swift('Facade/HandsUIAcceptance.swift'), /try await r7aChecks\(check, fixture\)/);
  assert.match(swift('Facade/HandsUIAcceptance.swift'), /deps\.retireRetryDelays = \[\]/);
});

// W183 R8a：ChatGPT build（照 09-28 對照稿；docs/specs/183-chatgpt-hands/chatgpt-build.md）——使用者「整個流程不要弄得非常多文字
// 我還寧願你做得像n8n那種icon流程可視化」「可以 多設備就這樣 照對照稿開工」。
test('W183 R8a interface: HandsBuild.swift unchanged; HandsBuildModel is the adapter; the screen only talks to the model through intents', () => {
  const iface = swift('Facade/HandsBuild.swift');
  for (const name of ['enum HandsBuildNodeState', 'struct HandsBuildDevice', 'struct HandsBuildZone', 'struct HandsBuildProject', 'protocol HandsBuildModeling',
    'func setEnabled(_ on: Bool)', 'func setDevice(_ id: String, selected: Bool)', 'func loginCloudflare()', 'func chooseZone(_ id: String)',
    'func setSubdomain(_ label: String, for deviceID: String)', 'func applyURLs()', 'func setLevel(_ level: Int)', 'func setProject(_ id: String, selected: Bool)',
    'func connect(deviceID: String?)']) assert.ok(iface.includes(name), name);
  assert.match(buildModel, /final class HandsBuildModel: ObservableObject, HandsBuildModeling, HandsBuildSeenApplying, HandsBuildLocalApplying \{/);
  // 畫面不直接碰現有流程：只經 HandsBuildModel（按鈕一律 HandsBuildUIIntent.…send(to: model)）。
  assert.doesNotMatch(code(build), /HandsSetup\.shared|HandsRemoteClient\.shared|HandsConnectFlow\.shared|HandsState\.shared|CloudflareAccountsStore\.shared|remote\.act\(|setup\.(runAll|login|chooseHost|confirmAuthorization)/);
  // W183 R12（使用者 09-30 裁決：拿掉等級選擇）：面板沒有選等級的按鈕了（level( 不再送）；其他照舊。
  for (const intent of ['toggle(true)', 'toggle(false)', 'pickDevice(', 'loginCloudflare', 'loginCloudflareFor(', 'chooseZone(', 'subdomain(', 'apply',
    'connect(nil)', 'connect(device.id)', 'unlockSafety(']) {
    assert.ok(build.includes(`HandsBuildUIIntent.${intent}`), intent);
  }
  assert.ok(!build.includes('HandsBuildUIIntent.level('), 'no level buttons on the panel (W183 R12)');
  // W183 R10：專案 chips 只顯示（全部可見、新專案自動加入）——畫面不再送勾專案的動作。
  assert.ok(!build.includes('HandsBuildUIIntent.project('), 'project chips are display-only');
  // 每個效果對到後端（execute）。W183 R8 整合：全部經 R8c 的 HandsBuildController（中央設定 CAS、信箱、逐台連線）——不再直接叫這台的
  // HandsSetup／HandsState（單主機）；這台自己的授權頁在等＝在這台的私訊框再打開。
  const execute = between(buildModel, 'private func execute(', '// MARK: 更新');
  for (const [effect, call] of [['setEnabled', 'build.setEnabled(on)'], ['select', 'build.setDevice(id, selected: selected)'],
    ['login', 'build.loginCloudflare(for: id)'], ['openLogin', 'HandsSetup.openLoginPage(url, returnTo: .tap'], ['chooseZone', 'build.chooseZone(zone)'],
    ['setSubdomain', 'build.setSubdomain(label, for: device)'], ['apply', 'build.applyURLs(saving: drafts.map { HandsBuildConfigOp.subdomain(device: $0.device, label: $0.label) }, expected: expected)'],
    ['setLevel', 'build.setLevel(level)'], ['setProject', 'build.setProject(id, selected: selected)'], ['connect', 'build.connect(deviceID: device)'],
    ['unlock', 'build.unlockSafety(for: id)']]) {
    assert.ok(execute.includes(`case .${effect}`) && execute.includes(call), `${effect} → ${call}`);
  }
  assert.doesNotMatch(code(execute), /hands\.set(Level|AllowedProjects|SubdomainLabel|Enabled)\(|setup\.(runAll|login|chooseHost|chooseDomain|confirmAuthorization)\(|HandsOneSwitch\./);
  assert.match(swift('Facade/HandsState.swift'), /func setSubdomainLabel\(_ label: String\) -> Bool \{ apply \{ _ = try self\.service\.updateSettings \{ \$0\.subdomainLabel = HandsSettings\.validLabel\(label\) \} \} \}/);
  // W183 R8a 審查（GPT-6）：「…」工程細節裡的寫入也只經 adapter（HandsBuildModel.detail／deleteUnusedTunnels；送出那一刻再核模式、主機、世代）。
  // W183 R8 整合：副設備看主機的兩塊拿掉之後，「…」裡的寫入只剩這台自己的（加上別台的撤銷全部）——一樣全部經 adapter。
  const details = code(between(section, 'struct ChatGPTBuildDetails: View {', 'struct ChatGPTHandsPairingCard: View'));
  assert.doesNotMatch(details, /setup\.(cancel|run|confirmAuthorization|reauthorize|chooseDomain|chooseHost|confirmHostChange|dismissHostChange|deleteUnusedTunnels|login)\(|hands\.(stopPairing|revokeGrant|revokeAll|setCallbacks|setLevel|setAllowedProjects|setSubdomainLabel)\(|remote\.(act|openLoginHere)\(|HandsSetup\.openLoginPage|\.revokeAll\(for:/);
  assert.ok((details.match(/build\.detail\(|HandsBuildModel\.shared\.detail\(|build\.deleteUnusedTunnels\(/g) ?? []).length >= 11, 'every write goes through the adapter');
  const detail = between(buildModel, 'func detail(_ action: HandsBuildDetail', 'func deleteUnusedTunnels(');
  assert.match(detail, /if let refusal = Self\.detailRefusal\(action, shown: shown, now: seen\) \{\n\s*notice = refusal\n\s*return refusal\n\s*\}/);
  assert.match(between(buildModel, 'func deleteUnusedTunnels(', 'private func run('), /Self\.detailRefusal\(\.deleteTunnels\(ids\), shown: shown, now: seen\)/);
  const refusal = between(buildModel, 'static func detailRefusal(', 'enum HandsBuildDetail');
  // W183 R8 整合：「模式、主機」換成「主設備（主權）」；會放寬的動作看這台的流程世代。
  assert.match(refusal, /guard shown\.sameRole\(now\) else \{ return HandsBuildCopy\.changed \}\n\s*if action\.checksEpoch, shown\.epochHere != now\.epochHere \{ return HandsBuildCopy\.changed \}/);
});

test('W183 R8a safety: scope and URL changes only where allowed; connect is the DM card; no AI tool reaches the build model', () => {
  const plan = between(buildModel, 'static func plan(_ action: Action', '// MARK: - adapter');
  const controller = swift('Facade/HandsBuildController.swift');
  // W183 R8 整合（R8c）：等級、專案、子網域、網域、勾選都是中央設定——哪一台都看得到、改得到，但一律照畫面看到的版本 CAS（別處改過＝不改）；
  // 還沒從主設備拿到設定＝不能改（沒有「不比對版本」）。原本「只有主機這台能改、副設備唯讀」守的是「改的一定是使用者在原生畫面看到的那一份」，
  // 現在由 CAS＋設備簽章 RPC（hands_build config）守；主設備那端還會核：同一個主機名不能分給兩台、別台建的網址不分、所有權表讀不到就不分配。
  assert.match(plan, /guard i\.configKnown, let revision = i\.configRevision else \{ return \[\.notice\(HandsBuildCopy\.notReady\)\] \}/);
  assert.match(between(controller, '    private func change(_ ops: [HandsBuildConfigOp]) {', '    func setEnabled('),
    /guard let expected = config\?\.configRevision else \{\n\s*actionProblem = "還沒從主設備拿到設定；等一下再按"[\s\S]*try sync\.updateConfig\(expected: expected, ops: ops\)/);
  assert.match(swift('Facade/HandsBuildConfig.swift'), /guard expectedRevision == current\.configRevision else \{ throw HandsBuildConfigError\.revisionConflict\(current\.configRevision\) \}/);
  // W183 R10：專案不再勾——面板的計畫對「勾專案」一律什麼都不做（不寫中央設定；範圍＝那台全部專案）。
  assert.match(between(plan, 'case .setProject:', 'case .connect(let device):'), /\/\/ W183 R10：專案不再勾（全部可見；面板只顯示）：這個動作什麼都不做（留著相容）。\s*return \[\]\s*$/);
  assert.match(between(plan, 'case .setLevel(let level):', 'case .setProject('), /let clamped = min\(max\(level, 0\), HandsSettings\.maxLevel\)/);
  // 子網域：只收合格的 DNS 標籤；改網址只處理那一台（按「套用」才建）。
  assert.match(between(plan, 'case .setSubdomain(let raw, let device):', 'case .applyURLs('), /guard let label = HandsSettings\.validLabel\(raw\) else \{ return \[\.notice\(HandsBuildCopy\.badLabel\)\] \}/);
  // 套用：W183 R8c 登入只是登入（沒有登入後的確認關卡，網域要使用者在 Cloudflare 面板選）；沒選網域、沒勾設備、關著＝不送。
  const apply = between(plan, 'case .applyURLs(let seen, let drafts):', 'case .setLevel(let level):');
  assert.match(apply, /guard i\.selectedZoneID != nil else \{ return \[\.notice\(HandsBuildCopy\.pickDomain\)\] \}/);
  // W183 R8a 審查（GPT-6）：確認的是畫面上看到的那一份（變了就不送）；子網域草稿先驗，不合格就停；存與套用是同一件（後端先存、存不成就停）。
  assert.match(apply, /if let seen, seen != HandsBuildSeen\.of\(i\) \{ return \[\.notice\(HandsBuildCopy\.changed\)\] \}/);
  assert.match(apply, /let saved = plan\(\.setSubdomain\(draft\.label, draft\.device\), i\)\n\s*if saved\.contains\(where: \\\.isNotice\) \{ return saved \}/);
  assert.match(apply, /return \[\.apply\(expected: seen\?\.configRevision \?\? revision, drafts: saving\)\]/);
  const chain = between(controller, 'func applyURLs(saving ops: [HandsBuildConfigOp], expected: Int) {', '    /// ［連線］');
  assert.match(chain, /do \{ saved = try sync\.updateConfig\(expected: expected, ops: ops\)\.configRevision \}/);
  assert.match(chain, /guard let revision else \{\n\s*\/\/ 存不成＝停在這裡（不建通道、不改 DNS）；一句話留在面板上。\n\s*self\.actionProblem = problem/);
  // W183 R8 整合審查（GPT-6 高）：守的東西不變（存好之後，那台回報拿到那一版才送），改得更嚴——每台各自等自己的回執、只為 CAS 回的那個確切版本送；
  // 到期還沒拿到＝不送（出錯）；送出帶按的時候看到的那一份（主權＋版本），送出那一刻不自己讀版本。
  assert.match(chain, /\(self\.report\(id\)\?\.appliedConfigRevision \?\? 0\) >= pending\.expected\.revision/);
  assert.match(chain, /if late \{\n\s*for id in pending\.remaining \{ applyWork\[id\] = \.failed\(/);
  assert.doesNotMatch(code(chain), /applyURLs\(\)   \/\/ 還沒拿到的那台/, 'no send-anyway on timeout');
  assert.match(chain, /try sync\.submit\(action: "apply_urls", target: target, setupEpoch: epoch, expected: expected,/);
  const submit = between(swift('Facade/HandsBuildSync.swift'), '    func submit(action: String, target: String', '    /// 送一件、等最後一則結果');
  assert.match(submit, /guard let current, current\.configRevision == expected\.revision, HandsBuildExpected\.authority\(of: current\) == expected\.authority else \{\n\s*throw HandsBuildSyncError\.configChanged/);
  assert.match(submit, /guard action != "apply_urls" else \{ throw HandsBuildSyncError\.unavailable\("expected_revision"\) \}/);
  // 照順序做、任何一步沒成功就停（runEffects）。
  assert.match(buildModel, /for \(index, effect\) in effects\.enumerated\(\) \{\n\s*if !perform\(effect\) \{ return \(index, effect\) \}/);
  // Claude：網址建好（或已連線）之後換網域＝先出卡片內確認列（不一鍵換）。
  assert.match(between(plan, 'case .chooseZone(let zone):', 'case .confirmZone('), /guard i\.urlBuilt\.isEmpty, i\.totalGrants == 0 else \{ return \[\.askZoneChange\(zone\)\] \}/);
  assert.match(between(plan, 'case .confirmZone(let zone, let seen):', 'case .setSubdomain('), /guard seen == HandsBuildSeen\.of\(i\) else \{ return \[\.notice\(HandsBuildCopy\.changed\)\] \}/);
  // 解除安全鎖：只有那台回報鎖著、使用者對那台按才送（輪詢、重新勾選、重開、同步都不解除；後端綁事故編號與世代）。
  assert.match(between(plan, 'case .unlock(let id):', 'case .fix:'), /guard i\.safetyLocked\.contains\(id\.lowercased\(\)\) else \{ return \[\] \}/);
  assert.match(controller, /payload: \["incident": incident, "revocation_generation": generation\]\)/);
  // ［連線］＝私訊框的原生卡（一次性連線意圖只在那張卡按下才建立；T15 不變），不直接開窗口、不帶配對碼。
  assert.doesNotMatch(code(buildModel), /startPairing|openAttemptWindow|beginConnect|pairingCode|connectFlow\.connect\(/);
  // AI 工具（os-mcp、助理）碰不到：沒有任何 OS 工具或 bridge 方法叫 HandsBuildModel／HandsBuildController（hands_build 只收 SSH 轉進來＋設備簽章）。
  assert.doesNotMatch(read('Engines/os-mcp/server.mjs'), /HandsBuild|build_/);
  assert.doesNotMatch(bridge, /HandsBuildModel|HandsBuildController/);
  // Pod 帳號只在畫面顯示：不寫檔、不進日誌。
  for (const source of [build, flow, buildModel]) assert.doesNotMatch(code(source), /print\(|NSLog\(|Logger\(|\.write\(to:|FileManager/);
});

test('W183 R8a flow looks like the mock: dotted canvas, curved edges (solid brand / dashed grey), node badges, keyboard and VoiceOver', () => {
  // 對照稿的顏色（淺色）：完成 #3e9a5b、等你 #d98a3a、沒選 #c9c0b3、雲 #c66a2b；品牌色用 LiquidGlassTokens.brandAccent。
  assert.match(flow, /static let done = Color\(red: 62 \/ 255, green: 154 \/ 255, blue: 91 \/ 255\)/);
  assert.match(flow, /static let waiting = Color\(red: 217 \/ 255, green: 138 \/ 255, blue: 58 \/ 255\)/);
  assert.match(flow, /static let idle = Color\(red: 201 \/ 255, green: 192 \/ 255, blue: 179 \/ 255\)/);
  assert.match(flow, /static var accent: Color \{ LiquidGlassTokens\.brandAccent \}/);
  assert.match(flow, /StrokeStyle\(lineWidth: 2, lineCap: \.round, dash: \[5, 5\]\)/);
  assert.match(flow, /path\.addCurve\(to: b, control1: CGPoint\(x: mid, y: a\.y\), control2: CGPoint\(x: mid, y: b\.y\)\)/);
  assert.match(flow, /y \+= 16/);
  for (const state of ['case .done:', 'case .waiting:', 'case .failed:', 'case .working:', 'case .off:']) assert.ok(between(flow, 'struct ChatGPTBuildBadge', 'struct ChatGPTBuildSpinner').includes(state), state);
  assert.match(flow, /Text\("!"\)/);
  // 鍵盤聚焦得到、空白鍵／Return 打開；VoiceOver 念「名稱：狀態」、當按鈕。
  assert.match(flow, /\.focusable\(interactions: \.activate\)\n\s*\.focused\(\$focused, equals: node\.id\)/);
  assert.match(flow, /\.onKeyPress\(keys: \[\.space, \.return\]\)/);
  assert.match(flow, /\.accessibilityLabel\(node\.accessibilityLabel\)/);
  assert.match(flow, /\.accessibilityAddTraits\(isSelected \? \[\.isButton, \.isSelected\] : \[\.isButton\]\)/);
  assert.match(flow, /\.accessibilityAction \{ onPick\(node\.panel\) \}/);
  assert.match(buildModel, /return "\\\(name\)：\\\(HandsBuildCopy\.word\(state\)\)"/);
  // 節點：GPT →（每台設備；只有一台就只畫「主」）→ Cloudflare → ChatGPT Dev。
  assert.match(buildModel, /label: device\.isPrimary \? HandsBuildCopy\.primary : HandsBuildCopy\.secondary/);
  assert.match(buildModel, /static let primary = "主"\n\s*static let secondary = "副"/);
  assert.match(buildModel, /if !i\.devices\.isEmpty \{ return i\.devices \}/);
});

test('W183 R8a no long explanation text on the main card (strings live in HandsBuildCopy; details only behind 「…」 and ⓘ)', () => {
  const literals = source => [...code(source).matchAll(/"((?:[^"\\\n]|\\.)*)"/g)].map(m => m[1]);
  const plain = text => text.replace(/\\\(.*\)/g, '');   // 插值不算字數
  const longOnes = [...literals(build), ...literals(flow)].filter(text => /[一-鿿]/.test(text) && plain(text).length > 20);
  assert.deepEqual(longOnes, [], 'the build card has no long sentences');
  const copy = between(buildModel, 'enum HandsBuildCopy {', '// MARK: - 1.');
  const copyLong = literals(copy).filter(text => plain(text).length > 20 && !text.startsWith('透過 Cloudflare 網域連結主、副設備'));
  assert.deepEqual(copyLong, [], 'every HandsBuildCopy line is short (the ⓘ sentence is the only paragraph)');
  // 卡頭的「…」收 Pod／記憶體、通知、診斷、探查、休眠。
  const tap = swift('TAP/TapSettingsView.swift');
  const menu = between(tap, 'private var moreMenu: some View {', '    private var memoryText');
  for (const words of ['記憶體', '通知', 'Button("診斷")', 'Button("探查網頁選單")', 'Button("休眠")']) assert.ok(menu.includes(words), words);
  assert.match(menu, /\.popover\(isPresented: \$showsDiagnostics, arrowEdge: \.bottom\)/);
  assert.doesNotMatch(code(between(tap, 'private var chatGPTCard: some View {', 'private var moreMenu')), /row\("Pod"|row\("用途"|探查網頁選單/);
});

test('W183 R8a self-test w183ui covers node states, panel switching, one vs many devices, intents and the adapter, short text', () => {
  const acceptance = swift('Facade/HandsBuildUIAcceptance.swift');   // W183 R8 整合：R8a 的自測檔改名（R8c 的 w183build 用了 HandsBuildAcceptance.swift）
  assert.match(acceptance, /^#if DEBUG/);
  assert.doesNotMatch(acceptance, /CloudflareKeychain\(\)|CloudflareAccountsStore\.shared|HandsSetup\.shared|URLSession|HandsConnectFlow\.shared|HandsBuildModel\.shared|HandsState\.shared/);
  assert.match(between(swift('Facade/HandsUIAcceptance.swift'), '@MainActor static func run()', '// MARK: - 設定分頁'), /buildUIChecks\(check\)/);
  // W183 R8 整合：adapter 對到的是 R8c 的多設備後端（不再是單主機流程）；多台都勾、每台自己當主機各一條。
  for (const label of ['W183 R8a 節點狀態對應', 'W183 R8a 只有一台設備：只畫一個「主」節點', 'W183 R8a 多台設備：每台一個節點', 'W183 R8a 面板切換',
    'W183 R8a 按鈕叫對 model 動作', 'W183 R8a adapter 把每個動作對到多設備後端', 'W183 R8a 節點位置',
    'W183 R8a VoiceOver 念名稱與狀態', 'W183 R8 整合 多台都勾', 'W183 R8 整合 每台自己當主機']) {
    assert.ok(acceptance.includes(label) || swift('Facade/HandsUIAcceptance.swift').includes(label), label);
  }
  // 現有的「按鈕叫對」「adapter」「不會繞過確認」標明是純邏輯／結構檢查（不代表安全流程驗收）。
  for (const label of ['按鈕叫對 model 動作（純邏輯', 'adapter 把每個動作對到多設備後端（純邏輯', '不會繞過確認（結構檢查']) assert.ok(acceptance.includes(label), label);
  // W183 R8a 審查（GPT-6／Claude）：每一條都有操作級的反例（buildReviewChecks；暫時 grant 的真流程在 w183connect 的 happyPath）。
  assert.match(acceptance, /buildReviewChecks\(check, input: input, connectedInput: connectedInput/);
  // W183 R8 整合：「副設備還在問主機」改成「還不知道（還沒從主設備拿到設定）」——守的一樣是不猜、不送。
  for (const label of ['W183 R8a 審查 Computer Use', 'W183 R8a 審查 角色切換後的舊面板', 'W183 R8a 審查 等確認時拒絕授權', 'W183 R8a 審查 「套用」確認的是畫面上看到的那一份',
    'W183 R8a 審查 子網域存檔失敗', 'W183 R8a 審查 暫時的 grant', 'W183 R8a 審查 還不知道（還沒從主設備拿到設定）', 'W183 R8a 審查 網址建好（或已連線）之後換網域',
    'W224-5 現在的卡片只留能力']) assert.ok(acceptance.includes(label), label);
  assert.match(acceptance, /W224Acceptance\.compactBuild/);
  assert.match(acceptance, /HandsBuildMore\.allCases\.allSatisfy \{ \$0\.title\.count <= 8 \}/);
  const currentCard = swift('New/W224Acceptance.swift');
  assert.match(currentCard, /labels\.filter \{ \$0 != HandsBuildCopy\.capabilities \}\.allSatisfy \{ \$0\.count <= 20 \}/);
  assert.match(currentCard, /HandsBuildCopy\.infoParagraph\.count <= 80/);
  assert.match(currentCard, /W214Acceptance\.node\("tap\.chatgpt\.build\.capabilities"/);
  assert.match(currentCard, /current-card-has-no-retired-summaries-or-levels/);
  // W183 R8 整合：真的存檔失敗改在後端那一半驗（主設備的設定正本存不成：HandsBuildConfigStore；w183build 的整合檢查）。
  const integration = swift('Facade/HandsBuildIntegrationAcceptance.swift');
  assert.match(integration, /fleet\.store\.failSavesForTesting = true/, 'a real settings write failure, not a stub');
  for (const label of ['W183 R8 整合 套用帶子網域草稿：主設備存不成', 'W183 R8 整合 套用帶子網域草稿：看到的版本舊了', 'W183 R8 整合 套用帶子網域草稿：照看到的版本存好',
    'W183 R8 整合 每台回報確認過的連線數']) assert.ok(integration.includes(label), label);
  assert.match(swift('Facade/HandsBuildAcceptance.swift'), /try await integrationChecks\(check, base, keys\)/);
  assert.match(acceptance, /check\.skip\("Computer Use 真的拿到以 TATWO 為目標的授權後被這張卡撤銷/);
  const connectAcceptance = swift('Facade/HandsConnectAcceptance.swift');
  assert.ok(connectAcceptance.includes('W183 R8a 審查 暫時的 grant：畫面不算已連線') && connectAcceptance.includes('W183 R8a 審查 grant 轉正之後才算已連線'));
});

// W183 R8a 審查（GPT-6／Claude，十一條）：Computer Use 碰不到這張卡、「…」經 adapter、副設備等確認時能拒絕、看到的才確認、存檔失敗就停、
// 暫時 grant 不算完成、範圍摘要常駐、副設備還不知道主機狀態不猜、網址建好後換網域要確認。
test('W183 R8a review: the build card is a sensitive surface for Computer Use; secondary can reject a pending authorization; provisional grants are not connected', () => {
  // 1. Computer Use：卡片在畫面上＝以 TATWO 自己為目標一律拒絕（跟私訊框授權頁同一道閘門）。
  const body = between(build, '    var body: some View {', '    // MARK: 那一列');
  assert.match(body, /\.onAppear \{ HandsBuildScreenGate\.appeared\(screenToken\) \}\n\s*\.onDisappear \{ HandsBuildScreenGate\.disappeared\(screenToken\) \}/);
  const gate = between(buildModel, 'enum HandsBuildScreenGate {', undefined);
  assert.match(gate, /shown\.insert\(token\)\n\s*BrowserSensitivePageGate\.pageAppeared\(\)/);
  assert.match(swift('New/HandsConnectDMView.swift'), /\|\| HandsBuildScreenGate\.isShown/);
  assert.match(swift('Browser/BrowserSensitivePage.swift'), /\|\| HandsConnectPresenter\.anySensitive/);
  const cu = swift('New/ComputerUseController.swift');
  assert.match(cu, /guard Self\.refusesSelf\(pid: grant\.pid, lane: grant\.lane, sensitivePageOpen: BrowserSensitivePageGate\.isActive\) else \{ return \}/);
  // 3. 副設備等確認時：「…」›「步驟」那一列也在（含「取消並重新授權」）；Cloudflare 面板有「重新授權」（卡片內確認）。
  // W183 R8 整合（R8c 必改 4：登入只是登入）：登入不綁網域、不建網址，Cloudflare 面板沒有「確認這個授權」的關卡（網域由使用者在網域選單選、
  // 按「套用」才建）；不是要的授權用不上（選別的網域、替那台再登入一次）。這台的「…」›「帳號與網域」照舊有「是這個，繼續／取消並重新授權」。
  assert.match(section, /HandsAuthorizationRow\(summary: summary, canReauthorize: hands\.activeGrants\.isEmpty/);
  const cf = between(build, '    private func cloudflarePanel(', '    private func accountName(');
  assert.doesNotMatch(cf, /awaitingConfirm|reauthorize/);
  assert.match(cf, /OSChipButton\(title: HandsBuildCopy\.apply, systemImage: "checkmark", isPrimary: true\) \{ apply\(hosts, seen: seen\) \}/);
  // W183 R8 整合審查（Claude 中）：守的東西（子網域存不成＝草稿留著）在背景 CAS 之下改寫——送出當下不清草稿；設定回來、那台的子網域已經是
  // 草稿那個字才清（存不成、版本衝突＝草稿留著）。
  assert.match(build, /HandsBuildUIIntent\.apply\(seen: seen, drafts: currentDrafts\(hosts\)\)\.send\(to: model\)/);
  assert.doesNotMatch(code(between(build, '    private func apply(_ hosts:', '    // MARK: ChatGPT Dev')), /subdomainDrafts = \[:\]/);
  assert.doesNotMatch(code(between(build, '    private func commitSubdomain(', '    private func pruneSavedDrafts(')), /if model\.notice == nil/);
  assert.match(build, /\.onChange\(of: frame\.input\.configRevision\) \{ _, _ in pruneSavedDrafts\(model\.snapshot\.devices\) \}/);
  assert.match(build, /if draft == device\.subdomain \|\| HandsSettings\.validLabel\(draft\) == device\.subdomain \{ subdomainDrafts\[id\] = nil \}/);
  // 6. 暫時的 grant：只算確認過的才「已連線」（主機 HandsState.confirmedGrants、副設備 remote_hands_status 的 provisional）。
  const auth = swift('Facade/HandsAuth.swift');
  assert.match(auth, /provisional: grant\.pendingAttempt != nil\)/);
  assert.match(swift('Facade/HandsState.swift'), /var confirmedGrants: \[HandsGrantSummary\] \{ activeGrants\.filter \{ !\$0\.provisional \} \}/);
  assert.match(oneSwitch, /case \.idle, \.waitingTap, \.waitingUser, \.waitingPairing, \.connected: return provisional > 0 \? \.connecting : \.waiting\(\.connect\)/);
  assert.match(oneSwitch, /return connection\(grants: status\.grants\.filter \{ !\$0\.provisional \}\.count, provisional: status\.grants\.filter\(\\\.provisional\)\.count,/);
  assert.match(remote, /"provisional": grant\.provisional\]/);
  // W199：Space 的小鈕改用同一份「目前帳號」入口，只報需要動手；確認過的授權數／逐筆證據保障仍必須成立。
  assert.match(between(section, 'struct ChatGPTHandsStatusButton: View', undefined), /@ObservedObject private var entry = HandsConnectEntry\.shared/);
  assert.match(swift('New/HandsConnectEntry.swift'), /guard case \.connected\(let level\) = verdict\(device\.id\) else \{ continue \}/);
  assert.match(swift('Facade/HandsBuildSync.swift'), /report\.grantLevels = Dictionary\(confirmedSummaries\.prefix\(64\)\.map/);
  assert.match(swift('Facade/HandsBuildSync.swift'), /report\.confirmedGrants = grants\.filter \{ !provisional\.contains\(\$0\) \}\.count/);
  assert.match(swift('Facade/HandsBuildController.swift'), /: \(info\?\.confirmedGrants \?\? 0\) > 0 && running \? \.done/);
  // W214-4: the native card retains one capability sentence and Connect; project chips and detail rows are removed.
  assert.match(nativeW214(4), /W214 PASS N4.title-capability-and-connect.true/);
  assert.match(nativeW214(4), /W214 PASS N4.no-project-chips-or-detail-rows.true/);
  // W183 R8 整合：R8a 與 R7a 各加了同一個 allowed_projects 欄位，留 R7a 的（R7a 審查：清單不截在 50，上限是可列舉的 listLimit）；守的東西不變——副設備讀得到主機勾的專案名稱、有上限、去掉換行。
  assert.match(remote, /allowedProjects = \(object\["allowed_projects"\] as\? \[String\] \?\? \[\]\)\.prefix\(HandsProjectChoice\.listLimit\)\.map \{ String\(\$0\.filter \{ !\$0\.isNewline \}\.prefix\(80\)\) \}/);
  // W183 R8 整合：專案是勾選的每台自己回報的（(deviceID, projectID)），哪一台都看得到、改得到（中央設定）；多台時名字後面帶設備。
  assert.match(buildModel, /i\.projects = b\.projects/);
  assert.match(build, /case \.ready: who = input\.podAccount\.map \{ HandsBuildCopy\.pod \+ "：" \+ \$0 \} \?\? HandsBuildCopy\.pod/);
  // 10. 副設備還不知道主機的狀態：不亮「等你登入」。W183 R8 整合：還沒從主設備拿到設定＝不知道——Cloudflare 與 Dev 不亮、字是「準備中…」。
  assert.match(buildModel, /if !i\.configKnown \{ cloudflare = \.off \}/);
  assert.match(buildModel, /\} else if !i\.configKnown \{\n\s*s\.statusText = HandsBuildCopy\.preparing/);
});
