import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('create_project describes shared folders and the Git requirement for workspaces', () => {
  const source = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsTools.swift', import.meta.url), 'utf8');
  const description = source.match(/HandsToolSpec\(id: "create_project"[\s\S]*?description: "([^"\n]+)"/)[1];
  assert.match(description, /another project/i);
  assert.match(description, /[Nn]ew folders are not [Gg]it repositories/);
  assert.match(description, /cannot open.*workspace.*until.*[Gg]it.*commit/);
  assert.match(description, /no additional approval is needed/);
});
