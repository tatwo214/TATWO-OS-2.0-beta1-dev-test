import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
test('W225 group: actual Swift engine, fake participants, no network', {timeout: 120000}, () => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'w225-group-'));
  const binary = path.join(scratch, 'group-test');
  const compile = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-turn-main.swift'), '-o', binary], {encoding:'utf8'});
  assert.equal(compile.status, 0, compile.stdout + compile.stderr);
  const run = spawnSync(binary, [], {encoding:'utf8', timeout: 60000});
  writeFileSync(path.join(scratch, 'result.log'), run.stdout + run.stderr);
  console.log(run.stdout.split("\n").filter(line => /ACCOUNT|SUMMARY|FAIL/.test(line)).join("\n"));
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /W225CORE SUMMARY failures=0/);
});
