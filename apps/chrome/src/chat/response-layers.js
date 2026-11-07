import { packParentContext } from '../../../../packages/core/src/context.js';
import { normalizeSelectionAttachment } from './chat-turn.js';

export function buildResponseLayerContext({
  attachment,
  capture,
  messages = [],
  ancestorContext = ''
} = {}) {
  const selected = normalizeSelectionAttachment(attachment);
  if (!selected || !capture) return null;
  const messageIndex = selected.messageIndex;
  const parentResponse = Number.isInteger(messageIndex) ? messages[messageIndex]?.content : '';
  return {
    attachment: selected,
    capture: { ...capture },
    parentContext: packParentContext({
      ancestorContext,
      messages: Number.isInteger(messageIndex)
        ? messages.filter((_entry, index) => index !== messageIndex)
        : messages,
      response: parentResponse || '',
      selection: selected.text
    })
  };
}
