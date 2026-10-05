import Foundation

enum ChatProviderModelIdentity {
    static func lookupKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\[1m\]$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
