'use strict';
const express=require('express'),http=require('http'),https=require('https'),tls=require('tls'),path=require('path'),fs=require('fs'),os=require('os'),crypto=require('crypto');
const {spawn}=require('child_process');
const app=express();
const PORT=Number(process.env.PORT||3000),HEALTH_PORT=Number(process.env.HEALTH_PORT||3001),MIKROTIK_HOST=process.env.MIKROTIK_HOST||'10.0.0.1',MIKROTIK_PORT=Number(process.env.MIKROTIK_PORT||8729),MIKROTIK_USER=process.env.MIKROTIK_USER,MIKROTIK_PASSWORD=process.env.MIKROTIK_PASSWORD;
const TLS_REJECT_UNAUTHORIZED=process.env.MIKROTIK_TLS_REJECT_UNAUTHORIZED!=='false',API_TIMEOUT=15000,INACTIVITY_SECONDS=60;
if(!MIKROTIK_USER||!MIKROTIK_PASSWORD){console.error('Missing MIKROTIK_USER or MIKROTIK_PASSWORD environment variable.');process.exit(1);}
if(!Number.isInteger(PORT)||PORT<1||PORT>65535||!Number.isInteger(HEALTH_PORT)||HEALTH_PORT<1||HEALTH_PORT>65535||HEALTH_PORT===PORT||!Number.isInteger(MIKROTIK_PORT)||MIKROTIK_PORT<1||MIKROTIK_PORT>65535){console.error('Invalid PORT, HEALTH_PORT, or MIKROTIK_PORT.');process.exit(1);}
const KEY_FILE=process.env.HTTPS_KEY||(fs.existsSync(path.join(__dirname,'key.pem'))?path.join(__dirname,'key.pem'):path.join(__dirname,'server.key'));
const CERT_FILE=process.env.HTTPS_CERT||(fs.existsSync(path.join(__dirname,'cert.pem'))?path.join(__dirname,'cert.pem'):path.join(__dirname,'server.cert'));
const options={key:fs.readFileSync(KEY_FILE),cert:fs.readFileSync(CERT_FILE)};
app.use(express.json({limit:'16kb'}));
// Allow account.html served by the MikroTik Hotspot to read transaction status.
// The update endpoints still require RouterOS credentials from the Voucher Manager.
app.use((req,res,next)=>{
 res.setHeader('Access-Control-Allow-Origin','*');
 res.setHeader('Access-Control-Allow-Methods','GET,POST,OPTIONS');
 res.setHeader('Access-Control-Allow-Headers','Content-Type');
 res.setHeader('Cache-Control','no-store, max-age=0');
 if(req.method==='OPTIONS')return res.sendStatus(204);
 next();
});
// Keep the server alive while any page or API endpoint is actively used.
// resetTimeout() is a function declaration below and is available here.
app.use((req,res,next)=>{ if(req.path!=='/quit') resetTimeout(); next(); });
// public/index.html loads html5-qrcode from /node_modules/...; expose the installed package.
app.use('/node_modules',express.static(path.join(__dirname,'node_modules'),{etag:false,maxAge:0}));
app.use(express.static(path.join(__dirname,'public'),{etag:false,lastModified:false,maxAge:0}));

// Global health is shared, but transaction records are isolated by an unguessable ID.
// latestTransactionByUsername is only a backward-compatibility index for older clients.
const transactionStatus = new Map();
const latestTransactionByUsername = new Map();
const TRANSACTION_TTL_MS = 30 * 60 * 1000;
function cleanTransactionRecords(now = Date.now()) {
 for (const [id, value] of transactionStatus) {
  if (now - value.updatedAt > TRANSACTION_TTL_MS) {
   transactionStatus.delete(id);
   if (latestTransactionByUsername.get(value.username) === id) latestTransactionByUsername.delete(value.username);
  }
 }
}
function recordTransaction(username, status, details = {}, requestedTransactionId = null) {
 const now = Date.now();
 cleanTransactionRecords(now);
 const safeId = typeof requestedTransactionId === 'string' && /^[a-f0-9-]{16,80}$/i.test(requestedTransactionId)
  ? requestedTransactionId : crypto.randomUUID();
 const previous = transactionStatus.get(safeId);
 const record = { ...details, transactionId:safeId, username, status,
  createdAt:previous?.createdAt || now, updatedAt:now };
 transactionStatus.set(safeId, record);
 latestTransactionByUsername.set(username, safeId);
 return record;
}

const SCRIPT3_SOURCE=String.raw`
:local usersList "["
:foreach user in=[/ip hotspot user find] do={
 :local username [/ip hotspot user get $user name]
 :local comment [/ip hotspot user get $user comment]
 :if ([:len $comment] > 0) do={
  :set usersList ($usersList . "{ \"username\": \"$username\", \"validity\": \"$comment\" },")
 }
}
:if ([:len $usersList] > 1) do={
 :set usersList ([:pick $usersList 0 ([:len $usersList] - 1)] . "]")
} else={ :set usersList "[]" }
/file set hotspot/hotspot-validity.json contents=$usersList
`;

const EXPIRATION_SCRIPT_SOURCE=String.raw`
:local date [/system clock get date]
:local time [/system clock get time]
:local cy [:tonum [:pick $date 0 4]]
:local cm [:tonum [:pick $date 5 7]]
:local cd [:tonum [:pick $date 8 10]]
:local ch [:tonum [:pick $time 0 2]]
:local cmin [:tonum [:pick $time 3 5]]
:local curtime (($ch * 60) + $cmin)
:local today (($cy * 10000) + ($cm * 100) + $cd)
:local months {"jan"=1;"feb"=2;"mar"=3;"apr"=4;"may"=5;"jun"=6;"jul"=7;"aug"=8;"sep"=9;"oct"=10;"nov"=11;"dec"=12}
:log info ("EXPIRATION CHECK: " . $date . " " . $time)
:foreach i in=[/ip hotspot user find where profile="General"] do={
 :local name [/ip hotspot user get $i name]
 :local comment [/ip hotspot user get $i comment]
 :local c [:pick $comment 0 [:len $comment]]
 :local expiry 0
 :local exptime 0
 :local valid false
 :if ([:len $c] >= 19) do={
  :local mon [:pick $c 0 3]
  :local emonthNum ($months->$mon)
  :if ([:typeof $emonthNum] = "num") do={
   :local eday [:tonum [:pick $c 4 6]]
   :local eyear [:tonum [:pick $c 7 11]]
   :local ehour [:tonum [:pick $c 12 14]]
   :local emin [:tonum [:pick $c 15 17]]
   :if (($eday >= 1) && ($eday <= 31) && ($eyear >= 2000) && ($ehour <= 23) && ($emin <= 59)) do={
    :set expiry (($eyear * 10000) + ($emonthNum * 100) + $eday)
    :set exptime (($ehour * 60) + $emin)
    :set valid true
   }
  }
 }
 :if (([:len $c] >= 19) && ($valid = false)) do={
  :local dash1 [:pick $c 4 5]
  :local dash2 [:pick $c 7 8]
  :local sep [:pick $c 10 11]
  :if (($dash1 = "-") && ($dash2 = "-") && ($sep = " ")) do={
   :local y [:tonum [:pick $c 0 4]]
   :local m [:tonum [:pick $c 5 7]]
   :local d [:tonum [:pick $c 8 10]]
   :local h [:tonum [:pick $c 11 13]]
   :local n [:tonum [:pick $c 14 16]]
   :if (($y >= 2000) && ($m >= 1) && ($m <= 12) && ($d >= 1) && ($d <= 31) && ($h <= 23) && ($n <= 59)) do={
    :set expiry (($y * 10000) + ($m * 100) + $d)
    :set exptime (($h * 60) + $n)
    :set valid true
   }
  }
 }
 :if ($valid = true) do={
  :log info ("USER=" . $name . " TODAY=" . $today . " EXPIRY=" . $expiry . " CURTIME=" . $curtime . " EXPTIME=" . $exptime)
  :if (($expiry < $today) || (($expiry = $today) && ($exptime <= $curtime))) do={
   :log warning ("EXPIRED: " . $name . " | " . $comment)
   /ip hotspot active remove [find where user=$name]
   /ip hotspot user remove $i
  }
 } else={ :log warning ("SKIPPED - INVALID OR EMPTY EXPIRY: " . $name . " | " . $comment) }
}
`;

function encodeLength(n){if(n<0x80)return Buffer.from([n]);if(n<0x4000)return Buffer.from([(n>>8)|0x80,n&255]);if(n<0x200000)return Buffer.from([(n>>16)|0xc0,(n>>8)&255,n&255]);if(n<0x10000000)return Buffer.from([(n>>24)|0xe0,(n>>16)&255,(n>>8)&255,n&255]);if(n<=0xffffffff)return Buffer.from([0xf0,(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255]);throw Error('RouterOS API word too large.');}
function decodeLength(b,o){if(o>=b.length)return null;const f=b[o];let bytes,length;if(!(f&128))return{length:f,bytes:1};if((f&192)===128){bytes=2;if(b.length<o+bytes)return null;length=((f&63)<<8)|b[o+1];}else if((f&224)===192){bytes=3;if(b.length<o+bytes)return null;length=((f&31)<<16)|(b[o+1]<<8)|b[o+2];}else if((f&240)===224){bytes=4;if(b.length<o+bytes)return null;length=((f&15)<<24)|(b[o+1]<<16)|(b[o+2]<<8)|b[o+3];}else if(f===240){bytes=5;if(b.length<o+bytes)return null;length=b.readUInt32BE(o+1);}else throw Error('Invalid RouterOS API length prefix.');return{length,bytes};}
function encodeSentence(words){const a=[];for(const w of words){const b=Buffer.from(String(w),'utf8');a.push(encodeLength(b.length),b);}a.push(Buffer.from([0]));return Buffer.concat(a);}
class RouterOSApi{
 constructor(){this.socket=null;this.buffer=Buffer.alloc(0);this.pending=new Map();this.nextTag=1;this.closed=false;}
 connect(){return new Promise((resolve,reject)=>{let settled=false;const tlsOptions={host:MIKROTIK_HOST,port:MIKROTIK_PORT,rejectUnauthorized:TLS_REJECT_UNAUTHORIZED,minVersion:'TLSv1.2'};if(!require('net').isIP(MIKROTIK_HOST))tlsOptions.servername=MIKROTIK_HOST;const s=tls.connect(tlsOptions);this.socket=s;const timer=setTimeout(()=>{if(!settled){settled=true;s.destroy();reject(Error('RouterOS TLS/login connection timed out.'));}},API_TIMEOUT);s.once('secureConnect',async()=>{if(settled)return;try{await this.command('/login',[`=name=${MIKROTIK_USER}`,`=password=${MIKROTIK_PASSWORD}`]);settled=true;clearTimeout(timer);resolve();}catch(e){settled=true;clearTimeout(timer);s.destroy();reject(e);}});s.on('data',c=>{this.buffer=Buffer.concat([this.buffer,c]);try{this.processBuffer();}catch(e){this.failAll(e);s.destroy();}});s.on('error',e=>{if(!settled){settled=true;clearTimeout(timer);reject(e);}this.failAll(e);});s.on('close',()=>{this.closed=true;this.failAll(Error('RouterOS connection closed.'));});});}
 processBuffer(){while(this.buffer.length){let o=0;const words=[];while(true){const d=decodeLength(this.buffer,o);if(!d)return;o+=d.bytes;if(!d.length)break;if(this.buffer.length<o+d.length)return;words.push(this.buffer.subarray(o,o+d.length).toString('utf8'));o+=d.length;}this.buffer=this.buffer.subarray(o);this.handleSentence(words);}}
 handleSentence(words){if(!words.length)return;const type=words[0],fields={};let tag=null;for(const w of words.slice(1)){if(w.startsWith('.tag=')){tag=w.slice(5);continue;}if(w.startsWith('=')){const i=w.indexOf('=',1);if(i!==-1)fields[w.slice(1,i)]=w.slice(i+1);}}if(type==='!fatal'){this.failAll(Error(fields.message||'RouterOS fatal API error.'));return;}if(!tag||!this.pending.has(tag))return;const r=this.pending.get(tag);if(type==='!re'){r.rows.push(fields);return;}if(type==='!trap'){const e=Error(fields.message||'RouterOS rejected API command.');e.category=fields.category;this.pending.delete(tag);clearTimeout(r.timer);r.reject(e);return;}if(type==='!done'){this.pending.delete(tag);clearTimeout(r.timer);r.resolve(r.rows);}}
 command(command,args=[]){if(!this.socket||this.socket.destroyed||this.closed)return Promise.reject(Error('RouterOS API is not connected.'));const tag=String(this.nextTag++);return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(tag);reject(Error(`RouterOS API command timed out: ${command}`));},API_TIMEOUT);this.pending.set(tag,{resolve,reject,timer,rows:[]});try{this.socket.write(encodeSentence([command,...args,`.tag=${tag}`]));}catch(e){this.pending.delete(tag);clearTimeout(timer);reject(e);}});}
 failAll(e){for(const [tag,r] of this.pending){clearTimeout(r.timer);r.reject(e);this.pending.delete(tag);}}
 close(){this.closed=true;if(this.socket&&!this.socket.destroyed)this.socket.end();}
}
async function withRouterOS(fn){const api=new RouterOSApi();try{await api.connect();return await fn(api);}finally{api.close();}}

async function ensureRouterOSScripts(api){
 const rows=await api.command('/system/script/print',['=.proplist=.id,name']);
 const get=n=>rows.find(x=>x.name===n);
 if(!get('script3'))await api.command('/system/script/add',['=name=script3','=policy=read,write,policy,test',`=source=${SCRIPT3_SOURCE}`]);
 const expName='hotspot-expiration-check',exp=get(expName);
 if(exp)await api.command('/system/script/set',[`=.id=${exp['.id']}`,`=source=${EXPIRATION_SCRIPT_SOURCE}`,'=policy=read,write,policy,test']);
 else await api.command('/system/script/add',[`=name=${expName}`,'=policy=read,write,policy,test',`=source=${EXPIRATION_SCRIPT_SOURCE}`]);
 const ss=await api.command('/system/scheduler/print',['=.proplist=.id,name']);
 const sch=ss.find(x=>x.name==='hotspot-expiration-5m');
 const args=['=interval=5m','=start-time=startup','=on-event=/system script run hotspot-expiration-check','=policy=read,write,policy,test'];
 if(sch)await api.command('/system/scheduler/set',[`=.id=${sch['.id']}`,...args]);
 else await api.command('/system/scheduler/add',['=name=hotspot-expiration-5m',...args]);
}

const MONTHS=['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'];
function parseDuration(input){if(typeof input!=='string'||input.length>100)throw Error('Invalid validity.');const text=input.trim();if(!text)throw Error('Validity is required.');const re=/(\d+)\s*([dhms])/gy,used=new Set();let p=0,total=0;while(p<text.length){while(text[p]===' ')p++;if(p>=text.length)break;re.lastIndex=p;const m=re.exec(text);if(!m)throw Error('Invalid validity. Examples: 1d, 12h, 7d 12h.');const v=Number(m[1]),u=m[2];if(!Number.isSafeInteger(v)||v<0)throw Error('Invalid validity value.');if(used.has(u))throw Error(`Duplicate validity unit: ${u}.`);used.add(u);total+=v*({d:86400,h:3600,m:60,s:1})[u];if(!Number.isSafeInteger(total))throw Error('Validity is too large.');p=re.lastIndex;}if(total<=0)throw Error('Validity must be greater than zero.');if(total>10*365*86400)throw Error('Validity cannot exceed 10 years.');return total;}
function parseExpiration(v){if(typeof v!=='string'||!v.trim())return null;const t=v.trim(),m=t.match(/^([a-zA-Z]{3})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})$/);if(m){const mo=MONTHS.indexOf(m[1].toLowerCase()),d=+m[2],y=+m[3],h=+m[4],mi=+m[5],s=+m[6];if(mo<0||d<1||d>31||h>23||mi>59||s>59)return null;const date=new Date(y,mo,d,h,mi,s);if(date.getFullYear()!==y||date.getMonth()!==mo||date.getDate()!==d)return null;return date;}const date=new Date(t);return Number.isNaN(date.getTime())?null:date;}
function formatExpiration(d){return `${MONTHS[d.getMonth()]}/${String(d.getDate()).padStart(2,'0')}/${d.getFullYear()} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;}
function calculateExpiration(comment,secs){const now=new Date(),old=parseExpiration(comment),base=old&&old>now?old:now;return formatExpiration(new Date(base.getTime()+secs*1000));}
function validateCredentials(u,p){if(typeof u!=='string'||u.length<1||u.length>64||/[\x00-\x1f\x7f]/.test(u))throw Error('Invalid username.');if(typeof p!=='string'||p.length<1||p.length>64||/[\x00-\x1f\x7f]/.test(p))throw Error('Invalid password.');}

app.post('/voucher-info',async(req,res)=>{
 const {username,password,validity,transactionId}=req.body||{};
 try{
  validateCredentials(username,password);
  const selectedSeconds=parseDuration(validity);
  const result=await withRouterOS(async api=>{
   const users=await api.command('/ip/hotspot/user/print',[`?name=${username}`,'=.proplist=.id,name,comment,profile']);
   const user=users.find(u=>u.name===username)||null;
   const serverNow=new Date();
   const current=parseExpiration(user?.comment||'');
   const remainingSeconds=current?Math.max(0,Math.floor((current.getTime()-serverNow.getTime())/1000)):0;
   const base=current&&current>serverNow?current:serverNow;
   const next=new Date(base.getTime()+selectedSeconds*1000);
   return{success:true,exists:!!user,serverNow:serverNow.toISOString(),remainingSeconds,currentExpiration:user?.comment||null,currentExpirationTimestamp:current?current.getTime():null,selectedSeconds,newExpiration:formatExpiration(next),newExpirationTimestamp:next.getTime(),base:current&&current>serverNow?'existing-expiry':'now'};
  });
  recordTransaction(username,'detected',{
   validity:validity.trim(), selectedSeconds,
   previousExpiration:result.currentExpiration,
   expiration:result.newExpiration,
   message:'QR/account recognized. Waiting for validity confirmation.'
  }, transactionId);
  return res.json(result);
 }catch(e){console.error('Voucher info failed:',e.message);return res.status(400).json({success:false,error:e.message});}
});

app.post('/update-validity',async(req,res)=>{
 const {username,password,validity,transactionId}=req.body||{};
 let selectedSeconds=0;
 try{
  validateCredentials(username,password);
  selectedSeconds=parseDuration(validity);
  recordTransaction(username,'processing',{
   validity:validity.trim(), selectedSeconds,
   message:'Validity update is being processed.'
  }, transactionId);
  const result=await withRouterOS(async api=>{
   await ensureRouterOSScripts(api);
   const users=await api.command('/ip/hotspot/user/print',[`?name=${username}`,'=.proplist=.id,name,comment']);
   const old=users.find(u=>u.name===username);
   const previousExpiration=old?.comment||null;
   let expiration;
   if(!old){
    expiration=calculateExpiration(null,selectedSeconds);
    await api.command('/ip/hotspot/user/add',[`=name=${username}`,`=password=${password}`,`=comment=${expiration}`,'=profile=General']);
    await api.command('/system/script/run',['=number=script3']);
   }else{
    if(!old['.id'])throw Error('RouterOS did not return the existing user ID.');
    expiration=calculateExpiration(old.comment||'',selectedSeconds);
    await api.command('/ip/hotspot/user/set',[`=.id=${old['.id']}`,`=comment=${expiration}`]);
    await api.command('/system/script/run',['=number=script3']);
   }
   return {previousExpiration,expiration};
  });
  const parsedNewExpiration=parseExpiration(result.expiration);
  const totalValiditySeconds=parsedNewExpiration?Math.max(0,Math.floor((parsedNewExpiration.getTime()-Date.now())/1000)):0;
  const completed=recordTransaction(username,'success',{
   validity:validity.trim(), selectedSeconds, totalValiditySeconds,
   previousExpiration:result.previousExpiration,
   expiration:result.expiration,
   message:'Validity updated successfully.'
  }, transactionId);
  return res.json({success:true,message:completed.message,expiration:result.expiration,previousExpiration:result.previousExpiration,selectedSeconds,totalValiditySeconds,transactionId:completed.transactionId});
 }catch(e){
  console.error('Update validity failed:',e.message);
  if(typeof username==='string'&&username.length>0&&username.length<=64){
   recordTransaction(username,'failed',{
    validity:typeof validity==='string'?validity.trim():'', selectedSeconds,
    message:e.message||'Validity update failed.'
   }, transactionId);
  }
  return res.status(500).json({success:false,error:e.message});
 }
});

// Health endpoint used by account.html to hide QR when Termux is offline.
app.get('/health',(req,res)=>{
 resetTimeout();
 return res.json({success:true,status:'online'});
});

// account.html polls this endpoint to show the scan/processing/success status.
app.get('/transaction-status',(req,res)=>{
 resetTimeout();
 const requestedId=req.query.transactionId;
 const username=req.query.username;
 const since=Number(req.query.since||0);
 let record=null;
 if(typeof requestedId==='string' && /^[a-f0-9-]{16,80}$/i.test(requestedId)) {
  // Exact-ID lookup prevents another browser tab/user's transaction from appearing here.
  record=transactionStatus.get(requestedId)||null;
 } else {
  // Compatibility for older Voucher Manager clients; new clients should always send transactionId.
  if(typeof username!=='string'||username.length<1||username.length>64||/[\x00-\x1f\x7f]/.test(username)){
   return res.status(400).json({success:false,error:'Provide a valid transactionId or username.'});
  }
  const latestId=latestTransactionByUsername.get(username);
  record=latestId?transactionStatus.get(latestId)||null:null;
 }
 if(!record||!Number.isFinite(since)||record.createdAt<since) return res.json({success:true,found:false});
 if(typeof requestedId==='string' && record.transactionId!==requestedId) return res.json({success:true,found:false});
 if(typeof username==='string' && record.username!==username) return res.json({success:true,found:false});
 return res.json({success:true,found:true,transaction:{
  transactionId:record.transactionId,username:record.username,status:record.status,
  validity:record.validity||'',selectedSeconds:record.selectedSeconds||0,
  totalValiditySeconds:record.totalValiditySeconds||0,
  previousExpiration:record.previousExpiration||null,expiration:record.expiration||null,
  message:record.message||'',createdAt:record.createdAt,updatedAt:record.updatedAt
 }});
});

let inactivityTimer=null;
function resetTimeout(){clearTimeout(inactivityTimer);inactivityTimer=setTimeout(()=>{console.log('done');console.log('No traffic detected');server.close(()=>process.exit(0));},INACTIVITY_SECONDS*1000);}
app.get('/qrcode',(req,res)=>{resetTimeout();res.sendFile(path.join(__dirname,'public','index.html'));});
app.get('/quit',(req,res)=>{clearTimeout(inactivityTimer);console.log('done');console.log('user exit');res.status(200).send('Server shutting down.');server.close(()=>process.exit(0));});
function getLanIPv4Addresses(){
 const out=[];
 for(const list of Object.values(os.networkInterfaces())){
  for(const nic of (list||[])){
   if(nic.family!=='IPv4'||nic.internal)continue;
   if(!out.includes(nic.address))out.push(nic.address);
  }
 }
 return out;
}

const server=https.createServer(options,app);
server.on('error',e=>{
 if(e.code==='EADDRINUSE')console.error(`Port ${PORT} is already in use. Stop the old Voucher Manager server first.`);
 else console.error('HTTPS server error:',e.message);
});

// Separate plain-HTTP endpoint for health and per-transaction status only.
// Voucher mutations and other APIs remain HTTPS.
const healthServer=http.createServer((req,res)=>{
 res.setHeader('Access-Control-Allow-Origin','*');
 res.setHeader('Access-Control-Allow-Methods','GET,OPTIONS');
 res.setHeader('Access-Control-Allow-Headers','Content-Type');
 res.setHeader('Cache-Control','no-store, max-age=0');
 if(req.method==='OPTIONS'){res.writeHead(204);return res.end();}
 const parsedUrl=new URL(req.url||'/','http://localhost');
 if(req.method==='GET' && parsedUrl.pathname==='/health'){
  res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});
  return res.end(JSON.stringify({success:true,status:'online'}));
 }
 if(req.method==='GET' && parsedUrl.pathname==='/transaction-status'){
  resetTimeout();
  const requestedId=parsedUrl.searchParams.get('transactionId');
  const username=parsedUrl.searchParams.get('username');
  const since=Number(parsedUrl.searchParams.get('since')||0);
  let record=null;
  if(typeof requestedId==='string' && /^[a-f0-9-]{16,80}$/i.test(requestedId)){
   record=transactionStatus.get(requestedId)||null;
  }else{
   if(typeof username!=='string'||username.length<1||username.length>64||/[\x00-\x1f\x7f]/.test(username)){
    res.writeHead(400,{'Content-Type':'application/json; charset=utf-8'});
    return res.end(JSON.stringify({success:false,error:'Provide a valid transactionId or username.'}));
   }
   const latestId=latestTransactionByUsername.get(username);
   record=latestId?transactionStatus.get(latestId)||null:null;
  }
  let payload;
  if(!record||!Number.isFinite(since)||record.createdAt<since||
     (typeof requestedId==='string'&&record.transactionId!==requestedId)||
     (typeof username==='string'&&record.username!==username)){
   payload={success:true,found:false};
  }else{
   payload={success:true,found:true,transaction:{
    transactionId:record.transactionId,username:record.username,status:record.status,
    validity:record.validity||'',selectedSeconds:record.selectedSeconds||0,
    totalValiditySeconds:record.totalValiditySeconds||0,
    previousExpiration:record.previousExpiration||null,expiration:record.expiration||null,
    message:record.message||'',createdAt:record.createdAt,updatedAt:record.updatedAt
   }};
  }
  res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});
  return res.end(JSON.stringify(payload));
 }
 res.writeHead(404,{'Content-Type':'application/json; charset=utf-8'});
 res.end(JSON.stringify({success:false,error:'Not found. HTTP only supports GET /health and GET /transaction-status.'}));
});
healthServer.on('error',e=>{
 if(e.code==='EADDRINUSE')console.error(`HTTP health port ${HEALTH_PORT} is already in use.`);
 else console.error('HTTP health server error:',e.message);
});
healthServer.listen(HEALTH_PORT,'0.0.0.0',()=>{
 console.log(`HTTP health/status endpoints listening on 0.0.0.0:${HEALTH_PORT} (/health, /transaction-status only)`);
 const lanIPs=getLanIPv4Addresses();
 for(const ip of lanIPs)console.log(`  HTTP health URL: http://${ip}:${HEALTH_PORT}/health`);
});

server.listen(PORT,'0.0.0.0',()=>{
 console.log(`HTTPS server listening on 0.0.0.0:${PORT} (LAN enabled)`);
 console.log(`Local URL: https://localhost:${PORT}/qrcode`);
 const lanIPs=getLanIPv4Addresses();
 if(lanIPs.length){
  console.log('LAN URLs (use the IP matching the Wi-Fi network):');
  for(const ip of lanIPs)console.log(`  https://${ip}:${PORT}/qrcode`);
 }else console.log('No LAN IPv4 address detected yet.');
 console.log(`RouterOS API target: ${MIKROTIK_HOST}:${MIKROTIK_PORT}`);
 // Install/update RouterOS scripts and scheduler as soon as the app starts.
 withRouterOS(api=>ensureRouterOSScripts(api))
  .then(()=>console.log('RouterOS scripts and 5-minute scheduler are ready.'))
  .catch(e=>console.error('RouterOS script/scheduler setup failed:',e.message));
 const opener=spawn('am',['start','-a','android.intent.action.VIEW','-d',`https://localhost:${PORT}/qrcode`],{stdio:'ignore'});
 opener.on('error',e=>console.warn('Could not open browser automatically:',e.message));
});
process.on('SIGINT',()=>{clearTimeout(inactivityTimer);healthServer.close();server.close(()=>process.exit(0));});
process.on('SIGTERM',()=>{clearTimeout(inactivityTimer);healthServer.close();server.close(()=>process.exit(0));});

