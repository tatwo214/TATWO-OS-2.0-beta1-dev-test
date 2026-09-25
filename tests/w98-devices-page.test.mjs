// W98：設備頁整理的靜態斷言（寫法沿用 w91b 的 wiring 測試）。
// 只看原始碼：入口搬去側欄、設備列收納、文案白話，而且信任那幾檔一行都沒動。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
// W98 分支的基準與分支尾（spec 與施工單都以它為準）。衛生斷言比對的是「W98 這條分支本身」，
// 用固定的兩個 commit 比，之後 W100／W91c 合法改動信任檔不會讓這條測試變成假警報。
const base = 'b7dbe873';
const w98Tip = '95782178';

const devicesCard = 'New/DevicesCard.swift';
const sidebar = 'Chat/ChatPage+Sidebar.swift';
const legacySections = 'New/RemoteDevicesSidebarSections.swift';
const uiFiles = [devicesCard, sidebar, legacySections];

test('W98 設備頁：「遙控它」換成「遠端設備專案」，只負責把人帶去側欄項目', () => {
  const card = source(devicesCard);
  assert.doesNotMatch(card, /遙控它/);
  assert.match(card, /Button\("遠端設備專案"\)/);
  // W98d：只帶路（展開＋捲到那台的區塊），不自己進遠端模式。
  assert.match(card, /model\.requestSidebarDeviceSection\(device\.id\)/);
  assert.doesNotMatch(card, /enterRemoteMode/);
  // 展開狀態只在畫面裡，不落地。
  assert.match(card, /@State private var expandedDevices: Set<String> = \[\]/);
  assert.doesNotMatch(card, /UserDefaults|AppStorage/);
});

test('W98d 側欄：每台設備一個跟「專案」「聊天」同層的區塊，標題照專案區那顆', () => {
  const view = source(sidebar);
  const sections = source(legacySections);
  // (b) 區塊標題：文字格式、字級、chevron、間距、右側 26x26 控制位置都照 projectSidebarSectionHeader。
  const projectHeader = view.slice(view.indexOf('var projectSidebarSectionHeader:'), view.indexOf('var chatSidebarSectionHeader:'));
  const deviceHeader = sections.slice(sections.indexOf('private var header: some View {'));
  assert.match(sections, /Text\("遠端設備（\\\(deviceName\)）" \+ \(isOnline \? "" : "・離線"\)\)/);
  for (const shape of [/\.font\(ChatTypography\.sidebarHeader\)/,
                       /Image\(systemName: \w+ \? "chevron\.down" : "chevron\.right"\)\s*\n\s*\.font\(\.system\(size: 9, weight: \.black\)\)/,
                       /HStack\(spacing: 6\)/, /HStack\(spacing: 8\)/, /Spacer\(minLength: 8\)/,
                       /\.frame\(width: 26, height: 26\)/, /\.frame\(minHeight: 30\)/,
                       /\.padding\(\.top, 2\)\s*\n\s*\.padding\(\.horizontal, 4\)/]) {
    assert.match(projectHeader, shape);
    assert.match(deviceHeader, shape);
  }
  // 標題只收合／展開，不進遠端模式；離線灰化。
  assert.match(deviceHeader, /isExpanded\.toggle\(\)/);
  assert.ok(!deviceHeader.includes('enterRemoteMode'), '區塊標題不該進遠端模式');
  assert.match(deviceHeader, /\.opacity\(isOnline \? 1 : 0\.55\)/);
  // 排在「專案」區之後、「聊天」區之前，而且專案區裡不再有遠端設備項目。
  const body = view.slice(view.indexOf('projectSidebarSectionHeader'), view.indexOf('chatSidebarSectionHeader\n'));
  const projectsBlock = body.slice(body.indexOf('if projectsSectionExpanded {'), body.indexOf('ForEach(model.devices)'));
  assert.ok(!projectsBlock.includes('RemoteDevice'), '「專案」區裡還留著遠端設備項目');
  assert.match(body, /ForEach\(model\.devices\) \{ device in\s*\n\s*RemoteDeviceSidebarSection\(/);
  assert.ok(!view.includes('RemoteDeviceProjectRow') && !view.includes('remoteDeviceProjectRow'), '舊的專案區項目沒清乾淨');
  assert.ok(!view.includes('RemoteDevicesSidebarSections('), '舊的整段列表沒清乾淨');
  // 圖示與遙控中高亮沿用 W98 的呈現規則。
  assert.match(view, /RemoteDevicePresentation\.icon\(device\)/);
  assert.match(sections, /model\.remoteMode\?\.id == deviceID \? LiquidGlassTokens\.brandAccent/);
  // (f) 沒有對應設備的工作階段仍有自己的區塊（fallback），不是死碼也不重複列。
  assert.match(view, /ForEach\(unmatchedRemoteSections\) \{ section in\s*\n\s*RemoteDeviceSidebarSection\(/);
  assert.match(view, /!model\.devices\.contains \{ \$0\.id == section\.deviceID \}/);
  // (g) 區塊內容仍從 remoteSidebarSections 依 device id 對應。
  assert.match(sections, /model\.remoteSidebarSections\.first \{ \$0\.deviceID == deviceID \}/);
  assert.match(sections, /if isExpanded, let section \{\s*\n\s*RemoteDeviceSectionContent\(model: model, section: section\)/);
  // 預設展開（同專案區），不持久化。
  assert.match(sections, /@State private var isExpanded = true/);
  assert.doesNotMatch(sections, /UserDefaults|AppStorage/);
  // 設備頁那顆按鈕的訊號：側欄捲過去、區塊自己展開。
  assert.match(view, /onReceive\(model\.\$sidebarDeviceFocus\)/);
  assert.match(view, /proxy\.scrollTo\(RemoteDeviceSidebarSection\.anchorID\(focus\.deviceID\), anchor: \.top\)/);
  assert.match(sections, /onReceive\(model\.\$sidebarDeviceFocus\)/);
  // 子層文字一字不改。
  for (const copy of ['這台還沒有專案', '離線・\\(RemoteDeviceSidebarSection.seen(section.lastSeenAt))',
                      'RemoteThreadRowView(model: model, deviceID: section.deviceID, thread: thread)']) {
    assert.ok(sections.includes(copy), `子層缺少 ${copy}`);
  }
});

test('W98c 專案是自己的可展開列，討論串只在專案展開後才列', () => {
  const legacy = source(legacySections);
  const content = legacy.slice(legacy.indexOf('struct RemoteDeviceSectionContent'));
  // (h) 討論串那圈 ForEach 必須關在 expandedProjects 的條件分支裡，不能再攤平。
  assert.match(content, /@State private var expandedProjects: Set<UUID> = \[\]/);
  assert.match(content, /let isExpanded = expandedProjects\.contains\(project\.id\)/);
  assert.match(content, /if isExpanded \{\s*\n\s*ForEach\(project\.threads\)/);
  const flat = content.slice(content.indexOf('ForEach(section.projects)'),
                             content.indexOf('if isExpanded {', content.indexOf('ForEach(section.projects)')));
  assert.ok(!flat.includes('ForEach(project.threads)'), '討論串還攤在專案層');
  // (i) 專案列有 chevron，而且是切換 expandedProjects 的按鈕。
  assert.match(content, /Image\(systemName: isExpanded \? "chevron\.down" : "chevron\.right"\)/);
  assert.match(content, /expandedProjects\.remove\(project\.id\)/);
  assert.match(content, /expandedProjects\.insert\(project\.id\)/);
  // 專案列預設收合、不持久化；遠端專案列不給寫入動作。
  assert.ok(!content.includes('createThread'), '遠端專案列不該有新增討論串');
  assert.ok(!content.slice(0, content.indexOf('struct RemoteThreadRowView')).includes('contextMenu'),
            '遠端專案列不該有右鍵動作');
  // 設備層的兩句話留在原地。
  assert.ok(content.includes('這台還沒有專案'));
  assert.ok(content.includes('離線・\\(RemoteDeviceSidebarSection.seen(section.lastSeenAt))'));
});

test('W98 設備列照 Computer Use 的收納列：收合只露名稱、狀態、user@host', () => {
  const card = source(devicesCard);
  const computerUse = source('New/ComputerUseSettingsView.swift');
  for (const shape of [
    /rotationEffect\(\.degrees\(.*expanded.*\? 90 : 0\)\)/i,
    /\.font\(\.system\(size: 13, weight: \.semibold\)\)/,
    /\.font\(\.system\(size: 11\.5\)\)/,
    /accessibilityHint\(/,
  ]) {
    assert.match(computerUse, shape);
    assert.match(card, shape);
  }
  // 展開後才出現的東西，全在 isExpanded 之後。
  const expandedBlock = card.slice(card.indexOf('if isExpanded {'), card.indexOf('private func badge('));
  for (const detail of ['device.fingerprintSummary', 'DeviceEndpointsRow(device: device)',
                        '加入 \\(Self.stamp(device.addedAt))', 'Button("移除")', 'Button("遠端設備專案")']) {
    assert.ok(expandedBlock.includes(detail), `展開區缺少 ${detail}`);
  }
  assert.match(card, /badge\(isOnline \? "在線" : "離線"/);
  // 沒有可提供的更新就不顯示徽章。
  assert.match(card, /if !update\.hasSuffix\("無"\)/);
});

test('W98 文案：端點三種路白話、順序說明一行、指紋改隧道／簽章識別', () => {
  const card = source(devicesCard);
  for (const copy of ['區網 IP', '隧道', 'SSH 別名', '停用這條路（可還原）', '加一條連線路徑',
                      '區網＝同一 Wi-Fi 直連', '出門在外走 Cloudflare', '~/.ssh/config 的設定',
                      '依區網→隧道→別名順序嘗試']) {
    assert.ok(card.includes(copy), `缺少文案 ${copy}`);
  }
  for (const stale of ['刪除端點（封存）', '新增端點', '主機金鑰', '客戶端金鑰']) {
    for (const file of uiFiles) {
      assert.ok(!source(file).includes(stale), `${file} 還留著舊文案 ${stale}`);
    }
  }
  const summary = source('Facade/DeviceRegistry.swift');
  const shown = summary.slice(summary.indexOf('var fingerprintSummary: String {'));
  assert.ok(shown.includes('part("隧道識別"') && shown.includes('part("簽章識別"'), '指紋文案沒改成白話');
  assert.ok(!shown.includes('part("主機金鑰"') && !shown.includes('part("客戶端金鑰"'), '指紋還在用舊字');
  assert.ok(shown.includes('重新配對即可補齊'), '缺一把時沒有補齊提示');
});

test('W98 信任那幾檔零改動；DeviceRegistry 只動 fingerprintSummary 的字', () => {
  const frozen = ['Facade/DevicePairingHost.swift', 'Facade/DevicePairingClient.swift',
                  'Facade/DevicePairingCode.swift', 'Facade/DevicePairingStubs.swift',
                  'Facade/RemoteHostLink.swift', 'Facade/DeviceDispatch.swift'];
  for (const file of frozen) {
    const diff = git('diff', '--stat', base, w98Tip, '--', join('App/Sources/Tatwo2', file));
    assert.equal(diff.trim(), '', `${file} 在 W98 分支（${base}..${w98Tip}）有改動：\n${diff}`);
  }
  // DeviceRegistry：把 fingerprintSummary 那段切掉之後，前後必須跟基準一字不差。
  const path = 'App/Sources/Tatwo2/Facade/DeviceRegistry.swift';
  const marker = 'var fingerprintSummary: String {';
  const tail = 'private extension NSLock {';
  const slice = text => {
    const head = text.indexOf(marker);
    const rest = text.indexOf(tail);
    assert.ok(head > 0 && rest > head, 'DeviceRegistry 的結構被動過（找不到 fingerprintSummary／NSLock 段）');
    return [text.slice(0, head), text.slice(rest)];
  };
  const before = slice(git('show', `${base}:${path}`));
  const after = slice(git('show', `${w98Tip}:${path}`));
  assert.equal(after[0], before[0], 'fingerprintSummary 以外的 DeviceRegistry 內容被改到了');
  assert.equal(after[1], before[1], 'fingerprintSummary 之後的 DeviceRegistry 內容被改到了');
  // ChatPageModel 只多了「請側欄展開專案區」這件事，遠端模式邏輯沒動。
  const model = git('diff', '-U0', base, w98Tip, '--', 'App/Sources/Tatwo2/Facade/ChatPageModel.swift')
    .split('\n').filter(line => /^[+-][^+-]/.test(line));
  assert.ok(model.every(line => line.startsWith('+')), `ChatPageModel 有刪改：\n${model.join('\n')}`);
  assert.ok(model.every(line => /sidebarProjectsExpandRequest|requestSidebarProjectsExpanded|W98/.test(line)),
            `ChatPageModel 多了無關的東西：\n${model.join('\n')}`);
});

test('W98 UI 檔不碰私鑰', () => {
  for (const file of uiFiles) {
    const text = source(file);
    for (const secret of [/privateKey/, /id_ed25519/, /-----BEGIN/]) {
      assert.doesNotMatch(text, secret, `${file} 出現 ${secret}`);
    }
  }
});
