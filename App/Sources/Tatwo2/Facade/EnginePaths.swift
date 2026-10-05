// engine-login 房間：集中 Tatwo2 內建引擎的獨立登入根與二進位路徑；合流時以 engine-bundle 房間為準。
import Foundation

struct EnginePaths: Sendable {
    let appSupportRoot: URL
    let enginesRoot: URL
    let codexHome: URL
    let claudeConfigDirectory: URL
    let grokHome: URL
    let runtimeBinDirectory: URL
    private let bundledCodex: URL
    private let bundledClaude: URL
    private let bundledGrok: URL
    private let engineEnvironment: [String: String]
    var codexExecutable: URL { selection(for: .codex).executable }
    var claudeExecutable: URL { selection(for: .claude).executable }
    var grokExecutable: URL { selection(for: .grok).executable }
    let userHome: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceRoot: URL? = nil
    ) {
        let fileManager = FileManager.default
        let liveRoot = environment["TATWO2_LIVE_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        let defaultAppSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("tatwo2", isDirectory: true)
        let supportRoot = environment["TATWO2_ENGINES_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }

        if let supportRoot {
            self.appSupportRoot = supportRoot.deletingLastPathComponent()
            self.enginesRoot = supportRoot
        } else {
            self.appSupportRoot = liveRoot?.deletingLastPathComponent() ?? defaultAppSupport
            self.enginesRoot = self.appSupportRoot.appendingPathComponent(
                "engines",
                isDirectory: true
            )
        }

        self.codexHome = enginesRoot.appendingPathComponent("codex", isDirectory: true)
        self.claudeConfigDirectory = enginesRoot.appendingPathComponent(
            "claude",
            isDirectory: true
        )
        self.grokHome = enginesRoot.appendingPathComponent("grok", isDirectory: true)

        let resources = resourceRoot
            ?? environment["TATWO2_RESOURCES_ROOT"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? Bundle.main.resourceURL
            ?? Bundle.main.bundleURL
        self.engineEnvironment = environment
        self.runtimeBinDirectory = environment["TATWO2_RUNTIME_BIN"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? resources.appendingPathComponent(
            "runtime/bin",
            isDirectory: true
        )
        self.bundledCodex = runtimeBinDirectory.appendingPathComponent("codex")
        self.bundledGrok = runtimeBinDirectory.appendingPathComponent("grok")
        self.bundledClaude = resources
            .appendingPathComponent("claude-sidecar", isDirectory: true)
            .appendingPathComponent(
                "node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
            )
        self.userHome = environment["HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fileManager.homeDirectoryForCurrentUser
    }

    private func runtimeURLs(for kind: ClaudeSidecar.Kind) -> (bundled: URL, home: URL) {
        switch kind {
        case .codex: return (bundledCodex, codexHome)
        case .claude: return (bundledClaude, claudeConfigDirectory)
        case .grok: return (bundledGrok, grokHome)
        }
    }
    func cachedSelection(for kind: ClaudeSidecar.Kind) -> EngineRuntimeSelection.Choice {
        let urls = runtimeURLs(for: kind)
        return EngineRuntimeSelection.cached(kind: kind, bundled: urls.bundled, userHome: userHome,
            engineHome: urls.home, environment: engineEnvironment)
    }
    func selectionAsync(for kind: ClaudeSidecar.Kind, forceVerification: Bool = false) async throws -> EngineRuntimeSelection.Choice {
        let urls = runtimeURLs(for: kind)
        return try await EngineRuntimeSelection.resolveAsync(kind: kind, bundled: urls.bundled, userHome: userHome,
            engineHome: urls.home, environment: engineEnvironment, forceVerification: forceVerification)
    }
    func selection(for kind: ClaudeSidecar.Kind, forceVerification: Bool = false) -> EngineRuntimeSelection.Choice {
        let urls = runtimeURLs(for: kind)
        return EngineRuntimeSelection.resolve(kind: kind, bundled: urls.bundled, userHome: userHome,
            engineHome: urls.home, environment: engineEnvironment, forceVerification: forceVerification)
    }

    var codexAuth: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    var claudeAccountFile: URL {
        claudeConfigDirectory.appendingPathComponent(".claude.json")
    }

    var fallbackClaudeAccountFile: URL {
        userHome.appendingPathComponent(".claude.json")
    }

    var grokAuth: URL {
        grokHome
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    func createPrivateDirectories() {
        for directory in [enginesRoot, codexHome, claudeConfigDirectory, grokHome] {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
