// Уустары бул — вход по номеру телефона через Zvonok.com (по образцу ElvA).
//
// Ключи Zvonok хранятся в секретах проекта и в браузер не попадают.
// verify_jwt выключен: функция сама проверяет сессию (гостя может и не быть).
//
// Секреты:
//   ZVONOK_PUBLIC_KEY        — API Public Key
//   ZVONOK_CAMPAIGN_FLASH    — кампания «звонок-сброс» (код = последние 4 цифры)
//   ZVONOK_CAMPAIGN_CALLBACK — кампания «позвоните на номер» (запасной способ, можно не задавать)
//   DISABLE_TEST_LOGINS=1    — выключить тестовые номера (обязательно перед запуском)
//
// Действия: start, confirm, start_fallback, check_fallback;
// challenge (задачка для телефона), guest (проверка гостя перед первым номером мастера);
// admin_config — для страницы управления: настроены ли кампании Zvonok и включены ли тестовые номера.
//
// Журнал (14.10.2026, миграция 020): каждая попытка получить код и каждый отказ защиты пишутся
// в login_log (номер, способ, итог, устройство — «iPhone · Safari», без IP) и в сводку guard_stats по дням.
// Ошибка записи в журнал вход не ломает.
//
// Защита от ботов (13.10.2026): «задачка для телефона» (proof-of-work в формате ALTCHA:
// найти number, при котором sha256(salt + number) = challenge) нужна для start, start_fallback
// и guest; одна задачка — одно действие. Плюс лимиты по IP (хеш): звонки 15/час, гости 20/час.
// Ключ подписи задачек выводится из ключа сервиса — настраивать ничего не нужно.
// После подтверждения возвращает token_hash — браузер обменивает его на сессию
// через supabase.auth.verifyOtp({ token_hash, type: 'magiclink' }).

import { createClient } from 'jsr:@supabase/supabase-js@2';

const ZVONOK = 'https://zvonok.com/manager/cabapi_external/api/v1';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
// Тестовые номера: таких номеров в России не бывает (код 000), звонков нет, код 1234.
const TEST_LOGINS: Record<string, string> = {
  '70000000001': '1234', '70000000002': '1234', '70000000003': '1234'
};
const EMAIL_DOMAIN = 'phone.uustarybul.ru';

const POW_MAX = 400000;          // сложность: телефон перебирает в среднем 200 тыс. вариантов
const POW_TTL = 10 * 60;         // задачка живёт 10 минут
const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
async function sha256(s: string) { return hex(await crypto.subtle.digest('SHA-256', enc.encode(s))); }
let hmacKey: CryptoKey | null = null;
async function sign(s: string) {
  if (!hmacKey) {
    const raw = await crypto.subtle.digest('SHA-256', enc.encode('uustarybul-pow:' + Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')));
    hmacKey = await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  }
  return hex(await crypto.subtle.sign('HMAC', hmacKey, enc.encode(s)));
}
async function newChallenge() {
  const rnd = hex(crypto.getRandomValues(new Uint8Array(12)).buffer);
  const salt = `${rnd}?expires=${Math.floor(Date.now() / 1000) + POW_TTL}`;
  const number = crypto.getRandomValues(new Uint32Array(1))[0] % (POW_MAX + 1);
  const challenge = await sha256(salt + number);
  return { algorithm: 'SHA-256', challenge, maxnumber: POW_MAX, salt, signature: await sign(challenge) };
}
// Решение верно и не просрочено → challenge (для учёта «одна задачка — одно действие»), иначе null
async function checkPow(p: any): Promise<string | null> {
  if (!p || typeof p.salt !== 'string' || typeof p.challenge !== 'string' || typeof p.signature !== 'string') return null;
  const exp = Number((p.salt.match(/[?&]expires=(\d+)/) || [])[1]);
  if (!exp || exp < Date.now() / 1000) return null;
  const n = Number(p.number);
  if (!Number.isInteger(n) || n < 0 || n > POW_MAX) return null;
  if ((await sha256(p.salt + n)) !== p.challenge) return null;
  if ((await sign(p.challenge)) !== p.signature) return null;
  return p.challenge;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
}
function fail(error: string, status = 400) { return json({ ok: false, error }, status); }

// Устройство коротко, для журнала: «Android · Chrome». Сама строка браузера не хранится.
function deviceOf(ua: string): string {
  const os = /iPhone|iPad|iPod/.test(ua) ? 'iPhone' : /Android/.test(ua) ? 'Android' : /Windows/.test(ua) ? 'Windows'
    : /Mac OS X|Macintosh/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : '';
  const br = /YaBrowser|YaApp/.test(ua) ? 'Яндекс' : /Edg[A\/]/.test(ua) ? 'Edge' : /OPR\/|Opera/.test(ua) ? 'Opera'
    : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /SamsungBrowser/.test(ua) ? 'Samsung' : /CriOS|Chrome\//.test(ua) ? 'Chrome'
    : /Safari/.test(ua) ? 'Safari' : '';
  return [os, br].filter(Boolean).join(' · ') || 'неизвестно';
}
// Отказ защиты → короткий код для журнала
function refusalCode(msg: string): string {
  if (msg === 'pow_failed') return 'pow';
  if (msg === 'pow_replay') return 'replay';
  if (/сети/.test(msg)) return 'ip_limit';
  if (/10 минут/.test(msg)) return 'device_limit';
  if (/сегодня/.test(msg)) return 'phone_limit';
  return 'busy';
}

// К одному виду: 7XXXXXXXXXX (так телефон хранится в auth.users)
function normalizePhone(raw: string): string | null {
  let d = String(raw || '').replace(/\D/g, '');
  if (d.length === 11 && (d[0] === '8' || d[0] === '7')) d = '7' + d.slice(1);
  else if (d.length === 10) d = '7' + d;
  return /^7\d{10}$/.test(d) ? d : null;
}

async function zvonok(path: string, params: Record<string, string>) {
  const q = new URLSearchParams(params).toString();
  const r = await fetch(`${ZVONOK}/${path}/?${q}`);
  const text = await r.text();
  let data: any = null;
  try { data = JSON.parse(text); } catch (_) { /* не JSON */ }
  console.log('zvonok', path, r.status, text.slice(0, 500));
  return { ok: r.ok && !(data && data.status === 'error'), data, text };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail('method not allowed', 405);

  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

    // Кто звонит: гость, зарегистрированный или без сессии
    let user: any = null;
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (token.split('.').length === 3) {
      const { data } = await admin.auth.getUser(token);
      user = data?.user ?? null;
    }
    const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'unknown';
    const sessionKey = user ? user.id : 'ip:' + ip;

    const body = await req.json().catch(() => ({}));
    const action = String(body.action || '');
    const device = deviceOf(req.headers.get('user-agent') || '');
    const forAdmin = body.admin === true;
    const ipHash = (await sha256('uustarybul-ip:' + ip + ':' + Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'))).slice(0, 32);

    // Задачка, лимит по IP; null — можно, иначе текст ошибки
    async function botGuard(kind: 'call' | 'guest'): Promise<string | null> {
      const ch = await checkPow(body.pow);
      if (!ch) return 'pow_failed';
      const { data, error } = await admin.rpc('guard_take', { p_kind: kind, p_ip_hash: ipHash, p_challenge: ch });
      if (error) throw new Error('guard failed: ' + error.message);
      return (data as string) || null;
    }

    // Журнал защиты; ошибки записи не мешают входу
    async function note(kind: 'call' | 'guest', outcome: string, extra: Record<string, unknown> = {}) {
      try { await admin.rpc('guard_note', { p_kind: kind, p_outcome: outcome, ...extra }); } catch (_) { /* журнал не обязателен */ }
    }
    async function noteResult(phone: string, result: 'ok' | 'wrong' | 'zvonok_error') {
      try { await admin.rpc('guard_result', { p_session: sessionKey, p_phone: phone, p_result: result }); } catch (_) { /* то же */ }
    }

    const key = Deno.env.get('ZVONOK_PUBLIC_KEY') || '';
    const flash = Deno.env.get('ZVONOK_CAMPAIGN_FLASH') || '';
    const callback = Deno.env.get('ZVONOK_CAMPAIGN_CALLBACK') || '';
    const testsOn = Deno.env.get('DISABLE_TEST_LOGINS') !== '1';

    if (action === 'challenge') return json({ ok: true, ...(await newChallenge()) });

    // Для управления: что настроено на сервере (без самих ключей). Только администратору с введённым паролем.
    if (action === 'admin_config') {
      if (!user || user.is_anonymous) return fail('admin_required', 403);
      const uc = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
        auth: { persistSession: false }, global: { headers: { Authorization: 'Bearer ' + token } }
      });
      const { data: st, error } = await uc.rpc('admin_state');
      if (error || !st?.unlocked) return fail('admin_required', 403);
      return json({ ok: true, flash: !!(key && flash), callback: !!(key && callback), test_logins: testsOn });
    }

    if (action === 'guest') {
      if (!user?.is_anonymous) return fail('Проверка нужна только гостям');
      const g = await botGuard('guest');
      if (g) { await note('guest', refusalCode(g)); return fail(g, g === 'pow_failed' || g === 'pow_replay' ? 400 : 429); }
      await note('guest', 'ok');
      const { error } = await admin.rpc('guest_mark', { p_uid: user.id });
      if (error) throw new Error('guest mark failed: ' + error.message);
      return json({ ok: true });
    }

    const phone = normalizePhone(body.phone);
    if (!phone) return fail('Введите номер полностью, 10 цифр после +7');
    const isTest = !!TEST_LOGINS[phone] && testsOn;
    const logExtra = (method: string) => ({ p_session: sessionKey, p_phone: phone, p_method: method,
                                            p_admin: forAdmin, p_test: isTest, p_device: device });

    // Вход в управление (/admin): звоним только на номера администраторов — аккаунт не заводится, баланс не тратится.
    // Для start / start_fallback проверка идёт после задачки: без её решения нельзя перебором узнать, чей номер админский.
    async function adminDenied(method: string | null): Promise<boolean> {
      if (!forAdmin) return false;
      const { data: isAdmin, error } = await admin.rpc('admin_phone_ok', { p_phone: phone });
      if (error) throw new Error('admin check failed: ' + error.message);
      if (isAdmin) return false;
      if (method) await note('call', 'not_admin', logExtra(method));
      return true;
    }
    const notAdmin = () => fail('Этот номер не подключён к управлению', 403);

    // Задачка, лимит по IP, лимиты на устройство и номер; при отказе — запись в журнал и текст ошибки
    async function callGuard(method: 'flash' | 'callback'): Promise<Response | null> {
      const g = await botGuard('call');
      if (g) { await note('call', refusalCode(g), logExtra(method)); return fail(g, g === 'pow_failed' || g === 'pow_replay' ? 400 : 429); }
      if (await adminDenied(method)) return notAdmin();
      const { data, error } = await admin.rpc('phone_call_allowed', { p_session: sessionKey, p_phone: phone });
      if (error) throw new Error('limit check failed: ' + error.message);
      if (data) { await note('call', refusalCode(data as string), logExtra(method)); return fail(data as string, 429); }
      await admin.from('phone_verify_log').insert({ session_key: sessionKey, phone, kind: method });
      await note('call', 'sent', logExtra(method));
      return null;
    }

    // Номер подтверждён: находим или заводим аккаунт и выдаём одноразовый ключ входа
    async function finish() {
      const email = `${phone}@${EMAIL_DOMAIN}`;
      const { data: existing, error: findErr } = await admin.rpc('find_user_by_phone', { p_phone: phone });
      if (findErr) throw new Error('lookup failed: ' + findErr.message);
      let target: string;
      let isNew = false;
      if (existing) {
        target = existing as string;
        if (user?.is_anonymous) await admin.rpc('merge_guest', { p_guest: user.id, p_target: target });
        const { data: u } = await admin.auth.admin.getUserById(target);
        if (u?.user && u.user.email !== email) {
          const { error } = await admin.auth.admin.updateUserById(target, { email, email_confirm: true });
          if (error) throw new Error('update failed: ' + error.message);
        }
      } else if (user?.is_anonymous) {
        // Гость становится зарегистрированным — его звонки и id сохраняются
        const { error } = await admin.auth.admin.updateUserById(user.id, { phone, phone_confirm: true, email, email_confirm: true });
        if (error) throw new Error('upgrade failed: ' + error.message);
        const { error: regErr } = await admin.rpc('mark_registered', { p_uid: user.id });
        if (regErr) throw new Error('register failed: ' + regErr.message);
        target = user.id;
        isNew = true;
      } else {
        const { data: created, error } = await admin.auth.admin.createUser({ phone, phone_confirm: true, email, email_confirm: true });
        if (error || !created?.user) throw new Error('create failed: ' + (error?.message || 'no user'));
        target = created.user.id;
        isNew = true;
      }
      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
      if (linkErr || !link?.properties?.hashed_token) throw new Error('session failed: ' + (linkErr?.message || 'no token'));
      return json({ ok: true, token_hash: link.properties.hashed_token, is_new: isNew });
    }

    if (action === 'start') {
      const refused = await callGuard('flash');
      if (refused) return refused;
      let pincode: string;
      if (isTest) {
        pincode = TEST_LOGINS[phone];
      } else {
        if (!key || !flash) return fail('Вход по звонку ещё не настроен', 503);
        const z = await zvonok('phones/flashcall', { campaign_id: flash, phone: '+' + phone, public_key: key });
        pincode = z.data?.data?.pincode;
        if (!z.ok || !pincode) {
          await noteResult(phone, 'zvonok_error');
          return fail('Не получилось позвонить. Попробуйте ещё раз через минуту.', 502);
        }
      }
      const { error } = await admin.from('phone_verify_codes').upsert({
        session_key: sessionKey, phone, pincode: String(pincode), attempts: 0, created_at: new Date().toISOString()
      });
      if (error) throw new Error('save failed: ' + error.message);
      return json({ ok: true, test: isTest });
    }

    if (action === 'confirm') {
      if (await adminDenied(null)) return notAdmin();
      const code = String(body.code || '').replace(/\D/g, '');
      if (code.length !== 4) return fail('Введите 4 цифры');
      const { data: row } = await admin.from('phone_verify_codes').select('*')
        .eq('session_key', sessionKey).eq('phone', phone).maybeSingle();
      if (!row || Date.now() - new Date(row.created_at).getTime() > 10 * 60 * 1000) return fail('Код устарел. Запросите звонок ещё раз.');
      if (row.attempts >= 5) return fail('Слишком много попыток. Запросите звонок ещё раз.');
      if (String(row.pincode).slice(-4) !== code) {
        await admin.from('phone_verify_codes').update({ attempts: row.attempts + 1 }).eq('session_key', sessionKey);
        await noteResult(phone, 'wrong');
        const left = 4 - row.attempts;
        return fail(left > 0 ? `Неверный код. Осталось попыток: ${left}` : 'Неверный код. Запросите звонок ещё раз.');
      }
      await admin.from('phone_verify_codes').delete().eq('session_key', sessionKey);
      await noteResult(phone, 'ok');
      return await finish();
    }

    if (action === 'start_fallback') {
      if (!key || !callback) return fail('Запасной способ пока не настроен', 503);
      const refused = await callGuard('callback');
      if (refused) return refused;
      const z = await zvonok('phones/confirm', { campaign_id: callback, phone: '+' + phone, public_key: key });
      if (!z.ok) { await noteResult(phone, 'zvonok_error'); return fail('Не получилось. Попробуйте ещё раз через минуту.', 502); }
      const d = z.data?.data || {};
      const numbers = d.allowed_phones_for_call ?? d.number ?? d.phone_number ?? [];
      return json({ ok: true, numbers: Array.isArray(numbers) ? numbers : [numbers].filter(Boolean) });
    }

    if (action === 'check_fallback') {
      if (!key || !callback) return fail('Запасной способ пока не настроен', 503);
      if (await adminDenied(null)) return notAdmin();
      const z = await zvonok('phones/calls_by_phone', { campaign_id: callback, phone: '+' + phone, public_key: key });
      const calls = Array.isArray(z.data) ? z.data : (Array.isArray(z.data?.data) ? z.data.data : []);
      const ok = calls.some((c: any) => ['completed', 'success', 'confirmed', 'answered', 'pincode_ok'].includes(c?.call_status));
      if (!ok) return json({ ok: false, pending: true });
      await noteResult(phone, 'ok');
      return await finish();
    }

    return fail('unknown action');
  } catch (e) {
    console.error('verify-phone error', e);
    return fail('Ошибка сервера: ' + String((e as Error)?.message || e), 500);
  }
});
