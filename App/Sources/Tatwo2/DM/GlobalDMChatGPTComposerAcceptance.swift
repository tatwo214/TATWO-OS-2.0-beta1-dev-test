#if DEBUG
import AppKit
import Combine
import SwiftUI

/// `TATWO2_SELFTEST=w184chat` 的 W184 G3 那一段：私訊框對象是 ChatGPT 時，輸入框＝ChatGPT Space 輸入框的元件（共用）。
/// 規則用純函式驗（兩套尺寸、送出鍵那一格、「＋」分層、膠囊上的字、收附件的規矩）；再用記憶體裡的假 Pod 走一遍私訊框真的動作
/// （工具小卡帶到 ChatGPT、模型與強度、貼上與拖進來的照片檔案、即時語音開始與結束、Esc）；最後把四種樣子畫成 PNG、核對識別碼。
/// ChatGPT Space 的輸入框行為不變：Space 的尺寸常數、送出鍵規則、分層規則、語音「連線中就按結束」的保護都在這裡守（Space 用的是同一份）。
/// W184 G3 修正單（GPT-6 審查＋查證）：即時語音只在 ChatGPT 那一欄真的在畫面上時開著（Browser、倒放、換對象、收框就停）、兩邊只有一個擁有者、
/// 停止要確認（沒確認就關掉語音那一頁）、只收自己那則、舊逐字稿不蓋新回答；聽寫綁住輸入框、可取消；檔案承諾只收接收資料夾裡的一般檔案；
/// 「最近用過的 App」只有一份。每一條都有反例（舊寫法會失敗的情境）。
/// 假 Pod 不開網頁、不連外；剪貼簿用自己的私有 pasteboard，不碰使用者的剪貼簿；設定都寫在自己的私有 suite。
extension GlobalDMChatAcceptance {
    @MainActor static func chatGPTComposerChecks(root: URL, model: ChatPageModel, artifacts: URL?, axWorks: Bool) async
        -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ condition: Bool, _ label: String) { results.append((condition, label)) }
        func checkIDs(_ found: Set<String>, has required: Set<String>, lacks forbidden: Set<String> = [], _ label: String) {
            guard axWorks else { return }
            let missing = required.subtracting(found).sorted()
            let extra = forbidden.intersection(found).sorted()
            check(missing.isEmpty && extra.isEmpty, label + (missing.isEmpty ? "" : " — missing \(missing)") + (extra.isEmpty ? "" : " — unexpected \(extra)"))
        }
        func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
        }

        // MARK: 兩套尺寸（規則）
        let dm = ChatGPTComposerMetrics.dmPhone
        let space = ChatGPTComposerMetrics.space
        let tokens: Set<CGFloat> = [DMPhone.TextSize.body, DMPhone.TextSize.secondary, DMPhone.TextSize.footnote, DMPhone.TextSize.caption]
        check(!dm.textSizes.isEmpty && dm.textSizes.allSatisfy(tokens.contains),
              "G3 DM ChatGPT composer: every font size is a phone token (17/15/13/11)")
        // W184 G3b 追加：私訊框沒有聽寫鈕（只核對看得到的圓鈕）；打的字與佔位字＝ChatGPT Space 輸入框的字級。
        check(dm.inputText == space.inputText && space.inputText == 15,
              "G3b 追加: the DM ChatGPT input text and placeholder are ChatGPT Space's size (\(Int(dm.inputText)) = Space \(Int(space.inputText)); was 17)")
        check([dm.plus, dm.voice, dm.send, dm.stop].allSatisfy { $0.size == DMPhone.smallControl }
              && dm.chipHeight == DMPhone.chipHeight && dm.pickerHeight == DMPhone.chipHeight && dm.chrome == .phone && dm.stopFilled
              && dm.cardRadius == DMPhone.cardRadius && dm.tileRadius == DMPhone.chipHeight / 2
              && dm.menuIcon == DMPhone.smallControl && dm.menuRowHeight >= DMPhone.touch && dm.menuRadius == DMPhone.cardRadius,
              "G3 DM ChatGPT composer: 36pt round buttons, 32pt chips and picker, the ChatGPT-app look (W184 G3b), filled stop like the web, card radius from the tokens")
        check(space.chrome == .web && space.plus == .init(size: 28, glyph: 14) && space.dictation == .init(size: 28, glyph: 13)
              && space.voice == .init(size: 30, glyph: 13) && space.send == .init(size: 30, glyph: 14) && space.stop == .init(size: 28, glyph: 11)
              && !space.stopFilled && space.chipHeight == 28 && space.chipText == 12 && space.pickerHeight == 32 && space.pickerText == 15
              && space.tileImage == ChatGPTAttachmentTile.imageSize && space.tileFileWidth == ChatGPTAttachmentTile.fileWidth
              && space.tileFileHeight == ChatGPTAttachmentTile.fileHeight && space.tileRadius == 16
              && space.cardRadius == ChatGPTEffortCardMetrics.radius && ChatGPTEffortCardMetrics.width == 260 && ChatGPTEffortCardMetrics.radius == 24
              && space.cardTitle == 16 && space.cardRow == 14 && space.voiceRing == 150 && space.voiceDot == 96 && space.dropRadius == 18,
              "G3 ChatGPT Space keeps its own numbers (28/30pt buttons, 15pt picker, 144/240 tiles, 260×24 card, 150/96 voice rings)")
        check(ChatGPTComposerChips.rowHeight(files: [], metrics: space) == 38
              && ChatGPTComposerChips.rowHeight(files: [.init(id: UUID(), name: "照片.png", mime: "image/png", data: Data())], metrics: space) == 152
              && ChatGPTComposerChips.rowHeight(files: [.init(id: UUID(), name: "文件.pdf", mime: "application/pdf", data: Data())], metrics: space) == 64,
              "G3 ChatGPT Space: the chip row is 38 (tool only), 152 (image), 64 (file) high, as before")

        // MARK: 送出鍵那一格（兩邊同一條規則）
        check(ChatGPTSendSlot.kind(isSending: true, isEmpty: true) == .stop && ChatGPTSendSlot.kind(isSending: true, isEmpty: false) == .stop
              && ChatGPTSendSlot.kind(isSending: false, isEmpty: true) == .voice && ChatGPTSendSlot.kind(isSending: false, isEmpty: false) == .send,
              "G3 send slot like the web: answering = stop, empty = voice mode, typed = send")

        // MARK: 「＋」分層（ChatGPT Space 與私訊框同一份規則）
        let tools = [
            TapTool(id: "search", title: "網路搜尋", detail: "找即時的答案", rank: 2),
            TapTool(id: "picture_v2", title: "建立圖片", detail: "把想法變成圖片", rank: 1),
            TapTool(id: "research", title: "深入研究", detail: "取得詳細報告", rank: 3),
            TapTool(id: "canvas", title: "Sketch", detail: "", rank: 4),
            TapTool(id: "study", title: "學習", detail: "", rank: 5),
            TapTool(id: "hidden", title: "藏起來的", detail: "", rank: 0, hidden: true),
            TapTool(id: "connector:gh", title: "GitHub", detail: "", isApp: true),
            TapTool(id: "connector:gm", title: "Gmail", detail: "", isApp: true, headApp: true),
            TapTool(id: "connector:pdf", title: "PDF", detail: "", isApp: true, firstPartyApp: true),
            TapTool(id: "connector:notion", title: "Notion", detail: "", isApp: true),
        ]
        check(ChatGPTSpaceModel.plusTools(tools).map(\.id) == ["picture_v2", "search", "research", "canvas"],
              "G3 ＋ first level: the four ranked tools in rank order (hidden and apps left out)")
        check(ChatGPTSpaceModel.plusApps(tools, recent: []).map(\.id) == ["connector:gm"]
              && ChatGPTSpaceModel.plusApps(tools, recent: ["connector:notion", "connector:pdf"]).map(\.id) == ["connector:notion", "connector:gm"],
              "G3 ＋ second level: recently used apps first, then the web's head apps; OpenAI's own apps never on the first level")
        check(ChatGPTSpaceModel.moreTools(tools, recent: []).map(\.id) == ["study", "connector:gh", "connector:pdf", "connector:notion"],
              "G3 ＋ 更多: everything else that is not hidden")
        let suite = "ai.tatwo.selftest.w184g3.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "G3 fixture: defaults suite"); return results }
        defer { defaults.removePersistentDomain(forName: suite) }
        ChatGPTSpaceModel.rememberApp(tools[9], in: defaults)
        ChatGPTSpaceModel.rememberApp(tools[0], in: defaults)
        check(defaults.stringArray(forKey: ChatGPTSpaceModel.recentAppsKey) == ["connector:notion"],
              "G3 picking an app remembers it (ids only); picking a tool does not")

        // MARK: 膠囊上的字（照網頁）
        let pro = TapEffort(id: "v6|pro", title: "Pro", version: "6", level: "Pro", isMax: true, showsVersion: true)
        let high = TapEffort(id: "v6|high", title: "High")
        let proLabel = ChatGPTSpaceModel.PickerLabel.resolve(effort: pro, model: nil, fallback: "ChatGPT")
        let highLabel = ChatGPTSpaceModel.PickerLabel.resolve(effort: high, model: nil, fallback: "ChatGPT")
        let bare = ChatGPTSpaceModel.PickerLabel.resolve(effort: nil, model: TapModel(id: "gpt-x", title: "GPT X", detail: ""), fallback: "ChatGPT")
        check(proLabel == .init(version: "6", level: "Pro", isMax: true) && highLabel == .init(version: nil, level: "高", isMax: false)
              && bare == .init(version: nil, level: "GPT X", isMax: false)
              && ChatGPTSpaceModel.PickerLabel.resolve(effort: nil, model: nil, fallback: "預設").level == "預設",
              "G3 picker words like the web: 「6 Pro」 (Pro purple), Chinese level names, model name when there is no level")

        // MARK: 收附件的規矩（ChatGPT Space 與私訊框同一套）
        let tiff = Self.fixtureImage(size: 12, type: .tiff)
        if case .success(let converted) = ChatGPTSpaceModel.admit(tiff, name: "掃描.tiff", mime: "image/tiff", currentBytes: 0) {
            check(converted.mime == "image/jpeg" && converted.name == "掃描.jpg", "G3 admit: images ChatGPT cannot read become JPEG")
        } else {
            check(false, "G3 admit: images ChatGPT cannot read become JPEG")
        }
        if case .failure(let refusal) = ChatGPTSpaceModel.admit(Data(count: 16), name: "大檔.bin", mime: "application/octet-stream",
                                                                 currentBytes: ChatGPTSpaceModel.attachmentLimit - 8) {
            check(refusal.message == "附件合計超過 20 MB，「大檔.bin」沒有加入", "G3 admit: over 20 MB in total is refused with one sentence")
        } else {
            check(false, "G3 admit: over 20 MB in total is refused with one sentence")
        }

        // MARK: 檔案承諾（查證：別的 App 交來的檔案）——只收這次接收資料夾「直接裡面」的一般檔案（ChatGPT Space 與私訊框同一條路）
        let inbox = root.appendingPathComponent("g3-promises-\(UUID().uuidString)", isDirectory: true)
        let outside = root.appendingPathComponent("g3-私人.txt")
        try? FileManager.default.createDirectory(at: inbox.appendingPathComponent("子資料夾", isDirectory: true), withIntermediateDirectories: true)
        try? Data("不能被讀到".utf8).write(to: outside)
        let promisedPhoto = Self.fixtureImage(size: 16, type: .png)
        try? promisedPhoto.write(to: inbox.appendingPathComponent("照片.png"))
        try? Data("巢狀".utf8).write(to: inbox.appendingPathComponent("子資料夾/裡面.png"))
        try? FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("連結.png"), withDestinationURL: outside)
        try? FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("連到外面"), withDestinationURL: root)
        let fifoMade = Darwin.mkfifo(inbox.appendingPathComponent("管線.png").path, 0o600) == 0
        try? Data(count: 64).write(to: inbox.appendingPathComponent("大.bin"))
        func receive(_ name: String, limit: Int = ChatGPTSpaceModel.attachmentLimit) -> Data? {
            ChatGPTSpaceModel.readReceivedFile(inbox.appendingPathComponent(name), in: inbox, limit: limit)
        }
        check(receive("照片.png") == promisedPhoto, "G3 file promise: a regular file inside this drop's folder is read")
        // 反例：直接讀（舊寫法 Data(contentsOf:)）會跟著連結讀到資料夾外的檔案。
        check(receive("連結.png") == nil && (try? Data(contentsOf: inbox.appendingPathComponent("連結.png"))) == Data("不能被讀到".utf8),
              "G3 file promise: a symlink to a file outside is refused (plain reading would have followed it)")
        check(ChatGPTSpaceModel.readReceivedFile(outside, in: inbox, limit: ChatGPTSpaceModel.attachmentLimit) == nil
              && receive("../g3-私人.txt") == nil && receive("連到外面/g3-私人.txt") == nil,
              "G3 file promise: paths outside this drop's folder (direct, .., through a linked folder) are refused")
        check(fifoMade && receive("子資料夾") == nil && receive("子資料夾/裡面.png") == nil && receive("管線.png") == nil,
              "G3 file promise: folders, nested files and non-regular files (a pipe) are refused")
        check(receive("大.bin", limit: 63) == nil && receive("大.bin", limit: 64)?.count == 64,
              "G3 file promise: over the size limit is refused before reading")
        // W184 G3 第三輪（修正核對 #4(b)）：檔案承諾只收一個名字的檔案（同一個檔案的第二個名字＝硬連結，不收）。
        let hardLink = inbox.appendingPathComponent("硬連結.png")
        let hardLinked = (try? FileManager.default.linkItem(at: inbox.appendingPathComponent("照片.png"), to: hardLink)) != nil
        check(hardLinked && ChatGPTSpaceModel.readReceivedFile(hardLink, in: inbox, limit: 1_000_000, singleLink: true) == nil
              && ChatGPTSpaceModel.readReceivedFile(hardLink, in: inbox, limit: 1_000_000) != nil,
              "G3 file promise: a second name for the same file (hard link) is refused for promised files")
        // W184 G3 第三輪（修正核對 #5）：大張的非網頁格式照片（21 MB 的 TIFF 掃描檔）照樣收：讀進來、轉成 JPEG；其他檔案照舊 20 MB。
        // 反例：舊的「一律 20 MB」在讀之前就擋掉這張照片（以前轉 JPEG 後收得下）。
        let bigScan = inbox.appendingPathComponent("大掃描.tiff")
        var scanData = Self.fixtureImage(size: 64, type: .tiff)
        scanData.append(Data(count: 21 * 1024 * 1024))
        try? scanData.write(to: bigScan)
        var bigScanAdmitted = false
        if let raw = ChatGPTSpaceModel.readReceivedFile(bigScan, in: inbox, limit: ChatGPTSpaceModel.readLimit(for: "大掃描.tiff")),
           case .success(let file) = ChatGPTSpaceModel.admit(raw, name: "大掃描.tiff", mime: "image/tiff", currentBytes: 0) {
            bigScanAdmitted = file.mime == "image/jpeg" && file.data.count < ChatGPTSpaceModel.attachmentLimit
        }
        let bigFile = inbox.appendingPathComponent("大文件.pdf")
        try? Data(count: 21 * 1024 * 1024).write(to: bigFile)
        check(bigScanAdmitted && ChatGPTSpaceModel.readLimit(for: "a.heic") == 200 * 1024 * 1024
              && ChatGPTSpaceModel.readLimit(for: "a.dng") == 200 * 1024 * 1024 && ChatGPTSpaceModel.readLimit(for: "a.pdf") == 20 * 1024 * 1024
              && ChatGPTSpaceModel.readReceivedFile(bigFile, in: inbox, limit: ChatGPTSpaceModel.readLimit(for: "大文件.pdf")) == nil,
              "G3 large photos: a 21 MB TIFF scan is still accepted (read, then turned into a JPEG); other files keep the 20 MB limit")
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.removeItem(at: outside)

        // MARK: 私訊框真的動作（假 Pod）
        let pod = GlobalDMChatGPTComposerPod()
        let tap = ChatGPTTap(transport: pod, connection: .ready)
        let session = ChatGPTConversationSession(tap: tap)
        let catalog = ChatGPTModelCatalog(models: [
            TapModel(id: "version:fixture", title: "Latest", detail: "",
                     efforts: [TapEffort(id: "fixture|instant", title: "Instant"), TapEffort(id: "fixture|high", title: "High"),
                               TapEffort(id: "fixture|pro", title: "Pro", version: "6", level: "Pro", isMax: true, showsVersion: true)]),
        ], defaultModelID: "version:fixture", defaultEffortID: "fixture|pro", tools: tools)
        // 「最近用過的 App」也寫在私有 suite（正式是 UserDefaults.standard，跟 ChatGPT Space 同一份）。
        let store = GlobalDMStore(defaults: defaults, chatGPT: { session }, chatGPTAllowed: { true },
                                  chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: defaults)
        store.attach(model)
        store.select(.chatGPT)
        store.openFloating()
        check(store.chatGPTCatalog.tools.count == tools.count && store.pickerLabel == .init(version: "6", level: "Pro", isMax: true)
              && !store.pickerCanReset,
              "G3 DM: the ＋ tools and the models come from the same list as ChatGPT Space; the capsule starts on ChatGPT's 「6 Pro」")

        // 模型與強度：面板的動作只改私訊框這邊。
        let spaceModelKey = UserDefaults.standard.string(forKey: ChatGPTSpaceModel.modelKey)
        let spaceEffortKey = UserDefaults.standard.string(forKey: ChatGPTSpaceModel.effortKey)
        store.pickerChoose(effort: "fixture|high")
        check(store.chatGPTChoice == ChatGPTModelChoice(modelID: nil, effortID: "fixture|high")
              && store.pickerLabel == .init(version: nil, level: "高", isMax: false) && store.pickerCanReset && store.pickerEffortID == "fixture|high",
              "G3 DM: picking a level on the card changes the capsule (「高」) and offers ↺ back to ChatGPT's default")
        store.isChatGPTModelCardOpen = true
        check(store.dismissChatGPTLayers() && !store.isChatGPTModelCardOpen, "G3 DM: Esc closes the card first")

        // 工具小卡：選了出現、送出時帶到 ChatGPT（網頁的 hint）、送到了才清；App 記進最近用過。
        store.chooseChatGPTTool(tools[1])
        store.chooseChatGPTTool(tools[9])
        check(store.chatGPTTool == tools[9] && store.chatGPTRecentApps.first == "connector:notion",
              "G3 DM: choosing from ＋ puts one tool card in the composer (the last pick wins); apps go to the recent list")
        // 「最近用過的 App」只有一份（查證）：內橫右欄（另一個 store、自己的設定 suite）選的 App，左欄與 ChatGPT Space 的「＋」都排第一。
        // 反例：舊寫法記在各自的設定裡（右欄記在它自己的 suite），左欄與 Space 看不到。
        let rightSuite = "ai.tatwo.selftest.w184g3.duo.\(UUID().uuidString)"
        if let rightDefaults = UserDefaults(suiteName: rightSuite) {
            let right = GlobalDMStore(defaults: rightDefaults, chatGPT: { session }, chatGPTAllowed: { true },
                                      chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: defaults)
            right.chooseChatGPTTool(tools[6])
            let shared = defaults.stringArray(forKey: ChatGPTSpaceModel.recentAppsKey) ?? []
            check(shared.first == "connector:gh" && store.chatGPTRecentApps.first == "connector:gh"
                  && rightDefaults.stringArray(forKey: ChatGPTSpaceModel.recentAppsKey) == nil
                  && ChatGPTSpaceModel.plusApps(tools, recent: shared).first?.id == "connector:gh",
                  "G3 recent apps: an app picked in the 內橫 right column comes first in the left column's and ChatGPT Space's ＋ (one list)")
            rightDefaults.removePersistentDomain(forName: rightSuite)
        } else {
            check(false, "G3 fixture: right-column defaults suite")
        }
        store.chooseChatGPTTool(nil)
        check(store.chatGPTTool == nil, "G3 DM: × on the tool card takes it away")
        store.chooseChatGPTTool(tools[1])

        // 貼上（私有 pasteboard）：原始 PNG／JPEG 直接收（不重新編碼）、Finder 的檔案讀進記憶體、只有文字照常貼文字。
        let board = NSPasteboard(name: NSPasteboard.Name("ai.tatwo.selftest.w184g3.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let png = Self.fixtureImage(size: 64, type: .png)
        board.clearContents()
        board.setData(png, forType: .png)
        let pastedPNG = store.pasteAttachment(from: board)
        let jpeg = Self.fixtureImage(size: 24, type: .jpeg)
        board.clearContents()
        board.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        let pastedJPEG = store.pasteAttachment(from: board)
        let pdfURL = root.appendingPathComponent("g3-驗收清單.pdf")
        try? Data("%PDF-1.4 fixture".utf8).write(to: pdfURL)
        board.clearContents()
        board.writeObjects([pdfURL as NSURL])
        let pastedFile = store.pasteAttachment(from: board)
        board.clearContents()
        board.setString("只有文字", forType: .string)
        let pastedText = store.pasteAttachment(from: board)
        let files = store.attachments(for: .chatGPT)
        check(pastedPNG && pastedJPEG && pastedFile && !pastedText && files.count == 3
              && files[0].name == "貼上的圖片.png" && files[0].data == png && files[1].name == "貼上的圖片.jpg" && files[1].data == jpeg
              && files[2].name == "g3-驗收清單.pdf" && files[2].fileURL == nil && files[2].data == Data("%PDF-1.4 fixture".utf8),
              "G3 DM paste (ChatGPT Space's intake): raw PNG/JPEG kept as is, Finder files read into memory, plain text still pastes as text")
        // 拖到對話區上（不在輸入框上）：同 ChatGPT Space 的對話區。
        let dragURL = root.appendingPathComponent("g3-拖進來.png")
        try? Self.fixtureImage(size: 32, type: .png).write(to: dragURL)
        let dropped = store.attachChatGPT(providers: [NSItemProvider(object: dragURL as NSURL)])
        await waitUntil { store.attachments(for: .chatGPT).count == 4 }
        check(dropped && store.attachments(for: .chatGPT).last?.name == "g3-拖進來.png" && store.attachments(for: .chatGPT).last?.data != nil,
              "G3 DM drop onto the conversation: the file arrives as an attachment (in memory)")
        if let dragged = store.attachments(for: .chatGPT).last { store.removeAttachment(dragged.id) }
        check(store.attachments(for: .chatGPT).count == 3, "G3 DM: an attachment thumbnail can be taken away")
        // W184 G3 第三輪（修正核對 #4）：拖到對話區的也走同一個安全讀法。反例：舊寫法直接讀，會跟著連結讀到資料夾外的檔案。
        let dropFolder = root.appendingPathComponent("g3-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        let dropSecret = root.appendingPathComponent("g3-拖放私人.txt")
        try? Data("不能被拖進來".utf8).write(to: dropSecret)
        let dropLink = dropFolder.appendingPathComponent("照片.png")
        try? FileManager.default.createSymbolicLink(at: dropLink, withDestinationURL: dropSecret)
        let beforeDrop = store.attachments(for: .chatGPT).count
        _ = store.attachChatGPT(providers: [NSItemProvider(object: dropLink as NSURL)])
        await waitUntil { store.notice == ChatGPTSpaceModel.refusedMessage("照片.png") }
        check(store.attachments(for: .chatGPT).count == beforeDrop && store.notice == ChatGPTSpaceModel.refusedMessage("照片.png"),
              "G3 drop onto the conversation: a file URL that is a symlink is refused (not read through the link)")
        let recorder = GlobalDMChatGPTSinkRecorder()
        ChatGPTSpaceModel.receiveProvidedFile(dropLink, fallbackMime: "image/png", into: recorder.sink)
        let dropImage = dropFolder.appendingPathComponent("系統暫存.png")
        try? Self.fixtureImage(size: 20, type: .png).write(to: dropImage)
        ChatGPTSpaceModel.receiveProvidedFile(dropImage, fallbackMime: "image/png", into: recorder.sink)
        await waitUntil { recorder.failed.count + recorder.added.count >= 2 }
        check(recorder.failed == [ChatGPTSpaceModel.refusedMessage("照片.png")] && recorder.added.map { $0.name } == ["系統暫存.png"],
              "G3 drop onto the conversation: the system's image file goes through the same reader (link refused, regular image read)")
        try? FileManager.default.removeItem(at: dropFolder)
        try? FileManager.default.removeItem(at: dropSecret)

        // 畫出來：空白、打字中、工具小卡＋附件、回答中、思考強度面板、語音模式。
        let paneSize = CGSize(width: GlobalDMLayout.box.width, height: GlobalDMLayout.box.height)
        func pane() -> some View {
            GlobalDMChatAcceptanceFrame { GlobalDMChatGPTPane(store: store, session: session, isAvailable: true) }
        }
        // W184 G3b：輸入框右邊多一顆圓框放大鏡（網路搜尋）。W184 G3b 追加：私訊框沒有聽寫鈕（tatwo.dm.dictate 不在）。
        // W184 G3c（使用者：「功能鍵也不全」）：模型與思考強度膠囊回到輸入框（照 ChatGPT Space 的輸入框；識別碼照舊 tatwo.dm.model）。
        let composerBase: Set<String> = ["tatwo.dm.input", "tatwo.dm.attach", "tatwo.dm.webSearch", "tatwo.dm.model", "tatwo.dm.chatgptCaption"]
        if let first = renderSync(pane(), size: paneSize) {
            // 縮圖是縮圖元件自己的 `.task` 讀的：讓出主執行緒讓它跑完，再重截一次（視窗還開著）。
            let shot = await settle(first)
            save(shot, "chatgpt-tool-attachments.png", to: artifacts)
            let thumbnailPixels = count(shot, near: Self.fixtureRGB)
            // 門檻＝一格半縮圖（72pt 見方×螢幕倍率²×1.5）：一張縮圖畫滿也到不了，要兩張都畫出來才過（實測兩張約 1.7 格）。
            let scale = Double(shot.bitmap.pixelsWide) / Double(shot.size.width)
            let tile = Double(ChatGPTComposerMetrics.dmPhone.tileImage)
            let twoPhotos = Int(1.5 * tile * tile * scale * scale)
            check(thumbnailPixels >= twoPhotos,
                  "G3 (drawn) the two photos show as thumbnails above the text [\(thumbnailPixels) px ≥ \(twoPhotos), more than one thumbnail can hold]")
            checkIDs(identifiers(in: shot), has: composerBase.union(["tatwo.dm.tool", "tatwo.dm.attachments", "tatwo.dm.send"]),
                     lacks: ["tatwo.dm.voice", "tatwo.dm.stop", "tatwo-memory-strength"],
                     "G3 drawn: tool card + thumbnails above the text; with attachments the slot is send")
            shot.close()
        }

        // 送出：工具、強度、附件都帶到 ChatGPT（TAP 指令）；送到了才清草稿、附件、工具小卡。
        store.setDraft("幫我把這三個檔案整理成一張表", for: .chatGPT)
        let sent = store.send()
        let command = pod.commands.last { $0["cmd"] as? String == "send" } ?? [:]
        let sentFiles = (command["files"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        check(sent && command["hint"] as? String == "picture_v2" && command["effort"] as? String == "fixture|high" && command["model"] == nil
              && sentFiles == ["貼上的圖片.png", "貼上的圖片.jpg", "g3-驗收清單.pdf"],
              "G3 DM send: the tool (as ChatGPT Space sends it), the picked level and the three files reach ChatGPT")
        check(store.chatGPTTool == nil && store.attachments(for: .chatGPT).isEmpty && store.draft(for: .chatGPT).isEmpty && session.isSending,
              "G3 DM send: draft, files and the tool card clear once it is on its way")
        check(UserDefaults.standard.string(forKey: ChatGPTSpaceModel.modelKey) == spaceModelKey
              && UserDefaults.standard.string(forKey: ChatGPTSpaceModel.effortKey) == spaceEffortKey,
              "G3 DM: ChatGPT Space's own model and level are untouched by the DM's card")
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-answering.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: composerBase.union(["tatwo.dm.stop"]), lacks: ["tatwo.dm.send", "tatwo.dm.voice"],
                     "G3 drawn: while ChatGPT answers the slot is stop")
            shot.close()
        }
        check(!store.canChooseModel, "G3 DM: the capsule is off while ChatGPT answers (same rule as the other targets)")
        pod.answer("好的，整理如下。")
        await waitUntil { !session.isSending }
        check(!session.isSending && session.messages.last?.text == "好的，整理如下。", "G3 fixture: the answer arrives through the in-memory Pod")

        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-empty.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: composerBase.union(["tatwo.dm.voice"]),
                     lacks: ["tatwo.dm.send", "tatwo.dm.stop", "tatwo.dm.tool", "tatwo-memory-strength", "tatwo.dm.dictate"],
                     "G3 drawn: empty composer — ＋, search and voice mode in the send slot (like the ChatGPT app); no dictation, no memory chip")
            shot.close()
        }
        store.setDraft("再畫一張橫的", for: .chatGPT)
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-typing.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: composerBase.union(["tatwo.dm.send"]), lacks: ["tatwo.dm.voice", "tatwo.dm.stop"],
                     "G3 drawn: typing — the slot becomes send")
            shot.close()
        }
        store.isChatGPTModelCardOpen = true
        // W184 G3c：膠囊在輸入框裡，思考強度與模型面板浮在膠囊上面（同 ChatGPT Space；掛在 ChatGPT 那一欄上）。
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-model-card.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["chatgpt.modelPopover", "chatgpt.effortSlider", "chatgpt.modelVersions", "tatwo.dm.model"],
                     "G3 drawn: the thinking card floats above the model capsule in the composer (slider, 「6 Pro ›」 to the versions; like ChatGPT Space)")
            shot.close()
        }
        store.select(.assistant)
        check(!store.isChatGPTModelCardOpen, "G3 DM: switching target closes the card")
        store.select(.chatGPT)

        // MARK: 即時語音（GPT-6 審查＋查證）：看得到才開、兩邊只有一個擁有者、停止要確認、只收自己那則、舊逐字稿不蓋新回答
        // 結束的每一步等多久（自測縮短；正式 6 秒／4 秒／0.4 秒）。
        func quick(_ voice: ChatGPTVoiceMode) {
            voice.stopTimeout = .milliseconds(400)
            voice.stateTimeout = .milliseconds(400)
            voice.stopPause = .milliseconds(50)
        }
        func stops(_ pod: GlobalDMChatGPTComposerPod) -> Int {
            pod.commands.filter { $0["cmd"] as? String == "voice" && $0["stop"] as? Bool == true }.count
        }
        func starts(_ pod: GlobalDMChatGPTComposerPod) -> Int {
            pod.commands.filter { $0["cmd"] as? String == "voice" && $0["stop"] == nil }.count
        }
        func wasSent(_ text: String) -> Bool { pod.commands.contains { $0["cmd"] as? String == "send" && $0["text"] as? String == text } }
        func gets() -> [String] { pod.commands.filter { $0["cmd"] as? String == "get" }.compactMap { $0["conversationID"] as? String } }
        let transcript = ["（語音）今天天氣如何", "晴天，最高 27 度。"]
        let forcedNotice = "語音那一頁沒有回應，已經關掉那一頁（麥克風停了）；等一下就能再用"
        quick(session.voice)

        // 開始：ChatGPT 那一欄在畫面上、沒人拿著語音；送出「開始」之前就佔住（中間沒有 await，另一邊不會同時開始）。
        let conversationBefore = session.conversationID
        check(store.chatGPTColumnOnScreen && session.canStartVoice && tap.voiceStartBlocker == nil,
              "G3 voice: the wave button is on while the ChatGPT column is on screen and nothing holds the page")
        let startedDM = store.startChatGPTVoice()
        check(startedDM && session.voice.voiceActive && tap.voiceClaim != nil && tap.voiceStartBlocker == "另一邊的語音模式還開著",
              "G3 voice owner: the DM takes the voice before the start goes to the page (no await in between)")
        await waitUntil { session.voice.voiceLive }
        let voiceStart = pod.commands.last { $0["cmd"] as? String == "voice" && $0["stop"] == nil }
        check(session.voice.voiceActive && session.voice.voiceLive && voiceStart?["conversationID"] as? String == conversationBefore
              && conversationBefore != nil && session.voice.voiceStatus == "正在聆聽，直接說話",
              "G3 DM voice mode starts in the DM's own conversation (same ChatGPTVoiceMode as ChatGPT Space)")
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-voice.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.voiceMode", "tatwo.dm.voiceMode.stop"], "G3 drawn: the voice screen covers the ChatGPT column")
            shot.close()
        }

        // 兩邊互斥：私訊框拿著語音時，ChatGPT Space（同一個 ChatGPTVoiceMode、同一個 TAP）開不了，聲波鈕是關的。
        let spaceVoice = ChatGPTVoiceMode(tap: tap, holderNotice: "ChatGPT Space 的語音模式還開著")
        quick(spaceVoice)
        let startsHeld = starts(pod)
        check(!spaceVoice.canStart && !spaceVoice.startVoice() && !spaceVoice.voiceActive && starts(pod) == startsHeld,
              "G3 voice owner: while the DM holds voice, ChatGPT Space cannot start and its wave button is off")

        // 語音中不送文字（畫面、store、session、TAP 各擋一層，不只靠畫面遮住）；會換頁的指令不做。
        store.setDraft("語音中打的字", for: .chatGPT)
        check(!store.send() && store.draft(for: .chatGPT) == "語音中打的字" && !session.isSending && !wasSent("語音中打的字"),
              "G3 voice: Return and send do nothing while voice is on (the draft stays)")
        session.send("繞過畫面直接送")
        check(!session.isSending && !wasSent("繞過畫面直接送"), "G3 voice: the session itself refuses text while its voice is on")
        store.setDraft("", for: .chatGPT)
        let spaceSession = ChatGPTConversationSession(tap: tap)   // 代表 ChatGPT Space：經同一個 TAP 送出
        spaceSession.send("另一邊的訊息")
        try? await Task.sleep(for: .milliseconds(100))
        check(spaceSession.isSending && !wasSent("另一邊的訊息"), "G3 TAP: a send from the other side waits in the queue while voice holds the page")
        var shareRefusal = ""
        do { _ = try await tap.share(conversationID: "c-dm", messageID: nil) } catch { shareRefusal = error.localizedDescription }
        check(shareRefusal == "語音模式開著；結束語音再試" && !pod.commands.contains { $0["cmd"] as? String == "share" },
              "G3 TAP: commands that would move the page are refused while voice holds it")

        // Esc 先停語音——內橫 Browser 開在右欄時也一樣（對話欄還在畫面上，語音不會被自動停）；頁面換到別則也只收自己那一則。
        store.browsesBeside = true
        store.showBrowser()
        check(store.isBrowsingBeside && store.chatGPTColumnOnScreen && session.voice.voiceActive && !session.voice.voiceStopping,
              "G3 voice: with Browser beside (內橫) the ChatGPT column stays on screen and voice keeps going")
        pod.voiceConversation = "c-elsewhere"
        let stopsEsc = stops(pod)
        check(store.endChatGPTVoiceForEscape() && session.voice.voiceStopping, "G3 DM: Esc ends voice mode first, even with Browser open")
        await waitUntil { !session.voice.voiceActive && session.messages.map(\.text) == transcript }
        check(!session.voice.voiceActive && session.voice.lastEnd == .confirmed && stops(pod) == stopsEsc + 1 && tap.voiceClaim == nil
              && session.conversationID == conversationBefore && gets().last == conversationBefore && !gets().contains("c-elsewhere")
              && session.messages.map(\.text) == transcript,
              "G3 DM voice end: the stop is confirmed, then only the DM's own conversation comes back (not the one the page moved to)")
        store.select(.chatGPT)
        store.browsesBeside = false
        // 放掉語音後，排隊的那一則接著送出。
        await waitUntil { wasSent("另一邊的訊息") }
        check(wasSent("另一邊的訊息"), "G3 TAP: the queued send goes out once voice is released")
        pod.answer("另一邊的回答")
        await waitUntil { !spaceSession.isSending }

        // 另一邊回答到一半：私訊框開不了語音；反過來，私訊框回答到一半，ChatGPT Space 也開不了。
        spaceSession.send("另一邊再問一次")
        await waitUntil { wasSent("另一邊再問一次") }
        let startsBusy = starts(pod)
        check(spaceSession.isSending && !session.canStartVoice && !store.startChatGPTVoice() && starts(pod) == startsBusy
              && tap.voiceStartBlocker == "ChatGPT 正在回答；等它結束再開語音",
              "G3 voice owner: while ChatGPT Space's answer is running the DM cannot start voice")
        pod.answer("另一邊的第二個回答")
        await waitUntil { !spaceSession.isSending }
        store.setDraft("私訊框的問題", for: .chatGPT)
        check(store.send() && session.isSending && !spaceVoice.canStart && !spaceVoice.startVoice() && starts(pod) == startsBusy,
              "G3 voice owner: while the DM's answer is running ChatGPT Space cannot start voice")
        pod.answer("私訊框的回答")
        await waitUntil { !session.isSending }

        // ChatGPT Space 拿著語音：私訊框的聲波鈕是關的、按了也不開；私訊框離開畫面也不會去關別人的語音。
        check(spaceVoice.startVoice(), "G3 fixture: ChatGPT Space takes the voice")
        await waitUntil { spaceVoice.voiceLive }
        let startsSpace = starts(pod)
        check(!session.canStartVoice && !store.startChatGPTVoice() && !session.voice.voiceActive && starts(pod) == startsSpace,
              "G3 voice owner: while ChatGPT Space holds voice the DM's wave button is off and pressing it does nothing")
        let stopsSpace = stops(pod)
        store.close()
        try? await Task.sleep(for: .milliseconds(150))
        check(spaceVoice.voiceActive && stops(pod) == stopsSpace, "G3 voice owner: the DM leaving the screen never ends ChatGPT Space's voice")
        store.openFloating()
        // W184 G3 第三輪（修正核對 #1）：私訊框說一句是誰拿著語音，給「結束那邊的語音」（走 Space 那一邊自己的確認結束）。
        check(session.voiceElsewhere == "ChatGPT Space 的語音模式還開著",
              "G3 voice elsewhere: the DM says 「ChatGPT Space 的語音模式還開著」 while its wave button is off")
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-voice-elsewhere.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.voiceElsewhere", "tatwo.dm.voiceElsewhere.action"],
                     "G3 drawn: the notice with 「結束那邊的語音」 sits above the DM's composer")
            shot.close()
        }
        check(session.endVoiceElsewhere() && spaceVoice.voiceStopping,
              "G3 voice elsewhere: 「結束那邊的語音」 asks ChatGPT Space's voice to end (its own confirmed stop)")
        await waitUntil { !spaceVoice.voiceActive }
        check(!spaceVoice.voiceActive && spaceVoice.lastEnd == .confirmed && tap.voiceClaim == nil && session.voiceElsewhere == nil,
              "G3 fixture: ChatGPT Space's voice ends (confirmed) and lets go of the page")

        // ChatGPT 那一欄離開畫面＝結束語音（確認停了才放掉）。反例：舊寫法只看租約，單欄切到 Browser、倒放時語音還開著。
        let leaving: [(String, () -> Void, () -> Void)] = [
            ("switching the single column to Browser", { store.showBrowser() }, { store.select(.chatGPT) }),
            ("turning to 倒放 (tent)", { store.hidesColumns = true }, { store.hidesColumns = false }),
            ("switching to another target", { store.select(.assistant) }, { store.select(.chatGPT) }),
            ("closing the box", { store.close() }, { store.openFloating() }),
            // W184 G3 第三輪（修正核對 #3）：［連線］的 sheet 蓋住框（停止鈕被蓋住）＝不在畫面上。
            ("the ［連線］ sheet covering the box", { store.coveredBySheet = true }, { store.coveredBySheet = false }),
        ]
        for (label, leave, back) in leaving {
            let stopsBefore = stops(pod)
            let started = store.startChatGPTVoice()
            await waitUntil { session.voice.voiceLive }
            leave()
            let stoppingRightAway = session.voice.voiceStopping
            await waitUntil { !session.voice.voiceActive }
            check(started && stoppingRightAway && !session.voice.voiceActive && session.voice.lastEnd == .confirmed
                  && stops(pod) == stopsBefore + 1 && tap.voiceClaim == nil && !store.chatGPTColumnOnScreen,
                  "G3 voice ends when \(label) (the ChatGPT column leaves the screen; stop confirmed)")
            back()
            await waitUntil { session.messages.map(\.text) == transcript }
        }
        check(store.chatGPTColumnOnScreen && !store.isBrowsing && !store.hidesColumns, "G3 fixture: the ChatGPT column is back on screen")

        // W184 G3 第三輪（修正核對 #2）：放掉語音時一定清掉語音旗標。語音中網頁重載要重新登入、之後又登入好：兩邊的聲波鈕、
        // ［連線］、「新增」都不被一個沒人拿著的旗標擋住。反例：舊寫法只在「送結束成功」時清，連線不是 ready 時直接放掉就漏了。
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        pod.hello(loggedIn: false)
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil { !session.voice.voiceActive }
        pod.hello(loggedIn: true)
        let reloginHold = tap.beginConnectorHold()
        if let reloginHold { tap.endConnectorHold(reloginHold) }
        check(!session.voice.voiceActive && tap.voiceClaim == nil && !tap.voiceOpen && tap.connection == .ready
              && tap.voiceStartBlocker == nil && reloginHold != nil && tap.menuHoldBlocker == nil,
              "G3 voice flags: after the page asked to log in again mid-voice and came back, nothing is blocked by a flag nobody holds")
        // 開了但一直沒在聽（等麥克風權限那種）、結束也沒回：查到沒在聽就放掉，旗標一樣清。
        pod.startsLive = false
        pod.stopMode = .ignore
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceStatus == "還沒開始：請確認麥克風權限" }
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil(3) { !session.voice.voiceActive }
        pod.startsLive = true
        pod.stopMode = .answer
        check(!session.voice.voiceActive && session.voice.lastEnd == .confirmed && !tap.voiceOpen && tap.voiceStartBlocker == nil,
              "G3 voice flags: a voice that never went live and whose stop got no answer still clears the flags once confirmed off")
        await waitUntil { session.messages.map(\.text) == transcript }

        // W184 G3 第三輪（修正核對 #1）：另一邊拿著語音時私訊框送出的字排在語音後面；太久（自測 0.6 秒，正式 20 秒）就不送、
        // 放回輸入框、說一句原因。反例：舊寫法一直「打字中」、永遠送不出去，草稿也已經清掉了。
        let queueSuite = "ai.tatwo.selftest.w184g3.queue.\(UUID().uuidString)"
        if let queueDefaults = UserDefaults(suiteName: queueSuite) {
            let qPod = GlobalDMChatGPTComposerPod()
            let qTap = ChatGPTTap(transport: qPod, connection: .ready, voiceQueueLimit: .milliseconds(600))
            let qSession = ChatGPTConversationSession(tap: qTap)
            let qStore = GlobalDMStore(defaults: queueDefaults, chatGPT: { qSession }, chatGPTAllowed: { true },
                                       chatGPTCatalog: { Just(catalog).eraseToAnyPublisher() }, directKeys: false, recentApps: queueDefaults)
            qStore.attach(model)   // 附件要框準備好（接上 model）才收；同內橫右欄的做法
            qStore.select(.chatGPT)
            qStore.openFloating()
            let qSpace = ChatGPTVoiceMode(tap: qTap, holderNotice: "ChatGPT Space 的語音模式還開著")
            quick(qSpace)
            _ = qSpace.startVoice()
            await waitUntil { qSpace.voiceLive }
            qStore.setDraft("排在語音後面的一句", for: .chatGPT)
            board.clearContents()
            board.setData(png, forType: .png)
            _ = qStore.pasteAttachment(from: board)
            let queuedAttached = qStore.attachments(for: .chatGPT).count == 1
            let queuedSent = qStore.send()
            let queuedWaiting = qSession.isSending && qStore.draft(for: .chatGPT).isEmpty && qStore.attachments(for: .chatGPT).isEmpty
            await waitUntil(3) { !qSession.isSending }
            check(queuedAttached && queuedSent && queuedWaiting && !qSession.isSending && qStore.draft(for: .chatGPT) == "排在語音後面的一句"
                  && qStore.attachments(for: .chatGPT).count == 1 && qStore.notice == "\(ChatGPTTap.queueTimeoutReason)；已放回輸入框"
                  && !qPod.commands.contains { $0["cmd"] as? String == "send" } && !qSession.messages.contains { $0.text == "排在語音後面的一句" },
                  "G3 queued behind the other side's voice: after the time limit the text goes back into the DM's input with one sentence (never sent)"
                  + " [attached=\(queuedAttached) sent=\(queuedSent) waiting=\(queuedWaiting) draft=\(qStore.draft(for: .chatGPT).count) "
                  + "files=\(qStore.attachments(for: .chatGPT).count) notice=\(qStore.notice ?? "-")]")
            qSpace.stopVoice()
            await waitUntil { !qSpace.voiceActive }
            qStore.close()
            queueDefaults.removePersistentDomain(forName: queueSuite)
        } else {
            check(false, "G3 fixture: queue defaults suite")
        }

        // W184 G3 第三輪（修正核對 #6）：強制關掉語音那一頁時，另一邊排著的訊息不丟——網頁重開好了照順序送出。
        // 反例：舊寫法關頁（休眠）時把排著的送出一起判失敗，打好的字就沒了。
        let fPod = GlobalDMChatGPTComposerPod()
        let fTap = ChatGPTTap(transport: fPod, connection: .ready, voiceQueueLimit: .seconds(10))
        let fVoice = ChatGPTVoiceMode(tap: fTap, holderNotice: "私訊框另一欄的語音模式還開著")
        quick(fVoice)
        let fOther = ChatGPTConversationSession(tap: fTap)   // 代表 ChatGPT Space：排在語音後面的一則
        _ = fVoice.startVoice()
        await waitUntil { fVoice.voiceLive }
        fOther.send("強制關頁時排著的一句")
        fPod.stopMode = .ignore
        fVoice.endVoice()
        try? await Task.sleep(for: .milliseconds(100))
        fVoice.stopVoice()   // 正在結束時再按一次＝直接關掉語音那一頁
        await waitUntil(6) { fPod.commands.contains { $0["cmd"] as? String == "send" && $0["text"] as? String == "強制關頁時排著的一句" } }
        let keptAndSent = fPod.commands.contains { $0["cmd"] as? String == "send" && $0["text"] as? String == "強制關頁時排著的一句" }
        fPod.answer("排著的那一句的回答")
        await waitUntil { !fOther.isSending }
        check(fVoice.lastEnd == .forced && fPod.stopCount == 1 && keptAndSent && fOther.messages.last?.text == "排著的那一句的回答",
              "G3 forced close keeps the other side's queued message: it goes out once the voice page is back")

        // 停止沒確認：網頁沒回「結束」、查到還在聽——一直是「正在結束」、停止入口留著、誰都開不了；兩輪都沒確認就關掉語音那一頁
        // （Pod 關了麥克風一定停），私訊框說一聲；有人看著就自己重開。反例：舊寫法送了結束就當作停了。
        let stopsIgnored = stops(pod)
        let podStopsIgnored = pod.stopCount
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        pod.stopMode = .ignore
        _ = store.endChatGPTVoiceForEscape()
        try? await Task.sleep(for: .milliseconds(100))
        check(session.voice.voiceActive && session.voice.voiceStopping && tap.voiceClaim != nil && pod.stopCount == podStopsIgnored
              && !spaceVoice.canStart && !session.canStartVoice,
              "G3 stop not confirmed yet: the voice screen stays (「正在結束」 with its stop entry) and nobody can start voice")
        if let shot = renderSync(pane(), size: paneSize) {
            save(shot, "chatgpt-voice-stopping.png", to: artifacts)
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.voiceMode", "tatwo.dm.voiceMode.stop"],
                     "G3 drawn: while stopping, the voice screen keeps its stop entry")
            shot.close()
        }
        await waitUntil(5) { !session.voice.voiceActive }
        check(!session.voice.voiceActive && session.voice.lastEnd == .forced && stops(pod) == stopsIgnored + 2
              && pod.stopCount == podStopsIgnored + 1 && tap.voiceClaim == nil && session.state == .failed(forcedNotice),
              "G3 stop never answered: after two tries the voice page is closed (Pod stopped, microphone off) and the DM says so")
        pod.stopMode = .answer
        await waitUntil(5) { tap.connection == .ready }
        check(tap.connection == .ready && pod.isRunning, "G3 after closing the voice page the TAP comes back by itself (someone is looking)")

        // 網頁說收到「結束」、但查到還在聽：一樣查兩次，還在聽就關掉語音那一頁。
        pod.stopMode = .keepsLive
        let stopsLive = stops(pod)
        let podStopsLive = pod.stopCount
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil(5) { !session.voice.voiceActive }
        check(session.voice.lastEnd == .forced && stops(pod) == stopsLive + 2 && pod.stopCount == podStopsLive + 1 && tap.voiceClaim == nil,
              "G3 stop acknowledged but the page still listens: checked twice, then the voice page is closed")
        pod.stopMode = .answer
        await waitUntil(5) { tap.connection == .ready }

        // 正在結束時再按一次（結束鈕或 Esc）＝馬上關掉語音那一頁，不等兩輪。
        pod.stopMode = .ignore
        let stopsAgain = stops(pod)
        let podStopsAgain = pod.stopCount
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        _ = store.endChatGPTVoiceForEscape()
        try? await Task.sleep(for: .milliseconds(100))
        let secondPress = store.endChatGPTVoiceForEscape()
        await waitUntil(2) { !session.voice.voiceActive }
        check(secondPress && session.voice.lastEnd == .forced && pod.stopCount == podStopsAgain + 1 && stops(pod) == stopsAgain + 1
              && tap.voiceClaim == nil,
              "G3 pressing 結束 (or Esc) again while stopping closes the voice page right away")
        pod.stopMode = .answer
        await waitUntil(5) { tap.connection == .ready }

        // 語音結束讀回來的逐字稿晚到：中間又送了一則、也回答完了——舊的逐字稿不蓋掉新的回答（版本對不上）。
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        pod.holdsGet = true
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil { pod.heldGet != nil }
        store.setDraft("語音之後的新問題", for: .chatGPT)
        let sentAfterVoice = store.send()
        pod.answer("語音之後的新回答")
        await waitUntil { !session.isSending }
        pod.holdsGet = false
        let answeredBefore = pod.answeredGets
        pod.releaseGet()
        try? await Task.sleep(for: .milliseconds(200))
        check(sentAfterVoice && pod.answeredGets == answeredBefore + 1 && session.messages.last?.text == "語音之後的新回答",
              "G3 revision: a late voice transcript does not replace the newer answer")

        // 新對話開語音：只收 live 時看到的那一則（之後頁面換到別則也不收）。
        session.newConversation()
        pod.voiceConversation = "c-new"
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        pod.voiceConversation = "c-elsewhere"
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil { session.conversationID != nil }
        check(session.conversationID == "c-new" && gets().last == "c-new" && session.messages.map(\.text) == transcript,
              "G3 voice from a new chat: the DM takes the conversation it saw while live, not the one the page moved to")
        // 新對話講完馬上結束（live 時還沒看到編號）：確認停了那一刻網頁所在的那一則回來（語音一直拿著 Pod，別人換不了頁；同原本的 Space）。
        session.newConversation()
        pod.voiceConversation = nil
        _ = store.startChatGPTVoice()
        await waitUntil { session.voice.voiceLive }
        pod.voiceConversation = "c-quick"
        _ = store.endChatGPTVoiceForEscape()
        await waitUntil { session.conversationID != nil }
        check(session.conversationID == "c-quick" && gets().last == "c-quick",
              "G3 voice from a new chat stopped right away: the conversation the page is on when the stop is confirmed comes back")

        // 連線中就按了結束（ChatGPT Space 與私訊框同一套）：晚回來的「開始」再確認結束一次；確認之前語音一直算在這一邊（另一邊搶不到）。
        let slowPod = GlobalDMChatGPTComposerPod()
        slowPod.holdsVoiceStart = true
        let slowTap = ChatGPTTap(transport: slowPod, connection: .ready)
        let voice = ChatGPTVoiceMode(tap: slowTap)
        quick(voice)
        let rival = ChatGPTVoiceMode(tap: slowTap)
        var finishedIn: String?? = .none
        voice.conversation = { "c-space" }
        voice.finished = { finishedIn = .some($0) }
        let slowStarted = voice.startVoice()
        await waitUntil { slowPod.heldVoiceStart != nil }
        voice.stopVoice()
        await waitUntil { !voice.voiceActive }
        check(slowStarted && !voice.voiceActive && finishedIn == .some("c-space") && slowTap.voiceClaim != nil && !rival.canStart && !rival.startVoice(),
              "G3 ChatGPT Space voice: after 結束 while connecting, the voice stays claimed until the late start is settled")
        slowPod.releaseVoiceStart()
        await waitUntil { slowTap.voiceClaim == nil }
        check(slowTap.voiceClaim == nil && !slowPod.live && stops(slowPod) >= 2 && rival.canStart,
              "G3 ChatGPT Space voice: stopping while connecting voids the late start (another confirmed stop), then lets go")

        // MARK: 聽寫（查證：延遲開始可以取消、綁原本的輸入框；停靠框按麥克風先成為 key，不會聽寫進主視窗的輸入框）
        // W184 G3b 追加：私訊框自己的聽寫鈕拿掉了；這幾條守的是 ChatGPT Space 還在用的共用聽寫（ChatGPTDictation：
        // 只聽寫進綁定的輸入框、開始前可以取消、換視窗或視窗不見就不開始），用兩個面板驗，跟私訊框有沒有鈕無關。
        // 兩個看不見的面板：一個當主視窗（有自己的輸入框），一個當停靠框（平常不搶焦點）。都用不啟動 App 的面板，
        // 自測程式不在最前面時也能換 key（換 key 本身才是要驗的）。
        func keyWindow(dock: Bool) -> (GlobalDMPanel, NSTextView) {
            let window = GlobalDMPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.sharingType = .none
            window.ignoresMouseEvents = true
            window.becomesKeyOnlyIfNeeded = dock   // 停靠框平常不搶焦點
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            window.contentView = text
            window.orderFrontRegardless()
            return (window, text)
        }
        let (mainWindow, mainText) = keyWindow(dock: false)
        let (dockPanel, dockText) = keyWindow(dock: true)
        let dictation = ChatGPTDictation()
        dictation.delay = .milliseconds(80)
        var dictated: [NSTextView] = []
        dictation.begin = { dictated.append($0) }
        dictation.textView = dockText
        // 主視窗是 key、它的輸入框是焦點；在停靠框按麥克風。
        mainWindow.makeKey()
        mainWindow.makeFirstResponder(mainText)
        let mainWasKey = mainWindow.isKeyWindow || NSApp.keyWindow === mainWindow
        dictation.start()
        let boxTookKey = (dockPanel.isKeyWindow || NSApp.keyWindow === dockPanel) && dockPanel.firstResponder === dockText
        await waitUntil(1) { !dictated.isEmpty }
        check(mainWasKey && boxTookKey && dictated.count == 1 && dictated.first === dockText,
              "G3 dictation: the mic in the docked box makes the box key and dictates into its own input (never the main window's)"
              + " [main key first=\(mainWasKey) box key=\(boxTookKey) callbacks=\(dictated.count) active=\(NSApp.isActive)]")
        dictated = []
        dictation.start()
        dictation.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        check(dictated.isEmpty && !dictation.isPending, "G3 dictation: closing the box or switching target before it starts cancels it")
        dictation.start()
        mainWindow.makeKey()
        mainWindow.makeFirstResponder(mainText)
        try? await Task.sleep(for: .milliseconds(200))
        check(dictated.isEmpty, "G3 dictation: switching away before it starts does not dictate anywhere")
        dictation.start()
        dockPanel.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(200))
        check(dictated.isEmpty, "G3 dictation: a box that went away never starts dictation")
        for window in [mainWindow, dockPanel] {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // 其他對象的輸入框不變（助理：沒有 ChatGPT 才有的鈕）。
        store.select(.assistant)
        if let shot = renderSync(GlobalDMComposer(store: store, placeholder: "問助理任何事…", isRunning: false, canSend: true),
                                 size: CGSize(width: GlobalDMLayout.box.width, height: 160)) {
            checkIDs(identifiers(in: shot), has: ["tatwo.dm.input", "tatwo.dm.attach", "tatwo.dm.model", "tatwo.dm.send"],
                     lacks: ["tatwo.dm.voice", "tatwo.dm.dictate", "tatwo.dm.tool", "tatwo.dm.chatgptCaption"],
                     "G3 other targets unchanged: the assistant composer has no ChatGPT-only buttons")
            shot.close()
        }

        // 畫出來量：ChatGPT Space 的語音模式鈕照舊 30pt，私訊框的 36pt（同一個元件、兩套尺寸）。
        func slotInk(_ metrics: ChatGPTComposerMetrics) -> CGRect? {
            let view = ChatGPTSendSlot(isSending: false, isEmpty: true, canSend: false, voiceEnabled: true, metrics: metrics,
                                       stop: {}, startVoice: {}, send: {})
                .frame(width: 60, height: 60)
            guard let rendered = renderSync(view, size: CGSize(width: 60, height: 60)) else { return nil }
            defer { rendered.close() }
            return ink(rendered)
        }
        let spaceInk = slotInk(space), dmInk = slotInk(dm)
        check(spaceInk.map { abs($0.width - 30) <= 2 } == true && dmInk.map { abs($0.width - 36) <= 2 } == true,
              "G3 (drawn) the voice-mode button is 30pt in ChatGPT Space and 36pt in the DM"
              + " [ink \(spaceInk.map { "\(Int($0.width))" } ?? "-") / \(dmInk.map { "\(Int($0.width))" } ?? "-")]")
        store.close()
        return results
    }

    /// 讓畫面裡的 `.task`（附件縮圖）跑完：讓出主執行緒一下，再畫幾輪、重截（同一個還開著的視窗）。
    @MainActor static func settle(_ shot: Rendered) async -> Rendered {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<4 {
            shot.host.layoutSubtreeIfNeeded()
            shot.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        guard let bitmap = shot.host.bitmapImageRepForCachingDisplay(in: shot.host.bounds) else { return shot }
        shot.host.cacheDisplay(in: shot.host.bounds, to: bitmap)
        return Rendered(host: shot.host, window: shot.window, bitmap: bitmap, size: shot.size)
    }

    /// 測試圖的顏色（綠；私訊框的畫面裡沒有別的東西是這個顏色）。
    static let fixtureRGB: (Int, Int, Int) = (26, 153, 51)

    /// 畫面裡接近某個顏色的像素數（找縮圖畫出來沒有）。
    @MainActor static func count(_ rendered: Rendered, near rgb: (Int, Int, Int), tolerance: Int = 45) -> Int {
        let rep = rendered.bitmap
        var hits = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(color.redComponent * 255), g = Int(color.greenComponent * 255), b = Int(color.blueComponent * 255)
                if abs(r - rgb.0) <= tolerance && abs(g - rgb.1) <= tolerance && abs(b - rgb.2) <= tolerance { hits += 1 }
            }
        }
        return hits
    }

    /// 測試用的小圖（純綠＋一條白斜線），只在記憶體。
    @MainActor static func fixtureImage(size: Int, type: NSBitmapImageRep.FileType) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return Data()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: CGFloat(fixtureRGB.0) / 255, green: CGFloat(fixtureRGB.1) / 255, blue: CGFloat(fixtureRGB.2) / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.setStroke()
        let line = NSBezierPath()
        line.move(to: .zero)
        line.line(to: NSPoint(x: size, y: size))
        line.lineWidth = 2
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: [:]) ?? Data()
    }
}

/// 記憶體裡的假 Pod（W184 G3）：記下每個指令；送出不自己收尾（answer 才回一段字）；語音開始回「正在聽」（新對話回 voiceConversation）、
/// 結束照 stopMode 回（answer＝停了；ignore＝不回；keepsLive＝回收到但還在聽）；讀對話回一段固定的語音逐字稿（holdsGet＝先扣著）；
/// 停止照樣回執。holdsVoiceStart＝先不回「開始」（測連線中就按結束）。開＝回報 hello（登入了）；關＝網頁沒了（不在聽）。不開網頁、不連外。
@MainActor final class GlobalDMChatGPTComposerPod: FakeTapPod {
    enum StopMode { case answer, ignore, keepsLive }
    init() { super.init(running: true) }
    var voiceConversation: String?
    var holdsVoiceStart = false
    private(set) var heldVoiceStart: String?
    var stopMode = StopMode.answer
    /// 開始時網頁回 live（false＝還在等麥克風權限那種：開了但沒在聽）。
    var startsLive = true
    var holdsGet = false
    private(set) var heldGet: String?
    private(set) var heldGetConversation: String?
    private(set) var answeredGets = 0
    /// W184 G3b 第二輪：讀某一則時回這些訊息（沒設＝固定的語音逐字稿）；讀不到（網頁回錯）；這些代號是 Work 模式開的。
    var getOverrides: [String: [[String: Any]]] = [:]
    var failsGet = false
    /// W184 G3c（GPT-6 審查 #1）：臨時聊天的送出，真的網頁艙會先確認實際送出的內容帶了不存紀錄旗標（kind temporary）再回答；
    /// false＝模擬網頁走了不加旗標的路（沒有確認就回答）。
    var confirmsTemporary = true
    var workConversations: Set<String> = []
    /// 語音那一頁被關掉（Pod 停）的次數。
    private(set) var stopCount = 0
    private(set) var live = false

    override func start() throws {
        try super.start()
        live = false
        emit(["type": "hello", "loggedIn": true])
    }

    override func stop() {
        super.stop()
        live = false
        stopCount += 1
    }

    override func respond(_ command: [String: Any], id: String, cmd: String) {
        switch cmd {
        case "voice" where command["stop"] as? Bool == true:
            switch stopMode {
            case .answer:
                live = false
                result(id, [:])
            case .keepsLive:
                result(id, [:])
            case .ignore:
                break
            }
        case "voice":
            if holdsVoiceStart { heldVoiceStart = id; return }
            live = startsLive
            result(id, ["live": startsLive, "conversationID": command["conversationID"] ?? voiceConversation.map { $0 as Any } ?? NSNull()])
        case "voiceState":
            result(id, ["live": live, "conversationID": voiceConversation.map { $0 as Any } ?? NSNull()])
        case "get":
            if holdsGet {
                heldGet = id
                heldGetConversation = command["conversationID"] as? String
                return
            }
            answerGet(id, conversationID: command["conversationID"] as? String)
        case "stop":
            result(id, ["stopped": true])
        default:
            break
        }
    }

    /// 放行先扣著的「開始」（晚回來的開始）。
    func releaseVoiceStart() {
        guard let id = heldVoiceStart else { return }
        heldVoiceStart = nil
        live = true
        result(id, ["live": true])
    }

    /// 網頁換了一份（重載）報到：loggedIn＝false 是要重新登入，true 是登入好了。
    func hello(loggedIn: Bool) {
        live = false
        emit(["type": "hello", "loggedIn": loggedIn])
    }

    /// 放行先扣著的「讀對話」（晚到的逐字稿）。
    func releaseGet() {
        guard let id = heldGet else { return }
        heldGet = nil
        answerGet(id, conversationID: heldGetConversation)
    }

    private func answerGet(_ id: String, conversationID: String?) {
        answeredGets += 1
        if failsGet {
            emit(["type": "result", "id": id, "ok": false, "message": "讀不到（自測）"])
            return
        }
        let messages = conversationID.flatMap { getOverrides[$0] }
            ?? [["id": "v1", "role": "user", "text": "（語音）今天天氣如何"], ["id": "v2", "role": "assistant", "text": "晴天，最高 27 度。"]]
        var data: [String: Any] = ["messages": messages, "parents": [String: Any]()]
        if let conversationID, workConversations.contains(conversationID) { data["work"] = true }
        result(id, data)
    }

    /// 假裝 ChatGPT 回了一段字（最後一則送出）；conversationID＝回報的對話代號（新對話建出來的、或接著的那一則）。
    func answer(_ text: String, conversationID: String = "c-dm") {
        guard let send = commands.last(where: { $0["cmd"] as? String == "send" }), let id = send["id"] as? String else { return }
        if send["temporary"] as? Bool == true, confirmsTemporary { emit(["type": "stream", "id": id, "kind": "temporary"]) }
        emit(["type": "stream", "id": id, "kind": "conversation", "conversationID": conversationID])
        emit(["type": "stream", "id": id, "kind": "text", "messageID": "fixture-reply", "full": text])
        emit(["type": "stream", "id": id, "kind": "finished"])
    }

    private func result(_ id: String, _ data: [String: Any]) {
        emit(["type": "result", "id": id, "ok": true, "data": data])
    }
}

/// W184 G3 第三輪自測：收附件的 sink 收到什麼（加了哪些、說了哪些不收）。
@MainActor final class GlobalDMChatGPTSinkRecorder {
    private(set) var added: [(data: Data, name: String, mime: String)] = []
    private(set) var failed: [String] = []
    var sink: ChatGPTSpaceModel.AttachmentSink {
        ChatGPTSpaceModel.AttachmentSink(add: { [weak self] data, name, mime in self?.added.append((data, name, mime)) },
                                         fail: { [weak self] message in self?.failed.append(message) })
    }
}
#endif
