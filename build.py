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
src = rd('src/app.html').replace('/*CABINET*/', rd('src/cabinet.js')).replace('/*LOGIN*/', rd('src/login.js'))
lib = open(lib_path, encoding='utf8').read()
# UMD-сборка не умеет работать встроенной в страницу — чиним определение publicPath
old = 'if(!e)throw new Error("Automatic publicPath is not supported in this browser");'
assert old in lib, 'другая версия supabase-js — проверь патч'
lib = lib.replace(old, 'if(!e)e="https://localhost/";').replace('</script', '<\\/script')
open(os.path.join(ROOT, 'index.html'), 'w', encoding='utf8').write(src.replace('/*SUPABASE_UMD*/', lib))
print('index.html собран')
