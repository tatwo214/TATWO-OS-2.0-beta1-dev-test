import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('W227-5 docs contain no concrete local account paths', () => {
  const root = new URL('../docs/', import.meta.url);
  const violations = fs.readdirSync(root, { recursive: true }).filter(name => {
    const file = new URL(name, root);
    if (!fs.lstatSync(file).isFile()) return false;
    const data = fs.readFileSync(file);
    // Match literal paths; privacy scanner regexes (such as an account followed by \b) stay intact.
    return !data.includes(0) && /\/Users\/(?:[A-Za-z0-9._-]+(?=\/|[\s`"']|$)|…)/.test(data.toString('utf8'));
  });
  assert.deepEqual(violations, [], 'use ~/ instead of a local account name');
});
