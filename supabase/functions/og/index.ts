// Уустары бул — превью ссылки на мастера для соцсетей и мессенджеров (план, шаг 11).
// Caddy присылает сюда запросы ботов (ВК, WhatsApp, Telegram, Одноклассники…) к /?m=<id мастера>.
// Ответ — маленькая страница с og:-тегами: имя, сферы, город, фото. Человек, если всё же попадёт сюда, уходит в приложение.
// Данные — только то, что уже показано в приложении (public.og_master, профили, видимые в поиске).
import { createClient } from 'jsr:@supabase/supabase-js@2';

const SITE = 'https://uustarybul.ru';
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function page(o: { title: string; desc: string; image: string; url: string; square: boolean }) {
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>${esc(o.title)}</title>
<meta name="description" content="${esc(o.desc)}">
<meta property="og:type" content="profile"><meta property="og:site_name" content="Уустары бул">
<meta property="og:title" content="${esc(o.title)}"><meta property="og:description" content="${esc(o.desc)}">
<meta property="og:url" content="${esc(o.url)}"><meta property="og:image" content="${esc(o.image)}">
<meta property="og:locale" content="ru_RU">
<meta name="twitter:card" content="${o.square ? 'summary' : 'summary_large_image'}">
<meta name="robots" content="noindex"><link rel="canonical" href="${esc(o.url)}">
<meta http-equiv="refresh" content="0;url=${esc(o.url)}">
</head><body><a href="${esc(o.url)}">${esc(o.title)}</a></body></html>`;
}

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const id = u.searchParams.get('m') || '';
  const url = `${SITE}/?m=${encodeURIComponent(id)}`;
  const fallback = { title: 'Уустары бул — мастера рядом', desc: 'Сантехники, электрики, сварщики, медсёстры, репетиторы и другие мастера вашего города. Цены, фото работ и отзывы — звоните напрямую.', image: `${SITE}/icons/icon-512.png`, url: SITE + '/', square: true };
  const html = (body: string) => new Response(body, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=600' } });
  if (!UUID.test(id)) return html(page(fallback));
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data } = await db.rpc('og_master', { p_id: id });
    if (!data || !data.name) return html(page(fallback));
    const sp: string[] = data.spheres || [];
    const what = sp.length ? sp.slice(0, 3).map((s, i) => i ? s.charAt(0).toLowerCase() + s.slice(1) : s).join(', ') : 'Мастер';
    const title = `${data.name} — ${what}${data.city ? ' · ' + data.city : ''}`;
    const extra = data.rating ? `Рейтинг ${Number(data.rating).toFixed(1).replace('.', ',')} · отзывов: ${data.reviews}. ` : '';
    const desc = `${extra}Услуги, цены и фото работ в «Уустары бул». Звоните мастеру напрямую.`;
    const image = data.image ? `${SITE}/storage/v1/object/public/photos/${data.image.split('/').map(encodeURIComponent).join('/')}` : fallback.image;
    return html(page({ title, desc, image, url, square: !data.image || String(data.image).includes('/avatar-') }));
  } catch (_) {
    return html(page(fallback));
  }
});
