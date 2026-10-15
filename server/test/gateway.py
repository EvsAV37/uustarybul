#!/usr/bin/env python3
"""Шлюз локальной копии сервера «Уустары бул» — одним адресом http://127.0.0.1:8000, как Caddy на сервере.

  /                 сайт из server/test/.run/site (собирает local.sh site)
  /admin/           управление
  /rest/v1/...      PostgREST (настоящий, :3000)
  /auth/v1/...      заглушка GoTrue: гость (signInAnonymously), вход по token_hash, обновление токена, выход,
                    admin-методы, которыми пользуется verify-phone (пользователи, generateLink)
  /storage/v1/...   заглушка хранилища: загрузка и удаление с проверкой RLS по storage.objects, файлы — в .run/storage
  /functions/v1/x   наши функции (verify-phone, send-push) под Node — functions.mjs (:9000)
  /__test/session   выдать сессию без звонка (для снимков экранов): {"phone":"70000000001","admin":true,"password":"..."}
                    или {"anon":true}; admin=true — назначает администратором, задаёт пароль и открывает управление

python3 gateway.py keys   — секрет и ключи anon / service_role (только для локальной проверки)
python3 gateway.py serve  — запустить (обычно через local.sh start)
"""
import base64, hashlib, hmac, json, os, re, secrets, sys, time, uuid, mimetypes, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, '.run')
SITE = os.path.join(RUN, 'site')
STORE = os.path.join(RUN, 'storage')
PGPORT = int(os.environ.get('UB_PGPORT', '5544'))
PORT = int(os.environ.get('UB_PORT', '8000'))
SECRET = 'ub-local-test-jwt-secret-not-for-production-0123456789'
ORIGIN = f'http://127.0.0.1:{PORT}'


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


def jwt_encode(claims):
    h = b64u(json.dumps({'alg': 'HS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
    p = b64u(json.dumps(claims, separators=(',', ':')).encode())
    s = b64u(hmac.new(SECRET.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest())
    return f'{h}.{p}.{s}'


def jwt_decode(tok):
    try:
        h, p, s = tok.split('.')
        if not hmac.compare_digest(b64u(hmac.new(SECRET.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest()), s):
            return None
        c = json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
        return c if c.get('exp', 0) > time.time() else None
    except Exception:
        return None


ANON = jwt_encode({'role': 'anon', 'iss': 'supabase', 'iat': 1760000000, 'exp': 2000000000})
SERVICE = jwt_encode({'role': 'service_role', 'iss': 'supabase', 'iat': 1760000000, 'exp': 2000000000})


def db():
    import psycopg2
    c = psycopg2.connect(host='/tmp', port=PGPORT, user='postgres', dbname='postgres')
    c.autocommit = False
    return c


def q(sql, args=(), one=False, claims=None, role=None):
    """Запрос от суперпользователя или (role + claims) — как его выполнил бы PostgREST."""
    c = db()
    try:
        with c.cursor() as cur:
            if role:
                cur.execute('select set_config(%s, %s, true)', ('request.jwt.claims', json.dumps(claims or {})))
                cur.execute(f'set local role {role}')
            cur.execute(sql, args)
            rows = cur.fetchall() if cur.description else []
            cols = [d[0] for d in cur.description] if cur.description else []
        c.commit()
        res = [dict(zip(cols, r)) for r in rows]
        return (res[0] if res else None) if one else res
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()


def iso(v):
    return v.isoformat() if v is not None and hasattr(v, 'isoformat') else v


USER_COLS = 'id, aud, role, email, phone, email_confirmed_at, phone_confirmed_at, last_sign_in_at, ' \
            'raw_app_meta_data, raw_user_meta_data, is_anonymous, created_at, updated_at'


def user_json(u):
    return {
        'id': str(u['id']), 'aud': u['aud'] or 'authenticated', 'role': u['role'] or 'authenticated',
        'email': u['email'] or '', 'phone': u['phone'] or '',
        'email_confirmed_at': iso(u['email_confirmed_at']), 'phone_confirmed_at': iso(u['phone_confirmed_at']),
        'confirmed_at': iso(u['phone_confirmed_at'] or u['email_confirmed_at']),
        'last_sign_in_at': iso(u['last_sign_in_at']),
        'app_metadata': u['raw_app_meta_data'] or {}, 'user_metadata': u['raw_user_meta_data'] or {},
        'identities': [], 'is_anonymous': bool(u['is_anonymous']),
        'created_at': iso(u['created_at']), 'updated_at': iso(u['updated_at']),
    }


def get_user(uid):
    return q(f'select {USER_COLS} from auth.users where id = %s', (str(uid),), one=True)


def new_session(uid, sid=None):
    u = get_user(uid)
    if sid is None:
        sid = str(q('insert into auth.sessions (user_id) values (%s) returning id', (str(uid),), one=True)['id'])
        q('update auth.users set last_sign_in_at = now() where id = %s', (str(uid),))
        u = get_user(uid)
    rt = secrets.token_urlsafe(24)
    q('insert into auth.refresh_tokens (token, user_id, session_id) values (%s, %s, %s)', (rt, str(uid), sid))
    now = int(time.time())
    claims = {
        'aud': 'authenticated', 'exp': now + 3600, 'iat': now, 'iss': ORIGIN + '/auth/v1', 'sub': str(uid),
        'email': u['email'] or '', 'phone': u['phone'] or '', 'role': 'authenticated', 'aal': 'aal1',
        'app_metadata': u['raw_app_meta_data'] or {}, 'user_metadata': u['raw_user_meta_data'] or {},
        'amr': [{'method': 'anonymous' if u['is_anonymous'] else 'otp', 'timestamp': now}],
        'session_id': sid, 'is_anonymous': bool(u['is_anonymous']),
    }
    return {'access_token': jwt_encode(claims), 'token_type': 'bearer', 'expires_in': 3600,
            'expires_at': now + 3600, 'refresh_token': rt, 'user': user_json(u)}


def session_user(tok):
    """Пользователь по токену доступа, если его сессия жива; иначе None."""
    c = jwt_decode(tok)
    if not c or c.get('role') != 'authenticated':
        return None, None
    if not q('select 1 from auth.sessions where id = %s', (c.get('session_id'),), one=True):
        return None, None
    return get_user(c['sub']), c


def admin_session(phone, password='test-password-1', unlock=True):
    """Сессия администратора управления: аккаунт, admin_grant, пароль, открытая админ-сессия."""
    uid = ensure_user(phone)
    q('select public.admin_grant(%s)', ('+' + phone,))
    s = new_session(uid)
    claims = jwt_decode(s['access_token'])
    q('select public.admin_set_password(%s)', (password,), claims=claims, role='authenticated')
    if not unlock:
        q('select public.admin_lock()', claims=claims, role='authenticated')
    return s


def ensure_user(phone):
    u = q('select id from auth.users where phone = %s', (phone,), one=True)
    if u:
        return u['id']
    email = f'{phone}@phone.uustarybul.ru'
    return q("""insert into auth.users (instance_id, aud, role, phone, phone_confirmed_at, email, email_confirmed_at,
                raw_app_meta_data, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000000',
                'authenticated', 'authenticated', %s, now(), %s, now(), '{"provider":"phone","providers":["phone"]}', '{}')
             returning id""", (phone, email), one=True)['id']


def parse_multipart(body, ctype):
    m = re.search(r'boundary="?([^";]+)"?', ctype)
    if not m:
        return body, 'application/octet-stream'
    b = ('--' + m.group(1)).encode()
    for part in body.split(b)[1:]:
        if part.startswith(b'--'):
            break
        head, _, data = part.partition(b'\r\n\r\n')
        h = head.decode('utf8', 'replace')
        if 'filename=' in h or 'name=""' in h:
            ct = re.search(r'Content-Type:\s*([^\r\n]+)', h, re.I)
            return data[:-2] if data.endswith(b'\r\n') else data, (ct.group(1).strip() if ct else 'application/octet-stream')
    return b'', 'application/octet-stream'


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *a):
        sys.stderr.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % a))

    # ---------- ответы
    def send(self, status, body=b'', ctype='application/json', extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def err(self, status, msg, code=None):
        self.send(status, {'code': status, 'error_code': code or 'error', 'msg': msg, 'message': msg, 'error': code or msg})

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''

    def jbody(self):
        try:
            return json.loads(self.body() or b'{}')
        except Exception:
            return {}

    def bearer(self):
        a = self.headers.get('Authorization') or ''
        return a[7:].strip() if a.lower().startswith('bearer ') else (self.headers.get('apikey') or '')

    # ---------- маршруты
    def do_OPTIONS(self):
        self.send(204, b'', extra={
            'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer, range, x-upsert, '
                                            'accept-profile, content-profile, x-supabase-api-version',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'})

    def do_GET(self): self.route()
    def do_HEAD(self): self.route()
    def do_POST(self): self.route()
    def do_PUT(self): self.route()
    def do_PATCH(self): self.route()
    def do_DELETE(self): self.route()

    def route(self):
        path = urlsplit(self.path).path
        try:
            if path.startswith('/rest/v1/'):
                return self.proxy('http://127.0.0.1:3000' + self.path[len('/rest/v1'):], rest=True)
            if path.startswith('/functions/v1/'):
                return self.proxy('http://127.0.0.1:9000/' + self.path[len('/functions/v1/'):])
            if path.startswith('/auth/v1/'):
                return self.auth(path[len('/auth/v1'):])
            if path.startswith('/storage/v1/'):
                return self.storage(path[len('/storage/v1'):])
            if path == '/__test/session':
                return self.test_session()
            return self.static(path)
        except BrokenPipeError:
            pass
        except Exception as e:  # ошибка заглушки — видна в журнале и в ответе
            import traceback
            traceback.print_exc()
            self.err(500, f'gateway: {e}')

    def proxy(self, url, rest=False):
        data = self.body() if self.command in ('POST', 'PUT', 'PATCH', 'DELETE') else None
        hdr = {k: v for k, v in self.headers.items()
               if k.lower() not in ('host', 'content-length', 'connection', 'accept-encoding')}
        if rest and not self.headers.get('Authorization') and self.headers.get('apikey'):
            hdr['Authorization'] = 'Bearer ' + self.headers['apikey']
        hdr['X-Forwarded-For'] = self.headers.get('X-Test-IP') or self.client_address[0]
        req = urllib.request.Request(url, data=data, headers=hdr, method=self.command)
        try:
            r = urllib.request.urlopen(req, timeout=60)
        except urllib.error.HTTPError as e:
            r = e
        except urllib.error.URLError as e:
            return self.err(502, f'нет ответа от {url.split("/")[2]}: {e.reason}')
        body = r.read()
        extra = {k: v for k, v in r.headers.items()
                 if k.lower() in ('content-range', 'preference-applied', 'location')}
        self.send(r.status if hasattr(r, 'status') else r.code, body, r.headers.get('Content-Type') or 'application/json', extra)

    # ---------- статика
    def static(self, path):
        if path == '/admin':
            return self.send(301, b'', 'text/plain', {'Location': '/admin/'})
        rel = unquote(path).lstrip('/')
        if rel == '' or rel.endswith('/'):
            rel += 'index.html'
        full = os.path.realpath(os.path.join(SITE, rel))
        if not full.startswith(os.path.realpath(SITE) + os.sep) or not os.path.isfile(full):
            return self.err(404, 'not found')
        ct = mimetypes.guess_type(full)[0] or 'application/octet-stream'
        if full.endswith('.webmanifest'):
            ct = 'application/manifest+json'
        if ct.startswith('text/') or ct in ('application/javascript', 'application/json'):
            ct += '; charset=utf-8'
        with open(full, 'rb') as f:
            self.send(200, f.read(), ct)

    # ---------- заглушка GoTrue
    def auth(self, p):
        qs = parse_qs(urlsplit(self.path).query)
        if p == '/settings':
            return self.send(200, {'external': {'phone': False, 'email': True, 'anonymous_users': True},
                                   'disable_signup': False, 'mailer_autoconfirm': True, 'phone_autoconfirm': True})
        if p == '/signup' and self.command == 'POST':
            b = self.jbody()
            if b.get('email') or b.get('phone'):
                return self.err(422, 'Signups not allowed for this instance', 'signup_disabled')
            u = q("""insert into auth.users (instance_id, aud, role, is_anonymous, raw_app_meta_data, raw_user_meta_data)
                     values ('00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', true, '{}', %s)
                     returning id""", (json.dumps(b.get('data') or {}),), one=True)
            return self.send(200, new_session(u['id']))
        if p == '/verify' and self.command == 'POST':
            b = self.jbody()
            row = q('delete from auth.one_time_tokens where token_hash = %s and created_at > now() - interval \'1 hour\' returning user_id',
                    (b.get('token_hash') or '',), one=True)
            if not row:
                return self.err(403, 'Email link is invalid or has expired', 'otp_expired')
            return self.send(200, new_session(row['user_id']))
        if p == '/token' and self.command == 'POST':
            if (qs.get('grant_type') or [''])[0] != 'refresh_token':
                return self.err(400, 'unsupported grant_type', 'validation_failed')
            rt = self.jbody().get('refresh_token') or ''
            row = q('update auth.refresh_tokens set revoked = true where token = %s and not revoked returning user_id, session_id',
                    (rt,), one=True)
            if not row or not q('select 1 from auth.sessions where id = %s', (row['session_id'],), one=True):
                return self.err(400, 'Invalid Refresh Token: Refresh Token Not Found', 'refresh_token_not_found')
            return self.send(200, new_session(row['user_id'], str(row['session_id'])))
        if p == '/logout' and self.command == 'POST':
            u, c = session_user(self.bearer())
            if u:
                scope = (qs.get('scope') or ['global'])[0]
                if scope == 'local':
                    q('delete from auth.sessions where id = %s', (c['session_id'],))
                elif scope == 'others':
                    q('delete from auth.sessions where user_id = %s and id <> %s', (c['sub'], c['session_id']))
                else:
                    q('delete from auth.sessions where user_id = %s', (c['sub'],))
            return self.send(204, b'')
        if p == '/user' and self.command == 'GET':
            u, _ = session_user(self.bearer())
            return self.send(200, user_json(u)) if u else self.err(403, 'Session from session_id claim in JWT does not exist', 'session_not_found')
        if p.startswith('/admin/'):
            c = jwt_decode(self.bearer())
            if not c or c.get('role') != 'service_role':
                return self.err(403, 'User not allowed', 'not_admin')
            return self.auth_admin(p[len('/admin'):])
        return self.err(404, 'auth stub: ' + p)

    def auth_admin(self, p):
        m = re.fullmatch(r'/users/([0-9a-f-]{36})', p)
        if m and self.command == 'GET':
            u = get_user(m.group(1))
            return self.send(200, user_json(u)) if u else self.err(404, 'User not found', 'user_not_found')
        if m and self.command == 'PUT':
            b = self.jbody()
            sets, args = [], []
            if 'phone' in b:
                sets.append('phone = %s'); args.append(b['phone'] or None)
                if b.get('phone_confirm'):
                    sets.append('phone_confirmed_at = coalesce(phone_confirmed_at, now())')
            if 'email' in b:
                sets.append('email = %s'); args.append(b['email'] or None)
                if b.get('email_confirm'):
                    sets.append('email_confirmed_at = coalesce(email_confirmed_at, now())')
            if b.get('phone') or b.get('email'):
                sets.append('is_anonymous = false')
            if not sets:
                return self.send(200, user_json(get_user(m.group(1))))
            try:
                q('update auth.users set ' + ', '.join(sets) + ', updated_at = now() where id = %s', (*args, m.group(1)))
            except Exception as e:
                return self.err(422, str(e).split('\n')[0], 'phone_exists' if 'phone' in str(e) else 'email_exists')
            u = get_user(m.group(1))
            return self.send(200, user_json(u)) if u else self.err(404, 'User not found', 'user_not_found')
        if p == '/users' and self.command == 'POST':
            b = self.jbody()
            try:
                u = q("""insert into auth.users (instance_id, aud, role, phone, phone_confirmed_at, email, email_confirmed_at,
                         raw_app_meta_data, raw_user_meta_data)
                         values ('00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', %s,
                                 case when %s then now() end, %s, case when %s then now() end,
                                 '{"provider":"phone","providers":["phone"]}', '{}') returning id""",
                      (b.get('phone'), bool(b.get('phone_confirm')), b.get('email'), bool(b.get('email_confirm'))), one=True)
            except Exception as e:
                return self.err(422, 'A user with this phone number has already been registered', 'phone_exists') \
                    if 'phone' in str(e) else self.err(422, str(e).split('\n')[0])
            return self.send(200, user_json(get_user(u['id'])))
        if p == '/generate_link' and self.command == 'POST':
            b = self.jbody()
            u = q(f'select {USER_COLS} from auth.users where email = %s', (b.get('email') or '',), one=True)
            if not u:
                return self.err(404, 'User not found', 'user_not_found')
            th = hashlib.sha224(secrets.token_bytes(16)).hexdigest()
            q('insert into auth.one_time_tokens (token_hash, user_id) values (%s, %s)', (th, str(u['id'])))
            return self.send(200, {**user_json(u), 'action_link': f'{ORIGIN}/auth/v1/verify?token={th}&type=magiclink',
                                   'email_otp': '000000', 'hashed_token': th, 'redirect_to': ORIGIN,
                                   'verification_type': 'magiclink'})
        return self.err(404, 'auth admin stub: ' + p)

    # ---------- заглушка хранилища
    def storage(self, p):
        m = re.fullmatch(r'/object/public/([^/]+)/(.+)', p)
        if m and self.command in ('GET', 'HEAD'):
            b = q('select public from storage.buckets where id = %s', (m.group(1),), one=True)
            f = os.path.realpath(os.path.join(STORE, m.group(1), unquote(m.group(2))))
            if not b or not b['public'] or not f.startswith(os.path.realpath(STORE) + os.sep) or not os.path.isfile(f):
                return self.err(400 if not b else 404, 'Object not found', 'not_found')
            meta = q('select metadata from storage.objects where bucket_id = %s and name = %s',
                     (m.group(1), unquote(m.group(2))), one=True)
            with open(f, 'rb') as fh:
                return self.send(200, fh.read(), ((meta or {}).get('metadata') or {}).get('mimetype') or 'application/octet-stream')
        claims = jwt_decode(self.bearer())
        if not claims:
            return self.err(400, 'Invalid JWT', 'InvalidJWT')
        role = claims.get('role') if claims.get('role') in ('anon', 'authenticated', 'service_role') else 'anon'
        m = re.fullmatch(r'/object/([^/]+)/(.+)', p)
        if m and self.command in ('POST', 'PUT'):
            bucket, name = m.group(1), unquote(m.group(2))
            raw = self.body()
            data, ctype = parse_multipart(raw, self.headers.get('Content-Type') or '') \
                if (self.headers.get('Content-Type') or '').startswith('multipart/') else (raw, self.headers.get('Content-Type') or 'application/octet-stream')
            bk = q('select file_size_limit, allowed_mime_types from storage.buckets where id = %s', (bucket,), one=True)
            if not bk:
                return self.err(404, 'Bucket not found', 'Bucket not found')
            if bk['file_size_limit'] and len(data) > bk['file_size_limit']:
                return self.err(413, 'The object exceeded the maximum allowed size', 'Payload too large')
            if bk['allowed_mime_types'] and ctype.split(';')[0] not in bk['allowed_mime_types']:
                return self.err(415, f'mime type {ctype} is not supported', 'invalid_mime_type')
            upsert = (self.headers.get('x-upsert') or '').lower() == 'true' or self.command == 'PUT'
            meta = json.dumps({'mimetype': ctype, 'size': len(data)})
            # Как storage-api: без RETURNING (у photos нет политики SELECT — чтение публичное, мимо RLS)
            oid = str(uuid.uuid4())
            try:
                exists = q('select id from storage.objects where bucket_id = %s and name = %s', (bucket, name), one=True)
                if exists and not upsert:
                    return self.err(409, 'The resource already exists', 'Duplicate')
                if exists:
                    oid = str(exists['id'])
                    q('update storage.objects set metadata = %s, updated_at = now() where bucket_id = %s and name = %s',
                      (meta, bucket, name), claims=claims, role=role)
                    if not q('select 1 from storage.objects where id = %s and metadata = %s::jsonb', (oid, meta), one=True):
                        return self.err(403, 'new row violates row-level security policy', 'Unauthorized')
                else:
                    q('insert into storage.objects (id, bucket_id, name, owner, metadata) values (%s, %s, %s, %s, %s)',
                      (oid, bucket, name, claims.get('sub'), meta), claims=claims, role=role)
            except Exception as e:
                s = str(e)
                return self.err(403, 'new row violates row-level security policy', 'Unauthorized') \
                    if 'row-level security' in s else self.err(400, s.split('\n')[0])
            f = os.path.join(STORE, bucket, name)
            os.makedirs(os.path.dirname(f), exist_ok=True)
            with open(f, 'wb') as fh:
                fh.write(data)
            return self.send(200, {'Key': f'{bucket}/{name}', 'Id': oid})
        m = re.fullmatch(r'/object/([^/]+)', p)
        if m and self.command == 'DELETE':
            bucket, names = m.group(1), self.jbody().get('prefixes') or []
            # Без RETURNING (см. загрузку): что удалилось — сравниваем до и после
            before = q('select id, name, metadata, created_at from storage.objects where bucket_id = %s and name = any(%s)',
                       (bucket, names))
            q('delete from storage.objects where bucket_id = %s and name = any(%s)', (bucket, names), claims=claims, role=role)
            left = {r['name'] for r in q('select name from storage.objects where bucket_id = %s and name = any(%s)', (bucket, names))}
            rows = [r for r in before if r['name'] not in left]
            for r in rows:
                try:
                    os.remove(os.path.join(STORE, bucket, r['name']))
                except OSError:
                    pass
            return self.send(200, [{'name': r['name'], 'id': str(r['id']), 'bucket_id': bucket, 'metadata': r['metadata'],
                                    'created_at': iso(r['created_at'])} for r in rows])
        return self.err(404, 'storage stub: ' + p)

    # ---------- сессия для проверок
    def test_session(self):
        if self.command != 'POST':
            return self.err(405, 'POST')
        b = self.jbody()
        if b.get('anon'):
            u = q("""insert into auth.users (instance_id, aud, role, is_anonymous, raw_app_meta_data, raw_user_meta_data)
                     values ('00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', true, '{}', '{}')
                     returning id""", one=True)
            return self.send(200, new_session(u['id']))
        phone = re.sub(r'\D', '', b.get('phone') or '70000000001')
        if b.get('admin'):
            return self.send(200, admin_session(phone, b.get('password') or 'test-password-1', b.get('unlock', True)))
        return self.send(200, new_session(ensure_user(phone)))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'keys':
        print('secret=' + SECRET)
        print('anon=' + ANON)
        print('service=' + SERVICE)
    elif cmd == 'serve':
        os.makedirs(STORE, exist_ok=True)
        print(f'gateway: {ORIGIN}', flush=True)
        ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
