/* ---------- кабинет мастера ---------- */
var DAY = 86400000;
function dmy(iso){ var d=new Date(iso); return d.getDate()+' '+MG[d.getMonth()]; }
function daysLeft(iso){ return Math.max(0, Math.ceil((new Date(iso)-Date.now())/DAY)); }
function uid(){ return S.session && S.session.user ? S.session.user.id : null; }
function dbMsg(e){
  var m = (e && (e.message||'')) + ' ' + ((e && e.hint)||'');
  var map = {
    spheres_limit:'Достигнут лимит активных направлений. Снимите с публикации другое или подключите Про.',
    spheres_total_limit:'В профиле может быть не больше 20 направлений.',
    services_limit:'Достигнут лимит услуг в направлении. В Про — без лимита.',
    photos_limit:'Достигнут лимит фото в направлении. В Про — до 30.',
    city_change_too_soon:'Город можно менять не чаще раза в 30 дней.',
    review_no_contact:'Отзыв можно оставить в течение 30 дней после звонка мастеру через Уустары бул.',
    review_own_profile:'Нельзя оставить отзыв самому себе.',
    complaint_own_profile:'Нельзя пожаловаться на себя.',
    sphere_blocked:'Это направление скрыто после жалоб, опубликовать его нельзя.',
    registration_required:'Нужен вход по номеру телефона.'
  };
  for(var k in map) if(m.indexOf(k)>=0) return map[k];
  if(e && e.code==='23505') return null;
  return errText(e);
}
function catById(id){ return S.cats.find(function(c){return c.id===id;}) || {name:'',slug:''}; }
function confirmSheet(title, text, label, onOk){
  openSheet('<h2>'+esc(title)+'</h2><p>'+esc(text)+'</p><button type="button" class="btn dg" id="ok">'+esc(label)+'</button><button type="button" class="btn" data-close style="margin-top:6px">Отмена</button>',
    function(){ document.getElementById('ok').onclick = function(){ closeSheet(); onOk(); }; });
}

function loadMine(){
  var id = uid();
  var since = new Date(Date.now()-30*DAY).toISOString().slice(0,10);
  return Promise.all([
    sb.from('profiles').select('*').eq('id',id).maybeSingle(),
    sb.from('spheres').select('id,title,description,category_id,status,published_at,expires_at,created_at,services(id,is_hidden),photos(id,is_hidden)').eq('profile_id',id).order('created_at'),
    sb.rpc('profile_limits',{p_profile:id}),
    sb.from('reviews').select('id,author_name,rating,body,reply,created_at,is_hidden').eq('profile_id',id).order('created_at',{ascending:false}),
    sb.from('stats_daily').select('views,contacts').eq('profile_id',id).gte('day',since)
  ]).then(function(r){
    var err = r[0].error||r[1].error;
    if(err) throw err;
    var lim = (r[2].data && r[2].data[0]) || {spheres:2, services_per_sphere:5, photos_per_sphere:10};
    var st = (r[4].data||[]).reduce(function(a,x){ a.views+=x.views; a.contacts+=x.contacts; return a; }, {views:0, contacts:0});
    return { p:r[0].data, spheres:r[1].data||[], lim:lim, reviews:r[3].data||[], stats:st };
  });
}
function sphereState(s, pro){
  var d = s.expires_at ? daysLeft(s.expires_at) : 0;
  if(s.status==='active'){
    if(pro) return {t:'Активна · продлится сама '+dmy(s.expires_at), c:'var(--ok)'};
    if(d<=3) return {t:'Осталось '+d+' '+plural(d,'день','дня','дней'), c:'var(--warn)', renew:true};
    return {t:'Активна · осталось '+d+' '+plural(d,'день','дня','дней'), c:'var(--ok)'};
  }
  if(s.status==='draft') return {t:'Черновик · не показывается', c:'var(--mu)', publish:true};
  if(s.status==='expired') return {t:'Срок вышел · не показывается', c:'var(--warn)', renew:true};
  if(s.status==='paused') return {t:'На паузе: превышен лимит тарифа', c:'var(--warn)'};
  if(s.status==='hidden') return {t:'Скрыта после жалоб', c:'var(--dg)'};
  return {t:'Заблокирована', c:'var(--dg)'};
}

function cabView(){
  var v = view;
  if(!isRegistered()){
    app.innerHTML = '<h1 class="h1" style="margin-top:28px">Кабинет</h1>'+
      '<div class="card"><div style="font-size:20px;font-weight:700;margin-bottom:8px">Станьте мастером на Уустары бул</div>'+
      '<div class="muted" style="font-size:15px;line-height:1.5">Бесплатно: 2 направления, в каждом до 5 услуг и 10 фото. Новым мастерам 3 месяца Про бесплатно: до 5 направлений, услуги без лимита, до 30 фото, статистика.</div></div>'+
      '<button type="button" class="btn pr" id="lg">Войти по номеру</button>'+
      '<div class="muted" style="font-size:13px;line-height:1.45">Вход нужен и заказчикам — чтобы сохранять мастеров в избранное, оставлять отзывы и жалобы.</div>';
    document.getElementById('lg').onclick = function(){ loginSheet(function(){ render(); }); };
    return;
  }
  app.innerHTML = '<h1 class="h1" style="margin-top:28px">Кабинет</h1><div class="skel" style="height:64px"></div><div class="skel" style="height:160px"></div>';
  loadMine().then(function(m){
    if(view!==v) return;
    v.m = m;
    var p = m.p;
    if(!p){
      app.innerHTML = '<h1 class="h1" style="margin-top:28px">Кабинет</h1>'+
        '<div class="card"><div style="font-size:20px;font-weight:700;margin-bottom:8px">Вы вошли как заказчик</div>'+
        '<div class="muted" style="font-size:15px;line-height:1.5">Чтобы предлагать свои услуги, создайте профиль мастера. Это бесплатно, а после первой публикации — 3 месяца Про в подарок.</div></div>'+
        '<button type="button" class="btn pr" id="np">Создать профиль мастера</button>'+settingsBlock(false);
      document.getElementById('np').onclick = function(){ go({name:'profEdit', isNew:true}); };
      bindSettings(null);
      return;
    }
    var pro = p.pro_until && new Date(p.pro_until) > new Date();
    var active = m.spheres.filter(function(s){return s.status==='active';}).length;
    var proDays = pro ? daysLeft(p.pro_until) : 0;
    var html = '<h1 class="h1" style="margin-top:28px">Кабинет</h1>'+
      '<button type="button" class="row" id="me" style="gap:14px;text-align:left;width:100%">'+
        '<span class="ava" style="width:64px;height:64px;border-radius:16px;font-size:22px;background:'+avColor(p.id)+'">'+esc(initials(p.display_name))+'</span>'+
        '<span class="stack" style="flex:1"><span style="font-size:18px;font-weight:700">'+esc(p.display_name)+'</span><span class="muted" style="font-size:14px">Открыть мой профиль</span></span>'+
        '<span class="muted">'+svg('M9 6l6 6-6 6',20,2)+'</span></button>';
    if(p.deleted_at){
      html += '<div class="warn"><span style="color:var(--dg);flex:none">'+svg(I.warn,22)+'</span><div>Аккаунт будет удалён '+dmy(new Date(new Date(p.deleted_at).getTime()+7*DAY).toISOString())+'. Профиль уже скрыт. <button type="button" id="undel" class="link" style="color:inherit">Отменить удаление</button></div></div>';
    }
    if(pro){
      html += '<div class="card"><div class="row" style="gap:8px"><span class="badge">ПРО</span><span class="muted" style="font-size:14px">до '+dmy(p.pro_until)+'</span></div>'+
        '<div style="font-size:22px;font-weight:700;margin:10px 0">Ещё '+proDays+' '+plural(proDays,'день','дня','дней')+'</div>'+
        '<div class="pbar"><i style="width:'+Math.min(100,Math.round(proDays/90*100))+'%"></i></div>'+
        '<div class="muted" style="font-size:13px;line-height:1.45;margin-top:10px">Без автосписаний. Напомним за 7 дней до конца.</div></div>'+
        '<div class="tiles"><div class="tile"><div class="muted" style="font-size:13px">Просмотры</div><b>'+m.stats.views+'</b><div class="muted" style="font-size:12px">за 30 дней</div></div>'+
        '<div class="tile"><div class="muted" style="font-size:13px">Звонки</div><b>'+m.stats.contacts+'</b><div class="muted" style="font-size:12px">за 30 дней</div></div></div>';
    } else {
      html += '<div class="card"><div class="row" style="gap:8px"><span class="badge">ПРО</span><span class="muted" style="font-size:14px">больше возможностей</span></div>'+
        '<div style="display:flex;flex-direction:column;gap:8px;margin:14px 0;font-size:15px">'+
        ['До 5 направлений вместо 2','Услуги без лимита вместо 5','До 30 фото вместо 10','Карточки продлеваются сами','Статистика просмотров и звонков'].map(function(x){ return '<div class="row" style="gap:10px">'+svg(I.check,18,2.2)+x+'</div>'; }).join('')+
        '</div><div class="muted" style="font-size:13px;margin-bottom:12px">990 ₽ в месяц или 2 490 ₽ за 3 месяца. Без автосписаний. На место в поиске не влияет.'+
        (p.pro_until?'':' <b style="color:var(--fg)">Опубликуйте первое направление — получите 3 месяца Про бесплатно.</b>')+'</div>'+
        '<button type="button" class="btn pr" id="buy" style="height:48px;font-size:16px">Подключить Про</button></div>';
    }
    html += '<section><div class="between" style="align-items:baseline;margin-bottom:4px"><h2 class="h2" style="font-size:20px">Мои сферы деятельности</h2>'+
      '<span class="muted" style="font-size:14px">'+active+' из '+m.lim.spheres+'</span></div>'+
      (m.spheres.length ? m.spheres.map(function(s){
        var stt = sphereState(s, pro), c = catById(s.category_id);
        var sv = (s.services||[]).length, ph = (s.photos||[]).length;
        var meta = sv+' '+plural(sv,'услуга','услуги','услуг')+(pro?'':' из '+(m.lim.services_per_sphere||'∞'))+' · '+ph+' фото'+(pro?'':' из '+m.lim.photos_per_sphere);
        return '<div class="item"><button type="button" class="main" data-sp="'+s.id+'">'+
          '<span class="ava" style="width:52px;height:52px;border-radius:13px;background:var(--sf);color:var(--mu)">'+svg(CAT[c.slug]||I.briefcase,24,1.7)+'</span>'+
          '<span class="stack"><span class="name">'+esc(s.title)+'</span><span class="sub">'+meta+'</span><span class="sub" style="color:'+stt.c+'">'+esc(stt.t)+'</span></span></button>'+
          (stt.renew ? '<button type="button" class="chip" aria-pressed="true" data-pub="'+s.id+'" style="font-weight:600">Продлить</button>'
           : '<button type="button" class="chip" data-sp="'+s.id+'" style="font-weight:600">Изменить</button>')+'</div>';
      }).join('') : '<div class="muted" style="font-size:15px;padding:12px 0">Пока нет ни одного направления.</div>')+
      '</section>'+
      '<button type="button" class="btn sec" id="newSp" style="height:52px;font-size:16px;gap:8px">'+svg('M12 5v14M5 12h14',20,2)+'Новое направление</button>'+
      '<div class="muted" style="font-size:13px;line-height:1.45">Карточка показывается 30 дней. За 2–3 дня до конца напомним — продлить можно в одно нажатие.</div>';
    if(m.reviews.length){
      html += '<section><h2 class="h2" style="font-size:20px;margin-bottom:10px">Отзывы обо мне</h2><div style="display:flex;flex-direction:column;gap:10px">'+
        m.reviews.slice(0, v.allRev?50:3).map(function(x){
          return '<div class="review"><div class="between" style="align-items:baseline"><div style="font-weight:600;font-size:15px">'+esc(x.author_name)+'</div><div class="muted" style="font-size:12px">'+shortDate(x.created_at)+'</div></div>'+
            '<div style="font-size:12px;color:var(--v);margin:2px 0 8px">'+stars(x.rating)+(x.is_hidden?' · скрыт после жалоб':'')+'</div>'+
            (x.body?'<div style="font-size:14px;line-height:1.45;color:var(--v)">'+esc(x.body)+'</div>':'')+
            (x.reply?'<div class="reply"><div style="font-size:13px;font-weight:600">Ваш ответ</div><div class="muted" style="font-size:13px">'+esc(x.reply)+'</div></div>':'')+
            '<button type="button" class="link" data-reply="'+x.id+'" style="margin-top:10px;font-size:14px">'+(x.reply?'Изменить ответ':'Ответить')+'</button></div>';
        }).join('')+'</div>'+
        (m.reviews.length>3&&!v.allRev?'<button type="button" class="wide" id="allRev" style="margin-top:10px">Все отзывы ('+m.reviews.length+')</button>':'')+'</section>';
    }
    html += settingsBlock(true);
    app.innerHTML = html;
    document.getElementById('me').onclick = function(){ go({name:'profile', id:p.id, from:'Кабинет', own:true}); };
    var b = document.getElementById('buy'); if(b) b.onclick = function(){ toast('Оплата появится позже. Сейчас Про даётся бесплатно на 3 месяца после первой публикации.'); };
    var ud = document.getElementById('undel'); if(ud) ud.onclick = function(){ sb.rpc('cancel_account_deletion').then(function(){ toast('Удаление отменено'); cabView(); }); };
    var ar = document.getElementById('allRev'); if(ar) ar.onclick = function(){ v.allRev=true; cabView(); };
    document.getElementById('newSp').onclick = function(){ go({name:'sphere', isNew:true}); };
    app.querySelectorAll('[data-sp]').forEach(function(x){ x.onclick = function(){ go({name:'sphere', id:x.getAttribute('data-sp')}); }; });
    app.querySelectorAll('[data-pub]').forEach(function(x){ x.onclick = function(){
      x.disabled = true;
      sb.rpc('publish_sphere',{p_sphere:x.getAttribute('data-pub')}).then(function(r){
        if(r.error){ x.disabled=false; return toast(dbMsg(r.error)); }
        toast('Продлено на 30 дней'); cabView();
      });
    }; });
    app.querySelectorAll('[data-reply]').forEach(function(x){ x.onclick = function(){
      replySheet(m.reviews.find(function(r){return r.id===x.getAttribute('data-reply');}));
    }; });
    bindSettings(p);
  }).catch(function(e){ if(view===v) app.innerHTML = '<h1 class="h1" style="margin-top:28px">Кабинет</h1><div class="empty">'+esc(errText(e))+'</div>'; });
}
function settingsBlock(hasProfile){
  return '<div class="group">'+
    (hasProfile?'<button type="button" class="opt grow" id="editP" style="padding-right:16px">Изменить профиль<span class="muted">'+svg('M9 6l6 6-6 6',18,2)+'</span></button>':'')+
    '<button type="button" class="opt grow" id="outB" style="padding-right:16px">Выйти</button>'+
    '<button type="button" class="opt grow" id="delB" style="padding-right:16px;color:var(--dg)">Удалить аккаунт</button></div>';
}
function bindSettings(p){
  var e = document.getElementById('editP'); if(e) e.onclick = function(){ go({name:'profEdit', p:p}); };
  document.getElementById('outB').onclick = function(){ sb.auth.signOut().then(function(){ toast('Вы вышли'); render(); }); };
  document.getElementById('delB').onclick = function(){
    confirmSheet('Удалить аккаунт?', 'Профиль сразу перестанет показываться, а через 7 дней аккаунт удалится окончательно. Отзывы о мастерах, которые вы оставили, останутся без имени. До этого срока удаление можно отменить в кабинете.', 'Удалить аккаунт', function(){
      sb.rpc('request_account_deletion').then(function(r){ if(r.error) return toast(errText(r.error)); return sb.auth.signOut().then(function(){ toast('Аккаунт будет удалён через 7 дней'); render(); }); });
    });
  };
}

/* ---------- профиль мастера: создание и правка ---------- */
function profEditView(){
  var v = view, p = v.p || {};
  v.kind = v.kind || p.kind || 'person';
  v.travels = v.travels!=null ? v.travels : !!p.travels;
  app.innerHTML =
    '<div class="topbar"><button type="button" class="back" id="bk">'+svg(I.back,22,2)+'Кабинет</button><span class="ttl">'+(v.isNew?'Профиль мастера':'Мой профиль')+'</span><span style="width:60px"></span></div>'+
    '<form id="pf" style="display:flex;flex-direction:column;gap:18px">'+
    '<div class="chips" role="group" aria-label="Кто вы"><button type="button" class="chip" data-kind="person" aria-pressed="'+(v.kind==='person')+'">Частный мастер</button><button type="button" class="chip" data-kind="org" aria-pressed="'+(v.kind==='org')+'">Организация</button></div>'+
    '<label class="field"><span>'+(v.kind==='org'?'Название для объявлений':'Имя и фамилия')+'</span><input id="fn" class="inp" required minlength="2" maxlength="80" value="'+esc(p.display_name||'')+'" placeholder="'+(v.kind==='org'?'Чистый двор':'Иван Петров')+'"></label>'+
    (v.kind==='org'?'<label class="field"><span>Юридическое название (необязательно)</span><input id="fo" class="inp" maxlength="120" value="'+esc(p.org_name||'')+'" placeholder="ИП Захаров А. С."></label>':'')+
    '<label class="field"><span>Город</span><select id="fc" class="inp">'+S.cities.map(function(c){ return '<option value="'+c.id+'"'+((p.city_id||S.city)===c.id?' selected':'')+'>'+esc(c.name)+'</option>'; }).join('')+'</select></label>'+
    '<label class="field"><span>О себе</span><textarea id="fa" class="inp" maxlength="1000" placeholder="Опыт, как работаете, чем отличаетесь">'+esc(p.about||'')+'</textarea></label>'+
    '<div class="group"><div class="grow" style="padding-right:16px"><span class="t" id="trl">Выезжаю по району</span><button type="button" class="sw" role="switch" id="ftr" aria-labelledby="trl" aria-checked="'+v.travels+'"></button></div></div>'+
    (v.travels?'<label class="field"><span>Куда выезжаете (необязательно)</span><input id="ft" class="inp" maxlength="200" value="'+esc(p.travel_note||'')+'" placeholder="Солянка, Токко, по договорённости"></label>':'')+
    (v.isNew?'<label class="check"><input id="fd" type="checkbox"><span>Согласен, чтобы моё имя, телефон и город показывались в объявлениях на Уустары бул</span></label>':'')+
    '<button type="submit" class="btn pr" id="fs">'+(v.isNew?'Создать профиль':'Сохранить')+'</button>'+
    (v.isNew?'':'<div class="muted" style="font-size:13px;line-height:1.45">Телефон в объявлениях — тот, по которому вы вошли. Город можно менять не чаще раза в 30 дней.</div>')+
    '</form>';
  function keep(){ p = Object.assign({}, p, {display_name:val('fn'), org_name:val('fo'), city_id:Number(val('fc')), about:val('fa'), travel_note:val('ft')}); v.p = p; }
  function val(id){ var e=document.getElementById(id); return e?e.value.trim():(id==='fo'?p.org_name:id==='ft'?p.travel_note:''); }
  document.getElementById('bk').onclick = back;
  app.querySelectorAll('[data-kind]').forEach(function(b){ b.onclick = function(){ keep(); v.kind=b.getAttribute('data-kind'); profEditView(); }; });
  document.getElementById('ftr').onclick = function(){ keep(); v.travels=!v.travels; profEditView(); };
  document.getElementById('pf').addEventListener('submit', function(e){
    e.preventDefault(); keep();
    if((p.display_name||'').length<2) return toast('Укажите имя — не короче 2 букв');
    if(v.isNew && !document.getElementById('fd').checked) return toast('Без этого согласия объявления не могут показываться');
    var row = { kind:v.kind, display_name:p.display_name, org_name: v.kind==='org' ? (p.org_name||null) : null, city_id:p.city_id,
      about:p.about||null, travels:v.travels, travel_note: v.travels ? (p.travel_note||null) : null };
    var btn = document.getElementById('fs'); btn.disabled = true;
    var q = v.isNew ? sb.from('profiles').insert(Object.assign({id:uid()}, row)) : sb.from('profiles').update(row).eq('id', uid());
    q.then(function(r){
      if(r.error){ btn.disabled=false; return toast(dbMsg(r.error)||'Не получилось сохранить'); }
      var next = v.isNew ? sb.from('consents').insert({kind:'pd_distribution', doc_version:DOC_VERSION}) : Promise.resolve();
      return next.then(function(){
        toast(v.isNew?'Профиль создан. Добавьте первое направление':'Сохранено');
        S.stack = []; view = v.isNew ? {name:'sphere', isNew:true} : {name:'cab'}; if(v.isNew) S.stack=[{name:'cab'}]; render(); window.scrollTo(0,0);
      });
    });
  });
}

/* ---------- направление (сфера): услуги, фото, публикация ---------- */
function shrink(file){
  return new Promise(function(res, rej){
    var url = URL.createObjectURL(file), img = new Image();
    img.onload = function(){
      var k = Math.min(1, 1600/Math.max(img.naturalWidth, img.naturalHeight));
      var c = document.createElement('canvas'); c.width = Math.round(img.naturalWidth*k); c.height = Math.round(img.naturalHeight*k);
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
      c.toBlob(function(b){ b ? res(b) : rej(new Error('Не удалось обработать фото')); }, 'image/jpeg', 0.82);
    };
    img.onerror = function(){ URL.revokeObjectURL(url); rej(new Error('Не удалось открыть фото. Подойдут JPG и PNG.')); };
    img.src = url;
  });
}
function photoUrl(path){ return SB_URL+'/storage/v1/object/public/photos/'+path; }

function sphereView(){
  var v = view;
  if(v.isNew){
    var cats = S.cats;
    app.innerHTML =
      '<div class="topbar"><button type="button" class="back" id="bk">'+svg(I.back,22,2)+'Кабинет</button><span class="ttl">Новое направление</span><span style="width:60px"></span></div>'+
      '<form id="nf" style="display:flex;flex-direction:column;gap:18px">'+
      '<label class="field"><span>Сфера деятельности</span><select id="nc" class="inp">'+cats.map(function(c){ return '<option value="'+c.id+'">'+esc(c.name)+'</option>'; }).join('')+'</select></label>'+
      '<label class="field"><span>Как назвать направление</span><input id="nt" class="inp" maxlength="60" required value="'+esc(cats[0]?cats[0].name:'')+'"></label>'+
      '<label class="field"><span>Коротко о работе</span><textarea id="nd" class="inp" maxlength="2000" placeholder="Опыт, инструмент, где работаете"></textarea></label>'+
      '<button type="submit" class="btn pr" id="ns">Дальше: услуги и фото</button>'+
      '<div class="muted" style="font-size:13px;line-height:1.45">Направление сохранится черновиком. Опубликовать можно после того, как добавите услуги.</div></form>';
    document.getElementById('bk').onclick = back;
    var nc = document.getElementById('nc'), nt = document.getElementById('nt'), touched = false;
    nt.addEventListener('input', function(){ touched = true; });
    nc.addEventListener('change', function(){ if(!touched) nt.value = catById(Number(nc.value)).name; });
    document.getElementById('nf').addEventListener('submit', function(e){
      e.preventDefault();
      var t = nt.value.trim(); if(t.length<2) return toast('Название — не короче 2 букв');
      var b = document.getElementById('ns'); b.disabled = true;
      sb.from('spheres').insert({profile_id:uid(), category_id:Number(nc.value), title:t, description:document.getElementById('nd').value.trim()||null}).select('id').single().then(function(r){
        if(r.error){ b.disabled=false; return toast(dbMsg(r.error)||'Не получилось сохранить'); }
        view = {name:'sphere', id:r.data.id}; render(); window.scrollTo(0,0);
      });
    });
    return;
  }
  app.innerHTML = '<div class="skel" style="height:44px"></div><div class="skel" style="height:200px"></div>';
  Promise.all([
    sb.from('spheres').select('id,title,description,category_id,status,expires_at,services(id,title,price_from,price_to,unit,sort,is_hidden),photos(id,storage_path,sort,is_hidden)').eq('id', v.id).maybeSingle(),
    sb.from('profiles').select('pro_until').eq('id', uid()).maybeSingle(),
    sb.rpc('profile_limits',{p_profile:uid()})
  ]).then(function(r){
    if(view!==v) return;
    var s = r[0].data; if(!s){ app.innerHTML = '<div class="empty">Направление не найдено.</div>'; return; }
    var pro = r[1].data && r[1].data.pro_until && new Date(r[1].data.pro_until) > new Date();
    var lim = (r[2].data && r[2].data[0]) || {services_per_sphere:5, photos_per_sphere:10};
    var svs = (s.services||[]).sort(function(a,b){return a.sort-b.sort;});
    var phs = (s.photos||[]).sort(function(a,b){return a.sort-b.sort;});
    var stt = sphereState(s, pro);
    var svLimit = lim.services_per_sphere, phLimit = lim.photos_per_sphere;
    app.innerHTML =
      '<div class="topbar"><button type="button" class="back" id="bk">'+svg(I.back,22,2)+'Кабинет</button><span class="ttl">Направление</span><span style="width:60px"></span></div>'+
      '<div style="font-size:14px;color:'+stt.c+'">'+esc(stt.t)+'</div>'+
      '<form id="ef" style="display:flex;flex-direction:column;gap:14px">'+
      '<label class="field"><span>Сфера деятельности</span><select id="ec" class="inp">'+S.cats.map(function(c){ return '<option value="'+c.id+'"'+(c.id===s.category_id?' selected':'')+'>'+esc(c.name)+'</option>'; }).join('')+'</select></label>'+
      '<label class="field"><span>Название</span><input id="et" class="inp" maxlength="60" value="'+esc(s.title)+'"></label>'+
      '<label class="field"><span>Коротко о работе</span><textarea id="ed" class="inp" maxlength="2000" placeholder="Опыт, инструмент, где работаете">'+esc(s.description||'')+'</textarea></label>'+
      '<button type="submit" class="btn sec" id="es" style="height:46px;font-size:15px">Сохранить описание</button></form>'+
      '<section><div class="between" style="align-items:baseline;margin-bottom:8px"><span class="lbl">Услуги и цены</span><span class="muted" style="font-size:12px">'+svs.length+(svLimit?' из '+svLimit+(pro?'':' · в Про без лимита'):' · без лимита')+'</span></div>'+
      '<div class="group">'+svs.map(function(x){
        return '<div class="grow"><span class="t">'+esc(x.title)+(x.is_hidden?' <span class="muted" style="font-size:12px">(скрыта: лимит)</span>':'')+'</span><span class="p">'+price(x)+'</span>'+
          '<button type="button" class="iconbtn" data-dsv="'+x.id+'" aria-label="Убрать «'+esc(x.title)+'»">'+svg('M18 6L6 18M6 6l12 12',18,2)+'</button></div>';
      }).join('')+
      '<form id="af" class="grow" style="flex-wrap:wrap;padding:10px 12px;gap:8px">'+
        '<input id="as" class="inp" style="height:44px;flex:1 1 100%;background:var(--bg)" maxlength="80" placeholder="Услуга, например «Замена смесителя»">'+
        '<input id="ap" class="inp" style="height:44px;flex:1 1 90px;background:var(--bg)" inputmode="numeric" placeholder="Цена от, ₽">'+
        '<input id="au" class="inp" style="height:44px;flex:1 1 120px;background:var(--bg)" maxlength="30" list="units" placeholder="за что">'+
        '<datalist id="units"><option value="за час"><option value="за м²"><option value="за шт."><option value="за выезд"><option value="за машину"><option value="договорная"></datalist>'+
        '<button type="submit" class="chip" aria-pressed="true" style="height:44px;flex:1 1 100%;font-weight:600">Добавить услугу</button></form>'+
      '</div><div class="muted" style="font-size:12px;margin:6px 4px 0">По названиям услуг вас найдут в поиске — например, по слову «бойлер».</div></section>'+
      '<section><div class="between" style="align-items:baseline;margin-bottom:8px"><span class="lbl">Фото работ</span><span class="muted" style="font-size:12px">'+phs.length+' из '+phLimit+(pro?'':' · в Про до 30')+'</span></div>'+
      '<div class="pgrid">'+
        (phs.length<phLimit?'<label class="cell add" for="pf">'+svg('M12 5v14M5 12h14',26,1.8)+'<span id="pfl">Добавить</span></label>':'')+
        phs.map(function(x){ return '<div class="cell"><img loading="lazy" alt="Фото работы" src="'+photoUrl(esc(x.storage_path))+'"><button type="button" class="del" data-dph="'+x.id+'" aria-label="Удалить фото">'+svg('M18 6L6 18M6 6l12 12',16,2.2)+'</button></div>'; }).join('')+
      '</div><input id="pf" type="file" accept="image/*" multiple hidden></section>'+
      '<div style="display:flex;flex-direction:column;gap:10px">'+
        (s.status==='active' ? '<button type="button" class="btn pr" id="pub">Продлить на 30 дней</button><button type="button" class="btn sec" id="unpub">Снять с публикации</button>'
         : (s.status==='hidden'||s.status==='blocked') ? '' : '<button type="button" class="btn pr" id="pub">Опубликовать на 30 дней</button>')+
        '<button type="button" class="btn" id="delS" style="color:var(--dg)">Удалить направление</button></div>'+
      (s.status!=='active'&&s.status!=='hidden'&&s.status!=='blocked' ? '<div class="muted" style="font-size:13px;line-height:1.45">Карточка будет видна 30 дней. За 2–3 дня до конца напомним продлить.</div>' : '');

    function reload(msg){ if(msg) toast(msg); sphereView(); }
    document.getElementById('bk').onclick = function(){ S.stack=[]; go({name:'cab'}, false); };
    var ec = document.getElementById('ec');
    document.getElementById('ef').addEventListener('submit', function(e){
      e.preventDefault();
      var t = document.getElementById('et').value.trim(); if(t.length<2) return toast('Название — не короче 2 букв');
      sb.from('spheres').update({category_id:Number(ec.value), title:t, description:document.getElementById('ed').value.trim()||null}).eq('id', s.id)
        .then(function(r){ if(r.error) return toast(dbMsg(r.error)); toast('Сохранено'); });
    });
    document.getElementById('af').addEventListener('submit', function(e){
      e.preventDefault();
      var t = document.getElementById('as').value.trim(); if(t.length<2) return toast('Напишите название услуги');
      var pr = document.getElementById('ap').value.replace(/\D/g,''); var u = document.getElementById('au').value.trim();
      sb.from('services').insert({sphere_id:s.id, title:t, price_from: pr?Number(pr):null, unit:u||null, sort: svs.length ? svs[svs.length-1].sort+1 : 1})
        .then(function(r){ if(r.error) return toast(dbMsg(r.error)); reload('Услуга добавлена'); });
    });
    app.querySelectorAll('[data-dsv]').forEach(function(b){ b.onclick = function(){
      sb.from('services').delete().eq('id', b.getAttribute('data-dsv')).then(function(r){ if(r.error) return toast(errText(r.error)); reload(); });
    }; });
    var pf = document.getElementById('pf');
    pf.addEventListener('change', function(){
      var files = Array.prototype.slice.call(pf.files||[]).slice(0, Math.max(0, phLimit - phs.length));
      if(!files.length) return;
      var lbl = document.getElementById('pfl'); var done = 0, sort = phs.length ? phs[phs.length-1].sort : 0;
      if(lbl) lbl.textContent = 'Загружаем…';
      files.reduce(function(chain, f){
        return chain.then(function(){
          return shrink(f).then(function(blob){
            var path = uid()+'/'+s.id+'/'+Date.now()+'-'+Math.random().toString(36).slice(2,8)+'.jpg';
            return sb.storage.from('photos').upload(path, blob, {contentType:'image/jpeg'}).then(function(up){
              if(up.error) throw up.error;
              return sb.from('photos').insert({sphere_id:s.id, storage_path:path, sort: ++sort}).then(function(r){
                if(r.error){ sb.storage.from('photos').remove([path]); throw r.error; }
                done++; if(lbl) lbl.textContent = 'Загружено '+done+' из '+files.length;
              });
            });
          });
        });
      }, Promise.resolve()).then(function(){ reload('Фото добавлены'); }, function(err){ toast(dbMsg(err)||'Не получилось загрузить фото'); reload(); });
    });
    app.querySelectorAll('[data-dph]').forEach(function(b){ b.onclick = function(){
      var x = phs.find(function(y){return y.id===b.getAttribute('data-dph');});
      sb.from('photos').delete().eq('id', x.id).then(function(r){ if(r.error) return toast(errText(r.error)); sb.storage.from('photos').remove([x.storage_path]); reload(); });
    }; });
    var pub = document.getElementById('pub');
    if(pub) pub.onclick = function(){
      if(!svs.length) return toast('Добавьте хотя бы одну услугу — по ним вас найдут в поиске');
      pub.disabled = true;
      sb.rpc('publish_sphere',{p_sphere:s.id}).then(function(r){
        if(r.error){ pub.disabled=false; return toast(dbMsg(r.error)); }
        reload(s.status==='active' ? 'Продлено на 30 дней' : 'Опубликовано на 30 дней');
      });
    };
    var un = document.getElementById('unpub');
    if(un) un.onclick = function(){ sb.rpc('unpublish_sphere',{p_sphere:s.id}).then(function(r){ if(r.error) return toast(errText(r.error)); reload('Снято с публикации'); }); };
    document.getElementById('delS').onclick = function(){
      confirmSheet('Удалить «'+s.title+'»?', 'Услуги и фото этого направления удалятся. Отзывы о вас останутся в профиле.', 'Удалить', function(){
        var paths = phs.map(function(y){return y.storage_path;});
        sb.from('spheres').delete().eq('id', s.id).then(function(r){
          if(r.error) return toast(errText(r.error));
          if(paths.length) sb.storage.from('photos').remove(paths);
          toast('Направление удалено'); S.stack=[]; go({name:'cab'}, false);
        });
      });
    };
  });
}

/* ---------- отзыв, жалоба, ответ на отзыв ---------- */
var RATE_LBL = ['Плохо','Так себе','Нормально','Хорошо','Отлично'];
function reviewSheet(p){
  var rate = 5;
  var starSvg = function(on){ return '<svg width="38" height="38" viewBox="0 0 24 24" fill="'+(on?'currentColor':'none')+'" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"></path></svg>'; };
  function starsHtml(){ return [1,2,3,4,5].map(function(n){ return '<button type="button" role="radio" aria-checked="'+(n===rate)+'" aria-label="'+n+' из 5" data-r="'+n+'" class="'+(n<=rate?'on':'')+'">'+starSvg(n<=rate)+'</button>'; }).join(''); }
  openSheet('<h2>Отзыв: '+esc(p.display_name)+'</h2>'+
    '<div style="text-align:center;margin:6px 0 14px"><div class="stars" role="radiogroup" aria-label="Оценка" id="st">'+starsHtml()+'</div><div class="muted" id="stl" style="margin-top:4px">'+RATE_LBL[rate-1]+'</div></div>'+
    '<form id="rf2" style="display:flex;flex-direction:column;gap:14px">'+
    '<label class="field"><span>Ваше имя</span><input id="rn" class="inp" maxlength="40" required value="'+esc(store('ub_name')||'')+'" placeholder="Как подписать отзыв"></label>'+
    '<label class="field"><span>Отзыв</span><textarea id="rt" class="inp" maxlength="1000" placeholder="Что делал мастер, уложился ли в срок и цену"></textarea></label>'+
    '<p style="margin:0;font-size:13px">Один отзыв на мастера. Мастер сможет ответить, но не удалить его.</p>'+
    '<button type="submit" class="btn pr" id="rs">Опубликовать отзыв</button></form>',
  function(){
    var st = document.getElementById('st');
    st.addEventListener('click', function(e){ var b=e.target.closest('[data-r]'); if(!b) return; rate=Number(b.getAttribute('data-r')); st.innerHTML=starsHtml(); document.getElementById('stl').textContent=RATE_LBL[rate-1]; });
    document.getElementById('rf2').addEventListener('submit', function(e){
      e.preventDefault();
      var name = document.getElementById('rn').value.trim(); if(!name) return toast('Укажите имя');
      var btn = document.getElementById('rs'); btn.disabled = true;
      sb.from('reviews').insert({profile_id:p.id, author_name:name, rating:rate, body:document.getElementById('rt').value.trim()||null}).then(function(r){
        if(r.error){ btn.disabled=false; return toast(dbMsg(r.error) || 'Вы уже оставили отзыв этому мастеру'); }
        store('ub_name', name); closeSheet(); toast('Спасибо за отзыв!'); if(view.name==='profile') profileView();
      });
    });
  });
}
var REASONS = [['prepayment','Просил предоплату'],['fraud','Не пришёл или обманул'],['rude','Грубость, оскорбления'],['fake','Чужие фото или неправда в профиле'],['spam','Спам или реклама'],['other','Другое']];
function complaintSheet(p){
  var cur = 'prepayment';
  function list(){ return REASONS.map(function(x){ return '<button type="button" class="radio" role="radio" aria-checked="'+(x[0]===cur)+'" data-c="'+x[0]+'"><span class="r"></span>'+x[1]+'</button>'; }).join(''); }
  openSheet('<h2>Жалоба</h2><p>На '+esc(p.display_name)+'. Мастер не узнает, кто пожаловался. Если жалобы приходят от нескольких разных людей, профиль скрывается.</p>'+
    '<div class="group" role="radiogroup" aria-label="Причина" id="rl" style="margin-bottom:14px">'+list()+'</div>'+
    '<label class="field" style="margin-bottom:14px"><span>Подробности (необязательно)</span><textarea id="ct" class="inp" maxlength="500" placeholder="Опишите, что произошло"></textarea></label>'+
    '<button type="button" class="btn dg" id="cs">Отправить жалобу</button>',
  function(){
    var rl = document.getElementById('rl');
    rl.addEventListener('click', function(e){ var b=e.target.closest('[data-c]'); if(!b) return; cur=b.getAttribute('data-c'); rl.innerHTML=list(); });
    document.getElementById('cs').onclick = function(){
      var b = document.getElementById('cs'); b.disabled = true;
      sb.from('complaints').insert({target_type:'profile', target_id:p.id, reason:cur, comment:document.getElementById('ct').value.trim()||null}).then(function(r){
        if(r.error){ b.disabled=false; return toast(dbMsg(r.error) || 'Вы уже отправляли жалобу на этого мастера'); }
        closeSheet(); toast('Жалоба отправлена. Спасибо!');
      });
    };
  });
}
function replySheet(rv){
  openSheet('<h2>Ответ на отзыв</h2><p>'+esc(rv.author_name)+': '+esc(rv.body||stars(rv.rating))+'</p>'+
    '<label class="field" style="margin-bottom:14px"><span>Ваш ответ</span><textarea id="ry" class="inp" maxlength="1000" placeholder="Спасибо за отзыв!">'+esc(rv.reply||'')+'</textarea></label>'+
    '<button type="button" class="btn pr" id="ys">Сохранить ответ</button>',
  function(){
    document.getElementById('ys').onclick = function(){
      var t = document.getElementById('ry').value.trim();
      sb.from('reviews').update({reply: t||null}).eq('id', rv.id).then(function(r){
        if(r.error) return toast(errText(r.error)); closeSheet(); toast('Ответ сохранён'); cabView();
      });
    };
  });
}
