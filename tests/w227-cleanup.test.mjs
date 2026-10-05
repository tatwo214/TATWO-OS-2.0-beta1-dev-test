import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const swift = name => fs.readFileSync(new URL(`../App/Sources/Tatwo2/${name}`, import.meta.url), 'utf8');

test('W227-1 sidebar update has no unused navigation callback', () => {
  const card = swift('New/UpdateAvailableCard.swift');
  assert.doesNotMatch(card, /openUpdateSettings/);
  assert.match(swift('Chat/ChatPage+Sidebar.swift'), /SidebarUpdateShortcut\(\)/);
  assert.match(card.slice(card.indexOf('struct SidebarUpdateShortcut')), /await updater\.activateUpdateMark/);
});

test('W227-3 acceptance checks retained short copy across hidden states and repair titles', () => {
  const acceptance = swift('New/W224Acceptance.swift');
  const body = acceptance.slice(acceptance.indexOf('static func compactBuild'), acceptance.indexOf('static func memory'));
  for (const name of ['busy', 'badLabel', 'changed', 'turnOnFirst', 'notReady', 'pickDomain', 'pickDevice']) {
    assert.ok(body.includes(`HandsBuildCopy.${name}`), `${name} must be checked even when absent from the current frame`);
  }
  for (const fix of ['retryApply', 'login', 'reauthorize', 'unlock', 'reconnect']) {
    assert.ok(body.includes(`HandsBuildFix.${fix}`), `repair title ${fix} must be checked`);
  }
  assert.match(body, /shortCopy/);
});

test('W227-4 root catalog acceptance waits for completion and verifies a replacement list', () => {
  const acceptance = swift('Facade/W199QuietAcceptance.swift');
  const body = acceptance.slice(acceptance.indexOf('pod.holdCatalog = true; model.retryProjects()'),
    acceptance.indexOf('let fresh = ChatGPTSpaceModel'));
  assert.doesNotMatch(body, /until \{ model\.projectsLoadState == \.loaded \}/);
  assert.doesNotMatch(body, /Task\.sleep/);
  assert.match(body, /catalogFinished/);
  assert.match(body, /Fixture project 5/);
  assert.match(acceptance, /catalogReplies/);
  assert.match(acceptance, /!pod\.workActive/);
});
