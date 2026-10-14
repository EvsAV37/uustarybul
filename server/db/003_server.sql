-- Отличия своего сервера от облачного Supabase.

-- 1. Push: функция send-push живёт рядом, в той же сети Docker
create or replace function public.push_kick()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'http://functions:9000/send-push',
    body := '{}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then null;
end $$;

-- 2. Чистка журнала защиты (в облаке создана вручную в SQL-редакторе 13.10.2026)
create or replace function public.guard_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from public.pow_used where created_at < now() - interval '1 day';
  delete from public.guard_log where created_at < now() - interval '2 days';
$$;
revoke execute on function public.guard_cleanup() from public, anon, authenticated;
select cron.schedule('uustarybul-guard-cleanup', '20 0 * * *', 'select public.guard_cleanup()');

-- 3. Миграции 013–017 из supabase/migrations уже вошли в 001_cloud_schema.sql
insert into ops.migrations (name) values
  ('migrations/013_push.sql'), ('migrations/014_professions.sql'), ('migrations/015_avatar.sql'),
  ('migrations/016_free_pro.sql'), ('migrations/017_guard.sql')
on conflict do nothing;
