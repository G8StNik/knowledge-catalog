"""Explicit local-only seed: two demo tenants and draft starter configurations."""
import hashlib
import json
import os
from pathlib import Path
import secrets
from datetime import datetime,timedelta,timezone

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict,make_conninfo

from kc.configuration import import_package
from kc.ids import uuid7
from kc.session import tenant_transaction

REVIEWER_ROLE='kc_local_reviewer'

def main():
    if os.environ.get('KC_DEV_MODE')!='1':
        raise ValueError('Set KC_DEV_MODE=1 only for a disposable development database')
    dsn=os.environ['KC_MIGRATION_DSN']; password=os.environ['KC_DEV_REVIEWER_PASSWORD']
    if conninfo_to_dict(dsn).get('host') not in ('127.0.0.1','localhost','postgres'):
        raise ValueError('Development seeds require a local/Docker database host')
    role=REVIEWER_ROLE
    package=json.loads((Path(__file__).resolve().parents[2]/'database/seeds/general-business.json').read_text())
    with psycopg.connect(dsn) as admin:
        found=admin.execute('SELECT rolsuper,rolbypassrls,rolcreaterole FROM pg_roles WHERE rolname=%s',(role,)).fetchone()
        if found is None:
            admin.execute(sql.SQL('CREATE ROLE {} LOGIN INHERIT PASSWORD {}').format(sql.Identifier(role),sql.Literal(password)))
        elif any(found):
            raise ValueError('Refusing a privileged development reviewer role')
        admin.execute(sql.SQL('GRANT kc_human_approver TO {}').format(sql.Identifier(role)))
    for key in ('demo_a','demo_b'):
        with psycopg.connect(dsn) as admin:
            if admin.execute('SELECT 1 FROM core.organization WHERE organization_key=%s',(key,)).fetchone():
                print(key,'already exists; preserved'); continue
            tenant,account,human,ai,workspace=[uuid7() for _ in range(5)]
            admin.execute('INSERT INTO core.organization(organization_id,organization_key,organization_name) VALUES(%s,%s,%s)',(tenant,key,key.replace('_',' ').title()))
            admin.execute('INSERT INTO core.workspace(workspace_id,organization_id,workspace_key,workspace_name) VALUES(%s,%s,%s,%s)',(workspace,tenant,'general','General'))
            admin.execute('INSERT INTO identity.account(account_id,display_name,primary_email) VALUES(%s,%s,%s)',(account,'Demo reviewer',key+'@example.invalid'))
            admin.execute('INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id) VALUES(%s,%s,%s)',(uuid7(),tenant,account))
            admin.execute("INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name) VALUES(%s,%s,%s,'USER','Demo reviewer')",(human,tenant,account))
            admin.execute("INSERT INTO identity.principal(principal_id,organization_id,principal_type,display_name) VALUES(%s,%s,'AI_AGENT','Demo proposal agent')",(ai,tenant))
            admin.execute('INSERT INTO security.configuration_permission(configuration_permission_id,organization_id,principal_id,can_approve) VALUES(%s,%s,%s,true)',(uuid7(),tenant,human))
            token=secrets.token_urlsafe(48)
            admin.execute('SELECT security.issue_ticket(%s,%s,%s,%s,%s)',(hashlib.sha256(token.encode()).digest(),tenant,human,role,datetime.now(timezone.utc)+timedelta(minutes=5)))
        try:
            with psycopg.connect(make_conninfo(dsn,user=role,password=password)) as reviewer:
                with tenant_transaction(reviewer,token): revision=import_package(reviewer,package)
            print(key,'tenant',tenant,'draft revision',revision)
        finally:
            with psycopg.connect(dsn) as admin:
                admin.execute('DELETE FROM security.session_ticket WHERE token_hash=%s',(hashlib.sha256(token.encode()).digest(),))


if __name__=='__main__': main()
