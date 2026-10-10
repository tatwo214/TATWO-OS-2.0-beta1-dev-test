import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { keychainFixtureFiles } from './helpers/w255b-keychain-fixture.mjs';
const read = file => readFileSync(new URL('../' + file, import.meta.url), 'utf8');
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'w255b-boundary-'));
  mkdirSync(join(root, 'home'));
  const env = { PATH: process.env.PATH, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'), TMPDIR: root,
    CLANG_MODULE_CACHE_PATH: join(root, 'cache') };
  return { root, env };
}
function compile(root, env, files, flags = []) {
  const binary = join(root, 'probe');
  const result = spawnSync('/usr/bin/xcrun', ['swiftc', ...flags, ...files, '-o', binary], { env, encoding: 'utf8', timeout: 60000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return binary;
}
const selftest = () => read('App/Sources/Tatwo2/SelfTest.swift');

test('W255b: every selftest Keychain API returns a synthetic denial before host access', () => {
  const { root, env } = fixture();
  const boundary = read('App/Sources/Tatwo2/Facade/TestKeychainBoundary.swift');
  assert.doesNotMatch(read('App/Sources/Tatwo2/Facade/CloudflareAccounts.swift'), /enum W255TestKeychain|func Sec(?:Item|Keychain)/);
  assert.ok(boundary.includes('Security.SecItemCopyMatching'));
  const guardFile = join(root, 'Boundary.swift');
  writeFileSync(guardFile, boundary + '\nfunc w255bBoundaryActive() -> Bool { W255TestKeychain.active }\n');
  const main = join(root, 'main.swift');
  writeFileSync(main, 'import Foundation\nimport Security\n' + `
if CommandLine.arguments.contains("--active-only") { print(w255bBoundaryActive()); exit(0) }
let q = [:] as CFDictionary
var data: CFTypeRef? = "synthetic-canary" as CFString
var allowed: DarwinBoolean = true
precondition(SecItemCopyMatching(q, &data) == errSecInteractionNotAllowed && data == nil)
precondition(SecItemAdd(q, &data) == errSecInteractionNotAllowed && data == nil)
precondition(SecItemUpdate(q, q) == errSecInteractionNotAllowed)
precondition(SecItemDelete(q) == errSecInteractionNotAllowed)
precondition(SecKeychainGetUserInteractionAllowed(&allowed) == errSecInteractionNotAllowed && !allowed.boolValue)
precondition(SecKeychainSetUserInteractionAllowed(true) == errSecInteractionNotAllowed)
print("W255b six fake Security APIs PASS")
`);
  const binary = compile(root, env, [guardFile, main]);
  for (const key of ['TATWO2_SELFTEST', 'TATWO2_SOURCETEST', 'TATWO2_GITHUBTEST', 'TATWO2_SECURITYTEST', 'TATWO2_W81TEST']) {
    const run = spawnSync(binary, [], { env: { ...env, [key]: '1' }, encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.match(run.stdout, /six fake Security APIs PASS/);
  }
  // Inspect activation only; these cases must never execute a native Security call.
  for (const flag of [undefined, '', '0']) {
    const run = spawnSync(binary, ['--active-only'], { env: { ...env, ...(flag === undefined ? {} : { TATWO2_SELFTEST: flag }) }, encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout.trim(), 'false');
  }
});

test('W255b: compiled fixture traps all six accidental native API calls without a Keychain', () => {
  const { root, env } = fixture();
  const probe = join(root, 'fixture.swift');
  writeFileSync(probe, `import Foundation\nimport Security
@main struct Probe { static func main() {
 let q = [:] as CFDictionary; var data: CFTypeRef?; var allowed: DarwinBoolean = true
 switch CommandLine.arguments[1] {
 case "read": _ = SecItemCopyMatching(q, &data)
 case "add": _ = SecItemAdd(q, &data)
 case "update": _ = SecItemUpdate(q, q)
 case "delete": _ = SecItemDelete(q)
 case "get-interaction": _ = SecKeychainGetUserInteractionAllowed(&allowed)
 case "set-interaction": _ = SecKeychainSetUserInteractionAllowed(true)
 default: exit(99)
 }
}}`);
  const binary = compile(root, env, keychainFixtureFiles(root, [probe]), ['-parse-as-library']);
  for (const call of ['read', 'add', 'update', 'delete', 'get-interaction', 'set-interaction']) {
    const run = spawnSync(binary, [call], { env, encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 86, run.stdout + run.stderr);
    assert.match(run.stderr, /W255B_BOUNDARY: un-injected Keychain API/);
  }
  writeFileSync(probe, 'func unsafe() { SecKeychainOpen(nil, nil) }');
  assert.throws(() => keychainFixtureFiles(root, [probe]), /unknown native Keychain API/);
});

test('W255b: shell, xcrun, env and compact signing options cannot bypass the launcher', () => {
  const { root, env } = fixture();
  const marker = join(root, 'executed');
  const security = join(root, 'security'), signer = join(root, 'codesign');
  for (const file of [security, signer]) writeFileSync(file, '#!/bin/sh\necho synthetic-command\ntouch "' + marker + '"\n', { mode: 0o700 });
  const preload = new URL('./fixtures/w255-swift-plugin.mjs', import.meta.url).pathname;
  const probe = join(root, 'probe.mjs');
  writeFileSync(probe, `import assert from 'node:assert/strict';
import cp from 'node:child_process';
const security = ${JSON.stringify(security)}, signer = ${JSON.stringify(signer)};
const denied = (file, args) => { const r = cp.spawnSync(file, args, {encoding:'utf8'}); assert.equal(r.status,126); assert.match(r.stderr,/W255_BOUNDARY/); };
denied(security, ['find-identity']);
denied('/usr/bin/xcrun', ['security','find-identity']);
denied('/usr/bin/env', [security,'find-identity']);
for (const command of [security+' find-identity', '"'+security+'" find-identity']) {
 denied('/bin/bash', ['-c',command]);
 assert.throws(() => cp.execSync(command), /W255_BOUNDARY/);
 assert.throws(() => cp.exec(command), /W255_BOUNDARY/);
}
for (const name of ['execFileSync','spawn','execFile']) assert.throws(() => cp[name](security,['find-identity']), /W255_BOUNDARY/);
for (const args of [['--sign','synthetic'],['--sign=synthetic'],['-ssynthetic']]) denied(signer,args);
denied('/bin/bash',['-c',signer+' --sign=synthetic target']);
`);
  const run = spawnSync(process.execPath, ['--import', preload, probe], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal(existsSync(marker), false, 'every forbidden call must stop before even a synthetic executable');
  writeFileSync(probe, `import assert from 'node:assert/strict'; import {spawnSync} from 'node:child_process';
for (const args of [['--sign','-'],['--sign=-'],['-s-']]) assert.equal(spawnSync(${JSON.stringify(signer)},args).status,0);
assert.equal(spawnSync('/bin/bash',['-c',${JSON.stringify(signer)}+' --verify --strict target']).status,0);`);
  const adhoc = spawnSync(process.execPath, ['--import', preload, probe], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(adhoc.status, 0, adhoc.stdout + adhoc.stderr);
  assert.equal(existsSync(marker), true, 'ad-hoc signing needs no Keychain and remains runnable');
});

test('W255b: standalone Swift fixture throws a boundary skip before host access', () => {
  const { root, env } = fixture();
  const source = read('Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/TatwoFleetSchedulerTests.swift');
  const body = source.match(/  private func requireInteractiveKeychain\(\) throws \{[\s\S]*?\n  \}/)?.[0];
  assert.ok(body);
  assert.doesNotMatch(body, /interactiveKeychainAvailability|Sec(?:Item|Keychain)/);
  assert.match(body, /throw XCTSkip\("W255B_BOUNDARY: host Keychain refused; needs a private test keychain"\)/);
  const probe = source.match(/  func testHostKeychainProbeIsRefusedBeforeAccess\(\) \{[\s\S]*?\n  \}/)?.[0];
  assert.match(probe, /XCTAssertTrue\(error is XCTSkip\)/);
  assert.match(probe, /contains\("W255B_BOUNDARY"\)/);
  const main = join(root, 'main.swift');
  // As before, inject only the error type for this standalone, Security-free fixture.
  // Real XCTest type checking belongs to swift build --build-tests.
  writeFileSync(main, 'import Foundation\nstruct XCTSkip: Error { let reason: String; init(_ reason: String) { self.reason = reason } }\n' + body.replace('private func', 'func') + `
do { try requireInteractiveKeychain(); exit(99) }
catch { precondition(error is XCTSkip); precondition(String(describing: error).contains("W255B_BOUNDARY")); print("host probe refused PASS") }
`);
  const binary = compile(root, env, [main]);
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /host probe refused PASS/);
});

test('W255b: generic live-engine selftest is refused before a session can launch', () => {
  const { root, env } = fixture();
  const source = selftest();
  const start = source.indexOf('    @MainActor static func runIfRequested() {') + '    @MainActor static func runIfRequested() {'.length;
  const guard = source.slice(start, source.indexOf('        #if DEBUG', start));
  assert.match(guard, /W255B_BOUNDARY/);
  const main = join(root, 'main.swift');
  writeFileSync(main, 'import Foundation\n' + guard + '\nexit(99)\n');
  const binary = compile(root, env, [main]);
  const denied = spawnSync(binary, [], { env: { ...env, TATWO2_SELFTEST: '1' }, encoding: 'utf8', timeout: 10000 });
  assert.equal(denied.status, 78, denied.stdout + denied.stderr);
  assert.match(denied.stderr, /live-engine selftest needs a synthetic adapter/);
  const ordinary = spawnSync(binary, [], { env: { ...env, TATWO2_SELFTEST: 'w255' }, timeout: 10000 });
  assert.equal(ordinary.status, 99);
});
