import os,sys,json,pathlib,subprocess as sp,queue,threading,time,signal,traceback,shlex,re
ROOT=pathlib.Path.cwd();LAB=ROOT/'.monitoring-test-lab';R=LAB/'runtime';H=LAB/'pi-native-verified'
E=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3HVZZRWW11B70AJT0JZKZX7')
for d in ['state','data/automatic-monitoring-pause','config','agent','projects']: (H/d).mkdir(parents=True,exist_ok=True)
(H/'config/backlog-backend').write_text('manual\n')
receipt=H/'data/automatic-monitoring-pause/receipt.json'
d=dict(instruction='Stop the automatic monitoring',time='2026-09-21T18:42:20.023025+00:00',home=str(H),scope='Automatic monitoring only',resume='Explicit approval required',action='Stop watcher processes without relinquishing session ownership',completed=True)
receipt.write_text(json.dumps(d))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS']:env.pop(k,None)
env.update(FM_HOME=str(H),FM_ROOT_OVERRIDE=str(R),FM_BACKEND='tmux',PI_CODING_AGENT_DIR=str(H/'agent'),FM_POLL='1',FM_HEARTBEAT='3600',FM_STARTUP_NETWORK_TIMEOUT='20',TMPDIR=str(LAB/'tmp'))
cmd=['pi','--mode','rpc','--offline','--approve','--no-session','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates','-e',str(R/'.pi/extensions/fm-primary-turnend-guard.ts'),'-e',str(R/'.pi/extensions/fm-primary-pi-watch.ts')]
log=(E/'live-pi-rpc-transcript.jsonl').open('w');lines=[];q=queue.Queue()
def emit(obj):
 line=json.dumps(obj);log.write(line+'\n');log.flush();print(line,flush=True)
socket=ROOT/'.t.sock'
sp.run(['tmux','-S',str(socket),'-f','/dev/null','new-session','-d','-s','monitoring-test','-n','parked-mini','-x','120','-y','40','sleep 600'],check=True)
server_pid=sp.check_output(['tmux','-S',str(socket),'display-message','-p','#{pid}'],text=True).strip()
env['TMUX']=str(socket)+','+server_pid+',0'
meta='kind=secondmate\nharness=pi\nwindow=monitoring-test:parked-mini\nbackend=tmux\n'
(H/'state/mini.meta').write_text(meta)
p=sp.Popen(cmd,cwd=R,env=env,stdin=sp.PIPE,stdout=sp.PIPE,stderr=sp.PIPE,text=True,bufsize=1)
def read(stream,channel):
 for line in stream:
  try:data=json.loads(line)
  except ValueError:data={'text':line.rstrip()}
  lines.append(data);emit({'channel':channel,'data':data});q.put(data)
threading.Thread(target=read,args=(p.stdout,'stdout'),daemon=True).start();threading.Thread(target=read,args=(p.stderr,'stderr'),daemon=True).start()
seq=0
def rpc(typ,**args):
 global seq
 seq+=1;id='live-'+str(seq);obj=dict(id=id,type=typ,**args);emit({'channel':'stdin','data':obj});p.stdin.write(json.dumps(obj)+'\n');p.stdin.flush()
 end=time.time()+45
 while time.time()<end:
  try:m=q.get(timeout=.3)
  except queue.Empty:
   if p.poll() is not None:raise AssertionError('Pi exited '+str(p.returncode))
   continue
  if m.get('id')==id and m.get('type')=='response':
   assert m.get('success'),m
   return m
 raise AssertionError('RPC timed out: '+typ)
def wait_path(path,timeout=20):
 end=time.time()+timeout
 while time.time()<end:
  if path.exists():return path.read_text()
  time.sleep(.1)
 raise AssertionError('missing '+str(path))
def bash(command):
 r=rpc('bash',command=command);assert r['data']['exitCode']==0,r;return r['data']['output']
try:
 emit({'command':cmd,'pi_version':sp.check_output(['pi','--version'],text=True).strip()})
 commands=rpc('get_commands');assert 'fm-watch-arm-pi' in json.dumps(commands)
 # Run the unmodified startup entrypoint as a native Pi shell action, with no LLM.
 out=bash('bin/fm-session-start.sh')
 (E/'live-pi-startup-digest.txt').write_text(out)
 assert 'lock acquired: harness pid' in out and 'This session retains the fleet lock and may dispatch' in out,out
 owner=(H/'state/.lock').read_text()
 assert not (H/'state/.watch.lock/pid').exists()
 time.sleep(3)
 network=bash('bin/fm-startup-network.sh report')
 (E/'live-startup-network.txt').write_text(network)
 assert (H/'state/mini.meta').read_text()==meta
 assert sp.run(['tmux','-S',str(socket),'has-session','-t','monitoring-test:parked-mini']).returncode==0
 emit({'observed':'Startup preserved the registered parked Mini endpoint and metadata under the active stop','network_report':network})
 before=len(lines);rpc('prompt',message='/fm-watch-arm-pi');time.sleep(.5)
 assert any('watcher: not armed - automatic monitoring is stopped' in json.dumps(x) for x in lines[before:])
 out=bash("printf '{}' | bin/fm-turnend-guard.sh")
 assert 'TURN WOULD END BLIND' not in out and 'AUTOMATIC_MONITORING_STOP:' not in out
 emit({'observed':'Native Pi owns fleet lock, startup allows dispatch/merge, explicit arm is suppressed, subsequent guard remains silent','owner':owner.strip()})
 project=H/'projects/merge-sample';project.mkdir()
 genv=os.environ.copy();genv.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live verification',GIT_AUTHOR_EMAIL='verification@example.invalid',GIT_COMMITTER_NAME='Live verification',GIT_COMMITTER_EMAIL='verification@example.invalid')
 def git(*args):return sp.check_output(['git','-c','init.templateDir=','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','-C',str(project),*args],env=genv,text=True).strip()
 git('init','-q','-b','main');(project/'result.txt').write_text('before\n');git('add','.');git('commit','-qm','initial')
 git('checkout','-qb','fm/merge-check');(project/'result.txt').write_text('after\n');git('commit','-qam','verified result');target=git('rev-parse','HEAD');git('checkout','-q','main')
 (H/'state/merge-check.meta').write_text('kind=ship\nmode=local-only\nyolo=on\nproject='+str(project)+'\n')
 merged=bash('bin/fm-merge-local.sh merge-check')
 assert 'merged fm/merge-check into local main' in merged and 'WATCHER DOWN' not in merged
 assert git('rev-parse','HEAD')==target and (H/'state/.lock').read_text()==owner
 assert not (H/'state/.watch.lock/pid').exists()
 emit({'observed':'Real local-only merge completed from the native Pi owner under active stop, with no watcher or repair prompt','merge_output':merged,'landed_commit':target})

 receipt.write_text('{bad json\n')
 before=len(lines);rpc('prompt',message='/fm-watch-arm-pi');time.sleep(.5)
 assert any('stop evidence is malformed' in json.dumps(x) for x in lines[before:])
 first=bash("printf '{}' | bin/fm-turnend-guard.sh");second=bash("printf '{}' | bin/fm-turnend-guard.sh")
 assert 'AUTOMATIC_MONITORING_STOP_INVALID' in first and not second.strip()
 assert (H/'state/.lock').read_text()==owner
 emit({'observed':'Native Pi refuses malformed stop evidence; real guard emits diagnostic exactly once and keeps same session owner'})
 drained=bash('bin/fm-wake-drain.sh')
 qpath=H/'state/.wake-queue'
 if qpath.exists() and qpath.read_text().strip():
  last_seq=qpath.read_text().strip().splitlines()[-1].split('\t')[1]
  ack='bin/fm-wake-drain.sh --ack-through '+last_seq
  generation=re.search(r'--recovery-generation ([a-zA-Z0-9._:-]+)',drained)
  if generation:ack+=' --recovery-generation '+generation.group(1)
  bash(ack)
 emit({'observed':'The stopped primary could read and acknowledge the real deferred-startup outcome without arming a watcher','drain':drained})
 (H/'state/mini.meta').unlink();(H/'state/merge-check.meta').unlink()
 resumed={**d,'resumed_at':'2026-09-27T18:00:00Z','resume_instruction':'Resume automatic monitoring'};receipt.write_text(json.dumps(resumed))
 before=len(lines);rpc('prompt',message='/fm-watch-arm-pi')
 watcher=int(wait_path(H/'state/.watch.lock/pid'))
 wait_path(H/'state/.last-watcher-beat')
 time.sleep(.7)
 emit({'observed':'Explicit resume armed a real watcher through the installed Pi extension','watcher_pid':watcher})
 receipt.write_text(json.dumps(d));os.kill(watcher,signal.SIGTERM);time.sleep(2)
 assert not any('watcher: FAILED' in json.dumps(x) for x in lines[before:])
 state=rpc('get_state');assert state['data']['pendingMessageCount']==0
 assert (H/'state/.lock').read_text()==owner
 emit({'observed':'Stop plus TERM after Pi watcher readiness produced no failure or queued repair prompt and retained session ownership'})
 (E/'live-pi-result.json').write_text(json.dumps({'result':'pass','live':True,'pi_version':sp.check_output(['pi','--version'],text=True).strip(),'owner':owner.strip()},indent=2))
except Exception as e:
 emit({'failure':traceback.format_exc()});(E/'live-pi-result.json').write_text(json.dumps({'result':'fail','detail':str(e)},indent=2));sys.exitcode=1
finally:
 p.terminate()
 try:p.wait(timeout=10)
 except sp.TimeoutExpired:p.kill();p.wait()
 sp.run(['tmux','-S',str(socket),'kill-server'],capture_output=True)
 time.sleep(.1);log.close()
sys.exit(getattr(sys,'exitcode',0))
