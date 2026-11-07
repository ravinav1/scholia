"""Small, inert documents for the native import integration check."""
import base64
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')

def archive(name, parts):
    with zipfile.ZipFile(root / name, 'w', zipfile.ZIP_DEFLATED) as z:
        for path, data in parts.items():
            z.writestr(path, data)

archive('lecture.docx', {
    'word/document.xml': '<w:document xmlns:w="urn:word" xmlns:a="urn:drawing" xmlns:r="urn:rels"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Eigenvectors and geometry</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Direction</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Scale</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Horizontal</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><a:blip r:embed="figure"/></w:r></w:p></w:body></w:document>',
    'word/_rels/document.xml.rels': '<Relationships><Relationship Id="figure" Target="media/figure.png"/></Relationships>',
    'word/media/figure.png': png,
})
archive('slides.pptx', {
    'ppt/presentation.xml': '<p:presentation xmlns:p="urn:ppt" xmlns:r="urn:rels"><p:sldIdLst><p:sldId r:id="second"/><p:sldId r:id="first"/></p:sldIdLst></p:presentation>',
    'ppt/_rels/presentation.xml.rels': '<Relationships><Relationship Id="first" Target="slides/slide1.xml"/><Relationship Id="second" Target="/ppt/slides/slide2.xml"/></Relationships>',
    'ppt/slides/slide1.xml': '<slide><p><t>Taught second</t></p></slide>',
    'ppt/slides/slide2.xml': '<slide xmlns:a="urn:drawing" xmlns:r="urn:rels"><p><t>Taught first</t></p><a:blip r:embed="img"/></slide>',
    'ppt/slides/_rels/slide2.xml.rels': '<Relationships><Relationship Id="img" Target="../media/figure.png"/></Relationships>',
    'ppt/media/figure.png': png,
})
archive('measurements.xlsx', {
    'xl/workbook.xml': '<workbook xmlns:r="urn:rels"><sheets><sheet name="Measurements" r:id="sheet"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="sheet" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/sharedStrings.xml': '<sst><si><t>Sample</t></si></sst>',
    'xl/worksheets/sheet1.xml': '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="D1"><v>12</v></c></row><row r="2"><c r="D2"><f>SUM(D1:D1)</f><v>12</v></c></row></sheetData></worksheet>',
})
archive('unsafe.docx', {'../escape.xml': 'not extracted', 'word/document.xml': '<document/>'})
archive('entities.docx', {'word/document.xml': '<!DOCTYPE document [<!ENTITY file SYSTEM "file:///etc/passwd">]><document>&file;</document>'})
archive('reading.odt', {'content.xml': '<document><p>A plain OpenDocument reading.</p></document>'})
(root / 'analysis.py').write_text('def solve(x):\n    return x * 2\n' + '\n'.join(f'# line {i}' for i in range(159)))
(root / 'lab.ipynb').write_text(json.dumps({
    'nbformat': 4, 'metadata': {'language_info': {'name': 'python'}}, 'cells': [
        {'cell_type': 'markdown', 'source': ['# Matrix experiment\n', 'Read the saved results.']},
        {'cell_type': 'code', 'source': ['print("not executed")'], 'outputs': [
            {'output_type': 'stream', 'text': ['Saved result: 42\n']},
            {'output_type': 'display_data', 'data': {'image/png': base64.b64encode(png).decode(), 'text/plain': '<saved plot>'}},
        ]},
    ],
}))
(root / 'legacy.doc').write_bytes(b'Original retained for Quick Look')
