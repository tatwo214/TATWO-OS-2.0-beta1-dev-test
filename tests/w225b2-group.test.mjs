import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
test('W225b2: real group engine, fake clock and TAP adapters', {timeout:120000}, () => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'w225b2-'));
  const binary = path.join(scratch, 'group-test');
  const compile = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-reconnect-main.swift'), '-o', binary], {encoding:'utf8'});
  assert.equal(compile.status, 0, compile.stdout + compile.stderr);
  const run = spawnSync(binary, [], {encoding:'utf8', timeout:60000});
  writeFileSync(path.join(scratch, 'result.log'), run.stdout + run.stderr);
  console.log(run.stdout);
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /W225B2CORE SUMMARY failures=0/);
});
