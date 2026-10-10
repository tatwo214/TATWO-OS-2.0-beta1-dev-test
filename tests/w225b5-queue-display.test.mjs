import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync(new URL('../App/Sources/Tatwo2/Facade/GroupCoderBridge.swift', import.meta.url), 'utf8');
test('W225b5-4 queued and unsent labels render in the existing user bubble', () => {
  const view = readFileSync(new URL('../App/Sources/Tatwo2/Chat/ChatPageLeafViews.swift', import.meta.url), 'utf8');
  const bubble = view.slice(view.indexOf('private var userMessageBubble'), view.indexOf('private var messageContainer'));
  const prefixes = [...bubble.matchAll(/status\.hasPrefix\("([^"]+)"\)/g)].map(match => match[1]);
  const statuses = bridge.match(/event\.kind == "queued" \? "([^"]+)" : event\.kind == "queue-cancelled" \? "([^"]+)"/);
  assert.ok(statuses, 'queued and cancelled group row statuses are explicit');
  for (const status of statuses.slice(1)) assert.ok(prefixes.some(prefix => status.startsWith(prefix)), `${status} must be visible in the user bubble`);
});
