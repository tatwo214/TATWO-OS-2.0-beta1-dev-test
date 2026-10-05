import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL('../App/Sources/Tatwo2/' + path, import.meta.url), 'utf8');
const composer = read('Chat/ChatPage+Composer.swift');
const model = read('Facade/ChatPageModel.swift');
const catalog = read('Chat/ChatGPTTapModelCatalog.swift');
const acceptance = read('Facade/ChatGPTTapAcceptance.swift');
const section = (source, start, end) => {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `${start} exists before ${end}`);
  return source.slice(a, b);
};

test('actual Coder mode card is TAP-aware, greys every TAP option and explains why', () => {
  const mode = section(composer, 'func coderComposerMode(', 'func modelCollaborationComposerPill');
  assert.match(mode, /Self\.tapAwareCoderMode\(mode, model: model/);
  assert.match(mode, /guard option\.brand == \.chatgptTap/);
  assert.match(mode, /isDisabled: reason != nil/);
  assert.match(mode, /title: reason\.map \{ "\\?\(option\.title\) · \\?\(\$0\)" \}/);
  assert.match(mode, /mode\.modelNote = /);
  const row = section(composer, 'func modelPickerInlineRouteRow(', 'func modelPickerTapEffortRow');
  assert.match(row, /\.disabled\(unavailableReason != nil\)/);
  assert.match(row, /\.help\(unavailableReason \?\? choice\.commandLabel\)/);
});

test('TAP chip retains full identity and exposes only native TAP effort IDs', () => {
  const mode = section(composer, 'static func tapAwareCoderMode(', 'func modelCollaborationComposerPill');
  assert.match(mode, /mode\.speed = nil/);
  assert.match(mode, /mode\.collaboration = nil/);
  assert.match(mode, /route\.tapEfforts\.map/);
  assert.match(mode, /options: route\.tapEfforts\.map \{ \.init\(id: effortPrefix \+ \$0\.id/);
  assert.match(mode, /model\.selectTapEffort\(String\(id\.dropFirst\(effortPrefix\.count\)\)\)/);
  assert.match(mode, /title: route\.commandLabel, suffix: nil/);
  assert.match(composer, /else if model\.routeChoice\.runtimeAdapter != \.chatgptTap \{\s*codexPermissionMenu/);
  assert.match(model, /guard routeChoice\.tapEfforts\.contains\(where: \{ \$0\.id == id \}\)/);
  const preferences = section(model, 'private func persistModelPreferences()', 'func applyPendingModelSelectionIfPossible');
  assert.match(preferences, /live\.setModelPreferences\(threadID: threadID, model: selectedModel,/);
  assert.match(preferences, /effort: routeChoice\.runtimeAdapter == \.chatgptTap \? selectedTapEffortID \?\? "" : selectedEffort\.rawValue/);
  assert.match(preferences, /speedTier: routeChoice\.runtimeAdapter == \.chatgptTap \? "" : selectedSpeedTier\.rawValue/);
});

test('ChatPageModel real send explicitly routes TAP before any CLI login check', () => {
  const send = section(model, 'func send() {', 'struct CoderDelivery:');
  const tap = send.indexOf('case .chatgptTap:');
  const login = send.indexOf('let loginStatus = sendLoginStatus(engine)');
  assert.ok(tap > 0 && login > tap);
  assert.match(send, /case \.chatgptTap:[\s\S]*?tapSendUnavailableReason\(routeChoice\)/);
  assert.match(send, /if selectedRemote == nil && !isTap/);
  assert.match(send, /if isTap \{\s*modelArg = routeChoice\.id/);
  assert.match(send, /reasoningEffort: isTap \? tapEffortIDForSend/);
  assert.match(send, /serviceTier: !isTap && \(engine == \.codex \|\| engine == \.claude\) \? selectedSpeedTier\.appServerValue : nil/);
  assert.match(send, /ultrawork: isTap \? nil/);
  const stop = section(model, 'func stop() {', 'private func computerUseScope');
  assert.match(stop, /activeLive\.stop\(threadID: id\)/);
});

test('login and sleep block sends; stale catalog refreshes at send without waking a Pod', () => {
  const availability = section(catalog, 'static func unavailabilityReason(', 'static func defaultEffort');
  for (const state of ['needsLogin', 'sleeping', 'off', 'starting', 'failed', 'ready']) {
    assert.ok(availability.includes(`case .${state}`));
  }
  assert.match(availability, /請打開 ChatGPT 登入/);
  assert.match(availability, /過期/);
  assert.match(catalog, /Date\(\)\.timeIntervalSince\(\$0\) < maxAge/);
  const refresh = section(catalog, 'func refreshIfNeeded()', 'private func reload');
  assert.match(refresh, /tap\.connection == \.ready/);
  assert.doesNotMatch(refresh, /wake|openPod|startPod|login\(/);
  assert.match(section(model, 'var canSend: Bool', 'var canSteerCurrentTurn'), /tapSendUnavailableReason\(routeChoice\) != nil \{ return false \}/);
  assert.match(section(model, 'func setSingleModel(', 'func restoreModelPreferences()'), /tapModelSelectionUnavailableReason\(choice\)/);
});

test('w185tap exercises ChatPageModel.send/stop, captures CLI fallback and exports native UI evidence', () => {
  const ui = section(acceptance, 'private static func runUIChecks(', 'private static func renderMode');
  assert.match(acceptance, /try await runUIChecks\(root:/);
  assert.match(ui, /ChatPage\(model: model\)\.coderComposerMode\(\)/);
  assert.match(ui, /model\.send\(\)/);
  assert.match(ui, /model\.stop\(\)/);
  assert.doesNotMatch(ui, /engine\.send\(/);
  assert.match(ui, /model\.sendLoginChecks\.count == checksBefore/);
  assert.match(ui, /engine\.sidecarProcessOwners\(\)\.isEmpty/);
  assert.match(ui, /sidecarCommands\(\)\.contains/);
  assert.match(ui, /model\.engineLoginTestDouble = \[\.codex\]/);
  assert.match(ui, /tap-ready\.png/);
  assert.match(ui, /tap-needs-login\.png/);
});
