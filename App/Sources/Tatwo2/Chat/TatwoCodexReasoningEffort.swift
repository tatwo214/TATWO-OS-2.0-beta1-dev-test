// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoCodexReasoningEffort.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoCodexReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case low
  case medium
  case high
  case xhigh
  case max
  case ultra

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    case .xhigh: return "超高"
    case .max: return "最高"
    case .ultra: return "Ultra（自動分派）"
    }
  }

  public var compactDisplayName: String {
    switch self {
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    case .xhigh: return "超高"
    case .max: return "最高"
    case .ultra: return "Ultra"
    }
  }

  public var codexRawValue: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh: return "xhigh"
    case .max: return "max"
    case .ultra: return "ultra"
    }
  }

  public var claudeRawValue: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh: return "xhigh"
    // Claude 的既有最高對應是 xhigh；不把 Codex 專屬值交給 Claude。
    case .max, .ultra: return "xhigh"
    }
  }

  public var gatewayReasoningValue: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh: return "xhigh"
    case .max: return "max"
    case .ultra: return "ultra"
    }
  }

  public var codexArguments: [String] {
    ["-c", "model_reasoning_effort=\"\(codexRawValue)\""]
  }

  public var claudeArguments: [String] {
    ["--effort", claudeRawValue]
  }
}
