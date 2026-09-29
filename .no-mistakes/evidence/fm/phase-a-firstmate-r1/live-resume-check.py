import os, pathlib, subprocess, json, shutil
root=pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3NQ64W15QB1PV2N0HRX29EQ')
evidence=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3NQ64W15QB1PV2N0HRX29EQ')
h=root/'.test-phase-runtime/live/resume-fresh'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX','TMUX_PANE']}
env.update(FM_GATE_REFUSE_BYPASS=os.environ['FM_GATE_REFUSE_BYPASS'],FM_HOME=str(h),FM_POLL='1',FM_CHECK_INTERVAL='999999',TMPDIR=str(root/'.test-phase-runtime/tmp'))
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(h)],check=True,env=env)
shutil.copytree(root/'bin',h/'bin')
log=(evidence/'live-resume-transcript.txt').open('w')
def run(command,args,rc):
    p=subprocess.run([str(h/'bin'/command),*args],cwd=h,env=env,text=True,capture_output=True,timeout=15)
    log.write('$ '+command+' '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr+'\n'); log.flush()
    assert p.returncode==rc,(p.returncode,p.stdout,p.stderr)
    return p
run('fm-monitoring-stop.sh',['status','--json'],0)
# A fresh receipt models explicit approval; the prior test already proved ordinary no-receipt monitoring.
r={'instruction':'Stop monitoring','time':'2026-09-29T10:00:00Z','home':str(h),'scope':'monitoring only','resume':'explicit approval required','action':'stop watcher','completed':True,'resumed_at':'2026-09-29T11:00:00Z','resume_instruction':'Explicit resumption in this isolated test home'}
path=h/'data/automatic-monitoring-pause';path.mkdir();(path/'receipt.json').write_text(json.dumps(r)+'\n')
p=run('fm-monitoring-stop.sh',['status','--json'],0);assert json.loads(p.stdout)['status']=='resumed'
run('fm-watch-checkpoint.sh',['--seconds','2'],124)
assert (h/'state/.last-watcher-beat').exists() and not (h/'state/.watch.lock').exists()
log.write('OBSERVED: resumed receipt allowed a real watcher (beacon created); quiet checkpoint expired normally and removed its lock. Prior same-home run correctly surfaced a durable rearm-resurface wake rather than timing out.\n')
log.close()
results=json.loads((evidence/'live-scenarios.json').read_text());results[-1].update(result='pass',reason='',evidence='live-monitoring-transcript.txt; live-resume-transcript.txt')
(evidence/'live-scenarios.json').write_text(json.dumps(results,indent=2))
print('PASS: explicit resumption permits real watcher startup and clean bounded shutdown.')
