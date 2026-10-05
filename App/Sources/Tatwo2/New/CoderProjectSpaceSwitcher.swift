import AppKit
import SwiftUI

/// W180 E3：Coder 側欄紅綠燈那一列的「專案空間」選單（照 Browser 的空間切換器）；匯入入口也在這裡。
struct CoderProjectSpaceSwitcher: View {
    @ObservedObject var model: ChatPageModel
    var width: CGFloat = WorkspaceSidebarMetrics.spaceSwitcherMenuWidth
    @ObservedObject private var spaces = CoderProjectSpaces.shared

    var body: some View {
        Menu {
            Toggle(CoderProjectSpaces.allProjectsName, isOn: selection(nil))
            ForEach(spaces.activeSpaces) { space in
                Toggle(space.name, isOn: selection(space.id))
            }
            Divider()
            Button("新增專案空間…") {
                spaces.addSpace()
                CoderSheetPresenter.presentSpaces(model: model)
            }
            if !spaces.file.spaces.isEmpty {
                Button("管理專案空間…") { CoderSheetPresenter.presentSpaces(model: model) }
            }
            Divider()
            Button("從 Codex／Claude Code 匯入…") { CoderSheetPresenter.presentImport(model: model) }
            if model.selectedRemote == nil, let source = model.coderImportSource(model.selectedThreadID) {
                Button("看這條的原檔") { CoderSheetPresenter.presentImport(model: model, focus: source) }
            }
        } label: {
            Text(spaces.selectedName)
                .font(.system(size: WorkspaceSidebarMetrics.spaceSwitcherFontSize, weight: .bold)).lineLimit(1)
                .padding(.horizontal, WorkspaceSidebarMetrics.spaceSwitcherHorizontalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: width, height: WorkspaceSidebarMetrics.spaceSwitcherHeight, alignment: .leading)
        .help("切換專案空間；從 Codex／Claude Code 匯入也在這裡")
        .accessibilityLabel("切換專案空間")
        .accessibilityIdentifier("coder.projectSpaceSwitcher")
    }

    private func selection(_ id: UUID?) -> Binding<Bool> {
        Binding(get: { spaces.selectedSpace?.id == id }, set: { _ in spaces.select(id) })
    }
}

/// 本機「專案」區照目前的空間過濾；自己看著空間設定，切換時側欄跟著重畫。「全部專案」＝原樣。
/// 只在 Coder 過濾（filtering＝mode 是 .chat）；自訂 Space 共用這個側欄，照原樣列出。
struct CoderSpaceProjectList<Row: View, Empty: View>: View {
    let projects: [TatwoNativeChatProject]
    let filtering: Bool
    let row: (TatwoNativeChatProject) -> Row
    let empty: (String) -> Empty
    @ObservedObject private var spaces = CoderProjectSpaces.shared

    init(projects: [TatwoNativeChatProject], filtering: Bool, @ViewBuilder row: @escaping (TatwoNativeChatProject) -> Row,
         @ViewBuilder empty: @escaping (String) -> Empty) {
        self.projects = projects; self.filtering = filtering; self.row = row; self.empty = empty
    }

    var body: some View {
        let visible = filtering ? spaces.visible(projects, id: \.id) : projects
        if !visible.isEmpty {
            ForEach(visible) { row($0) }
        } else {
            empty(!filtering || spaces.selectedSpace == nil ? "尚無專案" : "這個專案空間還沒有專案：在專案上按右鍵「移到專案空間」，或從上方選單「管理專案空間…」加進來。")
        }
    }
}

/// 專案列右鍵「移到專案空間」。
struct CoderProjectSpaceMoveMenu: View {
    let projectID: UUID
    @ObservedObject private var spaces = CoderProjectSpaces.shared

    var body: some View {
        Menu("移到專案空間") {
            ForEach(spaces.activeSpaces) { space in
                Toggle(space.name, isOn: Binding(get: { space.projectIDs.contains(projectID) },
                                                 set: { _ in spaces.move(localProject: projectID, to: space.id) }))
            }
            if !spaces.activeSpaces.isEmpty { Divider() }
            Button("新增專案空間並移進去") { spaces.move(localProject: projectID, to: spaces.addSpace()) }
            if spaces.activeSpaces.contains(where: { $0.projectIDs.contains(projectID) }) {
                Button("移出專案空間") { spaces.move(localProject: projectID, to: nil) }
            }
        }
    }
}

extension View {
    /// 遠端設備區塊用：不在目前專案空間的專案不畫。
    @ViewBuilder func coderSpaceHidden(_ hidden: Bool) -> some View {
        if !hidden { self }
    }

    /// 專案列右鍵「移到專案空間」只在 Coder 掛（自訂 Space 共用側欄但沒有切換器）。
    @ViewBuilder func coderSpaceMoveMenu(projectID: UUID, enabled: Bool) -> some View {
        if enabled { contextMenu { CoderProjectSpaceMoveMenu(projectID: projectID) } } else { self }
    }
}

// MARK: - 視窗（掛在主視窗上的 AppKit sheet；側欄以浮層出現、滑鼠移走時也不會被收掉）

@MainActor
enum CoderSheetPresenter {
    private static var window: CoderSheetWindow?
    private static var showsImport = false
    /// 現在掛著的那個（自測用）。
    static var current: NSWindow? { window }

    /// W181 R1：匯入改成照 Codex／Claude Code 左邊欄的專案挑（CoderImportBrowser）；不再用 W110 的「過去的對話」清單。
    /// 「看原檔」用出處（家別＋session id）找那一則，不從路徑猜是哪一家；串的右鍵只給路徑時先找回出處。
    static func presentImport(model: ChatPageModel, focusPath: String? = nil, focus source: CoderImportSource? = nil,
                              roots: CoderImportCatalog.Roots? = nil, parent: NSWindow? = nil) {
        CoderImportJob.shared.clearStatusIfIdle()
        CoderImportJob.shared.onFinished = { if showsImport { close() } }
        let focus = (source ?? focusPath.flatMap { model.coderImportSource(path: $0) }).map { CoderImportFocus($0) }
            ?? focusPath.map { CoderImportFocus(engine: nil, sessionID: "", path: $0) }
        present(size: NSSize(width: 1_080, height: 680), isImport: true, parent: parent) {
            CoderImportBrowser(model: model, roots: roots ?? model.coderImportRoots, focus: focus, onClose: { close() })
        }
    }

    static func presentSpaces(model: ChatPageModel, parent: NSWindow? = nil) {
        present(size: NSSize(width: 720, height: 520), isImport: false, parent: parent) {
            CoderProjectSpacesSheet(model: model, onClose: { close() })
        }
    }

    private static func present<Content: View>(size: NSSize, isImport: Bool, parent: NSWindow?, @ViewBuilder content: () -> Content) {
        close()
        let sheet = CoderSheetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                                     backing: .buffered, defer: false)
        let host = CoderSheetHostingView(rootView: content())
        host.sizingOptions = [.minSize]   // 防護性：視窗大小不跟著 SwiftUI 的理想高度長（沒有證實跟「關不掉」有關）
        sheet.contentView = host
        sheet.isReleasedWhenClosed = false
        sheet.onDismiss = { close() }
        sheet.setContentSize(size)
        window = sheet
        showsImport = isImport
        if let parent = parent ?? hostWindow() { parent.beginSheet(sheet) }
        else { sheet.center(); sheet.makeKeyAndOrderFront(nil) }
    }

    /// 防護性：掛在 TATWO 主視窗上（key 可能是私訊框之類的面板）。舊版用 mainWindow ?? keyWindow，
    /// 實機截圖裡 sheet 是掛在主視窗上的，沒有證實這是「關不掉」的原因。
    private static func hostWindow() -> NSWindow? {
        if let main = NSApp.mainWindow as? TatwoWorkOSWindow { return main }
        return NSApp.windows.first { $0 is TatwoWorkOSWindow && $0.isVisible } ?? NSApp.mainWindow ?? NSApp.keyWindow
    }

    static func close() {
        guard let sheet = window else { return }
        window = nil
        showsImport = false
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }
}

/// W181 R1：匯入、專案空間的 sheet。Esc、⌘W、系統的「取消」都只關這個 sheet，
/// 不往主視窗傳（主視窗的 Esc 會關整個 TATWO 視窗）。中文輸入法選字時的 Esc 照常給輸入法。
@MainActor
final class CoderSheetWindow: NSWindow {
    var onDismiss: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { dismissSheet() }
    override func performClose(_ sender: Any?) { dismissSheet() }

    override func sendEvent(_ event: NSEvent) {
        if Self.isPlainEscape(event), !isComposingText {
            dismissSheet()
            return
        }
        super.sendEvent(event)
    }

    static func isPlainEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private var isComposingText: Bool { (firstResponder as? NSTextView)?.hasMarkedText() == true }

    private func dismissSheet() {
        // 因為 Esc 關的：同一下按住的自動重複、或緊接著再按一下，不能落到主視窗（W181 審查：只擋第一下不夠）。
        if let event = NSApp.currentEvent, Self.isPlainEscape(event) { CoderSheetEscapeGuard.arm(after: event) }
        if let onDismiss { onDismiss() } else if let parent = sheetParent { parent.endSheet(self) } else { orderOut(nil) }
    }
}

/// Esc 關掉 sheet 之後，主視窗變成 key：這時還在按住的 Esc（自動重複）或 0.4 秒內再按的一下會送到主視窗，
/// 主視窗的 Esc 會關掉整個 TATWO 視窗。用一次性的本機事件監聽吃掉這些 Esc；之後重新按的 Esc 照常。
@MainActor
enum CoderSheetEscapeGuard {
    static let window: TimeInterval = 0.4
    private static var monitor: Any?
    private static var until: TimeInterval = 0
    private static var held = false
    private static var protectNextEscape = false
    private static var mainWindowOnly = false

    static func arm(after event: NSEvent) {
        protectNextEscape = false
        mainWindowOnly = false
        until = event.timestamp + window
        held = event.type == .keyDown
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 53 else { return event }
            // DM 的 keyDown 先給輸入法、輸入框與卡片；只有真的走到主視窗關閉才攔。
            if mainWindowOnly, event.type == .keyDown { return event }
            return swallows(event) ? nil : event
        }
    }

    /// 私訊框收起後，下一下 Esc（即使已過短暫保護時間）也不能關掉主視窗。
    /// 只保護主視窗；其他視窗的輸入、卡片與輸入法照自己的 Esc 路由。
    static func armForDM(after event: NSEvent) {
        arm(after: event)
        protectNextEscape = true
        mainWindowOnly = true
    }

    /// 吃掉：關掉 sheet 那一下之後 0.4 秒內的 Esc，和同一下按住的自動重複。放開（keyUp）照常送出；
    /// 過了時間又重新按下去的 Esc 照常送出，監聽也就拆掉。
    static func swallows(_ event: NSEvent) -> Bool {
        if mainWindowOnly, !(event.window is TatwoWorkOSWindow) { return false }
        if event.type == .keyUp {
            held = false
            if event.timestamp > until, !protectNextEscape { disarm() }
            return false
        }
        if protectNextEscape || event.timestamp <= until || (held && event.isARepeat) {
            protectNextEscape = false
            held = true
            return true
        }
        disarm()
        return false
    }

    static var isArmed: Bool { monitor != nil }

    static func preventsDMWindowClose(_ event: NSEvent?) -> Bool {
        guard mainWindowOnly, isArmed, let event, event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        return swallows(event)
    }

    static func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = false
        protectNextEscape = false
        mainWindowOnly = false
    }
}

/// 防護性：sheet 還不是 key 時點 ✕／完成也第一下就算數（沒有證實舊版「關不掉」是這個原因）。
final class CoderSheetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 「管理專案空間…」：改名、封存（卡片內確認）、還原；勾選這個空間放哪些本機與遠端專案。
struct CoderProjectSpacesSheet: View {
    @ObservedObject var model: ChatPageModel
    let onClose: () -> Void
    @ObservedObject private var spaces = CoderProjectSpaces.shared
    @State private var editing: UUID?
    @State private var name = ""
    @State private var confirmArchive = false

    private var current: CoderProjectSpace? { editing.flatMap { spaces.space($0) } }
    private var localProjects: [TatwoNativeChatProject] {
        model.document.projects.filter { $0.id != model.document.generalProjectID && $0.id != model.document.assistantProjectID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("專案空間").font(.system(size: 15, weight: .bold))
                Spacer()
                OSChipButton(title: "完成", isPrimary: true) { commitName(); onClose() }
            }
            Text("專案空間只是這台的顯示方式：選了空間，側欄只列放進來的專案；專案和對話本身不動，也不會同步到別台。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let problem = spaces.loadProblem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 14) {
                spaceList.frame(width: 190)
                Divider()
                if let space = current, !space.isArchived { editor(space) } else {
                    Text(spaces.activeSpaces.isEmpty ? "還沒有專案空間；按「新增」建一個。" : "選左邊一個空間來改。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { choose(spaces.selectedSpace?.id ?? spaces.activeSpaces.last?.id) }
    }

    private var spaceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(spaces.activeSpaces) { space in
                    Button { choose(space.id) } label: {
                        Text(space.name).font(.system(size: 12, weight: editing == space.id ? .semibold : .regular)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(editing == space.id ? LiquidGlassTokens.brandAccent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                OSChipButton(title: "新增", systemImage: "plus") { choose(spaces.addSpace()) }.padding(.top, 4)
                if !spaces.archivedSpaces.isEmpty {
                    Text("已封存").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
                    ForEach(spaces.archivedSpaces) { space in
                        HStack {
                            Text(space.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            OSChipButton(title: "還原") { spaces.restore(space.id); choose(space.id) }
                        }
                    }
                }
            }
        }
    }

    private func editor(_ space: CoderProjectSpace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("空間名稱", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 13))
                    .onSubmit(commitName).frame(maxWidth: 260)
                Spacer()
                if !confirmArchive { OSChipButton(title: "封存這個空間", systemImage: "archivebox") { confirmArchive = true } }
            }
            if confirmArchive {
                // 卡片內的玻璃確認列（不跳系統框）。
                HStack(spacing: 8) {
                    Text("封存「\(space.name)」？專案和對話不會動，之後可以在左邊「已封存」還原。").font(.system(size: 11))
                    Spacer(minLength: 4)
                    OSChipButton(title: "取消") { confirmArchive = false }
                    OSChipButton(title: "封存", isPrimary: true) { confirmArchive = false; spaces.archive(space.id); choose(spaces.activeSpaces.last?.id) }
                }
                .padding(10).chatGlassChip(isSelected: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("這台的專案").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(localProjects) { project in
                        memberRow(project.name, detail: project.workdir, on: space.projectIDs.contains(project.id)) {
                            spaces.setMember(localProject: project.id, in: space.id, !space.projectIDs.contains(project.id))
                        }
                    }
                    ForEach(model.remoteSidebarSections) { section in
                        Text("遠端設備（\(section.deviceName)）").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(section.projects) { project in
                            let on = spaces.contains(remoteProject: project.id, deviceID: section.deviceID, in: space.id)
                            memberRow(project.name, detail: nil, on: on) {
                                spaces.setMember(remoteProject: project.id, deviceID: section.deviceID, in: space.id, !on)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberRow(_ title: String, detail: String?, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                    .foregroundStyle(on ? LiquidGlassTokens.brandAccent : Color.secondary)
                Text(title).font(.system(size: 12)).lineLimit(1)
                if let detail { Text((detail as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func choose(_ id: UUID?) {
        commitName()
        confirmArchive = false
        editing = id
        name = id.flatMap { spaces.space($0)?.name } ?? ""
    }

    private func commitName() {
        if let editing { spaces.rename(editing, to: name) }
    }
}
