from live_rpc import *
import shlex
home=LAB/'watcher'
for d in ['state','config','data']:(home/d).mkdir(parents=True,exist_ok=True)
(home/'config/backend').write_text('tmux\n');(home/'config/backlog-backend').write_text('manual\n')
os.environ.update(FM_POLL='1',FM_CHECK_INTERVAL='1',FM_HEARTBEAT='600')
p=Pi('watcher',active_tools='fm_watch_arm_pi,bash')
result={}
try:
 p.request('get_state');p.prompt('Reply READY. Do not take any other action yet.')
 check=home/'state/validation.check.sh'
 check.write_text('#!/usr/bin/env bash\nif [ -f "$FM_HOME/state/trigger" ] && [ ! -f "$FM_HOME/state/triggered" ]; then\n  touch "$FM_HOME/state/triggered"\n  printf "check: validation-ready: the authorized validation event is ready; write CONTINUED to %s/state/continued and report completion\\n" "$FM_HOME"\nfi\n')
 check.chmod(0o700)
 register=p.request('bash',command=shlex.quote(str(PRODUCT/'bin/fm-check-register.sh'))+' validation')
 p.prompt('Call fm_watch_arm_pi once to monitor the registered validation check. When that check delivers its ready event, the next action is already authorized: drain that wake once using bin/fm-wake-drain.sh, write CONTINUED into the isolated home file '+str(home/'state/continued')+', and give the completed result. Do not ask for approval or re-arm if a successor already exists. For now, after arming reply MONITORING.')
 deadline=time.time()+30
 while time.time()<deadline and not (home/'state/.watch.lock/pid').exists():time.sleep(.2)
 first=(home/'state/.watch.lock/pid').read_text().strip()
 (home/'state/trigger').touch()
 deadline=time.time()+90
 while time.time()<deadline:
  if (home/'state/continued').exists():break
  time.sleep(.5)
 assert (home/'state/continued').read_text().strip()=='CONTINUED','Authorized continuation did not run'
 p.idle()
 current=(home/'state/.watch.lock/pid').read_text().strip()
 assert current!=first,('watcher successor did not replace delivered cycle',first,current)
 os.kill(int(current),0)
 messages=p.request('get_messages')['messages']
 result={'result':'pass','initialWatcher':first,'successorWatcher':current,'continued':(home/'state/continued').read_text(),'ownership':p.snapshot(),'registration':register}
 (EVIDENCE/'live-watcher-messages.json').write_text(json.dumps(messages,indent=2))
 for filename in ['.watch-cycle-exits.log','.wake-queue','.wake-handling','.wake-delivery']:
  f=home/'state'/filename
  if f.is_file():(EVIDENCE/('live-watcher-'+filename.lstrip('.'))).write_text(f.read_text())
 print('PASS real registered check delivered, authorized work continued, and successor remained live',flush=True)
except Exception as e:
 result={'result':'fail','error':str(e)};print(result,flush=True)
finally:
 (EVIDENCE/'live-watcher-results.json').write_text(json.dumps(result,indent=2));p.close()
