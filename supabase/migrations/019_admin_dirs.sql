-- 019: управление, этап 2а — справочники (сферы, города, лимиты) и дата бесплатного Про (14.10.2026)
-- Менять может только владелец (admin_need(true)). Каждое изменение — в admin_log: что было и что стало.
-- Лимиты тарифов здесь только показываются: они записаны в Соглашении и оферте и меняются вместе с документами.
-- Дату бесплатного Про можно только сдвинуть позже (оферта, п. 3.6: «Исполнитель вправе продлить этот срок»).

-- ===== Часовые пояса России для городов (подпись — город-ориентир) =====
create or replace function public.admin_tz_list()
returns table (name text, label text, utc_offset interval)
language sql stable set search_path = '' as $$
  select z.name, z.label, t.utc_offset
  from (values ('Europe/Kaliningrad','Калининград'), ('Europe/Moscow','Москва'), ('Europe/Samara','Самара'),
               ('Asia/Yekaterinburg','Екатеринбург'), ('Asia/Omsk','Омск'), ('Asia/Novosibirsk','Новосибирск'),
               ('Asia/Krasnoyarsk','Красноярск'), ('Asia/Irkutsk','Иркутск'), ('Asia/Yakutsk','Якутск'),
               ('Asia/Chita','Чита'), ('Asia/Khandyga','Хандыга'), ('Asia/Vladivostok','Владивосток'),
               ('Asia/Ust-Nera','Усть-Нера'), ('Asia/Magadan','Магадан'), ('Asia/Srednekolymsk','Среднеколымск'),
               ('Asia/Kamchatka','Петропавловск-Камчатский'), ('Asia/Anadyr','Анадырь')) z(name, label)
  join pg_catalog.pg_timezone_names t on t.name = z.name
$$;

-- ===== Адрес сферы латиницей (для новой сферы) =====
create or replace function public.slugify(p text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  m jsonb := '{"а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z","и":"i","й":"y","к":"k","л":"l","м":"m","н":"n",
              "о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"h","ц":"ts","ч":"ch","ш":"sh","щ":"shch","ъ":"","ы":"y","ь":"",
              "э":"e","ю":"yu","я":"ya","ҕ":"g","ҥ":"n","ө":"o","һ":"h","ү":"u"}';
  s text := lower(coalesce(p, '')); r text := ''; c text;
begin
  foreach c in array regexp_split_to_array(s, '') loop
    r := r || coalesce(m ->> c, c);
  end loop;
  r := trim(both '-' from regexp_replace(r, '[^a-z0-9]+', '-', 'g'));
  return left(nullif(r, ''), 40);
end $$;

-- ===== Всё для экрана «Справочники» и карточки даты Про =====
create or replace function public.admin_dirs(p_city int default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_need();
  return jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'slug', c.slug, 'name', c.name, 'name_plural', c.name_plural, 'short_name', c.short_name,
        'grp', c.grp, 'sort', c.sort, 'on_home', c.on_home, 'is_active', c.is_active, 'keywords', c.keywords,
        'hint_service', c.hint_service, 'hint_unit', c.hint_unit, 'hint_query', c.hint_query,
        'spheres', (select count(*) from public.spheres s where s.category_id = c.id),
        'masters', (select count(distinct s.profile_id) from public.spheres s join public.profiles p on p.id = s.profile_id
                     where s.category_id = c.id and s.status = 'active' and p.deleted_at is null
                       and (p_city is null or p.city_id = p_city)))
        order by c.sort, c.id), '[]') from public.categories c),
    'cities', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', ci.id, 'name', ci.name, 'region', ci.region, 'tz', ci.tz, 'sort', ci.sort, 'is_active', ci.is_active,
        'masters', (select count(*) from public.profiles p where p.city_id = ci.id and p.deleted_at is null),
        'active', (select count(*) from public.profiles p where p.city_id = ci.id and p.deleted_at is null
                     and exists (select 1 from public.spheres s where s.profile_id = p.id and s.status = 'active')))
        order by ci.sort, ci.id), '[]') from public.cities ci),
    'tz', (select jsonb_agg(jsonb_build_object('name', t.name, 'label', t.label,
                    'offset', extract(epoch from t.utc_offset)::int / 3600) order by t.utc_offset, t.label)
             from public.admin_tz_list() t),
    'limits', (select jsonb_object_agg(l.plan, jsonb_build_object('spheres', l.spheres,
                 'services', l.services_per_sphere, 'photos', l.photos_per_sphere)) from public.plan_limits l),
    'home_max', 8,
    'free_pro', (select jsonb_build_object('until', a.free_pro_until,
                   'pro_now', (select count(*) from public.profiles p where p.deleted_at is null and p.pro_until = a.free_pro_until))
                 from public.app_settings a where a.id),
    'owner', public.admin_role() = 'owner');
end $$;

-- ===== Сфера: создать (p_id null) или изменить =====
create or replace function public.admin_category_save(p_id int, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.categories; n public.categories;
  v_name text := nullif(regexp_replace(trim(coalesce(p ->> 'name', '')), '\s+', ' ', 'g'), '');
  v_plural text := nullif(regexp_replace(trim(coalesce(p ->> 'name_plural', '')), '\s+', ' ', 'g'), '');
  v_short text := nullif(regexp_replace(trim(coalesce(p ->> 'short_name', '')), '\s+', ' ', 'g'), '');
  v_grp text := nullif(regexp_replace(trim(coalesce(p ->> 'grp', '')), '\s+', ' ', 'g'), '');
  v_sort int; v_home boolean := coalesce((p ->> 'on_home')::boolean, false);
  v_active boolean := coalesce((p ->> 'is_active')::boolean, true);
  v_kw text; v_hs text := nullif(trim(coalesce(p ->> 'hint_service', '')), '');
  v_hu text := nullif(trim(coalesce(p ->> 'hint_unit', '')), '');
  v_hq text := nullif(trim(coalesce(p ->> 'hint_query', '')), '');
  v_slug text; i int := 1; v_changes jsonb := '{}'; k text;
begin
  perform public.admin_need(true);
  begin v_sort := coalesce((p ->> 'sort')::int, 500); exception when others then raise exception 'cat_sort' using errcode = 'P0001'; end;
  -- слова поиска: строчные, без знаков, без повторов
  select coalesce(string_agg(w, ' ' order by min_ord), '') into v_kw from (
    select w, min(ord) min_ord from regexp_split_to_table(lower(coalesce(p ->> 'keywords', '')), '[^a-z0-9а-яёҕҥөһү-]+')
           with ordinality as t(w, ord)
     where char_length(w) between 2 and 30 group by w) x;

  if v_name is null or char_length(v_name) not between 2 and 40 then raise exception 'cat_name' using errcode = 'P0001'; end if;
  if v_plural is null or char_length(v_plural) not between 2 and 60 then raise exception 'cat_plural' using errcode = 'P0001'; end if;
  if char_length(coalesce(v_short, '')) > 20 then raise exception 'cat_short' using errcode = 'P0001'; end if;
  if v_grp is null or char_length(v_grp) not between 2 and 30 then raise exception 'cat_grp' using errcode = 'P0001'; end if;
  if v_sort not between 0 and 9999 then raise exception 'cat_sort' using errcode = 'P0001'; end if;
  if char_length(v_kw) > 600 then raise exception 'cat_keywords' using errcode = 'P0001'; end if;
  if char_length(coalesce(v_hs, '')) > 60 or char_length(coalesce(v_hq, '')) > 60 or char_length(coalesce(v_hu, '')) > 30 then
    raise exception 'cat_hint' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.categories c where lower(c.name) = lower(v_name) and c.id is distinct from p_id) then
    raise exception 'cat_exists' using errcode = 'P0001';
  end if;
  if not v_active then v_home := false; end if;
  if v_home and (select count(*) from public.categories c where c.on_home and c.is_active and c.id is distinct from p_id) >= 8 then
    raise exception 'home_full' using errcode = 'P0001';
  end if;

  if p_id is null then
    v_slug := coalesce(public.slugify(v_name), 'sfera');
    while exists (select 1 from public.categories where slug = v_slug || case when i > 1 then '-' || i else '' end) loop i := i + 1; end loop;
    v_slug := v_slug || case when i > 1 then '-' || i else '' end;
    insert into public.categories (slug, name, name_plural, short_name, grp, sort, on_home, is_active, keywords,
                                   hint_service, hint_unit, hint_query, icon)
    values (v_slug, v_name, v_plural, v_short, v_grp, v_sort, v_home, v_active, v_kw, v_hs, v_hu, v_hq, v_slug)
    returning * into n;
    perform public.admin_log_add('category_create', 'category', null, null,
                                 jsonb_build_object('id', n.id, 'name', n.name, 'grp', n.grp));
    return to_jsonb(n);
  end if;

  select * into o from public.categories where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if o.is_active and not v_active and exists (select 1 from public.spheres s where s.category_id = p_id) then
    raise exception 'cat_in_use' using errcode = 'P0001';
  end if;
  update public.categories set name = v_name, name_plural = v_plural, short_name = v_short, grp = v_grp, sort = v_sort,
         on_home = v_home, is_active = v_active, keywords = v_kw, hint_service = v_hs, hint_unit = v_hu, hint_query = v_hq
   where id = p_id returning * into n;
  for k in select unnest(array['name','name_plural','short_name','grp','sort','on_home','is_active','keywords',
                               'hint_service','hint_unit','hint_query']) loop
    if (to_jsonb(o) -> k) is distinct from (to_jsonb(n) -> k) then
      v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(to_jsonb(o) -> k, to_jsonb(n) -> k));
    end if;
  end loop;
  if v_changes <> '{}' then
    perform public.admin_log_add('category_update', 'category', null, null,
                                 jsonb_build_object('id', n.id, 'name', n.name, 'changes', v_changes));
  end if;
  return to_jsonb(n);
end $$;

-- ===== Город: создать (p_id null) или изменить =====
create or replace function public.admin_city_save(p_id int, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.cities; n public.cities;
  v_name text := nullif(regexp_replace(trim(coalesce(p ->> 'name', '')), '\s+', ' ', 'g'), '');
  v_region text := nullif(regexp_replace(trim(coalesce(p ->> 'region', '')), '\s+', ' ', 'g'), '');
  v_tz text := coalesce(nullif(p ->> 'tz', ''), 'Asia/Yakutsk');
  v_sort int; v_active boolean := coalesce((p ->> 'is_active')::boolean, true);
  v_changes jsonb := '{}'; k text;
begin
  perform public.admin_need(true);
  begin v_sort := coalesce((p ->> 'sort')::int, 100); exception when others then raise exception 'city_sort' using errcode = 'P0001'; end;
  if v_name is null or char_length(v_name) not between 2 and 60 then raise exception 'city_name' using errcode = 'P0001'; end if;
  if v_region is null or char_length(v_region) not between 2 and 80 then raise exception 'city_region' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.admin_tz_list() t where t.name = v_tz) then raise exception 'city_tz' using errcode = 'P0001'; end if;
  if v_sort not between 0 and 9999 then raise exception 'city_sort' using errcode = 'P0001'; end if;
  if exists (select 1 from public.cities c where lower(c.name) = lower(v_name) and lower(c.region) = lower(v_region)
               and c.id is distinct from p_id) then
    raise exception 'city_exists' using errcode = 'P0001';
  end if;

  if p_id is null then
    insert into public.cities (name, region, tz, sort, is_active) values (v_name, v_region, v_tz, v_sort, v_active) returning * into n;
    perform public.admin_log_add('city_create', 'city', null, null, jsonb_build_object('id', n.id, 'name', n.name));
    return to_jsonb(n);
  end if;

  select * into o from public.cities where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if o.is_active and not v_active then
    if exists (select 1 from public.profiles pr where pr.city_id = p_id and pr.deleted_at is null) then
      raise exception 'city_in_use' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.cities c where c.is_active and c.id <> p_id) then
      raise exception 'city_last' using errcode = 'P0001';
    end if;
  end if;
  update public.cities set name = v_name, region = v_region, tz = v_tz, sort = v_sort, is_active = v_active
   where id = p_id returning * into n;
  for k in select unnest(array['name','region','tz','sort','is_active']) loop
    if (to_jsonb(o) -> k) is distinct from (to_jsonb(n) -> k) then
      v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(to_jsonb(o) -> k, to_jsonb(n) -> k));
    end if;
  end loop;
  if v_changes <> '{}' then
    perform public.admin_log_add('city_update', 'city', null, null,
                                 jsonb_build_object('id', n.id, 'name', n.name, 'changes', v_changes));
  end if;
  return to_jsonb(n);
end $$;

-- ===== Дата бесплатного Про: только позже (p_dry — посчитать, ничего не меняя) =====
-- Новая дата — конец дня по Якутску. Про у мастеров переезжает сам (триггер app_settings_changed),
-- дату в странице сайта сервер подменяет сам в течение 5 минут (ub-free-pro-sync).
create or replace function public.admin_free_pro_set(p_date date, p_dry boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_old timestamptz; v_new timestamptz; v_n int;
begin
  perform public.admin_need(true);
  if p_date is null then raise exception 'free_pro_date' using errcode = 'P0001'; end if;
  select free_pro_until into v_old from public.app_settings where id for update;
  v_new := (p_date::text || ' 23:59:59')::timestamp at time zone 'Asia/Yakutsk';
  if v_new <= now() then raise exception 'free_pro_past' using errcode = 'P0001'; end if;
  if v_old is not null and v_new <= v_old then raise exception 'free_pro_earlier' using errcode = 'P0001'; end if;
  if v_new > now() + interval '3 years' then raise exception 'free_pro_far' using errcode = 'P0001'; end if;
  -- как в tg_app_settings_changed
  select count(*) into v_n from public.profiles p
   where p.deleted_at is null and (p.pro_until is null or p.pro_until < v_new or (v_old is not null and p.pro_until = v_old));
  if not p_dry then
    update public.app_settings set free_pro_until = v_new where id;
    perform public.admin_log_add('free_pro_set', 'settings', null, null,
                                 jsonb_build_object('old', v_old, 'new', v_new, 'profiles', v_n));
  end if;
  return jsonb_build_object('old', v_old, 'new', v_new, 'profiles', v_n, 'restart', v_old is null or v_old <= now(), 'saved', not p_dry);
end $$;

-- ===== Права =====
revoke execute on function public.admin_tz_list(), public.slugify(text) from public, anon, authenticated;
revoke execute on function
  public.admin_dirs(int), public.admin_category_save(int, jsonb), public.admin_city_save(int, jsonb),
  public.admin_free_pro_set(date, boolean)
  from public, anon;
grant execute on function
  public.admin_dirs(int), public.admin_category_save(int, jsonb), public.admin_city_save(int, jsonb),
  public.admin_free_pro_set(date, boolean)
  to authenticated;
