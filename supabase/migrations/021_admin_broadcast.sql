-- 021. Управление, этап 2в: рассылка push мастерам (только служебные сообщения).
-- Реклама по сетям электросвязи — только с предварительного согласия (ст. 18 закона «О рекламе»),
-- поэтому рассылка — только служебная: документы, работа сервиса, аккаунт и карточки.
-- Кому: всем мастерам, мастерам города, мастерам сферы (или город + сфера). Не больше 2 рассылок за 7 дней.
-- Доставка — через обычную очередь notifications (тихие часы, повторы, выключенные подписки — как у всех push).

create table if not exists public.broadcasts (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  admin_id uuid references auth.users(id) on delete set null,
  topic text not null check (topic in ('docs', 'service', 'account')),
  title text not null check (char_length(title) between 3 and 40),
  body text not null check (char_length(body) between 5 and 120),
  go text not null default 'cab' check (go in ('cab', 'home', 'doc:terms', 'doc:privacy', 'doc:consents', 'doc:offer')),
  city_id int references public.cities(id),
  category_id int references public.categories(id),
  recipients int not null default 0,
  devices int not null default 0
);
create index if not exists broadcasts_created_idx on public.broadcasts (created_at desc);
alter table public.broadcasts enable row level security;
revoke all on public.broadcasts from anon, authenticated;

-- Уведомления рассылки ищем по номеру рассылки
create index if not exists notifications_broadcast_idx on public.notifications (((payload ->> 'broadcast_id')::bigint))
  where kind = 'broadcast';

-- Кому уйдёт: мастера (есть профиль), не удаляются, не демо; фильтр по городу и сфере
create or replace function public.broadcast_targets(p_city int, p_category int)
returns table (r_user uuid) language sql stable security definer set search_path = '' as $$
  select p.id from public.profiles p
   where p.deleted_at is null and not p.is_demo
     and (p_city is null or p.city_id = p_city)
     and (p_category is null or exists (select 1 from public.spheres s
                                         where s.profile_id = p.id and s.category_id = p_category))
$$;

-- Проверка текста и параметров; возвращает разобранное
create or replace function public.broadcast_parse(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_topic text := nullif(trim(p ->> 'topic'), '');
  v_title text := regexp_replace(trim(coalesce(p ->> 'title', '')), '\s+', ' ', 'g');
  v_body  text := regexp_replace(trim(coalesce(p ->> 'body', '')), '\s+', ' ', 'g');
  v_go    text := coalesce(nullif(trim(p ->> 'go'), ''), 'cab');
  v_city  int  := nullif(p ->> 'city_id', '')::int;
  v_cat   int  := nullif(p ->> 'category_id', '')::int;
begin
  if v_topic is null or v_topic not in ('docs', 'service', 'account') then
    raise exception 'broadcast_topic' using errcode = 'P0001'; end if;
  if v_go not in ('cab', 'home', 'doc:terms', 'doc:privacy', 'doc:consents', 'doc:offer') then
    raise exception 'broadcast_go' using errcode = 'P0001'; end if;
  if v_city is not null and not exists (select 1 from public.cities where id = v_city) then
    raise exception 'broadcast_city' using errcode = 'P0001'; end if;
  if v_cat is not null and not exists (select 1 from public.categories where id = v_cat) then
    raise exception 'broadcast_category' using errcode = 'P0001'; end if;
  return jsonb_build_object('topic', v_topic, 'title', v_title, 'body', v_body, 'go', v_go,
                            'city_id', v_city, 'category_id', v_cat);
end $$;

create or replace function public.broadcast_text_ok(p_title text, p_body text)
returns void language plpgsql immutable set search_path = '' as $$
declare t text := lower(p_title || ' ' || p_body);
begin
  if char_length(p_title) not between 3 and 40 then raise exception 'broadcast_title' using errcode = 'P0001'; end if;
  if char_length(p_body) not between 5 and 120 then raise exception 'broadcast_body' using errcode = 'P0001'; end if;
  -- ссылки и номера телефонов в рассылке не нужны: всё ведёт в приложение
  if t ~ '(https?://|www\.|[a-zа-я0-9-]+\.(ru|рф|com|net|org|su|me|io)\y)' then
    raise exception 'broadcast_link' using errcode = 'P0001'; end if;
  if t ~ '(\+7|8)[ ()-]*[0-9]{3}[ ()-]*[0-9]{3}[ -]*[0-9]{2}[ -]*[0-9]{2}' then
    raise exception 'broadcast_phone' using errcode = 'P0001'; end if;
end $$;

-- Лимит: не больше 2 рассылок за 7 дней
create or replace function public.broadcast_quota()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'used', count(*),
    'left', greatest(0, 2 - count(*)),
    'next_at', case when count(*) >= 2 then min(created_at) + interval '7 days' end)
  from (select created_at from public.broadcasts
         where created_at > now() - interval '7 days'
         order by created_at desc limit 2) x
$$;

-- Сколько получат (до отправки)
create or replace function public.admin_broadcast_preview(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_rec int; v_dev int; v_quiet int;
begin
  perform public.admin_need();
  v := public.broadcast_parse(p);
  select count(*),
         count(*) filter (where exists (select 1 from public.push_subscriptions s
                                         where s.user_id = t.r_user and s.disabled_at is null)),
         count(*) filter (where exists (select 1 from public.push_subscriptions s
                                         where s.user_id = t.r_user and s.disabled_at is null)
                            and exists (select 1 from public.notify_prefs np
                                          join public.profiles pr on pr.id = np.user_id
                                          left join public.cities ci on ci.id = pr.city_id
                                         where np.user_id = t.r_user
                                           and public.in_quiet_hours(np.quiet, np.quiet_from, np.quiet_to, coalesce(ci.tz, 'Asia/Yakutsk'))))
    into v_rec, v_dev, v_quiet
    from public.broadcast_targets((v ->> 'city_id')::int, (v ->> 'category_id')::int) t;
  return jsonb_build_object('recipients', v_rec, 'devices', v_dev, 'quiet_now', v_quiet,
                            'quota', public.broadcast_quota(), 'owner', public.admin_role() = 'owner');
end $$;

-- Отправить (только владелец). Пишет одну строку в broadcasts и по уведомлению каждому мастеру —
-- только тем, у кого включён телефон (остальным всё равно нечем показать).
create or replace function public.admin_broadcast_send(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; q jsonb; v_id bigint; v_rec int; v_dev int;
begin
  perform public.admin_need(true);
  v := public.broadcast_parse(p);
  perform public.broadcast_text_ok(v ->> 'title', v ->> 'body');
  if coalesce((p ->> 'no_ads')::boolean, false) is not true then
    raise exception 'broadcast_no_ads' using errcode = 'P0001'; end if;
  -- одна отправка за раз, лимит считаем под замком
  perform pg_advisory_xact_lock(hashtext('uustarybul-broadcast'));
  q := public.broadcast_quota();
  if (q ->> 'left')::int <= 0 then raise exception 'broadcast_quota' using errcode = 'P0001'; end if;

  select count(*),
         count(*) filter (where exists (select 1 from public.push_subscriptions s
                                         where s.user_id = t.r_user and s.disabled_at is null))
    into v_rec, v_dev
    from public.broadcast_targets((v ->> 'city_id')::int, (v ->> 'category_id')::int) t;
  if v_dev = 0 then raise exception 'broadcast_nobody' using errcode = 'P0001'; end if;

  insert into public.broadcasts (admin_id, topic, title, body, go, city_id, category_id, recipients, devices)
  values (auth.uid(), v ->> 'topic', v ->> 'title', v ->> 'body', v ->> 'go',
          (v ->> 'city_id')::int, (v ->> 'category_id')::int, v_rec, v_dev)
  returning id into v_id;

  insert into public.notifications (user_id, kind, payload)
  select t.r_user, 'broadcast',
         jsonb_build_object('broadcast_id', v_id, 'title', v ->> 'title', 'body', v ->> 'body', 'go', v ->> 'go')
    from public.broadcast_targets((v ->> 'city_id')::int, (v ->> 'category_id')::int) t
   where exists (select 1 from public.push_subscriptions s where s.user_id = t.r_user and s.disabled_at is null);

  perform public.admin_log_add('broadcast_send', 'broadcast', null, null,
    jsonb_build_object('broadcast_id', v_id, 'topic', v ->> 'topic', 'title', v ->> 'title',
                       'city_id', v -> 'city_id', 'category_id', v -> 'category_id',
                       'recipients', v_rec, 'devices', v_dev));
  return jsonb_build_object('id', v_id, 'recipients', v_rec, 'devices', v_dev, 'quota', public.broadcast_quota());
end $$;

-- История с итогами доставки (итоги живут, пока живут уведомления — 90 дней)
create or replace function public.admin_broadcast_list(p_limit int default 20, p_before bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_need();
  return jsonb_build_object(
    'quota', public.broadcast_quota(),
    'owner', public.admin_role() = 'owner',
    'items', coalesce((
      select jsonb_agg(x order by x.id desc) from (
        select b.id, b.created_at, b.topic, b.title, b.body, b.go, b.recipients, b.devices,
               b.city_id, ci.name as city, b.category_id, ca.name as category,
               st.sent, st.waiting, st.failed, st.no_device, st.off, st.stale, st.total
          from public.broadcasts b
          left join public.cities ci on ci.id = b.city_id
          left join public.categories ca on ca.id = b.category_id
          left join lateral (
            select count(*) filter (where n.push_status = 'sent') as sent,
                   count(*) filter (where n.sent_at is null or n.push_status in ('sending', 'retry')) as waiting,
                   count(*) filter (where n.push_status = 'failed') as failed,
                   count(*) filter (where n.push_status = 'no_device') as no_device,
                   count(*) filter (where n.push_status = 'off') as off,
                   count(*) filter (where n.push_status = 'stale') as stale,
                   count(*) as total
              from public.notifications n
             where n.kind = 'broadcast' and (n.payload ->> 'broadcast_id')::bigint = b.id) st on true
         where p_before is null or b.id < p_before
         order by b.id desc
         limit greatest(1, least(coalesce(p_limit, 20), 50))) x), '[]'::jsonb));
end $$;

-- ===== Права =====
revoke execute on function public.broadcast_targets(int, int), public.broadcast_parse(jsonb),
  public.broadcast_text_ok(text, text), public.broadcast_quota()
  from public, anon, authenticated;
revoke execute on function public.admin_broadcast_preview(jsonb), public.admin_broadcast_send(jsonb),
  public.admin_broadcast_list(int, bigint)
  from public, anon;
grant execute on function public.admin_broadcast_preview(jsonb), public.admin_broadcast_send(jsonb),
  public.admin_broadcast_list(int, bigint)
  to authenticated;
