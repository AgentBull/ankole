/**
 * Renders the agent's skill catalog into the `## Skills` block of the system prompt.
 *
 * A skill is an SOP the model can pull in on demand, not something it runs — the
 * block is an *index*, and the prompt tells the model to call `skill_view(name)`
 * only when a listed skill actually covers a task it is already about to do. The
 * catalog can be large, so this module also enforces hard size caps (entry count
 * and total characters) and degrades gracefully — first to a name-only "compact"
 * form, then by trimming entries — so the skill section can never blow the context
 * budget on an installation with thousands of skills.
 */
import type { Skill } from '../core/harness/types'

// Upper bounds on what the skill index may contribute to the prompt. The char cap
// is the real guardrail; the count cap is a cheap first cut. COMPACT_WARNING_OVERHEAD
// reserves room for the "list truncated" notice line so adding it can't itself push
// the block back over budget.
const MAX_SKILLS_IN_PROMPT = 1_000
const MAX_SKILLS_PROMPT_CHARS = 1_000_000
const COMPACT_WARNING_OVERHEAD = 150

/**
 * Builds the model-visible skill index as grouped YAML under a `## Skills` heading.
 *
 * Skills flagged `disableModelInvocation` are dropped: those are invocable only by
 * applications, never chosen by the model, so listing them would just invite the
 * model to call something it should not. Returns an empty string when nothing is
 * visible, which lets the caller omit the section entirely.
 */
export function formatSkillsForSystemPrompt(skills: Skill[]): string {
  const visibleSkills = skills.filter(skill => !skill.disableModelInvocation)
  if (visibleSkills.length === 0) return ''
  const limited = applySkillsPromptLimits(visibleSkills)
  const categories = groupSkillsByCategory(limited.skills)

  const lines = [
    '## Skills',
    `The skills below are a catalog of SOPs for specific tasks. A skill does not choose or perform a task; it provides instructions for how to perform a task.

Before performing a task or subtask you are already going to do, call \`skill_view(name)\` only if a listed skill covers that task, then follow the loaded instructions. Otherwise continue without a skill.`,
    '<available_skills>'
  ]
  if (limited.truncated) lines.push(`  # Skills list truncated to ${limited.skills.length} entries.`)

  for (const [category, categorySkills] of categories) {
    lines.push(`  ${formatYamlScalar(category)}:`)
    for (const skill of categorySkills) {
      const name = formatYamlScalar(skill.name)
      const description = formatYamlScalar(skill.description)
      // In compact mode (or when a skill has no description) only the name is
      // emitted; dropping descriptions is the first lever pulled to fit the budget.
      lines.push(limited.compact || !description ? `    - ${name}` : `    - ${name}: ${description}`)
    }
  }

  lines.push('</available_skills>')
  return lines.join('\n')
}

/**
 * Renders a string as a YAML scalar, quoting via JSON only when it is not safe bare.
 * Quoting through `JSON.stringify` (not the trimmed value) preserves the original
 * text exactly, including any surrounding whitespace, so a quoted description is not
 * silently altered.
 */
function formatYamlScalar(value: string): string {
  const trimmed = value.trim()
  return isPlainYamlScalar(trimmed) ? trimmed : JSON.stringify(value)
}

/**
 * Decides whether a value can appear unquoted in YAML. Rejects anything with
 * special characters, and also rejects the YAML boolean/null look-alikes
 * (`yes`, `no`, `on`, `off`, `~`, ...) because bare they would be parsed as those
 * types instead of as the literal skill/category string.
 */
function isPlainYamlScalar(value: string): boolean {
  if (!/^[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(value)) return false
  return !/^(true|false|null|~|yes|no|on|off)$/i.test(value)
}

/**
 * Fits the skill list into the budget through three escalating stages, stopping at
 * the first that fits:
 *  1. cap the count and keep full descriptions;
 *  2. switch to compact (name-only) form, which is far smaller;
 *  3. binary-search the largest prefix of compact entries that still fits.
 *
 * Descriptions are sacrificed before entries so the model keeps *seeing* every
 * skill it can (even without a blurb) for as long as possible — knowing a skill
 * exists matters more than knowing its description. `truncated`/`compact` flags
 * are returned so the caller can surface the right warning. The size estimate uses
 * the same `formatSkills` serialization at each step, which approximates the final
 * block closely enough for budgeting without re-rendering the full YAML.
 */
function applySkillsPromptLimits(skills: Skill[]): { skills: Skill[]; truncated: boolean; compact: boolean } {
  const byCount = skills.slice(0, MAX_SKILLS_IN_PROMPT)
  let selected = byCount
  let truncated = skills.length > byCount.length
  let compact = false
  if (formatSkills(selected, false).length <= MAX_SKILLS_PROMPT_CHARS) return { skills: selected, truncated, compact }

  compact = true
  const compactBudget = MAX_SKILLS_PROMPT_CHARS - COMPACT_WARNING_OVERHEAD
  if (formatSkills(selected, true).length <= compactBudget) return { skills: selected, truncated, compact }

  // Largest-fitting-prefix search: `lo` is the biggest prefix length known to fit,
  // `hi` the smallest known not to. Monotonic because appending a skill only grows
  // the string, so the predicate flips exactly once and binary search is valid.
  let lo = 0
  let hi = selected.length
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2)
    if (formatSkills(selected.slice(0, mid), true).length <= compactBudget) lo = mid
    else hi = mid - 1
  }
  selected = selected.slice(0, lo)
  truncated = true
  return { skills: selected, truncated, compact }
}

/**
 * Cheap size proxy used only by the budget search. It is intentionally not the
 * final YAML — it just needs to grow with the same inputs (category, name, and
 * optionally description) so length comparisons rank candidates correctly.
 */
function formatSkills(skills: Skill[], compact: boolean): string {
  return skills
    .map(skill => `${skill.category ?? 'general'}\n${skill.name}\n${compact ? '' : skill.description}`)
    .join('\n')
}

/**
 * Buckets skills by category for the grouped index, sorting deterministically
 * (category then name) first so the resulting order — and thus which entries get
 * trimmed under truncation — is stable across runs rather than insertion-dependent.
 */
function groupSkillsByCategory(skills: Skill[]): Array<[string, Skill[]]> {
  const grouped = new Map<string, Skill[]>()
  for (const skill of [...skills].sort(compareSkills)) {
    const category = skill.category?.trim() || 'general'
    const bucket = grouped.get(category)
    if (bucket) bucket.push(skill)
    else grouped.set(category, [skill])
  }
  return [...grouped.entries()]
}

function compareSkills(a: Skill, b: Skill): number {
  const category = (a.category?.trim() || 'general').localeCompare(b.category?.trim() || 'general')
  if (category !== 0) return category
  return a.name.localeCompare(b.name)
}
