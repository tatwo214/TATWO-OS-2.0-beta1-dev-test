import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { runIsolated } from './helpers/w187-runtime.mjs';

test('signed device row retains native offline status, retry and cancel controls in both appearances', { timeout: 240_000 }, () => {
  const { root, output } = runIsolated('w221bdevices');
  assert.match(output, /W221BDEVICES SUMMARY passed=[1-9]\d* failures=0/);
  assert.match(output, /W221BDEVICES PASS W221b offline device row belongs to the verified roster/);
  for (const appearance of ['light', 'dark']) {
    assert.match(output, new RegExp(`W221BDEVICES PASS W201 ${appearance} actual settings cancel updates the count`));
    for (const state of ['collapsed', 'expanded']) {
      const png = path.join(root, 'artifacts/w201-quiet-devices', `settings-devices-${state}-${appearance}.png`);
      assert.ok(fs.statSync(png).size > 1000);
    }
  }
});
