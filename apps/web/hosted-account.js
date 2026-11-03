import { escapeHtml as esc } from '../chrome/src/html-escape.js';

export function installHostedAccount({ request, notify, update }) {
  if (!document.querySelector('meta[name="scholia-hosted"]')) return () => {};
  document.documentElement.classList.add('hosted');
  const companion = document.querySelector('.companion');
  companion.innerHTML = '<span class="online-dot"></span><span>Private account</span>';
  const controls = document.querySelector('.sidebar-tools');
  const shortcutHelp = controls.querySelector('[data-action="keyboardShortcuts"]');
  controls.innerHTML =
    '<button id="account-settings">Account settings</button><button id="sign-out">Sign out</button>';
  if (shortcutHelp) controls.insertBefore(shortcutHelp, controls.lastElementChild);
  const dialog = document.createElement('dialog');
  dialog.setAttribute('aria-label', 'Account settings');
  dialog.innerHTML =
    '<form method="dialog" class="dialog-heading"><h2>Account settings</h2><button aria-label="Close">×</button></form><p class="account-email"></p><form id="provider-settings"><label class="field">AI provider<select name="providerID" required></select></label><label class="field">Your API key<input name="key" type="password" autocomplete="off" required maxlength="4096"></label><p>Your key is stored encrypted on this server and is used only for your account.</p><button type="submit" class="primary">Save provider key</button></form>';
  document.body.append(dialog);
  document.querySelector('#account-settings').onclick = () => dialog.showModal();
  document.querySelector('#sign-out').onclick = async () => {
    try {
      await request('/auth/logout', {});
      for (const key of Object.keys(sessionStorage))
        if (key.startsWith('scholia.')) sessionStorage.removeItem(key);
      location.replace('/login');
    } catch (error) {
      notify(error.message);
    }
  };
  dialog.querySelector('#provider-settings').onsubmit = async (event) => {
    event.preventDefault();
    const form = event.target,
      button = form.querySelector('button');
    button.disabled = true;
    try {
      const next = await request('/api/action', {
        action: 'credentials',
        ...Object.fromEntries(new FormData(form)),
      });
      update(next);
      form.elements.key.value = '';
      dialog.close();
      notify('Provider settings saved.');
    } catch (error) {
      notify(error.message);
    } finally {
      button.disabled = false;
    }
  };
  const canvas = document.querySelector('#canvas-dialog');
  canvas.querySelector('[value=all]').closest('label').querySelector('small').textContent =
    'Save supported course materials to your private account. You can stop and resume.';
  canvas.querySelector('h2').textContent = 'Connect your Canvas account.';
  canvas.querySelector('details').open = true;
  canvas.querySelector('details summary').textContent = 'Personal access token';
  canvas.querySelector('details p').textContent =
    'Create a Canvas access token in Account → Settings and paste it below. It belongs only to your Scholia account.';
  canvas.querySelector('.fineprint').textContent =
    'Scholia reads your Canvas courses and files. It does not submit assignments or change Canvas.';
  return (state) => {
    const select = dialog.querySelector('select'),
      providers = new Map(state.models.map((m) => [m.providerID, m.provider]));
    if (!select.options.length)
      select.innerHTML = [...providers]
        .map(([id, name]) => `<option value="${esc(id)}">${esc(name)}</option>`)
        .join('');
    if (!dialog.open) select.value = state.providerID;
    dialog.querySelector('.account-email').textContent = state.account?.email || '';
    document.querySelector('#review-due').hidden = false;
    document.querySelector('#practice-this').hidden = state.showingLibrary || !state.library.selectedCourseID;
  };
}
