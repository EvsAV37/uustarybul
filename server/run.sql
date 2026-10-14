-- Сверка с облаком: подробно функции и триггеры (имя и хеш определения)
select 'fn' k, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' n, md5(pg_get_functiondef(p.oid)) h
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f','p') and p.proname not in ('ub_export','push_kick')
union all
select 'trg', tgrelid::regclass::text || '.' || tgname, md5(pg_get_triggerdef(oid))
  from pg_trigger where not tgisinternal and tgrelid::regclass::text not like 'auth.%' and tgrelid::regclass::text not like 'storage.%'
order by 1, 2;
