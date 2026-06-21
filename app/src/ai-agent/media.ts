import type { AgentMessage } from './core'

// Placeholder left in the model-bound view where an older image was removed. The
// wording tells the model an image existed and that only the newest one is kept,
// so it does not hallucinate that the user sent no image at all.
export const HISTORICAL_MEDIA_STRIPPED_TEXT =
  '[Attached image stripped from older context. The latest image-bearing user message is retained.]'

// Placeholder used only while estimating token size — never sent to the model.
export const INLINE_IMAGE_DATA_STRIPPED_TEXT = '[inline image data stripped for token estimate]'

// Flat token budget charged per stripped image during estimation, standing in for
// the provider's real (model-dependent) image token cost.
export const INLINE_IMAGE_DATA_TOKEN_COST = 1500

// Matches a base64 `data:image/...;base64,...` URL anywhere in a text run. The
// global flag drives both the membership test and the replace; callers reset
// `lastIndex` before each use because a global regex carries state between calls.
const INLINE_IMAGE_DATA_URL_PATTERN = /data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=_-]+/g

// Minimal structural view of one content block. Images appear either as a typed
// image block or as a base64 data-URL embedded in a text block, so both shapes
// must be detected.
type ContentBlock = { type?: string; text?: string; image_url?: unknown; image?: unknown }

function textContainsInlineImageData(text: string): boolean {
  INLINE_IMAGE_DATA_URL_PATTERN.lastIndex = 0
  return INLINE_IMAGE_DATA_URL_PATTERN.test(text)
}

// Replaces every inline image data-URL in `text` and reports how many were
// replaced, so the token estimator can charge a flat cost per image.
function replaceInlineImageData(text: string, replacement: string): { text: string; count: number } {
  let count = 0
  INLINE_IMAGE_DATA_URL_PATTERN.lastIndex = 0
  const replaced = text.replace(INLINE_IMAGE_DATA_URL_PATTERN, () => {
    count += 1
    return replacement
  })
  return { text: replaced, count }
}

function isImageBlock(block: unknown): boolean {
  if (!block || typeof block !== 'object') return false
  const type = (block as ContentBlock).type
  return type === 'image' || type === 'image_url' || type === 'input_image'
}

function contentHasImages(content: unknown): boolean {
  if (typeof content === 'string') return textContainsInlineImageData(content)
  if (!Array.isArray(content)) return false
  return content.some(block => {
    if (isImageBlock(block)) return true
    if (!block || typeof block !== 'object') return false
    const text = (block as ContentBlock).text
    return typeof text === 'string' && textContainsInlineImageData(text)
  })
}

function messageContent(message: AgentMessage): unknown {
  return (message as { content?: unknown }).content
}

// Returns content with image parts swapped for the placeholder. Returns the
// original reference unchanged when nothing matched, so callers can use identity
// (`stripped === content`) to skip rebuilding the message — see
// `stripHistoricalMedia`, which relies on that to avoid needless copies.
function stripImagesFromContent(content: unknown): unknown {
  if (typeof content === 'string') {
    return replaceInlineImageData(content, HISTORICAL_MEDIA_STRIPPED_TEXT).text
  }
  if (!Array.isArray(content)) return content
  let changed = false
  const stripped = content.map(block => {
    if (isImageBlock(block)) {
      changed = true
      return { type: 'text' as const, text: HISTORICAL_MEDIA_STRIPPED_TEXT }
    }
    if (!block || typeof block !== 'object') return block
    const text = (block as ContentBlock).text
    if (typeof text !== 'string' || !textContainsInlineImageData(text)) return block
    changed = true
    return { ...block, text: replaceInlineImageData(text, HISTORICAL_MEDIA_STRIPPED_TEXT).text }
  })
  return changed ? stripped : content
}

/**
 * Replace image parts in messages before the newest image-bearing user message.
 *
 * This mirrors Hermes' `_strip_historical_media`: the latest user image remains
 * visible, while older image payloads are replaced in the model-bound view only.
 */
export function stripHistoricalMedia(messages: AgentMessage[]): AgentMessage[] {
  // Walk back to the newest user message that carries an image — that one is the
  // "anchor" and is kept intact; only messages strictly before it are stripped.
  let anchor = -1
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index]!
    if (message.role === 'user' && contentHasImages(messageContent(message))) {
      anchor = index
      break
    }
  }
  // `anchor < 0` (no image anywhere) and `anchor === 0` (the only image is the
  // first message, nothing before it to strip) both leave the input untouched.
  if (anchor <= 0) return messages

  let changed = false
  const out = messages.map((message, index) => {
    if (index >= anchor) return message
    const content = messageContent(message)
    if (!contentHasImages(content)) return message
    const strippedContent = stripImagesFromContent(content)
    if (strippedContent === content) return message
    changed = true
    return { ...message, content: strippedContent } as AgentMessage
  })
  return changed ? out : messages
}

/**
 * Replace inline data:image base64 payloads before rough token estimation.
 * Returns the number of stripped images so callers can add a flat image cost.
 */
export function stripInlineImageDataForEstimate(messages: AgentMessage[]): {
  messages: AgentMessage[]
  imageCount: number
} {
  let imageCount = 0
  let changed = false

  const out = messages.map(message => {
    const content = messageContent(message)
    if (typeof content === 'string') {
      const replaced = replaceInlineImageData(content, INLINE_IMAGE_DATA_STRIPPED_TEXT)
      imageCount += replaced.count
      if (replaced.count === 0) return message
      changed = true
      return { ...message, content: replaced.text } as AgentMessage
    }
    if (!Array.isArray(content)) return message

    let messageChanged = false
    const stripped = content.map(block => {
      if (!block || typeof block !== 'object') return block
      const text = (block as ContentBlock).text
      if (typeof text !== 'string') return block
      const replaced = replaceInlineImageData(text, INLINE_IMAGE_DATA_STRIPPED_TEXT)
      imageCount += replaced.count
      if (replaced.count === 0) return block
      messageChanged = true
      return { ...block, text: replaced.text }
    })
    if (!messageChanged) return message
    changed = true
    return { ...message, content: stripped } as AgentMessage
  })

  return { messages: changed ? out : messages, imageCount }
}
