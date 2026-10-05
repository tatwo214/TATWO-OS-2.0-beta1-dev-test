import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = file => readFileSync(new URL('../App/Sources/Tatwo2/' + file, import.meta.url), 'utf8');

test('W192-04 executable diagnostics stay inside collapsed details', () => {
  const card = read('New/EngineLoginCard.swift');
  assert.match(card, /DisclosureGroup\("詳細", isExpanded:/);
  assert.match(card, /Text\(Self\.runtimeSummary\(choice\)\)/);
  assert.match(card, /DisclosureGroup\("詳細", isExpanded:[\s\S]*?Text\(choice\.summary\)/);
  assert.doesNotMatch(card, /Developer ID|Team ID|\bCLI\b/);
});
test('W192-05 PR confirmation and submit use glass chips without blue prominent style', () => {
  const actions = read('Chat/PRPlanActions.swift');
  assert.doesNotMatch(actions, /borderedProminent|Color\.accentColor|\.blue\b/);
  for (const id of ['pr-plan-submit', 'pr-plan-confirm']) {
    assert.match(actions, new RegExp('chatGlassChip\\(\\)[\\s\\S]{0,450}accessibilityIdentifier\\("' + id + '"\\)'));
  }
});
test('W192-06 assistant guidance reflects full connection and current product names', () => {
  const persona = read('Resources/tatwo-assistant.md');
  assert.match(persona, /連上＝全開/);
  assert.doesNotMatch(persona, /session|TAP › ChatGPT|等級（L0／L1／L2）與允許的專案由使用者/);
  assert.match(persona, /你不能代替使用者核准/);
  assert.match(persona, /金鑰、憑證、通道 token 你讀不到/);
});
test('W192-02 read-only warning appears above composer; restore requires confirmation and date', () => {
  assert.match(read('Chat/ChatPage+Composer.swift'), /model\.localConversationReadOnlyNotice/);
  assert.match(read('Chat/ChatPage+Transcript.swift'), /alert\("還原對話紀錄？"/);
  assert.match(read('Chat/ChatPage+Transcript.swift'), /副本日期/);
  assert.match(read('Facade/ChatPageModel.swift'), /唯讀中，不能送出/);
});
test('W192-07 model catalog launches once at startup and is independent of login refresh', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.equal((model.match(/EngineModelCatalogProbe\.shared\.refresh/g) ?? []).length, 1);
  assert.match(model, /refreshEngineModelCatalogOnce\(\)/);
  const refresh = model.slice(model.indexOf('func refreshEngineLogins()'), model.indexOf('func loginEngine('));
  assert.doesNotMatch(refresh, /EngineModelCatalogProbe/);
  const send = model.slice(model.indexOf('private func sendLoginStatus('), model.indexOf('private var dmKnownDeviceIDs'));
  assert.ok(send.indexOf('return cached') < send.indexOf('refreshEngineLogins()'));
  // Unknown or expired login must not bounce the send (the refresh is asynchronous); the engine confirms and a
  // real login rejection carries the 模型登入 exit. A known logged-out result still blocks (cache-first above).
  assert.match(send, /isLoggedIn: true, account: nil, detail: "登入狀態待引擎確認"/);
});
