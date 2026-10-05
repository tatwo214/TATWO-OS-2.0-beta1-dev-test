import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { source } from './w185-pod-fixture.mjs';

// Run the production command with an in-memory API; no real browser or account.
function createFixture(reply) {
  const definitions = source.slice(source.indexOf('const gizmoOf ='), source.indexOf('const pinOf ='));
  const handler = source.slice(source.indexOf('createProject: async (c) => {'), source.indexOf('projectDetails: async (c) => {'));
  const calls = [];
  const create = vm.runInNewContext(`${definitions}\n({${handler}}).createProject`, {
    apiSend: async (method, path, body) => {
      calls.push({ method, path, body: JSON.parse(JSON.stringify(body)) });
      return reply(method, path, body);
    },
  });
  return { create, calls };
}
const folder = (id, name, description = '') => ({ resource: { gizmo: { id, display: { name, description } }, files: [] } });

test('W216 negative: ordinary Space project accepts a name without OS mapping metadata', async () => {
  const { create, calls } = createFixture((method, path, body) => folder('g-p-new', body.name));
  const result = await create({ name: '  新專案  ', description: '' });
  assert.equal(result.id, 'g-p-new');
  assert.equal(result.title, '新專案');
  assert.equal(result.kind, 'project');
  assert.deepEqual(calls, [{ method: 'POST', path: '/backend-api/projects',
    body: { name: '新專案', instructions: '', memory_scope: 'unset' } }]);
});

test('W216 negative: empty and whitespace names never call API', async () => {
  const { create, calls } = createFixture(() => assert.fail('must not request'));
  for (const name of ['', ' \n ', null]) await assert.rejects(create({ name, description: '' }));
  assert.equal(calls.length, 0);
});

test('W216 negative: rejected or malformed project never reports success', async () => {
  for (const reply of [{ error: 'name rejected' }, {}, folder('ordinary-gpt', 'bad')]) {
    const { create } = createFixture(() => reply);
    await assert.rejects(create({ name: '名稱', description: '' }), /ChatGPT 建專案失敗/);
  }
  for (const error of ['HTTP 401', 'HTTP 503', 'network unavailable']) {
    const { create } = createFixture(() => { throw Error(error); });
    await assert.rejects(create({ name: '名稱', description: '' }), new RegExp(error));
  }
});

test('W216 existing OS mapping description remains confirmed by the same command', async () => {
  const { create, calls } = createFixture((method, path, body) =>
    folder('g-p-mapped', body.name ?? body.display.name, body.display?.description ?? ''));
  const result = await create({ name: 'TATWO · 一般', description: 'OS fixture existing-id' });
  assert.equal(result.description, 'OS fixture existing-id');
  assert.equal(calls.length, 2);
  assert.equal(calls[1].body.gizmo_id, result.id);
  assert.equal(calls[1].body.display.description, 'OS fixture existing-id');
});
