import hashlib
import json
from pathlib import Path
from datetime import datetime, timedelta, timezone
import secrets

import psycopg
from psycopg import sql
import pytest

from kc.configuration import import_package, export_package, package_schema
from kc.ids import uuid7
from kc.session import tenant_transaction

ROOT=Path(__file__).resolve().parents[1]


def test_starter_import_and_published_schema(tenant,connect):
    starter=json.loads((ROOT/'database/seeds/general-business.json').read_text())
    conn=connect(tenant); revision=import_package(conn,starter)
    exported=export_package(conn,revision)
    assert len(exported['entities']['governance.authority_level'])==6
    assert len(exported['entities']['catalog.knowledge_type'])==9
    assert json.loads((ROOT/'database/schemas/configuration-package.schema.json').read_text())==package_schema()
    conn.execute('SELECT governance.approve_and_activate(%s,%s,%s,%s)',
                 (revision,uuid7(),uuid7(),datetime.now(timezone.utc)+timedelta(minutes=1)))
    assert conn.execute('SELECT approved_digest IS NOT NULL FROM governance.configuration_revision WHERE configuration_revision_id=%s',(revision,)).fetchone()[0]


def test_transaction_helper_clears_context_after_error(tenant,connect):
    conn=connect(tenant,context=False)
    with pytest.raises(RuntimeError):
        with tenant_transaction(conn,tenant['tickets']['human']):
            assert conn.execute('SELECT security.current_organization()').fetchone()[0]==tenant['id']
            raise RuntimeError('Request failed')
    assert conn.execute('SELECT security.current_organization()').fetchone()[0] is None
    with pytest.raises(ValueError,match='idle'):
        with tenant_transaction(conn,tenant['tickets']['human']): pass


def test_draft_changes_require_distinct_audit_events(tenant,connect):
    conn=connect(tenant)
    package={'format_version':1,'package_key':'audit_test','version':1,'entities':{
        'catalog.domain':[{'key':'root','display_name':'Root'}]}}
    revision=import_package(conn,package)
    with pytest.raises(psycopg.errors.CheckViolation,match='event ID'):
        with conn.transaction():
            conn.execute("UPDATE catalog.domain SET display_name='Unaudited' WHERE configuration_revision_id=%s",(revision,))
    event=uuid7()
    conn.execute("SELECT set_config('kc.change_event_id',%s,true)",(str(event),))
    conn.execute("UPDATE catalog.domain SET display_name='Reviewed draft' WHERE configuration_revision_id=%s",(revision,))
    before,after=conn.execute('SELECT before_state,after_state FROM audit.event WHERE audit_event_id=%s',(event,)).fetchone()
    assert before['display_name']=='Root' and after['display_name']=='Reviewed draft'
    assert conn.execute("SELECT current_setting('kc.change_event_id')").fetchone()[0]==''


def test_ticket_expiry_and_ai_approval_audience_rejection(database,tenant,connect):
    token=secrets.token_urlsafe(48)
    with psycopg.connect(database[0]) as admin:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with admin.transaction():
                admin.execute('SELECT security.issue_ticket(%s,%s,%s,%s,%s)',
                    (hashlib.sha256(token.encode()).digest(),tenant['id'],tenant['ai'],database[1]['human'],datetime.now(timezone.utc)+timedelta(minutes=5)))
        admin.execute('UPDATE security.session_ticket SET expires_at=now()-interval \'1 minute\' WHERE token_hash=%s',
            (hashlib.sha256(tenant['tickets']['human'].encode()).digest(),))
    conn=connect(tenant,context=False)
    with pytest.raises(psycopg.errors.InvalidAuthorizationSpecification):
        conn.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))


def test_development_seed_is_repeatable_and_draft_only(database,monkeypatch,capsys):
    from kc import dev_seed
    role='kc_test_seed_'+secrets.token_hex(6)
    monkeypatch.setattr(dev_seed,'REVIEWER_ROLE',role)
    monkeypatch.setenv('KC_DEV_MODE','1')
    monkeypatch.setenv('KC_MIGRATION_DSN',database[0])
    monkeypatch.setenv('KC_DEV_REVIEWER_PASSWORD','kc-test-only')
    try:
        dev_seed.main(); dev_seed.main()
        output=capsys.readouterr().out
        assert 'already exists; preserved' in output
        with psycopg.connect(database[0]) as admin:
            assert admin.execute("SELECT count(*) FROM core.organization WHERE organization_key IN ('demo_a','demo_b')").fetchone()[0]==2
            assert admin.execute("SELECT count(*) FROM governance.configuration_revision r JOIN core.organization o USING(organization_id) WHERE o.organization_key IN ('demo_a','demo_b') AND r.status='DRAFT'").fetchone()[0]==2
            assert admin.execute('SELECT count(*) FROM security.session_ticket WHERE database_role=%s',(role,)).fetchone()[0]==0
    finally:
        with psycopg.connect(database[0],autocommit=True) as admin:
            admin.execute(sql.SQL('DROP ROLE IF EXISTS {}').format(sql.Identifier(role)))
