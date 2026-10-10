import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const engine = fs.readFileSync('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift', 'utf8');
const bridge = fs.readFileSync('App/Sources/Tatwo2/Facade/OSAgentBridge.swift', 'utf8');
const call = 'ManagedConversationTAPPolicy.rejectionReason(';

test('all three TAP send entries enforce the shared refusal before side effects', () => {
  const send = engine.slice(engine.indexOf('let selectedModel = model ??'), engine.indexOf('var plan: TatwoPlanArtifactV1?'));
  const tap = engine.slice(engine.indexOf('private func sendTap('), engine.indexOf('private func sendTap(') + 1800);
  const remote = bridge.slice(bridge.indexOf('case "send_message", "send_message_with_options":'), bridge.indexOf('case "distill_open"'));
  for (const [source, boundary] of [[send, 'return sendTap('], [tap, 'let history ='], [remote, 'if let memoryStrength']]) {
    assert.ok(source.includes(call), 'missing shared refusal');
    assert.ok(source.indexOf(call) < source.indexOf(boundary), 'refusal must precede TAP, memory changes and fixture launch');
    assert.match(source, /appendSystemMessage\(threadID: threadID, text: reason, status: "error\|ChatGPT TAP"\)/);
  }
  assert.match(remote, /creator: live\.threadRecord\(threadID\)\?\.controllerCreatorFingerprint \?\? context\.controllerFingerprint/);
  assert.match(remote, /sendTurnRejected\("managed_chatgpt_tap_forbidden"\)/);
});

test('compiled shared policy denies every marked managed TAP thread, preserves other routes', () => {
  const policy = engine.match(/enum ManagedConversationTAPPolicy \{[\s\S]*?\n\}/)?.[0];
  assert.ok(policy, 'shared policy is required for future group routing');
  const root = testScratch('w221b-tap-policy-');
  fs.writeFileSync(path.join(root, 'main.swift'), `import Foundation
  enum ChatGPTTapModelCatalog { static func isRouteID(_ model: String) -> Bool { model.hasPrefix("chatgpt-tap:") } }
  ${policy}
  for creator: String? in [nil, "", "synthetic-controller"] {
    for model: String? in [nil, "gpt-6.1-sol", "chatgpt-tap:fixture-model", "chatgpt-tap:"] {
      let reason = ManagedConversationTAPPolicy.rejectionReason(model: model, creator: creator)
      precondition((reason != nil) == (creator != nil && (model?.hasPrefix("chatgpt-tap:") == true)))
    }
  }
  print("W221b TAP policy PASS")
  `);
  const binary = path.join(root, 'probe');
  execFileSync('/usr/bin/swiftc', [path.join(root, 'main.swift'), '-o', binary]);
  assert.match(execFileSync(binary, { encoding: 'utf8' }), /TAP policy PASS/);
});
