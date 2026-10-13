# server/db — миграции только для своего сервера

deploy.sh применяет по порядку `server/db/*.sql`, затем `supabase/migrations/*.sql`, каждую один раз
(учёт в `ops.migrations`). Файл, первая строка которого `-- ub:superuser`, выполняется от supabase_admin.

- `001_cloud_schema.sql`, `002_cloud_data.sql` — выгрузка из облачного Supabase (export.yml), не править.
- `003_server.sql` — отличия своего сервера от облака.
