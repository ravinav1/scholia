import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeMaterial } from '../apps/server/material-analysis.js';
import { materialInventory, Workspaces } from '../apps/server/workspaces.js';
import { parseOCR, sparseText } from '../apps/server/document-ocr.js';

const classify = (name, text, extra = {}) =>
  analyzeMaterial({ name, pages: [{ number: 1, text, ...extra }] });

test('content headings outweigh misleading filenames and yield a specific topic', () => {
  const result = classify(
    'lecture-3.pdf',
    '# Final exam: Linear algebra\nTime allowed: three hours\nPermitted aids: none.'
  );
  assert.equal(result.categoryID, 'exams');
  assert.equal(result.topic, 'Linear algebra');
  assert.equal(result.classificationConfidence, 'high');
  assert.equal(result.extractionMethod, 'text');
  assert.match(result.classificationBasis, /Document text/);
  assert.equal(
    classify('scan.pdf', '# TMA4115 / LECTURE NOTES\n## Linear transformations').topic,
    'Linear transformations'
  );
  assert.equal(
    classify('final-exam.pdf', '# Exam solutions\nWorked answers for the final exam').categoryID,
    'solutions'
  );
});

test('filename-only and ambiguous evidence remain visibly tentative', () => {
  const unknown = classify('scan-003.pdf', '');
  assert.equal(unknown.categoryID, 'documents');
  assert.equal(unknown.extractionMethod, 'none');
  assert.equal(unknown.topic, undefined);
  const filename = classify('Lecture_03.pdf', '');
  assert.equal(filename.categoryID, 'lectures');
  assert.equal(filename.classificationConfidence, 'low');
  assert.match(filename.classificationBasis, /unverified/);
  assert.equal(classify('misc.pdf', '# Lecture and exam').categoryID, 'documents');
  assert.equal(classify('archive.zip', '').categoryID, 'documents');
  assert.equal(
    classify(
      'scan.pdf',
      '# A solution to the heat equation\nSeparation of variables on a bounded domain'
    ).categoryID,
    'documents'
  );
  const mathematics = classify(
    'scan.pdf',
    '# Solutions of differential equations\nExistence and uniqueness for initial value problems'
  );
  assert.equal(mathematics.categoryID, 'documents');
  assert.equal(mathematics.topic, 'Solutions of differential equations');
});

test('OCR evidence can classify scans but unreliable OCR cannot invent a category or topic', () => {
  const text = '# Handwritten notes: Eigenvectors\nLinear transformations preserve vector spaces';
  const reliable = classify('scan.png', text, { extractionMethod: 'ocr', ocrConfidence: 0.9 });
  assert.equal(reliable.categoryID, 'notes');
  assert.equal(reliable.topic, 'Eigenvectors');
  assert.equal(reliable.extractionMethod, 'ocr');
  assert.match(reliable.classificationBasis, /Locally recognized/);
  const uncertain = classify('scan.png', text, { extractionMethod: 'ocr', ocrConfidence: 0.2 });
  assert.equal(uncertain.categoryID, 'documents');
  assert.equal(uncertain.topic, undefined);
  assert.equal(
    classify('logo.png', '# Lecture notes\nEigenvectors and matrices').categoryID,
    'notes'
  );
});

test('formats identify source code and structured data without mistaking code for headings', () => {
  assert.equal(classify('parameters.csv', 'alpha,beta\n1,2').categoryID, 'data');
  const code = classify('simulation.py', 'from numpy import array\n# Lecture notes');
  assert.equal(code.categoryID, 'code');
  assert.notEqual(code.topic, 'from numpy import array');
});

test('Canvas modules preserve ordering while saved content provides category and topic metadata', () => {
  const document = {
    id: 'a',
    title: 'scan',
    fileName: 'scan.pdf',
    pageCount: 1,
    sourceKey: 'files:1',
    materialAnalysis: classify('scan.pdf', '# Lecture 3: Eigenvectors\nMatrix diagonalization'),
  };
  const inventory = materialInventory({
    documents: [document],
    canvasMaterials: [
      {
        id: 'files:1',
        kind: 'files',
        title: 'scan',
        moduleID: '7',
        moduleTitle: 'Week 7',
        modulePosition: 1,
        moduleItemPosition: 2,
      },
      {
        id: 'assignments:2',
        kind: 'assignments',
        title: 'Assessment',
        assignment: { status: 'graded', grade: 'A' },
        moduleID: '7',
        moduleTitle: 'Week 7',
        modulePosition: 1,
        moduleItemPosition: 1,
      },
    ],
  });
  assert.equal(inventory.groups[0].id, 'module:7');
  assert.equal(inventory.groups[0].items[0].assignment.grade, 'A');
  assert.equal(inventory.groups[0].items[1].categoryID, 'lectures');
  assert.equal(inventory.groups[0].items[1].topic, 'Eigenvectors');
  assert.equal(inventory.files.length, 1);
});

test('local OCR parser preserves lines, filters uncertain words and rejects noise', () => {
  const header =
    'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext';
  const row = (line, word, confidence) =>
    `5\t1\t1\t1\t${line}\t1\t0\t0\t10\t10\t${confidence}\t${word}`;
  const result = parseOCR(
    [
      header,
      row(1, 'Lecture', 95),
      row(1, 'notes', 90),
      row(2, 'Eigenvectors', 94),
      row(2, 'garbled', 10),
    ].join('\n')
  );
  assert.equal(result.text, 'Lecture notes\nEigenvectors');
  assert.ok(result.confidence > 0.9);
  assert.equal(parseOCR([header, row(1, 'gibberish', 20)].join('\n')).text, '');
  assert.equal(sparseText('Page 1'), true);
  assert.equal(sparseText('This is a fully readable paragraph. '.repeat(8)), false);
});

test('background classification cannot replace analysis for a newer document revision', async () => {
  let release;
  const indexes = new Promise((resolve) => {
    release = resolve;
  });
  let saves = 0;
  const workspaces = new Workspaces({ save: () => saves++ }, { index: () => indexes });
  const document = { id: 'doc', fileName: 'scan.pdf', contentHash: 'old', indexVersion: 2 };
  const account = { id: 'user' },
    course = { id: 'course', documents: [document] };
  const pending = workspaces.analyzeStoredMaterials(account, course);
  assert.equal(account.analysisPending, 1);
  document.contentHash = 'new';
  document.materialAnalysis = classify('scan.pdf', '# Study notes\n## Eigenvectors');
  release({ pages: [{ number: 1, text: '# Final exam\nTime allowed: three hours' }] });
  await pending;
  assert.equal(document.materialAnalysis.categoryID, 'notes');
  assert.equal(saves, 0);
  assert.equal(account.analysisPending, 0);
});

test('distributed recognized pages participate in content classification', () => {
  const pages = Array.from({ length: 60 }, (_, i) => ({ number: i + 1, text: '' }));
  pages[20] = {
    number: 21,
    text: '# Study notes\n## Eigenvectors',
    extractionMethod: 'ocr',
    ocrConfidence: 0.9,
  };
  const result = analyzeMaterial({ name: 'scan.pdf', pages });
  assert.equal(result.categoryID, 'notes');
  assert.equal(result.topic, 'Eigenvectors');
  assert.equal(result.extractionMethod, 'ocr');
});
