import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, symlinkSync} from 'node:fs';
import {join, dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';
import {compileLauncher} from './fixtures/w293b-native.mjs';
const scratch = testScratch('w293b-native-', {base:'/tmp'});
const read = p => readFileSync(p, 'utf8');
const run = (cmd, args, opts={}) => spawnSync(cmd,args,{encoding:'utf8',timeout:60000,...opts});
const compile = (args, compiler='clang') => { const r=run(compiler,args); assert.equal(r.status,0,r.stderr); };
const bundle = (id,name) => {
  const root=join(scratch,name+'.app/Contents'); mkdirSync(join(root,'MacOS'),{recursive:true});
  writeFileSync(join(root,'Info.plist'),`<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>Tatwo2Staging</string></dict></plist>`);
  return join(root,'MacOS');
};

test('real dyld: staging launcher -> dlopen App -> linked framework; main, framework initializer and child deny eight APIs', () => {
  const original=join(scratch,'original.c'), originalLib=join(scratch,'original.dylib');
  const boundary=join(scratch,'tatwo2-staging-keychain.dylib');
  const framework=join(scratch,'Framework.c'), frameworkLib=join(scratch,'Framework.dylib');
  const payload=join(scratch,'payload.c'), child=join(scratch,'child');
  writeFileSync(original,`#include <Security/Security.h>
OSStatus SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) { if(r)*r=(void*)1; return 73; }
OSStatus SecItemAdd(CFDictionaryRef q, CFTypeRef *r) { if(r)*r=(void*)1; return 73; }
OSStatus SecItemUpdate(CFDictionaryRef q, CFDictionaryRef a) { return 73; }
OSStatus SecItemDelete(CFDictionaryRef q) { return 73; }
OSStatus SecKeychainGetUserInteractionAllowed(Boolean *a) { *a=true; return 73; }
OSStatus SecKeychainSetUserInteractionAllowed(Boolean a) { return 73; }
OSStatus SecKeychainFindGenericPassword(CFTypeRef k, UInt32 sn,const char*s,UInt32 an,const char*a,UInt32*n,void**p,SecKeychainItemRef*i) { if(n)*n=1; if(p)*p=(void*)1; if(i)*i=(void*)1; return 73; }
OSStatus SecKeychainAddGenericPassword(SecKeychainRef k,UInt32 sn,const char*s,UInt32 an,const char*a,UInt32 n,const void*p,SecKeychainItemRef*i) { if(i)*i=(void*)1; return 73; }
`);
  const calls=`CFTypeRef r=(void*)1; Boolean a=true; UInt32 n=1; void *p=(void*)1; SecKeychainItemRef i=(void*)1;
int copy=SecItemCopyMatching(NULL,&r); int clear=r==NULL;
int add=SecItemAdd(NULL,&r); clear &= r==NULL;
int update=SecItemUpdate(NULL,NULL), del=SecItemDelete(NULL);
int get=SecKeychainGetUserInteractionAllowed(&a); clear &= !a;
int set=SecKeychainSetUserInteractionAllowed(true);
int find=SecKeychainFindGenericPassword(NULL,0,NULL,0,NULL,&n,&p,&i); clear &= n==0 && p==NULL && i==NULL;
int ga=SecKeychainAddGenericPassword(NULL,0,NULL,0,NULL,0,NULL,&i); clear &= i==NULL;
printf("%s %d,%d,%d,%d,%d,%d,%d,%d clear=%d\\n",label,copy,add,update,del,get,set,find,ga,clear);`;
  writeFileSync(framework,'#include <Security/Security.h>\n#include <stdio.h>\nvoid frameworkCall(const char*label) { '+calls+' }\n__attribute__((constructor)) static void init(void) { frameworkCall("framework-init"); }\n');
  writeFileSync(payload,'#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n#include <sys/wait.h>\n#include <string.h>\nvoid frameworkCall(const char*);\nint main(int argc,char **argv) { frameworkCall("app"); const char *child=getenv("W293B_CHILD"); if(child && (argc < 2 || strcmp(argv[1],"--child"))) { pid_t p=fork(); if(!p) { execl(child,child,"--child",NULL); _exit(87); } int s; waitpid(p,&s,0); return WIFEXITED(s)?WEXITSTATUS(s):88; } return 0; }\n');
  compile(['-dynamiclib','-Wno-deprecated-declarations',original,'-o',originalLib]);
  compile(['-dynamiclib','-Wno-deprecated-declarations','script/tatwo2-staging-keychain.c',originalLib,'-Wl,-install_name,@executable_path/tatwo2-staging-keychain.dylib','-o',boundary]);
  compile(['-dynamiclib','-Wno-deprecated-declarations',framework,originalLib,'-o',frameworkLib]);
  compile([payload,frameworkLib,'-o',child]);
  const macos=bundle('ai.tatwo.tatwo2.staging','dyld-staging');
  writeFileSync(join(macos,'tatwo2-staging-keychain.dylib'),readFileSync(boundary));
  const header=join(scratch,'user.h');
  writeFileSync(header,'#include <pwd.h>\n#include <stdlib.h>\nstatic struct passwd *fake(uid_t u) { static struct passwd p; p.pw_dir=getenv("W293B_HOME"); return &p; }\n#define getpwuid fake\n');
  const launcher=join(macos,'Tatwo2Staging');
  compile(['-include',header,'script/tatwo2-staging-launcher.c','-Wl,-needed_library,'+boundary,'-o',launcher]);
  compile(['-dynamiclib',payload,frameworkLib,'-o',join(macos,'Tatwo2')]);
  const env={PATH:process.env.PATH,W293B_HOME:join(scratch,'user'),W293B_CHILD:child};
  const staged=run(launcher,[],{env}); assert.equal(staged.status,0,staged.stderr);
  const deny='-25300,-25308,-25308,-25308,-25308,-25308,-25300,-25308 clear=1';
  assert.equal(staged.stdout.split(deny).length-1,4,staged.stdout);
  const guardSource=join(scratch,'guard.c'), guardLib=join(scratch,'guard.dylib');
  writeFileSync(guardSource,'#include <Security/Security.h>\n#include <stdio.h>\nstatic OSStatus fallback(CFDictionaryRef q,CFTypeRef*r) { if(r)*r=NULL; fputs("guard-called\\n",stderr); return 89; }\n__attribute__((used,section("__DATA,__interpose"))) static const struct { const void *r,*o; } pair={(void*)&fallback,(void*)&SecItemCopyMatching};\n');
  compile(['-dynamiclib',guardSource,originalLib,'-o',guardLib]);
  const observed=run(launcher,[],{env:{...env,DYLD_INSERT_LIBRARIES:guardLib}});
  assert.equal(observed.status,0,observed.stderr); assert.doesNotMatch(observed.stderr,/guard-called/);
  assert.equal(observed.stdout.split(deny).length-1,4,observed.stdout);
  const formal=join(bundle('ai.tatwo.tatwo2','dyld-formal'),'Tatwo2Staging'); compile([payload,frameworkLib,'-o',formal]);
  const normal=run(formal,[],{env:{...env,TATWO_STAGING_SCRATCH_HOME:'/synthetic/home'}});
  assert.equal(normal.status,0,normal.stderr); assert.equal(normal.stdout.split('73,73,73,73,73,73,73,73 clear=0').length-1,4,normal.stdout);
  assert.doesNotMatch(run('otool',['-L',formal]).stdout,/staging-keychain/);
  console.log('dyld staging=4x8 denials; formal=4x8 fake originals; framework initializer covered');
});

test('EngineLogin allows only the selected executable inside an explicit test root; empty/missing/outside/symlink markers reject', () => {
  const source=read('App/Sources/Tatwo2/Facade/EngineLogin.swift');
  const validation=source.match(/    private static func validFakeExecutable[\s\S]*?\n    \}/)[0];
  const cli=source.slice(source.indexOf('extension EngineLogin {'));
  const policy=join(scratch,'login.swift'), main=join(scratch,'main.swift');
  writeFileSync(policy,'import Foundation\nstruct EngineLogin {\n'+validation+'\n}\n'+cli);
  writeFileSync(main,'import Foundation\nlet e=ProcessInfo.processInfo.environment\nlet r=EngineLogin.claudeCLIStatus(executable:e["W293B_SELECTED"]!,configDir:e["CLAUDE_CONFIG_DIR"]!,environment:e)\nprint(r?.loggedIn == true ? "fake-ran" : "rejected")\n');
  const bin=join(bundle('ai.tatwo.tatwo2.staging','login-staging'),'Tatwo2Staging');
  compile(['App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift',policy,main,'-o',bin],'swiftc');
  const root=join(scratch,'login-root'); mkdirSync(root);
  const paths={HOME:'home',CFFIXED_USER_HOME:'home',TATWO_STAGING_SCRATCH_HOME:'home',TATWO2_LIVE_ROOT:'live',TATWO2_ENGINES_ROOT:'engines',CODEX_HOME:'engines/codex',TATWO2_CODEX_SOURCE_HOME:'engines/codex',CLAUDE_CONFIG_DIR:'engines/claude',CLAUDE_SECURESTORAGE_CONFIG_DIR:'engines/claude',TATWO2_OS_SOCKET:'o.sock',TATWO2_BROWSER_SOCKET:'b.sock',TATWO2_OS_ROOT:'os',TATWO_OS_ROOT:'os',TATWO2_DOCS_ROOT:'docs',TATWO2_OS_UPSTREAM_PATH:'os/os.md',TATWO2_SKILLET_PATH:'os/skillet.md'};
  for(const p of ['home','live','engines/codex','engines/claude','os','docs']) mkdirSync(join(root,p),{recursive:true});
  const env={PATH:process.env.PATH,TATWO_STAGING_ROOT:root,TATWO2_LOGINTEST:'1',...Object.fromEntries(Object.entries(paths).map(([k,p])=>[k,join(root,p)]))};
  const fake=join(root,'fake'), outside=join(scratch,'outside'), alias=join(root,'alias');
  for(const f of [fake,outside]) writeFileSync(f,'#!/bin/sh\nprintf \'{"loggedIn":true}\\n\'\n',{mode:0o700});
  symlinkSync(outside,alias);
  for(const [marker,selected,want] of [[fake,fake,'fake-ran'],['',outside,'rejected'],[join(root,'missing'),outside,'rejected'],[join(root,'missing'),join(root,'missing'),'rejected'],[root,root,'rejected'],[fake,outside,'rejected'],[outside,outside,'rejected'],[alias,alias,'rejected']]) {
    const r=run(bin,[],{env:{...env,TATWO2_LOGIN_FAKE_BIN:marker,W293B_SELECTED:selected}}); assert.equal(r.status,0,r.stderr); assert.equal(r.stdout.trim(),want);
  }
  const forgedRoot=run(bin,[],{env:{...env,TATWO2_LOGIN_TEST_ROOT:scratch,TATWO2_LOGIN_FAKE_BIN:outside,W293B_SELECTED:outside}});
  assert.equal(forgedRoot.stdout.trim(),'rejected');
  const noTest=run(bin,[],{env:{...env,TATWO2_LOGINTEST:'0',TATWO2_LOGIN_FAKE_BIN:fake,W293B_SELECTED:fake}});
  assert.equal(noTest.stdout.trim(),'rejected');
  const formal=join(bundle('ai.tatwo.tatwo2','login-formal'),'Tatwo2Staging');
  compile(['App/Sources/Tatwo2/Engine/NativeStagingIsolation.swift',policy,main,'-o',formal],'swiftc');
  const polluted=run(formal,[],{env:{PATH:process.env.PATH,TATWO_STAGING_SCRATCH_HOME:'/synthetic/home',CLAUDE_CONFIG_DIR:join(root,'engines/claude'),W293B_SELECTED:fake,TATWO2_LOGIN_FAKE_BIN:''}});
  assert.equal(polluted.status,0,polluted.stderr); assert.equal(polluted.stdout.trim(),'fake-ran');
});

test('staging git helper exits before reading stdin or running security; staging install returns before resources/config', () => {
  const helper=join(scratch,'helper'), trace=join(scratch,'security-called');
  const fakeSecurity=join(scratch,'fake-security'); writeFileSync(fakeSecurity,'#!/bin/sh\necho called >> "'+trace+'"\necho synthetic-token\n',{mode:0o700});
  writeFileSync(helper,read('App/Sources/Tatwo2/Resources/tatwo2-git-credential').replace('/usr/bin/security',fakeSecurity),{mode:0o700});
  const accounts=join(scratch,'accounts.json'); writeFileSync(accounts,'{"accounts":[]}');
  const env={PATH:process.env.PATH,HOME:join(scratch,'home'),TATWO_STAGING_ROOT:scratch,TATWO2_STAGING_BUNDLE_ID:'ai.tatwo.tatwo2.staging',TATWO2_GITHUB_ACCOUNTS_FILE:accounts};
  const staged=run(helper,['get'],{env,input:'host=github.com\nusername=synthetic\n\n'});
  assert.equal(staged.status,0,staged.stderr); assert.equal(staged.stdout,'');
  const formal=run(helper,['get'],{env:{...env,TATWO2_STAGING_BUNDLE_ID:'ai.tatwo.tatwo2'},input:'host=github.com\nusername=synthetic\n\n'});
  assert.equal(formal.status,0,formal.stderr); assert.match(formal.stdout,/password=synthetic-token/);
  assert.equal(readFileSync(trace,'utf8').trim(),'called');
  assert.match(read('App/Sources/Tatwo2/Facade/GitHubAccounts.swift'),/func installHelper\(\) throws \{\s*guard !NativeStagingIsolation.isW276Bundle else \{ return \}/);
});

test('staging launcher suppresses an already configured Git credential helper, including SIP git children', () => {
  const root=join(scratch,'git-launch'); mkdirSync(root);
  const home=join(scratch,'git-user'), marker=join(root,'helper-called'), helper=join(root,'old-helper');
  writeFileSync(helper,'#!/bin/sh\necho called >> "'+marker+'"\nprintf "username=fixture\\npassword=canary\\n\\n"\n',{mode:0o700});
  const payload=join(root,'payload.c'), header=join(root,'user.h');
  writeFileSync(header,'#include <pwd.h>\n#include <stdlib.h>\nstatic struct passwd *fake(uid_t u) { static struct passwd p; p.pw_dir=getenv("W293B_HOME"); return &p; }\n#define getpwuid fake\n');
  compileLauncher(root,header);
  writeFileSync(payload,'#include <stdlib.h>\nint main() { return system("printf \'protocol=https\\nhost=example.invalid\\n\\n\' | /usr/bin/git credential fill >/dev/null 2>/dev/null") == 0 ? 89 : 0; }\n');
  compile(['-dynamiclib',payload,'-o',join(root,'Tatwo2')]);
  const env={PATH:process.env.PATH,W293B_HOME:home,GIT_TERMINAL_PROMPT:'0',GIT_CONFIG_COUNT:'1',GIT_CONFIG_KEY_0:'credential.helper',GIT_CONFIG_VALUE_0:helper};
  const formal=run('/usr/bin/git',['credential','fill'],{env:{...env,HOME:scratch},cwd:scratch,input:'protocol=https\nhost=example.invalid\n\n'});
  assert.equal(formal.status,0,formal.stderr); assert.match(formal.stdout,/password=canary/);
  const before=read(marker);
  const staged=run(join(root,'Tatwo2Staging'),[],{env,cwd:root}); assert.equal(staged.status,0,staged.stderr);
  assert.equal(read(marker),before,'staging must not execute the old helper');
});
