import hashlib

import psycopg
import pytest

from kc import sources
from test_sop_workflow import sop


def classification(s):
    return s['editor'].execute(
        'SELECT classification_id FROM governance.classification WHERE configuration_revision_id=%s AND is_enabled LIMIT 1',
        (s['revision'],)).fetchone()[0]


def test_upload_and_new_version_preserve_original_history_and_acl(sop):
    s = sop
    first_bytes = b'# Access requests\nVerify the requester and owner.'
    first = sources.upload(s['editor'], workspace_id=s['tenant']['workspace'],
        configuration_revision_id=s['revision'], classification_id=classification(s), document_key='POL-001',
        title='Access request policy', file_name='access.md', media_type='text/markdown', content=first_bytes,
        owner_principal_id=s['tenant']['human'], principal_ids=[s['reviewer_id']], effective_from='2026-01-01')
    artifact = s['editor'].execute(
        'SELECT source_artifact_id FROM source.artifact_version WHERE artifact_version_id=%s', (first,)).fetchone()[0]
    second_bytes = b'# Access requests\nVerify the requester, owner, and approval.'
    second = sources.upload(s['editor'], workspace_id=s['tenant']['workspace'],
        configuration_revision_id=s['revision'], classification_id=classification(s), document_key='ignored',
        title='ignored', file_name='access-v2.md', media_type='text/markdown', content=second_bytes,
        source_artifact_id=artifact)
    rows = s['editor'].execute('''SELECT version_key,original_content,original_content_hash,content
        FROM source.artifact_version WHERE source_artifact_id=%s ORDER BY version_key''', (artifact,)).fetchall()
    assert rows == [('1', first_bytes, hashlib.sha256(first_bytes).hexdigest(), '# Access requests\nVerify the requester and owner.'),
                    ('2', second_bytes, hashlib.sha256(second_bytes).hexdigest(), '# Access requests\nVerify the requester, owner, and approval.')]
    s['editor'].commit()
    s['reviewer'].execute('SELECT security.begin_context(%s)', (s['reviewer_ticket'],))
    assert s['reviewer'].execute('SELECT count(*) FROM source.artifact_version WHERE source_artifact_id=%s', (artifact,)).fetchone()[0] == 2
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        with s['editor'].transaction():
            s['editor'].execute("UPDATE source.artifact_version SET original_content='tamper' WHERE artifact_version_id=%s", (first,))


@pytest.mark.parametrize(('name', 'media', 'content'), [
    ('../policy.txt', 'text/plain', b'content'),
    ('policy.exe', 'application/octet-stream', b'content'),
    ('empty.txt', 'text/plain', b''),
    ('bad.txt', 'text/plain', b'\xff'),
    ('blank.pdf', 'application/pdf', b'%PDF-1.4 invalid'),
])
def test_invalid_uploads_fail_before_storage(sop, name, media, content):
    before = sop['editor'].execute('SELECT count(*) FROM source.source_artifact').fetchone()[0]
    with pytest.raises(ValueError):
        sources.upload(sop['editor'], workspace_id=sop['tenant']['workspace'],
            configuration_revision_id=sop['revision'], classification_id=classification(sop), document_key='BAD',
            title='Bad source', file_name=name, media_type=media, content=content)
    assert sop['editor'].execute('SELECT count(*) FROM source.source_artifact').fetchone()[0] == before


def test_other_tenant_cannot_add_a_version(sop, tenant_factory, connect):
    s = sop
    first = sources.upload(s['editor'], workspace_id=s['tenant']['workspace'], configuration_revision_id=s['revision'],
        classification_id=classification(s), document_key='POL-PRIVATE', title='Private policy', file_name='private.txt',
        media_type='text/plain', content=b'Private controlled evidence')
    artifact = s['editor'].execute('SELECT source_artifact_id FROM source.artifact_version WHERE artifact_version_id=%s', (first,)).fetchone()[0]
    other_tenant = tenant_factory()
    other = connect(other_tenant)
    with pytest.raises(psycopg.Error):
        sources.upload(other, workspace_id=other_tenant['workspace'], configuration_revision_id=s['revision'],
            classification_id=classification(s), document_key='POL-PRIVATE', title='Attack', file_name='attack.txt',
            media_type='text/plain', content=b'Attempted overwrite', source_artifact_id=artifact)


def test_named_source_owner_receives_access_without_extra_reader_grant(sop):
    s = sop
    version = sources.upload(s['editor'], workspace_id=s['tenant']['workspace'],
        configuration_revision_id=s['revision'], classification_id=classification(s), document_key='POL-OWNER',
        title='Owner policy', file_name='owner.txt', media_type='text/plain', content=b'Owner may verify this source.',
        owner_principal_id=s['reviewer_id'])
    s['editor'].commit()
    assert s['reviewer'].execute('SELECT content FROM source.artifact_version WHERE artifact_version_id=%s',
                                 (version,)).fetchone()[0] == 'Owner may verify this source.'
