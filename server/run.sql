-- Проверка справочников и даты Про (019) на сервере — всё внутри транзакции с откатом, в журнал только сводка
begin;
select set_config('request.jwt.claims', '', true);
-- временный владелец — демо-мастер (откатится)
insert into public.admins (user_id, role) select id, 'owner' from public.profiles where is_demo order by created_at limit 1;
select set_config('request.jwt.claims', json_build_object('sub', (select id from public.profiles where is_demo order by created_at limit 1),
  'session_id', '00000000-0000-4000-8000-000000000001', 'is_anonymous', false, 'role', 'authenticated')::text, true);
set local role authenticated;
select 'set_pw' k, public.admin_set_password('проверка-пароля-1') ->> 'ok' ok;
select 'dirs' k, jsonb_array_length(d -> 'categories') cats, jsonb_array_length(d -> 'cities') cities,
       jsonb_array_length(d -> 'tz') tz, d -> 'free_pro' ->> 'pro_now' pro_now
  from (select public.admin_dirs(null) d) x;
select 'new_cat' k, r ->> 'slug' slug, r ->> 'keywords' kw
  from (select public.admin_category_save(null, '{"name":"Проверка сферы","name_plural":"Проверки сферы","grp":"Услуги","sort":9990,"keywords":"Проверка, проверка тест"}') r) x;
select 'new_city' k, r ->> 'tz' tz from (select public.admin_city_save(null, '{"name":"Проверочный","region":"Проверка","tz":"Asia/Yakutsk","sort":9990,"is_active":false}') r) x;
select 'fp_dry' k, r ->> 'profiles' profiles, r ->> 'saved' saved
  from (select public.admin_free_pro_set(((select free_pro_until from public.app_settings) at time zone 'Asia/Yakutsk')::date + 30, true) r) x;
select 'fp_save' k, r ->> 'profiles' profiles
  from (select public.admin_free_pro_set(((select free_pro_until from public.app_settings) at time zone 'Asia/Yakutsk')::date + 30, false) r) x;
reset role;
select 'fp_moved' k, count(*) filter (where pro_until = (select free_pro_until from public.app_settings)) moved, count(*) total
  from public.profiles where deleted_at is null;
select 'log' k, string_agg(action, ', ' order by id) from public.admin_log where action in ('category_create','city_create','free_pro_set');
select 'anon' k, has_function_privilege('anon', 'public.admin_dirs(int)', 'execute') dirs,
       has_function_privilege('anon', 'public.admin_free_pro_set(date,boolean)', 'execute') free_pro;
rollback;
select 'after_rollback' k, (select count(*) from public.admins) admins,
       (select free_pro_until at time zone 'Asia/Yakutsk' from public.app_settings) free_pro,
       (select count(*) from public.categories) cats, (select count(*) from public.cities) cities;
