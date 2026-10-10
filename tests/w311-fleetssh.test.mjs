import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import { fleetRPCCompileStubs } from './helpers/fleet-rpc-compile-stubs.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');

test('W311 production cleanup kills only fake owned/orphan forwards; sockets and launchd restart', { timeout: 180_000 }, () => {
  const root = testScratch('w311-');
  const home = join(root, 'home'), live = join(root, 'live'), sweep = join(root, 'sweep');
  for (const path of [home, live, sweep]) mkdirSync(path);
  const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, TATWO2_LIVE_ROOT: live };
  // This executable never runs SSH or opens a network socket. Only AF_UNIX fixtures.
  writeFileSync(join(root, 'fake.c'), String.raw`
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  const char *path = NULL; int orphan = 0, once = 0;
  if (getenv("W311_REJECT")) { fputs("Connection closed by remote host\n", stderr); return 255; }
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--orphan")) orphan = 1;
    if (!strcmp(argv[i], "--once")) once = 1;
    if (!strcmp(argv[i], "--socket") && i + 1 < argc) path = argv[++i];
    if (!strcmp(argv[i], "-L") && i + 1 < argc) { path = argv[++i]; char *end = strchr((char *)path, ':'); if (end) *end = 0; }
  }
  if (orphan) {
    pid_t pid = fork(); if (pid < 0) return 2;
    if (pid) { printf("%d\n", pid); fflush(stdout); return 0; }
    close(0); close(1); close(2);
  }
  if (path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path)); unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 1)) return 3;
    if (once) { close(fd); return 0; }
  }
  for (;;) pause();
}
`);
  const fake = join(root, 'fake-ssh');
  execFileSync('cc', [join(root, 'fake.c'), '-o', fake], { env });
  writeFileSync(join(root, 'Remote.swift'), source('Facade/RemoteHostLink.swift') + String.raw`
extension RemoteHostLink {
    func fixtureForward(_ fake: URL, _ root: URL, reject: Bool = false) throws -> Int32 {
        Self.fixtureSSH = fake
        pinnedHostsFile = root.appendingPathComponent("w91-host-" + UUID().uuidString)
        pinnedHostAlgorithm = "ssh-ed25519"; remoteSocketPath = root.appendingPathComponent("live/os.sock").path
        let peer = DeviceRecord(id: "fixture", name: "fixture", host: "example.invalid", user: "fixture", sshPort: 22,
                                publicKeyFingerprint: "SHA256:fixture", addedAt: Date(), lastSeenAt: Date(), workdirMap: [:])
        try startTunnelLocked(device: peer)
        return tunnel!.processIdentifier
    }
}
`);
  writeFileSync(join(root, 'Gate.swift'), source('Facade/DeviceFleetGate.swift') + String.raw`
extension DeviceFleetGate {
    static func fixtureDecode(_ status: Int32, _ diagnostics: String) throws {
        _ = try decodeResponse(status: status, diagnostics: diagnostics, data: Data())
    }
}
`);
  writeFileSync(join(root, 'Checks.swift'), fleetRPCCompileStubs() + String.raw`
import Foundation
import Darwin

enum DeviceStatusReader { static func registry(environment: [String: String]) -> [DeviceRecord] { [] } }
struct DeviceStatusSnapshot: Sendable { static func decode(_ value: [String: Any]) throws -> Self { Self() } }
struct DeviceStatusProbe {
    enum Connection { case reachable, appUnavailable, sshUnavailable }
    var connection: Connection; var snapshot: DeviceStatusSnapshot?; var acquiredAt: Date; var reason: String?
}
@main struct Checks {
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); print("PASS " + label)
    }
    static func until(_ check: () -> Bool) {
        for _ in 0..<400 { if check() { return }; usleep(10_000) }; preconditionFailure("fixture timeout")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fake = root.appendingPathComponent("fake-ssh")
        let sweep = root.appendingPathComponent("sweep").path
        let env = ProcessInfo.processInfo.environment
        precondition(env["HOME"] == root.appendingPathComponent("home").path)
        precondition(env["TATWO2_LIVE_ROOT"] == root.appendingPathComponent("live").path)
        func launch(_ args: [String]) throws -> Process {
            let process = Process(); process.executableURL = fake; process.arguments = args; process.environment = env
            try process.run(); return process
        }
        let unrelated = try launch([])
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        for detail in ["Connection reset by peer", "Connection closed by remote host"] {
            do { try DeviceFleetGate.fixtureDecode(255, detail); preconditionFailure("accepted refusal") }
            catch { check(error as? DeviceFleetGate.CallError == .rejected("ssh_remote_login_unresponsive"), "fleet-classifies-" + detail) }
        }
        do { try DeviceFleetGate.fixtureDecode(255, "ssh: connect to host localhost port 22: Connection refused"); preconditionFailure("accepted timeout") }
        catch { check(error as? DeviceFleetGate.CallError == .unreachable, "network-unavailable-stays-distinct") }
        do { try DeviceFleetGate.fixtureDecode(255, "Authenticated to peer\nConnection closed"); preconditionFailure("accepted app failure") }
        catch { check(error as? DeviceFleetGate.CallError == .appUnavailable, "authenticated-app-failure-stays-distinct") }
        let link = RemoteHostLink(environment: env)
        let first = try link.fixtureForward(fake, root)
        check(FileManager.default.fileExists(atPath: link.localSocketPath), "normal-forward-ready")
        link.disconnect(); until { kill(first, 0) != 0 }
        check(!FileManager.default.fileExists(atPath: link.localSocketPath), "no-longer-needed-removes-socket")
        link.disconnect(); check(unrelated.isRunning, "repeat-disconnect-preserves-unrelated-process")
        // A real fake orphan (ppid=1) models a launchd restart. Enumeration is restricted
        // to this fixture's rows; the production scanner is NEVER invoked on Studio.
        let orphanSocket = RemoteHostLink(environment: env).localSocketPath
        let parent = Process(), pipe = Pipe(); parent.executableURL = fake
        parent.environment = env; parent.arguments = ["--orphan", "--socket", orphanSocket]; parent.standardOutput = pipe
        try parent.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); parent.waitUntilExit()
        let orphan = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
        defer { if kill(orphan, 0) == 0 { _ = kill(orphan, SIGKILL) }; _ = unlink(orphanSocket) }
        until { FileManager.default.fileExists(atPath: orphanSocket) }
        let ps = Process(), pp = Pipe(); ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(orphan), "-o", "ppid="]; ps.standardOutput = pp; try ps.run()
        let ppid = String(decoding: pp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ps.waitUntilExit(); check(ppid == "1", "fake-orphan-parent-is-launchd")
        let pin = root.appendingPathComponent("w91-host-" + UUID().uuidString).path
        let valid = "\(orphan) 1 /usr/bin/ssh -p 22 -o UserKnownHostsFile=\"\(pin)\" -N -L \(orphanSocket):/fixture/live/os.sock fixture@localhost"
        for row in [valid.replacingOccurrences(of: " 1 /", with: " 99 /"), valid.replacingOccurrences(of: "w91-host-", with: "other-host-"),
                    valid.replacingOccurrences(of: "t2-r-", with: "other-r-"), valid.replacingOccurrences(of: "/usr/bin/ssh", with: fake.path),
                    valid.replacingOccurrences(of: " -N ", with: " ")] {
            RemoteHostLink.reapOrphans(list: { _ in row }, socketDirectory: sweep)
            check(kill(orphan, 0) == 0, "nonmatching-orphan-preserved")
        }
        RemoteHostLink.reapOrphans(list: { pid in pid == nil ? valid : nil }, socketDirectory: sweep)
        check(kill(orphan, 0) == 0, "failed-pid-recheck-preserves-orphan")
        var calls = 0
        RemoteHostLink.reapOrphans(list: { _ in calls += 1; return calls == 1 ? valid : valid + " changed" }, socketDirectory: sweep)
        check(kill(orphan, 0) == 0, "changed-identity-preserved")
        let deadSocket = sweep + "/t2-r-12345678-abc.sock"
        let once = try launch(["--once", "--socket", deadSocket]); once.waitUntilExit()
        let ordinary = sweep + "/t2-r-87654321-cba.sock", foreign = sweep + "/unrelated.sock"
        try Data().write(to: URL(fileURLWithPath: ordinary)); try Data().write(to: URL(fileURLWithPath: foreign))
        RemoteHostLink.reapOrphans(list: { _ in nil }, socketDirectory: sweep)
        check(FileManager.default.fileExists(atPath: deadSocket), "enumeration-failure-preserves-sockets")
        RemoteHostLink.reapOrphans(list: { _ in valid }, socketDirectory: sweep)
        until { kill(orphan, 0) != 0 }
        check(!FileManager.default.fileExists(atPath: orphanSocket), "restart-removes-orphan-and-associated-socket")
        check(!FileManager.default.fileExists(atPath: deadSocket), "restart-removes-unreferenced-old-socket")
        check(FileManager.default.fileExists(atPath: ordinary) && FileManager.default.fileExists(atPath: foreign), "regular-and-unrelated-files-preserved")
        let reject = RemoteHostLink(environment: env.merging(["W311_REJECT": "1"]) { _, value in value })
        do { _ = try reject.fixtureForward(fake, root); preconditionFailure("accepted refusal") }
        catch { check(error.localizedDescription.contains("Connection closed"), "tunnel-preserves-ssh-refusal") }
        reject.disconnect()
        let second = try link.fixtureForward(fake, root)
        RemoteHostLink.terminateOwned(); until { kill(second, 0) != 0 }
        check(!FileManager.default.fileExists(atPath: link.localSocketPath), "normal-app-quit-removes-forward-and-socket")
        check(unrelated.isRunning, "app-quit-preserves-unrelated-process")
        do { _ = try link.fixtureForward(fake, root); preconditionFailure("launched during quit") }
        catch { check(!FileManager.default.fileExists(atPath: link.localSocketPath), "quit-blocks-new-forward") }
    }
}
`);
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-DDEBUG', '-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    join(app, 'Facade/DeviceRegistry.swift'),
    ...['TatwoEntry', 'DeviceIdentity', 'DevicePairingAuth', 'DeviceSignature', 'DeviceFleetRoster', 'DeviceFleetGraph', 'DeviceFleetTransfer', 'DeviceFleetRevocation'].map(name => join(app, 'Facade', name + '.swift')),
    join(root, 'Gate.swift'), join(root, 'Remote.swift'), join(root, 'Checks.swift'), '-o', binary], { env, encoding: 'utf8', timeout: 120_000 });
  const output = execFileSync(binary, [root], { env, encoding: 'utf8', timeout: 30_000 });
  assert.match(output, /PASS restart-removes-orphan-and-associated-socket/);
  assert.match(output, /PASS normal-app-quit-removes-forward-and-socket/);
  assert.match(output, /PASS tunnel-preserves-ssh-refusal/);
  console.log(output.trim());
});

test('W311 startup follows selftests/single-instance guard; termination precedes launchd relaunch', () => {
  const entry = source('Tatwo2App.swift');
  assert.ok(entry.indexOf('RemoteHostLink.reapOrphans()') > entry.indexOf('SelfTest.runIfRequested()'));
  assert.ok(entry.indexOf('RemoteHostLink.reapOrphans()') > entry.indexOf('TatwoSingleInstanceGuard.forwardToExistingInstanceAndExitIfNeeded()'));
  assert.ok(entry.indexOf('RemoteHostLink.terminateOwned()') < entry.indexOf('CrashRelaunch.willTerminate()'));
  assert.match(source('Facade/HandsBuildModel.swift'), /if b.hasFreshReport\(id\) \{ i.reported.insert\(id\) \}/);
  assert.match(source('New/ChatGPTBuildSection.swift'), /else if device.isThisDevice \|\| \(input.reported.contains\(device.id.lowercased\(\)\)/);
});


test('W311 card truth: absent report, reported missing certificate, SSH refusal after permit expiry', { timeout: 60_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'current room debug binary required; never skip');
  const root = testScratch('w311-card-');
  const at = name => join(root, name);
  for (const name of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs']) mkdirSync(at(name), { recursive: true });
  const env = { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
    HOME: at('home'), CFFIXED_USER_HOME: at('home'), TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'), CODEX_HOME: at('engines/codex'),
    TATWO2_CODEX_SOURCE_HOME: at('engines/codex'), CLAUDE_CONFIG_DIR: at('engines/claude'),
    CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'), TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_SELFTEST: 'w183build', TATWO2_W311_COPY_ONLY: '1' };
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], { env, encoding: 'utf8', timeout: 45_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(at('card.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W311 SUMMARY passed=\d+ failures=0/);
  for (const word of ['沒收到副設備回報', '明確回報沒有通道憑證', '副設備信封到期且 SSH 被拒']) assert.ok(output.includes('W183BUILD PASS W311 ' + word), word);
  console.log(output.trim());
});
