import test from 'node:test';
import assert from 'node:assert/strict';
import {
  closeQuickChatFromSignal,
  toggleQuickChatFromCommandTab
} from '../../apps/chrome/src/browser-commands.js';

test('Quick Chat opens synchronously when no existing panel answers the probe', async () => {
  const calls = [];
  let resolveSignal;
  const probe = new Promise((resolve) => { resolveSignal = resolve; });

  const toggling = toggleQuickChatFromCommandTab({ windowId: 34 }, {
    probePanel() {
      calls.push('probe');
      return probe;
    },
    openForWindow(windowId) {
      calls.push(['open', windowId]);
      return Promise.resolve();
    },
    prepareOpen(windowId) {
      calls.push(['prepare', windowId]);
      return Promise.resolve();
    }
  });

  assert.deepEqual(calls, ['probe', ['open', 34]]);
  resolveSignal(null);
  assert.equal(await toggling, 'opened');
  assert.deepEqual(calls, ['probe', ['open', 34], ['prepare', 34]]);
});

test('Quick Chat waits for the redundant open before closing an existing panel', async () => {
  const calls = [];
  let finishOpening;
  const opening = new Promise((resolve) => { finishOpening = resolve; });

  const toggling = toggleQuickChatFromCommandTab({ windowId: 34 }, {
    probePanel() {
      calls.push('probe');
      return Promise.resolve({ open: true });
    },
    openForWindow(windowId) {
      calls.push(['open', windowId]);
      return opening;
    },
    signalClose() {
      calls.push('close');
      return Promise.resolve({ closed: true });
    },
    prepareOpen() {
      calls.push('prepare');
    }
  });

  await Promise.resolve();
  assert.deepEqual(calls, ['probe', ['open', 34]]);
  finishOpening();
  assert.equal(await toggling, 'closed');
  assert.deepEqual(calls, ['probe', ['open', 34], 'close']);
});

test('Quick Chat ignores an open command without a usable window', () => {
  assert.equal(toggleQuickChatFromCommandTab({}, {
    probePanel() {},
    openForWindow() {}
  }), null);
});

test('Quick Chat can close from a command that omits its tab', async () => {
  assert.equal(await closeQuickChatFromSignal(() => ({ closed: true })), true);
  assert.equal(await closeQuickChatFromSignal(() => Promise.reject(new Error('No panel'))), false);
});

test('repeated toggle commands cannot reopen a panel while its close is settling', async () => {
  let closeCalls = 0;
  let prepareCalls = 0;
  const toggles = Array.from({ length: 50 }, (_, index) => toggleQuickChatFromCommandTab(
    { windowId: 34 },
    {
      probePanel: () => ({ open: true }),
      openForWindow: () => new Promise((resolve) => setTimeout(resolve, index % 4)),
      signalClose: () => {
        closeCalls += 1;
        return { closed: true };
      },
      prepareOpen: () => { prepareCalls += 1; }
    }
  ));

  assert.deepEqual(await Promise.all(toggles), Array(50).fill('closed'));
  assert.equal(closeCalls, 50);
  assert.equal(prepareCalls, 0);
});
