#!/usr/bin/env bash
# Локальная копия сервера «Уустары бул» для проверки в среде Claude (без Docker и без Supabase).
#
#   bash server/test/local.sh setup   — один раз: пользователь pg, psycopg2, PostgREST, поддельные pg_cron/pg_net
#   bash server/test/local.sh db      — новая база: заглушки Supabase + server/db/*.sql + supabase/migrations/*.sql
#   bash server/test/local.sh start   — база, PostgREST, функции (Node), шлюз http://127.0.0.1:8000 (сайт, /admin, API)
#   bash server/test/local.sh site    — пересобрать сайт после правок src/ (шлюз перезапускать не нужно)
#   bash server/test/local.sh stop | status | logs
#   bash server/test/local.sh psql [-c "..."]   — psql от postgres (суперпользователь)
#   bash server/test/local.sh sql FILE          — выполнить файл (проверку с откатом писать begin; … rollback;)
#   bash server/test/local.sh all     — setup + db + start + smoke
#
# Подробности — server/test/README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUN="$HERE/.run"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDATA="${UB_PGDATA:-/home/pg/ub-data}"
PGPORT="${UB_PGPORT:-5544}"
PGRST_VER="12.2.3"
mkdir -p "$RUN/logs" "$RUN/bin" "$RUN/storage"

as_pg() { runuser -u pg -- "$@"; }
psql_db() { "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h /tmp -p "$PGPORT" -U postgres -d postgres "$@"; }
pg_running() { as_pg "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }
pid_alive() { [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }

setup() {
  id pg >/dev/null 2>&1 || useradd -m -s /bin/bash pg
  python3 -c 'import psycopg2' 2>/dev/null || pip install -q --break-system-packages psycopg2-binary
  if [ ! -x "$RUN/bin/postgrest" ]; then
    curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/v$PGRST_VER/postgrest-v$PGRST_VER-linux-static-x64.tar.xz" \
      | tar xJ -C "$RUN/bin"
  fi
  local ext; ext="$("$PGBIN/pg_config" --sharedir)/extension"
  cp "$HERE"/ext/pg_cron* "$HERE"/ext/pg_net* "$ext/"
  python3 -c 'import playwright' 2>/dev/null || echo "нет playwright для Python — снимки экранов не получатся (pip install playwright)"
  echo "setup: готово (PostgREST $("$RUN/bin/postgrest" --version | head -1 | cut -d' ' -f2))"
}

pg_start() {
  pg_running && return 0
  as_pg "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/../ub-pg.log" -w \
    -o "-p $PGPORT -k /tmp -c listen_addresses='' -c timezone=UTC -c shared_preload_libraries=''" start >/dev/null
}

db() {
  [ -x "$RUN/bin/postgrest" ] || setup
  stop_services
  if pg_running; then as_pg "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null; fi
  rm -rf "$PGDATA"; as_pg mkdir -p "$PGDATA"
  as_pg "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
  pg_start
  psql_db -f "$HERE/stubs.sql" >/dev/null
  # Как deploy.sh: учёт в ops.migrations, каждый файл одной транзакцией
  psql_db -c "create schema if not exists ops; create table if not exists ops.migrations (name text primary key, applied_at timestamptz not null default now()); revoke all on schema ops from public;" >/dev/null
  local n=0 f key out
  for f in "$ROOT"/server/db/*.sql "$ROOT"/supabase/migrations/*.sql; do
    [ -f "$f" ] || continue
    key="$(basename "$(dirname "$f")")/$(basename "$f")"
    [ -n "$(psql_db -At -c "select 1 from ops.migrations where name = '$key'")" ] && continue
    if ! out=$( { cat "$f"; printf "\ninsert into ops.migrations(name) values ('%s');\n" "$key"; } | psql_db --single-transaction 2>&1 ); then
      echo "ОШИБКА в $key:"; printf '%s\n' "$out" | tail -15; exit 1
    fi
    n=$((n+1))
  done
  # Сброс кеша схемы PostgREST, если он уже запущен
  psql_db -c "notify pgrst, 'reload schema'" >/dev/null
  echo "db: применено файлов: $n; демо-мастеров: $(psql_db -At -c 'select count(*) from public.profiles where is_demo')"
}

site() {
  # Сборка как на сервере (SB_URL = адрес страницы, свой ключ), но в .run/site — index.html в репозитории не трогаем
  local anon; anon="$(python3 "$HERE/gateway.py" keys | sed -n 's/^anon=//p')"
  rm -rf "$RUN/site"; mkdir -p "$RUN/site"
  ( cd "$ROOT" && tar cf - --exclude=.git --exclude=server --exclude=vendor --exclude=admin . ) | tar xf - -C "$RUN/site"
  local fp; fp="$(psql_db -At -c "select coalesce(to_json(free_pro_until)#>>'{}', '') from public.app_settings limit 1" 2>/dev/null || true)"
  ( cd "$RUN/site" && UB_VENDOR_DIR="$RUN/vendor" UB_SB_KEY="$anon" UB_FREE_PRO="$fp" python3 build.py >/dev/null )
  echo "site: собран в $RUN/site"
}

start() {
  [ -d "$PGDATA" ] || db
  pg_start
  [ -f "$RUN/site/index.html" ] || site
  local secret; secret="$(python3 "$HERE/gateway.py" keys | sed -n 's/^secret=//p')"
  if ! pid_alive postgrest; then
    PGRST_DB_URI="postgres://authenticator:ub-local-test@/postgres?host=/tmp&port=$PGPORT" \
    PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_DB_EXTRA_SEARCH_PATH="public,extensions" \
    PGRST_JWT_SECRET="$secret" PGRST_SERVER_PORT=3000 PGRST_SERVER_HOST=127.0.0.1 PGRST_DB_CHANNEL_ENABLED=true \
      nohup "$RUN/bin/postgrest" >"$RUN/logs/postgrest.log" 2>&1 & echo $! >"$RUN/postgrest.pid"
  fi
  if ! pid_alive functions; then
    nohup node --experimental-strip-types --no-warnings "$HERE/functions.mjs" >"$RUN/logs/functions.log" 2>&1 & echo $! >"$RUN/functions.pid"
  fi
  if ! pid_alive gateway; then
    nohup python3 "$HERE/gateway.py" serve >"$RUN/logs/gateway.log" 2>&1 & echo $! >"$RUN/gateway.pid"
  fi
  for _ in $(seq 1 50); do curl -fsS -o /dev/null http://127.0.0.1:8000/rest/v1/cities?select=id \
      -H "apikey: $(python3 "$HERE/gateway.py" keys | sed -n 's/^anon=//p')" 2>/dev/null && { echo "start: http://127.0.0.1:8000 (сайт), /admin, /rest/v1, /auth/v1, /functions/v1"; return 0; }
    sleep 0.2; done
  echo "start: шлюз не отвечает — см. $RUN/logs/"; status; exit 1
}

stop_services() {
  local s; for s in gateway functions postgrest; do
    if pid_alive "$s"; then kill "$(cat "$RUN/$s.pid")" 2>/dev/null || true; fi; rm -f "$RUN/$s.pid"
  done
}
stop() { stop_services; if pg_running; then as_pg "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null; fi; echo "stop: остановлено"; }

status() {
  pg_running && echo "postgres: работает (порт $PGPORT)" || echo "postgres: остановлен"
  local s; for s in postgrest functions gateway; do pid_alive "$s" && echo "$s: работает" || echo "$s: остановлен"; done
}

case "${1:-}" in
  setup) setup ;;
  db) db ;;
  site) site ;;
  start) start ;;
  stop) stop ;;
  restart) stop_services; start ;;
  status) status ;;
  logs) tail -n 40 "$RUN"/logs/*.log ;;
  psql) shift; psql_db "$@" ;;
  sql) shift; psql_db -P pager=off -f "$1" ;;
  all) setup; db; site; start; python3 "$HERE/smoke.py" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
