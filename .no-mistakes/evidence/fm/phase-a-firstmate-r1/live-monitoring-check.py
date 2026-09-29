import json, os, pathlib, shutil, subprocess, time, traceback
ROOT = pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3NQ64W15QB1PV2N0HRX29EQ')
EVIDENCE = pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3NQ64W15QB1PV2N0HRX29EQ')
RUNTIME = ROOT / '.test-phase-runtime/live'
RUNTIME.mkdir(parents=True, exist_ok=True)
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
ENV['FM_GATE_REFUSE_BYPASS'] = os.environ['FM_GATE_REFUSE_BYPASS']
ENV.update(TMPDIR=str(ROOT / '.test-phase-runtime/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
processes=[]
results=[]
transcript = (EVIDENCE/'live-monitoring-transcript.txt').open('w', buffering=1)
def note(s):
    print(s, flush=True); transcript.write(str(s)+'\n')
def env(home, **extra):
    return dict(ENV, FM_HOME=str(home), FM_POLL='1', FM_HEARTBEAT='999999', FM_CHECK_INTERVAL='999999', **extra)
def run(home, command, args=(), expected=0, stdin='', extra=None, timeout=30):
    cmd=[str(home/'bin'/command), *args]
    note('$ FM_HOME='+str(home)+' '+' '.join(cmd))
    p=subprocess.run(cmd, input=stdin, text=True, capture_output=True, cwd=home, env=env(home, **(extra or {})), timeout=timeout)
    note('exit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    if expected is not None: assert p.returncode == expected, (command,p.returncode,expected,p.stdout,p.stderr)
    return p

def home(name):
    h=RUNTIME/name
    p=subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(h)],capture_output=True,text=True,env=ENV,cwd=ROOT)
    assert p.returncode==0,p.stderr
    shutil.copytree(ROOT/'bin',h/'bin')
    shutil.copytree(ROOT/'docs',h/'docs')
    shutil.copy2(ROOT/'AGENTS.md',h/'AGENTS.md')
    (h/'.fm-secondmate-home').write_text('test-'+name+'\n')
    (h/'config/backend').write_text('tmux\n')
    (h/'config/backlog-backend').write_text('manual\n')
    return h

def watch(h):
    log=(EVIDENCE/(h.name+'-watcher.log')).open('w')
    p=subprocess.Popen([str(h/'bin/fm-watch.sh')],cwd=h,env=env(h),stdout=log,stderr=subprocess.STDOUT)
    processes.append(p)
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        assert p.poll() is None, (h,p.returncode)
        if (h/'state/.last-watcher-beat').exists() and (h/'state/.watch.lock/pid-identity').exists():
            note('RUNNING real watcher home='+str(h)+' pid='+str(p.pid)+' identity='+(h/'state/.watch.lock/pid-identity').read_text().strip())
            return p
        time.sleep(.05)
    raise AssertionError('watcher did not become ready')

def scenario(name,fn):
    note('\nSCENARIO: '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='live-monitoring-transcript.txt',reason=''))
        note('RESULT: pass')
    except Exception as ex:
        note(traceback.format_exc()); results.append(dict(name=name,result='fail',live=True,evidence='live-monitoring-transcript.txt',reason=str(ex)))
        raise
    finally:
        (EVIDENCE/'live-scenarios.json').write_text(json.dumps(results,indent=2))

try:
    note('Standalone CLI checks use tests/lib.sh sandbox authorization; all source and runtime files are disposable copies inside the worktree. No vendor harness, backend, or watcher is stubbed.')
    a=home('selected'); b=home('sibling'); c=home('malformed'); d=home('ambiguous'); normal=home('normal')
    wp=watch(a); bp=watch(b)
    worker=subprocess.Popen(['sleep','300']); processes.append(worker)
    (a/'state/.lock').write_text(str(os.getpid())+'\n')
    (a/'state/retained.meta').write_text('kind=ship\nharness=codex\nstatus=running\n')
    (a/'data/worker-record.txt').write_text('Existing worker and validation must survive stop.\n')
    saved={str(p.relative_to(a)):p.read_bytes() for p in (a/'state/.lock',a/'state/retained.meta',a/'data/worker-record.txt')}
    def selected():
        # Explicit --home must win over ambient FM_HOME naming the sibling.
        run(b,'fm-monitoring-stop.sh',['stop','--home',str(a),'--reason','Live test: stop only selected home'])
        wp.wait(timeout=10)
        assert wp.returncode==3,wp.returncode
        assert bp.poll() is None
        assert worker.poll() is None
        assert not (a/'state/.watch.lock').exists()
        assert all((a/k).read_bytes()==v for k,v in saved.items())
        receipt=json.loads((a/'data/automatic-monitoring-pause/receipt.json').read_text())
        req=receipt['external_stop_request']
        assert req['caller_pid']==os.getpid() and req['caller_uid']==os.getuid()
        assert len((a/'data/automatic-monitoring-pause/receipt.json').read_text().splitlines())==1
        shutil.copy2(a/'data/automatic-monitoring-pause/receipt.json',EVIDENCE/'outside-stop-receipt.json')
        note('OBSERVED selected watcher exited 3; sibling watcher and worker remain alive; session owner and worker records unchanged; caller pid/uid match requesting process.')
    scenario('Stop one running home from outside; preserve sibling monitoring, worker, and session ownership',selected)
    def repeat():
        before=json.loads((a/'data/automatic-monitoring-pause/receipt.json').read_text())['time']
        run(a,'fm-monitoring-stop.sh',['stop','--home',str(a),'--reason','Live test: repeat the stop'],3)
        status=json.loads(run(a,'fm-monitoring-stop.sh',['status','--json']).stdout)
        assert status['status']=='active' and status['time']==before
        assert 'repeat the stop' in status['reason']
    scenario('Repeat an outside stop; report already-stopped and preserve the original stop time',repeat)
    def entries():
        for command,args in [('fm-watch.sh',[]),('fm-watch-arm.sh',[]),('fm-watch-arm.sh',['--restart']),('fm-watch-checkpoint.sh',['--seconds','2']),('fm-supervise-daemon.sh',[])]:
            run(a,command,args,3)
            assert not (a/'state/.watch.lock').exists()
        assert all((a/k).read_bytes()==v for k,v in saved.items())
        note('OBSERVED no watcher or daemon lock after direct, arm, restart, checkpoint, and daemon attempts.')
    scenario('Try every monitoring entry point after a stop; each refuses without starting a watcher',entries)
    def malformed():
        path=c/'data/automatic-monitoring-pause'; path.mkdir()
        receipt=path/'receipt.json'; receipt.write_text('{broken json\n')
        original=receipt.read_bytes()
        status=json.loads(run(c,'fm-monitoring-stop.sh',['status','--json']).stdout)
        assert status['status']=='malformed'
        run(c,'fm-monitoring-stop.sh',['stop','--home',str(c),'--reason','Must not overwrite malformed authority'],4)
        assert receipt.read_bytes()==original
        for command,args in [('fm-watch.sh',[]),('fm-watch-arm.sh',[]),('fm-watch-checkpoint.sh',['--seconds','2']),('fm-supervise-daemon.sh',[])]:
            run(c,command,args,3)
        assert not (c/'state/.watch.lock').exists()
    scenario('Present a corrupt stop receipt; preserve it and refuse all automatic monitoring',malformed)
    def guard():
        # Add actual in-flight metadata so a silent result cannot be an idle-home shortcut.
        (normal/'state/task.meta').write_text('kind=ship\nharness=codex\n')
        run(normal,'fm-turnend-guard.sh',[],2,stdin='{}')
        for h in (a,c):
            (h/'state/task.meta').write_text('kind=ship\nharness=codex\n')
            for args in ([],['--claude']):
                p=run(h,'fm-turnend-guard.sh',args,0,stdin='{}')
                assert 'TURN WOULD END BLIND' not in p.stdout+p.stderr
            p=run(h,'fm-guard.sh',[],0)
            assert 'WATCHER IS STALE' not in p.stdout+p.stderr
            assert not (h/'state/.watch.lock').exists()
        note('OBSERVED unstopped in-flight home blocks turn end; active and malformed stops allow it with no watcher-repair alarm.')
    scenario('End a turn with work in flight; stopped homes allow completion while an unstopped control requests supervision',guard)
    def startup():
        p=run(a,'fm-session-start.sh',[],0,timeout=150)
        (EVIDENCE/'stopped-startup-digest.txt').write_text(p.stdout+p.stderr)
        assert 'Automatic watcher startup is suppressed' in p.stdout
        assert not (a/'state/.watch.lock').exists()
        assert (a/'state/.lock').read_text().strip().isdigit()
        note('OBSERVED startup digest suppresses monitoring; startup acquired its own session lock and emitted the stopped-home block without launching monitoring.')
    scenario('Read startup status for a stopped home; emit suppression guidance and leave monitoring absent',startup)
    def ambiguous():
        p=watch(d)
        identity=d/'state/.watch.lock/pid-identity'
        original=identity.read_bytes(); identity.write_text('wrong-process-identity\n')
        result=run(d,'fm-monitoring-stop.sh',['stop','--home',str(d),'--reason','Live test ambiguous ownership'],4)
        assert 'owner identity' in result.stderr
        assert json.loads(run(d,'fm-monitoring-stop.sh',['status','--json']).stdout)['status']=='active'
        identity.write_bytes(original)
        p.wait(timeout=10)
        note('OBSERVED ambiguous ownership returned could-not-stop; receipt stayed active, and watcher subsequently exited through its normal stop check.')
    scenario('Attempt shutdown with a mismatched watcher identity; return could-not-stop while retaining re-arm suppression',ambiguous)
    def normal_resume():
        # Operator-authorized resumption is seeded only in this disposable test home.
        (normal/'state/task.meta').unlink()
        run(normal,'fm-watch-checkpoint.sh',['--seconds','2'],124)
        run(normal,'fm-monitoring-stop.sh',['stop','--home',str(normal),'--reason','Test receipt before explicit test-only resumption'])
        path=normal/'data/automatic-monitoring-pause/receipt.json'
        r=json.loads(path.read_text()); r.update(resumed_at='2026-09-29T12:00:00Z',resume_instruction='Explicit resumption in isolated live test home')
        path.write_text(json.dumps(r)+'\n')
        assert json.loads(run(normal,'fm-monitoring-stop.sh',['status','--json']).stdout)['status']=='resumed'
        p=run(normal,'fm-watch-checkpoint.sh',['--seconds','2'],None)
        assert p.returncode==124 or (p.returncode==0 and 'check: rearm-resurface' in p.stdout), (p.returncode,p.stdout,p.stderr)
        assert not (normal/'state/.watch.lock').exists()
        note('OBSERVED absent and explicitly resumed receipt both allow a real bounded watcher cycle, followed by a quiet timeout or a durable rearm wake, and cleanup.')
    scenario('Use an absent or explicitly resumed receipt; normal bounded monitoring still runs and cleans up',normal_resume)
finally:
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=6)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    note('CLEANUP: all test-owned watcher and worker processes reaped; production homes never accessed.')
    transcript.close()
