import SwiftUI
#if DEBUG
import AppKit
#endif

/// W201：頂端只顯示需要處理的拒收項目。自動排隊、離線、重連都不建立提示。
/// 完整清單在設定 › 設備自行查看；頂端與設定共用同一份可重送／取消清單。
struct PrimaryOfflineBannerHost: View {
    @ObservedObject var model: ChatPageModel
    /// 右側面板開著（頂右那排鈕會移到面板左邊）。
    var rightPanelOpen = false
    @State private var outboxRevision = 0
    #if DEBUG
    var testProbe: PrimaryOutboxViewProbe? = nil
    #endif
    @AppStorage("tatwo.chat.browserOverlayOpen") private var browserOverlayOpen = false
    @AppStorage("tatwo.chat.browserPanelWidth") private var browserPanelWidth: Double = 480
    @AppStorage("tatwo.chat.dockedBrowserWidth") private var dockedBrowserWidth: Double = 0

    /// 紅綠燈、側欄與側欄固定鈕那一塊（跟紅綠燈那列的拖曳區讓位同一個寬度）。
    static let leadingReserve = WorkspaceSidebarMetrics.width + ChatPage.sidebarPinButtonReserve
    /// 頂右那排鈕（資訊卡／瀏覽器／工具箱，或 ChatGPT 那排）。
    static let trailingReserve = WindowChromeMetrics.chatRightControlsReserve + WindowChromeMetrics.headerHorizontalInset
    /// 右側面板開著時多讓的寬度（面板最寬那一種）。
    static let rightPanelReserve = ChatRightPanelLayoutPolicy.loopsMinimumPanelWidth
    static let height: CGFloat = 24
    /// 跟紅綠燈同一條中線。
    static let topInset = WindowChromeMetrics.trafficLightTopInset + WindowChromeMetrics.nativeTrafficLightDiameter / 2 - height / 2

    var body: some View {
        let _ = outboxRevision
        Group {
            if model.primaryOfflineBanner != nil, let outbox = model.primaryOutbox {
                HStack(spacing: 0) {
                    Spacer(minLength: Self.leadingReserve)
                    #if DEBUG
                    PrimaryOfflineBanner(model: model, outbox: outbox, testProbe: testProbe)
                        .layoutPriority(1)
                    #else
                    PrimaryOfflineBanner(model: model, outbox: outbox)
                        .layoutPriority(1)
                    #endif
                    Spacer(minLength: trailing)
                }
                .frame(height: Self.height)
                .padding(.top, Self.topInset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PrimaryOutbox.didChange)) { note in
            guard let outbox = note.object as? PrimaryOutbox, outbox === model.primaryOutbox else { return }
            outboxRevision += 1
        }
    }

    private var trailing: CGFloat {
        var reserve = Self.trailingReserve
        if rightPanelOpen { reserve += Self.rightPanelReserve }
        if browserOverlayOpen { reserve += CGFloat(max(browserPanelWidth, 420)) }
        if dockedBrowserWidth > 0 { reserve += CGFloat(dockedBrowserWidth) }
        return reserve
    }
}

struct PrimaryOfflineBanner: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject var outbox: PrimaryOutbox
    @State private var expanded = false
    #if DEBUG
    var testProbe: PrimaryOutboxViewProbe? = nil
    #endif

    var body: some View {
        if let state = model.primaryOfflineBanner {
            Button {
                expanded.toggle()
            } label: {
                ViewThatFits(in: .horizontal) {
                    lineLabel(state.line)
                    lineLabel(state.shortLine)
                }
                .padding(.horizontal, 10)
                .frame(height: PrimaryOfflineBannerHost.height)
                .liquidGlassSurface(cornerRadius: PrimaryOfflineBannerHost.height / 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(state.line + (expanded ? "" : "（點一下重送或取消）"))
            .accessibilityLabel(state.line)
            .accessibilityHint(expanded ? "收起" : "展開重送與取消清單")
            .accessibilityIdentifier("primary-offline-banner")
            #if DEBUG
            .onAppear { testProbe?.bannerVisible = true }
            .onDisappear { testProbe?.bannerVisible = false }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.bannerFrame = $0 }
            #endif
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                #if DEBUG
                PrimaryOfflineOutboxList(model: model, outbox: outbox, testProbe: testProbe)
                    .padding(14).frame(width: 400, alignment: .leading)
                #else
                PrimaryOfflineOutboxList(model: model, outbox: outbox)
                    .padding(14).frame(width: 400, alignment: .leading)
                #endif
            }
        }
    }

    private func lineLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 10.5, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    static func lastSeen(_ date: Date?) -> String {
        guard let date else { return "最後連上：這次開 App 以來還沒連上過" }
        let relative = OverviewText.relative(date, now: Date())
        let exact = date.formatted(date: .abbreviated, time: .shortened)
        return "最後連上：\(relative)（\(exact)）"
    }

    static func status(_ item: PrimaryOutboxItem, name: String) -> String {
        if item.refused == true { return "沒送成：\(item.reason ?? "「\(name)」不能做")" }
        if item.state == .sending { return "送出中…" }
        let when = item.createdAt.formatted(date: .omitted, time: .shortened)
        return "排隊中（\(when)）：連回「\(name)」後會自動送" + (item.reason.map { "；上次沒送到：\($0)" } ?? "")
    }
}

/// 同一份佇列的正式 View，設定設備列與頂端處理 popover 共用。
struct PrimaryOfflineOutboxList: View {
    @State private var retryErrors: [UUID: String] = [:]
    @ObservedObject var model: ChatPageModel
    @ObservedObject var outbox: PrimaryOutbox
    #if DEBUG
    var testProbe: PrimaryOutboxViewProbe? = nil
    #endif
    var body: some View {
        if let state = model.primaryOfflineDetails {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.failed.isEmpty ? "等送到「\(state.name)」的項目" : state.line).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            Text(PrimaryOfflineBanner.lastSeen(state.lastSeenAt))
            if state.assistantStretches > 0 {
                Text("助理：這台離線時接著聊的 \(state.assistantStretches) 段，連回後補回主設備那條")
            }
            if state.waiting.isEmpty && state.failed.isEmpty {
                Text("沒有排隊的事。")
            }
            ForEach(state.waiting + state.failed) { item in
                row(item, name: state.name)
                if let error = retryErrors[item.id] { Text(error).foregroundStyle(.orange) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("primary-offline-banner-details")
        #if DEBUG
        .onAppear { testProbe?.detailsVisible = true }
        .onDisappear { testProbe?.detailsVisible = false }
        #endif
        }
    }

    private func row(_ item: PrimaryOutboxItem, name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(.primary).lineLimit(2)
                Text(PrimaryOfflineBanner.status(item, name: name))
                    .foregroundStyle(item.refused == true ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 8)
            // 排著的 /蒸餾 寫入要連畫布一起解鎖：走 model 那條，不直接從佇列拿掉。
            if !item.isWaiting && item.canRetry {
                OSChipButton(title: "重送") { retryErrors[item.id] = model.retryPrimaryOutboxItem(item) }
                    .accessibilityIdentifier("primary-outbox-retry-" + item.id.uuidString)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.retryFrames[item.id] = $0 }
                    .background(PrimaryOutboxButtonAnchor { window, frame in testProbe?.retryNative[item.id] = (window, frame) })
                    #endif
            }
            OSChipButton(title: item.canRetry ? "取消" : "移除") { model.cancelPrimaryOutboxItem(item) }
                .disabled(item.state == .sending)
                .accessibilityLabel((item.canRetry ? "取消：" : "移除：") + item.title)
                .accessibilityIdentifier("primary-outbox-cancel-" + item.id.uuidString)
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.cancelFrames[item.id] = $0 }
                .background(PrimaryOutboxButtonAnchor { window, frame in testProbe?.cancelNative[item.id] = (window, frame) })
                #endif
        }
    }

}

#if DEBUG
@MainActor final class PrimaryOutboxViewProbe {
    var bannerVisible = false
    var detailsVisible = false
    var bannerFrame: CGRect?
    var deviceFrame: CGRect?
    var retryFrames: [UUID: CGRect] = [:]
    var cancelFrames: [UUID: CGRect] = [:]
    var retryNative: [UUID: (NSWindow, CGRect)] = [:]
    var cancelNative: [UUID: (NSWindow, CGRect)] = [:]
}

/// 測試只讀實際按鈕的 AppKit 視窗座標；popover 不沿用主視窗的 SwiftUI global 座標。
private struct PrimaryOutboxButtonAnchor: NSViewRepresentable {
    let report: (NSWindow, CGRect) -> Void
    final class Anchor: NSView {
        var report: ((NSWindow, CGRect) -> Void)?
        override var frame: NSRect { didSet { capture() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); capture() }
        override func layout() { super.layout(); capture() }
        func capture() {
            guard let window, bounds.width > 0 else { return }
            report?(window, convert(bounds, to: nil))
        }
    }
    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.report = report; return view }
    func updateNSView(_ view: Anchor, context: Context) { view.report = report; view.capture() }
}
#endif
