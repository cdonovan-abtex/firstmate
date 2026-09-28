import json, os, pathlib, shutil, signal, subprocess, time, traceback

ROOT = pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3JMA89Q0VVBD9WPX6FSWWWV')
EVIDENCE = pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3JMA89Q0VVBD9WPX6FSWWWV')
LAB = ROOT / '.local-test-monitoring/live'
LAB.mkdir(parents=True, exist_ok=True)
log = (EVIDENCE / 'live-monitoring-stop.log').open('w', buffering=1)
children = []
watchers = []
results = []

def note(value):
    print(value, file=log, flush=True)
    print(value, flush=True)

def env(home):
    result = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'PI_'))}
    result.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_POLL='1', FM_HEARTBEAT='999999',
                  FM_CHECK_INTERVAL='999999', FM_WATCH_STOP_TIMEOUT='5', FM_BACKEND='tmux',
                  TMPDIR=str(ROOT / '.local-test-monitoring/tmp'), GIT_CONFIG_GLOBAL='/dev/null',
                  GIT_CONFIG_NOSYSTEM='1', FM_GATE_REFUSE_BYPASS='1')
    return result

def home(name, kind='secondmate'):
    p = LAB / name
    for d in ('state','data','config'): (p/d).mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT/'bin',p/'bin')
    shutil.copy2(ROOT/'AGENTS.md',p/'AGENTS.md')
    (p/'config/backend').write_text('tmux\n')
    if kind == 'primary': subprocess.run(['git','init','-q',str(p)],env=env(p),check=True)
    else: (p/'.fm-secondmate-home').write_text(name+'\n')
    return p

def run(p, args, expected=0, overrides=None):
    e = env(p)
    e.update(overrides or {})
    command = [str(p/'bin'/args[0]),*args[1:]]
    r = subprocess.run(command,cwd=p,env=e,text=True,capture_output=True,timeout=35)
    note('$ '+ ' '.join(command)+'\nexit='+str(r.returncode)+'\nstdout: '+r.stdout+'stderr: '+r.stderr)
    assert r.returncode == expected, (args,r.returncode,expected)
    return r

def receipt(p):
    path=p/'data/automatic-monitoring-pause/receipt.json'
    raw=path.read_text()
    assert len(raw.splitlines())==1
    data=json.loads(raw)
    assert data['external_stop_request']['caller_pid']==os.getpid()
    assert data['external_stop_request']['caller_uid']==os.getuid()
    shutil.copy2(path,EVIDENCE/(p.name+'-receipt.json'))
    note('persisted audit: '+raw.strip())
    return data

def start(p):
    out=(p/'arm.stdout').open('w'); err=(p/'arm.stderr').open('w')
    child=subprocess.Popen([str(p/'bin/fm-watch-arm.sh')],cwd=p,env=env(p),stdout=out,stderr=err)
    children.append(child)
    for _ in range(200):
        lock=p/'state/.watch.lock'
        if (lock/'pid-identity').exists() and (p/'state/.last-watcher-beat').exists():
            pid=int((lock/'pid').read_text()); watchers.append((p,pid))
            run(p,['fm-watch-arm.sh','--stop-status'])
            return child,pid
        assert child.poll() is None, (p,(p/'arm.stderr').read_text())
        time.sleep(.05)
    raise AssertionError('watcher did not become ready')

def stopped(child,p):
    assert child.wait(timeout=15)==3
    assert not (p/'state/.watch.lock').exists() and not (p/'state/.watch.lock').is_symlink()
    note('arm completion: '+(p/'arm.stdout').read_text()+'\n'+(p/'arm.stderr').read_text())
    ledger=p/'state/.watch-cycle-exits.log'
    if ledger.exists(): note('cycle ledger: '+ledger.read_text())

try:
    primary=home('primary','primary'); sibling=home('secondmate')
    arm,pid=start(primary); sibling_arm,sibling_pid=start(sibling)
    run(primary,['fm-watch-arm.sh','--stop'],expected=1)
    run(primary,['fm-watch-arm.sh','--stop-status'])
    assert not (primary/'data/automatic-monitoring-pause/receipt.json').exists()
    results.append('Owner inspection and stop without receipt leave a real watcher alive')
    run(primary,['fm-monitoring-stop.sh','stop','--home',str(primary),'--reason','purser runaway backstop'],overrides={
        'FM_HOME':str(sibling),'FM_STATE_OVERRIDE':str(sibling/'state'),'FM_DATA_OVERRIDE':str(sibling/'data')})
    stopped(arm,primary)
    first=receipt(primary)
    run(sibling,['fm-watch-arm.sh','--stop-status'])
    assert json.loads(run(sibling,['fm-monitoring-stop.sh','status','--json']).stdout)['status']=='none'
    results.append('Outside stop ends selected primary only and preserves sibling monitoring')
    time.sleep(1.1)
    run(primary,['fm-monitoring-stop.sh','stop','--home',str(primary),'--reason','later backstop request'],expected=3)
    second=receipt(primary)
    assert second['time']==first['time'] and second['external_stop_request']['at']!=first['external_stop_request']['at']
    notice=subprocess.run(['bash','-c','. "$1/bin/fm-monitoring-stop-lib.sh"; fm_monitoring_stop_report_once','_',str(primary)],env=env(primary),text=True,capture_output=True,check=True)
    note('visible notice: '+notice.stdout)
    assert first['time'] in notice.stdout and second['external_stop_request']['at'] in notice.stdout
    run(primary,['fm-watch-arm.sh'],expected=3)
    run(primary,['fm-watch-arm.sh','--restart'],expected=3)
    run(primary,['fm-watch.sh'],expected=3)
    results.append('Repeat stop is idempotent; stop and latest-request times stay distinct; rearm is suppressed')
    os.kill(sibling_pid,signal.SIGSTOP)
    run(sibling,['fm-monitoring-stop.sh','stop','--home',str(sibling),'--reason','unresponsive watcher deadline'],expected=4,overrides={'FM_WATCH_STOP_TIMEOUT':'1'})
    assert sibling_arm.poll() is None
    assert json.loads(run(sibling,['fm-monitoring-stop.sh','status','--json']).stdout)['status']=='active'
    receipt(sibling)
    retry=subprocess.Popen([str(sibling/'bin/fm-monitoring-stop.sh'),'stop','--home',str(sibling),'--reason','retry active live owner'],env=env(sibling),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    children.append(retry)
    for _ in range(100):
        if json.loads((sibling/'data/automatic-monitoring-pause/receipt.json').read_text())['external_stop_request']['reason']=='retry active live owner': break
        time.sleep(.05)
    else: raise AssertionError('retry did not publish its receipt')
    os.kill(sibling_pid,signal.SIGCONT)
    out,err=retry.communicate(timeout=15)
    note('active/live retry: exit='+str(retry.returncode)+'\nstdout: '+out+'stderr: '+err)
    assert retry.returncode==0 and out.startswith('stopped home=')
    stopped(sibling_arm,sibling)
    results.append('Suspended real watcher yields could-not-stop; active/live retry completes through receipt cleanup')
    malformed=home('malformed')
    lock=malformed/'state/.monitoring-stop-command.lock'
    lock.write_text('invalid lock\n')
    run(malformed,['fm-monitoring-stop.sh','stop','--home',str(malformed),'--reason','invalid operation lock'],expected=4)
    assert not (malformed/'data/automatic-monitoring-pause/receipt.json').exists()
    lock.unlink()
    arm_bad,pid_bad=start(malformed)
    ident=malformed/'state/.watch.lock/pid-identity'
    original=ident.read_text(); ident.write_text('forged-owner-identity\n')
    os.kill(pid_bad,signal.SIGSTOP)
    run(malformed,['fm-monitoring-stop.sh','stop','--home',str(malformed),'--reason','reject forged owner'],expected=4)
    assert arm_bad.poll() is None
    ident.write_text(original)
    os.kill(pid_bad,signal.SIGCONT)
    stopped(arm_bad,malformed)
    results.append('Malformed operation lock and forged watcher identity fail closed without signalling an owner')
    note('SCENARIOS: '+json.dumps(results,indent=2))
finally:
    for p,pid in watchers:
        lock=p/'state/.watch.lock/pid'
        if lock.exists() and lock.read_text().strip()==str(pid):
            try: os.kill(pid,signal.SIGCONT)
            except ProcessLookupError: pass
            try: run(p,['fm-monitoring-stop.sh','stop','--home',str(p),'--reason','isolated test cleanup'],expected=0)
            except Exception: pass
    for child in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
    log.close()
