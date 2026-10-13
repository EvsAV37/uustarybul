/* ---------- вход по номеру (звонок-сброс через Zvonok) ---------- */
var DOC_VERSION = '2026-10-10';
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
// Гость: проверка один раз, после неё сервер выдаёт номера мастеров
function guestCheck(){ return callGuarded({action:'guest'}); }
function finishLogin(data, after){
  return sb.auth.verifyOtp({ token_hash: data.token_hash, type: 'magiclink' }).then(function(r){
    if(r.error) throw r.error;
    S.session = r.data.session;
    // Согласия — отдельными записями (156-ФЗ): что принято, какая версия, когда
    return sb.from('consents').insert([{kind:'terms', doc_version:DOC_VERSION},{kind:'pd_processing', doc_version:DOC_VERSION}]).then(function(){
      closeSheet(true); closeScreen(); toast(data.is_new ? 'Добро пожаловать!' : 'Вы вошли'); render();
      if(typeof after==='function') setTimeout(after, 300);
    });
  });
}
function loginSheet(after){
  var phone = '';
  var timers = [];
  function clearT(){ timers.forEach(clearTimeout); timers=[]; }
  screenOnClose = clearT;
  var X = '<button type="button" class="circle" data-close aria-label="Закрыть">'+svg('M18 6L6 18M6 6l12 12',18,2)+'</button>';
  function shell(backLabel, inner){
    return '<div class="scr-top">'+(backLabel?'<button type="button" class="back" id="lgBack">'+svg(I.back,22,2)+esc(backLabel)+'</button>':'<span></span>')+X+'</div>'+
      '<div class="brand"><span class="logo" aria-hidden="true"></span>Уустары бул</div>'+inner;
  }
  function stepPhone(){
    clearT();
    openScreen(shell('',
      '<form id="lf" class="scr-body" style="margin-top:40px">'+
      '<h1 class="lg-h">Вход по номеру</h1>'+
      '<p class="lg-p">Мы позвоним и сразу сбросим. Введите последние 4 цифры номера, с которого поступит звонок. Отвечать не нужно.</p>'+
      '<label class="field"><span>Номер телефона</span><input id="lp" class="inp" type="tel" inputmode="tel" autocomplete="tel" placeholder="+7 ___ ___-__-__" style="height:54px;font-size:20px;letter-spacing:.02em" value="'+esc(phone)+'"></label>'+
      '<label class="check" style="margin-top:4px"><input id="lc" type="checkbox"><span>Даю <button type="button" class="lnk" data-doc="consents#processing">согласие на обработку персональных данных</button></span></label>'+
      '<div class="spacer"></div>'+
      '<button class="btn pr" id="lb" type="submit">Получить звонок</button>'+
      '<p class="lg-small">Продолжая, вы принимаете <button type="button" class="lnk" data-doc="terms">Пользовательское соглашение</button> и <button type="button" class="lnk" data-doc="privacy">Политику обработки персональных данных</button></p>'+
      '<p class="lg-small">Для проверки прототипа: +7 000 000-00-01, код 1234</p>'+
      '</form>'),
    function(){
      var inp = document.getElementById('lp');
      powPrefetch().catch(function(){});
      inp.addEventListener('input', function(){ fmtPhoneInput(inp); });
      setTimeout(function(){ if(!inp.value) inp.focus({preventScroll:true}); }, 300);
      document.getElementById('lf').addEventListener('submit', function(e){
        e.preventDefault();
        phone = inp.value;
        var digits = phone.replace(/\D/g,'');
        if(digits.length!==11) return toast('Введите номер полностью');
        if(!document.getElementById('lc').checked) return toast('Отметьте согласие, без него вход невозможен');
        var b = document.getElementById('lb'); b.disabled=true; b.textContent='Звоним…';
        callGuarded({action:'start', phone:phone}).then(function(){ stepCode(); powPrefetch().catch(function(){}); }, function(err){ b.disabled=false; b.textContent='Получить звонок'; toast(err.message); });
      });
    });
  }
  function stepCode(){
    clearT();
    openScreen(shell('Номер',
      '<form id="cf" class="scr-body" style="margin-top:40px">'+
      '<h1 class="lg-h">Вам звонят</h1>'+
      '<p class="lg-p">на '+esc(phone)+'. Введите последние 4 цифры номера, с которого звонят.</p>'+
      '<div class="cells" id="cells"><span></span><span></span><span></span><span></span>'+
        '<input id="cc" inputmode="numeric" autocomplete="one-time-code" maxlength="4" aria-label="Последние 4 цифры номера"></div>'+
      '<div style="font-size:15px"><button type="button" id="again" class="muted" disabled>Позвонить ещё раз через 1:00</button></div>'+
      '<div class="spacer"></div>'+
      '<button class="btn pr" id="cb" type="submit">Войти</button>'+
      '<button type="button" id="fb" class="btn sec" hidden>Звонок не пришёл</button>'+
      '<button type="button" id="chg" class="btn" style="height:48px;font-size:15px;font-weight:500">Изменить номер</button>'+
      '</form>'),
    function(){
      document.getElementById('lgBack').onclick = stepPhone;
      var cc = document.getElementById('cc'), cells = document.getElementById('cells').querySelectorAll('span');
      function paint(){ var v = cc.value; cells.forEach(function(c, i){ c.textContent = v[i]||''; c.className = (i < v.length || (i===v.length && document.activeElement===cc)) ? 'f' : ''; }); }
      function submit(){
        var code = cc.value.replace(/\D/g,''); if(code.length!==4) return toast('Введите 4 цифры');
        var b=document.getElementById('cb'); b.disabled=true; b.textContent='Проверяем…';
        callVerify({action:'confirm', phone:phone, code:code}).then(function(d){ clearT(); return finishLogin(d, after); })
          .catch(function(err){ b.disabled=false; b.textContent='Войти'; cc.value=''; paint(); toast(err.message); });
      }
      cc.addEventListener('input', function(){ cc.value = cc.value.replace(/\D/g,'').slice(0,4); paint(); if(cc.value.length===4) submit(); });
      cc.addEventListener('focus', paint); cc.addEventListener('blur', paint);
      setTimeout(function(){ cc.focus({preventScroll:true}); paint(); }, 300);
      document.getElementById('cf').addEventListener('submit', function(e){ e.preventDefault(); submit(); });
      document.getElementById('chg').onclick = stepPhone;
      var left = 60, ag = document.getElementById('again');
      (function tick(){
        if(!document.getElementById('again')) return;
        if(left<=0){ ag.disabled=false; ag.className='link'; ag.textContent='Позвонить ещё раз'; return; }
        ag.textContent='Позвонить ещё раз через '+Math.floor(left/60)+':'+String(left%60).padStart(2,'0'); left--; timers.push(setTimeout(tick,1000));
      })();
      ag.onclick = function(){ ag.disabled=true; callGuarded({action:'start', phone:phone}).then(function(){ toast('Звоним ещё раз'); stepCode(); powPrefetch().catch(function(){}); }, function(err){ ag.disabled=false; toast(err.message); }); };
      timers.push(setTimeout(function(){ var f=document.getElementById('fb'); if(f) f.hidden=false; }, 15000));
      document.getElementById('fb').onclick = stepFallback;
    });
  }
  function stepFallback(){
    clearT();
    callGuarded({action:'start_fallback', phone:phone}).then(function(d){
      var nums = (d.numbers||[]).map(String);
      openScreen(shell('Назад',
        '<div class="scr-body" style="margin-top:40px">'+
        '<h1 class="lg-h">Позвоните нам</h1>'+
        '<p class="lg-p">Позвоните с номера '+esc(phone)+' на номер ниже. Звонок бесплатный и сбросится сам.</p>'+
        '<div class="group">'+(nums.length? nums.map(function(n){
          var dg = n.replace(/\D/g,''); return '<a class="grow" href="tel:+'+esc(dg)+'"><span class="t" style="font-size:20px;font-weight:600;font-variant-numeric:tabular-nums">+'+esc(dg)+'</span></a>'; }).join('')
          : '<div class="grow"><span class="t muted">Номер не получен, попробуйте через минуту</span></div>')+'</div>'+
        '<div class="spacer"></div>'+
        '<button type="button" class="btn pr" id="done">Я позвонил</button>'+
        '</div>'),
      function(){
        document.getElementById('lgBack').onclick = stepCode;
        var tries = 0;
        document.getElementById('done').onclick = function poll(){
          var b=document.getElementById('done'); if(!b) return; b.disabled=true; b.textContent='Проверяем…';
          callVerify({action:'check_fallback', phone:phone}).then(function(d){
            if(d && d.token_hash) return finishLogin(d, after);
            tries++;
            if(tries<5) timers.push(setTimeout(poll, 3000));
            else { b.disabled=false; b.textContent='Я позвонил'; tries=0; toast('Звонок пока не найден. Попробуйте ещё раз через минуту.'); }
          }).catch(function(err){ b.disabled=false; b.textContent='Я позвонил'; toast(err.message); });
        };
      });
    }, function(err){ toast(err.message); });
  }
  stepPhone();
}
