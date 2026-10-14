/* ---------- общее для приложения и /admin: вызов verify-phone и задачка для телефона ---------- */
function fmtPhoneInput(el){
  var d = el.value.replace(/\D/g,'');
  if(d[0]==='8'||d[0]==='7') d = d.slice(1);
  d = d.slice(0,10);
  if(!d){ el.value=''; return; }
  var o = '+7 '+d.slice(0,3);
  if(d.length>3) o += ' '+d.slice(3,6);
  if(d.length>6) o += '-'+d.slice(6,8);
  if(d.length>8) o += '-'+d.slice(8,10);
  el.value = o;
}
function callVerify(body){
  return sb.functions.invoke('verify-phone', { body: body }).then(function(r){
    if(!r.error) return r.data;
    var ctx = r.error.context;
    if(ctx && typeof ctx.json==='function'){
      return ctx.json().then(function(b){ throw new Error((b&&b.error)||r.error.message); }, function(){ throw r.error; });
    }
    throw r.error;
  });
}
/* ---------- защита от ботов: задачка для телефона (proof-of-work) ----------
   Перед звонком с кодом и перед первым номером мастера для гостя телефон незаметно
   решает задачку от сервера (около секунды; решается заранее, пока человек вводит номер).
   Проверяет функция verify-phone, одна задачка — одно действие. */
// Решатель задачки: перебор number, пока sha256(salt + number) не совпадёт с challenge.
// Сообщения короче 56 байт → один блок SHA-256; без библиотек, работает в Web Worker.
function powSolveSync(salt, challenge, max){
  var K=[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  var t=[]; for(var i=0;i<8;i++) t.push(parseInt(challenge.substr(i*8,8),16)|0);
  var W=new Int32Array(64), B=new Uint8Array(64), sl=salt.length;
  for(i=0;i<sl;i++) B[i]=salt.charCodeAt(i)&255;
  for(var n=0;n<=max;n++){
    var ns=String(n), L=sl+ns.length;
    if(L>55) return -1;
    for(i=0;i<ns.length;i++) B[sl+i]=ns.charCodeAt(i);
    B[L]=0x80; for(i=L+1;i<64;i++) B[i]=0;
    var bits=L*8; B[62]=(bits>>>8)&255; B[63]=bits&255;
    for(i=0;i<16;i++) W[i]=(B[i*4]<<24)|(B[i*4+1]<<16)|(B[i*4+2]<<8)|B[i*4+3];
    for(i=16;i<64;i++){ var a=W[i-15], b=W[i-2];
      var s0=((a>>>7)|(a<<25))^((a>>>18)|(a<<14))^(a>>>3), s1=((b>>>17)|(b<<15))^((b>>>19)|(b<<13))^(b>>>10);
      W[i]=(W[i-16]+s0+W[i-7]+s1)|0; }
    var h0=0x6a09e667,h1=0xbb67ae85|0,h2=0x3c6ef372,h3=0xa54ff53a|0,h4=0x510e527f,h5=0x9b05688c|0,h6=0x1f83d9ab,h7=0x5be0cd19;
    for(i=0;i<64;i++){
      var S1=((h4>>>6)|(h4<<26))^((h4>>>11)|(h4<<21))^((h4>>>25)|(h4<<7)), ch=(h4&h5)^(~h4&h6),
          T1=(h7+S1+ch+K[i]+W[i])|0, S0=((h0>>>2)|(h0<<30))^((h0>>>13)|(h0<<19))^((h0>>>22)|(h0<<10)),
          mj=(h0&h1)^(h0&h2)^(h1&h2), T2=(S0+mj)|0;
      h7=h6;h6=h5;h5=h4;h4=(h3+T1)|0;h3=h2;h2=h1;h1=h0;h0=(T1+T2)|0;
    }
    if(((h0+0x6a09e667)|0)===t[0] && ((h1+(0xbb67ae85|0))|0)===t[1] && ((h2+0x3c6ef372)|0)===t[2] && ((h3+(0xa54ff53a|0))|0)===t[3] &&
       ((h4+0x510e527f)|0)===t[4] && ((h5+(0x9b05688c|0))|0)===t[5] && ((h6+0x1f83d9ab)|0)===t[6] && ((h7+0x5be0cd19)|0)===t[7]) return n;
  }
  return -1;
}
var POW = { ready:null, busy:null, worker:null };
function powRun(c){
  return new Promise(function(res){
    var done = function(n){ res(n); };
    try{
      if(!POW.worker){
        var src = powSolveSync.toString()+'\nonmessage=function(e){ postMessage(powSolveSync(e.data.salt, e.data.challenge, e.data.maxnumber)); };';
        POW.worker = new Worker(URL.createObjectURL(new Blob([src], {type:'text/javascript'})));
      }
      POW.worker.onmessage = function(e){ done(e.data); };
      POW.worker.onerror = function(){ POW.worker = null; done(powSolveSync(c.salt, c.challenge, c.maxnumber)); };
      POW.worker.postMessage(c);
    }catch(e){ setTimeout(function(){ done(powSolveSync(c.salt, c.challenge, c.maxnumber)); }, 0); }
  });
}
// Решить заранее (вызываем, когда открылся вход или окно гостя)
function powPrefetch(){
  if(POW.ready || POW.busy) return POW.busy || Promise.resolve();
  POW.busy = callVerify({action:'challenge'}).then(function(c){
    return powRun(c).then(function(n){
      POW.busy = null;
      if(n < 0) throw new Error('Проверка не удалась');
      var m = /expires=(\d+)/.exec(c.salt);
      POW.ready = { salt:c.salt, challenge:c.challenge, signature:c.signature, number:n, exp: m ? +m[1]*1000 : 0 };
    });
  }, function(e){ POW.busy = null; throw e; });
  return POW.busy;
}
function powTake(){
  var p = POW.ready;
  if(p && p.exp > Date.now()+60000){ POW.ready = null; return Promise.resolve(p); }
  POW.ready = null;
  return powPrefetch().then(function(){ var x = POW.ready; POW.ready = null; return x; });
}
// Вызов verify-phone с решённой задачкой; если сервер не принял — одна повторная попытка с новой
function callGuarded(body, retry){
  return powTake().then(function(p){
    var b = {}; for(var k in body) b[k] = body[k];
    b.pow = { salt:p.salt, challenge:p.challenge, signature:p.signature, number:p.number };
    return callVerify(b);
  }).catch(function(err){
    if(!retry && /pow_/.test(err && err.message)) return callGuarded(body, true);
    if(/pow_/.test(err && err.message)) throw new Error('Не получилось проверить устройство. Попробуйте ещё раз.');
    throw err;
  });
}
