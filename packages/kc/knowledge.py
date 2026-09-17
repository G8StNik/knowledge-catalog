"""SOP workflow client. Calls require a tenant_transaction and appropriate human credentials."""
from uuid import UUID

from psycopg.types.json import Jsonb

from kc.ids import uuid7


def command(conn, action, payload):
    def portable(value):
        if isinstance(value, UUID): return str(value)
        if isinstance(value, dict): return {k:portable(v) for k,v in value.items()}
        if isinstance(value, list): return [portable(v) for v in value]
        return value
    with conn.transaction():
        return conn.execute('SELECT catalog.knowledge_command(%s,%s,%s)',
                            (action,Jsonb(portable(payload)),uuid7())).fetchone()[0]


def create_draft(conn, *, workspace_id, configuration_revision_id, knowledge_type_id,
                 domain_id, knowledge_key, title, content, summary='', metadata=None):
    payload=dict(workspace_id=workspace_id,configuration_revision_id=configuration_revision_id,
                 knowledge_type_id=knowledge_type_id,domain_id=domain_id,knowledge_key=knowledge_key,
                 title=title,content=content,summary=summary,metadata=metadata or {},
                 item_id=uuid7(),version_id=uuid7())
    return command(conn,'create',payload)


def edit_draft(conn,version_id,**changes):
    if set(changes)-{'title','summary','content','metadata'}:
        raise ValueError('Only draft content and metadata can be edited')
    return command(conn,'edit',dict(version_id=version_id,**changes))


def attach_evidence(conn,version_id,artifact_version_id,locator,evidence_note=''):
    return command(conn,'attach',dict(version_id=version_id,artifact_version_id=artifact_version_id,
                                      locator=locator,evidence_note=evidence_note,citation_id=uuid7()))


def assign_responsibility(conn,version_id,role_id,principal_id):
    return command(conn,'assign',dict(version_id=version_id,role_id=role_id,principal_id=principal_id,
                                      responsibility_id=uuid7()))


def submit(conn,version_id,transition_key='submit_for_review'):
    return command(conn,'submit',dict(version_id=version_id,transition_key=transition_key))


def review(conn,version_id,note,transition_key='approve'):
    return command(conn,'review',dict(version_id=version_id,transition_key=transition_key,note=note,review_id=uuid7()))


def publish(conn,version_id,transition_key='publish'):
    return command(conn,'publish',dict(version_id=version_id,transition_key=transition_key))


def return_to_draft(conn,version_id,transition_key='return_to_draft'):
    return command(conn,'return_to_draft',dict(version_id=version_id,transition_key=transition_key))


def revise(conn,version_id):
    # SQL rechecks/locks the published version; its frozen child counts cannot change.
    citations=conn.execute('SELECT count(*) FROM catalog.citation WHERE knowledge_version_id=%s',(version_id,)).fetchone()[0]
    responsibilities=conn.execute('SELECT count(*) FROM governance.knowledge_responsibility WHERE knowledge_version_id=%s',(version_id,)).fetchone()[0]
    return command(conn,'revise',dict(version_id=version_id,new_version_id=uuid7(),
        citation_ids=[uuid7() for _ in range(citations)],responsibility_ids=[uuid7() for _ in range(responsibilities)]))
