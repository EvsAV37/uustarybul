// Наши функции Supabase (Deno) под Node — для локальной проверки, без Deno и без jsr.io.
// Запуск: node --experimental-strip-types server/test/functions.mjs   (обычно через local.sh start)
//
// Подменяет Deno.env / Deno.serve, а 'jsr:@supabase/supabase-js@2' — на ту же supabase-js, что встроена в сайт
// (.run/vendor, скачивает build.py). Слушает 127.0.0.1:9000, путь /<имя функции>; шлюз пересылает /functions/v1/*.
// Переменные функций — из окружения: SUPABASE_URL и ключи ставятся сами, остальное (DISABLE_TEST_LOGINS=1,
// ZVONOK_*) можно задать при запуске или в server/test/.run/functions.env (строки ИМЯ=значение).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { register, createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const RUN = path.join(HERE, '.run');

// Ключи — те же, что у шлюза
const keys = Object.fromEntries(execFileSync('python3', [path.join(HERE, 'gateway.py'), 'keys']).toString()
  .trim().split('\n').map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
const env = {
  SUPABASE_URL: 'http://127.0.0.1:' + (process.env.UB_PORT || '8000'),
  SUPABASE_ANON_KEY: keys.anon,
  SUPABASE_SERVICE_ROLE_KEY: keys.service,
};
const envFile = path.join(RUN, 'functions.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2];
  }
}

// supabase-js из сборки сайта (UMD) → модуль для import
const umd = path.join(RUN, 'vendor', 'package', 'dist', 'umd', 'supabase.js');
if (!fs.existsSync(umd)) { console.error('нет ' + umd + ' — сначала bash server/test/local.sh site'); process.exit(1); }
// UMD-сборка ждёт self и publicPath, как в браузере — чиним так же, как build.py
globalThis.self ??= globalThis;
const patched = path.join(RUN, 'supabase-node.cjs');
fs.writeFileSync(patched, fs.readFileSync(umd, 'utf8').replace(
  'if(!e)throw new Error("Automatic publicPath is not supported in this browser");', 'if(!e)e="https://localhost/";'));
globalThis.__ubSupabase = createRequire(import.meta.url)(patched);
const shim = 'data:text/javascript,' + encodeURIComponent(
  'const s = globalThis.__ubSupabase; export const createClient = s.createClient; export default s;');
register('data:text/javascript,' + encodeURIComponent(`
  export async function resolve(spec, ctx, next) {
    if (spec.startsWith('jsr:@supabase/supabase-js') || spec.startsWith('npm:@supabase/supabase-js'))
      return { url: ${JSON.stringify(shim)}, shortCircuit: true };
    return next(spec, ctx);
  }`));

// Deno: env и serve
const handlers = {};
let loading = null;
globalThis.Deno = {
  env: { get: (k) => (k in env ? env[k] : process.env[k]), toObject: () => ({ ...process.env, ...env }) },
  serve: (a, b) => { handlers[loading] = typeof a === 'function' ? a : b; return { finished: new Promise(() => {}) }; },
};

const fnDir = path.join(ROOT, 'supabase', 'functions');
for (const name of fs.readdirSync(fnDir)) {
  const entry = path.join(fnDir, name, 'index.ts');
  if (!fs.existsSync(entry)) continue;
  loading = name;
  await import(pathToFileURL(entry).href);
  console.log('функция', name, handlers[name] ? 'загружена' : 'не вызвала Deno.serve');
}

const port = Number(process.env.UB_FN_PORT || 9000);
http.createServer(async (req, res) => {
  const name = (req.url || '/').split('?')[0].split('/')[1];
  const h = handlers[name];
  if (!h) { res.writeHead(404, { 'Content-Type': 'application/json' }); return res.end('{"error":"no function"}'); }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v != null) headers.set(k, Array.isArray(v) ? v.join(', ') : v);
  const hasBody = !['GET', 'HEAD'].includes(req.method || 'GET');
  try {
    const r = await h(new Request('http://127.0.0.1:' + port + req.url, {
      method: req.method, headers, body: hasBody ? Buffer.concat(chunks) : undefined }));
    const out = Buffer.from(await r.arrayBuffer());
    res.writeHead(r.status, Object.fromEntries(r.headers.entries()));
    res.end(out);
  } catch (e) {
    console.error(name, e);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(e) }));
  }
}).listen(port, '127.0.0.1', () => console.log('functions: http://127.0.0.1:' + port));
