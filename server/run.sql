-- Проверка защиты и журналов (020) на сервере — всё внутри транзакции с откатом, в журнал только сводка
begin;
select set_config('request.jwt.claims', '', true);
-- журнал входа, как его пишет verify-phone
set local role service_role;
select public.guard_note('call', 'sent', 'check-1', '70000000003', 'flash', false, true, 'проверка');
select public.guard_result('check-1', '70000000003', 'ok');
select public.guard_note('call', 'pow', 'check-2', '70000000003', 'flash', false, true, 'проверка');
select public.guard_note('guest', 'ok');
reset role;
select 'login_log' k, string_agg(result, ', ' order by id) from public.login_log where session_key like 'check-%';
-- временный владелец — демо-мастер (откатится)
insert into public.admins (user_id, role) select id, 'owner' from public.profiles where is_demo order by created_at limit 1;
select set_config('request.jwt.claims', json_build_object('sub', (select id from public.profiles where is_demo order by created_at limit 1),
  'session_id', '00000000-0000-4000-8000-000000000002', 'is_anonymous', false, 'role', 'authenticated')::text, true);
set local role authenticated;
select 'set_pw' k, public.admin_set_password('проверка-пароля-2') ->> 'ok' ok;
select 'security' k, (s -> 'today') ->> 'calls' calls, (s -> 'today') ->> 'bots' bots, jsonb_array_length(s -> 'chart') chart, (s -> 'alert') ->> 'on' alert
  from (select public.admin_security() s) x;
select 'pd_new' k, r ->> 'due_on' due from (select public.admin_pd_save(null, '{"kind":"access","received_on":"2026-10-14","contact":"проверка"}') r) x;
select 'pd_list' k, jsonb_array_length(public.admin_pd_list('open')) open;
select 'journal' k, jsonb_array_length(public.admin_journal('logins', null, 5) -> 'rows') logins,
       jsonb_array_length(public.admin_journal('actions', null, 5) -> 'rows') actions;
select 'overview' k, (public.admin_overview(null, 7) -> 'system') ->> 'pd_open' pd_open, public.admin_badges(null) ->> 'pd_urgent' urgent;
reset role;
select 'anon' k, has_function_privilege('anon', 'public.admin_security()', 'execute') sec,
       has_function_privilege('authenticated', 'public.guard_note(text,text,text,text,text,boolean,boolean,text)', 'execute') note,
       has_table_privilege('authenticated', 'public.login_log', 'select') tbl;
select 'cron' k, count(*) from cron.job where jobname = 'uustarybul-security-cleanup';
rollback;
select 'after_rollback' k, (select count(*) from public.pd_requests) pd, (select count(*) from public.admins) admins;
