import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');
// 這個字串只在斷言時組出來，本檔的 diff 裡不會出現它的字面值。
const relaxed = 'accept' + '-new';
const disabled = 'StrictHostKeyChecking=' + 'no';

const pinned = ['Facade/DispatchEngine.swift', 'Facade/RemoteEngineSync.swift',
  'Facade/PeerUpdateSource.swift', 'Facade/SSHHostPin.swift'];

test('W91c: 三處 ssh／rsync 只吃主機金鑰 pin，沒有放寬旋鈕', () => {
  for (const name of pinned) {
    const text = source(name);
    assert.ok(!text.includes(relaxed), `${name} 仍有放寬的 host key 檢查`);
    assert.ok(!text.includes(disabled), `${name} 關掉了 host key 檢查`);
    assert.ok(text.includes('SSHHostPin'), `${name} 沒接上共用 pin helper`);
  }
  // 真的會執行的三條路徑都先要到 pin，缺指紋就 throw（不是回退成不 pin）。
  assert.match(source('Facade/DispatchEngine.swift'), /let pin = try SSHHostPin\.make\(deviceID: ref\.id, name: ref\.name\)/);
  assert.match(source('Facade/RemoteEngineSync.swift'), /let pin = try SSHHostPin\.make\(deviceID: ref\.id, name: ref\.name\)/);
  assert.match(source('Facade/PeerUpdateSource.swift'), /guard let pin = try\? SSHHostPin\.make\(device\)/);
  assert.match(source('Facade/PeerUpdateSource.swift'), /let pin = try SSHHostPin\.make\(offer\.device\)/);
  // rsync 的 -e 也要帶同一份 pin（不能只有 ssh 那條被收緊）。
  assert.match(source('Facade/RemoteEngineSync.swift'), /"-e", \(\["ssh"\] \+ SSHHostPin\.options\(pin\)/);
  assert.match(source('Facade/PeerUpdateSource.swift'), /"-e", \(\["\/usr\/bin\/ssh"\] \+ options\(offer\.device, pin: pin\)\)/);
  // W178：配對第一次 SSH 也改成只信配對碼證明過的主機金鑰（一次性 known_hosts＋StrictHostKeyChecking=yes），
  // 不再 accept-new，也不共用多工連線或其他金鑰來源。
  const pairing = source('Facade/DevicePairingClient.swift');
  assert.ok(!pairing.includes(relaxed), 'DevicePairingClient 仍有放寬的 host key 檢查');
  assert.ok(!pairing.includes(disabled), 'DevicePairingClient 關掉了 host key 檢查');
  for (const option of ['StrictHostKeyChecking=yes', 'ControlPath=none', 'KnownHostsCommand=none', 'VerifyHostKeyDNS=no']) {
    assert.ok(pairing.includes(option), option);
  }
  // W100 的主佇列斷言不得被動到。
  assert.equal(source('Facade/RemoteHostLink.swift').split('dispatchPrecondition(condition: .notOnQueue(.main))').length - 1, 3);
});

test('W91c: 信任檔相對 beta1/integration 零 diff', () => {
  const base = spawnSync('git', ['merge-base', 'beta1/integration', 'HEAD'], { encoding: 'utf8' });
  assert.equal(base.status, 0, base.stderr);
  const trusted = ['DevicePairingClient', 'DevicePairingCode', 'DevicePairingHost', 'DevicePairingStubs',
    'DeviceDispatch', 'DeviceRegistry', 'RemoteHostLink'].map(n => `App/Sources/Tatwo2/Facade/${n}.swift`);
  const diff = spawnSync('git', ['diff', '--name-only', base.stdout.trim(), '--', ...trusted], { encoding: 'utf8' });
  assert.equal(diff.status, 0, diff.stderr);
  assert.equal(diff.stdout.trim(), '');
});

test('W91c 編譯：缺指紋的紀錄被拒，有指紋的產生 StrictHostKeyChecking=yes ＋ pin 檔', { timeout: 300_000 }, () => {
  const root = testScratch('w91c-pin-');
  writeFileSync(join(root, 'Driver.swift'), String.raw`
import Darwin
import Foundation

enum DeviceRole: String, Codable, Sendable { case primary, secondary }
enum DeviceStatusReader {
    static var rows: [DeviceRecord] = []
    static func registry(environment: [String: String]) -> [DeviceRecord] { rows }
}

func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: "FAIL " + label, code: 1) }
    print("PASS " + label)
}
func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { print("PASS " + label); return }
    throw NSError(domain: "accepted " + label, code: 1)
}

@main struct Checks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let known = root.appendingPathComponent("known_hosts")
        // 全部是合成公鑰位元組，沒有私鑰，也沒有任何真實設備的指紋。
        func key(_ seed: UInt8) -> String {
            "ssh-ed25519 " + Data(repeating: seed, count: 32).base64EncodedString()
        }
        let hostKey = key(9), clientKey = key(7), strayKey = key(11)
        let hostFP = try DeviceRegistry.fingerprint(publicKey: hostKey)
        let clientFP = try DeviceRegistry.fingerprint(publicKey: clientKey)
        let strayFP = try DeviceRegistry.fingerprint(publicKey: strayKey)
        try Data(("[192.0.2.10]:22 " + hostKey + "\n").utf8).write(to: known)
        let environment = ["TATWO2_SSH_KNOWN_HOSTS": known.path]

        func record(_ id: String, host: String?, client: String?) -> DeviceRecord {
            DeviceRecord(id: id, name: "Fixture " + id, host: "192.0.2.10", user: "fixture", sshPort: 22,
                         publicKeyFingerprint: host ?? client ?? "", addedAt: Date(), lastSeenAt: Date(),
                         workdirMap: [:], hostKeyFingerprint: host, clientKeyFingerprint: client)
        }

        // (1) 只有客戶端金鑰＝缺隧道識別：拒絕，不拿另一把頂替、也不退回 TOFU。
        try rejects("client-key-only-rejected") {
            _ = try SSHHostPin.make(record("a", host: nil, client: clientFP), environment: environment)
        }
        // (2) host 指紋在 known_hosts 裡找不到對應金鑰：一樣拒絕。
        try rejects("unknown-host-key-rejected") {
            _ = try SSHHostPin.make(record("b", host: strayFP, client: nil), environment: environment)
        }
        // (3) 查無這筆配對紀錄：拒絕。
        DeviceStatusReader.rows = []
        try rejects("unpaired-device-id-rejected") {
            _ = try SSHHostPin.make(deviceID: "missing", name: "Fixture", environment: environment)
        }

        // (4) 有 host 指紋：產生只含那一把的 pin 檔，選項是 StrictHostKeyChecking=yes。
        var pinPath = ""
        do {
            let pin = try SSHHostPin.make(record("c", host: hostFP, client: clientFP), environment: environment)
            pinPath = pin.knownHostsFile.path
            let options = pin.options
            try check(options.contains("StrictHostKeyChecking=yes"), "strict-host-key-checking-yes")
            try check(options.contains("BatchMode=yes"), "batch-mode-yes")
            try check(options.contains("UserKnownHostsFile=\"" + pinPath + "\""), "user-known-hosts-file-is-pin")
            try check(options.contains("GlobalKnownHostsFile=/dev/null"), "no-global-known-hosts")
            try check(options.contains("HostKeyAlias=" + SSHHostPin.alias), "host-key-alias")
            try check(options.contains("HostKeyAlgorithms=ssh-ed25519"), "host-key-algorithm-pinned")
            try check(!options.joined(separator: " ").contains("accept" + "-new"), "no-relaxed-host-key-option")
            let text = try String(contentsOfFile: pinPath, encoding: .utf8)
            try check(text == SSHHostPin.alias + " " + hostKey + "\n", "pin-file-holds-only-paired-key")
            try check(pin.fingerprint == hostFP, "pin-reports-paired-fingerprint")
            // deviceID 版走同一份配對紀錄。
            DeviceStatusReader.rows = [record("c", host: hostFP, client: clientFP)]
            let byID = try SSHHostPin.make(deviceID: "c", name: "Fixture", environment: environment)
            try check(byID.fingerprint == hostFP, "device-id-lookup-uses-same-pin")
        }
        // (5) pin 用完就清掉，不會在 /tmp 留下 known_hosts 殘骸。
        try check(!FileManager.default.fileExists(atPath: pinPath), "pin-file-removed-after-use")

        // (6) 沒有 pin 的形狀（fixture 擷取）比 pin 更嚴：空 known_hosts，絕不是放寬旋鈕。
        try check(SSHHostPin.denied.contains("StrictHostKeyChecking=yes")
            && SSHHostPin.denied.contains("UserKnownHostsFile=/dev/null")
            && !SSHHostPin.denied.joined(separator: " ").contains("accept" + "-new"), "denied-shape-is-stricter")
        print("W91C PASS ssh-host-pin")
    }
}
`);
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    join(app, 'Facade/DeviceRegistry.swift'), join(app, 'Facade/SSHHostPin.swift'), join(root, 'Driver.swift'),
    '-o', binary], { encoding: 'utf8', timeout: 240_000 });
  assert.ok(existsSync(binary));
  const output = execFileSync(binary, [root], { encoding: 'utf8', timeout: 60_000 });
  assert.match(output, /W91C PASS ssh-host-pin/);
  console.log(output.trim());
});
