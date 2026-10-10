import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, realpathSync, statSync, existsSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {compileLauncher} from './fixtures/w293b-native.mjs';
const root = resolve(import.meta.dirname, '..');
const fixture = realpathSync(mkdtempSync('/tmp/w276-'));
const home = join(fixture, 'h');
const data = join(home, 'Library/Application Support/tatwo2-staging');
const launcher = join(fixture, 'Tatwo2Staging');
const header = join(fixture, 'user.h');
writeFileSync(header, '#include <pwd.h>\n#include <stdlib.h>\nstatic struct passwd *fixtureUser(uid_t u) { static struct passwd p; p.pw_dir=getenv("W276_TEST_HOME"); return &p; }\n#define getpwuid fixtureUser\n');
const keychain = compileLauncher(fixture, header);
const polluted = {...process.env, W276_TEST_HOME:home, HOME:'/production', TATWO_OS_ROOT:'/production/os', TATWO2_LIVE_ROOT:'/production/live', CODEX_HOME:'/production/codex', TATWO2_OS_SOCKET:'/production/os.sock'};
test('launcher isolates before dlopen initializers and preserves its executable identity', () => {
    const probe = spawnSync(launcher, ['--staging-paths'], {env:polluted, encoding:'utf8'});
    assert.equal(probe.status, 0, probe.stderr);
    const paths = Object.fromEntries(probe.stdout.trim().split('\n').map(x => x.split('=')));
    assert.equal(paths.TATWO_STAGING_ROOT, data);
    for (const [key, value] of Object.entries(paths)) assert.ok(value === data || value.startsWith(data+'/'), key);
    const payload = join(fixture,'payload.m');
    writeFileSync(payload, '#import <Foundation/Foundation.h>\n#include <mach-o/dyld.h>\n#include <unistd.h>\nextern char **environ;\n@interface LoadProbe : NSObject @end\n@implementation LoadProbe\n+ (void)load { printf("load-home=%s\\n", NSHomeDirectory().UTF8String); }\n@end\nint main(int argc, char **argv) { uint32_t n=4096; char p[4096]; _NSGetExecutablePath(p,&n); printf("executable=%s\\n",p); for(char **e=environ;*e;e++) puts(*e); return 0; }\n');
    const c = spawnSync('clang',['-dynamiclib','-framework','Foundation',payload,'-o',join(fixture,'Tatwo2')],{encoding:'utf8'});
    assert.equal(c.status,0,c.stderr);
    const launched = spawnSync(launcher, [], {env:polluted, encoding:'utf8'});
    assert.equal(launched.status, 0, launched.stderr);
    assert.ok(launched.stdout.includes('HOME='+data+'/home\n'));
    assert.ok(launched.stdout.includes('TATWO_ULTRAWORK_APP_MCP_PORT=17477\n'));
    assert.equal(realpathSync(launched.stdout.match(/^load-home=(.*)$/m)[1]),data+'/home');
    assert.ok(launched.stdout.includes('executable='+launcher+'\n'));
    assert.ok(!launched.stdout.includes('/production'));
    assert.doesNotMatch(spawnSync('otool',['-L',launcher],{encoding:'utf8'}).stdout,/Foundation|CEF|AppKit/);
});
test('launcher refuses a data root symlink', () => {
    const otherHome = join(fixture,'s');
    mkdirSync(join(otherHome,'Library/Application Support'), {recursive:true});
    symlinkSync(home, join(otherHome,'Library/Application Support/tatwo2-staging'));
    const r = spawnSync(launcher, [], {env:{...polluted,W276_TEST_HOME:otherHome},encoding:'utf8'});
    assert.equal(r.status, 78);
});
test('LaunchServices knows the staging host before payload initializers execute', () => {
    const contents = join(fixture,'Checkin.app/Contents');
    const macos = join(contents,'MacOS'); mkdirSync(macos,{recursive:true});
    const boot = join(macos,'Tatwo2Staging');
    writeFileSync(boot,readFileSync(launcher),{mode:0o755});
    writeFileSync(join(macos,'tatwo2-staging-keychain.dylib'),readFileSync(keychain));
    writeFileSync(join(contents,'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2.staging</string><key>CFBundleName</key><string>TATWO OS Staging</string><key>CFBundleExecutable</key><string>Tatwo2Staging</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
    const payload = join(fixture,'early-checkin.c');
    writeFileSync(payload, '#include <stdio.h>\n#include <unistd.h>\n__attribute__((constructor)) static void inspect(void) { char cmd[100], line[4096]; snprintf(cmd,sizeof cmd,"/usr/bin/lsappinfo info %d",getpid()); FILE *f=popen(cmd,"r"); if(f) { while(fgets(line,sizeof line,f)) fputs(line,stdout); pclose(f); } }\nint main(int argc,char **argv) { return 0; }\n');
    const compile = spawnSync('clang',['-dynamiclib',payload,'-o',join(macos,'Tatwo2')],{encoding:'utf8'});
    assert.equal(compile.status,0,compile.stderr);
    const result = spawnSync(boot,[],{env:polluted,encoding:'utf8',timeout:15000});
    assert.equal(result.status,0,result.stderr);
    assert.match(result.stdout,/bundleID="ai\.tatwo\.tatwo2\.staging"/);
    assert.match(result.stdout,/"TATWO OS Staging"/);
    assert.ok(result.stdout.includes('bundle path="'+join(fixture,'Checkin.app')+'"'),result.stdout);
});
test('fixed staging bundle fails closed when launched without isolation markers', () => {
    const app = join(fixture,'Probe.app/Contents'); mkdirSync(join(app,'MacOS'),{recursive:true});
    writeFileSync(join(app,'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2.staging</string><key>CFBundleExecutable</key><string>Tatwo2Staging</string></dict></plist>');
    const main = join(fixture,'main.swift');
    const stubs = join(fixture,'CLIStubs.swift');
    writeFileSync(stubs,'import Foundation\nenum CLISessionStore { static let limit = 100000 }\nstruct TatwoNativeTerminalLaunch { var workingDirectory: URL; var environment: [String:String]; var executable: String; var arguments: [String] }\n');
    writeFileSync(main, 'import Foundation\nif let e = NativeStagingIsolation.validationError(ProcessInfo.processInfo.environment) { print(e) } else { print("OK"); print(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path); print(CLITmuxRuntime(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"]!), executable: "/unused").socket) }\n');
    const bin = join(app,'MacOS/Tatwo2');
    const c = spawnSync('swiftc', [join(root,'App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift'), join(root,'App/Sources/Tatwo2/Engine/CLITmuxRuntime.swift'), stubs, main, '-o',bin],{encoding:'utf8'});
    assert.equal(c.status,0,c.stderr);
    const r = spawnSync(bin,[],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
    assert.equal(r.stdout.trim(),'missing staging root');
    const probe = spawnSync(launcher,['--staging-paths'],{env:polluted,encoding:'utf8'});
    const env = Object.fromEntries(probe.stdout.trim().split('\n').map(x => x.split('=')));
    env.TATWO_OS_ROOT='/production/os';
    assert.equal(spawnSync(bin,[],{env,encoding:'utf8'}).stdout.trim(),'inconsistent staging entry root');
    const checkSupport = r => { assert.equal(r.status,0,r.stderr); const [ok,path,socket]=r.stdout.trim().split('\n').filter(x => !x.startsWith('tatwo_staging_bootstrap=')); assert.ok(socket.startsWith(data+'/live/cli-runtime/')); assert.equal(ok,'OK'); assert.equal(realpathSync(path),data+'/home/Library/Application Support'); };
    env.TATWO_OS_ROOT=env.TATWO2_OS_ROOT;
    checkSupport(spawnSync(bin,[],{env,encoding:'utf8'}));
    const dylib = spawnSync('swiftc', [join(root,'App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift'), join(root,'App/Sources/Tatwo2/Engine/CLITmuxRuntime.swift'), stubs, main, '-Xlinker','-dylib','-o',bin],{encoding:'utf8'});
    assert.equal(dylib.status,0,dylib.stderr);
    const boot = join(app,'MacOS/Tatwo2Staging');
    writeFileSync(boot,readFileSync(launcher),{mode:0o755});
    writeFileSync(join(app,'MacOS/tatwo2-staging-keychain.dylib'),readFileSync(keychain));
    checkSupport(spawnSync(boot,[],{env:polluted,encoding:'utf8'}));
});
test('staging alone defaults Browser on; missing runtime fails closed without exec fallback', () => {
    const build = readFileSync(join(root,'script/build_tatwo2_staging_app.sh'),'utf8');
    assert.match(build,/TatwoBrowserWorkspaceEnabled=True/);
    assert.match(build,/TATWO2_STAGING_DYLIB=1.*--product Tatwo2/);
    const source = readFileSync(join(root,'script/tatwo2-staging-launcher.c'),'utf8');
    assert.doesNotMatch(source,/\bexecv\s*\(/);
    const empty = join(fixture,'empty'); mkdirSync(empty);
    const boot = join(empty,'Tatwo2Staging'); writeFileSync(boot,readFileSync(launcher),{mode:0o755});
    writeFileSync(join(empty,'tatwo2-staging-keychain.dylib'),readFileSync(keychain));
    const r = spawnSync(boot,[],{env:polluted,encoding:'utf8'});
    assert.equal(r.status,78); assert.match(r.stderr,/Staging load:/);
});
test('staging blocks updater and global shortcut entry points; sync refuses unverified artifacts', () => {
    for (const file of ['Facade/InAppUpdater.swift','Facade/GitHubReleaseUpdateChecker.swift','Shell/AppShell.swift']) {
        assert.match(readFileSync(join(root,'App/Sources/Tatwo2',file),'utf8'), /(?:!NativeStagingIsolation\.isW276Bundle|Bundle.main.bundleIdentifier != "ai\.tatwo\.tatwo2\.staging")/);
    }
    for (const target of ['/Applications','/','user@remote:/tmp']) {
        const r = spawnSync(join(root,'scripts/rooms/staging-sync.sh'),[target],{encoding:'utf8'});
        assert.notEqual(r.status,0);
    }
    const source = join(home,'tatwo-build/staging-app'), target = join(fixture,'dest');
    mkdirSync(source,{recursive:true}); mkdirSync(target);
    writeFileSync(join(source,'staging-receipt.json'),JSON.stringify({bundleID:'ai.tatwo.tatwo2.staging',buildStatus:'ready'}));
    symlinkSync('/Applications/TATWO OS.app',join(target,'TATWO OS Staging.app'));
    const r = spawnSync(join(root,'scripts/rooms/staging-sync.sh'),[target],{env:{...process.env,HOME:home},encoding:'utf8'});
    assert.notEqual(r.status,0); assert.match(r.stderr,/target entry is a symlink/);
});
test('sign-only signs real nested code without rebuilding or changing build/resource mtimes', () => {
    const source = join(home,'tatwo-build/staging-app'); mkdirSync(source,{recursive:true});
    const app = join(source,'TATWO OS Staging.app'), contents = join(app,'Contents');
    const plist = (id, executable) => `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`;
    mkdirSync(join(contents,'MacOS'),{recursive:true}); mkdirSync(join(contents,'Resources'));
    writeFileSync(join(contents,'Info.plist'),plist('ai.tatwo.tatwo2.staging','Tatwo2Staging'));
    for (const name of ['Tatwo2','Tatwo2Staging']) writeFileSync(join(contents,'MacOS',name),readFileSync(launcher),{mode:0o755});
    const framework = join(contents,'Frameworks/Chromium Embedded Framework.framework'); mkdirSync(framework,{recursive:true});
    writeFileSync(join(fixture,'framework.c'),'int fixture(void) { return 0; }\n');
    const c = spawnSync('clang',['-dynamiclib',join(fixture,'framework.c'),'-o',join(framework,'Chromium Embedded Framework')],{encoding:'utf8'});
    assert.equal(c.status,0,c.stderr);
    for (const suffix of ['', ' (Alerts)', ' (GPU)', ' (Plugin)', ' (Renderer)']) {
        const name = 'TATWO OS Staging Helper'+suffix, dir = join(contents,'Frameworks',name+'.app/Contents');
        mkdirSync(join(dir,'MacOS'),{recursive:true});
        writeFileSync(join(dir,'Info.plist'),plist('ai.tatwo.tatwo2.staging.helper',name));
        writeFileSync(join(dir,'MacOS',name),readFileSync(launcher),{mode:0o755});
    }
    const resource = join(contents,'Resources/sentinel'), build = join(fixture,'.build/Tatwo2');
    mkdirSync(join(fixture,'.build')); writeFileSync(build,'build product'); writeFileSync(resource,'resource');
    const before = [statSync(build).mtimeMs,statSync(resource).mtimeMs];
    const bin = join(fixture,'tools'); mkdirSync(bin);
    for (const tool of ['swift','security','clang','rsync','ditto']) writeFileSync(join(bin,tool),'#!/bin/sh\necho unexpected '+tool+' >&2\nexit 99\n',{mode:0o755});
    const receipt = join(source,'staging-receipt.json');
    writeFileSync(receipt,JSON.stringify({bundleID:'ai.tatwo.tatwo2.staging',buildStatus:'signing-blocked',sourceCommit:'fixture',buildSeconds:300,signingIdentitySHA1:'old'}));
    const r = spawnSync(join(root,'script/build_tatwo2_staging_app.sh'),['--sign-only',app,'--identity','-'],{env:{...process.env,HOME:home,PATH:bin+':'+process.env.PATH},encoding:'utf8'});
    assert.equal(r.status,0,r.stderr);
    assert.deepEqual([statSync(build).mtimeMs,statSync(resource).mtimeMs],before);
    const signed = JSON.parse(readFileSync(receipt));
    assert.equal(signed.buildStatus,'ready'); assert.equal(signed.signingIdentity,'-'); assert.equal(signed.adHoc,true);
    assert.equal(signed.sourceCommit,'fixture'); assert.equal(signed.buildSeconds,300); assert.equal(signed.signingIdentitySHA1,undefined);
    assert.equal(spawnSync('codesign',['--verify','--deep','--strict',app],{encoding:'utf8'}).status,0);
    const dest = join(fixture,'adhoc-dest');
    for (const flag of [{adHoc:true},{signingIdentity:'-'},{signingMode:'ad-hoc'}]) {
        writeFileSync(receipt,JSON.stringify({bundleID:'ai.tatwo.tatwo2.staging',buildStatus:'ready',...flag}));
        const sync = spawnSync(join(root,'scripts/rooms/staging-sync.sh'),[dest],{env:{...process.env,HOME:home},encoding:'utf8'});
        assert.notEqual(sync.status,0); assert.match(sync.stderr,/ad-hoc.*sync refused/); assert.equal(existsSync(dest),false);
    }
    writeFileSync(receipt,JSON.stringify({bundleID:'ai.tatwo.tatwo2.staging',buildStatus:'ready'}));
    const actual = spawnSync(join(root,'scripts/rooms/staging-sync.sh'),[dest],{env:{...process.env,HOME:home},encoding:'utf8'});
    assert.notEqual(actual.status,0); assert.match(actual.stderr,/ad-hoc signature/); assert.equal(existsSync(dest),false);
});
test('sign-only stops on Keychain UI and leaves receipt blocked; formal bundle is refused', () => {
    const source = join(home,'tatwo-build/staging-app'), app = join(source,'TATWO OS Staging.app');
    const bin = join(fixture,'ui-tools'); mkdirSync(bin);
    writeFileSync(join(bin,'pgrep'),'#!/bin/sh\n[ "$1" = "-x" ]\n',{mode:0o755});
    const stopped = spawnSync(join(root,'script/build_tatwo2_staging_app.sh'),['--sign-only',app,'--identity','-'],{env:{...process.env,PATH:bin+':'+process.env.PATH},encoding:'utf8'});
    assert.equal(stopped.status,78); assert.match(stopped.stderr,/Keychain UI present/);
    assert.equal(JSON.parse(readFileSync(join(source,'staging-receipt.json'))).buildStatus,'signing-blocked');
    const rejected = spawnSync(join(root,'script/build_tatwo2_staging_app.sh'),['--sign-only','/Applications/TATWO OS.app','--identity','-'],{encoding:'utf8'});
    assert.notEqual(rejected.status,0); assert.match(rejected.stderr,/unsafe signing target/);
});
// Keep fixtures as acceptance evidence; they contain no real account data.

test('clean install gate enables native isolation before launch with every path inside its scratch root', () => {
    const gate = readFileSync(join(root,'scripts/clean-install-gate.sh'),'utf8');
    const exports = gate.slice(gate.indexOf('export TATWO2_CLEANINSTALLTEST=1'), gate.indexOf('mkdir -p "$HOME"'));
    assert.ok(exports.length > 0 && gate.indexOf('export TATWO2_CLEANINSTALLTEST=1') < gate.indexOf('"$BINARY" > "$ROOT/app.log"'));
    const clean = join(fixture, 'clean'); mkdirSync(clean);
    const setup = spawnSync('/bin/bash', ['-c', 'ROOT="$1"\n' + exports + '\n/usr/bin/env', 'clean-env', clean], {env:{PATH:process.env.PATH}, encoding:'utf8'});
    assert.equal(setup.status,0,setup.stderr);
    const environment = Object.fromEntries(setup.stdout.trim().split('\n').map(line => { const at=line.indexOf('='); return [line.slice(0,at),line.slice(at+1)]; }));
    const source = join(fixture,'clean-main.swift'), main = join(fixture,'main.swift'), binary = join(fixture,'clean-probe');
    writeFileSync(source,'import Foundation\nlet env = ProcessInfo.processInfo.environment\nprecondition(NativeStagingIsolation.isEnabled(env))\nprecondition(NativeStagingIsolation.validationError(env) == nil)\nprint("isolated")\n');
    writeFileSync(main,readFileSync(source));
    const compile = spawnSync('swiftc',[join(root,'App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift'),main,'-o',binary],{encoding:'utf8'});
    assert.equal(compile.status,0,compile.stderr);
    const run = spawnSync(binary,[],{env:environment,encoding:'utf8'});
    assert.equal(run.status,0,run.stderr); assert.equal(run.stdout.trim(),'isolated');
    assert.equal(environment.TATWO2_CLEANINSTALLTEST,'1');
});
