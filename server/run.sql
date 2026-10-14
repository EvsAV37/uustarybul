-- Проверка рассылки (021) на сервере — всё внутри транзакции с откатом, в журнал только сводка
begin;
-- временный владелец — демо-мастер (откатится)
insert into public.admins (user_id, role, pw_hash) select id, 'owner', 'x' from public.profiles where is_demo order by created_at limit 1;
insert into public.admin_sessions (session_id, user_id, expires_at)
  select '00000000-0000-4000-8000-000000000021', id, now() + interval '10 minutes' from public.profiles where is_demo order by created_at limit 1;
-- один демо-мастер на время проверки — «настоящий» с включённым телефоном (откатится)
update public.profiles set is_demo = false where id = (select id from public.profiles where is_demo order by created_at offset 1 limit 1);
insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  select id, 'https://push.invalid/ub-check-021', repeat('a', 60), repeat('b', 20) from public.profiles
   where not is_demo and deleted_at is null order by created_at limit 1;
select set_config('request.jwt.claims', json_build_object('sub', (select id from public.profiles where is_demo order by created_at limit 1),
  'session_id', '00000000-0000-4000-8000-000000000021', 'is_anonymous', false, 'role', 'authenticated')::text, true);
set local role authenticated;
select 'preview' k, public.admin_broadcast_preview('{"topic":"service"}') - 'owner' p;
select 'send' k, public.admin_broadcast_send('{"topic":"docs","title":"Проверка рассылки","body":"Проверка на сервере, откатится.","go":"doc:terms","no_ads":true}') - 'quota' r;
select 'list' k, jsonb_array_length(l -> 'items') items, (l -> 'items' -> 0) ->> 'waiting' waiting from (select public.admin_broadcast_list(5) l) x;
reset role;
select 'queue' k, count(*) from public.notifications where kind = 'broadcast';
select 'log' k, count(*) from public.admin_log where action = 'broadcast_send';
select 'rights' k, has_function_privilege('anon', 'public.admin_broadcast_send(jsonb)', 'execute') anon_send,
       has_function_privilege('authenticated', 'public.broadcast_targets(int,int)', 'execute') targets,
       has_table_privilege('authenticated', 'public.broadcasts', 'select') tbl;
-- коды входа: сколько ещё открытых (после выкладки новые пишутся только хешем)
select 'codes' k, count(*) filter (where pincode like 'h1:%') hashed, count(*) filter (where pincode not like 'h1:%') plain from public.phone_verify_codes;
rollback;
