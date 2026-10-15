-- Поддельный pg_net: net.http_post / net.http_get только записывают запрос в net.requests.
create schema if not exists net;
create table net.requests (
  id bigserial primary key,
  method text not null,
  url text not null,
  body jsonb,
  headers jsonb,
  created_at timestamptz not null default now()
);
create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds int default 5000)
returns bigint language sql as $$
  insert into net.requests (method, url, body, headers) values ('POST', url, body, headers) returning id
$$;
create function net.http_get(url text, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb,
  timeout_milliseconds int default 5000)
returns bigint language sql as $$
  insert into net.requests (method, url, headers) values ('GET', url, headers) returning id
$$;
