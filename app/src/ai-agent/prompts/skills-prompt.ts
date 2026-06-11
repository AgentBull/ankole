import type { Skill } from '../core/harness/types'

const MAX_SKILLS_IN_PROMPT = 1_000
const MAX_SKILLS_PROMPT_CHARS = 1_000_000
const COMPACT_WARNING_OVERHEAD = 150

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
      lines.push(limited.compact || !description ? `    - ${name}` : `    - ${name}: ${description}`)
    }
  }

  lines.push('</available_skills>')
  return lines.join('\n')
}

function formatYamlScalar(value: string): string {
  const trimmed = value.trim()
  return isPlainYamlScalar(trimmed) ? trimmed : JSON.stringify(value)
}

function isPlainYamlScalar(value: string): boolean {
  if (!/^[A-Za-z0-9][A-Za-z0-9_./-]*$/.test(value)) return false
  return !/^(true|false|null|~|yes|no|on|off)$/i.test(value)
}

function applySkillsPromptLimits(skills: Skill[]): { skills: Skill[]; truncated: boolean; compact: boolean } {
  const byCount = skills.slice(0, MAX_SKILLS_IN_PROMPT)
  let selected = byCount
  let truncated = skills.length > byCount.length
  let compact = false
  if (formatSkills(selected, false).length <= MAX_SKILLS_PROMPT_CHARS) return { skills: selected, truncated, compact }

  compact = true
  const compactBudget = MAX_SKILLS_PROMPT_CHARS - COMPACT_WARNING_OVERHEAD
  if (formatSkills(selected, true).length <= compactBudget) return { skills: selected, truncated, compact }

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

function formatSkills(skills: Skill[], compact: boolean): string {
  return skills
    .map(skill => `${skill.category ?? 'general'}\n${skill.name}\n${compact ? '' : skill.description}`)
    .join('\n')
}

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
