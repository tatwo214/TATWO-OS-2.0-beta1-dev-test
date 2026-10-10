import Foundation

enum TurnArtifactsGit {
    static func paths(_ status: String) -> [String] {
        let fields = status.split(separator: "\0", omittingEmptySubsequences: true)
        var result: [String] = []
        var i = 0
        while i < fields.count && result.count <= TurnArtifacts.maxPaths {
            let field = fields[i]
            if field.count >= 4 {
                result.append(String(field.dropFirst(3)))
                if field.prefix(2).contains("R") || field.prefix(2).contains("C") { i += 1 }
            }
            i += 1
        }
        return result
    }
}
