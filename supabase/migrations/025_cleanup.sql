-- Уустары бул — чистка (план, шаг 7, 15.10.2026).
-- 1. Удаление фото из приложения не работало: Supabase для удаления файла требует политик DELETE и SELECT
--    на storage.objects, а SELECT не было — файлы оставались. Даём мастеру видеть свои файлы (чтение фото и так публичное).
-- 2. Файлы, на которые ничего не ссылается (старые аватары, фото удалённых направлений и аккаунтов), удаляет
--    server/ub-cleanup через Storage API раз в сутки — список берёт из ops_orphan_photos().
-- 3. Выключенные push-подписки — через 30 дней, записи рассылок — через год.

drop policy if exists photos_select_own on storage.objects;
create policy photos_select_own on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Файлы фото без ссылок, старше суток (сутки — запас на загрузку, которая ещё не дописала строку в базу)
create or replace function public.ops_orphan_photos(p_limit int default 500)
returns setof text language sql stable security definer set search_path = '' as $$
  select o.name from storage.objects o
   where o.bucket_id = 'photos' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from public.photos p where p.storage_path = o.name)
     and not exists (select 1 from public.profiles pr where pr.avatar_path = o.name)
   order by o.created_at
   limit greatest(1, least(coalesce(p_limit, 500), 1000))
$$;
revoke execute on function public.ops_orphan_photos(int) from public, anon, authenticated;

alter table ops.log drop constraint if exists log_kind_check;
alter table ops.log add constraint log_kind_check check (kind in ('backup', 'restore_test', 'watch', 'cleanup'));

-- Ежедневная чистка обслуживания (09:35 Якутск): журнал обслуживания 90 дней, выключенные push-подписки 30 дней,
-- записи рассылок 1 год (итоги доставки уходят раньше — вместе с уведомлениями, 90 дней)
create or replace function public.ops_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from ops.log where at < now() - interval '90 days';
  delete from public.push_subscriptions where disabled_at is not null and disabled_at < now() - interval '30 days';
  delete from public.broadcasts where created_at < now() - interval '1 year';
$$;
revoke execute on function public.ops_cleanup() from public, anon, authenticated;
