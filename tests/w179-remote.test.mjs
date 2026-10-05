import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W179 F：助理只有一個、住在主設備。副設備連得到主設備時，TATWO 與私訊框的助理、私訊框的 Coder session
// 都走主設備（遠端引擎）；預設模型跳過停用的引擎；私訊框排版與無障礙名稱。原始碼契約，實際行為在 w179remote 自測。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('secondary + reachable primary: TATWO assistant uses the primary thread through the remote engine', () => {
  const routing = read('Assistant/AssistantPrimaryRouting.swift');
  assert.match(routing, /@MainActor\s*protocol AssistantRemoteEngine: AnyObject/);
  assert.match(routing, /extension RemoteLiveEngine: AssistantRemoteEngine \{\}/);
  // The primary comes from this device's identity file (read-only) and the paired device list.
  assert.match(routing, /DeviceIdentityStore\.readLocal\(entry: TatwoEntry\(environment: environment\)\)/);
  assert.match(routing, /identity\.role == \.secondary/);
  assert.doesNotMatch(routing, /DeviceIdentityStore\.forLocalDevice|\.write\(/, 'resolver never writes identity');

  const model = read('Facade/ChatPageModel.swift');
  const placement = slice(model, 'var assistantPlacement: AssistantPlacement {', '\n    }\n');
  assert.match(placement, /guard let device = assistantPrimaryDevice else \{ return \.local \}/);
  assert.match(placement, /if let remote = assistantPrimaryEngine, let id = remote\.doc\.assistantThreadID \{\s*return \.primary\(engine: remote, threadID: id, device: device\)/);
  // W181 R3：退不退回本機仍看「三家有沒有全勾」（W181 前的全停用），不看這台現在送不送得出。
  assert.match(placement, /return assistantLocalFallbackAllowed \? \.local : \.unreachable\(device, gap\)/);
  assert.match(slice(model, 'private var assistantLocalFallbackAllowed: Bool {', '\n    }\n'), /isDisabled: \{ self\.isEngineDisabled\(\$0\) \}\) != nil/);
  // Connecting never falls back to this device's thread (one conversation, not two); a local turn in flight stays local.
  assert.match(placement, /if gap == \.connecting \{ return \.unreachable\(device, gap\) \}/);
  assert.match(placement, /if localLive\?\.isRunning\(assistantThreadID\) == true \{ return \.local \}/);
  const connecting = slice(model, 'private var assistantPrimaryConnecting: Bool {', '\n    }\n');
  assert.match(connecting, /session\.engine == nil, session\.state == \.connecting/);
  assert.match(connecting, /!assistantPrimarySettledIDs\.contains\(device\.id\) \|\| !assistantLocalFallbackAllowed/);   // W181 R3
  // Same connection Coder uses for remote devices; primary/standalone (no primary device) stays local.
  const engine = slice(model, 'private var assistantPrimaryEngine: (any AssistantRemoteEngine)? {', '\n    }\n');
  assert.match(engine, /remoteSessions\.first \{ \$0\.device\.id == device\.id \}\?\.engine/);
  const device = slice(model, 'var assistantPrimaryDevice: AssistantPrimaryDevice? {', '\n    }\n');
  assert.match(device, /guard isLive, let primaryID = assistantPrimaryID/);

  const send = slice(model, 'func sendToAssistant', 'func sendAssistantDraft');
  // W182 R5：連回後剛才離線那段還沒補回時，先補完再送（見 w182-assistant-offline）；其餘照舊直接交給主設備。
  assert.match(send, /case \.primary\(let remote, let primaryThreadID, let device\):\s*(?:if assistantOfflineMergeOutstanding\(device\) \{[\s\S]*?\n            \}\s*)?return sendToPrimaryAssistant\(remote, threadID: primaryThreadID, device: device, text: text,\s*onDelivered: onDelivered\)/);
  assert.match(send, /case \.unreachable:\s*return false/);
  const primarySend = slice(model, 'private func sendToPrimaryAssistant(', '\n    }\n');
  assert.match(primarySend, /AssistantModelRouting\.primaryTurn\(choice: choice\)/);
  assert.match(primarySend, /deliverToPrimary\(remote, device: device, threadID: threadID, text: text, model: turn\.model, engine: turn\.kind,\s*assistantRoute: choice\?\.id, onDelivered: onDelivered\)/);
  assert.match(primarySend, /!primaryDeliveries\.contains\(threadID\)/);
  // The primary decides: no local disable/login judgement, no Coder/remote selection or draft.
  assert.doesNotMatch(primarySend, /isEngineDisabled|EngineDisableStore|engineLogin|selectedThreadID|selectedRemote|\bprompt\b|localLive/);
  for (const name of ['assistantMessages', 'assistantIsRunning']) {
    const body = slice(model, `var ${name}:`, '\n    }\n');
    assert.match(body, /case \.primary\(let remote, let id, _\): return (remote\.|Self\.primaryTranscript\(remote, id\))/, name);
  }
  const stop = slice(model, 'func stopAssistant()', '\n    }\n');
  assert.match(stop, /remote\.stop\(threadID: id\)/);
  // Updates from the primary redraw TATWO and the DM immediately.
  assert.match(model, /if session\.device\.id == self\.assistantPrimaryDevice\?\.id \{ self\.objectWillChange\.send\(\) \}/);
  // Hints from the primary's connection reach TATWO and the DM, not only Coder.
  assert.match(model, /if device\.id == self\.assistantPrimaryDevice\?\.id \{ self\.showPrimaryHint\(message, threadID: nil\) \}/);
  // A new revision clears the remote cache: fall back to the snapshot the document already carries, never a blank flash.
  const fallback = slice(model, 'static func primaryTranscript(', '\n    }\n');
  assert.match(fallback, /if !cached\.isEmpty \{ return cached \}\s*return remote\.threadRecord\(threadID\)\?\.messages\.map\(\\\.chatMessage\) \?\? \[\]/);
  const pane = read('Assistant/AssistantSpacePane.swift');
  assert.match(pane, /if model\.assistantMessages\.isEmpty, model\.assistantTranscriptLoading \{[\s\S]{0,120}ProgressView\("載入對話…"\)/);
});

test('sends to the primary wait for its receipt: draft kept until then, blocked meanwhile, failures explained', () => {
  const remote = read('Facade/RemoteLiveEngine.swift');
  const deliver = slice(remote, 'func deliver(threadID: UUID, text: String', 'nonisolated static func deliverParams(');
  assert.match(deliver, /perform\(\{ try \$0\.call\(method: "send_message", params: sent\) \}\)/);
  assert.match(deliver, /self\.refreshDocument\(notify: true\) \{ completion\(\.success\(\(\)\)\) \}/);
  assert.doesNotMatch(deliver, /onHint|hintOnce|return true/, 'failures go back to the caller, not a Coder-only hint');
  const params = slice(remote, 'nonisolated static func deliverParams(', '\n    }\n');
  assert.match(params, /if let engine \{ params\["engine"\] = engine\.rawValue \}/);
  assert.match(params, /if let assistantRoute \{ params\["assistantRoute"\] = assistantRoute \}/);
  const routing = read('Assistant/AssistantPrimaryRouting.swift');
  assert.match(routing, /func deliver\(threadID: UUID, text: String, model: String\?, engine: ClaudeSidecar\.Kind\?, assistantRoute: String\?,\s*completion: @escaping @MainActor \(Result<Void, Error>\) -> Void\)/);
  assert.doesNotMatch(slice(routing, 'protocol AssistantRemoteEngine', 'extension RemoteLiveEngine'), /func send\(/);
  const model = read('Facade/ChatPageModel.swift');
  const deliverTo = slice(model, 'private func deliverToPrimary(', '\n    }\n');
  assert.match(deliverTo, /primaryDeliveries\.insert\(threadID\)/);
  assert.match(deliverTo, /case \.success:\s*onDelivered\(\)/);
  assert.match(deliverTo, /let note = AssistantPlacement\.deliveryFailureNote\(error, device: device\)/);
  assert.match(deliverTo, /self\.showPrimaryHint\(onPrimary \? note : note\.replacingOccurrences\(of: "主設備「", with: "「"\),\s*threadID: threadID\)/);
  assert.match(slice(model, 'var assistantCanSend: Bool {', '\n    }\n'), /case \.primary\(_, let id, _\): return !primaryDeliveries\.contains\(id\)/);
  for (const code of ['assistant_busy', 'assistant_engines_disabled', 'assistant_engine_disabled', 'assistant_not_sent']) {
    assert.ok(routing.includes(`case "${code}": return`), code);
  }
  // W179 UI：送出失敗等提示放在輸入框下的狀態抽屜（純函式決定顯示哪一句），不在頁首。
  const pane = read('Assistant/AssistantSpacePane.swift');
  assert.match(pane, /let status = AssistantComposerStatus\.resolve\(hint: model\.assistantPrimaryHint/);
  assert.match(read('Assistant/AssistantComposerStatus.swift'), /if let hint[\s\S]{0,160}\.hint/);
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /if let hint \{\s*GlobalDMNoticeRow\(icon: "info\.circle", text: hint/);
});

test('unreachable primary + all local engines disabled: one plain note, no send, draft kept', () => {
  const routing = read('Assistant/AssistantPrimaryRouting.swift');
  assert.ok(routing.includes('"助理在主設備「\\(device.displayName)」上，現在連不上；連上後會自動接回。"'));
  assert.ok(routing.includes('"助理在主設備「\\(device.displayName)」上，現在還不能送出；草稿留著。"'));
  // W182 R5：連不上時這段連回後補回主設備那條（不再說「不會出現在主設備上」）。
  assert.doesNotMatch(routing, /localFallbackNote/); // W201：自動接手不報備。
  const pane = read('Assistant/AssistantSpacePane.swift');
  assert.ok(read('Assistant/AssistantComposerStatus.swift').includes('"tatwo-assistant-offline"'));
  // W179 UI：說明只經 AssistantComposerStatus 交給輸入框下的狀態抽屜——頁面只在那一處讀它，輸入框那一段沒有錯誤卡。
  assert.equal(pane.split('model.assistantPlacementNote').length - 1, 1, 'placement note is read in one place only');
  const composer = slice(pane, 'private func composer(column: CGFloat)', 'private var isConnecting');
  // W182 R5：主設備離線、在這台接著聊時，頁頂那一行已經說了，輸入框下不重複。
  assert.match(composer, /AssistantComposerStatus\.resolve\([^)]*placementNote: model\.assistantPlacementNote/);
  assert.ok(composer.includes('ChatComposerStatusDrawer(text: status.text, tone: status.tone)'));
  assert.doesNotMatch(composer, /ChatErrorCard/, 'not an error card');
  assert.match(pane, /ChatComposerSendButton\(enabled: model\.assistantCanSend/);
  assert.match(read('Facade/ChatPageModel.swift'), /func sendAssistantDraft\(\) \{\s*let text = assistantPrompt[\s\S]{0,120}sendToAssistant\(text: text\) \{ \[weak self\] in\s*if self\?\.assistantPrompt == text \{ self\?\.assistantPrompt = "" \}/);
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /note: model\.assistantPlacementNote, hint: model\.assistantPrimaryHint,\s*canSend: model\.assistantCanSend/);
  assert.match(view, /if let note \{\s*GlobalDMNoticeRow\(icon: "wifi\.slash", text: note/);
  assert.match(read('DM/GlobalDMStore.swift'), /if self\.draft\(for: target\) == text \{ self\.setDraft\("", for: target\) \}/);
});

test('default model skips disabled engines on the device that runs the assistant', () => {
  const routing = read('Assistant/AssistantPrimaryRouting.swift');
  const pick = slice(routing, 'static func pick(', '\n    }\n');
  assert.match(pick, /\[stored, lead, coder\]/);
  assert.match(pick, /\(preferred \+ ChatRouteChoice\.all\)\.first/);
  assert.match(pick, /engineKind\(for: route\)\.map \{ !isDisabled\(\$0\) \} \?\? false/);
  const model = read('Facade/ChatPageModel.swift');
  const local = slice(model, 'private var assistantLocalRoute: ChatRouteChoice? {', '\n    }\n');
  assert.match(local, /stored: localLive\?\.threadRecord\(assistantThreadID\)\?\.requestedModel/);
  assert.match(local, /lead: UltraworkRoleConfigurationStore\(\)\.load\(\)\.primaryModelID/);
  assert.match(local, /coder: selectedModel, isDisabled: \{ self\.isEngineDisabled\(\$0\) \}/);
  // A disabled engine cannot be picked locally; on the primary the model is handed over without local judgement.
  const setModel = slice(model, 'func setAssistantModel(_ modelID: String)', 'func sendToAssistant');
  assert.match(setModel, /let kind = AssistantModelRouting\.engineKind\(for: route\), !isEngineDisabled\(kind\)/);
  assert.match(setModel, /assistantPrimaryModelChoice = route\.id/);
  // The secondary only sends an explicit route (with its engine); nothing picked → the primary decides.
  const turn = slice(routing, 'static func primaryTurn(', '\n    }\n');
  assert.match(turn, /guard let route = choice, let kind = engineKind\(for: route\) else \{ return \(nil, nil\) \}/);
  assert.doesNotMatch(turn, /storedRoute/);
  // The primary runs its own assistant order for turns handed over by a secondary, skipping its disabled engines.
  const receive = slice(model, 'func receiveAssistantTurnFromSecondary(', '\n    }\n');
  assert.match(receive, /guard !isEngineDisabled\(kind\) else \{ return "assistant_engine_disabled" \}/);
  assert.match(receive, /guard assistantLocalRoute != nil else \{ return "assistant_engines_disabled" \}/);
  assert.match(receive, /return sendToLocalAssistant\(text: text\) \? nil : "assistant_not_sent"/);
  const bridge = read('Facade/OSAgentBridge.swift');
  const sendMessage = slice(bridge, 'case "send_message", "send_message_with_options":', 'case "new_thread":');
  assert.match(sendMessage, /Self\.routesToAssistant\(isAssistantThread: live\.doc\.isAssistantThread\(threadID\)/);
  assert.match(sendMessage, /model\.receiveAssistantTurnFromSecondary\(threadID: threadID, text: text,\s*routeID: assistantRoute\)/);
  assert.match(sendMessage, /throw BridgeError\.assistantTurnRejected\(problem\)/);
  assert.match(sendMessage, /Self\.sendMessageEngine\(modelArgument: modelArgument, requested: requestedEngine,/);
  const engineRule = slice(bridge, 'static func sendMessageEngine(', '\n    }\n');
  assert.match(engineRule, /return requested\.flatMap\(ClaudeSidecar\.Kind\.init\(rawValue:\)\)\s*\?\? threadEngine\.flatMap/);
});

test('DM Coder sessions include the primary (and every paired device) sessions with the device name, sent through that device', () => {
  const model = read('Facade/ChatPageModel.swift');
  const list = slice(model, 'func dmSessionCandidates(limit: Int? = nil)', 'func sendFromDM');
  // W180 D2：主設備在最前面，其他配對設備照配對清單；連得到的才列（同一條連線，不另外連）。
  assert.match(list, /for device in dmRemoteDevices \{\s*guard let engine = device\.engine else \{ continue \}/);
  assert.match(list, /Self\.dmCandidates\(in: engine\.doc, deviceName: device\.device\.displayName\)/);
  assert.match(list, /result\.append\(GlobalDMRemoteDevice\(device: primary, engine: assistantPrimaryEngine,\s*connecting: assistantPrimaryConnecting, isPrimary: true\)\)/);
  // Disambiguate the whole list first, then cut the recent few, so the list and the header agree.
  assert.match(list, /let named = GlobalDMSessionCandidate\.disambiguated\(rows, now: Date\(\)\)\s*return limit\.map \{ Array\(named\.prefix\(\$0\)\) \} \?\? named/);
  const send = slice(model, 'func sendFromDM(threadID: UUID, text: String', 'var localLiveForBridge');
  assert.match(send, /if localLive\?\.threadRecord\(threadID\) == nil, let remote = dmRemote\(for: threadID\), let engine = remote\.engine \{\s*guard attachments\.isEmpty else \{ return false \}\s*return sendFromDMToRemote\(engine, device: remote, threadID: threadID, text: text, onDelivered: onDelivered\)/);
  const remote = slice(model, 'private func sendFromDMToRemote(', '\n    }\n');
  assert.match(remote, /!record\.isArchived, record\.deviceID == nil/);
  assert.match(remote, /!remote\.doc\.isAssistantThread\(threadID\)/);
  assert.match(remote, /Self\.dmCoderOnlyCommand\(in: text\) == nil/);
  // W180 A4：這次在私訊框選的模型 → 那條記住的（照 F 房 primaryTurn）。
  assert.match(remote, /let choice = ChatModelPreferences\.selection\(record, overrideRouteID: dmRemoteModelChoices\[threadID\], deviceID: device\.device\.id\)\.route/);
  assert.match(read('Chat/ChatModelPreferences.swift'), /ChatRouteChoice\.resolve\(overrideRouteID \?\? thread\?\.requestedModel \?\? thread\?\.model \?\? "gpt-6\.1-sol", deviceID: deviceID\)/);
  assert.match(remote, /AssistantModelRouting\.primaryTurn\(choice: choice\)/);
  assert.match(remote, /deliverToPrimary\(remote, device: device\.device, threadID: threadID, text: text, model: turn\.model, engine: turn\.kind,\s*assistantRoute: nil, onPrimary: device\.isPrimary\)/);
  assert.doesNotMatch(remote, /isEngineDisabled|EngineDisableStore|selectedThreadID|selectedRemote|\bprompt\b|\.select\(/);
  assert.match(model, /func dmTranscript\(for threadID: UUID\) -> \[ChatMessage\]/);
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /var displayLabel: String \{ disambiguator\.map \{ "\\\(baseLabel\) · \\\(\$0\)" \} \?\? baseLabel \}/);
  assert.match(store, /deviceName\.map \{ "\\\(\$0\) · \\\(label\)" \} \?\? label/);
  assert.match(store, /formatter\.locale = Locale\(identifier: "zh_Hant_TW"\)/);
  assert.match(store, /case \.thread\(let id\): return model\?\.dmSessionIsRunning\(id\) \?\? false/);
  assert.match(store, /model\?\.stopDMSession\(id\)/);
  assert.match(store, /return knownSessions\[id\]\?\.displayLabel \?\? "Coder 對話"/);
  // A primary session stays the DM target while the primary is connecting or offline; the pane explains and blocks send.
  assert.match(store, /!model\.dmSessionAwaitingRemote\(id\) \{\s*select\(\.assistant\)/);
  assert.match(model, /guard localLive\?\.threadRecord\(threadID\) == nil, dmRemote\(for: threadID\) == nil else \{ return false \}\s*return dmAwaitedDevice\(threadID\) != nil/);
  // Same title and same relative time still get distinct labels (date-time, then a number).
  assert.match(store, /if Set\(tags\)\.count < tags\.count \{ tags = indices\.map \{ absoluteTime\(rows\[\$0\]\.activity\) \} \}/);
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /bubbles: GlobalDMBubble\.rows\(model\.dmTranscript\(for: id\),\s*running: model\.dmSessionIsRunning\(id\)\)/);
  assert.match(view, /note: model\.dmSessionNote\(id\), hint: model\.dmSessionHint\(id\),\s*canSend: model\.dmSessionCanSend\(id\)/);
  // W180 D2：最近清單與搜尋共用同一種 session 列（最上層寫「設備 · 專案 › 標題」，子討論串縮排）。
  assert.match(view, /title: item\.depth > 0 \? "↳ " \+ session\.shortLabel : session\.displayLabel/);
  assert.equal((view.match(/ForEach\((rows|results)\) \{ sessionRow\(\$0\) \}/g) ?? []).length, 2, 'recent list and search both show the device name');
});

test('DM messages: Markdown like Coder, attachment paths never shown', () => {
  const text = read('DM/GlobalDMMessageText.swift');
  assert.match(text, /<\(image\|video\|file\)\\b\[\^>\]\*>/);
  for (const word of ['"圖片"', '"影片"', '"檔案"']) assert.ok(text.includes(word), word);
  // Attachments show their type and file name only: the path is reduced to its last component.
  assert.ok(text.includes('return "[\\(label)：\\(String(safe.prefix(160)))]"'));
  assert.match(text, /\.lastPathComponent/);
  assert.match(text, /ChatAssistantTranscriptBlockView\(\s*document: TatwoAssistantTranscriptPresentation\.document\(markdown: text\)/);
  assert.match(text, /AttributedString\(markdown: text,\s*options: \.init\(interpretedSyntax: \.inlineOnlyPreservingWhitespace\)\)/);
  const view = read('DM/GlobalDMView.swift');
  const rows = slice(view, 'static func rows(_ messages: [ChatMessage], running: Bool = false)', 'static func rows(_ messages: [TapMessage]');
  assert.equal((rows.match(/GlobalDMMessageText\.displayText\(message\.text\)/g) ?? []).length, 2);
  assert.match(view, /GlobalDMRichText\(text: bubble\.text\)/);
  assert.doesNotMatch(view, /\.blue\b|accentColor|borderedProminent|\.tint\(/);
});

test('assistant model menu is the Coder glass chip with friendly names and disabled engines marked', () => {
  const pane = read('Assistant/AssistantSpacePane.swift');
  // W184 H4b：助理頁的模型 chip 收進「模式選擇」chip（同 Coder、私訊框；記憶也在同一顆）。守的東西不變：模型清單與選擇還是助理自己的
  // （assistantModelOptions：友善名稱、本機跑時停用的引擎標「已停用」不能選；setAssistantModel：只改助理那一條）、回覆中不能換、
  // 模型那一段仍是 tatwo-assistant-model、無障礙名稱「助理的模型：…」、滑過寫「助理的模型，不更動 Coder」。
  assert.match(pane, /AssistantSpaceModeChip\(model: model, isOpen: modeOpen\)/);
  const assistantMode = slice(read('Chat/TatwoComposerMode.swift'), 'static func assistantSpace(model: ChatPageModel)', 'fileprivate static func applyPreferenceSteps(');
  for (const piece of ['assistantOptions(model.assistantModelOptions)', 'choose: { [weak model] id in model?.setAssistantModel(id) }',
    'let canChoose = !model.assistantIsRunning', 'identifier: "tatwo-assistant-model"', 'label: "助理的模型"',
    'mode.help = canChoose ? "助理的模型，不更動 Coder" : "回覆中不換模型"']) {
    assert.ok(assistantMode.includes(piece), piece);
  }
  assert.match(read('Chat/TatwoComposerMode.swift'), /accessibilityLabel: "\\\(label\)：\\\(accessibilityTitle\)"/);
  assert.doesNotMatch(pane, /ForEach\(ChatRouteChoice\.all\)|route\.title|assistantRouteChoice\.title/);
  const menu = read('Assistant/AssistantModelMenu.swift');
  // W179 UI：觸發鈕是 Coder 那顆模型 chip（Button＋ChatComposerModelLabel），點了跳系統選單；不用系統白框下拉。
  assert.match(menu, /ChatComposerModelLabel\(title: title, suffix: nil, compact: false, selected: false\)/);
  assert.doesNotMatch(menu, /\.menuStyle\(/);
  assert.match(menu, /item\.isEnabled = !option\.isDisabled/);
  assert.match(menu, /\.accessibilityLabel\("助理的模型：\\\(title\)"\)/);
  assert.doesNotMatch(menu, /\.blue\b|accentColor|borderedProminent/);
  const routing = read('Assistant/AssistantPrimaryRouting.swift');
  assert.match(routing, /title: disabled \? "\\\(name\) · 已停用" : name/);
  assert.match(routing, /static func friendlyName\(_ route: ChatRouteChoice\) -> String/);
  const model = read('Facade/ChatPageModel.swift');
  const options = slice(model, 'var assistantModelOptions: [AssistantModelOption] {', '\n    }\n');
  assert.match(options, /let checksLocal = !placement\.isPrimary/);
});

test('icon and glass-chip buttons in 設定 › OS › 記憶, 開始使用 and the DM have accessibility names', () => {
  const page = read('New/OSSettingsPage.swift');
  const memory = slice(page, '@ViewBuilder private var memorySection', 'private var memoryConfirmMessage');
  assert.match(memory, /\.accessibilityLabel\(memory\.pending\.count > 1/);
  const row = slice(page, 'private func memoryRow(', 'private func color(');
  assert.equal((row.match(/\.accessibilityLabel\(/g) ?? []).length, 2);
  const guide = read('Shell/SetupGuide.swift');
  assert.match(guide, /if item\.id == "backup" \{ EnvironmentLoginTarget\.backup\.open\(\) \} else \{ open\(item\.section\) \}/);
  assert.match(guide, /\.accessibilityIdentifier\("setup-open-" \+ item\.id\)\s*\.accessibilityLabel\(\(item\.state == \.done \? "查看：" : "去設定："\) \+ item\.title\)/);
  assert.match(read('DM/GlobalDMView.swift'), /\.help\("回對象清單"\)\s*\.accessibilityLabel\("回對象清單"\)/);
  assert.match(read('DM/GlobalDMDeskViews.swift'), /OSChipButton\(title: title, action: action\)\s*\.accessibilityLabel\(title\)\s*\.accessibilityIdentifier\("tatwo\.dm\.keys\./);
});

test('engine-disable settings are never written by W179 F code', () => {
  const dirs = ['Assistant', 'DM'];
  for (const dir of dirs) {
    for (const file of readdirSync(new URL(`../App/Sources/Tatwo2/${dir}/`, import.meta.url))) {
      const source = read(`${dir}/${file}`);
      assert.doesNotMatch(source, /EngineDisableStore\.set|forKey: "tatwo2\.disabledEngines"\)\s*$|\.set\([^)]*disableKey/m, `${dir}/${file}`);
    }
  }
  const model = read('Facade/ChatPageModel.swift');
  for (const [start, end] of [['// MARK: - W179 F 助理住在主設備', 'func dmSessionCandidates'],
    ['private func sendFromDMToRemote(', 'var hasRunningWork']]) {
    assert.doesNotMatch(slice(model, start, end), /EngineDisableStore|disabledEngines\s*=/);
  }
});
