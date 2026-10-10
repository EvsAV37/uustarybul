// Уустары бул — отправка push-уведомлений из очереди public.notifications.
//
// Будит её база: триггер после вставки в notifications и cron раз в 10 минут (public.push_kick).
// verify_jwt выключен: вызов ничего не раскрывает и не меняет сверх обычной обработки очереди;
// что и кому отправлять, решает база (push_take: настройки, тихие часы, удаление аккаунта).
//
// Ключи VAPID создаются при первом запуске и хранятся в vault (push_vapid_get / push_vapid_set),
// поэтому секретов задавать не нужно. Необязательный секрет PUSH_SUBJECT — контакт в подписи VAPID.
// В тексты уведомлений не попадают персональные данные (имя автора отзыва и т. п.).

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { generateVapid, sendPush, type Vapid } from './webpush.ts';

const SUBJECT = Deno.env.get('PUSH_SUBJECT') || 'https://evsav37.github.io/uustarybul/';
const OPEN_URL = './?go=cab';
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false }
});

type Row = {
  r_nid: number; r_kind: string; r_payload: Record<string, unknown>; r_tz: string;
  r_sub: number; r_endpoint: string; r_p256dh: string; r_auth: string;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

let vapidCache: Vapid | null = null;
async function vapid(): Promise<Vapid> {
  if (vapidCache) return vapidCache;
  const read = async () => {
    const { data, error } = await db.rpc('push_vapid_get');
    if (error) throw error;
    const r = (data || [])[0];
    return r && r.r_pub && r.r_priv ? { publicKey: r.r_pub, privateJwk: r.r_priv } : null;
  };
  let v = await read();
  if (!v) {
    const g = await generateVapid();
    await db.rpc('push_vapid_set', { p_pub: g.publicKey, p_priv: g.privateJwk }); // при гонке второй вызов вернёт false
    v = await read();
  }
  if (!v) throw new Error('vapid_unavailable');
  return (vapidCache = v);
}

function day(iso: unknown, tz: string): string {
  if (typeof iso !== 'string') return '';
  try {
    return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long', timeZone: tz }).format(new Date(iso));
  } catch { return ''; }
}

function text(kind: string, p: Record<string, unknown>, tz: string): { title: string; body: string } {
  const t = typeof p.title === 'string' && p.title ? `«${p.title}»` : 'карточка';
  switch (kind) {
    case 'sphere_expiring':
      return { title: 'Карточка скоро скроется', body: `${t} показывается до ${day(p.expires_at, tz)}. Продлите в кабинете в одно нажатие.` };
    case 'sphere_expired':
      return { title: 'Карточка скрыта из поиска', body: `Срок ${t} закончился. Продлите — и она снова появится.` };
    case 'trial_started':
      return { title: 'Про на 3 месяца — бесплатно', body: `Подключён до ${day(p.pro_until, tz)}: до 5 сфер, больше фото, карточки продлеваются сами.` };
    case 'trial_ending':
      return { title: 'Бесплатный Про заканчивается', body: `Действует до ${day(p.pro_until, tz)}. Потом лишние сферы встанут на паузу — ничего не удалится.` };
    case 'pro_ending':
      return { title: 'Про заканчивается через 7 дней', body: `Действует до ${day(p.pro_until, tz)}. Продлите в кабинете, чтобы карточки продлевались сами.` };
    case 'new_review': {
      const r = Math.max(1, Math.min(5, Number(p.rating) || 0));
      return { title: `Новый отзыв ${'★'.repeat(r)}${'☆'.repeat(5 - r)}`, body: 'Посмотрите и ответьте в кабинете.' };
    }
    case 'hidden_by_complaints':
      return p.target_type === 'profile'
        ? { title: 'Профиль скрыт после жалоб', body: 'На профиль пожаловались несколько человек. Подробности в кабинете.' }
        : { title: 'Карточка скрыта после жалоб', body: 'На карточку пожаловались несколько человек. Подробности в кабинете.' };
    default:
      return { title: 'Уустары бул', body: 'Откройте кабинет, там есть новости.' };
  }
}

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) await fn(items[i++]);
  }));
}

async function runBatch(v: Vapid) {
  const { data, error } = await db.rpc('push_take', { p_limit: 200 });
  if (error) throw error;
  const rows = (data || []) as Row[];
  if (!rows.length) return null;

  const okN = new Set<number>(), transientN = new Set<number>();
  const allN = new Set<number>(rows.map((r) => r.r_nid));
  const okS: number[] = [], deadS: number[] = [], badS: number[] = [];

  await pool(rows, 10, async (r) => {
    const msg = { ...text(r.r_kind, r.r_payload || {}, r.r_tz), url: OPEN_URL, tag: `${r.r_kind}-${r.r_nid}` };
    let st = 0;
    try {
      st = (await sendPush({ endpoint: r.r_endpoint, p256dh: r.r_p256dh, auth: r.r_auth }, msg, v, SUBJECT,
        { ttl: 86400, urgency: r.r_kind === 'hidden_by_complaints' ? 'high' : 'normal' })).status;
    } catch (e) {
      st = String(e).includes('bad_keys') ? 400 : 0; // 0 — сеть/таймаут
    }
    if (st >= 200 && st < 300) { okN.add(r.r_nid); okS.push(r.r_sub); }
    else if (st === 404 || st === 410) deadS.push(r.r_sub);
    else { badS.push(r.r_sub); if (st === 0 || st === 429 || st >= 500) transientN.add(r.r_nid); }
  });

  const sent = [...okN];
  const retry = [...transientN].filter((id) => !okN.has(id));
  const failed = [...allN].filter((id) => !okN.has(id) && !transientN.has(id));
  const { error: e2 } = await db.rpc('push_done', {
    p_sent: sent, p_retry: retry, p_failed: failed, p_dead: deadS, p_ok: okS, p_bad: badS
  });
  if (e2) throw e2;
  return { sent: sent.length, retry: retry.length, failed: failed.length, dead: deadS.length, deliveries: rows.length };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') return json({ error: 'method' }, 405);
  try {
    const v = await vapid();
    const total = { sent: 0, retry: 0, failed: 0, dead: 0, deliveries: 0 };
    for (let i = 0; i < 5; i++) {
      const r = await runBatch(v);
      if (!r) break;
      for (const k of Object.keys(total) as (keyof typeof total)[]) total[k] += r[k];
    }
    if (total.deliveries) console.log('push', JSON.stringify(total));
    return json({ ok: true, ...total });
  } catch (e) {
    console.error('send-push', e);
    return json({ ok: false }, 500);
  }
});
