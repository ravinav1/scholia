import { spawn } from 'node:child_process';
import { parentPort } from 'node:worker_threads';

export function sparseText(text) {
  return (String(text || '').match(/\p{L}/gu) || []).length < 70;
}

export function parseOCR(tsv) {
  const lines = new Map();
  let weighted = 0,
    letters = 0;
  for (const row of String(tsv).split('\n').slice(1)) {
    const fields = row.split('\t');
    const confidence = Number(fields[10]),
      word = fields.slice(11).join(' ').trim();
    if (fields[0] !== '5' || !Number.isFinite(confidence) || confidence < 35 || !word) continue;
    const key = fields.slice(1, 5).join(':');
    if (!lines.has(key)) lines.set(key, []);
    lines.get(key).push(word);
    weighted += confidence * word.length;
    letters += word.length;
  }
  const confidence = letters ? weighted / letters / 100 : 0;
  const text = [...lines.values()]
    .map((words) => words.join(' '))
    .join('\n')
    .slice(0, 100_000);
  // Keep uncertain scribbles out of search and classification instead of guessing.
  return {
    text: confidence >= 0.55 && (text.match(/\p{L}/gu) || []).length >= 12 ? text : '',
    confidence,
  };
}

export function recognizeImage(bytes, { timeout = 6000 } = {}) {
  return new Promise((resolve) => {
    if (process.env.SCHOLIA_OCR === 'off')
      return resolve({ text: '', confidence: 0, status: 'disabled' });
    let output = '',
      settled = false;
    const child = spawn(
      process.env.SCHOLIA_TESSERACT || 'tesseract',
      ['stdin', 'stdout', '-l', process.env.SCHOLIA_OCR_LANGUAGES || 'eng', '--psm', '3', 'tsv'],
      { stdio: ['pipe', 'pipe', 'ignore'], env: { ...process.env, OMP_THREAD_LIMIT: '1' } }
    );
    if (child.pid) parentPort?.postMessage({ type: 'ocrChild', event: 'start', pid: child.pid });
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(
      () => {
        child.kill('SIGKILL');
        finish({ text: '', confidence: 0, status: 'timeout' });
      },
      Math.max(1, timeout)
    );
    child.once('error', () => finish({ text: '', confidence: 0, status: 'unavailable' }));
    child.stdin.on('error', () => {});
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      output += chunk;
      if (output.length > 2_000_000) {
        child.kill('SIGKILL');
        finish({ text: '', confidence: 0, status: 'limit' });
      }
    });
    child.once('close', (code) => {
      if (child.pid) parentPort?.postMessage({ type: 'ocrChild', event: 'stop', pid: child.pid });
      finish(
        code === 0
          ? { ...parseOCR(output), status: 'complete' }
          : { text: '', confidence: 0, status: 'failed' }
      );
    });
    child.stdin.end(bytes);
  });
}
