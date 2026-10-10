/* ---------- настройки ---------- */
function maskPhone(p){
  var d = String(p||'').replace(/\D/g,'');
  if(d.length===11) return '+7 '+d.slice(1,4)+' ••• ••'+d.slice(9);
  return '';
}
function settingsView(){
  var v = view, t = store('ub_theme')||'system';
  var reg = isRegistered(), guest = isGuest();
  var chev = svg('M9 6l6 6-6 6',18,2);
  app.innerHTML =
    '<button type="button" class="back" id="bk">'+svg(I.back,22,2)+esc(v.from||'Назад')+'</button>'+
    '<div class="setx">'+
    '<h1 class="h1" style="margin:0 0 10px">Настройки</h1>'+
    '<div class="group"><button type="button" class="srow" id="sCity" aria-haspopup="dialog"><span>Город</span><span class="v">'+esc(cityName())+chev+'</span></button></div>'+

    '<div class="sec-h" id="thL">Оформление</div>'+
    '<div class="seg" role="radiogroup" aria-labelledby="thL">'+
      [['system','Как в системе'],['light','Светлая'],['dark','Тёмная']].map(function(o){
        return '<button type="button" role="radio" aria-checked="'+(t===o[0])+'" data-theme-opt="'+o[0]+'">'+o[1]+'</button>'; }).join('')+
    '</div>'+

    '<div id="nBox"></div>'+

    (canInstall() ? '<div class="sec-h">Приложение</div><div class="group"><button type="button" class="srow" id="sInst"><span>Установить на экран телефона</span><span class="v">'+chev+'</span></button></div>' : '')+

    '<div class="sec-h">Аккаунт</div><div class="group">'+
      (reg ? '<div class="srow"><span>Номер</span><span class="v">'+esc(maskPhone(S.session.user.phone))+'</span></div>'+
             '<button type="button" class="srow" id="sOut">Выйти</button>'+
             '<button type="button" class="srow" id="sDel" style="color:var(--dg)">Удалить аккаунт</button>'
       : guest ? '<div class="srow"><span>Вы вошли как гость</span></div>'+
             '<button type="button" class="srow" id="sIn">Войти по номеру</button>'+
             '<button type="button" class="srow" id="sOut">Выйти</button>'
       : '<button type="button" class="srow" id="sIn">Войти по номеру</button>')+
    '</div>'+
    (reg ? '<div class="note">Профиль и карточки скроются сразу, аккаунт удалится через 7 дней.</div>' : '')+

    '<div class="foot">Уустары бул · версия 0.1<br>© 2026 Евсеев А.В. · Прототип, данные вымышленные</div>'+
    '</div>';

  document.getElementById('bk').onclick = back;
  document.getElementById('sCity').onclick = citySheet;
  app.querySelectorAll('[data-theme-opt]').forEach(function(b){ b.onclick = function(){
    store('ub_theme', b.getAttribute('data-theme-opt')); applyTheme();
    app.querySelectorAll('[data-theme-opt]').forEach(function(x){ x.setAttribute('aria-checked', String(x===b)); });
  }; });
  var ib = document.getElementById('sInst'); if(ib) ib.onclick = installApp;
  var si = document.getElementById('sIn'); if(si) si.onclick = function(){ loginSheet(); };
  var so = document.getElementById('sOut'); if(so) so.onclick = function(){
    sb.auth.signOut().then(function(){ toast('Вы вышли'); S.stack=[]; go({name:'home'}, false); });
  };
  var sd = document.getElementById('sDel'); if(sd) sd.onclick = function(){
    confirmSheet('Удалить аккаунт?', 'Профиль и карточки сразу перестанут показываться, а через 7 дней аккаунт удалится окончательно. Ваши отзывы о мастерах останутся без имени. До этого срока удаление можно отменить, войдя снова.', 'Удалить аккаунт', function(){
      sb.rpc('request_account_deletion').then(function(r){
        if(r.error) return toast(errText(r.error));
        return sb.auth.signOut().then(function(){ toast('Аккаунт будет удалён через 7 дней'); S.stack=[]; go({name:'home'}, false); });
      });
    });
  };

  // Уведомления — только мастерам: про срок карточек, Про и новые отзывы
  if(!reg) return;
  var me = uid();
  Promise.all([
    sb.from('profiles').select('id').eq('id', me).maybeSingle(),
    sb.from('notify_prefs').select('expiry,reviews').eq('user_id', me).maybeSingle()
  ]).then(function(r){
    if(view!==v || !r[0].data) return;
    var pr = r[1].data || {expiry:true, reviews:true};
    var box = document.getElementById('nBox'); if(!box) return;
    box.outerHTML =
      '<div class="sec-h">Уведомления</div><div class="group">'+
      [['expiry','Срок карточек и Про'],['reviews','Новые отзывы']].map(function(o){
        return '<div class="srow"><span id="nl_'+o[0]+'">'+o[1]+'</span><button type="button" class="sw" role="switch" aria-labelledby="nl_'+o[0]+'" aria-checked="'+(pr[o[0]]!==false)+'" data-np="'+o[0]+'"></button></div>';
      }).join('')+'</div>'+
      '<div class="note">Присылать на телефон начнём в одном из ближайших обновлений.</div>';
    app.querySelectorAll('[data-np]').forEach(function(b){ b.onclick = function(){
      var k = b.getAttribute('data-np'), on = b.getAttribute('aria-checked')!=='true';
      b.setAttribute('aria-checked', String(on)); pr[k] = on;
      sb.from('notify_prefs').upsert({user_id:me, expiry:pr.expiry!==false, reviews:pr.reviews!==false}, {onConflict:'user_id'}).then(function(res){
        if(res.error){ b.setAttribute('aria-checked', String(!on)); pr[k] = !on; toast(errText(res.error)); }
      });
    }; });
  });
}
