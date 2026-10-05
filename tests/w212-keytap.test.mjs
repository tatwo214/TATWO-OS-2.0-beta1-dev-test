import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

function run(mode) {
  const root = testScratch('w212-keytap-');
  const binary = path.join(root, 'probe');
  const compiled = spawnSync('swiftc', [
    '-parse-as-library', 'App/Sources/Tatwo2/Display/DisplayKeyTap.swift',
    'tests/fixtures/w212-keytap.swift', '-o', binary,
  ], { encoding: 'utf8', timeout: 90_000 });
  assert.equal(compiled.status, 0, compiled.stdout + compiled.stderr);
  const env = { ...process.env, HOME: root, CFFIXED_USER_HOME: root, W212_LOG_TEST: mode };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 30_000 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(path.join(root, 'acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  return output;
}

test('W212 actual callback judgement stays immediate with main blocked and defers one adjustment', () => {
  const output = run('0');
  for (const key of ['brightnessUp', 'brightnessDown', 'volumeUp', 'volumeDown', 'mute']) {
    assert.ok(output.includes(`PASS ${key} intercepts while main blocked for two seconds`), output);
    assert.ok(output.includes(`PASS ${key} adjustment waits for main`), output);
    assert.ok(output.includes(`PASS ${key} adjusts once on main after unblock`), output);
  }
  assert.ok(output.includes('W212 SUMMARY failures=0'), output);
});

test('W212 supported pass reasons append; undecodable events are silent and periodic trimming retains 200', () => {
  const output = run('1');
  for (const reason of [
    'keyboard_off', 'no_permission', 'refreshing', 'mouse_display_unknown',
    'display_not_controllable', 'display_apple_native', 'volume_not_routed',
  ]) assert.ok(output.includes(`PASS ${reason} writes matching reason and target`), output);
  for (const behavior of [
    'one row per supported media event', 'rows contain timestamp and only four diagnostic fields',
    'unrelated media key writes no row', 'handled events write matching rows',
    'undecodable events write no row', 'normal append preserves open file identity',
    'between periodic checks appends without rewriting',
    'log retains exactly last 200 rows', 'log discards oldest rows and preserves event order',
  ]) assert.ok(output.includes(`PASS ${behavior}`), output);
  assert.ok(output.includes('W212LOG SUMMARY failures=0'), output);
});
