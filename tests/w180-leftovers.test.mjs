import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W180 R2：剩下的舊樣式按鈕（D1）、Coder 權限鈕接到訊息所屬的討論串（D3）、啟動後清舊簽章副本（B3）的原始碼契約。
// 執行期行為（清副本的挑選、權限寫到哪一條）由 `TATWO2_SELFTEST=w180leftovers` 實際跑過。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};
const count = (source, text) => source.split(text).length - 1;

// MARK: D3

test('D3 ChatBubble carries the thread its message belongs to', () => {
  const leaf = read('Chat/ChatPageLeafViews.swift');
  const bubble = slice(leaf, 'struct ChatBubble: View {', 'private var resolvedAssistantRoute');
  assert.match(bubble, /let message: ChatMessage\n\s*\/\/[^\n]*\n\s*let threadID: UUID\?\n\s*\/\/[^\n]*\n\s*let mcpAllowBlockedNote: String\?/);
  // The approve button sends the tool together with that thread, never a bare tool name.
  const button = slice(leaf, 'if let tool = approvalActionTool {', '.accessibilityIdentifier("chat-mcp-approve-button")');
  assert.match(button, /NotificationCenter\.default\.post\(\s*name: \.tatwoChatAllowMCPTool,\s*object: ChatMCPAllowRequest\(tool: tool, threadID: threadID\)\)/);
  assert.doesNotMatch(button, /object: tool\)/);
  // A thread this Mac cannot write (the primary's, the remote one on screen) gets a plain line, not a dead button.
  const note = slice(button, 'if let note = mcpAllowBlockedNote {', '} else {');
  assert.match(note, /Text\(note\)/);
  assert.match(note, /\.accessibilityIdentifier\("chat-mcp-approve-unavailable"\)/);
  assert.doesNotMatch(note, /Button|NotificationCenter/);
  assert.ok(button.indexOf('if let note = mcpAllowBlockedNote {') < button.indexOf('Button {'), 'note is checked before the button is drawn');
  // Allowing only takes effect from the next message; nothing is re-run.
  assert.ok(button.includes('Text("允許 \\(ChatBubble.approvalToolDisplayName(tool))（下一句起生效）")'));
  assert.doesNotMatch(leaf, /並自動重試/);
  assert.match(leaf, /struct ChatMCPAllowRequest: Sendable \{\s*let tool: String\s*let threadID: UUID\?\s*\}/);
});

test('D3 both transcripts pass the thread they are drawing', () => {
  const transcript = read('Chat/ChatPage+Transcript.swift');
  assert.match(transcript, /TranscriptScrollView\(\s*threadID: model\.selectedThreadID,\s*mcpAllowBlockedNote: model\.mcpAllowBlockedNote\(threadID: model\.selectedThreadID\),/);
  const scroll = slice(transcript, 'private struct TranscriptScrollView: View {', '@State private var followState');
  assert.match(scroll, /let threadID: UUID\?/);
  assert.match(scroll, /let mcpAllowBlockedNote: String\?/);
  assert.match(transcript, /ChatBubble\(\s*message: message,\s*threadID: threadID,\s*mcpAllowBlockedNote: mcpAllowBlockedNote,/);
  const pane = read('Assistant/AssistantSpacePane.swift');
  const paneTranscript = slice(pane, 'private func transcript(column: CGFloat) -> some View {', 'return GeometryReader');
  assert.match(paneTranscript, /let threadID = model\.assistantTranscriptThreadID\s*let allowNote = model\.mcpAllowBlockedNote\(threadID: threadID\)/);
  assert.match(pane, /threadID: threadID, allowNote: allowNote\)/);
  assert.match(pane, /ChatBubble\(message: message, threadID: threadID, mcpAllowBlockedNote: allowNote,/);
  const model = read('Facade/ChatPageModel.swift');
  const owner = slice(model, 'var assistantTranscriptThreadID: UUID? {', '\n    }\n');
  assert.match(owner, /case \.primary\(_, let id, _\): return id/);
  assert.match(owner, /case \.local: return assistantThreadID/);
  assert.match(owner, /case \.unreachable: return nil/);
});

test('D3 allow writes the message thread, not the one Coder has selected', () => {
  const page = read('Chat/ChatPage.swift');
  const handler = slice(page, 'NotificationCenter.default.publisher(for: .tatwoChatAllowMCPTool)', '// 2026-08-24 D 工作流');
  assert.match(handler, /guard let request = notification\.object as\? ChatMCPAllowRequest else \{ return \}/);
  assert.match(handler, /model\.allowMCPTool\(named: request\.tool, threadID: request\.threadID\)/);
  const model = read('Facade/ChatPageModel.swift');
  const allow = slice(model, 'func allowMCPTool(named tool: String, threadID: UUID?) {', '\n    }\n');
  assert.doesNotMatch(code(allow), /selectedThreadID|selectedMCPEngine|availableThreadPluginEntries|setThreadPlugin\(|rejectRemoteWrite/);
  assert.match(allow, /let engine = mcpEngine\(for: threadID\)/);
  assert.match(allow, /localLive\.setEnabledMCP\(entry\.id, enabled: true, engine: engine, threadID: threadID\)/);
  assert.match(allow, /guard let threadID, canAllowMCP\(threadID: threadID\), let localLive else \{/);
  assert.doesNotMatch(allow, /遠端討論串不支援/);
  // One rule decides both the button and the write: only a thread in this Mac's own document.
  const can = slice(model, 'func canAllowMCP(threadID: UUID?) -> Bool {', '\n    }\n');
  assert.match(can, /guard isLive, let threadID, selectedRemote\?\.threadID != threadID,/, 'the remote thread on screen is refused');
  assert.match(can, /assistantPrimaryEngine\?\.doc\.assistantThreadID != threadID/, 'the primary\'s assistant thread is refused');
  assert.match(can, /return localLive\.threadRecord\(threadID\) != nil/, 'unknown threads are refused, not redirected');
  const note = slice(model, 'func mcpAllowBlockedNote(threadID: UUID?) -> String? {', '\n    }\n');
  assert.match(note, /if canAllowMCP\(threadID: threadID\) \{ return nil \}/);
  for (const text of ['"這條對話在主設備上，要到主設備放行"', '"這條對話在遠端設備上，要到那台放行"', '"找不到這則訊息所屬的對話，這裡沒辦法放行"']) {
    assert.ok(note.includes(text), text);
  }
  assert.equal(count(model, 'func allowMCPTool('), 1, 'no selected-thread overload left behind');
  // The selected-thread path (sidebar toggle) keeps its behaviour through the same engine lookup.
  assert.match(model, /private var selectedMCPEngine: PluginsSource\.MCPEngine \{ mcpEngine\(for: selectedThreadID\) \}/);
  const engine = read('Facade/ChatLiveEngine.swift');
  const target = slice(engine, 'func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine, threadID: UUID) {', '\n    }\n');
  assert.doesNotMatch(target, /selectedThreadID/);
  const selected = slice(engine, 'func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine) {', '\n    }\n');
  assert.match(selected, /guard let threadID = doc\.selectedThreadID else \{ return \}\s*setEnabledMCP\(pluginID, enabled: enabled, engine: engine, threadID: threadID\)/);
});

// MARK: D1

test('D1 Tatwo Island 重設 is a glass chip; the island settings page has no system buttons', () => {
  const island = read('New/TatwoIslandSettingsView.swift');
  const reset = slice(island, 'private var resetRow: some View', 'private func percent(');
  assert.match(reset, /OSChipButton\(title: "重設"\) \{ settings\.resetSizes\(\) \}\s*\.accessibilityLabel\(/);
  assert.doesNotMatch(code(island), /\.buttonStyle\(\.bordered|\.borderedProminent|confirmationDialog|NSAlert|\.alert\(/);
});

test('D1 設定 › OS: rules 接上 confirms inside the card with neutral glass chips', () => {
  const page = read('New/OSSettingsPage.swift');
  assert.doesNotMatch(code(page), /confirmationDialog|NSAlert|\.alert\(|\.buttonStyle\(\.bordered|\.borderedProminent/);
  // The row button and the setup banner's「接上 N 個」only ask; the confirm row does the work.
  assert.match(page, /OSChipButton\(title: "接上"\) \{ pendingLinks = \[row\] \}/);
  const banner = slice(page, '@ViewBuilder private var setupBanner', 'private func rowView(');
  assert.match(banner, /OSChipButton\(title: pending\.count > 1 \? "接上 \\\(pending\.count\) 個" : "接上", isPrimary: true\) \{\s*pendingLinks = pending\s*\}/);
  assert.doesNotMatch(banner, /EngineLinks\.link\(|linkRules\(/, 'the batch chip never links directly');
  assert.equal(count(code(page), 'EngineLinks.link('), 1, 'only linkRules (run from the confirm row) links');
  assert.equal(count(code(page), 'linkRules('), 2, 'one call (the confirm row) plus the definition');
  const confirm = slice(page, 'if !pendingLinks.isEmpty {', 'if let linkError {');
  for (const piece of ['Text("把 \\(pendingLinks.map(\\.name).joined(separator: "、")) 接上統一入口？")', 'archive/engine-rules',
    'OSChipButton(title: "取消") { pendingLinks = [] }', 'OSChipButton(title: "接上") { linkRules(pendingLinks) }',
    '.chatLiquidSection(cornerRadius: 12)', '.accessibilityIdentifier("tatwo.settings.rules.confirm")']) {
    assert.ok(confirm.includes(piece), piece);
  }
  assert.doesNotMatch(confirm, /isPrimary|brandAccent|SetupBanner/);
  const link = slice(page, 'private func linkRules(_ pending: [EngineLinkRow]) {', '\n    }\n');
  assert.match(link, /for row in pending \{ try EngineLinks\.link\(row\) \}/);
  assert.match(link, /pendingLinks = \[\]\s*rescan\(\)\s*SetupChecklist\.shared\.refresh\(logins: model\.engineLogins\)/);
});

test('D1 設定 › OS: a confirm row left open does not outlive what it asks about', () => {
  // The card rows are not modal: after linking another way and rescanning, rows already linked leave the question.
  const page = read('New/OSSettingsPage.swift');
  const rescan = slice(page, 'private func rescan() {', 'EngineMemoryWatcher.shared.start()');
  assert.match(rescan, /pendingLinks = pendingLinks\.compactMap \{ old in\s*rows\.first \{ \$0\.id == old\.id && \$0\.state == \.notLinked && !\$0\.links\.isEmpty \}\s*\}/);
  assert.match(rescan, /let wanted: EngineMemoryRow\.State = confirm\.restore \? \.linked : \.notLinked/);
  assert.match(rescan, /if !stillPending \{ memoryConfirm = nil \}/);
  assert.ok(rescan.indexOf('rows = EngineLinks.scan()') < rescan.indexOf('pendingLinks = pendingLinks.compactMap'));
  assert.ok(rescan.indexOf('memory = EngineMemoryLinks.scan()') < rescan.indexOf('if let confirm = memoryConfirm'));
});

test('D1 設定 › OS › 記憶「接上 N 個」asks in the same card row before linking', () => {
  const page = read('New/OSSettingsPage.swift');
  const memory = slice(page, '@ViewBuilder private var memorySection', 'private var memoryConfirmMessage');
  const banner = slice(memory, 'SetupBanner(done: memory.pending.isEmpty', 'VStack(spacing: 0)');
  assert.match(banner, /\{\s*memoryConfirm = MemoryConfirm\(linking: memory\.pending\)\s*\}/);
  assert.doesNotMatch(banner, /runMemory\(/, 'the batch chip never links directly');
  // Only the confirm row runs it, for every engine it lists.
  assert.equal(count(page, 'runMemory(restore: confirm.restore'), 1);
  assert.equal(count(page, 'runMemory('), 2, 'one call (the confirm row) plus the definition');
  assert.match(memory, /runMemory\(restore: confirm\.restore, engines: confirm\.engines\)/);
  assert.match(memory, /"讓 \\\(confirm\.names\) 共用 TATWO 的記憶？"/);
  const confirmType = slice(page, 'private struct MemoryConfirm {', '\n    }\n');
  assert.match(confirmType, /init\(linking rows: \[EngineMemoryRow\]\) \{ restore = false; self\.rows = rows \}/);
  assert.match(confirmType, /var engines: Set<EngineMemoryEngine> \{ Set\(rows\.map\(\\\.engine\)\) \}/);
  // Several at once: one plain sentence; the engineering detail stays with the single-row confirm.
  const message = slice(page, 'private var memoryConfirmMessage: String {', '\n    }\n');
  const batch = slice(message, 'if confirm.rows.count > 1 {', '}');
  assert.ok(batch.includes('"\\(confirm.names) 原本的記憶和設定會先備份到入口的 archive，設定只改共用記憶需要的那幾行，其他不動，隨時能還原。"'));
  assert.doesNotMatch(batch, /settings\.json|autoMemoryDirectory|config\.toml|\[features\]|generate_memories/);
  assert.match(message, /settings\.json[\s\S]*autoMemoryDirectory/, 'the single-row detail is kept');
});

test('D1 cold-start screen retries with a glass chip, not the blue system button', () => {
  const shell = read('Shell/AppShell.swift');
  const cold = slice(shell, 'Text("Chat 尚未完成安全恢復")', '.globalDMCovers(surface == .window');
  assert.match(cold, /OSChipButton\(title: "重試恢復"\) \{\s*chatModel\.retryColdStartHydration\(\)\s*\}\s*\.disabled\(/);
  assert.doesNotMatch(cold, /\.borderedProminent|\.buttonStyle\(\.bordered|Button\("重試恢復"\)/);
});

// 沒寫樣式的 Button 在 macOS 就是系統外框鈕（跟 .bordered 一樣）。這個小掃描器找出「自己的修飾鏈上沒有 .buttonStyle(」的 Button：
// 字串、註解先遮掉；Menu、contextMenu、alert、confirmationDialog 裡的 Button 是選單項或系統框的動作，另外列。
function maskSource(src) {
  const out = src.split('');
  const stack = [{ kind: 'code', depth: 0 }];
  for (let i = 0; i < src.length; i++) {
    const top = stack[stack.length - 1], c = src[i], nested = stack.length > 1;
    if (top.kind === 'code') {
      if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') out[i++] = ' '; i--; continue; }
      if (c === '/' && src[i + 1] === '*') {
        const close = src.indexOf('*/', i + 2), stop = close < 0 ? src.length : close + 2;
        for (; i < stop; i++) if (src[i] !== '\n') out[i] = ' ';
        i--; continue;
      }
      if (c === '"') {
        const width = src.startsWith('"""', i) ? 3 : 1;
        stack.push({ kind: width === 3 ? 'mstring' : 'string' });
        if (nested) for (let k = 0; k < width; k++) out[i + k] = ' ';
        i += width - 1; continue;
      }
      if (top.interp) {
        if (c === '(') top.depth++;
        else if (c === ')' && top.depth-- === 0) { out[i] = ' '; stack.pop(); continue; }
      }
      if (nested && c !== '\n') out[i] = ' ';
      continue;
    }
    if (c === '\\') {
      out[i] = ' ';
      if (src[i + 1] === '(') { out[i + 1] = ' '; i++; stack.push({ kind: 'code', depth: 0, interp: true }); continue; }
      if (src[i + 1] !== '\n') out[i + 1] = ' ';
      i++; continue;
    }
    const width = top.kind === 'string' ? 1 : 3;
    if (top.kind === 'string' ? c === '"' : src.startsWith('"""', i)) {
      stack.pop();
      if (stack.length > 1) for (let k = 0; k < width; k++) out[i + k] = ' ';
      i += width - 1; continue;
    }
    if (c !== '\n') out[i] = ' ';
  }
  return out.join('');
}
function skipGroup(src, i) {
  const open = src[i], close = open === '(' ? ')' : '}';
  for (let depth = 0; i < src.length; i++) {
    if (src[i] === open) depth++;
    else if (src[i] === close && --depth === 0) return i + 1;
  }
  return src.length;
}
const skipWs = (src, i) => { while (i < src.length && /\s/.test(src[i])) i++; return i; };
// A call's trailing closures (`{…}`, `label: {…}`, `message: {…}`); returns the index after them.
function trailingClosures(src, i) {
  let j = skipWs(src, i);
  if (src[j] === '{') { i = skipGroup(src, j); j = skipWs(src, i); }
  for (let m; (m = /^[A-Za-z_]+:\s*\{/.exec(src.slice(j, j + 40)));) { i = skipGroup(src, j + m[0].length - 1); j = skipWs(src, i); }
  return i;
}
// The modifier chain right after a view (`.x(…)`, `.x { … }`), as text.
function modifierChain(src, i) {
  const start = i;
  for (let m; (m = /^\s*\.([A-Za-z_]+)/.exec(src.slice(i, i + 80)));) {
    i += m[0].length;
    if (src[i] === '(') i = skipGroup(src, i);
    const k = skipWs(src, i);
    if (src[k] === '{' && !src.slice(i, k).includes('\n')) i = skipGroup(src, k);
  }
  return src.slice(start, i);
}
function unstyledButtons(source) {
  const masked = maskSource(source);
  const skipped = [];
  for (const re of [/\.(?:confirmationDialog|alert)\(/g, /\.contextMenu\s*[({]/g, /(?<![\w.])Menu\s*[({]/g]) {
    for (const m of masked.matchAll(re)) {
      const at = m.index + m[0].length - 1;
      skipped.push([m.index, trailingClosures(masked, masked[at] === '(' ? skipGroup(masked, at) : at)]);
    }
  }
  const lines = source.split('\n'), found = [];
  for (const m of masked.matchAll(/(?<![\w.])Button\s*[({]/g)) {
    if (skipped.some(([from, to]) => m.index > from && m.index < to)) continue;
    const at = m.index + m[0].length - 1;
    const end = trailingClosures(masked, masked[at] === '(' ? skipGroup(masked, at) : at);
    if (!/\.buttonStyle\(/.test(modifierChain(masked, end))) {
      const line = masked.slice(0, m.index).split('\n').length;
      found.push(`${line}: ${lines[line - 1].trim()}`);
    }
  }
  return found;
}

test('D1 scanner finds unstyled Buttons and skips styled ones, chips, menus and dialog actions', () => {
  const sample = [
    'HStack {',
    '    Button("a") { go() }',
    '    Button("b") { go() }.buttonStyle(.plain)',
    '    Button { go() } label: { Text("c") }',
    '        .disabled(x)',
    '        .buttonStyle(.borderless)',
    '    OSChipButton(title: "d") { go() }',
    '    Menu { Button("e") { } } label: { Text("f") }',
    '    Text("\\(flag ? "Button(" : "x") // not a comment")',
    '    // Button("g") in a comment',
    '    Button(role: .destructive) { go() } label: { Text("h") }',
    '}',
    '.confirmationDialog("q", isPresented: $p) { Button("i") { } } message: { Text("j") }',
    '.alert("k", isPresented: $p) { Button("l", role: .cancel) { } }',
  ].join('\n');
  assert.deepEqual(unstyledButtons(sample), ['2: Button("a") { go() }', '11: Button(role: .destructive) { go() } label: { Text("h") }']);
});

test('D1 sweep: settings cards have no system-framed buttons left (bordered or unstyled)', () => {
  // 設定 › 模型登入／Computer Use／設備／GitHub（含更新卡）／瀏覽器／Plugin 的 iPad USE、Tatwo Island、OS。
  // 沒寫樣式的 Button 在 macOS 跟 .bordered 一樣是系統外框鈕，同列擺在玻璃 chip 旁邊更顯眼，一起換掉。
  const cards = ['New/EngineLoginCard.swift', 'New/ComputerUseSettingsView.swift', 'New/DevicesCard.swift',
    'New/GitHubAccountsCard.swift', 'New/UpdateAvailableCard.swift', 'New/IPadUseSettingsView.swift',
    'Browser/BrowserManagementView.swift', 'New/TatwoIslandSettingsView.swift', 'New/OSSettingsPage.swift',
    // W183 R3：環境登入 › Cloudflare、TAP › ChatGPT 的「ChatGPT 手腳」、ⓘ 說明鈕。
    'New/CloudflareAccountsCard.swift', 'New/ChatGPTHandsSection.swift', 'New/OSInfoButton.swift', 'New/EnvironmentLoginPage.swift',
    // W183 R8a：ChatGPT build（TAP 一張卡＋節點流程）。
    'New/ChatGPTBuildSection.swift', 'New/ChatGPTBuildFlow.swift'];
  for (const file of cards) {
    assert.doesNotMatch(code(read(file)), /\.borderedProminent|\.buttonStyle\(\.bordered/, file);
    assert.deepEqual(unstyledButtons(read(file)), [], file);
  }
  // 設定 › Space：沒有 .bordered，但「+add」、上下移、搭建對話等還是系統鈕——使用者說 Space 的 UI 是甜蜜點不要破壞
  // （w171 鎖住版面），這輪列出不改。
  for (const file of ['Space/SpaceSetupPreviewView.swift', 'Space/SpaceLiveSetupView.swift']) {
    assert.doesNotMatch(code(read(file)), /\.borderedProminent|\.buttonStyle\(\.bordered/, file);
  }
  assert.match(read('New/UpdateAvailableCard.swift'), /OSChipButton\(title: updater\.updateMarkTitle, isPrimary: true\) \{\s*Task \{\s*await updater\.activateUpdateMark/);
  assert.match(read('New/UpdateAvailableCard.swift'), /OSChipButton\(title: "稍後"\) \{ checker\.dismissForLaunch\(\) \}\s*\.disabled\(updater\.phase == \.handedOff\)/);
  assert.match(read('New/IPadUseSettingsView.swift'), /OSChipButton\(title: "立即停止", role: \.destructive\) \{ controller\.stop\(\) \}/);
  assert.match(read('New/EngineLoginCard.swift'), /OSChipButton\(title: "登入", isPrimary: true\) \{ model\.loginEngine\(kind\) \}\s*\.disabled\(model\.engineLoginInProgress != nil\)/);
});

test('D1 glass chip looks disabled when disabled, and red when destructive', () => {
  const docs = read('New/OSDocumentsCard.swift');
  const chip = slice(docs, 'struct OSChipButton: View {', '/// W163 記憶提案');
  assert.match(chip, /var role: ButtonRole\? = nil\n\s*let action: \(\) -> Void/);
  assert.match(chip, /@Environment\(\\\.isEnabled\) private var isEnabled/);
  assert.match(chip, /Button\(role: role, action: action\)/);
  assert.match(chip, /\.foregroundStyle\(foreground\)/);
  assert.match(chip, /\.chatGlassChip\(isSelected: isPrimary && isEnabled\)/);
  // W205：停用只輕度淡化、字用可讀中性色（兩種主題對比 ≥4.5:1），不畫強調底；仍由 Button 拒絕操作。
  assert.match(chip, /if !isEnabled \{ return ChatGlassChipModifier\.chipForeground \}\s*if role == \.destructive \{ return ChatGlassChipModifier\.chipDestructiveForeground \}/);
  assert.match(chip, /\.buttonStyle\(ChatGlassChipButtonStyle\(\)\)/);
});

test('D1 inventory: system dialogs still on settings cards are exactly the listed ones', () => {
  // SwiftUI 的 .alert／.confirmationDialog 在 macOS 就是系統框（預設鈕藍色）。這輪列出不改，要不要改成卡片內確認列由主導決定：
  // 模型登入「確定要用掉一張重置券？」、GitHub「移除帳號…？」（github-settings-polish 鎖住）、設備「改成加入你已經有的那台？」（w171 鎖住）、
  // iPad USE 三個同意框、瀏覽器管理兩個刪除確認。
  const expected = {
    'New/EngineLoginCard.swift': ['.alert("確定要用掉一張重置券？"'],
    'New/GitHubAccountsCard.swift': ['.alert("移除帳號 \\(pendingRemoval ?? "")？"'],
    'New/DevicesCard.swift': [], // W187 moves role changes into the DM's physical confirmation card.
    'New/IPadUseSettingsView.swift': ['.confirmationDialog("連接並授權這台 iPad？"', '.confirmationDialog("授權目前討論串？"', '.confirmationDialog("建立 TATWO iPad use？"'],
    'Browser/BrowserManagementView.swift': ['.confirmationDialog(', '.confirmationDialog('],
    'New/ComputerUseSettingsView.swift': [], 'New/UpdateAvailableCard.swift': [], 'New/TatwoIslandSettingsView.swift': [],
    'New/OSSettingsPage.swift': [],
    'New/CloudflareAccountsCard.swift': [], 'New/ChatGPTHandsSection.swift': [], 'New/OSInfoButton.swift': [],   // W183 R3：確認用卡片內確認列
    'New/ChatGPTBuildSection.swift': [], 'New/ChatGPTBuildFlow.swift': [],   // W183 R8a
  };
  for (const [file, dialogs] of Object.entries(expected)) {
    const source = code(read(file));
    assert.doesNotMatch(source, /NSAlert/, file);
    const found = [...source.matchAll(/\.(?:alert|confirmationDialog)\([^\n]*/g)].map((m) => m[0]);
    assert.equal(found.length, dialogs.length, `${file}: ${found.join(' | ')}`);
    dialogs.forEach((start, index) => assert.ok(found[index].startsWith(start), `${file}: ${found[index]}`));
  }
  const flow = read('New/DeviceFlowCards.swift');
  assert.match(flow, /action\("加入", primary: true, enabled: session\.code\.count == 6\) \{ await session\.joinFromCard\(\$0\) \}/);
  assert.match(flow, /OSChipButton\(title: "取消"\) \{ session\.close\(\) \}\.disabled\(session\.busy\)/);
  assert.match(read('DM/DeviceFlowSession.swift'), /func joinFromCard\(_ authority: DeviceFlowUserAction\) async \{\s*guard authority\.consume\(for: self\) else \{ return \}/);
});

// MARK: B3

test('B3 cleaner only touches the App clone folder and keeps the newest and the running copy', () => {
  const cleaner = read('Facade/CodeSignCloneCleaner.swift');
  assert.match(cleaner, /static let bundleID = "ai\.tatwo\.tatwo2"/);
  assert.match(cleaner, /static let folderName = bundleID \+ "\.code_sign_clone"/);
  assert.match(cleaner, /static let clonePrefix = "code_sign_clone\."/);
  // Folder: DARWIN_USER_TEMP_DIR (not TMPDIR) → ../X/<bundle id>.code_sign_clone.
  assert.match(cleaner, /confstr\(_CS_DARWIN_USER_TEMP_DIR/);
  assert.match(slice(cleaner, 'static func folder(userTempDirectory: String) -> URL {', '\n    }\n'),
    /\.deletingLastPathComponent\(\)\s*\.appendingPathComponent\("X", isDirectory: true\)\s*\.appendingPathComponent\(folderName, isDirectory: true\)/);
  // Exactly one delete, inside clean(), after re-checking it is a direct child clone folder (not a symlink).
  assert.equal(count(code(cleaner), 'removeItem('), 1);
  const clean = slice(cleaner, 'static func clean(folder: URL', '\n    // MARK: 紀錄');
  assert.ok(clean.includes('try FileManager.default.removeItem(at: candidate.url)'));
  assert.match(clean, /path\.hasPrefix\(base\), !path\.dropFirst\(base\.count\)\.contains\("\/"\), name\.hasPrefix\(clonePrefix\)/);
  assert.match(clean, /lstat\(path, &info\) == 0, \(info\.st_mode & S_IFMT\) == S_IFDIR/);
  assert.match(clean, /guard running != nil else \{/);
  assert.doesNotMatch(code(cleaner), /\.moveItem\(|trashItem|createSymbolicLink|Process\(|install\.sh|\/Applications/);
  // Selection: newest, the running copy (same executable file), or younger than 10 minutes stay; unknown running copy keeps all.
  const plan = slice(cleaner, 'static func plan(', '\n    // MARK: 找資料夾');
  assert.match(plan, /guard let running else \{\s*plan\.keep = ordered\s*return plan\s*\}/);
  assert.match(plan, /let isNewest = index == 0/);
  assert.match(plan, /let inUse = candidate\.executables\.contains\(running\)/);
  assert.match(plan, /if isNewest \|\| inUse \|\| isRecent \{ plan\.keep\.append\(candidate\) \} else \{ plan\.remove\.append\(candidate\) \}/);
  assert.match(cleaner, /static let recentGuard: TimeInterval = 600/);
  // Scan never follows symlinks.
  assert.match(slice(cleaner, 'static func scan(folder: URL', '\n    static func clean('), /lstat\(url\.path, &info\) == 0, \(info\.st_mode & S_IFMT\) == S_IFDIR/);
});

test('B3 runs once per installed build, after the App has been up for a while, off the main thread; one log line', () => {
  const cleaner = read('Facade/CodeSignCloneCleaner.swift');
  const schedule = slice(cleaner, '@MainActor static func scheduleAfterLaunch(', '\n    }\n}');
  for (const piece of ['guard !scheduled else { return }', 'environment["TATWO2_SELFTEST"] == nil', 'Bundle.main.bundleIdentifier == bundleID',
    'let running = FileIdentity.of(executable.path)', 'guard UserDefaults.standard.string(forKey: cleanedKey) != stamp else { return }',
    'DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + launchDelay)', 'UserDefaults.standard.set(stamp, forKey: Self.cleanedKey)',
    'Self.appendLog("build \\(build) " + outcome.logLine, in: logs)']) {
    assert.ok(schedule.includes(piece), piece);
  }
  assert.match(cleaner, /static let launchDelay: TimeInterval = 120/);
  assert.match(cleaner, /appendingPathComponent\("tatwo2\/logs", isDirectory: true\)/);
  assert.match(cleaner, /appendingPathComponent\("code-sign-clone\.log"\)/);
  // One call site, right after the first frame's launch sweep; install.sh is untouched (it must stay byte-identical to public/).
  const shell = read('Shell/AppShell.swift');
  assert.equal(count(shell, 'CodeSignCloneCleaner.scheduleAfterLaunch()'), 1);
  assert.match(shell, /reason: "first-frame-presented"\)\s*\/\/[^\n]*\n\s*CodeSignCloneCleaner\.scheduleAfterLaunch\(\)/);
  const root = (name) => readFileSync(new URL('../' + name, import.meta.url));
  assert.deepEqual(root('install.sh'), root('public/install.sh'));
});

test('w180leftovers self-test entry covers the clone picker and the thread source', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w180leftovers" \{[\s\S]{0,200}W180LeftoversAcceptance\.run\(\)/);
  const acceptance = read('Facade/W180LeftoversAcceptance.swift');
  assert.ok(acceptance.startsWith('#if DEBUG'));
  assert.ok(acceptance.includes('W180LEFTOVERS SUMMARY failures='));
  for (const label of ['B3 plan removes only the old ones', 'B3 plan keeps the newest and the one in use', 'B3 running copy unknown: keep everything',
    'B3 clones younger than 10 minutes are kept', 'B3 symlink and what it points to are untouched', 'B3 on disk: old ones gone, newest and in-use stay',
    'D3 engine: allow lands on the given thread', 'D3 model: allow writes the thread the message belongs to (its own engine)',
    'D3 model: Coder\'s selected thread is untouched', 'D3 model: allow from the TATWO pane writes the assistant thread, not Coder\'s',
    'D3 model: a thread of this Mac gets the allow button',
    'D3 model: the remote thread on screen is refused even when this Mac keeps a copy with the same id',
    'D3 TATWO pane draws the primary\'s assistant thread',
    'D3 model: the primary\'s assistant thread is refused even when this Mac has a thread with the same id']) {
    assert.ok(acceptance.includes(label), label);
  }
  // It only writes inside the isolated staging roots or its own temp folder.
  assert.match(acceptance, /guard NativeStagingIsolation\.isEnabled\(env\), NativeStagingIsolation\.validationError\(env\) == nil/);
  assert.doesNotMatch(acceptance, /"\/Applications|NSHomeDirectory|userTempDirectory: Cleaner\.userTempDirectory/);
  // The remote and primary cases are set up in memory only (selectedRemote, the primary test double) and put back afterwards.
  assert.match(acceptance, /model\.selectedRemote = \(deviceID: "w180-fake-remote", threadID: messageThread\)[\s\S]*model\.selectedRemote = nil/);
  assert.match(acceptance, /model\.assistantPrimaryTestDouble = \(device:[\s\S]*model\.assistantPrimaryTestDouble = nil/);
});
