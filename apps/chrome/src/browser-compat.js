const PDF_MIME_TYPE = 'application/pdf';

export async function isBraveBrowser(navigatorApi = globalThis.navigator) {
  const brave = navigatorApi?.brave;
  if (typeof brave?.isBrave === 'function') {
    try {
      if (await brave.isBrave()) return true;
    } catch {}
  }
  return Array.isArray(navigatorApi?.userAgentData?.brands)
    && navigatorApi.userAgentData.brands.some(({ brand }) => /brave/i.test(String(brand || '')));
}

export async function configurePdfMimeHandling(
  chromeApi = globalThis.chrome,
  navigatorApi = globalThis.navigator
) {
  const setOptions = chromeApi?.mimeHandler?.setMimeHandlerOptions;
  const brave = await isBraveBrowser(navigatorApi);
  if (typeof setOptions !== 'function') {
    return { brave, mimeHandlerConfigured: false, mimeHandlerEnabled: false };
  }
  try {
    // The reader now uses per-tab storage instead of the History API calls
    // that crash Chromium MIME frames. Enable browsers exposing this API;
    // browsers without it keep the standalone reader.
    const enabled = true;
    await setOptions.call(chromeApi.mimeHandler, PDF_MIME_TYPE, { enabled });
    return { brave, mimeHandlerConfigured: true, mimeHandlerEnabled: enabled };
  } catch {
    return { brave, mimeHandlerConfigured: false, mimeHandlerEnabled: false };
  }
}
