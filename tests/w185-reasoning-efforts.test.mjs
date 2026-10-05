import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const effort = read('Chat/TatwoCodexReasoningEffort.swift');
const routes = read('Chat/TatwoChatRouteProfile.swift');
const mode = read('Chat/TatwoComposerMode.swift');
const card = read('Chat/TatwoComposerModeCard.swift');
const model = read('Facade/ChatPageModel.swift');
const engine = read('Facade/ChatLiveEngine.swift');
const acceptance = read('Facade/ModelPreferencesAcceptance.swift');
// Evidence: strings from codex-cli 0.160.0 standalone arm64 binary,
// supported_reasoning_levels (not model_messages.instructions_template).
const catalog = routes.split('public static let defaults:')[1].split('private static func normalizedLookupKey')[0];
const base = ['low', 'medium', 'high', 'xhigh'];
const supported = {
  'gpt-6.1-sol': [...base, 'max', 'ultra'],
  'gpt-6-sol': [...base, 'max', 'ultra'],
  'gpt-6-astra': [...base, 'max', 'ultra'],
  'gpt-6-luna': [...base, 'max'],
  'gpt-5.6-sol': [...base, 'max', 'ultra'],
  'gpt-5.6-terra': [...base, 'max', 'ultra'],
  'gpt-5.6-luna': [...base, 'max'],
  'codex-auto-review': [...base, 'max', 'ultra'],
};

test('W185 M2 route capabilities exactly match Codex 0.160 built-in levels; old models stay unchanged', () => {
  const profiles = [...catalog.matchAll(/id: "([^"]+)"[\s\S]*?allowedEfforts: \[([^\]]*)\]/g)];
  assert.equal(profiles.length, 12);
  for (const [, id, raw] of profiles) {
    assert.deepEqual([...raw.matchAll(/\.(\w+)/g)].map(m => m[1]), supported[id] ?? base, id);
  }
});

test('W185 M2 extended values retain Codex/gateway spelling and cap Claude at existing xhigh', () => {
  assert.match(effort, /case max\s+case ultra/);
  assert.match(effort, /case \.max: return "最高"/);
  assert.match(effort, /case \.ultra: return "Ultra（自動分派）"/);
  assert.match(effort, /case \.max, \.ultra: return "xhigh"/);
  for (const level of ['max', 'ultra']) {
    assert.equal(effort.split(`case .${level}: return "${level}"`).length - 1, 2);
  }
  assert.ok(effort.includes('["-c", "model_reasoning_effort=\\"\\(codexRawValue)\\""]'));
  assert.ok(acceptance.includes('effort.codexArguments == ["-c", "model_reasoning_effort=\\"\\(effort.rawValue)\\""]'));
});

test('W185 M2 S/M/L/XL/XXL map to low/medium/high/xhigh/max, with legacy XXL fallback', () => {
  for (const [level, value] of [['s', 'low'], ['m', 'medium'], ['l', 'high'], ['xl', 'xhigh']]) {
    assert.ok(mode.includes(`case .${level}: requested = .${value}`));
  }
  assert.ok(mode.includes('case .xxl: requested = route.allowedEfforts.contains(.max) ? .max : .xhigh'));
  assert.ok(mode.includes('model.setCollaborationLevel($0)'));
  assert.ok(mode.includes('collaborationEffort($0, route: model.routeChoice) { model.selectedEffort = effort }'));
  assert.ok(mode.includes('dmSetPreferences(model: model, threadID: local, route: route, speed: nil, effort: effort)'));
  assert.ok(acceptance.includes('real card \\(level.title) persists \\(effort.rawValue)'));
});

test('W185 M2 Ultra is the explicit last glass stop, excluded from pointer and keyboard sliders, with quota warning', () => {
  assert.ok(mode.includes('options.filter { $0.id != TatwoCodexReasoningEffort.ultra.rawValue }'));
  assert.ok(card.includes('titles: steps.sliderOptions.map(\\.title)'));
  assert.ok(card.includes('selectedIndex: steps.sliderSelectedIndex'));
  assert.ok(card.includes('stepsFor(id)?.sliderOptions.count'));
  assert.ok(card.includes('steps.choose(steps.sliderOptions[index].id)'));
  assert.ok(card.includes('if steps.hasUltra {'));
  assert.ok(card.includes('Button("Ultra")'));
  assert.ok(card.includes('steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue'));
  assert.ok(!card.includes('Menu(steps.selectedTitle'));
  assert.ok(card.includes('.disabled(!steps.isEnabled)'));
  assert.ok(mode.includes('會自動分派子代理，較耗額度'));
  assert.ok(card.includes('noteLine(TatwoComposerMode.ultraWarning)'));
});

test('W185 M2 unsupported extended values are capped at hydration, switching, persistence, send and native goal', () => {
  assert.ok(routes.includes('TatwoCodexReasoningEffort.allCases.last { allowedEfforts.contains($0) }'));
  assert.ok(routes.includes('requested == .max || requested == .ultra else { return raw }'));
  assert.ok(routes.includes('return nativeReasoningEffort(for: requested)?.codexRawValue'));
  assert.ok(model.includes('if !restoringModelPreferences { normalizeExtendedReasoningEffort() }'));
  assert.ok(model.includes('profile.nativeReasoningEffort(for: selectedEffort) ?? profile.defaultEffort'));
  assert.ok(model.includes('flashComposerHint(notice)'));
  assert.ok(model.includes('reasoningAfterModelSwitch(route, stored: record.requestedEffort)'));
  assert.ok(engine.includes('profile.runtimeAdapter == .chatgptTap ? effort'));
  assert.ok(engine.includes(': profile.compatibleReasoningValue(effort)'));
  assert.ok(engine.includes('let effort = route.profile.compatibleReasoningValue(requestedEffort)'));
  assert.ok(engine.includes('choice.profile.compatibleReasoningValue(thread.requestedEffort'));
  assert.ok(acceptance.includes('survives store reload and model hydration'));
  assert.ok(acceptance.includes('Codable round trip'));
  assert.ok(acceptance.includes('downgrades on model switch with visible explanation'));
  assert.ok(acceptance.includes('Ultra → Luna becomes max, not default medium'));
});
