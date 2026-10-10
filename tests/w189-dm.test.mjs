import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const read = path => readFileSync(`App/Sources/Tatwo2/${path}`, 'utf8');
function block(source, marker) {
  const start = source.indexOf(marker);
  assert.ok(start >= 0, marker);
  const brace = source.indexOf('{', start);
  let depth = 1, end = brace + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return source.slice(brace + 1, end - 1);
}
function swiftProbe(name, source) {
  const root = mkdtempSync(join(tmpdir(), 'w189-dm-fixture-'));
  try {
    writeFileSync(join(root, 'main.swift'), source);
    const compile = spawnSync('/usr/bin/swiftc', [join(root, 'main.swift'), '-o', join(root, 'probe')], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(join(root, 'probe'), [], { encoding: 'utf8', timeout: 20000 });
    console.log(`${name} ${result.stdout.split("\n").find(line => line.startsWith("SUMMARY")) ?? "SUMMARY missing"}`);
    assert.equal(result.status, 0, `${name}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /SUMMARY failures=0/);
  } finally { rmSync(root, { recursive: true, force: true }); }
}
const cocoa = `
import AppKit
var failures = 0
func check(_ value: Bool, _ label: String) {
  if !value { failures += 1 }
  print("\\(value ? "PASS" : "FAIL") \\(label)")
}
func finish() { print("SUMMARY failures=\\(failures)"); exit(failures == 0 ? 0 : 1) }
class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
func key(_ window: NSWindow, code: UInt16 = 53, flags: NSEvent.ModifierFlags = [], time: TimeInterval = 10, repeatKey: Bool = false) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time,
    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
}
let app = NSApplication.shared
`;
test('DM-01: Esc belongs to the key window; composing never cancels an Island approval', () => {
  const branch = block(read('Shell/TatwoIslandShell.swift'), 'if event.type == .keyDown');
  swiftProbe('DM-01', cocoa + `
class State { var collapsed = false; func handleCollapseEvent(_ event: Event) { collapsed = true }; enum Event { case escape } }
class IslandNotice {
 static let shared = IslandNotice(); var current: Request? = Request(); var cancelled = false
 struct Request { let id = UUID() }; enum Decision { case cancel }
 func resolve(_ decision: Decision, id: UUID) { cancelled = true; current = nil }
}
class GlobalDMPanelController {
 static func isComposing(in window: NSWindow) -> Bool { (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true }
}
class Fixture {
 let state = State(); let panel = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
 func route(_ event: NSEvent) -> NSEvent? { ${branch}; return event }
}
let fixture = Fixture()
let dm = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
let text = NSTextView(frame: .zero); dm.contentView = text; dm.makeFirstResponder(text)
_ = fixture.route(key(dm))
check(!IslandNotice.shared.cancelled, "DM Esc keeps pending approval")
IslandNotice.shared.current = IslandNotice.Request(); IslandNotice.shared.cancelled = false
text.setMarkedText("fixture", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
_ = fixture.route(key(dm))
check(!IslandNotice.shared.cancelled && text.hasMarkedText(), "DM composing Esc stays with input")
IslandNotice.shared.current = IslandNotice.Request(); IslandNotice.shared.cancelled = false
fixture.panel.contentView = NSTextView(frame: .zero)
let islandText = fixture.panel.contentView as! NSTextView; fixture.panel.makeFirstResponder(islandText)
islandText.setMarkedText("fixture", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
_ = fixture.route(key(fixture.panel))
check(!IslandNotice.shared.cancelled, "Island input composing cannot reject")
islandText.unmarkText()
IslandNotice.shared.current = IslandNotice.Request(); IslandNotice.shared.cancelled = false
_ = fixture.route(key(fixture.panel))
check(!IslandNotice.shared.cancelled, "Island unmarked input cannot reject")
fixture.panel.makeFirstResponder(nil)
_ = fixture.route(key(fixture.panel))
check(IslandNotice.shared.cancelled, "Island own keyboard can cancel")
finish()
`);
});

const hotkeyFixtures = `
import Combine
@MainActor class GlobalHotkeyMonitor { static let shared = GlobalHotkeyMonitor(); func cancelPendingChord() {} }
enum GlobalDMTarget: String, Hashable { case assistant, chatGPT; var storageValue: String { rawValue } }
struct GlobalDMDirectKey: Hashable {
 let keyCode: UInt16; var display: String { "fixture" }
 init?(keyCode: UInt16) { self.keyCode = keyCode }
 static let down = Self(keyCode: 125)!, up = Self(keyCode: 126)!, tab = Self(keyCode: 48)!
}
enum GlobalDMDirectKeyVerdict: Equatable { case ok, unsupported, occupied(GlobalDMDirectKey) }
struct GlobalDMDirectKeyRules {
 static func verdict(_ key: GlobalDMDirectKey, for target: GlobalDMTarget, in keys: [GlobalDMTarget: GlobalDMDirectKey], formKey: GlobalDMDirectKey) -> GlobalDMDirectKeyVerdict { .ok }
}
struct GlobalDMFormKeyBook {
 static let standard = GlobalDMDirectKey.tab
 static func load(from defaults: UserDefaults) -> GlobalDMDirectKey { standard }
 static func save(_ key: GlobalDMDirectKey, to defaults: UserDefaults) {}
 static func verdict(_ key: GlobalDMDirectKey, directKeys: [GlobalDMTarget: GlobalDMDirectKey]) -> GlobalDMDirectKeyVerdict { .ok }
}
@MainActor class GlobalDMStore {
 @Published var isEnabled = true
 @Published var directKeys: [GlobalDMTarget: GlobalDMDirectKey] = [.chatGPT: GlobalDMDirectKey(keyCode: 5)!]
 func setDirectKey(_ key: GlobalDMDirectKey?, for target: GlobalDMTarget) -> GlobalDMDirectKeyVerdict { directKeys[target] = key; return .ok }
}
typealias GlobalDMCarbonHotKeys = GlobalDMDeskFakeHotKeyBackend
`;
function hotkeySource() {
  const source = read('DM/GlobalDMHotKeys.swift');
  return source.slice(0, source.indexOf('/// Carbon 版')) + '\n@MainActor final class GlobalDMDeskFakeHotKeyBackend: GlobalDMHotKeyBackend {' +
    block(read('DM/GlobalDMDeskAcceptance.swift'), 'final class GlobalDMDeskFakeHotKeyBackend') + '}';
}
test('DM-02: collapse arrows never register globally; foreground routing and default direct G remain', () => {
  const hasAppRouter = read('DM/GlobalDMHotKeys.swift').includes('func handleAppKey');
  swiftProbe('DM-02', cocoa + hotkeyFixtures + hotkeySource() + `
MainActor.assumeIsolated {
let fake = GlobalDMDeskFakeHotKeyBackend(), store = GlobalDMStore()
let hotkeys = GlobalDMHotKeys(backend: fake)
var actions: [GlobalDMHotKeys.Action] = []; hotkeys.onAction = { actions.append($0) }
hotkeys.install(store: store)
check(!fake.live.values.contains(125) && !fake.live.values.contains(126), "expanded: arrows stay available to other apps")
check(hotkeys.registeredKeys.contains(GlobalDMDirectKey(keyCode: 5)!), "default direct G remains global")
fake.press(keyCode: 125); check(actions.isEmpty, "other app down cannot collapse")
actions = []; hotkeys.isCollapsed = true
check(!fake.live.values.contains(125) && !fake.live.values.contains(126), "collapsed: arrows stay available to other apps")
fake.press(keyCode: 126); check(actions.isEmpty, "other app up cannot restore")
${hasAppRouter ? `
let window = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
hotkeys.isCollapsed = false; actions = []
_ = hotkeys.handleAppKey(key(window, code: 125, flags: [.option, .command]), appActive: false)
check(actions.isEmpty, "local event in inactive panel does not collapse")
let collapsed = hotkeys.handleAppKey(key(window, code: 125, flags: [.option, .command]), appActive: true)
check(collapsed == nil && actions == [.collapse], "foreground down collapses")
hotkeys.isCollapsed = true; actions = []
let restored = hotkeys.handleAppKey(key(window, code: 126, flags: [.option, .command]), appActive: true)
check(restored == nil && actions == [.restore], "foreground up restores")
hotkeys.isSuspended = true; actions = []
_ = hotkeys.handleAppKey(key(window, code: 126, flags: [.option, .command]), appActive: true)
check(actions.isEmpty, "capture suspends app arrows")
hotkeys.isSuspended = false
` : ''}
store.setDirectKey(nil, for: .chatGPT)
check(fake.live.isEmpty, "each direct key can be disabled independently")
hotkeys.uninstall()
check(fake.registerCount == fake.unregisterCount, "all registrations removed")
finish()
}
`);
});
test('DM-02: settings card can turn off each direct key and explains other-app scope', () => {
  const card = read('DM/GlobalDMDeskViews.swift').split('struct GlobalDMSettingsCard: View')[1];
  assert.match(card, /setDirectKey\(nil, for: target\)/);
  assert.match(card, /其他 App/);
  assert.match(card, /只在 TATWO/);
});

test('DM-03: DM ChatGPT new-chat shortcut cannot open the main Coder window', () => {
  const closure = block(read('Shell/AppShell.swift'), 'NSEvent.addLocalMonitorForEvents(matching: .keyDown)');
  swiftProbe('DM-03', cocoa + `
class TatwoWorkOSWindow: KeyWindow {}
class GlobalDMPanelController { static func isComposing(in window: NSWindow) -> Bool { (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true } }
enum TatwoNewChatShortcutCatalog { static func matchesAlternate(_ event: NSEvent) -> Bool { event.keyCode == 31 && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .shift] } }
class Fixture {
 var coderNewChats = 0
 func requestNewChatFromShortcut(_ sender: Any?) { coderNewChats += 1 }
 func route(_ event: NSEvent) -> NSEvent? { let monitor: (NSEvent) -> NSEvent? = { ${closure} }; return monitor(event) }
}
let fixture = Fixture()
let dm = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
let main = TatwoWorkOSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
let other = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
let dmEvent = key(dm, code: 31, flags: [.command, .shift])
check(fixture.route(dmEvent) != nil && fixture.coderNewChats == 0, "DM event left to its ChatGPT router, Coder unchanged")
fixture.coderNewChats = 0
check(fixture.route(key(other, code: 31, flags: [.command, .shift])) != nil && fixture.coderNewChats == 0, "settings window cannot open Coder")
fixture.coderNewChats = 0
check(fixture.route(key(main, code: 31, flags: [.command, .shift])) == nil && fixture.coderNewChats == 1, "main window retains Coder new chat")
finish()
`);
});

test('DM-04: external composer replacements discard stale undo without clearing another field history', () => {
  const source = read('Chat/ChatPageAppKitBridges.swift');
  const replacement = block(source, 'if text != context.coordinator.lastReportedText, textView.string != text');
  const ownsUndo = source.includes('private lazy var draftUndoManager');
  const helper = source.includes('func replaceExternalDraft') ? `func replaceExternalDraft(_ text: String) { ${block(source, 'func replaceExternalDraft')} }` : '';
  swiftProbe('DM-04', cocoa + `
class UndoWindow: KeyWindow { let history = UndoManager(); override var undoManager: UndoManager? { history } }
class ComposerText: NSTextView {
 ${ownsUndo ? 'private lazy var draftUndoManager = UndoManager(); override var undoManager: UndoManager? { draftUndoManager }' : ''}
 ${helper}
 func invalidateSlashHighlightStyle() {}
}
class Coordinator { var lastReportedText = "fixture" }
class Context { let coordinator = Coordinator() }
func replace(_ text: String, in textView: ComposerText) { let context = Context(); ${replacement} }
for newText in ["", "sample restored", "/example "] {
 let window = UndoWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
 let text = ComposerText(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
 window.contentView = text; text.allowsUndo = true; text.isRichText = false; window.makeFirstResponder(text)
 text.insertText("fixture", replacementRange: NSRange(location: NSNotFound, length: 0)); text.breakUndoCoalescing()
 check(text.undoManager?.canUndo == true, "fixture really records typing undo")
 replace(newText, in: text)
 check(text.string == newText && text.undoManager?.canUndo == false, "replacement clears stale typing undo")
 if text.undoManager?.canUndo == false { text.undoManager?.undo(); check(text.string == newText, "submit/restore/slash then Undo is safe") }
}
let window = UndoWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
let text = ComposerText(frame: .zero); window.contentView = text; text.allowsUndo = true; text.string = "fixture"
let sibling = NSObject(); window.history.registerUndo(withTarget: sibling) { _ in }
replace("sample", in: text)
check(window.history.canUndo, "another field's undo survives")
finish()
`);
});

test('DM-05: pointer down and drag invalidate a bare modifier chord in local and global monitors', () => {
  const source = read('DM/GlobalHotkeyMonitor.swift');
  const consume = block(source, 'private func consume(_ event: NSEvent)');
  swiftProbe('DM-05', cocoa + read('DM/ModifierChordDetector.swift') + `
extension Notification.Name { static let tatwoToggleGlobalDM = Notification.Name("fixtureToggle") }
enum GlobalDMDeskSettings { static func chordToggleEnabled() -> Bool { true } }
class FixtureMonitor { var detector = ModifierChordDetector(); func consume(_ event: NSEvent) { ${consume} } }
func flags(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> NSEvent {
 NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0,
 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
}
var toggles = 0
let observer = NotificationCenter.default.addObserver(forName: .tatwoToggleGlobalDM, object: nil, queue: nil) { _ in toggles += 1 }
let probe = FixtureMonitor()
for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
 toggles = 0
 probe.consume(flags([.command, .option], at: 10))
 let mouse = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [.command, .option], timestamp: 10.1,
 windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
 probe.consume(mouse); probe.consume(flags([], at: 10.2))
 check(toggles == 0, "pointer \\(type.rawValue) never toggles on modifier release")
}
toggles = 0; probe.consume(flags([.command, .option], at: 20)); probe.consume(flags([], at: 20.2))
check(toggles == 1, "bare chord still works after a disqualified gesture")
NotificationCenter.default.removeObserver(observer)
finish()
`);
  for (const event of ['leftMouseDown', 'rightMouseDown', 'otherMouseDown', 'leftMouseDragged', 'rightMouseDragged', 'otherMouseDragged']) assert.ok(source.includes(`.${event}`), event);
  assert.equal((source.match(/matching: Self\.chordEvents/g) ?? []).length, 2, 'local and global watch the same pointer events');
});

test('DM-06: closing docked, floating or tent DM keeps main visible and next Escape available', () => {
  const escape = block(read('DM/GlobalDMPanelController.swift'), 'static func routeEscape');
  const mainEscape = block(read('Shell/AppShell.swift'), 'override func cancelOperation');
  swiftProbe('DM-06', cocoa + `
class TatwoWorkOSWindow: KeyWindow { override func cancelOperation(_ sender: Any?) { ${mainEscape} } }
enum GlobalDMForm { case fixture, tent }
class GlobalDMStore {
 var isOpen = true, isFloatingOpen = true, isBrowsing = false, isBrowsingBeside = false
 var isModeCardOpen = false, isPickerOpen = false, isEditingDirectKeys = false
 func endChatGPTVoiceForEscape() -> Bool { false }; func dismissChatGPTLayers() -> Bool { false }
}
class GlobalDMDuo { static let shared = GlobalDMDuo(); var existing: GlobalDMStore? }
enum DMBrowserPanelEscape { static func closePanel(in window: NSWindow) -> Bool { false } }
enum GlobalDMNativePageMask { static func isInsideNativePage(_ view: NSView) -> Bool { false } }
@MainActor class Router {
 static func isComposing(in window: NSWindow) -> Bool { (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true }
 static func routeEscape(_ event: NSEvent, window: NSWindow, floating: NSWindow?, store: GlobalDMStore, form: GlobalDMForm) -> NSEvent? { ${escape} }
}
MainActor.assumeIsolated {
 let main = TatwoWorkOSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
 let dm = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
 for style in 0..<3 {
  let store = GlobalDMStore()
  let result = Router.routeEscape(key(dm), window: dm, floating: style == 1 ? dm : nil, store: store, form: style == 2 ? .tent : .fixture)
  check(result == nil && (style == 1 ? !store.isFloatingOpen : !store.isOpen), "DM style \\(style) closes")
  main.makeKeyAndOrderFront(nil)
  main.cancelOperation(nil)
  check(main.isVisible, "fresh Escape never closes main")
  let card = GlobalDMStore(); card.isModeCardOpen = true
  check(Router.routeEscape(key(main, time: 10.1), window: main, floating: nil, store: card, form: .fixture) == nil && !card.isModeCardOpen,
        "immediate Escape after DM closes the next card")

 }
 finish()
}
`);
});

test('DM-07: mixed clipboard text wins in Coder and both DM columns; image-only and explicit image still attach', () => {
  const dm = block(read('DM/GlobalDMStore.swift'), 'func pasteAttachment(from pasteboard: NSPasteboard, preferText:');
  const coder = block(read('Facade/ChatPageModel.swift'), 'func pasteClipboardImage(from pasteboard: NSPasteboard, preferText:');
  let policy = '';
  try { policy = read('Chat/ComposerPastePolicy.swift'); } catch {}
  swiftProbe('DM-07', cocoa + policy + `
struct GlobalDMAttachment { let name: String, mime: String; let fileURL: URL?; let data: Data? }
enum Target: Hashable { case assistant, chatGPT }
class Sink { var count = 0 }
class Model { func dmSaveAttachment(data: Data, suggestedName: String) -> URL? { URL(fileURLWithPath: "/tmp/fixture.png") } }
enum ChatGPTSpaceModel {
 static func pngData(_ image: NSImage) -> Data? { image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } }
 static func attach(from board: NSPasteboard, into sink: Sink) -> Bool { sink.count += 1; return true }
}
class DM {
 var target = Target.assistant, notice: String?, model: Model? = Model(), chatGPTSink = Sink()
 var attachmentsByTarget: [Target: [GlobalDMAttachment]] = [:]
 func attachmentBlock(for target: Target) -> String? { nil }
 func addAttachments(_ urls: [URL]) { attachmentsByTarget[target] = urls.map { GlobalDMAttachment(name: "fixture", mime: "fixture", fileURL: $0, data: nil) } }
 func attachments(for target: Target) -> [GlobalDMAttachment] { attachmentsByTarget[target] ?? [] }
 func pasteAttachment(from pasteboard: NSPasteboard, preferText: Bool = true) -> Bool { ${dm} }
 var count: Int { attachments(for: target).count + chatGPTSink.count }
}
class Coder {
 var isLive = true, count = 0
 func rejectRemoteWrite(_ kind: String) -> Bool { false }
 func appendDroppedPath(_ path: String) { count += 1 }
 func appendDroppedImageData(_ data: Data, suggestedName: String) { count += 1 }
 func pasteClipboardImage(from pasteboard: NSPasteboard, preferText: Bool = true) -> Bool { ${coder} }
}
let board = NSPasteboard.withUniqueName()
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
bitmap.bitmapData?.initialize(repeating: 0, count: 4)
let png = bitmap.representation(using: .png, properties: [:])!
for target in [Target.assistant, .chatGPT] {
 let store = DM(); store.target = target
 board.clearContents(); board.setData(png, forType: .png); board.setString("fixture\\tsample\\nexample", forType: .string)
 check(!store.pasteAttachment(from: board) && store.count == 0, "DM text+image stays text, with no attachment")
 store.attachmentsByTarget = [:]; store.chatGPTSink.count = 0
 check(store.pasteAttachment(from: board, preferText: false) && store.count == 1, "DM explicit image still attaches")
 board.clearContents(); board.setData(png, forType: .png)
 check(store.pasteAttachment(from: board) && store.count == 2, "DM image-only attaches")
}
let model = Coder()
board.clearContents(); board.setData(png, forType: .png); board.setString("fixture\\tsample\\nexample", forType: .string)
check(!model.pasteClipboardImage(from: board) && model.count == 0, "Coder text+image stays text")
model.count = 0
check(model.pasteClipboardImage(from: board, preferText: false) && model.count == 1, "Coder explicit image still attaches")
board.clearContents(); board.setData(png, forType: .png)
check(model.pasteClipboardImage(from: board) && model.count == 2, "Coder image-only attaches")
board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/tmp/fixture.txt") as NSURL]); board.setString("fixture.txt", forType: .string)
let files = Coder(); check(files.pasteClipboardImage(from: board) && files.count == 1, "file URL remains a file attachment")
board.releaseGlobally(); finish()
`);
});

test('DM-06 layers: main window has an empty cancelOperation and no sheet Escape monitor', () => {
  const mainEscape = block(read('Shell/AppShell.swift'), 'override func cancelOperation');
  assert.equal(mainEscape.trim(), '');
  assert.doesNotMatch(read('New/CoderProjectSpaceSwitcher.swift'), /CoderSheetEscapeGuard|addLocalMonitorForEvents/);
  assert.doesNotMatch(read('DM/GlobalDMPanelController.swift'), /CoderSheetEscapeGuard/);
});

test('DM-08: key capture cancels the chord in either monitor order and keeps errors visible', () => {
  const capture = block(read('DM/GlobalDMDeskViews.swift'), 'private func handle(_ event: NSEvent)');
  const toggle = block(read('DM/GlobalDMPanelController.swift'), 'func handleToggle()');
  swiftProbe('DM-08', cocoa + read('DM/ModifierChordDetector.swift') + `
enum GlobalDMTarget { case assistant }
enum GlobalDMDirectKeyVerdict: Equatable { case ok, unsupported; func message(title: (GlobalDMTarget) -> String) -> String { "fixture error" } }
@MainActor class GlobalHotkeyMonitor {
 static let shared = GlobalHotkeyMonitor(); var detector = ModifierChordDetector()
 func cancelPendingChord() { ${block(read('DM/GlobalHotkeyMonitor.swift'), 'func cancelPendingChord()')} }
}
@MainActor class GlobalDMHotKeys {
 static let shared = GlobalDMHotKeys(); var isSuspended = false
 func assign(keyCode: UInt16, to target: GlobalDMTarget, store: GlobalDMStore) -> GlobalDMDirectKeyVerdict { keyCode == 4 ? .unsupported : .ok }
 func assignFormKey(keyCode: UInt16, store: GlobalDMStore) -> GlobalDMDirectKeyVerdict { .ok }
}
class GlobalDMStore {
 var isEnabled = true, isOpen = true, isFloatingOpen = true, isEditingDirectKeys = true
 func title(for target: GlobalDMTarget) -> String { "fixture" }
 func toggleDocked() { isOpen.toggle() }; func openFloating() { isFloatingOpen = true }
}
enum GlobalDMToggleAction { case ignore, closeFloating, toggleDocked, openFloating
 static func resolve(enabled: Bool, floatingOpen: Bool, dockedFocused: Bool, appActive: Bool, mainWindowVisible: Bool) -> Self { .closeFloating }
}
@MainActor class Capture {
 enum Slot { case target(GlobalDMTarget), form }
 var slot: Slot? = .target(.assistant), store: GlobalDMStore?, hotkeys: GlobalDMHotKeys?, window: NSWindow?, message: String?
 func end() { slot = nil; hotkeys?.isSuspended = false }
 func handle(_ event: NSEvent) -> NSEvent? { ${capture} }
}
@MainActor class Panel {
 let store: GlobalDMStore; var docked: NSWindow?, hostsWindows = false, mainWindowCovered = false
 init(_ store: GlobalDMStore) { self.store = store }
 func mainWindowOnScreenForUser() -> NSWindow? { nil }; func reconcile() {}
 func handleToggle() { ${toggle} }
}
MainActor.assumeIsolated {
 let dm = KeyWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
 for code in [UInt16(40), UInt16(4)] {
  let store = GlobalDMStore(), capture = Capture(); capture.store = store; capture.window = dm; capture.hotkeys = .shared
  GlobalDMHotKeys.shared.isSuspended = true
  _ = GlobalHotkeyMonitor.shared.detector.flagsChanged(.chord, at: 10)
  check(capture.handle(key(dm, code: code, flags: [.option, .command])) == nil, "capture takes the key before the gesture monitor")
  check(!GlobalHotkeyMonitor.shared.detector.flagsChanged([], at: 10.2), "release cannot toggle after capture ate keyDown")
  if code == 4 { check(capture.message == "fixture error" && capture.slot != nil, "blocked key explains why and keeps capture open") }
  let panel = Panel(store)
  GlobalDMHotKeys.shared.isSuspended = true; panel.handleToggle()
  check(store.isFloatingOpen, "suspended capture ignores a toggle notification")
  GlobalDMHotKeys.shared.isSuspended = false; panel.handleToggle()
  check(store.isFloatingOpen, "editing page stays open after a successful assignment")
 }
 finish()
}
`);
});

test('DM-10 / Sol D1: lock and classification flags do not change held-modifier gestures, including Duo', () => {
  swiftProbe('DM-10-Sol-D1', cocoa + read('DM/ModifierChordDetector.swift') + `
func gesture(_ locked: ModifierChordDetector.Flags) -> Bool {
 var detector = ModifierChordDetector()
 _ = detector.flagsChanged(locked, at: 0)
 _ = detector.flagsChanged(locked.union(.command), at: 1)
 _ = detector.flagsChanged(locked.union(.chord), at: 1.1)
 _ = detector.flagsChanged(locked.union(.option), at: 1.2)
 return detector.flagsChanged(locked, at: 1.3)
}
check(gesture([]), "ordinary bare chord works")
check(gesture(.capsLock), "Claude DM-10: Caps Lock chord works")
check(gesture([.capsLock, .other]), "Sol D1: locked Duo uses the same detector")
check(gesture(.other), "classification flags are not held modifiers")
for extra in [ModifierChordDetector.Flags.shift, .control, .function] {
 check(!gesture([.capsLock, extra]), "actually held extra modifiers disqualify the gesture")
}
var detector = ModifierChordDetector()
_ = detector.flagsChanged([.capsLock, .chord], at: 2); detector.keyDown(at: 2.1)
check(!detector.flagsChanged(.capsLock, at: 2.2), "a key press still disqualifies the locked chord")
finish()
`);
});

test('DM-11: visible permission UI updates grants and revocations without activating TATWO', () => {
  const monitor = read('DM/GlobalHotkeyMonitor.swift')
    .replaceAll('NSEvent.addLocalMonitorForEvents', 'FixtureEventMonitors.addLocalMonitorForEvents')
    .replaceAll('NSEvent.addGlobalMonitorForEvents', 'FixtureEventMonitors.addGlobalMonitorForEvents')
    .replaceAll('NSEvent.removeMonitor', 'FixtureEventMonitors.removeMonitor');
  swiftProbe('DM-11', cocoa + read('DM/ModifierChordDetector.swift') + `
import Combine
var fixtureTrusted = false
func AXIsProcessTrusted() -> Bool { fixtureTrusted }
enum GlobalDMDeskSettings { static func chordToggleEnabled() -> Bool { true } }
@MainActor enum FixtureEventMonitors {
 static var globalAdds = 0
 static func addLocalMonitorForEvents(matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? { NSObject() }
 static func addGlobalMonitorForEvents(matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? { globalAdds += 1; return NSObject() }
 static func removeMonitor(_ token: Any) {}
}
${monitor}
MainActor.assumeIsolated {
 NSApp.setActivationPolicy(.prohibited)
 let monitor = GlobalHotkeyMonitor(); var states: [Bool] = []
 let subscription = monitor.$isSystemWide.sink { states.append($0) }
 monitor.install()
 monitor.setPermissionSurfaceVisible(true, owner: "fixture")
 check(!monitor.isSystemWide && FixtureEventMonitors.globalAdds == 0, "initially no global keyboard observer without permission")
 fixtureTrusted = true
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(!NSApp.isActive, "fixture remained in the background")
 check(monitor.isSystemWide, "grant takes effect without didBecomeActive or a manual refresh")
 check(FixtureEventMonitors.globalAdds == 1, "grant installs exactly one global monitor")
 check(states.contains(true), "published state refreshes the menu and settings")
 fixtureTrusted = false
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(!monitor.isSystemWide, "revocation removes the observer without foreground activation")
 monitor.setPermissionSurfaceVisible(false, owner: "fixture")
 monitor.uninstall(); let installed = FixtureEventMonitors.globalAdds
 fixtureTrusted = true
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(!monitor.isSystemWide && FixtureEventMonitors.globalAdds == installed, "uninstall stops permission polling")
 subscription.cancel(); finish()
}
`);
});
test('DM-11: menu construction reads permission afresh and settings expose status and the settings button', () => {
  const make = block(read('DM/GlobalDMPhoneBox.swift'), 'static func make(for store:');
  const card = read('DM/GlobalDMDeskViews.swift').split('struct GlobalDMSettingsCard: View')[1];
  assert.match(make, /refreshAccessibilityPermission\(\)/);
  assert.match(card, /GlobalHotkeyMonitor\.shared/);
  assert.match(card, /isSystemWide/);
  assert.match(card, /openAccessibilitySettings\(\)/);
});
