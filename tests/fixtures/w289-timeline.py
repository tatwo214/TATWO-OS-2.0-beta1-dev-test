"""Loopback-only recycling feed; each image response waits 80 ms. No accounts."""
import http.server
import json
import pathlib
import struct
import sys
import time
import zlib

root = pathlib.Path(sys.argv[1])
PAGE = b'''<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:#eee}article{height:420px;padding:10px}img,video{width:300px;height:180px}
</style><main></main><script>
const feed=document.querySelector('main');let serial=0,recycled=0,maxCards=0;
function add(){const a=document.createElement('article'),img=new Image(),v=document.createElement('video');
img.src='/image?'+serial++;v.muted=true;v.autoplay=true;v.loop=true;
const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;
const ctx=canvas.getContext('2d');ctx.fillStyle='#369';ctx.fillRect(0,0,320,180);
const stream=canvas.captureStream(5),recorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp8'}),chunks=[];
recorder.ondataavailable=e=>chunks.push(e.data);recorder.onstop=()=>{stream.getTracks().forEach(t=>t.stop());
if(v.isConnected){v.dataset.blob=URL.createObjectURL(new Blob(chunks,{type:'video/webm'}));v.src=v.dataset.blob;v.play().catch(()=>{});}};
recorder.start();setTimeout(()=>recorder.stop(),600);a.append(img,v);feed.append(a);maxCards=Math.max(maxCards,feed.children.length);}
for(let i=0;i<10;i++)add();
setInterval(()=>{scrollBy(0,42);if(scrollY>420){const a=feed.firstChild;
const v=a.querySelector('video');v.pause();if(v.dataset.blob)URL.revokeObjectURL(v.dataset.blob);a.remove();scrollBy(0,-440);add();recycled++;}
},50);
setInterval(()=>{feed.children[1].querySelector('img').src='/image?'+serial++;},2000);
// Exercise the numeric observer without sending the sentinel content to diagnostics.
document.title='W289_PRIVATE_SENTINEL';
setInterval(()=>{const v=feed.querySelector('video');v.dispatchEvent(new Event('waiting'));v.dispatchEvent(new Event('stalled'));
const start=performance.now();while(performance.now()-start<65){}},7000);
setInterval(()=>fetch('/state',{method:'POST',body:JSON.stringify({cards:feed.children.length,maxCards,recycled,images:document.images.length,videos:document.querySelectorAll('video').length,decodedVideos:[...document.querySelectorAll('video')].filter(v=>v.videoWidth>0).length})}),5000);
</script>'''

def image():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 300, 180, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\0' + b'\x30\x60\x90' * 300) * 180)) + chunk(b'IEND', b''))

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        is_image = self.path.startswith('/image')
        if is_image:
            time.sleep(.08)
        data = image() if is_image else PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if is_image else 'text/html')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        (root / 'feed-state.json').write_text(json.dumps(data))
        self.send_response(204)
        self.end_headers()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
