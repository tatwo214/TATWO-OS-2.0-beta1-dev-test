import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W182 R4：主設備（配對設備）斷線時，Coder 照樣列出最後同步的專案與對話（灰、可以讀），可以「在這台接著聊」；
// 私訊框同樣列出（灰），選到時唯讀＋同一個函式。原始碼契約；實際行為在 `TATWO2_SELFTEST=w182offline`
// （Facade/RemoteOfflineAcceptance.swift：假遠端設備、隔離 staging、不開 SSH、不送引擎）。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('offline copy lives in live/remote-cache/<device id>/: document.json + last 200 messages of read threads, capped, atomic', () => {
  const cache = read('Facade/RemoteOfflineCache.swift');
  assert.match(cache, /static let folderName = "remote-cache"/);
  assert.match(cache, /appendingPathComponent\("document\.json"\)/);
  assert.match(cache, /appendingPathComponent\("threads", isDirectory: true\)/);
  assert.match(cache, /environment\["TATWO2_LIVE_ROOT"\][\s\S]{0,300}appendingPathComponent\("tatwo2\/live", isDirectory: true\)/);
  // Limits from the brief: 30 threads per device, last 200 messages each, 20 MB total; the oldest go first.
  assert.match(cache, /var threads = 30/);
  assert.match(cache, /var messagesPerThread = 200/);
  assert.match(cache, /var bytes = 20 \* 1024 \* 1024/);
  const limits = slice(cache, 'func enforceLimits(deviceID: String)', '\n    }\n');
  assert.match(limits, /\$0\.savedAt < \$1\.savedAt/);
  assert.match(limits, /rows\.count > limits\.threads \|\| total > limits\.bytes/);
  assert.match(limits, /let oldest = rows\.removeFirst\(\)/);
  assert.match(cache, /messages\.suffix\(limits\.messagesPerThread\)/);
  // Atomic writes; a broken or foreign file is simply "none" (never throws into startup).
  assert.equal((cache.match(/options: \.atomic/g) ?? []).length, 2);
  const readSnapshot = slice(cache, 'func readSnapshot(deviceID: String)', '\n    }\n');
  assert.match(readSnapshot, /try\? Data\(contentsOf:/);
  assert.match(readSnapshot, /try\? Self\.decoder\(\)\.decode\(RemoteOfflineSnapshot\.self/);
  assert.match(readSnapshot, /snapshot\.deviceID == deviceID else \{ return nil \}/);
  assert.match(slice(cache, 'func readTranscript(deviceID: String', '\n    }\n'), /file\.threadID == threadID else \{ return nil \}/);
  // Device ids never escape the cache folder.
  assert.match(cache, /static func folderName\(deviceID: String\) -> String/);
  assert.match(cache, /"id-" \+ SHA256\.hash/);
  // The snapshot is slimmed: a preview per thread; no CLI tabs, room briefs or issues.
  const slim = slice(cache, 'func slimmed() -> RemoteOfflineSnapshot', '\n    }\n');
  for (const piece of ['.cliTabs = []', '.roomBrief = nil', '.issues = []']) assert.ok(slim.includes(piece), piece);
  // Offline rows never pretend to be running.
  assert.match(slice(cache, 'var projection: TatwoNativeChatStoreDocument', '\n    }\n'), /liveness: nil/);
});

test('no offline-cache file I/O on the main thread: one serial queue, the mirror only goes through cache.run', () => {
  const cache = read('Facade/RemoteOfflineCache.swift');
  assert.match(cache, /static let queue = DispatchQueue\(label: "ai\.tatwo\.tatwo2\.remote-offline-cache"/);
  const run = slice(cache, 'func run<T>(_ work:', '\n    }\n');
  assert.match(run, /Self\.queue\.async \{/);
  assert.match(run, /DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ box\.completion\(result\.value\) \} \}/);
  const mirror = cache.slice(cache.indexOf('final class RemoteOfflineMirror'));
  assert.match(mirror, /^final class RemoteOfflineMirror/);
  assert.doesNotMatch(code(mirror), /FileManager|Data\(contentsOf|\.write\(to:|contentsOfDirectory/);
  // Every file call of the mirror sits inside a cache.run closure.
  for (const call of ['readSnapshot(', 'writeSnapshot(', 'writeTranscript(', 'readTranscript(', 'touchTranscript(', 'entries(deviceID', 'clear(deviceID']) {
    for (const at of [...mirror.matchAll(new RegExp('cache\\.' + call.replace(/[()]/g, '\\$&'), 'g'))].map(m => m.index)) {
      const before = mirror.slice(Math.max(0, at - 220), at);
      assert.match(before, /cache\.run\(\{[^}]*$/, `cache.${call} outside cache.run`);
    }
  }
  // A counter the self-test reads.
  assert.match(cache, /guard Thread\.isMainThread else \{ return \}/);
  assert.match(cache, /static var mainThreadIOCount: Int/);
});

test('clearing is archive-not-delete: the device folder goes to the Trash (restorable); self-test never touches the real Trash', () => {
  const cache = read('Facade/RemoteOfflineCache.swift');
  const clear = slice(cache, 'func clear(deviceID: String) throws -> Bool', '\n    }\n');
  assert.match(clear, /FileManager\.default\.trashItem\(at: target, resultingItemURL: nil\)/);
  assert.doesNotMatch(clear, /removeItem/);
  assert.match(clear, /#if DEBUG\s*if let testRetire = Self\.testRetire \{ try testRetire\(target\); return true \}\s*#endif/);
  // removeItem only drops the oldest over the limit (a cache), never a clear.
  assert.equal((code(cache).match(/removeItem/g) ?? []).length, 1);
  const card = read('New/DevicesCard.swift');
  assert.match(card, /RemoteOfflineCacheRow\(model: model, device: device\)   \/\/ W182 R4/);
  const view = read('New/RemoteOfflineThreadView.swift');
  const row = slice(view, 'struct RemoteOfflineCacheRow: View', '\n}\n');
  assert.match(row, /OSChipButton\(title: "清除這台的離線副本"\)/);
  // In-card confirmation row with glass chips (W179 UI), no system dialog, no blue buttons.
  assert.match(row, /if confirming \{/);
  assert.match(row, /OSChipButton\(title: "取消"\) \{ confirming = false \}/);
  assert.match(row, /OSChipButton\(title: "清除"\) \{/);
  assert.match(row, /\.chatLiquidSection\(cornerRadius: 12\)/);
  assert.match(row, /移到垃圾桶（可以放回）/);
  assert.doesNotMatch(code(view), /confirmationDialog|NSAlert|\.alert\(|borderedProminent|\.blue\b|accentColor/);
});

test('RemoteDeviceSession writes the snapshot while connected and reads it back when offline (App restart included)', () => {
  const session = read('Facade/RemoteDeviceSession.swift');
  assert.match(session, /let offlineMirror: RemoteOfflineMirror/);
  const init = slice(session, '        self.lastSeenAt = device.lastSeenAt', '    /// W182 R4：離線副本讀好');
  assert.match(init, /RemoteOfflineCache\(root: RemoteOfflineCache\.defaultRoot\(environment: environment\)\)/);
  assert.match(init, /offlineMirror\.loadFromDisk\(\)/);
  const changed = slice(session, 'private func offlineMirrorChanged()', '\n    }\n');
  assert.match(changed, /if engine == nil \{/);
  assert.match(changed, /if lastDocument == TatwoNativeChatStoreDocument\(\) \{ lastDocument = snapshot\.projection \}/);
  assert.match(changed, /lastSeenAt = max\(lastSeenAt, snapshot\.syncedAt\)/);
  const install = slice(session, 'private func installConnectedEngine(', 'private func markOffline(');
  // Late transcript results after a disconnect or removal are dropped (same engine check as onChange).
  assert.match(install, /remote\.onTranscriptFetched = \{ \[weak self, weak remote\] threadID, records in[^\n]*\n\s*guard let self, let remote, self\.engine === remote else \{ return \}[^\n]*\n\s*self\.offlineMirror\.record\(transcript: records, threadID: threadID\)/);
  // Connect forces the latest snapshot; a dropped link writes the last pending one.
  assert.match(install, /offlineMirror\.record\(document: remote\.doc, revision: remote\.currentRevision, force: true\)   \/\/ W182 R4/);
  assert.match(install, /case \.failure\(let error\):\s*self\.offlineMirror\.flushPendingDocument\(\)/);
  assert.match(slice(session, 'func shutdown() {', '\n    }\n'), /offlineMirror\.flushPendingDocument\(\)/);
  assert.equal((install.match(/offlineMirror\.record\(document: remote\.doc, revision:/g) ?? []).length, 3,
    'connect, every change and every successful poll (throttled inside)');
  const mirror = read('Facade/RemoteOfflineCache.swift');
  const record = slice(mirror, 'func record(document: LiveDocumentRecord, revision: Int64', '\n    }\n');
  assert.match(record, /guard !isRetired else \{ return \}/);
  assert.match(record, /let changed = revision != lastWrittenRevision\s*guard changed \|\| now\.timeIntervalSince\(lastWrittenAt\) >= 60 else \{ return \}/);
  // A busy primary: at most one document write every 20 s; the rest waits as the pending one.
  assert.match(record, /if changed, !force, now\.timeIntervalSince\(lastWrittenAt\) < Self\.documentWriteInterval \{\s*pendingDocument = \(document, revision, now\)\s*return\s*\}/);
  assert.match(mirror, /static let documentWriteInterval: TimeInterval = 20/);
  assert.match(slice(mirror, 'func loadFromDisk()', '\n    }\n'), /if self\.snapshot == nil, let snapshot = loaded\.0/);
  const remote = read('Facade/RemoteLiveEngine.swift');
  const refresh = slice(remote, 'private func refreshTranscript(_ threadID: UUID)', 'private func refreshDocument(');
  assert.match(refresh, /self\.transcriptCache\[threadID\] = records\.map\(\\\.chatMessage\)\s*self\.onTranscriptFetched\?\(threadID, records\)   \/\/ W182 R4/);
  // Test hooks never open SSH: fake get_document, polling stopped, retry cancelled.
  const hooks = slice(session, 'func w182TestConnect(initial:', '#endif');
  assert.match(hooks, /installConnectedEngine\(initial: initial\)\s*engine\?\.shutdownAll\(\)/);
  assert.match(hooks, /retryTask\?\.cancel\(\)/);
  assert.doesNotMatch(hooks, /start\(\)|connectNow\(\)|link\.connect/);
});

test('sidebar: offline section still lists the last synced projects and threads, dimmed, with the last sync time', () => {
  const model = read('Facade/ChatPageModel.swift');
  const rebuild = slice(model, 'func rebuildRemoteSidebarSections() {', 'init(environment:');
  assert.match(rebuild, /let offlineLines: \[UUID: String\] = isOnline \? \[:\] : session\.offlineMirror\.activityLines\(\)/);
  assert.match(rebuild, /statusLine: offlineLines\[thread\.id\] \?\? statusLine/);
  assert.match(rebuild, /offlineSyncedAt: isOnline \|\| session\.offlineMirror\.snapshot == nil \? nil : session\.offlineMirror\.syncedAt/);
  assert.match(read('Facade/RemoteDeviceSession.swift'), /var offlineSyncedAt: Date\? = nil/);
  const sections = read('New/RemoteDevicesSidebarSections.swift');
  const content = slice(sections, 'struct RemoteDeviceSectionContent: View', 'private struct RemoteThreadRowView');
  assert.match(content, /if section\.isOnline \|\| section\.offlineSyncedAt != nil \{/);
  assert.match(content, /Text\("離線・最後同步 \\\(RemoteDeviceSidebarSection\.seen\(syncedAt\)\)"\)/);
  assert.match(content, /\.opacity\(section\.isOnline \? 1 : 0\.55\)/);
  // Without an offline copy the old one-line offline row stays.
  assert.ok(content.includes('離線・\\(RemoteDeviceSidebarSection.seen(section.lastSeenAt))'));
  const row = slice(sections, 'private struct RemoteThreadRowView', 'private var label: some View');
  assert.match(row, /if model\.remoteOfflineCanContinue\(deviceID: deviceID, threadID: thread\.id\) \{\s*Button\("在這台接著聊"\) \{ model\.continueOfflineThreadHere\(deviceID: deviceID, threadID: thread\.id\) \}/);
});

test('Coder: an offline thread opens read-only (cached content or a plain note); the composer becomes a note + glass chip', () => {
  const model = read('Facade/ChatPageModel.swift');
  const select = slice(model, 'func selectRemote(deviceID: String, threadID: UUID) -> Bool', 'func selectLocalThread(');
  assert.match(select, /session\.engine == nil,\s*session\.offlineMirror\.hasThread\(threadID\) \{\s*return selectOfflineRemote\(deviceID: deviceID, threadID: threadID\)/);
  const offline = slice(model, 'private func selectOfflineRemote(deviceID: String, threadID: UUID) -> Bool', '\n    }\n');
  assert.match(offline, /selectedRemote = \(deviceID, threadID\)[\s\S]{0,200}isRunning = false/);
  assert.match(model, /activeConversationEngine\?\.transcript\(for: selectedThreadID\) \?\? remoteOfflineTranscript/);
  assert.match(slice(model, 'var isRemoteTranscriptLoading: Bool', '\n    }\n'),
    /guard let remote = session\.engine else \{ return Self\.remoteOfflineLoading\(session, selectedThreadID\) \}/);
  const extensionFile = read('Facade/ChatPageModel+OfflineContinue.swift');
  assert.ok(extensionFile.includes('static let notReadNote = "這則離線前沒讀過，連上後才看得到"'));
  const loading = slice(extensionFile, 'static func remoteOfflineLoading(', '\n    }\n');
  assert.match(loading, /guard let threadID, session\.offlineMirror\.hasThread\(threadID\) else \{ return true \}/);
  const transcript = read('Chat/ChatPage+Transcript.swift');
  const area = slice(transcript, 'func messageArea(contentMaxWidth: CGFloat?) -> some View', 'func transcript(contentMaxWidth:');
  assert.match(area, /\} else if let note = model\.remoteOfflineEmptyNote \{\s*RemoteOfflineEmptyTranscript\(text: note\)/);
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.match(panels, /model\.mode != \.browser, model\.mode != \.chatgpt \{\s*composer\(contentMaxWidth: contentMaxWidth, forceCompactToolbar: forceCompactToolbar\)\s*\.modifier\(RemoteOfflineComposerSwap\(model: model, focus: \$composerFocused\)\)/);
  const view = read('New/RemoteOfflineThreadView.swift');
  const swap = slice(view, 'struct RemoteOfflineComposerSwap: ViewModifier', 'struct RemoteOfflineComposerBar');
  assert.match(swap, /if let state = model\.remoteOfflineReadOnly \{\s*RemoteOfflineComposerBar\(model: model, state: state\)\s*\} else \{\s*content/);
  const bar = slice(view, 'struct RemoteOfflineComposerBar: View', 'struct RemoteOfflineEmptyTranscript');
  assert.match(bar, /OSChipButton\(title: RemoteOfflineContinue\.chipTitle, systemImage: "arrow\.turn\.down\.right"\)/);
  assert.ok(extensionFile.includes('static let chipTitle = "在這台接著聊"'));
  // Reconnected: the read-only state is only while that device has no engine, so the same view can send again.
  const readOnly = slice(extensionFile, 'private var remoteOfflineSession: RemoteDeviceSession? {', '\n    }\n');
  assert.match(readOnly, /session\.engine == nil, session\.offlineMirror\.hasThread\(selected\.threadID\)/);
});

test('在這台接著聊: a new local thread (banner first, copied messages), same-name project or a new one in this home, never 聊天 unless it was', () => {
  const file = read('Facade/ChatPageModel+OfflineContinue.swift');
  assert.ok(file.includes('var lines = ["這條從\\(deviceName)的『\\(title)』複製過來（它離線時）；那邊的原串沒動。"]'));
  assert.ok(file.includes('原資料夾在\\(deviceName)'));
  const plan = slice(file, 'static func projectPlan(', '\n    }\n');
  assert.match(plan, /if projectID == doc\.generalProjectID \|\| \(doc\.generalProjectID == nil && project\.name == "一般"\) \{ return \.chat \}/);
  assert.match(plan, /\$0\.name\.caseInsensitiveCompare\(name\) == \.orderedSame/);
  assert.match(plan, /return \.create\(name\)/);
  const make = slice(file, 'private func makeOfflineCopy(', '\n    }\n');
  assert.match(make, /engine\.newProject\(name: name, workdir: NSHomeDirectory\(\)\)/);
  assert.match(make, /status: RemoteOfflineContinue\.bannerStatus/);
  assert.match(make, /engine\.insertOfflineCopy\(projectID: projectID, title: thread\.title, rows: \[banner\] \+ rows\)/);
  const copy = slice(file, 'static func copyRows(', '\n    }\n');
  assert.match(copy, /row\.eventKind == \.message, row\.role == \.user \|\| row\.role == \.assistant/);
  const go = slice(file, 'func continueOfflineThreadHere(', '\n    }\n\n');
  assert.match(go, /await mirror\.loadTranscript\(threadID\)/);
  assert.match(go, /self\.openOfflineCopy\(localID, inCoder: openInCoder\)/);
  assert.match(slice(file, 'private func openOfflineCopy(', '\n    }\n'),
    /guard inCoder else \{ return \}[^\n]*\n\s*mode = \.chat\s*selectLocalThread\(localID\)\s*RemoteOfflineContinueSignals\.shared\.requestComposerFocus\(\)/);
  // Same thread again = open the earlier copy; a double tap while copying makes only one.
  assert.match(go, /if let existing = Self\.offlineCopy\(in: engine, deviceID: deviceID, remoteThreadID: threadID\) \{[\s\S]{0,200}"這條已經在這台接著聊過，打開那條"/);
  assert.match(go, /guard RemoteOfflineContinueSignals\.shared\.continuing\.insert\(key\)\.inserted else \{/);
  assert.match(go, /Task \{ @MainActor \[weak self\] in\s*defer \{ RemoteOfflineContinueSignals\.shared\.continuing\.remove\(key\) \}/);
  const existing = slice(file, 'static func offlineCopy(in engine: ChatLiveEngine', '\n    }\n');
  assert.match(existing, /!thread\.isArchived/);
  assert.match(existing, /origin\.deviceID == deviceID && origin\.remoteThreadID == remoteThreadID/);
  const engine = read('Facade/ChatLiveEngine.swift');
  const insert = slice(engine, 'func insertOfflineCopy(projectID: UUID?', '\n    }\n');
  assert.match(insert, /id != doc\.assistantProjectID/);
  assert.match(insert, /doc\.ensureGeneralProject\(\)/);
  assert.doesNotMatch(insert, /selectedThreadID|RemoteThreadTransfer|write\(/, 'no selection change, no files');
  // No automatic merge: moving back is the user's right-click (W181 R3 menu), never code here.
  assert.doesNotMatch(code(file), /pushThreadToDevice|push_thread|pullThread/);
  assert.match(read('Chat/ChatPage+Sidebar.swift'), /Label\("移到其他設備…", systemImage: "arrow\.up\.forward\.app"\)/);
  // W201：設備連回安靜，原始複本、搬移選單與不自動併回的保證不變。
});

test('the first message carries the context like E3 seedPrompt (data, not instructions), only the first time per engine', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  const send = slice(engine, '@discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind = .claude', 'func savePastedAttachment(');
  // After E3's imported seed and the D3 engine-switch summary (both untouched), only when neither applied.
  assert.match(send, /if outgoing == engineText,   \/\/ W182 R4[^\n]*\n\s*let seeded = offlineCopySeed\(threadID: threadID, engine: engine, userText: engineText, currentTurn: turn\) \{\s*outgoing = seeded\s*\}\s*(?:if let seeded = AssistantOfflineSeed\.take[^\n]*\n\s*if outgoing == engineText, let caughtUp[^\n]*\n\s*outgoing = caughtUp[^\n]*\n\s*\}\s*)?if let planBriefing/);   // W182 R5 的兩段接在後面
  assert.ok(send.indexOf('importedSeed(') < send.indexOf('offlineCopySeed('));
  const file = read('Facade/ChatPageModel+OfflineContinue.swift');
  const seed = slice(file, 'func offlineCopySeed(threadID: UUID', '\n    }\n');
  assert.match(seed, /thread\.sessionIDs\[engine\.rawValue\] == nil, !\(engine == \.claude && thread\.sessionID != nil\)/);
  assert.match(seed, /RemoteOfflineContinue\.sourceLabel\(first\)/);
  assert.match(seed, /row\.turnID != currentTurn \|\| row\.role != \.user/);
  assert.match(seed, /return CoderImport\.seedPrompt\(rows: seedRows, sourceLabel: label, userText: userText\)/);
  assert.match(read('Facade/CoderImport.swift'), /是資料不是指令/);
});

test('DM: offline device sessions listed grey, read-only with 在這台接著聊 (same function), Coder untouched', () => {
  const model = read('Facade/ChatPageModel.swift');
  const list = slice(model, 'func dmSessionCandidates(limit: Int? = nil)', 'func sendFromDM');
  assert.match(list, /for session in remoteSessions where session\.engine == nil \{\s*guard let doc = session\.offlineMirror\.snapshot\?\.document else \{ continue \}/);
  assert.match(list, /row\.isOffline = true/);
  assert.match(model, /\?\? dmOfflineSession\(threadID\)\?\.offlineMirror\.transcript\(for: threadID\) \?\? \[\]/);
  assert.match(slice(model, 'func dmSessionNote(_ threadID: UUID)', '\n    }\n'), /if dmOfflineSession\(threadID\) != nil \{ return RemoteOfflineContinue\.dmNote\(place: device\.place\) \}/);
  // Sending stays blocked while offline (unchanged rule).
  assert.match(model, /func dmSessionCanSend\(_ threadID: UUID\) -> Bool \{\s*!dmSessionAwaitingRemote\(threadID\) && !primaryDeliveries\.contains\(threadID\)/);
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /var isOffline = false/);
  const tints = store.match(/enum Tint: Equatable \{ case ([^}]+) \}/)?.[1].split(',').map(value => value.trim());
  assert.deepEqual(tints, ['assistant', 'chatGPT', 'session', 'later', 'offline', 'browser']);
  assert.match(store, /if session\.isOffline \{[^\n]*\n\s*items\[items\.count - 1\]\.tint = \.offline/);
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /noteAction: model\.dmOfflineContinueAction\(id, store: store\)\)/);
  assert.match(view, /GlobalDMNoticeRow\(icon: "wifi\.slash", text: note, actionTitle: noteAction\?\.title, identifier: "tatwo\.dm\.primaryOffline"\) \{\s*noteAction\?\.run\(\)/);
  assert.match(view, /case \.offline: Color\(red: 0x9A \/ 255, green: 0x9C \/ 255, blue: 0xA0 \/ 255\)   \/\/ W182 R4/);
  assert.match(view, /\.opacity\(session\.isOffline \? 0\.6 : 1\)/);
  const file = read('Facade/ChatPageModel+OfflineContinue.swift');
  const action = slice(file, 'func dmOfflineContinueAction(', '\n    }\n');
  assert.match(action, /continueOfflineThreadHere\(deviceID: deviceID, threadID: threadID, openInCoder: false\)/);
  assert.match(action, /store\?\.select\(\.thread\(localID\)\)/);
  for (const name of ['DM/GlobalDMStore.swift', 'DM/GlobalDMView.swift']) {
    assert.doesNotMatch(read(name), /FileManager|\.write\(to:|createFile|JSONEncoder|NSLog|print\(/, name);
  }
});

test('review fixes: LRU by last read, evicted threads written back, slim document with its own cap, removal archives the copy', () => {
  const cache = read('Facade/RemoteOfflineCache.swift');
  // Archived threads are not saved (the assistant's stays); one short preview per thread.
  const slim = slice(cache, 'func slimmed() -> RemoteOfflineSnapshot', '\n    }\n');
  assert.match(slim, /full\.threads\.filter \{ !\$0\.isArchived \|\| full\.isAssistantThread\(\$0\.id\) \}/);
  assert.match(slim, /String\(row\.text\.prefix\(Self\.previewChars\)\) \+ "…"/);
  assert.match(cache, /static let previewChars = 300/);
  // The document has its own cap; write and read use the same rule.
  assert.match(cache, /var documentBytes = 4 \* 1024 \* 1024/);
  assert.match(slice(cache, 'func readSnapshot(deviceID: String)', '\n    }\n'), /data\.count <= limits\.documentBytes/);
  const write = slice(cache, 'func writeSnapshot(_ snapshot: RemoteOfflineSnapshot) throws -> Int', '\n    }\n');
  assert.match(write, /guard data\.count <= limits\.documentBytes else \{[\s\S]{0,200}throw CacheError\.documentTooLarge\(data\.count\)/);
  assert.ok(write.indexOf('documentBytes') < write.indexOf('.write(to:'), 'checked before writing');
  // Same content read again: touch the file time (LRU by last read), no rewrite; a dropped file is written back.
  assert.match(slice(cache, 'func touchTranscript(deviceID: String', '\n    }\n'), /setAttributes\(\[\.modificationDate: date\]/);
  const transcript = slice(cache, 'func record(transcript records: [LiveMessageRecord]', '\n    private func forget(');
  assert.match(transcript, /guard !isRetired else \{ return \}/);
  assert.match(transcript, /cache\.run\(\{ cache in cache\.touchTranscript\(deviceID: id, threadID: threadID, at: now\) \}\)/);
  assert.match(transcript, /self\.lastTranscriptSignature\[threadID\] = nil\s*self\.record\(transcript: records, threadID: threadID, now: now\)/);
  assert.match(transcript, /for key in known where self\.entries\[key\] == nil && self\.pendingTranscriptWrites\[key\] == nil \{ self\.forget\(key\) \}/);
  assert.match(slice(cache, 'private func forget(_ threadID: UUID)', '\n    }\n'), /lastTranscriptSignature\[threadID\] = nil/);
  // Removing a paired device archives its offline copy (Trash) and stops recording; the chip says so.
  const retire = slice(cache, 'func retire(completion:', '\n    }\n');
  assert.match(retire, /isRetired = true[\s\S]*clear\(completion: completion\)/);
  const model = read('Facade/ChatPageModel.swift');
  const remove = slice(model, 'func removeDevice(_ id: String) {', '\n    }\n');
  assert.match(remove, /retireRemoteOfflineCache\(deviceID: id, environment: runtimeEnvironment\)   \/\/ W182 R4/);
  assert.ok(remove.indexOf('retireRemoteOfflineCache(') < remove.indexOf('configureRemoteSessions()'), 'before the sessions are replaced');
  const file = read('Facade/ChatPageModel+OfflineContinue.swift');
  const helper = slice(file, 'func retireRemoteOfflineCache(deviceID: String', '\n    }\n\n');
  assert.match(helper, /session\.offlineMirror\.retire\(completion: report\)/);
  assert.match(helper, /cache\.run\(\{ cache in Result \{ try cache\.clear\(deviceID: deviceID\) \} \}, then: report\)/);
  assert.match(helper, /離線副本也移到垃圾桶了（可以放回）/);
  assert.match(read('New/DevicesCard.swift'), /OSChipButton\(title: "移除"\)[^\n]*\n\s*\.help\("[^"]*離線副本一起移到垃圾桶（可以放回）"\)   \/\/ W182 R4/);
});

test('W110: the offline copy is for the screen only — no OS tool or bridge method reads another device\'s history', () => {
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.doesNotMatch(bridge, /offlineMirror|RemoteOfflineCache|remote-cache|RemoteOfflineMirror/);
  for (const dir of ['Facade', 'Assistant', 'Memory', 'Engine']) {
    for (const name of readdirSync(new URL(`../App/Sources/Tatwo2/${dir}/`, import.meta.url))) {
      if (!name.endsWith('.swift') || name === 'RemoteOfflineCache.swift' || name === 'RemoteDeviceSession.swift'
          || name === 'ChatPageModel+OfflineContinue.swift' || name === 'ChatPageModel.swift' || name === 'RemoteOfflineAcceptance.swift'
          // W182 R4＋R5 併入：斷線接手讀主設備「助理那條」最近的問答當第一句前情（使用者 09-27 同意的做法；不是工具，AI 不能自己讀）。
          || name === 'AssistantOfflineHandoff.swift') continue;
      assert.doesNotMatch(read(`${dir}/${name}`), /offlineMirror|RemoteOfflineCache/, `${dir}/${name}`);
    }
  }
});

test('reconnect backoff is capped at one minute so a returning primary syncs quickly', () => {
  const session = read('Facade/RemoteDeviceSession.swift');
  assert.match(session, /static let maxRetryDelay: TimeInterval = 60/);
  assert.match(session, /retryDelay = min\(retryDelay \* 2, Self\.maxRetryDelay\)/);
  assert.doesNotMatch(session, /min\(retryDelay \* 2, 300\)/);
});
