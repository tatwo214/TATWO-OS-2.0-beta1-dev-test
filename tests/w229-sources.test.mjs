import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
const root = new URL('../App/Sources/Tatwo2/', import.meta.url);
const read = file => readFileSync(new URL(file, root), 'utf8');
test('W229 has one send provenance mechanism for both event actor and group admission', () => {
  const bridge = read('Facade/GroupCoderBridge.swift');
  const source = read('Events/OSEventSources.swift');
  const engine = read('Facade/ChatLiveEngine.swift');
  for (const file of readdirSync(new URL('Facade/', root)).filter(f => f.startsWith('Group') && f.endsWith('.swift'))) {
    assert.doesNotMatch(read('Facade/' + file), /enum Origin|withOrigin|takeOrigin|\borigins\b/, file);
  }
  assert.match(bridge, /source: OSEventSources.Send/);
  assert.match(bridge, /guard source.origin == "composer"/);
  assert.match(source, /static func take\(\).*send = .system/);
  assert.match(engine, /let source = OSEventSources.take\(\)/);
  assert.match(engine, /text: shown, turnID: turn\), source: source/);
  assert.match(source, /actor: source.actor[\s\S]*origin: source.origin/);
  assert.equal((source.match(/send = Send\(origin:/g) ?? []).length, 1, 'only begin sets a new scoped provenance');
});
test('W229 plan button uses normal routing with explicit nonhuman source and restores its draft', () => {
  const page = read('Facade/ChatPageModel.swift');
  const start = page.slice(page.indexOf('func startActivePlan()'), page.indexOf('func returnActivePRToDiscussion()'));
  assert.match(start, /defer \{ prompt = draft; droppedPaths = paths; droppedPathDisplayNames = names \}/);
  assert.match(start, /OSEventSources.scope\(origin: "plan", actor: "系統"\) \{ send\(\) \}/);
  assert.match(page, /OSEventSources.send.origin == "plan" \? "plan" : "composer"/);
});
