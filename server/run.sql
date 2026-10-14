-- Проверка управления (018) на сервере — всё внутри транзакции с откатом, в журнал только сводка
begin;
select set_config('request.jwt.claims', '', true);
-- временный админ — демо-мастер (откатится)
insert into public.admins (user_id, role) select id, 'owner' from public.profiles where is_demo order by created_at limit 1;
select set_config('request.jwt.claims', json_build_object('sub', (select id from public.profiles where is_demo order by created_at limit 1),
  'session_id', '00000000-0000-4000-8000-000000000001', 'is_anonymous', false, 'role', 'authenticated')::text, true);
set local role authenticated;
select 'state' k, (public.admin_state() ->> 'admin') admin, (public.admin_state() ->> 'unlocked') unlocked;
select 'set_pw' k, public.admin_set_password('проверка-пароля-1') ->> 'ok' ok;
select 'unlock_bad' k, public.admin_unlock('неверно') ->> 'left' left_tries;
select 'overview' k, o ->> 'masters' masters, o ->> 'spheres_active' spheres, jsonb_array_length(o -> 'chart') chart_days
  from (select public.admin_overview(null, 7) o) x;
select 'masters' k, m -> 'counts' ->> 'all' total, jsonb_array_length(m -> 'rows') rows from (select public.admin_masters(null, 'all', null) m) x;
select 'complaints' k, jsonb_array_length(public.admin_complaints(null, 'open')) open_groups,
       jsonb_array_length(public.admin_reviews(null, 'new')) reviews_30d;
select 'badges' k, public.admin_badges(null) ->> 'masters' masters;
reset role;
-- аноним и обычный пользователь закрыты
set local role anon;
select 'anon_overview' k, has_function_privilege('anon', 'public.admin_overview(int,int)', 'execute') allowed;
reset role;
select 'grant_fn_for_users' k, has_function_privilege('authenticated', 'public.admin_grant(text,text)', 'execute') allowed;
rollback;
select 'admins_after_rollback' k, count(*) from public.admins;
