import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_MAIL_REPLY_QUESTION,
  formatMailThread,
  isWebmailLocation,
  mailContextForSelection
} from '../../apps/chrome/src/mail-context.js';

function textElement(text, attributes = {}) {
  return {
    innerText: text,
    textContent: text,
    getAttribute: (name) => attributes[name] || '',
    querySelector: () => null,
    querySelectorAll: () => [],
    matches: () => false,
    contains: () => false
  };
}

test('webmail detection covers supported mail apps without classifying ordinary articles as mail', () => {
  assert.equal(isWebmailLocation('https://mail.google.com/mail/u/0/#inbox/thread'), true);
  assert.equal(isWebmailLocation('https://outlook.office.com/mail/inbox/id/example'), true);
  assert.equal(isWebmailLocation('https://app.proton.me/mail/u/0/inbox'), true);
  assert.equal(isWebmailLocation('https://example.test/article-about-email'), false);
});

test('mail threads are explicitly delimited, structured, deduplicated, and attachment-safe', () => {
  const context = formatMailThread([
    {
      sender: 'Ari <ari@example.test>',
      recipients: 'Team',
      date: '2026-08-30 10:15',
      body: 'Can you send the revised schedule by Tuesday?',
      attachments: ['schedule-v2.pdf'],
      selected: true
    },
    {
      sender: 'Ari <ari@example.test>',
      body: 'Can you send the revised schedule by Tuesday?'
    },
    {
      sender: 'Me',
      body: 'I will check the remaining dates.'
    }
  ], { subject: 'Project schedule', selectedText: 'revised schedule' });

  assert.match(context, /<scholia-mail-thread>/);
  assert.match(context, /Subject: Project schedule/);
  assert.match(context, /contains selected passage/);
  assert.match(context, /Attachments \(names only\): schedule-v2\.pdf/);
  assert.equal((context.match(/Can you send the revised schedule by Tuesday\?/g) || []).length, 1);
  assert.match(context, /<\/scholia-mail-thread>$/);
});

test('a selected Gmail-style message produces only its surrounding thread context', () => {
  const senderOne = textElement('Ari', { email: 'ari@example.test' });
  const senderTwo = textElement('Me', { email: 'me@example.test' });
  const recipient = textElement('to me');
  const dateOne = textElement('Aug 30, 10:15', { title: 'Aug 30, 2026, 10:15' });
  const dateTwo = textElement('Aug 30, 10:22', { title: 'Aug 30, 2026, 10:22' });
  const bodyOne = textElement('Could you confirm the revised deadline?');
  const bodyTwo = textElement('I am checking the project calendar now.');
  const attachment = textElement('timeline.pdf', { download: 'timeline.pdf' });
  const subject = textElement('Revised project deadline');

  const makeMessage = ({ sender, date, body, attachments = [] }) => ({
    parentElement: null,
    matches: () => false,
    contains: (value) => value === body,
    querySelector: (selector) => {
      if (selector === '.a3s') return body;
      if (selector === '.hb') return recipient;
      if (selector === 'time[datetime]') return date;
      return null;
    },
    querySelectorAll: (selector) => {
      if (selector === '[email], [data-email], [data-hovercard-id]') return [sender];
      if (selector.includes('[download]')) return attachments;
      return [];
    }
  });
  const first = makeMessage({ sender: senderOne, date: dateOne, body: bodyOne, attachments: [attachment] });
  const second = makeMessage({ sender: senderTwo, date: dateTwo, body: bodyTwo });
  const threadRoot = {
    querySelector: (selector) => selector === '.hP' ? subject : null,
    querySelectorAll: (selector) => selector.includes('[data-message-id]') ? [first, second] : []
  };
  first.parentElement = threadRoot;
  second.parentElement = threadRoot;
  const selectedElement = {
    nodeType: 1,
    parentElement: bodyOne,
    closest: (selector) => selector.includes('[role="main"]') ? threadRoot : selector.includes('.adn') ? first : null
  };
  const range = { commonAncestorContainer: selectedElement };

  const mail = mailContextForSelection(range, {
    documentValue: { title: 'Inbox', querySelector: () => null },
    locationValue: 'https://mail.google.com/mail/u/0/#inbox/example',
    selectedText: 'revised deadline'
  });
  assert.equal(mail?.kind, 'mail');
  assert.equal(mail?.subject, 'Revised project deadline');
  assert.equal(mail?.messageCount, 2);
  assert.match(mail?.context || '', /ari@example\.test/);
  assert.match(mail?.context || '', /I am checking the project calendar now\./);
  assert.match(mail?.context || '', /timeline\.pdf/);
  assert.equal(mail?.defaultQuestion, DEFAULT_MAIL_REPLY_QUESTION);
});
