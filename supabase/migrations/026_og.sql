-- Уустары бул — превью ссылки на мастера (план, шаг 11, 15.10.2026).
-- Когда ссылку …/?m=<id> открывает бот соцсети или мессенджера (ВК, WhatsApp, Telegram…), Caddy отдаёт ему
-- страницу функции og с именем, сферами, городом и фото мастера. Только то, что и так показывается в приложении
-- (согласие на распространение), и только для профилей, видимых в поиске.
create or replace function public.og_master(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', coalesce(nullif(p.org_name, ''), p.display_name),
    'city', (select c.name from public.cities c where c.id = p.city_id),
    'spheres', (select coalesce(jsonb_agg(s.title order by s.published_at nulls last, s.created_at), '[]')
                  from public.spheres s where s.profile_id = p.id and s.status = 'active'),
    'image', coalesce(p.avatar_path,
               (select ph.storage_path from public.photos ph join public.spheres s on s.id = ph.sphere_id
                 where s.profile_id = p.id and s.status = 'active' and not ph.is_hidden
                 order by s.published_at nulls last, ph.sort limit 1)),
    'reviews', p.reviews_count, 'rating', case when p.reviews_count >= 3 then p.rating_avg end)
  from public.profiles p
  where p.id = p_id and public.profile_is_public(p_id)
$$;
revoke execute on function public.og_master(uuid) from public, anon, authenticated;
grant execute on function public.og_master(uuid) to service_role;
