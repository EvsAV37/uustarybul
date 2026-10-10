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
// Действия: start, confirm, start_fallback, check_fallback.
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

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
}
function fail(error: string, status = 400) { return json({ ok: false, error }, status); }

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
    const phone = normalizePhone(body.phone);
    if (!phone) return fail('Введите номер полностью, 10 цифр после +7');
    const isTest = !!TEST_LOGINS[phone] && Deno.env.get('DISABLE_TEST_LOGINS') !== '1';

    const key = Deno.env.get('ZVONOK_PUBLIC_KEY') || '';
    const flash = Deno.env.get('ZVONOK_CAMPAIGN_FLASH') || '';
    const callback = Deno.env.get('ZVONOK_CAMPAIGN_CALLBACK') || '';

    async function guard(kind: string) {
      const { data, error } = await admin.rpc('phone_call_allowed', { p_session: sessionKey, p_phone: phone });
      if (error) throw new Error('limit check failed: ' + error.message);
      if (data) return data as string;
      await admin.from('phone_verify_log').insert({ session_key: sessionKey, phone, kind });
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
      const limit = await guard('flash');
      if (limit) return fail(limit, 429);
      let pincode: string;
      if (isTest) {
        pincode = TEST_LOGINS[phone];
      } else {
        if (!key || !flash) return fail('Вход по звонку ещё не настроен', 503);
        const z = await zvonok('phones/flashcall', { campaign_id: flash, phone: '+' + phone, public_key: key });
        pincode = z.data?.data?.pincode;
        if (!z.ok || !pincode) return fail('Не получилось позвонить. Попробуйте ещё раз через минуту.', 502);
      }
      const { error } = await admin.from('phone_verify_codes').upsert({
        session_key: sessionKey, phone, pincode: String(pincode), attempts: 0, created_at: new Date().toISOString()
      });
      if (error) throw new Error('save failed: ' + error.message);
      return json({ ok: true, test: isTest });
    }

    if (action === 'confirm') {
      const code = String(body.code || '').replace(/\D/g, '');
      if (code.length !== 4) return fail('Введите 4 цифры');
      const { data: row } = await admin.from('phone_verify_codes').select('*')
        .eq('session_key', sessionKey).eq('phone', phone).maybeSingle();
      if (!row || Date.now() - new Date(row.created_at).getTime() > 10 * 60 * 1000) return fail('Код устарел. Запросите звонок ещё раз.');
      if (row.attempts >= 5) return fail('Слишком много попыток. Запросите звонок ещё раз.');
      if (String(row.pincode).slice(-4) !== code) {
        await admin.from('phone_verify_codes').update({ attempts: row.attempts + 1 }).eq('session_key', sessionKey);
        const left = 4 - row.attempts;
        return fail(left > 0 ? `Неверный код. Осталось попыток: ${left}` : 'Неверный код. Запросите звонок ещё раз.');
      }
      await admin.from('phone_verify_codes').delete().eq('session_key', sessionKey);
      return await finish();
    }

    if (action === 'start_fallback') {
      if (!key || !callback) return fail('Запасной способ пока не настроен', 503);
      const limit = await guard('callback');
      if (limit) return fail(limit, 429);
      const z = await zvonok('phones/confirm', { campaign_id: callback, phone: '+' + phone, public_key: key });
      if (!z.ok) return fail('Не получилось. Попробуйте ещё раз через минуту.', 502);
      const d = z.data?.data || {};
      const numbers = d.allowed_phones_for_call ?? d.number ?? d.phone_number ?? [];
      return json({ ok: true, numbers: Array.isArray(numbers) ? numbers : [numbers].filter(Boolean) });
    }

    if (action === 'check_fallback') {
      if (!key || !callback) return fail('Запасной способ пока не настроен', 503);
      const z = await zvonok('phones/calls_by_phone', { campaign_id: callback, phone: '+' + phone, public_key: key });
      const calls = Array.isArray(z.data) ? z.data : (Array.isArray(z.data?.data) ? z.data.data : []);
      const ok = calls.some((c: any) => ['completed', 'success', 'confirmed', 'answered', 'pincode_ok'].includes(c?.call_status));
      if (!ok) return json({ ok: false, pending: true });
      return await finish();
    }

    return fail('unknown action');
  } catch (e) {
    console.error('verify-phone error', e);
    return fail('Ошибка сервера: ' + String((e as Error)?.message || e), 500);
  }
});
