const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
const letter = /^[\p{L}\p{N}]/u
// Han, Kana, Hangul, and Arabic glyphs are as wide as two Latin letters, so one of them fills the avatar.
const wide = /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Arabic}]/u

/** Initials come from the first letter of the first and last words, skipping emoji and punctuation. */
export function avatarInitials(name: string): string {
  const words = name
    .split(/\s+/)
    .map(word => Array.from(graphemes.segment(word), part => part.segment).filter(part => letter.test(part)))
    .filter(word => word.length > 0)
  const first = words[0]
  if (!first) return '?'
  if (wide.test(first[0]!)) return first[0]!
  const last = words.length > 1 ? words.at(-1)! : undefined
  // A generational suffix such as "III" names the person no better than the surname before it.
  const surname = last && /^[IVX]+$/.test(last.join('')) && words.length > 2 ? words.at(-2)! : last
  return (surname ? first[0]! + surname[0]! : first.slice(0, 2).join('')).toLocaleUpperCase()
}
