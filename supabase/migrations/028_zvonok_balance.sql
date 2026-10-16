-- Уустары бул — баланс Zvonok (16.10.2026).
-- Раз в час server/ub-zvonok-balance (его зовёт сторож) спрашивает баланс у Zvonok (users/balance) и пишет сюда.
-- Сторож считает сбоем: баланс ниже порога (100 ₽, решение пользователя 16.10) или баланс не узнать 3 часа.
-- Сбой — push администраторам (как остальные сбои сторожа), пополнили — «снова в порядке».
-- В управлении баланс виден в «Системе» на Обзоре и в карточке Zvonok на «Защите».

create table if not exists ops.zvonok_balance (
  id int primary key default 1 check (id = 1),
  balance numeric(12,2),        -- последний полученный баланс, ₽
  ok_at timestamptz,            -- когда он получен
  checked_at timestamptz,       -- последняя попытка
  error text                    -- ошибка последней попытки (без ключа); null — удачно
);
insert into ops.zvonok_balance (id) values (1) on conflict do nothing;

-- Порог в рублях: ниже — push «пополните»
create or replace function public.ops_zvonok_min()
returns numeric language sql immutable as $$ select 100::numeric $$;
revoke execute on function public.ops_zvonok_min() from public, anon, authenticated;

-- Итог запроса баланса: p_error null — удачно (p_balance — сумма), иначе — ошибка (баланс прежний)
create or replace function public.ops_zvonok_balance_set(p_balance numeric, p_error text default null)
returns void language sql security definer set search_path = '' as $$
  update ops.zvonok_balance
     set checked_at = now(),
         balance = case when p_error is null then p_balance else balance end,
         ok_at = case when p_error is null then now() else ok_at end,
         error = left(p_error, 200)
   where id = 1;
$$;
revoke execute on function public.ops_zvonok_balance_set(numeric, text) from public, anon, authenticated;

-- Проверки по базе (из 023) + баланс Zvonok
create or replace function public.ops_watch_db()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f jsonb := '[]'; v_ok timestamptz; v_fail timestamptz; n int; r record; z ops.zvonok_balance;
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

  -- Zvonok: баланс ниже порога; баланс не узнать 3 часа (проверка раз в час — значит, не прошли две подряд)
  select * into z from ops.zvonok_balance where id = 1;
  if z.ok_at is not null and z.ok_at > now() - interval '26 hours' and z.balance < public.ops_zvonok_min() then
    f := f || jsonb_build_object('id', 'zvonok_balance', 'text',
           'баланс Zvonok ' || to_char(z.balance, 'FM999999990') || ' ₽ — пополните, иначе вход по звонку перестанет работать');
  end if;
  if (z.ok_at is null and z.error is not null) or z.ok_at < now() - interval '3 hours' then
    f := f || jsonb_build_object('id', 'zvonok_api', 'text',
           'не удаётся узнать баланс Zvonok' || coalesce(': ' || z.error, ''));
  end if;
  return f;
end $$;
revoke execute on function public.ops_watch_db() from public, anon, authenticated;

-- «Система»: копии базы, сторож (023) + баланс Zvonok
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
                from ops.watch_state where id = 1),
    'zvonok', (select jsonb_build_object('balance', balance, 'ok_at', ok_at, 'checked_at', checked_at,
                                         'error', error, 'min', public.ops_zvonok_min())
                 from ops.zvonok_balance where id = 1)
  )
$$;
revoke execute on function public.ops_status() from public, anon, authenticated;

-- «Защита и журналы» (из 020) + баланс Zvonok для карточки Zvonok
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
    'pd_done', (select count(*) from public.pd_requests where done_at is not null),
    'zvonok', public.ops_status() -> 'zvonok'
  ) into res;
  return res;
end $$;
