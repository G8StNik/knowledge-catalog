import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
import pytest

from kc.ids import uuid7
from kc.migrate import migrate


@pytest.fixture(scope='session')
def database():
    admin_dsn=os.environ.get('KC_TEST_ADMIN_DSN')
    if not admin_dsn:
        pytest.fail('KC_TEST_ADMIN_DSN is required: integration tests must run against real PostgreSQL')
    name='kc_test_'+secrets.token_hex(6)
    with psycopg.connect(admin_dsn,autocommit=True) as admin:
        admin.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
    dsn=make_conninfo(admin_dsn,dbname=name)
    migrate(dsn)
    roles={kind:'kc_test_'+kind+'_'+secrets.token_hex(4) for kind in ('human','ai','app','reader','broker')}
    groups={'human':'kc_human_approver','ai':'kc_ai_agent','app':'kc_application','reader':'kc_readonly','broker':'kc_platform_admin'}
    with psycopg.connect(dsn,autocommit=True) as admin:
        for kind,name_role in roles.items():
            admin.execute(sql.SQL("CREATE ROLE {} LOGIN INHERIT PASSWORD 'kc-test-only'").format(sql.Identifier(name_role)))
            admin.execute(sql.SQL('GRANT {} TO {}').format(sql.Identifier(groups[kind]),sql.Identifier(name_role)))
    yield dsn,roles
    with psycopg.connect(admin_dsn,autocommit=True) as admin:
        # Only remove the isolated database and roles created by this fixture.
        assert name.startswith('kc_test_')
        admin.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(name)))
        for name_role in roles.values():
            admin.execute(sql.SQL('DROP ROLE {}').format(sql.Identifier(name_role)))


@pytest.fixture
def tenant_factory(database):
    dsn,roles=database
    def create():
        tenant,account,human,ai,workspace=[uuid7() for _ in range(5)]
        with psycopg.connect(dsn) as conn:
            conn.execute("INSERT INTO core.organization(organization_id,organization_key,organization_name) VALUES(%s,%s,'Test organization')",(tenant,str(tenant)))
            conn.execute("INSERT INTO identity.account(account_id,display_name) VALUES(%s,'Human')",(account,))
            conn.execute('INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id) VALUES(%s,%s,%s)',(uuid7(),tenant,account))
            conn.execute("INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name) VALUES(%s,%s,%s,'USER','Human')",(human,tenant,account))
            conn.execute("INSERT INTO identity.principal(principal_id,organization_id,principal_type,display_name) VALUES(%s,%s,'AI_AGENT','AI')",(ai,tenant))
            conn.execute("INSERT INTO core.workspace(workspace_id,organization_id,workspace_key,workspace_name) VALUES(%s,%s,'general','General')",(workspace,tenant))
            conn.execute('INSERT INTO security.configuration_permission(configuration_permission_id,organization_id,principal_id,can_approve) VALUES(%s,%s,%s,true)',(uuid7(),tenant,human))
        tickets={}
        for kind in ('human','ai','app','reader'):
            token=secrets.token_urlsafe(48)
            with psycopg.connect(dsn) as admin:
                admin.execute('SELECT security.issue_ticket(%s,%s,%s,%s,%s)',(hashlib.sha256(token.encode()).digest(),tenant,ai if kind=='ai' else human,roles[kind],datetime.now(timezone.utc)+timedelta(minutes=10)))
            tickets[kind]=token
        return dict(id=tenant,account=account,human=human,ai=ai,workspace=workspace,tickets=tickets)
    return create


@pytest.fixture
def connect(database):
    dsn,roles=database
    opened=[]
    def runtime(tenant,kind='human',context=True):
        conn=psycopg.connect(make_conninfo(dsn,user=roles[kind],password='kc-test-only'))
        opened.append(conn)
        if context: conn.execute('SELECT security.begin_context(%s)',(tenant['tickets'][kind],))
        return conn
    yield runtime
    for conn in opened: conn.close()


@pytest.fixture
def tenant(tenant_factory): return tenant_factory()
