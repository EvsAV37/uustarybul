#!/bin/bash
# Уустары бул — выкладка версии на сервер. Запускает ub-run (от root) из распакованного архива коммита.
#   1. настройки сервера (compose, Caddyfile, ub-run, ub-secret)
#   2. серверные функции (supabase/functions/*)
#   3. миграции базы: server/db/*.sql, затем supabase/migrations/*.sql — каждая один раз (ops.migrations)
#   4. server/run.sql — разовые запросы/загрузки: выполняется, если файл изменился
#   5. сайт: сборка build.py под свой сервер и выкладка в /opt/ub/site
#   6. проверка: контейнеры и ответы сайта, API, входа, функций
# Всё, что печатается, видно в GitHub (ветка server-log) — никаких персональных данных в выводе.
set -uo pipefail
REL=$(cd "$(dirname "$0")/.." && pwd)
SB=/opt/supabase
UB=/opt/ub
FAIL=0
step() { printf '\n== %s\n' "$*"; }
bad()  { printf '!! %s\n' "$*"; FAIL=1; }
cd "$SB" || { echo "нет $SB"; exit 1; }
URL=$(grep '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2-)
ANON=$(grep '^ANON_KEY=' .env | cut -d= -f2-)
psql_db() { docker exec -i supabase-db psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
psql_su() { docker exec -i supabase-db psql -X -q -v ON_ERROR_STOP=1 -h localhost -U supabase_admin -d postgres "$@"; }

printf 'версия %s · %s\n' "${UB_SHA:0:7}" "$(date '+%Y-%m-%d %H:%M %Z')"

step "1. Настройки сервера"
recreate=0; caddy=0
if ! cmp -s "$REL/server/docker-compose.ub.yml" docker-compose.ub.yml; then cp "$REL/server/docker-compose.ub.yml" docker-compose.ub.yml; recreate=1; echo "обновлён docker-compose.ub.yml"; fi
if ! cmp -s "$REL/server/Caddyfile" ub/Caddyfile; then cp "$REL/server/Caddyfile" ub/Caddyfile; caddy=1; echo "обновлён Caddyfile"; fi
for t in ub-run ub-secret; do
  cmp -s "$REL/server/$t" "/usr/local/sbin/$t" || { install -m 755 "$REL/server/$t" "/usr/local/sbin/$t"; echo "обновлён $t"; }
done
# адреса из server/site.env
set_env() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*$|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
SITE=$(grep '^SITE_DOMAIN=' "$REL/server/site.env" | cut -d= -f2-)
REDIR=$(grep '^REDIRECT_DOMAINS=' "$REL/server/site.env" | cut -d= -f2-)
if [ -n "$SITE" ] && { [ "$(grep '^PROXY_DOMAIN=' .env | cut -d= -f2-)" != "$SITE" ] || [ "$(grep '^REDIRECT_DOMAINS=' .env | cut -d= -f2-)" != "$REDIR" ]; }; then
  set_env PROXY_DOMAIN "$SITE"; set_env REDIRECT_DOMAINS "$REDIR"; set_env STUDIO_DOMAIN "$SITE:8443"
  set_env SUPABASE_PUBLIC_URL "https://$SITE"; set_env API_EXTERNAL_URL "https://$SITE/auth/v1"; set_env SITE_URL "https://$SITE"
  recreate=1; echo "адрес сайта: $SITE (перенаправляются: $REDIR)"
fi
URL=$(grep '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2-)
if [ $recreate = 1 ]; then docker compose up -d --wait --wait-timeout 300 >/dev/null 2>&1 || bad "docker compose up не прошёл"; fi
if [ $caddy = 1 ] && [ $recreate = 0 ]; then docker compose restart caddy >/dev/null 2>&1 || bad "caddy не перезапустился"; fi

step "2. Функции"
fchanged=0
for d in "$REL"/supabase/functions/*/; do
  n=$(basename "$d"); [ "$n" = main ] && continue
  out=$(rsync -a --delete -i "$d" "volumes/functions/$n/")
  [ -n "$out" ] && { fchanged=1; echo "обновлена $n"; }
done
if [ $fchanged = 1 ]; then docker compose restart functions >/dev/null 2>&1 || bad "функции не перезапустились"; else echo "без изменений"; fi

step "3. Миграции базы"
psql_db -c "create schema if not exists ops; create table if not exists ops.migrations (name text primary key, applied_at timestamptz not null default now()); revoke all on schema ops from public;" >/dev/null || bad "нет доступа к базе"
applied=$(psql_db -At -c "select name from ops.migrations")
napplied=0
for f in "$REL"/server/db/*.sql "$REL"/supabase/migrations/*.sql; do
  [ -f "$f" ] || continue
  key="$(basename "$(dirname "$f")")/$(basename "$f")"
  grep -qxF "$key" <<<"$applied" && continue
  # предыдущий файл мог отметить этот как уже применённый
  [ -n "$(psql_db -At -c "select 1 from ops.migrations where name = '$key'")" ] && continue
  run=psql_db; head -1 "$f" | grep -q '^-- ub:superuser' && run=psql_su
  if out=$( { cat "$f"; printf "\ninsert into ops.migrations(name) values ('%s');\n" "$key"; } | $run --single-transaction 2>&1 ); then
    echo "применена $key"; napplied=$((napplied+1))
  else
    bad "ошибка в $key:"; printf '%s\n' "$out" | tail -15; break
  fi
done
[ $napplied = 0 ] && [ $FAIL = 0 ] && echo "новых нет"

step "4. Разовые запросы (server/run.sql)"
if [ -f "$REL/server/run.sql" ]; then
  h=$(sha256sum "$REL/server/run.sql" | cut -c1-64)
  if [ "$h" = "$(cat "$UB/run.sql.sha" 2>/dev/null)" ]; then echo "уже выполнены"
  else
    out=$(psql_db -P pager=off < "$REL/server/run.sql" 2>&1); rc=$?
    printf '%s\n' "$out" | head -c 30000; echo
    if [ $rc = 0 ]; then echo "$h" > "$UB/run.sql.sha"; else bad "run.sql завершился с ошибкой"; fi
  fi
else echo "нет"; fi

step "5. Сайт"
if ( cd "$REL" && UB_SB_KEY="$ANON" UB_VENDOR_DIR="$UB/vendor" python3 build.py >/dev/null 2>&1 ); then
  rsync -a --delete \
    --include=/index.html --include=/manifest.webmanifest --include=/sw.js \
    --include=/icons/ --include='/icons/**' --include=/docs/ --include='/docs/*.html' --include='/docs/*.css' \
    --exclude='*' "$REL/" "$UB/site/"
  echo "выложен ($(du -sh "$UB/site" | cut -f1))"
else bad "сборка build.py не прошла"; fi

step "6. Проверка"
for _ in $(seq 1 12); do docker compose ps functions --format '{{.Status}}' | grep -q healthy && break; sleep 5; done
docker compose ps --format '{{.Service}}: {{.Status}}' | sort
HOSTN=${URL#https://}
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' --resolve "$HOSTN:443:127.0.0.1" "$@"; }
c=$(code "$URL/");                                              echo "сайт $c";    [ "$c" = 200 ] || bad "сайт не отвечает"
c=$(code -H "apikey: $ANON" "$URL/rest/v1/cities?select=id&limit=1"); echo "API $c";     [ "$c" = 200 ] || bad "API не отвечает"
c=$(code "$URL/auth/v1/health" -H "apikey: $ANON");             echo "вход $c";    [ "$c" = 200 ] || bad "сервис входа не отвечает"
c=$(code -X POST -H 'Content-Type: application/json' -d '{"action":"challenge"}' "$URL/functions/v1/verify-phone"); echo "функции $c"; [ "$c" = 200 ] || bad "функция verify-phone не отвечает"
if [ $FAIL = 1 ]; then
  echo "-- caddy (сертификат и ошибки):"
  docker compose logs caddy --since 30m --no-log-prefix 2>&1 | grep -iE 'certificate|obtain|acme|error|tls' | tail -8 | cut -c1-400
  echo "-- снаружи: $(curl -s -o /dev/null -m 10 -w '%{http_code}' "$URL/" 2>&1)"
fi
free -m | awk '/Mem/{printf "память: занято %s из %s МБ\n",$3,$2}'
df -h / | awk 'NR==2{printf "диск: занято %s из %s\n",$3,$2}'

echo; [ $FAIL = 0 ] && echo "ИТОГ: OK" || echo "ИТОГ: ЕСТЬ ОШИБКИ"
exit $FAIL
