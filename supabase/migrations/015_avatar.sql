-- 015 — фото профиля мастера (13.10.2026)
-- Фото лежит в хранилище photos в папке мастера: <id>/avatar-<время>.jpg.
-- База не даёт указать в профиле чужой файл или произвольную строку.
create or replace function public.tg_profiles_before()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if new.avatar_path is not null
     and (tg_op = 'INSERT' or new.avatar_path is distinct from old.avatar_path)
     and new.avatar_path !~ ('^' || new.id::text || '/avatar-[0-9a-z-]+\.jpg$') then
    raise exception 'avatar_path_invalid' using errcode = 'P0001', hint = 'Фото профиля должно лежать в папке мастера';
  end if;
  if tg_op = 'INSERT' then
    new.city_changed_at := null;
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
end $function$;
