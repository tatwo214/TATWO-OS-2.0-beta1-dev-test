"""Build native host against the actual CEF object, stage helpers, run isolated loopback probes.
Call only after the room's CEF build; consumes existing local runtime, no downloads.
"""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['TATWO2_TEST_BINARY'] = str(repo / '.build/debug/Tatwo2')
env['TATWO2_W258_CEF_RECEIPT'] = str(out / 'native-app.json')
subprocess.run(['node', 'tests/fixtures/w258-stage.mjs'], cwd=repo, env=env, check=True)
receipt = json.loads((out / 'native-app.json').read_text())
app = pathlib.Path(receipt['binary']).parents[2]
cef = pathlib.Path(env['TATWO_CEF_ROOT'])
obj = repo / '.build/out/Intermediates.noindex/TatwoUltrawork.build/Debug/TatwoCEFBridge-t.build/Objects-normal/arm64/TatwoCEFBridge.o'
subprocess.run(['clang++', '-std=c++20', '-fobjc-arc', '-fno-rtti', '-DUSING_CEF_SHARED',
    '-I' + str(cef), '-I' + str(repo / 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include'),
    str(repo / 'tests/fixtures/w289-cef.mm'), str(obj), env['TATWO_CEF_WRAPPER_LIBRARY'],
    '-F' + str(cef / 'Release'), '-framework', 'Chromium Embedded Framework',
    '-framework', 'Cocoa', '-framework', 'Security', '-framework', 'CoreServices',
    '-framework', 'Quartz', '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(out / 'native-host')], check=True)
shutil.copy2(out / 'native-host', receipt['binary'])
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info.update(CFBundleIdentifier='ai.tatwo.tatwo2.staging.w289', CFBundleName='W289')
plist.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', receipt['binary']], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
server = subprocess.Popen(['/usr/bin/python3', str(repo / 'tests/fixtures/w289-timeline.py'), str(out)])
try:
    import time
    deadline = time.monotonic() + 10
    while not (out / 'port').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('loopback server timeout')
        time.sleep(.05)
    port = (out / 'port').read_text()
    variants = [('off', '0', '0', 'x.com', '135'), ('on', '1', '0', 'x.com', '135'),
                ('no-inject', '1', '1', 'x.com', '35'), ('foreign', '1', '0', 'fixture.invalid', '15'),
                ('twitter', '1', '0', 'twitter.com', '15')]
    if env.get('W289_SMOKE') == '1':
        variants = [(label, diag, noinj, host, '15') for label, diag, noinj, host, seconds in variants]
        variants.sort(key=lambda v: v[0] != 'on')
    for label, diagnostic, noinject, host, seconds in variants:
        root = pathlib.Path(receipt['scratch']) / label
        for folder in ('home', 'os', 'live', 'engines/codex', 'engines/claude', 'docs'):
            (root / folder).mkdir(parents=True, exist_ok=True)
        child = env.copy()
        child.update(HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'),
            TATWO_STAGING_SCRATCH_HOME=str(root / 'home'), TATWO_STAGING_ROOT=str(root),
            TATWO2_LIVE_ROOT=str(root / 'live'), TATWO2_OS_ROOT=str(root / 'os'),
            TATWO2_ENGINES_ROOT=str(root / 'engines'), CODEX_HOME=str(root / 'engines/codex'),
            CLAUDE_CONFIG_DIR=str(root / 'engines/claude'), TATWO2_DOCS_ROOT=str(root / 'docs'),
            TATWO_X_DIAG=diagnostic, TATWO_X_DIAG_NO_INJECT=noinject, W289_HOST=host,
            W289_PORT=port, W289_SECONDS=seconds)
        if diagnostic == '0':
            child.pop('TATWO_X_DIAG', None)
            child.pop('TATWO_X_DIAG_NO_INJECT', None)
        args = [receipt['binary'], '--use-mock-keychain', '--no-proxy-server',
            '--host-resolver-rules=MAP x.com 127.0.0.1, MAP twitter.com 127.0.0.1, MAP fixture.invalid 127.0.0.1, MAP * ~NOTFOUND']
        with (out / (label + '.log')).open('w') as log:
            run = subprocess.run(args, env=child, stdout=log, stderr=log, timeout=int(seconds) + 35)
        print(label, 'exit', run.returncode, flush=True)
        if run.returncode:
            raise RuntimeError('native CEF probe failed: ' + label)
        for f in ('cef-embedding-telemetry.log', 'host-stats.json'):
            shutil.copy2(root / f, out / (label + '-' + f))
        if (out / 'feed-state.json').exists():
            shutil.copy2(out / 'feed-state.json', out / (label + '-feed-state.json'))
finally:
    server.terminate()
    server.wait(timeout=10)
