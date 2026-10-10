import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = name => fs.readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');
const bridgePath = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const bridge = read(bridgePath);

test('W257 uses native AX request events, with a debug-only persistent force switch', () => {
  const startup = bridge.slice(bridge.indexOf('void OnBeforeCommandLineProcessing('), bridge.indexOf('void OnBeforeChildProcessLaunch('));
  assert.match(startup, /if \(CEFAccessibilityTreeForced\(\)\) \{\s*command_line->AppendSwitchWithValue\("force-renderer-accessibility", "complete"\)/);
  const app = bridge.slice(bridge.indexOf('@implementation TatwoCEFApplication'), bridge.indexOf('\n@end', bridge.indexOf('@implementation TatwoCEFApplication')));
  assert.match(app, /AXManualAccessibility/);
  assert.match(app, /AXEnhancedUserInterface/);
  assert.match(app, /if \(requested\) ApplyRequestedAccessibility\(\)/);
  assert.doesNotMatch(app, /NSTimer|scheduledTimer|dispatch_after|while\s*\(/);
  const nativeCU = read('App/Sources/Tatwo2/New/ComputerUseController.swift');
  assert.match(nativeCU, /if includeTree, running.bundleIdentifier\?\.hasPrefix\("ai\.tatwo\.tatwo2"\)/);
  assert.match(nativeCU, /attr = "AXManualAccessibility"/);
  assert.match(nativeCU, /NSApp\.accessibilitySetValue\(value, forAttribute: \.init\(rawValue: attr\)\)/);
  assert.match(nativeCU, /AXUIElementSetAttributeValue\(app, attr as CFString, value \? kCFBooleanTrue : kCFBooleanFalse\)/);
});

test('W257 benchmark stays local, observes real frames and loads 20 cards per batch', () => {
  const page = read('tests/fixtures/w257-timeline.py');
  assert.match(page, /HTTPServer\(\('127\.0\.0\.1', 0\)/);
  assert.doesNotMatch(page, /https?:\/\//);
  assert.match(page, /for\(let i=0;i<20;i\+\+\)/);
  assert.match(page, /canvas\.toDataURL\('image\/png'\)/);
  assert.match(page, /requestAnimationFrame\(tick\)/);
  assert.match(page, /observer\.observe\(\{type:'longtask'\}\)/);
  assert.match(page, /frames\.filter\(v=>v>50\)/);
  assert.match(page, /Math\.ceil\(p\*sorted\.length\)-1/);
  assert.match(page, /t-start<10000/);
  const suite = read('App/Sources/Tatwo2/Browser/W257XSmoothAcceptance.swift');
  assert.match(suite, /for run in 1\.\.\.3/);
  assert.match(suite, /\.sorted\(\)\[1\]/);
  assert.match(suite, /\["--use-mock-keychain"\]/);
  assert.match(suite, /default does not expose web AX content/);
  assert.match(suite, /AXManualAccessibility exposes real web node text and AXButton/);
});

test('W257 preserves the restricted CEF settings from c901ffff', () => {
  // Only request handling and the force-switch gate change. Values are checked
  // against the immutable room base rather than against a second copied list.
  const { execFileSync } = process.getBuiltinModule('node:child_process');
  const base = execFileSync('git', ['show', `c901ffff:${bridgePath}`], { encoding: 'utf8' });
  const features = source => source.match(/const std::string disabled_features =[\s\S]*?command_line->AppendSwitchWithValue\("disable-features", disabled_features\);/)[0];
  assert.equal(features(bridge), features(base));
  assert.equal(bridge.match(/settings\.external_message_pump = [^;]+;/)[0], base.match(/settings\.external_message_pump = [^;]+;/)[0]);
});
