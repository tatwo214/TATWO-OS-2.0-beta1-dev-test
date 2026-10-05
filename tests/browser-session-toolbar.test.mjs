// Session toolbar parity: real registry/store/runtime routing + complete SwiftUI typecheck
// (the latter is retained in browser-workspace-design.test.mjs). No live profiles or CEF.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const browser = 'App/Sources/Tatwo2/Browser/';
const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
const surface = read(browser + 'BrowserChatSessionsSection.swift');
const projection = read(browser + 'BrowserSessionProjection.swift');
const chrome = read(browser + 'BrowserWorkSpaceEmbeddedChrome.swift');
function section(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `Missing production boundary: ${start} / ${end}`);
  return source.slice(a, b);
}

test('one complete shared chrome/shortcut owner; explicit AnyView breaks the recursive Body type', () => {
  assert.match(design, /var body: some View \{ sessionRoutedContent \}/);
  const routing = section(projection, '@ViewBuilder var sessionRoutedContent', 'func selectForegroundTab');
  assert.match(routing, /session == nil, onClose == nil, store.selectedSpace.isSessionSpace/);
  assert.match(routing, /BrowserChatSessionSurface\(pick: pick, source: store.registry, sidebarStore: sidebarStore\)/);
  assert.match(routing, /\} else \{\s*workspaceBody\s*\}/);
  assert.doesNotMatch(routing, /workspaceToolbar|BrowserDailyNavigationControls|BrowserTranslationHost|\.background|\.onChange/);
  const borrowed = surface.slice(surface.indexOf('struct BrowserChatSessionSurface:'));
  assert.match(borrowed, /var body: AnyView \{\s*AnyView\(Group/);
  assert.match(borrowed, /if session.isUsable \{\s*BrowserWorkSpaceDesignView\(store: session.store, runtime: session.runtime,\s*sidebarStore: sidebarStore, session: session\)/);
  assert.doesNotMatch(borrowed, /BrowserChatSessionControls|BrowserWorkSpaceCEFSurface|EmbeddedBrowserToolbar|BrowserDailyNavigationControls/);
  assert.equal((design.match(/BrowserDailyNavigationControls\(/g) ?? []).length, 1);
  assert.match(design, /BrowserTranslationHost\(runtime: runtime, translator: translator, tabID: store.showsStartPage \? nil : store.selectedRegistryID\)/);
  assert.match(design, /if onClose == nil \{ browserActionsButton \}/);
  assert.match(design, /if onClose == nil \{ auxiliaryBrowserControls \}/);
  assert.match(read('tests/browser-workspace-design.test.mjs'), /join\(root, 'App\/Sources\/Tatwo2\/Browser\/BrowserSessionProjection.swift'\)/);
});

test('borrowed target cannot migrate data, fall back to workspace, or retain stale commands/find', () => {
  const adapter = section(projection, '@MainActor', '// MARK: - Shared view routing');
  assert.doesNotMatch(adapter, /\.selectThreadSpace\(|registry\.(?:move|removeSpace|close|openTab|addSpace)\(|\.shared\.mount\(/);
  assert.match(adapter, /runtime = BrowserWorkSpaceRuntime.forChat\("chat-browser-inspector", registry: registry, adoptsWorkSpaceTabs: true\)/);
  assert.match(adapter, /\$0.owner == \.workSpace\(spaceID: spaceID\) && !\$0.usesAgentContext/);
  assert.match(adapter, /threadID\(ofSpaceNamed: space.name\) != nil/);
  assert.match(adapter, /isUsable && selection.pick == pick && store.selectedRegistryID == pick.tabID/);
  assert.match(adapter, /guard selection.pick == pick else \{ return \}/);
  assert.match(adapter, /store\.\$selectedID\.dropFirst\(\)\.sink/);
  assert.match(design, /onChange\(of: runtime.foregroundTabRequest.serial\)[^\n]*selectForegroundTab\(id\)/);
  assert.match(projection, /if let session \{ session.selectForeground\(id\) \}\s*else \{ store.select\(registryID: id\) \}/);
  assert.match(projection, /\.id\(BrowserSessionProjection.Identity\(source: ObjectIdentifier\(store.registry\), pick: pick\)\)/);
  assert.match(design, /onChange\(of: store.selectedSpaceID\)[\s\S]*?command = nil; commandTabID = nil; tabSearchPresented = false; findPresented = false/);
  assert.match(design, /onChange\(of: store.selectedID\)[\s\S]*?command = nil; commandTabID = nil; findPresented = false/);
  for (const marker of ['func send(', 'func performBrowserAction(', 'private func submitSearch(']) {
    const source = marker === 'func send(' ? projection : design;
    assert.match(source.slice(source.indexOf(marker), source.indexOf(marker) + 220), /guard session\?\.acceptsCommands != false else \{ return \}/);
  }
  assert.match(design, /command: commandTabID == tabID \? command : nil/);
  assert.doesNotMatch(projection + surface, /BrowserWorkSpaceLifecycleModifier\(/);
});

test('sidebar geometry and commands stay on the outer container; page actions stay on the session store', () => {
  assert.match(design, /_sidebarStore = ObservedObject\(wrappedValue: sidebarStore \?\? store\)/);
  assert.match(design, /BrowserSidebarControls\(store: sidebarStore\)/);
  assert.match(design, /sidebarVisible: !sidebarStore.focusMode \|\| sidebarStore.sidebarInteractionActive \|\| sidebarStore.hoverRailShown/);
  assert.match(chrome, /action: sidebarStore.toggleSidebar/);
  assert.match(chrome, /Button\("關閉目前分頁"\) \{ store.close\(store.selectedID\) \}/);
  assert.match(chrome, /Button\("新增 space", action: sidebarStore.addSpace\)/);
  assert.match(design, /state: runtime.navigationTabID == store.selectedRegistryID \? runtime.navigationState : .blank/);
});

test('swiftc executes real session projection + registry + runtime: ownership, commands, popup, stale/invalid selection', {
  skip: process.platform !== 'darwin', timeout: 150_000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'browser-session-toolbar-'));
  try {
    const rawStubs = read('tests/fixtures/browser-workspace-runtime-stubs.swift');
    // Reuse only the native engine/profile signature doubles, not the fake registry.
    // The actual production registry, projection/store and runtime are compiled below.
    let engine = rawStubs.slice(0, rawStubs.indexOf('enum BrowserTabOwner:'))
      + section(rawStubs, 'enum EmbeddedBrowserView {', 'struct BrowserTab {')
      // Newer runtimes also reference lending signatures. Keep the real registry
      // below; borrow only the native dependency doubles, not fixture tab state.
      + section(rawStubs, 'enum BrowserTabReturnReason:', '// Engine double')
      + rawStubs.slice(rawStubs.indexOf('// Engine double'));
    engine = engine.replace('struct EmbeddedBrowserCommand { let id = UUID() }',
      'struct EmbeddedBrowserCommand { enum Action: Equatable { case reload, goBack, find(String) }; let id = UUID(); let action: Action }');
    engine = engine.replace('var live: Set<String> = []',
      'var deliveries: [(String, EmbeddedBrowserCommand.Action)] = []\n    var live: Set<String> = []');
    engine = engine.replace('selected = tabID; live = openTabIDs',
      'selected = tabID; live = openTabIDs\n        if let tabID, let command { deliveries.append((tabID, command.action)) }');
    const runtimeSource = read(browser + 'BrowserWorkSpaceCEFSurface.swift');
    const runtime = section(runtimeSource, '@MainActor', 'struct BrowserWorkSpaceCEFSurface:');
    const store = section(design, '@MainActor', '// MARK: - End local fixture model');
    const selection = section(surface, '@MainActor', 'struct BrowserChatSessionsSection:');
    const adapter = section(projection, '@MainActor', '// MARK: - Shared view routing');
    const send = projection.slice(projection.indexOf('    func send('), projection.lastIndexOf('\n}'));
    const fixture = join(dir, 'Checks.swift');
    writeFileSync(fixture, engine + '\n' + store + '\n' + selection + '\n' + runtime + '\n' + adapter + String.raw`
extension BrowserWorkSpaceRuntime {
    static func fixtureNormal(_ registry: BrowserTabRegistry) -> BrowserWorkSpaceRuntime {
        BrowserWorkSpaceRuntime(registry: registry)
    }
    static func fixtureSettings() { applyMemorySettings(.init(liveTabLimit: 0, sleepMinutes: 0)) }
}
@MainActor final class CommandHarness {
    let store: BrowserWorkSpaceStore
    let session: BrowserSessionProjection?
    var command: EmbeddedBrowserCommand?
    var commandTabID: UUID?
    init(store: BrowserWorkSpaceStore, session: BrowserSessionProjection? = nil) {
        self.store = store; self.session = session
    }
` + send + String.raw`
}
@main struct Checks {
    @MainActor static func main() {
        let normal = BrowserTabRegistry(storageURL: nil)
        let normalStore = BrowserWorkSpaceStore(registry: normal)
        let normalSpace = normal.spaces.first { !$0.isSessionSpace }!
        let url = URL(string: "https://example.org/session")!
        let normalTab = normal.openTab(owner: .workSpace(spaceID: normalSpace.id), url: url)
        let normalRuntime = BrowserWorkSpaceRuntime.fixtureNormal(normal)
        BrowserWorkSpaceRuntime.fixtureSettings()
        let normalSurface = UUID(), normalHost = normalRuntime.mount()
        precondition(normalRuntime.select(normalTab.id, surfaceID: normalSurface, command: nil) { _, _ in })
        let originalNormal = normal.tabs

        let chat = BrowserTabRegistry(storageURL: nil)
        let straySpace = chat.spaces.first { !$0.isSessionSpace }!
        let stray = chat.openTab(owner: .workSpace(spaceID: straySpace.id), url: url)
        let aSpace = chat.addSpace(name: "thread:" + UUID().uuidString)
        let bSpace = chat.addSpace(name: "thread:" + UUID().uuidString)
        let a1 = chat.openTab(owner: .workSpace(spaceID: aSpace.id), url: url)
        let a2 = chat.openTab(owner: a1.owner, url: url)
        let b1 = chat.openTab(owner: .workSpace(spaceID: bSpace.id), url: url)
        let bot = chat.openTab(owner: .bot(botID: "fixture"), url: url, isAgentTab: true)
        let agent = chat.openTab(owner: .chatSession(sessionID: "agent"), url: url, isAgentTab: true)
        let originalIDs = chat.tabs.map(\.id), originalOwners = chat.tabs.map(\.owner)
        let originalSpaces = chat.spaces
        let selection = BrowserChatSessionSelection()
        let aPick = BrowserChatSessionSelection.Pick(spaceID: aSpace.id, tabID: a1.id)
        selection.pick = aPick
        let a = BrowserSessionProjection(pick: aPick, registry: chat, selection: selection)
        precondition(a.isUsable && a.acceptsCommands)
        precondition(a.store.selectedRegistryID == a1.id && a.store.currentSpaceUUID == aSpace.id)
        precondition(chat.tabs.map(\.id) == originalIDs && chat.tabs.map(\.owner) == originalOwners)
        precondition(chat.spaces == originalSpaces && normal.tabs == originalNormal)
        precondition(chat.tabs.first { $0.id == stray.id }!.owner == stray.owner)
        precondition(a.runtime === BrowserWorkSpaceRuntime.forChat("chat-browser-inspector", registry: chat, adoptsWorkSpaceTabs: true))
        let profile = a.runtime.runtimeProfile.registryKey
        precondition(profile == TatwoBrowserProfileIdentity(sessionID: "chat-browser-inspector")!.dataStoreIdentifier)
        precondition(profile != normalRuntime.runtimeProfile.registryKey)
        let aSurface = UUID(), aHost = a.runtime.mount()
        precondition(aHost !== normalHost)
        let commands = CommandHarness(store: a.store, session: a)
        commands.send(.reload)
        precondition(commands.commandTabID == a1.id)
        precondition(a.runtime.select(a1.id, surfaceID: aSurface, command: commands.command) { space, popup in
            a.store.openPopup(spaceID: space, url: popup)
        })
        precondition(aHost.deliveries.last?.0 == a1.id.uuidString && aHost.deliveries.last?.1 == .reload)
        precondition(normalHost.deliveries.isEmpty && normal.tabs == originalNormal)
        let nativeA = aHost.nativeIDs[a1.id.uuidString]
        aHost.onFindResult?(a1.id.uuidString, 5, 2)
        precondition(a.runtime.findCount == 5 && a.runtime.findIndex == 2)

        // Background popup remains in this owner, without stealing the foreground pick.
        let beforePopup = chat.tabs.count
        aHost.onTabPopupRequested?(a1.id.uuidString, url)
        precondition(chat.tabs.count == beforePopup + 1 && chat.tabs.last?.owner == a1.owner)
        precondition(selection.pick == aPick && normal.tabs == originalNormal)
        // Foreground popup follows the actual runtime callback and the view's selection adapter.
        aHost.onTabForegroundRequested?(a1.id.uuidString, url)
        let foregroundID = a.runtime.foregroundTabRequest.tabID!
        a.selectForeground(foregroundID)
        precondition(selection.pick == .init(spaceID: aSpace.id, tabID: foregroundID))
        precondition(chat.tabs.first { $0.id == foregroundID }!.owner == a1.owner)
        let oldCommandID = commands.command!.id
        commands.send(.goBack)
        precondition(commands.command!.id == oldCommandID && !a.acceptsCommands)
        let foreground = BrowserSessionProjection(pick: selection.pick!, registry: chat, selection: selection)
        precondition(foreground.runtime === a.runtime && foreground.runtime.runtimeProfile.registryKey == profile)
        let fresh = CommandHarness(store: foreground.store, session: foreground)
        precondition(fresh.command == nil && fresh.commandTabID == nil)
        let foregroundSurface = UUID()
        // While another surface owns the NSView, even a valid target must not steal it.
        precondition(!a.runtime.select(foregroundID, surfaceID: foregroundSurface, command: nil) { _, _ in })
        a.runtime.detach(surfaceID: aSurface)
        precondition(foreground.runtime.select(foregroundID, surfaceID: foregroundSurface, command: nil) { _, _ in })
        precondition(aHost.nativeIDs[a1.id.uuidString] == nativeA)
        precondition(a.runtime.findCount == 0 && a.runtime.findIndex == 0)

        // Sibling tab selection/new blank tab/close feed the same Session-space selection.
        foreground.store.select(registryID: a2.id)
        precondition(selection.pick == .init(spaceID: aSpace.id, tabID: a2.id))
        let sibling = BrowserSessionProjection(pick: selection.pick!, registry: chat, selection: selection)
        sibling.store.addTab()
        let blankPick = selection.pick!
        precondition(blankPick.spaceID == aSpace.id && chat.tabs.last?.id == blankPick.tabID)
        precondition(chat.tabs.last?.owner == a1.owner && chat.tabs.last?.url == nil)
        let blank = BrowserSessionProjection(pick: blankPick, registry: chat, selection: selection)
        blank.store.close(blank.store.selectedID)
        precondition(selection.pick != nil && selection.pick!.spaceID == aSpace.id && selection.pick!.tabID != blankPick.tabID)

        // Cross-session change retires all stale publishers/commands; only B can be selected.
        let bPick = BrowserChatSessionSelection.Pick(spaceID: bSpace.id, tabID: b1.id)
        selection.pick = bPick
        let b = BrowserSessionProjection(pick: bPick, registry: chat, selection: selection)
        a.selectForeground(a2.id)
        a.store.select(registryID: a1.id)
        precondition(selection.pick == bPick)
        for id in [a1.id, stray.id, bot.id, agent.id, normalTab.id, UUID()] { b.selectForeground(id) }
        precondition(selection.pick == bPick && b.store.selectedRegistryID == b1.id)
        foreground.runtime.detach(surfaceID: foregroundSurface)
        let bSurface = UUID()
        precondition(b.runtime.select(b1.id, surfaceID: bSurface, command: nil) { _, _ in })
        precondition(b.runtime === a.runtime && b.runtime.runtimeProfile.registryKey == profile)
        precondition(aHost.selected == b1.id.uuidString && normalHost.selected == normalTab.id.uuidString)

        // Normal workspace commands are still normal, even while the global pick names B.
        let normalCommands = CommandHarness(store: normalStore)
        normalCommands.send(.goBack)
        precondition(normalCommands.commandTabID == normalTab.id)
        precondition(normalRuntime.select(normalTab.id, surfaceID: normalSurface, command: normalCommands.command) { _, _ in })
        precondition(normalHost.deliveries.last?.0 == normalTab.id.uuidString && aHost.selected == b1.id.uuidString)

        // Missing/mismatched owner/stray/agent/bot picks are rejected before any selection or navigation.
        for invalid in [
            BrowserChatSessionSelection.Pick(spaceID: aSpace.id, tabID: b1.id),
            .init(spaceID: aSpace.id, tabID: UUID()),
            .init(spaceID: UUID(), tabID: a1.id),
            .init(spaceID: straySpace.id, tabID: stray.id),
            .init(spaceID: aSpace.id, tabID: bot.id),
            .init(spaceID: aSpace.id, tabID: agent.id),
            .init(spaceID: BrowserTabRegistry.sessionSpaceID, tabID: a1.id)
        ] {
            let selected = b.store.selectedRegistryID
            let spaces = chat.spaces, tabs = chat.tabs
            precondition(!BrowserSessionProjection.selectExisting(invalid, in: b.store))
            precondition(b.store.selectedRegistryID == selected && chat.spaces == spaces && chat.tabs == tabs)
            selection.pick = invalid
            let blocked = BrowserSessionProjection(pick: invalid, registry: chat, selection: selection)
            precondition(!blocked.isUsable && !blocked.acceptsCommands)
            let blockedCommands = CommandHarness(store: blocked.store, session: blocked)
            blockedCommands.send(.reload)
            precondition(blockedCommands.command == nil && blockedCommands.commandTabID == nil)
            precondition(aHost.selected == b1.id.uuidString && normalHost.selected == normalTab.id.uuidString)
        }
        // Closing the final selected B tab cannot fall through to a normal or another thread's tab.
        selection.pick = bPick
        chat.close(b1.id)
        precondition(selection.pick == nil && !b.isUsable && !b.acceptsCommands)
        precondition(chat.tabs.first { $0.id == agent.id }!.usesAgentContext)
        precondition(chat.tabs.first { $0.id == bot.id }!.usesAgentContext)
        precondition(normal.tabs == originalNormal)
        normalRuntime.detach(surfaceID: normalSurface)
        b.runtime.detach(surfaceID: bSurface)
        print("SESSION TOOLBAR FIXTURE PASS: real registry/store/runtime, scoped commands, popup, ownership/profile, invalid/stale guards")
    }
}
`);
    const inputs = ['TatwoBrowserLaneCore.swift', 'BrowserTabRegistry.swift', 'BrowserDailyNavigationPolicy.swift',
      'BrowserWorkSpacePolicies.swift', 'BrowserMemoryPolicy.swift', 'BrowserMemorySettings.swift',
      'BrowserNativeMemoryBudget.swift', 'BrowserGeneralSettings.swift', 'BrowserShortcuts.swift']
      .map(name => join(root, browser, name));
    const binary = join(dir, 'checks');
    const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
      ...inputs, fixture, '-o', binary], { cwd: root, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024 });
    assert.equal(compile.status, 0, `${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
    const result = spawnSync('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)(deny network*)(deny file-write*)', binary],
      { cwd: root, encoding: 'utf8', timeout: 20_000, env: { ...process.env, TATWO_BROWSER_SLEEP_SECONDS: '' } });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /SESSION TOOLBAR FIXTURE PASS/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
