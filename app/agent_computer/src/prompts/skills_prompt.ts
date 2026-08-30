/**
 * Renders the agent's skill catalog into the `## Skills` block of the system prompt.
 *
 * A skill is an SOP the model can pull in on demand, not something it runs. This
 * block is only an index, so the prompt tells the model to call `skill_view(name)`
 * when a listed skill covers work it is already about to do. The catalog can grow
 * large, so this module keeps Ankole's hard size caps and graceful degradation:
 * first count-limit, then description compaction, then prefix trimming.
 */
import { sanitizeBinaryOutput, sanitizeCatalogLine } from '../common/text-sanitize'

export type SkillPromptEntry = {
  name: string
  description: string
  category?: string
  brainRecallOnly?: boolean
  backgroundJobOnly?: boolean
}

// The char cap is the real guardrail; the count cap is a cheap first cut. Every
// candidate is measured after rendering so framing and warnings stay in-budget.
const MAX_SKILLS_IN_PROMPT = 150
const MAX_SKILLS_PROMPT_CHARS = 18_000
const COMPACT_DESCRIPTION_MAX_CHARS = 220
const COMPACT_DESCRIPTION_MIN_CHARS = 4
// Per-entry caps keep one oversized third-party entry from starving the shared
// prompt budget and forcing every other description into compaction.
const ENTRY_DESCRIPTION_MAX_CHARS = 400
const ENTRY_CATEGORY_MAX_CHARS = 100

type SkillsPromptFormat = { kind: 'full' } | { kind: 'compact'; descriptionMaxChars: number }

/**
 * Builds the model-visible skill index as a compact catalog under a `## Skills` heading.
 *
 * Brain-recall-only Skills stay loadable but are omitted from this prompt
 * index. Returning an empty string lets the caller omit the section entirely.
 */
export function formatSkillsForSystemPrompt(skills: SkillPromptEntry[]): string {
  const visibleSkills = skills
    .filter(skill => !skill.brainRecallOnly)
    .flatMap(skill => sanitizeSkillEntry(skill) ?? [])
    .toSorted(compareSkills)
  if (visibleSkills.length === 0) return ''

  const limited = applySkillsPromptLimits(visibleSkills)
  return renderSkillsPrompt(limited.skills, visibleSkills.length, limited.format)
}

/**
 * Re-normalizes one entry at the host boundary, trusting no producer.
 *
 * The name is the exact string the model must pass back to `skill_view`, so it
 * cannot be rewritten: an entry whose name carries hidden or control characters
 * is not addressable as displayed and is dropped instead. Descriptions and
 * categories are presentation text, so they are sanitized and capped.
 */
function sanitizeSkillEntry(skill: SkillPromptEntry): SkillPromptEntry | null {
  if (sanitizeBinaryOutput(skill.name) !== skill.name || skill.name.trim() === '') return null
  const category =
    skill.category === undefined ? undefined : sanitizeCatalogLine(skill.category, ENTRY_CATEGORY_MAX_CHARS)
  return {
    ...skill,
    description: sanitizeCatalogLine(skill.description, ENTRY_DESCRIPTION_MAX_CHARS),
    ...(category !== undefined ? { category } : {})
  }
}

/** Renders one exact prompt candidate so budget checks include all framing and warnings. */
function renderSkillsPrompt(skills: SkillPromptEntry[], totalSkills: number, format: SkillsPromptFormat): string {
  const categories = groupSkillsByCategory(skills)
  const hasBackgroundJobSkill = skills.some(skill => skill.backgroundJobOnly)

  const lines = [
    '## Skills',
    '',
    `You have access to the following skills. Skills are task-specific instructions and references.
Before performing a task or subtask you are already going to do, call \`skill_view(name)\` only if a listed skill covers that task, then follow the loaded instructions. If the user asks to inspect, view, choose, recommend, or identify an available skill, the index is only a routing aid: pick the relevant listed skill and call \`skill_view(name)\` before answering. Otherwise continue without a skill.`,
    hasBackgroundJobSkill
      ? 'Entries marked [background task] must run in a BackgroundAgentJob. Create one with create_background_job, name the Skill in its self-contained task, and do not execute the Skill inline.'
      : '',
    '<available_skills>'
  ].filter(Boolean)

  const limitNote = skillsLimitNote(skills.length, totalSkills, format)
  if (limitNote) lines.push(`  # ${limitNote}`)

  for (const [category, categorySkills] of categories) {
    lines.push(`  ${formatPromptScalar(category)}:`)

    for (const skill of categorySkills) {
      const name = formatPromptScalar(skill.name)
      const description = skillDescriptionForFormat(skill.description, format)
      const marker = skill.backgroundJobOnly ? '[background task]' : ''
      const value = [marker, description ? formatPromptScalar(description) : ''].filter(Boolean).join(' ')
      lines.push(value ? `    - ${name}: ${value}` : `    - ${name}`)
    }
  }

  lines.push('</available_skills>')
  return lines.join('\n')
}

/**
 * Fits the skill list into the budget while preserving skill identities before
 * spending the remaining space on trigger descriptions.
 */
function applySkillsPromptLimits(skills: SkillPromptEntry[]): {
  skills: SkillPromptEntry[]
  format: SkillsPromptFormat
} {
  const byCount = skills.slice(0, MAX_SKILLS_IN_PROMPT)
  let selected = byCount
  const fits = (candidate: SkillPromptEntry[], format: SkillsPromptFormat): boolean =>
    renderSkillsPrompt(candidate, skills.length, format).length <= MAX_SKILLS_PROMPT_CHARS

  if (fits(selected, { kind: 'full' })) {
    return { skills: selected, format: { kind: 'full' } }
  }

  if (!fits(selected, { kind: 'compact', descriptionMaxChars: 0 })) {
    // The predicate is monotonic because appending a skill only grows the
    // rendered catalog, so this finds the largest identity-only prefix.
    let lo = 0
    let hi = selected.length

    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2)
      if (fits(selected.slice(0, mid), { kind: 'compact', descriptionMaxChars: 0 })) {
        lo = mid
      } else {
        hi = mid - 1
      }
    }

    selected = selected.slice(0, lo)
  }

  let descriptionMaxChars = 0
  if (selected.length > 0 && fits(selected, { kind: 'compact', descriptionMaxChars: COMPACT_DESCRIPTION_MIN_CHARS })) {
    let lo = COMPACT_DESCRIPTION_MIN_CHARS
    let hi = COMPACT_DESCRIPTION_MAX_CHARS

    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2)
      if (fits(selected, { kind: 'compact', descriptionMaxChars: mid })) {
        lo = mid
      } else {
        hi = mid - 1
      }
    }

    descriptionMaxChars = lo
  }

  return { skills: selected, format: { kind: 'compact', descriptionMaxChars } }
}

/** Explains only material catalog degradation to the model. */
function skillsLimitNote(included: number, total: number, format: SkillsPromptFormat): string {
  const descriptionNote =
    format.kind === 'compact'
      ? format.descriptionMaxChars > 0
        ? ' Descriptions shortened.'
        : ' Descriptions omitted.'
      : ''

  if (included < total) return `Skills list truncated to ${included} of ${total} entries.${descriptionNote}`
  return format.kind === 'compact' ? `Skills catalog compacted.${descriptionNote}` : ''
}

/** Returns the full or bounded description selected by the prompt budget. */
function skillDescriptionForFormat(description: string, format: SkillsPromptFormat): string {
  const normalized = description.replace(/\s+/g, ' ').trim()
  if (format.kind === 'full' || normalized.length <= format.descriptionMaxChars) return normalized
  if (format.descriptionMaxChars === 0) return ''
  if (format.descriptionMaxChars <= 3) return normalized.slice(0, format.descriptionMaxChars)
  return `${normalized.slice(0, format.descriptionMaxChars - 3).trimEnd()}...`
}

/** Groups the already-sorted skills without changing their deterministic order. */
function groupSkillsByCategory(skills: SkillPromptEntry[]): Array<[string, SkillPromptEntry[]]> {
  const grouped = new Map<string, SkillPromptEntry[]>()

  for (const skill of skills) {
    const category = skill.category?.trim() || 'general'
    const bucket = grouped.get(category)
    if (bucket) {
      bucket.push(skill)
    } else {
      grouped.set(category, [skill])
    }
  }

  return [...grouped.entries()]
}

/**
 * Sorts skills by category and name for deterministic prompt output.
 */
function compareSkills(a: SkillPromptEntry, b: SkillPromptEntry): number {
  const category = (a.category?.trim() || 'general').localeCompare(b.category?.trim() || 'general')
  if (category !== 0) return category
  return a.name.localeCompare(b.name)
}

/**
 * Renders a prompt-safe scalar, quoting through JSON when a bare value would be ambiguous.
 */
function formatPromptScalar(value: string): string {
  const trimmed = value.trim()
  return isPlainPromptScalar(trimmed) ? trimmed : JSON.stringify(value)
}

/**
 * Checks whether a scalar can appear unquoted in the prompt catalog.
 */
function isPlainPromptScalar(value: string): boolean {
  if (!/^[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(value)) return false
  return !/^(true|false|null|~|yes|no|on|off)$/i.test(value)
}
