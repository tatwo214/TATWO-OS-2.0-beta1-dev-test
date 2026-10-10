#if DEBUG
import AppKit
import SwiftUI
import CryptoKit

@MainActor enum W298bAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let artifact = env["TATWO2_SELFTEST_ARTIFACTS"] else { throw CocoaError(.fileReadNoPermission) }
        let fm = FileManager.default, paths = EnginePaths(), artifacts = URL(fileURLWithPath: artifact)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) { if value { passed += 1 } else { failed += 1 }; print("W298B \(value ? "PASS" : "FAIL") \(label)") }
        defer { print("W298B SUMMARY failures=\(failed) passed=\(passed)") }
        let originalCatalogs = EngineModelCatalog.catalogs()
        defer { EngineModelCatalog.replace(originalCatalogs) }
        let suite = "w298b." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func binary(_ url: URL, version: String, team: String, invalid: Bool = false, update: String = "", sdk: Bool = true, versionExit: Int = 0) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n# fixture-team=\(team) signature=\(invalid ? "invalid" : "valid") sdk=\(sdk ? "yes" : "no")\nif [ \"$1\" = update ]; then \(update.isEmpty ? "exit 1" : update); exit 0; fi\nif [ \"$1\" = --version ]; then echo \(version); exit \(versionExit); fi\nexit 1\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        func link(_ name: String, to target: URL, in root: URL) throws {
            let temp = root.appendingPathComponent(UUID().uuidString)
            try fm.createSymbolicLink(at: temp, withDestinationURL: target)
            guard rename(temp.path, root.appendingPathComponent(name).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        func choice(_ url: URL, _ version: String = "1.0.0") -> EngineRuntimeSelection.Choice { .init(executable: url, version: version, source: "本機", reason: nil) }
        let oldCodex = paths.userHome.appendingPathComponent("fixture/codex")
        try binary(oldCodex, version: "1.0.0", team: EngineInstall.teams["codex"]!)
        let oldData = try Data(contentsOf: oldCodex)
        var installer = EngineInstall(paths: paths)
        let unsignedTrusted = await installer.signature(oldCodex, EngineInstall.teams["codex"]!)
        check(!unsignedTrusted, "production rejects unsigned fake without execution")
        installer.signature = { url, team in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.contains("fixture-team=" + team) && text.contains("signature=valid")
        }
        let fixtureBase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../tests/fixtures").standardizedFileURL
        let priorDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrideDefaults = priorDefaults
        overrideDefaults["tatwo2.sidecarPath.codex"] = fixtureBase.appendingPathComponent("w298b-sdk.mjs").path
        overrideDefaults["tatwo2.sidecarPath.claude"] = fixtureBase.appendingPathComponent("w298b-sdk.mjs").path
        UserDefaults.standard.setVolatileDomain(overrideDefaults, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(priorDefaults, forName: UserDefaults.argumentDomain) }
        let packRoot = artifacts.appendingPathComponent("registry-fixture")
        let member = packRoot.appendingPathComponent("package/vendor/aarch64-apple-darwin/bin/codex")
        let archive = packRoot.appendingPathComponent("native.tgz")
        var mode = "correct", fetches: [String] = [], commands: [String] = []
        let mainTar = Data("verified wrapper archive fixture".utf8)
        func metadata(_ version: String, data: Data, url: String, bad: Bool = false) -> Data {
            let integrity = "sha512-" + Data(SHA512.hash(data: bad ? Data("wrong".utf8) : data)).base64EncodedString()
            return try! JSONSerialization.data(withJSONObject: ["name": "@openai/codex", "version": version,
                "optionalDependencies": ["@openai/codex-darwin-arm64": mode == "main-alias" ? "npm:wrong" : "npm:@openai/codex@2.0.0-darwin-arm64"],
                "dist": ["tarball": url, "integrity": integrity]])
        }
        installer.fetch = { url in
            fetches.append(url.absoluteString)
            if url.path.hasSuffix("/2.0.0") { return metadata("2.0.0", data: mainTar, url: "https://registry.npmjs.org/main.tgz", bad: mode == "main-alias") }
            if url.path.hasSuffix("/2.0.0-darwin-arm64") {
                return metadata("2.0.0-darwin-arm64", data: try Data(contentsOf: archive), url: "https://registry.npmjs.org/native.tgz", bad: mode == "native-integrity")
            }
            if url.path == "/main.tgz" { return mainTar }
            if url.path == "/native.tgz" { return try Data(contentsOf: archive) }
            throw CocoaError(.fileReadNoPermission)
        }
        installer.run = { url, args, home in
            commands.append(url.path + " " + args.joined(separator: " "))
            if mode == "publish-version-fail", args == ["--version"],
               url.lastPathComponent == "codex" { return nil }
            return await EngineAIUpdate.command(url, args, home: home)
        }
        for caseName in ["signature-wrong", "team-wrong", "main-alias", "native-integrity", "version-fail", "publish-version-fail", "correct"] {
            mode = caseName; fetches = []; commands = []
            try binary(member, version: "2.0.0", team: caseName == "team-wrong" ? "WRONGTEAM0" : EngineInstall.teams["codex"]!, invalid: caseName == "signature-wrong", versionExit: caseName == "version-fail" ? 7 : 0)
            _ = await EngineAIUpdate.command(URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", packRoot.path, "package"], home: paths.userHome)
            do {
                let result = try await installer.install(.codex, current: choice(oldCodex), newest: "2.0.0")
                check(caseName == "correct" && result.contains("已更新"), "Codex \(caseName) result")
            } catch { check(caseName != "correct", "Codex \(caseName) result") }
            let adopted = paths.codexHome.appendingPathComponent("current").resolvingSymlinksInPath()
            check(caseName == "correct" ? adopted.deletingLastPathComponent().lastPathComponent == "2.0.0" : adopted.deletingLastPathComponent().lastPathComponent != "2.0.0", "Codex \(caseName) adoption gate")
            if ["signature-wrong", "team-wrong", "main-alias", "native-integrity"].contains(caseName) { check(!commands.contains { $0.hasSuffix("/codex --version") }, "Codex \(caseName) rejected before execution") }
            if caseName == "publish-version-fail" { check(!fm.fileExists(atPath: paths.codexHome.appendingPathComponent("current").path), "publication version failure preserves previous") }
        }
        check(!fetches.contains { $0.hasSuffix("/main.tgz") }, "W350 unused main tarball never downloaded")
        check(commands.filter { $0.hasSuffix("/codex --version") }.count == 1, "W350 new Codex validated once before publication")
        check(try Data(contentsOf: oldCodex) == oldData, "original and bundled files remain immutable")
        let active = paths.codexHome.appendingPathComponent("current").resolvingSymlinksInPath()
        let activeData = try Data(contentsOf: active)
        mode = "correct"
        let prior = installer.previous(.codex)!
        check(prior.deletingLastPathComponent().lastPathComponent == "1.0.0", "previous version retained")
        let rollback = try await installer.rollback(.codex)
        check(rollback == "已退回 1.0.0" && paths.codexHome.appendingPathComponent("current").resolvingSymlinksInPath() == prior, "atomic rollback points to old binary")
        check(try Data(contentsOf: active) == activeData, "running conversation binary survives rollback")
        let candidate = EngineRuntimeSelection.Candidate(path: prior, version: "1.0.0", verified: true, developerID: true, teamID: EngineInstall.teams["codex"])
        let bundled = EngineRuntimeSelection.Candidate(path: oldCodex, version: "3.0.0", verified: true, developerID: true, teamID: EngineInstall.teams["codex"])
        check(EngineRuntimeSelection.choose(bundled: bundled, local: candidate, pinned: true).executable == prior, "rollback pin beats newer bundled or PATH runtime")
        var unreadable = candidate; unreadable.version = nil
        check(!EngineRuntimeSelection.shouldRollback(bundled: bundled, local: unreadable), "W350 version timeout never rolls back pointers")
        check(!EngineRuntimeSelection.shouldRollback(bundled: bundled, local: candidate), "W350 valid older version never rolls back pointers")
        var unsigned = candidate; unsigned.verified = false
        check(EngineRuntimeSelection.shouldRollback(bundled: bundled, local: unsigned), "W350 bad signature rolls back pointers")
        var wrong = candidate; wrong.teamID = "WRONGTEAM0"
        check(EngineRuntimeSelection.shouldRollback(bundled: bundled, local: wrong), "W350 wrong team rolls back pointers")
        check(EngineRuntimeSelection.choose(bundled: bundled, local: wrong, pinned: true).executable == oldCodex, "rollback pin still enforces signature identity")
        let launcher = paths.userHome.appendingPathComponent(".local/bin/claude"), oldClaude = paths.userHome.appendingPathComponent(".local/share/claude/versions/1.0.0")
        let newClaude = paths.userHome.appendingPathComponent(".local/share/claude/versions/2.0.0")
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary(oldClaude, version: "1.0.0", team: EngineInstall.teams["claude"]!, update: "ln -sf '\(newClaude.path)' '\(launcher.path)'")
        try link("claude", to: oldClaude, in: launcher.deletingLastPathComponent())
        for caseName in ["sdk-fail", "signature-fail", "backup-sdk-fail", "correct"] {
            installer.models = { executable in
                if caseName == "backup-sdk-fail", (try? String(contentsOf: executable, encoding: .utf8))?.contains("echo 1.0.0;") == true { return nil }
                return await EngineModelCatalogProbe.shared.read(.claude, executable: executable)
            }
            try binary(newClaude, version: "2.0.0", team: EngineInstall.teams["claude"]!, invalid: caseName == "signature-fail", sdk: caseName != "sdk-fail")
            do { _ = try await installer.install(.claude, current: choice(oldClaude), newest: "2.0.0"); check(caseName == "correct", "Claude \(caseName) result") }
            catch {
                check(caseName != "correct", "Claude \(caseName) result")
                check(launcher.resolvingSymlinksInPath() == oldClaude, "Claude \(caseName) restores user launcher")
                check(try String(contentsOf: paths.claudeConfigDirectory.appendingPathComponent("failure.txt"), encoding: .utf8).contains(caseName.contains("sdk") ? "supportedModels" : "Team"), "Claude \(caseName) records reason")
            }
        }
        check(paths.claudeConfigDirectory.appendingPathComponent("current").resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent == "2.0.0", "Claude validated SDK adopts immutable managed binary")
        check(commands.contains { $0.hasSuffix(" update") }, "Claude uses official update command")
        let fetchedBeforeGrok = fetches, commandsBeforeGrok = commands
        let manual = try await installer.install(.grok, current: choice(oldCodex), newest: "2.0.0")
        check(manual == EngineInstall.manualGrok && fetches == fetchedBeforeGrok && commands == commandsBeforeGrok, "Grok missing checksum stops without download or script")
        // Cross-vendor review regressions use independent fake installations.
        func fresh(_ label: String) -> EnginePaths {
            var e = env; let r = paths.userHome.appendingPathComponent("regression-" + label)
            e["HOME"] = r.appendingPathComponent("home").path
            e["TATWO2_ENGINES_ROOT"] = r.appendingPathComponent("engines").path
            return EnginePaths(environment: e)
        }
        func fixtureInstaller(_ p: EnginePaths) -> EngineInstall {
            var i = installer
            i = EngineInstall(paths: p, fetch: installer.fetch, signature: installer.signature, run: EngineAIUpdate.command,
                              models: { await EngineModelCatalogProbe.shared.read(.claude, executable: $0) })
            return i
        }
        for (label, actual, newest, invalid) in [
            ("newer", "2.1.4", "2.1.3", false),
            ("older", "2.1.1", "2.1.3", false),
            ("same", "2.1.2", "2.1.3", false),
            ("below-checked", "2.1.3", "2.1.4", false),
            ("unsigned-newer", "2.1.4", "2.1.3", true),
            ("prerelease", "2.1.4-beta", "2.1.3", false)
        ] {
            let p = fresh("w314-" + label), vendor = p.userHome.appendingPathComponent(".local/share/claude/versions")
            let old = vendor.appendingPathComponent("2.1.2"), next = vendor.appendingPathComponent(actual)
            let launcher = p.userHome.appendingPathComponent(".local/bin/claude")
            let marker = vendor.appendingPathComponent("old-resource")
            try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            try binary(old, version: "2.1.2", team: EngineInstall.teams["claude"]!)
            try Data("original resource".utf8).write(to: marker)
            try link("claude", to: old, in: launcher.deletingLastPathComponent())
            let oldBytes = try Data(contentsOf: old), oldLink = try fm.destinationOfSymbolicLink(atPath: launcher.path)
            var i = fixtureInstaller(p), result: String?, error: String?, untrustedExecuted = false
            i.run = { url, args, home in
                if args == ["update"] {
                    do {
                        try binary(next, version: actual, team: EngineInstall.teams["claude"]!, invalid: invalid)
                        try fm.removeItem(at: marker)
                        try link("claude", to: next, in: launcher.deletingLastPathComponent())
                        return "Successfully updated"
                    } catch { return nil }
                }
                if invalid && url.lastPathComponent == "new" { untrustedExecuted = true }
                return await EngineAIUpdate.command(url, args, home: home)
            }
            do { result = try await i.install(.claude, current: choice(old, "2.1.2"), newest: newest) }
            catch let failure { error = failure.localizedDescription }
            let current = p.claudeConfigDirectory.appendingPathComponent("current")
            if label == "newer" {
                check(result == "2.1.2 → 2.1.4 已更新" && error == nil && current.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent == "2.1.4", "W314 newer succeeds and reports actual version")
                check(EngineAIUpdate.version(await i.run(current, ["--version"], p.userHome) ?? "") == "2.1.4" && i.previous(.claude)?.deletingLastPathComponent().lastPathComponent == "2.1.2", "W314 actual published binary and previous retained")
            } else {
                let restoredLink = try fm.destinationOfSymbolicLink(atPath: launcher.path), restoredBytes = try Data(contentsOf: old), restoredMarker = try Data(contentsOf: marker)
                check(result == nil && error != nil && !fm.fileExists(atPath: current.path) &&
                      restoredLink == oldLink && restoredBytes == oldBytes && restoredMarker == Data("original resource".utf8), "W314 \(label) fails and restores launcher and version tree")
                if invalid { check(!untrustedExecuted, "W314 unsigned actual rejected before version execution") }
            }
        }
        let restorePaths = fresh("restore"), vendor = restorePaths.userHome.appendingPathComponent(".local/share/claude")
        let original = vendor.appendingPathComponent("versions/1.0.0"), marker = vendor.appendingPathComponent("versions/old-resource")
        let userLink = restorePaths.userHome.appendingPathComponent(".local/bin/claude")
        try binary(original, version: "1.0.0", team: EngineInstall.teams["claude"]!)
        try Data("original resource".utf8).write(to: marker)
        try fm.createDirectory(at: userLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try link("claude", to: original, in: userLink.deletingLastPathComponent())
        let originalBytes = try Data(contentsOf: original), originalLink = try fm.destinationOfSymbolicLink(atPath: userLink.path)
        var destructive = fixtureInstaller(restorePaths)
        destructive.run = { url, args, home in
            if args == ["update"] {
                try? Data("overwritten by failed update".utf8).write(to: original)
                try? fm.removeItem(at: marker)
                try? Data("partial download".utf8).write(to: vendor.appendingPathComponent("versions/partial"))
                return nil
            }
            return await EngineAIUpdate.command(url, args, home: home)
        }
        do { _ = try await destructive.install(.claude, current: choice(original), newest: "2.0.0") } catch {}
        check((try? Data(contentsOf: original)) == originalBytes && (try? String(contentsOf: marker, encoding: .utf8)) == "original resource" &&
              !fm.fileExists(atPath: vendor.appendingPathComponent("versions/partial").path) &&
              (try? fm.destinationOfSymbolicLink(atPath: userLink.path)) == originalLink,
              "R1 failed Claude update restores full version tree and exact launcher")

        let snapshotPaths = fresh("snapshot"), source = snapshotPaths.userHome.appendingPathComponent("codex")
        try binary(source, version: "1.0.0", team: EngineInstall.teams["codex"]!)
        let sourceBytes = try Data(contentsOf: source)
        var snapshot = fixtureInstaller(snapshotPaths), verifiedPrivate = false
        snapshot.signature = { url, team in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("1.0.0") {
                let perms = (try? fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions]) as? Int
                verifiedPrivate = url != source && perms == 0o700
                try? Data("tampered after verification".utf8).write(to: source)
            }
            return text.contains("fixture-team=" + team) && text.contains("signature=valid")
        }
        mode = "correct"
        do { _ = try await snapshot.install(.codex, current: choice(source), newest: "2.0.0") } catch {}
        check(verifiedPrivate && (try? Data(contentsOf: snapshotPaths.codexHome.appendingPathComponent("1.0.0/codex"))) == sourceBytes,
              "R2 verification uses private snapshot despite source mutation")
        let existingPaths = fresh("existing"), existingOld = existingPaths.userHome.appendingPathComponent("codex")
        try binary(existingOld, version: "1.0.0", team: EngineInstall.teams["codex"]!)
        let poisoned = existingPaths.codexHome.appendingPathComponent("1.0.0/codex")
        try binary(poisoned, version: "1.0.0", team: "WRONGTEAM0")
        do { _ = try await fixtureInstaller(existingPaths).install(.codex, current: choice(existingOld), newest: "2.0.0") } catch {}
        check(existingPaths.codexHome.appendingPathComponent("current").resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent != "2.0.0",
              "R2 preexisting backup is reverified before adoption")

        let queuePaths = fresh("queue"), queueVendor = queuePaths.userHome.appendingPathComponent(".local/share/claude/versions/1.0.0")
        let queueLauncher = queuePaths.userHome.appendingPathComponent(".local/bin/claude")
        try binary(queueVendor, version: "1.0.0", team: EngineInstall.teams["claude"]!)
        try fm.createDirectory(at: queueLauncher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try link("claude", to: queueVendor, in: queueLauncher.deletingLastPathComponent())
        let queueOld = queuePaths.claudeConfigDirectory.appendingPathComponent("0.5.0/claude")
        try binary(queueOld, version: "0.5.0", team: EngineInstall.teams["claude"]!)
        try link("previous", to: queueOld, in: queuePaths.claudeConfigDirectory)
        var queued = fixtureInstaller(queuePaths), updating = false, overlap = false
        queued.signature = { url, team in
            let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if updating && t.contains("echo 0.5.0") { overlap = true }
            return t.contains("fixture-team=" + team) && t.contains("signature=valid")
        }
        queued.run = { url, args, home in
            if args == ["update"] { updating = true; try? await Task.sleep(for: .milliseconds(250)); updating = false; return nil }
            return await EngineAIUpdate.command(url, args, home: home)
        }
        let queueInstaller = queued
        let updateTask = Task { try? await queueInstaller.install(.claude, current: choice(queueVendor), newest: "2.0.0") }
        while !updating { try await Task.sleep(for: .milliseconds(5)) }
        let rollbackTask = Task<String?, Never> { do { return try await queueInstaller.rollback(.claude) } catch { print("R3 rollback error: " + error.localizedDescription); return nil } }
        _ = await updateTask.value; let queueResult = await rollbackTask.value
        check(!overlap && queueResult == "已退回 0.5.0", "R3 rollback validation waits for in-flight update")
        check(await EngineAIUpdate.command(queueLauncher, ["--version"], home: queuePaths.userHome) == "0.5.0\n", "W351 rollback launcher runs the old version")
        let bundledPaths = fresh("w351-bundled"), bundledClaude = bundledPaths.userHome.appendingPathComponent("bundled-claude")
        try binary(bundledClaude, version: "1.0.0", team: EngineInstall.teams["claude"]!)
        let bundledManual = try await fixtureInstaller(bundledPaths).install(.claude, current: choice(bundledClaude), newest: "2.0.0")
        check(bundledManual.contains("請手動更新") && !fm.fileExists(atPath: bundledPaths.userHome.appendingPathComponent(".local/bin/claude").path), "W351 missing launcher gives manual update")
        check(["1.0.0-preview", "1.0.0junk", "prefix 1.0.0 suffix", "1.0.0\n2.0.0", "1.0.0+build"].allSatisfy { EngineAIUpdate.version($0) == nil }, "stable version matches entire output")
        let pin = queuePaths.claudeConfigDirectory.appendingPathComponent("rollback-pin")
        check((try? fm.destinationOfSymbolicLink(atPath: pin.path)) == queueOld.path,
              "R4 only user rollback records explicit version pin")

        let stalePaths = fresh("stale"), staleOld = stalePaths.userHome.appendingPathComponent("codex")
        try binary(staleOld, version: "1.0.0", team: EngineInstall.teams["codex"]!)
        let newerCurrent = stalePaths.codexHome.appendingPathComponent("3.0.0/codex")
        try binary(newerCurrent, version: "3.0.0", team: EngineInstall.teams["codex"]!)
        try link("current", to: newerCurrent, in: stalePaths.codexHome)
        var staleRejected = false
        do { _ = try await fixtureInstaller(stalePaths).install(.codex, current: choice(staleOld), newest: "2.0.0") } catch { staleRejected = true }
        check(staleRejected && stalePaths.codexHome.appendingPathComponent("current").resolvingSymlinksInPath() == newerCurrent,
              "R3 stale queued update cannot downgrade current")
        let pointerPaths = fresh("pointers"), pointerOld = pointerPaths.userHome.appendingPathComponent("codex")
        try binary(pointerOld, version: "1.0.0", team: EngineInstall.teams["codex"]!)
        let priorPointer = pointerPaths.codexHome.appendingPathComponent("0.5.0/codex")
        try binary(priorPointer, version: "0.5.0", team: EngineInstall.teams["codex"]!)
        try link("previous", to: priorPointer, in: pointerPaths.codexHome)
        // A directory prevents the second rename, after old code already changed previous.
        try fm.createDirectory(at: pointerPaths.codexHome.appendingPathComponent("current/blocked"), withIntermediateDirectories: true)
        var pointerFailed = false
        do { _ = try await fixtureInstaller(pointerPaths).install(.codex, current: choice(pointerOld), newest: "2.0.0") } catch { pointerFailed = true }
        check(pointerFailed && (try? fm.destinationOfSymbolicLink(atPath: pointerPaths.codexHome.appendingPathComponent("previous").path)) == priorPointer.path,
              "R5 failed current publication preserves exact previous pointer")
        let transactionRoot = fresh("mid-publication").codexHome
        try fm.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: transactionRoot.appendingPathComponent("current").path, withDestinationPath: "1.0.0/codex")
        try fm.createSymbolicLink(atPath: transactionRoot.appendingPathComponent("previous").path, withDestinationPath: "0.5.0/codex")
        let nextTarget = transactionRoot.appendingPathComponent("2.0.0/codex")
        var midPublicationFailed = false
        do { try EngineInstall.pointers([("previous", nextTarget), ("current", nextTarget), (String(repeating: "x", count: 256), nextTarget)], in: transactionRoot) }
        catch { midPublicationFailed = true }
        check(midPublicationFailed && (try? fm.destinationOfSymbolicLink(atPath: transactionRoot.appendingPathComponent("current").path)) == "1.0.0/codex" &&
              (try? fm.destinationOfSymbolicLink(atPath: transactionRoot.appendingPathComponent("previous").path)) == "0.5.0/codex" &&
              (try? fm.contentsOfDirectory(atPath: transactionRoot.path).count) == 2,
              "R5 mid-publication rename failure restores both relative pointers")
        // Round 4 exercises faults at publication, lock acquisition and restoration.
        let b1Paths = fresh("b1"), b1Installer = fixtureInstaller(b1Paths)
        let b1Target = b1Paths.codexHome.appendingPathComponent("2.0.0/codex")
        try binary(b1Target, version: "2.0.0", team: EngineInstall.teams["codex"]!)
        let b1Bytes = try Data(contentsOf: b1Target), b1Inode = try fm.attributesOfItem(atPath: b1Target.path)[.systemFileNumber] as? UInt64
        let b1Stage = b1Paths.codexHome.appendingPathComponent(".stage-b1")
        try fm.createDirectory(at: b1Stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let damaged = b1Stage.appendingPathComponent("damaged")
        try Data("damaged incoming bytes".utf8).write(to: damaged)
        _ = try? await b1Installer.publish(damaged, kind: .codex, version: "2.0.0")
        check((try? Data(contentsOf: b1Target)) == b1Bytes && (try? fm.attributesOfItem(atPath: b1Target.path)[.systemFileNumber] as? UInt64) == b1Inode,
              "B1 existing valid version preserves every byte and inode")
        let a2Snapshot = b1Stage.appendingPathComponent("verified")
        try binary(a2Snapshot, version: "3.0.0", team: EngineInstall.teams["codex"]!)
        let a2Inode = try fm.attributesOfItem(atPath: a2Snapshot.path)[.systemFileNumber] as? UInt64
        var a2Installer = b1Installer, a2Verified = false
        a2Installer.signature = { url, team in
            a2Verified = url == a2Snapshot && (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) == a2Inode
            return await b1Installer.signature(url, team)
        }
        let a2Target = try await a2Installer.publish(a2Snapshot, kind: .codex, version: "3.0.0")
        check(a2Verified && (try? fm.attributesOfItem(atPath: a2Target.path)[.systemFileNumber] as? UInt64) == a2Inode && !fm.fileExists(atPath: a2Snapshot.path),
              "A2 publish adopts exactly the verified private inode")
        let gate = EngineRuntimeSelection.gates["grok"]!
        // Acquire off the main thread; cancellation must return before the holder releases.
        let held = await Task.detached { gate.wait(timeout: .now() + 1) == .success }.value
        let waiter = Task { () -> Bool in
            do { try await EngineRuntimeSelection.acquire(gate); gate.signal(); return false }
            catch { return error is CancellationError }
        }
        waiter.cancel()
        try await Task.sleep(for: .milliseconds(100))
        if held { gate.signal() }
        check(await waiter.value, "B2 cancelled lock wait stops without consuming holder permit")
        let timeoutGate = DispatchSemaphore(value: 0), started = Date()
        let pulse = Task { try? await Task.sleep(for: .milliseconds(50)); return true }
        var timeoutReported = false
        do { try await EngineRuntimeSelection.acquire(timeoutGate) } catch { timeoutReported = error.localizedDescription == "另一個更新正在進行" }
        let pulsed = await pulse.value
        check(timeoutReported && Date().timeIntervalSince(started) < 4 && pulsed, "B2 lock timeout reports busy while main actor stays responsive")
        var reentryRejected = false, probeReentryRejected = false
        try await EngineRuntimeSelection.withGate(.grok) {
            do { _ = try await b1Installer.rollback(.grok) } catch { reentryRejected = error.localizedDescription == "另一個更新正在進行" }
            do { _ = try await EngineRuntimeSelection.resolveAsync(kind: .grok, bundled: source, userHome: b1Paths.userHome, engineHome: b1Paths.grokHome, environment: env) }
            catch { probeReentryRejected = error.localizedDescription == "另一個更新正在進行" }
        }
        check(reentryRejected && probeReentryRejected, "B2 same flow rejects update and probe lock reentry")
        let b3Root = fresh("b3").codexHome
        try fm.createDirectory(at: b3Root, withIntermediateDirectories: true)
        for name in ["previous", "current"] { try fm.createSymbolicLink(atPath: b3Root.appendingPathComponent(name).path, withDestinationPath: "old/" + name) }
        var writes: [String: Int] = [:], b3Error = ""
        do {
            try EngineInstall.pointers([("previous", nextTarget), ("current", nextTarget), (String(repeating: "x", count: 256), nextTarget)], in: b3Root, replace: { source, target in
                let name = URL(fileURLWithPath: target).lastPathComponent
                writes[name, default: 0] += 1
                if name == "previous" && writes[name] == 2 { return -1 }
                return rename(source, target)
            })
        } catch { b3Error = error.localizedDescription }
        check((try? fm.destinationOfSymbolicLink(atPath: b3Root.appendingPathComponent("current").path)) == "old/current" && b3Error.contains("previous"),
              "B3 restore failure still attempts remaining pointers and names failed step")
        let b3Paths = fresh("b3-vendor"), b3Vendor = b3Paths.userHome.appendingPathComponent(".local/share/claude")
        let b3Old = b3Vendor.appendingPathComponent("versions/1.0.0"), b3Link = b3Paths.userHome.appendingPathComponent(".local/bin/claude")
        try binary(b3Old, version: "1.0.0", team: EngineInstall.teams["claude"]!)
        try fm.createDirectory(at: b3Link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try link("claude", to: b3Old, in: b3Link.deletingLastPathComponent())
        var b3Installer = fixtureInstaller(b3Paths), b3Stage: URL?
        b3Installer.run = { url, args, home in
            if args == ["update"] {
                b3Stage = url.deletingLastPathComponent()
                _ = rename(b3Stage!.appendingPathComponent("vendor-old").path, b3Stage!.appendingPathComponent("vendor-lost").path)
                try? link("claude", to: nextTarget, in: b3Link.deletingLastPathComponent())
                return nil
            }
            return await EngineAIUpdate.command(url, args, home: home)
        }
        var b3VendorError = ""
        do { _ = try await b3Installer.install(.claude, current: choice(b3Old), newest: "2.0.0") } catch { b3VendorError = error.localizedDescription }
        check((try? fm.destinationOfSymbolicLink(atPath: b3Link.path)) == b3Old.path && b3VendorError.contains("還原版本目錄") && b3Stage.map { fm.fileExists(atPath: $0.path) && b3VendorError.contains($0.path) } == true,
              "B3 vendor restore failure still restores launcher and retains recovery stage")
        let configRoot = URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"]!), configMarker = configRoot.appendingPathComponent(".last-update-result.json")
        try Data("original update result".utf8).write(to: configMarker)
        let b4Script = b1Stage.appendingPathComponent("update-fixture")
        try Data("#!/bin/sh\nmkdir -p \"$CLAUDE_CONFIG_DIR\"\necho changed > \"$CLAUDE_CONFIG_DIR/.last-update-result.json\"\nexit 1\n".utf8).write(to: b4Script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: b4Script.path)
        _ = await EngineAIUpdate.command(b4Script, ["update"], home: b1Paths.userHome)
        check((try? String(contentsOf: configMarker, encoding: .utf8)) == "original update result" && fm.fileExists(atPath: b1Stage.appendingPathComponent("update-config/.last-update-result.json").path),
              "B4 updater config writes stay in private stage")

        let update = EngineAIUpdate(defaults: defaults)
        update.rollbackAction = { try await installer.rollback($0) }
        var checks = 0, installs = 0
        update.install = { _, _ in installs += 1; return "已更新" }
        let daily: EngineAIUpdate.Source = { kind in checks += 1; return ("1.0.0", kind == .codex ? "2.0.0" : "1.0.0", nil) }
        let day = Date(timeIntervalSince1970: 1_000_000)
        await update.backgroundCheck(source: daily, now: day)
        check(update.hasNewVersion && checks == 3 && installs == 0 && update.rows.isEmpty && update.message.isEmpty, "daily check lights dot only and never installs")
        await update.backgroundCheck(source: daily, now: day.addingTimeInterval(3600))
        check(checks == 3 && EngineAIUpdate(defaults: defaults).hasNewVersion, "daily check persists cadence and dot across restart")
        await update.backgroundCheck(source: { _ in ("2.0.0", "2.0.0", nil) }, now: day.addingTimeInterval(86400))
        check(!update.hasNewVersion && update.rows.isEmpty, "no new versions clears dot without message")
        update.install = { kind, newest in try await installer.install(kind, current: choice(oldCodex), newest: newest) }
        update.source = { kind in ("1.0.0", kind == .codex ? "2.0.0" : "1.0.0", nil) }
        var modelEnv = env; modelEnv["TATWO_ULTRAWORK_CHAT_FIXTURE"] = "settings"
        let page = ChatPageModel(environment: modelEnv); page.engineQuotaDetails = [:]
        let tap = ChatGPTTap(transport: FakeTapPod(running: true), connection: .needsLogin)
        let buttonShot = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update), size: CGSize(width: 1040, height: 760), scheme: .light)!
        await W214Acceptance.settle(buttonShot)
        check(TatwoComposerModeAcceptance.press("login.aiUpdate", in: buttonShot), "real update button enters selection before installing")
        for _ in 0..<100 { if update.selecting { break }; try await Task.sleep(for: .milliseconds(20)) }
        await W214Acceptance.settle(buttonShot)
        check(update.selecting && update.selected == ["codex"] && update.rows["codex"]?.contains("可更新") == true, "new version selected and latest not selected")
        update.rows["grok"] = EngineInstall.manualGrok
        let untouchedClaude = update.rows["claude"]
        check(TatwoComposerModeAcceptance.press("login.aiUpdate.installSelected", in: buttonShot), "real update button installs validated fake tarball")
        for _ in 0..<200 { if update.rows["codex"]?.contains("已更新") == true && !update.running { break }; try await Task.sleep(for: .milliseconds(50)) }
        check(update.rows["codex"]?.contains("已更新") == true && update.rollbackVersions["codex"] == "1.0.0", "updated row exposes retained rollback version")
        check(update.rows["grok"] == EngineInstall.manualGrok && update.rows["claude"] == untouchedClaude, "W314 unselected Grok manual message and latest Claude unchanged")
        buttonShot.close()
        update.proposals = [.init(id: 0, old: "gpt-5.6-sol", suggested: "gpt-6.1-sol")]
        update.rows["claude"] = "1.0.0 → 2.0.0 已更新"; update.rows["grok"] = EngineInstall.manualGrok
        update.message = "更新完成。正在用的對話不會被打斷。"
        let theme = TatwoThemeSelfTestScope(); defer { theme.restore() }
        for dark in [false, true] {
            theme.use(dark ? .aurora : .fable5)
            for state in ["updated", "dot"] {
                update.hasNewVersion = state == "dot"
                let shot = GlobalDMChatAcceptance.renderSync(TatwoSettingsShell(section: .constant(.modelAccess)) { EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update) }, size: CGSize(width: 1040, height: 760), scheme: dark ? .dark : .light)!
                await W214Acceptance.settle(shot)
                let text = W214Acceptance.text(shot)
                check(text.contains("GPT-5.6 Sol") && text.contains("GPT-6.1 Sol") && !text.contains("gpt-5.6-sol"), "proposal uses model names \(dark) \(state)")
                check(W214Acceptance.node("login.aiUpdate.rollback.codex", shot) != nil && text.contains("退回 1.0.0"), "rollback button visible \(dark) \(state)")
                check((W214Acceptance.node("login.aiUpdate.dot", shot) != nil) == (state == "dot"), "dot visibility \(dark) \(state)")
                try W214Acceptance.save(shot, (dark ? "dark-" : "light-") + state, artifacts)
                if dark && state == "dot" {
                    check(TatwoComposerModeAcceptance.press("login.aiUpdate.rollback.codex", in: shot), "real rollback button")
                    for _ in 0..<100 { if update.rows["codex"] == "已退回 1.0.0" { break }; try await Task.sleep(for: .milliseconds(30)) }
                    check(update.rows["codex"] == "已退回 1.0.0" && update.rollbackVersions["codex"] == nil, "real rollback button restores previous version")
                }
                shot.close()
            }
        }
        func enabled(_ id: String, _ shot: GlobalDMChatAcceptance.Rendered) -> Bool {
            guard let node = W214Acceptance.node(id, shot) else { return false }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            typealias Get = @convention(c) (AnyObject, Selector) -> Bool
            return node.responds(to: selector) && unsafeBitCast(node.method(for: selector), to: Get.self)(node, selector)
        }
        var installed: [String] = [], selectionChecks = 0
        update.install = { kind, newest in installed.append(kind.rawValue); return "1.0.0 → \(newest) 已更新" }
        update.source = { kind in
            selectionChecks += 1
            return ("1.0.0", kind == .codex ? "2.0.0" : kind == .claude ? "1.0.0" : nil, nil)
        }
        await update.check()
        let rulesShot = GlobalDMChatAcceptance.renderSync(EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update), size: CGSize(width: 1040, height: 760), scheme: .light)!
        await W214Acceptance.settle(rulesShot)
        check(update.selected == ["codex"] && installed.isEmpty && selectionChecks == 3, "default selection checks versions without installing")
        check(!enabled("login.aiUpdate.select.claude", rulesShot) && !enabled("login.aiUpdate.select.grok", rulesShot) && W214Acceptance.node("login.aiUpdate.select.chatgpt", rulesShot) == nil, "latest unknown and ChatGPT cannot select")
        let logo = W214Acceptance.node("login.aiUpdate.select.codex", rulesShot)!
        check(GlobalDMChatAcceptance.attribute(logo, "accessibilityLabel", "AXDescription") as? String == "不要更新 Codex", "selected logo accessible label")
        check(TatwoComposerModeAcceptance.press("login.aiUpdate.select.codex", in: rulesShot), "real logo toggles selection")
        await W214Acceptance.settle(rulesShot)
        check(update.selected.isEmpty && update.rows["codex"]?.contains("可更新（你沒勾）") == true && !enabled("login.aiUpdate.installSelected", rulesShot) && W214Acceptance.text(rulesShot).contains("更新所選（0）"), "zero selection disables install")
        let keyboardLogo = W214Acceptance.node("login.aiUpdate.select.codex", rulesShot)!
        (keyboardLogo as AnyObject).setAccessibilityFocused?(true)
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rulesShot.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        rulesShot.window.sendEvent(space)
        await W214Acceptance.settle(rulesShot)
        check(update.selected == ["codex"], "focused logo toggles with Space key")
        (keyboardLogo as AnyObject).setAccessibilityFocused?(false)
        rulesShot.window.makeFirstResponder(nil)
        if update.selected.contains("codex") { _ = TatwoComposerModeAcceptance.press("login.aiUpdate.select.codex", in: rulesShot) }
        await update.installSelected()
        check(installed.isEmpty && update.selecting, "zero selection never installs")
        check(TatwoComposerModeAcceptance.press("login.aiUpdate.cancel", in: rulesShot) && installed.isEmpty && !update.selecting, "cancel never installs")
        await W214Acceptance.settle(rulesShot)
        check(W214Acceptance.text(rulesShot).contains("刷新額度") && !W214Acceptance.text(rulesShot).contains("重新檢查") && enabled("login.refreshQuota", rulesShot), "refresh quota renamed button")
        rulesShot.close()
        await update.check(source: { kind in (nil, kind == .codex ? "2.0.0" : nil, nil) })
        update.toggle("codex")
        check(update.selected.isEmpty && update.rows["codex"]?.contains("目前版本查不到") == true, "unknown current cannot select even with newest version")
        update.cancel()
        await update.check()
        check(update.selected == ["codex"], "selection resets on next check")
        update.cancel()
        for themeID in [TatwoThemeID.fable5, .aurora] {
            for dark in [false, true] {
                theme.use(themeID)
                update.source = { kind in ("1.0.0", kind == .grok ? nil : "2.0.0", nil) }
                await update.check()
                installed = []
                let shot = GlobalDMChatAcceptance.renderSync(TatwoSettingsShell(section: .constant(.modelAccess)) { EngineLoginCard(model: page, chatGPT: tap, aiUpdate: update) }, size: CGSize(width: 1040, height: 760), scheme: dark ? .dark : .light)!
                await W214Acceptance.settle(shot)
                check(TatwoComposerModeAcceptance.press("login.aiUpdate.select.claude", in: shot) && update.selected == ["codex"], "only chosen logo selected \(themeID.rawValue) \(dark)")
                let untouchedRows = update.rows.filter { $0.key != "codex" }
                await W214Acceptance.settle(shot)
                let prefix = themeID.rawValue + (dark ? "-dark-" : "-light-")
                try W214Acceptance.save(shot, prefix + "selection", artifacts)
                check(TatwoComposerModeAcceptance.press("login.aiUpdate.installSelected", in: shot), "install selection button \(prefix)")
                for _ in 0..<100 { if !update.running && !update.selecting { break }; try await Task.sleep(for: .milliseconds(20)) }
                await W214Acceptance.settle(shot)
                check(installed == ["codex"] && update.rows.filter { $0.key != "codex" } == untouchedRows && update.message.contains("已更新：Codex；Claude Code 照你的選擇不更新"), "only selected installed and skipped summary \(prefix)")
                try W214Acceptance.save(shot, prefix + "complete", artifacts)
                shot.close()
            }
        }
        return failed == 0
    }
}
#endif
