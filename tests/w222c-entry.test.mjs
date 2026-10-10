import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
test('W222c-5 no orphan project rename/restore functions remain in product engine', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  assert.equal(engine.includes('func renameProject('), false);
  assert.equal(engine.includes('func restoreProject('), false);
});
test('W222c-5 existing project-space actions still change space records only', () => {
  const spaces = read('Facade/CoderProjectSpaces.swift');
  for (const action of ['rename', 'archive', 'restore']) assert.match(spaces, new RegExp(`func ${action}\\(`));
  assert.equal(spaces.includes('syncProjectName'), false);
  const screen = read('New/CoderProjectSpaceSwitcher.swift');
  for (const action of ['rename', 'archive', 'restore']) assert.ok(screen.includes(`spaces.${action}(`));
});
