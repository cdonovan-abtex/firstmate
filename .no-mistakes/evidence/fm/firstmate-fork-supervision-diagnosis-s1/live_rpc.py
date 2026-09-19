from pathlib import Path
import subprocess, os, json, time, threading, queue, sys
ROOT=Path.cwd(); LAB=ROOT/'.test-phase-lab'; PRODUCT=LAB/'product'
EVIDENCE=Path('/Users/christiandonovan/.no-mistakes/evidence/01M2VRAW7TV0Q6AKAXNXF4Q4G5')
class Pi:
 def __init__(self,name,guard_only=False,branch=False,active_tools='fm_branch_processed'):
  self.name=name; self.home=LAB/name; self.events=[]; self.q=queue.Queue(); self.n=0
  self.env=os.environ.copy()
  for k in ['FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_MISTAKES_GATE']: self.env.pop(k,None)
  self.env.update(FM_HOME=str(self.home),FM_ROOT_OVERRIDE=str(PRODUCT),FM_STATE_OVERRIDE=str(self.home/'state'),FM_CONFIG_OVERRIDE=str(self.home/'config'),FM_DATA_OVERRIDE=str(self.home/'data'),FM_GATE_REFUSE_BYPASS='1',PI_CODING_AGENT_DIR=str(LAB/'agent'),PI_CODING_AGENT_SESSION_DIR=str(self.home/'sessions'),PI_TELEMETRY='0',TMPDIR=str(LAB/'tmp'),FM_STARTUP_NETWORK_TIMEOUT='15')
  # The normal Firstmate response contract, with validation confined to this isolated home.
  instructions=(PRODUCT/'AGENTS.md').read_text().split('## 9. Escalation and captain etiquette')[1].split('## 10.')[0]
  system='You are Firstmate. This is an isolated product validation home. Do not fix unrelated setup diagnostics. Do not contact people, merge, or access another project. '+instructions
  args=['pi','--mode','rpc','--approve','--offline','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates','--model','openai-codex/gpt-5.6-sol','--thinking','low','--tools',active_tools,'--system-prompt',system,'-e',str(PRODUCT/'.pi/extensions/fm-primary-turnend-guard.ts')]
  if not guard_only: args+=['-e',str(PRODUCT/'.pi/extensions/fm-primary-pi-watch.ts')]
  if branch: args+=['-e',str(PRODUCT/'.pi/extensions/fm-branch-supervision.ts')]
  self.p=subprocess.Popen(args,cwd=PRODUCT,env=self.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
  def consume():
   for line in self.p.stdout:
    try: row=json.loads(line)
    except: row={'raw':line}
    self.events.append(row); self.q.put(row)
  threading.Thread(target=consume,daemon=True).start()
 def request(self,kind,timeout=45,**kwargs):
  self.n+=1; identity=str(self.n)
  self.p.stdin.write(json.dumps(dict(type=kind,id=identity,**kwargs))+'\n');self.p.stdin.flush()
  deadline=time.time()+timeout
  while time.time()<deadline:
   try: row=self.q.get(timeout=min(1,max(.01,deadline-time.time())))
   except queue.Empty: continue
   if row.get('type')=='response' and row.get('id')==identity:
    if not row.get('success'): raise RuntimeError(row)
    return row.get('data')
  raise TimeoutError(kind)
 def idle(self,timeout=80):
  deadline=time.time()+timeout
  while time.time()<deadline:
   state=self.request('get_state')
   if not state.get('isStreaming'):
    time.sleep(.5)
    if not self.request('get_state').get('isStreaming'):return
   time.sleep(.3)
  raise TimeoutError('Pi did not become idle')
 def prompt(self,text):
  self.request('prompt',message=text);self.idle()
 def snapshot(self):
  state=self.home/'state'
  return {n: (state/n).read_text() if (state/n).exists() else None for n in ['.lock','.pi-watch-extension-loaded','.pi-turnend-extension-loaded','.session-start-complete','.branch-outcomes-cursor','.branch-outcomes-processed']}
 def close(self):
  self.p.terminate()
  try:self.p.wait(timeout=10)
  except subprocess.TimeoutExpired:self.p.kill();self.p.wait()
  (EVIDENCE/f'live-{self.name}-rpc.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in self.events))
  (EVIDENCE/f'live-{self.name}-stderr.log').write_text(self.p.stderr.read())
if __name__=='__main__':
 results=[]
 for name in ['absent','previous','guard-only']:
  p=Pi(name,guard_only=name=='guard-only',branch=name=='absent')
  try:
   p.request('get_state');p.prompt('Confirm readiness for this isolated validation by replying STARTUP_READY. Do not perform any other work.')
   messages=p.request('get_messages')['messages']
   startup=[m for m in messages if m.get('customType')=='firstmate-sessionstart-nudge']
   if not startup:raise AssertionError('Startup digest not delivered')
   digest=startup[0]['content'];(EVIDENCE/f'live-{name}-startup.txt').write_text(digest)
   snapshot=p.snapshot();(EVIDENCE/f'live-{name}-ownership.json').write_text(json.dumps(snapshot,indent=2))
   assert 'NEXT STEP' in digest,'Startup incomplete'
   assert ('PI_WATCH_EXTENSION: not loaded' in digest)==(name=='guard-only'),'Wrong startup extension diagnostic'
   assert snapshot['.lock'].strip()==str(p.p.pid),(snapshot,p.p.pid)
   for m in ['.pi-turnend-extension-loaded']+([] if name=='guard-only' else ['.pi-watch-extension-loaded']):assert snapshot[m].splitlines()[1]==str(p.p.pid)
   results.append(dict(scenario=name,result='pass',pid=p.p.pid))
   print(json.dumps(results[-1]),flush=True)
  except Exception as e:
   results.append(dict(scenario=name,result='fail',error=str(e)));print(json.dumps(results[-1]),flush=True)
  finally:p.close()
 (EVIDENCE/'live-startup-results.json').write_text(json.dumps(results,indent=2))
