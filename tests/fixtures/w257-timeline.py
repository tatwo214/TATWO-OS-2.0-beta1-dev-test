"""Loopback-only X-shaped timeline; all images generated in the page."""
import http.server
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
PAGE = r'''<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'">
<style>
body{margin:0;background:#fff;color:#111;font:15px system-ui}main{width:600px;margin:auto;border:1px solid #ddd}
article{height:300px;box-sizing:border-box;padding:12px;border-bottom:1px solid #ddd;display:flex;gap:12px}
.avatar{width:40px;height:40px;border-radius:50%}.content{flex:1}.photo{width:500px;height:170px;object-fit:cover;border-radius:12px}
button{background:#fff;border:0;padding:8px 24px;color:#444}p{margin:8px 0}
</style><main aria-label="Local timeline"><h1>W257 local timeline</h1><div id="feed"></div><button id="proof">W257 AX requested content</button></main>
<script>
const canvas=document.createElement('canvas');canvas.width=640;canvas.height=240;
const ctx=canvas.getContext('2d');ctx.fillStyle='#567c9d';ctx.fillRect(0,0,640,240);
for(let i=0;i<80;i++){ctx.fillStyle=`hsl(${i*17%360} 45% 65%)`;ctx.fillRect(i*23%640,i*31%240,50,30)}
const photo=canvas.toDataURL('image/png');let cards=0,batches=0;
function append(){let html='';for(let i=0;i<20;i++){const n=++cards;html+=`<article aria-label="Post ${n}"><img class="avatar" src="${photo}" alt="Avatar ${n}"><div class="content"><div><div><strong>Local author ${n}</strong><span> · @fixture · now</span></div><div><p>Timeline post ${n}. Local text and nested content for repeatable scrolling.</p><div><img class="photo" src="${photo}" alt="Local generated image ${n}"></div></div></div><div aria-label="Actions"><button>Reply</button><button>Repost</button><button>Like</button><button>Share</button></div></div></article>`}feed.insertAdjacentHTML('beforeend',html);batches++}
append();
window.addEventListener('scroll',()=>{while(scrollY+innerHeight+6500>document.documentElement.scrollHeight)append()},{passive:true});
const frames=[],tasks=[];let start,last,end;
const observer=new PerformanceObserver(list=>tasks.push(...list.getEntries().map(e=>({start:e.startTime,duration:e.duration}))));
observer.observe({type:'longtask'});
function tick(t){if(start===undefined){start=last=t} else {frames.push(t-last);last=t}
 const elapsed=Math.min(t-start,10000);scrollTo(0,elapsed*19.2);
 if(t-start<10000){requestAnimationFrame(tick);return}end=t;
 setTimeout(()=>{observer.disconnect();const sorted=frames.slice().sort((a,b)=>a-b);const q=p=>sorted[Math.ceil(p*sorted.length)-1];
 fetch('/result',{method:'POST',body:JSON.stringify({p50:q(.5),p95:q(.95),longFrames:frames.filter(v=>v>50).length,longtaskMs:tasks.reduce((n,e)=>n+Math.max(0,Math.min(e.start+e.duration,end)-Math.max(e.start,start)),0),frames,cards,batches,scrollY,width:innerWidth,height:innerHeight,duration:end-start,speed:19200,longtaskSupported:PerformanceObserver.supportedEntryTypes.includes('longtask')})})},150)
}
// Stable warmup before the fixed 10-second sample. AX proof is tested afterwards.
setTimeout(()=>requestAnimationFrame(tick),1500);
</script>'''

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        data = ('''<!doctype html><meta charset="utf-8"><title>W257 CU AX fixture</title>
<h1>W257 local CU page</h1><button>W257 AX requested content</button>'''
                if self.path == '/cuax' else PAGE).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        result = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        (root / 'result.json').write_text(json.dumps(result))
        self.send_response(204)
        self.end_headers()

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
