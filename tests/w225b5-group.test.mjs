import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
const scratch = mkdtempSync(path.join(tmpdir(), 'w225b5-'));
const binary = path.join(scratch, 'core');
const build = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-b5-main.swift'), '-o', binary], {encoding:'utf8'});
assert.equal(build.status, 0, build.stdout + build.stderr);
for (const item of ['1', '4', '6', '7']) test(`W225b5-${item} actual Swift regressions`, {timeout:60000}, () => {
  const run = spawnSync(binary, [item], {encoding:'utf8', timeout:50000});
  console.log(run.stdout);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
