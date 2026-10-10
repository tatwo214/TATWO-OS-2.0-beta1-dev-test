// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesPage.swift；改動 2 行（原因：新增來源標頭；移除舊 TatwoDomainContracts import，改用同名 Facade 型別）
import SwiftUI

// W77 consistency table plus W83's explicitly initiated handoff.

struct DevicesPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @ObservedObject private var chatModel: ChatPageModel
    private let deviceSnapshotProvider: any DomainDeviceSnapshotProvider

    init(
        chatModel: ChatPageModel,
        deviceSnapshotProvider: any DomainDeviceSnapshotProvider =
            TatwoDevicesCompositionRoot.makeProvider()
    ) {
        _chatModel = ObservedObject(wrappedValue: chatModel)
        self.deviceSnapshotProvider = deviceSnapshotProvider
    }

    var body: some View {
        VStack(alignment: .leading) {
            DeviceFleetToolbarContainer()
            DeviceConsistencyPanel()
        }
    }
}

/// Also used by the synthetic screenshot; every label comes from device.json.
struct PrimaryTransferStatusView: View {
    let record: PrimaryTransfer.Record
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.summary).font(.headline)
                .foregroundStyle(record.complete ? Color.green : Color.orange)
            Text("① epoch \(record.oldEpoch) → \(record.epoch)：\(record.epochComplete ? "已完成" : "等待設備讀回")")
            Text("② 憲法正本：\(record.constitutionComplete ? "已遷移" : record.constitution ? "切換中，待兩端讀回" : "仍在舊主設備")")
            Text(record.sourceRoot).font(.caption).textSelection(.enabled)
            Text("③ GBrain：\(record.brain.label)\(record.brainComplete ? "（已驗證）" : "（尚未驗證）")")
            Text("頁數：舊 \(record.sourcePages.map(String.init) ?? "—") ／新 \(record.targetPages.map(String.init) ?? "—")")
                .font(.caption)
            Text("④ 發行能力：\(record.releaseChecked ? record.release.label : "尚未檢查")")
            if record.releaseChecked && record.release == .missingCertificate { Text("比對名稱：" + (record.signingName.isEmpty ? "（空白）" : record.signingName)).font(.caption) }
            if record.releaseChecked && record.localVerification != true && record.acknowledgedRevision < record.releaseRevision {
                Text("發行能力檢查結果待兩端讀回").font(.caption)
            }
            if !record.missingDependencies.isEmpty {
                Text("缺少：" + record.missingDependencies.joined(separator: "、")).font(.caption)
            }
            Text(record.localVerification == true ? "由新主設備在本機分項驗收 · 版本 \(record.revision)" : "兩端讀回：\(record.acknowledgedRevision == record.revision ? "已同步" : "待同步，可重試") · 版本 \(record.revision)")
                .font(.caption)
        }
    }
}
