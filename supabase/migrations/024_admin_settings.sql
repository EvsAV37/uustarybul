-- Уустары бул — управление, этап 2г: «Настройки» (план, шаг 6, 15.10.2026).
-- Кто управляет (только просмотр), «Перед запуском» (тестовые номера, демо-мастера), документы, готовность к запуску.

-- Тестовые номера: выключить можно кнопкой, включить обратно — только SQL-редактором:
--   update public.app_settings set test_logins_off = null;
-- verify-phone считает номера тестовыми, только если и секрет DISABLE_TEST_LOGINS не задан, и здесь null.
alter table public.app_settings add column if not exists test_logins_off timestamptz;

create or replace function public.test_phones()
returns text[] language sql immutable set search_path = '' as $$
  select array['70000000001', '70000000002', '70000000003']
$$;

-- Всё для экрана «Настройки» одним запросом
create or replace function public.admin_settings()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public.admin_need();
  select jsonb_build_object(
    'admins', (select coalesce(jsonb_agg(jsonb_build_object(
        'phone', public.admin_phone_mask(u.phone), 'role', a.role, 'has_password', a.pw_hash is not null,
        'me', a.user_id = auth.uid(), 'since', a.created_at,
        'last_login', (select max(l.created_at) from public.admin_log l
                        where l.admin_id = a.user_id and l.action in ('unlock', 'password_set')))
        order by a.role, a.created_at), '[]')
      from public.admins a join auth.users u on u.id = a.user_id),
    'test_logins_off', (select test_logins_off from public.app_settings limit 1),
    'test_accounts', (select count(*) from auth.users where phone = any(public.test_phones())),
    'demo', jsonb_build_object(
        'masters', (select count(*) from public.profiles where is_demo),
        'spheres', (select count(*) from public.spheres s join public.profiles p on p.id = s.profile_id where p.is_demo),
        'reviews', (select count(*) from public.reviews r join public.profiles p on p.id = r.profile_id where p.is_demo)),
    -- согласия по видам и редакциям: сколько разных людей
    'consents', (select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'version', c.doc_version, 'people', c.n)), '[]')
                   from (select kind::text, doc_version, count(distinct user_id) n from public.consents group by 1, 2) c),
    'ops', public.ops_status(),
    'masters_real', (select count(*) from public.profiles where not is_demo and deleted_at is null
                       and not exists (select 1 from auth.users u where u.id = profiles.id and u.phone = any(public.test_phones())))
  ) into res;
  return res;
end $$;
revoke execute on function public.admin_settings() from public, anon;
grant execute on function public.admin_settings() to authenticated;

-- Выключить тестовые номера и удалить их аккаунты (без возврата кнопкой)
create or replace function public.admin_test_logins_off()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.admin_need(true); n int;
begin
  if exists (select 1 from public.admins a join auth.users u on u.id = a.user_id where u.phone = any(public.test_phones())) then
    raise exception 'Тестовый номер назначен администратором — сначала снимите его (admin_revoke)' using errcode = 'P0001';
  end if;
  update public.app_settings set test_logins_off = coalesce(test_logins_off, now());
  with d as (delete from auth.users where phone = any(public.test_phones()) returning 1) select count(*) into n from d;
  perform public.admin_log_add('test_logins_off', null, null, null, jsonb_build_object('accounts', n));
  return jsonb_build_object('ok', true, 'accounts', n);
end $$;
revoke execute on function public.admin_test_logins_off() from public, anon;
grant execute on function public.admin_test_logins_off() to authenticated;

-- Удалить всех демо-мастеров: нужно вписать «УДАЛИТЬ»
create or replace function public.admin_demo_purge(p_confirm text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.admin_need(true); n int;
begin
  if coalesce(p_confirm, '') <> 'УДАЛИТЬ' then
    raise exception 'Впишите слово УДАЛИТЬ' using errcode = 'P0001';
  end if;
  n := public.purge_demo();
  perform public.admin_log_add('demo_purge', null, null, null, jsonb_build_object('masters', n));
  return jsonb_build_object('ok', true, 'masters', n);
end $$;
revoke execute on function public.admin_demo_purge(text) from public, anon;
grant execute on function public.admin_demo_purge(text) to authenticated;
