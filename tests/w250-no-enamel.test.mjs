import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative } from 'node:path';
import { execFileSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? files(path) : [path];
  });
}
test('W250 App/Sources contains no removed enamel types', () => {
  const hits = files(join(root, 'App/Sources')).filter(path =>
    /EnamelPlate|EnamelStandard|EnamelChip|W220EnamelAcceptance/.test(readFileSync(path, 'utf8')));
  assert.deepEqual(hits.map(path => relative(root, path)), []);
});
test('W250 picker and browser design checks exactly match v2.0.22', () => {
  for (const path of ['App/Sources/Tatwo2/Shell/WorkspaceSidebarModePicker.swift', 'tests/browser-workspace-design.test.mjs']) {
    assert.deepEqual(readFileSync(join(root, path)), execFileSync('git', ['show', `531a6d6a:${path}`], { cwd: root }), path);
  }
});
test('W250 removes enamel registration and fixtures and registers picker acceptance', () => {
  const registry = readFileSync(join(root, 'App/Sources/Tatwo2/SelfTest.swift'), 'utf8');
  assert.doesNotMatch(registry, /w220enamel/);
  assert.match(registry, /"w250picker".*W250PickerAcceptance\.run/);
  for (const path of ['App/Sources/Tatwo2/Visual/EnamelStandard.swift', 'App/Sources/Tatwo2/Visual/EnamelPlate.swift',
    'App/Sources/Tatwo2/Visual/W220EnamelAcceptance.swift', 'tests/fixtures/w220-standard.json',
    'tests/fixtures/w220b-browser-baseline.json', 'tests/fixtures/w220-room-allow.txt']) {
    assert.equal(existsSync(join(root, path)), false, path);
  }
});
