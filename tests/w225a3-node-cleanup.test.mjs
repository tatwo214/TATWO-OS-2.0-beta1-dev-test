import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';

const source = fs.readFileSync(new URL('./w185-tools.test.mjs', import.meta.url), 'utf8');
const start = source.indexOf("test('compiled w185tools executable selftest");
const end = source.indexOf("\ntest('", start + 5);
const callbackSource = source.slice(start, end);

for (const mode of ['success', 'assertion failure', 'spawn exception', 'copy exception', 'supplied node', 'Homebrew node']) {
  test(`w185 fixture node cleanup: ${mode}`, () => {
    let callback, owned, copied = false;
    const removed = [];
    const fixtureFS = {
      realpathSync: value => value,
      mkdtempSync: prefix => {
        const value = prefix + 'owned-fixture';
        if (prefix.includes('w185-node-')) owned = value;
        return value;
      },
      existsSync: value => value === '/fake/Tatwo2' || (mode === 'Homebrew node' && value === '/opt/homebrew/bin/node'),
      mkdirSync() {}, chmodSync() {}, writeFileSync() {},
      copyFileSync() { if (mode === 'copy exception') throw new Error('copy fixture failed'); copied = true; },
      rmSync(value) { removed.push(value); },
    };
    const context = {
      fs: fixtureFS, path, os: { tmpdir: () => '/private/tmp' }, assert,
      process: { execPath: '/fixture/source-node', env: {
        TATWO2_TEST_BINARY: '/fake/Tatwo2',
        ...(mode === 'supplied node' ? { TATWO2_SELFTEST_NODE: '/caller/node' } : {}),
      } },
      console: { log() {} },
      test: (_name, _options, fn) => { callback = fn; },
      spawnSync: () => {
        if (mode === 'spawn exception') throw new Error('spawn fixture failed');
        return { status: mode === 'assertion failure' ? 1 : 0, stderr: '', stdout:
          'W185CU SUMMARY passed=1 failures=0\nW185TOOLS SUMMARY passed=1 failures=0\n' };
      },
    };
    vm.runInNewContext(callbackSource, context);
    if (['assertion failure', 'spawn exception', 'copy exception'].includes(mode)) assert.throws(callback);
    else callback();
    if (['supplied node', 'Homebrew node'].includes(mode)) {
      assert.equal(owned, undefined);
      assert.equal(copied, false);
      assert.deepEqual(removed, [], 'caller or system node must remain untouched');
    } else {
      assert.ok(owned?.startsWith('/private/tmp/w185-node-'));
      assert.deepEqual(removed, [owned], 'remove exactly the directory this test allocated, including on failure');
    }
  });
}
