import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import psycopg
from psycopg.conninfo import make_conninfo
import pytest

from kc.ids import uuid7
from kc.session import tenant_transaction
from test_auth0 import broker


@pytest.fixture
def administrator(database, tenant, connect):
    with psycopg.connect(database[0]) as conn:
        conn.execute('INSERT INTO security.organization_admin VALUES(%s,%s)', (tenant['id'], tenant['human']))
    return connect(tenant)


def create_invitation(conn, tenant, email='person@example.test'):
    code = secrets.token_urlsafe(48)
    conn.execute('SELECT identity.create_invitation(%s,%s,%s,%s,%s,%s,%s,%s)',
        (uuid7(), hashlib.sha256(code.encode()).digest(), email, tenant['workspace'], True, False,
         datetime.now(timezone.utc) + timedelta(days=1), uuid7()))
    return code


def accept(conn, database, tenant, code, email='person@example.test'):
    ticket = secrets.token_urlsafe(48)
    principal = uuid7()
    conn.execute('SELECT security.accept_identity_invitation(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)',
        (hashlib.sha256(code.encode()).digest(), str(tenant['id']), 'https://example.auth0.com/',
         'auth0|new-person', email, 'New person', database[1]['human'],
         datetime.now(timezone.utc) + timedelta(minutes=5), hashlib.sha256(ticket.encode()).digest(),
         uuid7(), uuid7(), principal, uuid7(), uuid7()))
    return principal, ticket


def test_invitation_is_single_use_and_creates_tenant_access(administrator, database, tenant, tenant_factory, broker):
    code = create_invitation(administrator, tenant)
    administrator.commit()
    other_tenant = tenant_factory()
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with conn.transaction(): accept(conn, database, other_tenant, code)
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with conn.transaction(): accept(conn, database, tenant, code, 'other@example.test')
        principal, ticket = accept(conn, database, tenant, code)
    with psycopg.connect(make_conninfo(database[0], user=database[1]['human'], password='kc-test-only')) as runtime:
        with tenant_transaction(runtime, ticket):
            assert runtime.execute('SELECT security.current_principal()').fetchone()[0] == principal
            assert runtime.execute('SELECT security.has_workspace_access(%s,\'edit\')', (tenant['workspace'],)).fetchone()[0]
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): accept(conn, database, tenant, code)
    administrator.execute('SELECT security.begin_context(%s)', (tenant['tickets']['human'],))
    assert administrator.execute('SELECT status FROM identity.list_invitations()').fetchone()[0] == 'ACCEPTED'


def test_only_admin_can_invite_and_revoked_code_cannot_be_used(administrator, database, tenant, tenant_factory, connect, broker):
    code = create_invitation(administrator, tenant)
    invitation = administrator.execute('SELECT invitation_id FROM identity.list_invitations()').fetchone()[0]
    administrator.execute('SELECT identity.revoke_invitation(%s,%s)', (invitation, uuid7()))
    administrator.commit()
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): accept(conn, database, tenant, code)
    other = connect(tenant_factory())
    with pytest.raises(psycopg.errors.InsufficientPrivilege): other.execute('SELECT * FROM identity.list_invitations()')


def test_organization_onboard_cli_creates_verified_first_admin(database, monkeypatch, capsys):
    from kc.identity_cli import main
    code = 'newco_' + secrets.token_hex(4)
    monkeypatch.setenv('KC_PROVISIONING_DSN', database[0])
    monkeypatch.setenv('KC_AUTH0_DOMAIN', 'example.auth0.com')
    monkeypatch.setattr('sys.argv', ['identity_cli', 'onboard', '--organization', code,
        '--name', 'New Company', '--admin-name', 'Founding Admin', '--admin-email', code+'@example.test',
        '--admin-subject', 'auth0|founder'])
    main()
    assert 'Created organization' in capsys.readouterr().out
    with psycopg.connect(database[0]) as conn:
        row = conn.execute('''SELECT o.organization_name,w.workspace_name,p.display_name,e.provider_object_id
            FROM core.organization o JOIN core.workspace w USING(organization_id)
            JOIN identity.principal p USING(organization_id)
            JOIN identity.external_identity e USING(organization_id,principal_id)
            JOIN security.organization_admin a USING(organization_id,principal_id)
            WHERE o.organization_key=%s''', (code,)).fetchone()
        assert row == ('New Company', 'General', 'Founding Admin', 'auth0|founder')


def test_expired_invitation_cannot_create_membership(administrator, database, tenant, broker):
    code = create_invitation(administrator, tenant)
    administrator.commit()
    with psycopg.connect(database[0]) as admin:
        admin.execute('UPDATE identity.invitation SET expires_at=now()-interval \'1 minute\' WHERE token_hash=%s',
                      (hashlib.sha256(code.encode()).digest(),))
    with psycopg.connect(broker) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): accept(conn, database, tenant, code)
