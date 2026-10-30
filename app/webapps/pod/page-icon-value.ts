export const CUSTOM_EMOJI_PREFIX = 'metadata/custom-emoji/'

/** A Page icon is either an emoji or a path in the shared custom-emoji library. */
export function isCustomEmojiIcon(icon: string | null | undefined): icon is string {
  return Boolean(icon?.startsWith(CUSTOM_EMOJI_PREFIX))
}
