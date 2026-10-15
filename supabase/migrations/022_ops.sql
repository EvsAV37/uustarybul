-- Уустары бул — журнал обслуживания сервера (план, шаги 3–4, 15.10.2026).
-- Копии базы (ub-backup) и сторож пишут сюда итоги; «Система» на Обзоре управления показывает последние.
-- Схема ops закрыта для клиентов (её не видит API); пишут только скрипты сервера от postgres.

create schema if not exists ops;
revoke all on schema ops from public, anon, authenticated;

create table if not exists ops.log (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('backup', 'restore_test', 'watch')),
  ok boolean not null,
  at timestamptz not null default now(),
  detail jsonb not null default '{}'   -- только служебное: размер, сколько копий, числа строк; без персональных данных
);
create index if not exists ops_log_kind_at on ops.log (kind, at desc);

-- Короткая сводка для «Системы»: последняя удачная и последняя неудачная запись каждого вида
create or replace function public.ops_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'backup', (select jsonb_build_object(
        'ok_at', (select max(at) from ops.log where kind = 'backup' and ok),
        'fail_at', (select max(at) from ops.log where kind = 'backup' and not ok),
        'size', (select (detail ->> 'size')::bigint from ops.log where kind = 'backup' and ok order by at desc limit 1),
        'copies', (select (detail ->> 'copies')::int from ops.log where kind = 'backup' and ok order by at desc limit 1))),
    'restore', (select jsonb_build_object(
        'ok_at', (select max(at) from ops.log where kind = 'restore_test' and ok),
        'fail_at', (select max(at) from ops.log where kind = 'restore_test' and not ok)))
  )
$$;
revoke execute on function public.ops_status() from public, anon, authenticated;

-- Обзор управления: тело — admin_overview_core (миграция 020), сверху — сводка обслуживания в system.
-- Дальше менять тело Обзора — в admin_overview_core, а admin_overview только дополняет его.
alter function public.admin_overview(int, int) rename to admin_overview_core;
revoke execute on function public.admin_overview_core(int, int) from public, anon, authenticated;

create or replace function public.admin_overview(p_city int default null, p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o jsonb;
begin
  o := public.admin_overview_core(p_city, p_days);   -- сама проверяет админ-сессию
  return jsonb_set(o, '{system}', coalesce(o -> 'system', '{}') || public.ops_status());
end $$;
revoke execute on function public.admin_overview(int, int) from public, anon;
grant execute on function public.admin_overview(int, int) to authenticated;

-- Чистка журнала обслуживания: 90 дней (вместе с остальной чисткой управления)
create or replace function public.ops_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from ops.log where at < now() - interval '90 days';
$$;
revoke execute on function public.ops_cleanup() from public, anon, authenticated;
select cron.schedule('uustarybul-ops-cleanup', '35 0 * * *', 'select public.ops_cleanup()');
