import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, utimesSync, symlinkSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const install = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const backup = install.slice(install.indexOf('LIVE_DOC="$HOME/'), install.indexOf('EXPECTED_RELEASE_SHA=', install.indexOf('LIVE_DOC="$HOME/')));
function fixture(t) {
  const home = mkdtempSync(join(tmpdir(), 'w191-fixture-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const live = join(home, 'Library/Application Support/tatwo2/live');
  mkdirSync(live, { recursive: true });
  writeFileSync(join(live, 'document.json'), 'sample transcript');
  return { home, live };
}
function run(home, fault = '') {
  return spawnSync('bash', ['-c', `set -eu
    fail() { echo "$1" >&2; exit 1; }
    OLD_VERSION=fixture
    ${fault}
    ${backup}
    touch "$HOME/switched"
  `], { encoding: 'utf8', env: { ...process.env, HOME: home } });
}
for (const [name, fault] of [
  ['copy failure', 'cp() { return 1; }'],
  ['directory failure', 'mkdir() { return 1; }'],
  ['corrupt copy', 'cp() { command cp "$@"; printf changed > "${@: -1}"; }'],
]) {
  test(`M2 ${name} stops installation with a plain reason`, t => {
    const { home, live } = fixture(t);
    const result = run(home, fault);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /對話.*備份|對話.*另存|對話.*比對/);
    assert.ok(!existsSync(join(home, 'switched')));
    assert.equal(readFileSync(join(live, 'document.json'), 'utf8'), 'sample transcript');
  });
}
test('M2 backup names are unique within a second and newest five sort by filename despite old mtimes', t => {
  const { home, live } = fixture(t);
  const directory = join(live, 'backups');
  mkdirSync(directory);
  for (let i = 0; i < 5; i++) {
    const file = join(directory, `document-20000101-000000-${i}.json`);
    writeFileSync(file, 'old sample');
    utimesSync(file, new Date('2030-01-01'), new Date('2030-01-01'));
  }
  const fault = `date() { printf '20261003-010203\\n'; }
    uuidgen() {
      count=0; if [[ -f "$HOME/counter" ]]; then read -r count < "$HOME/counter"; fi
      count=$((count+1)); echo "$count" > "$HOME/counter"
      printf '00000000-0000-0000-0000-%012d\\n' "$count"
    }`;
  for (let i = 1; i <= 8; i++) {
    const result = run(home, fault);
    assert.equal(result.status, 0, result.stderr);
  }
  const names = readdirSync(directory).sort();
  assert.deepEqual(names, [4, 5, 6, 7, 8].map(i => `document-20261003-010203-00000000-0000-0000-0000-${String(i).padStart(12, '0')}.json`));
  for (const name of names) assert.equal(readFileSync(join(directory, name), 'utf8'), 'sample transcript');
});
test('M2 no document can proceed; a document symlink is refused', t => {
  const { home, live } = fixture(t);
  const document = join(live, 'document.json');
  rmSync(document);
  assert.equal(run(home).status, 0);
  rmSync(join(home, 'switched'));
  const sample = join(home, 'sample.json'); writeFileSync(sample, 'sample');
  symlinkSync(sample, document);
  assert.equal(run(home).status, 1);
  assert.equal(readFileSync(sample, 'utf8'), 'sample');
  assert.ok(!existsSync(join(home, 'switched')));
});
test('M2 an inaccessible parent must not disguise an existing document as absent', t => {
  const { home, live } = fixture(t);
  chmodSync(live, 0o000);
  let result;
  try { result = run(home); } finally { chmodSync(live, 0o700); }
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /對話.*確認|對話.*權限/);
  assert.ok(!existsSync(join(home, 'switched')));
  assert.equal(readFileSync(join(live, 'document.json'), 'utf8'), 'sample transcript');
});
test('M2 public installer is byte identical and both scripts parse', () => {
  assert.deepEqual(readFileSync(new URL('../install.sh', import.meta.url)), readFileSync(new URL('../public/install.sh', import.meta.url)));
  for (const file of ['../install.sh', '../public/install.sh']) {
    const result = spawnSync('bash', ['-n', fileURLToPath(new URL(file, import.meta.url))]);
    assert.equal(result.status, 0);
  }
});

test('S2 mixed local-time legacy names cannot prune the current UTC backup', t => {
  const { home, live } = fixture(t);
  const directory = join(live, 'backups');
  mkdirSync(directory);
  const oldNames = [3,4,5,6,7].map(hour => `document-20261003-0${hour}0000-from-fixture.json`);
  for (const name of oldNames) writeFileSync(join(directory, name), 'old sample');
  const result = run(home, `date() { printf '20261003-020000\\n'; }
    uuidgen() { printf '00000000-0000-0000-0000-000000000192\\n'; }`);
  assert.equal(result.status, 0, result.stderr);
  const current = 'document-20261003-020000-00000000-0000-0000-0000-000000000192.json';
  assert.ok(existsSync(join(directory, current)), 'current UTC backup was pruned');
  assert.equal(readFileSync(join(directory, current), 'utf8'), readFileSync(join(live, 'document.json'), 'utf8'));
  assert.deepEqual(readdirSync(directory).sort(), [current, ...oldNames.slice(1)].sort());
});
test('S2 corruption or removal during pruning stops installation after the final comparison', t => {
  for (const action of ['remove', 'corrupt']) {
    const { home, live } = fixture(t);
    const directory = join(live, 'backups'); mkdirSync(directory);
    for (let i=0;i<5;i++) writeFileSync(join(directory, `document-20000101-00000${i}-from-fixture.json`), 'old sample');
    const result = run(home, `rm() {
      command rm "$@"
      for file in "$HOME/Library/Application Support/tatwo2/live/backups/"document-20261003-*.json; do
        ${action === 'remove' ? 'command rm -f "$file"' : 'printf changed > "$file"'}
      done
    }
    date() { printf '20261003-020000\\n'; }`);
    assert.equal(result.status, 1, result.stderr);
    assert.ok(!existsSync(join(home, 'switched')));
    assert.equal(readFileSync(join(live, 'document.json'), 'utf8'), 'sample transcript');
  }
});
