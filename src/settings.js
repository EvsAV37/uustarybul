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
    titleRow('<h1 class="h1">Настройки</h1>', 'margin-bottom:10px')+
    '<div class="group"><button type="button" class="srow" id="sCity" aria-haspopup="dialog"><span>Город</span><span class="v">'+esc(cityName())+chev+'</span></button></div>'+

    '<div class="sec-h" id="thL">Оформление</div>'+
    '<div class="seg" role="radiogroup" aria-labelledby="thL">'+
      [['system','Как в системе'],['light','Светлая'],['dark','Тёмная']].map(function(o){
        return '<button type="button" role="radio" aria-checked="'+(t===o[0])+'" data-theme-opt="'+o[0]+'">'+o[1]+'</button>'; }).join('')+
    '</div>'+

    '<div id="nBox"></div>'+

    (canInstall() ? '<div class="sec-h">Приложение</div><div class="group"><button type="button" class="srow" id="sInst"><span>Установить на экран телефона</span><span class="v">'+chev+'</span></button></div>' : '')+

    '<div class="sec-h">Документы</div><div class="group">'+DOCS.map(function(d){
      return '<button type="button" class="srow" data-doc="'+d[0]+'"><span>'+d[1]+'</span><span class="v">'+chev+'</span></button>'; }).join('')+'</div>'+
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
    pushOff().then(function(){ return sb.auth.signOut(); }).then(function(){ toast('Вы вышли'); S.stack=[]; go({name:'home'}, false); });
  };
  var sd = document.getElementById('sDel'); if(sd) sd.onclick = function(){
    confirmSheet('Удалить аккаунт?', 'Профиль и карточки сразу перестанут показываться, а через 7 дней аккаунт удалится окончательно. Ваши отзывы о мастерах останутся без имени. До этого срока удаление можно отменить, войдя снова.', 'Удалить аккаунт', function(){
      sb.rpc('request_account_deletion').then(function(r){
        if(r.error) return toast(errText(r.error));
        return pushOff().then(function(){ return sb.auth.signOut(); }).then(function(){ toast('Аккаунт будет удалён через 7 дней'); S.stack=[]; go({name:'home'}, false); });
      });
    });
  };

  // Уведомления — только мастерам: про срок карточек, Про и новые отзывы
  if(!reg) return;
  var me = uid();
  Promise.all([
    sb.from('profiles').select('id').eq('id', me).maybeSingle(),
    sb.from('notify_prefs').select('expiry,reviews,quiet,quiet_from,quiet_to').eq('user_id', me).maybeSingle(),
    pushIsOn()
  ]).then(function(r){
    if(view!==v || !r[0].data) return;
    var pr = r[1].data || {expiry:true, reviews:true, quiet:false, quiet_from:22, quiet_to:8};
    var dev = r[2], busy = false;
    var box = document.getElementById('nBox'); if(!box) return;
    function hours(id, cur, label){
      var o = ''; for(var h=0; h<24; h++) o += '<option value="'+h+'"'+(h===cur?' selected':'')+'>'+(h<10?'0':'')+h+':00</option>';
      return '<select class="hsel" id="'+id+'" aria-label="'+label+'">'+o+'</select>';
    }
    function note(){
      var t;
      if(!pushSupported()) t = isIOS() && !isStandalone()
        ? 'На iPhone уведомления приходят только в установленном приложении — пункт «Установить на экран телефона» ниже.'
        : 'Этот браузер не умеет присылать уведомления.';
      else if(Notification.permission==='denied') t = 'Уведомления запрещены в настройках браузера. Разрешите их для этого сайта и включите снова.';
      else t = 'О скрытии карточки или профиля после жалоб сообщаем всегда.'+(pr.quiet ? ' В тихие часы уведомления ждут их окончания.' : '');
      return t;
    }
    function save(){
      return sb.from('notify_prefs').upsert({user_id:me, expiry:pr.expiry!==false, reviews:pr.reviews!==false,
        quiet:!!pr.quiet, quiet_from:pr.quiet_from, quiet_to:pr.quiet_to}, {onConflict:'user_id'});
    }
    function draw(){
      var canDev = pushSupported() && Notification.permission!=='denied';
      box.innerHTML =
        '<div class="sec-h">Уведомления</div><div class="group">'+
        '<div class="srow"><span id="nl_dev">На этот телефон</span><button type="button" class="sw" role="switch" id="nDev" aria-labelledby="nl_dev" aria-checked="'+(dev&&canDev)+'"'+(canDev?'':' disabled')+(busy?' aria-busy="true"':'')+'></button></div>'+
        [['expiry','Срок карточек и Про'],['reviews','Новые отзывы'],['quiet','Тихие часы']].map(function(o){
          var on = o[0]==='quiet' ? !!pr.quiet : pr[o[0]]!==false;
          return '<div class="srow"><span id="nl_'+o[0]+'">'+o[1]+'</span><button type="button" class="sw" role="switch" aria-labelledby="nl_'+o[0]+'" aria-checked="'+on+'" data-np="'+o[0]+'"></button></div>';
        }).join('')+
        (pr.quiet ? '<div class="srow"><span>Время</span><span class="v qh">с '+hours('qFrom', pr.quiet_from, 'Тихие часы, начало')+' до '+hours('qTo', pr.quiet_to, 'Тихие часы, конец')+'</span></div>' : '')+
        '</div><div class="note">'+esc(note())+'</div>';

      document.getElementById('nDev').onclick = function(){
        if(busy || !canDev) return;
        busy = true; draw();
        var want = !dev;
        (want ? pushOn() : pushOff()).then(function(){
          dev = want; busy = false; draw();
          toast(want ? 'Уведомления включены' : 'Уведомления на этот телефон выключены');
        }, function(e){
          busy = false; draw();
          toast(e && e.code==='denied' ? 'Без разрешения браузера уведомления не придут' : 'Не удалось включить уведомления. Попробуйте ещё раз.');
        });
      };
      box.querySelectorAll('[data-np]').forEach(function(b){ b.onclick = function(){
        var k = b.getAttribute('data-np'), was = k==='quiet' ? !!pr.quiet : pr[k]!==false;
        pr[k] = !was; draw();
        save().then(function(res){ if(res.error){ pr[k] = was; draw(); toast(errText(res.error)); } });
      }; });
      ['qFrom','qTo'].forEach(function(id){
        var el = document.getElementById(id); if(!el) return;
        el.onchange = function(){
          var k = id==='qFrom' ? 'quiet_from' : 'quiet_to', was = pr[k];
          pr[k] = Number(el.value);
          save().then(function(res){ if(res.error){ pr[k] = was; draw(); toast(errText(res.error)); } });
        };
      });
    }
    draw();
  });
}

/* ---------- push-уведомления на этот телефон ---------- */
function pushSupported(){ return window.isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window; }
function withTimeout(p, ms){ return Promise.race([p, new Promise(function(_, rej){ setTimeout(function(){ rej({code:'timeout'}); }, ms); })]); }
function swReady(){ return withTimeout(navigator.serviceWorker.ready, 5000); }
function keyBytes(s){
  s = s.replace(/-/g,'+').replace(/_/g,'/'); while(s.length%4) s+='=';
  var b = atob(s), u = new Uint8Array(b.length); for(var i=0;i<b.length;i++) u[i]=b.charCodeAt(i); return u;
}
function sameKey(a, b){
  a = new Uint8Array(a); if(a.length!==b.length) return false;
  for(var i=0;i<a.length;i++) if(a[i]!==b[i]) return false; return true;
}
function pushSave(sub){
  var j = sub.toJSON();
  return sb.rpc('save_push_subscription', {p_endpoint:j.endpoint, p_p256dh:j.keys.p256dh, p_auth:j.keys.auth})
    .then(function(r){ if(r.error) throw r.error; });
}
function pushOn(){
  var key;
  return Notification.requestPermission().then(function(p){
    if(p!=='granted') throw {code:'denied'};
    return sb.rpc('push_public_key');
  }).then(function(r){
    if(r.error || !r.data) throw {code:'nokey'};
    key = keyBytes(r.data);
    return swReady();
  }).then(function(reg){
    return reg.pushManager.getSubscription().then(function(old){
      if(old && old.options && old.options.applicationServerKey && !sameKey(old.options.applicationServerKey, key))
        return old.unsubscribe().then(function(){ return null; });
      return old;
    }).then(function(old){ return old || reg.pushManager.subscribe({userVisibleOnly:true, applicationServerKey:key}); });
  }).then(pushSave);
}
function pushOff(){
  if(!pushSupported()) return Promise.resolve();
  return swReady().then(function(reg){ return reg.pushManager.getSubscription(); }).then(function(sub){
    if(!sub) return;
    return sb.from('push_subscriptions').delete().eq('endpoint', sub.endpoint).then(function(){ return sub.unsubscribe(); });
  }).catch(function(){});
}
function pushIsOn(){
  if(!pushSupported() || Notification.permission!=='granted') return Promise.resolve(false);
  return swReady().then(function(reg){ return reg.pushManager.getSubscription(); }).then(function(sub){
    if(!sub) return false;
    return sb.from('push_subscriptions').select('disabled_at').eq('endpoint', sub.endpoint).maybeSingle()
      .then(function(r){ return !!(r.data && !r.data.disabled_at); });
  }).catch(function(){ return false; });
}
// При запуске: телефон подписан (значит, мастер сам включил уведомления здесь) — освежить подписку на сервере
function pushRefresh(){
  if(!isRegistered() || !pushSupported() || Notification.permission!=='granted') return;
  swReady().then(function(reg){ return reg.pushManager.getSubscription(); })
    .then(function(sub){ if(sub) return pushSave(sub); }).catch(function(){});
}
