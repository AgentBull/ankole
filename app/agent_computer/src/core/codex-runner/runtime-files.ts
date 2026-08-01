import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync
} from 'node:fs'
import { join } from 'node:path'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RPCRequester, BrainSnapshot, RuntimeSkillSummary } from '../../lanes/rpc_lane'
import { formatAgentDurableContext } from '../../prompts/durable_context'
import {
  assertValidSkillName,
  composeNativeSkillFile,
  normalizeEnabledSkill,
  resolveSkillFilesystemRoot,
  resolveSkillOverlayText,
  type SkillFileRoots
} from '../../skills/effective-skill'

export type MaterializedCodexJobSkill = {
  name: string
  sourcePath: string
}

export type MaterializedCodexJobRuntimeFiles = {
  root: string
  skillsRoot: string
  skills: MaterializedCodexJobSkill[]
  expectedSkillNames: string[]
  cleanup(): void
}

export async function materializeCodexJobRuntimeFiles(input: {
  turn: ActorTurnRef
  jobRoot: string
  enabledSkills: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
}): Promise<MaterializedCodexJobRuntimeFiles> {
  const root = join(input.jobRoot, '.ankole')
  const skillsRoot = join(root, 'skills')
  rmSync(skillsRoot, { recursive: true, force: true })
  mkdirSync(skillsRoot, { recursive: true })

  try {
    const skills = await materializeSkills(input, skillsRoot)
    return {
      root,
      skillsRoot,
      skills,
      expectedSkillNames: skills.map(skill => skill.name),
      cleanup: () => undefined
    }
  } catch (error) {
    rmSync(skillsRoot, { recursive: true, force: true })
    throw error
  }
}

export function renderCodexJobAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  jobGuidance?: string
  brainSnapshot?: BrainSnapshot
  timezone?: string | null
  now?: Date
}): { content: string } {
  return {
    content: renderTaskAgents({
      jobRoot: input.jobRoot,
      soul: input.soul,
      mission: input.mission,
      jobGuidance: input.jobGuidance,
      brainSnapshot: input.brainSnapshot,
      timezone: input.timezone,
      now: input.now ?? new Date()
    })
  }
}

/**
 * Reads the shared Job guidance template shipped with the app library.
 * A missing template keeps the Job usable; the guidance section is skipped.
 */
export function readCodexJobGuidance(builtinSkillsRoot: string): string | undefined {
  const path = join(builtinSkillsRoot, 'templates', 'AGENT_JOB.md')
  if (!existsSync(path)) return undefined
  const content = readFileSync(path, 'utf8').trim()
  return content || undefined
}

async function materializeSkills(
  input: Parameters<typeof materializeCodexJobRuntimeFiles>[0],
  skillsRoot: string
): Promise<MaterializedCodexJobSkill[]> {
  const enabledSkills = input.enabledSkills
    .map(skill => {
      const normalized = normalizeEnabledSkill(skill)
      if (!normalized) throw new Error(`enabled skill has invalid name: ${skill.skillName}`)
      return normalized
    })
    .sort((left, right) => compareCodePoints(left.skillName, right.skillName))

  if (new Set(enabledSkills.map(skill => skill.skillName)).size !== enabledSkills.length) {
    throw new Error('enabled skill names must be unique')
  }
  if (enabledSkills.length > 0 && !input.skillRoots) {
    throw new Error('Codex enabled skills require worker skill source roots')
  }

  return await Promise.all(
    enabledSkills.map(async skill => {
      assertValidSkillName(skill.skillName)
      const sourcePath = realpathSync(resolveSkillFilesystemRoot(skill, { skillRoots: input.skillRoots! }))
      if (!statSync(sourcePath).isDirectory()) throw new Error(`skill source is not a directory: ${skill.skillName}`)
      const sourceSkillPath = join(sourcePath, 'SKILL.md')
      if (!existsSync(sourceSkillPath)) throw new Error(`enabled skill is missing SKILL.md: ${skill.skillName}`)

      const projectedPath = join(skillsRoot, skill.skillName)
      const overlay = await resolveSkillOverlayText(skill.skillName, { turn: input.turn, rpc: input.rpc })
      if (!overlay) {
        symlinkSync(sourcePath, projectedPath, 'dir')
        return { name: skill.skillName, sourcePath: projectedPath }
      }

      cpSync(sourcePath, projectedPath, { recursive: true, dereference: false })
      writeFileSync(
        join(projectedPath, 'SKILL.md'),
        composeNativeSkillFile(readFileSync(sourceSkillPath, 'utf8'), overlay),
        {
          mode: 0o600
        }
      )
      return { name: skill.skillName, sourcePath: projectedPath }
    })
  )
}

function renderTaskAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  jobGuidance?: string
  brainSnapshot?: BrainSnapshot
  background?: string
  notes?: string
  timezone?: string | null
  now: Date
}): string {
  const executionContext = [
    `Current time: ${input.now.toISOString()}${input.timezone ? ` (${input.timezone})` : ''}.`,
    `Job workspace (the process cwd): ${input.jobRoot}.`,
    'All absolute paths shown to you are the real paths inside this Worker. Relative paths resolve from the Job workspace.',
    'Your final message is the Job result for the caller. State outcomes, evidence, relevant paths, and remaining risks.',
    'The long-term memory system (codename Brain) preserves chat messages, curated current knowledge entries, and external materials that people ask it to learn so future work can retrieve the few most relevant items.',
    'The caller owns user-visible replies, attachments, scheduling, and durable Skill writes. Projected long-term memory tools operate only inside the server-validated caller conversation scope.',
    'If genuinely required information is missing, the lead agent must call request_parent_input; child agents must report the question to the lead. Do not call request_user_input, which is unavailable in this background execution.',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ].join('\n')

  return [
    '# Ankole Background Agent Job Context',
    section('SOUL', input.soul),
    section('MISSION', input.mission),
    section('Durable Context', formatAgentDurableContext(input.brainSnapshot)),
    section('Background', input.background),
    section('Notes', input.notes),
    section('Execution Context', executionContext),
    section('Job Guidance', input.jobGuidance)
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

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
