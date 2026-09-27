import os,sys,json,pathlib,subprocess as sp,queue,threading,time,shutil,shlex,traceback
ROOT=pathlib.Path.cwd();LAB=ROOT/'.monitoring-test-lab';R=LAB/'runtime';H=LAB/'dispatch-home';E=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3HVZZRWW11B70AJT0JZKZX7')
for d in ['state','data/automatic-monitoring-pause','config','agent','projects/sample']: (H/d).mkdir(parents=True,exist_ok=True)
(H/'config/backlog-backend').write_text('manual\n');project=H/'projects/sample'
(H/'data/automatic-monitoring-pause/receipt.json').write_text(json.dumps(dict(instruction='Stop automatic monitoring',time='2026-09-21T18:42:20.023025+00:00',home=str(H),scope='Automatic monitoring only',resume='Explicit approval required',action='Stop watcher processes without relinquishing session ownership',completed=True)))
auth=pathlib.Path(os.environ.get('PI_CODING_AGENT_DIR',str(pathlib.Path.home()/'.pi/agent')))/'auth.json';shutil.copyfile(auth,H/'agent/auth.json');(H/'agent/auth.json').chmod(0o600)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS']:env.pop(k,None)
env.update(FM_GATE_REFUSE_BYPASS='1',FM_HOME=str(H),FM_ROOT_OVERRIDE=str(R),FM_BACKEND='tmux',PI_CODING_AGENT_DIR=str(H/'agent'),TREEHOUSE_ROOT=str(LAB/'dispatch-pool'),SHELL='/bin/bash',HISTFILE=str(H/'shell-history'),TMPDIR=str(LAB/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live verification',GIT_AUTHOR_EMAIL='verification@example.invalid',GIT_COMMITTER_NAME='Live verification',GIT_COMMITTER_EMAIL='verification@example.invalid')
def git(*args):return sp.check_output(['git','-c','init.templateDir=','-c','commit.gpgsign=false','-C',str(project),*args],env=env,text=True).strip()
git('init','-q','-b','main');(project/'sample.txt').write_text('isolated test project\n');git('add','.');git('commit','-qm','initial')
socket=ROOT/'.d.sock'
sp.run(['tmux','-S',str(socket),'-f','/dev/null','new-session','-d','-s','dispatch-test','-x','120','-y','40','bash --noprofile --norc'],env=env,check=True)
server=sp.check_output(['tmux','-S',str(socket),'display-message','-p','#{pid}'],text=True).strip();env['TMUX']=str(socket)+','+server+',0'
sp.run(['tmux','-S',str(socket),'set-option','-g','default-shell','/bin/bash'],check=True)
sp.run(['tmux','-S',str(socket),'set-option','-g','default-command','bash --noprofile --norc'],check=True)
log=(E/'live-dispatch-transcript.jsonl').open('w');q=queue.Queue()
def emit(x):log.write(json.dumps(x)+'\n');log.flush()
cmd=['pi','--mode','rpc','--offline','--approve','--no-session','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates']
p=sp.Popen(cmd,cwd=R,env=env,stdin=sp.PIPE,stdout=sp.PIPE,stderr=sp.STDOUT,text=True,bufsize=1)
def read():
 for line in p.stdout:
  try:m=json.loads(line)
  except ValueError:m={'text':line.rstrip()}
  emit({'output':m});q.put(m)
threading.Thread(target=read,daemon=True).start();seq=0
def bash(c):
 global seq
 seq+=1;id='dispatch-'+str(seq);m=dict(id=id,type='bash',command=c);emit({'input':m});p.stdin.write(json.dumps(m)+'\n');p.stdin.flush();end=time.time()+90
 while time.time()<end:
  try:r=q.get(timeout=.3)
  except queue.Empty:continue
  if r.get('id')==id and r.get('type')=='response':assert r.get('success') and r['data']['exitCode']==0,r;return r['data']['output']
 raise AssertionError('Pi bash timed out')
try:
 out=bash('bin/fm-lock.sh');assert 'lock acquired' in out;owner=(H/'state/.lock').read_text()
 bash('bin/fm-brief.sh dispatch-check sample --scout')
 brief=H/'data/dispatch-check/brief.md';s=brief.read_text().replace('{TASK}','Verify isolated native worker dispatch while automatic monitoring is stopped.').replace('{FIRSTMATE_SPEC}','This is a disposable dispatch-only verification. No source changes or report are required; reply DISPATCH_READY and exit.');brief.write_text(s)
 launch=shlex.join(['pi','--offline','--approve','--no-session','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates','--no-tools','--print','--model','openai-codex/gpt-5.6-sol','--thinking','low','--system-prompt','Reply exactly DISPATCH_READY.','Verify worker dispatch.'])+' > '+shlex.quote(str(H/'worker-output.txt'))+' 2>&1'
 out=bash(shlex.join(['bin/fm-spawn.sh','dispatch-check',str(project),'--scout',launch]))
 assert 'WATCHER DOWN' not in out and 'TURN WOULD END BLIND' not in out
 end=time.time()+60
 while time.time()<end:
  worker=(H/'worker-output.txt').read_text() if (H/'worker-output.txt').exists() else ''
  if 'DISPATCH_READY' in worker:break
  time.sleep(.3)
 else:raise AssertionError('worker did not respond: '+worker)
 meta=(H/'state/dispatch-check.meta').read_text();assert 'kind=scout' in meta
 assert (H/'state/.lock').read_text()==owner and not (H/'state/.watch.lock/pid').exists()
 emit({'observed':'The native Pi primary dispatched a real Pi worker into a real isolated Treehouse worktree under active stop; worker responded, ownership was unchanged, and no watcher was started.','spawn_output':out,'worker_output':worker,'persisted_task_metadata':meta,'owner':owner.strip()})
 (E/'live-dispatch-result.json').write_text(json.dumps({'result':'pass','live':True},indent=2));print('PASS: native worker dispatched without watcher under operator stop')
except Exception as e:
 emit({'failure':traceback.format_exc()});print(traceback.format_exc());(E/'live-dispatch-result.json').write_text(json.dumps({'result':'fail','detail':str(e)},indent=2));sys.exitcode=1
finally:
 sp.run(['tmux','-S',str(socket),'capture-pane','-p','-t','dispatch-test','-S','-100'],stdout=(E/'dispatch-terminal.txt').open('w'),stderr=sp.DEVNULL)
 sp.run(['tmux','-S',str(socket),'kill-server'],capture_output=True);p.terminate()
 try:p.wait(timeout=10)
 except sp.TimeoutExpired:p.kill();p.wait()
 (H/'agent/auth.json').unlink(missing_ok=True);time.sleep(.1);log.close()
sys.exit(getattr(sys,'exitcode',0))
