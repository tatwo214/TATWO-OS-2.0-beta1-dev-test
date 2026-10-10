import Foundation

struct ChangeProposalStore: Sendable {
    struct File: Codable, Equatable, Sendable { let path: String; let added: Int; let deleted: Int }
    struct Proposal: Codable, Sendable {
        let title: String; var summary: String; let projectID: UUID; let cwd: String; let files: [File]; let digest: String
        var applied: Bool? = nil
        var reportOnly: Bool? = nil
        var sandboxGrant: String? = nil; var needsReconfirmation: Bool? = nil
        var statistics: String { "\(files.count) 個檔，+\(files.reduce(0) { $0 + $1.added }) −\(files.reduce(0) { $0 + $1.deleted })" }
        var eventText: String { ([title, sandboxGrant == nil ? summary : String(summary.prefix(300)), statistics] + files.map { "\($0.path) +\($0.added) −\($0.deleted)" }).joined(separator: "\n") }
    }
    let root: URL
    private func url(_ thread: UUID, _ sequence: Int, _ ext: String) -> URL {
        root.appendingPathComponent("proposals/\(thread)/\(sequence).\(ext)")
    }
    func save(_ proposal: Proposal, patch: String, thread: UUID, sequence: Int) throws {
        try HandsFiles.ensureDirectory(root.appendingPathComponent("proposals"))
        try HandsFiles.writeAtomically(Data(patch.utf8), to: url(thread, sequence, "patch"))
        try HandsFiles.writeAtomically(JSONEncoder().encode(proposal), to: url(thread, sequence, "json"))
    }
    func saveSandboxReport(_ text: String, thread: UUID, sequence: Int) throws { try HandsFiles.writeAtomically(Data(text.utf8), to: url(thread, sequence, "report")) }
    func invalidateSandbox(_ grants: Set<String>) throws {
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent("proposals"), includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "json" {
            guard let data = HandsFiles.readSecure(file), var proposal = try? JSONDecoder().decode(Proposal.self, from: data),
                  proposal.applied != true, proposal.sandboxGrant.map(grants.contains) ?? (!grants.isEmpty && proposal.reportOnly != nil && proposal.title == "沙盒交件（外部資料）") else { continue }
            proposal.needsReconfirmation = true; proposal.summary = "需要重新確認：沙盒授權已撤銷。\n" + String(proposal.summary.prefix(280))
            try HandsFiles.writeAtomically(JSONEncoder().encode(proposal), to: file)
        }
    }
    func remove(_ thread: UUID, sequence: Int? = nil) throws {
        let target = sequence.map { url(thread, $0, "patch") } ?? root.appendingPathComponent("proposals/\(thread)")
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let parts = ["proposals", thread.uuidString] + (sequence.map { ["\($0).patch"] } ?? [])
        _ = try HandsPath.resolve(root: root.path, components: parts, expect: .any)
        try FileManager.default.removeItem(at: target)
    }
    func proposal(_ thread: UUID, _ sequence: Int) -> Proposal? {
        HandsFiles.readSecure(url(thread, sequence, "json")).flatMap { try? JSONDecoder().decode(Proposal.self, from: $0) }
    }
    func patch(_ thread: UUID, _ sequence: Int) throws -> String {
        guard let proposal = proposal(thread, sequence), let data = HandsFiles.readSecure(url(thread, sequence, "patch"), limit: 204800),
              HandsAuth.sha256Hex(data) == proposal.digest, let text = String(data: data, encoding: .utf8) else {
            throw HandsToolError.invalid("proposal_unavailable：提案資料讀取失敗")
        }
        return text
    }
    func apply(_ thread: UUID, _ sequence: Int) throws {
        guard var proposal = proposal(thread, sequence) else { throw HandsToolError.invalid("proposal_unavailable：提案資料讀取失敗") }
        guard proposal.needsReconfirmation != true else { throw HandsToolError.invalid("需要重新確認：沙盒授權已撤銷，請重新交件。") }
        if proposal.applied == true { return }
        let text = try patch(thread, sequence)
        if proposal.reportOnly == true { proposal.applied = true; try HandsFiles.writeAtomically(JSONEncoder().encode(proposal), to: url(thread, sequence, "json")); return }
        guard try Self.check(text, cwd: proposal.cwd) == proposal.files else { throw HandsToolError.invalid("proposal_changed：提案資料已變") }
        let result = try HandsGit.run(["apply", "--whitespace=nowarn", "-"], cwd: proposal.cwd, stdin: Data(text.utf8))
        guard result.status == 0, !result.truncated else { throw HandsToolError.invalid("patch_does_not_apply：補丁套不上目前的專案，請重新產生") }
        proposal.applied = true
        try HandsFiles.writeAtomically(JSONEncoder().encode(proposal), to: url(thread, sequence, "json"))
        do { try remove(thread, sequence: sequence) }
        catch { proposal.summary += "\n補丁未能刪除，請稍後清理。"; try? HandsFiles.writeAtomically(JSONEncoder().encode(proposal), to: url(thread, sequence, "json")) }
    }
    static func check(_ patch: String, cwd: String) throws -> [File] {
        guard !patch.isEmpty, patch.utf8.count <= 204800 else { throw HandsToolError.invalid("patch_size：補丁須為 200 KB 以內的純文字") }
        guard !patch.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }) else {
            throw HandsToolError.invalid("hidden_characters：補丁含看不見的格式字元（例如雙向標記、零寬字元、BOM），畫面看到的可能跟實際不同，請改用一般文字")
        }
        guard !patch.contains("\0") else { throw HandsToolError.invalid("binary_patch：不收二進位補丁") }
        guard let real = HandsPath.realpath(cwd), let top = HandsGit.hostRead(["rev-parse", "--show-toplevel"], cwd: real),
              HandsPath.realpath(top.trimmingCharacters(in: .whitespacesAndNewlines)) == real else {
            throw HandsToolError.invalid("git_worktree_required：專案須為 git 工作副本根目錄")
        }
        func path(_ raw: String, strip: Bool = false) throws {
            if raw == "/dev/null" { return }
            let value = strip && (raw.hasPrefix("a/") || raw.hasPrefix("b/")) ? String(raw.dropFirst(2)) : raw
            guard !value.contains("\""), !value.contains("\\") else { throw HandsToolError.invalid("path_encoding：不收跳脫或引號路徑") }
            let parts = try HandsPath.components(value, forWrite: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.lowercased() == ".git" }) else { throw HandsToolError.invalid("git_path：不准改 .git") }
            guard !HandsSandbox.isProtected(components: parts), !HandsSecretFiles.isSecret(components: parts) else {
                throw HandsToolError.invalid("protected_path：不准改保護檔或金鑰檔")
            }
            _ = try HandsPath.resolve(root: real, components: parts, expect: .absentOrFile)
        }
        var old = 0, new = 0
        for line in patch.components(separatedBy: "\n") {
            if old > 0 || new > 0 {
                if line.hasPrefix(" ") { old -= 1; new -= 1 }
                else if line.hasPrefix("-") { old -= 1 }
                else if line.hasPrefix("+") { new -= 1 }
                else if !line.hasPrefix("\\") { throw HandsToolError.invalid("unified_diff：補丁格式不完整") }
                continue
            }
            if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                guard fields.count >= 4 else { throw HandsToolError.invalid("unified_diff：補丁格式不完整") }
                old = Int(fields[1].split(separator: ",").dropFirst().first ?? "1") ?? -1
                new = Int(fields[2].split(separator: ",").dropFirst().first ?? "1") ?? -1
                guard old >= 0, new >= 0 else { throw HandsToolError.invalid("unified_diff：補丁格式不完整") }
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                try path(String(line.dropFirst(4).split(separator: "\t", omittingEmptySubsequences: false)[0]), strip: true)
            } else if line.hasPrefix("diff --git ") {
                guard let separator = line.range(of: " b/", options: .backwards), line.hasPrefix("diff --git a/") else {
                    throw HandsToolError.invalid("path_must_be_relative：補丁路徑須相對於專案")
                }
                try path(String(line.dropFirst(11).prefix(upTo: separator.lowerBound)), strip: true)
                try path(String(line[separator.upperBound...]))
            } else if line.hasPrefix("rename ") || line.hasPrefix("copy ") {
                throw HandsToolError.invalid("rename_patch：請用純文字增刪檔補丁")
            } else if line.split(separator: " ").last == "120000" && (line.contains("mode ") || line.hasPrefix("index ")) {
                throw HandsToolError.invalid("symlink_refused：不收捷徑補丁")
            } else if line.split(separator: " ").last == "160000" && (line.contains("mode ") || line.hasPrefix("index ")) {
                throw HandsToolError.invalid("submodule_refused：不收子模組補丁")
            } else if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                throw HandsToolError.invalid("binary_patch：不收二進位補丁")
            }
        }
        let data = Data(patch.utf8)
        let stats = try HandsGit.run(["apply", "--whitespace=nowarn", "--numstat", "-z", "-"], cwd: real, stdin: data, cap: 204800)
        guard stats.status == 0, !stats.truncated else { throw HandsToolError.invalid("unified_diff：補丁格式不完整") }
        let files = try stats.out.split(separator: "\0").map { row -> File in
            let fields = row.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, let added = Int(fields[0]), let deleted = Int(fields[1]) else { throw HandsToolError.invalid("binary_patch：不收二進位補丁") }
            try path(String(fields[2])); return File(path: String(fields[2]), added: added, deleted: deleted)
        }
        guard !files.isEmpty else { throw HandsToolError.invalid("unified_diff：補丁沒有檔案改動") }
        let result = try HandsGit.run(["apply", "--whitespace=nowarn", "--check", "-"], cwd: real, stdin: data)
        guard result.status == 0, !result.truncated else { throw HandsToolError.invalid("patch_does_not_apply：補丁套不上目前的專案，請重新產生") }
        return files
    }
}

extension HandsService {
    func proposeChange(thread raw: String, title: String, summary: String, patch: String, grant: HandsGrantAccess, settings: HandsSettings) throws -> Int {
        _ = try readSession(raw, cursor: nil, grant: grant, settings: settings)
        guard let id = UUID(uuidString: raw) else { throw HandsToolError.invalid("session_not_found_or_not_allowed") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80, summary.count <= 300 else { throw HandsToolError.invalid("proposal_title_or_summary：標題或摘要長度不合") }
        let bridge = try onMain { Result { () throws -> GroupCoderBridge in
            guard let bridge = self.engine?.groupBridge else { throw HandsToolError.invalid("group_required：這串尚未三方協作") }; return bridge
        } }.get()
        let target = try onMain { Result { try bridge.proposalTarget(id, joined: true) } }.get()
        guard let project = allowedProjects(grant, settings).first(where: { $0.id == target.0 }), !classificationPending else { throw HandsToolError.invalid("session_not_found_or_not_allowed") }
        guard project.problem == nil else { throw HandsToolError.invalid("project_unavailable：專案資料夾不可用") }
        guard !project.readOnly else { throw HandsToolError.invalid(HandsTradingFloor.refusal) }
        let files = try ChangeProposalStore.check(patch, cwd: target.1)
        return try onMain { Result {
            let current = try bridge.proposalTarget(id, joined: true)
            guard current == target, let group = bridge.sessions[id] else { throw HandsToolError.invalid("proposal_target_changed：專案已變，請重送") }
            let proposal = ChangeProposalStore.Proposal(title: GroupCoderBridge.safe(title), summary: GroupCoderBridge.safe(summary), projectID: target.0,
                cwd: target.1, files: files, digest: HandsAuth.sha256Hex(Data(patch.utf8)))
            try bridge.proposals.save(proposal, patch: patch, thread: id, sequence: group.events.count + 1)
            return group.record(speaker: "ChatGPT", text: GroupCoderBridge.safe(proposal.eventText), kind: "proposal")
        } }.get()
    }
}
