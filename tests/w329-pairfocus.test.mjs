import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');

test('W329 actual native focus predicate in Swift/JavaScriptCore admits only the gateway pairing field', () => {
  const predicate = bridge.match(/kTatwoSafeFocus\[\] = R"TATWOJS\(([\s\S]*?)\)TATWOJS";/)[1];
  const gateway = read('Engines/chatgpt-hands/gateway.mjs');
  const input = gateway.match(/<input id="code"[^>]+>/)[0];
  const attributes = Object.fromEntries([...input.matchAll(/(\w+)="([^"]*)"/g)].map(m => [m[1], m[2]]));
  assert.equal(attributes.name, 'code');
  assert.equal(attributes.autocomplete, 'one-time-code');
  const root = mkdtempSync(join(tmpdir(), 'w329-focus-'));
  for (const dir of ['home', 'live', 'cache']) mkdirSync(join(root, dir));
  const file = join(root, 'checks.swift'), binary = join(root, 'checks');
  const source = read('tests/fixtures/w329-pairfocus-checks.swift')
    .replace('// INSERT predicate', `let predicate = ${JSON.stringify(predicate)}`)
    .replace('// INSERT gateway attributes', `let attributes = ${JSON.stringify(JSON.stringify(attributes))}`);
  writeFileSync(file, source);
  const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
    TATWO2_LIVE_ROOT: join(root, 'live'), CLANG_MODULE_CACHE_PATH: join(root, 'cache') };
  const build = spawnSync('/usr/bin/swiftc', ['-module-cache-path', join(root, 'cache'), file, '-o', binary],
    { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W329 SWIFT NATIVE FOCUS SUMMARY passes=\d+ failures=0/);
  assert.doesNotMatch(predicate, /\.value\b|\.focus\(/);
  console.log(run.stdout.trim());
});

test('W329 pairing mode is explicit and bound; the BrowserAgentBridge generic caller is unchanged', () => {
  const pod = read('App/Sources/Tatwo2/TAP/ChatGPTConnectorPod.swift');
  assert.match(pod, /checkAgentFocus\(withNavigationGeneration: generation, expectedRect: form.field, pairing: true/);
  assert.match(pod, /guard stillBound\(\), view.window\?\.isKeyWindow == true/);
  const generic = read('App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift');
  assert.match(generic, /bound.view.checkAgentFocus\(withNavigationGeneration: bound.generation, dispatchGate: gate, completion: completion\)/);
  assert.doesNotMatch(generic, /pairing: true/);
  assert.match(bridge, /expectedRect:rect pairing:NO dispatchGate:dispatchGate/);
  assert.match(bridge, /pairing \? NodeInputKind::pairingFocus : NodeInputKind::focus/);
  assert.match(bridge, /type_kind_ == NodeInputKind::pairingFocus \? "true" : "false"/);
  assert.match(read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m'),
    /pairing:\(BOOL\)pairing[^\n]+completion\(NO, @"browser_unavailable"\)/);
  const native = read('App/Sources/Tatwo2/TAP/W328PairfillAcceptance.swift');
  assert.match(native, /checkFocus\(fieldRect, pairing: false\)/);
  assert.match(native, /guard active && keyWindow else/);
  const fixture = read('App/Sources/Tatwo2/TAP/W248WebSpaceAcceptance.swift');
  assert.match(fixture, /field.id='code'; field.name='code'; field.autocomplete='one-time-code'/);
});
