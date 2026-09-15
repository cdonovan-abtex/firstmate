import os, subprocess, json, time
from pathlib import Path
root=Path("/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M2HFBS0PSJJP586FSE1NY79C")
evidence=Path("/Users/christiandonovan/.no-mistakes/evidence/01M2HFBS0PSJJP586FSE1NY79C")
env={k:v for k,v in os.environ.items() if not k.startswith(("FM_", "TASKS_AXI_", "GIT_"))}
env.update(TMPDIR=str(root/".test-phase/tmp"), HOME=str(root/".test-phase/home"), XDG_CONFIG_HOME=str(root/".test-phase/home/config"), XDG_CACHE_HOME=str(root/".test-phase/home/cache"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", PYTHONDONTWRITEBYTECODE="1")
suites=["fm-agent-context", "fm-procevent-when", "fm-afk-return", "fm-bearings-snapshot", "fm-brief", "fm-quiet-entry", "fm-claude-stop-autoarm", "fm-spawn-dispatch-profile", "fm-pr-check-security", "fm-teardown-endpoint-safety"]
results=[]
for suite in suites:
    cmd=["/bin/bash", "tests/"+suite+".test.sh"]
    start=time.monotonic()
    with (evidence/(suite+".log")).open("w") as log:
        try:
            rc=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600).returncode
        except subprocess.TimeoutExpired:
            rc=124
    data=(evidence/(suite+".log")).read_text()
    result=dict(command=cmd,exit=rc,seconds=round(time.monotonic()-start,1),skips=[l for l in data.splitlines() if "skip:" in l])
    results.append(result)
    (evidence/"targeted-tests.json").write_text(json.dumps(results,indent=2))
    print(json.dumps(result),flush=True)
    if rc: print(data[-3500:],flush=True)
