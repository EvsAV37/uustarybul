-- 016: Про бесплатно для всех мастеров до даты запуска оплаты (решено 13.10.2026: до 7 сентября 2027)
-- Дату можно сдвинуть: update public.app_settings set free_pro_until = '…' where id;
-- — профили с Про «до старой даты» сами переедут на новую.

create table if not exists public.app_settings (
  id boolean primary key default true check (id),
  free_pro_until timestamptz
);
insert into public.app_settings (id, free_pro_until)
values (true, '2027-09-07 23:59:59+09')
on conflict (id) do update set free_pro_until = excluded.free_pro_until;

alter table public.app_settings enable row level security;
create policy app_settings_read on public.app_settings for select using (true);
revoke insert, update, truncate, references, trigger on public.app_settings from anon, authenticated;
grant select on public.app_settings to anon, authenticated;

-- Дата бесплатного Про, если он ещё идёт; иначе null
create or replace function public.free_pro_active_until()
returns timestamptz language sql stable security definer set search_path = '' as $$
  select free_pro_until from public.app_settings where id and free_pro_until > now()
$$;

-- Новый профиль во время бесплатного Про сразу получает Про до этой даты
create or replace function public.tg_profiles_before()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_free timestamptz;
begin
  if new.avatar_path is not null
     and (tg_op = 'INSERT' or new.avatar_path is distinct from old.avatar_path)
     and new.avatar_path !~ ('^' || new.id::text || '/avatar-[0-9a-z-]+\.jpg$') then
    raise exception 'avatar_path_invalid' using errcode = 'P0001', hint = 'Фото профиля должно лежать в папке мастера';
  end if;
  if tg_op = 'INSERT' then
    new.city_changed_at := null;
    v_free := public.free_pro_active_until();
    if v_free is not null and (new.pro_until is null or new.pro_until < v_free) then
      new.pro_until := v_free;
    end if;
    return new;
  end if;
  if new.city_id is distinct from old.city_id then
    if old.city_changed_at is not null and old.city_changed_at > now() - interval '30 days' then
      raise exception 'city_change_too_soon'
        using errcode = 'P0001', hint = 'Город можно менять не чаще раза в 30 дней';
    end if;
    new.city_changed_at := now();
  end if;
  return new;
end $$;

-- Пробные 3 месяца: во время бесплатного Про не прибавляются сверху,
-- а дают «до даты или 3 месяца, что позже»; пробный период при этом считается использованным
create or replace function public.publish_sphere(p_sphere uuid)
returns public.spheres language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.spheres;
  v_limit int;
  v_active int;
  v_phone text;
  v_old timestamptz;
  v_until timestamptz;
begin
  select * into s from public.spheres where id = p_sphere for update;
  if not found or s.profile_id is distinct from v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if s.status in ('hidden','blocked') then
    raise exception 'sphere_blocked' using errcode = 'P0001';
  end if;

  -- 3 месяца Про — один раз на номер телефона (учёт по хешу)
  select phone into v_phone from auth.users where id = v_uid;
  if v_phone is not null and v_phone <> '' then
    insert into public.trial_grants (phone_hash)
    values (encode(extensions.digest('uustarybul:' || v_phone, 'sha256'), 'hex'))
    on conflict do nothing;
    if found then
      select pro_until into v_old from public.profiles where id = v_uid for update;
      if public.free_pro_active_until() is not null then
        v_until := greatest(coalesce(v_old, now()), now() + interval '3 months');
      else
        v_until := greatest(coalesce(v_old, now()), now()) + interval '3 months';
      end if;
      if v_old is null or v_until > v_old then
        update public.profiles set pro_until = v_until where id = v_uid;
        insert into public.notifications (user_id, kind, payload)
        values (v_uid, 'trial_started', jsonb_build_object('pro_until', v_until));
      end if;
    end if;
  end if;

  if s.status <> 'active' then
    select l.spheres into v_limit from public.profile_limits(v_uid) l;
    select count(*) into v_active from public.spheres where profile_id = v_uid and status = 'active';
    if v_active >= v_limit then
      raise exception 'spheres_limit' using errcode = 'P0001',
        hint = 'Лимит активных сфер исчерпан';
    end if;
  end if;

  update public.spheres
     set status = 'active',
         published_at = coalesce(published_at, now()),
         expires_at = now() + interval '30 days',
         reminded_at = null
   where id = p_sphere
   returning * into s;
  return s;
end $$;

-- Сдвиг даты в app_settings переносит Про у тех, у кого он был «до старой даты»
create or replace function public.tg_app_settings_changed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.free_pro_until is distinct from old.free_pro_until and new.free_pro_until > now() then
    update public.profiles
       set pro_until = new.free_pro_until
     where deleted_at is null
       and (pro_until is null or pro_until < new.free_pro_until
            or (old.free_pro_until is not null and pro_until = old.free_pro_until));
  end if;
  return null;
end $$;
create trigger app_settings_changed after update on public.app_settings
  for each row execute function public.tg_app_settings_changed();

-- Напоминание за 30 дней до конца бесплатного Про (за 7 дней шлёт daily_maintenance, вид trial_ending)
create or replace function public.free_pro_notify()
returns void language plpgsql security definer set search_path = '' as $$
declare v_free timestamptz;
begin
  select free_pro_until into v_free from public.app_settings where id;
  if v_free is null or v_free < now() + interval '30 days' or v_free >= now() + interval '31 days' then
    return;
  end if;
  insert into public.notifications (user_id, kind, payload)
  select p.id, 'trial_ending', jsonb_build_object('pro_until', p.pro_until, 'free_for_all', true)
    from public.profiles p
   where p.pro_until = v_free and p.deleted_at is null;
end $$;
revoke execute on function public.free_pro_notify() from public, anon, authenticated;
revoke execute on function public.tg_app_settings_changed() from public, anon, authenticated;

select cron.schedule('uustarybul-free-pro', '8 0 * * *', 'select public.free_pro_notify()');

-- Всем существующим мастерам — Про до даты
update public.profiles
   set pro_until = (select free_pro_until from public.app_settings where id)
 where deleted_at is null
   and (pro_until is null or pro_until < (select free_pro_until from public.app_settings where id));
