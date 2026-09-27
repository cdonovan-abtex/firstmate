import os,json,pathlib,subprocess as sp,time,shlex
from PIL import Image,ImageDraw,ImageFont
ROOT=pathlib.Path.cwd();LAB=ROOT/'.monitoring-test-lab';R=LAB/'runtime';H=LAB/'pi-tui'
E=pathlib.Path('/Users/christiandonovan/.no-mistakes/evidence/01M3HVZZRWW11B70AJT0JZKZX7')
for d in ['state','data/automatic-monitoring-pause','config','agent']: (H/d).mkdir(parents=True,exist_ok=True)
p=H/'data/automatic-monitoring-pause/receipt.json'
p.write_text(json.dumps(dict(instruction='Stop the automatic monitoring',time='2026-09-21T18:42:20.023025+00:00',home=str(H),scope='Automatic monitoring only',resume='Explicit approval required',action='Stop watcher processes without relinquishing session ownership',completed=True)))
socket=ROOT/'.u.sock'
opts=dict(FM_HOME=str(H),FM_ROOT_OVERRIDE=str(R),FM_BACKEND='tmux',PI_CODING_AGENT_DIR=str(H/'agent'),TMPDIR=str(LAB/'tmp'))
cmd=['env',*[k+'='+v for k,v in opts.items()],'pi','--offline','--approve','--no-session','--no-context-files','--no-skills','--no-extensions','--no-prompt-templates','-e',str(R/'.pi/extensions/fm-primary-pi-watch.ts')]
def tmux(*args):return sp.check_output(['tmux','-S',str(socket),*args],text=True)
def capture():return tmux('capture-pane','-p','-t','pi-ui','-S','-120')
def command(c):
 tmux('send-keys','-t','pi-ui','-l',c);tmux('send-keys','-t','pi-ui','Enter')
try:
 tmux('-f','/dev/null','new-session','-d','-s','pi-ui','-x','130','-y','40','-c',str(R),shlex.join(cmd))
 time.sleep(2)
 for kind in ['active','malformed']:
  if kind=='malformed':p.write_text('{bad json\n')
  command('/fm-watch-arm-pi')
  end=time.time()+8;screen=''
  while time.time()<end:
   screen=capture()
   if ('stop evidence is malformed' if kind=='malformed' else 'automatic monitoring is stopped') in screen:break
   time.sleep(.2)
  assert ('stop evidence is malformed' if kind=='malformed' else 'automatic monitoring is stopped') in screen,screen
  (E/f'pi-terminal-{kind}.txt').write_text(screen)
  # Render the actual captured terminal cells; this is not a mocked UI.
  font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',15)
  rows=screen.rstrip().splitlines();width=max(len(x) for x in rows)
  im=Image.new('RGB',(int(font.getlength('M')*max(width,80))+40,len(rows)*21+55),'#151719');draw=ImageDraw.Draw(im)
  draw.text((20,12),'Live Pi 0.85.1 terminal capture (130 x 40 cells)',font=font,fill='#8ab4f8')
  for i,line in enumerate(rows):draw.text((20,42+i*21),line,font=font,fill='#e3e5e8')
  im.save(E/f'pi-terminal-{kind}.png')
  print(kind+': captured live refusal message in terminal grid')
finally:
 sp.run(['tmux','-S',str(socket),'kill-server'],capture_output=True)
