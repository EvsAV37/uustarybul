-- Схема из облачного Supabase: миграции 001–017 в том виде, в каком они применены там.
-- Выгружено автоматически (export.yml). Не править: исправления — следующими файлами.

-- ==================== 001_core_schema ====================
-- Уустары бул: основная схема
create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- Типы
create type public.profile_kind as enum ('person','org');
create type public.sphere_status as enum ('draft','active','expired','paused','hidden','blocked');
create type public.contact_kind as enum ('call','message');
create type public.complaint_target as enum ('profile','sphere','review');
create type public.complaint_reason as enum ('fraud','prepayment','rude','fake','spam','other');
create type public.payment_kind as enum ('pro_1m','pro_3m','extra_sphere');
create type public.payment_status as enum ('pending','paid','failed','refunded');
create type public.consent_kind as enum ('terms','pd_processing','pd_distribution');

-- Справочники
create table public.cities (
  id int generated always as identity primary key,
  name text not null,
  region text not null,
  sort int not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (name, region)
);

create table public.categories (
  id int generated always as identity primary key,
  slug text not null unique,
  name text not null,
  icon text,
  sort int not null default 100,
  is_active boolean not null default true
);

create table public.plan_limits (
  plan text primary key check (plan in ('free','pro')),
  spheres int not null,
  services_per_sphere int,          -- null = без лимита
  photos_per_sphere int not null
);

-- Мастер
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  kind public.profile_kind not null default 'person',
  display_name text not null check (char_length(display_name) between 2 and 80),
  org_name text check (char_length(org_name) <= 120),
  about text check (char_length(about) <= 1000),
  avatar_path text,
  city_id int not null references public.cities(id),
  city_changed_at timestamptz,
  travels boolean not null default false,
  travel_note text check (char_length(travel_note) <= 200),
  pro_until timestamptz,
  extra_spheres int not null default 0 check (extra_spheres >= 0),
  extra_spheres_until timestamptz,
  rating_avg numeric(2,1),
  reviews_count int not null default 0,
  is_hidden boolean not null default false,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_city_idx on public.profiles (city_id) where deleted_at is null and not is_hidden;

-- Телефон отдельно: наружу только через get_contact()
create table public.profile_contacts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  phone text not null check (phone ~ '^\+?[0-9]{10,15}$'),
  updated_at timestamptz not null default now()
);

create table public.spheres (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  category_id int not null references public.categories(id),
  title text not null check (char_length(title) between 2 and 60),
  description text check (char_length(description) <= 2000),
  status public.sphere_status not null default 'draft',
  published_at timestamptz,
  expires_at timestamptz,
  reminded_at timestamptz,
  search_text text not null default '',
  search_doc tsvector,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index spheres_profile_idx on public.spheres (profile_id);
create index spheres_category_idx on public.spheres (category_id) where status = 'active';
create index spheres_expires_idx on public.spheres (expires_at) where status = 'active';
create index spheres_search_doc_idx on public.spheres using gin (search_doc);
create index spheres_search_trgm_idx on public.spheres using gin (search_text extensions.gin_trgm_ops);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  sphere_id uuid not null references public.spheres(id) on delete cascade,
  title text not null check (char_length(title) between 2 and 80),
  price_from int check (price_from >= 0),
  price_to int check (price_to >= 0),
  unit text check (char_length(unit) <= 30),
  sort int not null default 0,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  check (price_to is null or price_from is null or price_to >= price_from)
);
create index services_sphere_idx on public.services (sphere_id, sort);

create table public.photos (
  id uuid primary key default gen_random_uuid(),
  sphere_id uuid not null references public.spheres(id) on delete cascade,
  storage_path text not null,
  sort int not null default 0,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index photos_sphere_idx on public.photos (sphere_id, sort);

-- Доверие
create table public.contact_events (
  id bigint generated always as identity primary key,
  customer_id uuid references auth.users(id) on delete set null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  sphere_id uuid references public.spheres(id) on delete set null,
  kind public.contact_kind not null,
  created_at timestamptz not null default now()
);
create index contact_events_customer_idx on public.contact_events (customer_id, created_at desc);
create index contact_events_profile_idx on public.contact_events (profile_id, created_at desc);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  author_id uuid default auth.uid() references auth.users(id) on delete set null,
  author_name text not null check (char_length(author_name) between 1 and 40),
  rating smallint not null check (rating between 1 and 5),
  body text check (char_length(body) <= 1000),
  reply text check (char_length(reply) <= 1000),
  replied_at timestamptz,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  unique (profile_id, author_id)
);
create index reviews_profile_idx on public.reviews (profile_id, created_at desc);

create table public.complaints (
  id bigint generated always as identity primary key,
  author_id uuid default auth.uid() references auth.users(id) on delete set null,
  target_type public.complaint_target not null,
  target_id uuid not null,
  reason public.complaint_reason not null,
  comment text check (char_length(comment) <= 500),
  created_at timestamptz not null default now(),
  unique (author_id, target_type, target_id)
);
create index complaints_target_idx on public.complaints (target_type, target_id);

create table public.favorites (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, profile_id)
);
create index favorites_profile_idx on public.favorites (profile_id);

-- Деньги
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  kind public.payment_kind not null,
  quantity int not null default 1 check (quantity > 0),
  amount_rub int not null check (amount_rub >= 0),
  status public.payment_status not null default 'pending',
  provider text,
  provider_payment_id text unique,
  period_start timestamptz,
  period_end timestamptz,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index payments_profile_idx on public.payments (profile_id);

create table public.trial_grants (
  phone_hash text primary key,
  granted_at timestamptz not null default now()
);

-- Служебное
create table public.consents (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references auth.users(id) on delete set null,
  kind public.consent_kind not null,
  doc_version text not null check (char_length(doc_version) <= 40),
  accepted_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index consents_user_idx on public.consents (user_id);

create table public.stats_daily (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  views int not null default 0,
  contacts int not null default 0,
  primary key (profile_id, day)
);

create table public.search_queries (
  city_id int not null references public.cities(id) on delete cascade,
  query text not null check (char_length(query) between 2 and 60),
  hits int not null default 1,
  last_at timestamptz not null default now(),
  primary key (city_id, query)
);

create table public.push_subscriptions (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index push_user_idx on public.push_subscriptions (user_id);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  read_at timestamptz
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unsent_idx on public.notifications (created_at) where sent_at is null;

create table public.deletion_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now()
);

-- Очередь на удаление файлов (обрабатывает серверная функция)
create table public.storage_cleanup (
  id bigint generated always as identity primary key,
  bucket text not null default 'photos',
  prefix text not null,
  created_at timestamptz not null default now(),
  done_at timestamptz
);

-- Права: по умолчанию закрыто, открываем точечно
revoke all on all tables in schema public from anon, authenticated;

grant select on public.cities, public.categories, public.plan_limits to anon, authenticated;
grant select on public.profiles, public.spheres, public.services, public.photos, public.reviews to anon, authenticated;

grant insert (id, kind, display_name, org_name, about, avatar_path, city_id, travels, travel_note) on public.profiles to authenticated;
grant update (kind, display_name, org_name, about, avatar_path, city_id, travels, travel_note) on public.profiles to authenticated;

grant select, update (phone) on public.profile_contacts to authenticated;

grant insert (profile_id, category_id, title, description), update (category_id, title, description), delete on public.spheres to authenticated;
grant insert (sphere_id, title, price_from, price_to, unit, sort), update (title, price_from, price_to, unit, sort), delete on public.services to authenticated;
grant insert (sphere_id, storage_path, sort), update (sort), delete on public.photos to authenticated;

grant insert (profile_id, author_name, rating, body), update (reply) on public.reviews to authenticated;
grant insert (target_type, target_id, reason, comment) on public.complaints to authenticated;
grant select, insert (profile_id), delete on public.favorites to authenticated;
grant select on public.contact_events, public.payments, public.stats_daily to authenticated;
grant select, insert (kind, doc_version) on public.consents to authenticated;
grant select, insert (endpoint, p256dh, auth), delete on public.push_subscriptions to authenticated;
grant select, update (read_at) on public.notifications to authenticated;

-- ==================== 002_functions_triggers ====================
-- ===== Помощники =====
create or replace function public.is_registered()
returns boolean language sql stable set search_path = '' as $$
  select auth.uid() is not null
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
$$;

create or replace function public.profile_is_public(p_profile uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = p_profile and deleted_at is null and not is_hidden)
$$;

create or replace function public.sphere_is_public(p_sphere uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.spheres s join public.profiles p on p.id = s.profile_id
                 where s.id = p_sphere and s.status = 'active'
                   and p.deleted_at is null and not p.is_hidden)
$$;

create or replace function public.owns_sphere(p_sphere uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.spheres where id = p_sphere and profile_id = auth.uid())
$$;

create or replace function public.profile_is_pro(p_profile uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select pro_until > now() from public.profiles where id = p_profile), false)
$$;

-- Действующие лимиты мастера (бесплатно / Про + доп. сферы)
create or replace function public.profile_limits(p_profile uuid)
returns table (spheres int, services_per_sphere int, photos_per_sphere int)
language sql stable security definer set search_path = '' as $$
  select l.spheres + case when pr.pro_until > now() and pr.extra_spheres_until > now()
                          then pr.extra_spheres else 0 end,
         l.services_per_sphere,
         l.photos_per_sphere
  from public.profiles pr
  join public.plan_limits l
    on l.plan = case when pr.pro_until > now() then 'pro' else 'free' end
  where pr.id = p_profile
$$;

create or replace function public.tg_set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ===== Профиль =====
-- Смена города не чаще раза в 30 дней (первая смена — в любой момент)
create or replace function public.tg_profiles_before()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.city_changed_at := null;
    return new;
  end if;
  if new.city_id is distinct from old.city_id then
    if old.city_changed_at is not null and old.city_changed_at > now() - interval '30 days' then
      raise exception 'city_change_too_soon'
        using errcode = 'P0001', hint = 'Город можно менять не чаще раза в 30 дней';
    end if;
    new.city_changed_at := now();
  end if;
  return new;
end $$;

-- Телефон мастера берём из номера, по которому он вошёл
create or replace function public.tg_profiles_after_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_phone text;
begin
  select phone into v_phone from auth.users where id = new.id;
  if v_phone is not null and v_phone <> '' then
    insert into public.profile_contacts (profile_id, phone) values (new.id, v_phone)
    on conflict do nothing;
  end if;
  return null;
end $$;

-- Применяет лимиты тарифа: лишние сферы → paused, лишние услуги/фото скрываются;
-- при продлении Про возвращает всё обратно
create or replace function public.apply_plan_limits(p_profile uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_spheres int; v_services int; v_photos int; v_active int;
begin
  select l.spheres, l.services_per_sphere, l.photos_per_sphere
    into v_spheres, v_services, v_photos
  from public.profile_limits(p_profile) l;
  if v_spheres is null then return; end if;

  update public.spheres set status = 'paused'
  where id in (select id from public.spheres
               where profile_id = p_profile and status = 'active'
               order by published_at nulls last, created_at
               offset v_spheres);

  select count(*) into v_active from public.spheres where profile_id = p_profile and status = 'active';
  if v_active < v_spheres then
    update public.spheres set status = 'active'
    where id in (select id from public.spheres
                 where profile_id = p_profile and status = 'paused' and expires_at > now()
                 order by published_at nulls last, created_at
                 limit v_spheres - v_active);
  end if;

  update public.services sv set is_hidden = (r.rn > coalesce(v_services, 2147483647))
  from (select s2.id, row_number() over (partition by s2.sphere_id order by s2.sort, s2.created_at) as rn
        from public.services s2 join public.spheres sp on sp.id = s2.sphere_id
        where sp.profile_id = p_profile) r
  where sv.id = r.id and sv.is_hidden is distinct from (r.rn > coalesce(v_services, 2147483647));

  update public.photos ph set is_hidden = (r.rn > v_photos)
  from (select p2.id, row_number() over (partition by p2.sphere_id order by p2.sort, p2.created_at) as rn
        from public.photos p2 join public.spheres sp on sp.id = p2.sphere_id
        where sp.profile_id = p_profile) r
  where ph.id = r.id and ph.is_hidden is distinct from (r.rn > v_photos);
end $$;

create or replace function public.tg_profiles_plan_changed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.apply_plan_limits(new.id);
  return null;
end $$;

create trigger profiles_before before insert or update on public.profiles
  for each row execute function public.tg_profiles_before();
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.tg_set_updated_at();
create trigger profiles_after_insert after insert on public.profiles
  for each row execute function public.tg_profiles_after_insert();
create trigger profiles_plan_changed after update of pro_until, extra_spheres, extra_spheres_until on public.profiles
  for each row
  when (old.pro_until is distinct from new.pro_until
     or old.extra_spheres is distinct from new.extra_spheres
     or old.extra_spheres_until is distinct from new.extra_spheres_until)
  execute function public.tg_profiles_plan_changed();
create trigger profile_contacts_updated_at before update on public.profile_contacts
  for each row execute function public.tg_set_updated_at();

-- ===== Сферы, услуги, фото =====
create or replace function public.tg_spheres_before()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_cat text; v_services text;
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.spheres where profile_id = new.profile_id) >= 20 then
      raise exception 'spheres_total_limit' using errcode = 'P0001', hint = 'Не больше 20 сфер в профиле';
    end if;
  end if;
  select name into v_cat from public.categories where id = new.category_id;
  select coalesce(string_agg(title, ' ' order by sort), '') into v_services
  from public.services where sphere_id = new.id;
  new.search_text := lower(new.title || ' ' || coalesce(v_cat, '') || ' ' || v_services);
  new.search_doc := setweight(to_tsvector('russian', new.title), 'A')
                 || setweight(to_tsvector('russian', coalesce(v_cat, '') || ' ' || v_services), 'B')
                 || setweight(to_tsvector('russian', coalesce(new.description, '')), 'C');
  return new;
end $$;

create trigger spheres_before before insert or update on public.spheres
  for each row execute function public.tg_spheres_before();
create trigger spheres_updated_at before update on public.spheres
  for each row execute function public.tg_set_updated_at();

create or replace function public.tg_services_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_profile uuid; v_limit int; v_cnt int;
begin
  select profile_id into v_profile from public.spheres where id = new.sphere_id;
  select l.services_per_sphere into v_limit from public.profile_limits(v_profile) l;
  select count(*) into v_cnt from public.services where sphere_id = new.sphere_id;
  if v_cnt >= coalesce(v_limit, 100) then
    raise exception 'services_limit' using errcode = 'P0001',
      hint = 'Лимит услуг в сфере исчерпан';
  end if;
  return new;
end $$;

create or replace function public.tg_photos_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_profile uuid; v_limit int; v_cnt int;
begin
  select profile_id into v_profile from public.spheres where id = new.sphere_id;
  select l.photos_per_sphere into v_limit from public.profile_limits(v_profile) l;
  select count(*) into v_cnt from public.photos where sphere_id = new.sphere_id;
  if v_cnt >= v_limit then
    raise exception 'photos_limit' using errcode = 'P0001',
      hint = 'Лимит фото в сфере исчерпан';
  end if;
  return new;
end $$;

-- Услуги входят в поиск сферы: при изменении пересчитываем
create or replace function public.tg_services_touch_sphere()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.spheres set updated_at = now() where id = coalesce(new.sphere_id, old.sphere_id);
  return null;
end $$;

create trigger services_limit before insert on public.services
  for each row execute function public.tg_services_limit();
create trigger services_touch after insert or update or delete on public.services
  for each row execute function public.tg_services_touch_sphere();
create trigger photos_limit before insert on public.photos
  for each row execute function public.tg_photos_limit();

-- ===== Отзывы =====
create or replace function public.tg_reviews_before()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.author_id := auth.uid();
      if not public.is_registered() then
        raise exception 'registration_required' using errcode = 'P0001';
      end if;
      if new.profile_id = new.author_id then
        raise exception 'review_own_profile' using errcode = 'P0001';
      end if;
      if not exists (select 1 from public.contact_events
                     where customer_id = new.author_id and profile_id = new.profile_id
                       and created_at > now() - interval '30 days') then
        raise exception 'review_no_contact' using errcode = 'P0001',
          hint = 'Отзыв можно оставить в течение 30 дней после звонка мастеру';
      end if;
    end if;
    new.reply := null;
    new.replied_at := null;
    new.is_hidden := false;
    new.created_at := now();
  elsif new.reply is distinct from old.reply then
    new.replied_at := case when new.reply is null then null else now() end;
  end if;
  return new;
end $$;

create or replace function public.tg_reviews_rating()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_profile uuid := coalesce(new.profile_id, old.profile_id);
begin
  update public.profiles p
     set reviews_count = r.cnt, rating_avg = r.avg
  from (select count(*)::int as cnt, round(avg(rating)::numeric, 1) as avg
        from public.reviews where profile_id = v_profile and not is_hidden) r
  where p.id = v_profile;
  return null;
end $$;

create trigger reviews_before before insert or update on public.reviews
  for each row execute function public.tg_reviews_before();
create trigger reviews_rating after insert or delete or update of rating, is_hidden on public.reviews
  for each row execute function public.tg_reviews_rating();

-- ===== Жалобы: автоскрытие после 3 жалоб от разных людей =====
create or replace function public.tg_complaints_before()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then
    new.author_id := auth.uid();
    if not public.is_registered() then
      raise exception 'registration_required' using errcode = 'P0001';
    end if;
    if new.target_type = 'profile' and new.target_id = auth.uid() then
      raise exception 'complaint_own_profile' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

create or replace function public.tg_complaints_autohide()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_cnt int; v_owner uuid;
begin
  select count(distinct author_id) into v_cnt from public.complaints
  where target_type = new.target_type and target_id = new.target_id;
  if v_cnt < 3 then return null; end if;

  if new.target_type = 'profile' then
    update public.profiles set is_hidden = true where id = new.target_id and not is_hidden
      returning id into v_owner;
  elsif new.target_type = 'sphere' then
    update public.spheres set status = 'hidden'
      where id = new.target_id and status not in ('hidden','blocked')
      returning profile_id into v_owner;
  elsif new.target_type = 'review' then
    update public.reviews set is_hidden = true where id = new.target_id;
  end if;

  if v_owner is not null then
    insert into public.notifications (user_id, kind, payload)
    values (v_owner, 'hidden_by_complaints',
            jsonb_build_object('target_type', new.target_type, 'target_id', new.target_id));
  end if;
  return null;
end $$;

create trigger complaints_before before insert on public.complaints
  for each row execute function public.tg_complaints_before();
create trigger complaints_autohide after insert on public.complaints
  for each row execute function public.tg_complaints_autohide();

-- ===== Избранное, согласия, push: владелец — текущий пользователь =====
create or replace function public.tg_force_user_id()
returns trigger language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then
    new.user_id := auth.uid();
  end if;
  return new;
end $$;

create trigger favorites_user before insert on public.favorites
  for each row execute function public.tg_force_user_id();
create trigger consents_user before insert on public.consents
  for each row execute function public.tg_force_user_id();
create trigger push_user before insert on public.push_subscriptions
  for each row execute function public.tg_force_user_id();

-- ==================== 003_rls ====================
alter table public.cities enable row level security;
alter table public.categories enable row level security;
alter table public.plan_limits enable row level security;
alter table public.profiles enable row level security;
alter table public.profile_contacts enable row level security;
alter table public.spheres enable row level security;
alter table public.services enable row level security;
alter table public.photos enable row level security;
alter table public.contact_events enable row level security;
alter table public.reviews enable row level security;
alter table public.complaints enable row level security;
alter table public.favorites enable row level security;
alter table public.payments enable row level security;
alter table public.trial_grants enable row level security;
alter table public.consents enable row level security;
alter table public.stats_daily enable row level security;
alter table public.search_queries enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notifications enable row level security;
alter table public.deletion_requests enable row level security;
alter table public.storage_cleanup enable row level security;

-- Справочники
create policy cities_read on public.cities for select to anon, authenticated using (is_active);
create policy categories_read on public.categories for select to anon, authenticated using (is_active);
create policy plan_limits_read on public.plan_limits for select to anon, authenticated using (true);

-- Профили
create policy profiles_read on public.profiles for select to anon, authenticated
  using ((deleted_at is null and not is_hidden) or id = (select auth.uid()));
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = (select auth.uid()) and (select public.is_registered()));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy contacts_own_read on public.profile_contacts for select to authenticated
  using (profile_id = (select auth.uid()));
create policy contacts_own_update on public.profile_contacts for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

-- Сферы
create policy spheres_read on public.spheres for select to anon, authenticated
  using ((status = 'active' and public.profile_is_public(profile_id)) or profile_id = (select auth.uid()));
create policy spheres_insert on public.spheres for insert to authenticated
  with check (profile_id = (select auth.uid()));
create policy spheres_update on public.spheres for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));
create policy spheres_delete on public.spheres for delete to authenticated
  using (profile_id = (select auth.uid()));

-- Услуги и фото
create policy services_read on public.services for select to anon, authenticated
  using ((not is_hidden and public.sphere_is_public(sphere_id)) or public.owns_sphere(sphere_id));
create policy services_insert on public.services for insert to authenticated
  with check (public.owns_sphere(sphere_id));
create policy services_update on public.services for update to authenticated
  using (public.owns_sphere(sphere_id)) with check (public.owns_sphere(sphere_id));
create policy services_delete on public.services for delete to authenticated
  using (public.owns_sphere(sphere_id));

create policy photos_read on public.photos for select to anon, authenticated
  using ((not is_hidden and public.sphere_is_public(sphere_id)) or public.owns_sphere(sphere_id));
create policy photos_insert on public.photos for insert to authenticated
  with check (public.owns_sphere(sphere_id));
create policy photos_update on public.photos for update to authenticated
  using (public.owns_sphere(sphere_id)) with check (public.owns_sphere(sphere_id));
create policy photos_delete on public.photos for delete to authenticated
  using (public.owns_sphere(sphere_id));

-- Журнал контактов: заказчик видит свою историю звонков
create policy contact_events_own on public.contact_events for select to authenticated
  using (customer_id = (select auth.uid()));

-- Отзывы
create policy reviews_read on public.reviews for select to anon, authenticated
  using ((not is_hidden and public.profile_is_public(profile_id))
         or author_id = (select auth.uid()) or profile_id = (select auth.uid()));
create policy reviews_insert on public.reviews for insert to authenticated
  with check ((select public.is_registered()));
create policy reviews_reply on public.reviews for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

-- Жалобы (только запись)
create policy complaints_insert on public.complaints for insert to authenticated
  with check ((select public.is_registered()));

-- Избранное
create policy favorites_read on public.favorites for select to authenticated
  using (user_id = (select auth.uid()));
create policy favorites_insert on public.favorites for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.is_registered()));
create policy favorites_delete on public.favorites for delete to authenticated
  using (user_id = (select auth.uid()));

-- Деньги, статистика (только для Про), служебное
create policy payments_own on public.payments for select to authenticated
  using (profile_id = (select auth.uid()));
create policy stats_own_pro on public.stats_daily for select to authenticated
  using (profile_id = (select auth.uid()) and public.profile_is_pro(profile_id));
create policy consents_own_read on public.consents for select to authenticated
  using (user_id = (select auth.uid()));
create policy consents_own_insert on public.consents for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy push_own_read on public.push_subscriptions for select to authenticated
  using (user_id = (select auth.uid()));
create policy push_own_insert on public.push_subscriptions for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy push_own_delete on public.push_subscriptions for delete to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_own_read on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_own_update on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- trial_grants, search_queries, deletion_requests, storage_cleanup: только через функции

-- ==================== 004_rpc ====================
-- ===== Номер мастера: фиксирует контакт, лимит 20 (гость) / 50 (зарегистрированный) мастеров в сутки =====
create or replace function public.get_contact(p_profile uuid, p_sphere uuid default null,
                                              p_kind public.contact_kind default 'call')
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_anon boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_limit int;
  v_used int;
  v_phone text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = 'P0001';
  end if;
  if not public.profile_is_public(p_profile) and p_profile <> v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  v_limit := case when v_anon then 20 else 50 end;

  if p_profile <> v_uid then
    -- повторный контакт с тем же мастером за сутки лимит не тратит
    if not exists (select 1 from public.contact_events
                   where customer_id = v_uid and profile_id = p_profile
                     and created_at > now() - interval '24 hours') then
      select count(distinct profile_id) into v_used from public.contact_events
      where customer_id = v_uid and created_at > now() - interval '24 hours';
      if v_used >= v_limit then
        raise exception 'daily_limit' using errcode = 'P0001',
          hint = 'Лимит номеров на сегодня исчерпан';
      end if;
    end if;

    insert into public.contact_events (customer_id, profile_id, sphere_id, kind)
    values (v_uid, p_profile, p_sphere, p_kind);

    insert into public.stats_daily (profile_id, day, contacts)
    values (p_profile, (now() at time zone 'Asia/Yakutsk')::date, 1)
    on conflict (profile_id, day) do update set contacts = public.stats_daily.contacts + 1;
  end if;

  select phone into v_phone from public.profile_contacts where profile_id = p_profile;
  return v_phone;
end $$;

-- ===== Публикация / продление сферы (+ пробный Про при первой публикации) =====
create or replace function public.publish_sphere(p_sphere uuid)
returns public.spheres language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.spheres;
  v_limit int;
  v_active int;
  v_phone text;
  v_until timestamptz;
begin
  select * into s from public.spheres where id = p_sphere for update;
  if not found or s.profile_id is distinct from v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if s.status in ('hidden','blocked') then
    raise exception 'sphere_blocked' using errcode = 'P0001';
  end if;

  -- 3 месяца Про — один раз на номер телефона (учёт по хешу)
  select phone into v_phone from auth.users where id = v_uid;
  if v_phone is not null and v_phone <> '' then
    insert into public.trial_grants (phone_hash)
    values (encode(extensions.digest('uustarybul:' || v_phone, 'sha256'), 'hex'))
    on conflict do nothing;
    if found then
      update public.profiles
         set pro_until = greatest(coalesce(pro_until, now()), now()) + interval '3 months'
       where id = v_uid
       returning pro_until into v_until;
      insert into public.notifications (user_id, kind, payload)
      values (v_uid, 'trial_started', jsonb_build_object('pro_until', v_until));
    end if;
  end if;

  if s.status <> 'active' then
    select l.spheres into v_limit from public.profile_limits(v_uid) l;
    select count(*) into v_active from public.spheres where profile_id = v_uid and status = 'active';
    if v_active >= v_limit then
      raise exception 'spheres_limit' using errcode = 'P0001',
        hint = 'Лимит активных сфер исчерпан';
    end if;
  end if;

  update public.spheres
     set status = 'active',
         published_at = coalesce(published_at, now()),
         expires_at = now() + interval '30 days',
         reminded_at = null
   where id = p_sphere
   returning * into s;
  return s;
end $$;

create or replace function public.unpublish_sphere(p_sphere uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.spheres set status = 'draft'
  where id = p_sphere and profile_id = auth.uid() and status in ('active','paused','expired');
end $$;

-- ===== Просмотр страницы мастера (только агрегаты) =====
create or replace function public.track_view(p_profile uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.stats_daily (profile_id, day, views)
  select p_profile, (now() at time zone 'Asia/Yakutsk')::date, 1
  where p_profile is distinct from auth.uid() and public.profile_is_public(p_profile)
  on conflict (profile_id, day) do update set views = public.stats_daily.views + 1;
$$;

-- ===== Поиск: только по параметрам пользователя; Про и продление на порядок не влияют =====
-- p_sort: 'default' — релевантность, затем ежедневное перемешивание; 'rating' — по рейтингу
create or replace function public.search_spheres(
  p_city int, p_category int default null, p_query text default null,
  p_sort text default 'default', p_limit int default 20, p_offset int default 0)
returns table (
  sphere_id uuid, title text, category_id int, profile_id uuid, display_name text,
  kind public.profile_kind, avatar_path text, travels boolean, rating_avg numeric,
  reviews_count int, price_from int, photo_path text, rank real)
language sql stable set search_path = '' as $$
  with q as (
    select
      case when w.words is null then null
           else to_tsquery('russian', w.words) end as tsq,
      nullif(lower(trim(p_query)), '') as raw
    from (
      select string_agg(quote_literal(t) || ':*', ' & ') as words
      from regexp_split_to_table(
             lower(trim(regexp_replace(coalesce(p_query, ''), '[^[:alnum:][:space:]-]', ' ', 'g'))),
             '\s+') t
      where t <> ''
    ) w
  )
  select s.id, s.title, s.category_id, p.id, p.display_name, p.kind, p.avatar_path, p.travels,
         case when p.reviews_count >= 3 then p.rating_avg end,
         p.reviews_count,
         (select min(sv.price_from) from public.services sv
           where sv.sphere_id = s.id and not sv.is_hidden),
         (select ph.storage_path from public.photos ph
           where ph.sphere_id = s.id and not ph.is_hidden
           order by ph.sort, ph.created_at limit 1),
         case when q.raw is null then 0::real
              else coalesce(ts_rank(s.search_doc, q.tsq), 0)
                   + extensions.word_similarity(q.raw, s.search_text) end as rank
  from public.spheres s
  join public.profiles p on p.id = s.profile_id
  cross join q
  where s.status = 'active'
    and p.city_id = p_city and p.deleted_at is null and not p.is_hidden
    and (p_category is null or s.category_id = p_category)
    and (q.raw is null
         or (q.tsq is not null and s.search_doc @@ q.tsq)
         or q.raw operator(extensions.<%) s.search_text)
  order by
    case when p_sort = 'rating' and p.reviews_count >= 3 then p.rating_avg end desc nulls last,
    rank desc,
    md5(s.id::text || current_date::text)
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;

-- Счётчик «N мастеров в городе»
create or replace function public.count_masters(p_city int)
returns int language sql stable set search_path = '' as $$
  select count(distinct s.profile_id)::int
  from public.spheres s join public.profiles p on p.id = s.profile_id
  where s.status = 'active' and p.city_id = p_city and p.deleted_at is null and not p.is_hidden
$$;

-- Запоминаем запрос, только если по нему что-то нашлось (подсказки всегда «живые»)
create or replace function public.log_search(p_city int, p_query text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_q text := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g')));
begin
  if char_length(v_q) not between 2 and 60 then return; end if;
  if not exists (select 1 from public.search_spheres(p_city, null, v_q, 'default', 1, 0)) then return; end if;
  insert into public.search_queries (city_id, query) values (p_city, v_q)
  on conflict (city_id, query) do update set hits = public.search_queries.hits + 1, last_at = now();
end $$;

-- Подсказки и популярные запросы (пустой префикс = популярные)
create or replace function public.suggest_queries(p_city int, p_prefix text default '', p_limit int default 8)
returns setof text language sql stable security definer set search_path = '' as $$
  select query from public.search_queries
  where city_id = p_city and hits >= 2
    and query like replace(replace(lower(trim(coalesce(p_prefix, ''))), '%', ''), '_', '') || '%'
  order by hits desc, last_at desc
  limit least(greatest(p_limit, 1), 20)
$$;

-- ===== Удаление аккаунта: сразу скрывается, через 7 дней удаляется окончательно =====
create or replace function public.request_account_deletion()
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth_required' using errcode = 'P0001'; end if;
  insert into public.deletion_requests (user_id) values (v_uid) on conflict do nothing;
  update public.profiles set deleted_at = now() where id = v_uid and deleted_at is null;
  delete from public.push_subscriptions where user_id = v_uid;
end $$;

create or replace function public.cancel_account_deletion()
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  delete from public.deletion_requests where user_id = v_uid;
  update public.profiles set deleted_at = null where id = v_uid;
end $$;

create or replace function public.process_account_deletions()
returns int language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select user_id from public.deletion_requests
           where requested_at < now() - interval '7 days' loop
    update public.reviews set author_name = 'Удалённый пользователь' where author_id = r.user_id;
    insert into public.storage_cleanup (prefix) values (r.user_id::text);
    delete from auth.users where id = r.user_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ===== Оплата: вызывает только сервер (вебхук платёжного сервиса) =====
create or replace function public.apply_payment(p_provider_payment_id text)
returns public.payments language plpgsql security definer set search_path = '' as $$
declare v public.payments; v_start timestamptz; v_until timestamptz; v_extra int;
begin
  update public.payments set status = 'paid', paid_at = now()
   where provider_payment_id = p_provider_payment_id and status = 'pending'
   returning * into v;
  if not found then   -- повторный вебхук: ничего не делаем
    select * into v from public.payments where provider_payment_id = p_provider_payment_id;
    return v;
  end if;

  if v.kind = 'pro_1m' or v.kind = 'pro_3m' then
    select greatest(coalesce(pro_until, now()), now()) into v_start
    from public.profiles where id = v.profile_id for update;
    if v.kind = 'pro_1m' then
      v_until := v_start + interval '1 month';
    else
      v_until := v_start + interval '3 months';
    end if;
    update public.profiles set pro_until = v_until where id = v.profile_id;
  else  -- доп. сферы: только при активном Про и на тот же срок
    update public.profiles
       set extra_spheres = (case when extra_spheres_until > now() then extra_spheres else 0 end) + v.quantity,
           extra_spheres_until = pro_until
     where id = v.profile_id and pro_until > now()
     returning pro_until into v_until;
    if not found then
      raise exception 'pro_required' using errcode = 'P0001';
    end if;
    v_start := now();
  end if;

  update public.payments set period_start = v_start, period_end = v_until
   where id = v.id returning * into v;
  return v;
end $$;

-- ==================== 005_cron_storage_seed_grants ====================
-- ===== Ежедневная автоматика =====
create or replace function public.daily_maintenance()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  -- 1. Про: карточки продлеваются сами
  update public.spheres s
     set expires_at = s.expires_at + interval '30 days', reminded_at = null
    from public.profiles p
   where p.id = s.profile_id and s.status = 'active' and p.pro_until > now()
     and s.expires_at < now() + interval '1 day';

  -- 2. Бесплатные: напоминание за 2–3 дня до конца
  with e as (
    update public.spheres s set reminded_at = now()
      from public.profiles p
     where p.id = s.profile_id and s.status = 'active' and s.reminded_at is null
       and s.expires_at < now() + interval '3 days'
       and not (coalesce(p.pro_until > now(), false))
    returning s.id, s.profile_id, s.title, s.expires_at)
  insert into public.notifications (user_id, kind, payload)
  select profile_id, 'sphere_expiring',
         jsonb_build_object('sphere_id', id, 'title', title, 'expires_at', expires_at) from e;

  -- 3. Истёкшие карточки скрываются (не удаляются)
  with e as (
    update public.spheres set status = 'expired'
     where status = 'active' and expires_at < now()
    returning id, profile_id, title)
  insert into public.notifications (user_id, kind, payload)
  select profile_id, 'sphere_expired', jsonb_build_object('sphere_id', id, 'title', title) from e;

  -- 4. Про заканчивается через 7 дней
  insert into public.notifications (user_id, kind, payload)
  select p.id,
         case when exists (select 1 from public.payments pm
                           where pm.profile_id = p.id and pm.status = 'paid'
                             and pm.kind in ('pro_1m','pro_3m'))
              then 'pro_ending' else 'trial_ending' end,
         jsonb_build_object('pro_until', p.pro_until)
    from public.profiles p
   where p.pro_until >= now() + interval '6 days' and p.pro_until < now() + interval '7 days';

  -- 5. Доп. сферы сгорают вместе с периодом Про
  update public.profiles set extra_spheres = 0, extra_spheres_until = null
   where extra_spheres > 0 and (extra_spheres_until is null or extra_spheres_until < now());

  -- 6. Про закончился — применяем бесплатные лимиты
  for r in select id from public.profiles
           where pro_until < now() and pro_until > now() - interval '2 days' loop
    perform public.apply_plan_limits(r.id);
  end loop;

  -- 7. Окончательное удаление аккаунтов
  perform public.process_account_deletions();

  -- 8. Чистка
  delete from public.contact_events where created_at < now() - interval '180 days';
  delete from public.notifications where created_at < now() - interval '90 days';
  delete from public.search_queries where last_at < now() - interval '180 days' and hits < 3;
  delete from auth.users
   where is_anonymous and coalesce(last_sign_in_at, created_at) < now() - interval '60 days';
end $$;

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
-- каждый день в 09:07 по Якутску (00:07 UTC)
select cron.schedule('uustarybul-daily', '7 0 * * *', $$select public.daily_maintenance()$$);

-- ===== Хранилище фото: публичное чтение, запись только в свою папку =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy photos_upload_own on storage.objects for insert to authenticated
  with check (bucket_id = 'photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text
              and (select public.is_registered()));
create policy photos_update_own on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy photos_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ===== Справочники =====
insert into public.plan_limits (plan, spheres, services_per_sphere, photos_per_sphere) values
  ('free', 2, 5, 10),
  ('pro',  5, null, 30);

insert into public.cities (name, region, sort) values
  ('Олёкминск', 'Республика Саха (Якутия)', 1);

insert into public.categories (slug, name, icon, sort) values
  ('remont',      'Ремонт и стройка',        'hammer',      1),
  ('santehnika',  'Сантехника',              'droplet',     2),
  ('elektrika',   'Электрика',               'zap',         3),
  ('svarka',      'Сварка',                  'flame',       4),
  ('avto',        'Авто',                    'car',         5),
  ('drova',       'Дрова и пиломатериалы',   'trees',       6),
  ('vyvoz-tbo',   'Вывоз мусора',            'trash',       7),
  ('septik',      'Откачка септика',         'truck',       8),
  ('zdorovie',    'Здоровье',                'heart-pulse', 9),
  ('krasota',     'Красота',                 'sparkles',   10),
  ('obuchenie',   'Репетиторы и обучение',   'book-open',  11),
  ('yurist',      'Юридические услуги',      'scale',      12),
  ('strahovanie', 'Страхование',             'shield',     13),
  ('bytovye',     'Бытовые услуги',          'home',       14);

-- ===== Права на функции: закрыть всё, открыть только нужное =====
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_registered() to anon, authenticated;
grant execute on function public.profile_is_public(uuid) to anon, authenticated;
grant execute on function public.sphere_is_public(uuid) to anon, authenticated;
grant execute on function public.owns_sphere(uuid) to anon, authenticated;
grant execute on function public.profile_is_pro(uuid) to authenticated;
grant execute on function public.profile_limits(uuid) to authenticated;

grant execute on function public.search_spheres(int, int, text, text, int, int) to anon, authenticated;
grant execute on function public.count_masters(int) to anon, authenticated;
grant execute on function public.suggest_queries(int, text, int) to anon, authenticated;
grant execute on function public.log_search(int, text) to anon, authenticated;
grant execute on function public.track_view(uuid) to anon, authenticated;

grant execute on function public.get_contact(uuid, uuid, public.contact_kind) to authenticated;
grant execute on function public.publish_sphere(uuid) to authenticated;
grant execute on function public.unpublish_sphere(uuid) to authenticated;
grant execute on function public.request_account_deletion() to authenticated;
grant execute on function public.cancel_account_deletion() to authenticated;
-- apply_payment, apply_plan_limits, process_account_deletions, daily_maintenance — только сервер

-- ==================== 006_demo_flag ====================
alter table public.profiles add column is_demo boolean not null default false;

-- Удаление всех демо-мастеров одной командой: select public.purge_demo();
create or replace function public.purge_demo()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from public.search_queries where hits >= 1 and last_at < now() + interval '1 second'
    and query in ('откачка септика','дрова','электрик','уколы на дому','сантехник','утепление');
  with d as (delete from auth.users where id in (select id from public.profiles where is_demo) returning 1)
  select count(*) into n from d;
  return n;
end $$;
revoke execute on function public.purge_demo() from public, anon, authenticated;

-- ==================== 007a_phone_tables ====================
create table public.phone_verify_codes (
  session_key text primary key,
  phone text not null,
  pincode text not null,
  attempts int not null default 0,
  created_at timestamptz not null default now()
);
create table public.phone_verify_log (
  id bigint generated always as identity primary key,
  session_key text not null,
  phone text not null,
  kind text not null,
  created_at timestamptz not null default now()
);
create index phone_verify_log_phone_idx on public.phone_verify_log (phone, created_at desc);
create index phone_verify_log_session_idx on public.phone_verify_log (session_key, created_at desc);
alter table public.phone_verify_codes enable row level security;
alter table public.phone_verify_log enable row level security;
revoke all on public.phone_verify_codes, public.phone_verify_log from anon, authenticated;

-- ==================== 007b_phone_call_allowed ====================
create or replace function public.phone_call_allowed(p_session text, p_phone text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when (select count(*) from public.phone_verify_log where session_key = p_session and created_at > now() - interval '10 minutes') >= 3
      then 'Слишком много звонков. Попробуйте через 10 минут.'
    when (select count(*) from public.phone_verify_log where phone = p_phone and created_at > now() - interval '1 day') >= 6
      then 'На этот номер сегодня уже много звонили. Попробуйте завтра.'
    when (select count(*) from public.phone_verify_log where created_at > now() - interval '1 hour') >= 200
      then 'Сервис входа перегружен. Попробуйте позже.'
    else null end
$$;
revoke execute on function public.phone_call_allowed(text, text) from public, anon, authenticated;

-- ==================== 007c_find_user_by_phone ====================
create or replace function public.find_user_by_phone(p_phone text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from auth.users where phone = p_phone and not coalesce(is_anonymous, false) limit 1
$$;
revoke execute on function public.find_user_by_phone(text) from public, anon, authenticated;

-- ==================== 007d_mark_registered ====================
create or replace function public.mark_registered(p_uid uuid)
returns void language sql security definer set search_path = '' as $$
  update auth.users set is_anonymous = false where id = p_uid
$$;
revoke execute on function public.mark_registered(uuid) from public, anon, authenticated;

-- ==================== 007e_merge_guest ====================
-- Гость вошёл в существующий аккаунт: переносим его звонки (право на отзыв).
-- Сам гостевой аккаунт удалится ежедневной чисткой неактивных гостей.
create or replace function public.merge_guest(p_guest uuid, p_target uuid)
returns void language sql security definer set search_path = '' as $$
  update public.contact_events set customer_id = p_target
  where customer_id = p_guest and p_guest is distinct from p_target
    and exists (select 1 from auth.users where id = p_guest and is_anonymous);
$$;
revoke execute on function public.merge_guest(uuid, uuid) from public, anon, authenticated;

-- ==================== 008_pg_net ====================
create extension if not exists pg_net with schema extensions;

-- ==================== 009_experience_review_title_notify_prefs ====================
-- Опыт мастера: год начала работы (опыт в годах считает приложение, цифра не устаревает)
alter table public.profiles add column if not exists work_since smallint
  check (work_since is null or work_since between 1950 and 2100);
grant select (work_since) on public.profiles to anon, authenticated;
grant insert (work_since), update (work_since) on public.profiles to authenticated;

-- Заголовок отзыва («Коротко»)
alter table public.reviews add column if not exists title text
  check (title is null or char_length(title) between 1 and 80);
grant select (title) on public.reviews to anon, authenticated;
grant insert (title) on public.reviews to authenticated;

-- Настройки уведомлений (видит и меняет только владелец)
create table if not exists public.notify_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  expiry boolean not null default true,   -- срок карточек и Про
  reviews boolean not null default true,  -- новые отзывы
  updated_at timestamptz not null default now()
);
alter table public.notify_prefs enable row level security;
revoke all on public.notify_prefs from anon, authenticated;
grant select, insert (user_id, expiry, reviews), update (expiry, reviews, updated_at) on public.notify_prefs to authenticated;
create policy notify_prefs_own_read on public.notify_prefs for select to authenticated using (user_id = (select auth.uid()));
create policy notify_prefs_own_insert on public.notify_prefs for insert to authenticated with check (user_id = (select auth.uid()) and (select public.is_registered()));
create policy notify_prefs_own_update on public.notify_prefs for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ==================== 010_find_spheres_with_filter ====================
-- Поиск с фильтрами (замена search_spheres; старая остаётся, приложение её больше не вызывает)
CREATE OR REPLACE FUNCTION public.find_spheres(p_city integer, p_category integer DEFAULT NULL::integer, p_query text DEFAULT NULL::text, p_sort text DEFAULT 'default'::text, p_filter text DEFAULT 'all'::text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS TABLE(sphere_id uuid, title text, category_id integer, profile_id uuid, display_name text, kind profile_kind, avatar_path text, travels boolean, rating_avg numeric, reviews_count integer, price_from integer, photo_path text, rank real)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select * from public.search_spheres(p_city, p_category, p_query, p_sort, 50, 0) r
  where coalesce(p_filter, 'all') = 'all'
     or (p_filter = 'reviews' and r.reviews_count > 0)
     or (p_filter = 'photos' and r.photo_path is not null)
     or (p_filter = 'new' and exists (select 1 from public.profiles p where p.id = r.profile_id and p.created_at >= now() - interval '30 days'))
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$function$;
grant execute on function public.find_spheres(integer, integer, text, text, text, integer, integer) to anon, authenticated;

-- ==================== 011_notify_prefs_upsert_grant ====================
grant update (user_id) on public.notify_prefs to authenticated;

-- ==================== 012_consent_review_distribution ====================
-- Согласие автора отзыва на показ подписи (вариант Б согласия на распространение)
alter type public.consent_kind add value if not exists 'pd_distribution_review';

-- ==================== 013_push ====================
-- 013. Push-уведомления: тихие часы, очередь отправки, ключи VAPID, отзывы в очередь.

alter table public.cities add column if not exists tz text not null default 'Asia/Yakutsk';

alter table public.notify_prefs
  add column if not exists quiet boolean not null default false,
  add column if not exists quiet_from smallint not null default 22 check (quiet_from between 0 and 23),
  add column if not exists quiet_to smallint not null default 8 check (quiet_to between 0 and 23);
grant select (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;
grant insert (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;
grant update (quiet, quiet_from, quiet_to) on public.notify_prefs to authenticated;

alter table public.push_subscriptions
  add column if not exists disabled_at timestamptz,
  add column if not exists last_ok_at timestamptz,
  add column if not exists fail_count smallint not null default 0;

alter table public.notifications
  add column if not exists push_status text,
  add column if not exists push_attempts smallint not null default 0;

create or replace function public.in_quiet_hours(p_on boolean, p_from smallint, p_to smallint, p_tz text)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(p_on, false) and p_from is distinct from p_to and (
    case when p_from < p_to
         then extract(hour from now() at time zone p_tz) >= p_from and extract(hour from now() at time zone p_tz) < p_to
         else extract(hour from now() at time zone p_tz) >= p_from or  extract(hour from now() at time zone p_tz) < p_to end)
$$;

create or replace function public.tg_review_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, kind, payload)
  select new.profile_id, 'new_review', jsonb_build_object('review_id', new.id, 'rating', new.rating)
   where exists (select 1 from auth.users u where u.id = new.profile_id);
  return null;
end $$;
create trigger reviews_notify after insert on public.reviews
  for each row execute function public.tg_review_notify();

create or replace function public.push_kick()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://icojobutpjjvsjkizaak.supabase.co/functions/v1/send-push',
    body := '{}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then null;
end $$;

create or replace function public.tg_notifications_kick()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.push_kick();
  return null;
end $$;
create trigger notifications_kick after insert on public.notifications
  for each statement execute function public.tg_notifications_kick();

create or replace function public.push_take(p_limit int default 200)
returns table (r_nid bigint, r_kind text, r_payload jsonb, r_tz text,
               r_sub bigint, r_endpoint text, r_p256dh text, r_auth text)
language plpgsql security definer set search_path = '' as $$
begin
  update public.notifications set sent_at = null, push_status = 'retry'
   where push_status = 'sending' and sent_at < now() - interval '10 minutes' and push_attempts < 3;

  update public.notifications n set sent_at = now(), push_status = x.st
    from (
      select n2.id, case
        when n2.created_at < now() - interval '3 days' then 'stale'
        when p.deleted_at is not null then 'off'
        when n2.kind in ('sphere_expiring','sphere_expired','pro_ending','trial_ending','trial_started')
             and np.expiry is false then 'off'
        when n2.kind = 'new_review' and np.reviews is false then 'off'
        when not exists (select 1 from public.push_subscriptions s
                          where s.user_id = n2.user_id and s.disabled_at is null) then 'no_device'
      end as st
      from public.notifications n2
      left join public.profiles p on p.id = n2.user_id
      left join public.notify_prefs np on np.user_id = n2.user_id
      where n2.sent_at is null
    ) x
   where x.id = n.id and x.st is not null;

  return query
  with c as (
    update public.notifications n
       set sent_at = now(), push_status = 'sending', push_attempts = n.push_attempts + 1
     where n.id in (
       select n2.id from public.notifications n2
         left join public.profiles p on p.id = n2.user_id
         left join public.cities ci on ci.id = p.city_id
         left join public.notify_prefs np on np.user_id = n2.user_id
        where n2.sent_at is null
          and not public.in_quiet_hours(np.quiet, np.quiet_from, np.quiet_to, coalesce(ci.tz, 'Asia/Yakutsk'))
        order by n2.created_at
        limit p_limit
        for update of n2 skip locked)
    returning n.id, n.user_id, n.kind, n.payload)
  select c.id, c.kind, c.payload, coalesce(ci.tz, 'Asia/Yakutsk'),
         s.id, s.endpoint, s.p256dh, s.auth
    from c
    left join public.profiles p on p.id = c.user_id
    left join public.cities ci on ci.id = p.city_id
    join public.push_subscriptions s on s.user_id = c.user_id and s.disabled_at is null;
end $$;

create or replace function public.push_done(p_sent bigint[], p_retry bigint[], p_failed bigint[],
                                            p_dead bigint[], p_ok bigint[], p_bad bigint[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.notifications set push_status = 'sent' where id = any(p_sent);
  update public.notifications set push_status = 'failed' where id = any(p_failed);
  update public.notifications set sent_at = null, push_status = 'retry'
   where id = any(p_retry) and push_attempts < 3;
  update public.notifications set push_status = 'failed'
   where id = any(p_retry) and push_attempts >= 3;
  update public.push_subscriptions set disabled_at = now() where id = any(p_dead);
  update public.push_subscriptions set last_ok_at = now(), fail_count = 0 where id = any(p_ok);
  update public.push_subscriptions set fail_count = fail_count + 1,
         disabled_at = case when fail_count + 1 >= 10 then now() else disabled_at end
   where id = any(p_bad);
end $$;

create or replace function public.push_vapid_get()
returns table (r_pub text, r_priv text) language sql security definer set search_path = '' as $$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'),
         (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_private')
$$;

create or replace function public.push_vapid_set(p_pub text, p_priv text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from vault.secrets where name = 'push_vapid_private') then return false; end if;
  perform vault.create_secret(p_priv, 'push_vapid_private', 'Уустары бул: закрытый ключ VAPID');
  perform vault.create_secret(p_pub, 'push_vapid_public', 'Уустары бул: открытый ключ VAPID');
  return true;
end $$;

create or replace function public.push_public_key()
returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'
$$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_host text;
begin
  if v_uid is null or not public.is_registered() then
    raise exception 'not_registered' using errcode = 'P0001';
  end if;
  v_host := substring(p_endpoint from '^https://([^/:]+)');
  if v_host is null or length(p_endpoint) > 1000 or v_host ~ '^[0-9.]+$' or v_host !~ '\.'
     or length(coalesce(p_p256dh,'')) not between 40 and 200 or length(coalesce(p_auth,'')) not between 10 and 100 then
    raise exception 'bad_subscription' using errcode = 'P0001';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (v_uid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
     set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
         disabled_at = null, fail_count = 0;
  update public.push_subscriptions set disabled_at = now()
   where user_id = v_uid and disabled_at is null
     and id not in (select id from public.push_subscriptions
                     where user_id = v_uid and disabled_at is null
                     order by created_at desc limit 5);
end $$;

revoke all on function public.push_take(int), public.push_done(bigint[],bigint[],bigint[],bigint[],bigint[],bigint[]),
  public.push_vapid_get(), public.push_vapid_set(text,text), public.push_kick(),
  public.tg_review_notify(), public.tg_notifications_kick()
  from public, anon, authenticated;
grant execute on function public.push_take(int), public.push_done(bigint[],bigint[],bigint[],bigint[],bigint[],bigint[]),
  public.push_vapid_get(), public.push_vapid_set(text,text), public.push_kick() to service_role;
revoke all on function public.save_push_subscription(text,text,text) from public, anon;
grant execute on function public.save_push_subscription(text,text,text) to authenticated;
grant execute on function public.push_public_key() to anon, authenticated;

select cron.schedule('uustarybul-push', '*/10 * * * *', 'select public.push_kick()');

-- ==================== 014_professions ====================
-- 014 — сферы деятельности как профессии (13.10.2026)
alter table public.categories
  add column if not exists name_plural  text,
  add column if not exists short_name   text,
  add column if not exists grp          text,
  add column if not exists on_home      boolean not null default false,
  add column if not exists keywords     text not null default '',
  add column if not exists hint_service text,
  add column if not exists hint_unit    text,
  add column if not exists hint_query   text;

grant select (name_plural, short_name, grp, on_home, keywords, hint_service, hint_unit, hint_query)
  on public.categories to anon, authenticated;

create temp table _c (id int, slug text, name text, name_plural text, short_name text, grp text, sort int,
                      on_home bool, keywords text, hint_service text, hint_unit text, hint_query text) on commit drop;
insert into _c values
(2,    'santehnik',      'Сантехник', 'Сантехники', null, 'Дом и ремонт', 10, true,
 'сантехника водопровод канализация отопление трубы смеситель унитаз ванна бойлер водонагреватель засор радиатор батарея', 'Замена смесителя', 'за шт.', 'бойлер или засор'),
(3,    'elektrik',       'Электрик', 'Электрики', null, 'Дом и ремонт', 20, true,
 'электрика электромонтаж проводка розетка выключатель щиток автомат счётчик освещение люстра', 'Замена розетки', 'за шт.', 'проводка или щиток'),
(4,    'svarshchik',     'Сварщик', 'Сварщики', null, 'Дом и ремонт', 30, true,
 'сварка сварочные работы металл металлоконструкции ворота забор навес калитка', 'Сварка ворот', 'договорная', 'ворота или навес'),
(1,    'stroitel',       'Строитель-отделочник', 'Строители-отделочники', 'Строитель', 'Дом и ремонт', 40, true,
 'ремонт стройка строительство отделка утепление гипсокартон штукатурка плитка обои ламинат окна кровля фундамент', 'Укладка плитки', 'за м²', 'плитка или утепление'),
(null, 'plotnik',        'Плотник', 'Плотники', null, 'Дом и ремонт', 50, false,
 'плотницкие столяр дерево сруб баня крыша кровля пол крыльцо двери', 'Сборка сруба', 'договорная', 'сруб или баня'),
(null, 'pechnik',        'Печник', 'Печники', null, 'Дом и ремонт', 60, false,
 'печь печка камин дымоход труба кладка банная печь', 'Кладка печи', 'договорная', 'печь или дымоход'),
(null, 'remont-tehniki', 'Ремонт бытовой техники', 'Ремонт бытовой техники', 'Ремонт техники', 'Дом и ремонт', 70, false,
 'бытовая техника холодильник морозильник стиральная машина плита духовка микроволновка телевизор', 'Ремонт стиральной машины', 'за выезд', 'холодильник или стиральная'),
(null, 'remont-telefonov','Ремонт телефонов и компьютеров', 'Ремонт телефонов и компьютеров', 'Ремонт телефонов', 'Дом и ремонт', 80, false,
 'телефон смартфон компьютер ноутбук планшет экран стекло аккумулятор прошивка', 'Замена экрана телефона', 'за шт.', 'экран или ноутбук'),
(5,    'avtomehanik',    'Автомеханик', 'Автомеханики', null, 'Авто', 110, true,
 'авто автомобиль машина ремонт авто автосервис ходовая подвеска двигатель масло тормоза', 'Замена масла', 'за шт.', 'ходовая или масло'),
(null, 'avtoelektrik',   'Автоэлектрик', 'Автоэлектрики', null, 'Авто', 120, false,
 'авто автомобиль электрика автомобиля стартер генератор сигнализация автозапуск диагностика', 'Установка автозапуска', 'за шт.', 'стартер или автозапуск'),
(null, 'shinomontazh',   'Шиномонтаж', 'Шиномонтаж', null, 'Авто', 130, false,
 'шины колёса колеса резина переобувка балансировка вулканизация прокол', 'Переобувка', 'за колесо', 'переобувка или балансировка'),
(9,    'medsestra',      'Медсестра', 'Медсёстры', null, 'Здоровье', 210, true,
 'здоровье медсестра медбрат медицинская помощь на дому уколы инъекции капельница перевязка давление', 'Уколы на дому', 'за выезд', 'уколы или капельница'),
(null, 'massazhist',     'Массажист', 'Массажисты', null, 'Здоровье', 220, false,
 'массаж лечебный классический спина шея детский', 'Массаж спины', 'за сеанс', 'массаж спины'),
(null, 'sidelka',        'Сиделка', 'Сиделки', null, 'Здоровье', 230, false,
 'сиделка уход за пожилыми лежачий больной присмотр', 'Уход за пожилым человеком', 'за час', 'уход за пожилым'),
(null, 'parikmaher',     'Парикмахер', 'Парикмахеры', null, 'Красота', 310, false,
 'стрижка причёска прическа окрашивание укладка барбер', 'Мужская стрижка', 'за шт.', 'стрижка или окрашивание'),
(10,   'manikyur',       'Мастер маникюра', 'Мастера маникюра', null, 'Красота', 320, false,
 'красота маникюр педикюр ногти гель-лак наращивание', 'Маникюр с покрытием', 'за шт.', 'педикюр или наращивание'),
(null, 'kosmetolog',     'Косметолог', 'Косметологи', null, 'Красота', 330, false,
 'косметология чистка лица уход за кожей брови ресницы', 'Чистка лица', 'за процедуру', 'чистка лица или брови'),
(11,   'repetitor',      'Репетитор', 'Репетиторы', null, 'Обучение', 410, true,
 'обучение учитель занятия математика русский язык английский физика химия огэ егэ подготовка к школе', 'Математика ЕГЭ', 'за час', 'математика или ЕГЭ'),
(null, 'logoped',        'Логопед', 'Логопеды', null, 'Обучение', 420, false,
 'речь звуки постановка звуков дефектолог занятия с ребёнком', 'Постановка звуков', 'за занятие', 'постановка звуков'),
(7,    'vyvoz-musora',   'Вывоз мусора', 'Вывоз мусора', null, 'Услуги', 510, false,
 'мусор тбо строймусор вывоз хлама', 'Вывоз строймусора', 'за машину', 'строймусор'),
(8,    'septik',         'Откачка септика', 'Откачка септика', null, 'Услуги', 520, false,
 'септик выгребная яма ассенизатор откачка канализации', 'Откачка до 4 м³', 'за машину', 'выгребная яма'),
(6,    'drova',          'Дрова и пиломатериалы', 'Дрова и пиломатериалы', null, 'Услуги', 530, true,
 'дрова брус доска пиломатериал лес горбыль чурки', 'Дрова колотые', 'за машину', 'брус или доска'),
(null, 'gruzoperevozki', 'Грузоперевозки', 'Грузоперевозки', null, 'Услуги', 540, false,
 'переезд грузчики газель перевозка доставка груза', 'Переезд по городу', 'за час', 'переезд или грузчики'),
(14,   'uborka',         'Уборка', 'Уборка', null, 'Услуги', 550, false,
 'бытовые услуги клининг генеральная уборка мытьё окон', 'Генеральная уборка', 'за м²', 'мытьё окон'),
(null, 'remont-odezhdy', 'Ремонт одежды и обуви', 'Ремонт одежды и обуви', 'Ремонт одежды', 'Услуги', 560, false,
 'швея ателье пошив подшить молния ремонт обуви', 'Замена молнии', 'за шт.', 'молния или подшить'),
(null, 'fotograf',       'Фотограф', 'Фотографы', null, 'Услуги', 570, false,
 'фото фотосессия фотосъёмка съёмка свадьба выпускной', 'Фотосессия', 'за час', 'фотосессия или свадьба'),
(null, 'torty',          'Торты и выпечка', 'Торты и выпечка', null, 'Услуги', 580, false,
 'торт кондитер выпечка пироги на заказ', 'Торт на заказ', 'за кг', 'торт или пироги'),
(12,   'yurist',         'Юрист', 'Юристы', null, 'Услуги', 590, false,
 'юридические услуги адвокат консультация договор иск суд', 'Консультация', 'за час', 'договор или иск'),
(13,   'strahovoy-agent','Страховой агент', 'Страховые агенты', null, 'Услуги', 600, false,
 'страхование осаго каско полис', 'ОСАГО', 'договорная', 'ОСАГО или КАСКО');

create or replace function public.tg_spheres_before()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_cat record; v_services text; v_catwords text;
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.spheres where profile_id = new.profile_id) >= 20 then
      raise exception 'spheres_total_limit' using errcode = 'P0001', hint = 'Не больше 20 сфер в профиле';
    end if;
  end if;
  select name, name_plural, keywords into v_cat from public.categories where id = new.category_id;
  if v_cat.name is not null then new.title := v_cat.name; end if;
  v_catwords := coalesce(v_cat.name_plural, '') || ' ' || coalesce(v_cat.keywords, '');
  select coalesce(string_agg(title, ' ' order by sort), '') into v_services
  from public.services where sphere_id = new.id;
  new.search_text := lower(new.title || ' ' || v_catwords || ' ' || v_services);
  new.search_doc := setweight(to_tsvector('russian', new.title), 'A')
                 || setweight(to_tsvector('russian', v_catwords || ' ' || v_services), 'B')
                 || setweight(to_tsvector('russian', coalesce(new.description, '')), 'C');
  return new;
end $function$;

create or replace function public.tg_categories_reindex()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  update public.spheres set category_id = category_id where category_id = new.id;
  return null;
end $function$;

create or replace trigger categories_reindex after update of name, name_plural, keywords on public.categories
  for each row execute function public.tg_categories_reindex();

update public.categories c set slug=_c.slug, name=_c.name, name_plural=_c.name_plural, short_name=_c.short_name,
  grp=_c.grp, sort=_c.sort, on_home=_c.on_home, keywords=_c.keywords, hint_service=_c.hint_service,
  hint_unit=_c.hint_unit, hint_query=_c.hint_query, icon=_c.slug, is_active=true
from _c where _c.id = c.id;

insert into public.categories (slug, name, name_plural, short_name, grp, sort, on_home, keywords, hint_service, hint_unit, hint_query, is_active, icon)
select slug, name, name_plural, short_name, grp, sort, on_home, keywords, hint_service, hint_unit, hint_query, true, slug
from _c where id is null;

-- ==================== 015_avatar ====================
create or replace function public.tg_profiles_before()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if new.avatar_path is not null
     and (tg_op = 'INSERT' or new.avatar_path is distinct from old.avatar_path)
     and new.avatar_path !~ ('^' || new.id::text || '/avatar-[0-9a-z-]+\.jpg$') then
    raise exception 'avatar_path_invalid' using errcode = 'P0001', hint = 'Фото профиля должно лежать в папке мастера';
  end if;
  if tg_op = 'INSERT' then
    new.city_changed_at := null;
    return new;
  end if;
  if new.city_id is distinct from old.city_id then
    if old.city_changed_at is not null and old.city_changed_at > now() - interval '30 days' then
      raise exception 'city_change_too_soon'
        using errcode = 'P0001', hint = 'Город можно менять не чаще раза в 30 дней';
    end if;
    new.city_changed_at := now();
  end if;
  return new;
end $function$;

-- ==================== 016_free_pro ====================
-- 016: Про бесплатно для всех мастеров до даты запуска оплаты (решено 13.10.2026: до 7 сентября 2027)
create table if not exists public.app_settings (
  id boolean primary key default true check (id),
  free_pro_until timestamptz
);
insert into public.app_settings (id, free_pro_until)
values (true, '2027-09-07 23:59:59+09')
on conflict (id) do update set free_pro_until = excluded.free_pro_until;

alter table public.app_settings enable row level security;
create policy app_settings_read on public.app_settings for select using (true);
revoke insert, update, truncate, references, trigger on public.app_settings from anon, authenticated;
grant select on public.app_settings to anon, authenticated;

create or replace function public.free_pro_active_until()
returns timestamptz language sql stable security definer set search_path = '' as $$
  select free_pro_until from public.app_settings where id and free_pro_until > now()
$$;

create or replace function public.tg_profiles_before()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_free timestamptz;
begin
  if new.avatar_path is not null
     and (tg_op = 'INSERT' or new.avatar_path is distinct from old.avatar_path)
     and new.avatar_path !~ ('^' || new.id::text || '/avatar-[0-9a-z-]+\.jpg$') then
    raise exception 'avatar_path_invalid' using errcode = 'P0001', hint = 'Фото профиля должно лежать в папке мастера';
  end if;
  if tg_op = 'INSERT' then
    new.city_changed_at := null;
    v_free := public.free_pro_active_until();
    if v_free is not null and (new.pro_until is null or new.pro_until < v_free) then
      new.pro_until := v_free;
    end if;
    return new;
  end if;
  if new.city_id is distinct from old.city_id then
    if old.city_changed_at is not null and old.city_changed_at > now() - interval '30 days' then
      raise exception 'city_change_too_soon'
        using errcode = 'P0001', hint = 'Город можно менять не чаще раза в 30 дней';
    end if;
    new.city_changed_at := now();
  end if;
  return new;
end $$;

create or replace function public.publish_sphere(p_sphere uuid)
returns public.spheres language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.spheres;
  v_limit int;
  v_active int;
  v_phone text;
  v_old timestamptz;
  v_until timestamptz;
begin
  select * into s from public.spheres where id = p_sphere for update;
  if not found or s.profile_id is distinct from v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if s.status in ('hidden','blocked') then
    raise exception 'sphere_blocked' using errcode = 'P0001';
  end if;

  select phone into v_phone from auth.users where id = v_uid;
  if v_phone is not null and v_phone <> '' then
    insert into public.trial_grants (phone_hash)
    values (encode(extensions.digest('uustarybul:' || v_phone, 'sha256'), 'hex'))
    on conflict do nothing;
    if found then
      select pro_until into v_old from public.profiles where id = v_uid for update;
      if public.free_pro_active_until() is not null then
        v_until := greatest(coalesce(v_old, now()), now() + interval '3 months');
      else
        v_until := greatest(coalesce(v_old, now()), now()) + interval '3 months';
      end if;
      if v_old is null or v_until > v_old then
        update public.profiles set pro_until = v_until where id = v_uid;
        insert into public.notifications (user_id, kind, payload)
        values (v_uid, 'trial_started', jsonb_build_object('pro_until', v_until));
      end if;
    end if;
  end if;

  if s.status <> 'active' then
    select l.spheres into v_limit from public.profile_limits(v_uid) l;
    select count(*) into v_active from public.spheres where profile_id = v_uid and status = 'active';
    if v_active >= v_limit then
      raise exception 'spheres_limit' using errcode = 'P0001',
        hint = 'Лимит активных сфер исчерпан';
    end if;
  end if;

  update public.spheres
     set status = 'active',
         published_at = coalesce(published_at, now()),
         expires_at = now() + interval '30 days',
         reminded_at = null
   where id = p_sphere
   returning * into s;
  return s;
end $$;

create or replace function public.tg_app_settings_changed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.free_pro_until is distinct from old.free_pro_until and new.free_pro_until > now() then
    update public.profiles
       set pro_until = new.free_pro_until
     where deleted_at is null
       and (pro_until is null or pro_until < new.free_pro_until
            or (old.free_pro_until is not null and pro_until = old.free_pro_until));
  end if;
  return null;
end $$;
create trigger app_settings_changed after update on public.app_settings
  for each row execute function public.tg_app_settings_changed();

create or replace function public.free_pro_notify()
returns void language plpgsql security definer set search_path = '' as $$
declare v_free timestamptz;
begin
  select free_pro_until into v_free from public.app_settings where id;
  if v_free is null or v_free < now() + interval '30 days' or v_free >= now() + interval '31 days' then
    return;
  end if;
  insert into public.notifications (user_id, kind, payload)
  select p.id, 'trial_ending', jsonb_build_object('pro_until', p.pro_until, 'free_for_all', true)
    from public.profiles p
   where p.pro_until = v_free and p.deleted_at is null;
end $$;
revoke execute on function public.free_pro_notify() from public, anon, authenticated;
revoke execute on function public.tg_app_settings_changed() from public, anon, authenticated;

select cron.schedule('uustarybul-free-pro', '8 0 * * *', 'select public.free_pro_notify()');

update public.profiles
   set pro_until = (select free_pro_until from public.app_settings where id)
 where deleted_at is null
   and (pro_until is null or pro_until < (select free_pro_until from public.app_settings where id));

-- ==================== 017_guard_tables ====================
create table if not exists public.pow_used (
  challenge text primary key,
  created_at timestamptz not null default now()
);
alter table public.pow_used enable row level security;

create table if not exists public.guard_log (
  id bigserial primary key,
  kind text not null check (kind in ('call', 'guest')),
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists guard_log_ip on public.guard_log (ip_hash, kind, created_at);
alter table public.guard_log enable row level security;

create table if not exists public.guest_checks (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.guest_checks enable row level security;

revoke all on public.pow_used, public.guard_log, public.guest_checks from anon, authenticated;

create or replace function public.guard_take(p_kind text, p_ip_hash text, p_challenge text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_max int := case p_kind when 'call' then 15 when 'guest' then 20 else 0 end;
begin
  insert into public.pow_used (challenge) values (p_challenge) on conflict do nothing;
  if not found then
    return 'pow_replay';
  end if;
  if (select count(*) from public.guard_log
       where ip_hash = p_ip_hash and kind = p_kind and created_at > now() - interval '1 hour') >= v_max then
    return case p_kind
      when 'call' then 'С вашей сети сейчас слишком много входов. Попробуйте через час.'
      else 'С вашей сети сейчас слишком много гостей. Попробуйте через час или войдите по номеру.' end;
  end if;
  insert into public.guard_log (kind, ip_hash) values (p_kind, p_ip_hash);
  return null;
end $$;

create or replace function public.guest_mark(p_uid uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.guest_checks (user_id) values (p_uid) on conflict do nothing
$$;

revoke execute on function public.guard_take(text, text, text) from public, anon, authenticated;
revoke execute on function public.guest_mark(uuid) from public, anon, authenticated;

-- ==================== 017_guard_contact ====================
create or replace function public.get_contact(p_profile uuid, p_sphere uuid default null, p_kind public.contact_kind default 'call')
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_anon boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_limit int;
  v_used int;
  v_phone text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = 'P0001';
  end if;
  if v_anon and not exists (select 1 from public.guest_checks where user_id = v_uid) then
    raise exception 'guest_check_required' using errcode = 'P0001';
  end if;
  if not public.profile_is_public(p_profile) and p_profile <> v_uid then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  v_limit := case when v_anon then 20 else 50 end;

  if p_profile <> v_uid then
    if not exists (select 1 from public.contact_events
                   where customer_id = v_uid and profile_id = p_profile
                     and created_at > now() - interval '24 hours') then
      select count(distinct profile_id) into v_used from public.contact_events
      where customer_id = v_uid and created_at > now() - interval '24 hours';
      if v_used >= v_limit then
        raise exception 'daily_limit' using errcode = 'P0001',
          hint = 'Лимит номеров на сегодня исчерпан';
      end if;
    end if;

    insert into public.contact_events (customer_id, profile_id, sphere_id, kind)
    values (v_uid, p_profile, p_sphere, p_kind);

    insert into public.stats_daily (profile_id, day, contacts)
    values (p_profile, (now() at time zone 'Asia/Yakutsk')::date, 1)
    on conflict (profile_id, day) do update set contacts = public.stats_daily.contacts + 1;
  end if;

  select phone into v_phone from public.profile_contacts where profile_id = p_profile;
  return v_phone;
end $$;
