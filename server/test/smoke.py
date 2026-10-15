#!/usr/bin/env python3
"""Быстрая проверка локальной копии (после local.sh start): API, вход тестовым номером через настоящую
verify-phone, гость, хранилище, управление; с --browser — ещё снимки главной и /admin (Playwright).

  python3 server/test/smoke.py            — только API
  python3 server/test/smoke.py --browser  — плюс браузер (снимки в server/test/.run/shots/)

Это проверка инструментов, а не всего приложения: она должна проходить на чистой базе (local.sh db).
"""
import hashlib, json, os, sys, urllib.request, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gateway import ANON, q  # noqa: E402

BASE = 'http://127.0.0.1:' + os.environ.get('UB_PORT', '8000')
FAILS = []


def call(method, path, body=None, token=None, headers=None, raw=None, ctype='application/json'):
    h = {'apikey': ANON, 'Authorization': 'Bearer ' + (token or ANON), 'Content-Type': ctype}
    h.update(headers or {})
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=60)
    except urllib.error.HTTPError as e:
        r = e
    txt = r.read().decode('utf8', 'replace') or 'null'
    try:
        return r.status if hasattr(r, 'status') else r.code, json.loads(txt)
    except ValueError:
        return r.code, txt


def check(name, ok, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + name + ('' if ok else '  → ' + str(detail)[:300]))
    if not ok:
        FAILS.append(name)


def solve(ch):
    for n in range(ch['maxnumber'] + 1):
        if hashlib.sha256((ch['salt'] + str(n)).encode()).hexdigest() == ch['challenge']:
            return {**ch, 'number': n}
    raise RuntimeError('задачка не решилась')


def guarded(body, token=None):
    _, ch = call('POST', '/functions/v1/verify-phone', {'action': 'challenge'}, token)
    return call('POST', '/functions/v1/verify-phone', {**body, 'pow': solve(ch)}, token)


def main():
    # Лимиты звонков и гостей (по номеру, устройству, IP) сбрасываем — иначе повторный запуск упрётся в них
    q('delete from public.phone_verify_log; delete from public.phone_verify_codes; delete from public.guard_log')
    print('API')
    st, cities = call('GET', '/rest/v1/cities?select=id,name&order=sort')
    check('города (anon)', st == 200 and len(cities) >= 1, cities)
    city = cities[0]['id'] if st == 200 and cities else 1
    st, cats = call('GET', '/rest/v1/categories?select=id,name&order=sort')
    check('сферы (anon) — 29', st == 200 and len(cats) == 29, cats)
    st, found = call('POST', '/rest/v1/rpc/find_spheres', {'p_city': city, 'p_category': None, 'p_query': 'сварка',
                                                          'p_sort': 'default', 'p_filter': 'all', 'p_limit': 50})
    check('поиск «сварка»', st == 200 and isinstance(found, list) and len(found) >= 1, found)
    st, emb = call('GET', '/rest/v1/spheres?select=id,services(id,title)&status=eq.active&limit=1')
    check('вложенные услуги (как в приложении)', st == 200 and isinstance(emb, list), emb)
    st, users = call('GET', '/rest/v1/admins?select=*')
    check('anon не видит admins', st in (401, 403) or users == [], users)

    print('Гость')
    st, s = call('POST', '/auth/v1/signup', {'data': {}})
    check('гостевой вход', st == 200 and s.get('access_token'), s)
    gt = s.get('access_token')
    st, demo = call('GET', '/rest/v1/profiles?select=id&is_demo=eq.true&limit=1')
    pid = demo[0]['id'] if st == 200 and demo else None
    st, r = call('POST', '/rest/v1/rpc/get_contact', {'p_profile': pid}, gt)
    check('номер гостю без проверки — отказ', st >= 400 and 'guest_check_required' in json.dumps(r), r)
    st, r = guarded({'action': 'guest'}, gt)
    check('проверка гостя (задачка)', st == 200 and r.get('ok'), r)
    st, r = call('POST', '/rest/v1/rpc/get_contact', {'p_profile': pid}, gt)
    check('номер гостю после проверки', st == 200 and r, r)
    st, r = call('POST', '/functions/v1/verify-phone', {'action': 'guest', 'pow': {'salt': 'x', 'challenge': 'y', 'signature': 'z', 'number': 1}}, gt)
    check('неверная задачка — отказ', st == 400, r)

    print('Вход тестовым номером (настоящая verify-phone)')
    st, r = guarded({'action': 'start', 'phone': '+7 000 000-00-02'})
    check('start', st == 200 and r.get('ok'), r)
    st, r = call('POST', '/functions/v1/verify-phone', {'action': 'confirm', 'phone': '+7 000 000-00-02', 'code': '1111'})
    check('неверный код — отказ', st == 400, r)
    st, r = call('POST', '/functions/v1/verify-phone', {'action': 'confirm', 'phone': '+7 000 000-00-02', 'code': '1234'})
    check('confirm → token_hash', st == 200 and r.get('token_hash'), r)
    st, s = call('POST', '/auth/v1/verify', {'type': 'magiclink', 'token_hash': r.get('token_hash')})
    check('сессия по token_hash', st == 200 and s.get('user', {}).get('phone') == '70000000002', s)
    ut, uid = s.get('access_token'), s.get('user', {}).get('id')
    st, codes = call('GET', '/rest/v1/phone_verify_codes?select=*')
    check('коды входа клиенту закрыты', st in (401, 403) or codes == [], codes)
    st, s2 = call('POST', '/auth/v1/token?grant_type=refresh_token', {'refresh_token': s.get('refresh_token')})
    check('обновление токена', st == 200 and s2.get('access_token'), s2)

    print('Хранилище')
    jpg = b'\xff\xd8\xff\xe0' + b'0' * 100
    fn = f'{uid}/test-{os.urandom(4).hex()}.jpg'
    st, r = call('POST', f'/storage/v1/object/photos/{fn}', token=ut, raw=jpg, ctype='image/jpeg')
    check('загрузка в свою папку', st == 200, r)
    st, r = call('POST', f'/storage/v1/object/photos/{pid}/x.jpg', token=ut, raw=jpg, ctype='image/jpeg')
    check('в чужую папку — отказ', st == 403, r)
    st, _ = call('GET', f'/storage/v1/object/public/photos/{fn}')
    check('публичная ссылка', st == 200)
    st, r = call('POST', f'/storage/v1/object/photos/{fn}', token=ut, raw=jpg, ctype='image/jpeg')
    check('повтор того же имени — 409', st == 409, r)
    # Как в Supabase: удаление требует политик DELETE и SELECT (SELECT на свои файлы — миграция 025)
    st, r = call('DELETE', '/storage/v1/object/photos', {'prefixes': [fn]}, ut)
    check('удаление владельцем', st == 200 and len(r) == 1, r)
    st, r = call('DELETE', '/storage/v1/object/photos', {'prefixes': [f'{pid}/x.jpg']}, ut)
    check('чужой файл не удаляется', st == 200 and r == [], r)

    print('Управление')
    st, a = call('POST', '/__test/session', {'phone': '70000000003', 'admin': True})
    check('сессия администратора', st == 200 and a.get('access_token'), a)
    st, r = call('POST', '/rest/v1/rpc/admin_state', {}, a.get('access_token'))
    check('admin_state: открыто', st == 200 and r.get('unlocked'), r)
    st, r = call('POST', '/rest/v1/rpc/admin_overview', {'p_days': 7}, a.get('access_token'))
    check('обзор', st == 200 and isinstance(r, dict), r)
    st, r = call('POST', '/rest/v1/rpc/admin_overview', {'p_days': 7}, ut)
    check('обзор не администратору — отказ', st >= 400, r)
    st, r = call('POST', '/functions/v1/verify-phone', {'action': 'admin_config'}, a.get('access_token'))
    check('verify-phone admin_config', st == 200 and r.get('ok') is not False, r)

    if '--browser' in sys.argv:
        print('Браузер')
        from browser import shots
        out = shots([('app', None, '/'), ('admin', {'phone': '70000000003', 'admin': True}, '/admin/')],
                    widths=(390, 1440), themes=('light',))
        for path, errors in out:
            check('снимок ' + os.path.basename(path) + ' без ошибок JS', not errors, errors)

    print('ИТОГ:', 'OK' if not FAILS else 'ОШИБКИ: ' + ', '.join(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
