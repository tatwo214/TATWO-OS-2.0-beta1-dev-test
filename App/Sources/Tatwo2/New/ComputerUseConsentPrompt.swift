import AppKit
import SwiftUI

/// Compatibility facade: existing Computer Use callers retain their Decision and cancellation API.
@MainActor
final class ComputerUseConsentPrompt: ObservableObject {
    static let shared = ComputerUseConsentPrompt()
    typealias Request = IslandNotice.Request
    typealias Decision = IslandNotice.Decision
    private var pendingIDs: Set<UUID> = []
    var current: Request? {
        guard let request = IslandNotice.shared.current, pendingIDs.contains(request.id) else { return nil }
        return request
    }
    var hostAvailable: Bool {
        get { IslandNotice.shared.hostAvailable }
        set { IslandNotice.shared.hostAvailable = newValue }
    }

    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision {
        let id = UUID()
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        return await IslandNotice.shared.ask(title: title, detail: detail, allowLabel: allowLabel,
                                             timeout: timeout, requestID: id)
    }

    func resolve(_ decision: Decision) {
        // A Computer Use stop cannot dismiss an unrelated confirm/info card.
        if decision == .allow {
            if let current { IslandNotice.shared.resolve(decision, id: current.id) }
        } else {
            for id in pendingIDs { IslandNotice.shared.resolve(decision, id: id) }
        }
    }
}

enum ComputerUseIslandContentKind: Equatable {
    case collapsed, consent, blankTemplate

    static func select(isExpanded: Bool, hasPendingConsent: Bool) -> Self {
        guard isExpanded else { return .collapsed }
        return hasPendingConsent ? .consent : .blankTemplate
    }
}

/// Compatibility name for the shared notice surface; idle expanded content remains blank.
typealias ComputerUseIslandContent = IslandNoticeContent

struct IslandNoticeContent: View {
    @ObservedObject private var prompt = IslandNotice.shared
    @ObservedObject private var externalComputer = HandsComputerUse.shared
    let isExpanded: Bool

    init(prompt: IslandNotice? = nil, isExpanded: Bool) {
        _prompt = ObservedObject(wrappedValue: prompt ?? .shared)
        self.isExpanded = isExpanded
    }

    var body: some View {
        switch ComputerUseIslandContentKind.select(
            isExpanded: isExpanded, hasPendingConsent: prompt.current != nil || prompt.displayMeter != nil
        ) {
        case .consent:
            if let request = prompt.current {
                ComputerUseConsentCard(request: request)
            } else if let meter = prompt.displayMeter?.meter {
                IslandDisplayFeedbackContent(meter: meter)
            }
        case .blankTemplate:
            if externalComputer.isOperating, let request = externalComputer.current {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ChatGPT 正在操作〈\(request.appDisplayName)〉").font(.headline)
                    Text("只操作核准的 App；停止後須重新由你核准").font(.caption)
                    Button("停止", role: .destructive) { externalComputer.stop() }
                        .accessibilityLabel("停止 ChatGPT 操作畫面")
                }
                .padding()
                .frame(width: LiquidGlassTokens.islandNoticeWidth)
                .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
            } else {
                IslandBlankTemplate()
            }
        case .collapsed:
            EmptyView()
        }
    }
}

/// Content only: the original Island surface still owns the notch, glass and geometry.
struct IslandDisplayFeedbackContent: View {
    let meter: IslandNotice.Meter
    private var percentage: Double { meter.percentage.isFinite ? min(100, max(0, meter.percentage)) : 0 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: meter.symbol)
                    .accessibilityLabel(meter.symbol == "sun.max.fill" ? "亮度" : "音量")
                Text(meter.displayName).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(percentage.rounded()))%")
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LiquidGlassTokens.brandAccent)
                            .frame(width: geometry.size.width * percentage / 100)
                    }
            }
            .frame(height: 3)
            .accessibilityLabel("\(Int(percentage.rounded()))%")
        }
        .padding(.horizontal, 26)
        .frame(width: LiquidGlassTokens.islandBlankWidth, height: LiquidGlassTokens.islandBlankHeight)
        .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
    }
}

/// Preserve the former work content's footprint; the shell supplies the glass.
struct IslandBlankTemplate: View {
    var body: some View {
        Color.clear
            .frame(width: LiquidGlassTokens.islandBlankWidth, height: LiquidGlassTokens.islandBlankHeight)
            .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
    }
}

/// A short, dismissible Island heads-up that is not a consent (no allow/deny). It opens the Island for a
/// few seconds then collapses. Throttled so it never spams. Used for the browser-profile capacity warning
/// (使用者：滿了自動清最久沒用的，提前 20 個時在 island 通知).
@MainActor
final class ComputerUseIslandNotice: ObservableObject {
    static let shared = ComputerUseIslandNotice()

    struct Message: Identifiable, Equatable { let id = UUID(); let title: String; let detail: String }

    private var lastShownByKey: [String: Date] = [:]

    func show(key: String, title: String, detail: String, seconds: TimeInterval = 7, throttle: TimeInterval = 300) {
        if let last = lastShownByKey[key], Date().timeIntervalSince(last) < throttle { return }
        lastShownByKey[key] = Date()
        IslandNotice.shared.info(title: title, detail: detail, duration: seconds)
    }

    func dismiss() {
        guard let request = IslandNotice.shared.current, request.kind == .info else { return }
        IslandNotice.shared.resolve(.cancel, id: request.id)
    }

    /// Browser independent-storage capacity: warn from `warnAt` up to `limit`; explain LRU auto-eviction.
    nonisolated static func browserCapacity(count: Int, limit: Int, warnAt: Int) {
        guard count >= warnAt else { return }
        Task { @MainActor in
            let title = count >= limit ? "瀏覽器獨立資料已滿（\(count)/\(limit)）"
                                       : "瀏覽器獨立資料快滿了（\(count)/\(limit)）"
            shared.show(key: "browser-capacity",
                        title: title,
                        detail: "滿了會自動清掉最久沒用、目前沒開著的那一份；很舊的聊天可能要重新登入。")
        }
    }
}

/// One visual layout for ask, confirm, info and the legacy heads-up facade.
private struct IslandNoticeCardLayout<Actions: View, Countdown: View>: View {
    let title: String
    let detail: String
    let info: Bool
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let countdown: () -> Countdown

    var body: some View {
        HStack(spacing: LiquidGlassTokens.islandNoticeColumnSpacing) {
            if info {
                Image(systemName: "info")
                    .font(.system(size: LiquidGlassTokens.islandNoticeInfoFontSize, weight: .semibold))
                    .frame(width: LiquidGlassTokens.islandNoticeInfoSize, height: LiquidGlassTokens.islandNoticeInfoSize)
                    .background(LiquidGlassTokens.islandNoticeButtonFill, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: LiquidGlassTokens.islandNoticeLineSpacing) {
                Text(title).font(.system(size: LiquidGlassTokens.islandNoticeTitleSize, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.islandNoticeTitleColor).lineLimit(1)
                Text(detail).font(.system(size: LiquidGlassTokens.islandNoticeDetailSize))
                    .foregroundStyle(LiquidGlassTokens.islandNoticeDetailColor)
                    .lineLimit(1).truncationMode(.tail)
                countdown()
                    .font(.system(size: LiquidGlassTokens.islandNoticeCountdownSize))
                    .monospacedDigit().foregroundStyle(LiquidGlassTokens.islandNoticeCountdownColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions().fixedSize()
        }
        .foregroundStyle(LiquidGlassTokens.islandNoticeTitleColor)
        .padding(.vertical, LiquidGlassTokens.islandNoticeVerticalPadding)
        .padding(.leading, LiquidGlassTokens.islandNoticeLeadingPadding)
        .padding(.trailing, LiquidGlassTokens.islandNoticeTrailingPadding)
        .frame(width: LiquidGlassTokens.islandNoticeWidth)
        .background(LiquidGlassTokens.islandNoticeFill,
                    in: RoundedRectangle(cornerRadius: LiquidGlassTokens.islandNoticeRadius))
        .shadow(color: .black.opacity(LiquidGlassTokens.islandNoticeShadowOpacity),
                radius: LiquidGlassTokens.islandNoticeShadowRadius, y: LiquidGlassTokens.islandNoticeShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct ComputerUseNoticeCard: View {
    let message: ComputerUseIslandNotice.Message

    var body: some View {
        IslandNoticeCardLayout(title: message.title, detail: message.detail, info: true) {
            Button { ComputerUseIslandNotice.shared.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: LiquidGlassTokens.islandNoticeButtonFontSize))
                    .frame(width: LiquidGlassTokens.islandNoticeButtonSize, height: LiquidGlassTokens.islandNoticeButtonSize)
                    .background(LiquidGlassTokens.islandNoticeButtonFill, in: Circle())
            }.buttonStyle(.plain).help("知道了").accessibilityLabel("知道了")
        } countdown: { EmptyView() }
        .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
    }
}

/// W178：Island 卡片那一行放得下整段內容嗎（用卡片實際的字型量寬度；有換行、Tab 或看不見的字元就不算）。
enum IslandNoticeLine {
    @MainActor static func fits(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\t"), IslandNotice.visibleText(text) == text else { return false }
        let available = LiquidGlassTokens.islandNoticeWidth - LiquidGlassTokens.islandNoticeLeadingPadding
            - LiquidGlassTokens.islandNoticeTrailingPadding - LiquidGlassTokens.islandNoticeColumnSpacing
            - LiquidGlassTokens.islandNoticeButtonSize * 2 - LiquidGlassTokens.islandNoticeButtonSpacing
        let font = NSFont.systemFont(ofSize: LiquidGlassTokens.islandNoticeDetailSize)
        return (text as NSString).size(withAttributes: [.font: font]).width <= available * 0.92
    }
}

struct ComputerUseConsentCard: View {
    let request: ComputerUseConsentPrompt.Request

    /// 要看完整內容才能允許的請求（AI 代跑的指令）：那一行放得下就照常；放不下就不給允許鍵，只給「查看」。
    private var needsFullView: Bool {
        request.fullTextRequired && !(request.summaryLine.map(IslandNoticeLine.fits) ?? false)
    }
    private var line: String {
        guard request.fullTextRequired else { return request.detail }
        return needsFullView ? "內容較長，按眼睛看完整內容再決定" : request.summaryLine ?? ""
    }

    var body: some View {
        IslandNoticeCardLayout(title: request.title, detail: line, info: request.kind == .info) {
            if request.kind != .info {
                HStack(spacing: LiquidGlassTokens.islandNoticeButtonSpacing) {
                    if needsFullView {
                        Button { IslandNotice.shared.showFullText(id: request.id) } label: {
                            Image(systemName: "eye")
                                .font(.system(size: LiquidGlassTokens.islandNoticeButtonFontSize, weight: .bold))
                                .frame(width: LiquidGlassTokens.islandNoticeButtonSize, height: LiquidGlassTokens.islandNoticeButtonSize)
                                .background(LiquidGlassTokens.islandNoticeButtonFill, in: Circle())
                        }
                        .buttonStyle(.plain).help("看完整內容再決定").accessibilityLabel("查看完整內容")
                    } else {
                        Button { IslandNotice.shared.resolve(.allow, id: request.id) } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: LiquidGlassTokens.islandNoticeButtonFontSize, weight: .bold))
                                .frame(width: LiquidGlassTokens.islandNoticeButtonSize, height: LiquidGlassTokens.islandNoticeButtonSize)
                                .background(LiquidGlassTokens.islandNoticeAllowFill, in: Circle())
                        }
                        .buttonStyle(.plain).help(request.allowLabel).accessibilityLabel(request.allowLabel)
                    }
                    Button { IslandNotice.shared.resolve(.cancel, id: request.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: LiquidGlassTokens.islandNoticeButtonFontSize, weight: .bold))
                            .frame(width: LiquidGlassTokens.islandNoticeButtonSize, height: LiquidGlassTokens.islandNoticeButtonSize)
                            .background(LiquidGlassTokens.islandNoticeButtonFill, in: Circle())
                    }
                    .buttonStyle(.plain).help(request.cancelLabel).accessibilityLabel(request.cancelLabel)
                }
            }
        } countdown: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(request.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text(request.kind == .info ? "\(left) 秒後收起" : "\(left) 秒後自動取消")
            }
        }
        .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
    }
}
