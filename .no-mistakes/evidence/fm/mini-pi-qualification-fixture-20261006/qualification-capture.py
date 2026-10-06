import json, os, pathlib, subprocess, threading, time
root=pathlib.Path.cwd()
scratch=root/'.qualification-test-scratch'
evidence=pathlib.Path('/Users/abtex-mini/.no-mistakes/evidence/01M496VHA0F1NRTKZZJ1K1FWV6')
pkg=pathlib.Path('/Users/abtex-mini/.local/lib/node_modules/@earendil-works/pi-coding-agent')
results=[]
for label,cwd,revision in [('pre-fix',scratch/'base','69f5f9c69f01551761bba1679b11d750e0ff54cd'),('tracked-fix',root,'533361492d4e1712750ca3aef80fd0590f9b0bef')]:
    tmp=scratch/(label+'-tmp'); tmp.mkdir()
    env=os.environ.copy()
    for key in ('FM_HOME','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_ROOT_OVERRIDE','FM_CONFIG_OVERRIDE'):
        env.pop(key,None)
    env.update(TMPDIR=str(tmp),FM_PI_BRANCH_LIVE_E2E='1',FM_PI_PACKAGE_DIR=str(pkg))
    command=['bash','bin/fm-test-run.sh','tests/fm-pi-branch-live-e2e.test.sh']
    display='FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR='+str(pkg)+' TMPDIR='+str(tmp)+' '+' '.join(command)
    snapshots={}; signatures={}; done=threading.Event()
    def observe():
        while not done.is_set():
            for fixture in tmp.glob('fm-pi-branch-live.*'):
                candidates=list(fixture.glob('*-output'))+list(fixture.glob('*watch.log'))
                for name in ('home','error-home','stream-home'):
                    state=fixture/name/'state'
                    candidates.extend(state.glob('.branch-session'))
                    candidates.extend(state.glob('.wake-queue'))
                    candidates.extend((state/'branch-session').glob('**/*.jsonl'))
                for name in ('model-sessions','effort-sessions','delivery-sessions','stream-sessions'):
                    candidates.extend((fixture/name).glob('**/*.jsonl'))
                for file in candidates:
                    try:
                        stat=file.stat(); sig=(stat.st_mtime_ns,stat.st_size)
                        key=str(file.relative_to(fixture))
                        if signatures.get(key)!=sig:
                            text=file.read_text()
                            if text:
                                snapshots[key]=text; signatures[key]=sig
                    except (FileNotFoundError,OSError,UnicodeError):
                        pass
            done.wait(.01)
    observer=threading.Thread(target=observe); observer.start()
    started=time.monotonic()
    with (evidence/(label+'-real-sdk-transcript.log')).open('w') as log:
        log.write('Revision: '+revision+'\nWorking directory: '+str(cwd)+'\nCommand: '+display+'\n\n'); log.flush()
        proc=subprocess.Popen(command,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        for line in proc.stdout:
            print(label+': '+line,end='',flush=True); log.write(line); log.flush()
        exit_code=proc.wait()
        log.write('\nExit code: '+str(exit_code)+'\n')
    done.set(); observer.join()
    (evidence/(label+'-fixture-runtime.json')).write_text(json.dumps({'revision':revision,'command':display,'exit_code':exit_code,'files_observed_before_fixture_cleanup':snapshots},indent=2)+'\n')
    results.append({'label':label,'exit_code':exit_code,'seconds':round(time.monotonic()-started,2),'observed_files':list(snapshots)})
    print(json.dumps(results[-1]),flush=True)
(evidence/'qualification-execution.json').write_text(json.dumps({'node_version':subprocess.check_output(['node','--version'],text=True).strip(),'pi_sdk_version':json.loads((pkg/'package.json').read_text())['version'],'results':results},indent=2)+'\n')
