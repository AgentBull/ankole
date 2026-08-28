import { existsSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { labeledZonedDateTime } from '../../../prompts/zoned_time'

const legacySkillMigrationMarker = '<!-- ankole-background-job-skill-view-v1='

export function renderCodexJobAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  jobGuidance?: string
  skillsPrompt?: string
  lazySkillRouting?: boolean
  timezone?: string | null
  now?: Date
}): { content: string } {
  return {
    content: renderTaskAgents({
      jobRoot: input.jobRoot,
      soul: input.soul,
      mission: input.mission,
      jobGuidance: input.jobGuidance,
      skillsPrompt: input.skillsPrompt,
      lazySkillRouting: input.lazySkillRouting,
      timezone: input.timezone,
      now: input.now ?? new Date()
    })
  }
}

/** Reads the shared Job guidance template shipped with the app library. */
export function readCodexJobGuidance(builtinSkillsRoot: string): string | undefined {
  const path = join(builtinSkillsRoot, 'templates', 'AGENT_JOB.md')
  if (!existsSync(path)) return undefined
  const content = readFileSync(path, 'utf8').trim()
  return content || undefined
}

/**
 * Migrates native Skill roots that predate skill_view. Returns true until the
 * thread recorded by the marker is replaced.
 */
export function migrateLegacyCodexJobSkillRoots(input: {
  jobRoot: string
  runtimeThreadID: string
  skillsPrompt: string
}): boolean {
  const legacyRoots = [join(input.jobRoot, '.agents', 'skills'), join(input.jobRoot, '.ankole', 'agent-plugins')]
  const agentsPath = join(input.jobRoot, 'AGENTS.md')
  const existing = existsSync(agentsPath) ? readFileSync(agentsPath, 'utf8') : ''
  let migratedThreadID = legacySkillMigrationThreadID(existing)
  const hasLegacyRoots = legacyRoots.some(existsSync)

  if (!migratedThreadID && hasLegacyRoots) {
    const marker = `${legacySkillMigrationMarker}${encodeURIComponent(input.runtimeThreadID)} -->`
    const skillsPrompt = input.skillsPrompt.trim()
    const separator =
      existing.length === 0 ? '' : existing.endsWith('\n\n') ? '' : existing.endsWith('\n') ? '\n' : '\n\n'
    atomicWrite(agentsPath, `${existing}${separator}${[marker, skillsPrompt].filter(Boolean).join('\n\n')}\n`)
    migratedThreadID = input.runtimeThreadID
  }

  if (hasLegacyRoots) {
    for (const root of legacyRoots) rmSync(root, { recursive: true, force: true })
  }
  return migratedThreadID === input.runtimeThreadID
}

function legacySkillMigrationThreadID(content: string): string | undefined {
  const start = content.indexOf(legacySkillMigrationMarker)
  if (start === -1) return undefined
  const valueStart = start + legacySkillMigrationMarker.length
  const valueEnd = content.indexOf(' -->', valueStart)
  if (valueEnd === -1) throw new Error('invalid legacy Background Job Skill migration marker')
  return decodeURIComponent(content.slice(valueStart, valueEnd))
}

function atomicWrite(path: string, content: string): void {
  const temporary = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`
  try {
    writeFileSync(temporary, content, { mode: 0o600 })
    renameSync(temporary, path)
  } finally {
    rmSync(temporary, { force: true })
  }
}

function renderTaskAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  jobGuidance?: string
  skillsPrompt?: string
  lazySkillRouting?: boolean
  background?: string
  notes?: string
  timezone?: string | null
  now: Date
}): string {
  const startedAt = labeledZonedDateTime(input.now, input.timezone)
  const executionContext = [
    startedAt
      ? `Job start time: ${startedAt.text} (${startedAt.timezone}). Report times in ${startedAt.timezone}; the Worker system clock is UTC, so shell commands and the environment_context timezone show UTC.`
      : '',
    `Job workspace (the process cwd): ${input.jobRoot}.`,
    'All absolute paths shown to you are the real paths inside this Worker. Relative paths resolve from the Job workspace.',
    'Your final message is the Job result and the caller accepts it as the verification record: verify the work against what the task says the deliverable must satisfy, and state the outcome with evidence, relevant paths, and remaining risks.',
    'The caller owns user-visible replies, attachments, scheduling, and durable Skill writes.',
    'If genuinely required information is missing, the lead agent must call request_parent_input; child agents must report the question to the lead.',
    input.lazySkillRouting
      ? 'A `lazyload-agent-skills/` record is a Skill discovery record; load it with `skill_view`, while `get_page` delegates to `skill_view` and returns the loaded Skill.'
      : '',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ]
    .filter(Boolean)
    .join('\n')

  return [
    '# Ankole Background Agent Job Context',
    section('SOUL', input.soul),
    section('MISSION', input.mission),
    section('Background', input.background),
    section('Notes', input.notes),
    section('Execution Context', executionContext),
    section('Job Guidance', input.jobGuidance),
    input.skillsPrompt?.trim()
  ]
    .filter(Boolean)
    .join('\n\n')
    .trim()
    .concat('\n')
}

function section(title: string, content: string | undefined): string {
  const text = content?.trim()
  return text ? `## ${title}\n\n${text}` : ''
}
