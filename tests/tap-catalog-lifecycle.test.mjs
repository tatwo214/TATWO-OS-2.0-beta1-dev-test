// Execute the production Swift coordinator and Space's actual catalog wiring.
// Fake transport only: no Pod, network, credentials, standard-default writes or App launch.
import test, { before } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const tapPath = 'App/Sources/Tatwo2/TAP/';
const space = readFileSync(join(root, tapPath, 'ChatGPTSpace.swift'), 'utf8');
const dm = readFileSync(join(root, 'App/Sources/Tatwo2/DM/GlobalDMStore.swift'), 'utf8');
const navigation = readFileSync(join(root, 'App/Sources/Tatwo2/DM/GlobalDMChatGPTNavigation.swift'), 'utf8');
const composer = readFileSync(join(root, 'App/Sources/Tatwo2/DM/GlobalDMChatGPTComposer.swift'), 'utf8');
const desk = readFileSync(join(root, 'App/Sources/Tatwo2/DM/GlobalDMDesk.swift'), 'utf8');
const quick = readFileSync(join(root, tapPath, 'ChatGPTQuickMenu.swift'), 'utf8');
function between(start, end, source = space) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `production boundaries: ${start}`);
  return source.slice(a, b);
}
const catalogProperty = between('    private lazy var toolCatalog =', '    @Published var selectedTool:');
// W199（.056）：連線觀察搬進 observeDirectoryConnection()（每次就緒都重讀、連線換代計數）；照樣整段取正式程式。
const connectionWatch = between('    private func observeDirectoryConnection(', '    /// 清單讀取持有背景租約');
const refreshCatalog = between('    func refreshToolCatalog(', '    // MARK: 資料庫');
const dmInit = between('    init(defaults: UserDefaults', '    var isPresented:', dm);
const dmShared = between('    static let shared: GlobalDMStore =', '    static let enabledKey', dm);
const dmPlus = between('    func setChatGPTPlusOpen(', '    /// 換對象、收框', navigation);
const duoFactory = between('@MainActor\nfinal class GlobalDMDuo {', '    /// 右半邊預設：', desk);
const slashHandler = (source, expression) => between(
  `.onChange(of: ${expression}, initial: true) { _, active in`,
  '\n        }', source).split('{ _, active in')[1];
const spaceSlash = slashHandler(space, 'slashQuery != nil');
const dmSlash = slashHandler(composer, 'store.chatGPTSlashQuery != nil');
const slashQuery = between('    static func query(', '    /// 清單開不開', quick);
const handsBootstrap = between('        // 等本單例初始化完成', '\n    }\n\n#if DEBUG');
const artifacts = mkdtempSync(join(tmpdir(), 'tap-catalog-lifecycle-'));
const binary = join(artifacts, 'catalog-lifecycle');

before(() => {
  const harness = join(artifacts, 'CatalogLifecycleHarness.swift');
  writeFileSync(harness, `
import Foundation
import Combine

typealias TapTool = String
enum Connection { case off, starting, ready, needsLogin, failed }
enum FixtureError: Error { case unavailable }
enum HandsConnectionPhase { case idle, verifying, connected, failed }
@MainActor final class HandsConnectFlow {
    static var reads = 0
    static let fixture = HandsConnectFlow()
    static var shared: HandsConnectFlow {
        reads += 1
        // The production bootstrap must yield until the Space initializer returns.
        expect(ChatGPTSpaceModel.sharedInstance != nil, "Space init re-entered through Hands flow")
        return fixture
    }
    @Published var phase: HandsConnectionPhase = .idle
}

@MainActor final class FakeTap {
    @Published var connection: Connection = .off
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var peak = 0
    private var replies: [Int: CheckedContinuation<[TapTool], any Error>] = [:]
    func tools() async throws -> [TapTool] {
        calls += 1
        let id = calls
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { replies[id] = $0 }
    }
    func reply(_ id: Int, _ result: Result<[TapTool], any Error>) {
        guard let continuation = replies.removeValue(forKey: id) else {
            fatalError("request \\(id) not pending")
        }
        continuation.resume(with: result)
    }
}

// Only the surrounding unrelated App/UI is stubbed; these three blocks are
// extracted verbatim from ChatGPTSpace.swift, not a JS rewrite of its behavior.
@MainActor final class ChatGPTSpaceModel {
    static var sharedInstance: ChatGPTSpaceModel?
    static var sharedReads = 0
    static var shared: ChatGPTSpaceModel {
        sharedReads += 1
        guard let sharedInstance else { fatalError("fixture must not access shared Space") }
        return sharedInstance
    }
    let tap: FakeTap
    @Published private(set) var tools: [TapTool] = ["cached"]
    var selectedTool: TapTool? = "user-selection"
    var draft = "unsent draft"
    private var connectionWatch: AnyCancellable?
    private var handsConnectionWatch: AnyCancellable?
    static var cacheWrites: [[TapTool]] = []
    static func cacheTools(_ value: [TapTool], in defaults: UserDefaults) {
        cacheWrites.append(value) // capture only; never touch UserDefaults
    }
${catalogProperty}
    private var directoryGeneration = 0
    var search = ""
    func scheduleSearch() {}
    // W199：手腳連線換代時也重讀已展開的專案與清單；這裡只需讓正式片段編得過，目錄讀取不在本測試範圍。
    var expandedProjects: Set<String> = []
    func retryProject(_ id: String) {}
    func reloadConversationList() async {}
${connectionWatch}
    init(tap: FakeTap, observeLivePairing: Bool = false) {
        self.tap = tap
        observeDirectoryConnection()
        if observeLivePairing {
${handsBootstrap}
        }
    }
    func refresh() async {
        guard tap.connection == .ready else { return }
        refreshToolCatalog()
    }
${refreshCatalog}
    func bindPairing(_ phases: AnyPublisher<HandsConnectionPhase, Never>) {
        observeHandsConnection(phases)
    }
    var modelCatalogPublisher: AnyPublisher<ChatGPTModelCatalog, Never> {
        $tools.map { ChatGPTModelCatalog(tools: $0) }.eraseToAnyPublisher()
    }
    var refreshing: Bool { toolCatalog.isRefreshing }
}

// Compile the complete production DM initializer, shared factory and plus action.
// All unrelated DM dependencies below are inert; accidental singleton access traps.
struct ChatGPTModelCatalog { var tools: [TapTool] = [] }
@MainActor final class ChatGPTConversationSession {
    init() { fatalError("must not create a conversation session") }
}
@MainActor final class SpaceWorkspaceController {
    static var shared: SpaceWorkspaceController { fatalError("must not access live workspace") }
    enum Space { case chatgpt }
    func allows(_ space: Space) -> Bool { false }
}
enum GlobalDMTarget {
    case assistant, chatGPT, thread(String)
    init?(storageValue: String) { return nil }
}
enum GlobalDMDirectKeyBook {
    static func load(from defaults: UserDefaults) -> [String: String] { [:] }
}
@MainActor final class GlobalDMStore {
${dmShared}
    static let enabledKey = "fixture.catalog.enabled"
    static let lastTargetKey = "fixture.catalog.target"
    static let showsOtherTargets = false
    let defaults: UserDefaults
    let recentAppsDefaults: UserDefaults
    let makeChatGPT: @MainActor () -> ChatGPTConversationSession
    let chatGPTAllowed: @MainActor () -> Bool
    let chatGPTCatalogSource: @MainActor () -> AnyPublisher<ChatGPTModelCatalog, Never>
    let refreshChatGPTToolCatalog: @MainActor () -> Void
    let hasDirectKeys: Bool
    let directKeys: [String: String]
    let isEnabled: Bool
    var target: GlobalDMTarget
    var isChatGPTPlusOpen = false
    var chatGPTPlusShowingMore = false
    var isChatGPTModelCardOpen = false
    func select(_ target: GlobalDMTarget) { self.target = target }
${dmInit}
${dmPlus}
}
${duoFactory}
}
enum ChatGPTSlash {
${slashQuery}
}
@MainActor func spaceSlashEvent(_ active: Bool, model: ChatGPTSpaceModel) {
${spaceSlash}
}
@MainActor func dmSlashEvent(_ active: Bool, store: GlobalDMStore) {
${dmSlash}
}
// Emulate SwiftUI's Bool onChange(initial:true) delivery, then run the actual
// production callback. Rendering/layout itself is intentionally not claimed here.
@MainActor struct SlashEvents {
    var previous: Bool?
    mutating func input(_ text: String, dismissed: String? = nil, action: (Bool) -> Void) {
        let active = ChatGPTSlash.query(text, dismissed: dismissed) != nil
        if previous != active { previous = active; action(active) }
    }
}

@MainActor func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
@MainActor func until(_ message: String, _ predicate: () -> Bool) async {
    for _ in 0..<5000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    fatalError("timeout: " + message)
}
@MainActor func settled(_ model: ChatGPTSpaceModel) async {
    await until("catalog settled") { !model.refreshing }
}
@MainActor func bootstrap(_ tap: FakeTap, _ model: ChatGPTSpaceModel) async {
    tap.connection = .ready
    await until("first ready request") { tap.calls == 1 }
    tap.reply(1, .success(["first"]))
    await settled(model)
    expect(model.tools == ["first"], "first ready must replace cache")
}

@main struct Runner {
    @MainActor static func main() async {
        let scenario = CommandLine.arguments[1]
        let tap = FakeTap()
        let model = ChatGPTSpaceModel(tap: tap)
        switch scenario {
        case "duo-default-isolated":
            let duo = GlobalDMDuo(defaults: UserDefaults(suiteName: "fixture.catalog.duo")!)
            expect(duo.existing == nil, "secondary store must remain lazy")
            let store = duo.secondary!
            expect(duo.secondary === store, "secondary factory must reuse store")
            store.setChatGPTPlusOpen(true)
            dmSlashEvent(true, store: store)
            expect(ChatGPTSpaceModel.sharedReads == 0 && HandsConnectFlow.reads == 0 && tap.calls == 0,
                   "isolated Duo must not touch shared Pod")
            expect(GlobalDMDuo(defaults: nil).secondary == nil, "unavailable suite stays unavailable")
        case "duo-shared-injection":
            ChatGPTSpaceModel.sharedInstance = model
            let duo = GlobalDMDuo.shared
            let store = duo.secondary!
            expect(ChatGPTSpaceModel.sharedReads == 0, "Duo injection must be lazy")
            await bootstrap(tap, model)
            store.setChatGPTPlusOpen(true)
            dmSlashEvent(true, store: store)
            model.refreshToolCatalog()
            await until("Duo plus slash Space coalesce") { tap.calls == 2 }
            tap.reply(2, .success(["mini-right"]))
            await settled(model)
            expect(model.tools == ["mini-right"] && tap.peak == 1 && tap.calls == 2,
                   "right pane must share Space catalog flight")
            expect(ChatGPTSpaceModel.sharedReads == 2, "both Duo plus and slash must reach shared catalog")
        case "duo-injected-callback":
            var requests = 0
            let duo = GlobalDMDuo(defaults: UserDefaults(suiteName: "fixture.catalog.duo.injected")!,
                refreshChatGPTToolCatalog: { requests += 1 })
            let store = duo.secondary!
            store.setChatGPTPlusOpen(true)
            dmSlashEvent(true, store: store)
            expect(requests == 2 && ChatGPTSpaceModel.sharedReads == 0,
                   "Duo must forward injected callback without replacing it")
        case "dm-default-isolated":
            let store = GlobalDMStore(defaults: UserDefaults(suiteName: "fixture.catalog.isolated")!, directKeys: false)
            store.setChatGPTPlusOpen(true)
            dmSlashEvent(true, store: store)
            expect(ChatGPTSpaceModel.sharedReads == 0 && HandsConnectFlow.reads == 0 && tap.calls == 0,
                   "default DM initializer must not touch shared Space/Pod or pairing")
        case "dm-shared-injection":
            ChatGPTSpaceModel.sharedInstance = model
            let store = GlobalDMStore.shared
            expect(ChatGPTSpaceModel.sharedReads == 0, "shared factory must inject lazily, not initialize Space")
            await bootstrap(tap, model)
            store.setChatGPTPlusOpen(true)
            await until("DM shared plus refresh") { tap.calls == 2 }
            tap.reply(2, .success(["mini"]))
            await settled(model)
            expect(ChatGPTSpaceModel.sharedReads == 1 && model.tools == ["mini"], "shared DM must call shared catalog")
        case "dm-plus-edges":
            var requests = 0
            let store = GlobalDMStore(defaults: UserDefaults(suiteName: "fixture.catalog.plus")!,
                refreshChatGPTToolCatalog: { requests += 1 }, directKeys: false)
            store.isChatGPTModelCardOpen = true
            store.setChatGPTPlusOpen(true)
            store.setChatGPTPlusOpen(true)
            expect(requests == 1 && !store.isChatGPTModelCardOpen, "opening edge refreshes once; existing menu behavior stays")
            store.chatGPTPlusShowingMore = true
            store.setChatGPTPlusOpen(false)
            expect(requests == 1 && !store.chatGPTPlusShowingMore, "close must not refresh")
            store.setChatGPTPlusOpen(true)
            expect(requests == 2, "reopen must refresh")
        case "space-slash-missing-match":
            await bootstrap(tap, model)
            var events = SlashEvents()
            events.input("/missing-mini") { spaceSlashEvent($0, model: model) }
            await until("Space slash with missing old match") { tap.calls == 2 }
            tap.reply(2, .success(["missing-mini"]))
            await settled(model)
            expect(model.tools == ["missing-mini"], "slash must discover a tool missing from nonempty old catalog")
            events.input("/missing-mini-more") { spaceSlashEvent($0, model: model) }
            events.input("/missing-mini-more", dismissed: "/missing-mini-more") { spaceSlashEvent($0, model: model) }
            expect(tap.calls == 2 && !model.refreshing, "typing, catalog arrival and Esc must not request again")
            events.input("/") { spaceSlashEvent($0, model: model) }
            await until("Space slash reopened") { tap.calls == 3 }
            tap.reply(3, .success(["latest"]))
            await settled(model)
        case "dm-slash-shared-coalescing":
            await bootstrap(tap, model)
            let store = GlobalDMStore(defaults: UserDefaults(suiteName: "fixture.catalog.slash")!,
                refreshChatGPTToolCatalog: { model.refreshToolCatalog() }, directKeys: false)
            var dmEvents = SlashEvents()
            var spaceEvents = SlashEvents()
            dmEvents.input("/missing-mini") { dmSlashEvent($0, store: store) }
            spaceEvents.input("/missing-mini") { spaceSlashEvent($0, model: model) }
            store.setChatGPTPlusOpen(true)
            await until("both slash and DM plus share request") { tap.calls == 2 }
            tap.reply(2, .success(["mini"]))
            await settled(model)
            dmEvents.input("/missing-mini-next") { dmSlashEvent($0, store: store) }
            dmEvents.input("plain text") { dmSlashEvent($0, store: store) }
            expect(tap.calls == 2 && !model.refreshing, "DM slash typing/close must not refresh")
            dmEvents.input("/") { dmSlashEvent($0, store: store) }
            await until("DM slash reopened") { tap.calls == 3 }
            tap.reply(3, .success(["latest"]))
            await settled(model)
            expect(tap.peak == 1, "all surfaces must use one flight")
        case "pairing-connected-refresh":
            await bootstrap(tap, model)
            let phases = CurrentValueSubject<HandsConnectionPhase, Never>(.idle)
            model.bindPairing(phases.eraseToAnyPublisher())
            phases.send(.verifying)
            expect(!model.refreshing, "pending pairing must not refresh")
            phases.send(.connected)
            await until("successful pairing refresh") { tap.calls == 2 }
            phases.send(.connected)
            tap.reply(2, .success(["paired-mini"]))
            await settled(model)
            expect(model.tools == ["paired-mini"] && tap.calls == 2, "successful pairing directly refreshes without duplicate state requests")
        case "pairing-invalidates-inflight":
            tap.connection = .ready
            await until("pre-pair catalog") { tap.calls == 1 }
            let phases = CurrentValueSubject<HandsConnectionPhase, Never>(.verifying)
            model.bindPairing(phases.eraseToAnyPublisher())
            phases.send(.connected)
            tap.reply(1, .success(["pre-pair"]))
            await until("post-pair catalog") { tap.calls == 2 }
            expect(ChatGPTSpaceModel.cacheWrites.isEmpty, "pre-pair response must not overwrite paired state")
            tap.reply(2, .success(["paired-mini"]))
            await settled(model)
            expect(model.tools == ["paired-mini"] && tap.peak == 1, "pairing queues one non-overlapping refresh")
        case "pairing-offline-then-ready":
            let phases = CurrentValueSubject<HandsConnectionPhase, Never>(.connected)
            model.bindPairing(phases.eraseToAnyPublisher())
            expect(tap.calls == 0, "offline pairing must not start Pod")
            await bootstrap(tap, model)
            expect(tap.calls == 1, "next ready reads latest catalog")
        case "pairing-bootstrap-deferred":
            let liveModel = ChatGPTSpaceModel(tap: tap, observeLivePairing: true)
            expect(HandsConnectFlow.reads == 0, "pairing singleton must not initialize within Space init")
            ChatGPTSpaceModel.sharedInstance = liveModel
            await until("deferred pairing subscription") { HandsConnectFlow.reads == 1 }
            HandsConnectFlow.fixture.phase = .connected
            expect(tap.calls == 0, "bootstrap must not start offline Pod")
            expect(ChatGPTSpaceModel.sharedReads == 0, "pairing subscriber uses captured instance, not recursive shared access")
        case "ready-and-reopen":
            model.refreshToolCatalog()
            expect(tap.calls == 0 && model.tools == ["cached"], "offline retains cache without request")
            await bootstrap(tap, model)
            model.refreshToolCatalog()
            await until("reopen request") { tap.calls == 2 }
            tap.reply(2, .success(["first", "new-mini"]))
            await settled(model)
            expect(model.tools == ["first", "new-mini"], "reopen must discover installed tool")
            expect(ChatGPTSpaceModel.cacheWrites == [["first"], ["first", "new-mini"]], "cache follows accepted catalog")
        case "coalesce":
            tap.connection = .ready
            for _ in 0..<50 { model.refreshToolCatalog() }
            await until("one request") { tap.calls == 1 }
            for _ in 0..<50 { model.refreshToolCatalog() }
            tap.reply(1, .success(["coalesced"]))
            await settled(model)
            expect(tap.calls == 1 && tap.peak == 1, "concurrent refresh callers share one request")
        case "pod-ready-again":
            await bootstrap(tap, model)
            tap.connection = .ready
            await until("Pod ready again without offline transition") { tap.calls == 2 }
            tap.reply(2, .success(["new-page"]))
            await settled(model)
            expect(model.tools == ["new-page"], "Pod hello/auth must renew catalog even if already ready")
            tap.connection = .starting
            tap.connection = .ready
            await until("new ready request") { tap.calls == 3 }
            tap.reply(3, .success(["reconnected"]))
            await settled(model)
            expect(model.tools == ["reconnected"], "new ready must refresh")
        case "pod-ready-during-request":
            tap.connection = .ready
            await until("old page request") { tap.calls == 1 }
            for _ in 0..<20 { tap.connection = .ready }
            tap.reply(1, .success(["old-page"]))
            await until("new page request") { tap.calls == 2 }
            expect(model.tools == ["cached"] && ChatGPTSpaceModel.cacheWrites.isEmpty, "same-ready renewal must reject old page response")
            tap.reply(2, .success(["new-page"]))
            await settled(model)
            expect(model.tools == ["new-page"] && tap.calls == 2 && tap.peak == 1, "ready events must coalesce into one serial follow-up")
        case "late-disconnected-response":
            tap.connection = .ready
            await until("old request") { tap.calls == 1 }
            tap.connection = .needsLogin
            tap.reply(1, .success(["obsolete"]))
            await settled(model)
            expect(model.tools == ["cached"] && ChatGPTSpaceModel.cacheWrites.isEmpty, "offline late response must not publish or persist")
        case "reconnect-during-request":
            tap.connection = .ready
            await until("old request") { tap.calls == 1 }
            tap.connection = .off
            tap.connection = .ready
            for _ in 0..<20 { model.refreshToolCatalog() }
            expect(tap.calls == 1, "reconnect must not overlap an outstanding request")
            tap.reply(1, .success(["obsolete"]))
            await until("replacement request") { tap.calls == 2 }
            expect(model.tools == ["cached"] && ChatGPTSpaceModel.cacheWrites.isEmpty, "old generation cannot overwrite")
            tap.reply(2, .success(["latest"]))
            await settled(model)
            expect(model.tools == ["latest"] && tap.peak == 1, "replacement must publish without overlap")
        case "invalidate-during-request":
            tap.connection = .ready
            await until("pre-install request") { tap.calls == 1 }
            for _ in 0..<20 { model.refreshToolCatalog(invalidate: true) }
            tap.reply(1, .success(["pre-install"]))
            await until("post-install request") { tap.calls == 2 }
            expect(ChatGPTSpaceModel.cacheWrites.isEmpty, "pre-install response must not be cached")
            tap.reply(2, .success(["installed"]))
            await settled(model)
            expect(tap.calls == 2 && tap.peak == 1 && model.tools == ["installed"], "many invalidations need only one follow-up")
        case "failure-retains-and-retries":
            await bootstrap(tap, model)
            model.refreshToolCatalog()
            await until("failing request") { tap.calls == 2 }
            tap.reply(2, .failure(FixtureError.unavailable))
            await settled(model)
            expect(model.tools == ["first"] && ChatGPTSpaceModel.cacheWrites == [["first"]], "failure retains last catalog and cache")
            try? await Task.sleep(for: .milliseconds(20))
            expect(tap.calls == 2, "failure does not poll or spin")
            model.refreshToolCatalog()
            await until("retry") { tap.calls == 3 }
            tap.reply(3, .success(["recovered"]))
            await settled(model)
            expect(model.tools == ["recovered"], "failure must not latch freshness")
        case "failure-with-pending-invalidation":
            tap.connection = .ready
            await until("old request") { tap.calls == 1 }
            model.refreshToolCatalog(invalidate: true)
            tap.reply(1, .failure(FixtureError.unavailable))
            await until("pending refresh survives failure") { tap.calls == 2 }
            tap.reply(2, .success(["recovered"]))
            await settled(model)
            expect(model.tools == ["recovered"] && tap.peak == 1, "pending invalidation must drain after error")
        case "disconnect-drops-pending":
            tap.connection = .ready
            await until("old request") { tap.calls == 1 }
            model.refreshToolCatalog(invalidate: true)
            tap.connection = .failed
            tap.reply(1, .success(["obsolete"]))
            await settled(model)
            expect(tap.calls == 1 && model.tools == ["cached"], "do not drain pending request while disconnected")
            tap.connection = .ready
            await until("recovered connection") { tap.calls == 2 }
            tap.reply(2, .success(["recovered"]))
            await settled(model)
            expect(model.tools == ["recovered"], "next ready retries")
        case "empty-success":
            await bootstrap(tap, model)
            model.refreshToolCatalog()
            await until("empty catalog") { tap.calls == 2 }
            tap.reply(2, .success([]))
            await settled(model)
            expect(model.tools.isEmpty && ChatGPTSpaceModel.cacheWrites.last == [], "valid empty catalog must replace removed tools")
        case "shared-publisher-preserves-composer":
            var spaceValues: [[TapTool]] = []
            var dmValues: [[TapTool]] = []
            let spaceWatch = model.$tools.sink { spaceValues.append($0) }
            let dmWatch = model.$tools.sink { dmValues.append($0) }
            await bootstrap(tap, model)
            model.refreshToolCatalog(invalidate: true)
            await until("updated shared catalog") { tap.calls == 2 }
            tap.reply(2, .success(["mini"]))
            await settled(model)
            expect(spaceValues == dmValues && dmValues.last == ["mini"], "both surfaces receive same catalog")
            expect(model.selectedTool == "user-selection" && model.draft == "unsent draft", "refresh must not select tools or mutate draft")
            withExtendedLifetime((spaceWatch, dmWatch)) {}
        default:
            fatalError("unknown scenario")
        }
        print("PASS " + scenario)
    }
}
`);
  const result = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library',
    join(root, tapPath, 'ChatGPTToolCatalog.swift'), harness, '-o', binary],
  { encoding: 'utf8', timeout: 120_000 });
  assert.equal(result.status, 0, `Swift compilation failed:\n${result.stdout}\n${result.stderr}`);
});

for (const scenario of [
  'duo-default-isolated', 'duo-shared-injection', 'duo-injected-callback',
  'dm-default-isolated', 'dm-shared-injection', 'dm-plus-edges',
  'space-slash-missing-match', 'dm-slash-shared-coalescing',
  'pairing-connected-refresh', 'pairing-invalidates-inflight',
  'pairing-offline-then-ready', 'pairing-bootstrap-deferred',
  'ready-and-reopen', 'coalesce', 'pod-ready-again', 'pod-ready-during-request',
  'late-disconnected-response', 'reconnect-during-request', 'invalidate-during-request',
  'failure-retains-and-retries', 'failure-with-pending-invalidation',
  'disconnect-drops-pending', 'empty-success', 'shared-publisher-preserves-composer',
]) {
  test(`production Swift catalog lifecycle: ${scenario}`, () => {
    const result = spawnSync(binary, [scenario], { encoding: 'utf8', timeout: 15_000 });
    assert.equal(result.status, 0, `${scenario}:\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, new RegExp(`PASS ${scenario}`));
  });
}

test('Space ready, refresh, plus-menu and plugin-page events use the single catalog loader', () => {
  assert.doesNotMatch(space, /\btoolsFresh\b/);
  assert.equal((space.match(/(?:self\.)?tap\.tools\(\)/g) ?? []).length, 1, 'no unguarded writer bypasses the coordinator');
  assert.match(between('    func refresh() async', '    func loadMore'), /refreshToolCatalog\(\)/);
  assert.match(space, /\.onChange\(of: showsPlusMenu\) \{ _, open in[\s\S]*?if open \{ model\.refreshToolCatalog\(\) \}/);
  assert.match(space, /func loadPage\(_ target: ChatGPTPage\) async \{[\s\S]*?if target == \.plugins \{ refreshToolCatalog\(invalidate: true\) \}/);
  assert.match(between('    func pluginAction(', '    func openPlugin('), /await loadPage\(\.plugins\)/);
});

test('DM still consumes Space shared catalog publisher; refresh does not force a tool', () => {
  assert.match(dm, /ChatGPTSpaceModel\.shared\.modelCatalogPublisher/);
  assert.match(space, /Publishers\.CombineLatest4\(\$models, \$defaultModelID, \$defaultEffortID, \$tools\)/);
  assert.doesNotMatch(catalogProperty + refreshCatalog, /selectedTool\s*=|draft\s*=|Timer|Task\.sleep/);
});

test('slash events depend on input eligibility, not catalog matches; pairing only observes success', () => {
  assert.match(space, /\.onChange\(of: slashQuery != nil, initial: true\)/);
  assert.match(composer, /\.onChange\(of: store\.chatGPTSlashQuery != nil, initial: true\)/);
  assert.match(handsBootstrap, /Task \{ @MainActor \[weak self\] in[\s\S]*observeHandsConnection\(HandsConnectFlow\.shared\.\$phase/);
  const testInit = between('    init(testTap:', '#endif');
  assert.doesNotMatch(testInit, /HandsConnectFlow|observeHandsConnection/);
  assert.doesNotMatch(refreshCatalog + dmPlus + spaceSlash + dmSlash, /selectedTool\s*=|chatGPTTool\s*=|draft\s*=|Timer|Task\.sleep|pluginAction|requestPayload/);
});
