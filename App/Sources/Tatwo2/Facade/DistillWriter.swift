import Foundation

/// W180 E4：/蒸餾 的寫入點都在這裡：技能根的 `<name>/SKILL.md`、入口的 `note/蒸餾/<name>.md`、GBrain 頁。
/// 跟 EngineMemoryLinks 同一套封存做法：動任何東西之前先把同名舊檔整份封存到入口 `archive/distill-<時間>/`，
/// 寫 manifest.json 與「還原.md」，寫完逐字讀回；還原時新版也封存、舊版放回。入口 skillet.md 從來不是去處。
struct DistillWriterRoots: Sendable, Equatable {
    /// 技能根（PluginsSource 掃描的第一個根；各引擎的 skills 都連到它）。
    let skills: URL
    /// 入口（清單、SOP 寫到 note/蒸餾/，封存在 archive/）。
    let entry: URL

    var notes: URL { entry.appendingPathComponent("note", isDirectory: true).appendingPathComponent("蒸餾", isDirectory: true) }
    var archive: URL { entry.appendingPathComponent("archive", isDirectory: true) }

    static func current() -> DistillWriterRoots {
        DistillWriterRoots(skills: ManagedSkills.defaultRoot(), entry: TatwoEntry().root)
    }
}

/// 一次要在主設備跑的寫入或還原（在背景執行緒做檔案與 GBrain 的事）。
struct DistillWriteJob: Sendable {
    enum Mode: String, Sendable { case apply, restore }
    let mode: Mode
    let plan: DistillWritePlan
    let content: String
    let roots: DistillWriterRoots
    /// 寫進封存紀錄的設備名稱（只給人看）。
    let device: String
    let threadID: UUID?
    let planID: UUID?
    let submissionID: UUID?
    /// 還原時要用的封存資料夾。
    let archivePath: String?
    /// GBrain adapter 定義（JSON）；不是 GBrain 就是 nil。
    let gbrainDefinition: Data?
}

enum DistillWriteOutcome: Sendable, Equatable {
    /// 寫好並逐字讀回（還原：舊版已放回）。
    case done(lines: [String], archivePath: String?)
    /// 什麼都沒寫（例如預覽後原檔被改過）；畫布可以改完重新預覽。
    case cleanFailure(String)
    /// 可能寫了一部分；請先查目的地，不自動重送。
    case unconfirmed(String)
}

/// 封存資料夾裡的紀錄；還原照這份做。
struct DistillManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let path: String
        let existed: Bool
        /// 舊版在封存資料夾裡的相對路徑；新建的是 nil。
        let archived: String?
        let baseSHA: String?
        let newSHA: String
        var restoredAway: String?
    }
    var version = 1
    let createdAt: Date
    let device: String
    let output: DistillOutputKind
    let name: String
    let threadID: UUID?
    let planID: UUID?
    /// 這次寫入（畫布上那一次「確認寫入」）的編號；還原時要對得上才動（別台、別張畫布不能撤掉這次寫入）。
    var submissionID: UUID?
    var entries: [Entry]
    var writtenAt: Date?
    var restoredAt: Date?
    /// 封存建好了、但送出寫入之前就停下（什麼都沒寫）的原因。
    var abandoned: String?
}

enum DistillWriter {
    /// App 內建（受管技能、入口文件的連結）的名稱，/蒸餾 不能用。
    static let reservedSkillNames: Set<String> = ["tatwo-ultrawork", "skillet"]
    static let archivePrefix = "distill-"
    private static let lock = NSLock()

    // MARK: 預覽

    /// 寫到哪、會不會先封存同名舊檔。檢查不過就丟出給人看的原因（什麼都沒寫）。
    static func preview(output: DistillOutputKind, content: String, planID: UUID, roots: DistillWriterRoots) throws -> DistillWritePlan {
        let problems = DistillCanvas.problems(content, output: output)
        guard problems.isEmpty else { throw DistillCanvas.Failure(reason: problems.joined(separator: "\n")) }
        let title = DistillCanvas.title(for: content)
        let newSHA = DistillCanvas.sha256(content)
        let name: String
        let target: DistillTarget
        switch output {
        case .skill:
            name = DistillCanvas.skillFrontmatter(content)?.name ?? ""
            let folder = roots.skills.appendingPathComponent(name, isDirectory: true)
            target = try fileTarget(folder.appendingPathComponent("SKILL.md"), newSHA: newSHA, guardedFolder: folder)
        case .checklist, .sop:
            name = DistillCanvas.noteName(for: title, id: planID)
            if let problem = DistillCanvas.noteNameProblem(name) {
                throw DistillCanvas.Failure(reason: "筆記檔名不合法：\(problem)")
            }
            target = try fileTarget(roots.notes.appendingPathComponent(name + ".md"), newSHA: newSHA, guardedFolder: nil)
        case .gbrain:
            name = DistillCanvas.slug(for: title, id: planID)
            target = DistillTarget(path: "gbrain:" + name, action: .create, newSHA: newSHA, baseSHA: nil)
        }
        return DistillWritePlan(output: output, name: name, title: title, targets: [target], contentSHA: newSHA)
    }

    private static func fileTarget(_ file: URL, newSHA: String, guardedFolder: URL?) throws -> DistillTarget {
        let fm = FileManager.default
        for url in [guardedFolder, file].compactMap({ $0 }) where (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw DistillCanvas.Failure(reason: "同名的「\(url.lastPathComponent)」是捷徑，App 不改它；請換個名字。")
        }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: file.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw DistillCanvas.Failure(reason: "同名的「\(file.lastPathComponent)」是資料夾；請換個名字。") }
            let data = try Data(contentsOf: file)
            return DistillTarget(path: file.path, action: .replace, newSHA: newSHA, baseSHA: DistillCanvas.sha256(data))
        }
        return DistillTarget(path: file.path, action: .create, newSHA: newSHA, baseSHA: nil)
    }

    // MARK: 寫入與還原

    static func perform(_ job: DistillWriteJob, now: Date = Date()) -> DistillWriteOutcome {
        lock.lock(); defer { lock.unlock() }
        switch job.mode {
        case .apply: return apply(job, now: now)
        case .restore: return restore(job, now: now)
        }
    }

    /// 只准寫（與還原）技能根的 `<name>/SKILL.md`、入口 `note/蒸餾/*.md`；封存紀錄被改過也照這個擋。
    private static func allowedFile(_ path: String, output: DistillOutputKind, roots: DistillWriterRoots) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !url.pathComponents.contains(".."), url.standardizedFileURL.path == url.path else { return false }
        switch output {
        case .skill:
            return url.lastPathComponent == "SKILL.md"
                && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                    == roots.skills.standardizedFileURL.path
        case .checklist, .sop:
            return url.pathExtension == "md"
                && url.deletingLastPathComponent().standardizedFileURL.path == roots.notes.standardizedFileURL.path
        case .gbrain:
            return false
        }
    }

    private static func apply(_ job: DistillWriteJob, now: Date) -> DistillWriteOutcome {
        let fm = FileManager.default
        let plan = job.plan
        let data = Data(job.content.utf8)
        guard DistillCanvas.sha256(data) == plan.contentSHA, plan.targets.allSatisfy({ $0.newSHA == plan.contentSHA }) else {
            return .cleanFailure("內容跟預覽不一樣；請重新預覽。")
        }
        let files = plan.targets.filter { !$0.path.hasPrefix("gbrain:") }
        // 1. 寫入鎖內再比一次原檔：預覽之後有人改過（或新建了同名檔）就不寫。
        for target in files {
            guard allowedFile(target.path, output: plan.output, roots: job.roots) else {
                return .cleanFailure("寫入位置不在技能根或 note/蒸餾/；沒有寫入。")
            }
            let url = URL(fileURLWithPath: target.path)
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
                || (try? fm.destinationOfSymbolicLink(atPath: url.deletingLastPathComponent().path)) != nil {
                return .cleanFailure("同名的「\(url.lastPathComponent)」變成捷徑了；沒有寫入。")
            }
            let current = try? Data(contentsOf: url)
            guard current.map({ DistillCanvas.sha256($0) }) == target.baseSHA else {
                return .cleanFailure("預覽之後「\(url.lastPathComponent)」被改過（或多了同名檔）；沒有寫入，請重新預覽。")
            }
        }
        var definition: [String: Any]?
        if plan.output == .gbrain {
            guard let raw = job.gbrainDefinition,
                  let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
                return .cleanFailure("GBrain 不可用；沒有寫入。")
            }
            definition = parsed
        }
        // 2. 封存（任何寫入之前）：舊版原檔、manifest.json、還原.md。
        let archive: URL
        var manifest = DistillManifest(createdAt: now, device: job.device, output: plan.output, name: plan.name,
                                       threadID: job.threadID, planID: job.planID, submissionID: job.submissionID, entries: [])
        do {
            archive = try makeArchive(job.roots, now: now)
            for (index, target) in files.enumerated() {
                let url = URL(fileURLWithPath: target.path)
                var archived: String?
                if target.baseSHA != nil {
                    let relative = "files/\(index + 1)-\(url.lastPathComponent)"
                    try writePrivate(try Data(contentsOf: url), to: archive.appendingPathComponent(relative))
                    archived = relative
                }
                manifest.entries.append(.init(path: target.path, existed: target.baseSHA != nil, archived: archived,
                                              baseSHA: target.baseSHA, newSHA: target.newSHA, restoredAway: nil))
            }
            try save(manifest, archive)
            try writeRestoreNote(manifest, archive: archive, plan: plan)
        } catch {
            return .cleanFailure("封存沒建好，所以沒有寫入：\(error.localizedDescription)")
        }
        // 3. 寫入並逐字讀回。從這裡開始的錯誤都可能已經寫了一部分。
        var lines: [String] = []
        do {
            for target in files {
                let url = URL(fileURLWithPath: target.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                guard try Data(contentsOf: url) == data else {
                    return .unconfirmed("已嘗試寫入 \(target.path)，但讀回不一致；請先檢查，不會自動重送。封存：\(archive.path)")
                }
                lines.append("已寫入並逐字讀回：\(target.path)")
                if target.baseSHA != nil { lines.append("同名舊版已先封存：\(archive.path)") }
            }
            if let definition {
                let index = files.count + 1
                let slug = plan.name
                do {
                    try DistillGBrainClient.put(slug: slug, title: plan.title, body: job.content, definition: definition) { old in
                        // 同名舊頁整份封存（正文、標題、frontmatter、tags、GBrain 的完整原文），還原時照這份放回。
                        var archived: String?
                        var baseSHA: String?
                        if let old {
                            guard let body = old["compiled_truth"] as? String, JSONSerialization.isValidJSONObject(old) else {
                                throw DistillCanvas.Failure(reason: "GBrain 同名舊頁讀不出正文；沒有寫入。")
                            }
                            let relative = "files/\(index)-gbrain-page.json"
                            try writePrivate(JSONSerialization.data(withJSONObject: old, options: [.prettyPrinted, .sortedKeys]),
                                             to: archive.appendingPathComponent(relative))
                            archived = relative
                            baseSHA = DistillCanvas.sha256(body)
                        }
                        manifest.entries.append(.init(path: "gbrain:" + slug, existed: old != nil, archived: archived,
                                                      baseSHA: baseSHA, newSHA: plan.contentSHA, restoredAway: nil))
                        try save(manifest, archive)
                    }
                } catch let notSent as DistillGBrainClient.NotSent {
                    // 送出寫入之前就停了：GBrain 沒被改。封存紀錄記下原因（狀態查詢才不會當成未確認）。
                    manifest.abandoned = notSent.reason
                    try? save(manifest, archive)
                    return .cleanFailure("GBrain 沒有寫入：\(notSent.reason)")
                } catch {
                    return .unconfirmed("GBrain：\(error.localizedDescription)；結果未確認，請先查頁面，不會自動重送。封存：\(archive.path)")
                }
                lines.append("GBrain 已寫入並逐字讀回：\(slug)")
                if manifest.entries.last?.existed == true { lines.append("同名舊頁已先封存：\(archive.path)") }
                else { lines.append("GBrain 上原本沒有這頁（新建的頁，還原時 App 不刪）") }
            }
            manifest.writtenAt = now
            try save(manifest, archive)
        } catch {
            return .unconfirmed("寫入沒有確認：\(error.localizedDescription)；請先查 \(files.first?.path ?? plan.name)，不會自動重送。封存：\(archive.path)")
        }
        return .done(lines: lines, archivePath: archive.path)
    }

    /// 把這次寫入撤回：新版搬進封存（不刪），舊版放回；新建的就只搬走新版。
    /// 先全部檢查過才動手：封存要是這張畫布（或這台送來的那一次）寫的、路徑要在技能根或 note/蒸餾/ 裡、
    /// 寫入後沒被改過、GBrain 舊頁有封存而且 GBrain 可用。任何一項不過就什麼都不動（不記「已還原」）。
    private static func restore(_ job: DistillWriteJob, now: Date) -> DistillWriteOutcome {
        let fm = FileManager.default
        guard let path = job.archivePath else { return .cleanFailure("找不到這次寫入的封存；沒有還原。") }
        let archive = URL(fileURLWithPath: path).standardizedFileURL
        guard archive.lastPathComponent.hasPrefix(archivePrefix),
              archive.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                == job.roots.archive.resolvingSymlinksInPath().standardizedFileURL.path else {
            return .cleanFailure("封存位置不對；沒有還原。")
        }
        guard var manifest = readManifest(archive) else { return .cleanFailure("封存紀錄讀不到；沒有還原。") }
        // 只認這次寫入：同一張畫布、同一條（或同樣沒有討論串）、同一次確認寫入。
        guard let planID = job.planID, manifest.planID == planID, manifest.threadID == job.threadID,
              let submissionID = job.submissionID, manifest.submissionID == submissionID else {
            return .cleanFailure("這份封存不是這張畫布這次寫的；沒有還原。")
        }
        guard manifest.restoredAt == nil else { return .cleanFailure("這次寫入已經還原過了。") }
        guard manifest.writtenAt != nil else { return .cleanFailure("這次寫入沒有寫完，沒有可以還原的新版；請看 \(archive.path)/還原.md。") }
        // 1. 先全部檢查。
        var gbrainPages: [Int: [String: Any]] = [:]
        var definition: [String: Any]?
        for (index, entry) in manifest.entries.enumerated() {
            if let archived = entry.archived, archived.range(of: #"^files/[^/]+$"#, options: .regularExpression) == nil {
                return .cleanFailure("封存紀錄被改過（舊版位置不對）；沒有還原。")
            }
            if entry.path.hasPrefix("gbrain:") {
                guard entry.existed else {
                    return .cleanFailure("GBrain 的 \(entry.path.dropFirst("gbrain:".count)) 是這次新建的；App 不刪 GBrain 頁，要撤掉請到 GBrain 手動處理。")
                }
                guard let archived = entry.archived,
                      let raw = try? Data(contentsOf: archive.appendingPathComponent(archived)),
                      let page = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                      page["compiled_truth"] is String else {
                    return .cleanFailure("封存裡找不到 GBrain 舊頁的完整內容；沒有還原。")
                }
                guard let data = job.gbrainDefinition,
                      let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .cleanFailure("GBrain 不可用；沒有還原（連上 GBrain 後再按還原）。")
                }
                gbrainPages[index] = page
                definition = parsed
                continue
            }
            guard allowedFile(entry.path, output: manifest.output, roots: job.roots) else {
                return .cleanFailure("封存紀錄裡的路徑不在技能根或 note/蒸餾/；沒有還原。")
            }
            let url = URL(fileURLWithPath: entry.path)
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
                || (try? fm.destinationOfSymbolicLink(atPath: url.deletingLastPathComponent().path)) != nil {
                return .cleanFailure("「\(url.lastPathComponent)」變成捷徑了；沒有還原。")
            }
            let current = try? Data(contentsOf: url)
            guard current.map({ DistillCanvas.sha256($0) }) == entry.newSHA else {
                let where_ = entry.archived.map { archive.appendingPathComponent($0).path } ?? "（新建的，沒有舊版）"
                return .cleanFailure("寫入後「\(url.lastPathComponent)」又被改過；為了不蓋掉新改的內容，沒有還原。舊版在：\(where_)")
            }
            if entry.existed {
                guard let archived = entry.archived,
                      let original = try? Data(contentsOf: archive.appendingPathComponent(archived)),
                      DistillCanvas.sha256(original) == entry.baseSHA else {
                    return .cleanFailure("封存裡的舊版對不上紀錄；沒有還原。")
                }
            }
        }
        // 2. 動手。從這裡開始的錯誤都可能已經改了一部分。
        var lines: [String] = []
        do {
            for (index, entry) in manifest.entries.enumerated() {
                let away = "restored/\(index + 1)-"
                if let page = gbrainPages[index], let definition {
                    let slug = String(entry.path.dropFirst("gbrain:".count))
                    let awayPath = away + "gbrain-page.json"
                    do {
                        try DistillGBrainClient.restore(slug: slug, archived: page, writtenSHA: entry.newSHA, definition: definition) { current in
                            // 現頁（這次寫的版本）先整份存進封存，再放回舊頁。
                            try writePrivate(JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]),
                                             to: archive.appendingPathComponent(awayPath))
                        }
                    } catch let notSent as DistillGBrainClient.NotSent where lines.isEmpty {
                        return .cleanFailure("GBrain 沒有還原：\(notSent.reason)")
                    }
                    manifest.entries[index].restoredAway = awayPath
                    lines.append("GBrain 舊頁已放回（標題、frontmatter、tags 一起）：\(slug)")
                    continue
                }
                let url = URL(fileURLWithPath: entry.path)
                let awayPath = away + url.lastPathComponent
                let awayURL = archive.appendingPathComponent(awayPath)
                try fm.createDirectory(at: awayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: awayURL)
                manifest.entries[index].restoredAway = awayPath
                if entry.existed, let archived = entry.archived {
                    let original = try Data(contentsOf: archive.appendingPathComponent(archived))
                    try original.write(to: url, options: .atomic)
                    guard try DistillCanvas.sha256(Data(contentsOf: url)) == entry.baseSHA else {
                        return .unconfirmed("舊版放回 \(entry.path) 後讀回不一致；請手動檢查。封存：\(archive.path)")
                    }
                    lines.append("舊版已放回：\(entry.path)")
                } else {
                    let folder = url.deletingLastPathComponent()
                    if manifest.output == .skill, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                        try? fm.removeItem(at: folder)   // 只收空資料夾
                    }
                    lines.append("新寫的已撤掉（搬進封存）：\(entry.path)")
                }
            }
            manifest.restoredAt = now
            try save(manifest, archive)
            let note = archive.appendingPathComponent("還原.md")
            if let handle = try? FileHandle(forWritingTo: note) {
                handle.seekToEndOfFile()
                handle.write(Data("\n已還原（\(stamp(now))）：新版搬到本資料夾 restored/，舊版放回原處。\n".utf8))
                try? handle.close()
            }
        } catch {
            try? save(manifest, archive)
            return .unconfirmed("還原沒有做完：\(error.localizedDescription)；請看 \(archive.path)/還原.md 手動處理。")
        }
        lines.append("這次的新版留在：\(archive.path)/restored")
        return .done(lines: lines, archivePath: archive.path)
    }

    /// 讀一份封存紀錄（還原、狀態查詢用）。
    static func readManifest(_ archive: URL) -> DistillManifest? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: archive.appendingPathComponent("manifest.json")) else { return nil }
        return try? decoder.decode(DistillManifest.self, from: raw)
    }

    /// 已配對設備送來、沒有討論串的那次寫入（用 submissionID 找）：在封存裡找它的紀錄。沒找到是 nil。
    static func recorded(submissionID: UUID, planID: UUID, roots: DistillWriterRoots) -> (manifest: DistillManifest, archive: URL)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: roots.archive.path) else { return nil }
        for name in names.sorted().reversed() where name.hasPrefix(archivePrefix) {
            let archive = roots.archive.appendingPathComponent(name, isDirectory: true)
            if let manifest = readManifest(archive), manifest.submissionID == submissionID, manifest.planID == planID,
               manifest.threadID == nil {
                return (manifest, archive)
            }
        }
        return nil
    }

    // MARK: 封存

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func makeArchive(_ roots: DistillWriterRoots, now: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: roots.archive, withIntermediateDirectories: true)
        let base = archivePrefix + stamp(now)
        for attempt in 0..<100 {
            let url = roots.archive.appendingPathComponent(attempt == 0 ? base : "\(base)-\(attempt + 1)", isDirectory: true)
            if fm.fileExists(atPath: url.path) { continue }
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }
        throw DistillCanvas.Failure(reason: "封存資料夾建不起來")
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func save(_ manifest: DistillManifest, _ archive: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writePrivate(try encoder.encode(manifest), to: archive.appendingPathComponent("manifest.json"))
    }

    private static func writeRestoreNote(_ manifest: DistillManifest, archive: URL, plan: DistillWritePlan) throws {
        var text = "# /蒸餾 寫入封存（\(stamp(manifest.createdAt))）\n\n"
        text += "設備：\(manifest.device)\n類型：\(plan.output.label)；名稱：\(plan.name)\n\n這次寫入：\n"
        for entry in manifest.entries {
            text += "- \(entry.path)（\(entry.existed ? "取代；舊版在本資料夾 \(entry.archived ?? "")" : "新建")）\n"
        }
        if plan.output == .gbrain { text += "- GBrain：\(plan.name)（同名舊頁若存在，會先存到 files/）\n" }
        text += "\n還原方法：在 TATWO OS 那張 /蒸餾 畫布按「還原」。\n"
        text += "手動：把新檔搬進本資料夾（不要直接刪），再把 files/ 裡的舊版放回原路徑；新建的檔沒有舊版，搬走即可。\n"
        try writePrivate(Data(text.utf8), to: archive.appendingPathComponent("還原.md"))
    }
}
