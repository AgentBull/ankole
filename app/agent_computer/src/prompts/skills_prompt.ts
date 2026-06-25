/**
 * Renders the agent's skill catalog into the `## Skills` block of the system prompt.
 *
 * A skill is an SOP the model can pull in on demand, not something it runs. This
 * block is only an index, so the prompt tells the model to call `skill_view(name)`
 * when a listed skill covers work it is already about to do. The catalog can grow
 * large, so this module keeps BullX's hard size caps and graceful degradation:
 * first count-limit, then name-only compact mode, then prefix trimming.
 */
export type SkillPromptEntry = {
  name: string
  description: string
  category?: string
  disableModelInvocation?: boolean
}

// The char cap is the real guardrail; the count cap is a cheap first cut. The
// warning overhead reserves room for the truncation line so adding the warning
// cannot push the block back over budget.
const MAX_SKILLS_IN_PROMPT = 1_000
const MAX_SKILLS_PROMPT_CHARS = 1_000_000
const COMPACT_WARNING_OVERHEAD = 150

/**
 * Builds the model-visible skill index as grouped YAML under a `## Skills` heading.
 *
 * Skills flagged `disableModelInvocation` are dropped because those are invocable
 * only by applications, never chosen by the model. Returning an empty string lets
 * the caller omit the section entirely.
 */
export function formatSkillsForSystemPrompt(skills: SkillPromptEntry[]): string {
  const visibleSkills = skills.filter(skill => !skill.disableModelInvocation)
  if (visibleSkills.length === 0) return ''

  const limited = applySkillsPromptLimits(visibleSkills)
  const categories = groupSkillsByCategory(limited.skills)

  const lines = [
    '## Skills',
    '',
    `You have access to the following skills. Skills are task-specific instructions and references.
Before performing a task or subtask you are already going to do, call \`skill_view(name)\` only if a listed skill covers that task, then follow the loaded instructions. Otherwise continue without a skill.`,
    '<available_skills>'
  ]

  if (limited.truncated) lines.push(`  # Skills list truncated to ${limited.skills.length} entries.`)

  for (const [category, categorySkills] of categories) {
    lines.push(`  ${formatYamlScalar(category)}:`)

    for (const skill of categorySkills) {
      const name = formatYamlScalar(skill.name)
      const description = formatYamlScalar(skill.description)
      // In compact mode descriptions are sacrificed before entries so the model
      // can still see as many callable skill names as possible.
      lines.push(limited.compact || !description ? `    - ${name}` : `    - ${name}: ${description}`)
    }
  }

  lines.push('</available_skills>')
  return lines.join('\n')
}

/**
 * Fits the skill list into the budget through three escalating stages:
 * count cap, compact form, then largest-fitting-prefix search.
 */
function applySkillsPromptLimits(skills: SkillPromptEntry[]): {
  skills: SkillPromptEntry[]
  truncated: boolean
  compact: boolean
} {
  const byCount = skills.slice(0, MAX_SKILLS_IN_PROMPT)
  let selected = byCount
  let truncated = skills.length > byCount.length
  let compact = false

  if (formatSkills(selected, false).length <= MAX_SKILLS_PROMPT_CHARS) {
    return { skills: selected, truncated, compact }
  }

  compact = true
  const compactBudget = MAX_SKILLS_PROMPT_CHARS - COMPACT_WARNING_OVERHEAD
  if (formatSkills(selected, true).length <= compactBudget) {
    return { skills: selected, truncated, compact }
  }

  // The predicate is monotonic because appending a skill only grows the string,
  // so binary search finds the largest compact prefix that fits.
  let lo = 0
  let hi = selected.length

  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2)
    if (formatSkills(selected.slice(0, mid), true).length <= compactBudget) {
      lo = mid
    } else {
      hi = mid - 1
    }
  }

  selected = selected.slice(0, lo)
  truncated = true
  return { skills: selected, truncated, compact }
}

/**
 * Cheap size proxy used by the budget search. It only needs to grow with the
 * same inputs as the final YAML, not reproduce it exactly.
 */
function formatSkills(skills: SkillPromptEntry[], compact: boolean): string {
  return skills
    .map(skill => `${skill.category ?? 'general'}\n${skill.name}\n${compact ? '' : skill.description}`)
    .join('\n')
}

/**
 * Groups and sorts skills deterministically so truncation is stable across runs.
 */
function groupSkillsByCategory(skills: SkillPromptEntry[]): Array<[string, SkillPromptEntry[]]> {
  const grouped = new Map<string, SkillPromptEntry[]>()

  for (const skill of [...skills].sort(compareSkills)) {
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

function compareSkills(a: SkillPromptEntry, b: SkillPromptEntry): number {
  const category = (a.category?.trim() || 'general').localeCompare(b.category?.trim() || 'general')
  if (category !== 0) return category
  return a.name.localeCompare(b.name)
}

/**
 * Renders a YAML scalar, quoting through JSON when a bare value would be unsafe.
 */
function formatYamlScalar(value: string): string {
  const trimmed = value.trim()
  return isPlainYamlScalar(trimmed) ? trimmed : JSON.stringify(value)
}

function isPlainYamlScalar(value: string): boolean {
  if (!/^[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(value)) return false
  return !/^(true|false|null|~|yes|no|on|off)$/i.test(value)
}
