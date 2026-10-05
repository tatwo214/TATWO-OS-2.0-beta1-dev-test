import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('sendFromDM targets an explicit local thread and never touches Coder selection or draft', () => {
  const model = read('Facade/ChatPageModel.swift');
  const send = slice(model, 'func sendFromDM(threadID: UUID, text: String', 'var localLiveForBridge');
  // W184 H4 修正第三輪：多帶一個 onUndelivered（沒送到時照同一套放回），其他照舊。
  assert.match(send, /if threadID == assistantThreadID \{\s*return sendToAssistant\(text: text, attachments: attachments, onDelivered: onDelivered(, onUndelivered: onUndelivered)?\)\s*\}/);
  assert.match(send, /let engine = localLive, let record = engine\.threadRecord\(threadID\)/);
  // W180 D2：子討論串也能當對象（跟 Coder 一樣送）；派到遠端設備的房間照舊不列。
  assert.match(send, /!record\.isArchived, record\.deviceID == nil,/);
  assert.doesNotMatch(send, /record\.parentThreadID == nil/);
  // W184 H4 修正（GPT-6 H4 審查 #2、#3）：守的東西不變（這條的送出帶 ultrawork）、帶的是「這一條自己的」：不再當 sidecar 啟動時的
  // systemPrompt（主視窗 Coder 那條的 collaborationLevel），改成這一輪明確帶著的 ultrawork（那一條記住的檔位與角色）。
  assert.match(send, /systemPrompt: nil, attachments: attachments,/);
  assert.match(send, /ultrawork: ultraworkSettings\(for: threadID\)\)/);
  assert.doesNotMatch(send, /ultraworkTurnBriefing/, 'no longer the Coder thread\'s briefing');
  assert.match(send, /!engine\.doc\.isAssistantThread\(threadID\)/);
  assert.match(send, /let preferences = ChatModelPreferences\.selection\(record\)\s*let route = preferences\.route/);
  const preferences = read('Chat/ChatModelPreferences.swift');
  assert.match(preferences, /ChatRouteChoice\.resolve\(overrideRouteID \?\? thread\?\.requestedModel \?\? thread\?\.model \?\? "gpt-6\.1-sol", deviceID: deviceID\)/);
  assert.match(send, /engine\.send\(threadID: threadID, text: text, model: modelArgument, engine: kind/);
  assert.match(send, /reasoningEffort: kind == \.codex \? preferences\.effort : nil/);
  assert.match(send, /serviceTier: kind == \.codex\s*\? preferences\.speed\.appServerValue : nil/);
  assert.match(preferences, /let effort = thread\?\.requestedEffort \?\?/);
  assert.match(preferences, /thread\?\.requestedSpeedTier\.flatMap\(TatwoModelSpeedTier\.init\(rawValue:\)\) \?\? route\.defaultSpeedTier \?\? \.fast/);
  assert.match(send, /engine\.appendSystemMessage\(threadID: threadID,[\s\S]*status: "error\|登入"\)/);
  assert.doesNotMatch(send, /selectedThreadID|\bprompt\b|droppedPaths|activeConversationEngine|selectedRemote|localSelectedThreadID/);
  // Same gates as the Coder composer: no new turn while that thread's PR work runs; Coder-only slash commands stay out;
  // 「記住…」 becomes a memory proposal only when the message was really sent.
  assert.match(send, /Self\.dmCoderOnlyCommand\(in: text\) == nil/);
  assert.match(send, /guard !pendingPR\.contains\(threadID\) else \{\s*engine\.appendSystemMessage\(threadID: threadID, text: "PR 作業處理中，請等目前工作結束。", status: "info\|PR"\)/);
  assert.match(send, /if accepted, let remembered = UserMemoryText\.rememberRequest\(in: text\)/);
  assert.match(send, /UserMemoryStore\.shared\.propose\(text: remembered, source: source\)/);
  const commands = slice(model, 'static func dmCoderOnlyCommand(in text: String) -> String?', '\n    }\n');
  for (const command of ['/plan', '/goal', '/pr', '/討論串', '/顯示討論串', '/issue', '/feedback', '/蒸餾']) {
    assert.ok(commands.includes(`"${command}"`), command);
  }
  // The existing TATWO send stays byte-compatible with the W179 space contract.
  const assistant = slice(model, 'func sendToAssistant', 'func sendAssistantDraft');
  assert.doesNotMatch(assistant, /sendFromDM|dmSessionCandidates/);
});

test('session candidates exclude the assistant, archived and remote rooms; sub-threads hang under their parent', () => {
  const model = read('Facade/ChatPageModel.swift');
  const list = slice(model, 'func dmSessionCandidates(limit: Int? = nil)', 'func sendFromDM');
  assert.match(list, /guard let doc = localLive\?\.doc/);
  assert.match(list, /guard !thread\.isArchived, thread\.deviceID == nil, let projectID = thread\.projectID,/);
  assert.match(list, /guard depth < 4, let parent = threads\[parentID\] else \{ return false \}\s*return listed\(parent, depth: depth \+ 1\)/);
  assert.match(list, /parentID: thread\.parentThreadID,/);
  assert.match(list, /projectID != doc\.assistantProjectID/);
  assert.match(list, /\$0\.activity > \$1\.activity/);
  assert.match(list, /limit\.map \{ Array\(named\.prefix\(\$0\)\) \} \?\? named/);
  assert.match(list, /doc\.generalProjectID \? "聊天"/);
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /static let recentLimit = 5/);
  assert.match(store, /filter \{ \$0\.parentID == nil \}\.prefix\(Self\.recentLimit\)/);
  assert.match(store, /var label: String \{ parentTitle\.map \{ "\\\(projectName\) › \\\(\$0\) › \\\(title\)" \} \?\? "\\\(projectName\) › \\\(title\)" \}/);
});

test('store keeps per-target drafts, remembers the last target, and has a default-on master switch', () => {
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /@MainActor\s*final class GlobalDMStore: ObservableObject/);
  assert.match(store, /static let shared: GlobalDMStore = \{\s*let store = GlobalDMStore\(refreshChatGPTToolCatalog: \{\s*ChatGPTSpaceModel\.shared\.refreshToolCatalog\(\)\s*\}\)/);
  assert.match(store, /case assistant\s*case thread\(UUID\)\s*case chatGPT/);
  assert.match(store, /@Published private\(set\) var drafts: \[GlobalDMTarget: String\]/);
  assert.match(store, /defaults\.object\(forKey: Self\.enabledKey\) as\? Bool \?\? true/);
  assert.match(store, /defaults\.set\(newTarget\.storageValue, forKey: Self\.lastTargetKey\)/);
  // Only the switch and the target id are persisted; no conversation text.
  assert.equal((store.match(/defaults\.set\(/g) ?? []).length, 2);
  assert.match(store, /case \.thread\(let id\):\s*\/\/[^\n]*\n\s*if let command = ChatPageModel\.dmCoderOnlyCommand\(in: text\) \{[\s\S]{0,120}return false\s*\}\s*accepted = model\?\.sendFromDM\(threadID: id, text: text, attachments: paths, onDelivered: delivered(,\s*onUndelivered: undeliveredBack)?\)/);
  const assistantSend = slice(slice(store, 'func send() -> Bool', '// MARK: - 模型 chip'), 'case .assistant:', 'case .thread(let id):');
  assert.match(assistantSend, /if let command = ChatPageModel\.dmCoderOnlyCommand\(in: text\) \{\s*notice = [^\n]+\s*return false\s*\}\s*accepted = model\?\.sendToAssistant\(text: text, attachments: paths, onDelivered: delivered,\s*onUndelivered: undeliveredBack\)/);
  // W179 F：送到了才清草稿（本機馬上、主設備等它回覆收到）；送出途中草稿被改過就不動。
  assert.match(store, /if self\.draft\(for: target\) == text \{ self\.setDraft\("", for: target\) \}/);
  assert.match(store, /pendingPermissionThreadIDs\.contains\(id\)/);
  assert.match(store, /IslandExceptionsNavigation\.openWork\(\)/);
  // The approval is an app-modal alert: the DM row must stay clickable during it and surface that alert.
  assert.match(store, /if let modal = NSApp\.modalWindow \{[\s\S]{0,120}modal\.orderFrontRegardless\(\)\s*modal\.makeKey\(\)/);
  const controller = read('DM/GlobalDMPanelController.swift');
  assert.match(controller, /panel\.worksWhenModal = true/);
});

test('ChatGPT target uses one resident ChatGPTConversationSession, leases only while shown, and writes nothing', () => {
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /\{ ChatGPTConversationSession\(\) \}/);
  // The lease follows what the user can actually see, and never wakes ChatGPT while this Space has its tab off.
  assert.match(store, /let wants = isEnabled && isShowingBox && target == \.chatGPT && chatGPTAvailable/);
  assert.match(store, /var isShowingBox: Bool \{ isFloatingOpen \|\| \(isOpen && isDockedVisible\) \}/);
  assert.match(store, /SpaceWorkspaceController\.shared\.allows\(\.chatgpt\)/);
  assert.match(store, /func openChatGPTSpace\(\) \{\s*guard chatGPTAvailable else \{ return \}/);
  assert.match(store, /case \.chatGPT:\s*guard chatGPTAvailable else \{ return false \}/);
  const panelController = read('DM/GlobalDMPanelController.swift');
  assert.match(panelController, /if !store\.isDockedVisible \{ store\.isDockedVisible = true \}/);
  assert.match(panelController, /private func detachDocked\(\) \{\s*if store\.isDockedVisible \{ store\.isDockedVisible = false \}/);
  assert.match(store, /chatGPT\.appear\(\)/);
  assert.match(store, /chatGPTSession\?\.disappear\(\)/);
  assert.match(store, /model\?\.mode = \.chatgpt/);
  assert.match(store, /name: \.tatwoOpenWorkOSWindow, object: TatwoPage\.chat\.rawValue/);
  for (const file of ['DM/GlobalDMStore.swift', 'DM/GlobalDMView.swift', 'DM/GlobalDMPanelController.swift']) {
    const source = read(file);
    assert.doesNotMatch(source, /FileManager|\.write\(to:|createFile|JSONEncoder|NSLog|print\(/, file);
  }
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /GlobalDMChatGPTPane\(store: store, session: store\.chatGPT, isAvailable: store\.chatGPTAvailable\)/);
  assert.match(view, /ChatGPT Space 已關閉/);
  assert.match(view, /到 ChatGPT Space 登入/);
  // W184 AB：「OS 不記錄對話內容」從頂列的名字行拿掉（名字行整行拿掉）；房 C 把它放到 ChatGPT 輸入框上方，由房 C 的 tests/w184-chat.test.mjs 守。
  // 這裡守：頂列不再放它。
  assert.doesNotMatch(read('DM/GlobalDMPhoneBox.swift'), /OS 不記錄對話內容/);
});

test('independent floating panel is non-activating, key-capable and on every Space and full-screen app', () => {
  const controller = read('DM/GlobalDMPanelController.swift');
  assert.match(controller, /styleMask: \[\.borderless, \.nonactivatingPanel\]/);
  assert.match(controller, /panel\.collectionBehavior = \[\.canJoinAllSpaces, \.fullScreenAuxiliary\]/);
  assert.match(controller, /override var canBecomeKey: Bool \{ true \}/);
  assert.match(controller, /panel\.hidesOnDeactivate = false/);
  const show = slice(controller, 'private func showFloating(focus: Bool) {', '\n    }\n');
  assert.match(show, /if !panel\.isVisible \{ panel\.orderFrontRegardless\(\) \}\s*refreshBrowserPlacement\(\)\s*if focus \{ panel\.makeKey\(\) \}/);
  assert.match(slice(controller, 'private func refreshBrowserPlacement() {', '\n    }\n'), /if let browser = browserServices\.browser \{ browser\.containerMoved\(\) \}\s*else if store\.isBrowsing \|\| store\.isBrowsingBeside \{ DMBrowser\.shared\.containerMoved\(\) \}/);
  // Only a fresh open takes focus; hide/unhide/activate reconciles never steal it back.
  assert.match(controller, /let floatingJustOpened = store\.isFloatingOpen && !floatingWasOpen/);
  assert.match(controller, /showFloating\(focus: floatingJustOpened\)/);
  // ⌘H / Hide Others leave the floating box on screen, so ⌥⌘ works while TATWO is hidden.
  assert.match(controller, /panel\.canHide = false/);
  // A docked box opened while another app is in front hands keyboard focus back when it closes.
  assert.match(controller, /let hadKey = panel\.isKeyWindow\s*panel\.parent\?\.removeChildWindow\(panel\)\s*panel\.orderOut\(nil\)\s*if hadKey, NSApp\.isActive/);
  assert.match(controller, /NSMouseInRect\(mouse, \$0\.frame, false\)/);
  assert.match(controller, /visible\.maxX - GlobalDMLayout\.floatingInset/);
  assert.doesNotMatch(controller, /NSApp\.activate|activate\(ignoringOtherApps/);
  // Esc closes the DM, not the main window; IME composition keeps Esc.
  assert.match(controller, /event\.keyCode == 53/);
  assert.match(controller, /text\.hasMarkedText\(\)/);
  assert.match(controller, /if window === floating \{ store\.isFloatingOpen = false \}/);
});

test('hotkey wiring: foreground+visible main window toggles the docked box, otherwise floats; second press closes', () => {
  const controller = read('DM/GlobalDMPanelController.swift');
  assert.match(controller, /forName: \.tatwoToggleGlobalDM/);
  const resolve = slice(controller, 'static func resolve(', '\n    }\n');
  assert.match(resolve, /if floatingOpen \{ return \.closeFloating \}/);
  assert.match(resolve, /appActive && mainWindowVisible \? \.toggleDocked : \.openFloating/);
  assert.match(controller, /appActive: hostsWindows && NSApp\.isActive/);
  // ⌥⌘ needs the main window really in front of the user (this desktop, not fully covered); a focused docked box closes.
  assert.match(controller, /mainWindowVisible: mainWindowOnScreenForUser\(\) != nil/);
  assert.match(controller, /window\.isOnActiveSpace,\s*window\.occlusionState\.contains\(\.visible\)/);
  assert.match(controller, /dockedFocused: store\.isOpen && docked\?\.isKeyWindow == true/);
  assert.match(resolve, /if dockedFocused \{ return \.toggleDocked \}/);
  assert.match(controller, /window is TatwoWorkOSWindow && window !== closingWindow && window\.isVisible && !window\.isMiniaturized/);
  const shell = read('Shell/AppShell.swift');
  assert.match(shell, /GlobalHotkeyMonitor\.shared\.install\(\)\s*GlobalDMPanelController\.shared\.install\(\)/);
  assert.match(shell, /sharedChatPageModel = model\s*GlobalDMStore\.shared\.attach\(model\)/);
});

test('docked child panel follows the main window at the same bottom-right spot on every Space', () => {
  const controller = read('DM/GlobalDMPanelController.swift');
  assert.match(controller, /window\.addChildWindow\(panel, ordered: \.above\)/);
  for (const name of ['didResizeNotification', 'didMiniaturizeNotification', 'didDeminiaturizeNotification',
    'didEnterFullScreenNotification', 'didExitFullScreenNotification', 'willCloseNotification', 'willMiniaturizeNotification']) {
    assert.ok(controller.includes('NSWindow.' + name), name);
  }
  assert.match(controller, /NSApplication\.didHideNotification/);
  // W179 UI：擺位規則是純函式（GlobalDMDockLayout），控制器只把內容區、輸入框、模式交給它。
  // W184 AB：再加上目前形態的大小（停靠框也照形態）。
  assert.match(controller, /GlobalDMDockLayout\.place\(content: content, composer: composer, mode: store\.model\?\.mode, boxOpen: store\.isOpen,\s*boxSize: desk\.form\.size\)/);
  assert.match(read('DM/GlobalDMLayering.swift'), /GlobalDMLayout\.bottomInset\(contentWidth: content\.width, mode: mode\)/);
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /static let buttonSize: CGFloat = 44/);
  assert.match(view, /static let trailing: CGFloat = 12/);
  assert.match(view, /static let bottom: CGFloat = 8/);
  assert.match(view, /static let gap: CGFloat = 10/);
  // W181（使用者 09-27：「私訊筐再大 r角對照iphone螢幕弧度」）：框＝iPhone Duo 外螢幕 466×678，圓角 52（iPhone 螢幕的弧度）。
  assert.match(view, /static let box = CGSize\(width: 466, height: 678\)/);
  assert.match(view, /static let cornerRadius: CGFloat = 52/);
  assert.match(view, /static let floatingInset: CGFloat = 24/);
  assert.match(view, /Image\(systemName: "bubble\.left\.fill"\)/);
  // The round button lifts above the Coder/TATWO composer only when the right gutter cannot hold it.
  assert.match(view, /case \.chat\?, \.tatwo\?: return ChatUILayout\.chatColumnMaxWidth/);
  assert.match(view, /rightSpace >= trailing \+ buttonSize \+ 8 \? bottom : composerClearance/);
});

test('Bot tab hides its own round button only while the global DM is enabled', () => {
  const bot = read('Bot/BotStudioPage.swift');
  // W179 E：只讀總開關（@AppStorage 同一個鍵），不再訂閱整個私訊框狀態。
  assert.match(bot, /@AppStorage\(GlobalDMStore\.enabledKey\) private var globalDMEnabled = true/);
  assert.match(bot, /\.overlay\(alignment: \.bottomTrailing\) \{\s*if !globalDMEnabled \{ BotStudioMessagesFAB\(state: state\) \}\s*\}/);
});

test('box copy and structure follow the mock: target icons, session picker, approvals, hints, glass not blue', () => {
  const view = read('DM/GlobalDMView.swift');
  // W180 A3：對象改成框頂圖示列（助理、ChatGPT、Coder、最近 session、之後、設定直達鍵），圖示資料在 store。
  // W184 AB：⌥⌘ 與輔助使用權限的說明從頂列名字行搬進選單（GlobalDMPhoneBox.swift；W184 F：原本的「⋯ 更多」改成頁面圓鈕的右鍵選單），文字照舊。
  const more = read('DM/GlobalDMPhoneBox.swift');
  const copies = view + read('DM/GlobalDMStore.swift') + more;
  for (const copy of ['Coder 對話', '之後', 'Bot 團隊', 'LINE', '其他專案的對話…', '設定直達鍵…',
    'TATWO 助理', '⌥⌘', '開關', '要在其他 App 用 ⌥⌘，要開裝置控制和資料取用（舊稱輔助使用）權限', '等你核准', '到 Island 核准', '搜尋專案或對話']) {
    assert.ok(copies.includes(copy), copy);
  }
  // 守：有沒有輔助使用權限照實說，沒有時給一項打開設定（識別碼 tatwo.dm.accessibility 留在選單項上）。
  assert.match(more, /systemWide: monitor\.isSystemWide/);
  assert.match(more, /GlobalHotkeyMonitor\.shared\.openAccessibilitySettings\(\)/);
  assert.match(more, /NSUserInterfaceItemIdentifier\("tatwo\.dm\.accessibility"\)/);
  assert.match(view, /ChatComposerTextView\(text: draft/);
  assert.match(view, /onSubmit: \{ _ = store\.send\(\) \}/);
  // 守：停止鈕停的是私訊框這個對象（store.stop）。W184 C：36pt 的停止鈕是私訊框自己的（Coder 的 ChatComposerChrome 不改）。
  assert.match(view, /GlobalDMStopButton \{ store\.stop\(\) \}/);
  assert.match(view, /store\.isAwaitingApproval/);
  assert.match(view, /store\.revealApprovalInIsland\(\)/);
  assert.match(view, /case \.mine:[\s\S]*GlobalDMUserBubble\(text: bubble\.text\)/);
  assert.match(view, /onChange\(of: bubbles\.count\)/);
  assert.doesNotMatch(view, /\.blue\b|accentColor|borderedProminent|\.tint\(/);
});

test('executable self-test covers the brief', () => {
  const self = read('SelfTest.swift');
  assert.match(self, /TATWO2_SELFTEST"\] == "w179dm"/);
  assert.match(self, /GlobalDMAcceptance\.run\(\)/);
  const acceptance = read('DM/GlobalDMAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.match(acceptance, /isolated engine homes must be logged out/);
  for (const label of ['sendFromDM(B) keeps Coder selection on A', 'nothing lands in A',
    'B receives the message (logged-out: the error lands in B, not A)', 'each target keeps its own draft across switches',
    'tatwoToggleGlobalDM opens the DM', 'second tatwoToggleGlobalDM closes it', 'store recent list has no assistant',
    'unconnected ChatGPT does not send and keeps the draft', 'ChatGPT text is never written to disk',
    'pending PR blocks a DM send and says why in that thread', 'Coder-only slash commands are not sent from the DM',
    'hotkey closes a focused docked box opened while another app is in front',
    'hiding the main window releases the TAP lease and keeps the box state',
    'ChatGPT Space off: no lease, no wake-up, no send, no mode switch',
    'W179DM SUMMARY failures=']) {
    assert.ok(acceptance.includes(label), label);
  }
});
