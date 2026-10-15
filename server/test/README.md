# server/test — локальная копия сервера для проверки

Для среды Claude (и любого Linux без Docker): база, API, вход и управление поднимаются за ~10 секунд,
без Supabase и без интернета (кроме первой загрузки PostgREST и supabase-js).

```bash
bash server/test/local.sh all        # setup + новая база + сборка сайта + запуск + smoke.py
python3 server/test/smoke.py --browser
python3 server/test/browser.py /admin/#security --as admin --widths 390,1440 --themes light,dark
bash server/test/local.sh psql -c "select count(*) from public.profiles"
bash server/test/local.sh sql check.sql   # проверки с откатом: begin; … rollback;
python3 server/test/ideas_test.py        # «Предложить идею» (027): отправка, лимит, управление, push, ПДн, чистка
bash server/test/local.sh site            # после правок src/ — пересобрать сайт
bash server/test/local.sh db && bash server/test/local.sh restart   # после правок миграций — база заново
```

## Что внутри

| Часть | Как сделано |
|---|---|
| База | Postgres 16 (`/usr/lib/postgresql/16/bin`) от пользователя `pg`, данные в `/home/pg/ub-data`, сокет `/tmp`, порт 5544 |
| Заглушки Supabase | `stubs.sql`: роли anon / authenticated / service_role / authenticator, права по умолчанию в public, `auth.users`, `auth.uid()`, `auth.jwt()`, `storage.buckets/objects/foldername`, `vault` |
| pg_cron, pg_net | поддельные расширения `ext/` (ставит `setup` в каталог расширений Postgres): `cron.schedule` пишет в `cron.job`, `net.http_post` — в `net.requests`. Файлы миграций грузятся без правок |
| Миграции | как `deploy.sh`: `server/db/*.sql`, затем `supabase/migrations/*.sql`, каждый файл `--single-transaction`, учёт в `ops.migrations` |
| API | настоящий PostgREST 12.2.3 (`.run/bin`) — права, RLS и вложенные выборки как на сервере |
| Вход | `gateway.py` — заглушка GoTrue: гость, вход по `token_hash`, обновление токена, выход, admin-методы для verify-phone |
| Функции | настоящие `supabase/functions/*` под Node (`functions.mjs`: подмена `Deno.env`, `Deno.serve`, `jsr:@supabase/supabase-js`). Тестовые номера +7 000 000-00-01…03, код 1234. Свои переменные — `.run/functions.env` |
| Хранилище | `gateway.py`: загрузка и удаление с проверкой политик `storage.objects`, файлы в `.run/storage` |
| Сайт | `local.sh site` собирает копию в `.run/site` как на сервере (`UB_SB_KEY`, дата Про из базы); `index.html` в репозитории не трогает |
| Экраны | `browser.py` (Playwright): сессия кладётся в localStorage до загрузки (`sb-127-auth-token`, `ub-admin-auth`) |

Шлюз `http://127.0.0.1:8000`: `/`, `/admin/`, `/rest/v1`, `/auth/v1`, `/storage/v1`, `/functions/v1`,
и `/__test/session` — сессия без звонка: `{"phone":"70000000001"}`, `{"anon":true}`,
`{"phone":"70000000003","admin":true}` (назначает администратором, пароль `test-password-1`, управление открыто).
Заголовок `X-Test-IP` подменяет IP для лимитов verify-phone.

Ключи и секрет JWT в `gateway.py` — только для локальной проверки, на сервере свои.

## Чем отличается от сервера

- Миграции выполняет суперпользователь `postgres` (на сервере — `postgres` без прав суперпользователя, `-- ub:superuser` — `supabase_admin`). Ошибки прав владельца локально можно не увидеть — финальная проверка всё равно на сервере (`server/run.sql`, с откатом).
- Задания cron не выполняются — вызывать функции руками (`select public.daily_maintenance();`), команды — в `cron.job`.
- push не уходит: `push_kick()` пишет запрос в `net.requests`; send-push можно вызвать через `/functions/v1/send-push` (доставка на настоящие телефоны не проверяется).
- Zvonok не вызывается: без ключей работают только тестовые номера.
- Фото демо-мастеров на локальной копии нет (404).
- Хранилище повторяет правила Supabase: удаление требует политик DELETE **и** SELECT (до миграции 025 у `photos` не было SELECT, и удаление из приложения ничего не удаляло; smoke.py это проверяет). Файлов на диске сервера заглушка не трогает.
