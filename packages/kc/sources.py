"""Source upload helpers. Files are preserved while extracted text supports citations."""
import base64
from io import BytesIO
from html.parser import HTMLParser
from uuid import UUID
from xml.etree import ElementTree as ET
from zipfile import BadZipFile, ZipFile

from psycopg.types.json import Jsonb
from pypdf import PdfReader
from pypdf.errors import PyPdfError

from kc.ids import uuid7

MAX_FILE_BYTES = 10 * 1024 * 1024
MEDIA_TYPES = {'text/plain', 'text/markdown', 'application/pdf',
               'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
               'application/vnd.openxmlformats-officedocument.presentationml.presentation',
               'text/html'}
EXTENSIONS = {'.txt': 'text/plain', '.md': 'text/markdown', '.pdf': 'application/pdf',
              '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
              '.html': 'text/html', '.htm': 'text/html'}


class _HTMLText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'noscript'):
            self.skip += 1
        elif tag in ('p', 'div', 'br', 'li', 'h1', 'h2', 'h3', 'tr'):
            self.parts.append('\n')

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'noscript') and self.skip:
            self.skip -= 1
        elif tag in ('p', 'div', 'li', 'tr'):
            self.parts.append('\n')

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def _office_text(content, word):
    try:
        with ZipFile(BytesIO(content)) as archive:
            names = archive.namelist()
            targets = (['word/document.xml'] if word else
                       sorted((name for name in names if name.startswith('ppt/slides/slide')
                               and name.endswith('.xml') and name[16:-4].isdigit()),
                              key=lambda name: int(name[16:-4])))
            if not targets or any(name not in names for name in targets):
                raise ValueError('The Office document has no readable pages or slides')
            if len(targets) > 1000 or sum(archive.getinfo(name).file_size for name in targets) > 30 * 1024 * 1024:
                raise ValueError('The Office document is too large to extract')
            paragraphs = []
            for name in targets:
                root = ET.fromstring(archive.read(name))
                text_tag = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t' if word else '{http://schemas.openxmlformats.org/drawingml/2006/main}t'
                text = ' '.join(node.text or '' for node in root.iter(text_tag)).strip()
                if text:
                    paragraphs.append(text)
            return '\n\n'.join(paragraphs)
    except (BadZipFile, ET.ParseError, KeyError, RuntimeError) as error:
        raise ValueError('The Office document could not be read') from error


def extract_text(file_name, media_type, content):
    if not isinstance(content, bytes) or not content or len(content) > MAX_FILE_BYTES:
        raise ValueError('Upload a nonempty file no larger than 10 MB')
    if media_type not in MEDIA_TYPES:
        raise ValueError('Upload a PDF, Word, PowerPoint, HTML, plain-text, or Markdown file')
    if (not isinstance(file_name, str) or not file_name or len(file_name) > 255
            or '/' in file_name or '\\' in file_name or file_name in ('.', '..') or '\x00' in file_name):
        raise ValueError('Invalid file name')
    if EXTENSIONS.get('.' + file_name.rsplit('.', 1)[-1].lower()) != media_type:
        raise ValueError('File name and format do not match')
    if media_type == 'application/pdf':
        try:
            reader = PdfReader(BytesIO(content), strict=True)
            if reader.is_encrypted:
                raise ValueError('Encrypted PDFs are not supported')
            text = '\n\n'.join(page.extract_text() or '' for page in reader.pages)
        except PyPdfError as error:
            raise ValueError('The PDF could not be read') from error
    elif media_type.startswith('application/vnd.openxmlformats-officedocument.'):
        text = _office_text(content, 'wordprocessingml' in media_type)
    elif media_type == 'text/html':
        parser = _HTMLText()
        parser.feed(content.decode('utf-8'))
        text = ''.join(parser.parts)
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
