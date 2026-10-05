import AppKit
import SwiftUI

// W180 A3：私訊框框頂的對象圖示列；A4／D2：輸入列工具列的模型 chip、「＋」附件與附件小卡。
// 按鈕一律 App 的玻璃（圓形玻璃底、玻璃 chip），選中才用強調色；不用藍色、系統白框。
// W184 AB：框頂的圖示列改成頂列左上的圓鈕列（只露目前頁面那顆、指到向右展開），圓鈕 44。

enum GlobalDMIconStripLayout {
    /// 兩端還有東西時淡出的寬度（附件小卡那一排還在用）。
    static let fadeWidth: CGFloat = 18
    /// W184 AB：圓鈕 44（可按的東西至少 44；W181 的 38 放大）。
    static let iconSize: CGFloat = DMPhone.touch
}

/// W184 AB（使用者 09-29：「照現在這樣放左上並只呈現當前頁面的logo 滑鼠指到時向右滑展開出現其他logo」；對照稿 A-Proto）：
/// 頂列左上 52×52 的裁切容器（外距 −4、內距 4）裝 44pt 圓鈕、間距 8：平常只露目前頁面那顆；滑鼠指到向右展開到 156 寬
/// （玻璃底＋陰影，260ms 同一條曲線），移開收回；點別顆＝切過去並收回。展開後目前那顆在最左，其他照固定順序。
/// W184 F：目前那顆右鍵（control＋點）＝形態、直達鍵那一份選單（取代右上的 ⋯ 更多）。
struct GlobalDMIconStrip: View {
    @ObservedObject var store: GlobalDMStore
    /// 內橫：Browser 在右欄，目前頁面是左欄的對象。
    var besideBrowser = false
    @Environment(\.globalDMStripPinnedOpen) private var pinnedOpen
    @Environment(\.globalDMSurface) private var surface
    @State private var hover = GlobalDMStripHover()
    @State private var menuAnchor = GlobalDMPageMenuAnchor()

    var body: some View {
        let current = store.currentPageID(besideBrowser: besideBrowser)
        let items = GlobalDMTopBarLayout.order(store.pageItems(besideBrowser: besideBrowser), current: current)
        let open = pinnedOpen || hover.isOpen
        HStack(spacing: DMPhone.Strip.spacing) {
            ForEach(items) { item in
                let isCurrent = item.id == current
                GlobalDMIconButton(item: item, isCurrent: isCurrent) {
                    hover.picked()
                    withAnimation(GlobalDMTopBarLayout.stripAnimation) { store.activate(item) }
                }
                .allowsHitTesting(open || isCurrent)   // 收著時藏在裁切外面的圓鈕點不到
                .modifier(GlobalDMPageMenu(active: isCurrent, store: store, anchor: menuAnchor, surface: surface))
                .modifier(GlobalDMCurrentTargetMark(active: isCurrent, name: item.title))
            }
        }
        .fixedSize()
        .padding(DMPhone.Strip.inset)
        .frame(width: DMPhone.Strip.width(count: items.count, open: open), height: DMPhone.Strip.collapsed, alignment: .leading)
        .clipShape(Capsule())
        .background {
            if open {
                GlobalDMGlassCapsule()
                    .shadow(color: .black.opacity(LiquidGlassTokens.shadowOpacity + 0.06), radius: LiquidGlassTokens.shadowRadius,
                            x: LiquidGlassTokens.shadowOffsetX, y: LiquidGlassTokens.shadowOffsetY)
            }
        }
        .contentShape(Capsule())
        .onHover { inside in hover.hovering(inside) }
        .padding(-DMPhone.Strip.inset)
        .animation(GlobalDMTopBarLayout.stripAnimation, value: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("私訊對象")
        .accessibilityIdentifier("tatwo.dm.targets.strip")
    }
}

/// 一顆 44pt 圓鈕：頭像同對話裡的頭像（使用者的 logo、ChatGPT、Browser 地球；其他是字母＋頭像色），底是玻璃圓；
/// W184 AB：目前那顆 2pt 強調色外圈、其他 1pt 淡框。別台上的 session 右下角有小設備標記；關掉的 ChatGPT 是灰的、不能點。
struct GlobalDMIconButton: View {
    let item: GlobalDMIconItem
    var isCurrent = false
    let action: () -> Void

    var body: some View {
        let size = GlobalDMIconStripLayout.iconSize
        let art: GlobalDMAvatarArt? = item.kind == .assistant ? .assistant : item.kind == .chatGPT ? .chatGPT
            : item.kind == .browser ? .browser : nil   // W183 R8b：第三顆 Browser（地球）
        Button(action: action) {
            // 有圖的頭像（logo、ChatGPT、地球）幾乎填滿圓鈕，只留一圈玻璃邊；字母頭像照舊內縮。
            GlobalDMAvatar(letter: item.letter, color: GlobalDMPalette.color(for: item.tint), size: art == nil ? size - 10 : size - 4,
                           art: art)
                .frame(width: size, height: size)
                .background(GlobalDMGlassCircle(isSelected: isCurrent))
                .overlay {
                    Circle().strokeBorder(isCurrent ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.14),
                                          lineWidth: isCurrent ? DMPhone.Strip.currentRing : DMPhone.Strip.otherRing)
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.device != nil {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: DMPhone.TextSize.caption, weight: .bold))
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(GlobalDMGlassCircle())
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(item.isEnabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .help(item.device.map { "\(item.help)（在「\($0)」上）" } ?? item.help)
        .accessibilityLabel(item.title)
        .accessibilityValue(isCurrent ? "目前頁面" : "")
        .accessibilityIdentifier("tatwo.dm.icon." + item.id)
    }
}

// MARK: - 左右捲的一排

/// AppKit 的捲動區包 SwiftUI 內容：滑鼠滾輪（只有上下）換成左右捲、觸控板左右滑照系統；兩端還有東西時淡出。
/// SwiftUI 的橫向 ScrollView 在 macOS 上滑鼠滾輪不會捲，所以自己接。圖示列與附件小卡那一排共用。
/// 內層沿用面板的 GlobalDMHostingView：面板不是 key 視窗時第一下點擊也要生效（同 W179 的對象 chip）。
struct GlobalDMHorizontalScroller<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> GlobalDMHorizontalScrollView {
        let scroll = GlobalDMHorizontalScrollView(frame: .zero)
        let host = GlobalDMHostingView(rootView: AnyView(content))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: GlobalDMHorizontalScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<AnyView>)?.rootView = AnyView(content)
        scroll.updateFade()
    }
}

final class GlobalDMHorizontalScrollView: NSScrollView {
    private let fade = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
        updateFade()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    /// 面板不是 key 視窗時第一下點擊也要生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateFade()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateFade()
    }

    /// 滑鼠滾輪只有上下：換成左右捲（觸控板本來就能左右滑，照系統）。內容放得下時交回系統。
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let room = document.frame.width - contentView.bounds.width
        guard room > 0.5 else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x - step), room)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    /// 左邊捲過了就左端淡出、右邊還有東西就右端淡出。
    func updateFade() {
        guard let layer else { return }
        let width = max(1, bounds.width)
        let visible = contentView.bounds
        let contentWidth = documentView?.frame.width ?? 0
        let leading = visible.minX > 0.5
        let trailing = visible.maxX < contentWidth - 0.5
        let edge = Double(min(0.3, GlobalDMIconStripLayout.fadeWidth / width))
        let solid = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer.bounds
        fade.colors = [leading ? clear : solid, solid, solid, trailing ? clear : solid]
        fade.locations = [NSNumber(value: 0), NSNumber(value: edge), NSNumber(value: 1 - edge), NSNumber(value: 1)]
        CATransaction.commit()
    }
}

// MARK: - 模型 chip（W180 A4）

/// 輸入列右邊的模型 chip：同 Coder／TATWO 那一顆（ChatComposerModelLabel，整顆是 Button），點了在 chip 上方跳系統選單。
/// 助理＝助理的模型選單；Coder session＝那條的模型（本機停用的引擎標「已停用」）；ChatGPT 對象用 ChatGPT 自己的思考強度膠囊（W184 G3）。
/// 選了只改這個對象，不動 Coder 輸入框與其他對象。
struct GlobalDMModelChip: View {
    @ObservedObject var store: GlobalDMStore
    @State private var anchor = AssistantModelMenuAnchor()

    var body: some View {
        let title = store.modelChipTitle
        // W181：私訊框自己的膠囊 chip（寬度跟著模型名），不用 Coder 那顆固定寬的方塊。
        Button(action: popUp) {
            GlobalDMChipLabel(title: title)
                .fixedSize()   // W184 F 小修正：模型名不截（寬度不夠時旁邊的記憶膠囊先縮）
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .background(AssistantModelMenuAnchorView(anchor: anchor))
        .disabled(!store.canChooseModel)
        .help(store.modelChipHelp)
        .accessibilityLabel("模型：\(title)")
        .accessibilityHint(store.modelChipHelp)
        .accessibilityIdentifier("tatwo.dm.model")
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        AssistantModelMenu.popUp(GlobalDMModelMenus.menu(for: store), above: view)
    }
}

/// 模型 chip 的系統選單內容。W184 G3：ChatGPT 對象的模型 chip 換成 ChatGPT 自己的思考強度膠囊與面板
/// （GlobalDMChatGPTComposer.swift，跟 ChatGPT Space 同一個），這裡只剩助理與 Coder session。
@MainActor
enum GlobalDMModelMenus {
    static func menu(for store: GlobalDMStore) -> NSMenu {
        let target = store.target
        return AssistantModelMenu.makeMenu(headline: store.modelHeadline(for: target),
                                           options: store.modelOptions(for: target)) { [store] id in
            store.chooseModel(id, for: target)
        }
    }
}

// MARK: - 附件（W180 D2）

/// 輸入列左邊的「＋」：附加檔案、貼上剪貼簿圖片。帶不了附件的對象（別台上的 session、接在主設備的助理）
/// 變淡、不開選單；點了在框裡的提示列說為什麼（例「主設備上的 session 暫不支援附件」）。
/// 不用 .disabled：停用的按鈕滑過常常不顯示說明，等於看不到原因。
struct GlobalDMAttachButton: View {
    @ObservedObject var store: GlobalDMStore
    @State private var anchor = AssistantModelMenuAnchor()

    var body: some View {
        let block = store.attachmentBlock(for: store.target)
        Button { if let block { store.showNotice(block) } else { popUp() } } label: {
            // W181：玻璃圓鈕，同送出鈕大小，iPhone 輸入列的樣子。W184 C：36 的圓、圖示同內文 17。
            Image(systemName: "plus")
                .font(.system(size: GlobalDMChatLayout.glyphSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: GlobalDMChatLayout.controlSize, height: GlobalDMChatLayout.controlSize)
                .background(GlobalDMGlassCircle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(AssistantModelMenuAnchorView(anchor: anchor))
        .opacity(block == nil ? 1 : 0.45)
        .help(block ?? "附加檔案或貼上剪貼簿圖片")
        .accessibilityLabel("附件")
        .accessibilityHint(block ?? "附加檔案或貼上剪貼簿圖片")
        .accessibilityIdentifier("tatwo.dm.attach")
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        let menu = NSMenu(title: "附件")
        menu.autoenablesItems = false
        menu.addItem(AssistantModelMenuItem(title: "附加檔案…") { [store] in store.pickAttachments() })
        menu.addItem(AssistantModelMenuItem(title: "貼上剪貼簿圖片") { [store] in
            if !store.pasteAttachment(from: .general, preferText: false) { store.showNotice("剪貼簿沒有圖片或檔案") }
        })
        AssistantModelMenu.popUp(menu, above: view)
    }
}

/// 輸入框上方一排附件小卡（玻璃 chip：圖示、檔名、× 移除）；放不下就左右捲（同圖示列：滑鼠滾輪也能捲、兩端淡出）。
/// W184 C：小卡同輸入列的 chip——32 高膠囊、13pt（手機 token）。
struct GlobalDMAttachmentRow: View {
    @ObservedObject var store: GlobalDMStore
    let files: [GlobalDMAttachment]

    var body: some View {
        GlobalDMHorizontalScroller {
            HStack(spacing: 6) {
                ForEach(files) { file in chip(file) }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
        .frame(height: GlobalDMChatLayout.chipHeight + 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("附件")
        .accessibilityIdentifier("tatwo.dm.attachments")
    }

    private func chip(_ file: GlobalDMAttachment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: file.isImage ? "photo" : "paperclip")
                .font(.system(size: GlobalDMChatLayout.captionSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(.system(size: GlobalDMChatLayout.footnoteSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: GlobalDMChatLayout.attachmentNameWidth(file.name), alignment: .leading)
            Button { store.removeAttachment(file.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: GlobalDMChatLayout.footnoteSize))
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("移除")
            .accessibilityLabel("移除附件：\(file.name)")
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: GlobalDMChatLayout.chipHeight)
        .background(GlobalDMGlassCapsule())
        .help(file.name)
    }
}
