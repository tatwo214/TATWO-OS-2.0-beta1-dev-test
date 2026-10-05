// W183 R3：設定 › 環境登入（原「GitHub」分頁；rawValue `github` 不動）——GitHub｜Cloudflare 兩個子分頁，都可以登入多個帳號。
// 使用者 09-27：「設定/環境登入/github|cloudflare 全部都走多號可登入」「登入後就直接固定好環境登入那頁了 不要讓人重複登入」。
// 子分頁記住上次（@AppStorage），從 TAP › ChatGPT 導過來時先寫成 cloudflare 再開這一頁；登入完就停在這裡。
import SwiftUI

enum EnvironmentLoginTab: String, CaseIterable, Identifiable {
    case github, cloudflare
    static let storageKey = "tatwo.settings.envLogin.tab"
    var id: String { rawValue }
    var title: String { self == .github ? "GitHub" : "Cloudflare" }

    /// 從別頁導到「環境登入 › Cloudflare」：先把子分頁寫好，再開設定的那一頁（設定已經開著也會切過去，見 TatwoSettingsPage.onReceive）。
    @MainActor static func open(_ tab: EnvironmentLoginTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
        EnvironmentLoginTarget(rawValue: tab.rawValue)?.open()
    }
}

@MainActor enum EnvironmentLoginTarget: String, CaseIterable {
    case update, backup, github, cloudflare
    static var pending: Self?
    func open() {
        Self.pending = self
        NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.github.rawValue,
                                        userInfo: ["environmentTarget": rawValue])
    }
}

extension Notification.Name {
    /// W183 R3：從設定頁裡的按鈕關掉整個設定浮層（例如「看施工房」要切到 Coder）。
    static let tatwoCloseSettingsPage = Notification.Name("tatwoCloseSettingsPage")
}

/// 頁首右邊的子分頁切換（跟 代理帳戶＆錢包 一樣放在標題列 trailing）。
struct EnvironmentLoginTabPicker: View {
    @AppStorage(EnvironmentLoginTab.storageKey) private var tab = EnvironmentLoginTab.github.rawValue

    var body: some View {
        HStack(spacing: 10) {
            ForEach(EnvironmentLoginTab.allCases) { item in
                Button { tab = item.rawValue } label: {
                    Group {
                        if let url = ProviderIconResources.url(for: "EnvironmentIcon-" + item.rawValue), let logo = NSImage(contentsOf: url) {
                            Image(nsImage: logo).resizable().renderingMode(.template).scaledToFit()
                        }
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .frame(width: 36, height: 36)
                    .chatGlassChip().clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(tab == item.rawValue ? 0.65 : 0), lineWidth: 1.5))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityValue(tab == item.rawValue ? "已選取" : "未選取")
                .accessibilityIdentifier("settings.envLogin." + item.rawValue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.envLogin.tabs")
    }
}

/// 子分頁內容：GitHub 帳號卡或 Cloudflare 帳號卡。
struct EnvironmentLoginContent: View {
    @ObservedObject var model: ChatPageModel
    @AppStorage(EnvironmentLoginTab.storageKey) private var tab = EnvironmentLoginTab.github.rawValue

    var body: some View {
        if tab == EnvironmentLoginTab.cloudflare.rawValue {
            CloudflareAccountsCard()
        } else {
            GitHubAccountsCard(model: model)
        }
    }
}
