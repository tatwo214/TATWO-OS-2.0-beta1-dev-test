import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const runner = fileURLToPath(new URL('../scripts/rooms/thrice-candidate-full.sh', import.meta.url));

// These are process-orchestration fixtures, not substitute App acceptance.
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'thrice-wrapper-'));
  const repo = path.join(root, 'candidate with spaces');
  const staging = path.join(root, 'staging');
  const bin = path.join(root, 'tools');
  const product = path.join(root, 'SwiftBuild Products');
  for (const dir of [path.join(repo, 'scripts'), path.join(staging, 'rooms'), bin, product, path.join(root, 'cef/include')]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const executable = (file, text) => fs.writeFileSync(file, '#!/bin/bash\n' + text + '\n', { mode: 0o755 });
  executable(path.join(bin, 'swift'), `
echo "$*" >> "$FIXTURE_ROOT/swift-calls"
if [[ "$*" == *"--show-bin-path"* ]]; then printf '%s\\n' "$FIXTURE_PRODUCT"; exit 0; fi
if [ "\${FIXTURE_BUILD_EXIT:-0}" != 0 ]; then exit "$FIXTURE_BUILD_EXIT"; fi
printf '#!/bin/bash\\nexit 0\\n' > "$FIXTURE_PRODUCT/Tatwo2"
chmod +x "$FIXTURE_PRODUCT/Tatwo2"
`);
  executable(path.join(bin, 'git'), `
if [ "$1" = diff ]; then exit "\${FIXTURE_DIRTY:-0}"; fi
if [ "$1" = rev-parse ]; then
  if [ -f "$FIXTURE_ROOT/head-read" ] && [ "\${FIXTURE_DRIFT:-0}" = 1 ]; then
    echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  else echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
  touch "$FIXTURE_ROOT/head-read"
  exit 0
fi
exit 99
`);
  for (const tool of ['node', 'rg', 'python3']) executable(path.join(bin, tool), 'exit 0');
  executable(path.join(repo, 'scripts/tatwo-test-thrice.sh'), `
printf '%s\\n' "$TATWO2_TEST_BINARY" "$TATWO_BROWSER_ADDRESS_NATIVE" "$TATWO_BROWSER_TABS_NATIVE" "$TATWO_W67_NATIVE" "$TATWO_CLI_UI_RENDER" "$1" > "$FIXTURE_ROOT/suite-called"
exit "\${FIXTURE_SUITE_EXIT:-0}"
`);
  const helper = path.join(root, 'gbrain-helper');
  executable(helper, 'exit 0');
  for (const file of ['release.json', 'asset', 'LICENSE', 'cef/include/cef_app.h']) {
    fs.writeFileSync(path.join(root, file), 'unit fixture only');
  }
  const out = path.join(root, 'new-evidence');
  const env = {
    ...process.env, TATWO_STAGING: staging, TATWO_BUILD_PATH: bin,
    TATWO_TEST_TMPDIR: path.join(staging, 'tmp/unit'),
    W80B_GBRAIN_HELPER: helper, W80B_RELEASE_JSON: path.join(root, 'release.json'),
    W80B_ASSET: path.join(root, 'asset'), W80B_LICENSE: path.join(root, 'LICENSE'),
    TATWO_CEF_ROOT: path.join(root, 'cef'), FIXTURE_ROOT: root, FIXTURE_PRODUCT: product,
  };
  return { root, repo, staging, product, out, env,
    run(overrides = {}) {
      return spawnSync('/bin/bash', [runner, repo, out], {
        env: { ...env, ...overrides }, encoding: 'utf8', timeout: 10_000,
      });
    },
  };
}

test('full runner resolves the current SwiftPM product and enables native acceptance', () => {
  const f = fixture(), r = f.run();
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(fs.readFileSync(path.join(f.root, 'suite-called'), 'utf8').trim().split('\n'),
    [path.join(f.product, 'Tatwo2'), '1', '1', '1', '1', f.out]);
  assert.ok(!fs.existsSync(path.join(f.staging, 'rooms/.build-lock')));
});

test('failed build never executes tests using an existing stale product', () => {
  const f = fixture();
  fs.writeFileSync(path.join(f.product, 'Tatwo2'), 'stale product');
  const r = f.run({ FIXTURE_BUILD_EXIT: '7' });
  assert.equal(r.status, 7, r.stderr);
  assert.ok(!fs.existsSync(path.join(f.root, 'suite-called')));
  assert.equal(fs.readFileSync(path.join(f.product, 'Tatwo2'), 'utf8'), 'stale product');
  assert.ok(!fs.existsSync(path.join(f.staging, 'rooms/.build-lock')));
});

test('full-suite failure remains nonzero rather than the final echo masking it', () => {
  const r = fixture().run({ FIXTURE_SUITE_EXIT: '1' });
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stdout, /EXIT=1/);
  assert.doesNotMatch(r.stdout, /EXIT=0/);
});

test('previous evidence is preserved and no build runs', () => {
  const f = fixture();
  fs.mkdirSync(f.out); fs.writeFileSync(path.join(f.out, 'receipt'), 'retain me');
  assert.equal(f.run().status, 2);
  assert.equal(fs.readFileSync(path.join(f.out, 'receipt'), 'utf8'), 'retain me');
  assert.ok(!fs.existsSync(path.join(f.root, 'swift-calls')));
});

test('missing fixture cannot silently disable full acceptance', () => {
  const f = fixture(), r = f.run({ W80B_GBRAIN_HELPER: path.join(f.root, 'absent-helper') });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Missing full-suite fixture/);
  assert.ok(!fs.existsSync(path.join(f.root, 'swift-calls')));
});

test('existing build lock remains owned by the other job', () => {
  const f = fixture(), lock = path.join(f.staging, 'rooms/.build-lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'pid'), '1');
  fs.writeFileSync(path.join(lock, 'owner'), 'other active work');
  assert.equal(f.run().status, 2);
  assert.equal(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), 'other active work');
  assert.ok(!fs.existsSync(path.join(f.root, 'swift-calls')));
});

test('dirty source or source drift does not produce acceptance results', () => {
  for (const variable of ['FIXTURE_DIRTY', 'FIXTURE_DRIFT']) {
    const f = fixture(), r = f.run({ [variable]: '1' });
    assert.equal(r.status, 2, r.stderr);
    assert.ok(!fs.existsSync(path.join(f.root, 'suite-called')));
    assert.ok(!fs.existsSync(path.join(f.staging, 'rooms/.build-lock')));
  }
});
