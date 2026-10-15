-- Уустары бул — «Предложить идею» (16.10.2026).
-- Вошедшие по номеру (не гости) пишут идею, неудобство или «что-то сломалось»; не больше 3 в сутки.
-- Прикрепляется само: роль (мастер / заказчик), город, тип телефона и браузера, версия приложения. Номер и IP — нет.
-- В управлении — раздел «Предложения»: новое / прочитано / сделано / отклонено, ответ автору, удалить,
-- «Сделать запросом по ПДн». Автор видит статус и ответ в «Моих предложениях»; ответ и «сделано» — служебный push.
-- Хранение — 1 год (Политика), при удалении аккаунта — вместе с ним.

create table if not exists public.ideas (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('idea', 'inconvenient', 'broken')),
  body text not null check (char_length(body) between 5 and 1000),
  role text not null check (role in ('master', 'customer')),
  city_id int references public.cities(id) on delete set null,
  device text check (char_length(device) <= 40),
  app_version text check (char_length(app_version) <= 20),
  status text not null default 'new' check (status in ('new', 'read', 'done', 'rejected')),
  status_at timestamptz,
  reply text check (char_length(reply) <= 500),
  replied_at timestamptz,
  pd_request_id bigint references public.pd_requests(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ideas_user_idx on public.ideas (user_id, created_at desc);
create index if not exists ideas_status_idx on public.ideas (status, created_at desc);
alter table public.ideas enable row level security;
revoke all on public.ideas from anon, authenticated;

-- Отправить (только вошедшим по номеру)
create or replace function public.idea_send(p_kind text, p_body text, p_city int default null,
                                            p_device text default null, p_version text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_body text := trim(regexp_replace(coalesce(p_body, ''), '\r', '', 'g'));
  v_city int; v_role text; v_id bigint;
begin
  if not public.is_registered() then raise exception 'registration_required' using errcode = 'P0001'; end if;
  if p_kind is null or p_kind not in ('idea', 'inconvenient', 'broken') then raise exception 'idea_kind' using errcode = 'P0001'; end if;
  if char_length(v_body) < 5 then raise exception 'idea_short' using errcode = 'P0001'; end if;
  if char_length(v_body) > 1000 then raise exception 'idea_long' using errcode = 'P0001'; end if;

  perform pg_advisory_xact_lock(hashtext('idea:' || v_uid::text));
  if (select count(*) from public.ideas where user_id = v_uid and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'idea_limit' using errcode = 'P0001';
  end if;

  select p.city_id into v_city from public.profiles p where p.id = v_uid and p.deleted_at is null;
  if found then v_role := 'master';
  else
    v_role := 'customer';
    select c.id into v_city from public.cities c where c.id = p_city;
  end if;

  insert into public.ideas (user_id, kind, body, role, city_id, device, app_version)
  values (v_uid, p_kind, v_body, v_role, v_city,
          nullif(left(regexp_replace(coalesce(p_device, ''), '[^0-9A-Za-zА-Яа-яЁё ·.\-]', '', 'g'), 40), ''),
          nullif(left(regexp_replace(coalesce(p_version, ''), '[^0-9A-Za-z.\-]', '', 'g'), 20), ''))
  returning id into v_id;
  return jsonb_build_object('id', v_id,
    'left', 3 - (select count(*) from public.ideas where user_id = v_uid and created_at > now() - interval '24 hours'));
end $$;
revoke execute on function public.idea_send(text, text, int, text, text) from public, anon;
grant execute on function public.idea_send(text, text, int, text, text) to authenticated;

-- Мои предложения: статус и ответ
create or replace function public.idea_list_mine()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'body', i.body, 'status', i.status,
            'reply', i.reply, 'replied_at', i.replied_at, 'status_at', i.status_at, 'created_at', i.created_at)
          order by i.created_at desc), '[]')
    from (select * from public.ideas where user_id = auth.uid() order by created_at desc limit 50) i
$$;
revoke execute on function public.idea_list_mine() from public, anon;
grant execute on function public.idea_list_mine() to authenticated;

-- ===== Управление =====
create or replace function public.admin_ideas(p_tab text default 'new', p_city int default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public.admin_need();
  select jsonb_build_object(
    'items', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
      select i.id, i.kind, i.body, i.role, i.device, i.app_version, i.status, i.status_at, i.reply, i.replied_at,
             i.pd_request_id, i.created_at, c.name as city,
             p.id as profile_id, p.display_name as name
        from public.ideas i
        left join public.cities c on c.id = i.city_id
        left join public.profiles p on p.id = i.user_id and i.role = 'master'
       where (p_tab = 'all' or i.status = p_tab)
         and (p_city is null or i.city_id = p_city)
       order by i.created_at desc
       limit 200) x),
    'counts', (select coalesce(jsonb_object_agg(s, n), '{}') from (
      select status s, count(*) n from public.ideas
       where p_city is null or city_id = p_city group by 1) t)
  ) into res;
  return res;
end $$;
revoke execute on function public.admin_ideas(text, int) from public, anon;
grant execute on function public.admin_ideas(text, int) to authenticated;

-- Статус и ответ. Новый или изменённый ответ, а также «сделано» — служебный push автору (если включены уведомления).
create or replace function public.admin_idea_set(p_id bigint, p_status text, p_reply text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r public.ideas;
  v_reply text := nullif(trim(coalesce(p_reply, '')), '');
  v_new_reply boolean; v_done boolean; v_push boolean := false;
begin
  perform public.admin_need();
  if p_status is null or p_status not in ('new', 'read', 'done', 'rejected') then
    raise exception 'idea_status' using errcode = 'P0001';
  end if;
  if char_length(coalesce(v_reply, '')) > 500 then raise exception 'idea_reply_long' using errcode = 'P0001'; end if;
  select * into r from public.ideas where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;

  v_new_reply := v_reply is not null and v_reply is distinct from r.reply;
  v_done := p_status = 'done' and r.status <> 'done';
  update public.ideas
     set status = p_status,
         status_at = case when p_status <> r.status then now() else status_at end,
         reply = v_reply,
         replied_at = case when v_new_reply then now() when v_reply is null then null else replied_at end
   where id = p_id;

  if v_new_reply or v_done then
    insert into public.notifications (user_id, kind, payload)
    values (r.user_id, 'idea_reply', jsonb_build_object('idea_id', r.id, 'status', p_status,
            'reply', case when v_new_reply then left(v_reply, 120) end));
    v_push := true;
  end if;
  -- «прочитано» при открытии — не в журнал (шумно); решения и ответы — в журнал
  if p_status <> 'read' or v_new_reply then
    perform public.admin_log_add('idea_set', 'idea', null, null,
      jsonb_build_object('id', r.id, 'old', r.status, 'new', p_status, 'reply', v_new_reply, 'push', v_push));
  end if;
  return jsonb_build_object('ok', true, 'push', v_push);
end $$;
revoke execute on function public.admin_idea_set(bigint, text, text) from public, anon;
grant execute on function public.admin_idea_set(bigint, text, text) to authenticated;

create or replace function public.admin_idea_delete(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.ideas;
begin
  perform public.admin_need(true);
  delete from public.ideas where id = p_id returning * into r;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform public.admin_log_add('idea_delete', 'idea', null, null, jsonb_build_object('id', r.id, 'kind', r.kind));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_idea_delete(bigint) from public, anon;
grant execute on function public.admin_idea_delete(bigint) to authenticated;

-- Сделать запросом по ПДн: дата получения — день отправки (Якутск), аккаунт — автор, канал — «в приложении»
create or replace function public.admin_idea_to_pd(p_id bigint, p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.ideas; v_recv date; v_due date; v_pd bigint;
begin
  perform public.admin_need(true);
  if p_kind is null or p_kind not in ('access','correct','delete','withdraw','stop','other') then
    raise exception 'pd_kind' using errcode = 'P0001';
  end if;
  select * into r from public.ideas where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if r.pd_request_id is not null then raise exception 'idea_already_pd' using errcode = 'P0001'; end if;
  v_recv := (r.created_at at time zone 'Asia/Yakutsk')::date;
  v_due := public.pd_due(p_kind, v_recv);
  insert into public.pd_requests (kind, received_on, channel, user_id, contact, summary, due_on, created_by)
  values (p_kind, v_recv, 'app', r.user_id, 'ответ — в «Моих предложениях» в приложении', r.body, v_due, auth.uid())
  returning id into v_pd;
  update public.ideas set pd_request_id = v_pd,
         status = case when status = 'new' then 'read' else status end,
         status_at = case when status = 'new' then now() else status_at end
   where id = p_id;
  perform public.admin_log_add('pd_create', 'pd_request', null, null,
    jsonb_build_object('id', v_pd, 'kind', p_kind, 'due_on', v_due, 'from_idea', r.id));
  return jsonb_build_object('id', v_pd, 'due_on', v_due);
end $$;
revoke execute on function public.admin_idea_to_pd(bigint, text) from public, anon;
grant execute on function public.admin_idea_to_pd(bigint, text) to authenticated;

-- Значки меню: + новые предложения (во всех городах выбранного фильтра)
create or replace function public.admin_badges(p_city int default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_need();
  return jsonb_build_object(
    'masters', (select count(*) from public.profiles p
                 where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
    'complaints', (select count(distinct o.owner) from (
                     select public.complaint_owner(c.target_type, c.target_id) owner
                       from public.complaints c where c.resolved_at is null) o
                   join public.profiles p on p.id = o.owner
                  where p.deleted_at is null and (p_city is null or p.city_id = p_city)),
    'reviews_new', (select count(*) from public.reviews r join public.profiles p on p.id = r.profile_id
                     where r.created_at > now() - interval '7 days' and (p_city is null or p.city_id = p_city)),
    'pd_urgent', public.admin_pd_urgent(),
    'ideas_new', (select count(*) from public.ideas i where i.status = 'new' and (p_city is null or i.city_id = p_city)));
end $$;

-- Чистка (09:35 Якутск): + предложения старше года
create or replace function public.ops_cleanup()
returns void language sql security definer set search_path = '' as $$
  delete from ops.log where at < now() - interval '90 days';
  delete from public.push_subscriptions where disabled_at is not null and disabled_at < now() - interval '30 days';
  delete from public.broadcasts where created_at < now() - interval '1 year';
  delete from public.ideas where created_at < now() - interval '1 year';
$$;
revoke execute on function public.ops_cleanup() from public, anon, authenticated;
