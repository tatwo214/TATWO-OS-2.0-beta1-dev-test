import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL('../App/Sources/Tatwo2/' + path, import.meta.url), 'utf8');
const tools = read('Facade/HandsTools.swift');
for (const [name, level, required, readOnly] of [['read_session', 0, 'thread_id', true], ['create_project', 1, 'name', false]]) {
  test(`${name} exposed with schema and dispatch`, () => {
    const spec = tools.match(new RegExp(`HandsToolSpec\\(id: "${name}"[\\s\\S]*?destructive: false\\)`))?.[0] ?? '';
    assert.ok(spec, 'new tool absent');
    assert.ok(spec.includes(`level: ${level}`));
    assert.ok(spec.includes(`required: ["${required}"]`));
    assert.ok(spec.includes(`readOnly: ${readOnly}`));
    assert.ok(tools.includes(`case "${name}":`));
    assert.ok(spec.includes(name === 'read_session' ? 'cursor' : 'folder'));
  });
}
test('behavioral acceptance registered and isolated', () => {
  assert.match(read('SelfTest.swift'), /"w225mcp".*W225MCPAcceptance.run/);
  assert.match(read('Facade/W225MCPAcceptance.swift'), /NativeStagingIsolation.validationError/);
});
test('ChatGPT tool descriptions explain scope, paging and creation semantics', () => {
  const description = name => tools.match(new RegExp(`HandsToolSpec\\(id: "${name}"[\\s\\S]*?description: "([^"]+)"`))?.[1] ?? '';
  for (const phrase of ['thread_id', 'cursor', '40 rows', '24 KB', 'redacted', 'all-project access', 'same error']) assert.ok(description('read_session').includes(phrase), phrase);
  for (const phrase of ['no additional approval', 'Required name', 'Optional folder', 'relative', 'overwriting', 'numeric suffixes', 'project_id', 'sidebar']) assert.ok(description('create_project').includes(phrase), phrase);
});
