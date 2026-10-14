-- Отпечаток схемы: одинаковый запрос в облаке и на своём сервере, сравниваем итог по видам объектов.
-- Без данных пользователей — только определения.
with f(k, n, h) as (
  select 'fn', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', md5(pg_get_functiondef(p.oid))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f','p')
      and p.proname not in ('ub_export', 'push_kick')
  union all
  select 'col', c.table_name || '.' || c.column_name, md5(concat_ws('|', c.data_type, c.udt_name, c.is_nullable, c.column_default, c.is_identity))
    from information_schema.columns c where c.table_schema = 'public'
  union all
  select 'con', conrelid::regclass::text || '.' || conname, md5(pg_get_constraintdef(oid))
    from pg_constraint where connamespace = 'public'::regnamespace
  union all
  select 'idx', indexname, md5(indexdef) from pg_indexes where schemaname = 'public'
  union all
  select 'trg', tgrelid::regclass::text || '.' || tgname, md5(pg_get_triggerdef(oid))
    from pg_trigger where not tgisinternal and tgrelid::regclass::text not like 'auth.%' and tgrelid::regclass::text not like 'storage.%'
  union all
  select 'pol', schemaname || '.' || tablename || '.' || policyname, md5(concat_ws('|', permissive, cmd, roles::text, qual, with_check))
    from pg_policies where schemaname in ('public', 'storage')
  union all
  select 'grant', table_name || '.' || grantee || '.' || privilege_type, '1'
    from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
  union all
  select 'colgrant', table_name || '.' || column_name || '.' || grantee || '.' || privilege_type, '1'
    from information_schema.column_privileges where table_schema = 'public' and grantee in ('anon', 'authenticated')
  union all
  select 'exec', p.proname || '.' || r.rolname, '1'
    from pg_proc p cross join (values ('anon'), ('authenticated')) r(rolname)
   where p.pronamespace = 'public'::regnamespace and p.proname <> 'ub_export' and has_function_privilege(r.rolname, p.oid, 'execute')
  union all
  select 'cron', jobname, md5(schedule || '|' || command) from cron.job
  union all
  select 'bucket', id, md5(concat_ws('|', public, file_size_limit, allowed_mime_types::text)) from storage.buckets
  union all
  select 'type', t.typname, md5(string_agg(e.enumlabel, ',' order by e.enumsortorder))
    from pg_type t join pg_enum e on e.enumtypid = t.oid where t.typnamespace = 'public'::regnamespace group by t.typname
)
select k, count(*) as n, md5(string_agg(n || '=' || h, ',' order by n)) as h from f group by k order by k;
