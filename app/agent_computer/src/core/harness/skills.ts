import { parse } from 'yaml'

/**
 * `SKILL.md` frontmatter parsing shared by the DB-driven library loader
 * (`ai-agent/library/service.ts`).
 */

/**
 * Recognised `SKILL.md` frontmatter keys. Open via `Record<string, unknown>` because authors may add
 * fields the loader does not yet know about, and unknown keys should pass through rather than be
 * dropped. Both `default_enabled` and `defaultEnabled` are accepted to tolerate snake_case and camelCase
 * authoring; the loader picks whichever is present.
 */
export type SkillFrontmatter = Record<string, unknown> & {
  name?: string
  description?: string
  default_enabled?: boolean
  defaultEnabled?: boolean
  tags?: unknown
  category?: unknown
  /** When true, the skill is hidden from the model's auto-selectable list (explicit invocation only). */
  'disable-model-invocation'?: boolean
}

export interface ParsedSkillFile {
  frontmatter: SkillFrontmatter
  body: string
}

/**
 * Splits a `SKILL.md` document into YAML frontmatter and markdown body.
 *
 * Tolerant by design: a file with no leading `---` fence, or one whose fence does not close, is treated
 * as all-body with empty frontmatter rather than rejected — a malformed or frontmatter-less skill file
 * still loads, just without metadata. The `\r?\n` handling lets the same regex accept both Unix and
 * Windows line endings. A scalar or array YAML value (not an object) is likewise discarded back to empty
 * frontmatter, so a stray top-level value cannot be cast into the typed shape.
 */
export function parseSkillFile(raw: string): ParsedSkillFile {
  if (!raw.startsWith('---')) return { frontmatter: {}, body: raw }
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(raw)
  if (!match) return { frontmatter: {}, body: raw }
  const parsed = parse(match[1] ?? '')
  const frontmatter = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as SkillFrontmatter) : {}
  return { frontmatter, body: match[2] ?? '' }
}
