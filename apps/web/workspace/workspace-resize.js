export function installTutorResize(workspace, divider) {
  const key = 'scholia.tutorWidth';
  let preferred = null,
    dragging = false;
  try {
    const value = Number(localStorage.getItem(key));
    if (Number.isFinite(value) && value >= 220) preferred = value;
  } catch {}
  const tutor = workspace.querySelector('.tutor');
  const bounds = () => ({ min: 220, max: Math.max(220, workspace.clientWidth - 86) });
  function apply() {
    if (!workspace.clientWidth) return;
    const { min, max } = bounds();
    if (preferred !== null)
      workspace.style.setProperty('--tutor-width', `${Math.max(min, Math.min(max, preferred))}px`);
    else workspace.style.removeProperty('--tutor-width');
    const width = tutor.getBoundingClientRect().width;
    divider.setAttribute('aria-valuemin', String(min));
    divider.setAttribute('aria-valuemax', String(Math.round(max)));
    divider.setAttribute('aria-valuenow', String(Math.round(width)));
    divider.setAttribute(
      'aria-valuetext',
      `AI chat uses ${Math.round((width / workspace.clientWidth) * 100)}% of the workspace`
    );
  }
  function save() {
    try {
      if (preferred === null) localStorage.removeItem(key);
      else localStorage.setItem(key, String(preferred));
    } catch {}
  }
  function resize(width) {
    const { min, max } = bounds();
    preferred = Math.max(min, Math.min(max, width));
    apply();
  }
  divider.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    dragging = true;
    divider.setPointerCapture(event.pointerId);
    workspace.classList.add('resizing-chat');
    event.preventDefault();
  });
  window.addEventListener('pointermove', (event) => {
    if (dragging)
      resize(workspace.getBoundingClientRect().right - event.clientX - divider.clientWidth / 2);
  });
  const finish = () => {
    if (!dragging) return;
    dragging = false;
    workspace.classList.remove('resizing-chat');
    save();
  };
  window.addEventListener('pointerup', finish);
  window.addEventListener('pointercancel', finish);
  window.addEventListener('blur', finish);
  divider.addEventListener('dblclick', () => {
    preferred = null;
    apply();
    save();
  });
  divider.addEventListener('keydown', (event) => {
    const { min, max } = bounds(),
      width = tutor.getBoundingClientRect().width,
      step = event.shiftKey ? 100 : 20;
    const value = { ArrowLeft: width + step, ArrowRight: width - step, Home: min, End: max }[
      event.key
    ];
    if (value === undefined) return;
    event.preventDefault();
    resize(value);
    save();
  });
  new ResizeObserver(apply).observe(workspace);
  apply();
}
