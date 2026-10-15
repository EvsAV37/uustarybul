# Сборка index.html из src/ — один файл со встроенной библиотекой Supabase.
# Запуск: python3 build.py   (нужен python3; npm не обязателен)
# Для своего сервера: UB_SB_KEY=<anon key> python3 build.py — API на том же адресе, что и сайт.
# UB_VENDOR_DIR — где хранить скачанную библиотеку (по умолчанию ./vendor).
import os, subprocess, tarfile, shutil, urllib.request, io
ROOT = os.path.dirname(os.path.abspath(__file__))
VER = '2.45.4'
VENDOR = os.environ.get('UB_VENDOR_DIR') or os.path.join(ROOT, 'vendor')
lib_path = os.path.join(VENDOR, 'package', 'dist', 'umd', 'supabase.js')
if not os.path.exists(lib_path):
    os.makedirs(VENDOR, exist_ok=True)
    tgz = os.path.join(VENDOR, f'supabase-supabase-js-{VER}.tgz')
    if shutil.which('npm'):
        subprocess.run(['npm', 'pack', f'@supabase/supabase-js@{VER}', '--silent'], cwd=VENDOR, check=True)
    else:
        with urllib.request.urlopen(f'https://registry.npmjs.org/@supabase/supabase-js/-/supabase-js-{VER}.tgz', timeout=60) as r, open(tgz, 'wb') as f:
            f.write(r.read())
    with tarfile.open(tgz) as t:
        t.extractall(VENDOR)
rd = lambda p: open(os.path.join(ROOT, p), encoding='utf8').read()
POW = rd('src/pow.js')  # вызов verify-phone и задачка для телефона — общие для приложения и /admin
src = rd('src/app.html').replace('/*CABINET*/', rd('src/cabinet.js')).replace('/*LOGIN*/', rd('src/login.js').replace('/*POW*/', POW)).replace('/*SETTINGS*/', rd('src/settings.js'))
SB_KEY = os.environ.get('UB_SB_KEY')
if SB_KEY:  # свой сервер: API на том же адресе, ключ — с сервера
    old_url = "var SB_URL = 'https://icojobutpjjvsjkizaak.supabase.co';"
    assert old_url in src, 'не найден SB_URL в app.html'
    src = src.replace(old_url, 'var SB_URL = location.origin;')
    import re as _re
    src, n = _re.subn(r"var SB_KEY = '[^']*';", "var SB_KEY = '" + SB_KEY + "';", src)
    assert n == 1, 'не найден SB_KEY в app.html'
FREE_PRO = os.environ.get('UB_FREE_PRO', '').strip()  # дата бесплатного Про из базы (deploy.sh)
if FREE_PRO:
    import re as _re
    assert _re.fullmatch(r'[0-9T:.+\-]+', FREE_PRO), 'странная дата UB_FREE_PRO: ' + FREE_PRO
    old_fp = 'var FREE_PRO_BUILT = null;'
    assert old_fp in src, 'не найден FREE_PRO_BUILT в cabinet.js'
    src = src.replace(old_fp, "var FREE_PRO_BUILT = '" + FREE_PRO + "';")
lib = open(lib_path, encoding='utf8').read()
# UMD-сборка не умеет работать встроенной в страницу — чиним определение publicPath
old = 'if(!e)throw new Error("Automatic publicPath is not supported in this browser");'
assert old in lib, 'другая версия supabase-js — проверь патч'
lib = lib.replace(old, 'if(!e)e="https://localhost/";').replace('</script', '<\\/script')
import base64
logo = 'data:image/webp;base64,' + base64.b64encode(open(os.path.join(ROOT, 'icons', 'logo-mark.webp'), 'rb').read()).decode()
src = src.replace('/*LOGO_MARK*/', logo)  # знак заставки встроен в страницу — готов к первому кадру
open(os.path.join(ROOT, 'index.html'), 'w', encoding='utf8').write(src.replace('/*SUPABASE_UMD*/', lib))
print('index.html собран')

# Управление: src/admin.html → admin/index.html (отдельная страница, код админки не попадает к заказчикам).
# Собирается только для своего сервера (UB_SB_KEY): в облачном прототипе функций админки нет.
if SB_KEY:
    adm = rd('src/admin.html').replace('/*POW*/', POW)
    assert old_url in adm, 'не найден SB_URL в admin.html'
    adm = adm.replace(old_url, 'var SB_URL = location.origin;')
    adm, n = _re.subn(r"var SB_KEY = '[^']*';", "var SB_KEY = '" + SB_KEY + "';", adm)
    assert n == 1, 'не найден SB_KEY в admin.html'
    os.makedirs(os.path.join(ROOT, 'admin'), exist_ok=True)
    open(os.path.join(ROOT, 'admin', 'index.html'), 'w', encoding='utf8').write(adm.replace('/*SUPABASE_UMD*/', lib))
    print('admin/index.html собран')

# Документы: docs/src/*.html → docs/*.html (отдельные страницы; приложение открывает их у себя на экране)
import re, glob
DOC_TPL = '''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{title} — Уустары бул</title>
<link rel="icon" type="image/png" href="../icons/favicon-64.png">
<style>
:root{{--bg:#FFFFFF;--fg:#0B0C0E;--mu:#6B7079;--sf:#F4F4F6;--ln:#E5E5EA;--mk:#FFF1C2;--mkf:#5C4200;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1A1B1F;--fg:#F5F5F7;--mu:#9499A3;--sf:#24262B;--ln:#2E3035;--mk:#4A3B12;--mkf:#F7E2A6;color-scheme:dark}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font-family:'Onest',system-ui,-apple-system,'Segoe UI',sans-serif;-webkit-font-smoothing:antialiased}}
main{{max-width:720px;margin:0 auto;padding:16px 20px 48px}}
a.back{{display:inline-flex;align-items:center;height:44px;font-size:16px;font-weight:500;color:inherit;text-decoration:none}}
</style>
<link rel="stylesheet" href="../fonts/onest.css">
<link rel="stylesheet" href="doc.css">
</head>
<body><main><a class="back" href="../">‹ Уустары бул</a>
<article class="doc">
{draft}{body}
</article></main></body>
</html>
'''
# Дата бесплатного Про в оферте — из базы (как в странице); потом её поддерживает ub-free-pro-sync на сервере
FREE_PRO_RU = None
if FREE_PRO:
    import datetime as _dt
    _d = _dt.datetime.fromisoformat(FREE_PRO).astimezone(_dt.timezone(_dt.timedelta(hours=9)))  # Якутск, без перехода на летнее время
    FREE_PRO_RU = '%d %s %d' % (_d.day, ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'][_d.month-1], _d.year)
# Черновик: пометка на каждом документе. Снять, когда документы утверждены (план, Часть 2, п. 5), — и поднять
# DOC_VERSION в src/login.js (дата редакции): люди дадут согласие на новую редакцию.
DOCS_DRAFT = True
DRAFT_HTML = '<div class="draft">Черновик. Документ ещё не утверждён, выделенные места будут заполнены.</div>\n'
DOC_VERSION = re.search(r"var DOC_VERSION = '([0-9-]+)';", rd('src/login.js')).group(1)
meta = []
for src in sorted(glob.glob(os.path.join(ROOT, 'docs', 'src', '*.html'))):
    body = open(src, encoding='utf8').read()
    ed = re.search(r'Редакция от ([^.<]+)', body)
    meta.append({'key': os.path.basename(src)[:-5], 'title': re.search(r'<h1>(.*?)</h1>', body).group(1),
                 'edition': ed.group(1).strip() if ed else None, 'gaps': len(re.findall(r'\[([^\]<>]+)\]', body))})
    if FREE_PRO_RU:
        body = re.sub(r'<span data-free-pro>[^<]*</span>', '<span data-free-pro>' + FREE_PRO_RU + '</span>', body)
    body = re.sub(r'\[([^\]<>]+)\]', r'<mark>[\1]</mark>', body)
    title = re.search(r'<h1>(.*?)</h1>', body).group(1)
    open(os.path.join(ROOT, 'docs', os.path.basename(src)), 'w', encoding='utf8').write(
        DOC_TPL.format(title=title, body=body, draft=DRAFT_HTML if DOCS_DRAFT else ''))
# Сводка для управления (Настройки → Документы): редакция, пропуски в квадратных скобках, черновик ли
import json as _json
open(os.path.join(ROOT, 'docs', 'docs.json'), 'w', encoding='utf8').write(
    _json.dumps({'version': DOC_VERSION, 'draft': DOCS_DRAFT, 'docs': meta}, ensure_ascii=False, indent=1) + '\n')
print('документы собраны')
