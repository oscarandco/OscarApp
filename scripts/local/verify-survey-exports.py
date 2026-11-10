"""Read-only validation of downloads produced by the survey browser check."""
import json
import pathlib
import re
import zipfile

import openpyxl
from pypdf import PdfReader

root = pathlib.Path(__file__).resolve().parents[2]
evidence = root / 'local-db.local'
expected = json.loads((evidence / 'survey-export-test-expectations.json').read_text(encoding='utf-8'))
literal = expected['extraAnswers'][expected['questionIds'][5]]

def all_text(workbook):
    return '\n'.join(str(cell.value) for sheet in workbook for row in sheet for cell in row if cell.value is not None)

for identity in ('named', 'randomised'):
    path = evidence / f'survey-export-{identity}.xlsx'
    workbook = openpyxl.load_workbook(path, data_only=False)
    assert workbook.sheetnames == ['Summary', 'Responses', 'Questions']
    responses = workbook['Responses']
    assert responses.max_row == 3, 'Two submitted people, no drafts/non-respondents'
    assert responses.max_column == (9 if identity == 'named' else 7)
    assert responses.freeze_panes == 'B2'
    text = all_text(workbook)
    assert '\u2014' not in text
    for person_id in expected['ids']:
        assert person_id not in text, 'No account IDs in exports'
    assert workbook['Summary']['E9'].value == 3
    assert workbook['Summary']['F9'].value == 3
    assert workbook['Summary']['H9'].value == 50
    assert workbook['Summary']['E10'].value == 7
    for sheet in workbook:
        for row in sheet:
            assert all(cell.data_type != 'f' for cell in row), 'Raw text must never become a formula'
    if identity == 'named':
        for value in expected['names'] + expected['emails']:
            assert value in text
        assert literal in text
        assert set(responses.cell(i, 6).value for i in (2, 3)) == {True, False}
        assert set(responses.cell(i, 4).value for i in (2, 3)) == {2, 4}
    else:
        for value in expected['names'] + expected['emails']:
            assert value not in text
        assert 'More hands-on practice.' not in text
        assert literal not in text
        assert {responses['A2'].value, responses['A3'].value} == {'Response 001', 'Response 002'}
        assert responses['G2'].value == '[Written answer excluded]'
        assert responses['G3'].value == '[Written answer excluded]'
        with zipfile.ZipFile(path) as archive:
            xml = '\n'.join(archive.read(name).decode('utf-8') for name in archive.namelist() if name.endswith('.xml'))
            for value in expected['names'] + expected['emails'] + expected['ids']:
                assert value not in xml, 'No hidden identity mapping or metadata'
    pdf = PdfReader(evidence / f'survey-export-{identity}.pdf')
    pdf_text = re.sub(r'\s+', ' ', ' '.join(page.extract_text() for page in pdf.pages))
    assert len(pdf.pages) >= 3
    assert '\u2014' not in pdf_text
    for person_id in expected['ids']:
        assert person_id not in pdf_text
    for value in expected['names'] + expected['emails']:
        assert (value in pdf_text) == (identity == 'named'), f'PDF identity: {value}'
    if identity == 'named':
        assert 'whānau' in pdf_text, 'Macrons must survive PDF rendering/extraction'
        assert '=HYPERLINK' in pdf_text
    else:
        assert 'Response 001' in pdf_text and 'Response 002' in pdf_text
        assert 'More hands-on practice.' not in pdf_text and '=HYPERLINK' not in pdf_text
    print(f'PASS: {identity} XLSX/PDF, full raw values, identity fields, literals, statistics, Unicode and no em dashes')

long_path = evidence / 'survey-export-long.pdf'
if long_path.exists():
    long_pdf = PdfReader(long_path)
    long_text = ' '.join(page.extract_text() for page in long_pdf.pages)
    assert 'END-OF-COMMENT' in long_text, 'The final part of a long comment must survive pagination'
    assert 'Q12.' in long_text
    assert '(continued)' in long_text, 'Continuation pages need respondent context'
    assert '\u2014' not in long_text
    print(f'PASS: {len(long_pdf.pages)}-page long-question/long-answer PDF retains the final answer and continuation labels')

(evidence / 'survey-export-verification.log').write_text('PASSED: named/randomised XLSX and PDF checks, raw types and values, no formulas, privacy metadata, correct statistics, Unicode, and no em dashes.\n', encoding='utf-8')
