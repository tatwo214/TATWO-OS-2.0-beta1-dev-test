// 2026-09-23 支線：Spotify 在 OS 瀏覽器不能播 → Widevine 由 設定 › 瀏覽器 › 音樂與影片 開關（預設關）放行 Chromium 元件下載。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');

test('Protected media: off by default, bridge only lifts the download block when the setting is on', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /\[defaults boolForKey:@"tatwo\.browser\.protectedMedia"\] \|\|\n\s*\[defaults boolForKey:@"tatwo\.browser\.widevineSpike"\]/);
  assert.match(bridge, /if \(!allow_component_download\) \{\n\s*command_line->AppendSwitch\("disable-background-networking"\);/);
  assert.match(bridge, /if \(!allow_component_download\) \{\n\s*command_line->AppendSwitch\("disable-component-update"\);/);
  const media = read('App/Sources/Tatwo2/Browser/BrowserProtectedMedia.swift');
  assert.match(media, /static let key = "tatwo\.browser\.protectedMedia"/);
  assert.match(media, /UserDefaults\.standard\.bool\(forKey: key\) \|\| UserDefaults\.standard\.bool\(forKey: legacySpikeKey\)/);
  // 實測：元件在這次啟動之後才下載好，要重開一次才用得到。
  assert.match(media, /cdm\.date > launchDate \? \.downloadedNeedsRestart\(cdm\.version\) : \.ready\(cdm\.version\)/);
  assert.match(media, /TatwoTerminationCoordinator\.bypassNextConfirmation = true/);
  assert.match(read('App/Sources/Tatwo2/Shell/AppShell.swift'), /_ = \(BrowserProtectedMedia\.enabledAtLaunch, BrowserProtectedMedia\.launchedAt\)/);
});

test('Protected media: settings card, 開始使用 item, and diagnostics show real state', () => {
  assert.match(read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift'), /browserSettingsCard\("音樂與影片"\) \{ BrowserProtectedMediaSettingsView\(\);/);
  const guide = read('App/Sources/Tatwo2/Shell/SetupGuide.swift');
  assert.match(guide, /title: "在 OS 瀏覽器播受保護的影音"/);
  assert.match(guide, /section: \.browserManagement, required: false/);
  for (const f of ['BrowserDiagnosticsView.swift', 'BrowserDiagnosticsReport.swift']) {
    assert.doesNotMatch(read('App/Sources/Tatwo2/Browser/Diagnostics/' + f), /Widevine）：不支援/);
  }
});
