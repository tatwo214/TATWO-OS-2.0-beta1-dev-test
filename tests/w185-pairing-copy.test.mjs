import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const ui = read('New/HandsConnectDMView.swift');
const flow = read('Facade/HandsConnect.swift');
const clipboard = read('Facade/HandsPairingClipboard.swift');

test('pairing copy is a user button, shown only with visible, unexpired code', () => {
  assert.match(ui, /if let code = view\.spacedCode, context\.revealsCode, left > 0/);
  assert.match(ui, /GlobalDMChipButton\(title: copiedCode \? "已複製" : "複製"\)/);
  assert.match(ui, /copiedCode = actions\.copyPairingCode\(view\)/);
  assert.match(ui, /tatwo\.dm\.handsConnect\.copyCode/);
  assert.match(ui, /copyPairingCode: \{ flow\.copyPairingCode\(\$0\) \}/);
});
test('copy revalidates current phase, card, visible surface, expiry and host code alphabet', () => {
  assert.match(flow, /guard phase == \.waitingPairing, !cancelling, case \.pairing\(let current\)\? = card/);
  assert.match(flow, /visible: presenter\.showsSurface\(shown\.surface\)/);
  assert.match(clipboard, /current == shown, shown\.expiresAt > now, shown\.attemptsLeft > 0/);
  assert.match(clipboard, /code\.utf8\.count == 8/);
  assert.match(clipboard, /HandsAuth\.codeAlphabet\.contains\(\$0\)/);
});
test('copy remains on this Mac, clears only its own contents, and never submits', () => {
  assert.match(clipboard, /prepareForNewContents\(with: \.currentHostOnly\)/);
  assert.match(clipboard, /setString\(code, forType: \.string\)/);
  assert.match(clipboard, /min\(60, shown\.expiresAt\.timeIntervalSince\(now\)\)/);
  assert.match(clipboard, /pasteboard\.changeCount == ownedChange/);
  assert.match(flow, /if card != oldValue \{\s*pairingClipboard\.clear\(\)/);
  assert.doesNotMatch(clipboard, /print\(|\.log\(|writeAtomically|submit|autoFill|setPairingCode|callPrimary/);
});
