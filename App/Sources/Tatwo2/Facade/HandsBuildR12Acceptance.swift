#if DEBUG
import Foundation

// W183 R12 第二批自測（w183build；Fleet＝真的設定正本、信封、信箱、每台的 reconcile 與回報；測試金鑰簽，不上網）：
// 使用者 09-30 裁決「拿掉等級選擇」（「他連上就是全部都能看 唯讀記憶是有他專屬的區塊」：連上＝全開＝L2）；主導：中央設定所有設備一律 L2，
// 但 R11 的安全規則照守——既有 grant 不因此放大（要重新按［連線］同意才拿到新能力）、舊版主機一律不調高；底線不變。
// .032 實測的樣子：mini 的中央設定裡那台是 L0（查不到是誰設的），確認卡因此只顯示「只看」。

extension HandsBuildAcceptance {
    @MainActor static func r12LevelChecks(_ check: Checker, _ base: URL, _ keys: Keys) async throws {
        let fleet = try Fleet(base.appendingPathComponent("r12-unified"), keys: keys)
        let p = try fleet.add(pID, name: "Primary One")
        let authority = fleet.authority
        // C＝舊版主機（回報沒有 level_guard、沒有連線等級）：跟 R11 那一條同一個做法。
        func legacyCall(_ id: String) -> ([String: Any]) throws -> [String: Any] {
            { payload in
                var sent = try Fleet.wire(payload)
                if var report = sent["report"] as? [String: Any] {
                    report["grant_levels"] = nil
                    report["grant_level"] = nil
                    report["level_guard"] = nil
                    sent["report"] = report
                }
                return try Fleet.wire(try HandsBuildRemote.handle(payload: sent, sender: id, authority: authority))
            }
        }
        let b = try fleet.add(bID, name: "Studio B")
        let c = try fleet.add(cID, name: "Desk C", callPrimary: legacyCall(cID))
        let bHost = "os-for-chatgpt-studiob.example.com", cHost = "os-for-chatgpt-deskc.example.com"
        _ = try fleet.update([.select(device: bID, selected: true), .select(device: cID, selected: true), .setEnabled(true),
                              .zone(accountID: accountID, zoneID: zoneID, domain: domain), .level(device: bID, level: 0), .level(device: cID, level: 0)])
        for (device, host) in [(b, bHost), (c, cHost)] {
            _ = try device.service.updateSettings { $0.publicHost = host; $0.hostDeviceID = device.id }
            device.phase.set(.running(url: "https://\(host)/mcp"))
        }
        fleet.syncAll(); fleet.syncAll()
        // B 在 L0 的時候連過一次（舊的 token＝只看）。
        let bOld = try r11Pair(b.service, host: bHost)
        let before = r11ToolLevel(b.service, bOld.access) == 0 && b.service.settings.load().level == 0
        // 主設備更新成 R12：這一份還沒照過「一律 L2」（沒有 level_unified）＝讀檔時照一次：L0 的兩台都記成待升（不直接升）。
        guard var old = fleet.store.load() else { return check(false, "W183 R12 一律 L2：主設備讀不到設定") }
        old.levelUnified = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(old), to: fleet.store.url)
        fleet.store.reloadForTesting()
        let unified = fleet.store.load()
        let pendingBoth = Set(unified?.levelDefaultPending ?? []) == [bID, cID] && unified?.entry(bID)?.level == 0 && unified?.entry(cID)?.level == 0
            && unified?.levelUnified == true && unified?.configRevision == old.configRevision + 1
        fleet.syncAll(); fleet.syncAll(); fleet.syncAll()
        let config = fleet.store.load()
        check(before && pendingBoth && config?.entry(bID)?.level == 2 && b.service.settings.load().level == 2
              && r11ToolLevel(b.service, bOld.access) == 0 && b.service.auth.grantRecord(bOld.grant)?.level == 0,
              "W183 R12 一律 L2（.032 實測：中央是 L0）：主設備照一次、兩台都記成待升；會先封頂的主機（B）升到 L2，但 B 在 L0 時連的舊 token 照舊只看（沒重新按［連線］就拿不到 Codex、記憶）",
              "before=\(before) pending=\(String(describing: unified?.levelDefaultPending)) b=\(String(describing: config?.entry(bID)?.level)) old=\(String(describing: r11ToolLevel(b.service, bOld.access)))")
        let bNew = try r11Pair(b.service, host: bHost)
        check(r11ToolLevel(b.service, bNew.access) == 2 && r11ToolNames(b.service, bNew.access).contains("open_workspace"),
              "W183 R12 重新按一次［連線］（新的連線、看過確認卡）＝全開：Codex 的沙盒工作區工具在")
        // 舊版主機（C）：一律不調高——還是 L0、留在待升清單；面板那一行說「那台要先更新 TATWO OS」。
        let controller = reviewController(fleet, p)
        _ = await waitUntil(5) { controller.view.report(cID) != nil }
        check(config?.entry(cID)?.level == 0 && config?.levelDefaultPending == [cID] && c.service.settings.load().level == 0
              && controller.view.report(cID)?.levelGuard == false && controller.fullNeedsUpdate,
              "W183 R12 舊版主機（回報沒有 level_guard）一律不調高：還是 L0、留在待升清單；面板寫「還沒全開：那台要先更新 TATWO OS」",
              "c=\(String(describing: config?.entry(cID)?.level)) pending=\(String(describing: config?.levelDefaultPending)) needsUpdate=\(controller.fullNeedsUpdate)")
    }
}
#endif
