import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// Retain negative safety boundaries while executable suites own rendering and lifecycle behavior.
const read = name => fs.readFileSync('App/Sources/Tatwo2/' + name, 'utf8');
const section = (source, start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `${start} … ${end}`);
  return source.slice(from, to);
};
test('Web Dots shares the isolated Pod context without TAP scripting', () => {
  assert.doesNotMatch(read('TAP/ChatGPTDots.swift'), /TapWebPod\(|\.persistent\(|profileID|URLSession|FileManager|UserDefaults/);
  const dots = section(read('TAP/TapWebPod.swift'), 'func openDotsSpacePage()', 'func start(script:');
  assert.match(dots, /sharingContextWith: browser,[\s\S]*actor: \.human/);
  assert.match(dots, /var url = ChatGPTDotsState.url/);
  assert.doesNotMatch(dots, /\.configurePod\(|\.runPodCommand\(|profileID/);
  assert.doesNotMatch(read('Facade/W199QuietAcceptance.swift'), /ChatGPTTap\.shared|TapWebPod\(|https?:/);
});
test('Background notice refresh cannot connect, enable, modify settings or revoke credentials', () => {
  assert.doesNotMatch(section(read('New/HandsConnectEntry.swift'), 'private func refreshNotice()', '/// W183 R11'), /connect\(|setEnabled\(|updateSettings|revoke/);
});
test('Automatic device reconnect and synchronization cannot emit hints or Island notices', () => {
  assert.doesNotMatch(section(read('Facade/RemoteDeviceSession.swift'), 'private func markOffline(', 'private func scheduleRetry'), /onHint\?/);
  assert.doesNotMatch(section(read('Facade/RemoteLiveEngine.swift'), 'pollTask = Task', '\n    var document:'), /hintOnce\(|onHint\?/);
  const sync = read('Facade/PrimaryOfflineSync.swift');
  assert.doesNotMatch(sync, /IslandNotice\.shared/);
  assert.doesNotMatch(section(sync, 'private func sendPrimaryOutboxItem(', '\n    /// 記憶提案核准'), /IslandNotice|ProjectClassificationBoard\.shared\.message =/);
  assert.doesNotMatch(section(sync, 'func flushPrimaryOutbox(', '\n    private func sendPrimaryOutboxItem'), /IslandNotice/);
  assert.doesNotMatch(section(read('Facade/AssistantOfflineHandoff.swift'), 'func mergeAssistantOfflineStretches(', '\n    // MARK: 連回後的新一句'), /IslandNotice/);
});
test('Session mapping display cannot persist or log private titles', () => {
  assert.doesNotMatch(read('Chat/ChatGPTSessionMappingRow.swift'), /\b(print|Logger|NSLog|os_log)\s*\(|UserDefaults|JSONEncoder|\.save\(/);
  const map = read('Facade/TapProjectMap.swift');
  assert.doesNotMatch(section(map, 'func displayMap(', 'func prepareInbox('), /migrateLegacy|createDirectory|\.save\(/);
  assert.match(map, /post\(name: Self.didChange, object: nil\)/);
  assert.doesNotMatch(section(read('Facade/HandsTools.swift'), 'static func summarize', '// MARK: - 參數'), /"title"/);
  assert.doesNotMatch(read('Facade/HandsTools.swift'), /開了工作區「/);
});
