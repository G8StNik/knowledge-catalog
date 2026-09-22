"""Source upload helpers. Files are preserved while extracted text supports citations."""
import base64
from io import BytesIO
from uuid import UUID

from psycopg.types.json import Jsonb
from pypdf import PdfReader
from pypdf.errors import PyPdfError

from kc.ids import uuid7

MAX_FILE_BYTES = 10 * 1024 * 1024
MEDIA_TYPES = {'text/plain', 'text/markdown', 'application/pdf'}


def extract_text(file_name, media_type, content):
    if not isinstance(content, bytes) or not content or len(content) > MAX_FILE_BYTES:
        raise ValueError('Upload a nonempty file no larger than 10 MB')
    if media_type not in MEDIA_TYPES:
        raise ValueError('Upload a PDF, plain-text, or Markdown file')
    if (not isinstance(file_name, str) or not file_name or len(file_name) > 255
            or '/' in file_name or '\\' in file_name or file_name in ('.', '..') or '\x00' in file_name):
        raise ValueError('Invalid file name')
    if media_type == 'application/pdf':
        try:
            reader = PdfReader(BytesIO(content), strict=True)
            if reader.is_encrypted:
                raise ValueError('Encrypted PDFs are not supported')
            text = '\n\n'.join(page.extract_text() or '' for page in reader.pages)
        except PyPdfError as error:
            raise ValueError('The PDF could not be read') from error
    else:
        text = content.decode('utf-8')
    text = text.replace('\x00', '').strip()
    if not text:
        raise ValueError('The file contains no readable text')
    return text


def upload(conn, *, workspace_id, configuration_revision_id, classification_id, document_key,
           title, file_name, media_type, content, owner_principal_id=None, principal_ids=None,
           effective_from=None, effective_to=None, source_artifact_id=None):
    text = extract_text(file_name, media_type, content)
    action = 'version' if source_artifact_id else 'create'
    payload = dict(workspace_id=workspace_id, configuration_revision_id=configuration_revision_id,
                   classification_id=classification_id, document_key=document_key, title=title,
                   file_name=file_name, media_type=media_type, content_base64=base64.b64encode(content).decode(),
                   text_content=text, owner_principal_id=owner_principal_id, principal_ids=principal_ids or [],
                   effective_from=effective_from, effective_to=effective_to,
                   source_artifact_id=source_artifact_id or uuid7(), artifact_version_id=uuid7(),
                   knowledge_source_id=uuid7())
    portable = {k: str(v) if isinstance(v, UUID) else [str(x) for x in v] if isinstance(v, list) else v
                for k, v in payload.items() if v is not None}
    with conn.transaction():
        return conn.execute('SELECT source.document_command(%s,%s,%s)',
                            (action, Jsonb(portable), uuid7())).fetchone()[0]
