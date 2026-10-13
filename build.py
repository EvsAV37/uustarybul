# Сборка index.html из src/ — один файл со встроенной библиотекой Supabase.
# Запуск: python3 build.py   (нужны python3 и npm)
import os, subprocess, tarfile
ROOT = os.path.dirname(os.path.abspath(__file__))
VER = '2.45.4'
lib_path = os.path.join(ROOT, 'vendor', 'package', 'dist', 'umd', 'supabase.js')
if not os.path.exists(lib_path):
    os.makedirs(os.path.join(ROOT, 'vendor'), exist_ok=True)
    subprocess.run(['npm', 'pack', f'@supabase/supabase-js@{VER}', '--silent'], cwd=os.path.join(ROOT, 'vendor'), check=True)
    with tarfile.open(os.path.join(ROOT, 'vendor', f'supabase-supabase-js-{VER}.tgz')) as t:
        t.extractall(os.path.join(ROOT, 'vendor'))
rd = lambda p: open(os.path.join(ROOT, p), encoding='utf8').read()
src = rd('src/app.html').replace('/*CABINET*/', rd('src/cabinet.js')).replace('/*LOGIN*/', rd('src/login.js')).replace('/*SETTINGS*/', rd('src/settings.js'))
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
<link rel="stylesheet" href="doc.css">
</head>
<body><main><a class="back" href="../">‹ Уустары бул</a>
<article class="doc">
<div class="draft">Черновик. Документ ещё не утверждён, выделенные места будут заполнены.</div>
{body}
</article></main></body>
</html>
'''
for src in sorted(glob.glob(os.path.join(ROOT, 'docs', 'src', '*.html'))):
    body = open(src, encoding='utf8').read()
    body = re.sub(r'\[([^\]<>]+)\]', r'<mark>[\1]</mark>', body)
    title = re.search(r'<h1>(.*?)</h1>', body).group(1)
    open(os.path.join(ROOT, 'docs', os.path.basename(src)), 'w', encoding='utf8').write(DOC_TPL.format(title=title, body=body))
print('документы собраны')
