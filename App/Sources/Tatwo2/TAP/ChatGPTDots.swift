import AppKit
import SwiftUI

enum ChatGPTDotsState: Equatable {
    case closed, loading, ready, unavailable
    case blocked(String)

    static let url = URL(string: "https://chatgpt.com/dots")!
    static let unavailableText = "這個 ChatGPT 帳號還沒有 Dots"

    static func loaded(url: String, status: Int) -> Self {
        guard let value = URL(string: url), value.scheme == "https", value.host == "chatgpt.com",
              value.path == "/dots" || value.path.hasPrefix("/dots/") else { return .unavailable }
        if [401, 403, 404, 410].contains(status) || ["unavailable", "access-denied", "error"].contains(value.lastPathComponent) {
            return .unavailable
        }
        if status >= 500 || status == 0 { return .blocked("Dots 還沒打開，請稍後再試") }
        return .ready
    }
}

struct ChatGPTDotsSidebarRow: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        Button { model.openDots() } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.2x2").font(.system(size: 12)).foregroundStyle(ChatGlassChipModifier.chipForeground).frame(width: 16)
                    .accessibilityHidden(true)
                Text("Dots").font(ChatTypography.systemUI(13, weight: model.dotsPresented ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatGlassChip(isSelected: model.dotsPresented)
        .accessibilityIdentifier("chatgpt.dots")
#if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.dotsControlFramesForSelfTest["chatgpt.dots"] = $0 }
#endif
    }
}

struct ChatGPTDotsPane: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    @WorkspaceObservedObject var tap: ChatGPTTap

    init(model: ChatGPTSpaceModel) {
        _model = WorkspaceObservedObject(wrappedValue: model)
        _tap = WorkspaceObservedObject(wrappedValue: model.tap)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.closeDots() } label: {
                    Label("返回", systemImage: "chevron.left")
                        .padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(.plain)
                .chatGlassChip()
                .accessibilityIdentifier("chatgpt.dots.back")
#if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.dotsControlFramesForSelfTest["chatgpt.dots.back"] = $0 }
#endif
                Text("Dots").font(ChatTypography.systemUI(13, weight: .medium))
                Spacer()
                Button { model.openDotsInBrowser() } label: {
                    Text("在瀏覽器打開").padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(.plain)
                .chatGlassChip()
                .accessibilityIdentifier("chatgpt.dots.browser")
#if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.dotsControlFramesForSelfTest["chatgpt.dots.browser"] = $0 }
#endif
            }
            .font(ChatTypography.systemUI(12, weight: .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 10)

            ZStack {
                if tap.dotsState == .loading || tap.dotsState == .ready {
                    pageSurface
                        .accessibilityIdentifier("chatgpt.dots.web")
                }
                switch tap.dotsState {
                case .ready: EmptyView()
                case .unavailable:
                    notice(ChatGPTDotsState.unavailableText)
                        .accessibilityIdentifier("chatgpt.dots.unavailable")
                case .blocked(let text): notice(text)
                case .loading, .closed:
                    // 尚未驗到原生導覽資料之前遮住網頁，導回或 HTTP 錯誤的原文不會露出。
                    VStack(spacing: 10) { ProgressView().controlSize(.small); Text("開啟 Dots…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.dots.pane")
    }

    @ViewBuilder private var pageSurface: some View {
#if DEBUG
        if let page = model.dotsPageForSelfTest { page }
        else if let pod = tap.webPod { TapPodHostView(pod: pod, presentsPage: true) }
#else
        if let pod = tap.webPod { TapPodHostView(pod: pod, presentsPage: true) }
#endif
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(ChatTypography.systemUI(13, weight: .regular)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
