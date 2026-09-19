// W97. Static contracts only: the accessibility tree is built on demand, and
// the switches this change was not allowed to touch are still byte-identical.
// None of this proves a page loads faster; that is scripts/browser-perf-note.md.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const diagnostics = read('App/Sources/Tatwo2/Browser/Diagnostics/BrowserDiagnosticsView.swift');

function section(source, from, to, label) {
  const start = source.indexOf(from);
  assert.ok(start >= 0, `${label}: start not found`);
  const end = source.indexOf(to, start + from.length);
  assert.ok(end > start, `${label}: end not found`);
  return source.slice(start, end);
}

// A command-line switch or a CEF call is "conditional" when the nearest opening
// brace above it belongs to an `if (` on the accessibility gate, so a later edit
// that moves the call back out of the branch fails here instead of at runtime.
function guardedBy(body, needle, guard, label) {
  const at = body.indexOf(needle);
  assert.ok(at >= 0, `${label}: ${needle} not found`);
  assert.equal(body.indexOf(needle, at + needle.length), -1, `${label}: ${needle} appears twice`);
  const before = body.slice(0, at);
  const opened = before.lastIndexOf('{');
  assert.ok(opened >= 0, `${label}: no enclosing block`);
  const head = before.slice(before.lastIndexOf('\n', opened - 1) + 1, opened + 1).trim();
  assert.equal(head, `if (${guard}()) {`, `${label}: enclosing block is not the ${guard} gate`);
}

test('W97 (a) force-renderer-accessibility is only appended inside the gate', () => {
  const startup = section(bridge, '  void OnBeforeCommandLineProcessing(',
    '  void OnBeforeChildProcessLaunch(', 'OnBeforeCommandLineProcessing');
  guardedBy(startup, 'command_line->AppendSwitchWithValue("force-renderer-accessibility", "complete");',
    'CEFAccessibilityTreeEnabled', 'startup switch');
  // The whole file must not reach for the switch anywhere else.
  assert.equal(bridge.split('force-renderer-accessibility').length - 1, 1);

  const gate = section(bridge, 'AccessibilityTreeReason CEFAccessibilityTreeReason() {',
    'bool CEFAccessibilityTreeEnabled() {', 'reason helper');
  assert.match(gate, /getenv\("TATWO_CEF_FORCE_AX"\)/);
  assert.match(gate, /strcmp\(forced, "1"\) == 0/);
  assert.match(gate, /strcmp\(forced, "0"\) == 0/);
  assert.match(gate, /\[\[NSWorkspace sharedWorkspace\] isVoiceOverEnabled\]/);
  // AXIsProcessTrusted reports our own permission to automate others, not a
  // reader; it must never stand in for detection here.
  assert.doesNotMatch(bridge, /AXIsProcessTrusted\(/);
});

test('W97 (b) SetAccessibilityState(STATE_ENABLED) is only called inside the gate', () => {
  const created = section(bridge, 'void TatwoClient::OnAfterCreated(', 'bool TatwoClient::DoClose(',
    'OnAfterCreated');
  guardedBy(created, 'browser->GetHost()->SetAccessibilityState(STATE_ENABLED);',
    'CEFAccessibilityTreeEnabled', 'per-browser state');
  assert.equal(bridge.split('->SetAccessibilityState(').length - 1, 1);
});

test('W97 (c) the pump and windowed-rendering settings are untouched', () => {
  assert.match(bridge, /settings\.external_message_pump = true;/);
  assert.match(bridge, /settings\.windowless_rendering_enabled = false;/);
  assert.doesNotMatch(bridge, /settings\.windowless_rendering_enabled = true;/);
  assert.doesNotMatch(bridge, /settings\.external_message_pump = false;/);
});

test('W97 (d) the --disable-features list is byte-identical to the baseline', () => {
  // Baseline: beta1/integration @ 7a2c6b3d. W97 is not allowed to widen, narrow
  // or reorder this list; a deliberate change belongs in its own train.
  const baseline = [
    '    command_line->AppendSwitchWithValue(',
    '        "disable-features",',
    '        "AutofillServerCommunication,MediaRouter,WebBluetooth,WebHID,"',
    '        "WebNFC,WebOTP,WebSerial,WebUSB");',
  ].join('\n');
  assert.equal(bridge.split(baseline).length - 1, 1, 'disable-features block changed');
});

test('W97 diagnostics reports the tree state and the reason it was decided', () => {
  const state = section(diagnostics, 'enum BrowserAccessibilityTreeState {', '\n}\n',
    'diagnostics state');
  for (const reason of [
    '（原因：環境變數 TATWO_CEF_FORCE_AX=1）',
    '（原因：環境變數 TATWO_CEF_FORCE_AX=0）',
    '（原因：VoiceOver）',
    '（原因：未偵測到輔助工具）',
  ]) assert.ok(state.includes(reason), reason);
  // Same inputs as the bridge, same precedence: environment first, then VoiceOver.
  assert.ok(state.indexOf('TATWO_CEF_FORCE_AX') < state.indexOf('isVoiceOverEnabled'));
  assert.match(state, /NSWorkspace\.shared\.isVoiceOverEnabled/);
  // The row is actually rendered, above the sleep-threshold line of the engine card.
  const body = section(diagnostics, 'BrowserDiagnosticsCard(title: "引擎")', 'BrowserDiagnosticsCard(title: "程序")',
    'engine card');
  assert.match(body, /Text\(BrowserAccessibilityTreeState\.stateText\)/);
  assert.match(body, /Text\(BrowserAccessibilityTreeState\.scopeText\)/);
});
