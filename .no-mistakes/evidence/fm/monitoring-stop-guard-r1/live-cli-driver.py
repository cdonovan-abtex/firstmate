import os, sys, json, subprocess as sp, pathlib, time, signal, tarfile, io, traceback, shutil
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.monitoring-test-lab'
E=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3HVZZRWW11B70AJT0JZKZX7')
R=LAB/'runtime'
R.mkdir(exist_ok=True)
archive=sp.check_output(['git','archive','55bb6bf790a567a0fb89a0297e167eae7cc4cba0'],cwd=ROOT)
with tarfile.open(fileobj=io.BytesIO(archive)) as t: t.extractall(R,filter='data')
sp.run(['git','-c','init.templateDir=','init','-q',str(R)],check=True)
select=os.environ.get('LIVE_ONLY','')
log=(E/'live-cli-transcript.txt').open('a' if select else 'w')
results=[r for r in json.loads((E/'live-cli-results.json').read_text()) if select not in r['name']] if select else []
processes=[]
def emit(x):
 print(x,flush=True); log.write(x+'\n'); log.flush()
def env(h,**extra):
 e=os.environ.copy()
 for k in list(e):
  if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS']: e.pop(k,None)
 e.update(FM_HOME=str(h),FM_ROOT_OVERRIDE=str(R),FM_BACKEND='tmux',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='3600',TMPDIR=str(LAB/'tmp'))
 e.update(extra);return e
def home(name):
 h=LAB/name
 if select and h.exists(): shutil.rmtree(h)
 for d in ['state','data','config','projects']: (h/d).mkdir(parents=True,exist_ok=True)
 (h/'config/backlog-backend').write_text('manual\n')
 return h
def receipt(h,kind='active'):
 p=h/'data/automatic-monitoring-pause/receipt.json';p.parent.mkdir(exist_ok=True)
 d=dict(instruction='Stop the automatic monitoring',time='2026-09-21T18:42:20.023025+00:00',home=str(h),scope='Automatic monitoring only',resume='Explicit approval required',action='Stop watcher processes without relinquishing session ownership',completed=True)
 if kind=='resumed':d.update(resumed_at='2026-09-27T18:00:00Z',resume_instruction='Resume automatic monitoring')
 p.write_text('{bad json\n' if kind=='malformed' else json.dumps(d));return p
def run(h,args,input=None,expect=None,**extra):
 cmd=[str(R/'bin'/args[0]),*args[1:]]
 r=sp.run(cmd,input=input,text=True,capture_output=True,cwd=R,env=env(h,**extra),timeout=30)
 emit('$ '+ ' '.join(args)+f' [home={h.name}]\nexit={r.returncode}\n'+r.stdout+r.stderr)
 if expect is not None: assert r.returncode==expect,(args,r.returncode,r.stdout,r.stderr)
 return r

def scenario(name,fn):
 if select and select not in name: return
 emit('\nSCENARIO: '+name)
 try: fn();results.append(dict(name=name,result='pass',live=True));emit('OBSERVED: scenario satisfied')
 except Exception as e: results.append(dict(name=name,result='fail',live=True,detail=str(e)));emit('FAIL: '+traceback.format_exc())
 (E/'live-cli-results.json').write_text(json.dumps(results,indent=2))

def stopped():
 for kind in ['active','malformed']:
  h=home('entry-'+kind);receipt(h,kind)
  before=None
  for entry in ['fm-watch.sh','fm-watch-arm.sh','fm-supervise-daemon.sh']:
   r=run(h,[entry],expect=3);assert not r.stdout and not r.stderr
   assert not (h/'state/.monitoring-stop-reports').exists()
  r=run(h,['fm-turnend-guard.sh'],input='{}',expect=0)
  assert 'AUTOMATIC_MONITORING_STOP' in r.stdout
  if kind=='active':assert '2026-09-21T18:42:20.023025+00:00' in r.stdout
  r=run(h,['fm-turnend-guard.sh'],input='{}',expect=0);assert not r.stdout
  run(h,['fm-watch-checkpoint.sh','--seconds','2'],expect=3)
  assert not (h/'state/.watch.lock').exists()
  assert not (h/'state/.last-watcher-beat').exists()
  emit('STATE: no watcher lock or beacon; background entrypoints left notice unclaimed; turn-end displayed exactly one notice')
scenario('Active and malformed stop suppress every watcher entrypoint and report once at turn end',stopped)

def malformed():
 for kind in ['partial-resume','wrong-home','impossible-time','symlink']:
  h=home(kind);p=receipt(h);d=json.loads(p.read_text())
  if kind=='partial-resume':d['resumed_at']='2026-09-27T18:00:00Z'
  if kind=='wrong-home':d['home']=str(LAB/'another-home')
  if kind=='impossible-time':d['time']='2026-02-29T18:00:00Z'
  p.write_text(json.dumps(d))
  if kind=='symlink':p.rename(p.with_suffix('.saved'));p.symlink_to(p.with_suffix('.saved').name)
  r=run(h,['fm-monitoring-stop.sh','status','--json'],expect=0);assert json.loads(r.stdout)['status']=='malformed'
  run(h,['fm-watch-arm.sh'],expect=3)
  r=run(h,['fm-turnend-guard.sh'],input='{}',expect=0);assert 'AUTOMATIC_MONITORING_STOP_INVALID' in r.stdout
  assert not (h/'state/.watch.lock').exists()
scenario('Invalid resumption, wrong-home receipts, impossible timestamps and symlinks fail closed',malformed)

def normal():
 for kind in ['absent','resumed']:
  h=home('checkpoint-'+kind)
  if kind=='resumed':receipt(h,'resumed')
  check=h/'state/operator-check.check.sh'
  check.write_text('#!/usr/bin/env bash\n[ ! -f "${FM_HOME:?}/operator-ready" ] || printf "operator verification completed\\n"\n');check.chmod(0o700)
  run(h,['fm-check-register.sh','operator-check'],expect=0)
  r=run(h,['fm-turnend-guard.sh'],input='{}',expect=2)
  assert 'TURN WOULD END BLIND' in r.stderr
  (h/'operator-ready').write_text('ready\n')
  r=run(h,['fm-watch-checkpoint.sh','--seconds','12'],expect=0,FM_CHECK_INTERVAL='1')
  assert 'operator verification completed' in r.stdout
  q=(h/'state/.wake-queue').read_text();assert 'operator verification completed' in q;emit('PERSISTED WAKE QUEUE:\n'+q)
scenario('Absent or explicitly resumed stop preserves the guard and a real registered-check wake',normal)

def parked():
 h=home('parked-mini');(h/'state/mini.meta').write_text('kind=secondmate\nstatus=idle\n')
 r=run(h,['fm-turnend-guard.sh'],input='{}',expect=0);assert not r.stdout and not r.stderr
 (h/'state/work.meta').write_text('kind=ship\n')
 r=run(h,['fm-turnend-guard.sh'],input='{}',expect=2);assert '1 task(s) in flight' in r.stderr
 receipt(h);r=run(h,['fm-turnend-guard.sh'],input='{}',expect=0);assert 'monitoring stopped' in r.stdout
 emit('OBSERVED: Mini alone allowed turn-end; one ordinary task required supervision; same work permitted after operator stop')
scenario('Parked Mini does not count as work; ordinary work still requires supervision unless stopped',parked)

def wait_file(p,seconds=15):
 end=time.time()+seconds
 while time.time()<end:
  if p.exists() and (p.name=='.last-watcher-beat' or p.read_text().strip()):return p.read_text().strip()
  time.sleep(.1)
 raise AssertionError('not created: '+str(p))
def late_stop():
 for kind in ['active','malformed']:
  h=home('running-'+kind)
  cmd=[str(R/'bin/fm-watch-arm.sh')]
  p=sp.Popen(cmd,env=env(h),cwd=R,stdout=sp.PIPE,stderr=sp.PIPE,text=True);processes.append(p)
  pid=int(wait_file(h/'state/.watch.lock/pid'))
  wait_file(h/'state/.last-watcher-beat')
  # Confirm that a second real arm attaches to the same live watcher.
  a=sp.Popen(cmd,env=env(h),cwd=R,stdout=sp.PIPE,stderr=sp.PIPE,text=True);processes.append(a)
  time.sleep(1)
  receipt(h,kind);os.kill(pid,signal.SIGTERM)
  for label,proc in [('owner',p),('attached',a)]:
   out,err=proc.communicate(timeout=15);emit(f'$ fm-watch-arm.sh ({label}, stop={kind}, watcher pid={pid})\nexit={proc.returncode}\n{out}{err}')
   assert proc.returncode==3 and 'watcher: FAILED' not in out+err
  emit('CYCLE LEDGER:\n'+(h/'state/.watch-cycle-log').read_text() if (h/'state/.watch-cycle-log').exists() else 'STATE: both real arms returned intentional-stop exit 3')
  assert not (h/'state/.monitoring-stop-reports').exists()
scenario('Stopping a running watcher retires both owning and attached arms without a repair prompt',late_stop)

def checkpoint_late():
 for ending in ['termination','timeout']:
  h=home('checkpoint-late-'+ending)
  p=sp.Popen([str(R/'bin/fm-watch-checkpoint.sh'),'--seconds','4'],env=env(h),cwd=R,text=True,stdout=sp.PIPE,stderr=sp.PIPE);processes.append(p)
  pid=int(wait_file(h/'state/.watch.lock/pid'));receipt(h)
  if ending=='termination':os.kill(pid,signal.SIGTERM)
  out,err=p.communicate(timeout=15);emit(f'$ fm-watch-checkpoint.sh --seconds 4 (stop during {ending})\nexit={p.returncode}\n{out}{err}')
  assert p.returncode==3 and 'AUTOMATIC_MONITORING_STOP' in out
  assert 'watcher: FAILED' not in out+err and 'checkpoint: no actionable wake' not in out
scenario('Stop during a Codex checkpoint exit or timeout returns deliberate-stop status',checkpoint_late)
for p in processes:
 if p.poll() is None:p.terminate();p.wait(timeout=10)
log.close()
if any(r['result']=='fail' for r in results):sys.exit(1)
