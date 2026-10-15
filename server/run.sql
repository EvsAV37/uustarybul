-- Проверка «Настроек» управления (024) и обслуживания (022–023) на сервере — с откатом, в журнал только сводка
begin;
-- временный владелец — тестовый аккаунт +7 000 000-00-01 (его заводит проверка входа при выкладке; откатится)
insert into public.admins (user_id, role, pw_hash) select id, 'owner', 'x' from auth.users where phone = '70000000001';
insert into public.admin_sessions (session_id, user_id, expires_at)
  select '00000000-0000-4000-8000-000000000024', id, now() + interval '10 minutes' from auth.users where phone = '70000000001';
select set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where phone = '70000000001'),
  'session_id', '00000000-0000-4000-8000-000000000024', 'is_anonymous', false, 'role', 'authenticated')::text, true);
set local role authenticated;
select 'settings' k, s -> 'demo' demo, s -> 'test_accounts' test_accounts, jsonb_array_length(s -> 'admins') admins,
       jsonb_array_length(s -> 'consents') consent_rows, (s -> 'ops' -> 'backup' ->> 'ok_at') is not null backup_seen,
       (s -> 'ops' -> 'watch' ->> 'checked_at') is not null watch_seen
  from (select public.admin_settings() s) x;
select 'overview_system' k, (o -> 'system' ? 'backup') backup, (o -> 'system' ? 'watch') watch, (o -> 'system' ? 'push_queue') core
  from (select public.admin_overview(null, 7) o) x;
select 'demo_purge' k, public.admin_demo_purge('УДАЛИТЬ') r;
-- тестовый номер — администратор: выключить тестовые номера должно быть нельзя
do $$ begin perform public.admin_test_logins_off(); raise notice 'tests_off: ПРОШЛО — ошибка';
exception when others then raise notice 'tests_off: отказ, как и нужно (%)', sqlerrm; end $$;
do $$ begin perform public.admin_demo_purge('удалить'); raise notice 'demo word: ПРОШЛО — ошибка';
exception when others then raise notice 'demo word: отказ, как и нужно'; end $$;
reset role;
select 'after' k, (select count(*) from public.profiles where is_demo) demo_left,
       (select test_logins_off is not null from public.app_settings limit 1) flag,
       (select count(*) from public.admin_log where action in ('test_logins_off', 'demo_purge')) logged;
select 'rights' k, has_function_privilege('anon', 'public.admin_demo_purge(text)', 'execute') anon_purge,
       has_function_privilege('authenticated', 'public.ops_watch_report(jsonb)', 'execute') watch_report,
       has_function_privilege('authenticated', 'public.admin_overview_core(int,int)', 'execute') core,
       has_schema_privilege('authenticated', 'ops', 'usage') ops_schema;
select 'watch_state' k, checked_at is not null checked, jsonb_array_length(fails) fails from ops.watch_state;
rollback;
