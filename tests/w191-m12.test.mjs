import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('M12 empty projects hide the room and visible receipts use plain labels and glass', () => {
  const row = read('Chat/ChatGPTRoomRow.swift');
  assert.match(row, /if !calls\.isEmpty/);
  assert.match(row, /chatGlassChip\(\)/);
  assert.match(row, /row\.toolTitle/);
  assert.match(row, /row\.approvalTitle/);
  assert.doesNotMatch(row, /row\.grantTag|Text\(row\.tool\)|Text\("CU 核准/);
  assert.doesNotMatch(row, /Text\("App：已核准的 App"\)/);
  assert.match(row, /HandsRoomJournal\.didChange/);
});
test('M12 receipt summaries translate known machine statuses before display', () => {
  const row = read('Chat/ChatGPTRoomRow.swift');
  assert.match(row, /row\.summaryTitle/);
  assert.doesNotMatch(row, /Text\(row\.summary\)/);
});
