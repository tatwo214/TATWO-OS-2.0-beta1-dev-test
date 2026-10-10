import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

// W184 E（使用者 09-29：「倒放 預設作為影片子畫面」；spec E1–E3；spike 報告 rooms/w183-handoff/w184-e-spike-report.md）：
// 倒放＝Browser 影片子畫面（第一階段）＋有事時蓋上來的三種卡。原始碼契約；挑分頁、每一種還回時機、三種卡與畫面證據在
// `TATWO2_SELFTEST=w184tent`（假的影片來源）；真的 CEF 搬移由主導實機驗。
const root = fileURLToPath(new URL('../', import.meta.url));
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const app = (name) => read('App/Sources/Tatwo2/' + name);
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

const header = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const backend = app('Browser/ChromiumCEFBackend.swift');
const features = app('Browser/BrowserWebFeatures.swift');
const runtime = app('Browser/BrowserWorkSpaceCEFSurface.swift');
const lending = app('Browser/BrowserTentLending.swift');
const videoTabs = app('Browser/BrowserVideoTabs.swift');
const design = app('Browser/BrowserWorkSpaceDesignView.swift');
const agent = app('Facade/BrowserAgentBridge.swift');
const tentVideo = app('DM/DMTentVideo.swift');
const pane = app('DM/GlobalDMTentPane.swift');
const content = app('DM/GlobalDMTentContent.swift');
const panels = app('DM/GlobalDMPanelController.swift');
const selfTest = app('SelfTest.swift');
const acceptance = app('DM/DMTentAcceptance.swift');
const tentFiles = [['DMTentVideo.swift', tentVideo], ['GlobalDMTentPane.swift', pane], ['GlobalDMTentContent.swift', content]];

test('bridge: one more boolean (a visible <video> is playing), only for the human page, with defaults so old callers compile', () => {
  // 守：只過一個是非值（橋接層「只過布林值」的隱私原則），只給使用者本人的頁面、只在變動時。
  assert.match(header, /@property\(nonatomic, copy, nullable\) void \(\^onVideoPlayingChange\)\(BOOL playing\);/);
  assert.match(bridge, /bool audible = false, bool video = false\) \{/);
  assert.match(bridge, /args->SetBool\(4, audible\); args->SetBool\(5, video\);/);
  // 守：更新函式的新參數有預設值（browser-memory-policy 的 C++ 測試用舊的參數數量呼叫）。
  assert.match(bridge, /bool is_main, bool dirty, bool playing, bool audible, bool video = false\) \{/);
  assert.match(bridge, /found->second\.video = video;/);
  assert.match(bridge, /struct Activity \{ std::string token; bool dirty = false; bool playing = false; bool audible = false; bool video = false; \};/);
  const dispatch = slice(bridge, 'message->GetName() == kBrowserActivityMessage) {', '  if (source_process != PID_RENDERER || !browser || !frame ||');
  assert.match(dispatch, /\(args->GetSize\(\) != 5 && args->GetSize\(\) != 6\)/);
  assert.match(dispatch, /args->GetSize\(\) == 6 && args->GetBool\(5\)/);
  assert.match(dispatch, /if \(video_now != state->video_reported\) \{\s*state->video_reported = video_now;\s*if \(owner\.onVideoPlayingChange && ActorRequestPolicy\(owner\)\.human\) owner\.onVideoPlayingChange\(video_now\);/);
  // 守：渲染端的 binding 收第四個布林，舊的三個照舊。
  assert.match(bridge, /if \(args\.size\(\) == 4 && args\[0\]->IsBool\(\) && args\[1\]->IsBool\(\) && args\[2\]->IsBool\(\) && args\[3\]->IsBool\(\)\)/);
  assert.match(bridge, /if \(args\.size\(\) == 3 && args\[0\]->IsBool\(\) && args\[1\]->IsBool\(\) && args\[2\]->IsBool\(\)\)/);
  // 守：App 端只記「哪個分頁在播、什麼時候開始播」，只對人用分頁接（同 W112 的有聲音）。
  assert.match(backend, /if !agentMount \{ browser\.onVideoPlayingChange = \{ playing in BrowserVideoTabs\.shared\.set\(tabID, playing: playing\) \} \}/);
  // 分頁要關、要睡（不在 openTabIDs）＝播放紀錄一起清掉（同 W112 的有聲音在 closeTab 清；closeTab 本身不動，見下面）。
  assert.match(slice(backend, '    func update(\n        tabID: String?', '        showSelectedTab()'), /returnLent\(id, reason: \.closing\)\s*BrowserVideoTabs\.shared\.forget\(id\)/);
  assert.match(videoTabs, /@Published private\(set\) var startedAt: \[String: Date\] = \[:\]/);
  assert.match(videoTabs, /guard startedAt\[tabID\] == nil else \{ return \}\s*startedAt\[tabID\] = clock\(\)\s*starts\.send\(tabID\)/);
});

test('activity script: the fourth flag is a playing, sized, laid-out <video> — never its source or the page', () => {
  const script = bridge.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)?.[1];
  assert.ok(script);
  // 守：不讀網址、內容（同 w85-media-fallback 的守門）。
  assert.doesNotMatch(script, /location\.(href|pathname)|innerHTML|textContent|currentSrc|\.src\b|\.title\b/);
  const listeners = new Map(), reports = [], timers = [];
  const guarded = (fields) => new Proxy(fields, { get(target, key) {
    if (['src', 'currentSrc', 'textContent', 'innerHTML', 'title', 'baseURI'].includes(key)) throw Error(`must not read ${String(key)}`);
    return target[key];
  } });
  const media = [];
  const install = vm.runInNewContext(script, {
    document: {
      addEventListener: (name, callback) => listeners.set(name, callback),
      querySelectorAll: selector => { assert.equal(selector, 'audio,video'); return media; },
      createElement: () => ({ canPlayType: () => 'probably' }),
    },
    setInterval: callback => timers.push(callback),
  });
  assert.equal(install((...args) => reports.push(args)), true);
  const tick = () => { timers[0](); return reports.at(-1); };
  const video = guarded({ tagName: 'VIDEO', paused: false, ended: false, muted: true, volume: 0, videoWidth: 640, videoHeight: 360,
    getBoundingClientRect: () => ({ width: 320, height: 180 }) });
  media.push(video);
  assert.deepEqual(tick(), [false, true, false, true], 'a muted playing video with a picture and a box counts');
  video.paused = true;
  assert.deepEqual(tick(), [false, false, false, false], 'paused = not playing');
  video.paused = false; video.videoWidth = 0;
  assert.equal(tick()[3], false, 'no decoded picture (audio in a <video>) does not count');
  video.videoWidth = 640; video.getBoundingClientRect = () => ({ width: 0, height: 0 });
  assert.equal(tick()[3], false, 'display:none / zero-size does not count');
  media.length = 0;
  media.push(guarded({ tagName: 'AUDIO', paused: false, ended: false, muted: false, volume: 1, videoWidth: 0, videoHeight: 0 }));
  assert.deepEqual(tick(), [false, true, true, false], 'audio plays and is audible, but it is not a video');
  const count = reports.length;
  timers[0]();
  assert.equal(reports.length, count, 'unchanged activity does not emit IPC');
});

test('activity reducer stores the video flag per frame; old callers leave it false', { skip: process.platform !== 'darwin' }, () => {
  const reducer = bridge.slice(bridge.indexOf('void UpdateBrowserActivity('), bridge.indexOf('bool HasActiveBrowserPumpWork(const BrowserState'));
  const fields = bridge.match(/struct BrowserState \{([\s\S]*?)#pragma mark - W57a/)?.[1];
  assert.ok(reducer && fields);
  const dir = testScratch('w184-tent-');
  const input = path.join(dir, 'Activity.cpp'), output = path.join(dir, 'activity');
  fs.writeFileSync(input, `#include <map>\n#include <string>\n#include <cassert>\n#include <iostream>\nstruct BrowserState {${fields}};\n${reducer}\n` + String.raw`
int main() {
  BrowserState s;
  UpdateBrowserActivity(&s, "main", "t", "ready", true, false, false, false);
  UpdateBrowserActivity(&s, "main", "t", "update", true, false, true, false, true);
  assert(s.activity_frames.at("main").video && s.activity_frames.at("main").playing);
  UpdateBrowserActivity(&s, "main", "t", "update", true, false, true, true);
  assert(!s.activity_frames.at("main").video);
  UpdateBrowserActivity(&s, "child", "c", "ready", false, false, false, false);
  UpdateBrowserActivity(&s, "child", "old", "update", false, false, true, false, true);
  assert(!s.activity_frames.at("child").video);
  assert(!s.video_reported);
  std::cout << "w184 video reducer PASS\n";
}`);
  const compile = spawnSync('xcrun', ['clang++', '-std=c++17', input, '-o', output], { encoding: 'utf8', timeout: 120000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(output, [], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /w184 video reducer PASS/);
});

test('candidate filter: never lend auth pages, Pod, pairing/login popups, AI tabs or AI control, sensitive or https-only pages, non-human, sleeping or chat session tabs', () => {
  const policy = code(slice(lending, 'static func lendable(_ tab: BrowserLendableTab) -> Bool {', '\n    }\n'));
  // 守（施工單第 5 條）：每一種都在這一個判斷裡。
  for (const condition of ['tab.ownedByWorkSpace', '!tab.isAgentTab', '!tab.isSleeping', '!tab.isSensitive', 'let native = tab.native',
    'native.isHuman', '!native.agentControlled', '!native.sensitivePage', '!native.httpsOnly', '!native.isPod']) {
    assert.ok(policy.includes(condition), condition);
  }
  // 守：只從 Browser 工作區挑（聊天旁、聊天 session 的 runtime 不借）；登記簿標的敏感分頁不借。
  const lendables = slice(runtime, '    func lendableTabs() -> [BrowserLendableTab] {', '\n    }\n');
  assert.match(lendables, /guard owner == nil else \{ return \[\] \}/);
  assert.match(lendables, /isSensitive: registry\.isSensitive\(tab\.id\)/);
  assert.match(runtime, /func lendTab\(_ id: UUID, into target: NSView\) -> Bool \{\s*guard owner == nil, let host, workTabs\.contains\(where: \{ \$0\.id == id && !\$0\.isSleeping \}\), !registry\.isSensitive\(id\),/);
  // 守：主機再擋一次原生旗標（人用、沒被 AI 控制、不是敏感頁、受保護頁、Pod）。
  const lend = slice(backend, '    func lend(tabID: String, into target: NSView) -> Bool {', '    /// 還回：');
  assert.match(lend, /browser\.browserActor == \.human, !browser\.agentControlled, !browser\.sensitivePage, !browser\.httpsOnly,\s*!browser\.isPod else \{ return false \}/);
  // 守：從登記簿組旗標時，擁有者不是 Browser 工作區（聊天 session、bot）就不是工作區分頁。
  assert.match(lending, /if case \.workSpace = tab\.owner \{ workSpace = true \} else \{ workSpace = false \}/);
  // 守：AI 與 Computer Use 找頁面時跳過借出中的頁面。
  assert.match(agent, /!TatwoCEFTabHostView\.lentBrowsers\.contains\(browser\) else \{ return nil \}/);
});

test('moving the page: only the NSView moves; container.browserView is never cleared; the tab switcher is untouched', () => {
  const section = slice(backend, '    // MARK: W184 E：借給私訊框倒放（影片子畫面）', '    // MARK: W183 R5b：私訊框的敏感頁面');
  // 守（主導裁決第 3 條）：不清 browserView、不關、不重建（主視窗選到這個分頁時沿用，不重新載入）。
  assert.doesNotMatch(code(section), /browserView = nil|\.close\(|closeBrowser|TatwoCEFBrowserView\(frame|loadURLString|reload\(/);
  assert.match(section, /target\.addSubview\(browser\)/);
  assert.match(section, /entry\.container\.addSubview\(browser\)/);
  // 守：借出前先退出全螢幕與檔案框、清掉頁面裡的鍵盤焦點；只有「回到 Browser」「拿回來」把鍵盤還給頁面。
  const lend = slice(section, '    func lend(tabID: String, into target: NSView) -> Bool {', '    /// 還回：');
  assert.ok(lend.indexOf('browser.cancelWebFeatures()') < lend.indexOf('target.addSubview(browser)'));
  assert.match(lend, /Self\.resignPageFocus\(browser\)/);
  assert.match(section, /func takeBack\(tabID: String\) \{\s*guard lentTabs\[tabID\] != nil else \{ return \}\s*giveBack\(tabID: tabID, focus: true\)/);
  // 守：切分頁的函式不動（browser-stress 也守這一段不能有移除 view 的動作）。
  const show = slice(backend, '    private func showSelectedTab()', '    private func ensureSelectedTab()');
  assert.doesNotMatch(show, /lent|lend|giveBack|removeFromSuperview/);
});

test('return timings inside the host: closing, main-window commands, 拿回來 and fullscreen give the page back first, then tell the borrower', () => {
  // 守（第 6 條）：分頁要關或要睡（使用者關分頁、睡眠、不在 openTabIDs）＝先還回、通知借用者，再照舊關。
  const update = slice(backend, '    func update(\n        tabID: String?', '        showSelectedTab()');
  assert.ok(update.indexOf('returnLent(id, reason: .closing)') >= 0 && update.indexOf('returnLent(id, reason: .closing)') < update.indexOf('closeTab(id)'));
  // 守：closeTab 到主機結尾一字不動（browser-stress 把這一段原樣編進假的主機跑關閉統計）；倒放那一段也不在敏感頁那一段裡（w183-ui 守它不碰 entries）。
  const close = slice(backend, '    private func closeTab(_ tabID: String)', 'struct EmbeddedChromiumBrowserView:');
  assert.doesNotMatch(close, /W184|returnLent|lentTabs|BrowserVideoTabs/);
  assert.doesNotMatch(slice(backend, 'func openSensitivePage(', 'private func closeTab('), /W184|lentTabs|returnLent/);
  // 守：主視窗對這個分頁下指令（重新整理、網址、上一頁、尋找、縮放、翻譯）＝先拿回來再做。
  const execute = slice(backend, '    private func executePendingCommand(on browser: TatwoCEFBrowserView) {', '        let enqueue:');
  assert.match(execute, /returnLent\(lent, reason: \.command\)/);
  assert.match(slice(backend, '    func translate(tabID: String,', '\n    }\n'), /returnLent\(tabID, reason: \.command\)/);
  // 守：借出中要全螢幕＝先還回，再照原本的路走（主視窗看得到這個分頁才開）；告訴借用者開了沒。
  const full = slice(backend, '    private func fullscreenWhileLent(', '\n    }\n');
  assert.ok(full.indexOf('giveBack(tabID: tabID)') < full.indexOf('original?(true)'));
  assert.match(full, /onLentReturned\?\(tabID, \.fullscreen\(started: started\)\)/);
  // 守：canPresent 加條件——頁面在自己的容器裡（或正在全螢幕）才開全螢幕與檔案框。
  assert.match(slice(features, '    private var canPresent: Bool {', '\n    }\n'), /\(browser\.superview === container \|\| overlay != nil\)/);
  // 守：runtime 把主機的還回轉給倒放；主視窗那一格的「拿回來」走主機的 takeBack。
  assert.match(runtime, /host\.onLentReturned = \{ \[weak self\] id, reason in self\?\.lentReturned\(id, reason\) \}/);
  assert.match(runtime, /func takeBackLentTab\(\) \{\s*guard let id = lentTabID else \{ return \}\s*host\?\.takeBack\(tabID: id\.uuidString\)/);
});

test('runtime (production code, engine double): lends only awake, non-sensitive Browser work space tabs; 拿回來 tells the tent', {
  skip: process.platform !== 'darwin', timeout: 180000,
}, () => {
  // 守：Browser 工作區的 runtime（正式程式碼，主機是替身）只借醒著、有原生頁面、不是登記簿敏感分頁的 Browser 工作區分頁；
  // 聊天旁的 runtime 一個都不借；主視窗「拿回來」＝佔位卡消失、倒放收到 takenBack；倒放還回＝佔位卡消失。
  const controller = runtime.slice(runtime.indexOf('@MainActor'), runtime.indexOf('struct BrowserWorkSpaceCEFSurface:'));
  const dir = testScratch('w184-tent-runtime-');
  const file = path.join(dir, 'Checks.swift'), binary = path.join(dir, 'checks');
  fs.writeFileSync(file, read('tests/fixtures/browser-workspace-runtime-stubs.swift') + '\n' + controller + String.raw`
@MainActor final class Events { var list: [(UUID, BrowserTabReturnReason)] = [] }
@main struct Checks {
 @MainActor static func main() {
  let registry = BrowserTabRegistry.shared, space = UUID(), surface = UUID()
  let runtime = BrowserWorkSpaceRuntime.shared
  let a = registry.openTab(owner: .workSpace(space), url: URL(string: "https://video.example"))
  let b = registry.openTab(owner: .workSpace(space), url: URL(string: "https://b.example"))
  precondition(runtime.select(a.id, surfaceID: surface, command: nil) { _, _ in })
  let host = runtime.mount(), target = NSView()
  precondition(!runtime.lendTab(b.id, into: target), "no native page yet")
  precondition(runtime.lendTab(a.id, into: target) && runtime.lentTabID == a.id && host.lent == [a.id.uuidString])
  let tabs = runtime.lendableTabs()
  precondition(tabs.first { $0.id == a.id.uuidString }?.isSelected == true && tabs.first { $0.id == b.id.uuidString }?.native == nil)
  let events = Events()
  let watch = runtime.lentReturns.sink { events.list.append(($0.tabID, $0.reason)) }
  runtime.takeBackLentTab()
  precondition(runtime.lentTabID == nil && host.lent.isEmpty && events.list.count == 1 && events.list[0].0 == a.id
               && events.list[0].1 == .takenBack)
  registry.sensitiveIDs.insert(a.id)
  precondition(!runtime.lendTab(a.id, into: target), "a sensitive tab is never lent")
  registry.sensitiveIDs.remove(a.id)
  registry.markSleeping(a.id, true)
  precondition(!runtime.lendTab(a.id, into: target), "a sleeping tab is never lent")
  registry.markSleeping(a.id, false)
  let chat = BrowserWorkSpaceRuntime.forChat(UUID().uuidString)
  precondition(chat.lendableTabs().isEmpty && !chat.lendTab(a.id, into: target), "chat runtimes never lend")
  precondition(runtime.lendTab(a.id, into: target))
  runtime.giveBackTab(a.id)
  precondition(runtime.lentTabID == nil && host.lent.isEmpty && events.list.count == 1)
  let serial = runtime.foregroundTabRequest.serial
  runtime.requestForeground(b.id)
  chat.requestForeground(b.id)
  precondition(runtime.foregroundTabRequest.tabID == b.id && runtime.foregroundTabRequest.serial == serial + 1
               && chat.foregroundTabRequest.tabID == nil, "回到 Browser selects the tab through the existing foreground request")
  _ = watch
  print("W184 tent runtime PASS")
 }
}
`);
  const files = ['TatwoBrowserLaneCore.swift', 'BrowserWorkSpacePolicies.swift', 'BrowserMemoryPolicy.swift', 'BrowserMemorySettings.swift',
    'BrowserNativeMemoryBudget.swift', 'BrowserGeneralSettings.swift', 'BrowserShortcuts.swift'].map(name => path.join(root, 'App/Sources/Tatwo2/Browser', name));
  const compiled = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2', ...files, file, '-o', binary],
    { cwd: root, encoding: 'utf8', timeout: 170000 });
  assert.equal(compiled.status, 0, `${compiled.error ?? ''}\n${compiled.stdout}\n${compiled.stderr}`);
  const result = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 30000, env: { ...process.env, TATWO_BROWSER_SLEEP_SECONDS: '' } });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W184 tent runtime PASS/);
});

test('lent tabs never sleep (sleep protection list), even under memory pressure', () => {
  // 守（第 7 條）：主機的睡眠保護名單＝原生頁面擋睡的＋借給倒放的；單一分頁的判斷也先看借出。
  assert.match(backend, /entry\.container\.browserView\?\.preventsAutomaticSleep == true \? id : nil\s*\}\)\.union\(lentTabs\.keys\)/);
  assert.match(backend, /func preventsAutomaticSleep\(tabID: String\) -> Bool \{\s*lentTabs\[tabID\] != nil \|\|/);
  // 守：睡眠與記憶體壓力都走這份名單（既有的兩個入口）。
  assert.match(runtime, /\(runtime\.host\?\.protectedTabIDs \?\? \[\]\)/);
  assert.match(runtime, /host\?\.preventsAutomaticSleep\(tabID: id\.uuidString\) != true else \{ return \}/);
});

test('keyboard in the tent: ⌘ shortcuts do not reach the main menu or the main window; Esc closes the box', () => {
  // 守（第 9 條）：借出中的頁面先判斷，⌘W 等吃掉；編輯鍵、⌘Q、⌘H 放行；不帶 ⌘ 的鍵照常給頁面。
  const keys = slice(backend, '            browser.onBrowserKeyEquivalent = {', '            browser.onDailyShortcut = {');
  assert.ok(keys.indexOf('if let self, self.isLent(tabID) { return BrowserLentKeys.claims(event) }') < keys.indexOf('guard let self'));
  assert.match(slice(backend, '            browser.onDailyShortcut = {', '            browser.onFindResult = {'), /if let self, self\.isLent\(tabID\) \{ return \}/);
  assert.match(lending, /static let passThrough: Set<String> = \["c", "v", "x", "a", "z", "q", "h"\]/);
  assert.match(lending, /guard modifiers\.intersection\(\.deviceIndependentFlagsMask\)\.contains\(\.command\) else \{ return false \}/);
  // 守：倒放沒有 Browser 那一頁：Esc＝收框（影片還回），不給倒放框裡的網頁；其他形態照舊（w183-browser 守原本那一行）。
  // W184 G2 修正：Esc 的判斷抽成靜態的 routeEscape（自測拿真的 Esc 事件走同一條），形態由 handleEscape 照 desk.form 傳進來；
  // 倒放照舊最先判斷（在「Browser 自己的面板開著＝只收面板」與「Browser 開著＝給網頁」之前）。
  assert.match(panels, /return Self\.routeEscape\(event, window: window, floating: floating, store: store, form: desk\.form\)/);
  assert.match(panels, /if form == \.tent \{\s*if window === floating \{ store\.isFloatingOpen = false \} else if store\.isOpen \{ store\.isOpen = false \} else \{ return event \}\s*return nil\s*\}\s*(?:\/\/[^\n]*\n\s*)*if DMBrowserPanelEscape\.closePanel\(in: window\) \{ return nil \}\s*if store\.isBrowsing \{ return event \}/);
});

test('timing with the forms (room AB): leave the tent before the animation, enter after it; hand-offs wait a beat', () => {
  // 守（第 6 條）：@Published 在改值之前送、setForm 之後才播動畫——同步的 sink 讓影片在動畫開始前就還回。
  assert.match(tentVideo, /self\.settings\.\$form\s*\.sink \{ \[weak self\] form in self\?\.formWillChange\(to: form\) \}/);
  assert.doesNotMatch(slice(tentVideo, 'self.settings.$form', '.store(in: &cancellables)'), /receive\(on:/);
  assert.match(slice(tentVideo, '    private func formWillChange(to form: GlobalDMForm) {', '\n    }\n'), /if form != \.tent \{[\s\S]*returnLent\(focus: false\)/);
  // 守：轉換動畫走完才掛上（轉換中不借）；轉進倒放的動畫期間只放黑底，不閃空狀態那句。
  assert.match(tentVideo, /\.sink \{ \[weak self\] animating in if animating \{ self\?\.transitionStarted\(\) \} else \{ self\?\.scheduleEvaluate\(\) \} \}/);
  // W184 F／G1（查證 #8）：帶著影片離開倒放時，倒放那一層淡出的那一小段也只放黑底（leaving）。
  assert.match(pane, /\} else if video\.entering \|\| video\.leaving \{[^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*Color\.black/);
  // W184 F／G1（查證 #6）：轉換中再換形態（⌘⌥Tab 連按）不會再有「開始」：照傳進來的新形態重算 entering（不讀 settings.form）。
  const willChange = slice(tentVideo, '    private func formWillChange(to form: GlobalDMForm) {', '\n    }\n');
  assert.match(willChange, /if isTransitioning\(\) \{ updateEntering\(form\) \}/);
  assert.match(willChange, /if lentID != nil \|\| shown != nil \|\| entering \{ leaving = true \}/);
  assert.match(tentVideo, /private func transitionStarted\(\) \{\s*updateEntering\(settings\.form\)\s*\}/);
  assert.match(tentVideo, /let value = form == \.tent && lentID == nil && DMTentPick\.onEnter\(source\.tabs\(\), dismissed: dismissed\) != nil/);
  assert.match(tentVideo, /if leaving, !isTransitioning\(\) \{ leaving = false \}/);
  assert.match(tentVideo, /settings\.form == \.tent && !isTransitioning\(\) && container != nil/);
  // 守（GPT-6 審查發現 5）：影片只待在「看得到的框」——掛在視窗上、視窗排在畫面上（沒被 orderOut）、沒縮到 Dock、沒被整個蓋住、
  // 自己跟祖先都沒藏；不能只靠框被拆掉（release）才還。
  assert.match(tentVideo, /static func isVisibleHolder\(_ view: NSView\) -> Bool \{\s*guard let window = view\.window, window\.isVisible, !window\.isMiniaturized,\s*window\.occlusionState\.contains\(\.visible\) else \{ return false \}\s*return !view\.isHiddenOrHasHiddenAncestor/);
  assert.match(tentVideo, /return containers\.last\(where: \{ \$0\.view\.map \{ Self\.isVisibleHolder\(\$0\) \} \?\? false \}\)\?\.view/);
  // 守：借著而沒有看得到的框＝換手寬限期倒數；時間到還是沒有才還回（停靠↔浮動、sheet 一閃而過不彈回主視窗）。
  const evaluate = slice(tentVideo, '    func evaluate() {', '    private func videoStarted(');
  assert.match(evaluate, /let container = visibleContainer/);
  assert.match(evaluate, /guard let container else \{[\s\S]*?startOrphanGrace\(\)\s*return\s*\}\s*cancelOrphanGrace\(\)/);
  const grace = slice(tentVideo, '    private func startOrphanGrace() {', '    private func cancelOrphanGrace() {');
  assert.match(grace, /try\? await Task\.sleep\(nanoseconds: UInt64\(max\(0, grace\) \* 1_000_000_000\)\)/);
  assert.match(grace, /if self\.visibleContainer == nil \|\| self\.settings\.form != \.tent \{[\s\S]*?self\.returnLent\(focus: false\)/);
  // 守：框拿掉只重算（還不還交給上面那一條），不直接還；借著的時候定時重看（orderOut 不發通知）、視窗被蓋住／露出來也重看。
  const release = slice(tentVideo, '    func release(_ container: DMTentVideoContainer) {', '    /// 框掛上或拿下視窗。');
  assert.match(release, /containers\.removeAll \{ \$0\.view == nil \|\| \$0\.view === container \}\s*if containers\.isEmpty \{ restoreTicket = nil \}[^\n]*\n\s*scheduleEvaluate\(\)/);
  assert.doesNotMatch(code(release), /returnLent/);
  assert.match(slice(tentVideo, '    private func startRecheck() {', '    private func stopRecheck() {'), /guard let self, self\.lentID != nil, !Task\.isCancelled else \{ return \}\s*self\.evaluate\(\)/);
  assert.match(tentVideo, /NotificationCenter\.default\.publisher\(for: NSWindow\.didChangeOcclusionStateNotification\)/);
  // 守：框被收起（還掛著）而還回去的那一支，框再出現、主視窗沒接手才收回來；框整個拿掉（收起私訊框）不留。
  assert.match(grace, /let hidden = self\.hasContainer && self\.settings\.form == \.tent\s*self\.returnLent\(focus: false\)[\s\S]{0,120}self\.restoreTicket = hidden \? self\.source\.tabs\(\)\.first\(where: \{ \$0\.id == id \}\)\.flatMap\(DMTentRestore\.Ticket\.init\) : nil/);
  assert.match(evaluate, /if let ticket = restoreTicket \{\s*restoreTicket = nil\s*if DMTentRestore\.stillValid\(ticket, source\.tabs\(\)\.first\(where: \{ \$0\.id == ticket\.id \}\)\) \{\s*lend\(ticket\.id, into: container\)/);
  // 守（GPT-6 審查新發現 4）：收回來的資格綁還回當下的頁面世代與網址、最後使用時間、這一段播放；主視窗在呈現、選過或離開過、
  // 導頁、換網址、停了或又重播、不能借＝作廢。還回當下主視窗已經在呈現、沒在播影片＝不給資格。沒借著時每次變動就核一次（接手馬上作廢）。
  const restore = slice(tentVideo, 'enum DMTentRestore {', '// MARK: - 影片來源');
  assert.match(restore, /guard let native = tab\.native, !native\.isOnScreen, let started = tab\.videoStartedAt,\s*BrowserTentPolicy\.lendable\(tab\) else \{ return nil \}/);
  const valid = slice(restore, 'static func stillValid(', '\n    }\n');
  for (const condition of ['BrowserTentPolicy.lendable(tab)', 'native.navigationGeneration == ticket.navigationGeneration',
    'native.pageURL == ticket.pageURL', 'tab.lastActiveAt == ticket.lastActiveAt', 'tab.videoStartedAt == ticket.videoStartedAt',
    '!native.isOnScreen']) {
    assert.ok(valid.includes(condition), condition);
  }
  assert.match(tentVideo, /private func sourceChanged\(\) \{\s*if lentID != nil \{ evaluate\(\) \} else \{\s*expireRestoreIfTakenOver\(\)/);
  assert.match(backend, /isOnScreen: onScreen, navigationGeneration: browser\.navigationGeneration,\s*pageURL: browser\.currentURLString\)/);
  // 守：「進倒放那一刻」只算新的倒放畫面掛上（換到倒放、打開私訊框、換手），框被收起又出現不算——不把主視窗正在看的影片吸進來。
  assert.match(tentVideo, /containers\.append\(WeakContainer\(container\)\)\s*entryPending = true/);
  assert.match(evaluate, /guard entryPending else \{ return \}\s*entryPending = false\s*if let pick = DMTentPick\.onEnter\(source\.tabs\(\), dismissed: dismissed\) \{ lend\(pick, into: container\) \}/);
  // 守：影片容器跟動畫的「原生畫面先藏起來」是同一套（GlobalDMNativePageHost）。
  assert.match(tentVideo, /final class DMTentVideoContainer: NSView, GlobalDMNativePageHost \{/);
  // 守（第 4 條）：挑分頁的規則。
  assert.match(tentVideo, /if let selected = pool\.first\(where: \\\.isSelected\) \{ return selected\.id \}/);
  assert.match(tentVideo, /guard let tab = candidates\(tabs, dismissed: dismissed\)\.first\(where: \{ \$0\.id == id \}\) else \{ return false \}\s*return !tab\.isOnScreen/);
  assert.match(tentVideo, /guard lentID == nil, let container = visibleContainer, isActive\(container\),/);
});

test('cards: priority, and the pairing card reads only the expiry (the code never reaches the tent)', () => {
  // 守（第 11 條）：等你核准 ＞ 配對進行中 ＞ 回覆中；「稍後」只收這一次的核准。
  assert.match(pane, /if approval, !approvalSnoozed \{ return \.approval\(target: target\) \}\s*if let expires = pairingExpiresAt, expires > now \{ return \.pairing\(remaining: expires\.timeIntervalSince\(now\)\) \}\s*if running \{ return \.reply\(target: target, preview: preview\) \}\s*return nil/);
  assert.match(pane, /guard case \.pairing\(let view\) = card else \{ return nil \}\s*return view\.expiresAt/);
  // 守：倒放的檔案一個字都不碰配對碼（碼只在綁住的那一頁看得到時顯示）；卡片的配對 case 只帶剩幾秒。
  for (const [name, source] of tentFiles) {
    assert.doesNotMatch(code(source), /pairingCode|displayCode|spacedCode|callbackHost/, name);
  }
  assert.match(pane, /case pairing\(remaining: TimeInterval\)/);
  // 守：核准仍在 Island（D54）：卡上的鈕只帶過去；回覆中可以停止；打開配對頁＝回到有 Browser 的形態、把配對分頁叫到前面。
  assert.match(pane, /case \.approveInIsland:\s*store\.revealApprovalInIsland\(\)/);
  assert.match(pane, /case \.stop:\s*store\.stop\(\)/);
  assert.match(pane, /case \.openPairing:[\s\S]*GlobalDMDeskController\.shared\.setForm\(\.outerPortrait\)\s*DMBrowser\.shared\.revealConnectTab\(\)/);
  // 守：「打開私訊框」回到對話（不是 Browser）；W184 審查（房 AB #4）：走 showContent（轉換中排隊、倒放先立起到外直），不直接 setForm（轉換中會被拒）。
  assert.match(pane, /case \.openBox:[\s\S]{0,200}GlobalDMDeskController\.shared\.showContent \{\s*store\.isBrowsing = false/);
  assert.doesNotMatch(pane.slice(pane.indexOf('case .openBox:'), pane.indexOf('case .openBox:') + 400), /setForm\(/);
  // 守：卡片蓋著（或［連線］卡蓋著）時影片藏在下面，聲音照播（沒有還回）。
  assert.match(pane, /DMTentVideoSurface\(video: video, hover: hover, covered: cardShowing \|\| webSheetActive, radius: radius\)/);
  assert.match(tentVideo, /func applyCovered\(\) \{\s*for view in subviews \{ view\.isHidden = covered \}/);
});

test('no capture shield in the tent; the main window keeps a placeholder with 拿回來 that the CEF container yields to', () => {
  // 守（第 12 條）：倒放不持有 WindowCaptureShield（框裡沒有敏感內容）。
  for (const [name, source] of tentFiles) assert.doesNotMatch(code(source), /WindowCaptureShield/, name);
  assert.doesNotMatch(code(lending), /WindowCaptureShield\.shared\.hold/);
  // 守（第 8 條）：原分頁那一格疊佔位卡；按鈕掛 BrowserChromeHitLayer，CEF 容器才讓出點擊。
  assert.match(runtime, /\.overlay \{ if runtime\.lentTabID == tabID \{ BrowserTentPlaceholder \{ runtime\.takeBackLentTab\(\) \} \} \}/);
  assert.match(slice(lending, 'struct BrowserTentPlaceholder: View {', '\n}\n'), /\.background\(BrowserChromeHitLayer\(\)\)/);
  // 守：倒放框的控制鈕也掛 BrowserChromeHitLayer；影片容器照抄 BrowserChromeAwareContainerView 的讓位。
  assert.ok((pane.match(/\.background\(BrowserChromeHitLayer\(\)\)/g) ?? []).length >= 3);
  assert.match(tentVideo, /BrowserChromeHitLayer\.LayerView\.ownsChromePoint\(superview\.convert\(point, to: nil\), in: window\)/);
  // 守（第 10 條）：「回到 Browser」＝還回（鍵盤給頁面）＋主視窗切到 Browser 工作區選那個分頁＋叫到前面。
  assert.match(tentVideo, /returnLent\(focus: true\)\s*source\.openBrowser\(id\)/);
  assert.match(tentVideo, /NotificationCenter\.default\.post\(name: \.tatwoOpenWorkOSWindow, object: TatwoPage\.chat\.rawValue\)/);
  assert.match(tentVideo, /NotificationCenter\.default\.post\(name: \.tatwoChatSelectMode, object: ChatRunMode\.browser\.rawValue\)/);
  // 守：選分頁走 Browser 工作區既有的 foregroundTabRequest（同點連結開新分頁）；分頁在別的空間先切過去。
  assert.match(tentVideo, /if let tab \{ BrowserWorkSpaceRuntime\.shared\.requestForeground\(tab\) \}/);
  assert.match(runtime, /func requestForeground\(_ id: UUID\) \{\s*guard owner == nil, workTabs\.contains\(where: \{ \$0\.id == id \}\) else \{ return \}\s*foregroundTabRequest = \(id, foregroundTabRequest\.serial &\+ 1\)/);
  // Cross-space foreground selection and bookmark expansion run in browser-dia-sidebar-checks.swift.
  // 守：Browser 工作區那個檔的行數上限照舊（browser-workspace-design／w114 守 1300）。
  assert.ok(design.split('\n').length <= 1300);
});

test('UI tokens and identifiers: fonts 17/15/13/11 from DMPhone, 44pt buttons, glass not blue, new ids tatwo.dm.tent.*', () => {
  for (const [name, source] of [...tentFiles, ['BrowserTentLending.swift', lending]]) {
    assert.doesNotMatch(source, /\.font\(\.system\(size: \d/, `${name}: font sizes come from DMPhone.TextSize`);
    assert.doesNotMatch(source, /\.borderedProminent|Color\.blue|\.accentColor/, `${name}: no blue system buttons`);
    assert.doesNotMatch(source, /\.frame\(width: (2[0-9]|3[0-9]), height/, `${name}: buttons are at least 44`);
  }
  assert.match(pane, /\.frame\(width: DMPhone\.touch, height: DMPhone\.touch\)/);
  assert.match(pane, /\.frame\(height: DMPhone\.touch\)/);
  assert.match(pane, /\.frame\(maxWidth: \.infinity, minHeight: DMPhone\.touch\)/);
  for (const id of ['tatwo.dm.tent.video', 'tatwo.dm.tent.controls', 'tatwo.dm.tent.source', 'tatwo.dm.tent.backToBrowser',
    'tatwo.dm.tent.dismiss', 'tatwo.dm.tent.empty', 'tatwo.dm.tent.openBrowser', 'tatwo.dm.tent.card.approval',
    'tatwo.dm.tent.card.approval.island', 'tatwo.dm.tent.card.approval.later', 'tatwo.dm.tent.card.pairing',
    'tatwo.dm.tent.card.pairing.open', 'tatwo.dm.tent.card.reply', 'tatwo.dm.tent.card.reply.stop',
    'tatwo.dm.tent.card.reply.open', 'tatwo.dm.tent.placeholder', 'tatwo.dm.tent.placeholder.takeBack']) {
    assert.ok([tentVideo, pane, lending].some(source => source.includes(`"${id}"`)), id);
  }
  // 守：舊的識別碼 tatwo.dm.tent 留在倒放整塊上（inventory §3.2；w184-forms 也守）。
  assert.match(content, /\.accessibilityIdentifier\("tatwo\.dm\.tent"\)/);
  assert.match(content, /GlobalDMTentPane\(store: store, model: model, video: \.shared\)/);
});

test('executable self-test w184tent covers the brief', () => {
  assert.match(selfTest, /TATWO2_SELFTEST"\] == "w184tent"[\s\S]{0,200}DMTentAcceptance\.run\(\)/);
  for (const label of ['A1 never lent', 'B1 entering the tent', 'B4 a dismissed tab', 'B6 an empty tent collects', 'C1 when the transition ends',
    'C3 leaving the tent gives the page back synchronously', 'C4 closing the box', 'C5 docked ↔ floating hand-off', 'C6 a closed tab',
    'C7 a main-window command', 'C8 fullscreen returns', 'C9 AI control', 'C10 關掉子畫面', 'C11 回到 Browser', 'C12 a card covering',
    'C13 docked box only ordered out', 'C13 hidden then shown again within the grace', 'C13 docked hidden, floating box takes over',
    'C13 a fully covered (occluded) box', 'C13 when the hidden box is shown again', 'C13 an empty tent that is hidden and shown again',
    'C14 control: hidden past the grace', 'C14 while the ticket exists the main window shows the tab', 'C14 the main window selected the tab and left it again',
    'C14 the tab navigated in the main window', 'C14 the tab changed URL inside the same document', 'C14 the tab went to a non-video page',
    'C14 the main window already shows the tab when it is returned', 'C14 the main window took over, the ticket is void',
    'D1 a tab lent to the tent', 'E1 in the tent ⌘W', 'F1 priority', 'F4 配對進行中', 'G1 no video', 'H1 tent with a video', 'H2 tent with the hover controls',
    'H3 empty tent', 'H5 the three cards']) {
    assert.ok(acceptance.includes(label), label);
  }
});
