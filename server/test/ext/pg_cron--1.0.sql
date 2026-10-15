-- Поддельный pg_cron: cron.schedule / cron.unschedule пишут в cron.job. Запустить задание вручную:
--   select public.daily_maintenance();   (команды — в cron.job.command)
create schema if not exists cron;
create table cron.job (
  jobid bigserial primary key,
  schedule text not null,
  command text not null,
  jobname text unique,
  active boolean not null default true
);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid
$$;
create function cron.schedule(schedule text, command text) returns bigint language sql as $$
  insert into cron.job (schedule, command) values (schedule, command) returning jobid
$$;
create function cron.unschedule(job_name text) returns boolean language plpgsql as $$
begin delete from cron.job where jobname = job_name; return found; end $$;
create function cron.unschedule(job_id bigint) returns boolean language plpgsql as $$
begin delete from cron.job where jobid = job_id; return found; end $$;
