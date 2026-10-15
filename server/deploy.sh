#!/bin/bash
# Уустары бул — выкладка версии на сервер. Запускает ub-run (от root) из распакованного архива коммита.
#   1. настройки сервера (compose, Caddyfile, ub-run, ub-secret, fail2ban, таймеры: дата Про, копии базы, сторож)
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
for t in ub-run ub-secret ub-free-pro-sync ub-backup ub-watch; do
  cmp -s "$REL/server/$t" "/usr/local/sbin/$t" || { install -m 755 "$REL/server/$t" "/usr/local/sbin/$t"; echo "обновлён $t"; }
done
# таймер: дата бесплатного Про в сайте = дата в базе (раз в 5 минут)
# таймеры: копия базы каждую ночь (ub-backup, план, шаг 3), сторож каждые 5 минут (ub-watch, шаг 4)
units=0
for u in ub-free-pro-sync.service ub-free-pro-sync.timer ub-backup.service ub-backup.timer ub-watch.service ub-watch.timer; do
  cmp -s "$REL/server/$u" "/etc/systemd/system/$u" || { install -m 644 "$REL/server/$u" "/etc/systemd/system/$u"; units=1; echo "обновлён $u"; }
done
if [ $units = 1 ]; then
  systemctl daemon-reload && systemctl enable -q --now ub-free-pro-sync.timer ub-backup.timer ub-watch.timer || bad "таймеры не включились"
fi
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

# fail2ban: SSH и панель Supabase :8443 (server/fail2ban). Журнал панели пишет Caddy в /var/log/ub-caddy.
install -d -m 750 /var/log/ub-caddy; touch /var/log/ub-caddy/studio.log
if ! command -v fail2ban-client >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  { apt-get install -y -qq fail2ban python3-systemd || { apt-get update -qq && apt-get install -y -qq fail2ban python3-systemd; }; } >/dev/null 2>&1 \
    && echo "установлен fail2ban $(fail2ban-client --version 2>/dev/null | head -1)" || bad "fail2ban не установился"
fi
f2b=0
for pair in jail.local:/etc/fail2ban/jail.d/uustarybul.local ub-studio.conf:/etc/fail2ban/filter.d/ub-studio.conf \
            fail2ban.local:/etc/fail2ban/fail2ban.d/uustarybul.local; do
  src="$REL/server/fail2ban/${pair%%:*}"; dst="${pair#*:}"
  [ -f "$src" ] && [ -d "$(dirname "$dst")" ] || continue
  cmp -s "$src" "$dst" || { install -m 644 "$src" "$dst"; f2b=1; echo "обновлён $(basename "$dst")"; }
done
if command -v fail2ban-client >/dev/null && { [ $f2b = 1 ] || ! systemctl is-active -q fail2ban; }; then
  if fail2ban-client -t >/dev/null 2>&1; then
    systemctl enable -q fail2ban; systemctl restart fail2ban
    for _ in $(seq 1 20); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
    # самопроверка на адресе из документации (192.0.2.0/24 — в интернете не встречается): бан → правило есть → разбан
    t=192.0.2.77; ok=1
    fail2ban-client set sshd banip $t >/dev/null 2>&1 && iptables -w -C f2b-sshd -s $t -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
      && iptables -w -C INPUT -p tcp -m multiport --dports ssh -j f2b-sshd 2>/dev/null || ok=0
    fail2ban-client set sshd unbanip $t >/dev/null 2>&1
    fail2ban-client set ub-studio banip $t >/dev/null 2>&1 && iptables -w -C f2b-ub-studio -s $t -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
      && iptables -w -C DOCKER-USER -p tcp -m multiport --dports 8443 -j f2b-ub-studio 2>/dev/null || ok=0
    fail2ban-client set ub-studio unbanip $t >/dev/null 2>&1
    [ $ok = 1 ] && echo "fail2ban: самопроверка бана прошла (SSH — INPUT, панель — DOCKER-USER)" || bad "fail2ban: бан не ставится в iptables"
  else bad "fail2ban: ошибка в настройках"; fail2ban-client -t 2>&1 | tail -5; fi
fi

step "2. Функции"
fchanged=0
for d in "$REL"/supabase/functions/*/; do
  n=$(basename "$d"); [ "$n" = main ] && continue
  out=$(rsync -r -c --delete -i "$d" "volumes/functions/$n/" | grep -v "^\.d")
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

# Первая копия базы и проверка восстановления — сразу, если копий ещё нет (дальше — таймер ночью)
if ! ls /opt/ub/backups/db-*.dump >/dev/null 2>&1; then
  echo "-- первая копия базы:"; /usr/local/sbin/ub-backup all || bad "копия базы или проверка восстановления не прошла"
fi

step "5. Сайт"
# дата бесплатного Про — в страницу, чтобы кабинет сразу показывал верный текст (в ISO, как отдаёт API)
FREE_PRO=$(psql_db -At -c "select coalesce(to_json(free_pro_until)#>>'{}', '') from public.app_settings limit 1" 2>/dev/null || true)
echo "дата бесплатного Про: ${FREE_PRO:-нет}"
if ( cd "$REL" && UB_SB_KEY="$ANON" UB_FREE_PRO="$FREE_PRO" UB_VENDOR_DIR="$UB/vendor" python3 build.py >/dev/null 2>&1 ); then
  rsync -a --delete \
    --include=/index.html --include=/manifest.webmanifest --include=/sw.js \
    --include=/admin/ --include=/admin/index.html --include=/icons/ --include='/icons/**' --include=/fonts/ --include='/fonts/**' --include=/docs/ --include='/docs/*.html' --include='/docs/*.css' --include='/docs/*.json' \
    --exclude='*' "$REL/" "$UB/site/"
  echo "выложен ($(du -sh "$UB/site" | cut -f1))"
else bad "сборка build.py не прошла"; fi

step "6. Проверка"
for _ in $(seq 1 12); do docker compose ps functions --format '{{.Status}}' | grep -q healthy && break; sleep 5; done
docker compose ps --format '{{.Service}}: {{.Status}}' | sort
HOSTN=${URL#https://}
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' --resolve "$HOSTN:443:127.0.0.1" "$@"; }
c=$(code "$URL/");                                              echo "сайт $c";    [ "$c" = 200 ] || bad "сайт не отвечает"
c=$(code "$URL/admin/");                                        echo "управление $c"; [ "$c" = 200 ] || bad "страница /admin не отвечает"
c=$(code -H "apikey: $ANON" "$URL/rest/v1/cities?select=id&limit=1"); echo "API $c";     [ "$c" = 200 ] || bad "API не отвечает"
c=$(code "$URL/auth/v1/health" -H "apikey: $ANON");             echo "вход $c";    [ "$c" = 200 ] || bad "сервис входа не отвечает"
c=$(code -X POST -H 'Content-Type: application/json' -d '{"action":"challenge"}' "$URL/functions/v1/verify-phone"); echo "функции $c"; [ "$c" = 200 ] || bad "функция verify-phone не отвечает"
if [ $FAIL = 1 ]; then
  echo "-- caddy (сертификат и ошибки):"
  docker compose logs caddy --since 30m --no-log-prefix 2>&1 | grep -iE 'certificate|obtain|acme|error|tls' | tail -8 | cut -c1-400
  echo "-- снаружи: $(curl -s -o /dev/null -m 10 -w '%{http_code}' "$URL/" 2>&1)"
fi
# Вход целиком (план, шаг 5): задачка → тестовый номер → код (сверка хеша) → сессия → выход. Звонка нет.
# Если тестовые номера выключены — только задачка: гость проходит проверку, потом удаляется.
SRV=$(grep '^SERVICE_ROLE_KEY=' .env | cut -d= -f2-)
vp() { curl -s -m 20 --resolve "$HOSTN:443:127.0.0.1" -X POST -H 'Content-Type: application/json' -H "apikey: $ANON" ${2:+-H "Authorization: Bearer $2"} -d "$1" "$URL/functions/v1/verify-phone"; }
pow() { vp '{"action":"challenge"}' "${1:-}" | python3 -c '
import sys, json, hashlib
c = json.load(sys.stdin)
for n in range(c["maxnumber"] + 1):
    if hashlib.sha256((c["salt"] + str(n)).encode()).hexdigest() == c["challenge"]:
        print(json.dumps({k: c[k] for k in ("algorithm", "challenge", "salt", "signature")} | {"number": n})); break'; }
auth() { curl -s -m 20 --resolve "$HOSTN:443:127.0.0.1" -X POST -H 'Content-Type: application/json' -H "apikey: $ANON" ${3:+-H "Authorization: Bearer $3"} -d "$2" "$URL/auth/v1/$1"; }
if ! grep -q '^DISABLE_TEST_LOGINS=1' functions.env 2>/dev/null && [ "$(psql_db -At -c 'select test_logins_off is null from public.app_settings limit 1' 2>/dev/null)" = t ]; then
  p=$(pow); r1=$(vp "$(jq -cn --argjson p "${p:-null}" '{action:"start",phone:"+7 000 000-00-01",pow:$p}')")
  r2=$(vp '{"action":"confirm","phone":"+7 000 000-00-01","code":"1234"}')
  th=$(printf '%s' "$r2" | jq -r '.token_hash // empty' 2>/dev/null)
  s=$( [ -n "$th" ] && auth verify "$(jq -cn --arg t "$th" '{type:"magiclink",token_hash:$t}')" )
  at=$(printf '%s' "$s" | jq -r '.access_token // empty' 2>/dev/null); ph=$(printf '%s' "$s" | jq -r '.user.phone // empty' 2>/dev/null)
  if [ -n "$at" ] && [ "$ph" = 70000000001 ]; then
    auth logout '{}' "$at" >/dev/null; echo "вход тестовым номером: ок (задачка, код по хешу, сессия, выход)"
  else bad "вход тестовым номером не прошёл: $(printf '%s | %s' "$r1" "$r2" | tr -d '\n' | cut -c1-200)"; fi
else
  g=$(auth signup '{"data":{}}'); gt=$(printf '%s' "$g" | jq -r '.access_token // empty' 2>/dev/null); gid=$(printf '%s' "$g" | jq -r '.user.id // empty' 2>/dev/null)
  p=$(pow "$gt"); r=$(vp "$(jq -cn --argjson p "${p:-null}" '{action:"guest",pow:$p}')" "$gt")
  [ -n "$gid" ] && curl -s -m 20 --resolve "$HOSTN:443:127.0.0.1" -X DELETE -H "apikey: $SRV" -H "Authorization: Bearer $SRV" "$URL/auth/v1/admin/users/$gid" >/dev/null
  [ "$(printf '%s' "$r" | jq -r '.ok' 2>/dev/null)" = true ] && echo "задачка для телефона: ок (тестовые номера выключены — вход не проверяется)" \
    || bad "задачка для телефона не прошла: $(printf '%s' "$r" | cut -c1-200)"
fi
systemctl is-active -q ub-free-pro-sync.timer && echo "таймер даты Про: работает" || bad "таймер даты Про не работает"
last=$(ls -1t /opt/ub/backups/db-*.dump 2>/dev/null | head -1)
if [ -n "$last" ]; then
  echo "копии базы: $(ls -1 /opt/ub/backups/db-*.dump | wc -l), последняя $(basename "$last") ($(du -h "$last" | cut -f1)); таймер: $(systemctl is-active ub-backup.timer)"
  [ -n "$(find "$last" -mmin -1600)" ] || bad "последней копии базы больше суток"
else bad "копий базы нет"; fi
# сторож: таймер и его последняя проверка (сама проверка во время выкладки пропускается)
w=$(psql_db -At -F'|' -c "select coalesce(to_char(checked_at at time zone 'Asia/Yakutsk','DD.MM HH24:MI'),'ещё не было'), jsonb_array_length(fails) from ops.watch_state" 2>/dev/null)
echo "сторож: таймер $(systemctl is-active ub-watch.timer), последняя проверка ${w%%|*}, сбоев ${w##*|}"
systemctl is-active -q ub-watch.timer || bad "сторож не работает"
f2b_n() { fail2ban-client status "$1" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p'; }
if systemctl is-active -q fail2ban && [ -n "$(f2b_n sshd)" ] && [ -n "$(f2b_n ub-studio)" ]; then
  echo "fail2ban: работает, сейчас заблокировано — SSH $(f2b_n sshd), панель $(f2b_n ub-studio)"
  # неверный пароль панели с самого сервера → строка в журнале Caddy → её видит фильтр fail2ban
  sl=/var/log/ub-caddy/studio.log; n0=$(wc -l < "$sl" 2>/dev/null || echo 0)
  curl -s -o /dev/null -m 10 -u ub-check:wrong --resolve "$HOSTN:8443:127.0.0.1" "https://$HOSTN:8443/" || true
  sleep 1; tmpl=$(mktemp); tail -n +$((n0 + 1)) "$sl" > "$tmpl" 2>/dev/null
  m=$(fail2ban-regex "$tmpl" /etc/fail2ban/filter.d/ub-studio.conf 2>/dev/null | sed -n 's/^Lines: .*, \([0-9]*\) matched.*/\1/p'); rm -f "$tmpl"
  [ "${m:-0}" -ge 1 ] && echo "панель: неверный пароль попадает в журнал и в фильтр fail2ban" || bad "панель: неверный пароль не виден fail2ban"
else bad "fail2ban не работает"; fi
free -m | awk '/Mem/{printf "память: занято %s из %s МБ\n",$3,$2}'
df -h / | awk 'NR==2{printf "диск: занято %s из %s\n",$3,$2}'

echo; [ $FAIL = 0 ] && echo "ИТОГ: OK" || echo "ИТОГ: ЕСТЬ ОШИБКИ"
exit $FAIL
