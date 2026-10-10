import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const between = (source, from, to) => {
  const a = source.indexOf(from), b = source.indexOf(to, a + from.length);
  assert.ok(a >= 0 && b > a, `${from} through ${to}`);
  return source.slice(a, b);
};

test('W328 actual Swift fillPairingCode: fake view exercises binding, pairing typeText failures, residual cleanup and privacy', () => {
  const pod = read('App/Sources/Tatwo2/TAP/ChatGPTConnectorPod.swift');
  const source = read('tests/fixtures/w328-pairfill-checks.swift')
    .replace('// INSERT fillPairingCode', between(pod, '    func fillPairingCode(', '    /// 綁住的那一個畫面'))
    .replace('// INSERT helpers', between(pod, '    nonisolated static func sameViewport(', '    private static func snapshot(') +
      between(pod, '    nonisolated static func pairingForm(', '    func highlight('))
    .replace('// INSERT cleanStep', between(read('App/Sources/Tatwo2/Facade/HandsConnect.swift'), '    static func cleanStep(', '    /// W183 R9 審查'));
  const root = mkdtempSync(join(tmpdir(), 'w328-swift-'));
  for (const dir of ['home', 'live', 'cache']) mkdirSync(join(root, dir));
  const file = join(root, 'checks.swift'), binary = join(root, 'checks');
  writeFileSync(file, source);
  const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'), TATWO2_LIVE_ROOT: join(root, 'live'),
    CLANG_MODULE_CACHE_PATH: join(root, 'cache') };
  const build = spawnSync('/usr/bin/swiftc', ['-parse-as-library', '-swift-version', '5', '-num-threads', '2',
    '-module-cache-path', join(root, 'cache'), file, '-o', binary], { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 20000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W328 SWIFT SUMMARY passes=\d+ failures=0/);
  console.log(run.stdout.trim());
});

test('W328 native refusal property and real CEF self-test use existing input guards and only bound-host focus', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const send = between(bridge, '- (BOOL)sendAgentKey:', '- (void)releaseAgentKey');
  assert.match(send, /if \(!BrowserInputIsCurrent\(self, generation\)\) return NO/);
  for (const reason of ['stale_generation', 'input_not_current', 'bad_args', 'key_host_busy']) assert.ok(send.includes(`@"${reason}"`));
  assert.match(send, /!state->browser->IsSame\(state->agent_key_host->GetBrowser\(\)\)/);
  const click = between(bridge, '- (BOOL)sendClickAtPoint:', '- (void)clickElement:');
  assert.ok(click.indexOf('host->SetFocus(true)') > click.indexOf('BrowserInputIsCurrent(self, generation)'));
  assert.ok(click.indexOf('host->SetFocus(true)') < click.indexOf('host->SendMouseClickEvent'));
  assert.match(read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h'), /readonly, copy\) NSString \*lastAgentKeyRefusal/);
  assert.match(read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m'), /lastAgentKeyRefusal \{ return @"stale_generation"; \}/);
  assert.match(read('App/Sources/Tatwo2/TAP/W294ePodSizeAcceptance.swift'), /try await W328PairfillAcceptance\.run\(pod: pod\)/);
  const native = read('App/Sources/Tatwo2/TAP/W328PairfillAcceptance.swift');
  assert.match(native, /NativeStagingIsolation\.isEnabled/);
  assert.match(native, /http:\/\/127\.0\.0\.1:/);
  assert.match(native, /all eight synthetic characters arrive through the native setter/);
});

test('W328 actual native sequence guard accepts fresh wrappers for the same browser and rejects another browser', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const send = between(bridge, '- (BOOL)sendAgentKey:', '- (void)releaseAgentKey');
  const guard = between(send, '  // GetHost()', '  state->last_agent_key_refusal = @"";');
  const root = mkdtempSync(join(tmpdir(), 'w328-host-'));
  const file = join(root, 'checks.cc'), binary = join(root, 'checks');
  writeFileSync(file, read('tests/fixtures/w328-key-host-checks.cc').replace('// INSERT native guard', guard));
  const build = spawnSync('/usr/bin/clang++', ['-std=c++17', file, '-o', binary], { encoding: 'utf8', timeout: 60000 });
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W328 NATIVE IDENTITY SUMMARY passes=9 failures=0/);
  console.log(run.stdout.trim());
});

test('W328 actual isolated-world focus predicate requires document focus and the observed text field', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const source = bridge.match(/kTatwoSafeFocus\[\] = R"TATWOJS\(([\s\S]*?)\)TATWOJS";/)[1];
  const field = { localName: 'input', type: 'text', isConnected: true, disabled: false, readOnly: false,
    matches: () => false, getAttribute: () => '', getBoundingClientRect: () => ({x:20,y:20,width:200,height:40}) };
  let hasFocus = true, hit = field;
  const document = { activeElement: field, hasFocus: () => hasFocus, elementFromPoint: () => hit };
  const focus = Function('document', `return ${source}`)(document);
  const rect = [20,20,200,40];
  assert.equal(focus(rect), true);
  hasFocus = false; assert.equal(focus(rect), false); hasFocus = true;
  assert.equal(focus([120,20,200,40]), false);
  hit = {}; assert.equal(focus(rect), false); hit = field;
  for (const type of ['password', 'hidden', 'submit']) { field.type = type; assert.equal(focus(rect), false); }
  field.type = 'text'; field.readOnly = true; assert.equal(focus(rect), false); field.readOnly = false;
  field.disabled = true; assert.equal(focus(rect), false); field.disabled = false;
  field.autocomplete = 'one-time-code'; assert.equal(focus(rect), false); field.autocomplete = '';
  assert.equal(focus(rect), true);
  assert.equal(focus([0,0,0,0]), true, 'existing generic call retains its safe-control check');
  assert.doesNotMatch(source, /\.value\b|\.focus\(/, 'focus check reads no field contents and does not force DOM focus');
});
