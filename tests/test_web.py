"""Exercise the real HTTP boundary and database policies together."""
import json
import threading
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

import pytest
from psycopg.conninfo import make_conninfo
from kc.web import WorkspaceServer
from test_sop_workflow import sop  # Reuse the independently provisioned human identities.


@pytest.fixture
def web(sop, database):
    sop['editor'].commit()
    sop['reviewer'].commit()
    server = WorkspaceServer(('127.0.0.1', 0), make_conninfo(database[0], user=database[1]['human'], password='kc-test-only'))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    def client(ticket=None):
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
        def request(path, payload=None, origin=True):
            headers = {'Content-Type': 'application/json'}
            if origin:
                headers['Origin'] = server.origin
            req = urllib.request.Request(server.origin + path, data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
            try:
                response = opener.open(req)
            except urllib.error.HTTPError as error:
                response = error
            raw = response.read()
            return response.status, json.loads(raw) if 'application/json' in response.headers['Content-Type'] else raw
        if ticket:
            assert request('/api/login', {'ticket': ticket})[0] == 200
        return request
    yield sop, server, client
    server.shutdown()
    server.server_close()
    worker.join()


def test_web_full_sop_history(web):
    s, server, client = web
    author = client(s['tenant']['tickets']['human'])
    reviewer = client(s['reviewer_ticket'])
    status, state = author('/api/workspace')
    assert status == 200 and state['actor']['display_name'] == 'Human'
    assert len(state['evidence']) == 1
    payload = dict(workspace_id=str(s['tenant']['workspace']), configuration_revision_id=str(s['revision']),
                   knowledge_type_id=str(s['typ']), domain_id=str(s['domain']), knowledge_key='WEB-001',
                   title='A browser SOP', content='Verify and record approval.', metadata={'review_date': '2027-09-17'})
    status, result = author('/api/action/create', payload)
    assert status == 200, result
    version = result['version_id']
    def action(client, action, **kwargs):
        return client('/api/action/' + action, dict(version_id=version, **kwargs))
    assert action(author, 'attach', artifact_version_id=str(s['evidence']), locator='Procedure')[0] == 200
    for role, person in [('owner', s['tenant']['human']), ('approver', s['reviewer_id'])]:
        assert action(author, 'assign', role_id=str(s['roles'][role]), principal_id=str(person))[0] == 200
    assert action(author, 'submit')[0] == 200
    assert action(author, 'review', note='Self approval')[0] == 409
    assert action(reviewer, 'review', note='Checked the evidence')[0] == 200
    assert action(reviewer, 'publish')[0] == 200
    old = author('/api/workspace')[1]['versions'][0]
    assert old['status'] == 'PUBLISHED'
    assert action(author, 'edit', content='Overwrite publication')[0] == 409
    status, revised = action(author, 'revise')
    assert status == 200
    assert author('/api/action/edit', dict(version_id=revised['version_id'], content='Revised procedure'))[0] == 200
    state = author('/api/workspace')[1]
    assert next(v for v in state['versions'] if v['knowledge_version_id'] == version) == old
    assert len(state['reviews']) == 1


def test_web_auth_origin_logout_and_static(web):
    s, server, client = web
    anonymous = client()
    assert anonymous('/api/workspace')[0] == 401
    assert anonymous('/api/login', {'ticket': s['tenant']['tickets']['human']}, origin=False)[0] == 403
    assert anonymous('/api/login', {'ticket': 'invalid-ticket-but-long-enough'})[0] == 401
    assert anonymous('/')[0] == 200
    assert b'Create SOP' in anonymous('/')[1]
    assert anonymous('/../../pyproject.toml')[0] == 401
    author = client(s['tenant']['tickets']['human'])
    assert author('/api/action/create', {}, origin=False)[0] == 403
    assert author('/api/logout', {})[0] == 200
    assert author('/api/workspace')[0] == 401


def test_web_revoked_source_disappears(web, database):
    import psycopg
    s, server, client = web
    author = client(s['tenant']['tickets']['human'])
    assert author('/api/workspace')[1]['evidence']
    with psycopg.connect(database[0]) as admin:
        admin.execute('UPDATE security.source_acl SET is_allowed=false WHERE organization_id=%s AND principal_id=%s', (s['tenant']['id'], s['tenant']['human']))
    assert author('/api/workspace')[1]['evidence'] == []



def test_browser_workflow(web):
    import os
    import subprocess
    from pathlib import Path
    node = os.environ.get('KC_BROWSER_NODE')
    if not node:
        pytest.skip('Set KC_BROWSER_NODE and NODE_PATH to run the optional Edge browser test')
    s, server, client = web
    result = subprocess.run([node, str(Path(__file__).with_name('browser_smoke.cjs'))], input=json.dumps({
        'origin': server.origin, 'author': s['tenant']['tickets']['human'], 'reviewer': s['reviewer_ticket']}),
        text=True, capture_output=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
