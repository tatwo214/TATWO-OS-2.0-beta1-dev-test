import AppKit
import ImageIO
import SwiftUI

// W177 ChatGPT Space 的其他頁面（使用者 2026-09-25「2全要」）：圖庫、排程、外掛、網站、個人化、帳號、分享、即時語音。
// 版面照 ChatGPT 桌面版（使用者 09-25「chatgpt classic 我認為這是最適合研究的ui版本」）；文字一律繁體中文。

/// 側欄的頁面（nil＝對話）。
enum ChatGPTPage: String, CaseIterable, Identifiable {
    case library
    case scheduled
    case plugins
    case sites
    case personalization

    var id: String { rawValue }

    /// ChatGPT 繁體中文介面的叫法（桌面版：圖庫）。
    var title: String {
        switch self {
        case .library: "圖庫"
        case .scheduled: "排程"
        case .plugins: "外掛"
        case .sites: "網站"
        case .personalization: "個人化"
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .scheduled: "clock"
        case .plugins: "puzzlepiece.extension"
        case .sites: "globe"
        case .personalization: "person.crop.circle"
        }
    }

    /// 側欄上列出來的（個人化在左下帳號選單裡）。
    static let sidebar: [ChatGPTPage] = [.library, .scheduled, .plugins, .sites]
}

/// ChatGPT 的英文標籤換成繁體中文（伺服器已經給中文就原樣用）。
enum ChatGPTLabels {
    static let efforts: [String: String] = [
        "Instant": "即時", "Medium": "中等", "High": "高", "Extra High": "極高", "Pro": "Pro",
        "Auto": "自動", "Thinking": "思考", "Light": "輕度", "Standard": "標準", "Extended": "延伸", "Heavy": "深度",
    ]
    /// 說明文字：只放 ChatGPT 桌面版繁中真的有的（Instant／Auto／Thinking／Pro）；伺服器已給中文檔名時也對得到。
    /// 其他檔位 ChatGPT 沒有說明，就不顯示（不自己編）。
    static let details: [String: String] = [
        "Instant": "立即回答", "Auto": "決定要思考多久", "Thinking": "思考較長時間以取得更好的回答", "Pro": "研究等級智慧",
        "即時": "立即回答", "自動": "決定要思考多久", "思考": "思考較長時間以取得更好的回答",
    ]

    static func effort(_ title: String) -> String { efforts[title] ?? title }

    /// ChatGPT 給的說明；有的檔位伺服器只給版本號（例：「5.6」，09-25 實機），那種不算說明，改用上面的中文。
    static func detail(for title: String, given: String) -> String {
        let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionOnly = text.range(of: #"^[0-9.•·\s]+$"#, options: .regularExpression) != nil
        return text.isEmpty || versionOnly ? (details[title] ?? "") : text
    }

    static func version(_ title: String) -> String {
        title.replacingOccurrences(of: "Latest", with: "最新").replacingOccurrences(of: "Legacy", with: "舊版")
    }
}

// MARK: - 側欄：導覽列與帳號

struct ChatGPTSidebarNavRow: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let page: ChatGPTPage

    var body: some View {
        let active = model.page == page
        Button { model.open(page) } label: {
            HStack(spacing: 8) {
                Image(systemName: page.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityHidden(true)
                Text(page.title).font(ChatTypography.systemUI(13, weight: active ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(active ? LiquidGlassTokens.brandAccent.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatgpt.page.\(page.rawValue)")
    }
}

/// 左下的帳號（跟網頁、桌面版一樣：頭像＋名字＋方案），點開有個人化、設定、說明。
struct ChatGPTAccountRow: View {
    @ObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        Menu {
            Button { model.open(.personalization) } label: { Label("個人化", systemImage: "person.crop.circle") }
            // 設定＝OS 這座 TAP 的設定（連線、登入、休眠）；不開 ChatGPT 網頁版（使用者 09-25）。
            Button { model.openTapSettings() } label: { Label("連線與登入", systemImage: "gearshape") }
            Button {
                if let url = URL(string: "https://help.openai.com/") { NSWorkspace.shared.open(url) }
            } label: { Label("說明", systemImage: "questionmark.circle") }
        } label: {
            HStack(spacing: 10) {
                ChatGPTAvatar(model: model, account: model.account)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account.map { $0.name.isEmpty ? $0.email : $0.name } ?? "ChatGPT")
                        .font(ChatTypography.systemUI(13, weight: .medium))
                        .lineLimit(1)
                    if let plan = model.account?.plan, !plan.isEmpty {
                        Text(plan.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("帳號")
        .accessibilityIdentifier("chatgpt.account")
        .task { await model.loadAccount() }
    }
}

struct ChatGPTAvatar: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let account: TapAccount?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.pink.opacity(0.75))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text(account?.initials ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .task(id: account?.pictureURL) {
            guard let url = account?.pictureURL, let data = await model.tap.remoteImage(url) else { return }
            image = NSImage(data: data)
        }
    }
}

/// 外掛圖示這類外部小圖：不落地的連線、只放記憶體。
struct ChatGPTRemoteIcon: View {
    let url: URL?
    let fallback: String
    var size: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.primary.opacity(0.05))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(size * 0.11)
            } else {
                Image(systemName: fallback).font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url, let data = await ChatGPTTap.shared.remoteImage(url) else { return }
            image = NSImage(data: data)
        }
    }
}

// MARK: - 頁面的共用外框

struct ChatGPTPageScaffold<Content: View>: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }
                Spacer()
                if let trailing { trailing }
            }
            .padding(.top, 18)
            if let notice = model.pageNotice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let failure = model.pageFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                    if model.pageLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 18)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
    }
}

private func chipButton(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .chatGlassChip()
}

// MARK: - 排程

struct ChatGPTScheduledView: View {
    @ObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        ChatGPTPageScaffold(model: model, title: "排程", subtitle: "ChatGPT 會在指定時間自動執行，結果出現在對話裡",
                            trailing: AnyView(chipButton("新增排程", systemImage: "plus") { model.newAutomation() })) {
            if model.automations.isEmpty, !model.pageLoading, model.pageFailure == nil {
                Text("還沒有排程。按「新增排程」，在對話裡說要什麼時候做什麼。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 30)
            }
            ForEach(model.automations) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? "未命名排程" : item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(ChatGPTSchedule.label(for: item)).font(.system(size: 12)).foregroundStyle(.secondary)
                        if !item.prompt.isEmpty {
                            Text(item.prompt).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 12)
                    if !item.completed {
                        Toggle("", isOn: Binding(get: { item.enabled }, set: { model.setAutomation(item, enabled: $0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.primary)
                            .accessibilityLabel(item.enabled ? "暫停「\(item.title)」" : "開啟「\(item.title)」")
                    }
                    Menu {
                        if let conversationID = item.conversationID {
                            Button("打開對話") { model.select(conversationID) }
                        }
                        Button("刪除", role: .destructive) { model.removeAutomationTarget = item }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("排程選項：\(item.title)")
                }
                .padding(.vertical, 12)
                Divider()
            }
        }
        .alert("刪除這個排程？", isPresented: Binding(get: { model.removeAutomationTarget != nil },
                                                  set: { if !$0 { model.removeAutomationTarget = nil } })) {
            Button("刪除", role: .destructive) { model.confirmRemoveAutomation() }
            Button("取消", role: .cancel) { model.removeAutomationTarget = nil }
        } message: {
            Text("「\(model.removeAutomationTarget?.title ?? "")」會從 ChatGPT 一起刪除，之後不會再執行。")
        }
    }
}

/// ChatGPT 的排程：狀態照網頁的順序（09-25 讀網頁程式）——已完成 → 已暫停 → ChatGPT 自己的說明 → 監控中 → 時間。
/// 時間是 iCalendar（RRULE 週期、或只有 DTSTART 的一次性），換成一句中文；看不懂就說「時間未設定」，不露出原始代碼。
enum ChatGPTSchedule {
    static func label(for item: TapAutomation, now: Date = Date()) -> String {
        if item.completed { return "已完成" }
        if !item.enabled { return "已暫停" }
        let display = item.display.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty { return displayLabels[display.lowercased()] ?? display }
        if item.watching { return "監控中" }
        return describe(item.schedule, now: now)
    }

    /// 網頁會直接顯示的英文說明 → 中文（其他照原樣）。
    static let displayLabels: [String: String] = ["monitoring": "監控中", "paused": "已暫停", "completed": "已完成",
                                                  "hourly": "每小時", "daily": "每天", "weekly": "每週", "monthly": "每月",
                                                  "recurring": "週期性"]

    static func describe(_ raw: String, now: Date = Date()) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let start = lines.first { $0.uppercased().hasPrefix("DTSTART") }.flatMap(startDate)
        guard let range = text.range(of: "RRULE:") else {
            if let start { return once(start, now: now) }
            if text.isEmpty || text.uppercased().contains("BEGIN:") { return "時間未設定" }
            return text
        }
        let rule = text[range.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var parts: [String: String] = [:]
        for pair in rule.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { parts[kv[0].uppercased()] = kv[1] }
        }
        var hour = parts["BYHOUR"].flatMap { Int($0.split(separator: ",").first ?? "") }
        var minute = parts["BYMINUTE"].flatMap { Int($0.split(separator: ",").first ?? "") }
        if hour == nil, let start {
            let components = Calendar.current.dateComponents([.hour, .minute], from: start)
            hour = components.hour
            minute = minute ?? components.minute
        }
        let time = hour.map { String(format: "%02d:%02d", $0, minute ?? 0) } ?? ""
        let days = ["MO": "一", "TU": "二", "WE": "三", "TH": "四", "FR": "五", "SA": "六", "SU": "日"]
        let interval = Int(parts["INTERVAL"] ?? "1") ?? 1
        let suffix = time.isEmpty ? "" : " \(time)"
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": return (interval > 1 ? "每 \(interval) 天" : "每天") + suffix
        case "WEEKLY":
            let byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { days[String($0.suffix(2)).uppercased()] }
            if byDay.count == 5, !byDay.contains("六"), !byDay.contains("日") { return "平日" + suffix }
            return (interval > 1 ? "每 \(interval) 週" : "每週") + byDay.joined(separator: "、") + suffix
        case "MONTHLY":
            let day = parts["BYMONTHDAY"].map { " \($0) 號" } ?? ""
            return (interval > 1 ? "每 \(interval) 個月" : "每月") + day + suffix
        case "HOURLY": return interval > 1 ? "每 \(interval) 小時" : "每小時"
        case "YEARLY": return "每年" + suffix
        default: return "週期性"
        }
    }

    /// DTSTART;TZID=Asia/Taipei:20260820T043000、DTSTART:20260819T201421Z、DTSTART;VALUE=DATE:20260820。
    static func startDate(_ line: String) -> Date? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let tzid = line[..<colon].split(separator: ";").dropFirst()
            .first { $0.uppercased().hasPrefix("TZID=") }.map { String($0.dropFirst(5)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            formatter.timeZone = tzid.flatMap(TimeZone.init(identifier:)) ?? .current
            formatter.dateFormat = value.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        }
        return formatter.date(from: value)
    }

    static func once(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 外掛

struct ChatGPTPluginsView: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject private var index = TranslationIndex.shared
    @State private var expanded: Set<String> = []

    /// 版面照網頁版 Plugins（09-25 對照）：「已安裝」一排圖示，下面是 ChatGPT 的各分類（精選、新上架…）。
    /// 點外掛（列或圖示）進詳細頁；說明用全域翻譯索引顯示繁中（使用者 09-25「mcp商城全英文」）。
    var body: some View {
        Group {
            if let target = model.pluginDetailTarget {
                // 換一個外掛就是新的畫面（捲動位置從頂端開始，09-25 實機：第二個外掛沿用上一頁的捲動位置、頁首被切掉）。
                ChatGPTPluginDetailView(model: model, plugin: target).id(target.id)
            } else {
                catalog
            }
        }
        .modifier(TranslationIndexHost())
        .alert("解除安裝這個外掛？", isPresented: Binding(get: { model.uninstallPluginTarget != nil },
                                                   set: { if !$0 { model.uninstallPluginTarget = nil } })) {
            Button("解除安裝", role: .destructive) { model.confirmUninstallPlugin() }
            Button("取消", role: .cancel) { model.uninstallPluginTarget = nil }
        } message: {
            Text("「\(model.uninstallPluginTarget?.name ?? "")」之後不能在對話裡用；需要時可以再安裝。")
        }
    }

    private var catalog: some View {
        ChatGPTPageScaffold(model: model, title: "外掛", subtitle: "在你常用的工具裡使用 ChatGPT") {
            Text("已安裝").font(.system(size: 15, weight: .semibold)).padding(.top, 6).padding(.bottom, 8)
            if model.installedPlugins.isEmpty, !model.pageLoading {
                Text("還沒有安裝外掛").font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.installedPlugins) { plugin in
                            Button { model.openPlugin(plugin) } label: {
                                ChatGPTRemoteIcon(url: plugin.iconURL, fallback: "puzzlepiece.extension", size: 44)
                                    .opacity(plugin.enabled ? 1 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { actions(plugin) }
                            .help(plugin.enabled ? plugin.name : "\(plugin.name)（停用中）")
                            .accessibilityLabel(plugin.enabled ? "已安裝：\(plugin.name)" : "已安裝（停用中）：\(plugin.name)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.bottom, 8)
            }
            ForEach(model.pluginSections) { section in
                let all = section.plugins
                let shown = expanded.contains(section.id) ? all : Array(all.prefix(6))
                Text(index.text(section.title)).font(.system(size: 15, weight: .semibold)).padding(.top, 20).padding(.bottom, 6)
                // 跟網頁一樣：寬的時候兩欄、窄的時候一欄（09-25 實機：窄視窗兩欄會把名字截斷）。
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 28, alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(shown) { plugin in row(plugin) }
                }
                if all.count > 6 {
                    Button(expanded.contains(section.id) ? "收起" : "顯示全部 \(all.count) 個") {
                        if expanded.contains(section.id) { expanded.remove(section.id) } else { expanded.insert(section.id) }
                    }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            ChatGPTTranslationNote(index: index).padding(.top, 22)
        }
    }

    @ViewBuilder
    private func actions(_ plugin: TapPlugin) -> some View {
        if !plugin.enabled {
            Button("啟用") { model.pluginAction(plugin, action: "enable") }
        }
        Button("解除安裝…", role: .destructive) { model.uninstallPluginTarget = plugin }
    }

    private func row(_ plugin: TapPlugin) -> some View {
        HStack(spacing: 12) {
            Button { model.openPlugin(plugin) } label: {
                HStack(spacing: 12) {
                    ChatGPTRemoteIcon(url: plugin.iconURL, fallback: "puzzlepiece.extension", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if !plugin.detail.isEmpty {
                            Text(index.text(plugin.detail, keeping: [plugin.name])).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                .help(plugin.detail)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(plugin.name)，看詳細")
            .accessibilityIdentifier("chatgpt.plugin.\(plugin.id)")
            if plugin.installed {
                Menu { actions(plugin) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("外掛選項：\(plugin.name)")
            } else {
                Button { model.pluginAction(plugin, action: "install") } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("安裝")
                .accessibilityLabel("安裝 \(plugin.name)")
            }
        }
        .padding(.vertical, 8)
    }
}

/// 外掛詳細頁（照網頁 /plugins/<外掛>：說明、範例、工具〔讀取／寫入〕、技能、截圖、連結）。原生畫面，不開網頁。
struct ChatGPTPluginDetailView: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject private var index = TranslationIndex.shared
    let plugin: TapPlugin

    private var detail: TapPluginDetail? { model.pluginDetail }
    private var state: TapPlugin { model.pluginState(plugin.id) ?? plugin }
    /// 這個外掛的品牌名（外掛名稱、開發者）：翻譯時保留原文。
    private var brand: [String] { [plugin.name, detail?.name ?? "", detail?.developer ?? ""].filter { !$0.isEmpty } }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id("pluginDetail.top")
                Button { model.closePlugin() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("外掛").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 8))
                .accessibilityLabel("回到外掛")
                .accessibilityIdentifier("chatgpt.plugin.back")
                .padding(.leading, -8)
                .padding(.bottom, 18)

                header
                if let failure = model.pluginDetailFailure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 16)
                } else if detail == nil {
                    ProgressView().controlSize(.small).padding(.top, 24)
                }
                if let detail {
                    if !detail.prompts.isEmpty { prompts(detail.prompts) }
                    if !detail.about.isEmpty {
                        section("說明")
                        Text(index.text(detail.about, keeping: brand)).font(.system(size: 14)).lineSpacing(4)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !detail.capabilities.isEmpty {
                        section("能力")
                        HStack(spacing: 6) {
                            ForEach(detail.capabilities, id: \.self) { item in
                                Text(index.text(item)).font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                    tools(detail)
                    if !detail.skills.isEmpty {
                        section("技能（\(detail.skills.count)）")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(detail.skills, id: \.self) { skill in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name).font(.system(size: 13, weight: .semibold))
                                    if !skill.detail.isEmpty {
                                        Text(index.text(skill.detail, keeping: brand)).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    if !detail.screenshots.isEmpty {
                        section("截圖")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(detail.screenshots, id: \.self) { url in ChatGPTRemotePicture(url: url, width: 280, height: 175) }
                            }
                        }
                    }
                    links(detail)
                }
                ChatGPTTranslationNote(index: index).padding(.top, 26)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .onAppear { proxy.scrollTo("pluginDetail.top", anchor: .top) }
        .onChange(of: detail == nil) { _, _ in proxy.scrollTo("pluginDetail.top", anchor: .top) }
        }
        .accessibilityIdentifier("chatgpt.pluginDetail")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ChatGPTRemoteIcon(url: detail?.icon ?? plugin.iconURL, fallback: "puzzlepiece.extension", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail?.name.isEmpty == false ? detail!.name : plugin.name).font(.system(size: 22, weight: .semibold))
                let meta = [detail?.developer ?? "", detail.map { index.text($0.category) } ?? ""].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                let summary = detail?.summary.isEmpty == false ? detail!.summary : plugin.detail
                if !summary.isEmpty {
                    Text(index.text(summary, keeping: brand)).font(.system(size: 14)).padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary)
                }
            }
            Spacer(minLength: 12)
            primaryAction
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if state.installed {
            HStack(spacing: 6) {
                if state.enabled {
                    Label("已安裝", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                } else {
                    chipButton("啟用", systemImage: "power") { model.pluginAction(state, action: "enable") }
                }
                Menu {
                    Button("解除安裝…", role: .destructive) { model.uninstallPluginTarget = state }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("外掛選項：\(state.name)")
            }
        } else {
            chipButton("安裝", systemImage: "plus") { model.pluginAction(state, action: "install") }
                .accessibilityIdentifier("chatgpt.plugin.install")
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).padding(.top, 24).padding(.bottom, 8)
    }

    private func prompts(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section("試試看")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { prompt in
                    Button { model.tryPluginPrompt(index.text(prompt, keeping: brand)) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(index.text(prompt, keeping: brand)).font(.system(size: 13)).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("開新對話，把這句放進輸入框")
                }
            }
        }
    }

    @ViewBuilder
    private func tools(_ detail: TapPluginDetail) -> some View {
        switch detail.toolsState {
        case .none:
            EmptyView()
        case .failed:
            section("工具")
            Text("工具清單現在讀不到").font(.system(size: 12)).foregroundStyle(.secondary)
        case .loaded:
            let read = detail.tools.filter(\.read)
            let write = detail.tools.filter { !$0.read }
            if detail.tools.isEmpty {
                section("工具")
                Text("這個外掛還沒有工具").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !read.isEmpty { toolList("讀取工具（\(read.count)）", read) }
            if !write.isEmpty { toolList("寫入工具（\(write.count)）", write) }
        }
    }

    private func toolList(_ title: String, _ items: [TapPluginDetail.Tool]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section(title)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            // 工具名稱照網頁保留英文（函式名翻出來會變成「砰」「我是誰」）；說明才翻。
                            Text(Self.toolTitle(tool.name)).font(.system(size: 13, weight: .semibold))
                            if tool.destructive {
                                Text("會刪改資料").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red)
                                    .padding(.horizontal, 6).frame(height: 18)
                                    .background(Color.red.opacity(0.08), in: Capsule())
                            }
                        }
                        .help(tool.name)
                        if !tool.detail.isEmpty {
                            Text(index.text(tool.detail, keeping: brand)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// 工具名稱照網頁的寫法變成一句話（search_repos → Search repos；listIssues → List issues）。
    static func toolTitle(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "([a-z])([A-Z0-9])", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    @ViewBuilder
    private func links(_ detail: TapPluginDetail) -> some View {
        let links: [ChatGPTLink] = [ChatGPTLink(title: "網站", url: detail.website), ChatGPTLink(title: "隱私權政策", url: detail.privacy),
                                    ChatGPTLink(title: "使用條款", url: detail.terms)].filter { $0.url != nil }
        if !links.isEmpty {
            section("資訊")
            HStack(spacing: 8) {
                ForEach(links) { link in
                    chipButton(link.title, systemImage: "arrow.up.right") { if let url = link.url { NSWorkspace.shared.open(url) } }
                        .help("用預設瀏覽器打開")
                }
            }
        }
    }
}

/// 輸入框裡的附件，照 ChatGPT（09-25 使用者附圖 #122；網頁 file tile：圖片 9rem 方形、檔案 15rem 寬）：
/// 圖片是 144pt 方形縮圖（圓角 16、細框、填滿裁切），其他檔案是 240pt 寬的檔案卡（彩色類型方塊＋檔名＋類型）；
/// 滑鼠移上去才在右上角出現 ×。
struct ChatGPTAttachmentTile: View {
    let file: TapAttachment
    let remove: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    static let imageSize: CGFloat = 144
    static let fileWidth: CGFloat = 240
    static let fileHeight: CGFloat = 56

    var isImage: Bool { file.mime.lowercased().hasPrefix("image/") }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isImage { imageTile } else { fileTile }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(ChatGPTPalette.primary)
                    .frame(width: 22, height: 22)
                    .background(ChatGPTPalette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 7, y: -7)
            .opacity(hovering ? 1 : 0)
            .help("移除")
            .accessibilityLabel("移除 \(file.name)")
        }
        .onHover { hovering = $0 }
        .task(id: file.id) { if isImage { thumbnail = Self.thumbnail(file.data, maxPixel: Self.imageSize * 2) } }
    }

    private var imageTile: some View {
        ZStack {
            ChatGPTPalette.surface
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: Self.imageSize, height: Self.imageSize)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("圖片：\(file.name)")
        // × 平常隱藏（透明的元件輔助使用也看不到）：方塊本身帶「移除」動作，VoiceOver／鍵盤也能移除（09-25 實機）。
        .accessibilityAction(named: "移除", remove)
    }

    private var fileTile: some View {
        let kind = Self.kind(file)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(kind.color)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: kind.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatGPTPalette.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(kind.label).font(.system(size: 12)).foregroundStyle(ChatGPTPalette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.fileWidth, height: Self.fileHeight, alignment: .leading)
        .background(ChatGPTPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("檔案：\(file.name)")
        .accessibilityAction(named: "移除", remove)
    }

    struct Kind {
        let label: String
        let symbol: String
        let color: Color
    }

    /// 檔案類型：顏色與名稱（PDF 紅、文件藍、試算表綠、簡報橘、程式碼紫，其他灰）。
    static func kind(_ file: TapAttachment) -> Kind {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let mime = file.mime.lowercased()
        let rgb: (UInt32) -> Color = { Color(nsColor: ChatGPTPalette.rgb($0)) }
        if ext == "pdf" || mime == "application/pdf" { return Kind(label: "PDF", symbol: "doc.richtext.fill", color: rgb(0xFA423E)) }
        if ["doc", "docx", "pages", "rtf"].contains(ext) { return Kind(label: "文件", symbol: "doc.text.fill", color: rgb(0x0285FF)) }
        if ["xls", "xlsx", "numbers", "csv", "tsv"].contains(ext) { return Kind(label: "試算表", symbol: "tablecells.fill", color: rgb(0x04B84C)) }
        if ["ppt", "pptx", "key"].contains(ext) { return Kind(label: "簡報", symbol: "rectangle.on.rectangle.angled.fill", color: rgb(0xFF8500)) }
        if ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "m", "sh", "json", "yaml", "yml", "html", "css"].contains(ext) {
            return Kind(label: "程式碼", symbol: "chevron.left.forwardslash.chevron.right", color: rgb(0x8B5CF6))
        }
        if ["txt", "md", "markdown"].contains(ext) || mime.hasPrefix("text/") { return Kind(label: "文字", symbol: "doc.plaintext.fill", color: rgb(0x5D5D5D)) }
        if ["zip", "gz", "tar", "7z", "rar"].contains(ext) { return Kind(label: "壓縮檔", symbol: "doc.zipper", color: rgb(0x8F8F8F)) }
        return Kind(label: ext.isEmpty ? "檔案" : ext.uppercased(), symbol: "doc.fill", color: rgb(0x8F8F8F))
    }

    /// 縮圖：照原圖方向、長邊縮到 maxPixel（Retina 兩倍）。
    static func thumbnail(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}

/// 圖片放大，照 Coder 的圖片預覽（共用 ChatImagePreviewSurface；使用者 09-25 #126）：深色底、點空白或按 Esc 關閉、
/// 右上下載與關閉、下方縮放；同一則訊息有好幾張圖時左右切換。
struct ChatGPTImagePreview: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let image: NSImage
    /// 表單（小面板）才給固定大小；視窗裡是整個視窗的燈箱。
    var inSheet = false
    @State private var zoom: CGFloat = 1

    var body: some View {
        ChatImagePreviewSurface(
            image: Image(nsImage: image),
            imageSize: Self.pixelSize(image),
            name: model.zoomTitle,
            zoom: zoom,
            canGoBack: model.zoomNeighbor(-1) != nil,
            canGoForward: model.zoomNeighbor(1) != nil,
            canSave: model.zoomSource != nil,
            close: { model.closeZoom() },
            save: { model.downloadZoomedImage() },
            zoomOut: { zoom = max(0.25, zoom / 1.25) },
            zoomIn: { zoom = min(4, zoom * 1.25) },
            previous: { zoom = 1; model.moveZoom(-1) },
            next: { zoom = 1; model.moveZoom(1) })
        .frame(minWidth: inSheet ? 560 : nil, idealWidth: inSheet ? 900 : nil, maxWidth: inSheet ? nil : .infinity,
               minHeight: inSheet ? 440 : nil, idealHeight: inSheet ? 650 : nil, maxHeight: inSheet ? nil : .infinity)
    }

    /// 圖的像素大小（跟 Coder 一樣：最多放到 1:1，放不下就縮到剛好）。
    static func pixelSize(_ image: NSImage) -> CGSize {
        let sizes = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.filter { $0.width > 0 && $0.height > 0 }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? image.size
    }
}

/// 圖片放大的燈箱：蓋住整個視窗（跟 ChatGPT 一樣），圖片以外哪裡點都關（使用者 09-25 #128「點空白處要可以退出」）；
/// Esc 也關——自己接 Esc、不讓它落到主視窗（主視窗收到 Esc 會關掉）。
struct ChatGPTImageLightbox: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            if let image = model.zoomedImage {
                // 連紅綠燈那一條也蓋住（.030 實機：最上面 28pt 沒蓋到、看得到後面的對話）。
                ChatGPTImagePreview(model: model, image: image)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.zoomedImage != nil)
        .onChange(of: model.zoomedImage != nil, initial: true) { _, open in watchEscape(open) }
        .onDisappear { watchEscape(false) }
    }

    private func watchEscape(_ on: Bool) {
        if on, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
                // 只攔主視窗、上面沒有表單或存檔視窗時的 Esc（審查 #14）。
                guard event.keyCode == 53, model.zoomedImage != nil, let window = event.window, window.isMainWindow,
                      window.attachedSheet == nil else { return event }
                model.closeZoom()
                return nil
            }
        } else if !on, let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

/// 送出鈕照 ChatGPT：黑色圓鈕、白色向上箭頭；不能送時淡灰。
struct ChatGPTSendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Color(nsColor: .windowBackgroundColor) : ChatGPTPalette.tertiary)
                .frame(width: 30, height: 30)
                .background(enabled ? Color.primary : Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("送出")
        .accessibilityLabel("送出")
        .accessibilityIdentifier("chatgpt.send")
    }
}

struct ChatGPTLink: Identifiable {
    let title: String
    let url: URL?
    var id: String { title }
}

/// 外掛商店底下的一行小字：說明是誰翻的；翻不了時寫原因。
struct ChatGPTTranslationNote: View {
    @ObservedObject var index: TranslationIndex

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble").font(.system(size: 11)).accessibilityHidden(true)
            Text(index.unavailable.map { "說明顯示原文：\($0)" }
                 ?? (index.translating ? "正在用 Apple 裝置端翻譯成繁中（內容不離開這台 Mac）…" : "說明由 Apple 裝置端翻譯成繁中（內容不離開這台 Mac）；游標停在文字上可看原文"))
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.tertiary)
    }
}

/// 遠端圖片（截圖）：跟圖示一樣用不落地的連線下載。
struct ChatGPTRemotePicture: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let data = await ChatGPTTap.shared.remoteImage(url) else { return }
            image = NSImage(data: data)
        }
        .accessibilityLabel("外掛截圖")
    }
}

// MARK: - 網站

struct ChatGPTSitesView: View {
    @ObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        ChatGPTPageScaffold(model: model, title: "網站", subtitle: "在對話裡用「網站」工具做的網頁") {
            if model.sites.isEmpty, !model.pageLoading, model.pageFailure == nil {
                Text("還沒有網站。在對話的「＋ › 更多 › Sites」請 ChatGPT 幫你做一個。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 30)
            }
            ForEach(model.sites) { site in
                HStack(spacing: 12) {
                    Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name.isEmpty ? "未命名網站" : site.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(site.url?.host ?? (site.status.isEmpty ? "尚未發布" : site.status))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if let updated = site.updatedAt {
                        Text(ChatGPTLibraryView.relative(updated)).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    chipButton("打開", systemImage: "arrow.up.right") { model.openSite(site) }
                    Button { model.copySiteURL(site) } label: {
                        Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("拷貝網址")
                    .accessibilityLabel("拷貝「\(site.name)」的網址")
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
    }
}

// MARK: - 個人化（自訂指令、記憶）

struct ChatGPTPersonalizationView: View {
    @ObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        ChatGPTPageScaffold(model: model, title: "個人化", subtitle: "ChatGPT 的自訂指令與記憶（跟網頁版同一份）") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("自訂指令").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Toggle("啟用", isOn: $model.instructions.enabled).toggleStyle(.switch).controlSize(.small)
                }
                field("ChatGPT 該怎麼稱呼你？", text: $model.instructions.nickname, lines: 1)
                field("你的職業", text: $model.instructions.occupation, lines: 1)
                field("ChatGPT 應該有哪些特質？", text: $model.instructions.traits, lines: 4)
                field("還有什麼想讓 ChatGPT 知道的？", text: $model.instructions.aboutYou, lines: 4)
                HStack {
                    Spacer()
                    chipButton("儲存", systemImage: "checkmark") { model.saveInstructions() }
                        .disabled(!model.instructionsLoaded)
                }
            }
            .padding(.bottom, 26)

            HStack(alignment: .firstTextBaseline) {
                Text("記憶").font(.system(size: 15, weight: .semibold))
                // 伺服器的上限很大（09-25：500 萬），85 則也不到 1%；照實寫「不到 1%」，並列出則數。
                if !model.memories.isEmpty || model.memoryUsage != nil {
                    let usage = model.memoryUsage.map { $0 < 1 && !model.memories.isEmpty ? "不到 1%" : "\($0)%" }
                    Text(["\(model.memories.count) 則", usage.map { "已用 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.memories.isEmpty {
                    chipButton("全部清除", systemImage: "trash", role: .destructive) { model.clearMemoriesRequested = true }
                }
            }
            .padding(.bottom, 6)
            if model.memories.isEmpty, !model.pageLoading {
                Text("ChatGPT 還沒有記住任何事").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            ForEach(model.memories) { memory in
                HStack(alignment: .top, spacing: 10) {
                    Text(memory.text).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.deleteMemoryTarget = memory } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("刪除這條記憶")
                    .accessibilityLabel("刪除記憶")
                }
                .padding(.vertical, 9)
                Divider()
            }
        }
        .alert("刪除這條記憶？", isPresented: Binding(get: { model.deleteMemoryTarget != nil },
                                                  set: { if !$0 { model.deleteMemoryTarget = nil } })) {
            Button("刪除", role: .destructive) { model.confirmDeleteMemory() }
            Button("取消", role: .cancel) { model.deleteMemoryTarget = nil }
        } message: {
            Text("ChatGPT 之後不會再用這條記憶。")
        }
        .alert("清除全部記憶？", isPresented: $model.clearMemoriesRequested) {
            Button("全部清除", role: .destructive) { model.confirmClearMemories() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("ChatGPT 記住的所有事都會刪除，無法復原。")
        }
    }

    private func field(_ title: String, text: Binding<String>, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            if lines > 1 {
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(lines) * 20 + 12)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(title)
            } else {
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(title)
            }
        }
    }
}

// MARK: - 分享

struct ChatGPTShareSheet: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let request: ChatGPTSpaceModel.ShareRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.messageID == nil ? "分享對話" : "分享這則提問").font(.system(size: 16, weight: .semibold))
            Text(request.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            Text("會建立一個公開連結：拿到連結的任何人都能看到\(request.messageID == nil ? "這則對話到目前為止的內容" : "這則提問與回答")。之後的訊息不會自動加進去。")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let url = model.shareURL {
                HStack(spacing: 8) {
                    Text(url.absoluteString).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    chipButton("拷貝連結", systemImage: "doc.on.doc") { model.copy(url.absoluteString) }
                    chipButton("打開", systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 6) {
                    Text("分享錯了？").font(.system(size: 12)).foregroundStyle(.secondary)
                    chipButton("停止分享", systemImage: "link.badge.plus", role: .destructive) { model.stopSharing() }
                        .disabled(model.sharing)
                        .accessibilityIdentifier("chatgpt.share.stop")
                }
            }
            if model.shareStopped {
                Text("已停止分享：這個連結已刪除，拿到的人打不開了。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let failure = model.shareFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(model.shareURL == nil ? "取消" : "完成") { model.shareRequest = nil }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 28).chatGlassChip()
                    .keyboardShortcut(.cancelAction)
                if model.shareURL == nil {
                    Button { model.createShareLink() } label: {
                        HStack(spacing: 6) {
                            if model.sharing { ProgressView().controlSize(.small) }
                            Text(model.sharing ? "建立中…" : "建立連結")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 28)
                    }
                    .buttonStyle(.plain).chatGlassChip(isSelected: true)
                    .disabled(model.sharing)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 即時語音

/// 語音模式：聲音在 ChatGPT 網頁裡跑（Pod），這裡是原生的畫面與結束鈕。
struct ChatGPTVoiceOverlay: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(LiquidGlassTokens.brandAccent.opacity(0.14)).frame(width: 150, height: 150)
                    .scaleEffect(model.voiceLive && pulse ? 1.12 : 0.94)
                Circle().fill(LiquidGlassTokens.brandAccent.opacity(model.voiceLive ? 0.55 : 0.25)).frame(width: 96, height: 96)
                Image(systemName: "waveform").font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            Text("語音模式").font(.system(size: 17, weight: .semibold))
            Text(model.voiceStatus).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            Button { model.stopVoice() } label: {
                Label("結束語音", systemImage: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 36)
            }
            .buttonStyle(.plain)
            .chatGlassChip(isSelected: true)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.voice")
    }
}

// MARK: - 模型與思考強度（輸入框裡的膠囊點開）

/// ChatGPT 網頁版的顏色（09-25 從 Pod 快取裡網頁自己的 CSS 取值：text-primary／tertiary、purple-400、theme accent、
/// 滑桿軌道、面板底色）。深色模式照網頁的深色值。
enum ChatGPTPalette {
    /// 淺色／深色各一個 0xRRGGBB＋透明度；在 provider 裡才建 NSColor（只帶數字進去，Swift 6 併發檢查不會卡）。
    static func dynamic(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// --text-primary #0D0D0D
    static let primary = dynamic(0x0D0D0D, dark: 0xFFFFFF)
    /// --text-tertiary #8F8F8F
    static let tertiary = dynamic(0x8F8F8F, dark: 0xFFFFFF, 0.58)
    /// --purple-400 #8952EE（最高檔 Pro 的名字）
    static let purple = dynamic(0x8952EE, dark: 0xA77BF3)
    /// --theme-entity-accent（預設主題＝--blue-400 #3A83F7）：滑桿已選的那一段
    static let accent = dynamic(0x3A83F7, dark: 0x3A83F7)
    /// 滑桿軌道 #F3F3F3（深色 #FFFFFF1A）
    static let track = dynamic(0xF3F3F3, dark: 0xFFFFFF, 0.10)
    /// 面板底色 --bg-elevated-primary
    static let surface = dynamic(0xFFFFFF, dark: 0x303030)
    /// 膠囊按下／打開時的底色（#F0F0F0 ≈ 黑 6%）
    static let pressed = dynamic(0x000000, 0.06, dark: 0xFFFFFF, 0.10)
    /// 滑過的底色 --interactive-bg-secondary-hover（黑 5%）
    static let hover = dynamic(0x000000, 0.05, dark: 0xFFFFFF, 0.10)
    /// 圓鈕外框 --border-heavy（黑 15%）
    static let thumbBorder = dynamic(0x000000, 0.15, dark: 0xFFFFFF, 0.20)
}

/// 思考強度面板，照 ChatGPT 網頁版（09-25 使用者「思考模型ui只是像 但細節完全不對」→ 改成照網頁自己的 CSS／元件逐項對）：
/// 寬 260、圓角 24、白底＋陰影（shadow-long）；上面置中「High ›」（16pt、中粗；帶版本時「6」黑字、「Pro」灰字，最高檔紫色），
/// 右上角「↺」回到 ChatGPT 的預設；下面是滑桿。點「High ›」換成版本與其他模型的清單。臨時聊天不在這裡（網頁在右上角）。
struct ChatGPTEffortCard: View {
    @ObservedObject var model: ChatGPTSpaceModel
    let dismiss: () -> Void
    @State private var showsModels = false
    @State private var maxNotice = false
    @State private var noticeTask: Task<Void, Never>?

    static let width: CGFloat = 260
    static let radius: CGFloat = 24
    /// 網頁的開合動畫：0.32 秒 cubic-bezier(.23,1,.32,1)。
    static let motion = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)

    var body: some View {
        ZStack(alignment: .top) {
            if showsModels {
                modelList
                    .transition(.opacity.combined(with: .offset(y: 24)))
            } else {
                simpleView
                    .transition(.opacity.combined(with: .offset(y: -24)))
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(ChatGPTPalette.surface))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        // shadow-long：0 8px 12px #00000014，外加 0 0 1px 的細邊。
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.modelPopover")
        .onDisappear { noticeTask?.cancel() }
    }

    // MARK: 滑桿頁（網頁的 simple view）

    private var simpleView: some View {
        let efforts = model.currentModel?.efforts ?? []
        return VStack(spacing: 0) {
            ZStack {
                if maxNotice {
                    // 拖到最高檔時，標題位置閃一下「用量消耗較快」（網頁：Consumes usage limits faster，紫色流光字）。
                    ChatGPTShimmerText(text: "用量消耗較快")
                        .transition(.opacity)
                } else {
                    headerButton.transition(.opacity)
                }
                HStack {
                    Spacer()
                    if model.canResetSelection, !maxNotice {
                        Button { withAnimation(Self.motion) { model.resetSelection() } } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ChatGPTPalette.tertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 12))
                        .help("回到 ChatGPT 的預設")
                        .accessibilityLabel("回到 ChatGPT 的預設")
                        .accessibilityIdentifier("chatgpt.resetSelection")
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(height: 36)
            .padding(.top, 7)
            if efforts.count > 1 {
                ChatGPTEffortSlider(
                    count: efforts.count,
                    index: efforts.firstIndex { $0.id == model.effectiveEffortID } ?? efforts.count - 1,
                    maxIndex: efforts.lastIndex { $0.isMax },
                    titles: efforts.map { ChatGPTLabels.effort($0.level.isEmpty ? $0.title : $0.level) }) { index in
                        withAnimation(Self.motion) { model.selectedEffortID = efforts[index].id }
                        if efforts[index].isMax { flashMaxNotice() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
            }
        }
        .padding(.bottom, 10)
    }

    /// 「High ›」：帶版本時版本黑字、檔位灰字；只有名字時名字黑字；最高檔（Pro）名字紫色。16pt、中粗。
    private var headerButton: some View {
        let label = model.pickerLabel
        return Button { withAnimation(Self.motion) { showsModels = true } } label: {
            HStack(spacing: 0) {
                if let version = label.version {
                    Text(version).foregroundStyle(ChatGPTPalette.primary)
                    Text(" " + label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : ChatGPTPalette.tertiary)
                } else {
                    Text(label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : ChatGPTPalette.primary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatGPTPalette.tertiary)
                    .padding(.leading, 6)
            }
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 12))
        .help("換模型版本")
        .accessibilityLabel("模型：\(label.version.map { $0 + " " } ?? "")\(label.level)，換模型版本")
        .accessibilityIdentifier("chatgpt.modelVersions")
    }

    private func flashMaxNotice() {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { maxNotice = true }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { maxNotice = false }
        }
    }

    // MARK: 模型清單（網頁的 advanced view）

    private var modelList: some View {
        let versions = model.models.filter { $0.id.hasPrefix("version:") }
        let others = model.models.filter { !$0.id.hasPrefix("version:") }
        // 伺服器給每個舊模型同一句說明（09-25：都是「我們最新且最先進的模型」）→ 重複的就不顯示。
        let repeated = Set(Dictionary(grouping: others, by: \.detail).filter { $0.value.count > 1 }.keys)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Self.motion) { showsModels = false } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium))
                    Text("思考強度").font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(ChatGPTPalette.tertiary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 12))
            .accessibilityLabel("回到思考強度")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(versions) { item in
                        option(title: ChatGPTLabels.version(item.title), detail: "", selected: item.id == model.effectiveModelID) {
                            model.selectedModelID = item.id
                            withAnimation(Self.motion) { showsModels = false }
                        }
                    }
                    if !others.isEmpty {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 6)
                        ForEach(others) { item in
                            option(title: item.title, detail: repeated.contains(item.detail) ? "" : item.detail,
                                   selected: item.id == model.effectiveModelID) {
                                model.selectedModelID = item.id
                                dismiss()
                            }
                        }
                    }
                    if model.canResetSelection {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 6)
                        Button {
                            model.resetSelection()
                            withAnimation(Self.motion) { showsModels = false }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .medium))
                                Text("回到 ChatGPT 的預設").font(.system(size: 14))
                                Spacer()
                            }
                            .foregroundStyle(ChatGPTPalette.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(6)
    }

    private func option(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14)).foregroundStyle(ChatGPTPalette.primary)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(ChatGPTPalette.tertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(ChatGPTPalette.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 12))
        .accessibilityLabel(detail.isEmpty ? title : "\(title)、\(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 滑過有淡灰底、按下深一點（網頁的 hover／press 底色）。
struct ChatGPTHoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        ChatGPTHoverBackground(pressed: configuration.isPressed, cornerRadius: cornerRadius) { configuration.label }
    }
}

private struct ChatGPTHoverBackground<Content: View>: View {
    let pressed: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background((pressed ? ChatGPTPalette.pressed : (hovering ? ChatGPTPalette.hover : Color.clear)),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// 紫色流光字（網頁 MaximumNoticeText：purple-400→200→75→200→400 的漸層從右掃到左一次）。
struct ChatGPTShimmerText: View {
    let text: String
    @State private var phase: CGFloat = 1

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(LinearGradient(stops: Self.stops(phase), startPoint: .leading, endPoint: .trailing))
            .frame(height: 32)
            .onAppear { withAnimation(.easeOut(duration: 1.1)) { phase = 0 } }
            .accessibilityLabel(text)
    }

    /// 亮帶在 phase 的位置：紫 → 淡紫 → 最亮 → 淡紫 → 紫（位置要遞增、落在 0～1）。
    private static func stops(_ phase: CGFloat) -> [Gradient.Stop] {
        let light = Color(nsColor: ChatGPTPalette.rgb(0xB897F4))
        let brightest = Color(nsColor: ChatGPTPalette.rgb(0xDDCFFA))
        let spots: [(Color, CGFloat)] = [(ChatGPTPalette.purple, phase - 0.08), (light, phase - 0.03), (brightest, phase),
                                         (light, phase + 0.03), (ChatGPTPalette.purple, phase + 0.08)]
        return spots.map { Gradient.Stop(color: $0.0, location: min(1, max(0, $0.1))) }
    }
}

/// ChatGPT 網頁版的思考強度滑桿（照 model-reasoning-effort-slider.css）：
/// 軌道高 24、圓角 12、#F3F3F3、內陰影；已選的一段是主題藍；每一檔一個 4pt 小點（左右各內縮 13pt），
/// 已選段的小點是白 30%、未選段是灰；白色圓鈕 28pt（0.5pt 外框、2pt 陰影）。
/// 最高檔（Pro）：小點收起、整段變成紫色流動漸層＋白色星點，剛拖到時從圓鈕迸出紫色粒子。
struct ChatGPTEffortSlider: View {
    let count: Int
    let index: Int
    let maxIndex: Int?
    let titles: [String]
    let onChange: (Int) -> Void
    @State private var dragIndex: Int?
    @State private var burstStart: Date?

    static let trackHeight: CGFloat = 24
    static let thumb: CGFloat = 28
    /// 網頁：小點與圓鈕中心從兩端內縮 thumb/2 − 1 ＝ 13。
    static let inset: CGFloat = 13
    static let motion = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.3)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let current = dragIndex ?? index
            let atMax = maxIndex == current
            let centerX = x(for: current, width: width)
            ZStack(alignment: .leading) {
                // 軌道＋已選段（紫色或藍色）＋小點
                ZStack(alignment: .leading) {
                    ChatGPTPalette.track
                    if atMax {
                        ChatGPTMaxFill()
                            .frame(width: width)
                            .transition(.opacity)
                    } else {
                        ChatGPTPalette.accent
                            .frame(width: max(0, centerX))
                    }
                    ForEach(0..<count, id: \.self) { tick in
                        Circle()
                            .fill(tick < current ? Color.white.opacity(0.30) : Color(nsColor: ChatGPTPalette.rgb(0x8F8F8F, 0.5)))
                            .frame(width: 4, height: 4)
                            .scaleEffect(atMax ? 0.75 : 1)
                            .opacity(atMax || tick == current ? 0 : 1)
                            .position(x: x(for: tick, width: width), y: Self.trackHeight / 2)
                    }
                }
                .frame(width: width, height: Self.trackHeight)
                .clipShape(Capsule())
                // 內陰影 inset 0 0 2px #0000002e
                .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 1).blur(radius: 1).clipShape(Capsule()))
                .frame(height: Self.thumb)

                if let burstStart, atMax {
                    ChatGPTMaxBurst(start: burstStart)
                        .frame(width: 76, height: 76)
                        .position(x: centerX, y: Self.thumb / 2)
                        .allowsHitTesting(false)
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(ChatGPTPalette.thumbBorder, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .position(x: centerX, y: Self.thumb / 2)
            }
            .animation(Self.motion, value: current)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragIndex = nearest(value.location.x, width: width) }
                .onEnded { value in
                    let target = nearest(value.location.x, width: width)
                    dragIndex = nil
                    select(target)
                })
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("思考強度")
        .accessibilityValue(titles.indices.contains(index) ? titles[index] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < count - 1 { select(index + 1) }
            case .decrement: if index > 0 { select(index - 1) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("chatgpt.effortSlider")
    }

    private func select(_ target: Int) {
        guard target != index else { return }
        if target == maxIndex {
            let start = Date()
            burstStart = start
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                if burstStart == start { burstStart = nil }
            }
        }
        onChange(target)
    }

    private func x(for tick: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return Self.inset + CGFloat(tick) * (width - Self.inset * 2) / CGFloat(count - 1)
    }

    private func nearest(_ location: CGFloat, width: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let step = (width - Self.inset * 2) / CGFloat(count - 1)
        return min(count - 1, max(0, Int(((location - Self.inset) / step).rounded())))
    }
}

/// 最高檔的紫色：網頁用 12 色的流動漸層（WebGL）＋白色星點；這裡用幾團緩慢移動的柔光疊在
/// linear-gradient(90deg, #250e7a, #c775e9 55%, #7849d1) 上，星點是 14 顆白 72% 的小點，緩緩往左飄、忽明忽暗。
struct ChatGPTMaxFill: View {
    private static let blobs: [(UInt32, CGFloat, CGFloat, CGFloat)] = [
        (0x9763F1, 0.20, 0.38, 0.9), (0xD4B5F3, 0.52, 0.30, 1.1), (0x9700FE, 0.78, 0.44, 0.8),
        (0xC775E9, 0.36, 0.60, 1.3), (0x6636D1, 0.64, 0.26, 1.0), (0xE1B0FF, 0.88, 0.58, 0.7),
    ]
    private static let particles: [(CGFloat, CGFloat, CGFloat, Double)] = (0..<14).map { i in
        let seed = Double(i) * 12.9898
        let fx = CGFloat((sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)).magnitude
        let fy = CGFloat((sin(seed * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1)).magnitude
        let size = 1.4 + CGFloat(i % 3) * 0.5
        return (0.04 + fx * 0.92, 0.5 + (fy - 0.5) * 0.58, size, 1.6 * (0.8 + Double(i % 5) * 0.3))
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let base = Gradient(stops: [.init(color: Color(nsColor: ChatGPTPalette.rgb(0x250E7A)), location: 0),
                                            .init(color: Color(nsColor: ChatGPTPalette.rgb(0xC775E9)), location: 0.55),
                                            .init(color: Color(nsColor: ChatGPTPalette.rgb(0x7849D1)), location: 1)])
                canvas.fill(Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(base, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                for (index, blob) in Self.blobs.enumerated() {
                    let speed = 0.35 + Double(index) * 0.05
                    let cx = (blob.1 + CGFloat(sin(t * speed + Double(index))) * 0.18) * size.width
                    let cy = (blob.2 + CGFloat(cos(t * speed * 1.3 + Double(index))) * 0.30) * size.height
                    let radius = size.height * 1.4 * blob.3
                    let color = Color(nsColor: ChatGPTPalette.rgb(blob.0))
                    canvas.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                                with: .radialGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                                                      center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: radius))
                }
                for particle in Self.particles {
                    let phase = (t / particle.3).truncatingRemainder(dividingBy: 1)
                    let x = (particle.0 - CGFloat(phase) * 0.12).truncatingRemainder(dividingBy: 1)
                    let alpha = 0.72 * (0.55 + 0.45 * sin(phase * .pi * 2))
                    let rect = CGRect(x: x * size.width - particle.2, y: particle.1 * size.height - particle.2,
                                      width: particle.2 * 2, height: particle.2 * 2)
                    canvas.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white.opacity(alpha * 0.25)))
                    canvas.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 剛拖到最高檔時從圓鈕迸出的 16 顆紫色粒子（網頁 Burst：0.62 秒，#752aff／#8f5cff／#9d6bff）。
struct ChatGPTMaxBurst: View {
    let start: Date
    private static let offsets: [(CGFloat, CGFloat, UInt32)] = [
        (-3, -34, 0x752AFF), (15, -29, 0x752AFF), (30, -19, 0x8F5CFF), (34, -2, 0x752AFF), (26, 20, 0x9D6BFF),
        (12, 31, 0x752AFF), (-6, 34, 0x8F5CFF), (-22, 26, 0x752AFF), (-32, 9, 0x9D6BFF), (-32, -10, 0x752AFF),
        (-21, -26, 0x8F5CFF), (7, -24, 0x752AFF), (24, -9, 0x9D6BFF), (20, 10, 0x752AFF), (-9, 21, 0x8F5CFF), (-25, -5, 0x752AFF),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let progress = min(1, context.date.timeIntervalSince(start) / 0.62)
            Canvas { canvas, size in
                guard progress < 1 else { return }
                // cubic-bezier(.25,1,.5,1) 的近似：快出慢停。
                let eased = 1 - pow(1 - progress, 3)
                let scale = progress < 0.22 ? 0.25 + (1.28 - 0.25) * (progress / 0.22) : 1.28 - (1.28 - 0.55) * ((progress - 0.22) / 0.78)
                let alpha = progress < 0.22 ? progress / 0.22 : 1 - (progress - 0.22) / 0.78
                for particle in Self.offsets {
                    let x = size.width / 2 + particle.0 * CGFloat(eased)
                    let y = size.height / 2 + particle.1 * CGFloat(eased)
                    let r = 2.5 * CGFloat(scale)
                    canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                with: .color(Color(nsColor: ChatGPTPalette.rgb(particle.2)).opacity(alpha)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 臨時聊天的圖示：照網頁右上角那顆（虛線的對話泡泡，左下角是尾巴）。
struct ChatGPTTemporaryChatIcon: View {
    var active = false

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 20
            let center = CGPoint(x: 10.5 * s, y: 9.5 * s)
            let r = 7.5 * s
            var path = Path()
            path.move(to: CGPoint(x: center.x - r, y: center.y))
            path.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(450), clockwise: false)
            path.addLine(to: CGPoint(x: center.x - r, y: center.y + r))
            path.closeSubpath()
            let dash: [CGFloat] = active ? [] : [9.2 * s, 3.2 * s]
            context.stroke(path, with: .color(ChatGPTPalette.primary),
                           style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round, dash: dash, dashPhase: 2 * s))
        }
        .accessibilityHidden(true)
    }
}

/// 面板裡一列的滑過底色（跟桌面版一樣淡灰）。滑過狀態放在子 View（ButtonStyle 本身不能存狀態）。
struct ChatGPTRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatGPTRowHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct ChatGPTRowHighlight<Content: View>: View {
    let pressed: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background(Color.primary.opacity(pressed ? 0.09 : (hovering ? 0.05 : 0)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 4)
            .onHover { hovering = $0 }
    }
}
