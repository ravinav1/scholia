export function renderResponseLanguage(settings, root = document) {
  for (const select of root.querySelectorAll('[data-response-language]')) {
    select.value = settings?.language || 'auto';
  }
}

export function mountResponseLanguage({ root = document, message, onSettings, onError }) {
  const controls = [...root.querySelectorAll('[data-response-language]')];
  for (const select of controls) {
    select.innerHTML = '<option value="auto">Auto · match prompt</option><option value="en">English</option><option value="no">Norsk bokmål</option>';
    select.addEventListener('change', async () => {
      controls.forEach((control) => { control.disabled = true; });
      try {
        const settings = await message({ type: 'SCHOLIA_SAVE_LANGUAGE', language: select.value });
        onSettings(settings);
        renderResponseLanguage(settings, root);
      } catch (error) {
        onError(error);
        const settings = await message({ type: 'SCHOLIA_GET_PUBLIC_SETTINGS' }).catch(() => null);
        if (settings) renderResponseLanguage(settings, root);
      } finally {
        controls.forEach((control) => { control.disabled = false; });
      }
    });
  }
}
