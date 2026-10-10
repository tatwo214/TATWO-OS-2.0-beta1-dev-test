import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeW298c } from './fixtures/w298c-native.mjs';

test('W298c fake HTTP synchronizes local models through real comparison and native Coder groups', () => {
  const output = nativeW298c();
  for (const label of [
    'fourth source shares cloud comparison pass',
    'HTTP names preserved and duplicate removed',
    'Coder local group preserves name tag',
    'local routes never execute through Codex',
    'new download added and deleted models retired',
    'offline is a row status and preserves catalog',
    'bad JSON preserves catalog without error',
    'valid empty list retires all local models',
    'MLX same interface stub does no HTTP',
    'W297 same provider lookup key deduplicates local aliases',
    'same ID across providers preserves cloud and W298a Grok identity',
    'local cannot select while vendor selection remains intact',
    'local refresh preserves selected install and skipped vendors',
    'cancel preserves local row and never installs Ollama',
    'local sync never installs or advertises update',
  ]) assert.ok(output.includes(`W298C PASS ${label}`), label);
});
