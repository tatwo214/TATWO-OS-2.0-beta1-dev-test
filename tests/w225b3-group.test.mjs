import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = p => readFileSync(new URL('../App/Sources/Tatwo2/Facade/' + p, import.meta.url), 'utf8');
test('1 existing native context is appended with group data after ultrawork', () => {
  const s = source('ChatLiveEngine.swift');
  assert.ok(/if let groupText = groupBridge.outgoing\[threadID\] \{ outgoing \+=/.test(s));
  assert.ok(s.indexOf('if let groupText = groupBridge.outgoing') > s.indexOf('let ultraworkTurn = ultraworkTurnBlock'));
});
test('2 route requires a real local thread and applies the existing trading classifier', () => {
  const s = source('GroupCoderBridge.swift');
  assert.ok(/let thread = owner.threadRecord\(threadID\)/.test(s));
  assert.ok(s.includes('HandsTradingFloor.classify') && s.includes('交易專案不開群組'));
  assert.ok(s.indexOf('HandsTradingFloor.classify') < s.indexOf('let ledgerURL'));
});
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
test('3+ real Swift group regression cases', {timeout: 120000}, () => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'w225b3-'));
  const bin = path.join(scratch, 'test');
  const root = fileURLToPath(new URL('..', import.meta.url));
  const c = spawnSync('swiftc', ['-parse-as-library', path.join(root, 'App/Sources/Tatwo2/Facade/GroupTurnEngine.swift'), path.join(root, 'tests/group-review-main.swift'), '-o', bin], {encoding:'utf8'});
  assert.equal(c.status, 0, c.stdout + c.stderr);
  const r = spawnSync(bin, [], {encoding:'utf8', timeout:60000});
  console.log(r.stdout);
  assert.equal(r.status, 0, r.stderr);
});
test('3 facade cannot automatically relay TAP input into a writable Coder turn', () => {
  assert.ok(source('GroupCoderBridge.swift').includes('group.canExchange = { $0 != primary }'));
});
