import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
test('W225b4 miscellaneous actual group regressions', {timeout:120000}, () => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'w225b4-misc-'));
  const binary = path.join(scratch, 'test');
  const build = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-misc-main.swift'), '-o', binary], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], {encoding:'utf8', timeout:60000});
  writeFileSync(path.join(scratch, 'result.log'), run.stdout + run.stderr);
  console.log(run.stdout);
  assert.equal(run.status, 0, run.stderr);
});

test('W225b4 explicit lifecycle and Coder relay entries exist without dead conversation hook', () => {
  const bridge = readFileSync(path.join(root, 'App/Sources/Tatwo2/Facade/GroupCoderBridge.swift'), 'utf8');
  const engine = readFileSync(path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), 'utf8');
  assert.ok(bridge.includes('func end('), 'end group entry');
  assert.ok(bridge.includes('func forwardToCoder('), 'human Coder relay entry');
  assert.ok(bridge.includes('moveItem'), 'bad ledger archived by rename');
  assert.ok(!engine.includes('hasConversation'), 'unused conversation hook removed');
});
