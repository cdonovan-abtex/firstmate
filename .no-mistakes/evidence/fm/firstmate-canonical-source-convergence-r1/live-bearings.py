import os, subprocess, json, time, shutil, shlex, socket
from pathlib import Path
ROOT=Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M2HFBS0PSJJP586FSE1NY79C')
EV=Path('/Users/christiandonovan/.no-mistakes/evidence/01M2HFBS0PSJJP586FSE1NY79C')
HOME_DIR=ROOT/'.test-phase/bearings-home'
for d in ('state','data','config'): (HOME_DIR/d).mkdir(parents=True,exist_ok=True)
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_'))}
s=socket.socket(); s.bind(('127.0.0.1',0)); port=s.getsockname()[1]; s.close()
ENV.update(HOME=str(ROOT/'.test-phase/home'),TMPDIR=str(ROOT/'.test-phase/tmp'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',FM_HOME=str(HOME_DIR),FM_STATE_OVERRIDE=str(HOME_DIR/'state'),FM_CONFIG_OVERRIDE=str(HOME_DIR/'config'),FM_DATA_OVERRIDE=str(HOME_DIR/'data'),FM_PROCEVENT_CLAIM_ROOT=str(HOME_DIR/'claims'),LAVISH_AXI_STATE_DIR=str(HOME_DIR/'lavish-state'),LAVISH_AXI_PORT=str(port),LAVISH_AXI_NO_OPEN='1',PYTHONDONTWRITEBYTECODE='1')
LOG=(EV/'bearings-live.log').open('w')
RESULTS=[]
def run(args, expected=0, extra=None):
    env=ENV.copy(); env.update(extra or {})
    result=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
    LOG.write('$ '+shlex.join(list(map(str,args)))+'\n'+result.stdout+'[exit '+str(result.returncode)+']\n\n'); LOG.flush()
    if expected is not None: assert result.returncode==expected,(result.returncode,result.stdout)
    return result.stdout

def outcome(name, fn):
    try: fn(); r=dict(name=name,result='pass',live=True)
    except Exception as e: r=dict(name=name,result='fail',live=True,error=str(e))
    RESULTS.append(r); (EV/'bearings-live-results.json').write_text(json.dumps(RESULTS,indent=2)); print(json.dumps(r),flush=True)

shutil.copyfile(ROOT/'.tasks.toml',HOME_DIR/'.tasks.toml')
(HOME_DIR/'config/backlog-backend').write_text('manual\n')
(HOME_DIR/'data/secondmates.md').write_text('')
(HOME_DIR/'data/projects.md').write_text('')
(HOME_DIR/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
board=HOME_DIR/'.lavish/bearings-board.html'

def quiet():
    run([ROOT/'bin/fm-afk-launch.sh','propose'])
    run([ROOT/'bin/fm-afk-launch.sh','confirm'])
    run([ROOT/'bin/fm-afk-launch.sh','start-native'],extra={'FM_AFK_MODE':'quiet'})
    flag=(HOME_DIR/'state/.afk').read_bytes(); contract=(HOME_DIR/'state/.afk-contract').read_bytes()
    assert flag.startswith(b'quiet\n')
    data=json.loads(run([ROOT/'bin/fm-bearings-snapshot.sh','--json']))
    assert data['schema']=='fm-bearings.v1'
    assert flag==(HOME_DIR/'state/.afk').read_bytes() and contract==(HOME_DIR/'state/.afk-contract').read_bytes()
    (EV/'bearings-quiet.json').write_text(json.dumps(data,indent=2))
    run([ROOT/'bin/fm-afk-launch.sh','stop'])
    run([ROOT/'bin/fm-afk-launch.sh','propose'])
    run([ROOT/'bin/fm-afk-launch.sh','confirm'])
    run([ROOT/'bin/fm-afk-launch.sh','start-native'],extra={'FM_AFK_MODE':'away'})
    run([ROOT/'bin/fm-bearings-snapshot.sh','--json'],expected=3)
    run([ROOT/'bin/fm-afk-launch.sh','stop'])

def inventory():
    (HOME_DIR/'data/backlog.md').write_text('## In flight\n- [ ] orphan - Unowned work (repo: sample) (kind: ship)\n\n## Queued\n'+''.join(f'- [ ] queued-{i:02} - Queued work {i:02} (repo: sample) (kind: ship) (since 2026-06-{i:02})\n' for i in range(1,22))+'\n## Done\n')
    data=json.loads(run([ROOT/'bin/fm-bearings-snapshot.sh','--json']))
    assert data['gates'][0]['id']=='(main-inventory)' and len(data['gates'])==21,data['gates']
    assert data['gates'][1]['id']=='queued-21'
    (EV/'bearings-inventory.json').write_text(json.dumps(data,indent=2))
    run([ROOT/'bin/fm-bearings-snapshot.sh'])
    data=json.loads(run([ROOT/'bin/fm-bearings-snapshot.sh','--json','--all-queued']))
    assert len(data['gates'])==22 and data['gates'][0]['id']=='(main-inventory)'

def recovery():
    (HOME_DIR/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    run([ROOT/'bin/fm-afk-contract.sh','propose']); run([ROOT/'bin/fm-afk-contract.sh','confirm'])
    (HOME_DIR/'state/.watcher-down').write_text('acked:downtime:isolated-validation\n')
    (HOME_DIR/'state/.last-watcher-beat').touch()
    out=run([ROOT/'bin/fm-afk-return.sh','begin'])
    assert 'no unresolved gap in supervision at return' in out and 'no detected gap' not in out
    (EV/'return-brief.txt').write_text(out)
    # Fresh unresolved episode is the opposing health-state control.
    run([ROOT/'bin/fm-afk-contract.sh','propose']); run([ROOT/'bin/fm-afk-contract.sh','confirm'])
    (HOME_DIR/'state/.watcher-down').write_text('pending:isolated-validation-2\n')
    out=run([ROOT/'bin/fm-afk-return.sh','begin'],expected=None)
    assert 'GAP: watcher downtime was detected' in out and 'no unresolved gap' not in out
    (EV/'return-unresolved-brief.txt').write_text(out)

def render_board():
    payload=dict(schema='fm-bearings-board.v1',home='Isolated source-candidate validation',generated='2026-09-15T00:00Z',prs_live=False,captains_call=[],landed=[],underway=[dict(id='source-candidate',repo='firstmate',name='Reconcile canonical Firstmate histories',state='working',doing='Verify both input ancestries',kind='ship'),dict(id='watch-guard',repo='firstmate',name='Verify action trust during source updates',state='working',doing='Exercise tracked and modified actions',kind='ship')],charted=[dict(id='older',repo='firstmate',title='Older queued verification',reason='Awaiting a free slot',dispatchable=True,filed='2026-06-01'),dict(id='newer',repo='firstmate',title='Newest queued verification',reason='Most recently filed work',dispatchable=True,filed='2026-06-21'),dict(id='main-inventory',repo='firstmate',title='Main inventory integrity',reason='Unowned work needs metadata repair',dispatchable=False,kind='warning')])
    file=HOME_DIR/'board-payload.json'; file.write_text(json.dumps(payload))
    run([ROOT/'bin/fm-bearings-board.sh','build',file])
    shutil.copyfile(board,EV/'bearings-board.html')
    chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    out=run([chrome,'--headless','--disable-gpu','--disable-background-networking','--no-first-run','--no-default-browser-check','--user-data-dir='+str(HOME_DIR/'chrome-profile'),'--window-size=1440,1400','--virtual-time-budget=2500','--screenshot='+str(EV/'bearings-board.png'),'--dump-dom',board.as_uri()])
    (EV/'bearings-dom.html').write_text(out)
    assert 'Reconcile canonical Firstmate histories' in out and 'needs repair' in out
    assert (EV/'bearings-board.png').stat().st_size>10000

outcome('Bearings reads persisted quiet mode without exiting it and refuses genuine away mode',quiet)
outcome('Inventory repair warning survives the 20-row queue limit and newest work sorts first',inventory)
outcome('Return brief distinguishes acknowledged recovery from unresolved supervision gaps',recovery)
outcome('Fleet board renders durable work names, dated queue order, and an explicit repair warning',render_board)
if board.exists():
    run(['lavish-axi','end',board],expected=None)
    run([ROOT/'bin/fm-procevent-lavish.sh','retire',board],expected=None)
run([ROOT/'bin/fm-procevent.sh','stop'],expected=None)
run(['lavish-axi','stop'],expected=None)
LOG.close()
