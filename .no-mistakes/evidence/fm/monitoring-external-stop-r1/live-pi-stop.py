import json, os, pathlib, queue, shutil, subprocess, threading, time

ROOT=pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3JMA89Q0VVBD9WPX6FSWWWV')
EVIDENCE=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3JMA89Q0VVBD9WPX6FSWWWV')
LAB=ROOT/'.local-test-monitoring'
home=LAB/'pi-primary-final'
for d in ('state','data','config','pi-config'): (home/d).mkdir(parents=True,exist_ok=True)
shutil.copytree(ROOT/'bin',home/'bin')
shutil.copytree(ROOT/'.pi/extensions',home/'.pi/extensions')
shutil.copy2(ROOT/'AGENTS.md',home/'AGENTS.md')
(home/'config/backend').write_text('tmux\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','PI_','TASKS_AXI_'))}
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_POLL='1',FM_HEARTBEAT='999999',
    FM_CHECK_INTERVAL='999999',FM_GATE_REFUSE_BYPASS='1',FM_SESSION_START_TIMEOUT='40',
    FM_BACKEND='tmux',PI_CODING_AGENT_DIR=str(home/'pi-config'),PI_OFFLINE='1',
    TMPDIR=str(LAB/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
subprocess.run(['git','init','-q',str(home)],env=env,check=True)
log=(EVIDENCE/'live-pi-stop.jsonl').open('w',buffering=1)
events=queue.Queue(); all_events=[]
args=['pi','--offline','--mode','rpc','--no-session','--no-context-files','--no-skills',
    '--no-prompt-templates','--no-themes','--no-extensions','--approve',
    '-e','.pi/extensions/fm-primary-pi-watch.ts','-e','.pi/extensions/fm-primary-turnend-guard.ts']
err=(EVIDENCE/'live-pi-stop.stderr').open('w')
pi=subprocess.Popen(args,cwd=home,env=env,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err)

def drain():
    for line in pi.stdout:
        log.write(line)
        try:
            event=json.loads(line); events.put(event); all_events.append(event)
        except json.JSONDecodeError: pass
threading.Thread(target=drain,daemon=True).start()
counter=0
def rpc(kind,**kwargs):
    global counter
    counter+=1; ident='probe-'+str(counter)
    request=dict(id=ident,type=kind,**kwargs)
    log.write(json.dumps({'sent':request})+'\n')
    pi.stdin.write(json.dumps(request)+'\n'); pi.stdin.flush()
    deadline=time.monotonic()+55
    while time.monotonic()<deadline:
        try: response=events.get(timeout=.5)
        except queue.Empty:
            assert pi.poll() is None, 'Pi exited before RPC response'
            continue
        if response.get('id')==ident and response.get('type')=='response':
            assert response.get('success'), response
            return response
    raise AssertionError('RPC timeout: '+kind)

def stop(reason):
    r=subprocess.run([str(home/'bin/fm-monitoring-stop.sh'),'stop','--home',str(home),'--reason',reason],
        env=env,text=True,capture_output=True,timeout=35)
    log.write(json.dumps({'external_stop':reason,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
    assert r.returncode in (0,3),r.stderr

try:
    commands=rpc('get_commands')
    assert any(c['name']=='fm-watch-arm-pi' for c in commands['data']['commands'])
    started=rpc('bash',command='bin/fm-session-start.sh')
    (EVIDENCE/'live-pi-session-start-enabled.txt').write_text(started['data']['output'])
    assert started['data']['exitCode']==0,started
    assert (home/'state/.lock').read_text().strip()==str(pi.pid)
    for marker in ('.pi-watch-extension-loaded','.pi-turnend-extension-loaded'):
        assert (home/'state'/marker).read_text().splitlines()[1]==str(pi.pid)
    rpc('prompt',message='/fm-watch-arm-pi')
    for _ in range(250):
        if (home/'state/.watch.lock/pid-identity').exists() and (home/'state/.last-watcher-beat').exists(): break
        time.sleep(.1)
    else: raise AssertionError('Pi extension did not arm a real watcher')
    lock_before=(home/'state/.lock').read_text()
    stop('purser backstop while Pi owns monitoring')
    for _ in range(120):
        if not (home/'state/.watch.lock').exists() and not (home/'state/.watch.lock').is_symlink(): break
        time.sleep(.1)
    else: raise AssertionError('Pi watcher remained alive')
    rpc('prompt',message='/fm-watch-arm-pi')
    time.sleep(2)
    notices=[e for e in all_events if e.get('type')=='extension_ui_request' and 'not armed - automatic monitoring is stopped' in e.get('message','')]
    assert notices,all_events[-15:]
    (home/'state/pending-worker.meta').write_text('kind=ship\nstatus=working\n')
    guard=rpc('bash',command="printf '%s' '{\"stop_hook_active\":false}' | bin/fm-turnend-guard.sh")
    assert guard['data']['exitCode']==0,guard
    (EVIDENCE/'live-pi-turnend-guard.txt').write_text(guard['data']['output'])
    assert 'AUTOMATIC_MONITORING_STOP' in guard['data']['output'],guard
    assert 'TURN WOULD END BLIND' not in guard['data']['output']
    broad=rpc('bash',command="bin/fm-arm-pretool-check.sh --command \"pkill -f '/bin/fm-watch.sh'\"")
    assert broad['data']['exitCode']==2,broad
    assert 'broad-watcher-kill' in broad['data']['output'],broad
    supported=rpc('bash',command="bin/fm-arm-pretool-check.sh --command \"bin/fm-monitoring-stop.sh stop --home '$FM_HOME' --reason backstop\"")
    assert supported['data']['exitCode']==0,supported
    (home/'state/pending-worker.meta').unlink()
    started=rpc('bash',command='bin/fm-session-start.sh')
    (EVIDENCE/'live-pi-session-start-stopped.txt').write_text(started['data']['output'])
    assert started['data']['exitCode']==0,started
    assert 'Automatic watcher startup is suppressed by the home monitoring-stop record.' in started['data']['output'],started
    assert 'AUTOMATIC_MONITORING_STOP:' not in started['data']['output'], 'one-time notice repeated after turn-end delivery'
    assert 'TURN WOULD END BLIND' not in started['data']['output']
    rpc('new_session')
    rpc('prompt',message='/fm-watch-arm-pi')
    time.sleep(2)
    assert (home/'state/.lock').read_text()==lock_before
    assert not (home/'state/.watch.lock').exists()
    log.write(json.dumps({'result':'pass','pi_pid':pi.pid,'session_lock_preserved':True,
        'real_extensions_loaded':True,'enabled_watcher_started':True,'external_stop_suppressed_rearm':True,
        'turnend_guard_exit':guard['data']['exitCode'],'replacement_session_stayed_stopped':True})+'\n')
    print('Live Pi: real extension armed watcher, external stop ended it, rearm/new session stayed stopped, turn-end and startup honored the receipt.')
finally:
    try: stop('isolated Pi test cleanup')
    except Exception as ex: print('cleanup stop:',ex)
    pi.terminate()
    try: pi.wait(timeout=15)
    except subprocess.TimeoutExpired: pi.kill(); pi.wait()
    err.close(); log.close()
