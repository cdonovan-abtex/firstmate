from pathlib import Path
import json
p=Path('/Users/christiandonovan/.no-mistakes/evidence/01M2HFBS0PSJJP586FSE1NY79C')
s=(p/'live-bearings.py').read_text().split("outcome('Bearings reads")[0]
ns={}; exec(s.replace("'bearings-live.log'","'board-retry.log'"),ns)
ns['ENV']['PATH']=str(ns['ROOT']/'.test-phase/toolbin')+':'+ns['ENV']['PATH']
ns['outcome']('Fleet board renders durable work names, dated queue order, and an explicit repair warning',ns['render_board'])
run=ns['run']; root=ns['ROOT']; board=ns['board']
run(['lavish-axi','end',board],expected=None)
run([root/'bin/fm-procevent-lavish.sh','retire',board],expected=None)
run([root/'bin/fm-procevent.sh','stop'],expected=None)
run(['lavish-axi','stop'],expected=None)
ns['LOG'].close()
