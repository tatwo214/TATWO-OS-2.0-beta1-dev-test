#!/usr/bin/env bash
# Run on the logged-in macOS desktop. Never launch, quit or modify production.
# Usage: bash tests/fixtures/w276-launchservices-verify.sh [staging.app] [evidence-dir]
set -euo pipefail
FIXTURES="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/tatwo-build/staging-app/TATWO OS Staging.app}"
OUT="${2:-$(mktemp -d /tmp/w276-system-XXXXXX)}"
mkdir -p "$OUT"
clang -fobjc-arc -framework AppKit "$FIXTURES/w276-system-windows.m" -o "$OUT/system-windows"
/usr/bin/python3 - "$APP" "$OUT" <<'PY'
import json,os,pathlib,plistlib,subprocess,sys,time
app=pathlib.Path(sys.argv[1]).resolve(); out=pathlib.Path(sys.argv[2]).resolve()
bundle='ai.tatwo.tatwo2.staging'; executable=str(app/'Contents/MacOS/Tatwo2Staging')
assert not str(app).startswith('/Applications/'), 'production location refused'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info.get('CFBundleIdentifier')==bundle and info.get('CFBundleExecutable')=='Tatwo2Staging', 'only W276 staging permitted'
def run(args, timeout=30):
    return subprocess.run(args,capture_output=True,text=True,timeout=timeout)
def processes():
    return [(int(line.strip().split(None,1)[0]),line.strip().split(None,1)[1])
        for line in run(['ps','-axo','pid=,comm=']).stdout.splitlines()
        if len(line.strip().split(None,1))==2]
def owned():
    return [(pid,cmd) for pid,cmd in processes() if cmd.startswith(str(app)+'/Contents/')]
def observe(name,pid=None):
    r=run([str(out/'system-windows')]+([str(pid)] if pid else [])); assert r.returncode==0,r.stderr
    (out/(name+'.json')).write_text(r.stdout); return json.loads(r.stdout)
def main_windows(data,pid):
    return sorted([w for w in data['windows'] if w['pid']==pid and w['layer']==0 and w['visible']
        and w['alpha']>0 and w['bounds']['Width']>400 and w['bounds']['Height']>400],key=lambda w:w['id'])
assert not owned(), 'candidate already running; refuse to disturb it'
sign=run(['codesign','--verify','--deep','--strict',str(app)])
assert sign.returncode==0,sign.stderr
before=observe('before')
formal=[a for a in before['apps'] if a['bundleID']=='ai.tatwo.tatwo2']
assert len(formal)<=1, 'multiple production instances'
formal_pid=formal[0]['pid'] if formal else None
if formal_pid:
    assert len(main_windows(before,formal_pid))==1, 'production needs one visible main window before testing'
if any(pid==72148 for pid,cmd in processes()):
    assert formal_pid==72148, 'protected production pid identity mismatch'
assert not any(pathlib.Path(cmd).name=='Tatwo2Staging' for pid,cmd in processes()), 'another staging instance is running'
results=[]
for mode in ['open','finder']:
    pid=None
    try:
        if mode=='open':
            launch=run(['open','-g','--stdout',str(out/'open.stdout'),'--stderr',str(out/'open.stderr'),str(app)])
        else:
            # Deliver the file's open action to Finder through LaunchServices.
            # Finder opens the actual .app; no Automation or mouse permission.
            # This exercises Finder's open handler, not a physical mouse gesture.
            launch=run(['open','-a','Finder',str(app)])
        (out/(mode+'-launch.txt')).write_text(f'exit={launch.returncode}\n'+launch.stdout+launch.stderr)
        assert launch.returncode==0,launch.stderr
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            mains=[p for p,cmd in owned() if cmd==executable]
            assert len(mains)<=1, 'multiple staging processes'
            if mains:
                pid=mains[0]; snapshot=observe(mode+'-during',pid)
                staging=[a for a in snapshot['apps'] if a['bundleID']==bundle and a['pid']==pid]
                if len(staging)==1 and len(main_windows(snapshot,pid))==1: break
            time.sleep(.25)
        else: raise AssertionError('no staging NSRunningApplication + visible WindowServer main window within 30s')
        ls=run(['lsappinfo','info','-only','bundleid,name,pid',str(pid)])
        (out/(mode+'-lsappinfo.txt')).write_text(ls.stdout+ls.stderr)
        assert ls.returncode==0 and f'bundleID="{bundle}"' in ls.stdout and '"TATWO OS Staging"' in ls.stdout and f'pid = {pid}' in ls.stdout,ls.stdout+ls.stderr
        full=run(['lsappinfo','info',str(pid)])
        (out/(mode+'-lsappinfo-full.txt')).write_text(full.stdout+full.stderr)
        assert str(app) in full.stdout, 'full lsappinfo missing candidate bundle path'
        window=main_windows(snapshot,pid)[0]
        print(f'{mode}: launch_exit=0 bundleID={bundle} name="TATWO OS Staging" pid={pid}',flush=True)
        print(f'CGWindow: owner="{window["owner"]}" pid={pid} layer=0 visible=1 width={window["bounds"]["Width"]} height={window["bounds"]["Height"]} count=1',flush=True)
        if formal_pid:
            assert main_windows(snapshot,formal_pid)==main_windows(before,formal_pid), 'production main window changed'
            print(f'parallel: formal_pid={formal_pid} formal_windows=1 staging_windows=1 formal_main_unchanged=1',flush=True)
        else: print('parallel: NOT_TESTED production is not running',flush=True)
        quit_result=run(['osascript','-e',f'tell application id "{bundle}" to quit'],timeout=20)
        (out/(mode+'-quit.txt')).write_text(f'exit={quit_result.returncode}\n'+quit_result.stdout+quit_result.stderr)
        assert quit_result.returncode==0,quit_result.stderr
        for _ in range(40):
            if not owned(): break
            time.sleep(.25)
        assert not owned(),f'residual staging processes: {owned()}'
        after=observe(mode+'-after')
        assert not [a for a in after['apps'] if a['bundleID']==bundle], 'residual staging LaunchServices app'
        if formal_pid: assert main_windows(after,formal_pid)==main_windows(before,formal_pid), 'production main changed after quit'
        print('quit: osascript_exit=0 residual_processes=0',flush=True)
        results.append(dict(mode=mode,pid=pid,window=window,formalPID=formal_pid,launchExit=0,quitExit=0,residual=0))
    finally:
        # Failure cleanup targets only the candidate pids launched by this test.
        if pid is not None and any(p==pid for p,cmd in owned()):
            run(['osascript','-e',f'tell application id "{bundle}" to quit'],timeout=20)
            for _ in range(20):
                if not owned(): break
                time.sleep(.25)
            for p,cmd in owned(): os.kill(p,15)
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
print('SYSTEM_ACCEPTANCE PASS evidence='+str(out))
PY
