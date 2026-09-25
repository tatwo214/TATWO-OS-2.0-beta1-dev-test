// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoChatRouteProfile.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public struct TatwoChatRouteProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let displayName: String
  public let family: String
  public let engine: TatwoNativeChatEngine
  public let runtimeAdapter: TatwoChatRuntimeAdapter
  public let canonicalModelSlug: String
  public let modelArgument: String?
  public let contextWindowLabel: String
  public let supportsImageInput: Bool
  public let pluginFit: String
  public let sessionRisk: String
  public let defaultEffort: TatwoCodexReasoningEffort
  public let allowedEfforts: [TatwoCodexReasoningEffort]
  public let defaultSpeedTier: TatwoModelSpeedTier?
  public let allowedSpeedTiers: [TatwoModelSpeedTier]
  public let notes: [String]

  public init(
    id: String,
    displayName: String,
    family: String,
    engine: TatwoNativeChatEngine,
    runtimeAdapter: TatwoChatRuntimeAdapter? = nil,
    canonicalModelSlug: String? = nil,
    modelArgument: String?,
    contextWindowLabel: String,
    supportsImageInput: Bool,
    pluginFit: String,
    sessionRisk: String,
    defaultEffort: TatwoCodexReasoningEffort,
    allowedEfforts: [TatwoCodexReasoningEffort],
    defaultSpeedTier: TatwoModelSpeedTier? = nil,
    allowedSpeedTiers: [TatwoModelSpeedTier] = [],
    notes: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.engine = engine
    self.runtimeAdapter = runtimeAdapter ?? (engine == .claude ? .claudeCLI : .codexExec)
    self.canonicalModelSlug = canonicalModelSlug ?? modelArgument ?? id
    self.modelArgument = modelArgument
    self.contextWindowLabel = contextWindowLabel
    self.supportsImageInput = supportsImageInput
    self.pluginFit = TatwoPrivacyRedactor.redacted(pluginFit)
    self.sessionRisk = TatwoPrivacyRedactor.redacted(sessionRisk)
    self.defaultEffort = defaultEffort
    self.allowedEfforts = allowedEfforts
    self.defaultSpeedTier = defaultSpeedTier
    self.allowedSpeedTiers = allowedSpeedTiers
    self.notes = notes.map { TatwoPrivacyRedactor.redacted($0) }
  }

  public var menuSubtitle: String {
    let image = supportsImageInput ? "image ok" : "text-first"
    return "\(family) · \(contextWindowLabel) · \(image) · \(pluginFit)"
  }

  public var supportsNativeReasoningControl: Bool {
    !allowedEfforts.isEmpty
  }

  public var supportsNativeSpeedControl: Bool {
    !allowedSpeedTiers.isEmpty
  }

  public func acceptsAttachmentPath(_ path: String) -> Bool {
    acceptsAttachmentPath(
      path,
      interactionMode: .standard,
      requiresTatwoComputerHost: false)
  }

  public func acceptsAttachmentPath(
    _ path: String,
    interactionMode: TatwoChatInteractionMode,
    requiresTatwoComputerHost: Bool
  ) -> Bool {
    !TatwoChatCommandPlanner.isLikelyImagePath(path)
      || imageTransportCapability(
        interactionMode: interactionMode,
        requiresTatwoComputerHost: requiresTatwoComputerHost) != .none
  }

  public func imageTransportCapability(
    interactionMode: TatwoChatInteractionMode = .standard,
    requiresTatwoComputerHost: Bool = false
  ) -> TatwoImageTransportCapability {
    guard supportsImageInput else { return .none }
    switch runtimeAdapter {
    case .nativeAgent:
      return .none
    case .codexExec:
      return .codexExecImage
    case .claudeCLI:
      return .claudeReadRescue
    case .grokCLI:
      return .grokPromptJSONImage
    case .minimaxDirect:
      return .none
    case .gatewayDirect:
      return engine == .claude ? .claudeReadRescue : .none
    case .unavailable:
      return .none
    }
  }

  public func nativeReasoningEffort(for requested: TatwoCodexReasoningEffort) -> TatwoCodexReasoningEffort? {
    guard supportsNativeReasoningControl else { return nil }
    if allowedEfforts.contains(requested) { return requested }
    if allowedEfforts.contains(defaultEffort) { return defaultEffort }
    return allowedEfforts.first
  }

  public func nativeSpeedTier(for requested: TatwoModelSpeedTier?) -> TatwoModelSpeedTier? {
    guard supportsNativeSpeedControl else { return nil }
    if let requested, allowedSpeedTiers.contains(requested) { return requested }
    if let defaultSpeedTier, allowedSpeedTiers.contains(defaultSpeedTier) { return defaultSpeedTier }
    return allowedSpeedTiers.first
  }

  public static let defaults: [TatwoChatRouteProfile] = [
    .init(
      id: "gpt-5.6-sol",
      displayName: "GPT-5.6 Sol",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-sol",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "現代主力 host / tools",
      sessionRisk: "中：新 route 需 smoke",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["GPT-5.6 現代主力；本機 gateway catalog 與 Codex session 已查證", "live catalog 宣告 text + image"]),
    .init(
      id: "gpt-5.6-terra",
      displayName: "GPT-5.6 Terra",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-terra",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "審查 / 驗證",
      sessionRisk: "中：需 active Codex session",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["OS 以 Codex exec 經單一 model_gateway 調度；保留 active Codex Authorization", "live catalog 宣告 text + image"]),
    .init(
      id: "gpt-5.6-luna",
      displayName: "GPT-5.6 Luna",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-luna",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "一般 Chat / 替代路線",
      sessionRisk: "中：需 active Codex session",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["OS 以 Codex exec 經單一 model_gateway 調度；保留 active Codex Authorization", "live catalog 宣告 text + image"]),
    .init(   // 2026-09-05 GPT-6 發布；打包的 codex 0.153.2 的 model/list 已列 gpt-6-astra
      id: "gpt-6-astra",
      displayName: "GPT-6",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-6-astra",
      contextWindowLabel: "長 context",
      supportsImageInput: true,
      pluginFit: "最佳 host / tools",
      sessionRisk: "低",
      defaultEffort: .medium,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["GPT-6（codex 模型名 gpt-6-astra）"]),
    .init(
      id: "grok-build",
      displayName: "Grok 4.7",
      family: "Grok native",
      engine: .codex,
      runtimeAdapter: .grokCLI,
      modelArgument: "grok-4.7",   // 內建 grok 0.2.11 的 `grok models` 已列 grok-4.7（2026-09-23 使用者：4.7 大幅超越 4.6，取代）；"grok-build" 是 route id 不是模型
      contextWindowLabel: "news/refute",
      supportsImageInput: true,
      pluginFit: "反例/外部查證",
      sessionRisk: "中",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["外部消息與反方路線；需要回 Codex 驗證", "App 內建 Grok CLI adapter 以 --prompt-json 原生轉送圖片 content blocks 與 reasoning effort；provider 未回 effective attestation 時不得宣稱已實際生效"]),
    .init(
      id: "fable5.1",
      displayName: "fable5.1",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "fable-5.1",
      // 憲法 v4 §4：主導預設 Fable 5.1。CLI 需 vendor 全名。
      modelArgument: "claude-fable-5-1",
      contextWindowLabel: "200k",
      supportsImageInput: true,
      pluginFit: "規劃/語意 lead",
      sessionRisk: "低：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["憲法 §4 主導預設", "Claude CLI adapter 原生轉送 effort；只證明 forwarded，不把缺少 provider effective attestation 說成已生效"]),
    .init(
      id: "sonnet5",
      displayName: "sonnet5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "sonnet-5",
      modelArgument: "sonnet-5",
      contextWindowLabel: "review",
      supportsImageInput: true,
      pluginFit: "Loops Supervisor",
      sessionRisk: "中：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["N9 預設 Loops 副審", "active route 是 sonnet-5；Claude CLI adapter 原生轉送 effort，圖片 turn 使用 OS 管理的 Claude CLI Read 救援"]),
    .init(   // 2026-09-23 使用者：Opus 5.5 取代 Opus 5；需要內建 Claude agent SDK ≥ 0.3.280（Claude Code 2.1.280）
      id: "opus5.5",
      displayName: "Claude Opus 5.5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "opus-5.5",
      modelArgument: "claude-opus-5-5",
      contextWindowLabel: "judge",
      supportsImageInput: true,
      pluginFit: "Goal Judge / 細修",
      sessionRisk: "高：App 內建 Claude CLI；成本/長 context 需 gate",
      defaultEffort: .xhigh,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["高風險裁決與細修", "Claude CLI adapter 原生轉送 effort；provider 未回 effective attestation 時不得宣稱已實際生效，成本/上下文仍需人類 gate"]),
    .init(
      id: "codex-auto-review",
      displayName: "Codex Auto Review",
      family: "Codex",
      engine: .codex,
      modelArgument: "gpt-5.6-terra",
      contextWindowLabel: "review",
      supportsImageInput: true,
      pluginFit: "diff review",
      sessionRisk: "低",
      defaultEffort: .medium,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["review lane，不是獨立模型權威"]),
  ]

  private static func normalizedLookupKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  /// 2026-09-23 使用者：「只留 GPT-5.6 以上、Opus 5.5、Sonnet 5、Fable 5.1、Grok 4.7 等最新的模型」。
  /// 退役的模型不再出現在選單；舊討論串或設定裡存的舊 ID 改走接替的新模型（鍵是去掉符號的小寫）。
  static let retiredReplacements: [String: String] = [
    "gpt55": "gpt56sol", "gpt54": "gpt56sol",
    "fable5": "fable51", "claudefable5": "fable51",
    "haiku": "sonnet5", "haiku45": "sonnet5", "claudehaiku45": "sonnet5",
    "opus5": "opus55", "claudeopus5": "opus55",
    "minimaxm3": "gpt56luna",
    "grok46": "grokbuild", "grok45": "grokbuild",
  ]

  public static func resolve(_ id: String) -> TatwoChatRouteProfile {
    let needle = normalizedLookupKey(id)
    let compatibilityAliases: [String: String] = [
      "fable": "fable51",
      "sonnet": "sonnet5",
      "sonnet46": "sonnet5",
      "claudesonnet46": "sonnet5",
      "claudesonnet5": "sonnet5",
      "opus": "opus55",
    ].merging(retiredReplacements) { current, _ in current }
    let resolvedNeedle = compatibilityAliases[needle] ?? needle
    if let profile = defaults.first(where: { profile in
      [profile.id, profile.canonicalModelSlug, profile.modelArgument, profile.displayName, profile.family]
        .compactMap { $0 }
        .contains { normalizedLookupKey($0) == resolvedNeedle }
    }) {
      return profile
    }

    let requestedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let unavailableID = requestedID.isEmpty ? "unavailable" : requestedID
    return TatwoChatRouteProfile(
      id: unavailableID,
      displayName: requestedID.isEmpty ? "Unavailable route" : requestedID,
      family: "Unavailable",
      engine: .codex,
      runtimeAdapter: .unavailable,
      canonicalModelSlug: unavailableID,
      modelArgument: nil,
      contextWindowLabel: "not installed",
      supportsImageInput: false,
      pluginFit: "不可執行",
      sessionRisk: "blocked",
      defaultEffort: .low,
      allowedEfforts: [],
      notes: ["未知或已退役 route；fail closed，不自動改送其他模型"])
  }
}
