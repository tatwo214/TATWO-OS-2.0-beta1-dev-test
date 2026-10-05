import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const monitor = read('DM/GlobalHotkeyMonitor.swift')
  .replaceAll('NSEvent.addLocalMonitorForEvents', 'FixtureMonitors.addLocalMonitorForEvents')
  .replaceAll('NSEvent.addGlobalMonitorForEvents', 'FixtureMonitors.addGlobalMonitorForEvents')
  .replaceAll('NSEvent.removeMonitor', 'FixtureMonitors.removeMonitor');
function probe(body) {
  const root = mkdtempSync(join(tmpdir(), 'fixture-w191-permission-'));
  try {
    const source = `
import AppKit
import Combine
var queries = 0, trusted = false, failures = 0
func AXIsProcessTrusted() -> Bool { queries += 1; return trusted }
enum GlobalDMDeskSettings { static func chordToggleEnabled() -> Bool { true } }
@MainActor enum FixtureMonitors {
 static var adds = 0, removes = 0
 static func addLocalMonitorForEvents(matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? { NSObject() }
 static func addGlobalMonitorForEvents(matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? { adds += 1; return NSObject() }
 static func removeMonitor(_ token: Any) { removes += 1 }
}
${read('DM/ModifierChordDetector.swift')}
${monitor}
func check(_ value: Bool, _ label: String) { if !value { failures += 1 }; print("\\(value ? "PASS" : "FAIL") \\(label)") }
MainActor.assumeIsolated {
 let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
 let monitor = GlobalHotkeyMonitor(); monitor.install()
 ${body}
 monitor.uninstall()
 print("M18 SUMMARY failures=\\(failures)")
 exit(failures == 0 ? 0 : 1)
}
`;
    writeFileSync(join(root, 'main.swift'), source);
    const build = spawnSync('/usr/bin/swiftc', [join(root, 'main.swift'), '-o', join(root, 'probe')], {encoding: 'utf8', timeout: 60000});
    assert.equal(build.status, 0, build.stderr);
    const result = spawnSync(join(root, 'probe'), [], {encoding: 'utf8', timeout: 20000});
    console.log(result.stdout.trim());
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /M18 SUMMARY failures=0/);
  } finally { rmSync(root, {recursive: true, force: true}); }
}
test('M18 permission checks do not repeat while DM menu and settings are absent', () => {
  probe(`let before = queries
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(queries == before, "idle app does not poll permission")`);
});

test('M18 visible settings and menu share one watch, grant/revoke immediately, and stop when closed', () => {
  probe(`monitor.setPermissionSurfaceVisible(true, owner: "fixture")
 let menu = NSMenu(title: "fixture")
 monitor.menuWillOpen(menu)
 trusted = true
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(monitor.isSystemWide && FixtureMonitors.adds == 1, "visible permission UI applies grant once")
 trusted = false
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(!monitor.isSystemWide, "visible permission UI applies revocation")
 monitor.setPermissionSurfaceVisible(false, owner: "fixture")
 let stillWatching = queries
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(queries > stillWatching, "open menu keeps its own watch after settings close")
 monitor.menuDidClose(menu)
 let stopped = queries
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(queries == stopped, "closing the last permission surface stops polling")
 monitor.setPermissionSurfaceVisible(true, owner: "sample")
 monitor.uninstall()
 let uninstalled = queries
 RunLoop.current.run(until: Date().addingTimeInterval(0.8))
 check(queries == uninstalled, "uninstall stops even a visible surface watch")`);
});
test('M18 production setting card and menu own the permission watch lifetime', () => {
  const card = read('DM/GlobalDMDeskViews.swift').split('struct GlobalDMSettingsCard: View')[1];
  assert.match(card, /\.onAppear \{ chordMonitor\.setPermissionSurfaceVisible\(true, owner: permissionWatchID\)/);
  assert.match(card, /\.onDisappear \{ chordMonitor\.setPermissionSurfaceVisible\(false, owner: permissionWatchID\)/);
  assert.match(read('DM/GlobalDMPhoneBox.swift'), /menu\.delegate = GlobalHotkeyMonitor\.shared/);
});
