-- Проверка «Предложить идею» (027) на сервере — всё с откатом, в журнал только сводка (без номеров и текстов)
begin;
-- владелец управления, временная сессия управления (откатится)
select set_config('ub.uid', (select a.user_id::text from public.admins a where a.role = 'owner' order by a.created_at limit 1), true) is not null owner_found;
insert into public.admin_sessions (session_id, user_id, expires_at)
  values ('00000000-0000-4000-8000-000000000027', current_setting('ub.uid')::uuid, now() + interval '10 minutes');
select set_config('request.jwt.claims', json_build_object('sub', current_setting('ub.uid'), 'role', 'authenticated',
  'is_anonymous', false, 'session_id', '00000000-0000-4000-8000-000000000027')::text, true) is not null claims;
set local role authenticated;

select 'send' k, (public.idea_send('idea', 'Проверка 027: идея', null, 'Linux · Chrome', '0.1') ->> 'left')::int left_1,
       (public.idea_send('broken', 'Проверка 027: сломалось', null, 'Linux · Chrome', '0.1') ->> 'left')::int left_2,
       (public.idea_send('inconvenient', 'Проверка 027: неудобно', null, 'Linux · Chrome', '0.1') ->> 'left')::int left_3;
do $$ begin perform public.idea_send('idea', 'Проверка 027: четвёртое', null, null, null); raise notice 'limit: FAIL';
exception when others then raise notice 'limit: % (ожидается idea_limit)', sqlerrm; end $$;
select 'mine' k, jsonb_array_length(public.idea_list_mine()) n;
select 'badge' k, (public.admin_badges() ->> 'ideas_new')::int ideas_new;
select 'list' k, jsonb_array_length(public.admin_ideas('new') -> 'items') items;
select 'reply' k, (public.admin_idea_set((select max((e.v ->> 'id')::bigint) from jsonb_array_elements(public.idea_list_mine()) e(v)),
                                         'done', 'Проверка ответа') ->> 'push')::boolean push;
select 'to_pd' k, (public.admin_idea_to_pd((select min((e.v ->> 'id')::bigint) from jsonb_array_elements(public.idea_list_mine()) e(v)), 'other') ->> 'id') is not null pd_created;
select 'delete' k, (public.admin_idea_delete((select min((e.v ->> 'id')::bigint) from jsonb_array_elements(public.idea_list_mine()) e(v))) ->> 'ok')::boolean deleted;
do $$ begin perform 1 from public.ideas limit 1; raise notice 'table: FAIL (клиенту видна)';
exception when others then raise notice 'table: закрыта (%)', sqlerrm; end $$;
reset role;
select 'queue' k, count(*) idea_reply from public.notifications where kind = 'idea_reply'
   and created_at > now() - interval '1 minute';
select 'cleanup_fn' k, public.ops_cleanup() is null ran;
-- аноним — отказ
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true) is not null anon_claims;
do $$ begin perform public.idea_send('idea', 'Проверка 027: аноним', null, null, null); raise notice 'anon: FAIL';
exception when others then raise notice 'anon: отказ (%)', sqlerrm; end $$;
reset role;
rollback;
select 'after_rollback' k, (select count(*) from public.ideas) ideas,
       (select count(*) from public.admin_sessions where session_id::text = '00000000-0000-4000-8000-000000000027') tmp_session;
