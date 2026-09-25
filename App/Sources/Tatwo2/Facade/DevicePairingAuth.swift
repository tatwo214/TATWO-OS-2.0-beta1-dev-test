import CommonCrypto
import CryptoKit
import Foundation

/// W178：配對碼不再以明文經過網路。
///
/// 加入端每次產生 32 位元組隨機 nonce，兩端各自用「配對碼＋nonce」經 PBKDF2-HMAC-SHA256 導出同一把金鑰，
/// 請求與回應各帶一個 HMAC。區網上的中間人看不到配對碼，就換不掉加入端送去授權的公鑰，
/// 也改不了主機回報的登入名與主機金鑰指紋；PBKDF2 次數讓離線猜碼在 5 分鐘的配對窗內不划算。
enum DevicePairingAuth {
    static let protocolVersion = 2
    static let iterations: UInt32 = 2_000_000
    static let nonceByteCount = 32

    static func makeNonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        Data(base64Encoded: nonce)?.count == nonceByteCount
    }

    /// 配對碼一律轉大寫再導出，跟主機端的 seed（大寫英數）一致。
    static func key(code: String, nonce: String) -> SymmetricKey? {
        guard let salt = Data(base64Encoded: nonce), salt.count == nonceByteCount else { return nil }
        let password = Array(code.uppercased().utf8)
        let saltBytes = Array("tatwo-pair-v2:".utf8) + Array(salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations, &derived, derived.count)
        }
        guard status == kCCSuccess else { return nil }
        defer { derived.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        return SymmetricKey(data: derived)
    }

    static func mac(key: SymmetricKey, label: String, fields: [String]) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: transcript(label: label, fields: fields), using: key))
            .base64EncodedString()
    }

    static func verify(mac: String?, key: SymmetricKey, label: String, fields: [String]) -> Bool {
        guard let mac, let code = Data(base64Encoded: mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code, authenticating: transcript(label: label, fields: fields), using: key)
    }

    static func requestFields(
        nonce: String, publicKey: String, name: String, user: String?, deviceID: String?,
        clientKeyFingerprint: String?, hostKeyFingerprint: String?
    ) -> [String] {
        [nonce, publicKey, name, user ?? "", deviceID ?? "", clientKeyFingerprint ?? "", hostKeyFingerprint ?? ""]
    }

    static func responseFields(
        nonce: String, ok: Bool, deviceID: String?, hostName: String?, hostUser: String?,
        hostDeviceID: String?, hostKeyFingerprint: String?, clientKeyFingerprint: String?, reason: String?
    ) -> [String] {
        [nonce, ok ? "1" : "0", deviceID ?? "", hostName ?? "", hostUser ?? "", hostDeviceID ?? "",
         hostKeyFingerprint ?? "", clientKeyFingerprint ?? "", reason ?? ""]
    }

    /// 每欄前面加位元組長度，欄位內容怎麼變都不會跟別的組合撞在一起。
    private static func transcript(label: String, fields: [String]) -> Data {
        var data = Data()
        for value in ["tatwo-pair-v2-" + label] + fields {
            let bytes = Data(value.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
            data.append(0x0A)
        }
        return data
    }

    /// 對方送來、之後會進 ssh 參數的登入名：ASCII 英數、底線、點、連字號，不能以連字號開頭（避免被當成選項）。
    static func isSafeSSHUser(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar))
        }
    }

    /// 主機名或 IP（含 IPv6 與 %zone）：ASCII 英數與 . : % - _；不能以連字號開頭。
    static func isSafeSSHHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".:%-_".unicodeScalars.contains(scalar))
        }
    }
}
