import datetime, json, os, pathlib, shutil, subprocess, time
root=pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3JMA89Q0VVBD9WPX6FSWWWV')
evidence=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3JMA89Q0VVBD9WPX6FSWWWV')
home=root/'.local-test-monitoring/normal-final'
for d in ('state','data','config'): (home/d).mkdir(parents=True,exist_ok=True)
shutil.copytree(root/'bin',home/'bin'); shutil.copy2(root/'AGENTS.md',home/'AGENTS.md')
(home/'config/backend').write_text('tmux\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','PI_','TASKS_AXI_'))}
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_POLL='1',FM_SIGNAL_GRACE='0',
    FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_BACKEND='tmux',
    FM_GATE_REFUSE_BYPASS='1',TMPDIR=str(root/'.local-test-monitoring/tmp'),
    GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
subprocess.run(['git','init','-q',str(home)],env=env,check=True)
log=(evidence/'live-normal-supervision.log').open('w',buffering=1)
def run(args):
    r=subprocess.run([str(home/'bin'/args[0]),*args[1:]],env=env,cwd=home,text=True,capture_output=True,timeout=35)
    log.write('$ '+' '.join(args)+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr)
    return r
(home/'state/live-work.meta').write_text('kind=ship\nstatus=working\n')
arm=subprocess.Popen([str(home/'bin/fm-watch-arm.sh')],env=env,cwd=home,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
    for _ in range(200):
        if (home/'state/.watch.lock/pid-identity').exists() and (home/'state/.last-watcher-beat').exists(): break
        assert arm.poll() is None
        time.sleep(.05)
    else: raise AssertionError('normal watcher never started')
    assert json.loads(run(['fm-monitoring-stop.sh','status','--json']).stdout)['status']=='none'
    (home/'state/live-work.status').write_text('done: normal supervision remains active\n')
    log.write('Worker published: done: normal supervision remains active\n')
    out,err=arm.communicate(timeout=20)
    log.write('arm exit='+str(arm.returncode)+'\n'+out+err)
    assert arm.returncode==0 and ('signal:' in out or 'check: inactive-outcome' in out),out+err
    drain=run(['fm-wake-drain.sh'])
    assert drain.returncode==0 and 'done: normal supervision remains active' in drain.stdout,drain.stdout
    assert run(['fm-monitoring-stop.sh','stop','--home',str(home),'--reason','stop after normal delivery']).returncode==0
    path=home/'data/automatic-monitoring-pause/receipt.json'
    previous=json.loads(path.read_text())
    previous['resumed_at']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    previous['resume_instruction']='Resume isolated test monitoring'
    path.write_text(json.dumps(previous)+'\n')
    assert json.loads(run(['fm-monitoring-stop.sh','status','--json']).stdout)['status']=='resumed'
    assert run(['fm-monitoring-stop.sh','stop','--home',str(home),'--reason','new stop after authorized resumption']).returncode==0
    current=json.loads(path.read_text())
    assert current['previous_stop']=={'time':previous['time'],'resumed_at':previous['resumed_at']}
    log.write('new receipt after resumption: '+path.read_text())
    assert json.loads(run(['fm-monitoring-stop.sh','status','--json']).stdout)['status']=='active'
    print('Normal real watcher delivered a worker status; stopping a resumed home retained prior stop history.')
finally:
    if arm.poll() is None:
        run(['fm-monitoring-stop.sh','stop','--home',str(home),'--reason','normal-test cleanup'])
        try: arm.wait(timeout=10)
        except subprocess.TimeoutExpired: arm.terminate(); arm.wait(timeout=10)
    log.close()
