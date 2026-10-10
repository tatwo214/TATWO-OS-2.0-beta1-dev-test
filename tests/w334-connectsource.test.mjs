import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fixture } from './w185-pod-fixture.mjs';

const file = 'App/Sources/Tatwo2/TAP/ChatGPTConnectorPod.swift';
const driver = readFileSync(new URL('../' + file, import.meta.url), 'utf8');
const flowPath = 'App/Sources/Tatwo2/Facade/HandsConnect.swift';
const flow = readFileSync(new URL('../' + flowPath, import.meta.url), 'utf8');
const section = (text, from, to) => text.slice(text.indexOf(from), text.indexOf(to, text.indexOf(from)));

test('W334 native full load precedes every acquired connector lease, including remembered-ID reconnect', () => {
  const acquire = section(driver, 'func acquireExclusive(', 'func releaseExclusive(');
  assert.match(acquire, /tap\.beginConnectorHold\(\)[\s\S]*surface\.loadMain\(plugins\)/);
  assert.match(acquire, /URL\(string: "https:\/\/chatgpt\.com\/plugins"\)/);
  for (const required of ['!tap.backgroundPageIsShared', 'mainGeneration > generation', 'mainURL == plugins',
    '!mainLoading', '(200..<300).contains(mainHTTPStatus)', 'tap.helloCount > hellos', 'hold == id', '!Task.isCancelled']) {
    assert.ok(acquire.includes(required), required);
  }
  assert.ok(acquire.includes('reason=\\(tap.backgroundPageIsShared ? "space_shared" : "plugins_load_unconfirmed")'));
  assert.match(acquire, /hold = nil; tap\.endConnectorHold\(id\)/);
  const start = section(flow, 'guard await pod.acquireExclusive(', '// 3. 先讀既有連接器');
  assert.ok(start.includes('return fail(') && start.includes('外掛頁'));
  assert.ok(start.includes('ChatGPT Space 正在用這一頁'));
  assert.ok(flow.indexOf('guard await pod.acquireExclusive(') < flow.indexOf('let inspected = await pod.inspect(remembered.connector'));
  assert.ok(flow.indexOf('guard await pod.acquireExclusive(') < flow.indexOf('var scan = await pod.scan(url: intent.mcpURL)'));
});

test('W334 host, authorize provenance and press anchor predicates remain byte-for-byte unchanged from 047', () => {
  const old = execFileSync('git', ['show', '629f539b:' + flowPath], { cwd: new URL('..', import.meta.url), encoding: 'utf8' });
  for (const [from, to] of [['nonisolated static func anchorProblem(', 'private func pressDispatched('],
    ['static func provenanceProblem(', 'static func expectedAfterPairing(']]) {
    const original = section(old, from, to);
    assert.ok(original.length > 100);
    assert.equal(section(flow, from, to), original);
  }
  for (const name of ['HandsConnectHost.swift', 'HandsAuth.swift']) {
    const path = 'App/Sources/Tatwo2/Facade/' + name;
    assert.equal(readFileSync(new URL('../' + path, import.meta.url), 'utf8'),
      execFileSync('git', ['show', '629f539b:' + path], { cwd: new URL('..', import.meta.url), encoding: 'utf8' }));
  }
});

test('W334 native address changes update the URL even when SPA does not advance document generation', () => {
  const callback = section(driver, 'private func mainFrame(', 'private func noteNavigation(');
  assert.match(callback, /mainSource = generation > mainGeneration \? mainURL : nil/);
  assert.match(callback, /mainGeneration = generation\s*\}\s*if let url \{ mainURL = url \}/);
});

test('W334 TAP send returns from Plugins or settings to its existing conversation through the production Pod script', async () => {
  const conversationID = '11111111-1111-4111-8111-111111111111';
  for (const initial of ['/plugins', '/settings/plugins-settings/w334-fixture']) {
    const pod = fixture({ allowNetwork: true, respond: () => Response.json({ models: [], mapping: {} }) });
    await pod.sandbox.fetch('https://chatgpt.com/backend-api/models', { headers: { authorization: 'Bearer synthetic-fixture-only' } });
    pod.sandbox.location.pathname = initial;
    new pod.Element('div', { 'data-message-author-role': 'assistant' });
    let sentAt;
    pod.button.onClick = () => { sentAt = pod.sandbox.location.pathname; };
    pod.send({ conversationID });
    await pod.advance(20000);
    assert.equal(pod.sandbox.location.pathname, '/c/' + conversationID);
    assert.deepEqual(pod.navigations.slice(0, 2), ['/', '/c/' + conversationID]);
    assert.equal(sentAt, '/c/' + conversationID);
  }
});
