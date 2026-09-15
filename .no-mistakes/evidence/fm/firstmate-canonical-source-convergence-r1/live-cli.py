import os, subprocess, json, time, shutil, hashlib, shlex
from pathlib import Path
ROOT=Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M2HFBS0PSJJP586FSE1NY79C')
EV=Path('/Users/christiandonovan/.no-mistakes/evidence/01M2HFBS0PSJJP586FSE1NY79C')
TMP=ROOT/'.test-phase/live'
TMP.mkdir(exist_ok=True)
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_'))}
ENV.update(HOME=str(ROOT/'.test-phase/home'),TMPDIR=str(ROOT/'.test-phase/tmp'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Isolated validation',GIT_COMMITTER_NAME='Isolated validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_EMAIL='test@example.invalid',PYTHONDONTWRITEBYTECODE='1')
LOG=(EV/'live-cli.log').open('w')
RESULTS=[]
def run(args, cwd=ROOT, env=None, expected=0):
    args=list(map(str,args)); merged=ENV.copy(); merged.update(env or {})
    result=subprocess.run(args,cwd=cwd,env=merged,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
    LOG.write('$ '+shlex.join(args)+'\n'+result.stdout+'[exit '+str(result.returncode)+']\n\n'); LOG.flush()
    if expected is not None: assert result.returncode==expected, (args,result.returncode,result.stdout)
    return result

def scenario(name, fn):
    try:
        fn(); result={'name':name,'result':'pass','live':True}
    except Exception as e:
        result={'name':name,'result':'fail','live':True,'error':str(e)}
    RESULTS.append(result); (EV/'live-cli-results.json').write_text(json.dumps(RESULTS,indent=2)); print(json.dumps(result),flush=True)

def init(repo):
    repo.mkdir(parents=True,exist_ok=True)
    run(['git','init','-q','-b','candidate-test'],cwd=repo)

def commit(repo, msg):
    run(['git','add','.'],cwd=repo); run(['git','commit','-qm',msg],cwd=repo)
    return run(['git','rev-parse','HEAD'],cwd=repo).stdout.strip()

def history():
    repo=TMP/'history'; init(repo)
    target='c6c1c64f11188a1190db75522545ff2478ae1b88'
    fork='c781bb13857b76210faf2ff8288b9a0bcaedc4ef'
    upstream='a6618ddc690b4e613b62c6c4a3f6df4808a778b1'
    run(['git','fetch','--quiet',str(ROOT),target],cwd=repo)
    for label, ancestor in [('fork',fork),('upstream',upstream)]:
        run(['git','merge-base','--is-ancestor',ancestor,target],cwd=repo)
        run(['git','checkout','-q','-b',label,ancestor],cwd=repo)
        run(['git','merge','--ff-only',target],cwd=repo)
        assert run(['git','rev-parse','HEAD'],cwd=repo).stdout.strip()==target
    run(['git','log','-1','--format=%H %P %s','357aeabd9b22dd47d02ee4804f59b3382c1b2475'],cwd=repo)
    LOG.write('Both isolated lineage branches advanced by fast-forward to the exact candidate.\n\n'); LOG.flush()

def emitter():
    repo=TMP/'emitter'; init(repo)
    (repo/'AGENTS.md').write_text('# Operator prose\n\nKeep this paragraph intact.\n')
    (repo/'package.json').write_text('{"scripts":{"start":"node server.js"}}\n')
    commit(repo,'sample project')
    run(['git','remote','add','origin','https://synthetic:credential@example.invalid/org/sample.git'],cwd=repo)
    cli=ROOT/'bin/fm-agent-context.py'
    run([cli,'emit','--repo',repo]); run([cli,'check','--repo',repo])
    before=(repo/'AGENTS.md').read_bytes()
    assert before.startswith(b'# Operator prose\n\nKeep this paragraph intact.\n') and b'synthetic:credential' not in before and b'<redacted>' in before
    run([cli,'emit','--repo',repo]); assert before==(repo/'AGENTS.md').read_bytes()
    (repo/'package.json').write_text('{"scripts":{"start":"node changed.js"}}\n')
    run([cli,'check','--repo',repo],expected=1); assert before==(repo/'AGENTS.md').read_bytes()
    run([cli,'emit','--repo',repo]); run([cli,'check','--repo',repo])
    shutil.copyfile(repo/'AGENTS.md',EV/'emitted-agent-context.md')
    (repo/'AGENTS.md').write_text('# Preserve malformed input\n<!-- AGENT-CONTEXT:BEGIN -->\nunclosed\n')
    before=(repo/'AGENTS.md').read_bytes()
    run([cli,'emit','--repo',repo],expected=1); assert before==(repo/'AGENTS.md').read_bytes()
    LOG.write('Prose, repeat identity and refusal bytes verified; check detected drift without writing.\n\n'); LOG.flush()

ACTIVE=[]
def watches():
    seed=TMP/'watch-source'; init(seed)
    shutil.copytree(ROOT/'bin',seed/'bin')
    (seed/'.gitignore').write_text('state/\ndata/\nconfig/\n')
    action=seed/'bin/validation-action.sh'; action.write_text('#!/bin/sh\nprintf "v1\\n" >> "$1"\nprintf "ran v1\\n"\n'); action.chmod(0o755)
    commit(seed,'old tracked executable')
    home=TMP/'watch-home'; run(['git','clone','-q',seed,home])
    for sub in ('state','data','config'): (home/sub).mkdir()
    env={'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_PROCEVENT_CLAIM_ROOT':str(TMP/'watch-claims')}
    ACTIVE.append((home,env))
    when=home/'bin/fm-procevent-when.sh'; pe=home/'bin/fm-procevent.sh'
    for name, act in [('tracked',home/'bin/validation-action.sh'),('untracked',home/'data/untracked-action.sh'),('symlink',home/'bin/linked-action.sh')]:
        if name=='untracked': act.write_text('#!/bin/sh\nprintf "untracked-v1\\n" >> "$1"\n'); act.chmod(0o755)
        if name=='symlink': act.symlink_to('validation-action.sh')
        run([when,'arm',name,'--interval','0.1','--stable','1','--condition','/bin/test','-f',home/'state/trigger','--action',act,home/('state/'+name+'.executed')],env=env)
    # The symbolic link is deliberately untracked and excluded to keep the update clean.
    run(['git','config','--local','core.excludesFile',str(home/'state/excludes')],cwd=home)
    (home/'state/excludes').write_text('bin/linked-action.sh\n')
    action.write_text('#!/bin/sh\nprintf "v2\\n" >> "$1"\nprintf "ran v2\\n"\n')
    tip=commit(seed,'new tracked executable')
    run(['git','fetch','-q','origin'],cwd=home)
    untracked=home/'data/untracked-action.sh'; untracked.write_text('#!/bin/sh\nprintf "MUTATED\\n" >> "$1"\n')
    run([when,'fast-forward',tip],env=env)
    (home/'state/trigger').touch()
    run([pe,'reconcile'],env=env)
    deadline=time.monotonic()+30
    while time.monotonic()<deadline and len(list((home/'state/procevent-inbox').glob('*.result')))<3: time.sleep(.15)
    results={}
    for name in ('tracked','untracked','symlink'):
        files=list((home/'state/procevent-inbox').glob('when-'+name+'.*.result')); assert len(files)==1,(name,files)
        f=files[0]; shutil.copyfile(f,EV/('watch-'+name+'.result'))
        results[name]=run([pe,'classify',f],env=env).stdout.strip()
        LOG.write(f.read_text()+'\n')
        run([pe,'handled','when-'+name,'1'],env=env)
    assert results=={'tracked':'fired','untracked':'rejected','symlink':'rejected'},results
    run([pe,'reconcile'],env=env)
    assert (home/'state/tracked.executed').read_text()=='v2\n'
    assert not (home/'state/untracked.executed').exists() and not (home/'state/symlink.executed').exists()
    shutil.copyfile(home/'state/.wake-queue',EV/'watch-wake-queue.tsv')
    for name in results: run([when,'retire',name],env=env)

scenario('Both Git lineages fast-forward to the reconciliation candidate',history)
scenario('Context emission preserves prose, redacts credentials, and refuses malformed input',emitter)
scenario('Updating tracked actions rebinds watches while modified untracked and linked actions refuse',watches)
for home,env in ACTIVE:
    run([home/'bin/fm-procevent.sh','stop'],env=env,expected=None)
LOG.close()
