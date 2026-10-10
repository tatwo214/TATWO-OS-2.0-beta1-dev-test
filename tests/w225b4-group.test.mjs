import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
test('W225b4 actual group engine with fake participants', {timeout:120000}, () => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'w225b4-group-'));
  const binary = path.join(scratch, 'test');
  const build = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-fixes-main.swift'), '-o', binary], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], {encoding:'utf8', timeout:60000});
  writeFileSync(path.join(scratch, 'result.log'), run.stdout + run.stderr);
  console.log(run.stdout);
  assert.equal(run.status, 0, run.stderr);
});

test('W225b4 composer admits busy group and bypasses native steering', () => {
  const page = readFileSync(path.join(root, 'App/Sources/Tatwo2/Facade/ChatPageModel.swift'), 'utf8');
  assert.ok(/canQueueCurrentGroup/.test(page), "busy group composer admission");
  assert.ok(/activeLive\.isRunning\(id\) && !wasGroupBusy/.test(page), "busy group bypasses steering");
  assert.ok(page.includes("群組這句未能排隊，草稿已保留"), "queue rejection reason");
});
