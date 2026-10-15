#!/usr/bin/env python3
"""Снимки экранов локальной копии (Playwright, Chromium из /opt/pw-browsers).

  python3 server/test/browser.py /                         — главная, 390 и 1440 px, светлая и тёмная
  python3 server/test/browser.py /admin/#security --as admin
  python3 server/test/browser.py /?go=cab --as 70000000001 --widths 390 --themes dark
  python3 server/test/browser.py / --as 70000000001 --click 'text=Кабинет' --click 'text=Настройки'

--as: гость не вошёл (по умолчанию) | anon (гость с сессией) | номер 7XXXXXXXXXX | admin (номер +7 000 000-00-03,
назначен администратором, пароль задан, управление открыто) | admin-locked (то же, но спросит пароль).
Сессия кладётся в localStorage до загрузки страницы: приложение — sb-127-auth-token, управление — ub-admin-auth.
Снимок — один экран, как на телефоне (--full — вся страница). Снимки — в server/test/.run/shots/, ошибки JS и неудачные запросы печатаются.
"""
import argparse, json, os, re, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 'http://127.0.0.1:' + os.environ.get('UB_PORT', '8000')
OUT = os.path.join(HERE, '.run', 'shots')
os.environ.setdefault('PLAYWRIGHT_BROWSERS_PATH', '/opt/pw-browsers')


def session_for(spec):
    """spec: None | 'anon' | '7XXXXXXXXXX' | 'admin' | 'admin-locked' | dict для /__test/session"""
    if not spec:
        return None
    if isinstance(spec, str):
        spec = {'anon': True} if spec == 'anon' else \
            {'phone': '70000000003', 'admin': True, 'unlock': spec != 'admin-locked'} if spec.startswith('admin') else \
            {'phone': spec}
    req = urllib.request.Request(BASE + '/__test/session', data=json.dumps(spec).encode(),
                                 headers={'Content-Type': 'application/json'}, method='POST')
    return json.load(urllib.request.urlopen(req, timeout=30))


def shots(items, widths=(390, 1440), themes=('light', 'dark'), wait=2500, js=None, full_page=False, clicks=()):
    """items: [(имя, сессия, путь)]. Возвращает [(файл, [ошибки])]."""
    from playwright.sync_api import sync_playwright
    os.makedirs(OUT, exist_ok=True)
    res = []
    with sync_playwright() as p:
        br = p.chromium.launch()
        for name, spec, path in items:
            sess = session_for(spec)
            key = 'ub-admin-auth' if path.startswith('/admin') else 'sb-127-auth-token'
            for w in widths:
                for th in themes:
                    mobile = w < 700
                    ctx = br.new_context(viewport={'width': w, 'height': 844 if mobile else 900},
                                         device_scale_factor=2 if mobile else 1, is_mobile=mobile, has_touch=mobile,
                                         color_scheme=th, locale='ru-RU', timezone_id='Asia/Yakutsk')
                    if sess:
                        ctx.add_init_script('localStorage.setItem(%s, %s)' % (json.dumps(key), json.dumps(json.dumps(sess))))
                    pg = ctx.new_page()
                    errors = []
                    pg.on('pageerror', lambda e, errors=errors: errors.append('JS: ' + str(e)))
                    pg.on('console', lambda m, errors=errors: m.type == 'error' and errors.append('console: ' + m.text))
                    pg.on('response', lambda r, errors=errors: r.status >= 500 and errors.append(f'{r.status} {r.url}'))
                    pg.goto(BASE + path, wait_until='networkidle')
                    pg.wait_for_timeout(wait)
                    if js:
                        pg.evaluate(js)
                        pg.wait_for_load_state('networkidle')
                    for c in clicks:  # Playwright-селекторы: 'text=Кабинет', '#id', 'role=button[name="…"]'
                        pg.locator(c).first.click()
                        pg.wait_for_load_state('networkidle')
                        pg.wait_for_timeout(700)
                    fn = os.path.join(OUT, '%s-%s-%d-%s.png' % (name, re.sub(r'[^a-z0-9]+', '_', path.lower()).strip('_') or 'root', w, th))
                    pg.screenshot(path=fn, full_page=full_page)
                    # Картинки демо-мастеров на локальной копии отсутствуют — 404 на фото не считаем ошибкой
                    errors = [e for e in errors if '/storage/v1/object/public/' not in e and 'status of 404' not in e]
                    res.append((fn, errors))
                    ctx.close()
        br.close()
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?', default='/')
    ap.add_argument('--as', dest='who', default=None)
    ap.add_argument('--widths', default='390,1440')
    ap.add_argument('--themes', default='light,dark')
    ap.add_argument('--wait', type=int, default=2500)
    ap.add_argument('--eval', dest='js', default=None)
    ap.add_argument('--name', default=None)
    ap.add_argument('--click', action='append', default=[], help='нажать по очереди (селектор Playwright, напр. "text=Кабинет")')
    ap.add_argument('--full', action='store_true', help='вся страница (закреплённые панели окажутся посередине)')
    a = ap.parse_args()
    out = shots([(a.name or ('admin' if a.path.startswith('/admin') else 'app'), a.who, a.path)],
                widths=[int(x) for x in a.widths.split(',')], themes=a.themes.split(','), wait=a.wait, js=a.js, full_page=a.full, clicks=a.click)
    bad = 0
    for fn, errs in out:
        print(fn)
        for e in errs:
            print('   ', e)
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
