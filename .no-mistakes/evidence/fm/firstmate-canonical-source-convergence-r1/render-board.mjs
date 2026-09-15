import {spawn} from 'node:child_process';
import {writeFile,readFile,mkdir} from 'node:fs/promises';
const root='/Users/christiandonovan/.no-mistakes/worktrees/d9c4fb60435f/01M2HFBS0PSJJP586FSE1NY79C';
const ev='/Users/christiandonovan/.no-mistakes/evidence/01M2HFBS0PSJJP586FSE1NY79C';
const profile=root+'/.test-phase/chrome-cdp-'+Date.now();
await mkdir(profile,{recursive:true});
const chrome=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless','--disable-gpu','--disable-extensions','--disable-background-networking','--no-first-run','--no-default-browser-check','--no-proxy-server','--password-store=basic','--use-mock-keychain','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{env:{...process.env,HOME:root+'/.test-phase/home',TMPDIR:root+'/.test-phase/tmp'},stdio:['ignore','ignore','pipe']});
let diagnostics='';chrome.stderr.on('data',d=>diagnostics+=d);
let ws;
const timeout=setTimeout(()=>{chrome.kill('SIGTERM');process.exitCode=1;},60000);
try {
  let port;
  for(let i=0;i<100;i++){try{port=(await readFile(profile+'/DevToolsActivePort','utf8')).split('\n')[0];break;}catch{} await new Promise(r=>setTimeout(r,100));}
  if(!port) throw Error('No DevTools port: '+diagnostics);
  const page=await (await fetch('http://127.0.0.1:'+port+'/json/new?about:blank',{method:'PUT'})).json();
  ws=new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
  let id=0;const pending=new Map();
  ws.onmessage=e=>{const data=JSON.parse(e.data);if(data.id){let p=pending.get(data.id);pending.delete(data.id);data.error?p.reject(Error(JSON.stringify(data.error))):p.resolve(data.result);}};
  function send(method,params={}){const key=++id;return new Promise((resolve,reject)=>{pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));});}
  await send('Page.enable');await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1400,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate',{url:'file://'+ev+'/bearings-board.html'});
  await new Promise(r=>setTimeout(r,2500));
  const text=await send('Runtime.evaluate',{expression:'document.body.innerText',returnByValue:true});
  await writeFile(ev+'/board-visible-text.txt',text.result.value);
  const png=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});
  await writeFile(ev+'/bearings-board.png',Buffer.from(png.data,'base64'));
  console.log(text.result.value);
  const size=await send('Runtime.evaluate',{expression:'JSON.stringify({width:innerWidth,scroll:document.documentElement.scrollWidth})',returnByValue:true});
  console.log('layout',size.result.value);
  if(!text.result.value.includes('Reconcile canonical Firstmate histories') || !text.result.value.toLowerCase().includes('needs repair')) throw Error('Expected visible board rows were absent');
  if(text.result.value.indexOf('Newest queued verification')>text.result.value.indexOf('Older queued verification')) throw Error('Dated queue order incorrect');
  await send('Browser.close');
  console.log('Board rendered and captured successfully');
} finally {clearTimeout(timeout);if(ws)ws.close();chrome.kill('SIGTERM');await writeFile(ev+'/chrome-diagnostics.log',diagnostics);}
