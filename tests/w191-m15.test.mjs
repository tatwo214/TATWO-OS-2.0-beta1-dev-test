import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const between = (s, a, b) => s.slice(s.indexOf(a), s.indexOf(b, s.indexOf(a) + a.length));
test('M15 unavailable reasons are plain and the mode card offers an open ChatGPT action', () => {
  const catalog = read('Chat/ChatGPTTapModelCatalog.swift');
  assert.doesNotMatch(between(catalog, 'static func unavailabilityReason(', 'static func defaultEffort'), /Pod|TAP/);
  const mode = read('Chat/ChatPage+Composer.swift');
  assert.match(mode, /mode\.modelNoteAction = /);
  assert.match(read('Chat/TatwoComposerModeCard.swift'), /title: "打開 ChatGPT"/);
});
test('M15 selecting a sleeping model wakes it, while send admission stays separate', () => {
  const model = read('Facade/ChatPageModel.swift');
  const choose = between(model, 'func setSingleModel(', 'func restoreModelPreferences()');
  assert.match(choose, /tapModelSelectionUnavailableReason\(choice\)/);
  // The wake moved into prepareTapSelection so the model card (selectRouteChoice) shares it (.052 real device).
  assert.match(choose, /guard prepareTapSelection\(choice\) else \{ return \}/);
  const prepare = between(model, 'func prepareTapSelection(', 'private func wakeChatGPTForModelSelection(');
  assert.match(prepare, /chatGPTTapConnection == \.sleeping[\s\S]*wakeChatGPTForModelSelection\(\)/);
  assert.match(model, /private func tapSendUnavailableReason/);
});
test('M15 model card hides route IDs and localizes native effort titles', () => {
  const mode = between(read('Chat/ChatPage+Composer.swift'), 'static func tapAwareCoderMode(', 'func modelCollaborationComposerPill');
  assert.match(mode, /detail: isTap \? nil : row\.detail/);
  assert.match(mode, /title: ChatGPTTapModelCatalog\.effortTitle\(\$0\)/);
  assert.doesNotMatch(mode, /"ChatGPT TAP"|"ChatGPT（TAP）：/);
});
