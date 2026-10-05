import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('M16 completion is the primary peer of disconnect and completed tabs keep themed glass', () => {
  const connect = read('New/HandsConnectDMView.swift');
  const connected = connect.slice(connect.indexOf('private var connected: some View'), connect.indexOf('private var disconnected: some View'));
  assert.match(connected, /DMPhoneCapsuleButton\(title: "完成", prominent: true/);
  assert.doesNotMatch(connected, /if !inSheet \{ dismissChip \}/);
  const browser = read('DM/DMBrowserView.swift');
  const cards = browser.slice(browser.indexOf('private func card(_ tab:'), browser.indexOf('private func status(_ tab:'));
  assert.match(cards, /liquidGlassPanelSurface\(cornerRadius: DMBrowserPhone\.tabCardRadius\)/);
  assert.doesNotMatch(cards, /controlBackgroundColor/);
  assert.doesNotMatch(read('DM/DMBrowser.swift'), /"完成・頁面已關閉"/);
});
test('M16 DM uses Chinese conversation labels and one Island approval action', () => {
  const ui = read('DM/GlobalDMView.swift') + read('DM/GlobalDMStore.swift') + read('DM/GlobalDMChatAcceptance.swift');
  assert.doesNotMatch(ui, /到 Island 查看|Coder session|其他專案的 session|搜尋專案或 session|這條 session/);
  assert.match(ui, /到 Island 核准/);
});
