import Foundation

enum PersonalizationPage {
    // Runs in an isolated WebKit content world. Read only rendered settings;
    // do not scrape chats, page state, cookies, tokens or undocumented APIs.
    // This exact script is exercised against Chromium DOM fixtures.
    static let script = #"""
    const host = location.hostname.toLowerCase();
    const isGPT = ['chatgpt.com', 'chat.openai.com'].includes(host);
    if (location.protocol !== 'https:' || location.username || location.password ||
        (location.port && location.port !== '443') || (!isGPT && host !== 'claude.ai')) return '{}';
    const clean = value => String(value || '').replace(/\r\n?/g, '\n').replace(/[\t ]+/g, ' ').trim();
    const visible = node => {
      for (let el = node; el?.nodeType === 1; el = el.parentElement) {
        const s = getComputedStyle(el);
        if (el.hidden || el.getAttribute('aria-hidden') === 'true' || s.display === 'none' || s.visibility === 'hidden') return false;
      }
      return !!node?.getClientRects().length;
    };
    const text = node => clean(node?.innerText);
    const headings = [...document.querySelectorAll('h1,h2,h3,h4,[role=heading]')].filter(visible);
    const dialogs = [...document.querySelectorAll('[role=dialog],[data-radix-dialog-content]')].filter(visible);
    const settingsDialog = dialogs.find(el => /\bpersonalization\b/i.test(text(el)));
    const onProfile = isGPT
      ? /settings\/personalization/i.test(location.hash) || !!settingsDialog
      : /^\/settings(?:\/profile)?\/?$/.test(location.pathname);
    const onMemory = isGPT
      ? onProfile
      : /^\/settings\/(?:memory|capabilities)\/?$/.test(location.pathname);
    const result = {};
    const pending = value => /^(?:loading|generating|please wait|laster|genererer)(?:\b|[.…])/im.test(value);
    if ([...document.querySelectorAll('input[type=password]')].some(visible) || headings.some(el => /^(?:log in|sign in|verify you are human)$/i.test(text(el)))) return '{}';

    if (action === 'profile' && onProfile) {
      const root = settingsDialog || document.querySelector('main') || document.body;
      const labels = el => {
        const explicit = [...(el.labels || [])].map(text).join(' ');
        const labelled = (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => text(document.getElementById(id))).join(' ');
        return clean([explicit, labelled, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
          text(el.previousElementSibling)].find(value => clean(value)));
      };
      const instructions = [], profile = [];
      let sawInstructions = false, sawProfile = false;
      for (const field of root.querySelectorAll('textarea,input[type=text],input:not([type]),[contenteditable=true],[role=combobox],select')) {
        if (!visible(field) || field.id === 'prompt-textarea') continue;
        const label = labels(field);
        const value = clean(field.value ?? text(field));
        if (/custom instructions|instructions for claude|personal preferences|how (?:would you like|should) (?:chatgpt|claude).*respond|what preferences should claude/i.test(label)) {
          sawInstructions = true;
          if (value) instructions.push(value);
        } else if (/nickname|occupation|about you|more about|what (?:would you like|should) (?:chatgpt|claude).*know|what should (?:chatgpt|claude) call you|base style and tone|characteristics|full name|preferred name/i.test(label)) {
          sawProfile = true;
          if (value) profile.push(`${label.slice(0, 180)}: ${value}`);
        }
      }
      if (sawInstructions) result.instructions = [...new Set(instructions)].join('\n\n');
      if (sawProfile) result.profile = [...new Set(profile)].join('\n');
      return JSON.stringify(result);
    }

    if (!onMemory) return '{}';
    const memoryTitle = /^(?:manage memories|saved memories|memories|memory summary|view and edit (?:your )?memory|your memory|memory)$/i;
    const manage = [...document.querySelectorAll('button,[role=button],a[href]')].filter(visible).find(el => {
      const label = clean(el.getAttribute('aria-label') || text(el));
      if (/^(?:manage (?:saved )?memories|view (?:and edit )?(?:your )?memor(?:y|ies))$/i.test(label)) return true;
      const nearby = text(el.parentElement);
      return /^manage$/i.test(label) && nearby.length < 1_500 && /memory|memories/i.test(nearby);
    });
    if (action === 'openMemory') {
      if (manage) { manage.click(); return '{"opened":true}'; }
      return '{}';
    }
    if (action !== 'memory') return '{}';
    const title = headings.find(el => memoryTitle.test(text(el)) && (el.closest('[role=dialog],[data-radix-dialog-content]') || !isGPT));
    // The Memory card on Personalization is never a memory snapshot.
    if (!title) return '{}';
    let root = title.closest('[role=dialog],[data-radix-dialog-content]') || title.parentElement;
    if (!root || (manage && root.contains(manage))) return '{}';
    if (pending(text(root)) || [...root.querySelectorAll('[aria-busy=true],[role=progressbar]')].some(visible)) return '{}';
    if (root.querySelector('input[type=search]')?.value || [...root.querySelectorAll('input')].some(el => /search/i.test(el.placeholder || el.getAttribute('aria-label') || '') && el.value)) return '{}';
    if (headings.some(el => root.contains(el) && /^(?:personalization|base style and tone|custom instructions)$/i.test(text(el)))) return '{}';
    const empty = /^(?:you have no saved memories|no (?:saved )?memories(?: yet)?|nothing (?:saved|remembered) yet)[.!]?$/i;
    const read = () => {
      const fields = [...root.querySelectorAll('textarea')].filter(visible);
      if (fields.length === 1 && !/tell claude|add|change|remove|search/i.test(fields[0].placeholder || fields[0].getAttribute('aria-label') || '')) {
        const value = clean(fields[0].value);
        if (value && !pending(value)) return { text: value, empty: false };
      }
      const explicit = [...root.querySelectorAll('[data-testid="memory-entry"],[data-testid*="memory-item"],[data-testid*="memory-content"],[data-memory-id]')].filter(visible);
      const nodes = explicit.length ? explicit : [...root.querySelectorAll('li,p')].filter(el => visible(el) && !el.closest('nav,button,[role=button],form'));
      const values = nodes.map(text).filter(value => value && !pending(value) && !memoryTitle.test(value) && !empty.test(value)
        && !/^(?:search|delete|manage|close|done|memory is|claude can|chatgpt can|generate memory|reference saved|learn more|your memory is|tell claude what)/i.test(value));
      return { text: [...new Set(values)].join('\n'), empty: !values.length && text(root).split('\n').some(line => empty.test(clean(line))) };
    };
    // Traverse a bounded, rendered list, including virtualized lists. Do not
    // import a filtered/pending/oversized subset as the complete new snapshot.
    const scrollers = [root, ...root.querySelectorAll('*')].filter(el => visible(el) && el.scrollHeight > el.clientHeight + 8 && /auto|scroll/.test(getComputedStyle(el).overflowY));
    const scroller = scrollers.sort((a, b) => (b.scrollHeight-b.clientHeight) - (a.scrollHeight-a.clientHeight))[0];
    const lines = new Set();
    const original = scroller?.scrollTop || 0;
    let complete = !scroller, explicitlyEmpty = false, previous = '', stableBottom = 0;
    try {
      if (scroller) scroller.scrollTop = 0;
      for (let pass = 0; pass < (scroller ? 65 : 1); pass++) {
        if (scroller) await new Promise(resolve => setTimeout(resolve, 180));
        const sample = read();
        explicitlyEmpty = sample.empty;
        for (const line of sample.text.split('\n').filter(Boolean)) lines.add(line);
        if ([...lines].join('\n').length > 24_000) return '{}';
        if (!scroller) break;
        const bottom = scroller.scrollHeight - scroller.clientHeight;
        const signature = `${bottom}:${[...lines].join('\n')}`;
        if (scroller.scrollTop >= bottom - 2) {
          stableBottom = signature === previous ? stableBottom + 1 : 0;
          if (stableBottom >= 2) { complete = true; break; }
        }
        previous = signature;
        scroller.scrollTop = Math.min(bottom, scroller.scrollTop + Math.max(160, scroller.clientHeight * 0.8));
        scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
      }
    } finally { if (scroller) scroller.scrollTop = original; }
    if (complete && (lines.size || explicitlyEmpty)) result.memories = [...lines].join('\n');
    return JSON.stringify(result);
    """#
}
