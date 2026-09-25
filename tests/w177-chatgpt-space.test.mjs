// W177 ChatGPT Space（TAP 第一座 Tap）。
// 靜態：四層邊界、Space 分頁接線、設定 › Plugin 的 TAP 分頁、不寫記錄。
// 動態：在 node:vm 裡跑真正的 Pod 腳本（ChatGPTTap.podScript），用假的 chatgpt.com 回應驗證
// 登入標頭不外洩、清單／對話／模型的轉換、送出時改模型、串流解析（v1 delta 與舊格式）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = 'App/Sources/Tatwo2/';
const tapSwift = read(app + 'TAP/ChatGPTTap.swift');
const podScript = (() => {
  const start = tapSwift.indexOf('static let podScript = #"""');
  const end = tapSwift.indexOf('"""#', start);
  assert.ok(start > 0 && end > start, 'podScript literal');
  return tapSwift.slice(tapSwift.indexOf('\n', start) + 1, end);
})();

test('four layers: OS core and browser core know nothing about ChatGPT', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const header = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h');
  assert.doesNotMatch(bridge, /chatgpt/i);
  assert.doesNotMatch(header, /chatgpt/i);
  // Pod 腳本只給建立時帶腳本的瀏覽器、只在主框架、只經 tatwo.tap.event 回來。
  assert.match(bridge, /kTapPodEventMessage = "tatwo\.tap\.event"/);
  assert.match(bridge, /if \(frame->IsMain\(\)\) \{\s*const auto pod = pod_scripts_\.find/);
  assert.match(bridge, /state->close_requested \|\| state->pod_script\.empty\(\)\) return true;/);
  assert.match(bridge, /browser_settings, pod_info, state->request_context\)/);
  assert.match(bridge, /creation_attempted \|\| state->close_requested \|\| script\.length == 0\) return NO;/);
  assert.match(header, /configurePod\(script:\)/);
  assert.match(header, /runPodCommand\(_:\)/);
  for (const file of ['TAP/TAP.swift', 'TAP/TapWebPod.swift']) {
    const source = read(app + file);
    assert.doesNotMatch(source, /chatgpt\.com|backend-api|prompt-textarea/, file);
  }
  // Pod 用自己的登入空間，不跟 OS 瀏覽器搶設定檔。
  assert.match(tapSwift, /UUID\(uuidString: "00000000-0000-0000-0000-000000000177"\)/);
});

test('Space gets a ChatGPT tab wired like Browser, with its own sidebar and no Coder composer', () => {
  const mode = read(app + 'Chat/ChatPageConstants.swift');
  assert.match(mode, /case chat, cli, bot, browser/);
  assert.match(mode, /static let allCases: \[Self\] = \[\.chat, \.cli, \.bot, \.browser, \.chatgpt\]/);
  assert.match(mode, /case \.chatgpt: "ChatGPT"/);
  assert.match(mode, /case "ChatGPT": self = \.chatgpt/);
  const doc = read(app + 'Space/SpaceWorkspaceDocument.swift');
  assert.match(doc, /static let chatgpt = Self\(rawValue: "chatgpt"\)!/);
  assert.match(doc, /case \.chatgpt: "ChatGPT"/);
  assert.match(read(app + 'Space/SpaceSetupPreviewState.swift'), /static let chatgpt = Self\(rawValue: "ChatGPT"\)!/);
  const panels = read(app + 'Chat/ChatPage+Panels.swift');
  assert.match(panels, /else if model\.mode == \.chatgpt \{[\s\S]*?ChatGPTSpaceMainPane\(model: ChatGPTSpaceModel\.shared[,)]/);
  assert.match(panels, /model\.mode != \.browser, model\.mode != \.chatgpt \{\s*composer/);
  const sidebar = read(app + 'Chat/ChatPage+Sidebar.swift');
  assert.match(sidebar, /case \.chatgpt:\s*chatGPTSidebar/);
  const own = sidebar.slice(sidebar.indexOf('var chatGPTSidebar:'), sidebar.indexOf('var workspaceSidebarFooter:'));
  for (const token of ['WorkspaceSidebarShell', 'workspaceModeSection', 'ChatGPTSpaceSidebarList', 'workspaceSidebarFooter']) {
    assert.ok(own.includes(token), token);
  }
  // Coder 的資訊卡／瀏覽器／工具箱不掛在 ChatGPT Space。
  assert.match(read(app + 'Chat/ChatPage.swift'), /if !isPanel && model\.mode != \.browser && model\.mode != \.chatgpt \{\s*rightPanelControlStrip/);
  // 分頁列一列五格放不下「ChatGPT」時換短名，不截字。
  const picker = read(app + 'Shell/WorkspaceSidebarModePicker.swift');
  assert.match(picker, /ViewThatFits\(in: \.horizontal\)/);
  assert.match(picker, /mode == \.chatgpt \? "GPT" : nil/);
  // 分頁關掉時 Pod 休眠。
  assert.match(read(app + 'Space/SpaceWorkspaceController.swift'), /if !spaces\.allows\(\.chatgpt\), ChatGPTTap\.shared\.pod\.isRunning \{\s*ChatGPTTap\.shared\.sleep\(\)/);
});

test('native screen reuses OS conversation components and never shows the ChatGPT web page inside the Space', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  for (const token of ['ChatAssistantTranscriptBlockView(', 'TatwoAssistantTranscriptPresentation.document(markdown:',
    'ChatComposerTextView(', 'ChatGPTSendButton(', 'liquidGlassPanelSurface', 'chatGlassChip()',
    '"新對話"', '"今天"', '"昨天"', '"前 7 天"', '"前 30 天"', '"更早"', '"釘選"', '"專案"', 'model.stop', '不耗 Codex 額度',
    'model.copy(', 'model.regenerate()', '"思考強度"', 'ChatGPTConversationRow', '"重新命名"', '"封存"', '"刪除"',
    'model.confirmDelete()', '無法復原']) {
    assert.ok(space.includes(token), token);
  }
  // 使用者 09-24：Space 裡不需要「打開網頁版」；09-25：「我沒有想要chatgpt space有任何chatgpt網頁版的窗口 我要就像os原生」
  // → 連登入也不在 Space 裡顯示網頁：原生卡片「前往登入」開到 設定 › Plugin › TAP。
  const pages = read(app + 'TAP/ChatGPTPages.swift');
  assert.doesNotMatch(space + pages, /help\("打開網頁版"\)|showsWebPage|webSheetPath|ChatGPTWebSheet|在網頁版瀏覽|在網頁版管理/);
  assert.match(space, /private var needsLogin: Bool \{ tap\.connection == \.needsLogin \}/);
  assert.match(space, /Button \{ model\.openTapSettings\(login: true\) \}/);
  assert.match(space, /NotificationCenter\.default\.post\(name: \.tatwoOpenSettingsSection, object: TatwoSettingsPage\.Section\.plugin\.rawValue\)/);
  // Pod 的網頁永遠在畫面外、點不到（TapPodHostView 在 Space 裡只出現這一次）。
  assert.equal((space.match(/TapPodHostView\(pod:/g) || []).length, 1);
  assert.match(space, /TapPodHostView\(pod: tap\.pod\)\s*\.frame\(width: 1100, height: 800\)\s*\.offset\(x: -20_000\)\s*\.allowsHitTesting\(false\)/);
  assert.equal((pages.match(/TapPodHostView\(/g) || []).length, 0);
  // 模型選單在輸入框裡（composer 區塊內），不在標題列。
  const composer = space.slice(space.indexOf('private var composer: some View'), space.indexOf('private var modelPicker: some View'));
  assert.match(composer, /modelPicker/);
  const header = space.slice(space.indexOf('struct ChatGPTTopBarControls: View'), space.indexOf('struct ChatGPTSpaceMainPane: View'));
  assert.doesNotMatch(header, /modelPicker|globe|打開網頁版/);
  // 標題列只有對話選項（⋯），跟網頁版一樣。
  assert.match(header, /Menu \{\s*ChatGPTConversationActions/);
  // 外層識別碼不能蓋掉子元件：先成為容器。
  assert.match(space, /\.accessibilityElement\(children: \.contain\)\s*\.accessibilityIdentifier\("chatgpt\.space"\)/);
  // Pod 放背景、平常在畫面外，不撐大版面；閒置 15 分鐘休眠。
  assert.match(space, /\.background\(alignment: \.topLeading\) \{\s*TapPodHostView\(pod: tap\.pod\)/);
  assert.match(space, /\.offset\(x: -20_000\)/);
  assert.match(space, /idleSleepDelay: Duration = \.seconds\(15 \* 60\)/);
  // 模型選單照標籤原樣畫（borderlessButton 會把箭頭搬到前面、丟掉玻璃底）。
  const picker = space.slice(space.indexOf('Menu {'), space.indexOf('accessibilityIdentifier("chatgpt.modelPicker")'));
  assert.match(picker, /\.menuStyle\(\.button\)\s*\.buttonStyle\(\.plain\)/);
  assert.doesNotMatch(picker, /borderlessButton\)/);
});

test('Settings › Plugin lists Skillet, MCP, TAP, Pocket in that order with glass chips only', () => {
  const page = read(app + 'Pages/PluginsPage.swift');
  const order = ['.tag("skills")', '.tag("mcp")', '.tag("tap")', '.tag("pocket")'].map((t) => page.indexOf(t));
  assert.ok(order.every((i) => i > 0), 'all four tabs');
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.match(page, /else if selectedTab == "tap" \{\s*TapSettingsView\(\)/);
  const settings = read(app + 'TAP/TapSettingsView.swift');
  // 不要藍按鈕藍框：沒有 bordered 按鈕；開關跟其他設定頁一樣用品牌色。
  assert.doesNotMatch(settings, /borderedProminent|\.bordered\b/);
  const tints = [...settings.matchAll(/\.tint\(([^)]*)\)/g)].map((m) => m[1]);
  assert.ok(tints.length >= 1 && tints.every((x) => x === 'LiquidGlassTokens.brandAccent'), tints.join(','));   // 啟用、通知兩個開關都用品牌色
  // 為了登入打開的網頁版，登入完成就自動關掉（使用者 09-24）。
  assert.match(settings, /if showsWebPage, openedForLogin, connection == \.ready \{ showsWebPage = false \}/);
  assert.match(settings, /chip\("登入"[^}]*openWebPage\(forLogin: true\)/);
  assert.match(settings, /chip\("打開網頁版"[^}]*openWebPage\(forLogin: false\)/);
  for (const token of ['已連上', '需要登入', '休眠中', '出錯', '記憶體', '打開網頁版', '登入', '啟用']) assert.ok(settings.includes(token), token);
});

test('TAP code never logs or writes conversation content or tokens', () => {
  for (const file of ['TAP/TAP.swift', 'TAP/TapWebPod.swift', 'TAP/ChatGPTTap.swift', 'TAP/ChatGPTSpace.swift', 'TAP/ChatGPTPages.swift', 'TAP/TapSettingsView.swift']) {
    let source = read(app + file);
    if (file === 'TAP/ChatGPTSpace.swift') {
      // 使用者 09-25「2全要」：圖庫要能下載。唯一的寫檔：存到使用者自己在存檔視窗選的位置。
      const download = source.slice(source.indexOf('func downloadLibraryItem('), source.indexOf('func confirmDeleteLibraryItem('));
      assert.match(download, /NSSavePanel\(\)[\s\S]*panel\.runModal\(\) == \.OK, let url = panel\.url[\s\S]*try data\.write\(to: url, options: \.atomic\)/);
      source = source.replace(download, '');
      // 09-25 #126：圖片預覽照 Coder 的，也能下載；一樣只存到使用者在存檔視窗選的位置、存原檔。
      const zoomDownload = source.slice(source.indexOf('func downloadZoomedImage('), source.indexOf('static func imageExtension('));
      assert.match(zoomDownload, /case \.library\(let item\):\s*downloadLibraryItem\(item\)[\s\S]*NSSavePanel\(\)[\s\S]*panel\.runModal\(\) == \.OK, let url = panel\.url[\s\S]*try data\.write\(to: url, options: \.atomic\)/);
      source = source.replace(zoomDownload, '');
      // 拖進來的「照片」App 檔案：收到系統暫存資料夾，讀進記憶體後整個刪掉。
      assert.match(source, /receivePromisedFiles\(atDestination: directory[\s\S]*try\? FileManager\.default\.removeItem\(at: directory\)/);
    }
    assert.doesNotMatch(source, /\bNSLog\(|\bprint\(|os_log|Logger\(|FileHandle|\.write\(to:|createFile|appendingPathComponent/, file);
  }
  assert.doesNotMatch(podScript, /console\.|localStorage|sessionStorage|indexedDB|sendBeacon|XMLHttpRequest/);
});

// ---- Pod 腳本實跑 ----

const sseBody = (events) => new ReadableStream({
  start(controller) {
    const encoder = new TextEncoder();
    for (const event of events) controller.enqueue(encoder.encode(event));
    controller.close();
  },
});

function makePod({ responses, onSendClick, setup, sendPath = '/backend-api/f/conversation' }) {
  const reports = [];
  const requests = [];
  const inserted = [];
  const state = { sendClicked: 0, pathname: '/', assistantNodes: [], stop: false };
  const pageFetchBody = JSON.stringify({ action: 'next', model: 'auto', messages: [] });
  const sandbox = {
    Headers, Request, Response, ReadableStream, TextEncoder, TextDecoder, Promise, JSON, Date, Object, Set, Error, String, Array, URL, URLSearchParams,
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); if (ms >= 5000) t.unref(); return t; },
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); if (ms >= 1000) t.unref(); return t; }, clearInterval,
    location: { host: 'chatgpt.com', get pathname() { return state.pathname; } },
    history: { pushState(_s, _t, path) { state.pathname = path; } },
    PopStateEvent: class { constructor(type) { this.type = type; } },
    dispatchEvent: () => true,
  };
  const composer = { focus() {} };
  const sendButton = {
    disabled: false,
    click() {
      state.sendClicked += 1;
      // 網頁自己送出：跟 chatgpt.com 一樣走 window.fetch（此時已被 Pod 腳本包住）。
      sandbox.window.fetch('https://chatgpt.com' + sendPath, {
        method: 'POST', headers: { authorization: 'Bearer SECRET-TOKEN' }, body: pageFetchBody,
      }).then((response) => response.text());
      if (onSendClick) onSendClick(state);
    },
  };
  sandbox.document = {
    readyState: 'complete',
    addEventListener() {},
    execCommand(command, _ui, value) {
      if (command !== 'insertText') return true;
      inserted.push(value);
      // 跟真網頁一樣：打字時網頁先 POST f/conversation/prepare 拿 conduit token。
      sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation/prepare', {
        method: 'POST', headers: { authorization: 'Bearer SECRET-TOKEN' }, body: JSON.stringify({ model: 'auto', fork_from_shared_post: false }),
      });
      sandbox.window.fetch('https://chatgpt.com/backend-api/sentinel/chat-requirements/prepare', {
        method: 'POST', body: JSON.stringify({ p: 'opaque' }),
      });
      return true;
    },
    querySelector(selector) {
      if (selector === '#prompt-textarea') return composer;
      if (selector === '[data-testid="send-button"]') return sendButton;
      if (selector === '[data-testid="stop-button"]') return state.stop ? { click() { state.stop = false; } } : null;
      if (selector === '[data-message-author-role]') return {};
      return null;
    },
    querySelectorAll(selector) {
      return selector === '[data-message-author-role="assistant"]' ? state.assistantNodes : [];
    },
  };
  sandbox.window = sandbox;
  sandbox.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    requests.push({ url, init });
    const path = new URL(url, 'https://chatgpt.com').pathname;
    const reply = responses[path];
    if (typeof reply === 'function') return reply(url, init);
    if (!reply) return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
    if (reply.sse) return new Response(sseBody(reply.sse), { status: 200, headers: { 'content-type': 'text/event-stream' } });
    return new Response(JSON.stringify(reply.json), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  if (setup) setup(sandbox);
  const context = vm.createContext(sandbox);
  const factory = vm.runInContext(podScript, context);
  const started = factory((json) => reports.push(JSON.parse(json)));
  const pod = {
    reports, requests, inserted, state, started, sandbox,
    command: (payload) => sandbox.__tatwoPod.command(payload),
    waitFor: async (predicate, ms = 3000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const hit = reports.find(predicate);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 10));
      }
      assert.fail('timed out; reports=' + JSON.stringify(reports.map((r) => r.type + ':' + (r.kind || ''))));
    },
    // 網頁自己打一次帶登入標頭的 API，Pod 才拿得到標頭。
    signIn: () => sandbox.window.fetch('https://chatgpt.com/backend-api/me', {
      headers: { authorization: 'Bearer SECRET-TOKEN', 'oai-device-id': 'device-1', 'x-other': 'drop-me' },
    }),
  };
  return pod;
}

const noLeak = (pod) => {
  const text = JSON.stringify(pod.reports);
  assert.doesNotMatch(text, /SECRET-TOKEN|Bearer|device-1/);
};

test('pod script: only on chatgpt.com, captures auth once, hello says logged in, never reports tokens', async () => {
  const pod = makePod({ responses: {} });
  assert.equal(pod.started, true);
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  const hello = await pod.waitFor((r) => r.type === 'hello');
  assert.equal(hello.loggedIn, true);
  assert.equal(pod.reports.filter((r) => r.type === 'auth').length, 1);
  noLeak(pod);
  // 別的網站（例如登入頁）不跑。
  const other = vm.createContext({ location: { host: 'auth.openai.com' }, window: {} });
  assert.equal(vm.runInContext(podScript, other)(() => {}), false);
  // 頁面拿不到、也改不了 Pod 的入口。
  assert.throws(() => { 'use strict'; pod.sandbox.__tatwoPod = null; });
  assert.equal(typeof pod.sandbox.__tatwoPod.command, 'function');
});

test('pod script: list, get and models go through the page\'s own headers and return only what the App needs', async () => {
  const pod = makePod({ responses: {
    '/backend-api/conversations': { json: { total: 3, items: [
      { id: 'c1', title: '第一則', update_time: '2026-09-24T01:02:03.456Z', snippet: 'private' },
      { id: 'c2', title: '', update_time: 1790000000.5 },
    ] } },
    '/backend-api/conversation/c1': { json: { current_node: 'n4', mapping: {
      n0: { message: null, parent: null },
      n1: { message: { id: 'm1', author: { role: 'system' }, content: { content_type: 'text', parts: ['sys'] } }, parent: 'n0' },
      n2: { message: { id: 'm2', author: { role: 'user' }, content: { content_type: 'text', parts: ['哈囉'] } }, parent: 'n1' },
      n3: { message: { id: 'm3', author: { role: 'assistant' }, metadata: { is_visually_hidden_from_conversation: true }, content: { content_type: 'text', parts: ['hidden'] } }, parent: 'n2' },
      n4: { message: { id: 'm4', author: { role: 'assistant' }, metadata: { model_slug: 'sol-a' }, content: { content_type: 'text', parts: ['**你好**', '第二段'] } }, parent: 'n3' },
    } } },
    '/backend-api/models': { json: { default_model_slug: 'sol-b', categories: [{ default_model: 'luna-c' }, 'junk'], models: [
      { slug: 'auto', title: 'Auto', description: '自動', tags: ['x'] },
      { slug: 'sol-a', title: 'GPT-X Sol', description: 'a' },
      { slug: 'gpt-x-thinking', title: 'GPT-X Thinking', description: '想比較久',
        thinking_efforts: [{ thinking_effort: 'standard', short_label: '標準' }, { thinking_effort: 'extended', short_label: '延伸' }, 'max'] },
      { slug: 'sol-b', title: 'GPT-X Sol', description: 'b' },
      { slug: 'luna-a', title: 'GPT-X Luna', description: 'la' },
      { slug: 'luna-c', title: 'GPT-X Luna', description: 'lc' },
      { slug: 'sol-c', title: 'GPT-X Sol', description: 'c' },
      { title: 'no slug' },
    ] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');

  pod.command({ cmd: 'list', id: 'L', offset: 0, limit: 2 });
  const list = await pod.waitFor((r) => r.type === 'result' && r.id === 'L');
  assert.equal(list.ok, true);
  assert.deepEqual(list.data, { total: 3, items: [
    { id: 'c1', title: '第一則', update_time: '2026-09-24T01:02:03.456Z' },
    { id: 'c2', title: '', update_time: 1790000000.5 },
  ] });
  const listRequest = pod.requests.find((r) => r.url.includes('/backend-api/conversations'));
  assert.match(listRequest.url, /offset=0&limit=2&order=updated/);
  assert.equal(listRequest.init.headers.authorization, 'Bearer SECRET-TOKEN');
  assert.equal(listRequest.init.headers['oai-device-id'], 'device-1');
  assert.equal(listRequest.init.headers['x-other'], undefined);

  pod.command({ cmd: 'get', id: 'G', conversationID: 'c1' });
  const get = await pod.waitFor((r) => r.type === 'result' && r.id === 'G');
  assert.deepEqual(get.data.messages, [
    { id: 'm2', role: 'user', text: '哈囉' },
    // 同名的版本（sol-a／b／c 都叫 GPT-X Sol）加上檔位名，才分得出是哪個回答的。
    { id: 'm4', role: 'assistant', text: '**你好**\n\n第二段', model: 'GPT-X Sol Instant' },
  ]);

  pod.command({ cmd: 'models', id: 'M' });
  const models = await pod.waitFor((r) => r.type === 'result' && r.id === 'M');
  // 同名只留一個：預設（sol-b）與分組指定（luna-c）優先，順序照第一次出現。
  // 同名只留一個（預設與分組指定優先）；強度選項＝「代號|強度」；只有一個選項時不列強度。
  assert.deepEqual(models.data, { default: 'sol-b', models: [
    { slug: 'auto', title: 'Auto', description: '自動', efforts: [] },
    { slug: 'sol-b', title: 'GPT-X Sol', description: 'b', efforts: [] },
    { slug: 'gpt-x-thinking', title: 'GPT-X Thinking', description: '想比較久',
      efforts: [{ id: 'gpt-x-thinking|standard', title: '標準' }, { id: 'gpt-x-thinking|extended', title: '延伸' }, { id: 'gpt-x-thinking|max', title: 'max' }] },
    { slug: 'luna-c', title: 'GPT-X Luna', description: 'lc', efforts: [] },
  ], versions: [], current: null });
  pod.command({ cmd: 'diagnostics', id: 'D' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'D');
  assert.match(diag.data['模型欄位'], /description\+slug\+tags\+thinking_efforts\+title/);
  assert.equal(diag.data['推理強度來源'], 'thinking_efforts（short_label+thinking_effort）');
  assert.match(diag.data['模型表'], /gpt-x-thinking\|GPT-X Thinking\|-\|-\|-\|standard=標準\/-,extended=延伸\/-,max/);

  pod.command({ cmd: 'nope', id: 'N' });
  const unknown = await pod.waitFor((r) => r.type === 'result' && r.id === 'N');
  assert.equal(unknown.ok, false);
  noLeak(pod);
});

test('pod script: send types into the page, swaps the model and streams v1 deltas', async () => {
  const sse = [
    'event: delta_encoding\ndata: "v1"\n\n',
    'data: {"type": "resume_conversation_token", "token": "opaque"}\n\n',
    'event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "u1", "author": {"role": "user"}, "content": {"content_type": "text", "parts": ["嗨"]}, "status": "finished_successfully"}, "conversation_id": "c9"}, "c": 0}\n\n',
    'event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "a1", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": [""]}, "status": "in_progress"}, "conversation_id": "c9"}, "c": 1}\n\n',
    'event: delta\ndata: {"p": "/message/content/parts/0", "o": "append", "v": "你"}\n\n',
    'event: delta\ndata: {"v": "好"}\r\n\r\n',
    'event: delta\ndata: {"p": "", "o": "patch", "v": [{"p": "/message/content/parts/0", "o": "append", "v": "！"}, {"p": "/message/status", "o": "replace", "v": "finished_successfully"}]}\n\n',
    'data: {"type": "title_generation", "title": "打招呼", "conversation_id": "c9"}\n\n',
    'data: [DONE]\n\n',
  ];
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'S', text: '嗨', model: 'gpt-x-thinking' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'S' && r.kind === 'finished');
  assert.deepEqual(pod.inserted, ['嗨']);
  assert.equal(pod.state.sendClicked, 1);
  const post = pod.requests.find((r) => r.url.endsWith('/backend-api/f/conversation'));
  assert.equal(JSON.parse(post.init.body).model, 'gpt-x-thinking');
  // prepare 也要同一個模型，conduit token 才對得上；沒有 model 欄位的請求不動。
  const prepare = pod.requests.find((r) => r.url.endsWith('/backend-api/f/conversation/prepare'));
  assert.deepEqual(JSON.parse(prepare.init.body), { model: 'gpt-x-thinking', fork_from_shared_post: false });
  const sentinel = pod.requests.find((r) => r.url.includes('/sentinel/chat-requirements/prepare'));
  assert.equal(sentinel.init.body, JSON.stringify({ p: 'opaque' }));
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'S');
  assert.equal(events[0].kind, 'accepted');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === 'c9'));
  const texts = events.filter((e) => e.kind === 'text');
  assert.ok(texts.every((e) => e.messageID === 'a1'), 'only the assistant message streams');
  assert.equal(texts.at(-1).full, '你好！');
  assert.ok(events.some((e) => e.kind === 'title' && e.title === '打招呼' && e.conversationID === 'c9'));
  assert.equal(events.at(-1).kind, 'finished');
  assert.equal(events.at(-1).parsed, true);
  assert.match(events.at(-1).shape, /^事件 9（JSON 8、其他 0）；event: delta_encoding×1, delta×5；type: resume_conversation_token×1, title_generation×1/);
  assert.match(events.at(-1).shape, /ct=text\/event-stream/);
  assert.doesNotMatch(events.at(-1).shape, /你|好|嗨|opaque|打招呼/, 'shape has no content');
  noLeak(pod);
});

test('pod script: legacy full-message stream still shows the growing answer', async () => {
  const sse = [
    'data: {"message": {"id": "a2", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["舊"]}}, "conversation_id": "c8"}\n\n',
    'data: {"message": {"id": "a2", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["舊格式"]}}, "conversation_id": "c8"}\n\n',
    'data: [DONE]\n\n',
  ];
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'O', text: 'x' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'O' && r.kind === 'finished');
  const post = pod.requests.find((r) => r.url.endsWith('/backend-api/f/conversation'));
  assert.equal(JSON.parse(post.init.body).model, 'auto', 'no model chosen → page default kept');
  const prepare = pod.requests.find((r) => r.url.endsWith('/backend-api/f/conversation/prepare'));
  assert.equal(JSON.parse(prepare.init.body).model, 'auto');
  const texts = pod.reports.filter((r) => r.type === 'stream' && r.kind === 'text');
  assert.equal(texts.at(-1).full, '舊格式');
  noLeak(pod);
});

test('pod script: when the stream cannot be parsed, the answer comes from the page and the id from the URL', async () => {
  // 模擬 09-24 實機：串流內容看不懂（壓縮或新格式），回答只在網頁畫面上；網頁自己把網址換成 /c/<id>。
  const sse = ['data: KLUv/QBYnQAA\n\n', 'data: KLUv/QBYnQBB\n\n', 'data: [DONE]\n\n'];
  const id = '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b';
  const pod = makePod({
    responses: { '/backend-api/f/conversation': { sse } },
    onSendClick(state) {
      state.stop = true;
      const node = { innerText: '' };
      setTimeout(() => { state.assistantNodes = [node]; node.innerText = '台北'; }, 40);
      setTimeout(() => { node.innerText = '台北是台灣的首都。'; state.pathname = '/c/' + id; }, 200);
      setTimeout(() => { state.stop = false; }, 500);
    },
  });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'F', text: '介紹台北' });
  const finished = await pod.waitFor((r) => r.type === 'stream' && r.id === 'F' && r.kind === 'finished');
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'F');
  const texts = events.filter((e) => e.kind === 'text');
  assert.ok(texts.length >= 2, 'the growing page text is streamed');
  assert.ok(texts.every((e) => e.messageID === 'page'));
  assert.equal(texts.at(-1).full, '台北是台灣的首都。');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === id), 'id from the URL');
  assert.equal(finished.parsed, false);
  assert.match(finished.shape, /^事件 3（JSON 0、其他 2）/);
  // 停止鍵還在時不算完成。
  const finishedAt = pod.reports.indexOf(finished);
  assert.ok(pod.reports.slice(0, finishedAt).some((r) => r.kind === 'text' && r.full === '台北是台灣的首都。'));
  noLeak(pod);
});

test('pod script: image replies come back as images (pointer + size) on the answer, tool text stays out', async () => {
  const pod = makePod({ responses: {
    '/backend-api/conversation/img': { json: { current_node: 'n4', mapping: {
      n1: { message: { id: 'm1', author: { role: 'user' }, content: { content_type: 'text', parts: ['畫一張範例圖片'] } }, parent: null },
      n2: { message: { id: 'm2', author: { role: 'assistant' }, content: { content_type: 'code', text: '{"prompt":"x"}' } }, parent: 'n1' },
      n3: { message: { id: 'm3', author: { role: 'tool', name: 'image_gen' }, content: { content_type: 'multimodal_text',
        parts: [{ content_type: 'image_asset_pointer', asset_pointer: 'sediment://file_1', width: 1024, height: 1536 }, '內部說明'] } }, parent: 'n2' },
      n4: { message: { id: 'm4', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['完成了'] } }, parent: 'n3' },
    } } },
    '/backend-api/files/download/file_1': { json: { status: 'success', download_url: '/backend-api/estuary/content?id=file_1&sig=abc' } },
    '/backend-api/estuary/content': { json: { fake: 'png-bytes' } },
  } });
  pod.sandbox.FileReader = class { readAsDataURL(blob) { blob.text().then((t) => { this.result = 'data:image/png;base64,' + Buffer.from(t).toString('base64'); this.onload(); }); } };
  pod.sandbox.location.href = 'https://chatgpt.com/c/img';
  pod.sandbox.location.origin = 'https://chatgpt.com';
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'get', id: 'I', conversationID: 'img' });
  const got = await pod.waitFor((r) => r.type === 'result' && r.id === 'I');
  assert.deepEqual(got.data.messages, [
    { id: 'm1', role: 'user', text: '畫一張範例圖片' },
    { id: 'm3', role: 'assistant', text: '', images: [{ pointer: 'sediment://file_1', width: 1024, height: 1536 }] },
    { id: 'm4', role: 'assistant', text: '完成了' },
  ]);
  assert.doesNotMatch(JSON.stringify(got.data), /內部說明|prompt/);
  // 取圖：同網域下載網址在 Pod 裡抓（帶網頁登入），回傳 base64。
  pod.command({ cmd: 'image', id: 'G', pointer: 'sediment://file_1', conversationID: 'img' });
  const image = await pod.waitFor((r) => r.type === 'result' && r.id === 'G');
  assert.equal(image.ok, true);
  assert.equal(Buffer.from(image.data.base64, 'base64').toString(), JSON.stringify({ fake: 'png-bytes' }));
  const download = pod.requests.find((r) => r.url.includes('/files/download/file_1'));
  assert.match(download.url, /conversation_id=img/);
  noLeak(pod);
});

test('pod script: after a stream_handoff, a follow-up event stream from the page is parsed for the same turn', async () => {
  // 09-24 實機：送出的串流只有 resume_conversation_token＋stream_handoff；回答走另一條線。
  const cid = '11111111-2222-4333-8444-555555555555';
  const handoff = [
    'event: delta_encoding\ndata: "v1"\n\n',
    `data: {"type": "resume_conversation_token", "kind": "x", "token": "SECRET-RESUME", "conversation_id": "${cid}"}\n\n`,
    `data: {"type": "stream_handoff", "conversation_id": "${cid}", "turn_exchange_id": "t1", "options": {"transport": "sse", "resume_token": "SECRET-RESUME-LONG-VALUE-1234567890"}}\n\n`,
    'data: [DONE]\n\n',
  ];
  const resume = [
    `event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "a9", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": [""]}}, "conversation_id": "${cid}"}, "c": 1}\n\n`,
    'event: delta\ndata: {"p": "/message/content/parts/0", "o": "append", "v": "**交棒**"}\n\n',
    'event: delta\ndata: {"v": "之後"}\n\n',
    'data: [DONE]\n\n',
  ];
  const pod = makePod({
    responses: { '/backend-api/f/conversation': { sse: handoff }, '/backend-api/f/conversation/resume': { sse: resume } },
    onSendClick(state) {
      state.stop = true;
      setTimeout(() => { pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation/resume', { method: 'POST', body: '{}' }).then((r) => r.text()); }, 30);
      setTimeout(() => { state.stop = false; }, 400);
    },
  });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'H', text: 'x' });
  const finished = await pod.waitFor((r) => r.type === 'stream' && r.id === 'H' && r.kind === 'finished');
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'H');
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, '**交棒**之後', 'markdown kept from the resumed stream');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === cid));
  assert.equal(finished.parsed, true);
  assert.match(finished.shape, /交棒: transport=sse×1, resume_token=string×1/);
  assert.match(finished.shape, /連線: POST \/backend-api\/f\/conversation\/resume×1, SSE \/backend-api\/f\/conversation\/resume×1/);
  assert.doesNotMatch(JSON.stringify(pod.reports), /SECRET-RESUME/, 'handoff tokens never reported');
  noLeak(pod);
});


test('pod script: pins and projects come back as folders; project conversations are listed', async () => {
  const pod = makePod({ responses: {
    '/backend-api/pins': { json: [
      { gizmo: { gizmo: { id: 'g-p-aaa', display: { name: '範例專案一' } } } },
      { conversation: { id: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b', title: '釘選的對話' } },
      { gizmo: { gizmo: { id: 'g-xyz', display: { name: '某個 GPT' } } } },
      { weird: true },
    ] },
    '/backend-api/gizmos/snorlax/sidebar': { json: { cursor: null, items: [
      { gizmo: { gizmo: { id: 'g-p-bbb', display: { name: '範例專案二' } } }, conversations: { items: [] } },
      { gizmo: { id: 'g-p-ccc', name: '範例專案三' } },
    ] } },
    '/backend-api/gizmos/g-p-bbb/conversations': { json: { cursor: null, items: [
      { id: 'p1', title: '設計稿', update_time: 1790000000, snippet: 'private' },
    ] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'pins', id: 'P' });
  const pins = await pod.waitFor((r) => r.type === 'result' && r.id === 'P');
  assert.deepEqual(pins.data.items, [
    { id: 'g-p-aaa', title: '範例專案一', kind: 'project' },
    { id: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b', title: '釘選的對話', kind: 'conversation' },
    { id: 'g-xyz', title: '某個 GPT', kind: 'other' },
  ]);
  pod.command({ cmd: 'projects', id: 'J' });
  const projects = await pod.waitFor((r) => r.type === 'result' && r.id === 'J');
  assert.deepEqual(projects.data.items, [
    { id: 'g-p-bbb', title: '範例專案二', kind: 'project' },
    { id: 'g-p-ccc', title: '範例專案三', kind: 'project' },
  ]);
  pod.command({ cmd: 'projectConversations', id: 'C', projectID: 'g-p-bbb' });
  const inside = await pod.waitFor((r) => r.type === 'result' && r.id === 'C');
  assert.deepEqual(inside.data.items, [{ id: 'p1', title: '設計稿', update_time: 1790000000 }]);
  noLeak(pod);
});

test('pod script: a new chat switches the page to Chat (not Work) and the chosen effort is applied', async () => {
  const clicks = [];
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  const chat = { textContent: 'Chat', attrs: { 'aria-selected': 'false' }, getAttribute(k) { return this.attrs[k] ?? null; },
    click() { clicks.push('Chat'); this.attrs['aria-selected'] = 'true'; work.attrs['aria-selected'] = 'false'; } };
  const work = { textContent: 'Work', attrs: { 'aria-selected': 'true' }, getAttribute(k) { return this.attrs[k] ?? null; }, click() { clicks.push('Work'); } };
  const qsa = pod.sandbox.document.querySelectorAll;
  pod.sandbox.document.querySelectorAll = (selector) => (selector.startsWith('button, [role="tab"]') ? [work, chat] : qsa(selector));
  // 網頁的送出請求本身就帶推理強度欄位（例如使用者在網頁選過）。
  const originalFetch = pod.sandbox.fetch;
  pod.sandbox.fetch = (input, init = {}) => originalFetch(input, init);
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'E', text: 'x', effort: 'gpt-x|extended' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'E' && (r.kind === 'finished' || r.kind === 'failed'));
  assert.deepEqual(clicks, ['Chat']);
  pod.command({ cmd: 'diagnostics', id: 'D2' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'D2');
  assert.equal(diag.data['Chat 切換'], '已切到 Chat');
  assert.equal(diag.data['送出請求推理強度'], '已補上 thinking_effort');   // 審查 #7：網頁請求沒有強度欄位時補上
  const sent = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(sent.init.body).thinking_effort, 'extended');
  assert.match(diag.data['送出請求欄位'], /action\+messages\+model/);
  assert.match(diag.data['送出請求模型相關'], /model=auto/);
});


test('pod script: model variants merge into one effort slider, Work-only models are hidden, and the page choice is reported', async () => {
  const pod = makePod({ responses: {
    '/backend-api/models': { json: { default_model_slug: 'nova', models: [
      { slug: 'nova', title: 'GPT-X Nova', description: 'n', reasoning_type: 'none' },
      { slug: 'nova-thinking', title: 'GPT-X Nova', description: 'nt', reasoning_type: 'reasoning', configurable_thinking_effort: true,
        thinking_efforts: [{ thinking_effort: 'standard', short_label: 'Standard' }, { thinking_effort: 'max', short_label: 'Extra High' }] },
      { slug: 'astra', title: 'GPT-X Astra', description: 'a', is_work_mode_model: true },
      { slug: 'plain', title: 'GPT-X Plain', description: 'p', configurable_thinking_effort: false,
        thinking_efforts: [{ thinking_effort: 'max', short_label: 'Max' }] },
    ] } },
    '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
  } });
  // 網頁自己送出時帶的強度（使用者在網頁選過 Extra High）。
  pod.sandbox.document.querySelector = ((original) => (selector) => original(selector))(pod.sandbox.document.querySelector);
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'models', id: 'M' });
  const models = await pod.waitFor((r) => r.type === 'result' && r.id === 'M');
  assert.deepEqual(models.data.models.map((m) => [m.slug, m.title, m.efforts.map((e) => e.id + '=' + e.title).join(',')]), [
    ['nova', 'GPT-X Nova', 'nova=Instant,nova-thinking|standard=Standard,nova-thinking|max=Extra High'],
    ['plain', 'GPT-X Plain', ''],
  ]);
  // 選「Extra High」送出：模型換成 thinking 版、強度改成 max（網頁請求本來就有 thinking_effort 欄位）。
  // 網頁自己選的是 Thinking 版＋Standard（實機：gpt-5-6-thinking＋max）。
  const pageBody = JSON.stringify({ action: 'next', model: 'nova-thinking', thinking_effort: 'standard', messages: [] });
  pod.sandbox.document.querySelector = ((original) => (selector) => {
    if (selector === '[data-testid="send-button"]') return { disabled: false, click() {
      pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: pageBody }).then((r) => r.text());
    } };
    return original(selector);
  })(pod.sandbox.document.querySelector);
  pod.command({ cmd: 'send', id: 'X', text: 'x', model: 'nova', effort: 'nova-thinking|max' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'X' && (r.kind === 'finished' || r.kind === 'failed'));
  const post = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.deepEqual(JSON.parse(post.init.body), { action: 'next', model: 'nova-thinking', thinking_effort: 'max', messages: [] });
  // 網頁原本的選擇（nova-thinking + standard）回報給 App，對回選單上的「GPT-X Nova／Standard」。
  const selection = pod.reports.find((r) => r.type === 'selection');
  assert.deepEqual(selection, { type: 'selection', model: 'nova', effort: 'nova-thinking|standard', title: 'GPT-X Nova' });
});


test('pod script: regenerate goes through "Switch model" and presses "Try again" in its menu', async () => {
  const pressed = [];
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  const mk = (label, testid, onPress) => ({ label, testid, getAttribute(k) { return k === 'aria-label' ? label : k === 'data-testid' ? testid : null; },
    textContent: '', dispatchEvent(e) { pressed.push(label + ':' + e.type); if (e.type === 'pointerdown' && onPress) onPress(); return true; }, click() { pressed.push(label + ':click'); } });
  let menuOpen = false;
  const tryAgain = { textContent: 'Try again', getAttribute() { return null; }, dispatchEvent(e) { pressed.push('Try again:' + e.type); return true; },
    click() { pressed.push('Try again:click');
      pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: '{"action":"variant","model":"m"}' }).then((r) => r.text()); } };
  const turnButtons = [mk('Copy response', 'copy-turn-action-button'), mk('Share', null), mk('Switch model', null, () => { menuOpen = true; }), mk('More actions', null)];
  const scope = { parentElement: null, querySelectorAll: (sel) => (sel === 'button' ? turnButtons : []) };
  const answer = { innerText: '舊回答', parentElement: scope };
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => {
    if (sel === '[data-message-author-role="assistant"]') return [answer];
    if (sel.startsWith('[role="menuitem"]')) return menuOpen ? [tryAgain] : [];
    return qsa(sel);
  };
  // 網頁有 PointerEvent／MouseEvent（沙盒裡用最小替身）。
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.MouseEvent = class { constructor(type) { this.type = type; } };
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'regenerate', id: 'R', conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b' });
  const end = await pod.waitFor((r) => r.type === 'stream' && r.id === 'R' && (r.kind === 'finished' || r.kind === 'failed'), 5000);
  assert.equal(end.kind, 'finished');
  assert.deepEqual(pressed.filter((x) => x.startsWith('Switch model')), ['Switch model:pointerdown', 'Switch model:mousedown', 'Switch model:pointerup', 'Switch model:mouseup', 'Switch model:click']);
  assert.ok(pressed.includes('Try again:click'));
  pod.command({ cmd: 'diagnostics', id: 'DR' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'DR');
  assert.equal(diag.data['重新產生'], '找到：Switch model（經選單）');
  assert.equal(diag.data['回答下方按鈕'], 'Copy response copy-turn-action-button, Share, Switch model, More actions');
});


test('pod script: rename, archive and delete PATCH the conversation; search uses the server search', async () => {
  const pod = makePod({ responses: {
    '/backend-api/conversations/search': { json: { cursor: null, items: [
      { conversation_id: 'c-1', title: '台北夜市', update_time: 1790000000, payload: { snippet: 'private' } },
      { id: 'c-2', title: '舊的', create_time: 1780000000 },
    ] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  for (const [cmd, extra] of [['rename', { title: '  新標題  ' }], ['archive', {}], ['remove', {}]]) {
    pod.command(Object.assign({ cmd, id: cmd, conversationID: 'c-9' }, extra));
    const done = await pod.waitFor((r) => r.type === 'result' && r.id === cmd);
    assert.equal(done.ok, true, cmd);
  }
  const patches = pod.requests.filter((r) => r.init.method === 'PATCH');
  assert.deepEqual(patches.map((r) => [new URL(r.url, 'https://chatgpt.com').pathname, JSON.parse(r.init.body)]), [
    ['/backend-api/conversation/c-9', { title: '  新標題  ' }],
    ['/backend-api/conversation/c-9', { is_archived: true }],
    ['/backend-api/conversation/c-9', { is_visible: false }],
  ]);
  assert.ok(patches.every((r) => r.init.headers.authorization === 'Bearer SECRET-TOKEN' && r.init.headers['content-type'] === 'application/json'));
  pod.command({ cmd: 'search', id: 'S', query: '夜市' });
  const found = await pod.waitFor((r) => r.type === 'result' && r.id === 'S');
  assert.deepEqual(found.data.items, [
    { id: 'c-1', title: '台北夜市', update_time: 1790000000 },
    { id: 'c-2', title: '舊的', update_time: 1780000000 },
  ]);
  const searchRequest = pod.requests.find((r) => r.url.includes('/conversations/search'));
  assert.match(searchRequest.url, /query=%E5%A4%9C%E5%B8%82/);
  noLeak(pod);
});

test('pod script: attachments are handed to the page\'s own file input before sending', async () => {
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  const events = [];
  const input = { files: null, multiple: true, getAttribute(k) { return k === 'accept' ? '' : null; },
    dispatchEvent(e) { events.push(e.type); return true; } };
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => (sel === 'input[type="file"]' ? [input] : qsa(sel));
  pod.sandbox.DataTransfer = class { constructor() { this.list = []; this.items = { add: (f) => this.list.push(f) }; } get files() { return this.list; } };
  pod.sandbox.File = class { constructor(parts, name, opts) { this.name = name; this.type = opts.type; this.size = parts[0].length; } };
  pod.sandbox.Event = class { constructor(type) { this.type = type; } };
  pod.sandbox.atob = (b) => Buffer.from(b, 'base64').toString('binary');
  pod.sandbox.Uint8Array = Uint8Array;
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'A', text: '看這張', files: [{ name: '截圖.png', mime: 'image/png', base64: Buffer.from('PNGDATA').toString('base64') }] });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'A' && (r.kind === 'finished' || r.kind === 'failed'));
  assert.deepEqual(input.files.map((f) => [f.name, f.type, f.size]), [['截圖.png', 'image/png', 7]]);
  assert.deepEqual(events, ['change']);
  assert.deepEqual(pod.inserted, ['看這張']);
  pod.command({ cmd: 'diagnostics', id: 'DA' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'DA');
  assert.equal(diag.data['上傳'], '已交給網頁 1 個');
  assert.equal(diag.data['上傳欄位'], '*+multi');
});

test('pod script: tools, home suggestions and GPTs are read; a tool rides along as system_hints; a GPT chat opens /g/<id> first', async () => {
  const pod = makePod({ responses: {
    '/backend-api/system_hints': { json: { system_hints: [
      { system_hint: 'picture_v2', name: 'Create image', description: 'd', icon: 'x' },
      { system_hint: 'search', name: 'Web search' },
      { system_hint: 'connector:notion', name: 'Notion', category: 'connector', hide_from_initial_selection: true },
      { name: 'no id' },
    ] } },
    '/backend-api/prompt_library/': { json: { greeting: 'Ready when you are.', ui_style: 'x', total: 2,
      items: [{ id: 'p1', title: '整理下週行程', prompt: '幫我整理下週行程' }, { id: 'p2', prompt: '只有 prompt' }] } },
    '/backend-api/gizmos/bootstrap': { json: { gizmos: [
      { gizmo: { gizmo: { id: 'g-abc', display: { name: '翻譯小幫手' } } } },
      { flair: { kind: 'x' }, resource: { gizmo: { id: 'g-def', display: { name: '食譜助理' } } } },
    ] } },
    '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  for (const cmd of ['tools', 'home', 'gpts']) pod.command({ cmd, id: cmd });
  const tools = await pod.waitFor((r) => r.type === 'result' && r.id === 'tools');
  const home = await pod.waitFor((r) => r.type === 'result' && r.id === 'home');
  const gpts = await pod.waitFor((r) => r.type === 'result' && r.id === 'gpts');
  // 網頁「＋」第一層的名次（生圖 0、搜尋 1…）；連接的 App 另列、不給名次；hide_from_initial_selection 的標 hidden。
  assert.deepEqual(tools.data.items, [
    { id: 'picture_v2', title: 'Create image', description: 'd', primary: true, hidden: false, rank: 0, app: false, head: false, firstParty: false },
    { id: 'search', title: 'Web search', description: '', primary: true, hidden: false, rank: 1, app: false, head: false, firstParty: false },
    { id: 'connector:notion', title: 'Notion', description: '', primary: false, hidden: true, rank: null, app: false, head: false, firstParty: false },
  ]);
  assert.deepEqual(home.data, { greeting: 'Ready when you are.', items: [
    { id: 'p1', title: '整理下週行程', prompt: '幫我整理下週行程' },
    { id: 'p2', title: '只有 prompt', prompt: '只有 prompt' },
  ] });
  assert.deepEqual(gpts.data.items, [{ id: 'g-abc', title: '翻譯小幫手', kind: 'other' }, { id: 'g-def', title: '食譜助理', kind: 'other' }]);
  // 跟 GPT 開新對話＋帶「Create image」工具。
  pod.command({ cmd: 'send', id: 'T', text: '畫一隻貓', hint: 'picture_v2', gizmoID: 'g-abc' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'T' && (r.kind === 'finished' || r.kind === 'failed'));
  assert.equal(pod.state.pathname, '/g/g-abc');
  const post = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.deepEqual(JSON.parse(post.init.body).system_hints, ['picture_v2']);
});

test('pod script: feedback posts thumbs up/down for a message', async () => {
  const pod = makePod({ responses: {} });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'feedback', id: 'F1', conversationID: 'c-1', messageID: 'm-2', rating: 'thumbsDown' });
  const done = await pod.waitFor((r) => r.type === 'result' && r.id === 'F1');
  assert.equal(done.ok, true);
  const post = pod.requests.find((r) => r.url.includes('/message_feedback'));
  assert.equal(post.init.method, 'POST');
  assert.deepEqual(JSON.parse(post.init.body), { message_id: 'm-2', conversation_id: 'c-1', rating: 'thumbsDown' });
});


test('pod script: picker v2 turns versions × intelligence presets into the web\'s menu and maps the page choice back', async () => {
  const pod = makePod({ responses: {
    '/backend-api/models': { json: { default_model_slug: 'sol', model_picker_version: 2,
      versions: [
        { id: 'latest', display_text: 'Latest', display_text_full: 'Latest', enabled: true, slugs: ['sol-i', 'sol-t', 'sol-pro', 'sol'],
          intelligence_presets: ['Instant', 'Medium', 'High', 'Extra High', 'Pro'] },
        { id: '5.5', display_text: '5.5', display_text_full: 'Legacy • 5.5', enabled: true, slugs: ['old-i', 'old-t'],
          intelligence_presets: [{ label: 'Instant', model_slug: 'old-i' }, { label: 'High', model_slug: 'old-t', thinking_effort: 'extended' }] },
        { id: 'off', display_text: 'Off', enabled: false, slugs: ['sol'], intelligence_presets: ['Instant'] },
      ],
      models: [
        { slug: 'sol', title: 'GPT-X Sol', reasoning_type: 'auto' },
        { slug: 'sol-i', title: 'GPT-X Sol', reasoning_type: 'none' },
        { slug: 'sol-t', title: 'GPT-X Sol', reasoning_type: 'reasoning', thinking_efforts: [{ thinking_effort: 'max', short_label: 'Heavy' }] },
        { slug: 'sol-pro', title: 'GPT-X Pro', reasoning_type: 'pro' },
        { slug: 'old-i', title: 'GPT-5.5', reasoning_type: 'none' },
        { slug: 'old-t', title: 'GPT-5.5 Thinking', reasoning_type: 'reasoning' },
        { slug: 'mini', title: 'GPT-X Mini', reasoning_type: 'none' },
        { slug: 'wm', title: 'GPT-X Work', is_work_mode_model: true },
      ] } },
    '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'models', id: 'V' });
  const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'V');
  // 每個檔位多帶面板要顯示的「版本代號＋檔位名稱」與說明（純文字檔位沒有，就用名稱）；
  // Pro 是最高檔（紫色）；最新版的名字不帶版本號，舊版帶（跟網頁一樣：High／5.5 High）。
  const p = (id, title, extra = {}) => ({ id, title, version: '', level: title, detail: '', max: false, showVersion: false, ...extra });
  assert.deepEqual(res.data.versions, [
    { id: 'latest', title: 'Latest', presets: [
      p('sol-i', 'Instant'), p('sol-t|standard', 'Medium'), p('sol-t|extended', 'High'), p('sol-t|max', 'Extra High'), p('sol-pro', 'Pro', { max: true })] },
    { id: '5.5', title: 'Legacy • 5.5', presets: [p('old-i', 'Instant', { showVersion: true }), p('old-t|extended', 'High', { showVersion: true })] },
  ]);
  // 模型清單用中文語言標頭要（網頁切成繁中時一樣），好拿到中文的檔位名稱與說明。
  const modelsRequest = pod.requests.find((r) => r.url.includes('/backend-api/models'));
  assert.equal(modelsRequest.init.headers['oai-language'], 'zh-TW');
  // 已在版本檔位裡的模型不重複列；其他模型（Mini）留在「其他模型」；Work 模型不列。
  assert.deepEqual(res.data.models.map((m) => m.title), ['GPT-X Mini']);
  // 網頁自己用 sol-t＋max → 回報成 Latest／Extra High。
  pod.sandbox.document.querySelector = ((original) => (selector) => {
    if (selector === '[data-testid="send-button"]') return { disabled: false, click() {
      pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST',
        body: JSON.stringify({ model: 'sol-t', thinking_effort: 'max', messages: [] }) }).then((r) => r.text());
    } };
    return original(selector);
  })(pod.sandbox.document.querySelector);
  pod.command({ cmd: 'send', id: 'Q', text: 'x' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'Q' && (r.kind === 'finished' || r.kind === 'failed'));
  assert.deepEqual(pod.reports.find((r) => r.type === 'selection'),
    { type: 'selection', model: 'version:latest', effort: 'sol-t|max', title: 'Latest' });
});

// 09-24 v2.0.19.014 實機：暫時對話的第二則沒帶旗標 → HTTP 404；網頁版每一則都帶。
test('pod script: every message of a temporary chat carries history_and_training_disabled; normal chats do not', async () => {
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'T1', text: 'x', temporary: true });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'T1' && (r.kind === 'finished' || r.kind === 'failed'));
  const first = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(first.init.body).history_and_training_disabled, true);
  pod.command({ cmd: 'send', id: 'T2', text: 'y', temporary: true, conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'T2' && (r.kind === 'finished' || r.kind === 'failed'));
  const second = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(second.init.body).history_and_training_disabled, true);
  pod.command({ cmd: 'send', id: 'T3', text: 'z', conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'T3' && (r.kind === 'finished' || r.kind === 'failed'));
  const third = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(third.init.body).history_and_training_disabled, undefined);
});

test('pod script: probe never presses Pin/Delete; pin toggles press the page\'s own Pin/Unpin button', async () => {
  const pod = makePod({ responses: {} });
  const pressed = [];
  const mkBtn = (label) => ({ getAttribute(k) { return k === 'aria-label' ? label : null; }, textContent: '',
    dispatchEvent(e) { if (e.type === 'pointerdown') pressed.push(label); return true; }, click() {} });
  const id = '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b';
  let rowButtons = [mkBtn('Pin 自測對話'), mkBtn('Open conversation options')];
  const rowParent = { querySelectorAll: (sel) => (sel === 'button' ? rowButtons : []) };
  const doc = pod.sandbox.document;
  const qs = doc.querySelector;
  doc.querySelector = (sel) => (sel === 'a[href$="/c/' + id + '"]' ? { parentElement: rowParent } : qs(sel));
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.KeyboardEvent = class { constructor(type) { this.type = type; } };
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'probe', id: 'P1', conversationID: id });
  const probe = await pod.waitFor((r) => r.type === 'result' && r.id === 'P1', 8000);
  assert.equal(probe.ok, true);
  assert.deepEqual(pressed, ['Open conversation options'], 'only the options button is pressed');
  assert.equal(probe.data['網頁對話按鈕'], 'Pin 自測對話, Open conversation options');
  pressed.length = 0;
  pod.command({ cmd: 'pin', id: 'P2', conversationID: id, pinned: true });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'P2');
  assert.deepEqual(pressed, ['Pin 自測對話']);
  rowButtons = [mkBtn('Unpin 自測對話'), mkBtn('Open conversation options')];
  pressed.length = 0;
  pod.command({ cmd: 'pin', id: 'P3', conversationID: id, pinned: false });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'P3');
  assert.deepEqual(pressed, ['Unpin 自測對話']);
});


test('pod script: + menu ranks tools like the web and marks connected apps', async () => {
  const pod = makePod({ responses: {
    '/backend-api/system_hints': { json: { system_hints: [
      { system_hint: 'research', name: 'Deep research', description: 'Get a detailed report' },
      { system_hint: 'tasks', name: 'Tasks' },
      { system_hint: 'sketch', name: 'Sketch', description: 'Draw and attach an image' },
      { system_hint: 'picture_v2', name: 'Create image', description: 'Visualize anything' },
      { system_hint: 'search', name: 'Search', category: 'source' },
      { system_hint: 'connector:connector_github', name: 'GitHub', is_connector: true, is_head_plugin: true, is_connected: true },
      { system_hint: 'tatertot', name: 'Study', hide_from_initial_selection: true },
    ] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'tools', id: 'T' });
  const tools = await pod.waitFor((r) => r.type === 'result' && r.id === 'T');
  const byID = Object.fromEntries(tools.data.items.map((t) => [t.id, t]));
  assert.equal(byID.picture_v2.rank, 0);
  assert.equal(byID.search.rank, 1);
  assert.equal(byID.research.rank, 3);
  assert.equal(byID.sketch.rank, 4.5);
  assert.equal(byID.tasks.rank, null);
  assert.deepEqual([byID['connector:connector_github'].app, byID['connector:connector_github'].head, byID['connector:connector_github'].rank], [true, true, null]);
  assert.equal(byID.tatertot.hidden, true);
  pod.command({ cmd: 'diagnostics', id: 'D' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'D');
  assert.match(diag.data["工具分類"], /GitHub:connector:connector_gith:-:app:head:on/);
});

test('pod script: images load by file id from any pointer form, with or without a conversation', async () => {
  const pod = makePod({ responses: {
    '/backend-api/files/download/file_00000000abc': { json: { status: 'success', download_url: 'https://files.oaiusercontent.com/x?sig=1' } },
    // 帶對話編號時找不到（暫時對話實機 404），不帶才拿到。
    '/backend-api/files/download/abc*file_00000000abc': (url) => (url.includes('conversation_id=')
      ? new Response('{}', { status: 404, headers: { 'content-type': 'application/json' } })
      : new Response(JSON.stringify({ download_url: 'https://files.oaiusercontent.com/y?sig=3' }), { status: 200, headers: { 'content-type': 'application/json' } })),
  } });
  pod.sandbox.location.href = 'https://chatgpt.com/';
  pod.sandbox.location.origin = 'https://chatgpt.com';
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  // 沒有對話編號（暫時對話）也照樣讀；檔案代號照網頁的規則（去掉 sediment://，# 換成 *）。
  pod.command({ cmd: 'image', id: 'I1', pointer: 'sediment://file_00000000abc' });
  const image = await pod.waitFor((r) => r.type === 'result' && r.id === 'I1');
  assert.equal(image.ok, true);
  assert.equal(image.data.url, 'https://files.oaiusercontent.com/x?sig=1');
  const download = pod.requests.find((r) => r.url.includes('/files/download/'));
  assert.match(download.url, /\/files\/download\/file_00000000abc\?inline=false$/);
  pod.command({ cmd: 'image', id: 'I3', pointer: 'sediment://abc#file_00000000abc', conversationID: 'tmp-1' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'I3');
  const hashed = pod.requests.filter((r) => r.url.includes('/files/download/')).map((r) => r.url);
  // 帶對話找不到（404）→ 再試不帶對話。
  assert.match(hashed.at(-2), /\/files\/download\/abc\*file_00000000abc\?conversation_id=tmp-1&inline=false$/);
  assert.match(hashed.at(-1), /\/files\/download\/abc\*file_00000000abc\?inline=false$/);
  pod.command({ cmd: 'image', id: 'I2', pointer: 'attachment://nope' });
  const bad = await pod.waitFor((r) => r.type === 'result' && r.id === 'I2');
  assert.equal(bad.ok, false);
  noLeak(pod);
});

test('pod script: library lists files like the web (suggested / images / all) and fetches thumbnails', async () => {
  const pod = makePod({ responses: {
    '/backend-api/files/library': { json: { cursor: 'next-1', items: [
      { id: 'lib_1', file_name: 'a.png', mime_type: 'image/png', library_file_category: 'image', last_used_at: '2026-09-24T01:00:00Z', file_size_bytes: 10 },
      { id: 'lib_2', name: 'notes.md', mime_type: 'text/markdown', updated_at: 1790000000 },
      { id: 'dir_1', kind: 'directory', name: 'Folder' },
      { id: 'lib_3' },
    ] } },
    '/backend-api/files/library/files/lib_1/thumbnail_url': { json: { thumbnail_url: 'https://files.oaiusercontent.com/t?sig=2' } },
  } });
  pod.sandbox.location.href = 'https://chatgpt.com/';
  pod.sandbox.location.origin = 'https://chatgpt.com';
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'library', id: 'L1', tab: 'suggested', query: '' });
  const first = await pod.waitFor((r) => r.type === 'result' && r.id === 'L1');
  assert.deepEqual(first.data, { cursor: 'next-1', items: [
    { id: 'lib_1', name: 'a.png', mime: 'image/png', category: 'image', time: '2026-09-24T01:00:00Z', size: 10 },
    { id: 'lib_2', name: 'notes.md', mime: 'text/markdown', category: 'text', time: 1790000000, size: null },
  ] });
  const posts = () => pod.requests.filter((r) => r.url.endsWith('/backend-api/files/library')).map((r) => JSON.parse(r.init.body));
  assert.deepEqual(posts()[0], { limit: 40, cursor: null, ranking: 'suggested', include_saved_entities: true });
  pod.command({ cmd: 'library', id: 'L2', tab: 'images', query: '貓', cursor: 'next-1' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'L2');
  assert.deepEqual(posts()[1], { limit: 40, cursor: 'next-1', q: '貓', categories: ['image'] });
  pod.command({ cmd: 'library', id: 'L3', tab: 'all', query: '' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'L3');
  assert.deepEqual(posts()[2], { limit: 40, cursor: null });
  pod.command({ cmd: 'libraryData', id: 'T1', itemID: 'lib_1', full: false });
  const thumb = await pod.waitFor((r) => r.type === 'result' && r.id === 'T1');
  assert.equal(thumb.data.url, 'https://files.oaiusercontent.com/t?sig=2');
  pod.command({ cmd: 'libraryData', id: 'T2', itemID: '../../x', full: true });
  const bad = await pod.waitFor((r) => r.type === 'result' && r.id === 'T2');
  assert.equal(bad.ok, false);
  noLeak(pod);
});

test('pod script: answers carry their web sources; image refs and non-http links are left out', async () => {
  const pod = makePod({ responses: {
    '/backend-api/conversation/src': { json: { current_node: 'n2', mapping: {
      n1: { message: { id: 'm1', author: { role: 'user' }, content: { content_type: 'text', parts: ['台北天氣'] } }, parent: null },
      n2: { message: { id: 'm2', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['晴天'] }, metadata: {
        content_references: [
          { type: 'grouped_webpages', items: [{ title: '氣象署', url: 'https://www.cwa.gov.tw/a', attribution: 'cwa' }] },
          { type: 'image_v2', images: [{ url: 'https://img.example/x.png' }], url: 'https://img.example/x.png' },
          { type: 'sources_footnote', sources: [{ title: '氣象署', url: 'https://www.cwa.gov.tw/a' }, { title: 'B', url: 'https://b.example/' }] },
        ],
        citations: [{ metadata: { title: 'JS', url: 'javascript:alert(1)' } }],
      } }, parent: 'n1' },
    } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'get', id: 'G', conversationID: 'src' });
  const got = await pod.waitFor((r) => r.type === 'result' && r.id === 'G');
  assert.deepEqual(got.data.messages[1].sources, [
    { url: 'https://www.cwa.gov.tw/a', title: '氣象署' },
    { url: 'https://b.example/', title: 'B' },
  ]);
  assert.equal(got.data.messages[0].sources, undefined);
});

test('pod script: new-chat headline comes from the page when ChatGPT has no greeting', async () => {
  const pod = makePod({ responses: { '/backend-api/prompt_library/': { json: { greeting: null, items: [] } } } });
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => (sel === 'main h1' ? [{ className: 'sr-only', textContent: '隱藏' }, { className: 'text-2xl', textContent: ' Ready when you are. ' }] : qsa(sel));
  pod.sandbox.location.search = '';
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'home', id: 'H' });
  const home = await pod.waitFor((r) => r.type === 'result' && r.id === 'H');
  assert.equal(home.data.greeting, 'Ready when you are.');
});

test('pod script: regenerating with another preset swaps the model on the page\'s own request', async () => {
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  let menuOpen = false;
  const mk = (label, onPress) => ({ getAttribute(k) { return k === 'aria-label' ? label : null; }, textContent: '',
    dispatchEvent(e) { if (e.type === 'pointerdown' && onPress) onPress(); return true; }, click() {} });
  const tryAgain = { textContent: 'Try again', getAttribute() { return null; }, dispatchEvent() { return true; },
    click() { pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: '{"action":"variant","model":"m","thinking_effort":"standard"}' }).then((r) => r.text()); } };
  const buttons = [mk('Copy response'), mk('Share'), mk('Switch model', () => { menuOpen = true; }), mk('More actions')];
  const scope = { parentElement: null, querySelectorAll: (sel) => (sel === 'button' ? buttons : []) };
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => {
    if (sel === '[data-message-author-role="assistant"]') return [{ innerText: '舊回答', parentElement: scope }];
    if (sel.startsWith('[role="menuitem"]')) return menuOpen ? [tryAgain] : [];
    return qsa(sel);
  };
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.MouseEvent = class { constructor(type) { this.type = type; } };
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'regenerate', id: 'R', conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b', effort: 'sol-t|max' });
  const end = await pod.waitFor((r) => r.type === 'stream' && r.id === 'R' && (r.kind === 'finished' || r.kind === 'failed'), 5000);
  assert.equal(end.kind, 'finished');
  const post = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.deepEqual(JSON.parse(post.init.body), { action: 'variant', model: 'sol-t', thinking_effort: 'max' });
  pod.command({ cmd: 'diagnostics', id: 'D' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'D');
  assert.match(diag.data['重新產生'], /（換 sol-t・max）/);
});

test('ChatGPT Space mirrors the web: layered + menu, Library, sources, switch-model retry, temporary chats stay out of the list', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  // 「＋」：加入檔案＋說明；有名次的前 4 個工具；最近用過的 App；其他收進「更多」。
  const plus = space.slice(space.indexOf('照網頁版分層'), space.indexOf('accessibilityIdentifier("chatgpt.plus")'));
  assert.match(plus, /Text\("加入照片和檔案"\)\s*Text\("從電腦上傳"\)/);
  assert.match(plus, /ForEach\(model\.plusTools\)[\s\S]*ForEach\(model\.plusApps\)[\s\S]*Menu\("更多"\) \{ ForEach\(model\.moreTools\)/);
  assert.match(space, /\.prefix\(4\)\)/);
  assert.match(space, /if !tool\.detail\.isEmpty \{ Text\(tool\.detail\) \}/);
  // 資料庫：側欄入口、分頁、只在記憶體預覽，不寫檔。
  assert.match(space, /Text\("圖庫"\)/);
  assert.match(read(app + 'TAP/ChatGPTPages.swift'), /accessibilityIdentifier\("chatgpt\.page\.\\\(page\.rawValue\)"\)/);
  assert.match(space, /case \.library: ChatGPTLibraryView\(model: model\)/);
  assert.match(space, /PDFDocument\(data: data\)/);
  // 來源、換模型重答。
  assert.match(space, /ChatGPTSourcesButton\(model: model, sources: message\.sources\)/);
  assert.match(space, /Section\("換模型重答"\)[\s\S]*model\.regenerate\(effort: option\.id\)/);
  // 暫時對話：不插進側欄、標題寫暫時對話、沒有對話選項；沒有對話編號也讀得到圖。
  assert.match(space, /if let conversationID, !temporary, !conversations\.contains/);
  assert.match(space, /if selectedID == temporaryConversationID \{ return "臨時聊天" \}/);
  assert.match(space, /if let id = model\.selectedID, id != model\.temporaryConversationID \{/);
  assert.match(space, /tap\.imageData\(pointer: pointer, conversationID: selectedID\)/);
});

test('pod script: versions (‹ 1/2 ›) come with each turn; a branch shows that version down to its newest reply', async () => {
  const mapping = {
    n0: { message: null, parent: null, children: ['n1'] },
    n1: { message: { id: 'n1', author: { role: 'system' }, metadata: { is_visually_hidden_from_conversation: true }, content: { content_type: 'text', parts: [''] } }, parent: 'n0', children: ['u1', 'u2'] },
    u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['問題'] } }, parent: 'n1', children: ['a1', 'a2'] },
    a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['舊回答'] } }, parent: 'u1', children: [] },
    a2: { message: { id: 'a2', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['新回答'] } }, parent: 'u1', children: [] },
    u2: { message: { id: 'u2', author: { role: 'user' }, content: { content_type: 'text', parts: ['改過的問題'] } }, parent: 'n1', children: ['a3'] },
    a3: { message: { id: 'a3', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['改過的回答'] } }, parent: 'u2', children: [] },
  };
  const pod = makePod({ responses: { '/backend-api/conversation/v': { json: { current_node: 'a2', mapping } } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'get', id: 'G1', conversationID: 'v' });
  const current = await pod.waitFor((r) => r.type === 'result' && r.id === 'G1');
  assert.deepEqual(current.data.messages, [
    { id: 'u1', role: 'user', text: '問題', variant: { index: 0, count: 2, nodes: ['u1', 'u2'] } },
    { id: 'a2', role: 'assistant', text: '新回答', variant: { index: 1, count: 2, nodes: ['a1', 'a2'] } },
  ]);
  assert.deepEqual(current.data.parents, { u1: 'n1' });
  assert.equal(current.data.leaf, 'a2');
  assert.equal(current.data.current, true);
  pod.command({ cmd: 'get', id: 'G2', conversationID: 'v', branch: 'a1' });
  const older = await pod.waitFor((r) => r.type === 'result' && r.id === 'G2');
  assert.equal(older.data.messages[1].text, '舊回答');
  assert.deepEqual(older.data.messages[1].variant, { index: 0, count: 2, nodes: ['a1', 'a2'] });
  assert.deepEqual([older.data.leaf, older.data.current], ['a1', false]);
  pod.command({ cmd: 'get', id: 'G3', conversationID: 'v', branch: 'u2' });
  const edited = await pod.waitFor((r) => r.type === 'result' && r.id === 'G3');
  assert.deepEqual(edited.data.messages.map((m) => m.text), ['改過的問題', '改過的回答']);
  assert.deepEqual(edited.data.messages[0].variant, { index: 1, count: 2, nodes: ['u1', 'u2'] });
  assert.equal(edited.data.messages[1].variant, undefined);
  assert.deepEqual([edited.data.leaf, edited.data.current], ['a3', false]);
});

test('pod script: sending after switching versions (or editing) continues from the chosen node', async () => {
  const cid = '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b';
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  const doc = pod.sandbox.document;
  const qs = doc.querySelector;
  doc.querySelector = (sel) => (sel === '[data-testid="send-button"]' ? { disabled: false, click() {
    pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST',
      body: JSON.stringify({ action: 'next', parent_message_id: 'web-leaf', model: 'auto', messages: [] }) }).then((r) => r.text());
  } } : qs(sel));
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'S', text: '接著問', conversationID: cid, parentID: 'a1' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'S' && (r.kind === 'finished' || r.kind === 'failed'));
  const post = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(post.init.body).parent_message_id, 'a1');
  // 新對話不帶接續節點（沒有上一層可接）。
  pod.command({ cmd: 'send', id: 'S2', text: '新的', parentID: 'x' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'S2' && (r.kind === 'finished' || r.kind === 'failed'));
  const post2 = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.equal(JSON.parse(post2.init.body).parent_message_id, 'web-leaf');
});

test('pod script: a new chat in a project is sent from the project page', async () => {
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'P', text: '專案裡的新問題', gizmoID: 'g-p-abc123' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'P' && (r.kind === 'finished' || r.kind === 'failed'));
  assert.equal(pod.state.pathname, '/g/g-p-abc123/project');
});

test('ChatGPT Space: edit/copy own messages, version switch, new chat inside a project', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  assert.match(space, /case \.user:\s*ChatGPTUserMessageView\(model: model, message: message\)/);
  assert.match(space, /iconButton\("doc\.on\.doc", help: "拷貝訊息"\)/);
  assert.match(space, /iconButton\("pencil", help: "編輯訊息"\)/);
  assert.match(space, /model\.edit\(message, to: draft\)/);
  assert.match(space, /parentID: parent\)/);
  assert.match(space, /ChatGPTVariantNav\(model: model, message: message, variant: variant\)/);
  assert.match(space, /model\.showVariant\(message, offset: -1\)/);
  // 看舊版本時不能重新產生（網頁重答的是最新那一支）。
  assert.match(space, /model\.selectedID != nil, model\.branchLeaf == nil \{/);
  assert.match(space, /Button \{ model\.newChat\(with: folder\) \} label: \{\s*HStack\(spacing: 4\) \{\s*Image\(systemName: "plus"\)/);
});

test('pod script: + menu ranks Deep research third like the web and keeps OpenAI\'s own apps off the first level', async () => {
  const pod = makePod({ responses: {
    '/backend-api/system_hints': { json: { system_hints: [
      { system_hint: 'connector:connector_openai_deep_research', name: 'Deep research', is_connector: true },
      { system_hint: 'connector:connector_openai_pdf', name: 'PDF', is_connector: true },
      { system_hint: 'connector:connector_7686', name: 'GitHub', is_connector: true },
      { system_hint: 'search', name: 'Search' },
    ] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'tools', id: 'T' });
  const tools = await pod.waitFor((r) => r.type === 'result' && r.id === 'T');
  const byID = Object.fromEntries(tools.data.items.map((t) => [t.id, t]));
  assert.deepEqual([byID['connector:connector_openai_deep_research'].rank, byID['connector:connector_openai_deep_research'].app], [3, false]);
  assert.deepEqual([byID['connector:connector_openai_pdf'].app, byID['connector:connector_openai_pdf'].firstParty], [true, true]);
  assert.deepEqual([byID['connector:connector_7686'].app, byID['connector:connector_7686'].firstParty], [true, false]);
  assert.equal(byID.search.title, 'Web search');
});

test('ChatGPT Space: temporary chats flag every message; library zoom starts from the thumbnail; markdown files render as markdown', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  assert.match(space, /let temporary = selectedID == nil \? temporaryChat : selectedID == temporaryConversationID/);
  assert.match(space, /tap\.regenerate\(conversationID: conversationID, model: nil, effort: effort, temporary: temporary\)/);
  assert.match(space, /let apps = tools\.filter \{ \$0\.isApp && !\$0\.hidden && !\$0\.firstPartyApp \}/);
  assert.match(space, /Image\(systemName: "paperclip"\)\s*Text\("加入照片和檔案"\)\s*Text\("從電腦上傳"\)/);
  assert.match(space, /let thumbnail = cachedImage\("library:\\\(item\.id\)"\)\s*zoomSource = \.library\(item\)\s*if let thumbnail \{ zoomedImage = thumbnail \}/);
  assert.match(space, /case \.markdown\(let text\):\s*ScrollView \{\s*ChatAssistantTranscriptBlockView\(/);
  assert.match(space, /\.accessibilityAction\(named: "拷貝訊息"\)/);
  assert.match(space, /\.accessibilityAction\(named: "編輯訊息"\)/);
});

test('pod script: citation markers become the markdown links ChatGPT provides; widget markers are dropped', async () => {
  const cite = 'citeturn0search0';
  const widget = 'genuixBGg';
  const pod = makePod({ responses: {
    '/backend-api/conversation/cm': { json: { current_node: 'a1', mapping: {
      u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['天氣'] } }, parent: null, children: ['a1'] },
      a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['晴天 24°C。' + cite + ' ' + widget] },
        metadata: { content_references: [
          { matched_text: cite, alt: '([中央氣象署](https://www.cwa.gov.tw/))', type: 'grouped_webpages', items: [{ title: '中央氣象署', url: 'https://www.cwa.gov.tw/' }] },
          { matched_text: widget, alt: '天氣小工具的文字版', type: 'genui' },
        ] } }, parent: 'u1', children: [] },
    } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'get', id: 'G', conversationID: 'cm' });
  const got = await pod.waitFor((r) => r.type === 'result' && r.id === 'G');
  assert.equal(got.data.messages[1].text, '晴天 24°C。([中央氣象署](https://www.cwa.gov.tw/)) ');
  assert.doesNotMatch(got.data.messages[1].text, /[-]|genui|turn0search0/);
});

test('pod script: retrying with a model that has no reasoning effort drops the page\'s effort', async () => {
  const pod = makePod({ responses: {
    '/backend-api/models': { json: { models: [
      { slug: 'sol-i', title: 'Sol Instant', reasoning_type: 'none' },
      { slug: 'sol-t', title: 'Sol', reasoning_type: 'reasoning' },
    ] } },
    '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
  } });
  let menuOpen = false;
  const mk = (label, onPress) => ({ getAttribute(k) { return k === 'aria-label' ? label : null; }, textContent: '',
    dispatchEvent(e) { if (e.type === 'pointerdown' && onPress) onPress(); return true; }, click() {} });
  const tryAgain = { textContent: 'Try again', getAttribute() { return null; }, dispatchEvent() { return true; },
    click() { pod.sandbox.window.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: '{"action":"variant","model":"sol-t","thinking_effort":"max"}' }).then((r) => r.text()); } };
  const buttons = [mk('Copy response'), mk('Switch model', () => { menuOpen = true; }), mk('More actions')];
  const scope = { parentElement: null, querySelectorAll: (sel) => (sel === 'button' ? buttons : []) };
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => {
    if (sel === '[data-message-author-role="assistant"]') return [{ innerText: '舊回答', parentElement: scope }];
    if (sel.startsWith('[role="menuitem"]')) return menuOpen ? [tryAgain] : [];
    return qsa(sel);
  };
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.MouseEvent = class { constructor(type) { this.type = type; } };
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'models', id: 'M' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'M');
  pod.command({ cmd: 'regenerate', id: 'R', conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b', effort: 'sol-i' });
  const end = await pod.waitFor((r) => r.type === 'stream' && r.id === 'R' && (r.kind === 'finished' || r.kind === 'failed'), 5000);
  assert.equal(end.kind, 'finished');
  const post = pod.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  assert.deepEqual(JSON.parse(post.init.body), { action: 'variant', model: 'sol-i' });
  pod.command({ cmd: 'diagnostics', id: 'D' });
  const diag = await pod.waitFor((r) => r.type === 'result' && r.id === 'D');
  assert.equal(diag.data['送出請求改寫後'], 'model=sol-i，強度=無');
});

// ---- 09-25「2全要」：分享、排程、外掛、網站、個人化、帳號、圖庫刪除、語音 ----

test('pod script: share presses the page\'s own Share chat and captures the link without touching the clipboard', async () => {
  const written = [];
  const cid = '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b';
  const pod = makePod({ responses: {}, setup: (sb) => {
    sb.navigator = { clipboard: { writeText: async (t) => { written.push(t); } } };
  } });
  const shareButton = { getAttribute: (k) => (k === 'aria-label' ? 'Share chat' : null), textContent: '', dispatchEvent: () => true,
    click: () => { pod.sandbox.navigator.clipboard.writeText('https://chatgpt.com/share/68d3b2a1-1111-2222-3333-444455556666'); } };
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => (sel === 'button' ? [shareButton] : qsa(sel));
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.MouseEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.KeyboardEvent = class { constructor(type) { this.type = type; } };
  doc.dispatchEvent = () => true;
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'share', id: 'SH', conversationID: cid });
  const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'SH', 8000);
  assert.equal(res.ok, true);
  assert.equal(res.data.url, 'https://chatgpt.com/share/68d3b2a1-1111-2222-3333-444455556666');
  assert.deepEqual(written, []);   // 使用者的剪貼簿沒被網頁寫
  // 分享結束後，網頁自己要拷貝的東西照常寫。
  await pod.sandbox.navigator.clipboard.writeText('其他內容');
  assert.deepEqual(written, ['其他內容']);
});

test('pod script: scheduled tasks, plugins, sites, memories, instructions and account map only what the App shows', async () => {
  const pod = makePod({ responses: {
    '/backend-api/automations': { json: { items: [
      { id: 'a1', title: '晨報', prompt: '整理新聞', is_enabled: false, executor: 'cloud', timing_mode: 'exact_schedule', display_schedule: null,
        schedule: 'BEGIN:VEVENT\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0\nEND:VEVENT', next_run_times: ['2026-09-26T01:00:00Z'], conversation_id: 'c1', secret: 'x' },
      { id: 'a2', title: '提醒', prompt: '', is_enabled: false, executor: 'cloud', timing_mode: 'exact_schedule',
        schedule: 'BEGIN:VEVENT\nDTSTART;TZID=Asia/Taipei:20260820T043000\nEND:VEVENT', next_run_times: [] },
      { id: 'a3', title: '監控', prompt: '', is_enabled: true, executor: 'cloud', timing_mode: 'condition_watch', display_schedule: 'Monitoring',
        schedule: 'BEGIN:VEVENT\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=49\nEND:VEVENT', next_run_times: ['2026-09-26T01:49:00Z'] }] } },
    // 外掛服務在 /backend-api/ps/（09-25 網頁快取的真實網址）；名字、圖示在 release 裡。
    '/backend-api/ps/plugins/installed': { json: { plugins: [
      { id: 'p1', name: 'github', enabled: true, release: { display_name: 'GitHub', description: 'long', interface: { short_description: 'repos', logo_url: 'https://cdn.example/g.png' } } },
      { id: 'p3', name: 'canva', enabled: false, release: { display_name: 'Canva', interface: { logo_url: 'http://insecure/c.png' } } }],
      pagination: { limit: 1000, next_page_token: null } } },
    '/backend-api/ps/plugins/home': { json: { sections: [
      { id: 'featured', url_slug: 'featured', title: 'Popular', plugins: [
        { id: 'p1', display_name: 'GitHub', short_description: 'repos', icon_url: 'https://cdn.example/g.png' },
        { id: 'p2', display_name: 'Notion', short_description: 'notes', icon_url: 'https://cdn.example/n.png' }] },
      { id: 'empty', url_slug: 'empty', title: 'Empty', plugins: [] }] } },
    '/backend-api/ps/plugins/p2/install': { json: { oauth_url: 'https://notion.example/oauth?state=1' } },
    '/backend-api/ps/plugins/p4/install': () => new Response('{}', { status: 404, headers: { 'content-type': 'application/json' } }),
    '/backend-api/websites': { json: { items: [{ id: 's1', name: '作品集', live_url: 'https://abc.chatgpt.site', updated_at: '2026-09-24T02:00:00Z' }] } },
    '/backend-api/memories': { json: { memories: [{ id: 'm1', content: '喜歡繁體中文', updated_at: '2026-09-20T00:00:00Z' }], memory_max_tokens: 200, memory_num_tokens: 50 } },
    '/backend-api/user_system_messages': { json: { enabled: true, name_user_message: '小明', role_user_message: '工程師',
      traits_model_message: '簡潔', other_user_message: '住台北' } },
    '/backend-api/me': { json: { id: 'user-abc', name: 'Test User', email: 'user@example.invalid', picture: 'https://img.example/p.png', phone_number: '+886' } },
    '/backend-api/calpico/chatgpt/profile/user-abc': { json: { display_name: 'fixture', username: 'fixture', profile_picture_url: null, bio_snippets: ['x'] } },
    '/backend-api/accounts/check/v4-2023-04-27': { json: { account_ordering: ['acc1'], accounts: { acc1: { account: { plan_type: 'pro' } } } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  const call = async (cmd, extra = {}) => {
    const id = cmd + Math.random();
    pod.command({ cmd, id, ...extra });
    const r = await pod.waitFor((x) => x.type === 'result' && x.id === id);
    assert.equal(r.ok, true, cmd + ': ' + r.message);
    return r.data;
  };
  // 狀態照網頁：沒有下一次（又不是監控）＝已完成；監控中帶 ChatGPT 自己的說明。
  assert.deepEqual((await call('automations')).items, [
    { id: 'a1', title: '晨報', prompt: '整理新聞', schedule: 'BEGIN:VEVENT\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0\nEND:VEVENT', enabled: false,
      next: '2026-09-26T01:00:00Z', conversationID: 'c1', display: '', completed: false, watching: false },
    { id: 'a2', title: '提醒', prompt: '', schedule: 'BEGIN:VEVENT\nDTSTART;TZID=Asia/Taipei:20260820T043000\nEND:VEVENT', enabled: false,
      next: null, conversationID: null, display: '', completed: true, watching: false },
    { id: 'a3', title: '監控', prompt: '', schedule: 'BEGIN:VEVENT\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=49\nEND:VEVENT', enabled: true,
      next: '2026-09-26T01:49:00Z', conversationID: null, display: 'Monitoring', completed: false, watching: true }]);
  await call('automationStatus', { automationID: 'a1', enabled: true });
  await call('automationRemove', { automationID: 'a1' });
  const body = (path) => JSON.parse(pod.requests.filter((r) => r.url.endsWith(path)).at(-1).init.body);
  assert.deepEqual(body('/backend-api/automations/set_status'), { jawbone_id: 'a1', is_enabled: true });
  assert.deepEqual(body('/backend-api/automations/remove'), { automation_id: 'a1' });
  const plugins = await call('plugins');
  assert.deepEqual(plugins.installed, [
    { id: 'p1', name: 'GitHub', description: 'repos', enabled: true, icon: 'https://cdn.example/g.png', installed: true },
    { id: 'p3', name: 'Canva', description: '', enabled: false, icon: null, installed: true }]);
  assert.deepEqual(plugins.sections, [{ id: 'featured', title: 'Popular', plugins: [
    { id: 'p1', name: 'GitHub', description: 'repos', enabled: true, icon: 'https://cdn.example/g.png', installed: true },
    { id: 'p2', name: 'Notion', description: 'notes', enabled: true, icon: 'https://cdn.example/n.png', installed: false }] }]);
  const installedReq = pod.requests.filter((r) => r.url.includes('/backend-api/ps/plugins/installed')).at(-1);
  assert.match(installedReq.url, /[?&]limit=1000\b/);
  assert.equal(installedReq.init.headers['oai-language'], 'zh-TW');
  assert.equal(pod.requests.filter((r) => /\/backend-api\/plugins\/(installed|featured)/.test(r.url)).length, 0, 'old non-ps paths are not used');
  assert.equal((await call('pluginAction', { pluginID: 'p2', action: 'install' })).authURL, 'https://notion.example/oauth?state=1');
  assert.equal(pod.requests.filter((r) => r.url.endsWith('/backend-api/ps/plugins/p2/install')).at(-1).init.method, 'POST');
  // /ps/ 回 404 時退回舊路徑（網頁兩種傳法都有）。
  await call('pluginAction', { pluginID: 'p4', action: 'install' });
  assert.equal(pod.requests.filter((r) => r.url.endsWith('/backend-api/plugins/p4/install')).length, 1);
  await call('pluginAction', { pluginID: 'p1', action: 'uninstall' });
  assert.equal(pod.requests.filter((r) => r.url.endsWith('/backend-api/ps/plugins/p1/uninstall')).length, 1);
  const bad = 'X' + Math.random();
  pod.command({ cmd: 'pluginAction', id: bad, action: 'rm -rf' });
  assert.equal((await pod.waitFor((x) => x.type === 'result' && x.id === bad)).ok, false);
  assert.deepEqual((await call('sites')).items, [{ id: 's1', name: '作品集', url: 'https://abc.chatgpt.site', updated: '2026-09-24T02:00:00Z', status: '' }]);
  const memories = await call('memories');
  assert.deepEqual(memories, { items: [{ id: 'm1', text: '喜歡繁體中文', updated: '2026-09-20T00:00:00Z' }], usage: 25 });
  await call('memoryDelete', { memoryID: 'm1' });
  assert.equal(pod.requests.filter((r) => r.url.endsWith('/backend-api/memories/m1')).at(-1).init.method, 'DELETE');
  assert.deepEqual(await call('instructions'), { enabled: true, nickname: '小明', occupation: '工程師', traits: '簡潔', about: '住台北' });
  await call('saveInstructions', { enabled: true, nickname: '阿明', occupation: '設計', traits: '直接', about: '住高雄' });
  const saved = body('/backend-api/user_system_messages');
  assert.equal(saved.name_user_message, '阿明');
  assert.equal(saved.other_user_message, '住高雄');
  // 左下角名字＝ChatGPT 個人檔案的顯示名稱（網頁就是這樣）；大頭貼也只用個人檔案的（沒有就顯示字首）。
  assert.deepEqual(await call('account'), { name: 'fixture', email: 'user@example.invalid', picture: null, plan: 'pro' });
  await call('libraryDelete', { itemID: 'lib_1' });
  assert.equal(pod.requests.filter((r) => r.url.endsWith('/backend-api/files/library/files/lib_1')).at(-1).init.method, 'DELETE');
  noLeak(pod);
});

test('pod script: voice mode presses the page\'s Start Voice and ends with End voice mode', async () => {
  const pod = makePod({ responses: {} });
  let live = false;
  const pressed = [];
  const button = (label, onClick) => ({ getAttribute: (k) => (k === 'aria-label' ? label : null), textContent: '', dispatchEvent: () => true,
    click: () => { pressed.push(label); onClick(); } });
  const start = button('Start Voice', () => { live = true; });
  const end = button('End voice mode', () => { live = false; });
  const doc = pod.sandbox.document;
  const qsa = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => (sel === 'button' ? (live ? [end] : [start]) : qsa(sel));
  pod.sandbox.PointerEvent = class { constructor(type) { this.type = type; } };
  pod.sandbox.MouseEvent = class { constructor(type) { this.type = type; } };
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'voice', id: 'V1', conversationID: '0f8e7d6c-5b4a-4938-8271-605f4e3d2c1b' });
  const started = await pod.waitFor((r) => r.type === 'result' && r.id === 'V1', 8000);
  assert.equal(started.data.live, true);
  pod.command({ cmd: 'voiceState', id: 'V2' });
  assert.equal((await pod.waitFor((r) => r.type === 'result' && r.id === 'V2')).data.live, true);
  pod.command({ cmd: 'voice', id: 'V3', stop: true });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'V3');
  assert.deepEqual(pressed, ['Start Voice', 'End voice mode']);
  assert.equal(live, false);
});

test('pod script: the web sheet can open settings and ChatGPT pages', async () => {
  const pod = makePod({ responses: {} });
  pod.sandbox.location.hash = '';
  pod.sandbox.history.replaceState = () => {};
  pod.command({ cmd: 'navigate', id: 'N1', url: '/#settings' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'N1');
  assert.equal(pod.state.pathname, '/');
  assert.equal(pod.sandbox.location.hash, 'settings');
  pod.command({ cmd: 'navigate', id: 'N2', url: 'https://chatgpt.com/plugins' });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'N2');
  assert.equal(pod.state.pathname, '/plugins');
});

test('ChatGPT Space 09-25: no title top-left, Chinese composer, web-exact effort card, temporary chat top-right, photos drop and paste, ChatGPT typography', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const pages = read(app + 'TAP/ChatGPTPages.swift');
  const header = space.slice(space.indexOf('struct ChatGPTTopBarControls: View'), space.indexOf('struct ChatGPTSpaceMainPane: View'));
  assert.doesNotMatch(header, /Text\(model\.selectedTitle\)/);            // 左上角不放「新對話」
  // 臨時聊天照網頁在右上角、用網頁那顆虛線對話泡泡（09-25 對照網頁）；不再放在思考強度面板裡。
  assert.match(header, /model\.temporaryChat\.toggle\(\)/);
  assert.match(header, /ChatGPTTemporaryChatIcon\(active: model\.temporaryChat\)/);
  assert.doesNotMatch(pages, /Toggle\("臨時聊天"/);
  assert.match(header, /model\.requestShare\(conversationID: id, title: model\.selectedTitle\)/);
  assert.match(space, /placeholder: "想問什麼都可以"/);
  assert.match(space, /onPasteImage: \{ model\.attach\(from: \$0\) \}/);
  assert.match(space, /\.onDrop\(of: \[UTType\.fileURL, UTType\.image\], isTargeted: \$dropTargeted\)/);
  assert.match(space, /Button \{ model\.startVoice\(\) \} label: \{\s*Image\(systemName: "waveform"\)/);
  // 面板不是系統的 popover（有箭頭、灰底）：自己畫、浮在膠囊正上方；Esc 只關面板、不落到主視窗。
  assert.doesNotMatch(space, /\.popover\(isPresented: \$showsModelPopover/);
  assert.match(space, /\.overlayPreferenceValue\(ChatGPTPickerAnchorKey\.self\) \{ anchor in effortCard\(anchor\) \}/);
  assert.match(space, /ChatGPTEffortCard\(model: model\)/);
  assert.match(space, /guard event\.keyCode == 53, let window = event\.window, window\.isMainWindow, window\.attachedSheet == nil else \{ return event \}[\s\S]{0,120}return nil/);
  assert.match(space, /Text\("思考強度"\)\.foregroundStyle\(ChatGPTPalette\.tertiary\)/);
  assert.match(space, /let label = model\.pickerLabel/);
  // 網頁自己的數值（Pod 快取裡的 CSS）：面板寬 260、圓角 24；滑桿軌道高 24、圓鈕 28、兩端內縮 13；
  // 主題藍 #3A83F7、紫 #8952EE、軌道 #F3F3F3；最高檔的紫色漸層 #250e7a → #c775e9 55% → #7849d1。
  assert.match(pages, /static let width: CGFloat = 260/);
  assert.match(pages, /static let radius: CGFloat = 24/);
  assert.match(pages, /static let trackHeight: CGFloat = 24/);
  assert.match(pages, /static let thumb: CGFloat = 28/);
  assert.match(pages, /static let inset: CGFloat = 13/);
  assert.match(pages, /static let accent = dynamic\(0x3A83F7/);
  assert.match(pages, /static let purple = dynamic\(0x8952EE/);
  assert.match(pages, /static let track = dynamic\(0xF3F3F3/);
  assert.match(pages, /rgb\(0x250E7A\)[\s\S]{0,120}rgb\(0xC775E9\)\), location: 0\.55\)[\s\S]{0,120}rgb\(0x7849D1\)/);
  assert.match(pages, /ChatGPTEffortSlider\(/);
  assert.match(pages, /accessibilityAdjustableAction/);
  assert.match(pages, /"Extra High": "極高"/);
  assert.match(space, /\.environment\(\\\.chatTranscriptTypography, ChatGPTSpaceMainPane\.typography\)/);
  // 送出用的就是畫面上顯示的那一檔（沒特別選時＝ChatGPT 的「上次使用」）。
  assert.equal((space.match(/\n\s+let effort = effectiveEffortID\n/g) || []).length, 2);
  // 共用排版元件預設不變：Coder 不受影響。
  const flow = read(app + 'Chat/ChatPageLeafViews+TranscriptFlow.swift');
  assert.match(flow, /var scale: CGFloat = 1/);
  assert.match(flow, /typography: ChatTranscriptTypography = \.standard/);
  // 側欄：圖庫、排程、外掛、網站；左下帳號。
  assert.match(pages, /static let sidebar: \[ChatGPTPage\] = \[\.library, \.scheduled, \.plugins, \.sites\]/);
  assert.match(space, /ChatGPTAccountRow\(model: model\)/);
  // 照片拖進輸入框：只有 ChatGPT 的輸入框收「照片」App 的檔案承諾（Coder 不變）。
  const bridges = read(app + 'Chat/ChatPageAppKitBridges.swift');
  assert.match(bridges, /var acceptsPhotoDrags = false/);
  assert.match(space, /acceptsPhotoDrags: true/);
  // 剪貼簿只有圖片時，純文字輸入框會把「貼上」停用（09-25 實機：⌘V 沒反應的根因）→ 有附件管線就放行。
  assert.match(bridges, /override func validateUserInterfaceItem[\s\S]{0,200}item\.action == #selector\(paste\(_:\)\), onPasteImage != nil, Self\.carriesAttachment\(NSPasteboard\.general\)/);
  assert.match(bridges, /NSImage\.canInit\(with: pasteboard\)/);
  // ⌘V／「編輯 › 貼上」走選單驗證（validateMenuItem），也要放行（09-25 .021 實機：只改上面那個不夠）。
  assert.match(bridges, /override func validateMenuItem\(_ menuItem: NSMenuItem\) -> Bool \{\s*if menuItem\.action == #selector\(paste\(_:\)\), onPasteImage != nil, Self\.carriesAttachment\(NSPasteboard\.general\)/);
  assert.match(space, /\("public\.png", "貼上的圖片\.png", "image\/png"\)/);
});

test('TAP requests never pass an item id as "id" (the request id would overwrite it)', () => {
  const tapSource = read(app + 'TAP/ChatGPTTap.swift');
  const swiftPart = tapSource.slice(0, tapSource.indexOf('static let podScript'));
  const calls = [...swiftPart.matchAll(/request\("\w+", \[([^\]]*)\]/g)].map((m) => m[1]);
  assert.ok(calls.length > 10);
  for (const args of calls) assert.doesNotMatch(args, /(^|[\s,])"id":/, args);
});

test('pod script: account falls back to the sign-in name when the ChatGPT profile is unavailable', async () => {
  const pod = makePod({ responses: {
    '/backend-api/me': { json: { id: 'user-abc', name: 'Test User', email: 'user@example.invalid', picture: 'https://img.example/p.png' } },
    '/backend-api/calpico/chatgpt/profile/user-abc': () => new Response('{}', { status: 404, headers: { 'content-type': 'application/json' } }),
    '/backend-api/accounts/check/v4-2023-04-27': { json: { account_ordering: ['acc1'], accounts: { acc1: { account: { plan_type: 'plus', structure: 'personal' } } } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'account', id: 'A1' });
  const r = await pod.waitFor((x) => x.type === 'result' && x.id === 'A1');
  assert.equal(r.ok, true);
  assert.deepEqual(r.data, { name: 'Test User', email: 'user@example.invalid', picture: null, plan: 'plus' });
  noLeak(pod);
});

// 09-25：畫面上的檔位要跟 ChatGPT 伺服器記的「上次使用」一致（網頁、桌面版、手機共用）：web 優先、沒有才用 default，
// 強度一樣 default 之上蓋 web；對不到選單上的檔位就不猜。
test('pod script: the current preset comes from the server\'s last-used model config, the way the web reads it', async () => {
  const models = { json: { default_model_slug: 'sol', model_picker_version: 2,
    versions: [
      { id: 'latest', display_text_full: 'Latest', enabled: true, slugs: ['sol-i', 'sol-t', 'sol-pro'],
        intelligence_presets: [{ title: 'Instant', model_slug: 'sol-i', lane: 'instant' },
          { title: 'High', model_slug: 'sol-t', thinking_effort: 'extended', lane: 'thinking' },
          { title: 'Extra High', model_slug: 'sol-t', thinking_effort: 'max', lane: 'thinking' },
          { title: 'Pro', model_slug: 'sol-pro', lane: 'pro', selected_display_version: '6', show_version_in_latest: true }] },
      { id: '5.5', display_text_full: 'Legacy • 5.5', enabled: true, slugs: ['old-t'],
        intelligence_presets: [{ title: 'High', model_slug: 'old-t', thinking_effort: 'extended', lane: 'thinking', selected_display_version: '5.5' }] },
    ],
    models: [{ slug: 'sol-i', title: 'Sol', reasoning_type: 'none' }, { slug: 'sol-t', title: 'Sol', reasoning_type: 'reasoning' },
      { slug: 'sol-pro', title: 'Sol Pro', reasoning_type: 'pro' }, { slug: 'old-t', title: 'Old', reasoning_type: 'reasoning' }] } };
  const run = async (settings) => {
    const pod = makePod({ responses: { '/backend-api/models': models, '/backend-api/settings/user': { json: { settings } } } });
    await pod.signIn();
    await pod.waitFor((r) => r.type === 'auth');
    pod.command({ cmd: 'models', id: 'C' });
    const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'C');
    assert.equal(res.ok, true, res.message);
    return res.data;
  };
  const pro = await run({ last_used_model_config: { slugs: { web: 'sol-pro', default: 'sol-t' },
    juices: { default: { 'sol-t': 'extended', 'sol-pro': 'standard' }, web: { 'sol-t': 'max' } } } });
  assert.deepEqual(pro.current, { version: 'latest', preset: 'sol-pro' });
  // Pro 是最高檔、名字帶版本（6 Pro）；最新版的 High 不帶；舊版一律帶（5.5 High）。
  const latest = pro.versions[0].presets;
  assert.deepEqual(latest.map((x) => [x.id, x.max, x.showVersion]), [
    ['sol-i', false, false], ['sol-t|extended', false, false], ['sol-t|max', false, false], ['sol-pro', true, true]]);
  assert.deepEqual(pro.versions[1].presets.map((x) => [x.id, x.showVersion]), [['old-t|extended', true]]);
  const thinking = await run({ last_used_model_config: { slugs: { default: 'sol-t' },
    juices: { default: { 'sol-t': 'extended' }, web: { 'sol-t': 'max' } } } });
  assert.deepEqual(thinking.current, { version: 'latest', preset: 'sol-t|max' });
  const legacy = await run({ last_used_model_config: { slugs: { web: 'old-t' }, juices: { web: { 'old-t': 'extended' } } } });
  assert.deepEqual(legacy.current, { version: '5.5', preset: 'old-t|extended' });
  assert.equal((await run({ last_used_model_config: { slugs: { web: 'gone' } } })).current, null);
  assert.equal((await run({})).current, null);
});

// 09-25 實機：對話分享是 /share/<編號>。DELETE /share/post/ 會 404；只 PATCH 成不公開，公開頁照樣打得開；
// 網頁「已分享的連結」的垃圾桶是 DELETE /share/{編號}。刪掉的公開頁仍回 200，但標題不再是「ChatGPT - 對話標題」。
test('pod script: stop sharing deletes a conversation share like the web\'s Shared links trash and checks the public page', async () => {
  const pod = makePod({ responses: {
    '/backend-api/share/conv-1234': { json: {} },
    '/share/conv-1234': () => new Response('<html><head><title>ChatGPT</title></head><body>This shared link has been deleted.</body></html>', { status: 200 }),
    '/backend-api/share/post/post-5678': { json: {} },
    '/s/post-5678': () => new Response('<html><head><title>ChatGPT - 還在</title></head></html>', { status: 200 }),
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  const call = async (extra) => {
    const id = 'SD' + Math.random();
    pod.command({ cmd: 'shareDelete', id, ...extra });
    return pod.waitFor((x) => x.type === 'result' && x.id === id);
  };
  const conv = await call({ shareID: 'conv-1234', kind: 'share' });
  assert.equal(conv.ok, true, conv.message);
  assert.equal(conv.data.gone, true);
  const del = pod.requests.find((r) => r.url.endsWith('/backend-api/share/conv-1234'));
  assert.equal(del.init.method, 'DELETE');
  const page = pod.requests.find((r) => r.url.endsWith('/share/conv-1234') && !r.url.includes('backend-api'));
  assert.equal(page.init.credentials, 'omit');
  const post = await call({ shareID: 'post-5678', kind: 's' });
  assert.equal(post.ok, true, post.message);
  assert.equal(post.data.gone, false);            // 公開頁標題還是「ChatGPT - …」→ App 提示再按一次
  assert.equal(pod.requests.find((r) => r.url.endsWith('/backend-api/share/post/post-5678')).init.method, 'DELETE');
  const bad = await call({ shareID: '../x', kind: 'share' });
  assert.equal(bad.ok, false);
  noLeak(pod);
});


// 09-25 使用者「mcp的部分無法點擊進去」：外掛詳細頁（GET /ps/plugins/{id}）＋連接器工具（GET /aip/connectors/{id}/actions），
// 讀取／寫入照網頁的分法；停用、私人、同名的工具不列；連結只收 https。
test('pod script: plugin detail maps the web\'s plugin page and splits connector tools into read and write like the web', async () => {
  const pod = makePod({ responses: {
    '/backend-api/ps/plugins/plugin_gh': { json: {
      id: 'plugin_gh', name: 'github', connector_id: 'connector_gh', creator_name: 'OpenAI',
      release: { display_name: 'GitHub', description: 'repos', interface: {
        short_description: 'Triage PRs', long_description: 'Work with issues and pull requests.', developer_name: 'GitHub, Inc.',
        category: 'Developer Tools', capabilities: ['Interactive', 'Write'], default_prompts: ['Summarize my open PRs'],
        website_url: 'https://github.com', privacy_policy_url: 'http://insecure.example', terms_of_service_url: 'https://github.com/terms',
        logo_url: 'https://cdn.example/gh.png', screenshot_urls: ['https://cdn.example/1.png', 'javascript:alert(1)'] },
        skills: [{ name: 'triage', description: 'x', interface: { display_name: 'Triage', short_description: 'Sort issues' } }] } } },
    '/backend-api/aip/connectors/connector_gh/actions': { json: { actions: [
      { name: 'search_repos', description: 'Search repositories', is_read_only: true },
      { name: 'create_issue', description: 'Create an issue', is_consequential: true },
      { name: 'delete_branch', description: 'Delete a branch', is_destructive: true },
      { name: 'list_prs', description: 'List PRs', is_consequential: false },
      { name: 'hidden', is_enabled: false }, { name: 'secret', visibility: 'private' }, { name: 'search_repos', description: 'dup' }] } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'pluginDetail', id: 'PD', pluginID: 'plugin_gh' });
  const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'PD');
  assert.equal(res.ok, true, res.message);
  const d = res.data;
  assert.equal(d.name, 'GitHub');
  assert.equal(d.developer, 'GitHub, Inc.');
  assert.equal(d.category, 'Developer Tools');
  assert.equal(d.summary, 'Triage PRs');
  assert.equal(d.about, 'Work with issues and pull requests.');
  assert.deepEqual(d.capabilities, ['Interactive', 'Write']);
  assert.deepEqual(d.prompts, ['Summarize my open PRs']);
  assert.equal(d.website, 'https://github.com');
  assert.equal(d.privacy, null);                                   // 只收 https
  assert.deepEqual(d.screenshots, ['https://cdn.example/1.png']);
  assert.deepEqual(d.skills, [{ name: 'Triage', description: 'Sort issues' }]);
  assert.deepEqual(d.tools.map((x) => [x.name, x.read, x.destructive]), [
    ['search_repos', true, false], ['create_issue', false, false], ['delete_branch', false, true], ['list_prs', true, false]]);
  assert.equal(d.tools_state, 'ok');
  assert.equal(pod.requests.find((r) => r.url.includes('/backend-api/ps/plugins/plugin_gh')).init.headers['oai-language'], 'zh-TW');
  pod.command({ cmd: 'pluginDetail', id: 'PB', pluginID: '../x' });
  assert.equal((await pod.waitFor((r) => r.type === 'result' && r.id === 'PB')).ok, false);
  noLeak(pod);
});

// 09-25：外掛商店繁中＝全域翻譯索引（參考 ClaudeTW 的常駐索引，缺的用 Apple 裝置端翻譯補）；附件照 ChatGPT 的方塊。
test('ChatGPT Space 09-25: clickable plugins, native detail page, zh-Hant via the global translation index, ChatGPT attachment tiles', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const pages = read(app + 'TAP/ChatGPTPages.swift');
  const index = read(app + 'Translation/TranslationIndex.swift');
  // 外掛：列與已安裝圖示都能點進詳細頁；詳細頁是原生畫面。
  assert.match(pages, /Button \{ model\.openPlugin\(plugin\) \}/);
  assert.match(pages, /if let target = model\.pluginDetailTarget \{[\s\S]{0,200}ChatGPTPluginDetailView\(model: model, plugin: target\)/);
  for (const token of ['"說明"', '"能力"', '"試試看"', '讀取工具（', '寫入工具（', '技能（', '"截圖"', '"資訊"', 'model.closePlugin()'])
    assert.ok(pages.includes(token), token);
  // 繁中：外掛頁掛翻譯主機；說明走索引；外掛名稱不翻。
  assert.match(pages, /\.modifier\(TranslationIndexHost\(\)\)/);
  assert.match(pages, /Text\(index\.text\(plugin\.detail, keeping: \[plugin\.name\]\)\)/);
  assert.match(pages, /Text\(plugin\.name\)\.font/);
  // 翻譯索引：常駐查表、固定用語、只翻英文、Apple 裝置端翻譯、只寫自己的索引檔。
  assert.match(index, /static let glossary: \[String: String\] = \[/);
  assert.match(index, /"Developer Tools": "開發工具"/);
  assert.match(index, /recognizer\.dominantLanguage == \.english/);
  assert.match(index, /session\.translations\(from: requests\)/);
  assert.match(index, /appendingPathComponent\("TATWO OS\/Translation\/zh-Hant\.json"\)/);
  assert.equal((index.match(/\.write\(to:/g) || []).length, 1);
  assert.match(index, /沒有對話內容/);
  // 對話畫面不用翻譯索引（對話內容不進索引）。
  assert.doesNotMatch(space, /TranslationIndex|index\.text\(/);
  const outsideCatalog = pages.slice(0, pages.indexOf('struct ChatGPTPluginsView')) + pages.slice(pages.indexOf('struct ChatGPTTranslationNote'));
  assert.doesNotMatch(outsideCatalog.replace(/struct ChatGPTTranslationNote[\s\S]*?\n}\n/, ''), /index\.text\(/);
  // 附件：圖片 144 方形縮圖、檔案 240 寬的檔案卡、滑過才出現 ×；送出鈕照 ChatGPT 黑色圓鈕。
  assert.match(pages, /static let imageSize: CGFloat = 144/);
  assert.match(pages, /static let fileWidth: CGFloat = 240/);
  assert.match(pages, /\.opacity\(hovering \? 1 : 0\)/);
  assert.equal((pages.match(/\.accessibilityAction\(named: "移除", remove\)/g) || []).length, 2);   // × 隱藏時 VoiceOver／鍵盤也能移除
  assert.match(space, /ChatGPTAttachmentTile\(file: file\) \{ model\.removeAttachment\(file\.id\) \}/);
  assert.match(space, /ChatGPTSendButton\(enabled: model\.canSend\) \{ model\.send\(\) \}/);
});


// 09-25 使用者 #125「上方chatgpt的空間空太多 文字都被擠在下面」：視窗裡不再多一條 34pt 空帶＋48pt 標題列；
// 臨時聊天／分享／⋯ 跟 ChatGPT 桌面版一樣放在紅綠燈那一列的右上（拖曳區本來就讓出那塊）。
test('ChatGPT Space 09-25 #125: top-right controls live in the traffic-light row, no extra header band in the window', () => {
  const panels = read(app + 'Chat/ChatPage+Panels.swift');
  const page = read(app + 'Chat/ChatPage.swift');
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  assert.match(panels, /ChatGPTSpaceMainPane\(model: ChatGPTSpaceModel\.shared, showsHeader: surface != \.window\)\s*\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)/);
  assert.doesNotMatch(panels, /ChatGPTSpaceMainPane\([^)]*\)\s*\.padding\(\.top, surface == \.window \? WindowChromeMetrics\.bandHeight/);
  assert.match(page, /else if !isPanel && model\.mode == \.chatgpt \{[\s\S]{0,400}ChatGPTTopBarControls\(model: ChatGPTSpaceModel\.shared\)\s*\.frame\(height: 26\)\s*\.padding\(\.trailing, 14\)\s*\.offset\(y: -WindowChromeMetrics\.chromeRowLift\)/);
  // 小面板沒有紅綠燈那一列才在對話上方放一列；視窗裡對話直接從那一列下面開始。
  assert.match(space, /if showsHeader \{ header \}/);
  assert.match(space, /\.padding\(\.top, showsHeader \? 8 : 16\)/);
  // 其他頁與需要登入時不顯示右上的鈕。
  const controls = space.slice(space.indexOf('struct ChatGPTTopBarControls: View'), space.indexOf('struct ChatGPTSpaceMainPane: View'));
  assert.match(controls, /if model\.page == nil, tap\.connection != \.needsLogin \{/);
  // 寬度放得進拖曳區讓出的頂右那塊（chatRightControlsReserve 130）：最多三顆 ≤ 36pt 的鈕。
  assert.equal((controls.match(/\.frame\(width: (28|36), height: (28|36)\)/g) || []).length, 3);
});


// 09-25 實機（使用者 #125 截圖裡的「OpenAIHelpCenter」「TATWOMCP」、### 與 ** 沒套上）：ChatGPT 的來源註腳
// （sources_footnote）引用位置就是一個空格；以前把每個引用位置「全文替換」，整則回答的空格就被刪光。
test('pod script: a sources footnote whose matched text is a space does not delete every space in the answer', async () => {
  const cite = 'citeturn0search3';
  const answer = '### 四、降到 Plus 能不能得到 Codex 的效果？\n\n**第一，Plus 的 MCP 讀寫權限要實測。** 官方文件寫的是 Secure MCP Tunnel' + cite + '。';
  const pod = makePod({ responses: {
    '/backend-api/conversation/fn': { json: { current_node: 'a1', mapping: {
      u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['問'] } }, parent: null, children: ['a1'] },
      a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: [answer] },
        metadata: { content_references: [
          { matched_text: cite, alt: '([OpenAI Help Center](https://help.openai.com/))', type: 'grouped_webpages', items: [{ title: 'OpenAI Help Center', url: 'https://help.openai.com/' }] },
          { matched_text: ' ', start_idx: answer.length, end_idx: answer.length, alt: '', type: 'sources_footnote', sources: [{ title: 'OpenAI Help Center', url: 'https://help.openai.com/' }] },
          { matched_text: '【3†source】', alt: '', type: 'legacy' },
        ] } }, parent: 'u1', children: [] },
    } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'get', id: 'F', conversationID: 'fn' });
  const got = await pod.waitFor((r) => r.type === 'result' && r.id === 'F');
  const text = got.data.messages[1].text;
  assert.equal(text, '### 四、降到 Plus 能不能得到 Codex 的效果？\n\n**第一，Plus 的 MCP 讀寫權限要實測。** 官方文件寫的是 Secure MCP Tunnel([OpenAI Help Center](https://help.openai.com/))。');
  assert.match(text, /^### /);
  assert.doesNotMatch(text, /[-]/);
});


// 09-25 使用者 #126「chatgpt對話圖片預覽操作不好 例如點空白退出 畫面比例也不好看 應參考coder的圖片預覽」：
// 對話與圖庫的圖片放大都改用 Coder 的圖片預覽（ChatImagePreviewSurface）。
test('ChatGPT Space 09-25 #126: image zoom reuses Coder\'s image preview (tap blank or Esc closes, fit ratio, download, gallery)', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const pages = read(app + 'TAP/ChatGPTPages.swift');
  const surface = read(app + 'Chat/ChatAttachmentPreviewSurface.swift');
  // 視窗裡是整個視窗的燈箱（ChatPage 畫，#128）；小面板維持表單。
  assert.match(space, /\.sheet\(isPresented: Binding\(get: \{ showsHeader && model\.zoomedImage != nil \}, set: \{ if !\$0 \{ model\.closeZoom\(\) \} \}\)\) \{\s*if let image = model\.zoomedImage \{\s*ChatGPTImagePreview\(model: model, image: image, inSheet: true\)/);
  assert.match(read(app + 'Chat/ChatPage.swift'), /if model\.mode == \.chatgpt && !isPanel && !showSettingsPage \{\s*ChatGPTImageLightbox\(model: ChatGPTSpaceModel\.shared\)/);
  const lightbox = pages.slice(pages.indexOf('struct ChatGPTImageLightbox: View'), pages.indexOf('struct ChatGPTSendButton: View'));
  assert.match(lightbox, /ChatGPTImagePreview\(model: model, image: image\)\s*\.ignoresSafeArea\(\)/);   // 連紅綠燈那一條也蓋住
  assert.match(lightbox, /guard event\.keyCode == 53, model\.zoomedImage != nil, let window = event\.window, window\.isMainWindow,\s*window\.attachedSheet == nil else \{ return event \}\s*model\.closeZoom\(\)\s*return nil/);
  assert.doesNotMatch(space, /Button\("完成"\) \{ model\.zoomedImage = nil \}/);
  const preview = pages.slice(pages.indexOf('struct ChatGPTImagePreview: View'), pages.indexOf('struct ChatGPTSendButton: View'));
  assert.match(preview, /ChatImagePreviewSurface\(/);
  assert.match(preview, /close: \{ model\.closeZoom\(\) \}/);
  assert.match(preview, /save: \{ model\.downloadZoomedImage\(\) \}/);
  assert.match(preview, /\.frame\(minWidth: inSheet \? 560 : nil, idealWidth: inSheet \? 900 : nil, maxWidth: inSheet \? nil : \.infinity,/);   // 表單跟 Coder 同尺寸、燈箱填滿視窗
  // Coder 的預覽：點深色空白處關閉、Esc 關閉、圖片等比縮到放得下。
  assert.match(surface, /Color\.black\.opacity\(0\.88\)\s*\.contentShape\(Rectangle\(\)\)\s*\.onTapGesture\(perform: close\)/);
  assert.match(surface, /\.onExitCommand\(perform: close\)/);
  assert.match(surface, /let ratio = min\(size\.width \/ max\(1, imageSize\.width\),/);
  // 圖片旁邊的空白（可捲動的檢視區）點了也關；點圖片本身不關（.027 實機：以前只有最外圈能點）。
  assert.match(surface, /ZStack \{[\s\S]{0,200}Color\.clear\s*\.contentShape\(Rectangle\(\)\)\s*\.onTapGesture\(perform: close\)[\s\S]{0,120}image\.resizable\(\)/);
  // 同一則訊息的圖可以左右切換。
  assert.equal((space.match(/gallery: message\.images\.map\(\\\.id\)/g) || []).length, 2);
  assert.match(space, /func moveZoom\(_ offset: Int\)/);
});


// 09-25 .026 實機：Apple 繁中把品牌名與技術詞翻壞（Desktop Commander→桌面指揮官、Ping→砰、Markdown→降價、repo→回購），
// 也常出現大陸用語；第二個外掛的詳細頁沿用上一頁的捲動位置。
test('ChatGPT Space 09-25: translation keeps brand and tech terms, uses Taiwan wording, tool names stay English, detail opens at top', () => {
  const index = read(app + 'Translation/TranslationIndex.swift');
  const pages = read(app + 'TAP/ChatGPTPages.swift');
  // 不翻的詞：送去翻前換成暫代字、翻完換回；暫代字不見就不收（先顯示原文），也不再排隊（避免每次重畫都重送）。
  for (const term of ['"Markdown"', '"ping"', '"repo"', '"MCP"']) assert.ok(index.includes(term), term);
  assert.match(index, /static func protect\(_ text: String, keeping extra: \[String\]\)/);
  assert.match(index, /guard out\.contains\(token\) else \{ return nil \}/);
  assert.match(index, /rejected\.insert\(batch\[index\]\)/);
  assert.match(index, /guard !rejected\.contains\(key\), Self\.needsTranslation\(key\)/);
  // 台灣用語。
  for (const pair of ['("訪問", "存取")', '("計算機", "電腦")', '("構建", "建置")', '("幻燈片", "簡報")', '("收件箱", "收件匣")', '("影象", "影像")'])
    assert.ok(index.includes(pair), pair);
  // 規則改了舊譯文重翻；短的英文（Fetch）也翻。
  assert.match(index, /object\["schema"\] as\? Int == Self\.schema/);
  assert.match(index, /static let schema = 2/);
  assert.match(index, /unicodeScalars\.allSatisfy\(\\\.isASCII\)/);
  // 畫面：外掛名稱與開發者不翻；工具名稱保留英文；詳細頁換外掛就從頂端開始。
  assert.match(pages, /private var brand: \[String\] \{ \[plugin\.name, detail\?\.name \?\? "", detail\?\.developer \?\? ""\]/);
  assert.match(pages, /Text\(Self\.toolTitle\(tool\.name\)\)\.font/);
  assert.doesNotMatch(pages, /index\.text\(Self\.toolTitle/);
  assert.match(pages, /ChatGPTPluginDetailView\(model: model, plugin: target\)\.id\(target\.id\)/);
  assert.match(pages, /\.onAppear \{ proxy\.scrollTo\("pluginDetail\.top", anchor: \.top\) \}/);
});


// 09-25 使用者 #127「對話圖片太大張」：寬度照網頁（imagegen-image：直式 max-w-[400px]、其他 max-w-[480px]），
// 再加高度上限 400；自己上傳的圖在 240×240 的框內。
test('ChatGPT Space 09-25 #127: conversation images follow the web width rule and a 400pt height cap', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const view = space.slice(space.indexOf('struct ChatGPTImageView: View'), space.indexOf('struct ChatGPTUserMessageView: View'));
  assert.match(view, /var maxHeight: CGFloat = 400/);
  assert.match(view, /let widthCap = aspect < 1 \? min\(maxWidth, 400\) : maxWidth/);
  assert.match(view, /let height = min\(widthCap \/ aspect, maxHeight\)/);
  assert.equal((view.match(/\.frame\(maxWidth: box\.width, maxHeight: box\.height\)/g) || []).length, 2);
  assert.match(space, /ChatGPTImageView\(model: model, image: image, maxWidth: 240, maxHeight: 240, gallery:/);
  assert.match(space, /ChatGPTImageView\(model: model, image: image, maxWidth: 480, gallery:/);
});

// 09-25 使用者「chatgpt的載入速度需要加快」：分頁打開時各區塊同時要、開過的對話留在記憶體、滑過就預載、App 開好就在背景預熱。
test('ChatGPT Space 09-25: faster loading — parallel refresh, in-memory conversation cache, hover prefetch, launch prewarm', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const tap = read(app + 'TAP/ChatGPTTap.swift');
  const shell = read(app + 'Shell/AppShell.swift');
  const refresh = space.slice(space.indexOf('    func refresh() async {'), space.indexOf('    func prewarm() {'));
  // 清單以外的都用各自的 Task 同時要，不再 await 一個等一個。
  for (const call of ['tap.pinned()', 'tap.projects()', 'tap.models()', 'tap.tools()', 'tap.gpts()', 'tap.home()'])
    assert.match(refresh, new RegExp('Task \\{[^\\n]*' + call.replace(/[()\.]/g, (c) => '\\' + c) + '|Task \\{\\s*guard [^\\n]*' + call.replace(/[()\.]/g, (c) => '\\' + c)), call);
  assert.doesNotMatch(refresh, /for id in expandedProjects \{ await loadProject\(id\) \}/);
  // 快取只在記憶體、有上限；開過的先顯示再拿最新的；預載中的就等它。
  assert.match(space, /private var messageCache: \[String: \[TapMessage\]\] = \[:\]/);
  assert.match(space, /static let cacheLimit = 30/);
  assert.match(space, /let cached = messageCache\[id\]\s*messages = cached \?\? \[\]\s*isLoadingMessages = cached == nil/);
  assert.match(space, /if reuseInFlight, let running = messageLoads\[id\] \{ return await running\.value \}/);
  assert.match(space, /while messageCacheOrder\.count > Self\.cacheLimit/);
  // 滑過 0.15 秒才預載。
  assert.match(space, /try\? await Task\.sleep\(for: \.milliseconds\(150\)\)\s*guard !Task\.isCancelled else \{ return \}\s*model\.prefetch\(item\.id\)/);
  // 預熱：登入過才做、不在畫面上才排休眠；App 開好 6 秒後叫。
  assert.match(space, /guard ChatGPTTap\.isEnabled, ChatGPTTap\.hasBeenReady, !visible, !tap\.pod\.isRunning else \{ return \}/);
  assert.match(tap, /UserDefaults\.standard\.set\(true, forKey: Self\.readyOnceKey\)/);
  assert.match(shell, /DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 6\) \{ ChatGPTSpaceModel\.shared\.prewarm\(\) \}/);
  // 對話內容不落地（快取只在記憶體）。
  const cacheCode = space.slice(space.indexOf('private func loadMessages('), space.indexOf('func prefetch('));
  assert.doesNotMatch(cacheCode, /write\(to:|FileManager|UserDefaults/);
});


// 09-25 使用者 #130「專案開新對話失敗」：網頁在某些情況（f_completion 沒開）送到舊的 /backend-api/conversation，
// 以前只攔 /f/conversation；從專案送出時網頁也沒帶 conversation_mode，對話建成一般對話。
test('pod script: the old /backend-api/conversation send path is intercepted too, and project sends carry conversation_mode', async () => {
  const sse = [
    'event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "a1", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": [""]}, "status": "in_progress"}, "conversation_id": "c77"}, "c": 0}\n\n',
    'event: delta\ndata: {"p": "/message/content/parts/0", "o": "append", "v": "好"}\n\n',
    'data: [DONE]\n\n',
  ];
  const pod = makePod({ sendPath: '/backend-api/conversation', responses: { '/backend-api/conversation': { sse } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'P', text: '專案裡問', model: 'gpt-x', gizmoID: 'g-p-abc123' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'P' && r.kind === 'finished');
  assert.equal(pod.state.pathname, '/g/g-p-abc123/project');
  const post = pod.requests.find((r) => r.url.endsWith('/backend-api/conversation'));
  const body = JSON.parse(post.init.body);
  assert.equal(body.model, 'gpt-x');
  assert.deepEqual(body.conversation_mode, { kind: 'gizmo_interaction', gizmo_id: 'g-p-abc123' });
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'P');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === 'c77'));
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, '好');
  pod.command({ cmd: 'diagnostics', id: 'D' });
  const diag = (await pod.waitFor((r) => r.type === 'result' && r.id === 'D')).data;
  assert.equal(diag['送出路徑'], '/conversation');
  assert.match(diag['專案／GPT'], /已補上 conversation_mode/);
  // 一般對話（沒有專案）不加 conversation_mode。
  pod.command({ cmd: 'send', id: 'Q', text: '一般', model: 'gpt-x' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'Q' && r.kind === 'finished');
  const plain = pod.requests.filter((r) => r.url.endsWith('/backend-api/conversation')).at(-1);
  assert.equal('conversation_mode' in JSON.parse(plain.init.body), false);
  noLeak(pod);
});

// 09-25 使用者 #131「語音模式失敗」（找不到語音鈕）：網頁輸入框有字時語音鈕會換成送出鍵；先清空再找。
test('pod script: voice clears leftover text in the page composer before looking for the speech button', async () => {
  let started = false;
  const pod = makePod({ responses: {}, setup(sandbox) {
    const box = { innerText: '上次沒送出的字', focus() {} };
    const speech = { getAttribute: (k) => (k === 'data-testid' ? 'composer-speech-button' : k === 'aria-label' ? '開始語音' : null), click() { started = true; } };
    const end = { getAttribute: (k) => (k === 'aria-label' ? 'End voice mode' : null), click() {} };
    const doc = sandbox.document;
    const baseQuery = doc.querySelector.bind(doc);
    doc.querySelector = (selector) => {
      if (selector === '#prompt-textarea') return box;
      if (selector === '[data-testid="composer-speech-button"]') return box.innerText ? null : speech;
      return baseQuery(selector);
    };
    const baseAll = doc.querySelectorAll.bind(doc);
    doc.querySelectorAll = (selector) => (selector === 'button' ? (started ? [end] : []) : baseAll(selector));
    const baseExec = doc.execCommand.bind(doc);
    doc.execCommand = (command, ui, value) => { if (command === 'delete') { box.innerText = ''; return true; } return command === 'selectAll' ? true : baseExec(command, ui, value); };
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'voice', id: 'V' });
  const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'V', 12000);
  assert.equal(res.ok, true, res.message);
  assert.equal(res.data.live, true);
  assert.equal(started, true);
  pod.command({ cmd: 'diagnostics', id: 'D2' });
  const diag = (await pod.waitFor((r) => r.type === 'result' && r.id === 'D2')).data;
  assert.equal(diag['語音輸入框'], '原本有字，已清空');
  noLeak(pod);
});

// 09-25 使用者「chatgpt的回覆會有通知 但是os內建目前缺少通知 我們其實是需要有各space的通知功能的」：
// 各 Space 共用的 SpaceNotice（Island 提示卡、每個 Space 各自開關、只放標題不放內容）；ChatGPT 回覆好了先接上。
test('Space notices: shared SpaceNotice via Island, per-Space switch, ChatGPT posts when you are not on that conversation', () => {
  const notice = read(app + 'Space/SpaceNotice.swift');
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const settings = read(app + 'TAP/TapSettingsView.swift');
  assert.match(notice, /IslandNotice\.shared\.info\(title: title, detail: detail\)/);
  assert.match(notice, /static func key\(_ space: String\) -> String \{ "tatwo\.space\.\\\(space\)\.notify" \}/);
  assert.match(notice, /as\? Bool \?\? true/);                              // 預設開
  assert.doesNotMatch(notice, /UNUserNotificationCenter|write\(to:|FileManager/); // 不寫系統通知中心、不寫檔
  assert.match(space, /!\(NSApp\.isActive && visible && page == nil && selectedID == conversationID\)/);
  assert.match(space, /SpaceNotice\.post\(space: Self\.noticeSpace, title: "ChatGPT 回覆好了", detail: title\)/);
  const post = space.slice(space.indexOf('// 回覆好了：你不在這則對話上'), space.indexOf('SpaceNotice.post('));
  assert.doesNotMatch(post, /messages\.|\.text/);                              // 只放對話名稱，不放回覆內容
  assert.match(settings, /SpaceNotice\.setEnabled\(ChatGPTSpaceModel\.noticeSpace, \$0\)/);
  assert.match(settings, /accessibilityIdentifier\("tap\.chatgpt\.notify"\)/);
});

// 憲法 v4.2 草稿第 7 條「對話與訊息內容不落地」：Pod 讀對話不進瀏覽器快取；每次開 App 第一次啟動前清掉快取（登入不動）。
test('pod privacy: backend-api reads are no-store, and the Pod HTTP cache is purged before the first start each launch', async () => {
  const pod = makePod({ responses: { '/backend-api/conversations': { json: { total: 0, items: [] } } } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'list', id: 'L', offset: 0, limit: 5 });
  await pod.waitFor((r) => r.type === 'result' && r.id === 'L');
  const reads = pod.requests.filter((r) => r.url.includes('/backend-api/') && ((r.init && r.init.method) || 'GET') === 'GET');
  assert.ok(reads.length >= 2);
  assert.ok(reads.every((r) => r.init && r.init.cache === 'no-store'), 'every backend-api GET is no-store');
  const tapSource = read(app + 'TAP/ChatGPTTap.swift');
  assert.match(tapSource, /TapPodStorage\.purgeHTTPCacheOnce\(profileID: Self\.profileID\)\s*do \{\s*try pod\.start\(\)/);
  const storage = read(app + 'Browser/TapPodStorage.swift');
  assert.match(storage, /guard purged\.insert\(profileID\)\.inserted else \{ return \}/);
  assert.match(storage, /profile\.lastPathComponent\.contains\(profileID\.uuidString\.lowercased\(\)\)/);
  assert.match(storage, /appendingPathComponent\("Cache", isDirectory: true\)/);   // 只清 HTTP 快取
  const code = storage.split('\n').filter((l) => !l.trim().startsWith('///') && !l.trim().startsWith('//')).join('\n');
  assert.doesNotMatch(code, /Cookies|Local Storage|IndexedDB/);   // 程式只碰 HTTP 快取，登入資料不動
});

// 09-25 實機：專案裡用 6 Pro，回答轉線（stream_handoff）在伺服器上慢慢想；送出的串流很快結束，
// 以前就此判定「沒有收到回覆」。改成讀對話直到最新一則回答完成。
test('pod script: a handed-off answer is polled from the conversation until it finishes', async () => {
  const handoff = [
    'event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "u1", "author": {"role": "user"}, "content": {"content_type": "text", "parts": ["想一下"]}, "status": "finished_successfully"}, "conversation_id": "cpro"}, "c": 0}\n\n',
    'data: {"type": "stream_handoff", "conversation_id": "cpro", "options": {"transport": "pubsub"}}\n\n',
    'data: [DONE]\n\n',
  ];
  let polls = 0;
  const convo = (done) => ({ current_node: done ? 'a1' : 'u1', mapping: {
    u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['想一下'] }, status: 'finished_successfully' }, parent: null, children: done ? ['a1'] : [] },
    ...(done ? { a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['想好了'] }, status: 'finished_successfully', end_turn: true }, parent: 'u1', children: [] } } : {}),
  } });
  const pod = makePod({ responses: {
    '/backend-api/f/conversation': { sse: handoff },
    '/backend-api/conversation/cpro': () => { polls += 1; return new Response(JSON.stringify(convo(polls >= 2)), { status: 200, headers: { 'content-type': 'application/json' } }); },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'H2', text: '想一下', model: 'gpt-x-pro' });
  const finished = await pod.waitFor((r) => r.type === 'stream' && r.id === 'H2' && r.kind === 'finished', 15000);
  assert.ok(polls >= 2, 'kept polling until the answer finished');
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'H2');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === 'cpro'));
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, '想好了');
  assert.ok(!events.some((e) => e.kind === 'failed'));
  assert.match(finished.shape, /poll×/);
  noLeak(pod);
});

test('ChatGPT Space: you can browse other conversations while a long answer runs; an old send cannot pull the view back', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  assert.match(space, /func select\(_ id: String\) \{\s*guard id != selectedID \|\| page != nil else \{ return \}/);
  assert.doesNotMatch(space.slice(space.indexOf('func newChat(with gpt'), space.indexOf('var canSend: Bool')), /guard !isSending/);
  assert.match(space, /if selectedID == nil, viewEpoch == epoch \{ selectedID = id \}/);
  assert.match(space, /tap\.connection == \.ready && !isSending/);   // 送出中還是不能送第二則
});

// 09-25 實機：送出的串流 0 個事件（回答走 pubsub）；知道對話編號就改讀對話等答案。
test('pod script: an empty send stream with a known conversation falls back to polling the conversation', async () => {
  let polls = 0;
  const done = () => ({ current_node: 'a1', mapping: {
    u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['問'] }, status: 'finished_successfully' }, parent: null, children: ['a1'] },
    a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['答好了'] }, status: 'finished_successfully', end_turn: true }, parent: 'u1', children: [] },
  } });
  const pod = makePod({
    responses: {
      '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
      '/backend-api/conversation/0f1e2d3c-4b5a-4987-8765-43210fedcba9': () => { polls += 1; return new Response(JSON.stringify(done()), { status: 200, headers: { 'content-type': 'application/json' } }); },
    },
    onSendClick(state) { state.pathname = '/c/0f1e2d3c-4b5a-4987-8765-43210fedcba9'; },
  });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'Z', text: '問' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'Z' && r.kind === 'finished', 15000);
  assert.ok(polls >= 1);
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'Z');
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, '答好了');
  noLeak(pod);
});

// 09-25 實機 .035：專案裡用 6 Pro，串流 0 個事件、網頁畫面上只有「Pro thinking」；不能把它當答案提早收工。
test('pod script: a placeholder on the page ("Pro thinking") does not end an empty-stream turn; the server answer does', async () => {
  let polls = 0;
  const convo = (finished) => ({ current_node: 'a1', mapping: {
    u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['請只回覆 OK'] }, status: 'finished_successfully' }, parent: null, children: ['a1'] },
    a1: { message: { id: 'a1', author: { role: 'assistant' }, create_time: Date.now() / 1000,
      content: { content_type: 'text', parts: [finished ? 'OK' : ''] }, status: finished ? 'finished_successfully' : 'in_progress',
      end_turn: finished ? true : null }, parent: 'u1', children: [] },
  } });
  const pod = makePod({
    responses: {
      '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
      '/backend-api/conversation/5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d': () => { polls += 1;
        return new Response(JSON.stringify(convo(polls >= 2)), { status: 200, headers: { 'content-type': 'application/json' } }); },
    },
    onSendClick(state) {
      state.pathname = '/c/5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d';
      state.assistantNodes = [{ innerText: 'Pro thinking' }];
    },
  });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'PT', text: '請只回覆 OK', model: 'gpt-x-pro' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'PT' && r.kind === 'finished', 15000);
  assert.ok(polls >= 2, 'waited for the server to finish the answer');
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'PT');
  assert.ok(events.some((e) => e.kind === 'text' && e.full === 'Pro thinking'), 'the page placeholder still shows while waiting');
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, 'OK');
  assert.ok(!events.some((e) => e.kind === 'failed'));
  noLeak(pod);
});

// 09-25 實機 .036：專案 6 Pro 送出後網頁的停止鍵先消失、送出的串流還開著而且沒有文字，十秒就被判完成。
test('pod script: the stop button vanishing while the send stream is still open and silent does not end the turn', async () => {
  const id = '6b5c4d3e-2f1a-4b0c-9d8e-7f6a5b4c3d2e';
  let polls = 0;
  const convo = (finished) => ({ current_node: 'a1', mapping: {
    u1: { message: { id: 'u1', author: { role: 'user' }, content: { content_type: 'text', parts: ['請只回覆 OK'] }, status: 'finished_successfully' }, parent: null, children: ['a1'] },
    a1: { message: { id: 'a1', author: { role: 'assistant' }, create_time: Date.now() / 1000,
      content: { content_type: 'text', parts: [finished ? 'OK' : ''] }, status: finished ? 'finished_successfully' : 'in_progress',
      end_turn: finished ? true : null }, parent: 'u1', children: [] },
  } });
  // 送出的串流：先給對話編號（跟實機一樣是 resume_conversation_token），之後開著不給文字，4 秒後才關。
  const openStream = () => new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('data: ' + JSON.stringify({ type: 'resume_conversation_token', kind: 'k', token: 't', conversation_id: id }) + '\n\n'));
      setTimeout(() => controller.close(), 4000);
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
  const pod = makePod({
    responses: {
      '/backend-api/f/conversation': () => openStream(),
      ['/backend-api/conversation/' + id]: () => { polls += 1;
        return new Response(JSON.stringify(convo(polls >= 2)), { status: 200, headers: { 'content-type': 'application/json' } }); },
    },
    onSendClick(state) {
      state.pathname = '/g/g-p-0123456789abcdef0123456789abcdef-mac-studio/project';
      state.stop = true;
      setTimeout(() => { state.stop = false; state.assistantNodes = [{ innerText: 'Pro thinking' }]; }, 300);
    },
  });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'SV', text: '請只回覆 OK', model: 'gpt-x-pro' });
  const finished = await pod.waitFor((r) => r.type === 'stream' && r.id === 'SV' && r.kind === 'finished', 15000);
  assert.ok(polls >= 2, 'waited for the server to finish instead of trusting the vanished stop button');
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'SV');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === id));
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, 'OK');
  assert.ok(!events.some((e) => e.kind === 'failed'));
  // 診斷只有代號：看得到每次讀對話時伺服器的狀態，看不到內容。
  assert.match(finished.shape, /poll=assistant\/in_progress×1/);
  assert.match(finished.shape, /poll=assistant\/finished_successfully×1/);
  assert.doesNotMatch(finished.shape, /請只回覆|Pro thinking|OK/);
  noLeak(pod);
});

test('pod script: while the page already shows this turn\'s answer bubble, polling does not give up after two minutes', () => {
  const tap = read(app + 'TAP/ChatGPTTap.swift');
  assert.match(tap, /const pageBubble = assistantNodes\(\)\.length > turn\.before;/);
  assert.match(tap, /!convo\.async_status && !stopVisible\(\) && !pageBubble\s*&& Date\.now\(\) - turn\.started > 120000\) \{ finishTurn\(turn\); return; \}/);
});

test('voice: stopping while connecting voids the late start and ends the page session; the Pod auto-ends voice that starts after a stop', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const tap = read(app + 'TAP/ChatGPTTap.swift');
  assert.match(space, /guard session == voiceSession, voiceActive else \{[\s\S]{0,80}if !voiceActive \{ try\? await tap\.voiceStop\(\) \}\s*return\s*\}/);
  assert.match(space, /func stopVoice\(\) \{\s*guard voiceActive else \{ return \}\s*voiceSession \+= 1/);
  assert.match(tap, /voiceStopAt = Date\.now\(\);\s*if \(!voiceGuard\) voiceGuard = setInterval/);
  assert.match(tap, /if \(voiceGuard\) \{ clearInterval\(voiceGuard\); voiceGuard = null; \}/);
});


// 09-25 另一家引擎（GPT-6）唯讀審查的 15 條：逐條的回歸測試。
test('review fixes: Pod commands only run on chatgpt.com; same-origin downloads are no-store; diag routes are categories only', async () => {
  const tapSource = read(app + 'TAP/ChatGPTTap.swift');
  assert.match(tapSource, /return "location\.host==='chatgpt\.com'&&window\.__tatwoPod&&window\.__tatwoPod\.command\("/);   // #1
  assert.match(tapSource, /credentials: 'include', headers: auth \|\| \{\}, cache: 'no-store' \}/);                       // #3
  // #2：網頁導覽只回報路由分類。
  const pod = makePod({ responses: {}, setup(sandbox) {
    const base = sandbox.document.querySelectorAll.bind(sandbox.document);
    const links = ['/g/g-private-patient-treatment?access_token=PRIVATE-TOKEN', '/library?x=1', '/g/g-p-abc123/project', 'https://evil.example/x'].map((h) => ({ getAttribute: () => h }));
    sandbox.document.querySelectorAll = (sel) => (sel === 'nav a[href]' ? links : base(sel));
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'probe', id: 'PR' });
  const res = await pod.waitFor((r) => r.type === 'result' && r.id === 'PR', 8000);
  const nav = JSON.stringify(res.data || res.message || '');
  assert.doesNotMatch(nav, /patient|PRIVATE-TOKEN|access_token|evil/);
  noLeak(pod);
});

test('review fixes: a send that stays in Work is not sent; a Request-object send is still rewritten', async () => {
  // #6：切不到 Chat（仍在 Work）就不送。
  const clicks = [];
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  const mk = (label, selected) => ({ textContent: label, getAttribute: (k) => (k === 'aria-selected' ? String(selected()) : null), click() { clicks.push(label); } });
  const work = mk('Work', () => true);
  const chat = mk('Chat', () => false);
  const qsa = pod.sandbox.document.querySelectorAll;
  pod.sandbox.document.querySelectorAll = (sel) => (sel.startsWith('button, [role="tab"]') ? [work, chat] : qsa(sel));
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'W', text: 'x' });
  const failed = await pod.waitFor((r) => r.type === 'stream' && r.id === 'W' && r.kind === 'failed');
  assert.match(failed.message, /Work/);
  assert.equal(pod.state.sendClicked, 0, 'did not press send while in Work');
  // #8：網頁用 Request 物件送出時照樣改寫。
  const pod2 = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } } });
  pod2.sandbox.document.querySelector = ((base) => (sel) => (sel === '[data-testid="send-button"]' ? { disabled: false, click() {
    pod2.state.sendClicked += 1;
    pod2.sandbox.window.fetch(new Request('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', headers: { authorization: 'Bearer SECRET-TOKEN' },
      body: JSON.stringify({ action: 'next', model: 'auto', messages: [] }) })).then((r) => r.text());
  } } : base(sel)))(pod2.sandbox.document.querySelector.bind(pod2.sandbox.document));
  await pod2.signIn();
  await pod2.waitFor((r) => r.type === 'auth');
  pod2.command({ cmd: 'send', id: 'R', text: 'x', model: 'gpt-x', temporary: true });
  await pod2.waitFor((r) => r.type === 'stream' && r.id === 'R' && (r.kind === 'finished' || r.kind === 'failed'), 8000);
  const post = pod2.requests.filter((r) => r.url.endsWith('/backend-api/f/conversation')).at(-1);
  const body = JSON.parse(post.init.body);
  assert.equal(body.model, 'gpt-x');
  assert.equal(body.history_and_training_disabled, true);
  noLeak(pod2);
});

test('review fixes: text before a handoff is not completion; polling ignores the previous turn\'s finished answer', async () => {
  const cid = '11111111-2222-4333-8444-555555555555';
  const handoff = [
    `event: delta\ndata: {"p": "", "o": "add", "v": {"message": {"id": "a0", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["先想一下"]}, "status": "in_progress"}, "conversation_id": "${cid}"}, "c": 0}\n\n`,
    `data: {"type": "stream_handoff", "conversation_id": "${cid}", "options": {"transport": "pubsub"}}\n\n`,
    'data: [DONE]\n\n',
  ];
  const now = Date.now() / 1000;
  let polls = 0;
  const convo = () => {
    polls += 1;
    // 前兩次伺服器還回上一輪已完成的舊答案（create_time 很早），第三次才是這一輪的答案。
    const old = { id: 'old', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['OLD ANSWER'] }, status: 'finished_successfully', end_turn: true, create_time: now - 3600 };
    const fresh = { id: 'new', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['新答案'] }, status: 'finished_successfully', end_turn: true, create_time: now + 1 };
    const m = polls >= 3 ? fresh : old;
    return new Response(JSON.stringify({ current_node: 'n', mapping: { n: { message: m, parent: null, children: [] } } }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: handoff }, [`/backend-api/conversation/${cid}`]: convo } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'HX', text: 'x' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'HX' && r.kind === 'finished', 20000);
  const texts = pod.reports.filter((r) => r.type === 'stream' && r.id === 'HX' && r.kind === 'text').map((e) => e.full);
  assert.ok(polls >= 3, 'did not stop at the pre-handoff text or the old answer');
  assert.equal(texts.at(-1), '新答案');
  assert.ok(!texts.includes('OLD ANSWER'));
  noLeak(pod);
});

test('review fixes: turn results follow the turn, not the current view; photo promises always clean up; cache purge refuses symlinks', () => {
  const space = read(app + 'TAP/ChatGPTSpace.swift');
  const storage = read(app + 'Browser/TapPodStorage.swift');
  // #11
  assert.match(space, /@MainActor func viewingTurn\(\) -> Bool \{ conversationID != nil \? selectedID == conversationID : viewEpoch == epoch \}/);
  assert.match(space, /turnFailure = "\\\(failurePrefix\)：\\\(message\)"\s*if viewingTurn\(\) \{ failure = turnFailure \}/);
  assert.match(space, /if selectedID == conversationID \{ messages = saved \}/);
  // #4
  assert.match(space, /completed \+= 1\s*if error == nil \{ received\.append\(url\) \}\s*let done = completed >= expected/);
  assert.match(space, /DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 60\) \{ try\? FileManager\.default\.removeItem\(at: directory\) \}/);
  // #5
  assert.match(storage, /isSymbolicLinkKey/);
  assert.match(storage, /guard cache\.resolvingSymlinksInPath\(\)\.path == cache\.standardizedFileURL\.path else \{ return nil \}/);
  // #13：語音結束的保險不設時限
  const tapSource = read(app + 'TAP/ChatGPTTap.swift');
  assert.doesNotMatch(tapSource, /voiceStopAt > 60000/);
});

// 09-25 .033 實機：專案頁的輸入框留著上次的草稿，對整頁全選蓋不掉，新訊息沒打進去；送出流程出錯時什麼都沒回，App 一直「思考中」。
test('send: replaces a restored draft inside the composer; fails loudly when it cannot type or has no composer', async () => {
  // 有舊草稿：只選輸入框內的字再打，送出的是新訊息。
  const pod = makePod({ responses: { '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] } }, setup(sandbox) {
    const box = { innerText: '上次的草稿', focus() {} };
    let selectedInBox = false;
    sandbox.document.createRange = () => ({ selectNodeContents: (el) => { selectedInBox = el === box; } });
    sandbox.window.getSelection = () => ({ removeAllRanges() {}, addRange() {} });
    const baseQuery = sandbox.document.querySelector.bind(sandbox.document);
    sandbox.document.querySelector = (sel) => (sel === '#prompt-textarea' ? box : baseQuery(sel));
    const baseExec = sandbox.document.execCommand.bind(sandbox.document);
    sandbox.document.execCommand = (cmd, ui, value) => { if (cmd === 'insertText' && selectedInBox) box.innerText = value; return baseExec(cmd, ui, value); };
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'D1', text: '新訊息' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'D1' && (r.kind === 'finished' || r.kind === 'failed'), 8000);
  assert.equal(pod.state.sendClicked, 1);
  // 打不進字：回報失敗、不按送出。
  const stuck = makePod({ responses: {}, setup(sandbox) {
    const box = { innerText: '上次的草稿', focus() {} };
    const baseQuery = sandbox.document.querySelector.bind(sandbox.document);
    sandbox.document.querySelector = (sel) => (sel === '#prompt-textarea' ? box : baseQuery(sel));
  } });
  await stuck.signIn();
  await stuck.waitFor((r) => r.type === 'auth');
  stuck.command({ cmd: 'send', id: 'D2', text: '新訊息' });
  const failed = await stuck.waitFor((r) => r.type === 'stream' && r.id === 'D2' && r.kind === 'failed', 8000);
  assert.match(failed.message, /打不進/);
  assert.equal(stuck.state.sendClicked, 0);
  // 找不到輸入框：回報失敗（以前丟例外、什麼都不回）。
  const none = makePod({ responses: {}, setup(sandbox) {
    let calls = 0;
    const baseQuery = sandbox.document.querySelector.bind(sandbox.document);
    // openConversation 找得到輸入框，送出那一刻找不到（網頁剛好重畫）。
    sandbox.document.querySelector = (sel) => (sel === '#prompt-textarea' ? ((calls += 1) <= 1 ? { focus() {} } : null) : baseQuery(sel));
  } });
  await none.signIn();
  await none.waitFor((r) => r.type === 'auth');
  none.command({ cmd: 'send', id: 'D3', text: 'x' });
  const f3 = await none.waitFor((r) => r.type === 'stream' && r.id === 'D3' && r.kind === 'failed', 8000);
  assert.match(f3.message, /輸入框/);
});

test('project send: when the page stays on the project page, the new conversation is found in the project list and polled', async () => {
  const cid = '22222222-3333-4444-8555-666666666666';
  const now = new Date(Date.now() + 1000).toISOString();
  const pod = makePod({ responses: {
    '/backend-api/f/conversation': { sse: ['data: [DONE]\n\n'] },
    '/backend-api/gizmos/g-p-abc123/conversations': { json: { items: [{ id: cid, title: 'New chat', create_time: now, update_time: now },
      { id: '99999999-3333-4444-8555-666666666666', title: '舊的', create_time: '2026-01-01T00:00:00Z' }] } },
    [`/backend-api/conversation/${cid}`]: { json: { current_node: 'a1', mapping: {
      a1: { message: { id: 'a1', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['專案裡的答案'] }, status: 'finished_successfully', end_turn: true }, parent: null, children: [] } } } },
  } });
  await pod.signIn();
  await pod.waitFor((r) => r.type === 'auth');
  pod.command({ cmd: 'send', id: 'PJ', text: '專案問', gizmoID: 'g-p-abc123' });
  await pod.waitFor((r) => r.type === 'stream' && r.id === 'PJ' && r.kind === 'finished', 20000);
  const events = pod.reports.filter((r) => r.type === 'stream' && r.id === 'PJ');
  assert.ok(events.some((e) => e.kind === 'conversation' && e.conversationID === cid));
  assert.equal(events.filter((e) => e.kind === 'text').at(-1).full, '專案裡的答案');
  noLeak(pod);
});

test('Tap: a send the page never answers fails after a silence watchdog instead of spinning forever', () => {
  const tapSource = read(app + 'TAP/ChatGPTTap.swift');
  assert.match(tapSource, /let silence: Duration = \(base\["files"\] as\? \[Any\]\)\?\.isEmpty == false \? \.seconds\(150\) : \.seconds\(60\)/);
  assert.match(tapSource, /pending\.yield\(\.failed\("ChatGPT 網頁沒有回應，這則可能沒有送出"\)\)/);
  assert.match(tapSource, /acceptedStreams\.insert\(id\)   \/\/ 回了任何事件都算有回應/);
  assert.match(tapSource, /send\(command\)\.catch\(failStream\)/);
});
