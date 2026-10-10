import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
test('W229 real group lifecycle emits membership and transfer events and preserves Ledger', () => {
  const binary = path.join(mkdtempSync(path.join(tmpdir(), 'w229-events-')), 'check');
  const build = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-events-main.swift'), '-o', binary], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PASS join=1 transfer=1 leave=1 away=1 reconnect=2 ledger-preserved/);
});
test('W229 group log uses project ID, stable metadata notes and local append API', () => {
  const source = readFileSync(path.join(root, 'App/Sources/Tatwo2/Events/OSEventSources.swift'), 'utf8');
  const hook = source.slice(source.indexOf('func eventsGroup('), source.indexOf('func eventsFinished('));
  assert.ok(hook.includes('events.append(project: eventProject(thread)'));
  assert.match(hook, /note: "群組 " \+ event.kind/);
  assert.doesNotMatch(hook, /sizeText:|note:.*event.text|transcript\(for:/);
  const bridge = readFileSync(path.join(root, 'App/Sources/Tatwo2/Facade/GroupCoderBridge.swift'), 'utf8');
  assert.match(bridge, /owner\?\.eventsGroup\(threadID, event/);
  assert.match(bridge, /try group.snapshot\(\).write/);
});
