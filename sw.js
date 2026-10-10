/* Уустары бул — service worker.
   Страница: сначала сеть (чтобы обновления приходили сразу), без сети — сохранённая копия.
   Значки и шрифты: из кеша, в фоне обновляются.
   Запросы к Supabase не трогаем — данные всегда свежие. */
var VERSION = 'ub-v1';
var CORE = ['./', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/apple-touch-icon.png', 'icons/favicon-64.png'];

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

  // Свои файлы (значки, манифест) и шрифты Google
  var own = url.origin === self.location.origin;
  var font = url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
  if (!own && !font) return; // Supabase и всё остальное — напрямую в сеть

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
