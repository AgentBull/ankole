import type { Skill } from './types'

const MAX_SKILLS_IN_PROMPT = 1_000
const MAX_SKILLS_PROMPT_CHARS = 1_000_000
const COMPACT_WARNING_OVERHEAD = 150

export function formatSkillsForSystemPrompt(skills: Skill[]): string {
  const visibleSkills = skills.filter(skill => !skill.disableModelInvocation)
  if (visibleSkills.length === 0) return ''
  const limited = applySkillsPromptLimits(visibleSkills)

  const lines = [
    'The following skills provide specialized instructions for specific tasks.',
    'Read the full skill file when the task matches its description.',
    'When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.',
    '',
    '<available_skills>'
  ]
  if (limited.truncated) lines.push(`  <notice>Skills list truncated to ${limited.skills.length} entries.</notice>`)

  for (const skill of limited.skills) {
    lines.push('  <skill>')
    lines.push(`    <name>${escapeXml(skill.name)}</name>`)
    if (!limited.compact) lines.push(`    <description>${escapeXml(skill.description)}</description>`)
    lines.push(`    <location>${escapeXml(skill.filePath)}</location>`)
    lines.push('  </skill>')
  }

  lines.push('</available_skills>')
  return lines.join('\n')
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
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
  return skills.map(skill => `${skill.name}\n${compact ? '' : skill.description}\n${skill.filePath}`).join('\n')
}
