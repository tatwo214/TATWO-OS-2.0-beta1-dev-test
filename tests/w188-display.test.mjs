import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

const source = name => readFileSync(new URL(`../App/Sources/Tatwo2/Display/${name}.swift`, import.meta.url), 'utf8');

test('probe opens a read-only discovery session and does not call setters', () => {
  const acceptance = source('DisplayAcceptance');
  const probe = acceptance.slice(acceptance.indexOf('    static func probe()'));
  assert.match(probe, /DisplayDiscovery\.discover\(readOnly: true\)/);
  assert.doesNotMatch(probe, /\.set\(|setBrightness\(|setVolume\(/);
  const transport = source('DDCArm64');
  assert.match(transport, /func write\(_ command: DDCCommand, value: UInt16\) -> Bool \{\s*guard !readOnly else \{ return false \}/);
  assert.match(probe, /settingWrites=0/);
});

test('private symbols have runtime availability checks and no direct binding calls', () => {
  const ddc = source('DDCArm64');
  for (const symbol of ['IOAVServiceCreateWithService', 'IOAVServiceReadI2C', 'IOAVServiceWriteI2C']) {
    assert.match(ddc, new RegExp(`@_silgen_name\\("${symbol}"\\)`));
    assert.equal(ddc.match(new RegExp(`${symbol}\\(`, 'g'))?.length, 1, `${symbol} must only have an ABI declaration`);
  }
  assert.match(ddc, /dlsym/);
  assert.match(ddc, /#if arch\(arm64\)/);
  assert.match(ddc, /actor DDCArm64/);
});

test('keyboard and overlay do not request permissions or use gamma tables', () => {
  const files = readdirSync(new URL('../App/Sources/Tatwo2/Display/', import.meta.url)).filter(x => x.endsWith('.swift'));
  const production = files.filter(x => x !== 'DisplayAcceptance.swift').map(x => source(x.slice(0, -6))).join('\n');
  assert.doesNotMatch(production, /AXIsProcessTrustedWithOptions|AXTrustedCheckOptionPrompt|CGRequest|CGSetDisplayTransfer|NSWorkspace\.shared\.open|terminate\(/);
  const shade = source('SoftwareDimmer');
  assert.match(shade, /ignoresMouseEvents = true/);
  assert.match(shade, /canJoinAllSpaces/);
  assert.match(shade, /fullScreenAuxiliary/);
  assert.match(shade, /maximumWindow/);
});

test('selftests are registered and write harness uses fixture transports', () => {
  const entries = readFileSync(new URL('../App/Sources/Tatwo2/SelfTest.swift', import.meta.url), 'utf8');
  assert.match(entries, /"w188display"/);
  assert.match(entries, /"w188ddcprobe"/);
  const acceptance = source('DisplayAcceptance');
  const run = acceptance.slice(acceptance.indexOf('    static func run()'), acceptance.indexOf('    static func probe()'));
  assert.doesNotMatch(run, /IOAVTransport\(entry:|DisplayDiscovery\.discover\(/);
  assert.match(run, /FixtureDDCTransport/);
  assert.match(run, /SUMMARY failures=/);
});

test('copied DDC adaptation includes upstream full license and copyright', () => {
  const notices = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8');
  assert.match(notices, /Copyright © 2017/);
  assert.match(notices, /Permission is hereby granted, free of charge/);
  assert.match(notices, /THE SOFTWARE IS PROVIDED "AS IS"/);
  assert.match(notices, /OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\s+SOFTWARE\./);
  assert.match(source('DDCArm64'), /THIRD_PARTY_NOTICES/);
});
