from pathlib import Path
import os,pty,fcntl,termios,struct,threading,subprocess,time,json,http.server,base64,signal
ROOT=Path.cwd();LAB=ROOT/'.test-phase-lab';WEB=LAB/'web';PRODUCT=LAB/'product';HOME_DIR=LAB/'calm'
EVIDENCE=Path('/Users/christiandonovan/.no-mistakes/evidence/01M2VRAW7TV0Q6AKAXNXF4Q4G5')
for d in ['state','config','sessions']:(HOME_DIR/d).mkdir(parents=True,exist_ok=True)
(HOME_DIR/'config/calm').write_text('on\n')
html='''<!doctype html><html><head><link rel="stylesheet" href="xterm.css"><style>html,body{margin:0;background:#000;}#terminal{padding:12px;}</style></head><body><div id="terminal"></div><script src="xterm.js"></script><script>
const term=new Terminal({cols:140,rows:48,fontSize:14,fontFamily:'Menlo, monospace',theme:{background:'#000000'},scrollback:10000});term.open(document.getElementById('terminal'));let offset=0;async function poll(){const r=await fetch('/output?offset='+offset);const j=await r.json();offset=j.offset;if(j.data){await new Promise(resolve=>term.write(Uint8Array.from(atob(j.data),c=>c.charCodeAt(0)),resolve));}window.terminalReady=true;setTimeout(poll,100);}poll();term.onData(d=>fetch('/input',{method:'POST',body:d}));</script></body></html>'''
(WEB/'index.html').write_text(html)
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
env.update(FM_HOME=str(HOME_DIR),FM_ROOT_OVERRIDE=str(PRODUCT),PI_CODING_AGENT_DIR=str(LAB/'agent'),PI_CODING_AGENT_SESSION_DIR=str(HOME_DIR/'sessions'),PI_TELEMETRY='0',TMPDIR=str(LAB/'tmp'),TERM='xterm-256color',COLORTERM='truecolor')
args=['pi','--approve','--offline','--no-context-files','--no-extensions','--no-skills','--no-prompt-templates','--model','openai-codex/gpt-5.6-sol','--thinking','low','--tools','bash','--system-prompt','You are a concise coding assistant. Follow the user instructions precisely. All shell commands are restricted to this isolated validation directory.','-e',str(PRODUCT/'.pi/extensions/fm-calm.ts')]
pid,master=pty.fork()
if pid==0:
 fcntl.ioctl(1,termios.TIOCSWINSZ,struct.pack('HHHH',48,140,0,0))
 os.chdir(HOME_DIR);os.execvpe('pi',args,env)
fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',48,140,0,0))
raw=bytearray();lock=threading.Lock()
def drain():
 while True:
  try:b=os.read(master,65536)
  except OSError:break
  if not b:break
  with lock:raw.extend(b)
threading.Thread(target=drain,daemon=True).start()
class Handler(http.server.SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(WEB),**kw)
 def log_message(self,*a):pass
 def do_GET(self):
  if self.path.startswith('/output'):
   offset=int(self.path.split('offset=')[-1])
   with lock:data=bytes(raw[offset:]);end=len(raw)
   body=json.dumps({'offset':end,'data':base64.b64encode(data).decode()}).encode()
   self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
  else:super().do_GET()
 def do_POST(self):
  content=self.rfile.read(int(self.headers.get('Content-Length',0)))
  if self.path=='/input':os.write(master,content)
  elif self.path.startswith('/capture'):
   with lock:(EVIDENCE/self.path.split('/')[-1]).write_bytes(bytes(raw))
  self.send_response(200);self.end_headers();self.wfile.write(b'OK')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(LAB/'terminal-server.json').write_text(json.dumps({'port':server.server_port,'pid':pid,'server_pid':os.getpid(),'cols':140,'rows':48}))
print(json.dumps({'port':server.server_port,'pid':pid,'cols':140,'rows':48}),flush=True)
try:server.serve_forever()
finally:
 os.kill(pid,signal.SIGTERM);os.waitpid(pid,0);os.close(master)
