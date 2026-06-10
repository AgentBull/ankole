import { parse } from 'yaml'

/**
 * `SKILL.md` frontmatter parsing shared by the DB-driven library loader
 * (`ai-agent/library/service.ts`).
 */

export type SkillFrontmatter = Record<string, unknown> & {
  name?: string
  description?: string
  default_enabled?: boolean
  defaultEnabled?: boolean
  tags?: unknown
  category?: unknown
  'disable-model-invocation'?: boolean
}

export interface ParsedSkillFile {
  frontmatter: SkillFrontmatter
  body: string
}

/** Split a `SKILL.md` document into YAML frontmatter and markdown body. */
export function parseSkillFile(raw: string): ParsedSkillFile {
  if (!raw.startsWith('---')) return { frontmatter: {}, body: raw }
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(raw)
  if (!match) return { frontmatter: {}, body: raw }
  const parsed = parse(match[1] ?? '')
  const frontmatter = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as SkillFrontmatter) : {}
  return { frontmatter, body: match[2] ?? '' }
}
