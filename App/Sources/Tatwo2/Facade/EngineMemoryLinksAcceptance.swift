#if DEBUG
import Darwin
import Foundation

/// W179 M 房自測：`TATWO2_SELFTEST=w179memlinks`。
/// 全部在假 HOME 底下自己造的資料夾裡跑（真 HOME 直接拒跑），不碰真的 ~/.claude、~/.codex、入口。
enum EngineMemoryLinksAcceptance {
    final class Checker {
        var failures = 0
        func callAsFunction(_ condition: Bool, _ label: String) {
            if condition { print("W179MEMLINKS PASS \(label)") } else { failures += 1; print("W179MEMLINKS FAIL \(label)") }
        }
    }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let check = Checker()
        let environment = ProcessInfo.processInfo.environment
        guard let fakeHome = environment["HOME"], !fakeHome.isEmpty, let account = getpwuid(getuid()),
              let realHome = account.pointee.pw_dir,
              URL(fileURLWithPath: fakeHome).standardizedFileURL.path != URL(fileURLWithPath: String(cString: realHome)).standardizedFileURL.path
        else {
            print("W179MEMLINKS FAIL isolated HOME required")
            print("W179MEMLINKS SUMMARY failures=1")
            return 1
        }
        let base = URL(fileURLWithPath: fakeHome).appendingPathComponent("w179memlinks-" + UUID().uuidString.prefix(8))
        do {
            try unitChecks(check)
            try linkAndRestore(base: base, check)
            try secondaryWithoutPrimary(base: base, check)
            try manualLeadState(base: base, check)
            try leadCodexImport(base: base, check)
            try partialLinkRestore(base: base, check)
            try? FileManager.default.removeItem(at: base)
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        print("W179MEMLINKS SUMMARY failures=\(check.failures)")
        return check.failures == 0 ? 0 : 1
    }

    // MARK: 小零件：settings 單一鍵、TOML 單一行、索引上限

    static func unitChecks(_ check: Checker) throws {
        let compact = try JSONMembers.setting("autoMemoryDirectory", rawValue: "\"~/m\"", in: Data("{\"a\":1}".utf8))
        check(String(decoding: compact, as: UTF8.self) == "{\"a\":1, \"autoMemoryDirectory\":\"~/m\"}", "json compact insert keeps separator")
        let empty = try JSONMembers.setting("autoMemoryDirectory", rawValue: "\"~/m\"", in: Data("{}\n".utf8))
        check(((try? JSONSerialization.jsonObject(with: empty)) as? [String: Any])?["autoMemoryDirectory"] as? String == "~/m",
              "json empty object insert")
        let replaced = try JSONMembers.setting("autoMemoryDirectory", rawValue: "\"/new\"",
                                               in: Data("{\n  \"autoMemoryDirectory\": \"/old\",\n  \"b\": [1, {\"c\": \"}\"}]\n}\n".utf8))
        check(String(decoding: replaced, as: UTF8.self) == "{\n  \"autoMemoryDirectory\": \"/new\",\n  \"b\": [1, {\"c\": \"}\"}]\n}\n",
              "json existing key replaced in place")
        let crlf = "{\r\n  \"a\": 1\r\n}\r\n"
        let crlfOut = try JSONMembers.setting("k", rawValue: "true", in: Data(crlf.utf8))
        check(String(decoding: crlfOut, as: UTF8.self) == "{\r\n  \"a\": 1,\r\n  \"k\": true\r\n}\r\n", "json CRLF insert")
        let removed = try JSONMembers.removing("k", in: crlfOut)
        check(String(decoding: removed, as: UTF8.self) == crlf, "json remove restores bytes")
        var rejected = false
        do { _ = try JSONMembers.setting("k", rawValue: "1", in: Data("{\"a\": 1,}".utf8)) } catch { rejected = true }
        check(rejected, "json malformed settings refused")
        check(JSONMembers.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"", "json value escaping")

        let appended = try TOMLMemories.disableGenerate(Data("model = \"x\"".utf8))
        check(appended?.kind == "appended" && String(decoding: appended!.data, as: UTF8.self) == "model = \"x\"\n\n[memories]\ngenerate_memories = false\n",
              "toml append section when missing")
        let inserted = try TOMLMemories.disableGenerate(Data("[memories]\nuse_memories = true\n".utf8))
        check(inserted?.kind == "inserted" && String(decoding: inserted!.data, as: UTF8.self) == "[memories]\ngenerate_memories = false\nuse_memories = true\n",
              "toml insert under existing section")
        let dotted = try TOMLMemories.disableGenerate(Data("memories.generate_memories = true # x\n[other]\ngenerate_memories = true\n".utf8))
        check(dotted?.kind == "replaced" && String(decoding: dotted!.data, as: UTF8.self) == "memories.generate_memories = false # x\n[other]\ngenerate_memories = true\n",
              "toml dotted top-level key, other table untouched")
        let unchanged = try TOMLMemories.disableGenerate(Data("[memories]\ngenerate_memories = false\n".utf8))
        check(unchanged == nil, "toml already false is no-op")
        check(TOMLMemories.value(of: "generate_memories", in: "[x]\ngenerate_memories = false\n") == nil, "toml ignores other tables")

        // [features] memories：Codex 記憶功能的總開關，預設關
        func text(_ edit: TOMLMemories.Edit?) -> String { edit.map { String(decoding: $0.data, as: UTF8.self) } ?? "" }
        let featureAdded = try TOMLMemories.enableFeature(Data("model = \"x\"\n".utf8))
        check(featureAdded?.kind == "appended" && text(featureAdded) == "model = \"x\"\n\n[features]\nmemories = true\n",
              "toml features table appended when missing")
        check(try TOMLMemories.enableFeature(Data("[features]\nmemories = true\n".utf8)) == nil, "toml features already on is no-op")
        let featureFlipped = try TOMLMemories.enableFeature(Data("[features]\nother = true\nmemories = false # off\n".utf8))
        check(featureFlipped?.kind == "replaced" && text(featureFlipped) == "[features]\nother = true\nmemories = true # off\n",
              "toml features false flipped in place")
        let featureDotted = try TOMLMemories.enableFeature(Data("features.other = true\n[x]\ny = 1\n".utf8))
        check(featureDotted?.kind == "inserted" && text(featureDotted) == "features.other = true\nfeatures.memories = true\n[x]\ny = 1\n",
              "toml dotted features table gets a dotted line")

        // memories 表已經用別的寫法定義過：不能再加第二個 [memories]（Codex 會讀不了設定）
        let dottedOther = try TOMLMemories.disableGenerate(Data("memories.use_memories = true\n\n[x]\ny = 1\n".utf8))
        check(dottedOther?.kind == "inserted"
              && text(dottedOther) == "memories.use_memories = true\nmemories.generate_memories = false\n\n[x]\ny = 1\n",
              "toml dotted memories table: no second [memories] header")
        func refused(_ config: String) -> Bool {
            do { _ = try TOMLMemories.disableGenerate(Data(config.utf8)); return false } catch { return true }
        }
        check(refused("memories = { use_memories = true }\n"), "toml inline memories table refused")
        check(refused("[memories]\ngenerate_memories = \"yes\"\n"), "toml non-boolean value refused (no duplicate key)")
        check(refused("memories.use_memories = true\n[memories]\ngenerate_memories = true\n"), "toml table defined twice refused")
        let multiline = "instructions = \"\"\"\n[memories]\ngenerate_memories = true\n\"\"\"\n"
        let skipped = try TOMLMemories.disableGenerate(Data(multiline.utf8))
        check(skipped?.kind == "appended" && text(skipped) == multiline + "\n[memories]\ngenerate_memories = false\n",
              "toml multi-line string content is not config")

        // 接上後又被改過：兩行都撤回，別人加的留著
        if let feature = try TOMLMemories.enableFeature(Data("model = \"x\"\n".utf8)),
           let generate = try TOMLMemories.disableGenerate(feature.data) {
            let record = EngineMemoryManifest.Codex(configPath: "", configExisted: true, edit: generate.kind, originalLine: generate.originalLine,
                                                    writtenLine: generate.writtenLine, writtenSHA: nil, summaryPath: "", summaryExisted: false,
                                                    memoriesExisted: false, summaryWritten: false, restoredAt: nil,
                                                    featureEdit: feature.kind, featureOriginalLine: feature.originalLine,
                                                    featureWrittenLine: feature.writtenLine)
            let edited = String(decoding: generate.data, as: UTF8.self) + "# 使用者後來加的\n"
            let undone = TOMLMemories.undo(Data(edited.utf8), record: record).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check(TOMLMemories.value(of: "generate_memories", in: undone) == nil
                  && TOMLMemories.value(of: "memories", table: "features", in: undone) == nil
                  && undone.hasPrefix("model = \"x\"\n") && undone.hasSuffix("# 使用者後來加的\n"), "toml undo removes both our lines only")
        } else {
            check(false, "toml undo removes both our lines only")
        }
    }

    // MARK: 主設備：接上 → 檢查 → 還原 → 逐位元比對

    static func linkAndRestore(base: URL, _ check: Checker) throws {
        let fm = FileManager.default
        let home = base.appendingPathComponent("home").path
        let entryRoot = URL(fileURLWithPath: home).appendingPathComponent("AI/TATWO OS", isDirectory: true)
        try fm.createDirectory(at: entryRoot, withIntermediateDirectories: true)
        let paths = EngineMemoryPaths(home: home, entryRoot: entryRoot)
        let now = Date()
        let stamp = EngineMemoryLinks.dayStamp(now)

        // 兩個 Claude 專案記憶（同名不同內容、同名同內容、超過 200 行的索引、索引沒列到的檔）、一個空的、一個已經是連結的
        let encodedHome = String(home.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let projects = URL(fileURLWithPath: paths.claudeProjects)
        let projectA = projects.appendingPathComponent(encodedHome).appendingPathComponent("memory")
        let projectB = projects.appendingPathComponent(encodedHome + "-work-shop").appendingPathComponent("memory")
        let projectEmpty = projects.appendingPathComponent(encodedHome + "-empty").appendingPathComponent("memory")
        let projectLinked = projects.appendingPathComponent(encodedHome + "-linked").appendingPathComponent("memory")
        let elsewhere = base.appendingPathComponent("elsewhere-memory")
        for dir in [projectA, projectB, projectEmpty, elsewhere, projectLinked.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: projectLinked, withDestinationURL: elsewhere)
        try write("---\nname: linked only\n---\n不該被匯入\n", elsewhere.appendingPathComponent("linked-only.md"))
        func note(_ name: String, _ body: String) -> String {
            "---\nname: \(name)\ndescription: \(body)\nmetadata:\n  type: project\n---\n\n\(body)\n"
        }
        var indexA = "# Memory Index\n\n"
        for i in 0..<230 {
            try write(note("note \(i)", "第 \(i) 條測試記憶"), projectA.appendingPathComponent("note-\(i).md"))
            indexA += "- [note \(i)](note-\(i).md) — 第 \(i) 條\n"
        }
        try write(note("shared", "A 的版本"), projectA.appendingPathComponent("shared.md"))
        try write(note("same", "兩邊一樣"), projectA.appendingPathComponent("same.md"))
        indexA += "- [shared](shared.md) — A\n- [same](same.md) — same\n"
        try write(indexA, projectA.appendingPathComponent("MEMORY.md"))
        try write(note("shared", "B 的版本"), projectB.appendingPathComponent("shared.md"))
        try write(note("same", "兩邊一樣"), projectB.appendingPathComponent("same.md"))
        try write(note("b only", "只有 B 有"), projectB.appendingPathComponent("b-only.md"))
        try write(note("unindexed", "索引沒列到"), projectB.appendingPathComponent("unindexed.md"))
        // 看起來含權杖的記憶（假的，執行時才拼起來）：不進記憶的 git
        try write(note("leaky", "不小心貼了權杖") + "api" + "_key = " + String(repeating: "Q", count: 20) + "\n",
                  projectB.appendingPathComponent("leaky.md"))
        try write("# Memory Index\n\n- [shared](shared.md) — B\n- [same](same.md) — same\n- [b only](b-only.md) — B\n",
                  projectB.appendingPathComponent("MEMORY.md"))

        let settingsText = "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls:*)\"\n    ]\n  },\n  \"model\": \"opus\",\n  \"env\": {\n    \"EXAMPLE_FLAG\": \"1\"\n  }\n}\n"
        try write(settingsText, URL(fileURLWithPath: paths.claudeSettings))
        let configText = """
        # 使用者的 Codex 設定：註解與其他段落都要原樣保留
        model = "gpt-fixture"
        approval_policy = "on-request"

        [memories]
        # 記憶
        generate_memories = true   # 背景自己整理
        use_memories = true

        [mcp_servers.example]
        command = "echo"
        args = ["hi"]

        """
        try fm.createDirectory(atPath: paths.codexMemories + "/rollout_summaries", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.codexMemories + "/.git", withIntermediateDirectories: true)
        try write(configText, URL(fileURLWithPath: paths.codexConfig))
        try write("# Codex 自己的摘要\n舊內容\n", URL(fileURLWithPath: paths.codexSummary))
        try write("# Codex MEMORY\n- 一條\n", URL(fileURLWithPath: paths.codexMemories + "/MEMORY.md"))
        try write("raw\n", URL(fileURLWithPath: paths.codexMemories + "/raw_memories.md"))
        try write("rollout\n", URL(fileURLWithPath: paths.codexMemories + "/rollout_summaries/r1.md"))
        try write("ref: refs/heads/main\n", URL(fileURLWithPath: paths.codexMemories + "/.git/HEAD"))

        let originalSettings = try Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))
        let originalConfig = try Data(contentsOf: URL(fileURLWithPath: paths.codexConfig))
        let originalCodex = tree(URL(fileURLWithPath: paths.codexMemories))
        let originalA = tree(projectA), originalB = tree(projectB)

        let first = EngineMemoryLinks.scan(paths: paths)
        check(first.rows.map(\.state) == [.notLinked, .notLinked] && !first.exists, "scan before link: both not linked")

        let report = try EngineMemoryLinks.link(paths: paths, now: now, deviceName: "fixture-mac", role: .primary,
                                                pullFromPrimary: { _ in false })
        let memory = paths.memory
        check(fm.fileExists(atPath: memory.path + "/.git") && fm.fileExists(atPath: memory.path + "/README.md")
              && fm.fileExists(atPath: memory.path + "/.gitignore"), "memory folder created as git repo with README")

        // b. 合併
        check((0..<230).allSatisfy { fm.fileExists(atPath: memory.appendingPathComponent("note-\($0).md").path) }, "all project A files imported")
        let sharedB = memory.appendingPathComponent("shared--work-shop.md")
        check(read(memory.appendingPathComponent("shared.md")).contains("A 的版本") && read(sharedB).contains("B 的版本"),
              "name clash gets source suffix")
        check(!fm.fileExists(atPath: memory.appendingPathComponent("same--work-shop.md").path), "identical file not duplicated")
        check(fm.fileExists(atPath: memory.appendingPathComponent("b-only.md").path)
              && fm.fileExists(atPath: memory.appendingPathComponent("unindexed.md").path), "project B files imported")
        check(!fm.fileExists(atPath: memory.appendingPathComponent("linked-only.md").path), "symlinked project memory skipped")
        check(report.importedFiles == 230 + 2 + 4, "import count \(report.importedFiles)")

        // 主索引上限與分索引
        let main = read(memory.appendingPathComponent("MEMORY.md"))
        let mainLines = main.hasSuffix("\n") ? main.dropLast().components(separatedBy: "\n") : main.components(separatedBy: "\n")
        check(mainLines.count <= 200 && main.utf8.count <= 25_000, "main index within 200 lines / 25 KB (\(mainLines.count) lines)")
        let subA = read(memory.appendingPathComponent("MEMORY-home.md"))
        check(!subA.isEmpty && main.contains("](MEMORY-home.md)"), "overflow goes to MEMORY-home.md with pointer")
        let allIndex = main + subA + read(memory.appendingPathComponent("MEMORY-work-shop.md"))
        check((0..<230).allSatisfy { allIndex.contains("](note-\($0).md)") }, "every note reachable from an index")
        check(allIndex.contains("](shared--work-shop.md)") && allIndex.contains("](unindexed.md)") && allIndex.contains("](b-only.md)"),
              "renamed and unindexed files listed")
        check(main.contains("](imports/codex-fixture-mac/README.md)"), "codex import pointer in main index")
        let imports = memory.appendingPathComponent("imports/codex-fixture-mac")
        check(read(imports.appendingPathComponent("memory_summary.md")) == "# Codex 自己的摘要\n舊內容\n"
              && fm.fileExists(atPath: imports.appendingPathComponent("MEMORY.md").path)
              && fm.fileExists(atPath: imports.appendingPathComponent("raw_memories.md").path)
              && fm.fileExists(atPath: imports.appendingPathComponent("rollout_summaries/r1.md").path)
              && !fm.fileExists(atPath: imports.appendingPathComponent(".git").path), "codex memories copied to imports")

        // c. 封存
        let archive = URL(fileURLWithPath: report.archive ?? "/nonexistent")
        check(archive.lastPathComponent == "engine-memory-\(stamp)", "archive folder named by date")
        let restoreNote = read(archive.appendingPathComponent("還原.md"))
        check(restoreNote.contains("還原") && restoreNote.contains("autoMemoryDirectory") && restoreNote.contains("generate_memories"),
              "還原.md written")
        check(tree(archive.appendingPathComponent("claude-projects/\(encodedHome)/memory")) == originalA
              && tree(archive.appendingPathComponent("claude-projects/\(encodedHome)-work-shop/memory")) == originalB,
              "claude originals archived whole")
        check(tree(archive.appendingPathComponent("codex-memories")) == originalCodex, "codex memories archived whole")
        check((try? Data(contentsOf: archive.appendingPathComponent("claude-settings.json"))) == originalSettings
              && (try? Data(contentsOf: archive.appendingPathComponent("codex-config.toml"))) == originalConfig, "settings and config backed up")

        // d. settings.json 只多一個鍵
        let settingsNow = read(URL(fileURLWithPath: paths.claudeSettings))
        let insertedMember = ",\n  \"autoMemoryDirectory\": \"~/AI/TATWO OS/memory\""
        check(settingsNow.replacingOccurrences(of: insertedMember, with: "") == settingsText, "settings: only one key merged, other bytes untouched")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(settingsNow.utf8))) as? [String: Any]
        check(parsed?["model"] as? String == "opus" && (parsed?["env"] as? [String: String])?["EXAMPLE_FLAG"] == "1"
              && parsed?.count == 4, "settings: other keys unchanged")
        check(EngineMemoryLinks.pointsToMemory(parsed?["autoMemoryDirectory"] as? String ?? "", paths: paths), "settings value points to memory")
        let movedA = projectA.path + ".moved-w179-" + stamp
        check(EngineLinks.isLink(projectA.path, to: memory.path) && tree(URL(fileURLWithPath: movedA)) == originalA,
              "old claude folder renamed and replaced by link")

        // e. config.toml：generate_memories 原地改一行；沒有 [features] 就在檔尾補上 memories = true；其他一字不動
        let configNow = read(URL(fileURLWithPath: paths.codexConfig)).components(separatedBy: "\n")
        let configBefore = configText.components(separatedBy: "\n")
        let changed = zip(configBefore, configNow).filter { $0 != $1 }
        check(configNow.count == configBefore.count + 3 && changed.count == 1
              && changed.first?.1 == "generate_memories = false   # 背景自己整理"
              && Array(configNow.suffix(4)) == ["", "[features]", "memories = true", ""],
              "toml: generate line changed in place, [features] memories appended, nothing else touched")
        let summary = read(URL(fileURLWithPath: paths.codexSummary))
        check(summary.hasPrefix("<!-- 由 TATWO OS 產生，勿手改") && summary.utf8.count <= 8_192 && summary.contains(memory.path),
              "codex summary generated with marker within 8 KB")

        // f. commit：Codex 原始紀錄與看起來含權杖的檔不進 git（檔案還在這台）
        let log = EngineMemoryLinks.git(["log", "--oneline"], in: memory).output
        let dirty = EngineMemoryLinks.git(["status", "--porcelain"], in: memory).output
        check(!log.isEmpty && dirty.isEmpty, "memory committed")
        let tracked = EngineMemoryLinks.git(["ls-files"], in: memory).output
        let ignore = read(memory.appendingPathComponent(".gitignore"))
        check(ignore.contains("imports/**/raw_memories.md") && ignore.contains("imports/**/rollout_summaries/")
              && tracked.contains("imports/codex-fixture-mac/MEMORY.md") && !tracked.contains("raw_memories.md")
              && !tracked.contains("rollout_summaries"), "codex raw memories and rollout summaries stay out of git")
        check(!tracked.contains("leaky.md") && tracked.contains("b-only.md") && fm.fileExists(atPath: memory.appendingPathComponent("leaky.md").path)
              && read(memory.appendingPathComponent(".git/info/exclude")).contains("/leaky.md")
              && report.notes.contains { $0.contains("leaky.md") && $0.contains("金鑰或權杖") }, "secret-looking file held back from git with a note")

        let linked = EngineMemoryLinks.scan(paths: paths)
        check(linked.rows.allSatisfy { $0.state == .linked && $0.canRestore } && linked.exists && linked.isGitRepository
              && linked.itemCount == 236 && !linked.awaitingPrimarySync, "scan after link: all linked (\(linked.itemCount) items)")

        // 記憶變了 → 重產 Codex 摘要
        let fresh = memory.appendingPathComponent("fresh-idea.md")
        try write(note("fresh idea", "剛記的"), fresh)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: fresh.path)
        check(EngineMemoryLinks.refreshCodexSummary(paths: paths)
              && read(URL(fileURLWithPath: paths.codexSummary)).contains("](fresh-idea.md)"), "summary refreshed after memory change")
        check(!EngineMemoryLinks.refreshCodexSummary(paths: paths), "summary refresh is a no-op when unchanged")

        // 再接一次：都已接上，不再封存
        let again = try EngineMemoryLinks.link(paths: paths, now: now, deviceName: "fixture-mac", role: .primary, pullFromPrimary: { _ in false })
        check(again.archive == nil && EngineMemoryLinks.manifests(paths).count == 1, "second link is a no-op")

        // 還原：逐位元回到原樣
        try EngineMemoryLinks.restore(paths: paths, now: now)
        check((try? Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))) == originalSettings, "restore: settings.json byte-identical")
        check((try? Data(contentsOf: URL(fileURLWithPath: paths.codexConfig))) == originalConfig, "restore: config.toml byte-identical")
        check(tree(URL(fileURLWithPath: paths.codexMemories)) == originalCodex, "restore: codex memories byte-identical")
        check((try? fm.destinationOfSymbolicLink(atPath: projectA.path)) == nil && tree(projectA) == originalA && tree(projectB) == originalB
              && !fm.fileExists(atPath: movedA), "restore: claude folders back in place")
        let restored = EngineMemoryLinks.scan(paths: paths)
        check(restored.rows.allSatisfy { $0.state == .notLinked && !$0.canRestore } && restored.exists, "scan after restore: not linked, memory kept")
        check(read(archive.appendingPathComponent("還原.md")).contains("已還原"), "還原.md records the restore")
    }

    // MARK: 副設備：主設備連不上

    static func secondaryWithoutPrimary(base: URL, _ check: Checker) throws {
        let fm = FileManager.default
        let home = base.appendingPathComponent("home-secondary").path
        try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let paths = EngineMemoryPaths(home: home, entryRoot: URL(fileURLWithPath: home).appendingPathComponent("AI/TATWO OS"))
        var asked = false
        let report = try EngineMemoryLinks.link(paths: paths, deviceName: "fixture-secondary", role: .secondary,
                                                pullFromPrimary: { _ in asked = true; return false })
        let status = EngineMemoryLinks.scan(paths: paths)
        check(asked && status.exists && status.awaitingPrimarySync && status.folderLine.contains("等主設備同步")
              && report.notes.contains { $0.contains("等主設備同步") }, "secondary without primary: local copy waits for sync")
        check(status.rows.first?.state == .linked && status.rows.last?.state == .notInstalled, "secondary: claude linked, codex not installed")
    }

    // MARK: 主導手動接好的狀態（~ 路徑、絕對路徑、入口本身是連結）

    static func manualLeadState(base: URL, _ check: Checker) throws {
        let fm = FileManager.default
        let home = base.appendingPathComponent("home-manual").path
        let entryRoot = URL(fileURLWithPath: home).appendingPathComponent("AI/TATWO OS")
        let paths = EngineMemoryPaths(home: home, entryRoot: entryRoot)
        try fm.createDirectory(at: paths.memory, withIntermediateDirectories: true)
        EngineMemoryLinks.git(["init", "-q"], in: paths.memory)
        let encodedHome = String(home.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let project = URL(fileURLWithPath: paths.claudeProjects).appendingPathComponent(encodedHome)
        try fm.createDirectory(at: project.appendingPathComponent("memory.moved-w179-20260926"), withIntermediateDirectories: true)
        try write("old\n", project.appendingPathComponent("memory.moved-w179-20260926/a.md"))
        try fm.createSymbolicLink(atPath: project.appendingPathComponent("memory").path, withDestinationPath: paths.memory.path)
        try write("{\n  \"model\": \"opus\",\n  \"autoMemoryDirectory\": \"~/AI/TATWO OS/memory\"\n}\n", URL(fileURLWithPath: paths.claudeSettings))
        let tildeRow = EngineMemoryLinks.scan(paths: paths).rows.first
        check(tildeRow?.state == .linked && tildeRow?.canRestore == false, "manual link with ~/ path recognized")
        check(EngineMemoryLinks.claudeSources(paths).isEmpty, "manual symlinked folder not re-imported")

        // 寫設定之前就失敗的那次接上（只有封存、沒動任何東西）：不給還原鈕，還原也不去動主導手動接好的設定
        let staleArchive = paths.archiveRoot.appendingPathComponent("engine-memory-20260101", isDirectory: true)
        try fm.createDirectory(at: staleArchive, withIntermediateDirectories: true)
        let stale = EngineMemoryManifest(version: 1, createdAt: Date(timeIntervalSince1970: 0), device: "fixture", memoryPath: paths.memory.path,
                                         claude: .init(settingsPath: paths.claudeSettings, settingsExisted: true, originalValue: nil,
                                                       writtenSHA: nil, moved: [], restoredAt: nil), codex: nil)
        try EngineMemoryLinks.save(stale, staleArchive)
        let manualSettings = try Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))
        check(EngineMemoryLinks.scan(paths: paths).rows.first?.canRestore == false, "failed attempt (nothing written) gives no restore button")
        var nothingToRestore = false
        do { try EngineMemoryLinks.restore(paths: paths) } catch { nothingToRestore = true }
        check(nothingToRestore && (try? Data(contentsOf: URL(fileURLWithPath: paths.claudeSettings))) == manualSettings,
              "restore skips a failed attempt and leaves the manual link alone")

        // Codex：摘要是 OS 產生的、generate_memories 也關了，但 [features] memories 沒開＝Codex 根本不讀記憶，不算接上
        try write("[memories]\ngenerate_memories = false\nuse_memories = true\n", URL(fileURLWithPath: paths.codexConfig))
        try write("<!-- \(EngineMemoryLinks.marker) -->\n", URL(fileURLWithPath: paths.codexSummary))
        let featureOff = EngineMemoryLinks.scan(paths: paths).rows.last
        check(featureOff?.state == .notLinked && featureOff?.statusText.contains("記憶功能沒開") == true, "codex with [features] memories off is not linked")
        try write("[features]\nmemories = true\n\n[memories]\ngenerate_memories = false\nuse_memories = true\n", URL(fileURLWithPath: paths.codexConfig))
        check(EngineMemoryLinks.scan(paths: paths).rows.last?.state == .linked, "codex with [features] memories on is linked")
        try write("{\"autoMemoryDirectory\": \"\(paths.memory.path)/\"}", URL(fileURLWithPath: paths.claudeSettings))
        check(EngineMemoryLinks.scan(paths: paths).rows.first?.state == .linked, "manual link with absolute path recognized")

        // mini：入口本身是指向外接卷的連結，設定寫的是外接卷的絕對路徑
        let volume = base.appendingPathComponent("volume/TATWO OS", isDirectory: true)
        try fm.createDirectory(at: volume.appendingPathComponent("memory"), withIntermediateDirectories: true)
        let miniHome = base.appendingPathComponent("home-mini").path
        try fm.createDirectory(atPath: miniHome + "/AI", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: miniHome + "/AI/TATWO OS", withDestinationPath: volume.path)
        try fm.createDirectory(atPath: miniHome + "/.claude", withIntermediateDirectories: true)
        let miniPaths = EngineMemoryPaths(home: miniHome, entryRoot: URL(fileURLWithPath: miniHome).appendingPathComponent("AI/TATWO OS"))
        try write("{\"autoMemoryDirectory\": \"\(volume.appendingPathComponent("memory").path)\"}", URL(fileURLWithPath: miniPaths.claudeSettings))
        check(EngineMemoryLinks.scan(paths: miniPaths).rows.first?.state == .linked, "mini layout (entry is a symlink) recognized")
        try write("{\"autoMemoryDirectory\": \"/somewhere/else\"}", URL(fileURLWithPath: miniPaths.claudeSettings))
        check(EngineMemoryLinks.scan(paths: miniPaths).rows.first?.state == .notLinked, "other folder is not linked")
    }

    // MARK: 主導手動匯入過 Codex（資料夾名跟設備名對不上）；還原後 Codex 又記了新的

    static func leadCodexImport(base: URL, _ check: Checker) throws {
        let fm = FileManager.default
        let home = base.appendingPathComponent("home-lead-import").path
        let paths = EngineMemoryPaths(home: home, entryRoot: URL(fileURLWithPath: home).appendingPathComponent("AI/TATWO OS", isDirectory: true))
        let memory = paths.memory
        let now = Date()
        let live = URL(fileURLWithPath: paths.codexMemories)
        try write("# Codex 摘要\n", live.appendingPathComponent("memory_summary.md"))
        try write("# Codex MEMORY\n", live.appendingPathComponent("MEMORY.md"))
        try write("raw v1\n", live.appendingPathComponent("raw_memories.md"))
        try write("rollout\n", live.appendingPathComponent("rollout_summaries/r1.md"))
        let configText = "model = \"x\"\n\n[features]\nmemories = true\n\n[memories]\ngenerate_memories = true\n"
        let config = URL(fileURLWithPath: paths.codexConfig)
        try write(configText, config)
        // 主導手動建的 memory/：.gitignore 只有 .DS_Store、Codex 匯入在 imports/codex-lead-import/、索引已指過去
        let lead = memory.appendingPathComponent("imports/codex-lead-import", isDirectory: true)
        try fm.createDirectory(at: lead, withIntermediateDirectories: true)
        for name in EngineMemoryLinks.codexImportNames {
            try fm.copyItem(at: live.appendingPathComponent(name), to: lead.appendingPathComponent(name))
        }
        try write(".DS_Store\n", memory.appendingPathComponent(".gitignore"))
        try write("# 記憶索引\n\n- Codex（前一台）：[imports/codex-lead-import/](imports/codex-lead-import/memory_summary.md)\n",
                  memory.appendingPathComponent("MEMORY.md"))
        EngineMemoryLinks.git(["init", "-q"], in: memory)
        let indexBefore = read(memory.appendingPathComponent("MEMORY.md"))

        let own = memory.appendingPathComponent("imports/codex-Laptop-One", isDirectory: true)
        try EngineMemoryLinks.link([.codex], paths: paths, now: now, deviceName: "Laptop One", role: .secondary, pullFromPrimary: { _ in false })
        check(!fm.fileExists(atPath: own.path) && read(memory.appendingPathComponent("MEMORY.md")) == indexBefore,
              "lead's codex import under another folder name recognized by content: no second copy, no second pointer")
        let ignore = read(memory.appendingPathComponent(".gitignore"))
        check(ignore.hasPrefix(".DS_Store\n") && ignore.contains("imports/**/raw_memories.md") && ignore.contains("imports/**/rollout_summaries/"),
              "existing .gitignore gets the local-only rules appended")
        let tracked = EngineMemoryLinks.git(["ls-files"], in: memory).output
        check(tracked.contains("imports/codex-lead-import/MEMORY.md") && !tracked.contains("raw_memories.md") && !tracked.contains("rollout_summaries"),
              "lead import: raw memories stay out of git")
        let lines = read(config).components(separatedBy: "\n"), before = configText.components(separatedBy: "\n")
        check(lines.count == before.count && zip(before, lines).filter { $0 != $1 }.count == 1 && EngineMemoryLinks.scan(paths: paths).rows.last?.state == .linked,
              "toml: exactly one line changed when [features] memories is already on")

        // 還原後 Codex 又自己記了新的 → 再接上要匯入新的，不因為資料夾在就略過
        try EngineMemoryLinks.restore([.codex], paths: paths, now: now)
        check(read(config) == configText, "lead import: restore puts config back")
        try write("raw v2\n", live.appendingPathComponent("raw_memories.md"))
        try EngineMemoryLinks.link([.codex], paths: paths, now: now, deviceName: "Laptop One", role: .secondary, pullFromPrimary: { _ in false })
        check(read(own.appendingPathComponent("raw_memories.md")) == "raw v2\n"
              && read(memory.appendingPathComponent("MEMORY.md")).contains("](imports/codex-Laptop-One/README.md)"),
              "newer codex memories imported after restore")
        try EngineMemoryLinks.restore([.codex], paths: paths, now: now)
        try write("raw v3\n", live.appendingPathComponent("raw_memories.md"))
        try EngineMemoryLinks.link([.codex], paths: paths, now: now, deviceName: "Laptop One", role: .secondary, pullFromPrimary: { _ in false })
        let day = EngineMemoryLinks.dayStamp(now)
        check(read(own.appendingPathComponent("\(day)/raw_memories.md")) == "raw v3\n" && read(own.appendingPathComponent("raw_memories.md")) == "raw v2\n"
              && read(memory.appendingPathComponent("MEMORY.md")).contains("](imports/codex-Laptop-One/\(day)/README.md)"),
              "same device folder with other content: dated subfolder, nothing skipped")
    }

    // MARK: 寫設定時停在一半（manifest 記了改哪一行、沒記到寫完的 sha）

    static func partialLinkRestore(base: URL, _ check: Checker) throws {
        let fm = FileManager.default
        let home = base.appendingPathComponent("home-partial").path
        let paths = EngineMemoryPaths(home: home, entryRoot: URL(fileURLWithPath: home).appendingPathComponent("AI/TATWO OS", isDirectory: true))
        try fm.createDirectory(at: paths.memory, withIntermediateDirectories: true)
        let config = URL(fileURLWithPath: paths.codexConfig)
        let original = "[features]\nmemories = true\n\n[memories]\ngenerate_memories = true # 背景整理\n"
        try write("[features]\nmemories = true\n\n[memories]\ngenerate_memories = false # 背景整理\n", config)
        let archive = paths.archiveRoot.appendingPathComponent("engine-memory-20260102", isDirectory: true)
        try write(original, archive.appendingPathComponent("codex-config.toml"))
        let partial = EngineMemoryManifest(version: 1, createdAt: Date(), device: "fixture", memoryPath: paths.memory.path, claude: nil,
                                           codex: .init(configPath: paths.codexConfig, configExisted: true, edit: "replaced",
                                                        originalLine: "generate_memories = true # 背景整理",
                                                        writtenLine: "generate_memories = false # 背景整理", writtenSHA: nil,
                                                        summaryPath: paths.codexSummary, summaryExisted: false, memoriesExisted: false,
                                                        summaryWritten: false, restoredAt: nil))
        try EngineMemoryLinks.save(partial, archive)
        check(EngineMemoryLinks.scan(paths: paths).rows.last?.canRestore == true, "half-done link (no written sha) is still restorable")
        try EngineMemoryLinks.restore([.codex], paths: paths)
        check(read(config) == original, "half-done link: restore undoes the edited line")
    }

    // MARK: 工具

    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// 資料夾逐位元快照：相對路徑 → 內容（連結記它指向哪）。
    static func tree(_ root: URL) -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        func walk(_ url: URL, _ relative: String) {
            if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                result[relative] = Data(("link:" + destination).utf8)
                return
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue {
                result[relative + "/"] = Data()
                for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                    walk(url.appendingPathComponent(name), relative + "/" + name)
                }
            } else {
                result[relative] = (try? Data(contentsOf: url)) ?? Data()
            }
        }
        walk(root, "")
        return result
    }
}
#endif
