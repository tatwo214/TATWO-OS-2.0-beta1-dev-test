import http.server, pathlib, sys, time, urllib.parse
root = pathlib.Path(sys.argv[1])
class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        with (root / 'requests.log').open('a') as log:
            log.write(self.headers.get('Host', '') + ' ' + path + '\n')
        port = self.server.server_port
        if path.startswith('/w291/'):
            data = pathlib.Path(__file__).with_name('w291-page.html').read_bytes()
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == '/prototype':
            data = (root / 'prototype.html').read_bytes()
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == '/document.pdf':
            objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                       b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>']
            data = b'%PDF-1.4\n'; offsets = [0]
            for i, obj in enumerate(objects, 1):
                offsets.append(len(data)); data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
            xref = len(data)
            data += b'xref\n0 4\n0000000000 65535 f \n' + b''.join(f'{o:010d} 00000 n \n'.encode() for o in offsets[1:])
            data += f'trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
            self.send_response(200); self.send_header('Content-Type', 'application/pdf')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        if path.startswith('/redirect/'):
            step = int(path.rsplit('/', 1)[1])
            host = 'localhost' if step % 2 == 0 else '127.0.0.1'
            destination = f'/redirect/{step+1}' if step < 2 else '/file/B'
            self.send_response(302)
            self.send_header('Location', f'http://{host}:{port}{destination}')
            self.end_headers()
            return
        if path.startswith('/file/'):
            name = path.rsplit('/', 1)[1]
            data = b'x' * (2 * 1024 * 1024) if name.startswith(('slow', 'unknown')) or name.startswith('broken') else ('W258 fixture ' + name + '\n').encode() * 4096
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            if name == 'slow-long-zh': filename = '報告' * 40 + '.bin'
            elif name == 'slow-long-ascii240': filename = 'a' * 240 + '.bin'
            elif name == 'slow-long-extension': filename = 'c.' + 'z' * 253
            elif name == 'slow-long-excl': filename = 'b' * 251 + '.bin'
            elif name.startswith('slow-long-zh'): filename = '報' * 83 + '.bin'
            elif name.startswith('slow-long-'): filename = 'a' * 251 + '.bin'
            else: filename = name + '.bin'
            if name.startswith('slow-long-'):
                self.send_header('Content-Disposition', "attachment; filename*=UTF-8''" + urllib.parse.quote(filename))
            else: self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        else:
            if not path.startswith('/page/'):
                self.send_error(404)
                return
            name = path.rsplit('/', 1)[1] or 'A'
            if name == 'dots': name = 'slow-dots'
            if name.startswith(('slow', 'unknown')) or name.startswith('broken'):
                link = (f'<input aria-label="Typing" autofocus><a href="/file/{name}" '
                        'onclick="document.querySelector(\'input\').focus()">Download slow</a>'
                        '<output></output><script>setInterval(()=>document.querySelector(\'output\').textContent='
                        '\'Focus:\'+document.activeElement.tagName+\' Typed:\'+document.querySelector(\'input\').value,20)</script>')
            else:
                link = {'A': '<a href="/file/A">Download A</a>',
                        'B': '<a href="/redirect/0">Download B</a>',
                        'C': '<a href="/file/C" target="_blank">Download C</a>',
                        'D': '<button onclick="location.href=\'/file/D\'">Download D</button>',
                        'E': '<a href="/file/E" download="E.bin">Download E</a>',
                        'agent': '<a href="/file/agent">Download agent</a>'}[name]
            data = ('<!doctype html><meta charset="utf-8"><title>W258</title>'
                    '<style>body{font:24px system-ui;padding:60px}a,button{font:inherit;white-space:nowrap}output{display:block}</style>' + link).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
        if not path.startswith('/file/unknown'): self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if path.startswith('/file/broken'):
            self.wfile.write(data[:16384]); self.wfile.flush()
        elif path.startswith(('/file/slow', '/file/unknown')):
            try:
                for offset in range(0, len(data), 16384):
                    self.wfile.write(data[offset:offset+16384]); self.wfile.flush(); time.sleep(1/16)
            except (BrokenPipeError, ConnectionResetError): pass
        else: self.wfile.write(data)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
