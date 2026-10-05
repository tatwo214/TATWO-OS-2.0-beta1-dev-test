// W183 R3：設定 › 環境登入 › Cloudflare（多帳號）。照 GitHubAccountsCard 的版面；按鈕一律玻璃 chip，確認用卡片內確認列（不跳系統框）。
// 登入＝標準設定流程的「授權」步驟（W183 R5b：私訊框裡打開 Cloudflare 授權頁、按一下 Authorize）；憑證只進鑰匙圈，AI 讀不到。
import SwiftUI
import AppKit

struct CloudflareAccountsCard: View {
    @ObservedObject private var store = CloudflareAccountsStore.shared
    @ObservedObject private var setup = HandsSetup.shared
    @State private var confirmingRemoval: String?
    @State private var removalProblem: String?
    @State private var removing = false
    /// W183 R3b 審查：確認授權、重新授權做不了的原因。
    @State private var confirmProblem: String?

    private var authorize: HandsSetupStepState { setup.state.step(.authorize) }
    private var loggingIn: Bool { setup.busy && (authorize.status == .running || authorize.status == .waitingUser) }

    var body: some View {
        VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloudflare 帳號（\(store.accounts.count)）").font(.headline)
                Text("ChatGPT 手腳要一個你自己的網域（要付費、放在 Cloudflare）。登入一次就記在這裡，TAP › ChatGPT 只選用、不用再登入。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.accounts.isEmpty {
                Text("還沒有帳號。按下面的「用瀏覽器登入 Cloudflare」加一個。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { account in
                accountRow(account)
                if confirmingRemoval == account.id { removalRow(account) }
                Divider().opacity(0.4)
            }
            if let removalProblem {
                Text(removalProblem).font(.footnote).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("加帳號").font(.headline)
                HStack(spacing: 8) {
                    OSChipButton(title: "用瀏覽器登入 Cloudflare", systemImage: "person.badge.key", isPrimary: true) {
                        // W183 R5b：授權頁在私訊框開（設定頁不關、不跳頁）；私訊鈕關掉時才退回 OS 瀏覽器（那條會先關設定、授權完帶回這一頁）。
                        HandsSetup.returnAfterAuthorize = .environmentLogin
                        HandsSetup.shared.login(trigger: .user)
                    }
                    .disabled(setup.busy)
                    .accessibilityIdentifier("settings.cloudflare.login")
                    if loggingIn {
                        OSChipButton(title: "取消") { HandsSetup.shared.cancel() }
                    }
                }
                if loggingIn || authorize.status == .failed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if loggingIn { ProgressView().controlSize(.small) }
                        Text(authorize.message)
                            .font(.footnote)
                            .foregroundStyle(authorize.status == .failed ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("settings.cloudflare.loginStatus")
                }
                if let url = setup.loginURL {
                    HStack(spacing: 8) {
                        Text("授權頁沒出現？").font(.footnote).foregroundStyle(.secondary)
                        OSChipButton(title: "在這台打開授權頁") {
                            HandsSetup.openLoginPage(url, returnTo: .environmentLogin, onCancel: { HandsSetup.shared.cancel() })
                        }
                    }
                }
                // W183 R3b 審查：在這裡登入完也要先確認帳號與網域（確認前 ChatGPT 手腳不會用它）；上次取消沒清完＝再清一次。
                if let summary = setup.authorizedSummary(), summary.needsConfirm || summary.cleanupPending {
                    HandsAuthorizationRow(summary: summary, canReauthorize: true, busy: setup.busy, problem: confirmProblem,
                                          onConfirm: { domain in
                                              confirmProblem = nil
                                              do { try setup.confirmAuthorization(token: summary.confirmToken ?? "", domain: domain) }
                                              catch { confirmProblem = String(describing: error) }
                                          },
                                          onReauthorize: {
                                              confirmProblem = nil
                                              HandsSetup.returnAfterAuthorize = .environmentLogin
                                              if let refusal = setup.reauthorize(trigger: .user) {
                                                  HandsSetup.returnAfterAuthorize = nil
                                                  confirmProblem = refusal.description
                                              }
                                          })
                }
                Text("登入是在私訊框裡打開 Cloudflare 授權頁、按一下「Authorize」（用這台 OS 瀏覽器已登入的 Cloudflare），一次選一個網域；要用別的網域或帳號就再登入一次。授權存在這台的鑰匙圈，AI 讀不到，也不會碰你電腦裡原本的 cloudflared 設定。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.reload(); setup.refreshDerived() }
        .accessibilityIdentifier("settings.cloudflare.card")
    }

    private func accountRow(_ account: CloudflareAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(account.displayName).font(.subheadline.weight(.medium))
                if account.tunnelID != nil {
                    Text("ChatGPT 手腳")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(LiquidGlassTokens.brandAccent.opacity(0.15), in: Capsule())
                }
                Spacer()
                OSChipButton(title: "移除", role: .destructive) {
                    removalProblem = nil
                    confirmingRemoval = account.id
                }
                .disabled(setup.busy || removing)   // W183 R3 審查：設定進行中不准移除（會跟建通道搶）
                .accessibilityIdentifier("settings.cloudflare.remove")
            }
            ForEach(account.domains, id: \.zoneID) { domain in
                HStack(spacing: 6) {
                    Image(systemName: account.selectedDomain == domain.zoneID ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(account.selectedDomain == domain.zoneID ? LiquidGlassTokens.brandAccent : Color.secondary)
                    Text(domain.name.isEmpty ? "網域（名稱建通道時補上）" : domain.name).font(.footnote)
                    if setup.state.isUnconfirmed(domain.zoneID) {
                        Text("待確認").font(.caption2).foregroundStyle(.orange)   // W183 R3b 審查：確認前 ChatGPT 手腳不用它
                    }
                    if account.selectedDomain == domain.zoneID {
                        Text("ChatGPT 手腳用這個").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let tunnel = account.tunnelID {
                Text("通道 \(tunnel.prefix(8))…（只記 id；token 在鑰匙圈）").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 卡片內確認列（W179 UI 記憶卡的做法；不跳系統確認框）。
    private func removalRow(_ account: CloudflareAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("移除「\(account.displayName)」？").font(.system(size: 13, weight: .semibold))
            Text("會刪掉這台存的 Cloudflare 授權（鑰匙圈）。Cloudflare 上的通道與 DNS 紀錄不會被刪（要刪請到 Cloudflare 後台）。ChatGPT 手腳用的就是這個帳號時，手腳會停下，要重新登入才能再開。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OSChipButton(title: "取消") { confirmingRemoval = nil }
                OSChipButton(title: "移除", role: .destructive) {
                    confirmingRemoval = nil
                    removing = true
                    // 正在用的帳號：先安全停用（關開關＝撤銷全部連線、關口停下、刪通道 token），再刪授權與清單（HandsSetup.removeAccount）。
                    HandsSetup.shared.removeAccount(account.id) { problem in
                        removing = false
                        removalProblem = problem.map { "移除沒有全部完成：\($0)" }
                        store.reload()
                        HandsSetup.shared.refreshDerived()
                    }
                }
                .disabled(setup.busy || removing)
                .accessibilityIdentifier("settings.cloudflare.removeConfirm")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatLiquidSection(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.cloudflare.confirmRow")
    }
}
