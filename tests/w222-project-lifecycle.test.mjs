import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';
test('W350 removed rename command cannot write to ChatGPT', async () => {
  const p = fixture();
  p.command({ cmd: 'renameProject', id: 'rename', projectID: 'g-p-fixture', name: 'sample' });
  await p.advance(100);
  assert.equal(p.requests.length, 0);
  assert.equal(p.reports.find(r => r.id === 'rename')?.ok, false);
});
