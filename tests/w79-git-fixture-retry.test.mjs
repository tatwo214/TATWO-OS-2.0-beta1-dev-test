import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

test('W79 lock retries never repeat branch creation inside worktree add', () => {
  const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OSBindingAcceptance.swift', import.meta.url), 'utf8');
  for (const [branch, destination] of [
    ['friction-child', 'roomPath'],
    ['friction-ff', 'root + "/ff-room"'],
  ]) {
    const creation = `_ = try git(["branch", "${branch}"])`;
    const addition = `_ = try git(["worktree", "add", ${destination}, "${branch}"])`;
    const sequence = creation + '\n            ' + addition;
    assert.ok(source.includes(sequence), `${branch}: create once, retry attachment separately`);
    assert.ok(!source.includes(`["worktree", "add", "-b", "${branch}"`));
    assert.ok(!source.replace(creation, '').includes(sequence), 'missing branch creation rejected');
    assert.ok(!source.replace(addition, `_ = try git(["worktree", "add", "-b", "${branch}", ${destination}])`).includes(sequence),
      'non-idempotent combined retry rejected');
  }
  assert.match(source, /guard lastError\.contains\("\.lock"\), attempt < 5 else \{ break \}/);
  const harness = readFileSync(new URL('./w79-generators.test.mjs', import.meta.url), 'utf8');
  assert.match(harness, /writeFileSync\(join\(root, flag \+ '\.log'\), error\.stdout \?\? ''\)/);
  assert.match(harness, /writeFileSync\(join\(root, flag \+ '\.stderr\.log'\), error\.stderr \?\? ''\)/);
  assert.match(harness, /console\.error\(`\$\{flag\} failed; isolated evidence retained at \$\{root\}`\);\s*throw error;/);
});
