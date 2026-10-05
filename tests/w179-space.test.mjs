import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('TATWO is a builtin with stable raw identity, first in all three tab lists', () => {
  for (const file of ['Chat/ChatPageConstants.swift', 'Space/SpaceSetupPreviewState.swift', 'Space/SpaceWorkspaceDocument.swift']) {
    const source = read(file);
    assert.match(source, /allCases: \[Self\] = \[\.tatwo, \.chat, \.cli, \.bot, \.browser, \.chatgpt\]/);
  }
  assert.match(read('Chat/ChatPageConstants.swift'), /case "tatwo": self = \.tatwo/);
  const document = read('Space/SpaceWorkspaceDocument.swift');
  assert.match(document, /if !tabOrder\.contains\(\.tatwo\) \{ tabOrder\.insert\(\.tatwo, at: 0\) \}/);
  assert.match(document, /for tab in SpaceManagedTab\.allCases where !tabOrder\.contains\(tab\) \{ tabOrder\.append\(tab\) \}/);
});

test('assistant has durable dedicated identity and sidecar-level persona, not selection-based injection', () => {
  const store = read('Facade/ChatLiveStore.swift');
  assert.match(store, /var assistantProjectID: UUID\?/);
  const ensure = store.slice(store.indexOf('mutating func ensureAssistantProject'), store.indexOf('mutating func ensureGeneralProject'));
  assert.match(ensure, /ensureAssistantThread/);
  assert.doesNotMatch(ensure, /selectedThreadID\s*=/);
  const engine = read('Facade/ChatLiveEngine.swift');
  assert.match(engine, /d\.ensureAssistantThread\(\)/);
  assert.match(engine, /if d != original \{ store\.save\(d\) \}/);
  assert.match(engine, /threadRecord\(threadID\)\?\.projectID == doc\.assistantProjectID/);
  assert.match(engine, /s\.start\([^\n]*systemPrompt: composedSystemPrompt\(threadID: threadID/);
  assert.match(read('Facade/OSUpstream.swift'), /TatwoResources\.url\(forResource: "tatwo-assistant", withExtension: "md"\)/);
  const manifest = readFileSync(new URL('../Package.swift', import.meta.url), 'utf8');
  assert.equal((manifest.match(/\.copy\("[^"]*Resources\/tatwo-assistant\.md"\)/g) ?? []).length, 2);
});

test('assistant sends to explicit local ID and all Coder lists exclude the project', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /var assistantThreadID: UUID\? \{ localLive\?\.doc\.assistantThreadID \}/);
  const send = model.slice(model.indexOf('func sendToAssistant'), model.indexOf('func sendAssistantDraft'));
  assert.match(send, /let id = assistantThreadID, let engine = localLive/);
  assert.match(send, /engine\.send\(threadID: id/);
  assert.doesNotMatch(send, /selectedThreadID|activeConversationEngine|selectedRemote/);
  for (const [start, end] of [['var filteredProjects:', 'var '], ['var pinnedThreadRefs:', 'var activeMappings:'], ['var sidebarStandaloneThreads:', 'var activeGoalNextActionLabel:']]) {
    const offset = model.indexOf(start);
    const slice = model.slice(offset, model.indexOf(end, offset + start.length));
    assert.match(slice, /!= document\.assistantProjectID/);
  }
  assert.match(model, /default: return \.chat/);
});

test('TATWO has its own transcript/composer, selectable conversation and disabled future rows', () => {
  const pane = read('Assistant/AssistantSpacePane.swift');
  assert.match(pane, /model\.assistantMessages/);
  assert.match(pane, /text: \$model\.assistantPrompt/);
  assert.match(pane, /model\.sendAssistantDraft/);
  assert.doesNotMatch(pane, /model\.selectedThreadID|model\.prompt\b/);
  const sidebar = read('Assistant/AssistantSidebarList.swift');
  // W180 E2：側欄列由 AssistantSpaceTab.allCases 產生，名稱與「階段 2／之後」在 enum 那個檔。
  const tabs = read('Assistant/AssistantSpaceTabs.swift');
  assert.match(sidebar, /ForEach\(AssistantSpaceTab\.allCases\)/);
  // W180 E1：記憶頁接上了，不再是「階段 2」佔位。
  for (const name of ['對話', '記憶', '全域狀態', '專案地圖', '團隊', '之後']) assert.ok(tabs.includes(`"${name}"`), name);
  assert.ok(!tabs.includes('"階段 2"'), 'memory is no longer a stage-2 placeholder');
  assert.match(sidebar, /\.disabled\(true\)/);
  assert.match(read('Chat/ChatPage+Panels.swift'), /model\.mode == \.tatwo[\s\S]*AssistantSpacePane\(model: model\)/);
  assert.match(read('Chat/ChatPage+Sidebar.swift'), /case \.tatwo:\s*tatwoSidebar/);
  assert.match(read('Chat/ChatPage.swift'), /model\.mode != \.tatwo && model\.mode != \.browser/);
});

test('headless acceptance covers fresh and actual legacy workspace, restart, filters, selection and persona', () => {
  assert.match(read('SelfTest.swift'), /TATWO2_SELFTEST"\] == "w179space"/);
  const checks = read('Assistant/AssistantSpaceAcceptance.swift');
  for (const marker of ['(a)', '(b)', '(c)', '(d)', '(e)', '(f)', '(g)', '(h)', '(i)', 'space-workspaces.json', 'W179SPACE SUMMARY'])
    assert.ok(checks.includes(marker), marker);
});

test('remote wire document and projection carry assistant identity without changing generalProjectID', () => {
  const remote = read('Facade/RemoteLiveEngine.swift');
  const projection = remote.slice(remote.indexOf('var document:'), remote.indexOf('func transcript('));
  assert.match(projection, /assistantProjectID: doc\.assistantProjectID/);
  assert.doesNotMatch(projection, /generalProjectID:/);
  assert.equal((remote.match(/LiveDocumentRecord = try Self\.decode\(result\["document"\]\)/g) ?? []).length, 2);
  const store = read('Facade/ChatLiveStore.swift');
  assert.match(store, /struct LiveDocumentRecord: Codable, Equatable/);
  assert.match(store, /var assistantProjectID: UUID\?/);
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.match(bridge, /"document": try Self\.jsonObject\(snapshot\.0\)/);
  assert.match(bridge, /var snapshot = live\.doc/);
  const checks = read('Assistant/AssistantSpaceAcceptance.swift');
  assert.match(checks, /JSONSerialization\.jsonObject\(with: encoder\.encode\(remoteRecord\)\)/);
  assert.match(checks, /initial: \["document": wireDocument/);
  assert.match(checks, /remote\.doc\.assistantProjectID == assistantProjectID/);
});

test('local and both remote fallbacks use assistant-free candidates, even for saved IDs', () => {
  const visibility = read('Assistant/AssistantCoderVisibility.swift');
  assert.match(visibility, /projects\.filter \{ \$0\.id != assistantProjectID \}/);
  assert.match(visibility, /let threads = coderProjects\.lazy\.flatMap\(\\\.threads\)/);
  assert.match(visibility, /threads\.contains\(where: \{ \$0\.id == preferred \}\)/);
  assert.match(visibility, /return threads\.first\?\.id/);
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /session\.document\.coderThreadID\(preferred: session\.engine\?\.doc\.selectedThreadID\)/);
  assert.match(model, /session\.document\.coderThreadID\(preferred: engine\.doc\.selectedThreadID\)/);
  assert.match(model, /document\.coderThreadID\(preferred: localLive\?\.doc\.selectedThreadID\)/);
  assert.doesNotMatch(model, /\bdocument\.projects\.lazy\.flatMap\(\\\.threads\)\.first\?\.id/);
});

test('CLI project menus, transcript history and remote sidebar exclude the assistant home', () => {
  const sidebar = read('Chat/ChatPage+Sidebar.swift');
  const cli = sidebar.slice(sidebar.indexOf('var cliSidebar:'));
  assert.match(cli, /ForEach\(model\.document\.coderProjects\)/);
  assert.doesNotMatch(cli, /ForEach\(model\.document\.projects\)/);
  assert.match(read('Chat/ChatPage+Panels.swift'), /projects: model\.document\.coderProjects\.map/);
  assert.match(read('Facade/ChatPageModel.swift'), /let projects = session\.document\.coderProjects\.map/);
});

test('ID selection redirects local/socket and remote assistant threads before changing Coder selection', () => {
  const model = read('Facade/ChatPageModel.swift');
  const local = model.slice(model.indexOf('func selectLocalThread('), model.indexOf('func pushThreadToDevice('));
  assert.match(local, /if let threadID, localLive\?\.doc\.isAssistantThread\(threadID\) == true \{\s*mode = \.tatwo\s*return\s*\}/);
  assert.ok(local.indexOf('mode = .tatwo') < local.indexOf('selectedRemote = nil'));
  const remote = model.slice(model.indexOf('func selectRemote('), model.indexOf('func selectLocalThread('));
  assert.match(remote, /if remote\.doc\.isAssistantThread\(threadID\) \{\s*mode = \.tatwo\s*return true\s*\}/);
  assert.ok(remote.indexOf('mode = .tatwo') < remote.indexOf('selectedThreadID = threadID'));
  const discussion = model.slice(model.indexOf('func selectDiscussion('), model.indexOf('func compressDiscussion('));
  assert.match(discussion, /if activeLive\.doc\.isAssistantThread\(discussionID\) \{\s*mode = \.tatwo\s*return\s*\}/);
  assert.ok(discussion.indexOf('mode = .tatwo') < discussion.indexOf('selectedDiscussionID = discussionID'));
  assert.match(model, /func select\(projectID: UUID, threadID: UUID\) \{ selectLocalThread\(threadID\) \}/);
  const bridge = read('Facade/OSAgentBridge.swift');
  const socket = bridge.slice(bridge.indexOf('case "select_thread":'), bridge.indexOf('case "github_import_from_gh":'));
  assert.match(socket, /model\?\.selectLocalThread\(id\)/);
  assert.match(read('Assistant/AssistantCoderVisibility.swift'),
    /guard let assistantProjectID else \{ return false \}[\s\S]*\$0\.id == threadID && \$0\.projectID == assistantProjectID/);
});

test('assistant manual describes session distillation as reusable skills or other material', () => {
  const manual = read('Resources/tatwo-assistant.md');
  assert.ok(manual.includes('`/蒸餾` 在一條對話做完後，把它整理成技能或其他可以重用的東西；'));
  assert.ok(!manual.includes('`/蒸餾` 把經驗整理後寫進 GBrain 或 skillet；'));
});
