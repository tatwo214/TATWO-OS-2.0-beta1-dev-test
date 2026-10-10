#!/usr/bin/env python3
"""Outbound W264 client. Only the configured local runner consumes job instructions."""
import argparse
import base64
import getpass
import hashlib
import html.parser
import http.client
import json
import os
import re
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse as url

TOOLS = {'sandbox_fetch_job', 'sandbox_post_result', 'sandbox_heartbeat'}
LIMIT = 204800
CALLBACK = 'https://chatgpt.com/connector_platform_oauth_redirect'  # W264 identifier; never contacted.
INIT = {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'runner', 'version': '1'}}


class Refused(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class JobError(Refused):
    pass


class Form(html.parser.HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.fields = {}
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'input' and attrs.get('type') == 'hidden':
            self.fields[attrs.get('name')] = attrs.get('value', '')


class Client:
    def __init__(self, gateway, unix_socket=None):
        self.origin = gateway.rstrip('/')
        self.target = url.urlsplit(self.origin)
        if (self.target.scheme != 'https' or not self.target.hostname or
                self.target.username or self.target.password or
                self.target.path or self.target.query or self.target.fragment):
            raise Refused('gateway must be an HTTPS origin')
        self.socket = unix_socket  # Fixture transport: HTTP over Unix, never TCP.
        self.session = None
        self.token = None
        self.save = None

    def request(self, path, body=None, form=False, headers=None):
        if path.split('?')[0] not in {'/sandbox/register', '/sandbox/token', '/authorize', '/mcp'}:
            raise Refused('endpoint refused')
        conn = http.client.HTTPSConnection(self.target.hostname, self.target.port, timeout=30)
        if self.socket:
            conn = http.client.HTTPConnection(self.target.hostname, timeout=30)
            conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.sock.settimeout(30)
            conn.sock.connect(self.socket)
        data = None if body is None else (url.urlencode(body) if form else json.dumps(body)).encode()
        fields = {'Host': self.target.netloc, 'Accept': 'application/json'}
        if self.socket:
            fields['Cf-Connecting-Ip'] = '198.51.100.7'  # Synthetic proxy header, Unix fixture only.
        if data is not None:
            fields['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
        fields.update(headers or {})
        try:
            conn.request('GET' if data is None else 'POST', path, data, fields)
            res = conn.getresponse()
            raw = res.read(1048577)
            if len(raw) > 1048576 or res.status not in (200, 201, 302):
                reason = re.search(rb'"error"\s*:\s*"([a-z_]{1,40})"', raw[:2048])
                raise Refused('gateway refused %s (HTTP %s%s); stopped' % (path.split('?')[0], res.status,
                              ' ' + reason[1].decode() if reason else ''),
                              res.status if res.status != 404 or b'Session not found' in raw[:2048] else None)
            return res.status, {key.lower(): value for key, value in res.getheaders()}, raw.decode('utf-8')
        finally:
            conn.close()

    def pair(self, name, redirect=CALLBACK):
        _, _, raw = self.request('/sandbox/register', {'client_name': name, 'redirect_uris': [redirect]})
        registration = json.loads(raw)
        if registration.get('scope') != 'sandbox':
            raise Refused('unexpected registration scope')
        verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(24)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
        query = {'response_type': 'code', 'client_id': registration['client_id'], 'redirect_uri': redirect,
                 'scope': 'sandbox', 'state': state, 'code_challenge': challenge, 'code_challenge_method': 'S256'}
        _, headers, raw = self.request('/authorize?' + url.urlencode(query))
        form = Form(raw).fields
        if set(form) != {'transaction_id', 'csrf'}:
            raise Refused('invalid pairing page')
        display = re.search(r'<strong>([A-Z2-9]{4})</strong>', raw)
        if not display:
            raise Refused('invalid transaction display code')
        print('交易：%s；回呼識別：%s（不會連往該網址）。請在主設備核對再輸入配對碼。' % (display[1], url.urlsplit(redirect).netloc), flush=True)
        form['code'] = getpass.getpass('配對碼：') if sys.stdin.isatty() else sys.stdin.readline().strip()
        status, headers, _ = self.request('/authorize', form, form=True, headers={
            'Cookie': headers.get('set-cookie', '').split(';')[0], 'Origin': self.origin})
        location = url.urlsplit(headers.get('location', ''))
        reply = url.parse_qs(location.query)
        if (status != 302 or location.scheme + '://' + location.netloc + location.path != redirect
                or reply.get('state') != [state] or reply.get('iss') != [self.origin]):
            raise Refused('invalid authorization response')
        _, _, raw = self.request('/sandbox/token', {'grant_type': 'authorization_code', 'code': reply['code'][0],
            'client_id': registration['client_id'], 'redirect_uri': redirect, 'code_verifier': verifier}, form=True)
        token = json.loads(raw)
        if token.get('scope') != 'sandbox' or not isinstance(token.get('access_token'), str):
            raise Refused('unexpected token scope')
        # Access tokens last an hour; the refresh token rotates on every use and is refused once the user revokes.
        return {'gateway': self.origin, 'client_id': registration['client_id'], 'access_token': token['access_token'],
                'refresh_token': token.get('refresh_token'), 'expires_at': time.time() + token['expires_in']}

    def refresh(self):
        if not (isinstance(self.token.get('refresh_token'), str) and isinstance(self.token.get('client_id'), str)):
            raise Refused('token expired; stopped')
        _, _, raw = self.request('/sandbox/token', {'grant_type': 'refresh_token', 'refresh_token': self.token['refresh_token'],
            'client_id': self.token['client_id']}, form=True)
        token = json.loads(raw)
        if (token.get('scope', 'sandbox') != 'sandbox' or not isinstance(token.get('access_token'), str)
                or not isinstance(token.get('refresh_token'), str)):
            raise Refused('unexpected token scope')
        self.token.update(access_token=token['access_token'], refresh_token=token['refresh_token'],
                          expires_at=time.time() + token['expires_in'])
        if self.save:
            try:
                self.save(self.token)
            except OSError:
                # The old refresh token is already spent; a restart would reuse it and get the grant revoked.
                raise Refused('token save failed; pair again')

    def rpc(self, method, params, retried=False):
        if self.token['expires_at'] <= time.time() + 60:
            self.refresh()
        fields = {'Authorization': 'Bearer ' + self.token['access_token']}
        if self.session:
            fields['Mcp-Session-Id'] = self.session
        try:
            _, headers, raw = self.request('/mcp', {'jsonrpc': '2.0', 'id': secrets.token_hex(16),
                'method': method, 'params': params}, headers=fields)
        except Refused as error:
            # Sessions end after 24 hours; the gateway answers 404 and MCP says to initialize again, once.
            if error.status != 404 or not self.session or retried or method == 'initialize':
                raise
            self.session = None
            self.rpc('initialize', INIT, True)
            return self.rpc(method, params, True)
        self.session = headers.get('mcp-session-id', self.session)
        reply = json.loads(raw)
        if 'error' in reply:
            raise Refused('MCP refused; stopped', 503 if isinstance(reply['error'], dict) and reply['error'].get('code') == -32000 and
                          reply['error'].get('message') == 'TATWO OS is temporarily unavailable' else None)
        return reply['result']

    def call(self, name, args=None):
        if name not in TOOLS:
            raise Refused('tool refused')
        result = self.rpc('tools/call', {'name': name, 'arguments': {'issued_at': time.time(), **(args or {})}})
        if result.get('isError'):
            # W264 currently represents an empty queue as this tool error.
            text = ''.join(c.get('text', '') for c in result.get('content', []))
            if re.search(r'\b(unauthorized|invalid_grant|revoked)\b|撤銷', text, re.I):
                raise Refused('sandbox authorization refused; stopped', 403)
            if name == 'sandbox_fetch_job' and '沒有可領取的工作' in text:
                return None
            if name == 'sandbox_post_result' or name == 'sandbox_heartbeat' and args and args.get('job_id') and text != 'TATWO OS is temporarily unavailable.':
                raise JobError('sandbox result refused: ' + text[:1000])
            raise Refused('sandbox tool refused; stopped', 503 if text == 'TATWO OS is temporarily unavailable.' else None)
        return result


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Refused('unsafe state directory')
    path.chmod(0o700)


def path_in(root, name):
    parts = name.split('/')
    if (not name or any(p in ('', '.', '..') or p.lower() == '.git' for p in parts)
            or '\\' in name or any(ord(c) < 32 for c in name)):
        raise JobError('unsafe snapshot path')
    result = root.joinpath(*parts)
    if result.is_symlink() or not result.resolve().is_relative_to(root.resolve()):
        raise JobError('snapshot path escaped workspace')
    return result


def run_job(client, job, root, runner, timeout, heartbeat):
    work = Path(tempfile.mkdtemp(prefix='job-', dir=root))
    try:
        with tempfile.TemporaryDirectory(prefix='runner-home-', dir=root) as home:
            execute_job(client, job, work, Path(home), runner, timeout, heartbeat)
    except (JobError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report = '工作失敗：' + str(error)[:2000]
        try:
            (work / 'failure-report.txt').write_text(report, encoding='utf-8')
        except OSError:
            print(report, file=sys.stderr)
        try:
            client.call('sandbox_post_result', {'job_id': job['job_id'], 'lease': job['lease'], 'report': report})
        except (Refused, http.client.HTTPException, OSError, ValueError) as refused:
            if isinstance(refused, Refused) and not isinstance(refused, JobError) and (refused.status in (None, 401, 403) or 'invalid_grant' in str(refused)):
                raise
            print('失敗報告保留於：' + str(work), file=sys.stderr)
    finally:
        for old in sorted(root.glob('job-*'), key=lambda p: p.stat().st_mtime, reverse=True)[20:]:
            shutil.rmtree(old)


def execute_job(client, job, work, home, runner, timeout, heartbeat):
    files, artifacts = job['files'], job['artifacts']
    if (len(files) > 32 or len(artifacts) > 16 or len(json.dumps(job, ensure_ascii=False, separators=(',', ':')).encode()) > 262144
            or len(job['instruction'].encode()) > 8192):
        raise JobError('snapshot exceeds W264 limits')
    for name, text in files.items():
        if '\0' in text or len(text.encode()) > 65536:
            raise JobError('invalid snapshot text')
        target = path_in(work, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding='utf-8')
    for name in artifacts:
        path_in(work, name)
    # Runner never inherits pairing credentials, engine accounts or the user's HOME.
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home), 'TMPDIR': str(home),
           'LANG': 'en_US.UTF-8', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}

    def git(*args):
        return subprocess.run(['git', '-c', 'core.quotePath=false', '-c', 'core.hooksPath=/dev/null', *args], cwd=work, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=30).stdout

    git('init', '-q', '--template=')
    git('add', '--force', '.')
    git('-c', 'user.name=TATWO Sandbox', '-c', 'user.email=sandbox@localhost', 'commit', '-qm', 'snapshot', '--allow-empty')
    snapshot = git('rev-parse', 'HEAD').decode().strip()
    own = {'job_id': job['job_id'], 'lease': job['lease']}
    client.call('sandbox_heartbeat', own)
    output = bytearray()
    instruction = home / 'instruction.txt'
    instruction.write_text(job['instruction'], encoding='utf-8')
    with instruction.open('rb') as data:
        proc = subprocess.Popen(runner, stdin=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                cwd=work, env=env, start_new_session=True)

    def drain():
        while True:
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            output.extend(chunk[:max(0, 65536 - len(output))])

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    deadline, next_beat = time.monotonic() + timeout, time.monotonic() + heartbeat
    timed_out = False
    try:
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                timed_out = True
                break
            if time.monotonic() >= next_beat:
                client.call('sandbox_heartbeat', own)
                next_beat = time.monotonic() + heartbeat
            time.sleep(0.1)
    finally:
        # Also terminate leftover descendants after the runner exits.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        reader.join(timeout=2)
        proc.stdout.close()
    client.call('sandbox_heartbeat', own)
    report = ('timeout' if timed_out else 'exit=%s' % proc.returncode) + '\n' + output.decode('utf-8', 'replace')
    names = sorted(set(files) | set(artifacts))
    for name in names:
        target = path_in(work, name)
        if target.exists():
            if not target.is_file() or target.stat().st_size > LIMIT:
                raise JobError('result must be bounded text')
            content = target.read_bytes()
            if len(content) > LIMIT or b'\0' in content:
                raise JobError('result must be bounded text')
            content.decode('utf-8')
            git('add', '-N', '--force', '--', name)
    patch = git('diff', snapshot, '--no-ext-diff', '--no-textconv', '--', *names).decode('utf-8') if names else ''
    if len(patch.encode()) + len(report.encode()) > LIMIT:
        raise JobError('Result exceeds 200 KB; retained locally for review.')
    client.call('sandbox_post_result', {**own, 'patch': patch, 'report': report})
    print('交件已送主設備審查。工作目錄：' + str(work), flush=True)


def write_token(path, token):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, 'w') as out:
        json.dump(token, out)
    os.replace(temporary, path)


def main():
    if os.getuid() == 0 or os.geteuid() == 0:
        raise Refused('refuse root; run as your normal user without sudo')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['pair', 'run'])
    parser.add_argument('--gateway')
    parser.add_argument('--name', default=socket.gethostname())
    parser.add_argument('--redirect-uri', default=CALLBACK, help='W264 callback identifier, never fetched')
    parser.add_argument('--runner', help='local command; job instruction is stdin, never an agent control message')
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--interval', type=int, default=30)
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--socket', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 3600 or not 1 <= args.interval <= 300:
        raise Refused('invalid timeout or interval')
    root = Path.home() / '.tatwo-sandbox'
    private_dir(root)
    token_file = root / 'token.json'
    if args.action == 'pair':
        client = Client(args.gateway or '', args.socket)
        write_token(token_file, client.pair(args.name, args.redirect_uri))
        print('已配對；權杖只允許領工、交件、心跳。')
        return
    if not args.runner:
        raise Refused('run requires an explicitly selected --runner')
    if token_file.is_symlink():
        raise Refused('unsafe token symlink')
    fd = os.open(token_file, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as data:
        info = os.fstat(data.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise Refused('token file must be owned by you with mode 600')
        token = json.load(data)
    client = Client(token['gateway'], args.socket)
    client.token, client.save = token, lambda value: write_token(token_file, value)
    client.rpc('initialize', INIT)
    while True:
        client.call('sandbox_heartbeat')
        fetched = client.call('sandbox_fetch_job')
        if fetched:
            job = json.loads(fetched['content'][0]['text'])
            run_job(client, job, root, shlex.split(args.runner), args.timeout, min(args.interval, 30))
        if args.once:
            return
        time.sleep(args.interval)


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print(str(error), file=sys.stderr)
        sys.exit(1 if error.status in (408, 429) or error.status is not None and 500 <= error.status <= 599 else 3)
    except (http.client.HTTPException, OSError, ValueError, KeyError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print('沙盒版已停止（%s）；連線或執行失敗。' % type(error).__name__, file=sys.stderr)
        sys.exit(3 if isinstance(error, PermissionError) else 1)
