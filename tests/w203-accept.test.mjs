// W203 regression contracts; synthetic data only. Native behavior and screenshots
// are exercised by w185tap, w179dm, w198dispatch and w199quiet.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { script } from './w185-pod-fixture.mjs';
const syntheticMailbox = 'fixture' + String.fromCharCode(64) + 'example.invalid';
const read = p => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const section = (s, a, b) => s.slice(s.indexOf(a), s.indexOf(b, s.indexOf(a)));

test('W203-3 git add -A cannot stage dispatch replies even in nested rooms', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'w203-git-'));
  try {
    fs.writeFileSync(path.join(root, '.gitignore'), read('.gitignore'));
    const reply = path.join(root, 'rooms/fixture/chatgpt-dispatch/fixture.md');
    fs.mkdirSync(path.dirname(reply), { recursive: true });
    fs.writeFileSync(reply, 'synthetic private response');
    for (const args of [['init', '-q'], ['add', '-A']]) assert.equal(spawnSync('git', args, { cwd: root }).status, 0);
    const staged = spawnSync('git', ['diff', '--cached', '--name-only'], { cwd: root, encoding: 'utf8' });
    assert.equal(staged.status, 0);
    assert.doesNotMatch(staged.stdout, /fixture\.md/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('W203-4 real Pod localText masks short passwords, paths, email and phone before truncating', () => {
  const source = section(script, 'const localText =', 'const tooLong =');
  const clean = vm.runInNewContext(`(() => { ${source}; return localText; })()`);
  for (const secret of ['password=abc', '"password":"xyz"', '/Users/fixture/private.txt', '/Volumes/fixture/private.txt',
    syntheticMailbox, '+886 912 345 678', '0912-345-678']) {
    assert.doesNotMatch(clean('synthetic error ' + secret), new RegExp(secret.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.ok(Array.from(clean('錯'.repeat(200))).length <= 160);
  assert.doesNotMatch(clean('error password="short secret phrase" tail'), /short|secret|phrase/);
  assert.doesNotMatch(clean('error "token":"SHORT_SECRET'), /SHORT_SECRET/);
  assert.doesNotMatch(clean('error password="first\nsecond" tail'), /first|second/);
  assert.doesNotMatch(clean('error phone=2025550143 phone=12345678 tail'), /2025550143|12345678/);
});
