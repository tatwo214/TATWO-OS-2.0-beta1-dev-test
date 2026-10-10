import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, chmodSync, existsSync, copyFileSync, symlinkSync, realpathSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const scratch = mkdtempSync(join(tmpdir(), 'w284-'));
const binary = join(scratch, 'probe');
const run = (cmd, args, extra = {}) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 120_000, ...extra });
writeFileSync(join(scratch, 'main.swift'), `
import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let entry = TatwoEntry(environment: ["TATWO2_OS_ROOT": root.path], preference: nil, homeDirectory: root)
if CommandLine.arguments[2] == "fail-midwrite" {
    signal(SIGXFSZ, SIG_IGN)
    var limit = rlimit(rlim_cur: 16, rlim_max: 16)
    precondition(setrlimit(RLIMIT_FSIZE, &limit) == 0)
}
do {
    let selection = CommandLine.arguments[2] == "reset" ? nil : URL(fileURLWithPath: CommandLine.arguments[3])
    let warning = try WorkPath.set(selection, entry: entry)
    print(try WorkPath.current(entry).path)
    print(warning ?? "")
    precondition(WorkPath.warning(bytes: 49_999_999_999) != nil)
    precondition(WorkPath.warning(bytes: 50_000_000_000) == nil && WorkPath.warning(bytes: nil) == nil)
} catch { print(error.localizedDescription); exit(1) }
`);
const compiled = run('swiftc', ['App/Sources/Tatwo2/Facade/TatwoEntry.swift', 'App/Sources/Tatwo2/Onboarding/WorkPath.swift', join(scratch, 'main.swift'), '-o', binary]);
assert.equal(compiled.status, 0, compiled.stderr);

function fixture(text) {
  const root = mkdtempSync(join(scratch, 'entry-'));
  const chosen = join(root, 'custom work');
  mkdirSync(chosen);
  writeFileSync(join(root, 'device.json'), text);
  return { root, chosen, file: join(root, 'device.json') };
}
function change(f, action = 'choose') { return run(binary, [f.root, action, f.chosen]); }

test('existing resources: only staging value changes, all other bytes survive', () => {
  const original = '{\n "deviceID" : "fixture", "name":"fixture", "epoch":1e2, "emoji":"測試😀",\n "nested":{"staging":"keep", "x":[true,null,12.30]},\n "resources" : { "entry":"logical", "physicalEntry":"physical", "other": {"x":false}, "staging" : "old\\/path" }, "tail":false\n}\n';
  const f = fixture(original), result = change(f);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(readFileSync(f.file, 'utf8'), original.replace('"old\\/path"', JSON.stringify(f.chosen)));
  assert.equal(JSON.parse(readFileSync(f.file)).resources.staging, f.chosen);
});

test('legacy identity: insert entry, resolved physicalEntry and staging; preserve other bytes', () => {
  const original = '{ "deviceID":"fixture", "preferences":{"energy":"平衡"}, "name" : "fixture" }\n';
  const f = fixture(original);
  assert.equal(change(f).status, 0);
  const next = readFileSync(f.file, 'utf8');
  assert.equal(next.slice(0, original.lastIndexOf('}')), original.slice(0, original.lastIndexOf('}')));
  const resources = JSON.parse(next).resources;
  assert.equal(resources.entry, f.root);
  assert.equal(resources.physicalEntry, f.root);
  assert.equal(resources.staging, f.chosen);
});

test('partial resources: retain entry and physicalEntry verbatim, add staging', () => {
  const f = fixture('{"resources": { "entry":"logical", "physicalEntry" : "physical", "unknown":[1,true,null] },"name":"fixture"}');
  assert.equal(change(f).status, 0);
  const next = readFileSync(f.file, 'utf8');
  assert.ok(next.includes('"entry":"logical", "physicalEntry" : "physical", "unknown":[1,true,null] '));
  assert.equal(JSON.parse(next).resources.staging, f.chosen);
});

test('legacy linked entrance records logical entry and resolved physicalEntry', () => {
  const f = fixture('{"deviceID":"fixture", "role":"secondary"}');
  const logical = join(scratch, 'linked-entry');
  symlinkSync(f.root, logical);
  const result = run(binary, [logical, 'choose', f.chosen]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(f.file)).resources,
    { entry: logical, physicalEntry: realpathSync(f.root), staging: f.chosen });
});

test('escaped field names and strings, empty resources and nested staging are handled', () => {
  for (const resources of ['{}', '{"\\u0073taging":"old", "untouched":"a\\\"b", "nested":{"staging":"keep"}}']) {
    const f = fixture(`{ "resources":${resources}, "untouched":"\\u6e2c\\u8a66" }\n`);
    assert.equal(change(f).status, 0);
    const next = readFileSync(f.file, 'utf8');
    assert.equal(JSON.parse(next).resources.staging, f.chosen);
    assert.ok(next.endsWith(', "untouched":"\\u6e2c\\u8a66" }\n'));
    if (resources !== '{}') assert.ok(next.includes('"untouched":"a\\\"b", "nested":{"staging":"keep"}'));
  }
});

test('unwritable folder: refused with reason, identity and folder unchanged', () => {
  const original = '{"deviceID":"fixture"}', f = fixture(original);
  chmodSync(f.chosen, 0o500);
  try {
    const result = change(f);
    assert.equal(result.status, 1);
    assert.match(result.stdout, /不可寫/);
    assert.equal(readFileSync(f.file, 'utf8'), original);
    assert.deepEqual(readdirSync(f.chosen), []);
  } finally { chmodSync(f.chosen, 0o700); }
});

test('reset clears custom value, computes default from entrance, and keeps other bytes', () => {
  const f = fixture('{"resources":{"entry":"keep", "staging":"old"},"name":"fixture"}\n');
  assert.equal(change(f).status, 0);
  const before = readFileSync(f.file, 'utf8');
  const result = change(f, 'reset');
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(readFileSync(f.file, 'utf8'), before.replace(JSON.stringify(f.chosen), JSON.stringify(join(f.root, 'staging'))));
  assert.ok(existsSync(join(f.root, 'staging')));
});

test('atomic write interrupted by file size limit leaves original intact and no partial file', () => {
  const original = '{"deviceID":"fixture","padding":"keep this complete identity"}\n', f = fixture(original);
  const result = change(f, 'fail-midwrite');
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.equal(readFileSync(f.file, 'utf8'), original);
  assert.deepEqual(readdirSync(f.root).sort(), ['custom work', 'device.json']);
});

test('malformed resources and duplicate staging keys fail without changing the file', () => {
  for (const original of ['{"resources":null}', '{"resources":{"staging":"a","staging":"b"}}', '{"resources":[]}', '{invalid']) {
    const f = fixture(original), result = change(f);
    assert.equal(result.status, 1, original + result.stdout + result.stderr);
    assert.equal(readFileSync(f.file, 'utf8'), original);
  }
});

test('real settings pages: light/dark screenshots, order, status, conditional reset and validation messages', () => {
  const app = process.env.TATWO2_TEST_BINARY ?? resolve('.build/debug/Tatwo2');
  assert.ok(existsSync(app), 'build with verify.sh first');
  const root = mkdtempSync('/private/tmp/w284-ui-');
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) mkdirSync(join(root, dir), { recursive: true });
  const env = { ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
    TATWO_STAGING_SCRATCH_HOME: join(root, 'home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'engines'),
    CODEX_HOME: join(root, 'engines/codex'), TATWO2_CODEX_SOURCE_HOME: join(root, 'engines/codex'),
    CLAUDE_CONFIG_DIR: join(root, 'engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: join(root, 'engines/claude'),
    TATWO2_OS_SOCKET: join(root, 'o.sock'), TATWO2_BROWSER_SOCKET: join(root, 'b.sock'),
    TATWO2_OS_ROOT: join(root, 'os'), TATWO2_DOCS_ROOT: join(root, 'docs'),
    TATWO2_OS_UPSTREAM_PATH: join(root, 'os/os-upstream.md'), TATWO2_SKILLET_PATH: join(root, 'os/skillet.md'),
    TATWO2_SELFTEST: 'w284', TATWO2_SELFTEST_ARTIFACTS: join(root, 'artifacts') };
  delete env.TATWO_OS_ROOT;
  const result = run(app, [], { env });
  writeFileSync(join(scratch, 'ui.log'), result.stdout + result.stderr);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W284 SUMMARY failures=0 passed=[1-9]/);
  for (const name of ['W352-status-and-queue-use-current-workpath', 'W352-explicit-staging-environment-wins', 'W352-invalid-staging-environment-uses-workpath', 'W352-workpath-reset-updates-existing-queue']) assert.ok(result.stdout.includes('PASS ' + name), name);
  const destination = resolve('tests/fixtures/w284-shots');
  mkdirSync(destination, { recursive: true });
  for (const page of ['documents', 'getting-started', 'unwritable', 'low-space']) {
    for (const scheme of ['light', 'dark']) {
      const name = `${page}-${scheme}.png`;
      assert.ok(existsSync(join(root, 'artifacts', name)), name);
      copyFileSync(join(root, 'artifacts', name), join(destination, name));
    }
  }
});
