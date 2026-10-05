import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

// .052 實機（mini，10-03）：ChatGPT Space 送兩段文字第一次一定失敗——等送出鍵的迴圈還在逐字比對輸入框文字。
test('TAP never compares composer text byte for byte; every check ignores rewritten whitespace', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  assert.doesNotMatch(tap, /composerText\([^)]*\)\s*[!=]==\s*wanted/);
  assert.match(tap, /chatForm\(current\) !== form \|\| !sameText\(composerText\(current\), wanted\)/);
  assert.ok((tap.match(/sameText\(composerText\(/g) ?? []).length >= 4);
});

// .052 實機：休眠時在 Coder 模式卡選 ChatGPT 模型沒有反應——模式卡呼叫的 selectRouteChoice 還用舊檢查。
test('every model-selection entry point lets a sleeping ChatGPT model through and wakes it', () => {
  const composer = read('Chat/ChatPage+Composer.swift');
  const select = composer.slice(composer.indexOf('func selectRouteChoice('), composer.indexOf('func modelPickerInlineRouteRow('));
  assert.match(select, /model\.tapModelSelectionUnavailableReason\(choice\)/);
  assert.doesNotMatch(select, /model\.tapModelUnavailableReason\(choice\)/);
  assert.match(select, /guard model\.prepareTapSelection\(choice\) else \{ return \}/);
  assert.match(composer, /chooseModel: \{ selectRouteChoice\(\$0\) \}/);
  const model = read('Facade/ChatPageModel.swift');
  const start = model.indexOf('func setSingleModel(');
  const single = model.slice(start, model.indexOf('if isRunning {', start));
  assert.match(single, /guard prepareTapSelection\(choice\) else \{ return \}/);
  const prepare = model.slice(model.indexOf('func prepareTapSelection('), model.indexOf('private func wakeChatGPTForModelSelection('));
  assert.match(prepare, /chatGPTTapConnection == \.sleeping/);
  assert.match(prepare, /wakeChatGPTForModelSelection\(\)/);
});

// .052 Claude 驗收：喚醒後狀態馬上變 starting，模式卡下一輪套用時不能被「啟動中」擋回，清單也不能被清空。
test('a ChatGPT model chosen while it is still starting is kept, and the list survives the wake', () => {
  const model = read('Facade/ChatPageModel.swift');
  const selection = model.slice(model.indexOf('func tapModelSelectionUnavailableReason('), model.indexOf('func prepareTapSelection('));
  assert.match(selection, /chatGPTTapConnection == \.sleeping \|\| chatGPTTapConnection == \.starting \{ return nil \}/);
  const catalog = read('Chat/ChatGPTTapModelCatalog.swift');
  assert.match(catalog, /if connection != \.sleeping, connection != \.starting \{ ChatGPTTapModelCatalog\.replace\(\[\]\) \}/);
  assert.match(read('Facade/ChatGPTTapAcceptance.swift'), /M15 model card path: choosing while ChatGPT is still starting keeps the choice/);
});
