-- 013. Push-уведомления: тихие часы, очередь отправки, ключи VAPID, отзывы в очередь.

-- Часовой пояс города (тихие часы считаются по городу мастера)
alter table public.cities add column if not exists tz text not null default 'Asia/Yakutsk';

-- Тихие часы — каждый мастер решает сам
alter table public.notify_prefs
  add column if not exists quiet boolean not null default false,
  add column if not exists quiet_from smallint not null default 22 check (quiet_from between 0 and 23),
  add column if not exists quiet_to smallint not null default 8 check (quiet_to between 0 and 23);
grant select (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;
grant insert (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;
grant update (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;

-- Подписки: мёртвые не удаляем, а выключаем
alter table public.push_subscriptions
  add column if not exists disabled_at timestamptz,
  add column if not exists last_ok_at timestamptz,
  add column if not exists fail_count smallint not null default 0;

-- Очередь: чем закончилась отправка
alter table public.notifications
  add column if not exists push_status text,
  add column if not exists push_attempts smallint not null default 0;

-- Тихие часы сейчас?
create or replace function public.in_quiet_hours(p_on boolean, p_from smallint, p_to smallint, p_tz text)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(p_on, false) and p_from is distinct from p_to and (
    case when p_from < p_to
         then extract(hour from now() at time zone p_tz) >= p_from and extract(hour from now() at time zone p_tz) < p_to
         else extract(hour from now() at time zone p_tz) >= p_from or  extract(hour from now() at time zone p_tz) < p_to end)
$$;

-- Новый отзыв → в очередь (имя автора не передаём)
create or replace function public.tg_review_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, kind, payload)
  select new.profile_id, 'new_review', jsonb_build_object('review_id', new.id, 'rating', new.rating)
   where exists (select 1 from auth.users u where u.id = new.profile_id);
  return null;
end $$;
create trigger reviews_notify after insert on public.reviews
  for each row execute function public.tg_review_notify();

-- Разбудить отправщик (асинхронно, после фиксации транзакции)
create or replace function public.push_kick()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://icojobutpjjvsjkizaak.supabase.co/functions/v1/send-push',
    body := '{}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then null;
end $$;

create or replace function public.tg_notifications_kick()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.push_kick();
  return null;
end $$;
create trigger notifications_kick after insert on public.notifications
  for each statement execute function public.tg_notifications_kick();

-- Взять порцию на отправку
create or replace function public.push_take(p_limit int default 200)
returns table (r_nid bigint, r_kind text, r_payload jsonb, r_tz text,
               r_sub bigint, r_endpoint text, r_p256dh text, r_auth text)
language plpgsql security definer set search_path = '' as $$
begin
  -- зависшие «отправляется» (функция упала) — вернуть в очередь
  update public.notifications set sent_at = null, push_status = 'retry'
   where push_status = 'sending' and sent_at < now() - interval '10 minutes' and push_attempts < 3;

  -- не отправляем: устарело, аккаунт удаляется, выключено в настройках, нет устройства
  update public.notifications n set sent_at = now(), push_status = x.st
    from (
      select n2.id, case
        when n2.created_at < now() - interval '3 days' then 'stale'
        when p.deleted_at is not null then 'off'
        when n2.kind in ('sphere_expiring','sphere_expired','pro_ending','trial_ending','trial_started')
             and np.expiry is false then 'off'
        when n2.kind = 'new_review' and np.reviews is false then 'off'
        when not exists (select 1 from public.push_subscriptions s
                          where s.user_id = n2.user_id and s.disabled_at is null) then 'no_device'
      end as st
      from public.notifications n2
      left join public.profiles p on p.id = n2.user_id
      left join public.notify_prefs np on np.user_id = n2.user_id
      where n2.sent_at is null
    ) x
   where x.id = n.id and x.st is not null;

  -- остальное, кроме тихих часов, забираем на отправку
  return query
  with c as (
    update public.notifications n
       set sent_at = now(), push_status = 'sending', push_attempts = n.push_attempts + 1
     where n.id in (
       select n2.id from public.notifications n2
         left join public.profiles p on p.id = n2.user_id
         left join public.cities ci on ci.id = p.city_id
         left join public.notify_prefs np on np.user_id = n2.user_id
        where n2.sent_at is null
          and not public.in_quiet_hours(np.quiet, np.quiet_from, np.quiet_to, coalesce(ci.tz, 'Asia/Yakutsk'))
        order by n2.created_at
        limit p_limit
        for update of n2 skip locked)
    returning n.id, n.user_id, n.kind, n.payload)
  select c.id, c.kind, c.payload, coalesce(ci.tz, 'Asia/Yakutsk'),
         s.id, s.endpoint, s.p256dh, s.auth
    from c
    left join public.profiles p on p.id = c.user_id
    left join public.cities ci on ci.id = p.city_id
    join public.push_subscriptions s on s.user_id = c.user_id and s.disabled_at is null;
end $$;

-- Итоги отправки
create or replace function public.push_done(p_sent bigint[], p_retry bigint[], p_failed bigint[],
                                            p_dead bigint[], p_ok bigint[], p_bad bigint[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.notifications set push_status = 'sent' where id = any(p_sent);
  update public.notifications set push_status = 'failed' where id = any(p_failed);
  update public.notifications set sent_at = null, push_status = 'retry'
   where id = any(p_retry) and push_attempts < 3;
  update public.notifications set push_status = 'failed'
   where id = any(p_retry) and push_attempts >= 3;
  update public.push_subscriptions set disabled_at = now() where id = any(p_dead);
  update public.push_subscriptions set last_ok_at = now(), fail_count = 0 where id = any(p_ok);
  update public.push_subscriptions set fail_count = fail_count + 1,
         disabled_at = case when fail_count + 1 >= 10 then now() else disabled_at end
   where id = any(p_bad);
end $$;

-- Ключи VAPID: создаёт сама функция отправки при первом запуске, хранятся в vault
create or replace function public.push_vapid_get()
returns table (r_pub text, r_priv text) language sql security definer set search_path = '' as $$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'),
         (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_private')
$$;

create or replace function public.push_vapid_set(p_pub text, p_priv text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from vault.secrets where name = 'push_vapid_private') then return false; end if;
  perform vault.create_secret(p_priv, 'push_vapid_private', 'Уустары бул: закрытый ключ VAPID');
  perform vault.create_secret(p_pub, 'push_vapid_public', 'Уустары бул: открытый ключ VAPID');
  return true;
end $$;

-- Открытый ключ — приложению
create or replace function public.push_public_key()
returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'
$$;

-- Подписка устройства (если на телефоне раньше был другой аккаунт — переходит к текущему)
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_host text;
begin
  if v_uid is null or not public.is_registered() then
    raise exception 'not_registered' using errcode = 'P0001';
  end if;
  v_host := substring(p_endpoint from '^https://([^/:]+)');
  if v_host is null or length(p_endpoint) > 1000 or v_host ~ '^[0-9.]+$' or v_host !~ '\.'
     or length(coalesce(p_p256dh,'')) not between 40 and 200 or length(coalesce(p_auth,'')) not between 10 and 100 then
    raise exception 'bad_subscription' using errcode = 'P0001';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (v_uid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
     set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
         disabled_at = null, fail_count = 0;
  -- не больше 5 устройств на аккаунт: старые выключаем
  update public.push_subscriptions set disabled_at = now()
   where user_id = v_uid and disabled_at is null
     and id not in (select id from public.push_subscriptions
                     where user_id = v_uid and disabled_at is null
                     order by created_at desc limit 5);
end $$;

-- Права
revoke all on function public.push_take(int), public.push_done(bigint[],bigint[],bigint[],bigint[],bigint[],bigint[]),
  public.push_vapid_get(), public.push_vapid_set(text,text), public.push_kick(),
  public.tg_review_notify(), public.tg_notifications_kick()
  from public, anon, authenticated;
grant execute on function public.push_take(int), public.push_done(bigint[],bigint[],bigint[],bigint[],bigint[],bigint[]),
  public.push_vapid_get(), public.push_vapid_set(text,text), public.push_kick() to service_role;
revoke all on function public.save_push_subscription(text,text,text) from public, anon;
grant execute on function public.save_push_subscription(text,text,text) to authenticated;
grant execute on function public.push_public_key() to anon, authenticated;

-- Подстраховка: раз в 10 минут (тихие часы закончились, повторы)
select cron.schedule('uustarybul-push', '*/10 * * * *', 'select public.push_kick()');
