-- Уустары бул — сторож (план, шаг 4, 15.10.2026).
-- Каждые 5 минут server/ub-watch проверяет сайт, API, вход, функции, диск, контейнеры и передаёт найденные
-- сбои в ops_watch_report(); сюда же добавляются проверки по базе (копии, задания cron, очередь push, Zvonok).
-- Сбой засчитывается, если повторился в двух проверках подряд (выкладка и короткие перезапуски не тревожат).
-- При новом сбое, раз в 6 часов пока он длится, и когда всё починилось — push администраторам (вид 'watch').

create table if not exists ops.watch_state (
  id int primary key default 1 check (id = 1),
  checked_at timestamptz,
  fails jsonb not null default '[]',     -- подтверждённые сбои: [{id, text}]
  pending jsonb not null default '[]',   -- замеченные один раз
  since timestamptz,                     -- с какого времени есть сбои
  notified_at timestamptz
);
insert into ops.watch_state (id) values (1) on conflict do nothing;

-- Проверки по базе → [{id, text}]
create or replace function public.ops_watch_db()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f jsonb := '[]'; v_ok timestamptz; v_fail timestamptz; n int; r record;
begin
  -- копии базы (ub-backup): была удачная за последние 26 часов, последняя попытка не с ошибкой
  select max(at) filter (where ok), max(at) filter (where not ok) into v_ok, v_fail from ops.log where kind = 'backup';
  if v_ok is null or v_ok < now() - interval '26 hours' then
    f := f || jsonb_build_object('id', 'backup', 'text', 'копии базы не было больше суток');
  elsif v_fail > v_ok then
    f := f || jsonb_build_object('id', 'backup', 'text', 'ошибка копии базы');
  end if;
  select max(at) filter (where ok), max(at) filter (where not ok) into v_ok, v_fail from ops.log where kind = 'restore_test';
  if v_fail is not null and (v_ok is null or v_fail > v_ok) then
    f := f || jsonb_build_object('id', 'restore', 'text', 'копия базы не восстановилась при проверке');
  end if;

  -- задания по расписанию (pg_cron): последний запуск каждого задания не с ошибкой
  if to_regclass('cron.job_run_details') is not null then
    for r in execute $q$
      select j.jobname, d.status from cron.job j
        join lateral (select status from cron.job_run_details x where x.jobid = j.jobid
                       and x.start_time > now() - interval '26 hours' order by x.start_time desc limit 1) d on true
       where j.jobname like 'uustarybul-%' and d.status = 'failed' $q$ loop
      f := f || jsonb_build_object('id', 'cron:' || r.jobname, 'text', 'ошибка задания ' || r.jobname);
    end loop;
    execute $q$ select count(*) from cron.job_run_details x join cron.job j on j.jobid = x.jobid
                 where j.jobname = 'uustarybul-daily' and x.start_time > now() - interval '26 hours' $q$ into n;
    if n = 0 and exists (select 1 from cron.job where jobname = 'uustarybul-daily') then
      f := f || jsonb_build_object('id', 'cron:daily', 'text', 'ежедневное обслуживание не запускалось сутки');
    end if;
  end if;

  -- push: записи, зависшие в отправке, и очередь, которая не уходит (кроме тихих часов — те ждут сами)
  select count(*) into n from public.notifications where push_status = 'sending' and sent_at < now() - interval '30 minutes';
  if n > 0 then f := f || jsonb_build_object('id', 'push_stuck', 'text', 'уведомления зависли при отправке: ' || n); end if;
  select count(*) into n from public.notifications n1
    left join public.profiles p on p.id = n1.user_id
    left join public.cities ci on ci.id = p.city_id
    left join public.notify_prefs np on np.user_id = n1.user_id
   where n1.sent_at is null and n1.created_at < now() - interval '30 minutes'
     and not public.in_quiet_hours(np.quiet, np.quiet_from, np.quiet_to, coalesce(ci.tz, 'Asia/Yakutsk'));
  if n > 0 then f := f || jsonb_build_object('id', 'push_queue', 'text', 'уведомления не уходят больше 30 минут: ' || n); end if;

  -- Zvonok: звонки с кодом не уходят (часто — кончился баланс)
  select count(*) into n from public.login_log
   where result = 'zvonok_error' and not is_test and created_at > now() - interval '1 hour';
  if n >= 3 then
    f := f || jsonb_build_object('id', 'zvonok', 'text', 'Zvonok не звонит (' || n || ' за час) — проверьте баланс');
  end if;
  return f;
end $$;
revoke execute on function public.ops_watch_db() from public, anon, authenticated;

-- Итог проверки от ub-watch: p_fails — сбои, найденные на сервере. Возвращает подтверждённые сбои.
create or replace function public.ops_watch_report(p_fails jsonb default '[]')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  st ops.watch_state; cur jsonb; seen jsonb; conf jsonb; pend jsonb; added jsonb; msg text; title text;
begin
  select * into st from ops.watch_state where id = 1 for update;
  cur := coalesce(p_fails, '[]') || public.ops_watch_db();
  seen := (select coalesce(jsonb_agg(e -> 'id'), '[]') from jsonb_array_elements(st.fails || st.pending) e);
  conf := (select coalesce(jsonb_agg(e), '[]') from jsonb_array_elements(cur) e where seen @> jsonb_build_array(e -> 'id'));
  pend := (select coalesce(jsonb_agg(e), '[]') from jsonb_array_elements(cur) e where not seen @> jsonb_build_array(e -> 'id'));
  added := (select coalesce(jsonb_agg(e), '[]') from jsonb_array_elements(conf) e
             where not (select coalesce(jsonb_agg(x -> 'id'), '[]') from jsonb_array_elements(st.fails) x) @> jsonb_build_array(e -> 'id'));

  msg := (select string_agg(e ->> 'text', '; ') from jsonb_array_elements(conf) e);
  if jsonb_array_length(added) > 0 or (jsonb_array_length(conf) > 0 and st.notified_at < now() - interval '6 hours') then
    title := case when jsonb_array_length(added) > 0 then 'Сбой на сервере' else 'Сбой продолжается' end;
    insert into public.notifications (user_id, kind, payload)
      select a.user_id, 'watch', jsonb_build_object('title', title, 'body', left(msg, 200)) from public.admins a;
    insert into ops.log (kind, ok, detail) values ('watch', false, jsonb_build_object('fails', conf));
    st.notified_at := now();
  elsif jsonb_array_length(conf) = 0 and jsonb_array_length(st.fails) > 0 then
    insert into public.notifications (user_id, kind, payload)
      select a.user_id, 'watch', jsonb_build_object('title', 'Сервер снова в порядке',
             'body', 'Сбой длился с ' || to_char(st.since at time zone 'Asia/Yakutsk', 'DD.MM HH24:MI') || '.')
        from public.admins a;
    insert into ops.log (kind, ok, detail) values ('watch', true, jsonb_build_object('since', st.since));
    st.notified_at := null;
  end if;

  update ops.watch_state set checked_at = now(), fails = conf, pending = pend,
         since = case when jsonb_array_length(conf) = 0 then null else coalesce(st.since, now()) end,
         notified_at = st.notified_at
   where id = 1;
  return conf;
end $$;
revoke execute on function public.ops_watch_report(jsonb) from public, anon, authenticated;

-- «Система»: к копиям базы добавляется сторож
create or replace function public.ops_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'backup', (select jsonb_build_object(
        'ok_at', (select max(at) from ops.log where kind = 'backup' and ok),
        'fail_at', (select max(at) from ops.log where kind = 'backup' and not ok),
        'size', (select (detail ->> 'size')::bigint from ops.log where kind = 'backup' and ok order by at desc limit 1),
        'copies', (select (detail ->> 'copies')::int from ops.log where kind = 'backup' and ok order by at desc limit 1))),
    'restore', (select jsonb_build_object(
        'ok_at', (select max(at) from ops.log where kind = 'restore_test' and ok),
        'fail_at', (select max(at) from ops.log where kind = 'restore_test' and not ok))),
    'watch', (select jsonb_build_object('checked_at', checked_at, 'fails', fails, 'since', since)
                from ops.watch_state where id = 1)
  )
$$;
revoke execute on function public.ops_status() from public, anon, authenticated;
