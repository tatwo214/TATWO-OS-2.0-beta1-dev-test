import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, statSync } from 'node:fs';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');

// W181（使用者 09-27：「這是我的logo 做小視窗t的替代」「chatgpt logo也對應過去」）
test('DM avatars: TATWO assistant uses the user logo, ChatGPT uses the OpenAI icon, letters stay as fallback', () => {
  const png = statSync(new URL('../App/Sources/Tatwo2/Resources/ProviderIcons/TatwoAvatar-assistant.png', import.meta.url));
  assert.ok(png.size > 1000 && png.size < 400_000, 'logo is packaged as a small PNG in the processed ProviderIcons folder');
  assert.match(read('Package.swift'), /\.process\("Resources\/ProviderIcons"\)/);
  assert.match(read('App/Sources/Tatwo2/Shell/ProviderIconResources.swift'), /static func pngURL\(for fileName: String\) -> URL\?/);
  const view = read('App/Sources/Tatwo2/DM/GlobalDMView.swift');
  assert.match(view, /enum GlobalDMAvatarArt: Equatable \{\s*case assistant, chatGPT/);
  assert.match(view, /pngURL\(for: "TatwoAvatar-assistant"\)/);
  assert.match(view, /ProviderSVGIconLoader\.image\(for: "codex-gpt"\)/);
  assert.match(view, /case \.assistant: letter = "T"; color = GlobalDMPalette\.assistantAvatar; art = \.assistant/);
  assert.match(view, /case \.chatGPT: letter = "G"; color = GlobalDMPalette\.chatGPTAvatar; art = \.chatGPT/);
  // 讀不到圖時照舊畫字母。
  assert.match(view, /\} else \{\s*Text\(letter\)/);
  const strip = read('App/Sources/Tatwo2/DM/GlobalDMTargetStrip.swift');
  // W183 R8b 加了第三顆 Browser 的地球（這一條在基準上就沒跟上，W184 AB 補上）；其他照舊是字母。
  assert.match(strip, /let art: GlobalDMAvatarArt\? = item\.kind == \.assistant \? \.assistant : item\.kind == \.chatGPT \? \.chatGPT\s*: item\.kind == \.browser \? \.browser : nil/);
});

// W181（使用者 09-27：「白色圓形比例是這樣」「chatgpt要用白色底黑線不要綠色」「其他圓鈕先移除」）
test('DM avatars: logo on a white circle, ChatGPT black lines on white, the strip keeps only these two', () => {
  const view = read('App/Sources/Tatwo2/DM/GlobalDMView.swift');
  assert.match(view, /\.foregroundStyle\(Color\.black\)/);
  assert.match(view, /\.background\(Color\.white, in: Circle\(\)\)/);
  const store = read('App/Sources/Tatwo2/DM/GlobalDMStore.swift');
  assert.match(store, /static let showsOtherTargets = false/);
  assert.match(store, /guard showingOthers else \{ return items \}/);
  // W184 AB：圓鈕列在頂列（GlobalDMPhoneBox.swift），圓鈕照舊來自 store.iconItems()（只放這幾顆）。
  const phone = read('App/Sources/Tatwo2/DM/GlobalDMPhoneBox.swift');
  assert.match(phone, /GlobalDMIconStrip\(store: store, besideBrowser: form\.isDuo\)/);
  assert.match(phone, /var items = iconItems\(\)/);
});

// W181：兩顆圖示放大、幾乎填滿圓鈕；上次停在 session 時開 App 改回助理（那條沒有圖示可點）。
test('DM strip: bigger icons for the two avatars; a stale session target falls back to the assistant', () => {
  const strip = read('App/Sources/Tatwo2/DM/GlobalDMTargetStrip.swift');
  // W184 AB：圓鈕 44（可按的東西至少 44；樣子照舊，只放大）。
  assert.match(strip, /static let iconSize: CGFloat = DMPhone\.touch/);
  assert.match(strip, /let size = GlobalDMIconStripLayout\.iconSize/);
  assert.match(strip, /size: art == nil \? size - 10 : size - 4/);
  const store = read('App/Sources/Tatwo2/DM/GlobalDMStore.swift');
  assert.match(store, /if !showsOtherTargets, case \.thread = store\.target \{ store\.select\(\.assistant\) \}/);
});
