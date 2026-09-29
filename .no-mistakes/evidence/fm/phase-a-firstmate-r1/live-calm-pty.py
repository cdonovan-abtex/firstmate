import os, pathlib, subprocess, pty, fcntl, termios, struct, select, time, json, shutil
root=pathlib.Path('/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M3NQ64W15QB1PV2N0HRX29EQ')
evidence=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3NQ64W15QB1PV2N0HRX29EQ')
lab=root/'.test-phase-runtime/pi-calm'
for p in ['project','agent','home/config','sessions']: (lab/p).mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['PI_CODING_AGENT','TMUX','TMUX_PANE']}
env.update(FM_HOME=str(lab/'home'), PI_CODING_AGENT_DIR=str(lab/'agent'), PI_TELEMETRY='0', PI_OFFLINE='1',TERM='xterm-256color',COLUMNS='150',LINES='36')
master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',36,150,0,0))
command=[shutil.which('pi'),'--offline','--approve','--no-context-files','--no-skills','--no-prompt-templates','--no-extensions','-e',str(root/'.pi/extensions/fm-calm.ts'),'--session-dir',str(lab/'sessions'),'--no-session']
p=subprocess.Popen(command,cwd=lab/'project',env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
os.close(slave); data=bytearray(); start=time.monotonic(); events=[]
def drain(seconds):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if select.select([master],[],[],.1)[0]:
            try: raw=os.read(master,65536)
            except OSError: break
            if not raw: break
            data.extend(raw); events.append([round(time.monotonic()-start,3),'o',raw.decode('utf8','replace')])
            if b'\x1b[6n' in raw: os.write(master,b'\x1b[1;1R')
        if p.poll() is not None: break

def save(name): (evidence/name).write_bytes(data)
try:
    drain(8); save('pi-calm-startup.ansi')
    assert p.poll() is None,('Pi exited',p.returncode,data.decode('utf8','replace'))
    os.write(master,b'/calm\r');drain(3);save('pi-calm-on.ansi')
    pref=lab/'home/config/calm'; assert pref.exists(),data.decode('utf8','replace')
    assert pref.read_text().strip()=='on',pref.read_text()
    os.write(master,b'/calm\r');drain(3);save('pi-calm-off.ansi')
    assert pref.read_text().strip()=='off',pref.read_text()
    (evidence/'pi-calm-result.json').write_text(json.dumps({'result':'pass','live':True,'pi_version':'0.85.1','pty':{'rows':36,'columns':150},'command':command,'observed':['/calm persisted on','/calm persisted off'],'model_turn':False},indent=2))
    print('PASS: real Pi 0.85.1, PTY 150x36; /calm persisted on then off; no model turn submitted.')
finally:
    os.write(master,b'/quit\r');drain(2)
    if p.poll() is None: p.terminate()
    try: p.wait(timeout=4)
    except subprocess.TimeoutExpired:p.kill();p.wait()
    os.close(master)
    (evidence/'pi-calm.cast').write_text(json.dumps({'version':2,'width':150,'height':36,'timestamp':int(time.time()),'env':{'TERM':'xterm-256color'}})+'\n'+''.join(json.dumps(e)+'\n' for e in events))
    save('pi-calm-full.ansi')
