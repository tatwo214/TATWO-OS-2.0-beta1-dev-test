import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('W227-2 each fresh process trims an oversized diagnostic log on its first event', () => {
  const root = testScratch('w227-keylog-'), binary = path.join(root, 'probe');
  const compiled = spawnSync('swiftc', ['-parse-as-library',
    'App/Sources/Tatwo2/Display/DisplayKeyTap.swift', 'tests/fixtures/w212-keytap.swift', '-o', binary],
    { encoding: 'utf8', timeout: 90_000 });
  assert.equal(compiled.status, 0, compiled.stdout + compiled.stderr);
  const log = path.join(root, 'Library/Application Support/tatwo2/logs/display-keys.log');
  fs.mkdirSync(path.dirname(log), { recursive: true });
  fs.writeFileSync(log, Array.from({ length: 225 }, (_, i) => `fixture-${i}`).join('\n') + '\n');
  for (let launch = 1; launch <= 3; launch++) {
    const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 10_000,
      env: { ...process.env, HOME: root, CFFIXED_USER_HOME: root, W212_LOG_TEST: '2', W227_DISPLAY_ID: String(launch) } });
    fs.writeFileSync(path.join(root, `launch-${launch}.log`), result.stdout + result.stderr);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const rows = fs.readFileSync(log, 'utf8').trimEnd().split('\n');
    assert.equal(rows.length, 200, `launch ${launch} must trim before 50 writes`);
    assert.equal(rows[0], `fixture-${25 + launch}`, 'retain the newest rows in order');
    for (let id = 1; id <= launch; id++) assert.ok(rows.some(row => row.endsWith(`display=${id}`)));
    assert.ok(rows.at(-1).endsWith(`display=${launch}`));
  }
});
