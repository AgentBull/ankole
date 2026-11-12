export const CUSTOM_EMOJI_PREFIX = 'metadata/custom-emoji/'

const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
// An emoji code point other than a digit, `#`, or `*`, which are emoji only inside a keycap; a code point that Unicode
// reserves for future pictographs and this engine's tables do not name yet; or a keycap mark. The control plane
// applies the same pattern, so a browser and the server agree on every emoji the Pod picker offers even when they
// ship different Unicode versions.
const EMOJI = /(?![0-9#*])\p{Emoji}|(?=\p{Extended_Pictographic})\p{Cn}|\u20E3/u

/** A Page icon is either an emoji or a path in the shared custom-emoji library. */
export function isCustomEmojiIcon(icon: string | null | undefined): icon is string {
  return Boolean(icon?.startsWith(CUSTOM_EMOJI_PREFIX))
}

/**
 * The icon a Page shows: its stored value when that value is one emoji or a custom-emoji path. The Pages API rejects
 * other text, but a version restore writes a snapshot's icon as recorded, so a stored icon can be a word. Pod
 * treats such text as no icon, and the Page shows its type mark instead of text that overflows the icon slot.
 */
export function pageIcon(icon: string | null | undefined): string | undefined {
  if (!icon) return undefined
  if (isCustomEmojiIcon(icon)) return icon
  return [...graphemes.segment(icon)].length === 1 && EMOJI.test(icon) ? icon : undefined
}
