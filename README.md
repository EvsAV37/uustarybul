# Уустары бул

Доска услуг местных мастеров: https://uustarybul.ru (управление — https://uustarybul.ru/admin).
Старый адрес https://evsav37.github.io/uustarybul перенаправляет на новый.

## Устройство
- `src/app.html`, `src/login.js`, `src/pow.js`, `src/cabinet.js`, `src/settings.js` — приложение (PWA).
- `src/admin.html` — управление (/admin).
- `docs/src/*.html` — тексты документов (Соглашение, Политика, Согласия, Оферта).
- `build.py` — сборка. С `UB_SB_KEY` (на сервере) — приложение и управление; без ключа (перед коммитом) —
  страницы документов `docs/*.html`, `docs/docs.json` и `index.html`-перенаправление для GitHub Pages.
- `supabase/functions/` — серверные функции: `verify-phone` (вход по звонку Zvonok, задачка от ботов), `send-push` (уведомления).
- `supabase/migrations/`, `server/db/` — схема базы.
- `server/` — свой сервер: установка (`install.sh`), выкладка (`deploy.sh`), Caddy, fail2ban, копии базы (`ub-backup`,
  см. `README-backup.md`), сторож (`ub-watch`), чистка хранилища (`ub-cleanup`), таймер даты Про.
- `server/test/` — локальная копия сервера для проверки (см. `server/test/README.md`).

## Выкладка
```
python3 build.py
git add -A && git commit -m "..." && git push
```
После `git push` в `main` GitHub Actions передаёт версию на сервер (FirstVDS, Россия): `server/deploy.sh` обновляет
настройки, функции, базу и сайт и проверяет, что всё работает. Итог — файл `last.txt` в ветке `server-log`.

## Сервер
Свой Supabase (self-hosted) на FirstVDS, данные хранятся в России. Тестовые номера входа: +7 000 000-00-01/02/03,
код 1234 — перед запуском выключить в управлении (Настройки → Перед запуском).

© 2026 Евсеев А.В.
