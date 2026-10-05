import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');

test('W185P compiled production input, feedback and private clipboard scenarios', { timeout: 180_000 }, () => {
  const root = testScratch('w185-device-pairing-');
  writeFileSync(join(root, 'Driver.swift'), String.raw`
import AppKit
import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw NSError(domain: "W185PAIR FAIL " + label, code: 1) }
            checks += 1
            print("W185PAIR PASS " + label)
        }
        typealias Input = DevicePairingInput
        let address = "192.0.2.47:18815"
        let code = "DQT2GQ"
        let line = "TATWO 配對 " + address + " " + code
        try check(Input.parseAddress(address) == .init(host: "192.0.2.47", port: "18815", code: nil),
                  "IP-colon-port-splits")
        try check(Input.parseAddress(line) == .init(host: "192.0.2.47", port: "18815", code: code),
                  "whole-line-fills-three-fields")
        try check(Input.parseAddress("  TATWO 配對 " + address + " dqt2gq \n")?.code == code,
                  "whole-line-lowercase-uppercase")
        try check(Input.parseAddress("device.example:18815")?.host == "device.example", "DNS-colon-port")
        try check(Input.parseAddress("[2001:db8::1]:18815")?.host == "2001:db8::1", "bracketed-IPv6")
        try check(Input.parseAddress("[fe80::1%en0]:18815")?.host == "fe80::1%en0", "IPv6-zone")
        try check(!Input.isBulkEdit(previous: "192.0.2.47:", current: "192.0.2.47:1"),
                  "typing-first-port-digit-not-prematurely-split")
        try check(!Input.isBulkEdit(previous: "192.0.2.47:18815", current: "192.0.2.47:1881"),
                  "backspace-not-prematurely-split")
        try check(Input.isBulkEdit(previous: "192.0.2.47", current: address), "paste-port-detected")
        try check(Input.isBulkEdit(previous: "old-field-value", current: address), "replacement-paste-detected")
        for invalid in ["192.0.2.47", "192.0.2.47:", "192.0.2.47:0", "192.0.2.47:65536",
                        "192.0.2.47:+18815", "192.0.2.47:18xx", "192.0.2.999:18815",
                        "http://192.0.2.47:18815", "2001:db8::1:18815", "[oops]:18815",
                        "TATWO 配對 " + address, line + " extra", "TATWO 配對 " + address + " DQT2G!",
                        "TATWO 配對 " + address + " DQT2GQX", "TATWO 配對 " + address + " ßqt2gq"] {
            try check(Input.parseAddress(invalid) == nil, "malformed-paste-not-guessed")
        }
        try check(Input.normalizedCode("dqt2gq") == code, "typed-lowercase-uppercase")
        try check(Input.normalizedCode("d-q t!2@g#q") == code, "non-code-characters-filtered")
        try check(Input.normalizedCode("中文éßＡａ🙂dqt2gq") == code, "only-ASCII-alphabet-accepted")
        try check(Input.normalizedCode("dqt2gq999") == code, "code-max-six")
        try check(Input.normalizedCode("0o1i2z") == "0O1I2Z", "letters-and-digits-not-substituted")
        try check(Input.normalizedCode("") == "", "empty-code")
        func validation(host: String = "192.0.2.47", port: String = "18815",
                        code: String = "DQT2GQ", name: String = "Studio") -> String? {
            Input.validationMessage(host: host, port: port, code: code, name: name)
        }
        try check(validation() == nil, "all-four-valid-enables-join")
        try check(validation(host: "")?.contains("那台的位址") == true, "missing-host-disabled-and-explained")
        try check(validation(host: "   ") != nil, "whitespace-host-disabled")
        try check(validation(host: "192.0.2.47:invalid") != nil, "unparsed-endpoint-disabled")
        try check(validation(host: "192.0.2.999") != nil, "bad-IP-disabled")
        try check(validation(port: "")?.contains("冒號後面的數字") == true, "missing-port-disabled-and-explained")
        for port in ["0", "65536", "-1", "+18815", "12.5", "１２３", "abc", " "] {
            try check(validation(port: port) != nil, "invalid-port-disabled")
        }
        try check(validation(port: " 18815\n") == nil, "port-trimmed")
        try check(Input.portNumber("1") == 1 && Input.portNumber("65535") == 65535, "valid-port-boundaries")
        try check(validation(code: "DQT")?.contains("6 碼") == true, "short-code-disabled-and-explained")
        try check(validation(code: "DQT2G!") != nil, "invalid-code-disabled")
        try check(validation(code: "dqt2gq") != nil, "validation-requires-normalized-code")
        try check(validation(name: "\n  ")?.contains("這台的名字") == true, "missing-name-disabled-and-explained")
        try check(Input.copyLine(address: address, code: code) == line, "exact-copy-line-format")

        func feedback(_ raw: String) -> DevicePairingFeedback.Failure? {
            DevicePairingFeedback.failure("配對失敗：" + raw)
        }
        try check(feedback("invalid_port")?.message == "配對埠要填那台畫面上冒號後面的數字",
                  "invalid-port-human-language")
        try check(feedback("invalid_port")?.detail == "invalid_port", "raw-code-retained-separately")
        for (raw, human) in [
            ("pairing_rejected:pairing_code_mismatch：配對碼不對", "配對碼不對"),
            ("pairing_rejected:pairing code expired", "已過期"),
            ("pairing_rejected:pairing code already consumed (replay rejected)", "已用過"),
            ("pairing_rejected:pairing_window_closed", "沒有開著配對"),
            ("pairing_connection_timed_out", "連不到那台"),
            ("pairing_rejected:pairing_protocol_outdated：舊訊息", "版本"),
            ("pairing_rejected:bad_request", "版本"),
            ("ssh_host_key_mismatch：舊訊息", "身分驗證沒有通過"),
            ("pairing_response_unauthenticated：舊訊息", "身分驗證沒有通過"),
            ("pairing_peer_account_invalid：舊訊息", "登入名字"),
            ("ssh_batch_mode_verification_failed", "遠端登入"),
            ("ssh_host_fingerprint_unavailable", "遠端登入"),
            ("ssh_public_key_unreadable", "公鑰"),
            ("ssh_keygen_failed:fixture", "建立配對用的金鑰"),
            ("pairing_response_invalid", "回覆無法辨識"),
            ("pairing_rejected:request_too_large", "資料太大"),
            ("pairing_rejected:pairing code authority primary/epoch mismatch", "身分已變更"),
            ("POSIXErrorCode(rawValue: 61): Connection refused", "同一個網路"),
            ("unknown_future_error", "配對沒有完成"),
        ] {
            let result = feedback(raw)
            try check(result?.message.contains(human) == true, "error-human-language")
            try check(result?.detail == String(raw.split(separator: "：").first!), "engineering-code-preserved")
        }
        try check(DevicePairingFeedback.failure("已配對「Fixture」，SSH 登入驗證通過。") == nil,
                  "success-message-not-treated-as-error")
        for (error, human) in [
            (DevicePairingClient.ClientError.invalidHost, "位址"),
            (.invalidPort, "冒號後面的數字"),
            (.connectionTimedOut, "連不到那台"),
            (.publicKeyUnreadable, "公鑰"),
            (.keyGenerationFailed("fixture"), "建立配對用的金鑰"),
            (.responseInvalid, "回覆無法辨識"),
            (.sshVerificationFailed, "遠端登入"),
            (.hostFingerprintUnavailable, "遠端登入"),
            (.pairingRejected("pairing_code_mismatch"), "配對碼不對"),
            (.pairingRejected("pairing code expired"), "已過期"),
            (.pairingRejected("pairing_window_closed"), "沒有開著配對"),
            (.pairingRejected("unknown_fixture_error"), "沒有完成配對"),
        ] {
            try check(error.localizedDescription.contains(human), "actual-client-error-has-human-text")
        }
        try check(feedback(DevicePairingClient.ClientError.invalidPort.localizedDescription)?.detail == "invalid_port",
                  "actual-client-error-keeps-engineering-code")

        // 專用 pasteboard；測試不讀寫使用者的剪貼簿，也不觸發跨裝置傳送。
        let board = NSPasteboard(name: .init("ai.tatwo.w185pair.fixture." + UUID().uuidString))
        let clipboard = DevicePairingClipboard(pasteboard: board)
        defer { clipboard.clear(); board.releaseGlobally() }
        try check(!clipboard.copy(.all, address: address, code: code, expiresAt: Date().addingTimeInterval(-1)),
                  "expired-code-never-copied")
        try check(board.string(forType: .string) == nil, "rejected-copy-leaves-clipboard-alone")
        try check(!clipboard.copy(.all, address: "—", code: code, expiresAt: Date().addingTimeInterval(10)),
                  "missing-address-never-copied")
        try check(!clipboard.copy(.all, address: address, code: "dqt2gq", expiresAt: Date().addingTimeInterval(10)),
                  "invalid-host-code-never-copied")
        try check(clipboard.copy(.address, address: address, code: code, expiresAt: Date().addingTimeInterval(10)),
                  "address-button-copies")
        try check(board.string(forType: .string) == address && clipboard.copied == .address,
                  "address-copy-and-feedback")
        clipboard.clear()
        try check(board.string(forType: .string) == address, "address-only-needs-no-code-cleanup")
        try check(clipboard.copy(.all, address: address, code: code, expiresAt: Date().addingTimeInterval(10)),
                  "all-button-copies")
        try check(board.string(forType: .string) == line && clipboard.copied == .all, "full-copy-and-feedback")
        try await Task.sleep(for: .milliseconds(2200))
        try check(clipboard.copied == nil && board.string(forType: .string) == line, "copied-feedback-is-temporary")
        clipboard.clear()
        try check(board.string(forType: .string) == nil, "cancel-or-dismiss-clears-owned-code")
        try check(clipboard.copy(.all, address: address, code: code, expiresAt: Date().addingTimeInterval(0.06)),
                  "short-expiry-copy")
        try await Task.sleep(for: .milliseconds(150))
        try check(board.string(forType: .string) == nil, "expired-owned-code-cleared")
        _ = clipboard.copy(.all, address: address, code: code, expiresAt: Date().addingTimeInterval(0.06))
        board.clearContents()
        board.setString("fixture-unrelated-user-copy", forType: .string)
        try await Task.sleep(for: .milliseconds(150))
        try check(board.string(forType: .string) == "fixture-unrelated-user-copy", "expiry-keeps-new-user-copy")
        _ = clipboard.copy(.all, address: address, code: code, expiresAt: Date().addingTimeInterval(10))
        board.clearContents()
        board.setString("fixture-next-copy", forType: .string)
        clipboard.clear()
        try check(board.string(forType: .string) == "fixture-next-copy", "dismiss-keeps-new-user-copy")
        print("W185PAIR SUMMARY checks=" + String(checks) + " failures=0")
    }
}
`);
  const binary = join(root, 'driver');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    ...['TatwoEntry', 'DeviceIdentity', 'DeviceRegistry', 'DevicePairingCode', 'DevicePairingStubs',
      'DevicePairingAuth', 'DevicePairingClient', 'DevicePairingInput', 'DevicePairingClipboard']
      .map(name => join(app, 'Facade', name + '.swift')),
    join(root, 'Driver.swift'), '-o', binary],
  { encoding: 'utf8', timeout: 120_000 });
  const output = execFileSync(binary, [], {
    encoding: 'utf8', timeout: 30_000,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR },
  });
  assert.match(output, /W185PAIR SUMMARY checks=\d+ failures=0/);
  writeFileSync(join(root, 'w185pair.log'), output);
  console.log(output.trim());
});

test('W185P device card uses the production validation, parser, copy and feedback paths', () => {
  const ui = source('New/DevicesCard.swift');
  for (const label of ['那台的位址', '那台畫面上冒號後面的數字', '那台畫面上的 6 碼', '這台的名字']) {
    assert.ok(ui.includes(`Text("${label}")`), label);
  }
  assert.match(ui, /nameField = \(try\? DeviceIdentityStore\.readLocal\(\)\)\?\.name/);
  assert.match(ui, /Host\.current\(\)\.localizedName/);
  assert.match(ui, /onChange\(of: hostField\)[\s\S]*?DevicePairingInput\.isBulkEdit\(previous: previous, current: value\)/);
  assert.match(ui, /guard let parsed = DevicePairingInput\.parseAddress\(hostField\) else \{ return \}/);
  assert.match(ui, /hostField = parsed\.host\s+portField = parsed\.port\s+if let code = parsed\.code \{ codeField = code \}/);
  assert.match(ui, /\.onSubmit \{ parseHostField\(\) \}/);
  assert.match(ui, /onChange\(of: hostFieldFocused\)[\s\S]*?if !focused \{ parseHostField\(\) \}/);
  assert.match(ui, /onChange\(of: codeField\)[\s\S]*?DevicePairingInput\.normalizedCode\(value\)/);
  assert.match(ui, /TextField\("A–Z、0–9，共 6 碼"[\s\S]*?design: \.monospaced/);
  assert.match(ui, /guard pairingValidationMessage == nil,\s+let port = DevicePairingInput\.portNumber\(portField\)/);
  assert.match(ui, /\.disabled\(pairingValidationMessage != nil\)/);
  assert.match(ui, /Text\(pairingValidationMessage \?\?/);
  assert.match(ui, /DevicePairingInput\.validationMessage\(host: hostField, port: portField, code: codeField, name: nameField\)/);
  assert.doesNotMatch(ui, /Int\(portField\) \?\? 0/);
  for (const item of ['address', 'all']) {
    assert.match(ui, new RegExp(`pairingClipboard\\.copy\\(\\.${item}, address: listen, code: window\\.code`));
    assert.match(ui, new RegExp(`pairingClipboard\\.copied == \\.${item} \\? "已複製"`));
  }
  assert.match(ui, /DevicePairingFeedback\.failure\(pairMessage\)/);
  assert.match(ui, /Text\(failure\.message\)/);
  assert.match(ui, /Text\("工程資訊：\\\(failure\.detail\)"\)[\s\S]*?\.caption2/);
});

test('W185P code clipboard expires and clears on close without logging, persistence or protocol changes', () => {
  const ui = source('New/DevicesCard.swift');
  const clipboard = source('Facade/DevicePairingClipboard.swift');
  assert.match(ui, /onChange\(of: model\.pairingWindow\?\.code\).*pairingClipboard\.clear\(\)/);
  assert.match(ui, /\.onDisappear \{ pairingClipboard\.clear\(\) \}/);
  assert.match(clipboard, /prepareForNewContents\(with: \[\]\)/);
  assert.match(clipboard, /guard expiresAt > now/);
  assert.match(clipboard, /expiresAt\.timeIntervalSince\(now\)/);
  assert.match(clipboard, /pasteboard\.changeCount == ownedChange/);
  assert.doesNotMatch(clipboard, /print\(|\.log\(|writeAtomically|UserDefaults|FileManager|NWConnection|NWListener/);
  const host = source('Facade/DevicePairingHost.swift');
  assert.match(host, /ttlSeconds: 300/);
  assert.equal(host.match(/NWListener\(/g).length, 1);
  assert.match(host, /DevicePairingAuth\.verify/);
  const client = source('Facade/DevicePairingClient.swift');
  assert.match(client, /guard authenticated else \{ throw ClientError\.responseUnauthenticated \}/);
  assert.match(client, /guard fingerprint == declaredHostKey else \{ throw ClientError\.hostKeyMismatch \}/);
});
