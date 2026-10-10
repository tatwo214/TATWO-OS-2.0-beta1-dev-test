import test, { before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const source = fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsConnect.swift', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `missing Swift section: ${start}`);
  return source.slice(from, to);
};
const url = 'https://fixture.invalid/mcp', name = 'TATWO（Fixture）';
let cards;
before(() => {
  const root = testScratch('w321-manualsteps-');
  for (const dir of ['home', 'live']) fs.mkdirSync(path.join(root, dir));
  const env = { ...process.env, HOME: path.join(root, 'home'), CFFIXED_USER_HOME: path.join(root, 'home'), TATWO2_LIVE_ROOT: path.join(root, 'live') };
  const swift = `import Foundation
${section('struct HandsConnectorScan:', '/// W183 R6b 審查：使用者看過')}
enum Flow {
${section('    static func manualSteps(', '    /// W183 R9：Pod 回')}
}
let url = "${url}", name = "${name}"
let empty = HandsConnectorScan(listKnown: true)
let outputs = [
  "existing": Flow.manualSteps(url, name: name, existing: true, scan: empty),
  "unknown": Flow.manualSteps(url, name: name, scan: HandsConnectorScan(listKnown: false)),
  "unread": Flow.manualSteps(url, name: name),
  "empty": Flow.manualSteps(url, name: name, scan: empty),
  "match": Flow.manualSteps(url, name: name, scan: HandsConnectorScan(listKnown: true, matches: [.init(id: nil, name: name, auth: "unknown")])),
  "failure": Flow.manualSteps(url, name: name, scan: HandsConnectorScan(listKnown: true, failure: "invalid-row")),
  "loggedOut": Flow.manualSteps(url, name: name, scan: HandsConnectorScan(loggedIn: false, listKnown: true))
]
print(String(data: try JSONEncoder().encode(outputs), encoding: .utf8)!)
`;
  const input = path.join(root, 'main.swift'), binary = path.join(root, 'probe');
  fs.writeFileSync(input, swift);
  const build = spawnSync('swiftc', [input, '-o', binary], { env, encoding: 'utf8', timeout: 120000 });
  fs.writeFileSync(path.join(root, 'build.log'), `${build.stdout ?? ''}${build.stderr ?? ''}`);
  assert.equal(build.status, 0, `${build.error ?? ''}\n${build.stderr}`);
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 10000 });
  fs.writeFileSync(path.join(root, 'result.json'), run.stdout ?? '');
  assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stderr}`);
  cards = JSON.parse(run.stdout);
});

const inOrder = (steps, words) => {
  const text = steps.join('\n');
  let after = 0;
  for (const word of words) {
    const at = text.indexOf(word, after);
    assert.ok(at >= after, `missing or out of order: ${word}\n${text}`);
    after = at + word.length;
  }
};

test('W321 existing manualSteps uses Installed, Manage, exact URL and Reconnect', () => {
  inOrder(cards.existing, ['Plugins', 'Customize', 'Installed', name, 'Manage', 'Plugin settings', 'About', `URL 完全等於 ${url}`, 'Connected accounts', 'Reconnect', '8 碼', '只在你自己剛按了 Reconnect']);
  assert.match(cards.existing[0], /如果 Installed 裡沒有任何 TATWO 才改走新建/);
  assert.doesNotMatch(cards.existing.join('\n'), /Create as a plugin|設定 › Apps|Connect／重新連線/);
});

test('W321 unreadable or unknown list always shows reuse steps', () => {
  for (const key of ['unknown', 'unread', 'failure', 'loggedOut']) assert.deepEqual(cards[key], cards.existing, key);
});

test('W321 only a known empty list shows create; even an unidentified match means reuse', () => {
  assert.deepEqual(cards.match, cards.existing);
  assert.notDeepEqual(cards.empty, cards.existing);
  assert.match(cards.empty.join('\n'), /先確認 Installed 沒有同網址的 TATWO/);
});

test('W321 create manualSteps uses October button names and preserves the pairing reminder', () => {
  inOrder(cards.empty, ['Plugins', '右上 Add', 'Add custom MCP server', 'Name', name, 'Server URL', url, 'OAuth', 'I understand and want to continue', 'Create as a plugin', '8 碼', '只在你自己剛按了 Create as a plugin 建立才打']);
  assert.doesNotMatch(cards.empty.join('\n'), /新增 ▾|Create MCP app|按「Create」/);
  assert.ok(cards.empty.every(step => step.length < 100));
});

test('W321 manual card reads the real list unless reuse is already known and drops a cancelled scan', () => {
  assert.match(source, /let scan = selectedConnector != nil \|\| hasPendingCreate\(createKey\) \? nil : await pod\.scan\(url: intent\.mcpURL\)\s+guard my == runID else \{ return \}\s+card = \.manual\([^\n]*existing: selectedConnector != nil \|\| hasPendingCreate\(createKey\), scan: scan\)/);
});
