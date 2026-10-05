import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeW214 } from './w214-native-fixture.mjs';
import { makePage } from './w185-pod-fixture.mjs';

for (const step of [1, 2, 3, 4, 5, 6, 7, 8, 9]) {
  test(`W214-${step}: production behavior and native accessibility tree`, () => {
    assert.match(nativeW214(step), new RegExp(`W214 PASS N${step}\\.`));
  });
}

test('external project added on another device is returned by the real Pod catalog script', async () => {
  const routes = { '/backend-api/gizmos/snorlax/sidebar': { items: [] } };
  const pod = makePage({ routes });
  await pod.signIn();
  assert.deepEqual((await pod.command({ cmd: 'projects' })).data.items, []);
  routes['/backend-api/gizmos/snorlax/sidebar'].items.push({
    resource: { gizmo: { id: 'g-p-mobile-fixture', display: { name: '手機新增', description: '' } } },
  });
  const reply = await pod.command({ cmd: 'projects' });
  assert.equal(reply.ok, true);
  assert.ok(reply.data.items.some(project => project.id === 'g-p-mobile-fixture' && project.title === '手機新增'));
});
