import hashlib
import json
from pathlib import Path
import secrets
from datetime import datetime,timedelta,timezone

import psycopg
from psycopg.types.json import Jsonb
import pytest

from kc.configuration import import_package
from kc.ids import uuid7
from kc import knowledge as kc


@pytest.fixture
def sop(database,tenant,connect):
    editor=connect(tenant)
    package=json.loads((Path(__file__).resolve().parents[1]/'database/seeds/general-business.json').read_text())
    revision=import_package(editor,package)
    editor.execute('SELECT governance.approve_and_activate(%s,%s,%s,statement_timestamp())',(revision,uuid7(),uuid7()))
    typ=editor.execute("SELECT knowledge_type_id FROM catalog.knowledge_type WHERE configuration_revision_id=%s AND key='sop'",(revision,)).fetchone()[0]
    domain=editor.execute('SELECT domain_id FROM catalog.domain WHERE configuration_revision_id=%s',(revision,)).fetchone()[0]
    roles=dict(editor.execute('SELECT key,role_id FROM governance.role WHERE configuration_revision_id=%s',(revision,)))
    editor.commit()
    reviewer,account,source,artifact,evidence=[uuid7() for _ in range(5)]
    token=secrets.token_urlsafe(48)
    with psycopg.connect(database[0]) as admin:
        admin.execute("INSERT INTO identity.account(account_id,display_name) VALUES(%s,'Independent reviewer')",(account,))
        admin.execute('INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id) VALUES(%s,%s,%s)',(uuid7(),tenant['id'],account))
        admin.execute("INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name) VALUES(%s,%s,%s,'USER','Reviewer')",(reviewer,tenant['id'],account))
        for actor in (tenant['human'],reviewer):
            admin.execute('INSERT INTO security.workspace_access VALUES(%s,%s,%s,true,true)',(tenant['id'],tenant['workspace'],actor))
        admin.execute("INSERT INTO source.knowledge_source VALUES(%s,%s,'manual','Controlled source','manual')",(source,tenant['id']))
        admin.execute("INSERT INTO source.source_artifact(source_artifact_id,organization_id,knowledge_source_id,external_key,source_uri,title) VALUES(%s,%s,%s,'onboarding','urn:example:approved-onboarding','Approved onboarding source')",(artifact,tenant['id'],source))
        admin.execute("INSERT INTO source.artifact_version(artifact_version_id,organization_id,source_artifact_id,version_key,content) VALUES(%s,%s,%s,'1','Verify the request, confirm the owner, record approval, and retain the evidence.')",(evidence,tenant['id'],artifact))
        for actor in (tenant['human'],reviewer):
            admin.execute("INSERT INTO security.source_acl VALUES(%s,%s,%s,true,now()+interval '1 day')",(tenant['id'],artifact,actor))
        admin.execute('SELECT security.issue_ticket(%s,%s,%s,%s,%s)',(hashlib.sha256(token.encode()).digest(),tenant['id'],reviewer,database[1]['human'],datetime.now(timezone.utc)+timedelta(minutes=10)))
    editor.execute('SELECT security.begin_context(%s)',(tenant['tickets']['human'],))
    review_tenant={**tenant,'human':reviewer,'tickets':{**tenant['tickets'],'human':token}}
    review_conn=connect(review_tenant)
    return dict(tenant=tenant,editor=editor,reviewer=review_conn,reviewer_id=reviewer,
                revision=revision,typ=typ,domain=domain,roles=roles,evidence=evidence,artifact=artifact,reviewer_ticket=token)


def new_draft(s):
    return kc.create_draft(s['editor'],workspace_id=s['tenant']['workspace'],configuration_revision_id=s['revision'],
                          knowledge_type_id=s['typ'],domain_id=s['domain'],knowledge_key='SOP-001',
                          title='Request review SOP',content='1. Verify the request.\n2. Record approval and retain evidence.',metadata={'review_date':'2027-09-17'})


def prepared(s):
    version=new_draft(s)
    kc.attach_evidence(s['editor'],version,s['evidence'],'Full procedure','Steps grounded in the controlled source.')
    kc.assign_responsibility(s['editor'],version,s['roles']['owner'],s['tenant']['human'])
    kc.assign_responsibility(s['editor'],version,s['roles']['approver'],s['reviewer_id'])
    return version


def commit_editor(s):
    s['editor'].commit()
    s['editor'].execute('SELECT security.begin_context(%s)',(s['tenant']['tickets']['human'],))


def published(s):
    version=prepared(s); kc.submit(s['editor'],version); commit_editor(s)
    kc.review(s['reviewer'],version,'Verified procedure against the cited source.')
    kc.publish(s['reviewer'],version); s['reviewer'].commit()
    return version


def test_sop_draft_evidence_review_publish_revise_preserves_history(sop):
    s=sop; version=published(s)
    old=s['editor'].execute('SELECT to_jsonb(v) FROM catalog.knowledge_version v WHERE knowledge_version_id=%s',(version,)).fetchone()[0]
    citations=s['editor'].execute('SELECT to_jsonb(c) FROM catalog.citation c WHERE knowledge_version_id=%s',(version,)).fetchall()
    revised=kc.revise(s['editor'],version)
    kc.edit_draft(s['editor'],revised,content='1. Verify the request.\n2. Confirm the owner.\n3. Record approval and retain evidence.')
    assert s['editor'].execute('SELECT to_jsonb(v) FROM catalog.knowledge_version v WHERE knowledge_version_id=%s',(version,)).fetchone()[0]==old
    assert s['editor'].execute('SELECT to_jsonb(c) FROM catalog.citation c WHERE knowledge_version_id=%s',(version,)).fetchall()==citations
    assert s['editor'].execute('SELECT version_number,status FROM catalog.knowledge_version WHERE knowledge_version_id=%s',(revised,)).fetchone()==(2,'DRAFT')
    assert s['editor'].execute('SELECT current_version_id FROM catalog.knowledge_item WHERE knowledge_item_id=%s',(old['knowledge_item_id'],)).fetchone()[0]==version
    assert s['editor'].execute('SELECT count(*) FROM governance.knowledge_review WHERE knowledge_version_id=%s',(revised,)).fetchone()[0]==0
    assert s['editor'].execute('SELECT artifact_version_id FROM catalog.citation WHERE knowledge_version_id=%s',(revised,)).fetchone()[0]==s['evidence']


def test_cannot_submit_without_evidence_or_responsibilities(sop):
    v=new_draft(sop)
    with pytest.raises(psycopg.errors.CheckViolation,match='evidence'): kc.submit(sop['editor'],v)
    kc.attach_evidence(sop['editor'],v,sop['evidence'],'Full procedure')
    with pytest.raises(psycopg.errors.CheckViolation,match='Responsibility'): kc.submit(sop['editor'],v)


def test_required_metadata_and_unknown_fields_fail_closed(sop):
    v=prepared(sop); kc.edit_draft(sop['editor'],v,metadata={})
    with pytest.raises(psycopg.errors.CheckViolation,match='Required metadata'): kc.submit(sop['editor'],v)
    kc.edit_draft(sop['editor'],v,metadata={'review_date':'2027-09-17','made_up':'value'})
    with pytest.raises(psycopg.errors.CheckViolation,match='Unknown'): kc.submit(sop['editor'],v)


def test_review_freezes_content_evidence_and_responsibilities(sop):
    v=prepared(sop); kc.submit(sop['editor'],v)
    with pytest.raises(psycopg.errors.CheckViolation): kc.edit_draft(sop['editor'],v,content='Changed after submission')
    with pytest.raises(psycopg.errors.CheckViolation): kc.attach_evidence(sop['editor'],v,sop['evidence'],'Another locator')
    with pytest.raises(psycopg.errors.CheckViolation): kc.assign_responsibility(sop['editor'],v,sop['roles']['reviewer'],sop['reviewer_id'])


def test_author_cannot_review_or_publish_without_independent_approval(sop):
    v=prepared(sop); kc.submit(sop['editor'],v)
    with pytest.raises(psycopg.errors.CheckViolation,match='Independent'): kc.review(sop['editor'],v,'Self approval')
    with pytest.raises(psycopg.errors.CheckViolation): kc.publish(sop['editor'],v)


def test_source_revocation_hides_knowledge_and_evidence(sop,database):
    v=published(sop)
    with psycopg.connect(database[0]) as admin:
        admin.execute('UPDATE security.source_acl SET is_allowed=false WHERE organization_id=%s AND principal_id=%s',
                      (sop['tenant']['id'],sop['tenant']['human']))
    assert sop['editor'].execute('SELECT count(*) FROM catalog.knowledge_version').fetchone()[0]==0
    assert sop['editor'].execute('SELECT count(*) FROM catalog.citation').fetchone()[0]==0
    assert sop['editor'].execute('SELECT count(*) FROM source.artifact_version').fetchone()[0]==0
    with pytest.raises(psycopg.errors.InsufficientPrivilege): kc.revise(sop['editor'],v)


def test_published_and_source_history_immutable_even_for_privileged_writer(sop,database):
    v=published(sop)
    with psycopg.connect(database[0]) as admin:
        for statement,identifier in [('UPDATE catalog.knowledge_version SET content=\'tamper\' WHERE knowledge_version_id=%s',v),
                                     ('DELETE FROM catalog.citation WHERE knowledge_version_id=%s',v),
                                     ('UPDATE source.artifact_version SET content=\'tamper\' WHERE artifact_version_id=%s',sop['evidence'])]:
            with pytest.raises(psycopg.errors.CheckViolation):
                with admin.transaction(): admin.execute(statement,(identifier,))


def test_other_tenant_and_ai_cannot_mutate_sop(sop,tenant_factory,connect):
    v=prepared(sop); commit_editor(sop)
    other=connect(tenant_factory())
    assert other.execute('SELECT count(*) FROM catalog.knowledge_version').fetchone()[0]==0
    with pytest.raises(psycopg.errors.InsufficientPrivilege): kc.edit_draft(other,v,content='Attack')
    ai=connect(sop['tenant'],'ai')
    with pytest.raises(psycopg.errors.InsufficientPrivilege): kc.publish(ai,v)


def test_contributor_other_than_creator_cannot_approve(sop):
    v=prepared(sop); commit_editor(sop)
    kc.edit_draft(sop['reviewer'],v,content='Reviewer also wrote this content.')
    kc.submit(sop['reviewer'],v)
    with pytest.raises(psycopg.errors.CheckViolation,match='contributor'):
        kc.review(sop['reviewer'],v,'I edited and approved it')


def test_return_to_draft_requires_new_review_snapshot(sop):
    v=prepared(sop); kc.submit(sop['editor'],v)
    previous=sop['editor'].execute('SELECT review_digest FROM catalog.knowledge_version WHERE knowledge_version_id=%s',(v,)).fetchone()[0]
    kc.return_to_draft(sop['editor'],v)
    kc.edit_draft(sop['editor'],v,content='Updated draft must be reviewed again.')
    kc.submit(sop['editor'],v)
    current=sop['editor'].execute('SELECT review_round,review_digest FROM catalog.knowledge_version WHERE knowledge_version_id=%s',(v,)).fetchone()
    assert current[0]==2 and current[1]!=previous


def test_reviewer_revocation_invalidates_approval(sop,database):
    v=prepared(sop); kc.submit(sop['editor'],v); commit_editor(sop)
    kc.review(sop['reviewer'],v,'Approved with source access'); sop['reviewer'].commit()
    with psycopg.connect(database[0]) as admin:
        admin.execute('UPDATE security.source_acl SET is_allowed=false WHERE organization_id=%s AND principal_id=%s',
                      (sop['tenant']['id'],sop['reviewer_id']))
    with pytest.raises(psycopg.errors.CheckViolation,match='Valid human approvals'):
        kc.publish(sop['editor'],v)


def test_second_draft_for_same_published_item_is_rejected(sop):
    v=published(sop); kc.revise(sop['editor'],v)
    with pytest.raises(psycopg.errors.UniqueViolation): kc.revise(sop['editor'],v)


def test_cli_complete_walkthrough(sop,database,monkeypatch,capsys,tmp_path):
    from psycopg.conninfo import make_conninfo
    from kc.knowledge_cli import main
    monkeypatch.setenv('KC_RUNTIME_DSN',make_conninfo(database[0],user=database[1]['human'],password='kc-test-only'))
    def run(*args,reviewer=False):
        monkeypatch.setenv('KC_SESSION_TICKET',sop['reviewer_ticket'] if reviewer else sop['tenant']['tickets']['human'])
        monkeypatch.setattr('sys.argv',['knowledge_cli',*map(str,args)])
        main()
        return json.loads(capsys.readouterr().out)
    creation=tmp_path/'sop.json'
    creation.write_text(json.dumps(dict(workspace_id=sop['tenant']['workspace'],configuration_revision_id=sop['revision'],
        knowledge_type_id=sop['typ'],domain_id=sop['domain'],knowledge_key='SOP-CLI',title='Request review SOP',
        content='Verify the request, record approval and retain evidence.',metadata={'review_date':'2027-09-17'}),default=str))
    version=run('create',creation)
    run('attach',version,sop['evidence'],'--locator','Full procedure')
    run('assign',version,sop['roles']['owner'],sop['tenant']['human'])
    run('assign',version,sop['roles']['approver'],sop['reviewer_id'])
    run('submit',version)
    run('review',version,'--note','Verified against the immutable source',reviewer=True)
    run('publish',version,reviewer=True)
    original=run('show',version)
    revised=run('revise',version)
    changes=tmp_path/'revision.json'; changes.write_text(json.dumps({'content':'Verify the request, confirm the owner, record approval and retain evidence.'}))
    run('edit',revised,changes)
    assert run('show',version)==original
    assert original['version']['status']=='PUBLISHED' and original['version']['version_number']==1
    assert len(original['citations'])==1 and len(original['reviews'])==1
    assert run('show',revised)['version']['status']=='DRAFT'


def test_missing_source_permission_blocks_attachment(sop,database):
    v=new_draft(sop)
    with psycopg.connect(database[0]) as admin:
        admin.execute('DELETE FROM security.source_acl WHERE organization_id=%s AND principal_id=%s',
                      (sop['tenant']['id'],sop['tenant']['human']))
    with pytest.raises(psycopg.errors.InsufficientPrivilege,match='Source evidence unavailable'):
        kc.attach_evidence(sop['editor'],v,sop['evidence'],'Full procedure')
