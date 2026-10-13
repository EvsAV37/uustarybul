-- 017: защита от ботов без сторонних сервисов (решено 13.10.2026)
-- 1) «Задачка для телефона» (proof-of-work, формат как у ALTCHA): перед звонком с кодом
--    и перед первым номером мастера для гостя. Проверяет функция verify-phone.
-- 2) Лимиты по IP (IP хранится только хешем): звонки с кодом — 15 в час, новые гости — 20 в час.

-- Решённые задачки: одна задачка — одно действие
create table if not exists public.pow_used (
  challenge text primary key,
  created_at timestamptz not null default now()
);
alter table public.pow_used enable row level security;

-- Журнал действий по IP (только хеш IP с секретом сервера)
create table if not exists public.guard_log (
  id bigserial primary key,
  kind text not null check (kind in ('call', 'guest')),
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists guard_log_ip on public.guard_log (ip_hash, kind, created_at);
alter table public.guard_log enable row level security;

-- Гости, прошедшие проверку: только им get_contact выдаёт номер
create table if not exists public.guest_checks (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.guest_checks enable row level security;

revoke all on public.pow_used, public.guard_log, public.guest_checks from anon, authenticated;

-- Задачка ещё не использована + лимит по IP. null — можно, иначе текст для человека
create or replace function public.guard_take(p_kind text, p_ip_hash text, p_challenge text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_max int := case p_kind when 'call' then 15 when 'guest' then 20 else 0 end;
begin
  insert into public.pow_used (challenge) values (p_challenge) on conflict do nothing;
  if not found then
    return 'pow_replay';
  end if;
  if (select count(*) from public.guard_log
       where ip_hash = p_ip_hash and kind = p_kind and created_at > now() - interval '1 hour') >= v_max then
    return case p_kind
      when 'call' then 'С вашей сети сейчас слишком много входов. Попробуйте через час.'
      else 'С вашей сети сейчас слишком много гостей. Попробуйте через час или войдите по номеру.' end;
  end if;
  insert into public.guard_log (kind, ip_hash) values (p_kind, p_ip_hash);
  return null;
end $$;

create or replace function public.guest_mark(p_uid uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.guest_checks (user_id) values (p_uid) on conflict do nothing
$$;

revoke execute on function public.guard_take(text, text, text) from public, anon, authenticated;
revoke execute on function public.guest_mark(uuid) from public, anon, authenticated;

-- Номер мастера: гость — только после проверки
create or replace function public.get_contact(p_profile uuid, p_sphere uuid default null, p_kind public.contact_kind default 'call')
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_anon boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_limit int;
  v_used int;
  v_phone text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = 'P0001';
  end if;
  if v_anon and not exists (select 1 from public.guest_checks where user_id = v_uid) then
    raise exception 'guest_check_required' using errcode = 'P0001';
  end if;
  if not public.profile_is_public(p_profile) and p_profile <> v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  v_limit := case when v_anon then 20 else 50 end;

  if p_profile <> v_uid then
    -- повторный контакт с тем же мастером за сутки лимит не тратит
    if not exists (select 1 from public.contact_events
                   where customer_id = v_uid and profile_id = p_profile
                     and created_at > now() - interval '24 hours') then
      select count(distinct profile_id) into v_used from public.contact_events
      where customer_id = v_uid and created_at > now() - interval '24 hours';
      if v_used >= v_limit then
        raise exception 'daily_limit' using errcode = 'P0001',
          hint = 'Лимит номеров на сегодня исчерпан';
      end if;
    end if;

    insert into public.contact_events (customer_id, profile_id, sphere_id, kind)
    values (v_uid, p_profile, p_sphere, p_kind);

    insert into public.stats_daily (profile_id, day, contacts)
    values (p_profile, (now() at time zone 'Asia/Yakutsk')::date, 1)
    on conflict (profile_id, day) do update set contacts = public.stats_daily.contacts + 1;
  end if;

  select phone into v_phone from public.profile_contacts where profile_id = p_profile;
  return v_phone;
end $$;

-- Чистка старых записей. Supabase от Claude удаление не принимает — выполнить самому в SQL-редакторе:
-- create or replace function public.guard_cleanup()
-- returns void language sql security definer set search_path = '' as $$
--   delete from public.pow_used where created_at < now() - interval '1 day';
--   delete from public.guard_log where created_at < now() - interval '2 days';
-- $$;
-- revoke execute on function public.guard_cleanup() from public, anon, authenticated;
-- select cron.schedule('uustarybul-guard-cleanup', '20 0 * * *', 'select public.guard_cleanup()');
