import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = 'App/Sources/Tatwo2/';

test('M2/send-06/Sol M2: every Claude entry forwards provider model, remote send declares engine', () => {
  for (const file of ['Facade/ChatPageModel.swift', 'Assistant/AssistantPrimaryRouting.swift']) {
    assert.doesNotMatch(read(app + file), /modelArgument\.flatMap \{ \$0\.hasPrefix\("claude"\)/, file);
  }
  const remote = read(app + 'Facade/RemoteLiveEngine.swift');
  const send = remote.slice(remote.indexOf('var params: [String: Any] = [', remote.indexOf('func send(')));
  assert.match(send.slice(0, 1000), /"engine": engine\.rawValue/);
  const host = read(app + 'Facade/OSAgentBridge.swift');
  const resolver = host.slice(host.indexOf('static func sendMessageEngine'), host.indexOf('static func routesToAssistant'));
  assert.ok(resolver.indexOf('requested.flatMap') < resolver.indexOf('if let modelArgument'));
});

test('M2 all remote dispatch paths resolve a provider model even when callers omit it', () => {
  const remote = read(app + 'Facade/RemoteLiveEngine.swift');
  assert.match(remote, /remoteProviderModel/);
  assert.match(remote, /params\["model"\] = Self\.remoteProviderModel/);
});
