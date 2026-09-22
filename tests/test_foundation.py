import hashlib
from datetime import datetime, timedelta, timezone
import shutil
from decimal import Decimal

import psycopg
from psycopg import sql
import pytest

from kc.ids import uuid7
from kc.migrate import migrate, MIGRATIONS
from kc.configuration import TABLES, import_package, export_package, validate_package


def package(version=1):
    return {'format_version':1,'package_key':'general','version':version,'entities':{
        'catalog.domain':[{'key':'root','display_name':'Root'}, {'key':'child','display_name':'Child','parent_domain_key':'root'}],
        'catalog.taxonomy':[{'key':'topics','display_name':'Topics'}],
        'catalog.taxonomy_term':[{'key':'hr','display_name':'Human resources','taxonomy_key':'topics'}],
        'catalog.term_alias':[{'key':'hr_alias','display_name':'HR','taxonomy_term_key':'hr','alias':'HR','alias_kind':'ACRONYM'}],
        'governance.authority_level':[{'key':'approved','display_name':'Approved','trust_rank':1}],
        'governance.classification':[{'key':'internal','display_name':'Internal','sensitivity_rank':1}],
        'governance.role':[{'key':'approver','display_name':'Approver'}],
        'governance.lifecycle_workflow':[{'key':'standard','display_name':'Standard'}],
        'governance.lifecycle_state':[{'key':'draft','display_name':'Draft','lifecycle_workflow_key':'standard','is_initial':True},
            {'key':'published','display_name':'Published','lifecycle_workflow_key':'standard','is_published':True}],
        'governance.lifecycle_transition':[{'key':'publish','display_name':'Publish','lifecycle_workflow_key':'standard',
            'from_state_key':'draft','to_state_key':'published','approval_role_key':'approver','minimum_approvals':1,'requires_human_approval':True}],
        'catalog.knowledge_type':[{'key':'policy','display_name':'Policy','lifecycle_workflow_key':'standard','default_authority_level_key':'approved','default_classification_key':'internal'}],
        'catalog.custom_field_definition':[{'key':'department','display_name':'Department','data_type':'CHOICE'}],
        'catalog.custom_field_choice':[{'key':'hr','display_name':'HR','custom_field_definition_key':'department','value':'HR'}],
        'catalog.knowledge_type_field':[{'key':'policy_department','display_name':'Department','knowledge_type_key':'policy','custom_field_definition_key':'department','is_required':True}],
        'catalog.relationship_type':[{'key':'governs','display_name':'Governs','forward_label':'governs','reverse_label':'governed by'}],
        'catalog.relationship_type_restriction':[{'key':'policy_governs_policy','display_name':'Policy governs policy','relationship_type_key':'governs','source_knowledge_type_key':'policy','target_knowledge_type_key':'policy'}],
        'governance.responsibility_requirement':[{'key':'policy_approver','display_name':'Approver','knowledge_type_key':'policy','role_key':'approver'}],
        'catalog.knowledge_template':[{'key':'policy','display_name':'Policy template','knowledge_type_key':'policy','domain_key':'root','content_sections':['Purpose','Policy']}],
        'catalog.template_responsibility':[{'key':'policy_approver','display_name':'Approver','knowledge_template_key':'policy','role_key':'approver'}],
        'catalog.template_field':[{'key':'policy_department','display_name':'Department','knowledge_template_key':'policy','custom_field_definition_key':'department'}],
    }}


def activate(conn,revision,starts=None,ends=None):
    activation=uuid7()
    conn.execute('SELECT governance.approve_and_activate(%s,%s,%s,%s,%s,%s)',
                 (revision,activation,uuid7(),starts or datetime.now(timezone.utc)+timedelta(seconds=10),ends,'Reviewed exact revision'))
    return activation


def denied(conn,statement,params=(),error=psycopg.Error):
    with pytest.raises(error):
        with conn.transaction(): conn.execute(statement,params)


def test_uuid7_unique_monotonic_and_clock_rollback(monkeypatch):
    from kc import ids
    values=[uuid7() for _ in range(10000)]
    assert all(v.version==7 and v.variant=='specified in RFC 4122' for v in values)
    assert len(set(values))==len(values) and values==sorted(values)
    monkeypatch.setattr(ids.time,'time_ns',lambda:0)
    assert uuid7()>values[-1]


def test_migrations_repeat_and_tamper_detection(database,tmp_path):
    dsn,_=database
    assert migrate(dsn)==[]
    directory=tmp_path/'migrations'; shutil.copytree(MIGRATIONS,directory)
    first=next(directory.glob('V001*')); first.write_text(first.read_text()+'\n-- tampered\n')
    with pytest.raises(ValueError,match='changed'): migrate(dsn,directory)


def test_context_requires_ticket_and_clears_after_commit(tenant,tenant_factory,connect):
    other=tenant_factory(); conn=connect(tenant,context=False)
    assert conn.execute('SELECT count(*) FROM core.workspace').fetchone()[0]==0
    conn.execute("SELECT set_config('app.current_organization_id',%s,true)",(str(other['id']),))
    assert conn.execute('SELECT count(*) FROM core.workspace').fetchone()[0]==0
    denied(conn,'SELECT security.begin_context(%s)',('x'*64,),psycopg.errors.InvalidAuthorizationSpecification)
    conn.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))
    assert conn.execute('SELECT organization_id FROM core.workspace').fetchall()==[(tenant['id'],)]
    conn.commit()
    assert conn.execute('SELECT count(*) FROM core.workspace').fetchone()[0]==0


def test_ticket_bound_to_login_and_ai_cannot_impersonate_human(tenant,connect):
    conn=connect(tenant,'ai')
    denied(conn,'SELECT security.begin_context(%s)',(tenant['tickets']['human'],),psycopg.errors.InvalidAuthorizationSpecification)
    assert conn.execute('SELECT security.current_principal()').fetchone()[0]==tenant['ai']
    denied(conn,'SELECT * FROM security.session_ticket',error=psycopg.errors.InsufficientPrivilege)
    denied(conn,'SELECT * FROM identity.account',error=psycopg.errors.InsufficientPrivilege)


def test_revocation_membership_and_account_suspension(database,tenant,connect):
    dsn,_=database; conn=connect(tenant)
    with psycopg.connect(dsn) as admin:
        admin.execute("UPDATE identity.account SET status='SUSPENDED' WHERE account_id=%s",(tenant['account'],))
    assert conn.execute('SELECT count(*) FROM core.workspace').fetchone()[0]==0
    with psycopg.connect(dsn) as admin:
        admin.execute("UPDATE identity.account SET status='ACTIVE' WHERE account_id=%s",(tenant['account'],))
        admin.execute('DELETE FROM security.session_ticket WHERE token_hash=%s',(hashlib.sha256(tenant['tickets']['human'].encode()).digest(),))
    assert conn.execute('SELECT count(*) FROM core.workspace').fetchone()[0]==0


def test_cross_tenant_integrity_even_for_privileged_writer(database,tenant,tenant_factory):
    other=tenant_factory(); dsn,_=database
    with psycopg.connect(dsn) as admin:
        denied(admin,"INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_object_id) VALUES(%s,%s,%s,'oidc','a')",
               (uuid7(),tenant['id'],other['human']),psycopg.errors.ForeignKeyViolation)
        denied(admin,"INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name) VALUES(%s,%s,%s,'USER','Bad')",
               (uuid7(),tenant['id'],other['account']),psycopg.errors.ForeignKeyViolation)


@pytest.mark.parametrize('reverse',[False,True])
def test_all_config_tables_rls_read_update_delete_insert(tenant,tenant_factory,connect,database,reverse):
    other=tenant_factory(); a=connect(tenant); b=connect(other)
    if reverse: tenant,other=other,tenant; a,b=b,a
    ra=import_package(a,package()); rb=import_package(b,package()); a.commit(); b.commit()
    a.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))
    for table in TABLES:
        name=sql.Identifier(*table.split('.'))
        assert a.execute(sql.SQL('SELECT count(*) FROM {} WHERE organization_id=%s').format(name),(other['id'],)).fetchone()[0]==0
        assert a.execute(sql.SQL("UPDATE {} SET display_name='attack' WHERE organization_id=%s").format(name),(other['id'],)).rowcount==0
        assert a.execute(sql.SQL('DELETE FROM {} WHERE organization_id=%s').format(name),(other['id'],)).rowcount==0
        with psycopg.connect(database[0]) as admin:
            from psycopg.rows import dict_row
            with admin.cursor(row_factory=dict_row) as cursor:
                row=cursor.execute(sql.SQL('SELECT * FROM {} WHERE configuration_revision_id=%s LIMIT 1').format(name),(rb,)).fetchone()
        from psycopg.types.json import Jsonb
        from kc.configuration import JSON_FIELDS
        values=[Jsonb(v) if k in JSON_FIELDS else v for k,v in row.items()]
        denied(a,sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(name,sql.SQL(',').join(map(sql.Identifier,row)),sql.SQL(',').join(sql.Placeholder()*len(row))),values,psycopg.errors.InsufficientPrivilege)
    denied(a,"INSERT INTO catalog.domain(domain_id,organization_id,configuration_revision_id,key,display_name) VALUES(%s,%s,%s,'attack','Attack')",(uuid7(),other['id'],rb),psycopg.errors.InsufficientPrivilege)
    # Same tenant but wrong revision is also prohibited by composite FK.
    r2=import_package(a,package(2))
    root=a.execute("SELECT domain_id FROM catalog.domain WHERE configuration_revision_id=%s AND key='root'",(ra,)).fetchone()[0]
    denied(a,"UPDATE catalog.domain SET parent_domain_id=%s WHERE configuration_revision_id=%s AND key='child'",(root,r2),psycopg.errors.ForeignKeyViolation)


def test_hierarchy_cycle_rejected(tenant,connect):
    conn=connect(tenant); revision=import_package(conn,package())
    child=conn.execute("SELECT domain_id FROM catalog.domain WHERE configuration_revision_id=%s AND key='child'",(revision,)).fetchone()[0]
    denied(conn,"UPDATE catalog.domain SET parent_domain_id=%s WHERE configuration_revision_id=%s AND key='root'",(child,revision),psycopg.errors.CheckViolation)


def test_approval_immutable_audited_and_no_overlapping_activation(tenant,connect):
    conn=connect(tenant); revision=import_package(conn,package()); activate(conn,revision)
    for table in TABLES:
        denied(conn,sql.SQL("UPDATE {} SET display_name='tamper' WHERE configuration_revision_id=%s").format(sql.Identifier(*table.split('.'))),(revision,),psycopg.errors.CheckViolation)
    denied(conn,"UPDATE governance.configuration_revision SET status='DRAFT' WHERE configuration_revision_id=%s",(revision,),psycopg.errors.InsufficientPrivilege)
    denied(conn,'DELETE FROM audit.event',error=psycopg.errors.InsufficientPrivilege)
    assert conn.execute("SELECT count(*) FROM audit.event WHERE action='CONFIGURATION_APPROVED_AND_SCHEDULED'").fetchone()[0]==1
    revision2=import_package(conn,package(2))
    with pytest.raises(psycopg.errors.ExclusionViolation):
        with conn.transaction(): activate(conn,revision2)
    assert conn.execute('SELECT status FROM governance.configuration_revision WHERE configuration_revision_id=%s',(revision2,)).fetchone()[0]=='DRAFT'


def test_ai_proposal_requires_authorized_human(tenant,connect,database):
    ai=connect(tenant,'ai'); proposal=uuid7()
    from psycopg.types.json import Jsonb
    ai.execute('SELECT governance.propose_configuration(%s,%s,%s,%s,%s,%s,%s)',(proposal,uuid7(),Jsonb(package()),'Improve catalog',Decimal('0.8'),Jsonb([]),Jsonb({'provider':'test'})))
    ai.commit(); ai.execute('SELECT security.begin_context(%s)',(tenant['tickets']['ai'],))
    denied(ai,'SELECT governance.create_revision(%s,%s,%s,%s,%s)',(uuid7(),'general',1,'AI bypass',proposal),psycopg.errors.InsufficientPrivilege)
    denied(ai,"UPDATE governance.configuration_proposal SET status='APPROVED' WHERE configuration_proposal_id=%s",(proposal,),psycopg.errors.InsufficientPrivilege)
    human=connect(tenant); revision=import_package(human,package(),proposal)
    denied(ai,'SELECT governance.approve_and_activate(%s,%s,%s,%s)',(revision,uuid7(),uuid7(),datetime.now(timezone.utc)+timedelta(minutes=1)),psycopg.errors.InsufficientPrivilege)
    activate(human,revision)
    assert human.execute('SELECT status,reviewed_by FROM governance.configuration_proposal WHERE configuration_proposal_id=%s',(proposal,)).fetchone()==('APPROVED',tenant['human'])


def test_human_without_permission_cannot_approve(tenant,connect,database):
    conn=connect(tenant); revision=import_package(conn,package()); conn.commit()
    with psycopg.connect(database[0]) as admin:
        admin.execute('UPDATE security.configuration_permission SET can_approve=false WHERE organization_id=%s',(tenant['id'],))
    conn.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))
    with pytest.raises(psycopg.errors.InsufficientPrivilege): activate(conn,revision)


def test_portable_package_round_trip_between_tenants(tenant,tenant_factory,connect):
    a=connect(tenant); revision=import_package(a,package()); exported=export_package(a,revision)
    b=connect(tenant_factory()); imported=import_package(b,exported)
    assert export_package(b,imported)==exported
    assert str(tenant['id']) not in str(exported)
    assert a.execute('SELECT status FROM governance.configuration_revision WHERE configuration_revision_id=%s',(revision,)).fetchone()[0]=='DRAFT'


def test_import_rejects_unknown_fields_bad_references_and_remote_schema():
    p=package(); p['entities']['catalog.domain'][0]['organization_id']=str(uuid7())
    with pytest.raises(Exception): validate_package(p)
    p=package(); p['entities']['catalog.domain'][1]['parent_domain_key']='missing'
    with pytest.raises(ValueError,match='Unresolved'): validate_package(p)
    p=package(); p['entities']['catalog.custom_field_definition'][0]['validation_schema']={'$ref':'https://example.com/schema'}
    with pytest.raises(ValueError,match='local'): validate_package(p)


def test_bad_import_rolls_back_revision(tenant,connect):
    conn=connect(tenant); p=package(); p['entities']['catalog.domain'][0]['parent_domain_key']='child'
    with pytest.raises(ValueError,match='cycle'): import_package(conn,p)
    assert conn.execute('SELECT count(*) FROM governance.configuration_revision').fetchone()[0]==0


def test_no_runtime_superuser_owner_bypass_or_public_functions(database):
    with psycopg.connect(database[0]) as conn:
        for role in database[1].values():
            assert conn.execute('SELECT rolsuper OR rolbypassrls OR rolcreaterole FROM pg_roles WHERE rolname=%s',(role,)).fetchone()==(False,)
        assert conn.execute("""SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname IN ('core','identity','catalog','governance','audit') AND c.relkind='r' AND NOT (c.relrowsecurity AND c.relforcerowsecurity)""").fetchall()==[]
        assert conn.execute("""SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace,
            LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
            WHERE n.nspname IN ('core','identity','catalog','governance','security','audit') AND a.grantee=0 AND a.privilege_type='EXECUTE'""").fetchall()==[]


def test_failed_migration_is_atomic(database,tmp_path):
    directory=tmp_path/'migrations'; shutil.copytree(MIGRATIONS,directory)
    (directory/'V999__deliberate_failure.sql').write_text('CREATE TABLE core.must_rollback(id int); SELECT 1/0;')
    with pytest.raises(psycopg.errors.DivisionByZero): migrate(database[0],directory)
    with psycopg.connect(database[0]) as conn:
        assert conn.execute("SELECT to_regclass('core.must_rollback')").fetchone()[0] is None
        assert conn.execute('SELECT count(*) FROM kc_migrations.history WHERE version=999').fetchone()[0]==0


def test_group_kinds_cycles_and_principal_retyping(database,tenant):
    with psycopg.connect(database[0]) as conn:
        groups=[uuid7(),uuid7()]
        for group in groups:
            conn.execute("INSERT INTO identity.principal(principal_id,organization_id,principal_type,display_name) VALUES(%s,%s,'GROUP','Group')",(group,tenant['id']))
        statement='INSERT INTO identity.group_membership(group_membership_id,organization_id,group_principal_id,member_principal_id) VALUES(%s,%s,%s,%s)'
        denied(conn,statement,(uuid7(),tenant['id'],tenant['human'],groups[0]),psycopg.errors.CheckViolation)
        conn.execute(statement,(uuid7(),tenant['id'],groups[0],groups[1]))
        denied(conn,statement,(uuid7(),tenant['id'],groups[1],groups[0]),psycopg.errors.CheckViolation)
        denied(conn,"UPDATE identity.principal SET principal_type='SERVICE' WHERE principal_id=%s",(groups[0],),psycopg.errors.CheckViolation)


def test_external_identity_reusable_across_tenants_but_unique_within(database,tenant,tenant_factory):
    other=tenant_factory()
    with psycopg.connect(database[0]) as conn:
        statement="INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_object_id) VALUES(%s,%s,%s,'oidc','same-global-subject')"
        for t in (tenant,other): conn.execute(statement,(uuid7(),t['id'],t['human']))
        denied(conn,statement,(uuid7(),tenant['id'],tenant['human']),psycopg.errors.UniqueViolation)


def test_other_tenant_tables_fail_closed(database,tenant,tenant_factory,connect):
    other=tenant_factory(); conn=connect(tenant)
    with psycopg.connect(database[0]) as admin:
        tables=admin.execute("""SELECT table_schema,table_name FROM information_schema.columns
            WHERE column_name='organization_id' AND table_schema IN ('core','identity','governance','security','audit')
            AND table_name<>'session_ticket'""").fetchall()
    for schema,table in tables:
        identifier=sql.Identifier(schema,table)
        if (schema,table) in {('security','organization_admin'),('identity','invitation')}:
            denied(conn,sql.SQL('SELECT count(*) FROM {}').format(identifier),(),psycopg.errors.InsufficientPrivilege)
            continue
        assert conn.execute(sql.SQL('SELECT count(*) FROM {} WHERE organization_id=%s').format(identifier),(other['id'],)).fetchone()[0]==0
        statement=sql.SQL('DELETE FROM {} WHERE organization_id=%s').format(identifier)
        if schema+'.'+table in TABLES:
            assert conn.execute(statement,(other['id'],)).rowcount==0
        else:
            denied(conn,statement,(other['id'],),psycopg.errors.InsufficientPrivilege)


def test_invalid_workflow_cannot_activate(tenant,connect):
    conn=connect(tenant); p=package()
    p['entities']['governance.lifecycle_state'][0]['is_initial']=False
    revision=import_package(conn,p)
    with pytest.raises(psycopg.errors.CheckViolation,match='initial'):
        with conn.transaction(): activate(conn,revision)
    conn.execute("SELECT set_config('kc.change_event_id',%s,true)",(str(uuid7()),))
    conn.execute('UPDATE governance.lifecycle_state SET is_initial=true WHERE configuration_revision_id=%s AND key=%s',(revision,'draft'))
    conn.execute("SELECT set_config('kc.change_event_id',%s,true)",(str(uuid7()),))
    conn.execute('UPDATE governance.lifecycle_transition SET requires_human_approval=false WHERE configuration_revision_id=%s',(revision,))
    with pytest.raises(psycopg.errors.CheckViolation,match='human'):
        with conn.transaction(): activate(conn,revision)


def test_deactivation_retains_history_and_allows_successor(tenant,connect):
    conn=connect(tenant); first=import_package(conn,package())
    start=datetime.now(timezone.utc)+timedelta(minutes=1); end=start+timedelta(days=1)
    activation=activate(conn,first,start)
    conn.execute('SELECT governance.deactivate_configuration(%s,%s,%s,%s)',(activation,uuid7(),end,'Superseded'))
    second=import_package(conn,package(2)); activate(conn,second,end)
    assert conn.execute('SELECT count(*) FROM governance.configuration_activation').fetchone()[0]==2
    assert conn.execute('SELECT status FROM governance.configuration_revision WHERE configuration_revision_id=%s',(first,)).fetchone()[0]=='APPROVED'


def test_concurrent_hierarchy_edits_cannot_form_cycle(database,tenant,connect):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from psycopg.conninfo import make_conninfo
    conn=connect(tenant); p=package()
    p['entities']['catalog.domain']=[{'key':key,'display_name':key} for key in ('left','right')]
    p['entities']['catalog.knowledge_template'][0]['domain_key']='left'
    revision=import_package(conn,p)
    ids=dict(conn.execute('SELECT key,domain_id FROM catalog.domain WHERE configuration_revision_id=%s',(revision,)))
    conn.commit(); barrier=Barrier(2)
    def change(source,target):
        with psycopg.connect(make_conninfo(database[0],user=database[1]['human'],password='kc-test-only')) as worker:
            worker.execute("SET statement_timeout='10s'")
            worker.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))
            barrier.wait(timeout=5)
            try:
                worker.execute("SELECT set_config('kc.change_event_id',%s,true)",(str(uuid7()),))
                worker.execute('UPDATE catalog.domain SET parent_domain_id=%s WHERE domain_id=%s',(ids[target],ids[source]))
                worker.commit(); return 'committed'
            except psycopg.errors.CheckViolation:
                worker.rollback(); return 'cycle rejected'
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(change,'left','right'),pool.submit(change,'right','left')]
        assert sorted(f.result(timeout=15) for f in futures)==['committed','cycle rejected']
