import SwiftUI

private struct DownloadMotionKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var browserDownloadReducedMotion: Bool? {
        get { self[DownloadMotionKey.self] }
        set { self[DownloadMotionKey.self] = newValue }
    }
}

struct BrowserDownloadIndicator: View {
    var scope = "browser"
    @ObservedObject private var flight = BrowserDownloadFlight.shared
    private var active: [BrowserDownloadStore.Item] { flight.items(scope).filter { !$0.state.isTerminal } }
    private var completionID: String? { flight.completions.first { flight.routes[$0] == scope } }
    private var progress: Double? { active.isEmpty || active.contains { $0.total <= 0 } ? nil : min(1, active.reduce(0) { $0 + Double($1.received) } / active.reduce(0) { $0 + Double(max($1.total, $1.received)) }) }
    @ObservedObject private var store = BrowserDownloadStore.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.browserDownloadReducedMotion) private var motionOverride
    private var reduceMotion: Bool { systemReduceMotion || motionOverride == true }
    @State private var dropping = false
    @State private var spinning = false
    private var unknown: Bool { !active.isEmpty && progress == nil }
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 1.5)
            if !active.isEmpty || completionID != nil {
                Circle().trim(from: 0, to: completionID != nil ? 1 : progress ?? 0.25)
                    .stroke(BrowserDownloadPalette.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 + (!reduceMotion && unknown && spinning ? 360 : 0)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: progress)
            }
            Image(systemName: completionID != nil ? "checkmark" : "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .keyframeAnimator(initialValue: CGFloat(1), trigger: completionID) { view, scale in view.scaleEffect(reduceMotion ? 1 : scale) } keyframes: { _ in MoveKeyframe(0.4); CubicKeyframe(1.2, duration: 0.22); CubicKeyframe(1, duration: 0.14) }.offset(y: !reduceMotion && dropping ? 4 : 0)
            if !store.unreadCompletions.isEmpty {
                Circle().fill(LiquidGlassTokens.browserDownloadBadge).frame(width: 5, height: 5).offset(x: 10, y: -10)
            }
        }
        .frame(width: 22, height: 22)
        .background(BrowserDownloadRegistration(scope: scope, anchor: true))
        .keyframeAnimator(initialValue: CGFloat(1), trigger: flight.pulses[scope]) { view, scale in view.scaleEffect(reduceMotion ? 1 : scale) } keyframes: { _ in CubicKeyframe(1.25, duration: 0.16); CubicKeyframe(1, duration: 0.16) }
#if DEBUG
        .background(W268DownloadAcceptance.Probe(kind: "indicator", motion: "\(!reduceMotion && dropping):\(!reduceMotion && unknown && spinning)", phase: completionID != nil ? "completed" : active.isEmpty ? "idle" : "active"))
#endif
        .accessibilityElement(children: .ignore).accessibilityIdentifier("browser.download.indicator")
        .accessibilityLabel("下載進度")
        .accessibilityValue("\(completionID != nil ? "已下載" : active.isEmpty ? "閒置" : "下載中")；\(reduceMotion ? "減少動態" : "動畫")；\(store.unreadCompletions.count) 個未讀")
        .task(id: flight.pulses[scope]) {
            guard completionID == nil, let item = flight.feedback(scope), flight.landed.contains(item.id), !reduceMotion else { dropping = false; return }
            withAnimation(.easeIn(duration: 0.16)) { dropping = true }
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeOut(duration: 0.18)) { dropping = false }
        }
        .onChange(of: unknown && !reduceMotion, initial: true) { _, rotate in
            spinning = false
            if rotate { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true } }
        }
    }
}

struct BrowserDownloadCard: View {
    var scope = "browser"
    var width = BrowserSidebarMetrics.downloadsWidth
    @ObservedObject private var flight = BrowserDownloadFlight.shared
    @ObservedObject private var store = BrowserDownloadStore.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.browserDownloadReducedMotion) private var motionOverride
    private var reduceMotion: Bool { systemReduceMotion || motionOverride == true }
    @State private var hovered = false
    var body: some View {
        Group {
            if let item = flight.feedback(scope), flight.landed.contains(item.id) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : item.failure != nil ? "exclamationmark.circle" : item.isImage ? "photo" : item.fileURL.pathExtension == "dmg" ? "externaldrive" : "doc.fill")
                            .font(.system(size: 24)).foregroundStyle(BrowserDownloadPalette.purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(item.done ? "已下載 · 點此在 Finder 顯示" : item.time)
                                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.75)).monospacedDigit()
                        }
                    }
                    if !item.state.isTerminal {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.secondary.opacity(0.15))
                                Capsule().fill(BrowserDownloadPalette.gradient).frame(width: geometry.size.width * (item.total > 0 ? min(1, Double(item.received) / Double(max(item.total, item.received))) : 0.25))
                            }
                        }.frame(height: 3)
                            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: item.received)
                    }
                    if let failure = item.failure { Text(failure).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                    if item.state == .failed || item.state == .cancelled {
                        Button("重試") { store.retry(item) }.disabled(!store.canRetry(item)).buttonStyle(.plain)
                    }
                    if item.state == .failed, store.revealURL(item) != nil {
                        Button("在 Finder 顯示") { store.reveal(item) }.buttonStyle(.plain)
                    }
                    let others = flight.items(scope).filter { $0.id != item.id && !$0.state.isTerminal }.count
                    if others > 0 { Text("還有 \(others) 個").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.75)) }
                }
                .padding(12).frame(width: width, alignment: .leading)
                .foregroundStyle(Color.primary).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1), lineWidth: 0.5) }
                .shadow(color: LiquidGlassTokens.browserShadowColor.opacity(0.18), radius: 12, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture { if item.done { store.reveal(item) } }
#if DEBUG
                .background(W268DownloadAcceptance.Probe(kind: "card"))
#endif
                .onHover { if hovered && !$0 && item.done { flight.deadlines[item.id] = Date().addingTimeInterval(4); store.deferFeedbackDismissal(item.id) }; hovered = $0 }.transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(x: -14).combined(with: .scale(scale: 0.96)).combined(with: .opacity), removal: .opacity))
                .accessibilityElement(children: .contain).accessibilityIdentifier("browser.download.card")
                .task(id: "\(item.id):\(item.state):\(hovered)") {
                    guard item.done, !hovered else { return }
                    do { try await Task.sleep(for: .seconds(max(0, (flight.deadlines[item.id] ?? store.feedbackDeadline).timeIntervalSinceNow))) } catch { return }
                    flight.dismiss(item.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.26), value: flight.landed)
    }
}
