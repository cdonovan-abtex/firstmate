import os,sys,json,pathlib,subprocess as sp,queue,threading,time,signal,shutil,traceback
ROOT=pathlib.Path.cwd();LAB=ROOT/'.monitoring-test-lab';R=LAB/'runtime';H=LAB/'pi-turnend-verified'
E=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3HVZZRWW11B70AJT0JZKZX7')
for d in ['state','data/automatic-monitoring-pause','config','agent']: (H/d).mkdir(parents=True,exist_ok=True)
(H/'config/backlog-backend').write_text('manual\n')
auth=pathlib.Path(os.environ.get('PI_CODING_AGENT_DIR',str(pathlib.Path.home()/'.pi/agent')))/'auth.json'
shutil.copyfile(auth,H/'agent/auth.json');(H/'agent/auth.json').chmod(0o600)
receipt=H/'data/automatic-monitoring-pause/receipt.json'
d=dict(instruction='Stop automatic monitoring',time='2026-09-21T18:42:20.023025+00:00',home=str(H),scope='Automatic monitoring only',resume='Explicit approval required',action='Stop watcher processes without relinquishing session ownership',completed=True)
receipt.write_text(json.dumps(d))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS']:env.pop(k,None)
env.update(FM_GATE_REFUSE_BYPASS='1',FM_HOME=str(H),FM_ROOT_OVERRIDE=str(R),FM_BACKEND='tmux',PI_CODING_AGENT_DIR=str(H/'agent'),FM_POLL='1',FM_HEARTBEAT='3600',FM_STARTUP_NETWORK_TIMEOUT='20',TMPDIR=str(LAB/'tmp'))
cmd=['pi','--mode','rpc','--offline','--approve','--no-session','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates','--no-tools','--model','openai-codex/gpt-5.6-sol','--thinking','low','--system-prompt','You are participating in an isolated runtime verification. Reply READY to each input. Never call tools. Diagnostics are contextual.','-e',str(R/'.pi/extensions/fm-primary-turnend-guard.ts'),'-e',str(R/'.pi/extensions/fm-primary-pi-watch.ts')]
log=(E/'live-pi-turnend.jsonl').open('w');messages=[];q=queue.Queue();lock=threading.Lock()
def emit(x):
 with lock:log.write(json.dumps(x)+'\n');log.flush()
p=sp.Popen(cmd,cwd=R,env=env,stdin=sp.PIPE,stdout=sp.PIPE,stderr=sp.PIPE,text=True,bufsize=1)
def reader(f,channel):
 for s in f:
  try:m=json.loads(s)
  except ValueError:m={'text':s.rstrip()}
  messages.append(m);emit({'channel':channel,'data':m});q.put(m)
threading.Thread(target=reader,args=(p.stdout,'stdout'),daemon=True).start();threading.Thread(target=reader,args=(p.stderr,'stderr'),daemon=True).start()
seq=0
def rpc(typ,**args):
 global seq
 seq+=1;id='turnend-'+str(seq);m=dict(id=id,type=typ,**args);emit({'channel':'stdin','data':m});p.stdin.write(json.dumps(m)+'\n');p.stdin.flush()
 end=time.time()+60
 while time.time()<end:
  try:r=q.get(timeout=.3)
  except queue.Empty:
   if p.poll() is not None:raise AssertionError('Pi exited')
   continue
  if r.get('id')==id and r.get('type')=='response':assert r.get('success'),r;return r
 raise AssertionError('RPC timed out '+typ)
def turn(label):
 start=len(messages);rpc('prompt',message=label+' Reply READY.')
 end=time.time()+90
 while time.time()<end:
  if any(m.get('type')=='agent_end' for m in messages[start:]):
   time.sleep(.8)
   state=rpc('get_state')['data']
   if not state['isStreaming'] and not state['pendingMessageCount']:break
  time.sleep(.25)
 else:raise AssertionError('model turn did not settle')
 recent=messages[start:]
 errors=[m for m in recent if m.get('type')=='extension_error' or m.get('type')=='message_end' and m.get('message',{}).get('stopReason')=='error']
 assert not errors,errors
 return recent
try:
 rpc('get_state')
 first=turn('Initial stopped session')
 assert (H/'state/.lock').exists() and not (H/'state/.watch.lock/pid').exists()
 owner=(H/'state/.lock').read_text()
 receipt.write_text('{bad json\n')
 turn('Malformed stop evidence')
 msgs=rpc('get_messages')['data']['messages']
 notices=[m for m in msgs if m.get('customType')=='firstmate-monitoring-stop' and 'AUTOMATIC_MONITORING_STOP_INVALID' in str(m.get('content'))]
 assert len(notices)==1,notices
 turn('Repeated malformed stop evidence')
 msgs=rpc('get_messages')['data']['messages'];notices=[m for m in msgs if m.get('customType')=='firstmate-monitoring-stop' and 'AUTOMATIC_MONITORING_STOP_INVALID' in str(m.get('content'))]
 assert len(notices)==1
 assert not any(m.get('role')=='user' and 'TURN WOULD END BLIND' in str(m.get('content')) for m in msgs)
 assert (H/'state/.lock').read_text()==owner and not (H/'state/.watch.lock/pid').exists()
 emit({'observed':'Real Pi model turns reached agent_settled; malformed stop produced one displayed custom diagnostic over repeated turns, no repair user prompt, no watcher, and the same session owner'})
 # Counterfactual: resumed monitoring with registered work and no arm still demands ordinary supervision.
 receipt.write_text(json.dumps({**d,'resumed_at':'2026-09-27T18:00:00Z','resume_instruction':'Resume automatic monitoring'}))
 check=H/'state/turnend-check.check.sh';check.write_text('#!/usr/bin/env bash\nexit 0\n');check.chmod(0o700)
 r=sp.run([str(R/'bin/fm-check-register.sh'),'turnend-check'],env=env,text=True,capture_output=True);assert r.returncode==0,r.stderr
 turn('Normal supervision required')
 msgs=rpc('get_messages')['data']['messages']
 repairs=[m for m in msgs if m.get('role')=='user' and 'TURN WOULD END BLIND' in str(m.get('content'))]
 assert len(repairs)==1,repairs
 emit({'observed':'With explicit resume and registered work, real Pi turn-end delivered exactly one ordinary missing-supervision repair prompt','delivered_repair':repairs[0]})
 (E/'live-pi-turnend-result.json').write_text(json.dumps({'result':'pass','live':True,'malformed_notice_count':len(notices),'normal_repair_count':len(repairs)},indent=2))
 print('PASS: real Pi model turns preserved stopped and normal native turn-end behavior')
except Exception as e:
 emit({'failure':traceback.format_exc()});(E/'live-pi-turnend-result.json').write_text(json.dumps({'result':'fail','detail':str(e)},indent=2));print(traceback.format_exc());sys.exitcode=1
finally:
 p.terminate()
 try:p.wait(timeout=10)
 except sp.TimeoutExpired:p.kill();p.wait()
 (H/'agent/auth.json').unlink(missing_ok=True)
 time.sleep(.1);log.close()
sys.exit(getattr(sys,'exitcode',0))
