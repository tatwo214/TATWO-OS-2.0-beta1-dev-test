// W176（使用者 2026-09-23）：「可以做進App 不要叫測試 叫TATWO OS 並且預設用os開啟時就是tatwo os播放 不要手動再喬」。
// OS 瀏覽器的 Spotify 網頁播放器沒有 VMP 簽章只能播約 10 秒；改由 App 內建的 Spotify 裝置（librespot）播放。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');

test('helper：librespot 釘版、不開區網探索、名字 TATWO OS、320 kbps、quit 就走', () => {
  const cargo = read('Engines/spotify-helper/Cargo.toml');
  assert.match(cargo, /librespot = \{ version = "=0\.8\.0", default-features = false, features = \["native-tls", "rodio-backend"\] \}/);
  assert.doesNotMatch(cargo, /with-libmdns|with-avahi|with-dns-sd/);
  assert.match(read('Engines/spotify-helper/Cargo.lock'), /name = "librespot"\nversion = "0\.8\.0"/);
  assert.match(read('Engines/spotify-helper/LICENSE-librespot'), /The MIT License/);
  const main = read('Engines/spotify-helper/src/main.rs');
  assert.match(main, /let mut name = "TATWO OS"\.to_string\(\);/);
  assert.match(main, /Bitrate::Bitrate320/);
  for (const command of ['login', 'logout', 'transfer', 'quit']) assert.match(main, new RegExp(`"${command}" => Command::`));
  assert.match(main, /Command::Transfer => match spirc\.as_ref\(\)/);
  assert.match(main, /None => transfer_pending = true/);
  // 不存音樂檔、憑證失效就丟掉重登、結束時不等 stdin。
  assert.match(main, /Cache::new\(Some\(&options\.cache\), Some\(&options\.cache\), None, None\)/);
  assert.match(main, /std::fs::remove_file\(&credentials_file\)/);
  assert.match(main, /std::process::exit\(0\);\n\}\s*$/);
  assert.match(read('.gitignore'), /Engines\/spotify-helper\/target\//);
});

test('打包：放進 Contents/Helpers、照 Cargo.lock 編、用 App 同一張憑證簽', () => {
  const bundler = read('scripts/bundle-spotify.py');
  assert.match(bundler, /HELPER = "Contents\/Helpers\/tatwo-spotify"/);
  assert.match(bundler, /"build", "--release", "--locked"/);
  assert.match(bundler, /TATWO2_SKIP_SPOTIFY_HELPER/);
  assert.match(bundler, /"codesign", "--force", "--sign", identity/);
  const build = read('scripts/build-app.sh');
  assert.match(build, /bundle-gbrain\.py" prepare "\$APP"\n# W176[^\n]*\npython3 -E "\$ROOT\/scripts\/bundle-spotify\.py" prepare "\$APP"/);
  assert.match(build, /bundle-spotify\.py" finalize "\$APP" "\$SIGN_IDENTITY"\n\s*python3 -E "\$ROOT\/scripts\/runtime-sign\.py"/);
  assert.match(build, /bundle-spotify\.py" finalize "\$APP" -\n\s*python3 -E "\$ROOT\/scripts\/runtime-sign\.py"/);
  assert.match(build, /Engines\/spotify-helper\/Cargo\.lock/);
});

test('App：啟動就開、打開 Spotify 分頁轉到 TATWO OS（每分頁一次）、只開官方登入頁', () => {
  const service = read('App/Sources/Tatwo2/Browser/SpotifyConnect.swift');
  assert.match(service, /static let deviceName = "TATWO OS"/);
  assert.match(service, /url\.scheme == "https", url\.host == "accounts\.spotify\.com"/);
  assert.match(service, /attributes: \[\.posixPermissions: 0o700\]/);
  // 等網頁播放器初始化完才轉；30 秒內被搶回就再轉（最多 3 次）。
  assert.match(service, /static let handoffDelay: TimeInterval = 4\n\s*static let handoffGuard: TimeInterval = 30/);
  assert.match(service, /func spotifyTabOpened\(\) \{[\s\S]*?asyncAfter\(deadline: \.now\(\) \+ Self\.handoffDelay\)/);
  // 接手後被搶回的兇手是別的瀏覽器開著的 Spotify 網頁；直接接手＋30 秒內被搶再接手（最多 3 次）。
  assert.match(service, /private func requestTransfer\(\) \{[\s\S]*?guard !isActive else \{[^\n]*\}\n\s*Self\.trace\("transfer requested"\)\n\s*send\("transfer"\)/);
  assert.match(service, /case "inactive":[\s\S]*?until > Date\(\), handoffRetries < 3[\s\S]*?requestTransfer\(\)/);
  assert.doesNotMatch(service, /SpotifyDevicePicker|clickElement|captureVisibleSnapshot/);
  assert.match(read('Engines/spotify-helper/src/main.rs'), /PlayerEvent::SessionDisconnected \{ \.\. \} => emit\("inactive"/);
  assert.match(service, /case "connected":\n\s*status = \.connected\n\s*if pendingTransfer \{ pendingTransfer = false; requestTransfer\(\) \}/);
  assert.match(service, /forName: NSApplication\.willTerminateNotification/);
  assert.match(read('App/Sources/Tatwo2/Shell/AppShell.swift'), /SpotifyConnect\.shared\.startIfSignedIn\(\)/);
  const cef = read('App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift');
  assert.match(cef, /if !entry\.spotifyHandedOff, pageURL\.host\?\.lowercased\(\) == SpotifyConnect\.spotifyHost \{\n\s*entry\.spotifyHandedOff = true\n\s*SpotifyConnect\.shared\.spotifyTabOpened\(\)/);
});

test('設定與開始使用：音樂與影片卡片有 Spotify 區塊，開始使用多一項', () => {
  assert.match(read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift'),
    /browserSettingsCard\("音樂與影片"\) \{ BrowserProtectedMediaSettingsView\(\); Divider\(\); SpotifyConnectSettingsView\(\) \}/);
  const service = read('App/Sources/Tatwo2/Browser/SpotifyConnect.swift');
  assert.match(service, /OSChipButton\(title: "登入 Spotify", isPrimary: true\)/);
  assert.match(service, /需要 Premium；音質最高 320 kbps，不支援無損/);
  const guide = read('App/Sources/Tatwo2/Shell/SetupGuide.swift');
  assert.match(guide, /Item\(id: "spotify", title: "在 OS 裡聽 Spotify"/);
});

test('接手播放的每一步寫進 spotify/app.log（App 的 stderr 是 /dev/null）', () => {
  const service = read('App/Sources/Tatwo2/Browser/SpotifyConnect.swift');
  assert.match(service, /static func trace\(_ message: String\)/);
  assert.match(service, /appendingPathComponent\("app\.log"\)/);
  for (const step of ['tab opened', 'transfer deferred', 'transfer skipped', 'transfer requested']) {
    assert.ok(service.includes(step), step);
  }
});

test('TATWO OS 播 Spotify 時，Spotify 分頁與釘選也畫音符（和 YouTube 同一個動畫）', () => {
  const audible = read('App/Sources/Tatwo2/Browser/BrowserAudibleTabs.swift');
  assert.match(audible, /@Published private\(set\) var playingElsewhere: Set<String> = \[\]/);
  assert.match(audible, /if playingElsewhere\.contains\(host\) \{ return true \}/);
  assert.match(read('App/Sources/Tatwo2/Browser/BrowserTabRow.swift'), /audible\.ids\.contains\(tabID\) \|\| host\.map\(audible\.playingElsewhere\.contains\) == true \{ BrowserAudioNote\(\) \}/);
  assert.match(read('App/Sources/Tatwo2/Browser/SpotifyConnect.swift'), /BrowserAudibleTabs\.shared\.setPlayingElsewhere\(host: Self\.spotifyHost, isPlaying\)/);
});
