"""Extraction previews use the same parser as stored evidence."""
from io import BytesIO
from zipfile import ZipFile

import pytest

from kc.sources import extract_text


def office_file(name, xml):
    buffer = BytesIO()
    with ZipFile(buffer, 'w') as archive:
        archive.writestr(name, xml)
    return buffer.getvalue()


def test_word_text():
    content = office_file('word/document.xml',
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>Review</w:t></w:r><w:r><w:t>requests</w:t></w:r></w:p></w:body></w:document>')
    assert extract_text('policy.docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document', content) == 'Review requests'


def test_powerpoint_text():
    content = office_file('ppt/slides/slide1.xml',
        '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:t>Customer objection</a:t><a:t>Pricing</a:t></p:sld>')
    assert extract_text('sales.pptx',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation', content) == 'Customer objection Pricing'


def test_saved_html_omits_scripts_and_style():
    html = b'<h1>Policy</h1><script>secretCode()</script><style>.x{}</style><p>Confirm owner.</p>'
    text = extract_text('policy.html', 'text/html', html)
    assert 'Policy' in text and 'Confirm owner.' in text
    assert 'secretCode' not in text and '.x' not in text


@pytest.mark.parametrize(('name', 'media'), [
    ('broken.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
    ('broken.pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'),
])
def test_broken_office_rejected(name, media):
    with pytest.raises(ValueError):
        extract_text(name, media, b'not a zip')


def test_file_extension_must_match_format():
    with pytest.raises(ValueError, match='do not match'):
        extract_text('disguised.exe', 'text/html', b'<p>Unexpected</p>')
