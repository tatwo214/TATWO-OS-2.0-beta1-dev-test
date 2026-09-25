import AppKit
import SwiftUI

/// W112（使用者 2026-09-20：「browser space的空間無法編輯名稱跟顏色 直接對照dia照抄」）：
/// 空間圓點右鍵 → 八色圓點、改名、刪除。刪除走封存（見 `BrowserTabRegistry.archiveAndRemoveSpace`）。
enum BrowserSpacePalette {
    static let ids = ["graphite", "green", "blue", "purple", "yellow", "pink", "red", "orange"]
    static func color(_ id: String?) -> Color? {
        switch id {
        case "graphite": return Color(red: 0.13, green: 0.13, blue: 0.14)
        case "green": return Color(red: 0.24, green: 0.71, blue: 0.54)
        case "blue": return Color(red: 0.24, green: 0.53, blue: 0.80)
        case "purple": return Color(red: 0.42, green: 0.36, blue: 0.65)
        case "yellow": return Color(red: 0.91, green: 0.68, blue: 0.20)
        case "pink": return Color(red: 0.85, green: 0.48, blue: 0.58)
        case "red": return Color(red: 0.78, green: 0.31, blue: 0.34)
        case "orange": return Color(red: 0.87, green: 0.46, blue: 0.27)
        default: return nil
        }
    }
    static func title(_ id: String) -> String {
        ["graphite": "石墨", "green": "綠", "blue": "藍", "purple": "紫", "yellow": "黃", "pink": "粉", "red": "紅", "orange": "橘"][id] ?? id
    }
}

struct BrowserSpaceDot: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let space: BrowserWorkSpaceStore.Space
    let fallbackFill: Color
    let idleFill: Color
    @State private var menuPresented = false

    private var selected: Bool { store.selectedSpaceID == space.id }
    private var fill: Color {
        if let own = BrowserSpacePalette.color(space.color) { return own.opacity(selected ? 1 : 0.45) }
        return selected ? fallbackFill : idleFill
    }

    var body: some View {
        Button { store.selectSpace(space.id) } label: {
            ZStack {
                if space.isSessionSpace {
                    Circle().strokeBorder(fill, lineWidth: WorkspaceSpaceControlMetrics.ringStroke)
                } else {
                    Circle().fill(fill)
                }
            }
            .frame(width: WorkspaceSpaceControlMetrics.dotSize, height: WorkspaceSpaceControlMetrics.dotSize)
            .frame(width: WorkspaceSpaceControlMetrics.cellWidth, height: WorkspaceSpaceControlMetrics.cellHeight)
            .contentShape(Rectangle())
        }
        .overlay { if !space.isSessionSpace { BrowserRightClickCatcher { menuPresented = true } } }
        .popover(isPresented: $menuPresented, arrowEdge: .top) {
            BrowserSpaceMenu(store: store, space: space) { menuPresented = false }
        }
        .help(space.isSessionSpace ? space.name : "\(space.name)（右鍵改名、換顏色）")
        .accessibilityLabel(space.name)
        .accessibilityIdentifier("browser.space.\(space.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "編輯空間") { if !space.isSessionSpace { menuPresented = true } }
    }
}

private struct BrowserSpaceMenu: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let space: BrowserWorkSpaceStore.Space
    let dismiss: () -> Void
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var deletable: Bool { store.spaces.filter { !$0.isSessionSpace }.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(BrowserSpacePalette.ids, id: \.self) { id in
                    Button {
                        if let uuid = space.registryID { store.registry.setSpaceColor(uuid, space.color == id ? nil : id) }
                    } label: {
                        Circle().fill(BrowserSpacePalette.color(id) ?? .gray).frame(width: 18, height: 18)
                            .overlay { if space.color == id { Circle().strokeBorder(BrowserSpacePalette.color(id) ?? .gray, lineWidth: 1.5).padding(-4) } }
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("顏色 \(BrowserSpacePalette.title(id))")
                    .accessibilityAddTraits(space.color == id ? .isSelected : [])
                }
            }
            if renaming {
                TextField("空間名稱", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .onSubmit(commitRename).accessibilityLabel("空間名稱")
            } else {
                row("pencil", "改名…") { name = space.name; renaming = true; DispatchQueue.main.async { nameFocused = true } }
            }
            if confirmingDelete {
                VStack(alignment: .leading, spacing: 6) {
                    Text("刪除「\(space.name)」？裡面開著的分頁會關閉；資料夾與書籤會先封存，不會直接消失。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("取消") { confirmingDelete = false }
                        Button("刪除", role: .destructive) {
                            if let uuid = space.registryID { store.registry.archiveAndRemoveSpace(uuid) }
                            dismiss()
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                row("xmark", "刪除…", action: { confirmingDelete = true }).disabled(!deletable)
                    .help(deletable ? "" : "至少要留一個空間")
            }
        }
        .padding(14)
        .frame(width: 8 * 26 + 7 * 6 + 28, alignment: .leading)   // 內容寬（八顆一排）＋左右內距；使用者 09-20：「不工整」——之前把內距算進寬度，橘色被裁掉
    }

    private func commitRename() {
        if let uuid = space.registryID { store.registry.renameSpace(uuid, to: name) }
        renaming = false
    }

    private func row(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).padding(.leading, 4)   // 圖示與上面第一顆顏色的圓對齊
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13)).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 只接右鍵（與 control＋點擊）；左鍵照常穿過去給底下的按鈕。
struct BrowserRightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> CatcherView { let view = CatcherView(); view.action = action; return view }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary && bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) { action() }   // 只有 control＋點擊會到這裡
    }
}
