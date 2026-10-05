import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');

test('modifier detector has no AppKit dependency and triggers only at full release', () => {
  const source = read('DM/ModifierChordDetector.swift');
  assert.doesNotMatch(source, /import AppKit|NSEvent\./);
  assert.match(source, /let heldFlags = flags\.intersection\(\[\.option, \.command, \.shift, \.control, \.function\]\)/);
  assert.match(source, /if heldFlags\.isEmpty \{/);
  assert.match(source, /sawChord && !disqualified/);
  assert.match(source, /time >= \$0 && time - \$0 <= maximumDuration/);
  assert.match(source, /maximumDuration: TimeInterval = 1/);
  assert.match(source, /heldFlags\.subtracting\(\.chord\)/);
  assert.match(source, /mutating func keyDown/);
  assert.match(source, /if startedAt != nil \{ disqualified = true \}/);
});

test('monitor is passive, local plus permission-gated global; permission can upgrade on activation', () => {
  const source = read('DM/GlobalHotkeyMonitor.swift');
  assert.match(source, /private static let chordEvents: NSEvent\.EventTypeMask = \[\s*\.flagsChanged, \.keyDown, \.leftMouseDown, \.rightMouseDown, \.otherMouseDown,\s*\.leftMouseDragged, \.rightMouseDragged, \.otherMouseDragged, \.scrollWheel,/);
  assert.match(source, /addLocalMonitorForEvents\(matching: Self\.chordEvents\) \{ \[weak self\] event in\s*self\?\.consume\(event\)\s*return event/);
  assert.match(source, /addGlobalMonitorForEvents\(matching: Self\.chordEvents\)/);
  assert.match(source, /if AXIsProcessTrusted\(\)/);
  assert.match(source, /didBecomeActiveNotification/);
  assert.match(source, /private\(set\) var isSystemWide = false/);
  assert.match(source, /let available = globalMonitor != nil\s*if isSystemWide != available \{ isSystemWide = available \}/);
  assert.match(source, /Timer\(timeInterval: 0\.5, repeats: true\)[\s\S]*self\?\.refreshAccessibilityPermission\(\)/);
  assert.match(source, /return event/);
  assert.doesNotMatch(source, /return nil/);
  assert.match(source, /name: \.tatwoToggleGlobalDM/);
  assert.match(source, /x-apple.systempreferences:com.apple.preference.security\?Privacy_Accessibility/);
  assert.match(source, /removeMonitor\(localMonitor\)/);
  assert.match(source, /removeMonitor\(globalMonitor\)/);
  assert.doesNotMatch(source, /AXIsProcessTrustedWithOptions|NSPanel|makeKeyAndOrderFront/);
});

test('AppDelegate installs and uninstalls monitor; executable self-test covers required sequences', () => {
  const shell = read('Shell/AppShell.swift');
  assert.match(shell, /installAlternateNewChatShortcutMonitor\(\)\s*GlobalHotkeyMonitor.shared.install\(\)/);
  assert.match(shell, /func applicationWillTerminate[\s\S]{0,160}GlobalHotkeyMonitor.shared.uninstall\(\)/);
  const checks = read('SelfTest.swift');
  assert.match(checks, /TATWO2_SELFTEST"\] == "w179hotkey"/);
  for (const label of ['option-command release reverse', 'command-option release reverse',
    'reject chord plus', 'reject extra modifier', 'reject 1.2 second hold', 'command only',
    'two gestures exactly twice', 'no trigger before full release']) {
    assert.ok(checks.includes(label), label);
  }
});
