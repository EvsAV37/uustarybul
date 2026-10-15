#!/usr/bin/env python3
"""Проверка «Предложить идею» (миграция 027) на локальной копии: python3 server/test/ideas_test.py"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke import call, check, FAILS  # noqa: E402
from gateway import q  # noqa: E402


def qv(sql):
    r = q(sql)
    return list(r[0].values())[0] if r else None


def rpc(name, body, tok):
    return call('POST', '/rest/v1/rpc/' + name, body, tok)


def main():
    q('delete from public.ideas')
    q("delete from public.notifications where kind = 'idea_reply'")
    _, g = call('POST', '/auth/v1/signup', {'data': {}})
    _, u = call('POST', '/__test/session', {'phone': '70000000002'})
    _, a = call('POST', '/__test/session', {'phone': '70000000003', 'admin': True})
    gt, ut, at = g['access_token'], u['access_token'], a['access_token']
    city = call('GET', '/rest/v1/cities?select=id&limit=1')[1][0]['id']

    print('Отправка')
    st, r = rpc('idea_send', {'p_kind': 'idea', 'p_body': 'Хочу фильтр по цене'}, None)
    check('аноним — отказ', st >= 400, r)
    st, r = rpc('idea_send', {'p_kind': 'idea', 'p_body': 'Хочу фильтр по цене'}, gt)
    check('гость — отказ', st >= 400 and 'registration_required' in json.dumps(r), r)
    st, r = rpc('idea_send', {'p_kind': 'idea', 'p_body': 'ой'}, ut)
    check('короткий текст — отказ', 'idea_short' in json.dumps(r), r)
    st, r = rpc('idea_send', {'p_kind': 'idea', 'p_body': 'x' * 1001}, ut)
    check('длинный текст — отказ', 'idea_long' in json.dumps(r), r)
    st, r = rpc('idea_send', {'p_kind': 'spam', 'p_body': 'Хочу фильтр по цене'}, ut)
    check('неверный тип — отказ', 'idea_kind' in json.dumps(r), r)
    ids = []
    for i, k in enumerate(['idea', 'inconvenient', 'broken']):
        st, r = rpc('idea_send', {'p_kind': k, 'p_body': f'Сообщение номер {i + 1}', 'p_city': city,
                                  'p_device': 'iPhone · Safari<script>', 'p_version': '0.1'}, ut)
        check(f'отправка {i + 1}', st == 200 and r.get('id') and r.get('left') == 2 - i, r)
        ids.append(r.get('id'))
    st, r = rpc('idea_send', {'p_kind': 'idea', 'p_body': 'Четвёртое за сутки'}, ut)
    check('четвёртое за сутки — отказ', 'idea_limit' in json.dumps(r), r)
    row = q(f"select role, city_id, device, app_version from public.ideas where id = {ids[0]}")[0]
    check('прикреплено: заказчик, город, устройство без лишних знаков, версия',
          row == {'role': 'customer', 'city_id': city, 'device': 'iPhone · Safariscript', 'app_version': '0.1'}, row)
    st, r = call('GET', '/rest/v1/ideas?select=*', None, ut)
    check('таблица клиенту закрыта', st >= 400 or r == [], r)
    st, mine = rpc('idea_list_mine', {}, ut)
    check('мои предложения — 3, новое сверху', st == 200 and len(mine) == 3 and mine[0]['id'] == ids[2], mine)
    st, other = rpc('idea_list_mine', {}, at)
    check('чужие не видны', st == 200 and other == [], other)

    print('Управление')
    st, r = rpc('admin_ideas', {'p_tab': 'new'}, ut)
    check('не администратору — отказ', st >= 400, r)
    st, b = rpc('admin_badges', {}, at)
    check('значок: 3 новых', st == 200 and b.get('ideas_new') == 3, b)
    st, l = rpc('admin_ideas', {'p_tab': 'new'}, at)
    check('список новых', st == 200 and len(l['items']) == 3 and l['counts'].get('new') == 3, l)
    check('в списке нет номера', '7000000000' not in json.dumps(l), '')
    n0 = qv("select count(*) from public.notifications where kind = 'idea_reply'")
    st, r = rpc('admin_idea_set', {'p_id': ids[0], 'p_status': 'read'}, at)
    check('прочитано — без push', st == 200 and r['push'] is False, r)
    st, r = rpc('admin_idea_set', {'p_id': ids[0], 'p_status': 'read', 'p_reply': 'Спасибо, подумаем'}, at)
    check('ответ — push', st == 200 and r['push'] is True, r)
    st, r = rpc('admin_idea_set', {'p_id': ids[0], 'p_status': 'read', 'p_reply': 'Спасибо, подумаем'}, at)
    check('тот же ответ ещё раз — без push', st == 200 and r['push'] is False, r)
    st, r = rpc('admin_idea_set', {'p_id': ids[1], 'p_status': 'done'}, at)
    check('сделано — push', st == 200 and r['push'] is True, r)
    n1 = qv("select count(*) from public.notifications where kind = 'idea_reply'")
    check('в очереди 2 уведомления', n1 - n0 == 2, n1 - n0)
    st, r = rpc('admin_idea_set', {'p_id': ids[1], 'p_status': 'oops'}, at)
    check('неверный статус — отказ', 'idea_status' in json.dumps(r), r)
    st, mine = rpc('idea_list_mine', {}, ut)
    m = {x['id']: x for x in mine}
    check('автор видит ответ и «сделано»', m[ids[0]]['reply'] == 'Спасибо, подумаем' and m[ids[1]]['status'] == 'done', mine)
    st, r = rpc('admin_idea_to_pd', {'p_id': ids[2], 'p_kind': 'delete'}, at)
    check('сделать запросом по ПДн', st == 200 and r.get('id'), r)
    pd = q(f"select kind, channel, user_id is not null as has_user from public.pd_requests where id = {r.get('id', 0)}")[0]
    check('запрос ПДн: удалить, в приложении, аккаунт привязан', pd == {'kind': 'delete', 'channel': 'app', 'has_user': True}, pd)
    st, r = rpc('admin_idea_to_pd', {'p_id': ids[2], 'p_kind': 'delete'}, at)
    check('второй раз — отказ', 'idea_already_pd' in json.dumps(r), r)
    st, b = rpc('admin_badges', {}, at)
    check('значок: новых 0', b.get('ideas_new') == 0, b)
    st, r = rpc('admin_idea_delete', {'p_id': ids[0]}, at)
    check('удалить', st == 200 and r.get('ok'), r)
    st, l = rpc('admin_ideas', {'p_tab': 'all'}, at)
    check('осталось 2', len(l['items']) == 2, l)
    log = qv("select count(*) from public.admin_log where action in ('idea_set','idea_delete','pd_create')")
    check('журнал действий', log >= 4, log)

    print('Чистка')
    q(f"update public.ideas set created_at = now() - interval '13 months' where id = {ids[1]}")
    q('select public.ops_cleanup()')
    left = qv('select count(*) from public.ideas')
    check('старше года удалено', left == 1, left)
    q('delete from public.ideas')
    print('ИТОГ:', 'OK' if not FAILS else 'ОШИБКИ: ' + ', '.join(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
