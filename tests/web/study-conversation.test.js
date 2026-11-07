import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { StudyConversation } from '../../apps/web/chat/study-conversation.js';
import { conversationScope, courseCoverage } from '../../apps/web/workspace/study-session.js';

test('empty chat changes its starters when navigating between whole-course and reading scope', () => {
  const { document } = parseHTML('<div id="messages"></div>');
  const host = document.querySelector('#messages');
  const view = new StudyConversation(host);
  const state = {
    library: { courses: [], selectedThreadID: null },
    messages: [],
    contextScope: 'course',
  };
  view.render(state);
  assert.equal(host.querySelectorAll('[data-course-prompt]').length, 3);
  state.contextScope = 'document';
  view.render(state);
  assert.equal(host.querySelectorAll('[data-course-prompt]').length, 0);
  assert.equal(host.querySelectorAll('[data-study-prompt]').length, 3);
  state.contextScope = 'course';
  view.render(state);
  assert.match(host.textContent, /Your whole course/);
  state.mode = 'General';
  view.render(state);
  assert.match(host.textContent, /What’s on your mind/);
  assert.equal(host.querySelectorAll('[data-course-prompt]').length, 0);
  assert.equal(host.querySelector('[data-study-prompt]').dataset.studyPrompt, 'General');
  state.mode = 'Explain';
  view.render(state);
  assert.match(host.textContent, /Your whole course/);
  state.automaticContextEnabled = false;
  view.render(state);
  assert.match(host.textContent, /Automatic reading and course context is off/);
  assert.doesNotMatch(host.textContent, /Your whole course/);
});

test('coverage distinguishes remote titles, saved originals and readable sources', () => {
  assert.equal(
    courseCoverage({ documents: [], canvasMaterials: [{ id: 'remote' }] }),
    '0 saved readings with text · 1 material with titles only until opened.'
  );
  const course = {
    id: 'course',
    documents: [
      { sourceKey: 'saved', kind: 'text', pageCount: 1 },
      { sourceKey: 'original', kind: 'preview', pageCount: 1 },
    ],
    canvasMaterials: [{ id: 'saved' }, { id: 'original' }, { id: 'remote' }],
    threads: [{ id: 'thread', documentID: null, assignmentID: null }],
  };
  assert.match(courseCoverage(course), /^1 saved reading with text · 1 material/);
  assert.equal(
    conversationScope({
      library: {
        courses: [course],
        selectedCourseID: 'course',
        selectedThreadID: 'thread',
        selectedDocumentID: 'citation',
      },
    }),
    'course'
  );
});

test('a conversation loading its renderer follows the latest thread', async () => {
  const { document } = parseHTML('<div id="messages"></div>');
  const view = new StudyConversation(document.querySelector('#messages'));
  view.render({ library: { selectedThreadID: 'old' }, messages: [{ id: 'old', role: 'assistant', content: 'Old answer' }] });
  view.render({ library: { selectedThreadID: 'new' }, messages: [{ id: 'new', role: 'assistant', content: '**New answer**' }] });
  await view.ready;
  assert.equal(view.host.querySelector('[data-message-id="old"]'), null);
  assert.equal(view.host.querySelector('strong').textContent, 'New answer');
});

test('streaming keeps unchanged message sections, disclosures and older messages alive', async () => {
  const { document } = parseHTML('<div id="messages"></div>');
  const host = document.querySelector('#messages');
  const view = new StudyConversation(host);
  const message = {
    id: 'answer', role: 'assistant', content: 'Initial answer', reasoning: 'Checking **evidence**',
    isStreaming: true, metadata: 'Thinking', activity: [{ title: 'Reading', detail: 'Page 1' }],
  };
  const state = {
    library: { selectedThreadID: 'thread' }, streaming: true,
    messages: [{ id: 'question', role: 'user', content: 'Question' }, message],
    sources: { answer: [{ documentID: 'doc', page: 1, title: 'Lecture notes' }] },
    answerStartedAt: Date.now() / 1000 - 2,
  };
  view.render(state);
  await view.ready;
  const question = host.querySelector('[data-message-id="question"] p');
  const answer = host.querySelector('[data-message-id="answer"]');
  const content = answer.querySelector('[data-message-part="content"] p');
  const reasoning = answer.querySelector('[data-detail="reasoning"]');
  const sources = answer.querySelector('[data-detail="sources"]');
  const actions = answer.querySelector('.message-actions');
  reasoning.open = true;
  sources.open = true;
  message.metadata = 'Reading more';
  message.activity.push({ title: 'Found evidence' });
  view.render(state);
  assert.equal(answer.querySelector('[data-message-part="content"] p'), content);
  assert.equal(answer.querySelector('[data-detail="reasoning"]'), reasoning);
  assert.equal(answer.querySelector('[data-detail="sources"]'), sources);
  assert.equal(reasoning.open, true);
  assert.equal(sources.open, true);
  assert.match(answer.querySelector('.chat-activity').textContent, /Found evidence/);

  message.content += ' and another token';
  view.render(state);
  assert.match(answer.querySelector('[data-message-part="content"]').textContent, /another token/);
  assert.equal(answer.querySelector('[data-detail="reasoning"]'), reasoning);
  assert.equal(answer.querySelector('.message-actions'), actions);
  assert.equal(host.querySelector('[data-message-id="question"] p'), question);

  message.isStreaming = false;
  state.streaming = false;
  view.render(state);
  assert.equal(answer.querySelector('.generation-progress'), null);
  assert.ok(host.querySelector('[data-action="edit"]'));
});
