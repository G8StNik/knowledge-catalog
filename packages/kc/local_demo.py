"""Disposable, loopback-only human pilot without an external identity provider."""
import hashlib
import json
import os
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from kc.configuration import import_package
from kc.ids import uuid7
from kc.session import tenant_transaction
from kc.web import WorkspaceServer


ROLE = 'kc_local_demo_web'
KEY = 'local_demo'


def _ticket(admin, tenant, principal):
    code = secrets.token_urlsafe(32)
    admin.execute('SELECT security.issue_ticket(%s,%s,%s,%s,%s)',
                  (hashlib.sha256(code.encode()).digest(), tenant, principal, ROLE,
                   datetime.now(timezone.utc) + timedelta(minutes=15)))
    return code


def prepare(admin_dsn, runtime_password):
    if os.environ.get('KC_DEV_MODE') != '1':
        raise ValueError('KC_DEV_MODE=1 is required for a disposable local demo')
    if conninfo_to_dict(admin_dsn).get('host') not in ('127.0.0.1', 'localhost'):
        raise ValueError('The demo database must be on this computer')
    with psycopg.connect(admin_dsn) as admin:
        role = admin.execute('SELECT rolsuper,rolbypassrls,rolcreaterole FROM pg_roles WHERE rolname=%s',
                             (ROLE,)).fetchone()
        if role is None:
            admin.execute(sql.SQL('CREATE ROLE {} LOGIN INHERIT PASSWORD {}').format(
                sql.Identifier(ROLE), sql.Literal(runtime_password)))
        elif any(role):
            raise ValueError('Refusing a privileged demo runtime role')
        else:
            admin.execute(sql.SQL('ALTER ROLE {} PASSWORD {}').format(
                sql.Identifier(ROLE), sql.Literal(runtime_password)))
        admin.execute(sql.SQL('GRANT kc_human_approver TO {}').format(sql.Identifier(ROLE)))
    with psycopg.connect(admin_dsn) as admin:
        existing = admin.execute('SELECT organization_id FROM core.organization WHERE organization_key=%s',
                                 (KEY,)).fetchone()
        if existing:
            tenant = existing[0]
            workspace = admin.execute('SELECT workspace_id FROM core.workspace WHERE organization_id=%s AND workspace_key=%s',
                                      (tenant, 'general')).fetchone()[0]
            people = dict(admin.execute('SELECT display_name,principal_id FROM identity.principal WHERE organization_id=%s AND principal_type=%s',
                                        (tenant, 'USER')))
            author, reviewer = people['Demo Author'], people['Demo Reviewer']
        else:
            tenant, workspace = uuid7(), uuid7()
            admin.execute("INSERT INTO core.organization(organization_id,organization_key,organization_name) VALUES(%s,%s,'Local Demo')",
                          (tenant, KEY))
            admin.execute("INSERT INTO core.workspace(workspace_id,organization_id,workspace_key,workspace_name) VALUES(%s,%s,'general','General')",
                          (workspace, tenant))
            people = []
            for label, email in (('Demo Author', 'demo.author@example.invalid'),
                                 ('Demo Reviewer', 'demo.reviewer@example.invalid')):
                account, principal = uuid7(), uuid7()
                admin.execute('INSERT INTO identity.account(account_id,display_name,primary_email) VALUES(%s,%s,%s)',
                              (account, label, email))
                admin.execute('INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id) VALUES(%s,%s,%s)',
                              (uuid7(), tenant, account))
                admin.execute("INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name,email) VALUES(%s,%s,%s,'USER',%s,%s)",
                              (principal, tenant, account, label, email))
                admin.execute('INSERT INTO security.workspace_access VALUES(%s,%s,%s,true,true)',
                              (tenant, workspace, principal))
                people.append(principal)
            author, reviewer = people
            admin.execute('INSERT INTO security.organization_admin VALUES(%s,%s)', (tenant, author))
            admin.execute('INSERT INTO security.configuration_permission(configuration_permission_id,organization_id,principal_id,can_approve) VALUES(%s,%s,%s,true)',
                          (uuid7(), tenant, author))
    runtime_dsn = make_conninfo(admin_dsn, user=ROLE, password=runtime_password)
    with psycopg.connect(admin_dsn) as admin:
        active = admin.execute('''SELECT configuration_revision_id FROM governance.configuration_activation
            WHERE organization_id=%s AND package_key='general_business'
              AND effective_from<=now() AND (effective_to IS NULL OR effective_to>now())''',
            (tenant,)).fetchone()
        author_ticket = _ticket(admin, tenant, author)
        reviewer_ticket = _ticket(admin, tenant, reviewer)
    if not active:
        package = json.loads((Path(__file__).resolve().parents[2] / 'database/seeds/general-business.json').read_text())
        with psycopg.connect(runtime_dsn) as runtime:
            with tenant_transaction(runtime, author_ticket):
                revision = import_package(runtime, package)
                runtime.execute('SELECT governance.approve_and_activate(%s,%s,%s,statement_timestamp())',
                                (revision, uuid7(), uuid7()))
    return runtime_dsn, author_ticket, reviewer_ticket


def main():
    runtime_dsn, author, reviewer = prepare(os.environ['KC_DEMO_ADMIN_DSN'],
                                            os.environ['KC_DEMO_RUNTIME_PASSWORD'])
    server = WorkspaceServer(('127.0.0.1', 8080), runtime_dsn, dev_ticket_login=True)
    print('Local Knowledge Catalog demo: http://127.0.0.1:8080/', flush=True)
    print('Demo Author ticket:', author, flush=True)
    print('Demo Reviewer ticket:', reviewer, flush=True)
    print('Tickets expire after 15 minutes. Restart this demo to get fresh tickets.', flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
