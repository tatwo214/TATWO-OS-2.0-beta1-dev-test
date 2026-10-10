import AppKit
import SwiftUI

enum ChatGPTWebSpace {
    static let enabledKey = "tatwo.chatgpt.webSpace"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
    static func usesBrowserChrome(_ mode: ChatRunMode) -> Bool {
        mode == .browser || (mode == .chatgpt && isEnabled)
    }
    #if DEBUG
    static var tabFramesForSelfTest: [Bool: CGRect] = [:]
    static var tapForSelfTest: ChatGPTTap?
    #endif
    static var windowTap: ChatGPTTap {
        #if DEBUG
        if let tapForSelfTest { return tapForSelfTest }
        #endif
        return .shared
    }
}

struct ChatGPTWebSpacePane: View {
    @ObservedObject var tap: ChatGPTTap
    let pod: TapWebPod
    var showsTabs = false
    @ObservedObject private var connectEntry = HandsConnectEntry.shared
    @State private var dots = false
    @State private var hostID = UUID()
    @State private var occupied = false
    @State private var page: TatwoCEFBrowserView?
    @State private var failure: String?
    @State private var lease: UUID?
    @State private var waiting = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTabs {
                ChatGPTWebSpaceHeader(dots: $dots, entryText: connectEntry.webEntryText, connect: { connectEntry.tap() })
            }
            ZStack {
                if let page { ChatGPTWebSpaceSurface(page: page, pod: pod) }
                else if occupied { Text("ChatGPT 已在另一個視窗顯示").foregroundStyle(.secondary) }
                else if let failure { Text(failure).foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(BrowserDownloadSurface(scope: hostID.uuidString))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.webSpace")
        .onReceive(NotificationCenter.default.publisher(for: TapWebPod.spaceChanged, object: pod).receive(on: RunLoop.main)) { _ in mountPage() }
        .task(id: dots) {
            guard !Task.isCancelled else { return }
            page = nil; failure = nil; waiting = true
            if lease == nil { lease = tap.acquireLease(backgroundWork: true) }
            tap.start()
            mountPage()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            if waiting, pod.browser?.canShareRequestContext != true { failure = TapPodError.profileUnavailable.localizedDescription }
        }
        .onDisappear {
            waiting = false; pod.releaseSpaceHost(hostID)
            if let lease { tap.releaseLease(lease) }
            lease = nil; page = nil
        }
    }
    private func mountPage() {
        guard waiting, failure == nil, pod.browser?.canShareRequestContext == true else { return }
        occupied = !pod.acquireSpaceHost(hostID)
        guard !occupied else { return }
        do {
            let next = try dots ? pod.openDotsSpacePage() : pod.openSpacePage()
            guard next.superview == nil else { return }
            page = next; waiting = false
            if let lease { tap.releaseLease(lease) }
            lease = tap.acquireLease()
        } catch { failure = error.localizedDescription }
    }
}

/// 私訊框的原生頂列；網頁內容由 Pod 自己畫。
struct ChatGPTWebSpaceHeader: View {
    @Binding var dots: Bool
    var entryText: String?
    var connect: () -> Void
    var body: some View {
                HStack(spacing: GlobalDMWebSheetLayout.segmentInset) {
                    ForEach([false, true], id: \.self) { value in
                        Button { dots = value } label: {
                            Text(value ? "Dots" : "ChatGPT").padding(.horizontal, DMPhone.edgeInset)
                                .frame(height: GlobalDMWebSheetLayout.segmentHeight)
                        }
                        .buttonStyle(.plain).chatGlassChip()
                        .overlay {
                            if dots == value {
                                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                                    .strokeBorder(ChatGlassChipModifier.chipForeground.opacity(0.55), lineWidth: 1.5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityAddTraits(dots == value ? .isSelected : [])
                        .accessibilityIdentifier(value ? "chatgpt.webSpace.dots" : "chatgpt.webSpace.chatgpt")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ChatGPTWebSpace.tabFramesForSelfTest[value] = $0 }
                        #endif
                    }
                    if !dots, let text = entryText {
                        Button { connect() } label: { Label("連線", systemImage: "link") }
                            .buttonStyle(.plain).chatGlassChip()
                            .help(text)
                            .accessibilityIdentifier("tatwo.dm.handsConnect.webEntry")
                    }
                }
                .font(ChatTypography.systemUI(DMPhone.TextSize.footnote, weight: .regular))
                .padding(GlobalDMWebSheetLayout.segmentInset)
    }
}

private struct ChatGPTWebSpaceSurface: NSViewRepresentable {
    let page: TatwoCEFBrowserView
    let pod: TapWebPod
    func makeCoordinator() -> TapWebPod { pod }
    func makeNSView(context: Context) -> TatwoCEFContainerView { TatwoCEFContainerView(frame: .zero) }
    func updateNSView(_ view: TatwoCEFContainerView, context: Context) {
        guard view.browserView !== page else { return }
        guard page.superview == nil else { return }
        if view.browserView != nil { view.detachBorrowedBrowser(); pod.spaceDidChange() }
        view.mountBorrowedBrowser(page)
    }
    static func dismantleNSView(_ view: TatwoCEFContainerView, coordinator: TapWebPod) {
        view.detachBorrowedBrowser()
        coordinator.spaceDidChange()
    }
}
