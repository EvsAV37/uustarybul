-- Проверка баланса Zvonok (028) на сервере — всё с откатом, суммы условные (настоящий баланс сюда не попадает)
begin;
select 'set low' k, (select count(*) from (select public.ops_zvonok_balance_set(87, null)) x) = 1 ok;
select 'low → сбой' k, public.ops_watch_db() @> '[{"id":"zvonok_balance"}]' fail;
select public.ops_zvonok_balance_set(null, 'Zvonok ответил 403');
select 'ошибка, баланс свежий → нет сбоя' k, not public.ops_watch_db() @> '[{"id":"zvonok_api"}]' ok;
update ops.zvonok_balance set ok_at = now() - interval '4 hours';
select 'ошибка 4 часа → сбой' k, public.ops_watch_db() @> '[{"id":"zvonok_api"}]' fail;
select public.ops_zvonok_balance_set(500, null);
select 'норма → сбоев нет' k, not public.ops_watch_db() @> '[{"id":"zvonok_balance"}]' and not public.ops_watch_db() @> '[{"id":"zvonok_api"}]' ok,
       (public.ops_status() -> 'zvonok' ->> 'min')::int min;
-- «Защита» и Обзор отдают баланс владельцу управления (временная сессия, откатится)
select set_config('ub.uid', (select a.user_id::text from public.admins a where a.role = 'owner' order by a.created_at limit 1), true) is not null owner_found;
insert into public.admin_sessions (session_id, user_id, expires_at)
  values ('00000000-0000-4000-8000-000000000028', current_setting('ub.uid')::uuid, now() + interval '10 minutes');
select set_config('request.jwt.claims', json_build_object('sub', current_setting('ub.uid'), 'role', 'authenticated',
  'is_anonymous', false, 'session_id', '00000000-0000-4000-8000-000000000028')::text, true) is not null claims;
set local role authenticated;
select 'admin_security.zvonok' k, public.admin_security() -> 'zvonok' ? 'balance' ok;
select 'overview.system.zvonok' k, public.admin_overview(null, 7) -> 'system' -> 'zvonok' ? 'min' ok;
do $$ begin perform public.ops_zvonok_balance_set(1, null); raise notice 'клиенту запись баланса: FAIL';
exception when others then raise notice 'клиенту запись баланса: отказ (ожидается)'; end $$;
rollback;
select 'после отката' k, checked_at is null and balance is null clean from ops.zvonok_balance;
