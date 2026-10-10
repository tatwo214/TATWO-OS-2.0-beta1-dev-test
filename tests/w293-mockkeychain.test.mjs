import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync, realpathSync} from 'node:fs';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const scratch = realpathSync(mkdtempSync('/tmp/w293-policy-'));
const run = (cmd, args, options = {}) => spawnSync(cmd, args, {encoding:'utf8', timeout:60000, ...options});
import {compileLauncher} from './fixtures/w293b-native.mjs';
const bridgePath = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const bridge = read(bridgePath);
const block = '    if (StagingUsesMockKeychain()) {\n      command_line->AppendSwitch("use-mock-keychain");\n    }\n';

test('owned CEF switches follow deny filtering and cover all child launches; formal callbacks equal 2f34610e', () => {
  const baseline = run('git', ['show', '2f34610e:' + bridgePath]);
  assert.equal(baseline.status, 0, baseline.stderr);
  const callback = s => s.slice(s.indexOf('  void OnBeforeCommandLineProcessing('), s.indexOf('  void OnScheduleMessagePumpWork('));
  assert.equal(callback(bridge).split(block).length - 1, 2);
  assert.equal(callback(bridge).replaceAll(block, ''), callback(baseline.stdout));
  const denied = s => s.match(/const char \*const kDeniedHostSwitches\[\] = \{[\s\S]*?\n\};/)[0];
  assert.equal(denied(bridge), denied(baseline.stdout));
  assert.ok(callback(bridge).indexOf('RemoveSwitch(switch_name)') < callback(bridge).indexOf(block));
  assert.match(callback(bridge), /if \(!process_type.empty\(\)\) \{\s*return;/);
});


test('compiled CEF predicate uses only the exact staging bundle id under polluted environments', () => {
  const fn = bridge.match(/bool StagingUsesMockKeychain\(\) \{[\s\S]*?\n\}/)[0];
  const source = join(scratch, 'policy.mm');
  writeFileSync(source, '#import <Foundation/Foundation.h>\n' + fn + '\nint main() { @autoreleasepool { puts(StagingUsesMockKeychain() ? "true" : "false"); } }\n');
  for (const id of ['ai.tatwo.tatwo2', 'ai.tatwo.tatwo2.staging', 'ai.tatwo.tatwo2.staging.w258']) {
    const binary = bundleBinary(id, 'policy');
    const c = run('clang++',['-fobjc-arc',source,'-framework','Foundation','-o',binary]); assert.equal(c.status,0,c.stderr);
    for (const marker of ['', ' \t\n', '/synthetic/home']) {
      const r = run(binary,[],{env:{PATH:process.env.PATH,TATWO_STAGING_SCRATCH_HOME:marker}});
      assert.equal(r.status,0,r.stderr); assert.equal(r.stdout.trim(),String(id === 'ai.tatwo.tatwo2.staging'));
    }
  }
});

function bundleBinary(id, name) {
  const contents = join(scratch, name + '-' + id + '.app/Contents'); mkdirSync(join(contents,'MacOS'),{recursive:true});
  writeFileSync(join(contents,'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>probe</string></dict></plist>`);
  return join(contents,'MacOS/probe');
}

test('Swift six-entry boundary rejects staging and selftests; polluted formal bundle calls only fake Security APIs', () => {
  const source = join(scratch, 'boundary.swift'), main = join(scratch, 'main.swift');
  const fake = `import Foundation
import CoreFoundation
typealias OSStatus = Int32
let errSecInteractionNotAllowed: OSStatus = -25308
var forwarded = 0
enum Security {
 static func SecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { forwarded += 1; r?.pointee = nil; return 73 }
 static func SecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { forwarded += 1; r?.pointee = nil; return 73 }
 static func SecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { forwarded += 1; return 73 }
 static func SecItemDelete(_ q: CFDictionary) -> OSStatus { forwarded += 1; return 73 }
 static func SecKeychainGetUserInteractionAllowed(_ a: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus { forwarded += 1; a.pointee = false; return 73 }
 static func SecKeychainSetUserInteractionAllowed(_ a: Bool) -> OSStatus { forwarded += 1; return 73 }
}
`;
  writeFileSync(source, fake + read('App/Sources/Tatwo2/Facade/TestKeychainBoundary.swift').replace('import Security',''));
  writeFileSync(main, `import Foundation
import CoreFoundation
let denied = CommandLine.arguments.contains("deny")
let expected: OSStatus = denied ? errSecInteractionNotAllowed : 73
let q = NSDictionary() as CFDictionary; var data: CFTypeRef?; var allowed: DarwinBoolean = true
precondition(SecItemCopyMatching(q, &data) == expected && data == nil)
precondition(SecItemAdd(q, &data) == expected && data == nil)
precondition(SecItemUpdate(q,q) == expected)
precondition(SecItemDelete(q) == expected)
precondition(SecKeychainGetUserInteractionAllowed(&allowed) == expected && !allowed.boolValue)
precondition(SecKeychainSetUserInteractionAllowed(true) == expected)
precondition(forwarded == (denied ? 0 : 6))
print("six status=\\(expected) forwarded=\\(forwarded)")
`);
  for (const id of ['ai.tatwo.tatwo2','ai.tatwo.tatwo2.staging']) {
    const binary = bundleBinary(id, 'swift');
    const c = run('swiftc',['-O','App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift',source,main,'-o',binary]); assert.equal(c.status,0,c.stderr);
    for (const marker of ['', ' \t\n', '/synthetic/home']) {
      for (const flags of [{},{TATWO2_SELFTEST:'w293b'},{TATWO2_LOGINTEST:'1'},{TATWO2_LOGINTEST:'0'}]) {
        const denied = id.endsWith('.staging') || Object.values(flags).some(v=>v !== '0');
        const r = run(binary,denied ? ['deny'] : [],{env:{PATH:process.env.PATH,TATWO_STAGING_SCRATCH_HOME:marker,...flags}});
        assert.equal(r.status,0,r.stderr);
        assert.match(r.stdout,new RegExp('forwarded=' + (denied ? 0 : 6)));
      }
    }
  }
});

test('launcher makes owned argv visible to ps once and loads its interposer before dlopen', () => {
  const root = join(scratch,'launch'); mkdirSync(root);
  const header = join(root,'user.h');
  writeFileSync(header,'#include <pwd.h>\n#include <stdlib.h>\nstatic struct passwd *fakeUser(uid_t u) { static struct passwd p; p.pw_dir=getenv("W293_HOME"); return &p; }\n#define getpwuid fakeUser\n');
  compileLauncher(root, header);
  const launcher = join(root,'Tatwo2Staging');
  const payload = join(root,'payload.c');
  writeFileSync(payload,'#include <stdio.h>\n#include <unistd.h>\n#include <stdlib.h>\nint main(int n,char **v) { for(int i=0;i<n;i++) puts(v[i]); char c[128]; snprintf(c,sizeof c,"/bin/ps -o args= -p %d",getpid()); return system(c); }\n');
  const d = run('clang',['-dynamiclib',payload,'-o',join(root,'Tatwo2')]); assert.equal(d.status,0,d.stderr);
  for (const supplied of [[],['--use-mock-keychain']]) {
    const r = run(launcher,['--synthetic-canary',...supplied],{env:{PATH:process.env.PATH,W293_HOME:join(scratch,'user')}});
    assert.equal(r.status,0,r.stderr);
    assert.match(r.stdout,/--synthetic-canary\n--use-mock-keychain\n/);
    const ps = r.stdout.trim().split('\n').at(-1); assert.equal(ps.split('--use-mock-keychain').length-1,1);
  }
  assert.match(run('otool',['-L',launcher]).stdout,/tatwo2-staging-keychain\.dylib/);
});
