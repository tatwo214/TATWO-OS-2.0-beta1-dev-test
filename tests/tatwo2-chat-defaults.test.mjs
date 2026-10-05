import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const model = read('App/Sources/Tatwo2/Facade/ChatPageModel.swift');
const profiles = read('App/Sources/Tatwo2/Chat/TatwoChatRouteProfile.swift');

test('live startup selects GPT-6.1 Sol medium fast without changing fixture defaults', () => {
  assert.match(model, /if liveMode \{\s*\/\/[^\n]*\n\s*selectedModel = "gpt-6.1-sol"\s*selectedEffort = \.medium\s*selectedSpeedTier = \.fast\s*\}/);
  assert.match(model, /self\.selectedModel = fixture\.selectedModel/);
});

test('GPT-6 profile uses the native route with the official catalog reasoning default and fast speed', () => {
  const profile = profiles.split('id: "gpt-6-astra",')[1].split('notes:')[0];
  assert.match(profile, /modelArgument: "gpt-6-astra"/);
  assert.match(profile, /defaultEffort: \.low/);
  assert.match(profile, /allowedEfforts: \[\.low, \.medium, \.high, \.xhigh, \.max, \.ultra\]/);
  assert.match(profile, /defaultSpeedTier: \.fast/);
});
