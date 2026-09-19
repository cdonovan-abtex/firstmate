from live_rpc import *
import shlex
p=Pi('absent',branch=True)
p.name='continuation'
results=[]
try:
 p.request('get_state');p.prompt('Reply READY for the next validation event. No other work is needed yet.')
 before=p.snapshot()
 # The public RPC bash command runs a real second Pi CLI below the canonical Pi.
 child_code='''import os,subprocess,time,json,threading
p=subprocess.Popen(%r,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
threading.Thread(target=lambda:list(p.stdout),daemon=True).start()
p.stdin.write('{"type":"get_state","id":"child"}\\n');p.stdin.flush()
time.sleep(5)
p.terminate();p.wait(timeout=10)
print('DESCENDANT_PI_PID='+str(p.pid))
''' % ['pi','--mode','rpc','--approve','--offline','--no-context-files','--no-skills','--no-extensions','--no-tools','-e',str(PRODUCT/'.pi/extensions/fm-primary-turnend-guard.ts'),'-e',str(PRODUCT/'.pi/extensions/fm-primary-pi-watch.ts')]
 childfile=LAB/'descendant.py';childfile.write_text(child_code)
 descendant=p.request('bash',command='python3 '+shlex.quote(str(childfile)),timeout=30)
 after=p.snapshot()
 assert all(before[m]==after[m] for m in ['.lock','.pi-watch-extension-loaded','.pi-turnend-extension-loaded']), (before,after)
 results.append({'scenario':'real descendant Pi launch preserves canonical markers','result':'pass','before':before,'after':after,'descendant':descendant})
 print('PASS real descendant preserves canonical markers',flush=True)
 # Actual store command queues one requested result for the real extension.
 summary='The requested assembly-supervision repair is complete and ready for review. Review URL: https://example.invalid/reviews/assembly-supervision-validation . Local validation passed. Review is the next step; no merge has been authorized.'
 r=subprocess.run([str(PRODUCT/'bin/fm-branch-outcome.sh'),'append','--task','validation-assembly','--verdict','captain','--summary',summary,'--wake','done: requested assembly repair ready for review'],env=p.env,text=True,capture_output=True,check=True)
 seq=int(r.stdout.strip())
 p.prompt('Continue with any pending authorized outcomes.')
 p.idle();time.sleep(1)
 messages=p.request('get_messages')['messages']
 text='\n'.join(b.get('text','') for m in messages if m.get('role')=='assistant' for b in m.get('content',[]) if b.get('type')=='text')
 processed=p.snapshot()['.branch-outcomes-processed']
 assert processed and int(processed.strip())==seq, ('outcome was not acknowledged',processed,text)
 assert 'https://example.invalid/reviews/assembly-supervision-validation' in text, text
 assistant=[m for m in messages if m.get('role')=='assistant' and m.get('stopReason')=='stop'][-1]
 final='\n'.join(b.get('text','') for b in assistant['content'] if b.get('type')=='text')
 assert 'https://example.invalid/reviews/assembly-supervision-validation' in final and final.strip()!='Captain, shipshape.',final
 requests=[m for m in messages if m.get('customType')=='fm-branch-process' and 'outcome-processing request' in str(m)]
 assert requests,'No generated processing request reached Pi'
 results.append({'scenario':'requested outcome produces substantive final reply and sequence acknowledgement','result':'pass','seq':seq,'final':final,'processed':processed})
 print('PASS substantive outcome final and acknowledgement',flush=True)
 (EVIDENCE/'live-outcome-messages.json').write_text(json.dumps(messages,indent=2))
 p.request('export_html',outputPath=str(EVIDENCE/'live-outcome-session.html'))
 # Session replacement is a real Pi RPC command, preserving the canonical PID.
 p.request('new_session');p.prompt('Reply REPLACEMENT_READY. No other work is needed.')
 replacement=p.snapshot()
 assert replacement['.lock']==after['.lock']
 assert all(replacement[m]==after[m] for m in ['.pi-watch-extension-loaded','.pi-turnend-extension-loaded'])
 results.append({'scenario':'same-process new session retains canonical ownership','result':'pass','ownership':replacement})
 print('PASS same-process new session ownership',flush=True)
except Exception as e:
 results.append({'scenario':'continuation live validation','result':'fail','error':str(e)})
 print(str(e),flush=True)
finally:
 (EVIDENCE/'live-continuation-results.json').write_text(json.dumps(results,indent=2));p.close()
