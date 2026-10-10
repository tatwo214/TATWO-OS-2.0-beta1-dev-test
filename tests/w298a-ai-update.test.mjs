import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { codexModels, claudeModels } from '../Engines/model-capabilities.mjs';
import { nativeW298a } from './fixtures/w298a-native.mjs';

test('W298a synthetic sources, model retirement, rules, real approval buttons and six native screenshots', () => {
  const output = nativeW298a();
  for (const label of ['new version', 'already latest', 'latest lookup fails',
    'same suffix newest numeric version', 'Claude same series', 'fallback provider default', 'needs user selection',
    'new 1 retired 2 duplicate 1 counted accurately', 'Coder menu replaced',
    'retired conversation uses provider default', 'accept saves actual role configuration',
    'accept updates os through document writer', 'accept document writer backs up os before change',
    'retired dispatch refused', 'dispatch refusal creates no child or worktree']) {
    assert.ok(output.includes(`W298A PASS ${label}`), label);
  }
});

test('native Codex catalog preserves new official ID and excludes hidden models without guessing capabilities', () => {
  const rows = codexModels([
    { model: 'gpt-6.10-sol', displayName: 'Sol 6.10', supportedReasoningEfforts: [{reasoningEffort: 'high'}], inputModalities: ['text'] },
    { model: 'retired-hidden', hidden: true },
  ]);
  assert.deepEqual(rows, [{ model: 'gpt-6.10-sol', displayName: 'Sol 6.10', efforts: ['high'], defaultEffort: '', speeds: [], defaultSpeed: '', images: false }]);
});

test('Claude native resolvedModel is authoritative and duplicate effort levels normalize once', () => {
  const rows = claudeModels([{value: 'fable', resolvedModel: 'claude-fable-6-1', supportedEffortLevels: ['high', 'high'], supportsFastMode: false}]);
  assert.equal(rows[0].model, 'claude-fable-6-1');
  assert.deepEqual(rows[0].efforts, ['high']);
  assert.deepEqual(rows[0].speeds, []);
});

test('W350 routine settings and startup reads keep signature cache; explicit check forces verification', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/EngineAIUpdate.swift', 'utf8');
  assert.match(source, /func refreshLocalVersions\(paths: EnginePaths = EnginePaths\(\), forceVerification: Bool = false\)/);
  assert.match(source, /static func read\(_ kind: ClaudeSidecar.Kind, versionsOnly: Bool = false, forceVerification: Bool = false\)/);
  assert.match(source, /Self.read\(\$0, versionsOnly: selection == nil, forceVerification: selection == nil\)/);
  for (const path of ['New/EngineLoginCard.swift', 'Tatwo2App.swift']) {
    assert.doesNotMatch(readFileSync('App/Sources/Tatwo2/' + path, 'utf8'), /forceVerification: true/);
  }
});
