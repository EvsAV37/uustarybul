# Уустары бул

Доска услуг местных мастеров. Прототип: https://evsav37.github.io/uustarybul

## Устройство
- `index.html` — собранное приложение (один файл, отдаётся GitHub Pages). Руками не править.
- `src/app.html` — разметка, стили, главная, поиск, страница мастера.
- `src/login.js` — вход по номеру (звонок-сброс Zvonok + запасной звонок на номер).
- `src/cabinet.js` — кабинет мастера, направления, услуги, фото, отзывы, жалобы.
- `build.py` — собирает `index.html` из `src/` и встраивает supabase-js 2.45.4.
- `supabase/functions/verify-phone/index.ts` — серверная функция входа (копия того, что развёрнуто в Supabase).

## Сборка и выкладка
```
python3 build.py
git add -A && git commit -m "..." && git push
```
GitHub Pages обновляется сам через 1–2 минуты.

## Сервер
Supabase, проект `uustarybul` (id icojobutpjjvsjkizaak). Схема базы — в миграциях проекта (Database → Migrations).
Тестовые номера входа: +7 000 000-00-01/02/03, код 1234 (выключить секретом DISABLE_TEST_LOGINS=1 перед запуском).

© 2026 Евсеев А.В.
