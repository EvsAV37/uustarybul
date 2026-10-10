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
      closeSheet(); toast(data.is_new ? 'Добро пожаловать!' : 'Вы вошли'); render();
      if(typeof after==='function') setTimeout(after, 300);
    });
  });
}
function loginSheet(after){
  var phone = '';
  var timers = [];
  function clearT(){ timers.forEach(clearTimeout); timers=[]; }
  function stepPhone(){
    clearT();
    openSheet('<h2>Вход по номеру</h2><p>Мы позвоним и сразу сбросим. Введите последние 4 цифры номера, с которого поступит звонок. Отвечать не нужно.</p>'+
      '<form id="lf" style="display:flex;flex-direction:column;gap:16px">'+
      '<label class="field"><span>Номер телефона</span><input id="lp" class="inp" type="tel" inputmode="tel" autocomplete="tel" placeholder="+7 ___ ___-__-__" style="font-size:20px" value="'+esc(phone)+'"></label>'+
      '<label class="check"><input id="lc" type="checkbox"><span>Даю согласие на обработку персональных данных и принимаю пользовательское соглашение</span></label>'+
      '<button class="btn pr" id="lb" type="submit">Получить звонок</button>'+
      '<p style="margin:0;font-size:12px">Для проверки прототипа: +7 000 000-00-01, код 1234.</p>'+
      '</form>',
    function(){
      var inp = document.getElementById('lp');
      inp.addEventListener('input', function(){ fmtPhoneInput(inp); });
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
    openSheet('<h2>Вам звонят</h2><p>на '+esc(phone)+'. Введите последние 4 цифры номера, с которого звонят.</p>'+
      '<form id="cf" style="display:flex;flex-direction:column;gap:14px">'+
      '<input id="cc" class="inp code" inputmode="numeric" autocomplete="one-time-code" maxlength="4" aria-label="Последние 4 цифры" placeholder="••••">'+
      '<button class="btn pr" id="cb" type="submit">Войти</button></form>'+
      '<div style="display:flex;justify-content:space-between;gap:10px;margin-top:16px;font-size:15px">'+
      '<button type="button" id="again" class="muted" disabled>Позвонить ещё раз через 60</button>'+
      '<button type="button" id="chg" class="link">Изменить номер</button></div>'+
      '<button type="button" id="fb" class="btn sec" style="margin-top:16px" hidden>Звонок не пришёл</button>',
    function(){
      var cc = document.getElementById('cc');
      function submit(){
        var code = cc.value.replace(/\D/g,''); if(code.length!==4) return;
        var b=document.getElementById('cb'); b.disabled=true; b.textContent='Проверяем…';
        callVerify({action:'confirm', phone:phone, code:code}).then(function(d){ clearT(); return finishLogin(d, after); })
          .catch(function(err){ b.disabled=false; b.textContent='Войти'; cc.value=''; toast(err.message); });
      }
      cc.addEventListener('input', function(){ cc.value = cc.value.replace(/\D/g,'').slice(0,4); if(cc.value.length===4) submit(); });
      document.getElementById('cf').addEventListener('submit', function(e){ e.preventDefault(); submit(); });
      document.getElementById('chg').onclick = stepPhone;
      var left = 60, ag = document.getElementById('again');
      (function tick(){
        if(!document.getElementById('again')) return;
        if(left<=0){ ag.disabled=false; ag.className='link'; ag.textContent='Позвонить ещё раз'; return; }
        ag.textContent='Позвонить ещё раз через '+left; left--; timers.push(setTimeout(tick,1000));
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
      openSheet('<h2>Позвоните нам</h2><p>Позвоните с номера '+esc(phone)+' на любой номер ниже. Звонок бесплатный и сбросится сам.</p>'+
        '<div class="group" style="margin-bottom:16px">'+(nums.length? nums.map(function(n){
          var dg = n.replace(/\D/g,''); return '<a class="grow" href="tel:+'+esc(dg)+'"><span class="t" style="font-size:20px;font-weight:600;font-variant-numeric:tabular-nums">+'+esc(dg)+'</span></a>'; }).join('')
          : '<div class="grow"><span class="t muted">Номер не получен, попробуйте через минуту</span></div>')+'</div>'+
        '<button type="button" class="btn pr" id="done">Я позвонил</button>'+
        '<button type="button" class="btn" id="bk2" style="margin-top:6px">Назад</button>',
      function(){
        document.getElementById('bk2').onclick = stepCode;
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
