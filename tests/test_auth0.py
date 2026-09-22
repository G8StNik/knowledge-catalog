"""No live Auth0 account needed: sign real RSA tokens and test the trust boundary."""
import hashlib
import secrets
import time
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import jwt
import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from kc.auth0 import Auth0, Auth0Settings
from kc.ids import uuid7
from kc.session import tenant_transaction


@pytest.fixture
def auth():
    adapter = Auth0(Auth0Settings('example.auth0.com', 'test-client', 'test-secret', 'unused'), 'http://127.0.0.1:8080', 'runtime')
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    adapter.keys = SimpleNamespace(get_signing_key_from_jwt=lambda _: SimpleNamespace(key=key.public_key()))
    def sign(**changes):
        now = int(time.time())
        claims = dict(iss=adapter.settings.issuer, sub='auth0|test-user', aud='test-client',
                      exp=now+600, iat=now, auth_time=now, nonce='test-nonce', amr=['pwd','mfa'])
        claims.update(changes)
        return jwt.encode(claims, key, algorithm='RS256', headers={'kid':'test-key'})
    return adapter, sign


def test_valid_mfa_token(auth):
    adapter, sign = auth
    assert adapter.verify(sign(), 'test-nonce')['sub'] == 'auth0|test-user'


@pytest.mark.parametrize('changes', [
    {'iss':'https://attacker.example/'}, {'aud':'another-app'}, {'aud':['test-client','other']},
    {'exp':1}, {'iat':9999999999}, {'auth_time':1}, {'nonce':'wrong'}, {'azp':'another-app'},
    {'sub':''}, {'amr':['pwd']}, {'amr':'mfa'}, {'amr':None},
])
def test_invalid_claims_fail_closed(auth, changes):
    adapter, sign = auth
    with pytest.raises((ValueError, PermissionError, jwt.PyJWTError)):
        adapter.verify(sign(**changes), 'test-nonce')


def test_wrong_signature_and_algorithm_rejected(auth):
    adapter, sign = auth
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    claims = jwt.decode(sign(), options={'verify_signature':False})
    for token in (jwt.encode(claims, other, algorithm='RS256'), jwt.encode(claims, 'untrusted-test-key-at-least-32-bytes', algorithm='HS256')):
        with pytest.raises(jwt.PyJWTError):
            adapter.verify(token, 'test-nonce')


def test_login_has_pkce_nonce_mfa_and_browser_binding(auth):
    adapter, _ = auth
    url, cookie = adapter.begin('company-one')
    params = parse_qs(urlsplit(url).query)
    assert params['code_challenge_method'] == ['S256']
    assert params['scope'] == ['openid profile email']
    assert params['acr_values'] and params['nonce'] and params['code_challenge']
    state = params['state'][0]
    with pytest.raises(PermissionError): adapter.finish(state, 'different-browser', 'code')
    assert state in adapter.pending
    adapter.pending[state]['expires'] = 0
    with pytest.raises(PermissionError): adapter.finish(state, cookie, 'code')


@pytest.fixture
def broker(database):
    role = 'kc_test_auth_' + secrets.token_hex(4)
    with psycopg.connect(database[0], autocommit=True) as conn:
        conn.execute(sql.SQL("CREATE ROLE {} LOGIN INHERIT PASSWORD 'test-only'").format(sql.Identifier(role)))
        conn.execute(sql.SQL('GRANT kc_auth_broker TO {}').format(sql.Identifier(role)))
    yield make_conninfo(database[0], user=role, password='test-only')
    with psycopg.connect(database[0], autocommit=True) as conn:
        conn.execute(sql.SQL('DROP ROLE {}').format(sql.Identifier(role)))


def link(database, tenant, subject='auth0|test-user'):
    with psycopg.connect(database[0]) as conn:
        conn.execute('INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_tenant_id,provider_object_id) VALUES(%s,%s,%s,%s,%s,%s)',
                     (uuid7(),tenant['id'],tenant['human'],'oidc','https://example.auth0.com/',subject))


def test_broker_only_issues_mapped_active_humans(database, tenant, tenant_factory, broker):
    link(database, tenant)
    other = tenant_factory()
    token = secrets.token_urlsafe(48)
    digest = hashlib.sha256(token.encode()).digest()
    def issue(conn, org, subject='auth0|test-user', audience=None):
        conn.execute('SELECT security.issue_identity_ticket(%s,%s,%s,%s,%s,%s,%s)',
                     (digest,str(org),'https://example.auth0.com/',subject,audience or database[1]['human'],datetime.now(timezone.utc)+timedelta(minutes=5),uuid7()))
    with psycopg.connect(broker) as conn:
        issue(conn,tenant['id'])
    with psycopg.connect(make_conninfo(database[0],user=database[1]['human'],password='kc-test-only')) as conn:
        with tenant_transaction(conn,token):
            assert conn.execute('SELECT security.current_principal()').fetchone()[0] == tenant['human']
        with pytest.raises(psycopg.errors.InsufficientPrivilege): issue(conn,tenant['id'])
    for org,subject,audience in [(other['id'],'auth0|test-user',None),(tenant['id'],'someone-else',None),(tenant['id'],'auth0|test-user',database[1]['broker'])]:
        with psycopg.connect(broker) as conn:
            with pytest.raises(psycopg.errors.InsufficientPrivilege): issue(conn,org,subject,audience)
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): conn.execute('SELECT * FROM identity.account')
    with psycopg.connect(broker) as conn:
        conn.execute('SELECT security.revoke_identity_ticket(%s)',(digest,))
    with psycopg.connect(make_conninfo(database[0],user=database[1]['human'],password='kc-test-only')) as conn:
        with pytest.raises(psycopg.errors.InvalidAuthorizationSpecification):
            with tenant_transaction(conn,token): pass
    with psycopg.connect(database[0]) as conn:
        conn.execute("UPDATE identity.organization_membership SET status='SUSPENDED' WHERE organization_id=%s",(tenant['id'],))
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): issue(conn,tenant['id'])


def test_complete_callback_issues_ticket_once(auth, database, tenant, broker):
    adapter, sign = auth
    link(database, tenant)
    adapter.settings = Auth0Settings('example.auth0.com','test-client','test-secret',broker)
    adapter.audience = database[1]['human']
    url, cookie = adapter.begin(str(tenant['id']))
    state = parse_qs(urlsplit(url).query)['state'][0]
    nonce = adapter.pending[state]['nonce']
    adapter.exchange = lambda code, verifier: sign(nonce=nonce)
    ticket, seconds = adapter.finish(state,cookie,'one-time-code')
    assert seconds <= 600
    with psycopg.connect(make_conninfo(database[0],user=database[1]['human'],password='kc-test-only')) as conn:
        with tenant_transaction(conn,ticket):
            assert conn.execute('SELECT security.current_organization()').fetchone()[0] == tenant['id']
    with pytest.raises(PermissionError): adapter.finish(state,cookie,'one-time-code')


def test_verified_email_and_invitation_code_create_membership(auth, database, tenant, connect, broker):
    adapter, sign = auth
    with psycopg.connect(database[0]) as conn:
        conn.execute('INSERT INTO security.organization_admin VALUES(%s,%s)', (tenant['id'], tenant['human']))
    admin = connect(tenant)
    code = secrets.token_urlsafe(48)
    admin.execute('SELECT identity.create_invitation(%s,%s,%s,%s,%s,%s,%s,%s)',
                  (uuid7(),hashlib.sha256(code.encode()).digest(),'new@example.test',tenant['workspace'],
                   False,True,datetime.now(timezone.utc)+timedelta(days=1),uuid7()))
    admin.commit()
    adapter.settings = Auth0Settings('example.auth0.com','test-client','test-secret',broker)
    adapter.audience = database[1]['human']
    url, cookie = adapter.begin(str(tenant['id']), code)
    state = parse_qs(urlsplit(url).query)['state'][0]
    nonce = adapter.pending[state]['nonce']
    adapter.exchange = lambda *_: sign(nonce=nonce, sub='auth0|invited', email='new@example.test', email_verified=False)
    with pytest.raises(PermissionError): adapter.finish(state,cookie,'code')
    url, cookie = adapter.begin(str(tenant['id']), code)
    state = parse_qs(urlsplit(url).query)['state'][0]
    nonce = adapter.pending[state]['nonce']
    adapter.exchange = lambda *_: sign(nonce=nonce, sub='auth0|invited', email='new@example.test',
                                       email_verified=True, name='Invited Reviewer')
    ticket, _ = adapter.finish(state,cookie,'code')
    with psycopg.connect(make_conninfo(database[0],user=database[1]['human'],password='kc-test-only')) as conn:
        with tenant_transaction(conn,ticket):
            principal=conn.execute('SELECT security.current_principal()').fetchone()[0]
            assert principal != tenant['human']
            assert conn.execute('SELECT security.has_workspace_access(%s,\'review\')',(tenant['workspace'],)).fetchone()[0]
    with psycopg.connect(database[0]) as conn:
        assert conn.execute('SELECT status FROM identity.invitation WHERE token_hash=%s',
                            (hashlib.sha256(code.encode()).digest(),)).fetchone()[0] == 'ACCEPTED'


def test_http_auth0_callback_cookie_logout_and_no_ticket_bypass(auth, database, tenant, broker):
    import json
    import threading
    import urllib.request
    import urllib.error
    from kc.auth0 import NoRedirect
    from kc.web import WorkspaceServer
    adapter, sign = auth
    link(database, tenant)
    server = WorkspaceServer(('127.0.0.1',0), make_conninfo(database[0],user=database[1]['human'],password='kc-test-only'),
        auth0_settings=Auth0Settings('example.auth0.com','test-client','test-secret',broker))
    server.auth.keys = adapter.keys
    def exchange(code, verifier):
        # nonce is captured before the single-use flow is consumed by finish().
        return sign(nonce=expected_nonce)
    server.auth.exchange = exchange
    worker = threading.Thread(target=server.serve_forever,daemon=True)
    worker.start()
    opener = urllib.request.build_opener(NoRedirect)
    def request(path, payload=None, cookie=None):
        headers={'Origin':server.origin,'Content-Type':'application/json'}
        if cookie: headers['Cookie']=cookie
        req = urllib.request.Request(server.origin+path, data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
        try: response = opener.open(req)
        except urllib.error.HTTPError as e: response=e
        raw=response.read()
        return response.status,response.headers,json.loads(raw)
    try:
        assert request('/api/auth/config')[2] == {'mode':'auth0'}
        assert request('/api/login',{'ticket':tenant['tickets']['human']})[0] == 401
        status, headers, result = request('/api/auth/start',{'organization':str(tenant['id'])})
        assert status == 200
        transaction_cookie = headers['Set-Cookie'].split(';')[0]
        assert 'HttpOnly' in headers['Set-Cookie'] and 'SameSite=Lax' in headers['Set-Cookie']
        state = parse_qs(urlsplit(result['url']).query)['state'][0]
        expected_nonce = server.auth.pending[state]['nonce']
        assert request('/auth/callback?code=code&state='+state)[1]['Location'] == '/?signin=failed'
        status, headers, _ = request('/auth/callback?code=code&state='+state,cookie=transaction_cookie)
        assert status == 303 and headers['Location'] == '/'
        cookies = headers.get_all('Set-Cookie')
        session_cookie = next(c for c in cookies if c.startswith('kc_session='))
        assert 'HttpOnly' in session_cookie and 'SameSite=Strict' in session_cookie
        session_cookie = session_cookie.split(';')[0]
        assert request('/api/workspace',cookie=session_cookie)[0] == 200
        assert request('/auth/callback?code=code&state='+state,cookie=transaction_cookie)[1]['Location'] == '/?signin=failed'
        status, headers, result = request('/api/logout',{},session_cookie)
        assert status == 200 and result['url'].startswith('https://example.auth0.com/v2/logout?')
        assert request('/api/workspace',cookie=session_cookie)[0] == 401
        with psycopg.connect(database[0]) as conn:
            assert conn.execute("SELECT count(*) FROM audit.event WHERE organization_id=%s AND action='USER_SIGN_IN'",(tenant['id'],)).fetchone()[0] == 1
    finally:
        server.shutdown(); server.server_close(); worker.join()


def test_auth_mode_never_silently_falls_back():
    from kc.web import WorkspaceServer
    with pytest.raises(ValueError): WorkspaceServer(('127.0.0.1',0),'unused')
    with pytest.raises(ValueError): WorkspaceServer(('127.0.0.1',0),'unused',
        auth0_settings=Auth0Settings('example.auth0.com','test-client','test-secret','unused'),dev_ticket_login=True)



def test_auth0_browser_signin(database, broker):
    import json
    import os
    import subprocess
    import threading
    from pathlib import Path
    from kc.web import WorkspaceServer
    node = os.environ.get('KC_BROWSER_NODE')
    if not node:
        pytest.skip('Set KC_BROWSER_NODE and NODE_PATH for the optional Edge test')
    server = WorkspaceServer(('127.0.0.1',0),make_conninfo(database[0],user=database[1]['human'],password='kc-test-only'),
        auth0_settings=Auth0Settings('example.auth0.com','test-client','test-secret',broker))
    worker = threading.Thread(target=server.serve_forever,daemon=True)
    worker.start()
    try:
        result = subprocess.run([node,str(Path(__file__).with_name('auth0_browser.cjs'))],
            input=json.dumps({'origin':server.origin}),text=True,capture_output=True,timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
    finally:
        server.shutdown(); server.server_close(); worker.join()
