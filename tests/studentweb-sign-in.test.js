import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DOMParser } from 'linkedom';

const source = readFileSync(new URL('../apps/macos/Sources/ScholiaMac/StudentwebResultsConnection.swift', import.meta.url), 'utf8');
const script = source.match(/static let signInScript = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const start = new Function('document', 'location', script);
// Fabricated JSF state. No credentials, real view state or authentication tokens.
const form = '<section class="login-name-feide"><form method="post" action="/studentweb/login.jsf">'
  + '<input type="hidden" name="javax.faces.ViewState" value="SYNTHETIC_STATE">'
  + '<a class="link" href="#">Feide</a></form></section>';

function attempt(html = form, url = 'https://fsweb.no/studentweb/login.jsf?inst=FSNTNU') {
  const document = new DOMParser().parseFromString(`<html><body>${html}</body></html>`, 'text/html');
  let clicks = 0;
  for (const a of document.querySelectorAll('a')) a.addEventListener('click', () => clicks++);
  const result = start(document, new URL(url));
  return { result, clicks };
}

test('one-click sign-in invokes only the official Feide form handler', () => {
  assert.deepEqual(attempt(), { result: true, clicks: 1 });
  assert.doesNotMatch(script, /fetch\s*\(|XMLHttpRequest|\.value\b|FormData|document\.cookie|localStorage|sessionStorage|eval\s*\(|console\./);
});

test('changed, ambiguous, foreign and credential forms never get submitted automatically', () => {
  for (const html of [
    '', form + form, form.replace('method="post"', 'method="get"'),
    form.replace('action="/studentweb/login.jsf"', 'action="https://evil.test/studentweb/login.jsf"'),
    form.replace('action="/studentweb/login.jsf"', 'action="/studentweb/other.jsf"'),
    form.replace('action="/studentweb/login.jsf"', 'action="/studentweb/login.jsf?redirect=other"'),
    form.replace('method="post"', 'method="post" target="_blank"'),
    form.replace('type="hidden"', 'type="password"'),
    form.replace('</form>', '<textarea></textarea></form>'),
    form.replace('href="#"', 'href="/somewhere"'),
    form.replace('</form>', '<a class="link" href="#">Second action</a></form>'),
  ]) assert.deepEqual(attempt(html), { result: false, clicks: 0 });
  for (const url of [
    'http://fsweb.no/studentweb/login.jsf', 'https://fsweb.no.evil.test/studentweb/login.jsf',
    'https://fsweb.no/studentweb/resultater.jsf', 'https://fsweb.no:444/studentweb/login.jsf',
    'https://user:password@fsweb.no/studentweb/login.jsf',
  ]) assert.deepEqual(attempt(form, url), { result: false, clicks: 0 });
});
