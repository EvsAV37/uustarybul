# Копии базы «Уустары бул»

- **Что**: каждую ночь в 03:40 по Якутску `ub-backup` (таймер `ub-backup.timer`) делает `pg_dump -Fc` всей базы
  в `/opt/ub/backups/db-ГГГГ-ММ-ДД-ЧЧММ.dump`, хранит 7 последних. Рядом — `.counts` (сколько строк в главных таблицах).
- **Проверка**: по воскресеньям последняя копия восстанавливается во временную базу `ub_restore_test`
  (схемы public, auth, storage), числа строк сверяются с `.counts`, база удаляется.
- **Где видно**: управление → Обзор → «Система»: «Копия базы» и «Проверка копии». Итоги — в `ops.log` (90 дней).
- **Фото** (файлы хранилища) в эти копии не входят — их, как и весь сервер, сохраняет резервное копирование FirstVDS.

## Вручную (от root на сервере)

```bash
ub-backup status          # список копий
ub-backup dump            # копия сейчас
ub-backup restore-test    # пробное восстановление последней копии
```

## Если нужно вернуть данные

Чаще всего нужно вернуть отдельные строки (что-то удалили по ошибке) — восстановить копию рядом и взять нужное:

```bash
f=/opt/ub/backups/db-2026-10-20-0340.dump     # нужная копия
docker exec -i supabase-db psql -h localhost -U supabase_admin -c "create database ub_restore"
docker exec -i supabase-db psql -h localhost -U supabase_admin -d ub_restore -c \
  'create schema auth; create schema storage; create schema extensions;
   create extension pg_trgm schema extensions; create extension pgcrypto schema extensions; create extension "uuid-ossp" schema extensions;'
docker exec -i supabase-db pg_restore -h localhost -U supabase_admin -d ub_restore --no-owner --no-acl -n public -n auth -n storage < "$f"
# … посмотреть и перенести нужное, потом:
docker exec -i supabase-db psql -h localhost -U supabase_admin -c "drop database ub_restore"
```

Полный откат всей базы на копию — только если сервер цел, а база испорчена; делает Claude через выкладку
(с остановкой сервисов и предупреждением, что всё после копии пропадёт). Если потерян весь сервер — восстановление
из резервной копии FirstVDS (панель FirstVDS → Резервные копии).
