"""Exercise the real staging App and helpers with disposable HOME and a loopback form.
Usage: python3 tests/fixtures/w293-system.py <evidence directory>
Requires a CEF-enabled Tatwo2 dylib built with TATWO2_STAGING_DYLIB=1.
"""
import datetime, http.server, json, os, pathlib, plistlib, shutil, sqlite3
import subprocess, sys, tempfile, threading, time

repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='k-', dir=pathlib.Path.home() / 'tatwo-build/tmp'))
fake_user = fixture / 'u'
root = fake_user / 'Library/Application Support/tatwo2-staging'
env = os.environ.copy()
env.update(TATWO2_TEST_BINARY=os.environ.get('TATWO2_W293_STAGING_BINARY', str(repo / '.build/debug/Tatwo2')),
           TATWO2_W258_CEF_RECEIPT=str(out / 'system-app.json'))
subprocess.run(['node', 'tests/fixtures/w258-stage.mjs'], cwd=repo, env=env, check=True)
receipt = json.loads((out / 'system-app.json').read_text())
binary = pathlib.Path(receipt['binary'])
app = binary.parents[2]
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info.update(CFBundleIdentifier='ai.tatwo.tatwo2.staging', CFBundleExecutable='Tatwo2Staging',
            CFBundleName='W258', CFBundleDisplayName='TATWO OS Staging W293', NSPrincipalClass='TatwoCEFApplication',
            TatwoBrowserWorkspaceEnabled=True, SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False)
plist.write_bytes(plistlib.dumps(info))
header = out / 'fixture-user.h'
header.write_text('#include <pwd.h>\n#include <stdlib.h>\n'
                  'static struct passwd *fixtureUser(uid_t u) { static struct passwd p; '
                  'p.pw_dir=getenv("W293_FIXTURE_USER"); return &p; }\n#define getpwuid fixtureUser\n')
launcher = binary.parent / 'Tatwo2Staging'
keychain = binary.parent / 'tatwo2-staging-keychain.dylib'
subprocess.run(['clang', '-dynamiclib', '-Wno-deprecated-declarations', str(repo / 'script/tatwo2-staging-keychain.c'),
                '-framework', 'Security', '-Wl,-install_name,@executable_path/tatwo2-staging-keychain.dylib', '-o', str(keychain)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(keychain)], check=True)
subprocess.run(['clang', '-Os', '-include', str(header), str(repo / 'script/tatwo2-staging-launcher.c'),
                '-Wl,-needed_library,' + str(keychain), '-o', str(launcher)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'ai.tatwo.tatwo2.staging', str(binary)], check=True)
for target in [launcher, app]:
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

class Site(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def record(self):
        with (out / 'site-requests.log').open('a') as f:
            f.write(f'{time.time():.3f} {self.command} {self.path} cookie-present={bool(self.headers.get("Cookie"))}\n')
    def do_GET(self):
        self.record()
        body = b'''<!doctype html><title>W293 local cookie and password fixture</title>
<form action="/login" method="post"><input name="username" autocomplete="username" value="synthetic">
<input name="password" type="password" autocomplete="current-password" value="fixture-pass">
<button>Submit synthetic form</button></form><p id="status">Local fixture</p>
<script>document.cookie='js_fixture=canary; Max-Age=3600; SameSite=Lax';
setInterval(()=>fetch('/heartbeat').then(()=>document.querySelector('#status').textContent='Cookie write exercised'),2000);
if(location.pathname=='/')setTimeout(()=>document.querySelector('form').requestSubmit(),3000);</script>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Set-Cookie', 'http_fixture=canary; Max-Age=3600; HttpOnly; SameSite=Lax')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.record()
        self.send_response(303)
        self.send_header('Set-Cookie', 'form_fixture=canary; Max-Age=3600; HttpOnly; SameSite=Lax')
        self.send_header('Location', '/done')
        self.end_headers()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Site)
threading.Thread(target=server.serve_forever, daemon=True).start()
env.update(W293_FIXTURE_USER=str(fake_user), TATWO_STAGING_ALLOW_BROWSER_LOOPBACK='1',
           TATWO_STAGING_BROWSER_LOOPBACK_PORT=str(server.server_port))
# The probe imports Security.framework: set fake HOME before dyld loads it.
env.update(HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'),
           TATWO_STAGING_SCRATCH_HOME=str(root / 'home'), W293_KEYCHAIN_TRACE=str(out / 'native-api-trace.txt'))
probe = out / 'keychain-probe.dylib'
subprocess.run(['clang', '-dynamiclib', '-Wno-deprecated-declarations',
    str(repo / 'tests/fixtures/w293-keychain-probe.c'), '-framework', 'Security', '-o', str(probe)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(probe)], check=True)
env['DYLD_INSERT_LIBRARIES'] = str(probe)
# Clear all selftest markers: this is the normal staging startup path.
for key in list(env):
    if key.startswith('TATWO2_') and (key == 'TATWO2_SELFTEST' or key.endswith('TEST')):
        del env[key]
start = datetime.datetime.now().astimezone()
log = (out / 'system-app.log').open('w')
# CEF Helpers apply their own sandbox; macOS refuses a second sandbox_init.
process = subprocess.Popen([str(launcher), '--staging-snapshot'],
                           env=env, stdout=log, stderr=log)
samples, pids = [], {process.pid}
try:
    time.sleep(4)
    opened = subprocess.run(['open', '-a', str(app), f'http://127.0.0.1:{server.server_port}/'],
                            capture_output=True, text=True)
    (out / 'open-url.txt').write_text(f'exit={opened.returncode}\n{opened.stdout}{opened.stderr}')
    if opened.returncode:
        raise RuntimeError('LaunchServices could not open fixture URL')
    deadline = time.monotonic() + 125
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'staging exited early: {process.returncode}')
        if subprocess.run(['pgrep', '-x', 'SecurityAgent'], capture_output=True).returncode == 0:
            raise RuntimeError('SecurityAgent appeared; stop without accepting or resetting Keychain')
        ps = subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True)
        rows = [line for line in ps.splitlines() if str(app) + '/Contents/' in line]
        pids.update(int(line.strip().split()[0]) for line in rows)
        if not rows or any('--use-mock-keychain' not in line for line in rows):
            raise RuntimeError('OS argv is missing the owned mock switch')
        samples.append((time.time(), rows))
        (out / 'ps-last.txt').write_text('\n'.join(rows) + '\n')
        (out / 'ps-args.txt').write_text(subprocess.check_output(
            ['ps', '-o', 'args', '-p', ','.join(line.strip().split()[0] for line in rows)], text=True))
        time.sleep(5)
finally:
    # Only the disposable App from this run is terminated; other Apps stay running.
    if process.poll() is None:
        subprocess.run(['osascript', '-e', f'tell application "{app}" to quit'], capture_output=True, timeout=10)
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    server.shutdown()
    log.close()
    end = datetime.datetime.now().astimezone()
    (out / 'ps-samples.json').write_text(json.dumps(samples, indent=2))
    result = subprocess.run(['/usr/bin/log', 'show', '--start', start.strftime('%Y-%m-%d %H:%M:%S'),
        '--end', end.strftime('%Y-%m-%d %H:%M:%S'), '--style', 'compact', '--info', '--debug',
        '--predicate', 'process == "SecurityAgent" OR subsystem == "com.apple.securityd"'],
        capture_output=True, text=True)
    (out / 'security-log-raw.txt').write_text(result.stdout + result.stderr)
    import re
    related = [line for line in result.stdout.splitlines() if
        str(app) in line or str(root) in line or
        any(re.search(r'\bpid\s*[:=]?\s*' + str(pid) + r'\b', line, re.I) for pid in pids) or
        any(re.search(r'\[' + str(pid) + r':', line) for pid in pids) or
        re.search(r'W258 Helper|Chromium Safe Storage|SecurityAgent\[', line, re.I)]
    (out / 'security-log-correlated.txt').write_text('\n'.join(related) + '\n')
    requests = [line for line in related if re.search(
        r'SecItem(?:CopyMatching|Add|Update|Delete)|SecKeychain(?:Find|Add)|Safe Storage|SecurityAgent\[|CSSMERR_CSP_OPERATION_AUTH_DENIED', line, re.I)]
    trace = (out / 'native-api-trace.txt').read_text().splitlines()
    attached = {int(line.split()[0]) for line in trace if ' attached' in line}
    calls = [line for line in trace if ' call ' in line]
    (out / 'security-log-filtered.txt').write_text(
        f'log show exit={result.returncode}; interval={start.isoformat()}..{end.isoformat()}; stagingPIDs={sorted(pids)}\n'
        + '\n'.join(requests) + ('\n' if requests else 'staging-related credential requests/SecurityAgent matches=0\n')
        + f'correlated framework diagnostic lines={len(related)}; native credential API calls={len(calls)}; attachedPIDs={sorted(attached)}\n')
    cookies = []
    for db in root.rglob('Cookies'):
        try:
            with sqlite3.connect(f'file:{db}?mode=ro', uri=True) as connection:
                cookies.extend(connection.execute('select name,length(value),length(encrypted_value) from cookies where host_key="127.0.0.1"').fetchall())
        except sqlite3.Error:
            pass
    summary = dict(app=str(app), disposableRoot=str(root), seconds=(end-start).total_seconds(),
                   samples=len(samples), pids=sorted(pids), logExit=result.returncode,
                   securityMatches=len(requests), frameworkDiagnostics=len(related), nativeCalls=calls,
                   attachedPIDs=sorted(attached), cookies=cookies)
    (out / 'system-summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)
site_requests = (out / 'site-requests.log').read_text()
assert 'POST /login' in site_requests and 'cookie-present=True' in site_requests, 'cookie/password fixture did not run'
assert len(samples) >= 24, 'two-minute process sampling incomplete'
assert cookies and all(length > 0 and plain == 0 for _, plain, length in cookies), 'cookies were not encrypted on disk'
assert result.returncode == 0 and not requests, 'system credential request log verification failed'
assert not calls and pids.issubset(attached), 'native API probe missed a process or observed a credential API call'
