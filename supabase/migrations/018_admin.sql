-- 018: админ-панель, этап 1 (14.10.2026)
-- Вход: номер телефона (только номера администраторов) + пароль админки.
-- Права проверяет база: каждая функция admin_* требует открытую админ-сессию (пароль введён в этой сессии входа).
-- Назначить администратора — только в SQL-редакторе: select public.admin_grant('+7 914 000-00-00');
-- Пароль администратор придумывает сам на странице /admin при первом входе.

-- ===== Администраторы, сессии, журнал =====
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','moderator')),
  pw_hash text,
  pw_set_at timestamptz,
  fails smallint not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

-- Пароль введён в этой сессии входа (session_id из токена) — до expires_at
create table if not exists public.admin_sessions (
  session_id uuid primary key,
  user_id uuid not null references public.admins(user_id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table if not exists public.admin_log (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id uuid,
  profile_id uuid references public.profiles(id) on delete set null,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists admin_log_profile_idx on public.admin_log (profile_id, created_at desc);
create index if not exists admin_log_created_idx on public.admin_log (created_at desc);

-- ===== Решения по жалобам, блокировка, причина скрытия отзыва =====
alter table public.complaints
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid references auth.users(id) on delete set null,
  add column if not exists decision text check (decision in ('upheld','rejected'));
create index if not exists complaints_open_idx on public.complaints (target_type, target_id) where resolved_at is null;

alter table public.profiles add column if not exists blocked_at timestamptz;
alter table public.reviews add column if not exists hidden_reason text
  check (hidden_reason in ('complaints','insult','spam'));

-- ===== Поиски: сколько всего и что ищут без результата (только запросы, без пользователей) =====
create table if not exists public.search_stats (
  day date not null,
  city_id int not null references public.cities(id) on delete cascade,
  total int not null default 0,
  misses int not null default 0,
  primary key (day, city_id)
);
create table if not exists public.search_misses (
  day date not null,
  city_id int not null references public.cities(id) on delete cascade,
  query text not null check (char_length(query) between 2 and 60),
  hits int not null default 1,
  primary key (day, city_id, query)
);

alter table public.admins enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.admin_log enable row level security;
alter table public.search_stats enable row level security;
alter table public.search_misses enable row level security;
revoke all on public.admins, public.admin_sessions, public.admin_log, public.search_stats, public.search_misses
  from anon, authenticated;

-- ===== Автоскрытие считает только нерешённые жалобы (после решения админа старые не в счёт) =====
create or replace function public.tg_complaints_autohide()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_cnt int; v_owner uuid;
begin
  select count(distinct author_id) into v_cnt from public.complaints
  where target_type = new.target_type and target_id = new.target_id and resolved_at is null;
  if v_cnt < 3 then return null; end if;

  if new.target_type = 'profile' then
    update public.profiles set is_hidden = true where id = new.target_id and not is_hidden
      returning id into v_owner;
  elsif new.target_type = 'sphere' then
    update public.spheres set status = 'hidden'
      where id = new.target_id and status not in ('hidden','blocked')
      returning profile_id into v_owner;
  elsif new.target_type = 'review' then
    update public.reviews set is_hidden = true, hidden_reason = 'complaints'
      where id = new.target_id and not is_hidden;
  end if;

  if v_owner is not null then
    insert into public.notifications (user_id, kind, payload)
    values (v_owner, 'hidden_by_complaints',
            jsonb_build_object('target_type', new.target_type, 'target_id', new.target_id));
  end if;
  return null;
end $$;

-- ===== Учёт поисков =====
create or replace function public.log_search(p_city int, p_query text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_q text := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g')));
  v_day date := (now() at time zone 'Asia/Yakutsk')::date;
  v_found boolean;
begin
  if char_length(v_q) not between 2 and 60 then return; end if;
  if not exists (select 1 from public.cities where id = p_city) then return; end if;
  v_found := exists (select 1 from public.search_spheres(p_city, null, v_q, 'default', 1, 0));
  insert into public.search_stats (day, city_id, total, misses)
  values (v_day, p_city, 1, case when v_found then 0 else 1 end)
  on conflict (day, city_id) do update
    set total = public.search_stats.total + 1, misses = public.search_stats.misses + excluded.misses;
  if v_found then
    -- подсказки — только из запросов, по которым что-то нашлось
    insert into public.search_queries (city_id, query) values (p_city, v_q)
    on conflict (city_id, query) do update set hits = public.search_queries.hits + 1, last_at = now();
  else
    insert into public.search_misses (day, city_id, query) values (v_day, p_city, v_q)
    on conflict (day, city_id, query) do update set hits = public.search_misses.hits + 1;
  end if;
end $$;

-- ===== Помощники (только внутри функций админки) =====
create or replace function public.admin_phone_mask(p text)
returns text language sql immutable set search_path = '' as $$
  select case when d ~ '^7[0-9]{10}$' then '+7 ' || substr(d, 2, 3) || ' •••-••-' || right(d, 2)
              when d = '' then null else '••' || right(d, 2) end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

create or replace function public.admin_phone_full(p text)
returns text language sql immutable set search_path = '' as $$
  select case when d ~ '^7[0-9]{10}$'
              then '+7 ' || substr(d, 2, 3) || ' ' || substr(d, 5, 3) || '-' || substr(d, 8, 2) || '-' || substr(d, 10, 2)
              else nullif(d, '') end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

-- Роль, если в этой сессии входа введён пароль админки; иначе null
create or replace function public.admin_role()
returns text language sql stable security definer set search_path = '' as $$
  select a.role from public.admins a
  join public.admin_sessions s on s.user_id = a.user_id
  where a.user_id = auth.uid()
    and s.session_id::text = coalesce(auth.jwt() ->> 'session_id', '')
    and s.expires_at > now()
    and a.pw_hash is not null
$$;

create or replace function public.admin_need(p_owner boolean default false)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare r text := public.admin_role();
begin
  if r is null then raise exception 'admin_required' using errcode = 'P0001'; end if;
  if p_owner and r <> 'owner' then raise exception 'admin_owner_required' using errcode = 'P0001'; end if;
  return auth.uid();
end $$;

create or replace function public.admin_log_add(p_action text, p_target_type text, p_target uuid,
                                                p_profile uuid, p_details jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.admin_log (admin_id, action, target_type, target_id, profile_id, details)
  values (auth.uid(), p_action, p_target_type, p_target, p_profile, coalesce(p_details, '{}'));
$$;

-- Чей мастер стоит за жалобой
create or replace function public.complaint_owner(p_type public.complaint_target, p_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'profile' then (select id from public.profiles where id = p_id)
    when 'sphere'  then (select profile_id from public.spheres where id = p_id)
    when 'review'  then (select profile_id from public.reviews where id = p_id) end
$$;

create or replace function public.complaint_target_hidden(p_type public.complaint_target, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(case p_type
    when 'profile' then (select is_hidden from public.profiles where id = p_id)
    when 'sphere'  then (select status in ('hidden','blocked') from public.spheres where id = p_id)
    when 'review'  then (select is_hidden from public.reviews where id = p_id) end, false)
$$;

create or replace function public.complaint_target_title(p_type public.complaint_target, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'profile' then 'Профиль'
    when 'sphere'  then (select title from public.spheres where id = p_id)
    when 'review'  then (select 'Отзыв «' || coalesce(title, left(body, 40), author_name) || '»'
                          from public.reviews where id = p_id) end
$$;

-- Скрыть / вернуть объект; true — если что-то изменилось. Мастеру — уведомление.
create or replace function public.admin_target_set(p_type text, p_id uuid, p_hide boolean, p_reason text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_owner uuid; v_title text;
begin
  if p_type = 'profile' then
    if p_hide then
      update public.profiles set is_hidden = true where id = p_id and not is_hidden returning id into v_owner;
    else
      update public.profiles set is_hidden = false
       where id = p_id and is_hidden and blocked_at is null and deleted_at is null returning id into v_owner;
    end if;
  elsif p_type = 'sphere' then
    if p_hide then
      update public.spheres set status = 'hidden'
       where id = p_id and status not in ('hidden','blocked') returning profile_id, title into v_owner, v_title;
    else
      update public.spheres
         set status = case when published_at is null then 'draft'::public.sphere_status
                           when expires_at > now() then 'active'::public.sphere_status
                           else 'expired'::public.sphere_status end
       where id = p_id and status = 'hidden' returning profile_id, title into v_owner, v_title;
    end if;
  elsif p_type = 'review' then
    if p_hide then
      update public.reviews set is_hidden = true, hidden_reason = coalesce(p_reason, 'complaints')
       where id = p_id and not is_hidden returning profile_id into v_owner;
    else
      update public.reviews set is_hidden = false, hidden_reason = null
       where id = p_id and is_hidden returning profile_id into v_owner;
    end if;
    return v_owner is not null;  -- об отзывах мастеру не пишем
  else
    raise exception 'bad_target' using errcode = 'P0001';
  end if;
  if v_owner is not null then
    insert into public.notifications (user_id, kind, payload)
    values (v_owner, case when p_hide then 'hidden_by_admin' else 'restored' end,
            jsonb_strip_nulls(jsonb_build_object('target_type', p_type, 'target_id', p_id, 'title', v_title)));
  end if;
  return v_owner is not null;
end $$;

-- Закрыть нерешённые жалобы на объект
create or replace function public.admin_resolve_target(p_type public.complaint_target, p_id uuid, p_decision text)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.complaints set resolved_at = now(), resolved_by = auth.uid(), decision = p_decision
   where target_type = p_type and target_id = p_id and resolved_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ===== Вход в админку =====
create or replace function public.admin_state()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when a.user_id is null then jsonb_build_object('admin', false)
    else jsonb_build_object(
      'admin', true, 'role', a.role,
      'has_password', a.pw_hash is not null,
      'unlocked', public.admin_role() is not null,
      'locked_until', case when a.locked_until > now() then a.locked_until end,
      'phone', public.admin_phone_mask(u.phone)) end
  from (select 1) x
  left join public.admins a on a.user_id = auth.uid() and public.is_registered()
  left join auth.users u on u.id = a.user_id
$$;

create or replace function public.admin_open_session(p_uid uuid)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare v_sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid; v_until timestamptz := now() + interval '12 hours';
begin
  if v_sid is null then raise exception 'admin_no_session' using errcode = 'P0001'; end if;
  insert into public.admin_sessions (session_id, user_id, expires_at) values (v_sid, p_uid, v_until)
  on conflict (session_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
  return v_until;
end $$;

-- Ввод пароля. Ошибки не бросаем, а возвращаем — чтобы счётчик неудач сохранился.
create or replace function public.admin_unlock(p_password text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.admins; v_until timestamptz;
begin
  if not public.is_registered() then raise exception 'admin_required' using errcode = 'P0001'; end if;
  select * into a from public.admins where user_id = auth.uid() for update;
  if not found then raise exception 'admin_required' using errcode = 'P0001'; end if;
  if a.pw_hash is null then return jsonb_build_object('ok', false, 'error', 'no_password'); end if;
  if a.locked_until > now() then return jsonb_build_object('ok', false, 'locked_until', a.locked_until); end if;
  if extensions.crypt(coalesce(p_password, ''), a.pw_hash) = a.pw_hash then
    update public.admins set fails = 0, locked_until = null where user_id = a.user_id;
    v_until := public.admin_open_session(a.user_id);
    perform public.admin_log_add('unlock', null, null, null);
    return jsonb_build_object('ok', true, 'role', a.role, 'expires_at', v_until);
  end if;
  if a.fails + 1 >= 5 then
    update public.admins set fails = 0, locked_until = now() + interval '15 minutes' where user_id = a.user_id;
    perform public.admin_log_add('unlock_locked', null, null, null);
    return jsonb_build_object('ok', false, 'locked_until', now() + interval '15 minutes');
  end if;
  update public.admins set fails = a.fails + 1 where user_id = a.user_id;
  perform public.admin_log_add('unlock_failed', null, null, null);
  return jsonb_build_object('ok', false, 'left', 4 - a.fails);
end $$;

-- Первый пароль (после назначения) или смена (нужна открытая админ-сессия и старый пароль)
create or replace function public.admin_set_password(p_new text, p_old text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.admins; v_until timestamptz;
begin
  if not public.is_registered() then raise exception 'admin_required' using errcode = 'P0001'; end if;
  select * into a from public.admins where user_id = auth.uid() for update;
  if not found then raise exception 'admin_required' using errcode = 'P0001'; end if;
  if char_length(coalesce(p_new, '')) < 10 then raise exception 'admin_password_short' using errcode = 'P0001'; end if;
  if a.pw_hash is not null then
    if public.admin_role() is null or extensions.crypt(coalesce(p_old, ''), a.pw_hash) <> a.pw_hash then
      raise exception 'admin_password_wrong' using errcode = 'P0001';
    end if;
  end if;
  update public.admins set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pw_set_at = now(),
         fails = 0, locked_until = null
   where user_id = a.user_id;
  update public.admin_sessions set expires_at = now() where user_id = a.user_id and expires_at > now();
  v_until := public.admin_open_session(a.user_id);
  perform public.admin_log_add('password_set', null, null, null);
  return jsonb_build_object('ok', true, 'role', a.role, 'expires_at', v_until);
end $$;

create or replace function public.admin_lock()
returns void language sql security definer set search_path = '' as $$
  update public.admin_sessions set expires_at = now()
   where user_id = auth.uid() and session_id::text = coalesce(auth.jwt() ->> 'session_id', '') and expires_at > now();
$$;

-- Только для SQL-редактора: назначить администратора (пароль сбрасывается — придумать на /admin)
create or replace function public.admin_grant(p_phone text, p_role text default 'owner')
returns text language plpgsql security definer set search_path = '' as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); v_uid uuid;
begin
  if char_length(d) = 11 and left(d, 1) in ('7','8') then d := '7' || substr(d, 2);
  elsif char_length(d) = 10 then d := '7' || d; end if;
  if d !~ '^7[0-9]{10}$' then raise exception 'Номер: 10 цифр после +7'; end if;
  if p_role not in ('owner','moderator') then raise exception 'Роль: owner или moderator'; end if;
  v_uid := public.find_user_by_phone(d);
  if v_uid is null then
    raise exception 'Сначала войдите с этого номера в приложение: uustarybul.ru → Кабинет → Войти по номеру';
  end if;
  insert into public.admins (user_id, role) values (v_uid, p_role)
  on conflict (user_id) do update set role = excluded.role, pw_hash = null, pw_set_at = null, fails = 0, locked_until = null;
  update public.admin_sessions set expires_at = now() where user_id = v_uid and expires_at > now();
  insert into public.admin_log (admin_id, action, details) values (v_uid, 'grant', jsonb_build_object('role', p_role));
  return 'Готово: ' || public.admin_phone_mask(d) || ' — ' || case p_role when 'owner' then 'владелец' else 'модератор' end
      || '. Откройте uustarybul.ru/admin, войдите по номеру и придумайте пароль.';
end $$;

create or replace function public.admin_revoke(p_phone text)
returns text language plpgsql security definer set search_path = '' as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); v_uid uuid;
begin
  if char_length(d) = 11 and left(d, 1) in ('7','8') then d := '7' || substr(d, 2);
  elsif char_length(d) = 10 then d := '7' || d; end if;
  v_uid := public.find_user_by_phone(d);
  delete from public.admins where user_id = v_uid;
  if not found then return 'Такого администратора нет'; end if;
  return 'Готово: доступ к управлению снят';
end $$;

-- Для verify-phone: звонить с /admin только на номера администраторов
create or replace function public.admin_phone_ok(p_phone text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins a join auth.users u on u.id = a.user_id
                 where u.phone = p_phone and not coalesce(u.is_anonymous, false))
$$;

-- ===== Счётчики для меню =====
create or replace function public.admin_badges(p_city int default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_need();
  return jsonb_build_object(
    'masters', (select count(*) from public.profiles p
                 where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
    'complaints', (select count(distinct o.owner) from (
                     select public.complaint_owner(c.target_type, c.target_id) owner
                       from public.complaints c where c.resolved_at is null) o
                   join public.profiles p on p.id = o.owner
                  where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
    'reviews_new', (select count(*) from public.reviews r join public.profiles p on p.id = r.profile_id
                     where r.created_at > now() - interval '7 days' and (p_city is null or p.city_id = p_city)));
end $$;

-- ===== Обзор =====
create or replace function public.admin_overview(p_city int default null, p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_days int := case when p_days in (1, 7, 30) then p_days else 7 end;
  v_today date := (now() at time zone 'Asia/Yakutsk')::date;
  v_from timestamptz; v_prev timestamptz; v_chart int; res jsonb;
begin
  perform public.admin_need();
  v_from := (v_today - (v_days - 1))::timestamp at time zone 'Asia/Yakutsk';
  v_prev := v_from - make_interval(days => v_days);
  v_chart := greatest(v_days, 7);

  with mp as (select * from public.profiles p where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
  ce as (select ce.created_at from public.contact_events ce join mp on mp.id = ce.profile_id where ce.created_at >= v_prev),
  ss as (select * from public.search_stats s where (p_city is null or s.city_id = p_city)
           and s.day >= v_today - (greatest(v_chart, v_days * 2) - 1))
  select jsonb_build_object(
    'from', v_from, 'days', v_days,
    'masters', (select count(*) from mp where exists (select 1 from public.spheres s where s.profile_id = mp.id and s.status = 'active')),
    'masters_all', (select count(*) from mp),
    'masters_new', (select count(*) from mp where mp.created_at >= v_from),
    'spheres_active', (select count(*) from public.spheres s join mp on mp.id = s.profile_id where s.status = 'active'),
    'contacts', (select count(*) from ce where ce.created_at >= v_from),
    'contacts_prev', (select count(*) from ce where ce.created_at < v_from),
    'searches', (select coalesce(sum(total), 0) from ss where ss.day >= v_today - (v_days - 1)),
    'misses', (select coalesce(sum(misses), 0) from ss where ss.day >= v_today - (v_days - 1)),
    'customers_new', (select count(*) from auth.users u
                       where u.created_at >= v_from and not coalesce(u.is_anonymous, false)
                         and not exists (select 1 from public.profiles p where p.id = u.id)),
    'reviews_new', (select count(*) from public.reviews r join mp on mp.id = r.profile_id where r.created_at >= v_from),
    'complaints_new', (select count(*) from public.complaints c
                        join mp on mp.id = public.complaint_owner(c.target_type, c.target_id) where c.created_at >= v_from),
    'chart', (select jsonb_agg(jsonb_build_object(
                 'day', d.day,
                 'contacts', (select count(*) from ce where (ce.created_at at time zone 'Asia/Yakutsk')::date = d.day),
                 'searches', (select coalesce(sum(total), 0) from ss where ss.day = d.day)) order by d.day)
              from (select (v_today - g)::date as day from generate_series(0, v_chart - 1) g) d),
    'misses_top', (select coalesce(jsonb_agg(jsonb_build_object('query', m.query, 'hits', m.hits) order by m.hits desc, m.query), '[]')
                   from (select query, sum(hits)::int hits from public.search_misses
                          where day >= v_today - (v_days - 1) and (p_city is null or city_id = p_city)
                          group by query order by 2 desc, 1 limit 8) m),
    'system', jsonb_build_object(
       'code_calls_today', (select count(*) from public.phone_verify_log
                             where created_at >= v_today::timestamp at time zone 'Asia/Yakutsk'),
       'push_queue', (select count(*) from public.notifications where sent_at is null),
       'push_failed', (select count(*) from public.notifications
                        where push_status = 'failed' and created_at > now() - interval '1 day'),
       'free_pro_until', (select free_pro_until from public.app_settings limit 1),
       'deletions', (select count(*) from public.deletion_requests))
  ) into res;
  return res;
end $$;

-- ===== Мастера =====
create or replace function public.admin_masters(p_city int default null, p_filter text default 'all',
                                                p_q text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
  v_digits text := regexp_replace(coalesce(p_q, ''), '[^0-9]', '', 'g');
  res jsonb;
begin
  perform public.admin_need();
  if char_length(v_digits) = 11 and left(v_digits, 1) = '8' then v_digits := '7' || substr(v_digits, 2); end if;
  with oc as (
    select public.complaint_owner(c.target_type, c.target_id) as owner, count(*)::int n
      from public.complaints c where c.resolved_at is null group by 1),
  b as (
    select p.id, p.display_name, p.org_name, p.kind, p.avatar_path, p.created_at, p.is_hidden, p.blocked_at,
           p.rating_avg, p.reviews_count, ci.name as city,
           coalesce(pc.phone, u.phone) as phone,
           coalesce(oc.n, 0) as open_c,
           (select coalesce(jsonb_agg(jsonb_build_object('title', s.title, 'status', s.status) order by s.created_at), '[]')
              from public.spheres s where s.profile_id = p.id) as spheres,
           exists (select 1 from public.spheres s where s.profile_id = p.id and s.status = 'active') as has_active,
           exists (select 1 from public.spheres s where s.profile_id = p.id and s.status in ('hidden','blocked')) as has_hidden,
           (select string_agg(lower(s.title), ' ') from public.spheres s where s.profile_id = p.id) as titles,
           (select count(*) from public.contact_events ce where ce.profile_id = p.id
                and ce.created_at > now() - interval '7 days')::int as c7
      from public.profiles p
      join public.cities ci on ci.id = p.city_id
      left join public.profile_contacts pc on pc.profile_id = p.id
      left join auth.users u on u.id = p.id
      left join oc on oc.owner = p.id
     where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
  s as (
    select b.*, case when b.blocked_at is not null then 'blocked'
                     when b.is_hidden or b.has_hidden then 'hidden'
                     when b.open_c > 0 then 'complaints'
                     when b.has_active then 'active' else 'draft' end as st
      from b),
  f as (
    select * from s where
      (p_filter = 'all'
       or (p_filter = 'active' and st in ('active','complaints'))
       or (p_filter = 'hidden' and st = 'hidden')
       or (p_filter = 'blocked' and st = 'blocked')
       or (p_filter = 'drafts' and st = 'draft')
       or (p_filter = 'complaints' and open_c > 0)
       or (p_filter = 'new' and created_at > now() - interval '30 days'))
      and (v_q is null
           or lower(display_name) like '%' || v_q || '%'
           or lower(coalesce(org_name, '')) like '%' || v_q || '%'
           or coalesce(titles, '') like '%' || v_q || '%'
           or (char_length(v_digits) >= 3 and regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%')))
  select jsonb_build_object(
    'counts', (select jsonb_build_object(
        'all', count(*), 'active', count(*) filter (where st in ('active','complaints')),
        'hidden', count(*) filter (where st = 'hidden'), 'blocked', count(*) filter (where st = 'blocked'),
        'drafts', count(*) filter (where st = 'draft'), 'complaints', count(*) filter (where open_c > 0),
        'new', count(*) filter (where created_at > now() - interval '30 days'),
        'spheres_active', (select count(*) from public.spheres sp join s on s.id = sp.profile_id where sp.status = 'active'))
      from s),
    'total', (select count(*) from f),
    'rows', (select coalesce(jsonb_agg(r order by r.ord, r.created_at desc), '[]') from (
        select f.id, f.display_name as name, f.org_name as org, f.kind, f.avatar_path as avatar, f.created_at, f.city,
               public.admin_phone_mask(f.phone) as phone, f.spheres, f.st as status, f.open_c as complaints,
               case when f.reviews_count >= 1 then f.rating_avg end as rating, f.reviews_count as reviews, f.c7 as contacts_7d,
               case f.st when 'hidden' then 0 when 'complaints' then 1 when 'active' then 2 when 'draft' then 3 else 4 end as ord
          from f order by ord, f.created_at desc limit least(greatest(p_limit, 1), 500)) r)
  ) into res;
  return res;
end $$;

create or replace function public.admin_master(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public.admin_need();
  select jsonb_build_object(
    'id', p.id, 'name', p.display_name, 'org', p.org_name, 'kind', p.kind, 'avatar', p.avatar_path,
    'city', ci.name, 'phone', public.admin_phone_mask(coalesce(pc.phone, u.phone)),
    'created_at', p.created_at, 'pro_until', p.pro_until, 'is_hidden', p.is_hidden, 'blocked_at', p.blocked_at,
    'deleted_at', p.deleted_at, 'is_demo', p.is_demo,
    'rating', p.rating_avg, 'reviews', p.reviews_count,
    'views', (select coalesce(sum(views), 0) from public.stats_daily where profile_id = p.id),
    'contacts_7d', (select count(*) from public.contact_events where profile_id = p.id and created_at > now() - interval '7 days'),
    'contacts_30d', (select count(*) from public.contact_events where profile_id = p.id and created_at > now() - interval '30 days'),
    'complaints_open', (select count(*) from public.complaints c where c.resolved_at is null
                          and public.complaint_owner(c.target_type, c.target_id) = p.id),
    'complaints_total', (select count(*) from public.complaints c where public.complaint_owner(c.target_type, c.target_id) = p.id),
    'spheres', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', s.id, 'title', s.title, 'status', s.status, 'expires_at', s.expires_at,
                   'complaints', (select count(*) from public.complaints c
                                   where c.target_type = 'sphere' and c.target_id = s.id and c.resolved_at is null))
                 order by s.created_at), '[]') from public.spheres s where s.profile_id = p.id),
    'history', (select coalesce(jsonb_agg(h order by h.at desc), '[]') from (
        select l.created_at as at, l.action, l.target_type, l.details from public.admin_log l where l.profile_id = p.id
        union all
        select n.created_at, 'auto_hidden', n.payload ->> 'target_type',
               jsonb_build_object('title', public.complaint_target_title((n.payload ->> 'target_type')::public.complaint_target,
                                                                         (n.payload ->> 'target_id')::uuid))
          from public.notifications n where n.user_id = p.id and n.kind = 'hidden_by_complaints'
        union all
        select s.published_at, 'published', 'sphere', jsonb_build_object('title', s.title)
          from public.spheres s where s.profile_id = p.id and s.published_at is not null
        union all
        select p.created_at, 'registered', null, '{}'::jsonb
        order by 1 desc limit 30) h)
  ) into res
  from public.profiles p
  join public.cities ci on ci.id = p.city_id
  left join public.profile_contacts pc on pc.profile_id = p.id
  left join auth.users u on u.id = p.id
  where p.id = p_id;
  if res is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  return res;
end $$;

-- Полный номер — только по кнопке, каждый просмотр в журнал
create or replace function public.admin_master_phone(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  perform public.admin_need();
  select public.admin_phone_full(coalesce(pc.phone, u.phone)) into v
    from public.profiles p
    left join public.profile_contacts pc on pc.profile_id = p.id
    left join auth.users u on u.id = p.id
   where p.id = p_id;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform public.admin_log_add('phone_view', 'profile', p_id, p_id);
  return v;
end $$;

-- Действия с мастером: hide_profile / show_profile / block / unblock / hide_sphere / show_sphere
create or replace function public.admin_master_action(p_id uuid, p_action text, p_sphere uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_changed boolean := false; v_title text; n int := 0; r record;
begin
  perform public.admin_need();
  if not exists (select 1 from public.profiles where id = p_id) then raise exception 'not_found' using errcode = 'P0001'; end if;
  if p_action in ('hide_sphere','show_sphere') then
    select title into v_title from public.spheres where id = p_sphere and profile_id = p_id;
    if v_title is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  end if;

  if p_action = 'hide_profile' then
    v_changed := public.admin_target_set('profile', p_id, true);
    n := public.admin_resolve_target('profile', p_id, 'upheld');
  elsif p_action = 'show_profile' then
    v_changed := public.admin_target_set('profile', p_id, false);
    n := public.admin_resolve_target('profile', p_id, 'rejected');
  elsif p_action = 'hide_sphere' then
    v_changed := public.admin_target_set('sphere', p_sphere, true);
    n := public.admin_resolve_target('sphere', p_sphere, 'upheld');
  elsif p_action = 'show_sphere' then
    v_changed := public.admin_target_set('sphere', p_sphere, false);
    n := public.admin_resolve_target('sphere', p_sphere, 'rejected');
  elsif p_action = 'block' then
    update public.profiles set blocked_at = now(), is_hidden = true where id = p_id and blocked_at is null;
    v_changed := found;
    for r in select c.target_type, c.target_id from public.complaints c
              where c.resolved_at is null and public.complaint_owner(c.target_type, c.target_id) = p_id
              group by 1, 2 loop
      n := n + public.admin_resolve_target(r.target_type, r.target_id, 'upheld');
    end loop;
    if v_changed then
      insert into public.notifications (user_id, kind, payload) values (p_id, 'blocked', '{}');
    end if;
  elsif p_action = 'unblock' then
    update public.profiles set blocked_at = null, is_hidden = false where id = p_id and blocked_at is not null;
    v_changed := found;
    if v_changed then
      insert into public.notifications (user_id, kind, payload)
      values (p_id, 'restored', jsonb_build_object('target_type', 'profile', 'target_id', p_id));
    end if;
  else
    raise exception 'bad_action' using errcode = 'P0001';
  end if;

  if v_changed or n > 0 then
    perform public.admin_log_add(p_action, case when p_sphere is null then 'profile' else 'sphere' end,
                                 coalesce(p_sphere, p_id), p_id,
                                 jsonb_strip_nulls(jsonb_build_object('title', v_title, 'complaints', nullif(n, 0))));
  end if;
  return jsonb_build_object('changed', v_changed, 'resolved', n);
end $$;

-- ===== Жалобы и отзывы =====
create or replace function public.admin_complaints(p_city int default null, p_tab text default 'open')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public.admin_need();
  if p_tab = 'resolved' then
    select coalesce(jsonb_agg(x order by x.resolved_at desc), '[]') into res from (
      select c.id, c.reason, c.comment, c.created_at, c.resolved_at, c.decision, c.target_type,
             public.complaint_target_title(c.target_type, c.target_id) as target_title,
             p.id as profile_id, p.display_name as name, p.avatar_path as avatar
        from public.complaints c
        join public.profiles p on p.id = public.complaint_owner(c.target_type, c.target_id)
       where c.resolved_at is not null and (p_city is null or p.city_id = p_city)
       order by c.resolved_at desc limit 60) x;
    return res;
  end if;

  with oc as (
    select c.*, public.complaint_owner(c.target_type, c.target_id) as owner,
           public.complaint_target_hidden(c.target_type, c.target_id) as t_hidden
      from public.complaints c where c.resolved_at is null),
  per_t as (
    select owner, target_type, target_id, count(distinct author_id)::int as authors, bool_or(t_hidden) as hidden
      from oc group by 1, 2, 3)
  select coalesce(jsonb_agg(g order by g.any_hidden desc, g.max_authors desc, g.last_at desc), '[]') into res
  from (
    select p.id, p.display_name as name, p.avatar_path as avatar, ci.name as city, p.created_at as since,
           p.rating_avg as rating, p.reviews_count as reviews, p.blocked_at,
           (select string_agg(s.title, ', ' order by s.created_at) from public.spheres s where s.profile_id = p.id) as spheres,
           (select bool_or(t.hidden) from per_t t where t.owner = p.id) as any_hidden,
           (select max(t.authors) from per_t t where t.owner = p.id) as max_authors,
           (select max(o.created_at) from oc o where o.owner = p.id) as last_at,
           (select min(o.created_at) from oc o where o.owner = p.id) as first_at,
           (select max(n.created_at) from public.notifications n
             where n.user_id = p.id and n.kind = 'hidden_by_complaints') as hidden_at,
           (select jsonb_agg(jsonb_build_object(
               'id', o.id, 'target_type', o.target_type, 'target_id', o.target_id,
               'target_title', public.complaint_target_title(o.target_type, o.target_id),
               'target_hidden', o.t_hidden,
               'reason', o.reason, 'comment', o.comment, 'created_at', o.created_at,
               'author_tail', right(regexp_replace(coalesce(u.phone, ''), '[^0-9]', '', 'g'), 2),
               'contacted_at', (select max(ce.created_at) from public.contact_events ce
                                 where ce.customer_id = o.author_id and ce.profile_id = p.id and ce.created_at <= o.created_at),
               'same_day', (u.created_at at time zone 'Asia/Yakutsk')::date = (o.created_at at time zone 'Asia/Yakutsk')::date)
               order by o.created_at desc)
              from oc o left join auth.users u on u.id = o.author_id where o.owner = p.id) as items
      from public.profiles p
      join public.cities ci on ci.id = p.city_id
     where p.id in (select owner from oc) and p.deleted_at is null and (p_city is null or p.city_id = p_city)) g;
  return res;
end $$;

-- Решение по жалобам на мастера: restore (вернуть, жалобы отклонены) / uphold (скрыть, жалобы приняты)
-- / dismiss (отклонить все, ничего не менять) / reject_one (отклонить одну жалобу p_complaint)
create or replace function public.admin_complaints_decide(p_profile uuid, p_decision text, p_complaint bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; ch int := 0;
begin
  perform public.admin_need();
  if p_decision = 'reject_one' then
    update public.complaints set resolved_at = now(), resolved_by = auth.uid(), decision = 'rejected'
     where id = p_complaint and resolved_at is null and public.complaint_owner(target_type, target_id) = p_profile;
    get diagnostics n = row_count;
    if n > 0 then perform public.admin_log_add('complaint_rejected', 'profile', p_profile, p_profile); end if;
    return jsonb_build_object('resolved', n);
  end if;
  if p_decision not in ('restore','uphold','dismiss') then raise exception 'bad_action' using errcode = 'P0001'; end if;

  for r in select c.target_type, c.target_id from public.complaints c
            where c.resolved_at is null and public.complaint_owner(c.target_type, c.target_id) = p_profile
            group by 1, 2 loop
    if p_decision = 'restore' then
      if public.admin_target_set(r.target_type::text, r.target_id, false) then ch := ch + 1; end if;
    elsif p_decision = 'uphold' then
      if public.admin_target_set(r.target_type::text, r.target_id, true, 'complaints') then ch := ch + 1; end if;
    end if;
    n := n + public.admin_resolve_target(r.target_type, r.target_id,
                                         case when p_decision = 'uphold' then 'upheld' else 'rejected' end);
  end loop;
  if n > 0 then
    perform public.admin_log_add('complaints_' || p_decision, 'profile', p_profile, p_profile,
                                 jsonb_build_object('complaints', n, 'changed', ch));
  end if;
  return jsonb_build_object('resolved', n, 'changed', ch);
end $$;

create or replace function public.admin_reviews(p_city int default null, p_tab text default 'new')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public.admin_need();
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into res from (
    select r.id, r.title, r.body, r.rating, r.author_name, r.created_at, r.is_hidden, r.hidden_reason, r.reply,
           p.id as profile_id, p.display_name as name
      from public.reviews r join public.profiles p on p.id = r.profile_id
     where (p_city is null or p.city_id = p_city)
       and case when p_tab = 'hidden' then r.is_hidden
                else r.created_at > now() - interval '30 days' end
     order by r.created_at desc limit 100) x;
  return res;
end $$;

-- Скрыть отзыв — только оскорбление или спам; вернуть — любой скрытый
create or replace function public.admin_review_action(p_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_profile uuid; v_changed boolean; n int;
begin
  perform public.admin_need();
  select profile_id into v_profile from public.reviews where id = p_id;
  if v_profile is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if p_action = 'hide' then
    if p_reason not in ('insult','spam') then raise exception 'bad_reason' using errcode = 'P0001'; end if;
    v_changed := public.admin_target_set('review', p_id, true, p_reason);
    n := public.admin_resolve_target('review', p_id, 'upheld');
  elsif p_action = 'show' then
    v_changed := public.admin_target_set('review', p_id, false);
    n := public.admin_resolve_target('review', p_id, 'rejected');
  else
    raise exception 'bad_action' using errcode = 'P0001';
  end if;
  if v_changed or n > 0 then
    perform public.admin_log_add('review_' || p_action, 'review', p_id, v_profile,
                                 jsonb_strip_nulls(jsonb_build_object('reason', p_reason)));
  end if;
  return jsonb_build_object('changed', v_changed, 'resolved', n);
end $$;

-- ===== Чистка =====
create or replace function public.admin_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from public.search_misses where day < (now() at time zone 'Asia/Yakutsk')::date - 180;
  delete from public.search_stats where day < (now() at time zone 'Asia/Yakutsk')::date - 800;
  delete from public.admin_sessions where expires_at < now() - interval '1 day';
  delete from public.admin_log where created_at < now() - interval '3 years';
$$;
select cron.schedule('uustarybul-admin-cleanup', '25 0 * * *', 'select public.admin_cleanup()');

-- ===== Права на функции =====
-- Внутренние: только для других функций, сервера и SQL-редактора
revoke execute on function
  public.admin_phone_mask(text), public.admin_phone_full(text), public.admin_role(), public.admin_need(boolean),
  public.admin_log_add(text, text, uuid, uuid, jsonb), public.complaint_owner(public.complaint_target, uuid),
  public.complaint_target_hidden(public.complaint_target, uuid), public.complaint_target_title(public.complaint_target, uuid),
  public.admin_target_set(text, uuid, boolean, text), public.admin_resolve_target(public.complaint_target, uuid, text),
  public.admin_open_session(uuid), public.admin_grant(text, text), public.admin_revoke(text), public.admin_cleanup()
  from public, anon, authenticated;
revoke execute on function public.admin_grant(text, text), public.admin_revoke(text), public.admin_cleanup() from service_role;
revoke execute on function public.admin_phone_ok(text) from public, anon, authenticated;

-- Для страницы /admin: только вошедшим (каждая проверяет админ-сессию сама)
revoke execute on function
  public.admin_state(), public.admin_unlock(text), public.admin_set_password(text, text), public.admin_lock(),
  public.admin_badges(int), public.admin_overview(int, int), public.admin_masters(int, text, text, int),
  public.admin_master(uuid), public.admin_master_phone(uuid), public.admin_master_action(uuid, text, uuid),
  public.admin_complaints(int, text), public.admin_complaints_decide(uuid, text, bigint),
  public.admin_reviews(int, text), public.admin_review_action(uuid, text, text)
  from public, anon;
grant execute on function
  public.admin_state(), public.admin_unlock(text), public.admin_set_password(text, text), public.admin_lock(),
  public.admin_badges(int), public.admin_overview(int, int), public.admin_masters(int, text, text, int),
  public.admin_master(uuid), public.admin_master_phone(uuid), public.admin_master_action(uuid, text, uuid),
  public.admin_complaints(int, text), public.admin_complaints_decide(uuid, text, bigint),
  public.admin_reviews(int, text), public.admin_review_action(uuid, text, text)
  to authenticated;
