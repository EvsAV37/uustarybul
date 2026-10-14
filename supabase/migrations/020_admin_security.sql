-- 020: управление, этап 2б — защита и журналы (14.10.2026)
-- Журнал входа по звонку (30 дней) и сводка защиты по дням (без IP и номеров),
-- реестр запросов по персональным данным со сроками по 152-ФЗ, журналы для страницы /admin.
-- Сроки хранения приведены к Политике: журнал действий управления — 1 год (п. «Безопасность, жалобы, модерация»).

-- ===== Журнал входа по звонку: одна строка — одна попытка получить код =====
create table if not exists public.login_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  session_key text not null,
  phone text,
  method text not null check (method in ('flash','callback')),
  for_admin boolean not null default false,
  is_test boolean not null default false,
  result text not null check (result in ('sent','ok','wrong','zvonok_error','pow','replay','ip_limit',
                                         'device_limit','phone_limit','busy','not_admin')),
  device text check (char_length(device) <= 40)
);
create index if not exists login_log_created_idx on public.login_log (created_at desc);
create index if not exists login_log_session_idx on public.login_log (session_key, phone, created_at desc);

-- Сводка по дням (Якутск): сколько звонков, входов, отказов защиты, новых гостей — только числа
create table if not exists public.guard_stats (
  day date not null,
  kind text not null check (kind in ('call','guest')),
  outcome text not null,
  n int not null default 0,
  primary key (day, kind, outcome)
);

-- ===== Запросы по персональным данным =====
create table if not exists public.pd_requests (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('access','correct','delete','withdraw','stop','rkn','other')),
  received_on date not null,
  channel text not null default 'email' check (channel in ('email','letter','app','phone','other')),
  user_id uuid references auth.users(id) on delete set null,
  contact text check (char_length(contact) <= 200),
  summary text check (char_length(summary) <= 1000),
  due_on date not null,
  extended_at timestamptz,
  done_at timestamptz,
  done_note text check (char_length(done_note) <= 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists pd_requests_open_idx on public.pd_requests (due_on) where done_at is null;

alter table public.login_log enable row level security;
alter table public.guard_stats enable row level security;
alter table public.pd_requests enable row level security;
revoke all on public.login_log, public.guard_stats, public.pd_requests from anon, authenticated;

-- ===== Для verify-phone (только сервер) =====
create or replace function public.guard_note(p_kind text, p_outcome text, p_session text default null, p_phone text default null,
                                             p_method text default null, p_admin boolean default false,
                                             p_test boolean default false, p_device text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_kind not in ('call','guest') or coalesce(p_outcome, '') !~ '^[a-z_]{2,20}$' then return; end if;
  insert into public.guard_stats (day, kind, outcome, n)
  values ((now() at time zone 'Asia/Yakutsk')::date, p_kind, p_outcome, 1)
  on conflict (day, kind, outcome) do update set n = public.guard_stats.n + 1;
  if p_kind = 'call' and p_method in ('flash','callback') and p_session is not null then
    insert into public.login_log (session_key, phone, method, for_admin, is_test, result, device)
    values (p_session, p_phone, p_method, coalesce(p_admin, false), coalesce(p_test, false), p_outcome, left(p_device, 40));
  end if;
end $$;

-- Итог попытки входа: ok / wrong / zvonok_error — последняя попытка этого устройства на этот номер
create or replace function public.guard_result(p_session text, p_phone text, p_result text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_result not in ('ok','wrong','zvonok_error') then return; end if;
  update public.login_log set result = p_result, updated_at = now()
   where id = (select id from public.login_log
                where session_key = p_session and phone = p_phone and result in ('sent','wrong')
                  and created_at > now() - interval '1 hour'
                order by created_at desc limit 1);
  insert into public.guard_stats (day, kind, outcome, n)
  values ((now() at time zone 'Asia/Yakutsk')::date, 'call', p_result, 1)
  on conflict (day, kind, outcome) do update set n = public.guard_stats.n + 1;
end $$;

-- ===== Срок ответа на запрос по ПДн =====
-- Рабочие дни считаются без праздников — срок выходит раньше, не позже (безопасно).
create or replace function public.add_workdays(p_from date, p_n int)
returns date language plpgsql immutable set search_path = '' as $$
declare r date := p_from; k int := 0;
begin
  while k < p_n loop
    r := r + 1;
    if extract(isodow from r) < 6 then k := k + 1; end if;
  end loop;
  return r;
end $$;

-- 152-ФЗ: ст. 20 ч. 1, 2, 4 — 10 рабочих дней (+5 с мотивированным уведомлением); ст. 20 ч. 3 — 7 рабочих;
-- ст. 21 ч. 5 (отзыв согласия) — 30 дней; ст. 10.1 ч. 13 (прекратить распространение) — 3 рабочих дня
create or replace function public.pd_due(p_kind text, p_received date)
returns date language sql immutable set search_path = '' as $$
  select case p_kind
    when 'withdraw' then p_received + 30
    when 'stop' then public.add_workdays(p_received, 3)
    when 'correct' then public.add_workdays(p_received, 7)
    when 'delete' then public.add_workdays(p_received, 7)
    else public.add_workdays(p_received, 10) end
$$;

-- ===== Счётчики для меню (+ срочные запросы по ПДн) =====
create or replace function public.admin_pd_urgent()
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.pd_requests
   where done_at is null and due_on <= (now() at time zone 'Asia/Yakutsk')::date + 2
$$;

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
                     where r.created_at > now() - interval '7 days' and (p_city is null or p.city_id = p_city)),
    'pd_urgent', public.admin_pd_urgent());
end $$;

-- Похоже на ботов: сегодня отказов защиты ≥ 20 и втрое больше, чем в среднем за 14 дней до этого
create or replace function public.admin_guard_alert()
returns jsonb language sql stable security definer set search_path = '' as $$
  with t as (select (now() at time zone 'Asia/Yakutsk')::date d),
  b as (select s.day, sum(s.n) n from public.guard_stats s, t
         where s.outcome in ('pow','replay','ip_limit') and s.day between t.d - 14 and t.d group by 1)
  select jsonb_build_object(
    'today', coalesce((select n from b, t where b.day = t.d), 0),
    'avg', round(coalesce((select sum(n) from b, t where b.day < t.d), 0) / 14.0, 1),
    'on', coalesce((select n from b, t where b.day = t.d), 0) >= 20
          and coalesce((select n from b, t where b.day = t.d), 0)
              >= 3 * greatest(coalesce((select sum(n) from b, t where b.day < t.d), 0) / 14.0, 1))
$$;

-- ===== Обзор: + запросы по ПДн и тревога по ботам в «Системе» =====
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
    'pd_due', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'due_on', r.due_on) order by r.due_on), '[]')
                 from public.pd_requests r where r.done_at is null and r.due_on <= v_today + 2),
    'system', jsonb_build_object(
       'code_calls_today', (select count(*) from public.phone_verify_log
                             where created_at >= v_today::timestamp at time zone 'Asia/Yakutsk'),
       'push_queue', (select count(*) from public.notifications where sent_at is null),
       'push_failed', (select count(*) from public.notifications
                        where push_status = 'failed' and created_at > now() - interval '1 day'),
       'free_pro_until', (select free_pro_until from public.app_settings limit 1),
       'deletions', (select count(*) from public.deletion_requests),
       'pd_open', (select count(*) from public.pd_requests where done_at is null),
       'guard_alert', (public.admin_guard_alert() ->> 'on')::boolean)
  ) into res;
  return res;
end $$;

-- ===== Страница «Защита и журналы» =====
create or replace function public.admin_security()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone 'Asia/Yakutsk')::date; res jsonb;
begin
  perform public.admin_need();
  with g as (select * from public.guard_stats where day >= v_today - 29)
  select jsonb_build_object(
    'today', jsonb_build_object(
      'calls', (select coalesce(sum(n), 0) from g where day = v_today and kind = 'call' and outcome = 'sent'),
      'ok', (select coalesce(sum(n), 0) from g where day = v_today and kind = 'call' and outcome = 'ok'),
      'bots', (select coalesce(sum(n), 0) from g where day = v_today and outcome in ('pow','replay')),
      'guests', (select coalesce(sum(n), 0) from g where day = v_today and kind = 'guest' and outcome = 'ok'),
      'limits', (select coalesce(sum(n), 0) from g where day = v_today
                   and outcome in ('ip_limit','device_limit','phone_limit','busy')),
      'not_admin', (select coalesce(sum(n), 0) from g where day = v_today and outcome = 'not_admin')),
    'chart', (select jsonb_agg(jsonb_build_object(
                'day', d.day,
                'calls', (select coalesce(sum(n), 0) from g where g.day = d.day and kind = 'call' and outcome = 'sent'),
                'ok', (select coalesce(sum(n), 0) from g where g.day = d.day and kind = 'call' and outcome = 'ok'),
                'refused', (select coalesce(sum(n), 0) from g where g.day = d.day
                              and outcome in ('pow','replay','ip_limit','device_limit','phone_limit','busy','not_admin'))) order by d.day)
              from (select (v_today - x)::date as day from generate_series(0, 29) x) d),
    'alert', public.admin_guard_alert(),
    -- дошёл ли звонок: из настоящих (не тестовых) звонков за 7 дней — сколько закончились входом
    'delivery', (select jsonb_build_object('sent', count(*), 'ok', count(*) filter (where result = 'ok'))
                   from public.login_log
                  where not is_test and created_at > now() - interval '7 days'
                    and result in ('sent','ok','wrong','zvonok_error')),
    'deletions', (select coalesce(jsonb_agg(jsonb_build_object(
                     'requested_at', d.requested_at, 'delete_at', d.requested_at + interval '7 days',
                     'phone', public.admin_phone_mask(u.phone), 'name', p.display_name, 'profile_id', p.id)
                   order by d.requested_at), '[]')
                    from public.deletion_requests d
                    left join auth.users u on u.id = d.user_id
                    left join public.profiles p on p.id = d.user_id),
    'pd_open', (select count(*) from public.pd_requests where done_at is null),
    'pd_done', (select count(*) from public.pd_requests where done_at is not null)
  ) into res;
  return res;
end $$;

-- Журналы: logins — вход по звонку; actions — действия администраторов (и вход в управление); phones — просмотры номеров
create or replace function public.admin_journal(p_tab text default 'logins', p_before bigint default null, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); res jsonb;
begin
  perform public.admin_need();
  if p_tab = 'logins' then
    select coalesce(jsonb_agg(x order by x.id desc), '[]') into res from (
      select l.id, l.created_at as at, public.admin_phone_mask(l.phone) as phone, l.method, l.result,
             l.device, l.for_admin, l.is_test
        from public.login_log l
       where p_before is null or l.id < p_before
       order by l.id desc limit v_lim + 1) x;
  elsif p_tab in ('actions','phones') then
    select coalesce(jsonb_agg(x order by x.id desc), '[]') into res from (
      select l.id, l.created_at as at, l.action, l.target_type, l.details,
             public.admin_phone_mask(u.phone) as admin,
             l.profile_id, p.display_name as name
        from public.admin_log l
        left join auth.users u on u.id = l.admin_id
        left join public.profiles p on p.id = l.profile_id
       where (p_before is null or l.id < p_before)
         and case when p_tab = 'phones' then l.action = 'phone_view' else l.action <> 'phone_view' end
       order by l.id desc limit v_lim + 1) x;
  else
    raise exception 'bad_action' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(e order by (e ->> 'id')::bigint desc), '[]')
               from (select e from jsonb_array_elements(res) e order by (e ->> 'id')::bigint desc limit v_lim) z),
    'more', jsonb_array_length(res) > v_lim);
end $$;

-- ===== Реестр запросов по ПДн =====
create or replace function public.admin_pd_list(p_tab text default 'open')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone 'Asia/Yakutsk')::date; res jsonb;
begin
  perform public.admin_need();
  select coalesce(jsonb_agg(x order by x.ord, x.due_on, x.id), '[]') into res from (
    select r.id, r.kind, r.received_on, r.channel, r.contact, r.summary, r.due_on, r.extended_at, r.done_at, r.done_note,
           r.created_at, r.user_id is not null as has_user,
           public.admin_phone_mask(u.phone) as phone,
           p.id as profile_id, p.display_name as name,
           (r.due_on - v_today) as days_left,
           case when r.done_at is null then 0 else 1 end as ord
      from public.pd_requests r
      left join auth.users u on u.id = r.user_id
      left join public.profiles p on p.id = r.user_id
     where case when p_tab = 'done' then r.done_at is not null when p_tab = 'all' then true else r.done_at is null end
     order by ord, r.due_on, r.id limit 200) x;
  return res;
end $$;

-- Создать (p_id null) или изменить запрос. p: kind, received_on, channel, phone (необязательно), contact, summary
create or replace function public.admin_pd_save(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_kind text := p ->> 'kind';
  v_recv date;
  v_channel text := coalesce(nullif(p ->> 'channel', ''), 'email');
  v_contact text := nullif(trim(coalesce(p ->> 'contact', '')), '');
  v_summary text := nullif(trim(coalesce(p ->> 'summary', '')), '');
  v_digits text := regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9]', '', 'g');
  v_uid uuid; v_old public.pd_requests; v_due date; v_id bigint;
begin
  perform public.admin_need(true);
  if v_kind is null or v_kind not in ('access','correct','delete','withdraw','stop','rkn','other') then
    raise exception 'pd_kind' using errcode = 'P0001';
  end if;
  if v_channel not in ('email','letter','app','phone','other') then raise exception 'pd_channel' using errcode = 'P0001'; end if;
  begin v_recv := (p ->> 'received_on')::date;
  exception when others then raise exception 'pd_date' using errcode = 'P0001'; end;
  if v_recv is null or v_recv > (now() at time zone 'Asia/Yakutsk')::date or v_recv < (now() at time zone 'Asia/Yakutsk')::date - 365 then
    raise exception 'pd_date' using errcode = 'P0001';
  end if;
  if char_length(coalesce(v_contact, '')) > 200 or char_length(coalesce(v_summary, '')) > 1000 then
    raise exception 'pd_long' using errcode = 'P0001';
  end if;
  if v_digits <> '' then
    if char_length(v_digits) = 11 and left(v_digits, 1) in ('7','8') then v_digits := '7' || substr(v_digits, 2);
    elsif char_length(v_digits) = 10 then v_digits := '7' || v_digits; end if;
    if v_digits !~ '^7[0-9]{10}$' then raise exception 'pd_phone' using errcode = 'P0001'; end if;
    v_uid := public.find_user_by_phone(v_digits);
  end if;
  if v_kind <> 'rkn' and v_uid is null and v_contact is null then raise exception 'pd_who' using errcode = 'P0001'; end if;

  if p_id is null then
    v_due := public.pd_due(v_kind, v_recv);
    insert into public.pd_requests (kind, received_on, channel, user_id, contact, summary, due_on, created_by)
    values (v_kind, v_recv, v_channel, v_uid, v_contact, v_summary, v_due, auth.uid())
    returning id into v_id;
    perform public.admin_log_add('pd_create', 'pd_request', null, null,
                                 jsonb_build_object('id', v_id, 'kind', v_kind, 'due_on', v_due));
  else
    select * into v_old from public.pd_requests where id = p_id for update;
    if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
    if v_old.done_at is not null then raise exception 'pd_done' using errcode = 'P0001'; end if;
    v_due := public.pd_due(v_kind, v_recv);
    if v_old.extended_at is not null and v_kind in ('access','rkn','other') then v_due := public.add_workdays(v_due, 5); end if;
    update public.pd_requests
       set kind = v_kind, received_on = v_recv, channel = v_channel,
           user_id = case when v_digits = '' then user_id else v_uid end,
           contact = v_contact, summary = v_summary, due_on = v_due,
           extended_at = case when v_kind in ('access','rkn','other') then extended_at end
     where id = p_id;
    v_id := p_id;
    perform public.admin_log_add('pd_update', 'pd_request', null, null,
                                 jsonb_build_object('id', v_id, 'kind', v_kind, 'due_on', v_due,
                                                    'old_due_on', v_old.due_on));
  end if;
  return jsonb_build_object('id', v_id, 'due_on', v_due, 'user_found', v_uid is not null);
end $$;

-- Продлить на 5 рабочих дней (только сведения, запрос РКН, прочее; один раз) — мотивированное уведомление отправляет владелец
create or replace function public.admin_pd_extend(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.pd_requests;
begin
  perform public.admin_need(true);
  select * into r from public.pd_requests where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if r.done_at is not null then raise exception 'pd_done' using errcode = 'P0001'; end if;
  if r.kind not in ('access','rkn','other') then raise exception 'pd_no_extend' using errcode = 'P0001'; end if;
  if r.extended_at is not null then raise exception 'pd_extended' using errcode = 'P0001'; end if;
  if r.due_on < (now() at time zone 'Asia/Yakutsk')::date then raise exception 'pd_overdue' using errcode = 'P0001'; end if;
  update public.pd_requests set due_on = public.add_workdays(r.due_on, 5), extended_at = now() where id = p_id
  returning * into r;
  perform public.admin_log_add('pd_extend', 'pd_request', null, null, jsonb_build_object('id', p_id, 'due_on', r.due_on));
  return jsonb_build_object('id', p_id, 'due_on', r.due_on);
end $$;

-- Отметить выполненным: что ответили или сделали
create or replace function public.admin_pd_close(p_id bigint, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_note text := nullif(trim(coalesce(p_note, '')), ''); r public.pd_requests;
begin
  perform public.admin_need(true);
  if v_note is null or char_length(v_note) < 3 then raise exception 'pd_note' using errcode = 'P0001'; end if;
  if char_length(v_note) > 1000 then raise exception 'pd_long' using errcode = 'P0001'; end if;
  update public.pd_requests set done_at = now(), done_note = v_note where id = p_id and done_at is null returning * into r;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform public.admin_log_add('pd_close', 'pd_request', null, null,
                               jsonb_build_object('id', p_id, 'kind', r.kind, 'late', r.done_at::date > r.due_on));
  return jsonb_build_object('id', p_id, 'done_at', r.done_at);
end $$;

-- ===== Снятие администратора — тоже в журнал =====
create or replace function public.admin_revoke(p_phone text)
returns text language plpgsql security definer set search_path = '' as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); v_uid uuid;
begin
  if char_length(d) = 11 and left(d, 1) in ('7','8') then d := '7' || substr(d, 2);
  elsif char_length(d) = 10 then d := '7' || d; end if;
  v_uid := public.find_user_by_phone(d);
  delete from public.admins where user_id = v_uid;
  if not found then return 'Такого администратора нет'; end if;
  insert into public.admin_log (admin_id, action) values (v_uid, 'revoke');
  return 'Готово: доступ к управлению снят';
end $$;

-- ===== Чистка: журнал управления — 1 год (как в Политике), остальное — по своим срокам =====
create or replace function public.admin_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from public.search_misses where day < (now() at time zone 'Asia/Yakutsk')::date - 180;
  delete from public.search_stats where day < (now() at time zone 'Asia/Yakutsk')::date - 800;
  delete from public.admin_sessions where expires_at < now() - interval '1 day';
  delete from public.admin_log where created_at < now() - interval '1 year';
$$;

create or replace function public.security_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from public.login_log where created_at < now() - interval '30 days';
  delete from public.guard_stats where day < (now() at time zone 'Asia/Yakutsk')::date - 400;
  delete from public.phone_verify_log where created_at < now() - interval '2 days';
  delete from public.phone_verify_codes where created_at < now() - interval '1 day';
  delete from public.pd_requests where done_at < now() - interval '1 year';  -- Политика: обращения — 1 год после ответа
$$;
select cron.schedule('uustarybul-security-cleanup', '30 0 * * *', 'select public.security_cleanup()');

-- ===== Права =====
revoke execute on function
  public.guard_note(text, text, text, text, text, boolean, boolean, text), public.guard_result(text, text, text),
  public.add_workdays(date, int), public.pd_due(text, date), public.admin_pd_urgent(), public.admin_guard_alert(),
  public.security_cleanup()
  from public, anon, authenticated;
revoke execute on function public.security_cleanup() from service_role;
revoke execute on function public.admin_revoke(text), public.admin_cleanup() from public, anon, authenticated, service_role;
revoke execute on function
  public.admin_security(), public.admin_journal(text, bigint, int), public.admin_pd_list(text),
  public.admin_pd_save(bigint, jsonb), public.admin_pd_extend(bigint), public.admin_pd_close(bigint, text)
  from public, anon;
grant execute on function
  public.admin_security(), public.admin_journal(text, bigint, int), public.admin_pd_list(text),
  public.admin_pd_save(bigint, jsonb), public.admin_pd_extend(bigint), public.admin_pd_close(bigint, text)
  to authenticated;
