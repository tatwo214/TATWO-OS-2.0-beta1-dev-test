import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {nativeW298b} from './fixtures/w298b-native.mjs';

test('W298b real installer gates fake registry and binary adoption, rollback, SDK and daily UI', () => {
  const output = nativeW298b();
  for (const label of [
    'production rejects unsigned fake without execution',
    ...['signature-wrong','team-wrong','main-alias','native-integrity','version-fail','publish-version-fail','correct'].map(x => `Codex ${x} adoption gate`),
    'publication version failure preserves previous',
    'atomic rollback points to old binary', 'running conversation binary survives rollback',
    'rollback pin beats newer bundled or PATH runtime', 'rollback pin still enforces signature identity',
    'Claude sdk-fail restores user launcher', 'Claude sdk-fail records reason',
    'Claude signature-fail restores user launcher', 'Claude backup-sdk-fail restores user launcher', 'Claude validated SDK adopts immutable managed binary', 'Claude uses official update command',
    'Grok missing checksum stops without download or script',
    'daily check lights dot only and never installs', 'daily check persists cadence and dot across restart',
    'no new versions clears dot without message', 'real update button installs validated fake tarball',
    'real rollback button restores previous version',
  ]) assert.ok(output.includes(`W298B PASS ${label}`), label);
});


test('W298b selection, cancellation, renamed quota action and theme matrix', () => {
  const output = nativeW298b();
  for (const label of ['default selection checks versions without installing',
    'latest unknown and ChatGPT cannot select', 'selected logo accessible label',
    'real logo toggles selection', 'focused logo toggles with Space key', 'zero selection disables install',
    'zero selection never installs', 'cancel never installs', 'refresh quota renamed button',
    'selection resets on next check', 'unknown current cannot select even with newest version',
    ...['fable5-light-', 'fable5-dark-', 'aurora-light-', 'aurora-dark-'].map(x => `only selected installed and skipped summary ${x}`),
  ]) assert.ok(output.includes(`W298B PASS ${label}`), label);
});

test('W298b changed Swift adds no hardcoded RGB or hexadecimal colors', () => {
  const diff = execFileSync('git', ['diff', '9139ad50', '--', '*.swift'], {encoding: 'utf8'});
  const added = diff.split('\n').filter(x => x.startsWith('+') && !x.startsWith('+++')).join('\n');
  assert.doesNotMatch(added, /Color\s*\(\s*red\s*:|#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b|0x[0-9a-fA-F]{6,8}\b/);
});

for (const [id, label] of [
  [1, 'failed Claude update restores full version tree and exact launcher'],
  [2, 'verification uses private snapshot despite source mutation'],
  [3, 'rollback validation waits for in-flight update'],
  [4, 'only user rollback records explicit version pin'],
  [5, 'failed current publication preserves exact previous pointer'],
]) test(`W298b R${id} ${label}`, () => {
  const output = nativeW298b();
  assert.ok(output.includes(`W298B PASS R${id} ${label}`));
  if (id === 3) assert.ok(output.includes('W298B PASS R3 stale queued update cannot downgrade current'));
  if (id === 5) assert.ok(output.includes('W298B PASS R5 mid-publication rename failure restores both relative pointers'));
});

for (const [id, label] of [
  [1, 'existing valid version preserves every byte and inode'],
  [2, 'cancelled lock wait stops without consuming holder permit'],
  [3, 'restore failure still attempts remaining pointers and names failed step'],
  [4, 'updater config writes stay in private stage'],
]) test(`W298b B${id} ${label}`, () => {
  assert.ok(nativeW298b().includes(`W298B PASS B${id} ${label}`));
});

for (const label of [
  'newer succeeds and reports actual version',
  'actual published binary and previous retained',
  ...['older', 'same', 'below-checked', 'unsigned-newer', 'prerelease'].map(x => `${x} fails and restores launcher and version tree`),
  'unsigned actual rejected before version execution',
  'unselected Grok manual message and latest Claude unchanged',
]) test(`W314 ${label}`, () => {
  assert.ok(nativeW298b().includes(`W298B PASS W314 ${label}`));
});

test('W350 installer avoids unused main tarball and repeated validation', () => {
  const output = nativeW298b();
  assert.ok(output.includes('W298B PASS W350 unused main tarball never downloaded'));
  assert.ok(output.includes('W298B PASS W350 new Codex validated once before publication'));
});
