import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('M13 Island uses the resolved application name while authorization keeps the bundle ID', () => {
  const island = read('New/ComputerUseConsentPrompt.swift');
  const session = read('New/ComputerUseExternalSession.swift');
  assert.match(island, /request\.appDisplayName/);
  assert.doesNotMatch(island, /Text\("ChatGPT 正在操作〈\\\(request\.app\)/);
  assert.match(session, /appDisplayName: application\.name/);
  assert.match(session, /backend\.start\([^\n]*app: app/);
});
