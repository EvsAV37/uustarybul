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
      '<div class="brand">Уустары бул</div>'+inner;
  }
  function stepPhone(){
    clearT();
    openScreen(shell('',
      '<form id="lf" class="scr-body" style="margin-top:40px">'+
      '<h1 class="lg-h">Вход по номеру</h1>'+
      '<p class="lg-p">Мы позвоним и сразу сбросим. Введите последние 4 цифры номера, с которого поступит звонок. Отвечать не нужно.</p>'+
      '<label class="field"><span>Номер телефона</span><input id="lp" class="inp" type="tel" inputmode="tel" autocomplete="tel" placeholder="+7 ___ ___-__-__" style="height:54px;font-size:20px;letter-spacing:.02em" value="'+esc(phone)+'"></label>'+
      '<label class="check" style="margin-top:4px"><input id="lc" type="checkbox"><span>Даю согласие на обработку персональных данных</span></label>'+
      '<div class="spacer"></div>'+
      '<button class="btn pr" id="lb" type="submit">Получить звонок</button>'+
      '<p class="lg-small">Продолжая, вы принимаете Пользовательское соглашение и Политику обработки персональных данных</p>'+
      '<p class="lg-small">Для проверки прототипа: +7 000 000-00-01, код 1234</p>'+
      '</form>'),
    function(){
      var inp = document.getElementById('lp');
      inp.addEventListener('input', function(){ fmtPhoneInput(inp); });
      setTimeout(function(){ if(!inp.value) inp.focus({preventScroll:true}); }, 300);
      document.getElementById('lf').addEventListener('submit', function(e){
        e.preventDefault();
        phone = inp.value;
        var digits = phone.replace(/\D/g,'');
        if(digits.length!==11) return toast('Введите номер полностью');
        if(!document.getElementById('lc').checked) return toast('Отметьте согласие, без него вход невозможен');
        var b = document.getElementById('lb'); b.disabled=true; b.textContent='Звоним…';
        callVerify({action:'start', phone:phone}).then(function(){ stepCode(); }, function(err){ b.disabled=false; b.textContent='Получить звонок'; toast(err.message); });
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
      ag.onclick = function(){ ag.disabled=true; callVerify({action:'start', phone:phone}).then(function(){ toast('Звоним ещё раз'); stepCode(); }, function(err){ ag.disabled=false; toast(err.message); }); };
      timers.push(setTimeout(function(){ var f=document.getElementById('fb'); if(f) f.hidden=false; }, 15000));
      document.getElementById('fb').onclick = stepFallback;
    });
  }
  function stepFallback(){
    clearT();
    callVerify({action:'start_fallback', phone:phone}).then(function(d){
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
