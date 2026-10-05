import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
const root = new URL('../App/Sources/Tatwo2/', import.meta.url);
const read = p => readFileSync(new URL(p, root), 'utf8');
test('W226 app hooks stay local and do not expose events as MCP', () => {
  const presence = read('Events/OSPresence.swift');
  assert.match(presence, /NSEvent.addLocalMonitorForEvents/);
  assert.match(presence, /NSApp\?\.isActive \?\? false/);
  assert.doesNotMatch(presence, /addGlobalMonitor|AXIsProcessTrusted/);
  assert.match(read('Tatwo2App.swift'), /OSPresence.shared.install/);
  assert.doesNotMatch(read('Facade/OSAgentBridge.swift'), /OSEventLog|OSClock|queryEvents/);
});
test('W226 every requested source has a minimal event hook', () => {
  for (const [file, hook] of [
    ['Facade/ChatLiveEngine.swift', 'eventsSelected'], ['Facade/ChatLiveEngine.swift', 'eventsRow'],
    ['Facade/ChatLiveEngine.swift', 'eventsFinished'], ['Facade/ChatLiveEngine.swift', 'eventsNativeGoal'],
    ['Facade/HandsChatGPTRoom.swift', 'eventsHands'], ['Facade/BackgroundJobManager.swift', 'eventsJob'],
    ['New/DispatchRoomMessaging.swift', 'eventsDecision'], ['Facade/ThreadGoalStore.swift', 'eventsGoals'],
    ['Facade/ChatPageModel.swift', 'OSPresence.shared.select']]) assert.ok(read(file).includes(hook), file + ':' + hook);
});
test('W226 storage appends on a serial queue; monthly rollover uses OSClock', () => {
  const log = read('Events/OSEventLog.swift');
  assert.match(log, /DispatchQueue\(label:/);
  assert.match(log, /seekToEnd/);
  assert.doesNotMatch(log, /options: .atomic/);
  assert.match(log, /clock.schedule/);
  assert.match(log, /HandsRedactor.redact/);
  const files = readdirSync(new URL('Events/', root)).filter(f => !f.endsWith('Acceptance.swift'));
  const lines = files.reduce((n, f) => n + read('Events/' + f).trimEnd().split('\n').length, 0);
  assert.ok(lines <= 460, `Events production lines ${lines}`);
});
