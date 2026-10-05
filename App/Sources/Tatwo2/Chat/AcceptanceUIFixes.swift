#if DEBUG
import Foundation
import SwiftUI
import AppKit

enum AcceptanceUIFixes {
    @MainActor static func run() throws -> Bool {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W191UI \(condition ? "PASS" : "FAIL") \(label)")
        }
        let environment = ProcessInfo.processInfo.environment
        if TatwoThemeSelfTestScope.forceDark {
            check(NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                  "I3 DEBUG environment pins the App to darkAqua before evidence scopes")
        }
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let liveRoot = environment["TATWO2_LIVE_ROOT"] else {
            throw HandsToolError.invalid("w191ui requires fully isolated staging")
        }
        let root = URL(fileURLWithPath: liveRoot).appendingPathComponent("fixture-" + UUID().uuidString)
        let project = UUID(), other = UUID()
        let journal = HandsRoomJournal(url: root.appendingPathComponent("room.json"))
        check(journal.rows(projectID: project).isEmpty, "M12 empty project has no receipts")
        var receipts: [HandsRoomCall] = []
        for index in 0...200 {
            let row = HandsRoomCall(id: UUID(), at: Date(timeIntervalSince1970: Double(index)), projectID: project,
                                    grantTag: "fixture", tool: "read_file", summary: "fixture", workspaceID: nil, approval: nil)
            receipts.append(row)
            try journal.append(row)
        }
        let rows = journal.rows(projectID: project)
        check(rows.count == 200 && rows.first?.id == receipts[1].id && rows.last?.id == receipts.last?.id,
              "M12 only latest 200 receipts remain active")
        let archive = root.appendingPathComponent("room").appendingPathComponent(project.uuidString).appendingPathComponent("archive")
        let saved = HandsFiles.readSecure(archive.appendingPathComponent(receipts[0].id.uuidString + ".json"))
        check(saved.flatMap { try? JSONDecoder().decode(HandsRoomCall.self, from: $0) }?.id == receipts[0].id,
              "M12 old receipt is preserved in archive")
        try journal.append(receipts[0])
        check(journal.rows(projectID: project).count == 200, "M12 late receipt update does not revive archived history")
        check(journal.rows(projectID: other).isEmpty, "M12 project records stay isolated")
        func summary(_ tool: String, _ text: String) -> String {
            HandsRoomCall(id: UUID(), at: Date(), projectID: project, grantTag: "fixture", tool: tool,
                          summary: text, workspaceID: nil, approval: nil).summaryTitle
        }
        for (state, title) in [("pending", "等待核准"), ("allowed", "已核准"), ("denied", "已拒絕"), ("expired", "已失效")] {
            check(summary("computer_status", "CU " + state) == "操作畫面：" + title,
                  "M12 operation summary translates " + state)
        }
        check([("running", "執行中"), ("exited", "已結束"), ("cancelled", "已取消"), ("timed_out", "已逾時"), ("failed", "啟動失敗")]
            .allSatisfy { state, title in summary("job_status", "工作 " + state) == "工作：" + title
                && summary("job_cancel", "停工作：" + state) == "工作：" + title },
              "M12 job status and cancellation summaries are Chinese")
        check(summary("run_command", "exit 0\nsample") == "結束碼：0\nsample",
              "M12 command status is translated while command output is preserved")
        check(summary("read_file", "CU allowed") == "CU allowed", "M12 unrelated receipt data is preserved")
        ChatGPTTapModelCatalog.replace([
            TapModel(id: "example", title: "O 3-pro", detail: ""),
            TapModel(id: "deep-research", title: "Deep Research", detail: ""),
            TapModel(id: "sample", title: "GPT-5.5", detail: "")])
        check(ChatGPTTapModelCatalog.choices.map(\.title) == ["o3-pro", "GPT-5.5"],
              "M15 official model spelling and no research mode in Coder")
        for connection in [TapConnection.sleeping, .needsLogin, .off, .starting, .failed("fixture")] {
            let reason = ChatGPTTapModelCatalog.unavailabilityReason(connection: connection) ?? ""
            check(!reason.isEmpty && !reason.contains("Pod") && !reason.contains("TAP"),
                  "M15 unavailable reason uses user-facing language")
        }
        check(ChatGPTTapModelCatalog.effortTitle(TapEffort(id: "fixture", title: "Light")) == "輕量"
              && ChatGPTTapModelCatalog.effortTitle(TapEffort(id: "sample", title: "Heavy")) == "深入"
              && ChatGPTTapModelCatalog.effortTitle(TapEffort(id: "example", title: "Custom")) == "其他強度",
              "M15 effort labels are Chinese without changing native IDs")
        check(GlobalDMMessageText.displayText("fixture <image name=[sample.png] path=\"/example/sample.png\">")
              == "fixture [圖片：sample.png]", "M16 local image displays its filename")
        check(GlobalDMMessageText.displayText("fixture", files: ["sample.png", "sample.txt"])
              == "fixture\n\n[圖片：sample.png]\n[檔案：sample.txt]", "M16 ChatGPT attachment names remain distinguishable")
        check(!GlobalDMMessageText.attachmentTag(fileName: "/example/sample.png").contains("/example/"),
              "M16 attachment filenames never expose full paths")
        check(GlobalDMMessageText.displayText("<image path=\"/example/sample.png\">") == "[圖片附件]"
              && GlobalDMMessageText.attachmentTag(fileName: "C:\\example\\sample.png") == "[圖片：sample.png]",
              "M16 nameless images have a description and Windows paths are stripped")
        check(GlobalDMMessageText.displayText("<file name=\"sample report.txt\" path=\"/example/sample report.txt\">")
              == "[檔案：sample report.txt]", "M16 quoted names with spaces remain readable")
        let artifacts = environment["TATWO2_SELFTEST_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        func evidence() -> some View {
            let row = TatwoComposerMode.ModelRow(id: "single", role: "模型", tint: LiquidGlassTokens.brandAccent,
                title: "ChatGPT · o3-pro", identifier: "tatwo.composer.mode.model", isEnabled: false, options: [], choose: { _ in })
            let mode = TatwoComposerMode(eyebrow: "ChatGPT", title: "模式選擇", models: [row],
                modelNote: ChatGPTTapModelCatalog.unavailabilityReason(connection: .needsLogin), segments: [])
            let bubbles = GlobalDMBubble.rows([
                ChatMessage(role: .user, text: GlobalDMMessageText.displayText("請查看附件", files: ["sample.png", "sample.txt"])),
                ChatMessage(role: .assistant, text: "已收到圖片與檔案。")])
            return VStack(spacing: 16) {
                TatwoComposerModeCard(mode: mode, metrics: .main, fitsAbove: false)
                GlobalDMMessageList(bubbles: bubbles, emptyText: "").frame(height: 190)
            }.padding(16)
        }
        if let shot = GlobalDMChatAcceptance.renderSync(evidence(), size: CGSize(width: 400, height: 560)) {
            GlobalDMChatAcceptance.save(shot, "w191-light.png", to: artifacts)
            shot.close()
            check(true, "I3 model unavailable and attachment light evidence")
        } else { check(false, "I3 model unavailable and attachment light evidence") }
        check(TatwoThemeSelfTestScope.saveDarkEvidence("w191-dark.png", size: CGSize(width: 400, height: 560), to: artifacts, content: evidence),
              "I3 model unavailable and attachment darkAqua evidence")
        print("W191UI SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
