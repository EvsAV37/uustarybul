-- Проверка чистки (025) на сервере — только чтение и откат, в журнал только сводка
begin;
select 'policy' k, count(*) filter (where policyname = 'photos_select_own') select_own,
       count(*) filter (where policyname = 'photos_delete_own') delete_own
  from pg_policies where schemaname = 'storage' and tablename = 'objects';
select 'storage' k, count(*) files, (select count(*) from public.ops_orphan_photos(1000)) orphans_older_1d
  from storage.objects where bucket_id = 'photos';
select 'push_subs' k, count(*) filter (where disabled_at is null) active, count(*) filter (where disabled_at is not null) disabled
  from public.push_subscriptions;
select 'cleanup_fn' k, public.ops_cleanup() is null ran;
rollback;
