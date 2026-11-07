import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_SETTINGS, mergeSettings } from '../../packages/core/src/providers.js';
import { buildProviderRequest, checkBridgeStatus, runCompletion } from '../../apps/chrome/src/provider-runtime.js';

const basePayload = {
  messages: [{ role: 'user', content: 'Explain this.' }],
  selection: '$x^2$',
  kind: 'latex',
  pageLanguage: 'en'
};

test('GPT-6 requests preserve supported reasoning without unsupported temperature', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'test-key' } });
  for (const model of ['gpt-6-astra', 'gpt-6.1-sol', 'gpt-6-sol', 'gpt-6-luna']) {
    for (const webSearch of [false, true]) {
      const request = buildProviderRequest({ ...basePayload, provider: 'openai', model, reasoningEffort: 'high', webSearch }, settings);
      const body = JSON.parse(request.fetchOptions.body);
      assert.equal(body.model, model);
      assert.equal(body.temperature, undefined);
      assert.equal(webSearch ? body.reasoning.effort : body.reasoning_effort, 'high');
    }
  }
});

test('OpenAI-compatible request keeps the system prompt outside page content', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: {
      memory: 'The user prefers geometric intuition.',
      projectName: 'Linear algebra',
      projectContext: 'The course uses column-vector notation.'
    }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    model: 'gpt-5-mini',
    parentContext: 'The parent answer defined the variable.',
    useChatGptWebContext: true
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(request.fetchOptions.headers.authorization, 'Bearer secret');
  assert.equal(body.messages[0].role, 'system');
  assert.match(body.messages[1].content, /<scholia-selection>/);
  assert.match(body.messages[1].content, /<scholia-parent-context>/);
  assert.match(body.messages[1].content, /<scholia-chatgpt-context>/);
  assert.match(body.messages[1].content, /The user prefers geometric intuition/);
  assert.equal(body.stream, true);
});

test('GPT NTNU uses its bearer key and OpenAI-compatible chat contract', () => {
  const settings = mergeSettings({
    provider: 'ntnu',
    apiKeys: { ntnu: 'ntnu-secret' }
  });
  const request = buildProviderRequest({ ...basePayload, provider: 'ntnu' }, settings);
  const body = JSON.parse(request.fetchOptions.body);

  assert.equal(request.url, 'https://llm.hpc.ntnu.no/v1/chat/completions');
  assert.equal(request.fetchOptions.headers.authorization, 'Bearer ntnu-secret');
  assert.equal(body.model, 'openai/gpt-oss-120b');
  assert.equal(body.messages[0].role, 'system');
  assert.equal(body.stream, true);
});

test('GPT NTNU rejects images for text-only models and encodes them for vision models', () => {
  const settings = mergeSettings({ apiKeys: { ntnu: 'ntnu-secret' } });
  const imagePayload = {
    ...basePayload,
    provider: 'ntnu',
    imageDataUrl: 'data:image/png;base64,aGVsbG8='
  };

  assert.throws(
    () => buildProviderRequest(imagePayload, settings),
    /openai\/gpt-oss-120b is text-only/
  );

  const request = buildProviderRequest({
    ...imagePayload,
    model: 'moonshotai/Kimi-K2.6'
  }, settings);
  const userContent = JSON.parse(request.fetchOptions.body).messages[1].content;
  assert.equal(userContent[1].type, 'image_url');
  assert.equal(userContent[1].image_url.url, imagePayload.imageDataUrl);
});

test('PDF guided learning mode reaches the provider system instruction', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    learningMode: true,
    sourceKind: 'pdf'
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);

  assert.match(body.messages[0].content, /Explain mode:/);
  assert.match(body.messages[0].content, /never produce a complete submission/);
});

test('an initial highlight question includes the fetched page context', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    context: 'Fetched page evidence: the cobalt reference corrects wavelength drift.',
    pageTitle: 'Calibration notes',
    url: 'https://example.test/calibration'
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  const question = body.messages[1].content;

  assert.match(question, /<scholia-context>/);
  assert.match(question, /Fetched page evidence/);
  assert.match(question, /<scholia-selection>/);
  assert.ok(question.endsWith('Question: Explain this.'));
});

test('Auto follows the prompt while retaining document language as reference metadata', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' }, language: 'auto' });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    pageLanguage: 'fr-FR',
    selection: 'Pourquoi ce résultat est-il vrai?'
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);

  assert.match(body.messages[0].content, /language of the user’s latest question on every turn/);
  assert.match(body.messages[1].content, /Detected document language: fr-FR/);
});

test('a selected response language reaches providers and can be reset to Auto', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' }, language: 'no' });
  for (const [language, rule] of [
    [undefined, /Svar på norsk bokmål/], ['en', /Reply in English/],
    ['auto', /language of the user’s latest question on every turn/]
  ]) {
    const request = buildProviderRequest({ ...basePayload, provider: 'openai', language }, settings);
    assert.match(JSON.parse(request.fetchOptions.body).messages[0].content, rule);
  }
});

test('a per-chat context toggle omits automatic source and account context but keeps explicit selection', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: {
      quickChatRefreshInterval: '3h',
      memory: 'Private imported memory.'
    }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    includeContext: false,
    context: 'Automatic page evidence.',
    pageTitle: 'Private title',
    url: 'https://chatgpt.com/c/private',
    useChatGptWebContext: true
  }, settings);
  const prompt = JSON.parse(request.fetchOptions.body).messages[1].content;

  assert.match(prompt, /<scholia-selection>/);
  assert.doesNotMatch(prompt, /<scholia-context>/);
  assert.doesNotMatch(prompt, /scholia-chatgpt-context/);
  assert.doesNotMatch(prompt, /Automatic page evidence|Private imported memory|Private title|chatgpt\.com/);
});

test('turning compact mode off keeps full automatic context unless no-context is explicit', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    includePageContext: false
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    compactContext: false,
    context: 'Full source evidence remains attached.',
    pageTitle: 'Full source',
    url: 'https://example.test/full'
  }, settings);
  const prompt = JSON.parse(request.fetchOptions.body).messages[1].content;

  assert.match(prompt, /<scholia-context>/);
  assert.match(prompt, /Full source evidence remains attached/);
  assert.match(prompt, /Full source/);
});

test('highlight follow-ups receive the fetched source context beside the current question', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    context: 'Fetched page evidence: the correction is subtracted from the sample spectrum.',
    pageTitle: 'Calibration notes',
    url: 'https://example.test/calibration',
    messages: [
      { role: 'user', content: 'Why is this reference needed?' },
      { role: 'assistant', content: 'It corrects instrument drift.' },
      { role: 'user', content: 'How is the correction applied?' }
    ]
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  const firstQuestion = body.messages[1].content;
  const followUp = body.messages[3].content;

  assert.match(firstQuestion, /<scholia-selection>/);
  assert.doesNotMatch(firstQuestion, /Fetched page evidence/);
  assert.match(followUp, /<scholia-context>/);
  assert.match(followUp, /Fetched page evidence/);
  assert.match(followUp, /<scholia-selection>/);
  assert.ok(followUp.endsWith('Question: How is the correction applied?'));
});

test('OpenAI web search uses the Responses API and its native search tool', () => {
  const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    model: 'gpt-5-mini',
    webSearch: true
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(request.url, 'https://api.openai.com/v1/responses');
  assert.equal(request.responseProtocol, 'openai-responses');
  assert.deepEqual(body.tools, [{ type: 'web_search' }]);
  assert.deepEqual(body.reasoning, { summary: 'auto' });
  assert.match(body.instructions, /You are Scholia/);
  assert.equal(body.messages, undefined);
  assert.equal(body.input[0].role, 'user');
  assert.match(body.input[0].content, /<scholia-selection>/);
});

test('Anthropic and OpenRouter requests enable their native web-search tools', () => {
  const anthropic = buildProviderRequest({
    ...basePayload, provider: 'anthropic', webSearch: true
  }, mergeSettings({ apiKeys: { anthropic: 'secret' } }));
  assert.deepEqual(JSON.parse(anthropic.fetchOptions.body).tools, [
    { type: 'web_search_20250305', name: 'web_search', max_uses: 5 }
  ]);

  const openrouter = buildProviderRequest({
    ...basePayload, provider: 'openrouter', webSearch: true
  }, mergeSettings({ apiKeys: { openrouter: 'secret' } }));
  assert.deepEqual(JSON.parse(openrouter.fetchOptions.body).tools, [
    { type: 'openrouter:web_search' }
  ]);
});

test('Codex web search is forwarded explicitly to the local bridge', () => {
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'codex',
    model: 'gpt-5.6-sol',
    webSearch: true
  }, mergeSettings({ provider: 'codex' }));
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(body.web_search, true);
  assert.equal(request.webSearch, true);
  assert.equal(request.url, 'http://127.0.0.1:8789/v1/chat/completions');
});

test('web search fails clearly for providers without a supported tool contract', () => {
  assert.throws(
    () => buildProviderRequest({ ...basePayload, provider: 'ollama', webSearch: true }, mergeSettings({ provider: 'ollama' })),
    /Web search is not available through Ollama/
  );
});

test('imported ChatGPT context cannot be attached to ordinary chat without Quick Chat opt-in', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: { memory: 'Private imported memory.' }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    useChatGptWebContext: true,
    parentContext: ''
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.doesNotMatch(body.messages[1].content, /scholia-chatgpt-context/);
  assert.doesNotMatch(body.messages[1].content, /Private imported memory/);
});

test('Quick Chat opt-in attaches the refreshed ChatGPT snapshot to an ordinary question', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: {
      quickChatRefreshInterval: '3h',
      memory: 'Private imported memory.'
    }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    useChatGptWebContext: true
  }, settings);
  const prompt = JSON.parse(request.fetchOptions.body).messages[1].content;
  assert.match(prompt, /<scholia-chatgpt-context>/);
  assert.match(prompt, /Private imported memory/);
});

test('automatic ChatGPT reference context is compressed before provider submission', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: {
      quickChatRefreshInterval: '3h',
      memory: Array.from(
        { length: 120 },
        (_, index) => `Memory section ${index + 1}. ${'Background preference detail. '.repeat(10)}`
      ).join('\n\n')
    }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    includeContext: true,
    useChatGptWebContext: true
  }, settings);
  const prompt = JSON.parse(request.fetchOptions.body).messages[1].content;

  assert.match(prompt, /<scholia-chatgpt-context>/);
  assert.ok(prompt.length < 6_000);
});

test('imported memory is attached automatically on ChatGPT with only matching project context', () => {
  const settings = mergeSettings({
    apiKeys: { openai: 'secret' },
    chatgptWebContext: {
      autoUseOnChatGpt: true,
      memory: 'Private imported memory.',
      projectName: 'Course work',
      projectUrl: 'https://chatgpt.com/g/g-p-course/project',
      projectContext: 'Use course-specific symbols.'
    }
  });
  const matching = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    url: 'https://chatgpt.com/g/g-p-course/c/current-chat'
  }, settings);
  const matchingPrompt = JSON.parse(matching.fetchOptions.body).messages[1].content;
  assert.match(matchingPrompt, /Private imported memory/);
  assert.match(matchingPrompt, /Use course-specific symbols/);

  const unrelated = buildProviderRequest({
    ...basePayload,
    provider: 'openai',
    url: 'https://chatgpt.com/g/g-p-other/c/current-chat'
  }, settings);
  const unrelatedPrompt = JSON.parse(unrelated.fetchOptions.body).messages[1].content;
  assert.match(unrelatedPrompt, /Private imported memory/);
  assert.doesNotMatch(unrelatedPrompt, /Use course-specific symbols/);
});

test('Anthropic image request uses base64 source blocks', () => {
  const settings = mergeSettings({ apiKeys: { anthropic: 'secret' } });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'anthropic',
    imageDataUrl: 'data:image/png;base64,aGVsbG8='
  }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(body.messages[0].content[1].type, 'image');
  assert.equal(body.messages[0].content[1].source.media_type, 'image/png');
});

test('an image added during a chat stays on the new user turn for every message-shaped provider', () => {
  const imageDataUrl = 'data:image/png;base64,aGVsbG8=';
  const messages = [
    { role: 'user', content: 'Explain the page.' },
    { role: 'assistant', content: 'The page describes a theorem.' },
    { role: 'user', content: 'Now inspect this selected region.', imageDataUrl }
  ];

  const openAi = buildProviderRequest({ ...basePayload, provider: 'openai', messages }, mergeSettings({
    apiKeys: { openai: 'secret' }
  }));
  const openAiMessages = JSON.parse(openAi.fetchOptions.body).messages;
  assert.equal(typeof openAiMessages[1].content, 'string');
  assert.equal(openAiMessages[3].content[0].text, 'Now inspect this selected region.');
  assert.equal(openAiMessages[3].content[1].image_url.url, imageDataUrl);

  const anthropic = buildProviderRequest({ ...basePayload, provider: 'anthropic', messages }, mergeSettings({
    apiKeys: { anthropic: 'secret' }
  }));
  const anthropicMessages = JSON.parse(anthropic.fetchOptions.body).messages;
  assert.equal(typeof anthropicMessages[0].content, 'string');
  assert.equal(anthropicMessages[2].content[0].text, 'Now inspect this selected region.');
  assert.equal(anthropicMessages[2].content[1].source.data, 'aGVsbG8=');

  const ollama = buildProviderRequest({ ...basePayload, provider: 'ollama', messages }, mergeSettings({ provider: 'ollama' }));
  const ollamaMessages = JSON.parse(ollama.fetchOptions.body).messages;
  assert.equal(ollamaMessages[1].images, undefined);
  assert.deepEqual(ollamaMessages[3].images, ['aGVsbG8=']);
});

test('missing hosted-provider key fails before network access', () => {
  assert.throws(() => buildProviderRequest({ ...basePayload, provider: 'openai' }, DEFAULT_SETTINGS), /Add your OpenAI API key/);
});

test('provider endpoints accept local HTTP but reject unsafe remote URLs', () => {
  const remoteHttp = mergeSettings({
    apiKeys: { openai: 'secret' },
    endpoints: { openai: 'http://models.example.com/v1/chat/completions' }
  });
  assert.throws(
    () => buildProviderRequest({ ...basePayload, provider: 'openai' }, remoteHttp),
    /must use HTTPS unless it runs on this device/
  );

  const loopback = mergeSettings({
    apiKeys: { openai: 'secret' },
    endpoints: { openai: 'http://localhost:8080/v1/chat/completions' }
  });
  assert.equal(
    buildProviderRequest({ ...basePayload, provider: 'openai' }, loopback).url,
    'http://localhost:8080/v1/chat/completions'
  );

  const embeddedCredentials = mergeSettings({
    apiKeys: { openai: 'secret' },
    endpoints: { openai: 'https://user:password@models.example.com/v1/chat/completions' }
  });
  assert.throws(
    () => buildProviderRequest({ ...basePayload, provider: 'openai' }, embeddedCredentials),
    /Remove embedded credentials/
  );
});

test('text-only provider rejects screenshots', () => {
  const settings = mergeSettings({ apiKeys: { cohere: 'secret' } });
  assert.throws(() => buildProviderRequest({
    ...basePayload,
    provider: 'cohere',
    imageDataUrl: 'data:image/jpeg;base64,aGVsbG8='
  }, settings), /cannot receive images/);
});

test('text-only opencode models reject images before creating a provider session', () => {
  const settings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'opencode-go/glm-5.3' }
  });
  assert.throws(() => buildProviderRequest({
    ...basePayload,
    provider: 'opencode',
    model: 'opencode-go/glm-5.3',
    imageDataUrl: 'data:image/jpeg;base64,aGVsbG8='
  }, settings), /text-only/);

  const visionSettings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'future/vision' },
    discoveredModels: {
      opencode: [{ id: 'future/vision', label: 'Future Vision', supportsImages: true }]
    }
  });
  assert.equal(buildProviderRequest({
    ...basePayload,
    provider: 'opencode',
    model: 'future/vision',
    imageDataUrl: 'data:image/jpeg;base64,aGVsbG8='
  }, visionSettings).model, 'future/vision');
});

test('OpenAI-compatible SSE is assembled token by token', async () => {
  const originalFetch = globalThis.fetch;
  const chunks = [
    'data: {"choices":[{"delta":{"reasoning_content":"Checking the premise. "}}]}\n\n',
    'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
    'data: {"choices":[{"delta":{"content":"lo"}}]}\n\ndata: [DONE]\n\n'
  ];
  globalThis.fetch = async () => new Response(new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(new TextEncoder().encode(chunk));
      controller.close();
    }
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } });

  try {
    const tokens = [];
    const reasoningTokens = [];
    const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
    const result = await runCompletion(
      { ...basePayload, provider: 'openai' },
      settings,
      (token) => tokens.push(token),
      undefined,
      (token) => reasoningTokens.push(token)
    );
    assert.equal(result.text, 'Hello');
    assert.equal(result.reasoning, 'Checking the premise.');
    assert.deepEqual(tokens, ['Hel', 'lo']);
    assert.deepEqual(reasoningTokens, ['Checking the premise. ']);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('OpenAI web-search streaming preserves citations as clickable sources', async () => {
  const originalFetch = globalThis.fetch;
  let requestedUrl = '';
  let requestBody = null;
  const chunks = [
    'data: {"type":"response.web_search_call.completed","item_id":"search_1"}\n\n',
    'data: {"type":"response.reasoning_summary_text.delta","delta":"I checked current sources."}\n\n',
    'data: {"type":"response.output_text.delta","delta":"The current result is 42."}\n\n',
    'data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"https://example.com/research","title":"Example research"}}\n\n',
    'data: {"type":"response.completed","response":{"output":[]}}\n\n'
  ];
  globalThis.fetch = async (url, options) => {
    requestedUrl = String(url);
    requestBody = JSON.parse(options.body);
    return new Response(new ReadableStream({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(new TextEncoder().encode(chunk));
        controller.close();
      }
    }), { status: 200, headers: { 'content-type': 'text/event-stream' } });
  };

  try {
    const tokens = [];
    const activity = [];
    const settings = mergeSettings({ apiKeys: { openai: 'secret' } });
    const result = await runCompletion({
      ...basePayload, provider: 'openai', webSearch: true
    }, settings, (token) => tokens.push(token), undefined, () => {}, (event) => activity.push(event));
    assert.ok(activity.some((event) => event.title === 'Web search complete'));
    assert.equal(requestedUrl, 'https://api.openai.com/v1/responses');
    assert.deepEqual(requestBody.tools, [{ type: 'web_search' }]);
    assert.equal(result.webSearch, true);
    assert.equal(result.webSearchUsed, true);
    assert.equal(result.sourceCount, 1);
    assert.equal(result.reasoning, 'I checked current sources.');
    assert.match(result.text, /The current result is 42\./);
    assert.match(result.text, /### Sources/);
    assert.match(result.text, /\[Example research\]\(https:\/\/example\.com\/research\)/);
    assert.equal(tokens[0], 'The current result is 42.');
    assert.match(tokens[1], /### Sources/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Codex bridge streaming reports when the CLI used web search', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response([
    'data: {"web_search_used":true,"choices":[{"delta":{"content":"Current answer"}}]}\n\n',
    'data: [DONE]\n\n'
  ].join(''), { status: 200, headers: { 'content-type': 'text/event-stream' } });

  try {
    const result = await runCompletion({
      ...basePayload, provider: 'codex', webSearch: true
    }, mergeSettings({ provider: 'codex' }), () => {});
    assert.equal(result.webSearch, true);
    assert.equal(result.webSearchUsed, true);
    assert.equal(result.text, 'Current answer');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Ollama NDJSON stream is assembled', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(
    '{"message":{"thinking":"Compare the inputs. ","content":"Local "}}\n{"message":{"thinking":"Return the result.","content":"answer"},"done":true}\n',
    { status: 200, headers: { 'content-type': 'application/x-ndjson' } }
  );

  try {
    const settings = mergeSettings({ provider: 'ollama' });
    const reasoningTokens = [];
    const result = await runCompletion(
      { ...basePayload, provider: 'ollama' },
      settings,
      undefined,
      undefined,
      (token) => reasoningTokens.push(token)
    );
    assert.equal(result.text, 'Local answer');
    assert.equal(result.reasoning, 'Compare the inputs. Return the result.');
    assert.deepEqual(reasoningTokens, ['Compare the inputs. ', 'Return the result.']);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Codex bridge receives the selected model, raw reasoning effort, and Fast mode', () => {
  const settings = mergeSettings({
    provider: 'codex',
    fastMode: true,
    models: { codex: 'gpt-5.6-sol' },
    reasoningEfforts: { codex: 'ultra' }
  });
  const request = buildProviderRequest({ ...basePayload, provider: 'codex', model: 'gpt-5.6-sol' }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(request.url, 'http://127.0.0.1:8789/v1/chat/completions');
  assert.equal(body.model, 'gpt-5.6-sol');
  assert.equal(body.reasoning_effort, 'ultra');
  assert.equal(body.fast_mode, true);
  assert.equal(request.fetchOptions.headers.authorization, undefined);
});

test('Codex bridge health enables image forwarding', async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url: String(url), options });
    if (String(url).endsWith('/health')) {
      return Response.json({ ok: true, service: 'codex-bridge', images: true });
    }
    return Response.json({ choices: [{ message: { content: 'I can see it.' } }] });
  };
  try {
    const settings = mergeSettings({ provider: 'codex' });
    const result = await runCompletion({
      ...basePayload,
      provider: 'codex',
      imageDataUrl: 'data:image/png;base64,aGVsbG8='
    }, settings);
    assert.equal(result.text, 'I can see it.');
    assert.equal(requests[0].url, 'http://127.0.0.1:8789/health');
    const body = JSON.parse(requests[1].options.body);
    assert.equal(body.messages[1].content[1].type, 'image_url');
    assert.equal(body.messages[1].content[1].image_url.url, 'data:image/png;base64,aGVsbG8=');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Claude Code bridge receives fast mode and a supported reasoning effort', () => {
  const settings = mergeSettings({ provider: 'claudecode', fastMode: true, reasoningEfforts: { claudecode: 'xhigh' } });
  const request = buildProviderRequest({ ...basePayload, provider: 'claudecode', model: 'sonnet' }, settings);
  const body = JSON.parse(request.fetchOptions.body);
  assert.equal(body.reasoning_effort, 'xhigh');
  assert.equal(body.fast_mode, true);
});

test('OpenRouter keeps an exact custom free-model id', () => {
  const settings = mergeSettings({ apiKeys: { openrouter: 'secret' } });
  const request = buildProviderRequest({ ...basePayload, provider: 'openrouter', model: 'openai/gpt-oss-20b:free' }, settings);
  assert.equal(JSON.parse(request.fetchOptions.body).model, 'openai/gpt-oss-20b:free');
});

test('opencode creates a native session and sends image file parts', async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push({ url: String(url), options });
    if (String(url).endsWith('/session')) return Response.json({ id: 'session-test' });
    return Response.json({ parts: [{ type: 'reasoning', text: 'hidden' }, { type: 'text', text: 'Visible answer' }] });
  };
  try {
    const settings = mergeSettings({
      provider: 'opencode',
      endpoints: { opencode: 'http://127.0.0.1:4196' },
      discoveredModels: {
        opencode: [{
          id: 'opencode-go/deepseek-v4-pro',
          label: 'DeepSeek V4 Pro',
          supportsImages: true
        }]
      }
    });
    const result = await runCompletion({
      ...basePayload,
      provider: 'opencode',
      imageDataUrl: 'data:image/png;base64,aGVsbG8='
    }, settings);
    assert.equal(result.text, 'Visible answer');
    assert.equal(result.reasoning, 'hidden');
    assert.equal(requests[0].url, 'http://127.0.0.1:4196/session');
    const messageBody = JSON.parse(requests[1].options.body);
    assert.match(messageBody.parts[0].text, /\[Attached image: scholia-turn-1\.png\]/);
    assert.deepEqual(messageBody.model, { providerID: 'opencode-go', modelID: 'deepseek-v4-pro' });
    assert.equal(messageBody.parts[1].type, 'file');
    assert.equal(messageBody.parts[1].mime, 'image/png');
    assert.equal(messageBody.parts[1].filename, 'scholia-turn-1.png');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('opencode sessions are request-scoped so one chat cannot poison another', async () => {
  const originalFetch = globalThis.fetch;
  const created = [];
  const messageURLs = [];
  globalThis.fetch = async (url) => {
    const value = String(url);
    if (value.endsWith('/session')) {
      const id = `isolated-${created.length + 1}`;
      created.push(id);
      return Response.json({ id });
    }
    messageURLs.push(value);
    return Response.json({ parts: [{ type: 'text', text: 'OK' }] });
  };
  try {
    const settings = mergeSettings({
      provider: 'opencode',
      endpoints: { opencode: 'http://127.0.0.1:4197' }
    });
    await runCompletion({ ...basePayload, provider: 'opencode' }, settings);
    await runCompletion({ ...basePayload, provider: 'opencode' }, settings);
    assert.deepEqual(created, ['isolated-1', 'isolated-2']);
    assert.deepEqual(messageURLs, [
      'http://127.0.0.1:4197/session/isolated-1/message',
      'http://127.0.0.1:4197/session/isolated-2/message'
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('opencode forwards a discovered model reasoning variant', () => {
  const settings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'future/new-reasoner' },
    reasoningEfforts: { opencode: 'high' },
    discoveredModels: {
      opencode: [{
        id: 'future/new-reasoner',
        label: 'New Reasoner',
        reasoning: { efforts: ['low', 'medium', 'high'], default: 'medium' }
      }]
    }
  });
  const request = buildProviderRequest({
    ...basePayload,
    provider: 'opencode',
    model: 'future/new-reasoner',
    reasoningEffort: 'high'
  }, settings);
  assert.equal(request.variant, 'high');
});

test('bridge health uses the folk-compatible health endpoint and capability response', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    assert.equal(String(url), 'http://127.0.0.1:8787/health');
    return Response.json({ ok: true, service: 'claude-code-bridge', images: true });
  };
  try {
    const status = await checkBridgeStatus('claudecode', mergeSettings());
    assert.equal(status.up, true);
    assert.equal(status.supportsImages, true);
    assert.equal(status.startUrl, 'claudecode://start?port=8787');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('a cold Codex bridge supplies a Scholia-specific launcher and recovers on the next health check', async () => {
  const originalFetch = globalThis.fetch;
  let running = false;
  globalThis.fetch = async (url) => {
    assert.equal(String(url), 'http://127.0.0.1:8789/health');
    if (!running) throw new TypeError('Failed to fetch');
    return Response.json({ ok: true, service: 'codex-bridge', images: true });
  };
  try {
    const offline = await checkBridgeStatus('codex', mergeSettings());
    assert.equal(offline.up, false);
    assert.equal(offline.startUrl, 'scholia-codex://start');
    assert.equal(offline.installCommand, 'npm run bridge:install:codex -- --port 8789');
    running = true;
    const online = await checkBridgeStatus('codex', mergeSettings());
    assert.equal(online.up, true);
    assert.equal(online.supportsImages, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
