/* Уустары бул — service worker.
   Страница: сначала сеть (чтобы обновления приходили сразу), без сети — сохранённая копия.
   Значки и шрифт (свой, fonts/): из кеша, в фоне обновляются.
   Запросы к Supabase не трогаем — данные всегда свежие.
   Push: показывает уведомление, по нажатию открывает кабинет. */
var VERSION = 'ub-v10';
var CORE = ['./', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/apple-touch-icon.png', 'icons/favicon-64.png', 'icons/logo-mark.webp',
  'fonts/onest.css', 'fonts/onest-cyrillic.woff2', 'fonts/onest-latin.woff2'];

var OFFLINE_HTML = '<!doctype html><html lang="ru"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1"><title>Уустары бул</title>' +
  '<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center;' +
  'font-family:system-ui,-apple-system,sans-serif;background:#fff;color:#0B0C0E;padding:24px}' +
  '@media (prefers-color-scheme:dark){body{background:#1A1B1F;color:#F5F5F7}}' +
  'h1{font-size:24px;margin:0 0 8px}p{color:#8E939B;margin:0 0 24px}' +
  'button{font:inherit;font-weight:600;border:0;border-radius:14px;height:50px;padding:0 28px;background:#1A8048;color:#fff}</style>' +
  '</head><body><div><h1>Нет связи</h1><p>Проверьте интернет и попробуйте ещё раз.</p>' +
  '<button onclick="location.reload()">Обновить</button></div></body></html>';

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(VERSION).then(function (c) { return c.addAll(CORE); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== VERSION; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);
  // Управление (/admin) — всегда из сети и мимо кеша: его копия не должна подменить приложение
  if (/\/admin(\/|$)/.test(url.pathname)) return;

  // Страница приложения
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then(function (res) {
        if (res.ok) { var copy = res.clone(); caches.open(VERSION).then(function (c) { c.put('./', copy); }); }
        return res;
      }).catch(function () {
        return caches.match('./').then(function (hit) {
          return hit || new Response(OFFLINE_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
        });
      })
    );
    return;
  }

  // Свои файлы (значки, манифест, шрифт)
  var own = url.origin === self.location.origin;
  if (!own) return; // Supabase и всё остальное — напрямую в сеть
  // На своём сервере API живёт на том же адресе — его запросы тоже только в сеть
  if (own && /^\/(rest|auth|storage|functions|realtime)\/v1\//.test(url.pathname)) return;

  e.respondWith(caches.open(VERSION).then(function (c) {
    return c.match(req).then(function (hit) {
      var net = fetch(req).then(function (res) {
        if (res.ok || res.type === 'opaque') c.put(req, res.clone());
        return res;
      }).catch(function () { return hit || Response.error(); });
      return hit || net;
    });
  }));
});

// Push-уведомления (тексты готовит сервер, без персональных данных)
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Уустары бул', {
    body: d.body || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/favicon-64.png',
    tag: d.tag || undefined,
    lang: 'ru',
    data: { url: d.url || './?go=cab' }
  }));
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || './?go=cab', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (c.url.indexOf(self.registration.scope) === 0 && 'focus' in c) {
        c.postMessage({ go: 'cab' });
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  }));
});
