import Foundation

// W183 R1b：ChatGPT 手腳的秘密遮蔽——跨切點、跨分頁也遮得住（審查：分頁可繞過遮蔽、輸出原文落盤）。
//
// - 秘密行（HandsSecretLines，跟 Engines/chatgpt-hands/fsop.mjs 的 secretLineMask 同一套規則）：私鑰區段（BEGIN 到 END，
//   沒有 END 就一直遮到最後）、整行像金鑰內文的 base64（≥ 60 字、大小寫與數字都有；後面緊接的短 base64 行是它的最後一行）、
//   行尾是 Bearer 的下一行開頭那個字。一定要整個檔（或整段輸出）從頭一起算，再切頁／截斷：頁從私鑰中間開始也遮得住。
// - 串流遮蔽（HandsStreamRedactor）：指令輸出在寫進輸出區（磁碟）之前就遮好——跨 chunk 帶著狀態（還在私鑰裡、上一行結尾是 Bearer），
//   只處理完整的行（太長的行在空白處切），最後一段在結束時處理。輸出區、job_output、run_command 回的都是遮過的。

enum HandsSecretLines {
    enum Kind: Equatable { case all, firstToken }
    static let masked = "[已遮蔽：私鑰／金鑰內容]"

    struct State: Equatable {
        var inside = false
        var body = false
        var bearer = false
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern)) ?? (try! NSRegularExpression(pattern: "[\\s\\S]*"))
    }
    private static let pemBegin = regex("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")
    private static let pemEnd = regex("-----END [A-Z0-9 ]*PRIVATE KEY-----")
    private static let bearerEnd = regex("(?i)\\bBearer\\s*$")
    private static let firstToken = regex("^(\\s*)[A-Za-z0-9._~+/=\\-]{8,}")

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> NSRange? {
        let range = pattern.rangeOfFirstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        return range.location == NSNotFound ? nil : range
    }

    private static func isBase64(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "+" || scalar == "/"
    }

    /// 只有 base64 字元（結尾最多兩個 =），至少 minimum 個字。
    private static func base64Line(_ text: String, minimum: Int) -> (ok: Bool, upper: Bool, lower: Bool, digit: Bool) {
        var body = Substring(text)
        var padding = 0
        while body.hasSuffix("="), padding < 2 { body = body.dropLast(); padding += 1 }
        var upper = false, lower = false, digit = false, count = 0
        for scalar in body.unicodeScalars {
            guard isBase64(scalar) else { return (false, false, false, false) }
            if scalar >= "A" && scalar <= "Z" { upper = true } else if scalar >= "a" && scalar <= "z" { lower = true }
            else if scalar >= "0" && scalar <= "9" { digit = true }
            count += 1
        }
        return (count >= minimum, upper, lower, digit)
    }

    static func keyLine(_ trimmed: String) -> Bool {
        let check = base64Line(trimmed, minimum: 60)
        return check.ok && check.upper && check.lower && check.digit
    }

    /// 一行的判定（帶著前面各行留下的狀態）。
    static func classify(_ line: String, state: inout State) -> Kind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var kind: Kind?
        var isBody = false
        if state.inside {
            kind = .all
            if matches(pemEnd, line) != nil { state.inside = false }
        } else if let begin = matches(pemBegin, line) {
            kind = .all
            let after = (line as NSString).substring(from: begin.location)
            state.inside = matches(pemEnd, after) == nil
        } else if matches(pemEnd, line) != nil {
            kind = .all
        } else if keyLine(trimmed) {
            kind = .all
            isBody = true
        } else if state.body && base64Line(trimmed, minimum: 4).ok {
            kind = .all   // 內文的最後一行（較短）；之後就不算內文了
        } else if state.bearer, matches(firstToken, line) != nil {
            kind = .firstToken
        }
        state.body = isBody
        state.bearer = matches(bearerEnd, line) != nil
        return kind
    }

    static func mask(_ lines: [String]) -> [Kind?] {
        var state = State()
        return lines.map { classify($0, state: &state) }
    }

    static func apply(_ line: String, _ kind: Kind?) -> String {
        switch kind {
        case .all?: return masked
        case .firstToken?:
            return firstToken.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1[已遮蔽]")
        case nil: return line
        }
    }

    /// 整段文字一起算、逐行遮（行數不變）。
    static func maskText(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let kinds = mask(lines)
        return zip(lines, kinds).map { apply($0, $1) }.joined(separator: "\n")
    }

    /// git diff 的輸出：每個檔一段（`diff --git` 開頭）；段裡只要有一行像私鑰／金鑰內文（去掉 +、-、空白前綴後判），
    /// 這一段的內容行（+、-、空白開頭）全部遮掉——hunk 可能從私鑰中間開始，看不到 BEGIN。
    static func maskDiff(_ patch: String) -> String {
        var sections: [[String]] = [[]]
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { sections.append([]) }
            sections[sections.count - 1].append(line)
        }
        var output: [String] = []
        for section in sections where !section.isEmpty {
            let content = section.map { line -> String in
                guard let first = line.first, first == "+" || first == "-" || first == " " else { return "" }
                if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { return "" }
                return String(line.dropFirst())
            }
            let secret = mask(content).contains { $0 == .all }
            if !secret { output += section; continue }
            output += section.map { line in
                guard let first = line.first, first == "+" || first == "-" || first == " ",
                      !line.hasPrefix("+++ "), !line.hasPrefix("--- ") else { return line }
                return String(first) + masked
            }
        }
        return output.joined(separator: "\n")
    }
}

/// 指令輸出的串流遮蔽（一個串流一個）：帶狀態、只處理完整的行，遮好了才交給呼叫端寫盤。不是執行緒安全的：同一個串流一次一個呼叫。
final class HandsStreamRedactor {
    static let maxLine = 64 * 1024
    private let context: HandsRedactor.Context
    private var pending = Data()
    private var state = HandsSecretLines.State()

    init(context: HandsRedactor.Context) { self.context = context }

    /// 收一段原始輸出，回可以寫出去的（已遮蔽）位元組。
    func feed(_ chunk: Data) -> Data {
        pending.append(chunk)
        var lines: [String] = []
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self) + "\n")
                pending = Data(pending[pending.index(after: newline)...])
            } else if pending.count > Self.maxLine {
                // 一行太長：在最後一個空白切開（空白前面當一行處理；沒有空白就整段當一行）。
                let cut = pending.lastIndex(where: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }).map { pending.index(after: $0) } ?? pending.endIndex
                lines.append(String(decoding: pending[pending.startIndex..<cut], as: UTF8.self))
                pending = Data(pending[cut...])
            } else {
                break
            }
        }
        return render(lines)
    }

    /// 結束：剩下沒換行的最後一段也處理掉。
    func finish() -> Data {
        guard !pending.isEmpty else { return Data() }
        let last = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return render([last])
    }

    private func render(_ lines: [String]) -> Data {
        guard !lines.isEmpty else { return Data() }
        var block = ""
        for line in lines {
            let newline = line.hasSuffix("\n")
            let body = newline ? String(line.dropLast()) : line
            let kind = HandsSecretLines.classify(body, state: &state)
            block += HandsSecretLines.apply(body, kind) + (newline ? "\n" : "")
        }
        return Data(HandsRedactor.redact(block, context: context).utf8)
    }
}
