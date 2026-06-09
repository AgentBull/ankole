import { estimateContextTokens, type AgentMessage } from './core'
import { INLINE_IMAGE_DATA_TOKEN_COST, stripInlineImageDataForEstimate } from './media'
import { estimateStringChars, estimateTokensFromChars } from '@/common/cjk-chars'

/**
 * The base estimator counts every character at ~4 chars/token. Dense JSON is
 * really closer to ~2 chars/token, so a tool result that returns JSON (today:
 * web_extract on a JSON URL; tomorrow: API/DB tools) is under-counted ~2x. This
 * adds the missing half for JSON-looking tool-result text.
 *
 * Detection is a cheap shape sniff (`{…}` / `[…]`). A false positive only nudges
 * the estimate UP, which makes the compaction trigger slightly more conservative —
 * harmless. A false negative just leaves the base behavior unchanged.
 */
function jsonDensityCorrection(messages: AgentMessage[]): number {
  let correction = 0
  for (const message of messages) {
    if (message.role !== 'toolResult') continue
    for (const block of message.content) {
      if (block.type !== 'text') continue
      const trimmed = block.text.trim()
      const looksJson =
        (trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))
      if (looksJson) correction += Math.ceil(block.text.length / 4)
    }
  }
  return correction
}

function cjkDensityCorrection(messages: AgentMessage[]): number {
  let correction = 0
  for (const message of messages) {
    if (!hasTextContentBlocks(message)) continue
    for (const block of message.content) {
      if (block.type !== 'text' || typeof block.text !== 'string') continue
      const adjusted = estimateStringChars(block.text)
      if (adjusted > block.text.length) {
        correction += estimateTokensFromChars(adjusted - block.text.length)
      }
    }
  }
  return correction
}

/**
 * Context token estimate used for compaction TRIGGER decisions (preflight +
 * microcompact). Wraps pi's `estimateContextTokens` and bumps JSON-dense tool
 * results so we don't trigger compaction too late on JSON-heavy contexts. The
 * cut-point math inside compaction keeps using the base estimator — this only
 * affects "when", which is safe to make more conservative.
 */
export function estimateContextTokensJsonAware(messages: AgentMessage[]): number {
  const media = stripInlineImageDataForEstimate(messages)
  return (
    estimateContextTokens(media.messages).tokens +
    jsonDensityCorrection(media.messages) +
    cjkDensityCorrection(media.messages) +
    media.imageCount * INLINE_IMAGE_DATA_TOKEN_COST
  )
}

function hasTextContentBlocks(
  message: AgentMessage
): message is AgentMessage & { content: Array<{ type: string; text?: string }> } {
  return 'content' in message && Array.isArray(message.content)
}
