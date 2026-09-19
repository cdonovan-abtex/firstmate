from pathlib import Path
import json,urllib.request,time,sys
lab=Path('.test-phase-lab');port=json.loads((lab/'terminal-server.json').read_text())['port']
def messages():
 files=list((lab/'calm/sessions').rglob('*.jsonl'))
 return [r.get('message',{}) for f in files for r in map(json.loads,f.read_text().splitlines())]
def send(prompt,expected):
 req=urllib.request.Request(f'http://127.0.0.1:{port}/input',data=('\x1b[200~'+prompt+'\x1b[201~\r').encode(),method='POST');urllib.request.urlopen(req).read()
 end=time.time()+60
 while time.time()<end:
  if any(m.get('role')=='assistant' and m.get('stopReason')=='stop' and any(b.get('text')==expected for b in m.get('content',[])) for m in messages()):print(expected,flush=True);return
  time.sleep(.3)
 raise TimeoutError(expected)
send('For another display check, write the following two-line note BEFORE calling bash, preserving its newline: "MULTILINE_NOTE_SENTINEL: completed the inspection.\\nThe result remains available for review." Then call bash with command printf MULTILINE_TOOL_OK. Finally reply exactly MULTILINE_DONE.','MULTILINE_DONE')
send('For a final display check, BEFORE calling bash write one substantive paragraph beginning LONG_NOTE_SENTINEL, with at least 280 characters, explaining how a supervisor can retain the completed result, its review link, the pending next action, and continued monitoring without losing ownership. Then call bash with command printf LONG_TOOL_OK. Finally reply exactly LONG_DONE.','LONG_DONE')
print('Calm live responses generated.',flush=True)
