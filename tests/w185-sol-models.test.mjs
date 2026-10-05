import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const routes = read('Chat/TatwoChatRouteProfile.swift');
const model = read('Facade/ChatPageModel.swift');
const engine = read('Facade/ChatLiveEngine.swift');
const preferences = read('Chat/ChatModelPreferences.swift');
const ids = ['gpt-6.1-sol', 'gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna'];
const catalog = routes.split('public static let defaults:')[1].split('private static func normalizedLookupKey')[0];

test('W185 all GPT-6 routes lead the picker; previous routes remain selectable', () => {
  const actual = [...catalog.matchAll(/id: "([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(actual, [...ids, 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna',
    'grok-build', 'fable5.1', 'sonnet5', 'opus5.5', 'codex-auto-review']);
  assert.equal(new Set(actual).size, actual.length);
  assert.ok(!actual.includes('gpt-6-pro'));
  for (const id of ids) {
    const profile = catalog.split(`id: "${id}",`)[1].split('notes:')[0];
    assert.ok(profile.includes(`modelArgument: "${id}"`));
    assert.match(profile, /defaultSpeedTier: \.fast,\s*allowedSpeedTiers: \[\.fast, \.standard\]/);
    const levels = ['low', 'medium', 'high', 'xhigh', 'max', ...(id === 'gpt-6-luna' ? [] : ['ultra'])];
    assert.deepEqual([...profile.match(/allowedEfforts: \[([^\]]+)\]/)[1].matchAll(/\.(\w+)/g)].map(m => m[1]), levels);
  }
  const sol = catalog.split('id: "gpt-6.1-sol",')[1].split('notes:')[0];
  assert.match(sol, /displayName: "GPT-6\.1 Sol"/);
  assert.match(sol, /contextWindowLabel: "272k"/);
  assert.match(sol, /defaultEffort: \.low/);
  assert.match(catalog.split('id: "gpt-6-sol",')[1].split('notes:')[0], /defaultEffort: \.medium/);
});

test('W185 Coder initialization and hydration use Sol medium Fast, preserving explicit controls', () => {
  assert.match(model, /@Published var selectedModel = "gpt-6\.1-sol"/);
  assert.match(model, /selectedModel = "gpt-6\.1-sol"\s*selectedEffort = \.medium\s*selectedSpeedTier = \.fast/);
  assert.match(preferences, /thread\?\.requestedModel \?\? thread\?\.model \?\? "gpt-6\.1-sol"/);
  assert.match(preferences, /route.id == "gpt-6\.1-sol" \? TatwoCodexReasoningEffort.medium : route.defaultEffort/);
  assert.match(model, /ChatModelPreferences.selection\(thread/);
  assert.match(model, /Rate limit reached for gpt-6-astra: weekly limit exhausted/);
});

test('W185 live turns recognize all four GPT-6 models even without a supplied model', () => {
  assert.match(engine, /ChatRouteChoice\.resolve\(model \?\? thread\?\.requestedModel \?\? thread\?\.model \?\? "gpt-6\.1-sol", deviceID: thread\?\.deviceID \?\? "local"\)/);
  assert.ok(engine.includes(`let usesGPT6Defaults = [${ids.map(id => `"${id}"`).join(', ')}].contains(route.id)`));
  assert.match(engine, /reasoningEffort \?\? thread\?\.requestedEffort \?\? \(usesGPT6Defaults \? "medium" : nil\)/);
  assert.match(engine, /serviceTier \?\? thread\?\.requestedSpeedTier[\s\S]{0,180}usesGPT6Defaults \? TatwoModelSpeedTier\.fast\.appServerValue : nil/);
  assert.match(engine, /model \?\? thread\.requestedModel \?\? thread\.model \?\? "gpt-6\.1-sol"/);
});

test('W185 ultrawork changes only fallback roles, not saved configuration', () => {
  const roles = read('Chat/UltraworkRoleConfiguration.swift');
  for (const [role, id] of [['lead', 'fable-5.1'], ['loops', 'gpt-6.1-sol'],
    ['refinement', 'opus-5.5'], ['mechanic', 'grok-build'], ['reviewer', 'gpt-6.1-sol']]) {
    assert.ok(roles.includes(`${role}: "${id}"`));
  }
  assert.match(roles, /static let appWideKey = "tatwo\.ultrawork\.last-role-configuration\.v1"/);
  assert.match(roles, /func load\(\)[\s\S]*?JSONDecoder\(\)\.decode[\s\S]*?return \.defaultValue\s*\}\s*return value/);
  assert.ok(!roles.includes('retiredReplacements'));
});

test('W185 trait lists, task fallback and collaboration labels include new models', () => {
  const traits = read('Pages/TraitsPage.swift');
  assert.match(traits, /selectedSecondaryModelID = "gpt-6\.1-sol"/);
  for (const id of ids) {
    assert.ok(read('Facade/ModesStubs.swift').includes(`trait("${id}"`));
    assert.equal(traits.split(`"${id}",`).length - 1, 2);
    assert.ok(read('Chat/ChatPage+Collaboration.swift').includes(`case "${id}": return`));
  }
  assert.match(read('Pages/TraitCardsSection.swift'), /if key\.contains\("gpt-6"\) \{ return \.green \}/);
  assert.match(read('Facade/RunTask.swift'), /spec\["route"\] as\? String \?\? "gpt-6\.1-sol"/);
});
