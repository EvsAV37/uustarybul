#!/bin/bash
# Уустары бул — установка сервера с нуля (Ubuntu 24.04, от root). Одна команда:
#   curl -fsSL https://raw.githubusercontent.com/EvsAV37/uustarybul/main/server/install.sh | bash
#
# Что делает:
#   1. файл подкачки 2 ГБ, Docker из пакетов Ubuntu, зеркала Docker Hub, брандмауэр (22, 80, 443; панель :8443 — только через SSH-туннель)
#   2. Supabase (официальный self-hosted, версия закреплена) в /opt/supabase, все ключи — новые, только на сервере
#   3. Caddy с HTTPS на адресе сервера; сайт выкладывает GitHub Actions
#   4. пользователь deploy: по ключу может только одно — выложить новую версию (ub-run)
#   5. в конце печатает строку для секрета GitHub SERVER_SSH
# Повторный запуск безопасен: что уже сделано, пропускается.
set -euo pipefail

DOMAIN="${UB_DOMAIN:-elva-technologies.fvds.ru}"
RAW="https://raw.githubusercontent.com/EvsAV37/uustarybul/main/server"
SB_REF="self-hosted/v0.8.2"
SB=/opt/supabase
UB=/opt/ub

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "запустите от root"
. /etc/os-release
[ "$ID" = ubuntu ] || die "нужна Ubuntu (сейчас: $ID)"
export DEBIAN_FRONTEND=noninteractive

log "1/7 Файл подкачки"
if swapon --show | grep -q .; then echo "уже есть"; else
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-ub-swap.conf && sysctl -q -p /etc/sysctl.d/99-ub-swap.conf
  echo "создан 2 ГБ"
fi

log "2/7 Пакеты и Docker"
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 git jq openssl curl ca-certificates python3 rsync ufw >/dev/null
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://dockerhub.timeweb.cloud", "https://mirror.gcr.io"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
fi
systemctl enable -q docker && systemctl restart docker
# !reset и env_file с required нужны compose >= 2.24.4
cv=$(docker compose version --short 2>/dev/null || echo 0)
if [ "$(printf '%s\n2.24.4\n' "$cv" | sort -V | head -1)" != "2.24.4" ]; then
  warn "docker compose $cv старый — ставлю новый с GitHub"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
docker --version; docker compose version

log "3/7 Брандмауэр"
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443 >/dev/null
ufw --force enable >/dev/null && echo "открыты 22, 80, 443"

log "4/7 Supabase ($SB_REF)"
if [ -f "$SB/.env" ]; then echo "уже установлен"; else
  cd /opt
  curl -fsSL "https://raw.githubusercontent.com/supabase/supabase/$SB_REF/docker/setup.sh" -o /tmp/sb-setup.sh
  sh /tmp/sb-setup.sh -y --skip-deps --ref "$SB_REF" --project-dir supabase > /tmp/sb-setup.log 2>&1 \
    || { tail -30 /tmp/sb-setup.log; die "установка Supabase не удалась (полный журнал: /tmp/sb-setup.log)"; }
  echo "ключи созданы"
fi
cd "$SB"
set_env() { # set_env KEY VALUE — заменить или добавить строку в .env
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*$|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
set_env SUPABASE_PUBLIC_URL "https://$DOMAIN"
set_env API_EXTERNAL_URL "https://$DOMAIN/auth/v1"
set_env SITE_URL "https://$DOMAIN"
grep -q '^PROXY_DOMAIN=your-domain' .env && set_env PROXY_DOMAIN "$DOMAIN" || true   # потом сюда же добавится uustarybul.ru
grep -q '^STUDIO_DOMAIN=' .env || set_env STUDIO_DOMAIN "$DOMAIN:8443"
set_env DASHBOARD_USERNAME admin
set_env ENABLE_ANONYMOUS_USERS true
set_env ENABLE_PHONE_SIGNUP false        # телефон подтверждаем сами (Zvonok), иначе любой «зарегистрирует» чужой номер
set_env ENABLE_PHONE_AUTOCONFIRM false
set_env FUNCTIONS_VERIFY_JWT false       # обе функции проверяют вход сами (как в облаке)
set_env COMPOSE_FILE "docker-compose.yml:docker-compose.ub.yml"
chmod 600 .env
touch functions.env && chmod 600 functions.env

log "5/7 Настройки Уустары бул"
mkdir -p "$UB/releases" "$UB/site" "$UB/vendor" "$SB/ub"
curl -fsSL "$RAW/docker-compose.ub.yml" -o "$SB/docker-compose.ub.yml"
curl -fsSL "$RAW/Caddyfile" -o "$SB/ub/Caddyfile"
curl -fsSL "$RAW/ub-run" -o /usr/local/sbin/ub-run && chmod 755 /usr/local/sbin/ub-run
curl -fsSL "$RAW/ub-secret" -o /usr/local/sbin/ub-secret && chmod 755 /usr/local/sbin/ub-secret
if [ ! -f "$UB/site/index.html" ]; then
  printf '<!doctype html><meta charset="utf-8"><title>Уустары бул</title><p style="font:20px system-ui;margin:40px">Сервер Уустары бул работает. Приложение появится после первой выкладки.</p>\n' > "$UB/site/index.html"
fi

log "6/7 Запуск (первый раз качает образы — 5–15 минут)"
docker compose pull -q || die "не удалось скачать образы Docker — пришлите Claude последние строки выше"
docker compose up -d --wait --wait-timeout 600 || { docker compose ps; die "не все службы запустились — пришлите Claude вывод выше"; }
docker compose ps --format 'table {{.Service}}\t{{.Status}}'

log "7/7 Доступ для GitHub Actions"
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
cat > /usr/local/bin/ub-ssh <<'SH'
#!/bin/sh
exec sudo -n /usr/local/sbin/ub-run -- "$SSH_ORIGINAL_COMMAND"
SH
chmod 755 /usr/local/bin/ub-ssh
echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/ub-run' > /etc/sudoers.d/ub-deploy && chmod 440 /etc/sudoers.d/ub-deploy
visudo -cq || die "ошибка в sudoers"
mkdir -p /root/.ub && chmod 700 /root/.ub
[ -f /root/.ub/deploy_key ] || ssh-keygen -q -t ed25519 -N '' -C github-actions-uustarybul -f /root/.ub/deploy_key
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
printf 'restrict,command="/usr/local/bin/ub-ssh" %s\n' "$(cat /root/.ub/deploy_key.pub)" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys && chmod 600 /home/deploy/.ssh/authorized_keys
SECRET=$(jq -cn --rawfile k /root/.ub/deploy_key --arg h "$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" '{k:$k,h:$h}' | base64 -w0)

STUDIO_PASS=$(grep '^DASHBOARD_PASSWORD=' .env | cut -d= -f2-)
cat <<EOF

=====================================================================
 Готово. Сайт: https://$DOMAIN
 Панель Supabase: ssh -L 8443:127.0.0.1:8443 root@<IP>, затем http://localhost:8443  (логин admin, пароль ниже)
 Пароль панели: $STUDIO_PASS
 (пароль Claude не нужен; посмотреть снова: grep DASHBOARD /opt/supabase/.env)

 ПОСЛЕДНИЙ ШАГ. Скопируйте строку между линиями целиком (одна длинная строка)
 и добавьте её в GitHub: репозиторий uustarybul → Settings → Secrets and
 variables → Actions → New repository secret. Name: SERVER_SSH, Secret: строка.
---------------------------------------------------------------------
$SECRET
---------------------------------------------------------------------
 Показать строку ещё раз: bash /root/.ub/show-secret.sh
=====================================================================
EOF
printf '#!/bin/sh\necho "%s"\n' "$SECRET" > /root/.ub/show-secret.sh && chmod 700 /root/.ub/show-secret.sh
