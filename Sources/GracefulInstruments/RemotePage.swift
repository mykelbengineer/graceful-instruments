/// The phone remote's web page (one file, no internet needed).
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Graceful Remote</title>
<style>
:root{--bg:#0f1115;--card:#191c22;--line:#2a2e37;--text:#eef0f4;--dim:#9097a3;--accent:#4f8cff;--on:#2fbf71;--warn:#ff6b5b}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:var(--text);font:16px -apple-system,system-ui,sans-serif;padding:12px 12px 40px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:12px}
h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--dim);margin:0 0 10px}
.title{font-size:20px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta{color:var(--dim);font-size:14px;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row{display:flex;gap:8px;margin-top:8px}
.row>*{flex:1}
button{font:inherit;color:var(--text);background:#262a33;border:1px solid var(--line);border-radius:12px;height:52px;font-weight:600;min-width:0;padding:0 6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
button:active{transform:scale(.97)}
button.big{height:72px;font-size:22px;background:var(--accent);border:0}
button.on{background:var(--on);border-color:var(--on);color:#06140c}
button.small{height:40px;font-size:14px}
.chord{display:flex;align-items:baseline;gap:12px;margin-top:10px}
.chord .now{font-size:40px;font-weight:800}
.chord .nxt{color:var(--dim);font-size:18px}
.lyric{margin-top:6px;font-size:18px}
.lyric .n{color:var(--dim);font-size:15px;margin-top:2px}
.bar{height:6px;background:var(--line);border-radius:3px;margin-top:10px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent);width:0}
.keys{display:grid;grid-template-columns:repeat(6,1fr);gap:6px;margin-top:8px}
.keys button{height:44px}
.list button{display:block;width:100%;text-align:left;margin-top:6px;height:46px;padding:0 12px}
.list .sec{color:var(--dim);font-size:13px;margin:12px 0 0}
.big-key{font-size:34px;font-weight:800;margin:6px 0}
select{font:inherit;width:100%;height:44px;border-radius:12px;background:#262a33;color:var(--text);border:1px solid var(--line);padding:0 10px}
#err{display:none;background:var(--warn);color:#fff;border-radius:12px;padding:12px;margin-bottom:12px}
.val{display:flex;align-items:center;justify-content:center;font-weight:700}
</style></head><body>
<div id="err"></div>

<div class="card">
  <div class="title" id="title">Nothing loaded</div>
  <div class="meta" id="meta"></div>
  <div class="chord" id="chordbox" style="display:none"><span class="now" id="chord"></span><span class="nxt" id="nchord"></span></div>
  <div class="lyric" id="lyricbox" style="display:none"><div id="lyric"></div><div class="n" id="nlyric"></div></div>
  <div class="bar"><i id="pos"></i></div>
  <div class="row"><button class="big" id="play" onclick="act('play')">Play</button></div>
  <div class="row">
    <button onclick="act('stop')">Stop</button>
    <button onclick="act('fade')">Fade</button>
  </div>
  <div class="row">
    <button onclick="act('prev')">&#9664; Prev</button>
    <button onclick="act('next')" id="next">Next &#9654;</button>
  </div>
  <div class="row">
    <button id="loop" onclick="act('loop')">Loop</button>
    <button id="click" onclick="act('click')">Click</button>
  </div>
  <div class="row">
    <button class="small" onclick="act('bar-')">&minus; bar</button>
    <button class="small" onclick="act('bar+')">+ bar</button>
  </div>
</div>

<div class="card">
  <h2>Tempo and key</h2>
  <div class="row"><button onclick="act('tempo-')">&minus;</button><div class="val" id="bpm">&nbsp;</div><button onclick="act('tempo+')">+</button></div>
  <div class="row"><button onclick="act('key-')">&minus;</button><div class="val" id="key">&nbsp;</div><button onclick="act('key+')">+</button></div>
  <div id="portions"></div>
</div>

<div class="card">
  <h2>Pad</h2>
  <div class="row"><button id="pad" onclick="act('pad')">Pad off</button>
  <select id="padsound" onchange="act('padsound',this.value)">
    <option value="warm">Warm pad</option><option value="shimmer">Shimmer</option>
    <option value="organ">Gospel organ</option><option value="strings">Strings</option></select></div>
  <div class="keys" id="padkeys"></div>
</div>

<div class="card">
  <h2>Key finder</h2>
  <div class="big-key" id="fkey">&nbsp;</div>
  <div class="meta" id="falt"></div>
  <div class="row"><button id="listen" onclick="act('listen')">Listen</button><button onclick="act('listenreset')">New song</button></div>
  <div class="row"><button onclick="act('padfound')">Pad in this key</button><button onclick="act('match')">Move song here</button></div>
</div>

<div class="card">
  <h2 id="svcname">Service</h2>
  <select id="services" onchange="act('service',this.value)"></select>
  <div class="list" id="service"></div>
</div>

<script>
const names=["C","Db","D","Eb","E","F","F#","G","Ab","A","Bb","B"];
let k=new URLSearchParams(location.search).get('k')||localStorage.getItem('gik')||'';
if(k) localStorage.setItem('gik',k);
const $=id=>document.getElementById(id);
const pk=$('padkeys'); names.forEach((n,i)=>{const b=document.createElement('button');b.textContent=n;b.onclick=()=>act('padkey',i);pk.appendChild(b)});
let lastSvc='';
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function call(path){
  if(!k){k=prompt('Enter the 4-digit code shown in Graceful Instruments (Phone Remote, in the sidebar)')||'';localStorage.setItem('gik',k)}
  try{
    const r=await fetch(path+(path.includes('?')?'&':'?')+'k='+encodeURIComponent(k),{cache:'no-store'});
    if(r.status==403){$('err').style.display='block';$('err').textContent='Wrong code. Scan the code on the MacBook again.';localStorage.removeItem('gik');k='';return}
    $('err').style.display='none';
    show(await r.json());
  }catch(e){$('err').style.display='block';$('err').textContent='Can\'t reach the MacBook. Is it on the same Wi-Fi, with the app open?'}
}
function act(a,v){call('/api/do?a='+encodeURIComponent(a)+(v!==undefined?'&v='+encodeURIComponent(v):''))}
function show(s){
  $('title').textContent=s.title||'Nothing loaded';
  $('meta').textContent=[s.entry,s.kind,s.bpm?s.bpm+' BPM':'',s.key?'Key '+s.key:''].filter(x=>x).join(' · ');
  $('play').textContent=s.playing?'Pause':'Play';
  $('pos').style.width=(s.dur>0?Math.min(100,s.pos/s.dur*100):0)+'%';
  $('next').textContent=s.next?'Next: '+s.next:'Next ▶';
  $('loop').className=s.loop?'on':''; $('click').className=s.click?'on':'';
  $('bpm').textContent=s.bpm?s.bpm+' BPM':'–';
  $('key').textContent=(s.key||'Key')+(s.semitones?' ('+(s.semitones>0?'+':'')+s.semitones+')':'');
  $('chordbox').style.display=s.chord?'flex':'none'; $('chord').textContent=s.chord||''; $('nchord').textContent=s.nextChord?'then '+s.nextChord:'';
  $('lyricbox').style.display=s.lyric?'block':'none'; $('lyric').textContent=s.lyric||''; $('nlyric').textContent=s.nextLyric||'';
  $('portions').innerHTML=(s.portions||[]).length?'<div class="row" style="flex-wrap:wrap">'+s.portions.map(p=>'<button class="small'+(p.on?' on':'')+'" style="flex:1 1 30%" onclick="act(\'portion\',\''+p.id+'\')">'+esc(p.name)+'</button>').join('')+'</div>':'';
  const p=s.pad||{}; $('pad').className=p.on?'on':''; $('pad').textContent=p.on?'Pad on: '+p.name:'Pad off';
  $('padsound').value=p.sound||'warm';
  [...pk.children].forEach((b,i)=>b.className=(p.on&&p.key==i)?'on':'');
  const f=s.finder||{}; $('fkey').textContent=f.key||(f.on?'Listening…':'–');
  $('falt').textContent=f.key?('Sure: '+Math.round((f.sure||0)*100)+'%'+(f.alt?' · or '+f.alt:'')):'';
  $('listen').className=f.on?'on':''; $('listen').textContent=f.on?'Listening':'Listen';
  const sv=s.services||[]; const key=sv.map(x=>x.id).join(',')+(s.service?s.service.id:'');
  if(key!==lastSvc){lastSvc=key;$('services').innerHTML='<option value="">Choose a service</option>'+sv.map(x=>'<option value="'+x.id+'"'+(s.service&&s.service.id==x.id?' selected':'')+'>'+esc(x.name)+'</option>').join('')}
  let h='';
  if(s.service){s.service.sections.forEach(sec=>{if(!sec.entries.length)return;h+='<div class="sec">'+esc(sec.name)+'</div>';sec.entries.forEach(e=>{h+='<button class="'+(e.current?'on':'')+'" onclick="act(\'entry\',\''+e.id+'\')">'+esc(e.title)+'</button>'})})}
  $('service').innerHTML=h;
}
call('/api/state'); setInterval(()=>{if(!document.hidden)call('/api/state')},800);
</script>
</body></html>
"""#
}
