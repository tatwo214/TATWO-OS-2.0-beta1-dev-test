import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeW298a } from './fixtures/w298a-native.mjs';

for (const scenario of ['newer', 'older', 'uncached-true', 'uncached-false']) {
  test(`W315 ${scenario}: opening login reconciles the actual dot, rows and fake defaults offline`, () => {
    const output = nativeW298a();
    for (const label of ['page dot and persisted availability', 'page versionLine', 'local refresh preserves network cadence']) {
      assert.ok(output.includes(`W298A PASS W315 ${scenario} ${label}`), label);
    }
  });
}
test('W315 reopening observes an external CLI update; latest cache and daily gate persist', () => {
  const output = nativeW298a();
  for (const label of ['reopen observes external CLI update', 'background stores each known newest',
    'daily network gate unchanged', 'failed lookup retains newest cache',
    'local probe and background check cannot race', 'background check resumes after local probe',
    'fake CLI only reads local version with auto updater disabled']) {
    assert.ok(output.includes(`W298A PASS W315 ${label}`), label);
  }
});
