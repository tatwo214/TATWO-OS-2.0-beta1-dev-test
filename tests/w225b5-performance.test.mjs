import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync(new URL('../App/Sources/Tatwo2/Facade/GroupCoderBridge.swift', import.meta.url), 'utf8');
test('W225b5-5 admits a group before classifying only the current project', () => {
  assert.ok(bridge.indexOf('guard sessions[threadID]') < bridge.indexOf('HandsTradingFloor.classify'), 'plain sends must skip project filesystem classification');
  assert.ok(!bridge.includes('owner.doc.projects.map'), 'must not classify every project directory');
  assert.ok(bridge.includes('HandsTradingFloor.classify'), 'existing trading refusal must remain');
});
test('W225b5-5 tool-step recording never sorts the transcript', () => {
  const step = bridge.slice(bridge.indexOf('func recordStep('), bridge.indexOf('@discardableResult func stop('));
  assert.ok(!step.includes('GroupSessionCursor.rows'), 'tool-step cursor uses a visible row count');
  assert.match(bridge, /group\.rowCount = .*GroupSessionCursor\.count/, 'event recording must not sort merely to count rows');
});
