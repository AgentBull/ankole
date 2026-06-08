/**
 * Normalize inbound user text from IM platforms.
 *
 * Conservative scope (intentionally narrow): full-width space (U+3000) → ASCII
 * space, and full-width digits (U+FF10–FF19) → ASCII digits. Full-width letters,
 * CJK punctuation, and ASCII `/` are left untouched so user-meaningful content
 * isn't rewritten (e.g. a full-width slash `／` is NOT turned into a command).
 *
 * Applied once at the inbound chokepoint so the projection mirror, the agent
 * envelope (→ conversation → model), slash-command parsing, and the clarify gate
 * all observe the same canonical text.
 */
export function normalizeInboundText(text: string): string {
  return text.replace(/　/g, ' ').replace(/[０-９]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0xff10 + 0x30))
}
